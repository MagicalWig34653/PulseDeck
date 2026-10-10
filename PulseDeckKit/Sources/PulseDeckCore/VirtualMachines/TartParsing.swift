import Foundation

/// Tart (cirruslabs/tart) — everything that can be decided without touching the file system or
/// running a tool. Layout verified against Tart's sources (`VMDirectory`, `VMConfig`, `Set`, `Stop`):
/// `~/.tart/vms/<name>/{config.json, disk.img, nvram.bin, state.vzvmsave}`.
public enum TartParsing {
    public static let providerID = VMProviderID.tart.rawValue

    /// What a VM's `config.json` says (only the keys PulseDeck needs).
    public struct Config: Hashable, Sendable {
        /// `darwin` or `linux`.
        public var os: String
        /// `arm64` or `amd64`.
        public var arch: String
        public var cpuCount: Int?
        /// Tart stores `memorySize` in bytes.
        public var memoryBytes: UInt64?
        /// `raw` (default) or `asif`.
        public var diskFormat: String
        public var display: String?
    }

    // MARK: config.json

    private struct RawConfig: Decodable {
        struct Display: Decodable {
            var width: Int?
            var height: Int?
            var unit: String?
        }

        var os: String?
        var arch: String?
        var cpuCount: Int?
        var memorySize: UInt64?
        var diskFormat: String?
        var display: Display?
    }

    /// Decodes `config.json`. `os` defaults to `darwin` and `arch` to `arm64` when absent, exactly
    /// like Tart's own decoder does for VMs created by old versions.
    public static func parseConfig(_ data: Data) -> Config? {
        guard let raw = try? JSONDecoder().decode(RawConfig.self, from: data) else { return nil }
        var display: String?
        if let width = raw.display?.width, let height = raw.display?.height {
            display = "\(width)x\(height)" + (raw.display?.unit ?? "")
        }
        return Config(
            os: raw.os ?? "darwin",
            arch: raw.arch ?? "arm64",
            cpuCount: raw.cpuCount,
            memoryBytes: raw.memorySize,
            diskFormat: raw.diskFormat ?? "raw",
            display: display
        )
    }

    public static func guestOS(_ os: String) -> String? {
        switch os.lowercased() {
        case "darwin": "macOS"
        case "linux": "Linux"
        default: nil
        }
    }

    public static func architecture(_ arch: String) -> String? {
        switch arch.lowercased() {
        case "arm64": "arm64"
        case "amd64": "x86_64"
        default: nil
        }
    }

    // MARK: Host processes

    /// Tart options that take a separate value argument (`Run.swift`); needed to find the
    /// positional VM name in `tart run [options] <name>` without mistaking an option value for it.
    private static let optionsWithValue: Set<String> = [
        "--serial-path", "--disk", "--rosetta", "--dir", "--net-bridged", "--net-softnet-allow",
        "--net-softnet-block", "--net-softnet-control-fd", "--net-softnet-expose", "--root-disk-opts",
        "--provision-opts",
    ]

    /// The VM name of a `tart run` command line, or `nil` if `arguments` is not one.
    public static func runningVMName(arguments: [String]) -> String? {
        guard arguments.first == "run" else { return nil }
        var index = 1
        while index < arguments.count {
            let token = arguments[index]
            if token.hasPrefix("-") {
                index += optionsWithValue.contains(token) ? 2 : 1
            } else {
                return token
            }
        }
        return nil
    }

    /// `tart run <name>` processes of exactly this VM. Nothing else is attributed.
    public static func hostProcesses(forVM name: String, in processes: [VMHostProcess]) -> [VMHostProcess] {
        processes.filter { process in
            let executable = process.executablePath.map { ($0 as NSString).lastPathComponent } ?? process.name
            return (process.name == "tart" || executable == "tart") && runningVMName(arguments: process.arguments) == name
        }
    }

    // MARK: Record

