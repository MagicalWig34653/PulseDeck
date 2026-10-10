import Foundation
import Testing
@testable import PulseDeckCore

// MARK: - VMUsageTracker

@Suite("VMUsageTracker")
struct VMUsageTrackerTests {
    private func instant(_ seconds: Double) -> MonotonicInstant {
        MonotonicInstant(nanoseconds: UInt64(seconds * 1e9))
    }

    private func sample(pid: Int32, start: UInt64 = 1, cpuSeconds: Double, footprint: UInt64 = 1_000, read: UInt64 = 0, written: UInt64 = 0) -> VMProcessSample {
        VMProcessSample(
            identity: ProcessIdentity(pid: pid, startTimeMicroseconds: start),
            usage: .success(.init(cpuTimeNanoseconds: UInt64(cpuSeconds * 1e9), physicalFootprintBytes: footprint, diskBytesRead: read, diskBytesWritten: written))
        )
    }

    @Test("first sample awaits a baseline, never zero")
    func firstSample() {
        var tracker = VMUsageTracker()
        let usage = tracker.update(machines: ["a": [sample(pid: 10, cpuSeconds: 5)]], at: instant(0))["a"]
        #expect(usage?.cpu == .unavailable(.awaitingBaseline))
        #expect(usage?.diskReadBytesPerSecond == .unavailable(.awaitingBaseline))
        #expect(usage?.memoryBytes == .available(1_000))
        #expect(usage?.processCount == 1)
    }

    @Test("second sample yields CPU fraction and disk rates")
    func rates() {
        var tracker = VMUsageTracker()
        _ = tracker.update(machines: ["a": [sample(pid: 10, cpuSeconds: 5, read: 0, written: 0)]], at: instant(0))
        let usage = tracker.update(machines: ["a": [sample(pid: 10, cpuSeconds: 6.5, footprint: 2_000, read: 4_000, written: 1_000)]], at: instant(2))["a"]
        // 1.5 CPU seconds in 2 s of wall time.
        #expect(usage?.cpu == .available(0.75))
        #expect(usage?.diskReadBytesPerSecond == .available(2_000))
        #expect(usage?.diskWriteBytesPerSecond == .available(500))
        #expect(usage?.memoryBytes == .available(2_000))
    }

    @Test("several processes of one VM are summed")
    func sums() {
        var tracker = VMUsageTracker()
        let first = ["a": [sample(pid: 10, cpuSeconds: 0, footprint: 100), sample(pid: 11, cpuSeconds: 0, footprint: 300)]]
        _ = tracker.update(machines: first, at: instant(0))
        let second = ["a": [sample(pid: 10, cpuSeconds: 1, footprint: 100), sample(pid: 11, cpuSeconds: 0.5, footprint: 300)]]
        let usage = tracker.update(machines: second, at: instant(1))["a"]
        #expect(usage?.cpu == .available(1.5))
        #expect(usage?.memoryBytes == .available(400))
        #expect(usage?.processCount == 2)
    }

    @Test("a counter going backwards is an invalid delta")
    func counterReset() {
        var tracker = VMUsageTracker()
        _ = tracker.update(machines: ["a": [sample(pid: 10, cpuSeconds: 10)]], at: instant(0))
        let usage = tracker.update(machines: ["a": [sample(pid: 10, cpuSeconds: 2)]], at: instant(1))["a"]
        #expect(usage?.cpu == .unavailable(.invalidDelta))
    }

    @Test("a reused PID (different start time) starts a new baseline")
    func pidReuse() {
        var tracker = VMUsageTracker()
        _ = tracker.update(machines: ["a": [sample(pid: 10, start: 1, cpuSeconds: 10)]], at: instant(0))
        let usage = tracker.update(machines: ["a": [sample(pid: 10, start: 2, cpuSeconds: 1)]], at: instant(1))["a"]
        #expect(usage?.cpu == .unavailable(.awaitingBaseline))
    }

