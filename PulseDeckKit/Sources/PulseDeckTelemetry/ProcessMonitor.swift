#if os(macOS)
import Darwin
import PulseDeckCore

/// Process table telemetry (SPEC §20, §21) from libproc.
///
/// Per process and tick: `proc_pidinfo(PROC_PIDTASKALLINFO)` (identity, name, owner, thread
/// count) and `proc_pid_rusage(RUSAGE_INFO_V4)` (CPU time, physical footprint, disk I/O). For
/// other users' processes the kernel refuses task-level information (`EPERM`); those rows keep
/// name and PID from `PROC_PIDTBSDINFO` and show *Not Available* elsewhere (L‑7). A process that
/// exits between listing and querying (`ESRCH`) is simply omitted — a normal race.
///
/// `libproc.h` describes itself as "private interfaces … subject to change" although it ships in
/// the SDK and SPEC §21 names it (IMPLEMENTATION_PLAN.md R2). Every failure degrades to
/// `.unavailable`; nothing here traps.
///
/// Demand-driven: sampled only while the Processes section is visible.
public actor ProcessMonitor: TelemetryProvider {
    private struct NameInfo: Sendable {
        var name: String
        var path: String?
    }

    /// Extra PID slots beyond the kernel's count, for processes spawned between the two
    /// `proc_listallpids` calls.
    private static let pidSlack = 64
    /// `PROC_PIDPATHINFO_MAXSIZE` from `libproc.h` (4 × `MAXPATHLEN`).
    private static let pathBufferSize = 4 * 1024

    private let timebase: MachTimebase?
    private var tracker = ProcessUsageTracker()
    /// Names and paths never change for a process identity, so they are looked up once.
    private var names: [ProcessIdentity: NameInfo] = [:]
    /// Grow-only scratch storage reused across samples.
    private var pidBuffer: [pid_t] = []
    private var pathBuffer = [UInt8](repeating: 0, count: ProcessMonitor.pathBufferSize)

    public init() {
        var info = mach_timebase_info_data_t()
        timebase = mach_timebase_info(&info) == KERN_SUCCESS
            ? MachTimebase(numerator: info.numer, denominator: info.denom)
            : nil
    }

    public func capability() -> TelemetryCapability {
        guard timebase != nil else { return .unsupported(.transientFailure("mach_timebase_info failed")) }
        return listPIDs() == nil ? .unsupported(.transientFailure("proc_listallpids failed")) : .supported
    }

    public func sample(at instant: MonotonicInstant) -> MetricState<[ProcessSnapshot]> {
        guard let timebase else { return .unavailable(.transientFailure("mach_timebase_info failed")) }
        guard let pids = listPIDs() else { return .unavailable(.transientFailure("proc_listallpids failed")) }

        var readings: [ProcessReading] = []
        readings.reserveCapacity(pids.count)
        for pid in pids {
            if let reading = read(pid: pid, timebase: timebase) {
                readings.append(reading)
            }
        }
        let live = Set(readings.map(\.identity))
        if names.count > live.count {
            names = names.filter { live.contains($0.key) }
        }
        return .available(tracker.update(readings, at: instant))
    }

    public func invalidateBaselines() {
        tracker.reset()
    }

    // MARK: - libproc

    private func listPIDs() -> [pid_t]? {
        // With a NULL buffer the call returns the current number of processes.
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return nil }
        let capacity = Int(estimate) + Self.pidSlack
        if pidBuffer.count < capacity {
            pidBuffer = [pid_t](repeating: 0, count: capacity)
        }
        let count = pidBuffer.withUnsafeMutableBytes { bytes in
            proc_listallpids(bytes.baseAddress, Int32(bytes.count))
        }
        guard count > 0 else { return nil }
        return Array(pidBuffer.prefix(min(Int(count), pidBuffer.count)))
    }

    private func read(pid: pid_t, timebase: MachTimebase) -> ProcessReading? {
        let basic: BasicProcessInfo
        let threads: Result<Int, UnavailableReasonError>
        var all = proc_taskallinfo()
        let allSize = Int32(MemoryLayout<proc_taskallinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTASKALLINFO, 0, &all, allSize) == allSize {
            basic = BasicProcessInfo(all.pbsd)
            threads = .success(Int(all.ptinfo.pti_threadnum))
        } else {
            let error = errno
            if error == ESRCH { return nil }
            // Task info is refused for other users' processes. `sysctl(KERN_PROC_PID)` still
            // provides identity, short name and owner for every process (as `ps` uses it).
            guard let fallback = ProcessControl.basicInfo(of: pid) else { return nil }
            basic = fallback
            threads = .failure(UnavailableReasonError(Self.reason(for: error)))
        }

        let identity = ProcessIdentity(pid: pid, startTimeMicroseconds: basic.startTimeMicroseconds)

        let usage: Result<ProcessReading.Usage, UnavailableReasonError>
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        if status == 0 {
            // CPU times are Mach absolute-time units, not nanoseconds (R3).
            let ticks = info.ri_user_time &+ info.ri_system_time
            if let nanoseconds = timebase.nanoseconds(fromTicks: ticks) {
                usage = .success(.init(
                    cpuTimeNanoseconds: nanoseconds,
                    physicalFootprintBytes: info.ri_phys_footprint,
                    diskBytesRead: info.ri_diskio_bytesread,
                    diskBytesWritten: info.ri_diskio_byteswritten
                ))
            } else {
                usage = .failure(UnavailableReasonError(.transientFailure("invalid timebase")))
            }
        } else {
            let error = errno
            if error == ESRCH { return nil }
            usage = .failure(UnavailableReasonError(Self.reason(for: error)))
        }

        let nameInfo = names[identity] ?? lookUpName(pid: pid, basic: basic)
        names[identity] = nameInfo
        return ProcessReading(
            identity: identity,
            name: nameInfo.name,
            path: nameInfo.path,
            userID: basic.userID,
            usage: usage,
            threadCount: threads
        )
    }

    /// Display name: the executable's file name from its path (not truncated), else the kernel's
    /// short names (`pbi_name` up to 32 characters, `pbi_comm`/`p_comm` up to 16).
    private func lookUpName(pid: pid_t, basic: BasicProcessInfo) -> NameInfo {
        let length = pathBuffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        let path = length > 0 ? String(decoding: pathBuffer.prefix(Int(length)), as: UTF8.self) : nil
        let fileName = path.flatMap { $0.split(separator: "/").last.map(String.init) }
        let name = ([fileName] + basic.names)
            .compactMap { $0 }
            .first { !$0.isEmpty }
        return NameInfo(name: name ?? "PID \(pid)", path: path)
    }

    private static func reason(for error: Int32) -> UnavailableReason {
        error == EPERM || error == EACCES ? .permissionDenied : .transientFailure("libproc errno \(error)")
    }

}

