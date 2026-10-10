import Foundation

/// The parts of a `qemu-system-*` command line that describe the VM. Syntax per QEMU's
/// `qemu-options.hx`:
///
/// - `-name [guest=]name[,process=name][,debug-threads=on|off]`
/// - `-m [size=]megs[,slots=n,maxmem=size]` (default unit MiB, optional suffix `M`/`G`; also `T`, `K`)
/// - `-smp [[cpus=]n][,maxcpus=n][,sockets=…][,cores=…][,threads=…]` (+ drawers/books/dies/clusters/modules)
/// - `-drive file=…,if=…,media=…`, `-hda|-hdb|-hdc|-hdd file`, `-blockdev driver=…,file.filename=…`
/// - `-machine [type=]name[,accel=…]` / `-M`, `-accel name[,…]`, `-uuid …`
///
/// Option values are comma separated; a literal comma is written `,,`. QEMU accepts both `-opt` and `--opt`.
public struct QEMUCommandLine: Hashable, Sendable {
    public var guestName: String?
    public var memoryBytes: UInt64?
    public var cpuCount: Int?
    /// Disk image paths (hard disks only; CD-ROMs are left out), in command-line order.
    public var diskImages: [String] = []
    public var machineType: String?
    public var accelerator: String?
    public var uuid: String?

    /// - Parameter arguments: argv without the executable.
    public init(arguments: [String]) {
        var index = 0
        var smp: SMP?
        while index < arguments.count {
            let token = arguments[index]
            guard let option = Self.optionName(token) else { index += 1; continue }
            let value: String? = index + 1 < arguments.count ? arguments[index + 1] : nil
            guard let value else { break }
            var consumed = true
            switch option {
            case "name":
                let items = Self.items(value)
                guestName = Self.firstValue(items, key: "guest").flatMap { $0.isEmpty ? nil : $0 }
            case "m":
                memoryBytes = Self.parseMemory(value)
            case "smp":
                smp = Self.parseSMP(value)
            case "drive":
                let items = Self.items(value)
                // CD-ROMs and firmware flash (`if=pflash`) are not the VM's disk.
                let isCDROM = items.contains { $0.key == "media" && $0.value == "cdrom" }
                let isFirmware = items.contains { $0.key == "if" && ($0.value == "pflash" || $0.value == "floppy") }
                if !isCDROM, !isFirmware, let file = items.first(where: { $0.key == "file" })?.value, !file.isEmpty { diskImages.append(file) }
            case "hda", "hdb", "hdc", "hdd":
                if !value.isEmpty { diskImages.append(value) }
            case "blockdev":
                let items = Self.items(value)
                if let file = items.first(where: { $0.key == "file.filename" || $0.key == "filename" })?.value, !file.isEmpty { diskImages.append(file) }
            case "machine", "M":
                let items = Self.items(value)
                machineType = Self.firstValue(items, key: "type").flatMap { $0.isEmpty ? nil : $0 }
                if let accel = items.first(where: { $0.key == "accel" })?.value, accelerator == nil { accelerator = accel }
            case "accel":
                let items = Self.items(value)
                accelerator = Self.firstValue(items, key: "accel").flatMap { $0.isEmpty ? nil : $0 }
            case "uuid":
                uuid = value.isEmpty ? nil : value
            default:
                // Unknown option: skip only the option token. Its value (if any) does not start
                // with "-" in practice and is skipped by the guard above on the next iteration.
                consumed = false
            }
            index += consumed ? 2 : 1
        }
        cpuCount = smp?.cpuCount
    }

    /// `qemu-system-aarch64` → "arm64", `qemu-system-x86_64` → "x86_64"; other suffixes unchanged.
    public static func architecture(forExecutableName name: String) -> String? {
        guard name.hasPrefix("qemu-system-") else { return nil }
        let suffix = String(name.dropFirst("qemu-system-".count))
        guard !suffix.isEmpty else { return nil }
        return suffix == "aarch64" ? "arm64" : suffix
    }

    // MARK: - Option syntax

    /// `-name`/`--name` → "name"; `nil` for values and anything not starting with a dash.
    static func optionName(_ token: String) -> String? {
        guard token.hasPrefix("-"), token.count > 1 else { return nil }
        let stripped = token.hasPrefix("--") ? String(token.dropFirst(2)) : String(token.dropFirst())
        return stripped.isEmpty ? nil : stripped
    }