    @Test("a gap longer than the maximum (sleep) is an invalid delta")
    func sleepGap() {
        var tracker = VMUsageTracker(maximumGap: .seconds(15))
        _ = tracker.update(machines: ["a": [sample(pid: 10, cpuSeconds: 0)]], at: instant(0))
        let usage = tracker.update(machines: ["a": [sample(pid: 10, cpuSeconds: 1)]], at: instant(3_600))["a"]
        #expect(usage?.cpu == .unavailable(.invalidDelta))
    }

    @Test("a new helper process does not hide the VM's other processes")
    func newProcessJoins() {
        var tracker = VMUsageTracker()
        _ = tracker.update(machines: ["a": [sample(pid: 10, cpuSeconds: 0)]], at: instant(0))
        let usage = tracker.update(machines: ["a": [sample(pid: 10, cpuSeconds: 1), sample(pid: 12, cpuSeconds: 50)]], at: instant(1))["a"]
        #expect(usage?.cpu == .available(1))
        #expect(usage?.processCount == 2)
    }

    @Test("vanished processes are forgotten and a stopped VM has no usage")
    func vanished() {
        var tracker = VMUsageTracker()
        _ = tracker.update(machines: ["a": [sample(pid: 10, cpuSeconds: 0)]], at: instant(0))
        #expect(tracker.trackedCount == 1)
        let usage = tracker.update(machines: ["a": []], at: instant(1))
        #expect(usage["a"] == VMUsage.none)
        #expect(tracker.trackedCount == 0)
    }

    @Test("unreadable processes report why instead of zero")
    func permissionDenied() {
        var tracker = VMUsageTracker()
        let denied = VMProcessSample(identity: ProcessIdentity(pid: 1, startTimeMicroseconds: 1), usage: .failure(UnavailableReasonError(.permissionDenied)))
        let usage = tracker.update(machines: ["a": [denied]], at: instant(0))["a"]
        #expect(usage?.cpu == .unavailable(.permissionDenied))
        #expect(usage?.memoryBytes == .unavailable(.permissionDenied))
    }

    @Test("reset and retainOnly drop baselines")
    func resetting() {
        var tracker = VMUsageTracker()
        _ = tracker.update(machines: ["a": [sample(pid: 10, cpuSeconds: 0), sample(pid: 11, cpuSeconds: 0)]], at: instant(0))
        tracker.retainOnly([ProcessIdentity(pid: 10, startTimeMicroseconds: 1)])
        #expect(tracker.trackedCount == 1)
        tracker.reset()
        #expect(tracker.trackedCount == 0)
        let usage = tracker.update(machines: ["a": [sample(pid: 10, cpuSeconds: 3)]], at: instant(1))["a"]
        #expect(usage?.cpu == .unavailable(.awaitingBaseline))
    }

    @Test("a process claimed by two VMs is evaluated once")
    func sharedProcess() {
        var tracker = VMUsageTracker()
        let shared = sample(pid: 10, cpuSeconds: 0)
        _ = tracker.update(machines: ["a": [shared], "b": [shared]], at: instant(0))
        let later = sample(pid: 10, cpuSeconds: 1)
        let usage = tracker.update(machines: ["a": [later], "b": [later]], at: instant(1))
        #expect(usage["a"]?.cpu == .available(1))
        #expect(usage["b"]?.cpu == .available(1))
    }
}

// MARK: - SimpleYAML

@Suite("SimpleYAML")
struct SimpleYAMLTests {
    /// The non-comment lines of `embedded/defaults/colima.yaml` in abiosoft/colima.
    static let colimaDefaults = """
    # Number of CPUs to be allocated to the virtual machine.
    # Default: 2
    cpu: 2

    # Size of the disk in GiB to be allocated to the virtual machine.
    disk: 100

    # Size of the memory in GiB to be allocated to the virtual machine.
    memory: 2
    arch: host
    runtime: docker
    hostname: null
    kubernetes:
      enabled: false
      version: v1.35.0+k3s1
      k3sArgs: [--disable=traefik]
      port: 0
    autoActivate: true
    network:
      address: true
      mode: shared
      subnet: ""
      dns: []
      dnsHosts:
        host.docker.internal: host.lima.internal
    docker: {}
    vmType: qemu
    mountType: sshfs
    provision: []
    mounts: []
    env: {}
    """