    public static let capabilities = VMCapabilities(
        canStart: true, canStop: true, canRestart: true,
        canEditCPUs: true, canEditMemory: true, canEditDisk: true,
        editRequiresStopped: true, diskCanOnlyGrow: true
    )

    /// - Parameters:
    ///   - diskBytes: logical size of `disk.img` (`nil` for stacked / ASIF disks, see below).
    ///   - hasSavedState: `state.vzvmsave` exists (a suspended VM).
    ///   - directory: the VM's directory, shown as a detail.
    public static func makeRecord(name: String, config: Config, diskBytes: UInt64?, hasSavedState: Bool, directory: String, processes: [VMHostProcess]) -> VMRecord {
        let host = hostProcesses(forVM: name, in: processes)
        let state: VMState = !host.isEmpty ? .running : (hasSavedState ? .suspended : .stopped)

        // The growth-only resize in Tart works on the raw `disk.img` length. For ASIF images and
        // stacked VMs (no `disk.img`) the file length is not the guest-visible size, so the size is
        // not reported and the disk is not editable.
        let diskKnown = diskBytes != nil && config.diskFormat.lowercased() == "raw"
        var capabilities = Self.capabilities
        capabilities.canEditDisk = diskKnown

        var details = [VMDetail(label: "Location", value: directory)]
        if let display = config.display { details.append(VMDetail(label: "Display", value: display)) }
        if config.diskFormat.lowercased() != "raw" { details.append(VMDetail(label: "Disk format", value: config.diskFormat.uppercased())) }
        if !host.isEmpty {
            details.append(VMDetail(label: "Process", value: "tart run (PID \(host.map { String($0.pid) }.joined(separator: ", ")))"))
        }

        return VMRecord(
            nativeID: name,
            name: name,
            state: state,
            guestOS: guestOS(config.os),
            architecture: architecture(config.arch),
            resources: VMResources(cpus: config.cpuCount, memoryBytes: config.memoryBytes, diskBytes: diskKnown ? diskBytes : nil),
            hostProcessIDs: host.map(\.pid),
            details: details,
            capabilities: capabilities
        )
    }

    // MARK: Commands

    /// `tart run --no-graphics <name>`: headless, so it needs no window; detached by the adapter.
    public static func startArguments(name: String) -> [String] { ["run", "--no-graphics", name] }

    /// `tart stop <name>` (SIGINT, then SIGKILL after Tart's own 30 s timeout).
    public static func stopArguments(name: String) -> [String] { ["stop", name] }

    public static let bytesPerMiB: UInt64 = 1_048_576
    /// `tart set --disk-size` counts decimal gigabytes (`UInt64(sizeGB) * 1000 * 1000 * 1000` in Tart).
    public static let bytesPerDiskGB: UInt64 = 1_000_000_000
    /// `--disk-size` is a `UInt16`.
    public static let maximumDiskGB: UInt64 = UInt64(UInt16.max)

    /// Arguments of `tart set` for the values that differ from `current`; `nil` if nothing changes.
    /// `--memory` is in MiB (Tart multiplies by 1024 × 1024); `--disk-size` in whole GB, rounded up,
    /// and omitted unless it enlarges the disk (Tart refuses shrinking).
    public static func setArguments(name: String, new: VMResources, current: VMResources) -> [String]? {
        var arguments = ["set", name]
        if let cpus = new.cpus, cpus > 0, cpus != current.cpus {
            arguments += ["--cpu", String(cpus)]
        }
        if let memory = new.memoryBytes, memory >= bytesPerMiB, memory != current.memoryBytes {
            arguments += ["--memory", String(memory / bytesPerMiB)]
        }
        if let disk = new.diskBytes, disk > (current.diskBytes ?? 0) {
            let gigabytes = (disk + bytesPerDiskGB - 1) / bytesPerDiskGB
            arguments += ["--disk-size", String(min(gigabytes, maximumDiskGB))]
        }
        return arguments.count > 2 ? arguments : nil
    }
}
