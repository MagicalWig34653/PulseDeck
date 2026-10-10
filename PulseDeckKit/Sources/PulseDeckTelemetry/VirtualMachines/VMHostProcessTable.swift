#if os(macOS)
import Darwin
import Foundation
import PulseDeckCore

/// The processes of VM runtimes on the host, as seen at one tick.
struct VMProcessTableSnapshot: Sendable {
    /// Only processes whose executable is on `VMProcessAllowList`; all other processes are not
    /// listed (adapters match VMs against VM runtimes only).
    var processes: [VMHostProcess]
    /// PID plus start time for every listed process (for usage baselines).
    var identities: [Int32: ProcessIdentity]
}

/// One cheap snapshot of the VM-relevant part of the process table per tick.
///
/// - One `sysctl(KERN_PROC_ALL)` lists every process (all users) with PID, parent, start time and
///   the kernel's short name (`p_comm`, cut at 16 characters).
/// - Only for names that may be VM runtimes (`VMProcessAllowList.mayMatch`) the full path is looked
///   up (`proc_pidpath`) and, for confirmed runtimes, the argument vector
///   (`sysctl KERN_PROCARGS2`). Both are cached per process identity (PID + start time): a process
///   costs these calls once, and unrelated processes cost nothing after the first tick.
/// - Arguments of other users' processes are refused by the kernel (`EPERM`/`EINVAL`); such a
///   process is listed with empty arguments.
///
/// Cumulative usage (`usage(of:)`) is read with `proc_pid_rusage`, as `ProcessMonitor` does: CPU
/// times are in Mach absolute-time units and converted with `mach_timebase_info`.
struct VMHostProcessTable {
    private enum Entry {
        case unrelated
        case runtime(VMHostProcess)
    }

    /// Extra `kinfo_proc` slots for processes spawned between sizing and reading the list.
    private static let processSlack = 64
    /// `PROC_PIDPATHINFO_MAXSIZE` from `libproc.h` (4 × `MAXPATHLEN`).
    private static let pathBufferSize = 4 * 1024
    private static let microsecondsPerSecond: UInt64 = 1_000_000

    private let timebase: MachTimebase?
    private var known: [ProcessIdentity: Entry] = [:]
    private var processBuffer: [kinfo_proc] = []
    private var pathBuffer = [UInt8](repeating: 0, count: VMHostProcessTable.pathBufferSize)
    /// `kern.argmax`: the most `KERN_PROCARGS2` can return (1 MiB on current macOS). Allocated on first use.
    private var argumentBuffer: [UInt8] = []

    init() {
        var info = mach_timebase_info_data_t()
        timebase = mach_timebase_info(&info) == KERN_SUCCESS
            ? MachTimebase(numerator: info.numer, denominator: info.denom)
            : nil
    }

    /// `nil` only if the kernel refuses the process list altogether.
    mutating func snapshot() -> VMProcessTableSnapshot? {
        guard let count = listProcesses() else { return nil }
        var processes: [VMHostProcess] = []
        var identities: [Int32: ProcessIdentity] = [:]
        var live = Set<ProcessIdentity>(minimumCapacity: count)
        for index in 0..<count {
            let pid = processBuffer[index].kp_proc.p_pid
            guard pid > 0 else { continue }
            // `p_starttime` is `p_un.__p_starttime`; the same value ProcessMonitor uses for identities.
            let start = processBuffer[index].kp_proc.p_un.__p_starttime
            let identity = ProcessIdentity(
                pid: pid,
                startTimeMicroseconds: UInt64(clamping: start.tv_sec) &* Self.microsecondsPerSecond &+ UInt64(clamping: start.tv_usec)
            )
            live.insert(identity)
            let entry: Entry
            if let cached = known[identity] {
                entry = cached
            } else {
                entry = classify(index: index, pid: pid)
                known[identity] = entry
            }
            if case .runtime(let process) = entry {
                processes.append(process)
                identities[pid] = identity
            }
        }
        if known.count > live.count {
            known = known.filter { live.contains($0.key) }
        }
        return VMProcessTableSnapshot(processes: processes, identities: identities)
    }