    /// A Lima instance configuration in the style of `templates/default.yaml` (nested images, mounts).
    static let limaInstance = """
    # This file was generated by limactl
    minimumLimaVersion: 1.1.0
    vmType: "vz"
    arch: "aarch64"
    images:
    - location: "https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-arm64.img"
      arch: "aarch64"
      digest: "sha256:abc"
    cpus: 6          # six cores
    memory: "8GiB"
    disk: '120GiB'
    mounts:
    - location: "~"
      writable: false
    mountType: "virtiofs"
    ssh:
      localPort: 60022
      loadDotSSHPubKeys: true
    os: null
    containerd:
      system: false
    """

    @Test("reads Colima's default configuration")
    func colima() {
        let yaml = SimpleYAML(parsing: Self.colimaDefaults)
        #expect(yaml.int("cpu") == 2)
        #expect(yaml.int("disk") == 100)
        #expect(yaml.double("memory") == 2)
        #expect(yaml.string("runtime") == "docker")
        #expect(yaml.string("vmType") == "qemu")
        #expect(yaml.string("hostname") == nil)
        #expect(yaml.value("hostname") == .null)
        #expect(yaml.nestedBool("kubernetes", "enabled") == false)
        #expect(yaml.nestedBool("network", "address") == true)
        #expect(yaml.nested("network", "mode") == "shared")
        #expect(yaml.string("subnet") == nil)
        #expect(yaml.value("docker") == .flow("{}"))
    }

    @Test("reads a Lima instance configuration, ignoring nested lists")
    func lima() {
        let yaml = SimpleYAML(parsing: Self.limaInstance)
        #expect(yaml.string("vmType") == "vz")
        #expect(yaml.string("arch") == "aarch64")
        #expect(yaml.int("cpus") == 6)
        #expect(yaml.string("memory") == "8GiB")
        #expect(yaml.string("disk") == "120GiB")
        #expect(yaml.string("mountType") == "virtiofs")
        #expect(yaml.string("os") == nil)
        #expect(yaml.nestedInt("ssh", "localPort") == 60022)
        #expect(yaml.value("images") == .block)
        // "arch" inside the images list must not leak out.
        #expect(yaml.string("location") == nil)
    }

    @Test("null variants, quotes, comments and CRLF")
    func scalars() {
        let yaml = SimpleYAML(parsing: "a: ~\r\nb: null\r\nc: 'it''s'\r\nd: \"x # not a comment\" # comment\r\ne: 3.0\r\nf: yes\r\n")
        #expect(yaml.value("a") == .null)
        #expect(yaml.value("b") == .null)
        #expect(yaml.string("c") == "it's")
        #expect(yaml.string("d") == "x # not a comment")
        #expect(yaml.int("e") == 3)
        #expect(yaml.bool("f") == true)
    }

    @Test("garbage does not crash and yields nothing")
    func garbage() {
        let yaml = SimpleYAML(parsing: "\u{0}\u{1}: : :\n- - -\n   \t\n::\n")
        #expect(yaml.string("anything") == nil)
        #expect(SimpleYAML(parsing: "").topLevel.isEmpty)
    }

    @Test("only the first document is read")
    func documents() {
        let yaml = SimpleYAML(parsing: "---\ncpus: 2\n---\ncpus: 8\n")
        #expect(yaml.int("cpus") == 2)
    }

