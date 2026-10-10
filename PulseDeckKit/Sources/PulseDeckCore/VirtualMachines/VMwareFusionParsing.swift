import Foundation

/// VMware Fusion — `.vmx` files (`key = "value"` lines), the Fusion inventory
/// (`~/Library/Application Support/VMware Fusion/vmInventory`, lines `vmlistN.config = "<vmx>"`),
/// `vmware-vmx` process matching, `vmrun` command lines and the pure rewrite of the `.vmx` that
/// changes CPU count and memory.
public enum VMwareFusionParsing {
    public static let providerID = VMProviderID.vmwareFusion.rawValue
    public static let bytesPerMiB: UInt64 = 1_048_576

    // MARK: key = "value" files

    /// Parses `key = "value"` lines. Keys are lower-cased (VMware treats keys case-insensitively);
    /// comments (`#`) and lines without `=` are ignored. Values are unquoted and `|XX` escapes
    /// (`|22` is `"`) decoded.
    public static func parseKeyValues(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let (key, value) = split(line: String(line)) else { continue }
            result[key.lowercased()] = value
        }
        return result
    }

    private static func split(line: String) -> (key: String, value: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { return nil }
        let key = trimmed[..<equals].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return nil }
        var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            value = String(value.dropFirst().dropLast())
        }
        return (key, decodeEscapes(value))
    }

    /// `|HH` (two hex digits) stands for the character with that code, e.g. `|22` for `"`.
    public static func decodeEscapes(_ value: String) -> String {
        guard value.contains("|") else { return value }
        var bytes: [UInt8] = []
        let source = Array(value.utf8)
        var index = 0
        while index < source.count {
            if source[index] == UInt8(ascii: "|"), index + 2 < source.count,
               let high = hexValue(source[index + 1]), let low = hexValue(source[index + 2]) {
                bytes.append(UInt8(high * 16 + low))
                index += 3
            } else {
                bytes.append(source[index])
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> Int? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): Int(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): Int(byte - UInt8(ascii: "a")) + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): Int(byte - UInt8(ascii: "A")) + 10
        default: nil
        }
    }

    // MARK: Inventory

    /// `.vmx` paths listed in Fusion's `vmInventory` (`vmlist1.config = "/Users/…/Foo.vmx"`).
    public static func inventoryPaths(_ text: String) -> [String] {
        var seen = Set<String>()
        var paths: [String] = []
        for (key, value) in text.split(whereSeparator: \.isNewline).compactMap({ split(line: String($0)) }) {
            let lowered = key.lowercased()
            guard lowered.hasPrefix("vmlist"), lowered.hasSuffix(".config"), value.lowercased().hasSuffix(".vmx") else { continue }
            if seen.insert(value).inserted { paths.append(value) }
        }
        return paths
    }

    // MARK: .vmx

    public struct Config: Hashable, Sendable {
        public var displayName: String
        public var guestOSID: String?
        public var cpus: Int?
        public var memoryMiB: UInt64?
        /// Virtual disk file names as written in the `.vmx` (relative to the `.vmx` directory
        /// unless absolute).
        public var diskFiles: [String]
    }

    /// - Parameter fallbackName: used when the `.vmx` has no `displayName`.
    public static func parseConfig(_ text: String, fallbackName: String) -> Config {
        let values = parseKeyValues(text)
        let name = values["displayname"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
        return Config(
            displayName: name,
            guestOSID: values["guestos"],
            cpus: values["numvcpus"].flatMap { Int($0) }.flatMap { $0 > 0 ? $0 : nil },
            memoryMiB: values["memsize"].flatMap { UInt64($0) }.flatMap { $0 > 0 ? $0 : nil },
            diskFiles: diskFiles(values)
        )
    }

    /// `scsi0:0.fileName`, `sata0:0.fileName`, `nvme0:0.fileName`, `ide0:0.fileName` entries that
    /// are present and point at a `.vmdk`.
    static func diskFiles(_ values: [String: String]) -> [String] {
        let buses = ["scsi", "sata", "nvme", "ide"]
        return values
            .filter { key, value in
                guard key.hasSuffix(".filename"), value.lowercased().hasSuffix(".vmdk") else { return false }
                guard buses.contains(where: { key.hasPrefix($0) }) else { return false }
                let device = key.dropLast(".filename".count)
                return values[device + ".present"]?.uppercased() != "FALSE"
            }
            .sorted { $0.key < $1.key }
            .map(\.value)
    }

    public static func guestInfo(_ identifier: String?) -> (os: String?, architecture: String?) {
        guard var id = identifier?.lowercased(), !id.isEmpty else { return (nil, nil) }
        let isARM = id.hasPrefix("arm-")
        if isARM { id.removeFirst(4) }
        let os: String?
        if id.hasPrefix("darwin") || id.contains("macos") {
            os = "macOS"
        } else if id.hasPrefix("win") {
            os = "Windows"
        } else {
            let linux = ["linux", "ubuntu", "debian", "fedora", "centos", "rhel", "redhat", "sles", "suse", "oracle", "alma", "rocky", "kali", "alpine"]
            os = linux.contains(where: { id.contains($0) }) ? "Linux" : nil
        }
        let architecture = isARM ? "arm64" : (id.hasSuffix("-64") ? "x86_64" : nil)
        return (os, architecture)
    }

    // MARK: Disk sizes

    /// Virtual size of a disk from the first bytes of a `.vmdk` (sparse header or text descriptor).
    public static func diskSize(header: Data, descriptorText: String?) -> UInt64? {
        if let size = HypervisorDiskHeader.virtualSize(header: header) { return size }
        return descriptorText.flatMap(HypervisorDiskHeader.vmdkDescriptorSize)
    }

    // MARK: Host processes

    /// `vmware-vmx` is started with the `.vmx` path as its last argument
    /// (`… "-D" "4" "/Users/me/VMs/Foo.vmx"` in `vmware.log`). Only exact path matches count.
    public static func hostProcesses(forVMX path: String, in processes: [VMHostProcess]) -> [VMHostProcess] {
        let wanted = path.lowercased() // APFS volumes are case-insensitive by default
        return processes.filter { process in
            guard process.name.hasPrefix("vmware-vmx") else { return false }
            return process.arguments.contains { $0.lowercased() == wanted }
        }
    }

    // MARK: Record

    public static let capabilities = VMCapabilities(
        canStart: true, canStop: true, canRestart: true,
        canEditCPUs: true, canEditMemory: true, canEditDisk: false,
        editRequiresStopped: true, diskCanOnlyGrow: true
    )

    public static func makeRecord(vmxPath: String, config: Config, diskBytes: UInt64?, hasSuspendState: Bool, processes: [VMHostProcess]) -> VMRecord {
        let host = hostProcesses(forVMX: vmxPath, in: processes)
        let state: VMState = !host.isEmpty ? .running : (hasSuspendState ? .suspended : .stopped)
        let guest = guestInfo(config.guestOSID)
        var details = [VMDetail(label: "Location", value: vmxPath)]
        if let id = config.guestOSID { details.append(VMDetail(label: "Guest OS ID", value: id)) }
        return VMRecord(
            nativeID: vmxPath,
            name: config.displayName,
            state: state,
            guestOS: guest.os,
            architecture: guest.architecture,
            resources: VMResources(cpus: config.cpus, memoryBytes: config.memoryMiB.map { $0 * bytesPerMiB }, diskBytes: diskBytes),
            hostProcessIDs: host.map(\.pid),
            details: details,
            capabilities: capabilities
        )
    }

    // MARK: vmrun

    /// `vmrun -T fusion start <vmx> nogui` (no GUI window; `vmrun start` returns once the VM is up).
    public static func startArguments(vmx: String) -> [String] { ["-T", "fusion", "start", vmx, "nogui"] }

    /// `soft` asks the guest (VMware Tools) to shut down; `hard` would power off.
    public static func stopArguments(vmx: String) -> [String] { ["-T", "fusion", "stop", vmx, "soft"] }

    public static func restartArguments(vmx: String) -> [String] { ["-T", "fusion", "reset", vmx, "soft"] }

    // MARK: Rewriting the .vmx

    /// VMware requires memory in multiples of 4 MB.
    public static func memoryMiB(forBytes bytes: UInt64) -> UInt64 {
        let mebibytes = bytes / bytesPerMiB
        return max(4, mebibytes - mebibytes % 4)
    }

    /// Returns `text` with `numvcpus` and `memsize` replaced (or appended when missing), keeping
    /// every other line, comment and the line endings untouched. When the file sets
    /// `cpuid.coresPerSocket` and the new CPU count is not a multiple of it (VMware refuses to
    /// power on then), the setting is reset to 1.
    public static func applying(cpus: Int?, memoryMiB: UInt64?, to text: String) -> String {
        var edits: [String: String] = [:]
        if let cpus, cpus > 0 { edits["numvcpus"] = String(cpus) }
        if let memoryMiB, memoryMiB > 0 { edits["memsize"] = String(memoryMiB) }
        if let cpus, cpus > 0, let perSocket = parseKeyValues(text)["cpuid.corespersocket"].flatMap({ Int($0) }), perSocket > 0, cpus % perSocket != 0 {
            edits["cpuid.corespersocket"] = "1"
        }
        guard !edits.isEmpty else { return text }

        var pending = edits
        // Split on the LF byte: Swift treats "\r\n" as one Character, so splitting by string
        // would not separate CRLF-terminated lines.
        var lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
        for index in lines.indices {
            let line = lines[index]
            let carriageReturn = line.utf8.last == UInt8(ascii: "\r") ? "\r" : ""
            let content = carriageReturn.isEmpty ? line : String(decoding: line.utf8.dropLast(), as: UTF8.self)
            guard let (key, _) = split(line: content), let replacement = pending[key.lowercased()] else { continue }
            lines[index] = "\(key) = \"\(replacement)\"" + carriageReturn
            pending[key.lowercased()] = nil
        }
        // Keys that were not in the file are appended (before a final empty element, if any).
        let missing = pending.keys.sorted()
        if !missing.isEmpty {
            let appended = missing.map { key -> String in
                let canonical = key == "cpuid.corespersocket" ? "cpuid.coresPerSocket" : key
                return "\(canonical) = \"\(pending[key] ?? "")\""
            }
            if lines.last == "" { lines.removeLast() }
            lines += appended
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }
}