/// Identity, owner and kernel short names of a process, from `proc_bsdinfo` or `kinfo_proc`.
struct BasicProcessInfo {
    var startTimeMicroseconds: UInt64
    var userID: UInt32
    /// Kernel names, best first.
    var names: [String]

    private static let microsecondsPerSecond: UInt64 = 1_000_000

    init(_ bsd: proc_bsdinfo) {
        startTimeMicroseconds = bsd.pbi_start_tvsec &* Self.microsecondsPerSecond &+ bsd.pbi_start_tvusec
        userID = bsd.pbi_uid
        names = [Self.cString(bsd.pbi_name), Self.cString(bsd.pbi_comm)]
    }

    init(_ kinfo: kinfo_proc) {
        // `p_starttime` is a macro for `p_un.__p_starttime` in `sys/proc.h`. It is the same kernel
        // field `pbi_start_tv*` reports, so identities agree whichever source was used.
        let start = kinfo.kp_proc.p_un.__p_starttime
        startTimeMicroseconds = UInt64(clamping: start.tv_sec) &* Self.microsecondsPerSecond &+ UInt64(clamping: start.tv_usec)
        userID = kinfo.kp_eproc.e_ucred.cr_uid
        names = [Self.cString(kinfo.kp_proc.p_comm)]
    }

    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { bytes in String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
    }
}

/// Signals that `ProcessControl` can send.
public enum ProcessSignal: Sendable {
    /// `SIGTERM`: ask the process to exit.
    case terminate
    /// `SIGKILL`: end the process immediately.
    case kill
}

/// Why a process action failed.
public enum ProcessControlError: Error, Hashable, Sendable {
    /// The process is gone, or its PID now belongs to a different process.
    case processExited
    /// The process belongs to another user (or is protected by the system).
    case permissionDenied
    case failed(errno: Int32)
}

/// Process actions (SPEC §22). Every action first re-checks that the PID still belongs to the
/// same process (start time), so a reused PID is never signalled by mistake.
public enum ProcessControl {
    /// Whether `identity` still names a running process.
    public static func isRunning(_ identity: ProcessIdentity) -> Bool {
        guard let info = basicInfo(of: identity.pid) else { return false }
        return info.startTimeMicroseconds == identity.startTimeMicroseconds
    }

    public static func send(_ signal: ProcessSignal, to identity: ProcessIdentity) -> Result<Void, ProcessControlError> {
        guard isRunning(identity) else { return .failure(.processExited) }
        let number = switch signal {
        case .terminate: SIGTERM
        case .kill: SIGKILL
        }
        guard Darwin.kill(identity.pid, number) == 0 else {
            let error = errno
            switch error {
            case ESRCH: return .failure(.processExited)
            case EPERM: return .failure(.permissionDenied)
            default: return .failure(.failed(errno: error))
            }
        }
        return .success(())
    }

    /// `PROC_PIDTBSDINFO` where permitted (own processes), otherwise `sysctl(KERN_PROC_PID)`,
    /// which the kernel answers for every process. `nil` if the process does not exist.
    static func basicInfo(of pid: pid_t) -> BasicProcessInfo? {
        var bsd = proc_bsdinfo()
        let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize {
            return BasicProcessInfo(bsd)
        }
        var kinfo = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { name in
            sysctl(name.baseAddress, UInt32(name.count), &kinfo, &size, nil, 0)
        }
        // A PID that does not exist succeeds with size 0.
        guard result == 0, size == MemoryLayout<kinfo_proc>.stride else { return nil }
        return BasicProcessInfo(kinfo)
    }
}
#endif