    @Test("editing a scalar keeps comments, nested blocks and other keys")
    func editing() throws {
        let edited = try #require(SimpleYAML.settingTopLevelScalar("cpu", to: "8", in: Self.colimaDefaults))
        let yaml = SimpleYAML(parsing: edited)
        #expect(yaml.int("cpu") == 8)
        #expect(yaml.int("disk") == 100)
        #expect(yaml.nestedBool("network", "address") == true)
        #expect(edited.contains("# Default: 2"))
        let withComment = try #require(SimpleYAML.settingTopLevelScalar("cpus", to: "2", in: Self.limaInstance))
        #expect(withComment.contains("cpus: 2 # six cores"))
        #expect(SimpleYAML(parsing: withComment).string("memory") == "8GiB")
    }

    @Test("editing appends a missing key and refuses structured values")
    func editingEdgeCases() {
        #expect(SimpleYAML.settingTopLevelScalar("cpu", to: "4", in: "memory: 2")  == "memory: 2\ncpu: 4\n")
        #expect(SimpleYAML.settingTopLevelScalar("images", to: "x", in: Self.limaInstance) == nil)
        #expect(SimpleYAML.settingTopLevelScalar("docker", to: "x", in: Self.colimaDefaults) == nil)
        // A nested key of the same name is not the top-level key.
        let nestedOnly = "network:\n  cpu: 1\n"
        #expect(SimpleYAML.settingTopLevelScalar("cpu", to: "3", in: nestedOnly) == "network:\n  cpu: 1\ncpu: 3\n")
    }
}

// MARK: - Sizes

@Suite("VMSizeParsing")
struct VMSizeParsingTests {
    @Test("binary suffixes as Lima and Colima read them")
    func suffixes() {
        #expect(VMSizeParsing.bytes(from: "4GiB") == 4 << 30)
        #expect(VMSizeParsing.bytes(from: "4 GB") == 4 << 30)
        #expect(VMSizeParsing.bytes(from: "512MiB") == 512 << 20)
        #expect(VMSizeParsing.bytes(from: "1.5g") == 3 << 29)
        #expect(VMSizeParsing.bytes(from: "100") == 100)
        #expect(VMSizeParsing.bytes(from: "100", defaultUnit: .mebibytes) == 100 << 20)
        #expect(VMSizeParsing.bytes(from: "2TiB") == 2 << 40)
        #expect(VMSizeParsing.bytes(from: "4GB", decimalSuffixes: true) == 4_000_000_000)
    }

    @Test("rejects nonsense")
    func rejects() {
        #expect(VMSizeParsing.bytes(from: "") == nil)
        #expect(VMSizeParsing.bytes(from: "GiB") == nil)
        #expect(VMSizeParsing.bytes(from: "-4GiB") == nil)
        #expect(VMSizeParsing.bytes(from: "4 parsecs") == nil)
        #expect(VMSizeParsing.bytes(from: "99999999999TiB") == nil)
        #expect(VMSizeParsing.bytes(-1, unit: .gibibytes) == nil)
        #expect(VMSizeParsing.bytes(.infinity, unit: .mebibytes) == nil)
    }

    @Test("fixed units")
    func fixedUnits() {
        #expect(VMSizeParsing.bytes(8192, unit: .mebibytes) == 8 << 30)
        #expect(VMSizeParsing.bytes(0.5, unit: .gibibytes) == 1 << 29)
    }

    @Test("command-line values")
    func flags() {
        #expect(VMSizeParsing.gibibyteFlagValue(fromBytes: 4 << 30) == "4")
        #expect(VMSizeParsing.gibibyteFlagValue(fromBytes: 3 << 29) == "1.5")
        #expect(VMSizeParsing.gibibyteFlagValue(fromBytes: 1 << 28) == "0.25")
        #expect(VMSizeParsing.gibibyteFlagValue(fromBytes: (1 << 30) + (1 << 24)) == "1.02")
        #expect(VMSizeParsing.suffixedString(fromBytes: 4 << 30) == "4GiB")
        #expect(VMSizeParsing.suffixedString(fromBytes: 1536 << 20) == "1536MiB")
    }
}

// MARK: - Process table helpers