    /// Cumulative CPU time, memory footprint and disk bytes of one process.
    func usage(of pid: Int32) -> Result<ProcessReading.Usage, UnavailableReasonError> {
        guard let timebase else { return .failure(UnavailableReasonError(.transientFailure("mach_timebase_info failed"))) }
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        guard status == 0 else {
            let error = errno
            switch error {
            case ESRCH: return .failure(UnavailableReasonError(.sourceRemoved))
            case EPERM, EACCES: return .failure(UnavailableReasonError(.permissionDenied))
            default: return .failure(UnavailableReasonError(.transientFailure("libproc errno \(error)")))
            }
        }
        // CPU times are Mach absolute-time units, not nanoseconds.
        guard let nanoseconds = timebase.nanoseconds(fromTicks: info.ri_user_time &+ info.ri_system_time) else {
            return .failure(UnavailableReasonError(.transientFailure("invalid timebase")))
        }
        return .success(.init(
            cpuTimeNanoseconds: nanoseconds,
            // The footprint is the figure Activity Monitor shows as "Memory"; for a hypervisor it
            // includes the guest RAM the host has actually touched.
            physicalFootprintBytes: info.ri_phys_footprint,
            diskBytesRead: info.ri_diskio_bytesread,
            diskBytesWritten: info.ri_diskio_byteswritten
        ))
    }

    // MARK: - Classification

    private mutating func classify(index: Int, pid: pid_t) -> Entry {
        let shortName = withUnsafeBytes(of: processBuffer[index].kp_proc.p_comm) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        guard VMProcessAllowList.mayMatch(kernelName: shortName) else { return .unrelated }

        // The kernel name is cut at 16 characters: confirm with the file name of the executable.
        let length = pathBuffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        let path = length > 0 ? String(decoding: pathBuffer.prefix(Int(length)), as: UTF8.self) : nil
        let fileName = path.flatMap { $0.split(separator: "/").last.map(String.init) } ?? shortName
        guard VMProcessAllowList.matches(name: fileName) else { return .unrelated }

        let parsed = readArguments(pid: pid)
        return .runtime(VMHostProcess(
            pid: pid,
            parentPID: processBuffer[index].kp_eproc.e_ppid,
            name: fileName,
            executablePath: path ?? parsed?.executablePath,
            arguments: parsed?.arguments ?? []
        ))
    }

    /// `sysctl(CTL_KERN, KERN_PROCARGS2, pid)`; `nil` when the kernel refuses (other users'
    /// processes, a process that just exited).
    private mutating func readArguments(pid: pid_t) -> VMParsedProcessArguments? {
        if argumentBuffer.isEmpty {
            var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
            var argmax: Int32 = 0
            var size = MemoryLayout<Int32>.size
            let result = mib.withUnsafeMutableBufferPointer { name in
                sysctl(name.baseAddress, UInt32(name.count), &argmax, &size, nil, 0)
            }
            // Cap what we allocate: argv comes first in the buffer and is short.
            let capacity = result == 0 && argmax > 0 ? min(Int(argmax), 1 << 20) : 256 * 1024
            argumentBuffer = [UInt8](repeating: 0, count: capacity)
        }
        var size = argumentBuffer.count
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        let result = argumentBuffer.withUnsafeMutableBytes { buffer in
            mib.withUnsafeMutableBufferPointer { name in
                sysctl(name.baseAddress, UInt32(name.count), buffer.baseAddress, &size, nil, 0)
            }
        }
        guard result == 0, size > 0 else { return nil }
        return VMProcessArguments.parse(Array(argumentBuffer.prefix(size)))
    }

    // MARK: - sysctl(KERN_PROC_ALL)

    /// Fills `processBuffer` with every process and returns how many entries are valid.
    private mutating func listProcesses() -> Int? {
        let stride = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        let sized = mib.withUnsafeMutableBufferPointer { name in
            sysctl(name.baseAddress, UInt32(name.count), nil, &size, nil, 0)
        }
        guard sized == 0, size > 0 else { return nil }
        let capacity = size / stride + Self.processSlack
        if processBuffer.count < capacity {
            processBuffer = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        }
        var bytes = processBuffer.count * stride
        let result = processBuffer.withUnsafeMutableBytes { buffer in
            mib.withUnsafeMutableBufferPointer { name in
                sysctl(name.baseAddress, UInt32(name.count), buffer.baseAddress, &bytes, nil, 0)
            }
        }
        // ENOMEM: more processes appeared than the slack covers; the next tick resizes.
        guard result == 0 else { return nil }
        return min(bytes / stride, processBuffer.count)
    }
}
#endif
