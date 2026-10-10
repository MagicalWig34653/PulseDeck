import Foundation

/// Which host processes can belong to a VM. `VMHostProcessTable` (telemetry) reads the full
/// argument vector (`sysctl KERN_PROCARGS2`) only for processes this list accepts, so PulseDeck
/// does not read arguments of hundreds of unrelated processes every tick.
///
/// The names are the executable file names of the hypervisors and helpers of every provider in
/// `VMProviderID`; matching is case-insensitive.
public enum VMProcessAllowList {
    /// Exact executable names (lower-case).
    static let exactNames: Set<String> = [
        // Lima family and Colima: `limactl hostagent` supervises the VM; with the `vz` driver the
        // VM runs inside that process.
        "limactl", "colima",
        // Docker Desktop, OrbStack, Rancher Desktop (their VM helpers; Docker's are `com.docker.*`).
        "orbstack", "orbstack helper", "rancher desktop", "docker desktop",
        // Tart, UTM, Anka (prefix below), Multipass, Podman machine, minikube, Vagrant.
        "tart", "utm", "multipassd", "multipass", "vfkit", "krunkit", "gvproxy", "podman",
        "minikube", "vagrant", "hyperkit",
    ]

    /// Name prefixes (lower-case).
    static let prefixes: [String] = [
        "qemu",  // qemu-system-aarch64, QEMULauncher, QEMUHelper (UTM)
        "com.apple.virtualization.",  // com.apple.Virtualization.VirtualMachine (XPC service per VM)
        "com.docker.",  // com.docker.virtualization, com.docker.backend, com.docker.hyperkit …
        "vbox", "virtualbox",  // VBoxHeadless, VirtualBoxVM
        "prl_",  // prl_vm_app (Parallels Desktop)
        "vmware",  // vmware-vmx (VMware Fusion)
        "anka",  // Anka VMs
    ]

    /// `p_comm` holds at most this many characters (`MAXCOMLEN`); longer names are cut.
    static let kernelNameLimit = 16

    /// Whether the full executable file name (from `proc_pidpath`) is a VM runtime.
    public static func matches(name: String) -> Bool {
        let lowered = name.lowercased()
        return exactNames.contains(lowered) || prefixes.contains { lowered.hasPrefix($0) }
    }

    /// Cheap pre-filter on the kernel's short name (`kinfo_proc.p_comm`, cut at 16 characters), so
    /// the path is looked up only for plausible candidates. A cut name matches when it is the
    /// beginning of an accepted longer name.
    public static func mayMatch(kernelName: String) -> Bool {
        let lowered = kernelName.lowercased()
        if exactNames.contains(lowered) || prefixes.contains(where: { lowered.hasPrefix($0) }) { return true }
        guard lowered.count >= kernelNameLimit - 1 else { return false }
        return exactNames.contains { $0.hasPrefix(lowered) } || prefixes.contains { $0.hasPrefix(lowered) }
    }
}

/// The result of parsing the buffer `sysctl(CTL_KERN, KERN_PROCARGS2, pid)` returns.
public struct VMParsedProcessArguments: Hashable, Sendable {
    public var executablePath: String
    /// argv without argv[0] (the program name as invoked).
    public var arguments: [String]
}

public enum VMProcessArguments {
    /// Layout (see `sysctl_procargsx` in XNU): `int32 argc`, the executable path as a C string,
    /// padding NUL bytes, `argc` C strings (argv), then the environment (ignored — it can contain
    /// secrets and PulseDeck never reads it).
    ///
    /// Returns `nil` for buffers that are too short or malformed. A buffer cut off inside argv
    /// yields the arguments that were complete.
    public static func parse(_ buffer: [UInt8]) -> VMParsedProcessArguments? {
        let headerSize = MemoryLayout<Int32>.size
        guard buffer.count > headerSize else { return nil }
        var argumentCount = 0
        for index in 0..<headerSize {
            argumentCount |= Int(buffer[index]) << (8 * index)  // little-endian (Apple silicon and Intel)
        }
        guard argumentCount >= 0, argumentCount < 4096 else { return nil }

        var position = headerSize
        // Executable path.
        let pathStart = position
        while position < buffer.count, buffer[position] != 0 { position += 1 }
        let path = String(decoding: buffer[pathStart..<position], as: UTF8.self)
        // Padding NULs before argv[0].
        while position < buffer.count, buffer[position] == 0 { position += 1 }

        var strings: [String] = []
        while strings.count < argumentCount, position < buffer.count {
            let start = position
            while position < buffer.count, buffer[position] != 0 { position += 1 }
            // A string that runs to the end of the buffer without its NUL was cut off: drop it.
            if position >= buffer.count { break }
            strings.append(String(decoding: buffer[start..<position], as: UTF8.self))
            position += 1
        }
        guard !path.isEmpty || !strings.isEmpty else { return nil }
        return VMParsedProcessArguments(executablePath: path, arguments: Array(strings.dropFirst()))
    }
}