@Suite("VM host process helpers")
struct VMHostProcessTests {
    private func buffer(argc: Int32, path: String, padding: Int = 3, argv: [String], environment: [String] = ["HOME=/Users/x"], truncateTail: Int = 0) -> [UInt8] {
        var bytes = withUnsafeBytes(of: argc.littleEndian) { Array($0) }
        bytes += Array(path.utf8) + [0]
        bytes += [UInt8](repeating: 0, count: padding)
        for argument in argv { bytes += Array(argument.utf8) + [0] }
        for variable in environment { bytes += Array(variable.utf8) + [0] }
        return truncateTail > 0 ? Array(bytes.dropLast(truncateTail)) : bytes
    }

    @Test("parses KERN_PROCARGS2 buffers")
    func parseArguments() throws {
        let raw = buffer(argc: 5, path: "/opt/homebrew/bin/qemu-system-aarch64", argv: ["qemu-system-aarch64", "-name", "colima", "-m", "2048"])
        let parsed = try #require(VMProcessArguments.parse(raw))
        #expect(parsed.executablePath == "/opt/homebrew/bin/qemu-system-aarch64")
        #expect(parsed.arguments == ["-name", "colima", "-m", "2048"])
    }

    @Test("environment is never part of the arguments, empty arguments survive")
    func environmentIgnored() throws {
        let raw = buffer(argc: 3, path: "/bin/tool", argv: ["tool", "", "x"], environment: ["SECRET=1"])
        let parsed = try #require(VMProcessArguments.parse(raw))
        #expect(parsed.arguments == ["", "x"])
    }

    @Test("truncated or malformed buffers degrade")
    func malformed() throws {
        #expect(VMProcessArguments.parse([]) == nil)
        #expect(VMProcessArguments.parse([1, 0, 0]) == nil)
        // argc says 3 but the buffer ends inside the second argument.
        let cut = buffer(argc: 3, path: "/bin/tool", argv: ["tool", "--long-argument"], environment: [], truncateTail: 4)
        let parsed = try #require(VMProcessArguments.parse(cut))
        #expect(parsed.arguments.isEmpty)
        #expect(VMProcessArguments.parse([0xFF, 0xFF, 0xFF, 0x7F, 65, 0]) == nil)
    }

    @Test("allow-list accepts VM runtimes and nothing else")
    func allowList() {
        for name in ["limactl", "qemu-system-aarch64", "QEMULauncher", "com.apple.Virtualization.VirtualMachine", "VBoxHeadless", "VirtualBoxVM", "prl_vm_app", "vmware-vmx", "tart", "UTM", "colima", "OrbStack Helper", "com.docker.virtualization", "vfkit", "krunkit", "multipassd"] {
            #expect(VMProcessAllowList.matches(name: name), "\(name)")
        }
        for name in ["Safari", "launchd", "kernel_task", "Finder", "qe", "docker", "bash"] {
            #expect(!VMProcessAllowList.matches(name: name), "\(name)")
        }
    }

    @Test("kernel short names are cut at 16 characters")
    func kernelNames() {
        // p_comm of /…/com.apple.Virtualization.VirtualMachine
        #expect(VMProcessAllowList.mayMatch(kernelName: "com.apple.Virtua"))
        #expect(VMProcessAllowList.mayMatch(kernelName: "limactl"))
        #expect(VMProcessAllowList.mayMatch(kernelName: "qemu-system-aarc"))
        #expect(VMProcessAllowList.mayMatch(kernelName: "com.docker.virtu"))
        #expect(!VMProcessAllowList.mayMatch(kernelName: "Safari"))
        #expect(!VMProcessAllowList.mayMatch(kernelName: "com.apple.dock.e"))
    }
}

// MARK: - Tools and versions

@Suite("VMToolLocator")
struct VMToolLocatorTests {
    @Test("bare names are searched everywhere, absolute paths kept, duplicates removed")
    func candidates() {
        let resolved = VMToolLocator.resolvedCandidates(["limactl", "/opt/homebrew/bin/limactl", "~/.rd/bin/rdctl", "sub/dir/tool"], home: "/Users/me")
        #expect(resolved.first == "/opt/homebrew/bin/limactl")
        #expect(resolved.filter { $0 == "/opt/homebrew/bin/limactl" }.count == 1)
        #expect(resolved.contains("/Users/me/.local/bin/limactl"))
        #expect(resolved.contains("/Users/me/.rd/bin/rdctl"))
        #expect(!resolved.contains { $0.contains("sub/dir") })
    }