    struct Item: Hashable {
        /// `nil` for a bare value (the option's implicit first key).
        var key: String?
        var value: String
    }

    /// Splits `a=1,b,c=x,,y` into `[(a,1), (nil,b), (c,"x,y")]` (`,,` is an escaped comma).
    static func items(_ text: String) -> [Item] {
        var parts: [String] = []
        var current = ""
        let characters = Array(text)
        var position = 0
        while position < characters.count {
            let character = characters[position]
            if character == "," {
                if position + 1 < characters.count, characters[position + 1] == "," {
                    current.append(",")
                    position += 2
                    continue
                }
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
            position += 1
        }
        parts.append(current)
        return parts.filter { !$0.isEmpty }.map { part in
            if let equals = part.firstIndex(of: "=") {
                return Item(key: String(part[..<equals]), value: String(part[part.index(after: equals)...]))
            }
            return Item(key: nil, value: part)
        }
    }

    /// The value of `key=…`, else of the first bare item (the option's leading positional value).
    static func firstValue(_ items: [Item], key: String) -> String? {
        if let keyed = items.first(where: { $0.key == key }) { return keyed.value }
        return items.first(where: { $0.key == nil })?.value
    }

    // MARK: - Values

    /// `-m`: `4G`, `4096`, `size=4096M`, `1G,slots=3,maxmem=4G`. Plain numbers are MiB.
    static func parseMemory(_ text: String) -> UInt64? {
        let items = Self.items(text)
        guard let size = firstValue(items, key: "size") else { return nil }
        return parseSize(size, defaultUnit: 1_048_576)
    }

    /// QEMU size: decimal number (fraction allowed) with an optional suffix B, K, M, G or T
    /// (case-insensitive, optionally followed by `iB`/`B`); no suffix means `defaultUnit`.
    static func parseSize(_ text: String, defaultUnit: UInt64) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        var number = ""
        var rest = Substring(trimmed)
        while let first = rest.first, first.isNumber && first.isASCII || first == "." {
            number.append(first)
            rest = rest.dropFirst()
        }
        guard !number.isEmpty, let value = Double(number), value.isFinite else { return nil }
        let suffix = rest.lowercased()
        let multiplier: Double
        switch suffix {
        case "": multiplier = Double(defaultUnit)
        case "b": multiplier = 1
        case "k", "kb", "kib": multiplier = 1024
        case "m", "mb", "mib": multiplier = 1_048_576
        case "g", "gb", "gib": multiplier = 1_073_741_824
        case "t", "tb", "tib": multiplier = 1_099_511_627_776
        default: return nil
        }
        let bytes = value * multiplier
        guard bytes > 0, bytes < 1.8e19 else { return nil }
        return UInt64(bytes)
    }

    private struct SMP {
        var cpuCount: Int?
    }

    /// `-smp`: `4`, `cpus=4`, `4,sockets=1,cores=4`, `sockets=2,cores=2` (CPU count = maxcpus, or
    /// the product of the topology parameters, as QEMU computes omitted values).
    private static func parseSMP(_ text: String) -> SMP? {
        let items = Self.items(text)
        func number(_ key: String) -> Int? {
            items.first(where: { $0.key == key }).flatMap { Int($0.value) }.flatMap { $0 > 0 ? $0 : nil }
        }
        if let cpus = number("cpus") ?? items.first(where: { $0.key == nil }).flatMap({ Int($0.value) }).flatMap({ $0 > 0 ? $0 : nil }) {
            return SMP(cpuCount: cpus)
        }
        if let maximum = number("maxcpus") { return SMP(cpuCount: maximum) }
        let topology = ["drawers", "books", "sockets", "dies", "clusters", "modules", "cores", "threads"].compactMap(number)
        guard !topology.isEmpty else { return nil }
        var product = 1
        for factor in topology {
            let (result, overflow) = product.multipliedReportingOverflow(by: factor)
            if overflow { return nil }
            product = result
        }
        return SMP(cpuCount: product)
    }
}