    @Test("child environment is minimal and English")
    func environment() {
        let environment = VMToolLocator.childEnvironment(home: "/Users/me", userName: "me", temporaryDirectory: "/tmp/x/")
        #expect(environment["HOME"] == "/Users/me")
        #expect(environment["LANG"] == "C")
        #expect(environment["PATH"]?.contains("/opt/homebrew/bin") == true)
        #expect(environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
    }

    @Test("command plans get a readable title")
    func title() {
        let plan = VMCommandPlan(tool: ["/opt/homebrew/bin/limactl"], arguments: ["stop", "default"], timeout: .seconds(1))
        #expect(plan.title == "limactl stop default")
    }
}

@Suite("VMVersion")
struct VMVersionTests {
    @Test("parsing and ordering")
    func versions() throws {
        #expect(try #require(VMVersion("1.1.0")) > #require(VMVersion("1.0.7")))
        #expect(try #require(VMVersion("v2.0.0-beta.1")) == #require(VMVersion("2.0.0")))
        #expect(try #require(VMVersion("1.2")) == #require(VMVersion("1.2.0")))
        #expect(try #require(VMVersion("0.23.2")) < #require(VMVersion("1.0.0")))
        #expect(try #require(VMVersion("10.0")) > #require(VMVersion("9.9.9")))
        #expect(VMVersion("latest") == nil)
        #expect(VMVersion("") == nil)
    }

    @Test("newest Homebrew keg")
    func newest() {
        #expect(VMVersion.newest(in: ["1.0.4", "1.1.1", ".DS_Store", "0.9"])?.description == "1.1.1")
        #expect(VMVersion.newest(in: ["junk"]) == nil)
    }
}

@Suite("VMResourceEditing")
struct VMResourceEditingTests {
    private let capabilities = VMCapabilities(canStart: true, canStop: true, canRestart: true, canEditCPUs: true, canEditMemory: true, canEditDisk: true, editRequiresStopped: true, diskCanOnlyGrow: true)
    private let current = VMResources(cpus: 4, memoryBytes: 4 << 30, diskBytes: 100 << 30)

    @Test("only changed fields are returned")
    func changed() throws {
        let result = VMResourceEditing.changes(requested: VMResources(cpus: 4, memoryBytes: 8 << 30, diskBytes: 100 << 30), current: current, capabilities: capabilities)
        let changes = try result.get()
        #expect(changes == VMResources(cpus: nil, memoryBytes: 8 << 30, diskBytes: nil))
        let same = try VMResourceEditing.changes(requested: current, current: current, capabilities: capabilities).get()
        #expect(VMResourceEditing.isEmpty(same))
    }

    @Test("rejects invalid, shrinking and not-editable changes")
    func rejected() {
        #expect(throws: VMResourceEditing.Problem.invalidCPUs) { try VMResourceEditing.changes(requested: VMResources(cpus: 0), current: current, capabilities: capabilities).get() }
        #expect(throws: VMResourceEditing.Problem.invalidMemory) { try VMResourceEditing.changes(requested: VMResources(memoryBytes: 0), current: current, capabilities: capabilities).get() }
        #expect(throws: VMResourceEditing.Problem.diskCannotShrink) { try VMResourceEditing.changes(requested: VMResources(diskBytes: 50 << 30), current: current, capabilities: capabilities).get() }
        var readOnlyDisk = capabilities
        readOnlyDisk.canEditDisk = false
        #expect(throws: VMResourceEditing.Problem.notEditable("The disk size")) { try VMResourceEditing.changes(requested: VMResources(diskBytes: 200 << 30), current: current, capabilities: readOnlyDisk).get() }
    }
}