/// Detection of VMs that run as bare `qemu-system-*` processes, without a manager PulseDeck knows.
public enum QEMUVMParsing {
    /// Substrings (lowercased) in a QEMU process' path or arguments that show a VM manager started
    /// it. Matching is deliberately broad: wrongly leaving a VM out is better than listing the same
    /// VM twice, once under its manager.
    static let managerMarkers: [(marker: String, manager: String)] = [
        (".lima/", "Lima"), ("/.lima", "Lima"), (".colima", "Colima"), ("/colima/", "Colima"),
        ("rancher-desktop", "Rancher Desktop"), (".finch", "Finch"), ("/finch/", "Finch"),
        ("com.utmapp", "UTM"), ("utm.app", "UTM"),
        ("multipass", "Multipass"), ("/vault/instances/", "Multipass"),
        ("/containers/podman/machine", "Podman"), ("podman-machine", "Podman"),
        (".minikube", "minikube"),
        (".vagrant", "Vagrant"),
        (".tart", "Tart"), ("veertu", "Anka"),
        ("orbstack", "OrbStack"), ("docker.app", "Docker Desktop"), ("com.docker", "Docker Desktop"),
    ]

    /// The manager that started this QEMU process, or `nil` for a bare one.
    public static func managerName(of process: VMHostProcess) -> String? {
        let haystack = ([process.executablePath ?? ""] + process.arguments).joined(separator: "\n").lowercased()
        for entry in managerMarkers where haystack.contains(entry.marker) { return entry.manager }
        // Lima names its guests "lima-<instance>" (Colima: "colima…").
        if let guest = QEMUCommandLine(arguments: process.arguments).guestName?.lowercased(), guest.hasPrefix("lima-") || guest.hasPrefix("colima") {
            return guest.hasPrefix("colima") ? "Colima" : "Lima"
        }
        return nil
    }

    public static func isQEMUSystemProcess(_ process: VMHostProcess) -> Bool {
        process.name.hasPrefix("qemu-system-")
    }

    /// One record per QEMU process that no known manager claims. A process whose arguments could not
    /// be read is skipped: nothing identifies it as unmanaged.
    public static func records(processes: [VMHostProcess]) -> [VMRecord] {
        let unmanaged = processes
            .filter { isQEMUSystemProcess($0) && !$0.arguments.isEmpty && managerName(of: $0) == nil }
            .sorted { $0.pid < $1.pid }

        let parsed = unmanaged.map { ($0, QEMUCommandLine(arguments: $0.arguments)) }
        var idCounts: [String: Int] = [:]
        for (process, line) in parsed { idCounts[baseID(process, line), default: 0] += 1 }

        return parsed.map { process, line in
            let base = baseID(process, line)
            // Two processes with the same -name (or none) must not share an id.
            let nativeID = (idCounts[base] ?? 0) > 1 ? "\(base)-\(process.pid)" : base

            var details: [VMDetail] = []
            if let machine = line.machineType { details.append(VMDetail(label: "Machine type", value: machine)) }
            if let accelerator = line.accelerator { details.append(VMDetail(label: "Accelerator", value: accelerator)) }
            for image in line.diskImages { details.append(VMDetail(label: "Disk image", value: image)) }
            if let uuid = line.uuid { details.append(VMDetail(label: "UUID", value: uuid)) }
            if let path = process.executablePath { details.append(VMDetail(label: "Executable", value: path)) }
            details.append(VMDetail(label: "Management", value: "A QEMU process without a VM manager PulseDeck knows. It can be monitored but not controlled; stop it where you started it."))

            return VMRecord(
                nativeID: nativeID,
                name: displayName(process, line),
                state: .running,
                guestOS: nil,
                architecture: QEMUCommandLine.architecture(forExecutableName: process.name),
                resources: VMResources(cpus: line.cpuCount, memoryBytes: line.memoryBytes, diskBytes: nil),
                ipAddress: nil,
                startedAt: nil,
                hostProcessIDs: [process.pid],
                details: details,
                capabilities: .readOnly
            )
        }
    }

    private static func baseID(_ process: VMHostProcess, _ line: QEMUCommandLine) -> String {
        if let name = line.guestName { return "name-\(name)" }
        return "pid-\(process.pid)"
    }

    private static func displayName(_ process: VMHostProcess, _ line: QEMUCommandLine) -> String {
        if let name = line.guestName { return name }
        if let image = line.diskImages.first {
            let file = image.split(separator: "/").last.map(String.init) ?? image
            // Drop the extension (".qcow2", ".img") but keep dotted names such as "ubuntu-24.04".
            let stem = file.lastIndex(of: ".").map { String(file[..<$0]) } ?? file
            if !stem.isEmpty { return stem }
        }
        return "QEMU (pid \(process.pid))"
    }
}
