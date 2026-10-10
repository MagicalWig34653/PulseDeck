import Foundation
import Testing
@testable import PulseDeckCore

private let host = LimaHostInfo(cpuCount: 10, memoryBytes: 16 << 30, architecture: "arm64")

private func process(_ pid: Int32, _ name: String, arguments: [String] = [], path: String? = nil) -> VMHostProcess {
    VMHostProcess(pid: pid, parentPID: 1, name: name, executablePath: path, arguments: arguments)
}

private let fullInstanceYAML = """
vmType: "vz"
arch: "aarch64"
cpus: 6
memory: "8GiB"
disk: "120GiB"
mountType: "virtiofs"
images:
- location: "https://example.invalid/ubuntu.img"
  arch: "aarch64"
"""

// MARK: - Lima instances

@Suite("Lima instances")
struct LimaInstanceTests {
    private func files(yaml: String? = fullInstanceYAML, pids: [String: String] = [:], started: Date? = nil) -> LimaInstanceFiles {
        LimaInstanceFiles(name: "dev", directory: "/Users/me/.lima/dev", limaYAML: yaml, sshConfig: "Host lima-dev\n  Hostname 127.0.0.1\n  Port 60022\n", limaVersion: "1.1.1\n", pidFiles: pids, hostAgentStartedAt: started)
    }

    @Test("running: host agent and driver alive")
    func running() {
        let started = Date(timeIntervalSince1970: 1_000)
        let instance = LimaInspector.inspect(
            files(pids: ["ha.pid": "100\n", "vz.pid": "100"], started: started),
            processes: [process(100, "limactl", arguments: ["hostagent", "dev"])],
            host: host,
            now: started.addingTimeInterval(3_600)
        )
        #expect(instance.state == .running)
        #expect(instance.hostProcessIDs == [100])
        #expect(instance.startedAt == started)
        #expect(instance.resources == VMResources(cpus: 6, memoryBytes: 8 << 30, diskBytes: 120 << 30))
        #expect(instance.vmType == "vz")
        #expect(instance.architecture == "arm64")
        #expect(instance.guestOS == "Linux")
        #expect(instance.sshPort == 60022)
        #expect(instance.limaVersion == "1.1.1")
        #expect(instance.defaultedResources.isEmpty)
    }

    @Test("QEMU driver: two processes")
    func qemu() {
        let instance = LimaInspector.inspect(
            files(pids: ["ha.pid": "100", "qemu.pid": "200"]),
            processes: [process(100, "limactl"), process(200, "qemu-system-aarch64")],
            host: host
        )
        #expect(instance.state == .running)
        #expect(instance.hostProcessIDs == [100, 200])
    }

    @Test("stale PID files (processes gone) mean stopped, and no start time is shown")
    func stale() {
        let instance = LimaInspector.inspect(
            files(pids: ["ha.pid": "100", "qemu.pid": "200"], started: Date()),
            processes: [process(4242, "limactl")],
            host: host
        )
        #expect(instance.state == .stopped)
        #expect(instance.hostProcessIDs.isEmpty)
        #expect(instance.startedAt == nil)
    }

    @Test("a reused PID that is not limactl is not the host agent")
    func reusedPID() {
        let instance = LimaInspector.inspect(files(pids: ["ha.pid": "100"]), processes: [process(100, "tart")], host: host)
        #expect(instance.state == .stopped)
    }

    @Test("starting, stopping and the driver-without-PID-file grace")
    func transitions() {
        let now = Date(timeIntervalSince1970: 10_000)
        let starting = LimaInspector.inspect(files(pids: ["ha.pid": "100", "qemu.pid": "200"]), processes: [process(100, "limactl")], host: host, now: now)
        #expect(starting.state == .starting)
        let stopping = LimaInspector.inspect(files(pids: ["qemu.pid": "200"]), processes: [process(200, "qemu-system-aarch64")], host: host, now: now)
        #expect(stopping.state == .stopping)
        // No driver PID file at all: starting at first, running once the host agent has lived a while.
        let young = LimaInspector.inspect(files(pids: ["ha.pid": "100"], started: now.addingTimeInterval(-10)), processes: [process(100, "limactl")], host: host, now: now)
        #expect(young.state == .starting)
        let old = LimaInspector.inspect(files(pids: ["ha.pid": "100"], started: now.addingTimeInterval(-600)), processes: [process(100, "limactl")], host: host, now: now)
        #expect(old.state == .running)
    }

    @Test("Lima's built-in defaults are applied and reported when lima.yaml is silent")
    func defaults() {
        let yaml = "vmType: null\ncpus: null\nmemory: null\ndisk: null\narch: null\n"
        let instance = LimaInspector.inspect(files(yaml: yaml), processes: [], host: host)
        #expect(instance.resources == VMResources(cpus: 4, memoryBytes: 4 << 30, diskBytes: 100 << 30))
        #expect(instance.defaultedResources == ["CPUs", "memory", "disk"])
        #expect(instance.vmType == nil)
        let small = LimaHostInfo(cpuCount: 2, memoryBytes: 4 << 30, architecture: "x86_64")
        let onSmallHost = LimaInspector.inspect(files(yaml: yaml), processes: [], host: small)
        #expect(onSmallHost.resources.cpus == 2)
        #expect(onSmallHost.resources.memoryBytes == 2 << 30)
        #expect(onSmallHost.architecture == "x86_64")
    }

    @Test("an unreadable lima.yaml hides resources and edit capabilities")
    func unreadable() {
        let instance = LimaInspector.inspect(files(yaml: nil), processes: [], host: host)
        #expect(!instance.configurationReadable)
        let record = LimaRecordBuilder.record(for: instance, nativeID: "dev", name: "dev", capabilities: LimaCapabilityRules.capabilities(installedVersion: VMVersion("1.1.0")))
        #expect(record.resources == VMResources())
        #expect(record.capabilities.canStart)
        #expect(!record.capabilities.canEditAnything)
    }

    @Test("ssh.config port")
    func ssh() {
        #expect(LimaSSHConfig.port(in: "Host x\n  Port 50022\n") == 50022)
        #expect(LimaSSHConfig.port(in: "Host x\n  Port nope\n") == nil)
        #expect(LimaSSHConfig.port(in: "") == nil)
    }

    @Test("macOS guests and architecture names")
    func guests() {
        let instance = LimaInspector.inspect(files(yaml: "os: Darwin\narch: x86_64\n"), processes: [], host: host)
        #expect(instance.guestOS == "macOS")
        #expect(instance.architecture == "x86_64")
    }
}

@Suite("Lima capabilities, commands and ownership")
struct LimaCommandTests {
    @Test("disk editing needs a Lima that is known to accept it")
    func capabilities() {
        #expect(LimaCapabilityRules.capabilities(installedVersion: VMVersion("1.1.1")).canEditDisk)
        #expect(!LimaCapabilityRules.capabilities(installedVersion: VMVersion("1.0.7")).canEditDisk)
        #expect(!LimaCapabilityRules.capabilities(installedVersion: nil).canEditDisk)
        let caps = LimaCapabilityRules.capabilities(installedVersion: nil)
        #expect(caps.canEditCPUs && caps.canEditMemory && caps.editRequiresStopped && caps.diskCanOnlyGrow)
    }

    @Test("lifecycle plans")
    func lifecycle() {
        #expect(LimaCommands.plans(for: .start, instance: "dev").map(\.arguments) == [["start", "dev"]])
        #expect(LimaCommands.plans(for: .stop, instance: "dev").map(\.arguments) == [["stop", "dev"]])
        #expect(LimaCommands.plans(for: .restart, instance: "dev").map(\.arguments) == [["restart", "dev"]])
        let custom = LimaCommands.plans(for: .start, instance: "dev", environment: ["LIMA_HOME": "/x"])
        #expect(custom.first?.environment == ["LIMA_HOME": "/x"])
    }

    @Test("edit plan: GiB flags, then start when it was running")
    func edit() {
        let changes = VMResources(cpus: 8, memoryBytes: 6 << 30, diskBytes: 200 << 30)
        let plans = LimaCommands.editPlans(instance: "dev", changes: changes, restartAfterwards: true)
        #expect(plans.map(\.arguments) == [["edit", "dev", "--cpus", "8", "--memory", "6", "--disk", "200"], ["start", "dev"]])
        let memoryOnly = LimaCommands.editPlans(instance: "dev", changes: VMResources(memoryBytes: 3 << 29), restartAfterwards: false)
        #expect(memoryOnly.map(\.arguments) == [["edit", "dev", "--memory", "1.5"]])
        #expect(LimaCommands.editPlans(instance: "dev", changes: VMResources(), restartAfterwards: false).isEmpty)
    }

    @Test("Lima homes owned by other providers are not listed twice")
    func ownership() {
        let home = "/Users/me"
        #expect(LimaPaths.limaHome(environment: [:], home: home) == "/Users/me/.lima")
        #expect(LimaPaths.limaHome(environment: ["LIMA_HOME": "/data/lima"], home: home) == "/data/lima")
        #expect(!LimaPaths.isForeign(limaHome: "/Users/me/.lima", home: home))
        #expect(LimaPaths.isForeign(limaHome: "/Users/me/.colima/_lima/", home: home))
        #expect(LimaPaths.isForeign(limaHome: "/Users/me/Library/Application Support/rancher-desktop/lima", home: home))
        #expect(LimaPaths.isForeign(limaHome: "/Applications/Finch/lima/data", home: home))
        #expect(LimaPaths.isColimaInstance(name: "colima"))
        #expect(LimaPaths.isColimaInstance(name: "colima-work"))
        #expect(!LimaPaths.isColimaInstance(name: "colimax"))
    }
}

// MARK: - Colima

@Suite("Colima")
struct ColimaTests {
    @Test("configuration directory resolution mirrors Colima")
    func base() {
        let home = "/Users/me"
        #expect(ColimaPaths.configBase(environment: [:], home: home, exists: { $0 == "/Users/me/.colima" }) == "/Users/me/.colima")
        #expect(ColimaPaths.configBase(environment: ["COLIMA_HOME": "/c"], home: home, exists: { $0 == "/c" || $0 == "/Users/me/.colima" }) == "/c")
        #expect(ColimaPaths.configBase(environment: ["COLIMA_HOME": "/missing"], home: home, exists: { $0 == "/Users/me/.colima" }) == "/Users/me/.colima")
        #expect(ColimaPaths.configBase(environment: [:], home: home, exists: { $0 == "/Users/me/.config/colima" }) == "/Users/me/.config/colima")
        #expect(ColimaPaths.configBase(environment: [:], home: home, exists: { _ in false }) == "/Users/me/.colima")
        #expect(ColimaPaths.limaHome(environment: [:], base: "/b") == "/b/_lima")
        #expect(ColimaPaths.limaHome(environment: ["LIMA_HOME": "/l"], base: "/b") == "/l")
    }

    @Test("profiles and instance names")
    func profiles() {
        #expect(ColimaPaths.limaInstanceName(profile: "default") == "colima")
        #expect(ColimaPaths.limaInstanceName(profile: "work") == "colima-work")
        #expect(ColimaPaths.limaInstanceName(profile: "colima-work") == "colima-work")
        #expect(ColimaPaths.profile(forLimaInstance: "colima") == "default")
        #expect(ColimaPaths.profile(forLimaInstance: "colima-work") == "work")
        #expect(ColimaPaths.profile(forLimaInstance: "other") == nil)
        let list = ColimaPaths.profiles(configDirectoriesWithConfig: ["work", "default", "_lima", ".cache"], limaInstances: ["colima", "colima-old", "foreign"])
        #expect(list == ["default", "old", "work"])
    }

    @Test("start and stop commands name the profile positionally")
    func commands() {
        #expect(ColimaCommands.plans(for: .start, profile: "default").map(\.arguments) == [["start"]])
        #expect(ColimaCommands.plans(for: .stop, profile: "work").map(\.arguments) == [["stop", "work"]])
        #expect(ColimaCommands.plans(for: .restart, profile: "work").map(\.arguments) == [["restart", "work"]])
        let apply = ColimaCommands.startWithResources(profile: "work", changes: VMResources(cpus: 4, memoryBytes: 3 << 29, diskBytes: 150 << 30))
        #expect(apply.arguments == ["start", "work", "--cpus", "4", "--memory", "1.5", "--disk", "150"])
        #expect(ColimaCommands.startWithResources(profile: "default", changes: VMResources(cpus: 2)).arguments == ["start", "--cpus", "2"])
    }

    @Test("colima.yaml is edited in place")
    func editing() throws {
        let edited = try #require(ColimaCommands.editedConfiguration(SimpleYAMLTests.colimaDefaults, changes: VMResources(cpus: 6, memoryBytes: 8 << 30, diskBytes: 200 << 30)))
        let config = ColimaConfig(parsing: edited)
        #expect(config.cpu == 6)
        #expect(config.memoryGiB == 8)
        #expect(config.diskGiB == 200)
        #expect(config.runtime == "docker")
        #expect(edited.contains("# Number of CPUs"))
    }

    @Test("configuration to resources")
    func configuration() {
        let config = ColimaConfig(parsing: SimpleYAMLTests.colimaDefaults)
        #expect(config.resources == VMResources(cpus: 2, memoryBytes: 2 << 30, diskBytes: 100 << 30))
        #expect(config.runtime == "docker")
        #expect(config.networkAddress == true)
        #expect(config.kubernetesEnabled == false)
    }

    @Test("a running profile gets its processes and the config's resources")
    func record() {
        let yaml = "cpus: 4\nmemory: \"4GiB\"\ndisk: \"60GiB\"\nvmType: \"vz\"\narch: \"aarch64\"\nmountType: virtiofs\n"
        let files = LimaInstanceFiles(name: "colima", directory: "/Users/me/.colima/_lima/colima", limaYAML: yaml, pidFiles: ["ha.pid": "50", "vz.pid": "50"])
        let instance = LimaInspector.inspect(files, processes: [process(50, "limactl")], host: host)
        let config = ColimaConfig(parsing: "cpu: 8\nmemory: 12\ndisk: 100\nruntime: containerd\n")
        let record = ColimaRecordBuilder.record(profile: "default", config: config, instance: instance, host: host)
        #expect(record.nativeID == "default")
        #expect(record.state == .running)
        #expect(record.hostProcessIDs == [50])
        // colima.yaml wins: it is what the next start applies.
        #expect(record.resources == VMResources(cpus: 8, memoryBytes: 12 << 30, diskBytes: 100 << 30))
        #expect(record.details.contains(VMDetail(label: "Container runtime", value: "containerd")))
        #expect(record.capabilities.canEditDisk && record.capabilities.editRequiresStopped && record.capabilities.diskCanOnlyGrow)
    }

    @Test("a profile that was never started is described from colima.yaml alone")
    func neverStarted() {
        let instance = LimaInspector.inspect(LimaInstanceFiles(name: "colima-new", directory: "/x"), processes: [], host: host)
        let config = ColimaConfig(parsing: SimpleYAMLTests.colimaDefaults)
        let record = ColimaRecordBuilder.record(profile: "new", config: config, instance: instance, host: host)
        #expect(record.state == .stopped)
        #expect(record.name == "colima (new)")
        #expect(record.resources.cpus == 2)
        #expect(record.architecture == "arm64")
        #expect(!record.details.contains { $0.label == "Configuration" })
    }
}

// MARK: - Finch / Rancher Desktop

@Suite("Finch")
struct FinchTests {
    @Test("locations")
    func paths() {
        #expect(FinchPaths.limaHome == "/Applications/Finch/lima/data")
        #expect(FinchPaths.instanceDirectory == "/Applications/Finch/lima/data/finch")
        #expect(FinchPaths.configFile(home: "/Users/me") == "/Users/me/.finch/finch.yaml")
    }

    @Test("finch.yaml")
    func config() {
        let config = FinchConfig(parsing: "cpus: 4\nmemory: 8GiB\nvmType: vz\ncreds_helpers:\n  - ecr-login\n")
        #expect(config.cpus == 4)
        #expect(config.memoryBytes == 8 << 30)
        #expect(config.vmType == "vz")
    }

    @Test("commands: no restart verb, settings only touch finch.yaml")
    func commands() {
        #expect(FinchCommands.plans(for: .restart).map(\.arguments) == [["vm", "stop"], ["vm", "start"]])
        #expect(FinchCommands.plans(for: .start).map(\.arguments) == [["vm", "start"]])
        let plans = FinchCommands.settingsPlans(changes: VMResources(cpus: 6, memoryBytes: 6 << 30, diskBytes: 1 << 40), startAfterwards: true)
        #expect(plans.map(\.arguments) == [["vm", "settings", "--cpus", "6", "--memory", "6GiB"], ["vm", "start"]])
        #expect(FinchCommands.settingsPlans(changes: VMResources(diskBytes: 1 << 40), startAfterwards: false).isEmpty)
    }

    @Test("record uses finch.yaml and keeps the disk read-only")
    func record() {
        let files = LimaInstanceFiles(name: "finch", directory: FinchPaths.instanceDirectory, limaYAML: "cpus: 2\nmemory: 2GiB\ndisk: 50GiB\nvmType: vz\n", pidFiles: ["ha.pid": "7", "vz.pid": "7"])
        let instance = LimaInspector.inspect(files, processes: [process(7, "limactl")], host: host)
        let record = FinchRecordBuilder.record(config: FinchConfig(parsing: "cpus: 4\nmemory: 4GiB\n"), instance: instance, configFile: "/Users/me/.finch/finch.yaml")
        #expect(record.state == .running)
        #expect(record.resources == VMResources(cpus: 4, memoryBytes: 4 << 30, diskBytes: 50 << 30))
        #expect(record.capabilities.canEditCPUs && record.capabilities.canEditMemory && !record.capabilities.canEditDisk)
    }
}

@Suite("Rancher Desktop")
struct RancherDesktopTests {
    @Test("locations: settings are under Preferences, the VM is Lima instance 0")
    func paths() {
        let home = "/Users/me"
        #expect(RancherDesktopPaths.instanceDirectory(home: home) == "/Users/me/Library/Application Support/rancher-desktop/lima/0")
        #expect(RancherDesktopPaths.settingsFile(home: home) == "/Users/me/Library/Preferences/rancher-desktop/settings.json")
    }

    @Test("settings.json")
    func settings() {
        let json = """
        {"version": 19, "containerEngine": {"allowedImages": {"enabled": false}, "name": "moby"},
         "virtualMachine": {"memoryInGB": 6, "numberCPUs": 4, "type": "vz", "useRosetta": false, "mount": {"type": "virtiofs"}},
         "kubernetes": {"enabled": true}}
        """
        let settings = RancherDesktopSettings(parsing: json)
        #expect(settings.cpus == 4)
        #expect(settings.memoryGiB == 6)
        #expect(settings.vmType == "vz")
        #expect(settings.containerEngine == "moby")
        let broken = RancherDesktopSettings(parsing: "{not json")
        #expect(broken.cpus == nil && broken.memoryGiB == nil)
    }

    @Test("rdctl: start with flags updates a running application")
    func commands() throws {
        #expect(RancherDesktopCommands.plans(for: .stop).map(\.arguments) == [["shutdown"]])
        #expect(RancherDesktopCommands.plans(for: .restart).map(\.arguments) == [["shutdown"], ["start"]])
        let plan = try #require(RancherDesktopCommands.applyPlan(changes: VMResources(cpus: 6, memoryBytes: 5 << 30)))
        #expect(plan.arguments == ["start", "--virtual-machine.number-cpus=6", "--virtual-machine.memory-in-gb=5"])
        #expect(RancherDesktopCommands.applyPlan(changes: VMResources(diskBytes: 1)) == nil)
    }

    @Test("record")
    func record() {
        let files = LimaInstanceFiles(name: "0", directory: "/x/lima/0", limaYAML: "cpus: 2\nmemory: 2GiB\ndisk: 100GiB\nvmType: vz\n", pidFiles: ["ha.pid": "9", "vz.pid": "9"])
        let instance = LimaInspector.inspect(files, processes: [process(9, "limactl")], host: host)
        let settings = RancherDesktopSettings(parsing: "{\"virtualMachine\":{\"memoryInGB\":8,\"numberCPUs\":6}}")
        let record = RancherDesktopRecordBuilder.record(settings: settings, instance: instance)
        #expect(record.state == .running)
        #expect(record.resources == VMResources(cpus: 6, memoryBytes: 8 << 30, diskBytes: 100 << 30))
        #expect(!record.capabilities.editRequiresStopped)
        #expect(!record.capabilities.canEditDisk)
    }
}

// MARK: - OrbStack

@Suite("OrbStack")
struct OrbStackTests {
    @Test("machine list: array shape")
    func list() {
        let json = """
        [{"id":"01HX","name":"ubuntu","image":{"distro":"ubuntu","version":"24.04","arch":"arm64"},"record":{"state":"running"}},
         {"name":"fedora","state":"stopped","image":{"distro":"fedora","arch":"amd64"}},
         {"name":"weird","state":"exploding"},
         {"id":"nameless"}]
        """
        let machines = OrbStackParsing.machines(fromJSON: json)
        #expect(machines.map(\.name) == ["ubuntu", "fedora", "weird"])
        #expect(machines[0].state == .running)
        #expect(machines[0].distribution == "ubuntu 24.04")
        #expect(machines[0].architecture == "arm64")
        #expect(machines[1].state == .stopped)
        #expect(machines[1].architecture == "x86_64")
        #expect(machines[2].state == .unknown)
    }

    @Test("machine list: wrapped object and garbage")
    func wrapped() {
        #expect(OrbStackParsing.machines(fromJSON: "{\"machines\":[{\"name\":\"a\",\"state\":\"running\"}]}").count == 1)
        #expect(OrbStackParsing.machines(fromJSON: "").isEmpty)
        #expect(OrbStackParsing.machines(fromJSON: "OrbStack is not running").isEmpty)
    }

    @Test("config show")
    func config() {
        #expect(OrbStackParsing.config(fromShowOutput: "cpu: 6\nmemory_mib: 8192\nrosetta: true\n") == OrbStackConfig(cpu: 6, memoryMiB: 8192))
        #expect(OrbStackParsing.config(fromShowOutput: "cpu = 4\nmemory_mib = 4096") == OrbStackConfig(cpu: 4, memoryMiB: 4096))
        #expect(OrbStackParsing.config(fromShowOutput: "{\"cpu\": 3, \"memory_mib\": 2048}") == OrbStackConfig(cpu: 3, memoryMiB: 2048))
        #expect(OrbStackParsing.config(fromShowOutput: "nothing useful") == OrbStackConfig())
    }

    @Test("VM processes: the vmgr helper when arguments are readable")
    func processes() {
        let all = [process(1, "OrbStack Helper", arguments: ["vmgr"]), process(2, "OrbStack Helper", arguments: ["renderer"]), process(3, "limactl")]
        #expect(OrbStackParsing.vmProcessIDs(in: all) == [1])
        #expect(OrbStackParsing.vmProcessIDs(in: [process(2, "OrbStack Helper"), process(4, "OrbStack Helper")]) == [2, 4])
        #expect(OrbStackParsing.vmProcessIDs(in: [process(3, "limactl")]).isEmpty)
    }

    @Test("commands: machines are named, the shared VM is restarted by stop and start")
    func commands() {
        #expect(OrbStackCommands.plans(for: .stop, machine: "ubuntu").map(\.arguments) == [["stop", "ubuntu"]])
        #expect(OrbStackCommands.plans(for: .restart, machine: "ubuntu").map(\.arguments) == [["restart", "ubuntu"]])
        #expect(OrbStackCommands.plans(for: .restart, machine: nil).map(\.arguments) == [["stop"], ["start"]])
        #expect(OrbStackCommands.configPlans(changes: VMResources(cpus: 4, memoryBytes: 6 << 30)).map(\.arguments) == [["config", "set", "cpu", "4"], ["config", "set", "memory_mib", "6144"]])
        #expect(OrbStackCommands.listPlan.arguments == ["list", "-f", "json"])
    }

    @Test("records: one shared VM with global resources, machines for control only")
    func records() throws {
        let machines = [OrbStackMachine(name: "ubuntu", state: .running, distribution: "ubuntu 24.04", architecture: "arm64")]
        let records = OrbStackRecordBuilder.records(machines: machines, config: OrbStackConfig(cpu: 6, memoryMiB: 8192), vmProcessIDs: [11], host: host)
        #expect(records.map(\.nativeID) == ["vm", "ubuntu"])
        let vm = try #require(records.first)
        #expect(vm.state == .running)
        #expect(vm.resources == VMResources(cpus: 6, memoryBytes: 8 << 30, diskBytes: nil))
        #expect(vm.capabilities.canEditCPUs && vm.capabilities.canEditMemory && !vm.capabilities.editRequiresStopped)
        #expect(records[1].hostProcessIDs.isEmpty)
        #expect(!records[1].capabilities.canEditAnything)
        // Unknown configuration: no editing in the dark.
        let unknown = OrbStackRecordBuilder.records(machines: [], config: OrbStackConfig(), vmProcessIDs: [], host: host)
        #expect(unknown.first?.state == .stopped)
        #expect(unknown.first?.capabilities.canEditAnything == false)
    }
}

// MARK: - Docker Desktop

@Suite("Docker Desktop")
struct DockerDesktopTests {
    @Test("settings keys are matched case-insensitively")
    func settings() {
        let store = DockerDesktopSettings(parsing: "{\"Cpus\": 6, \"MemoryMiB\": 8192, \"DiskSizeMiB\": 102400, \"SwapMiB\": 1024}")
        #expect(store.resources == VMResources(cpus: 6, memoryBytes: 8 << 30, diskBytes: 100 << 30))
        let legacy = DockerDesktopSettings(parsing: "{\"cpus\": 2, \"memoryMiB\": 2048}")
        #expect(legacy.resources == VMResources(cpus: 2, memoryBytes: 2 << 30, diskBytes: nil))
        #expect(DockerDesktopSettings(parsing: "[]").resources == VMResources())
        #expect(DockerDesktopSettings(parsing: "{\"Cpus\": 0}").cpus == nil)
    }

    @Test("settings file order")
    func paths() {
        let files = DockerDesktopPaths.settingsFiles(home: "/Users/me")
        #expect(files == ["/Users/me/Library/Group Containers/group.com.docker/settings-store.json", "/Users/me/Library/Group Containers/group.com.docker/settings.json"])
    }

    @Test("VM processes and Resource Saver state")
    func processes() {
        let table = [process(1, "com.docker.backend"), process(2, "com.docker.virtualization"), process(3, "qemu-system-aarch64", path: "/Applications/Docker.app/Contents/MacOS/qemu"), process(4, "qemu-system-aarch64", path: "/opt/homebrew/bin/qemu-system-aarch64")]
        #expect(DockerDesktopProcesses.vmProcessIDs(in: table) == [2, 3])
        #expect(DockerDesktopProcesses.backendIsRunning(in: table))
        let paused = DockerDesktopRecordBuilder.record(settings: nil, vmProcessIDs: [], backendRunning: true, host: host, settingsFile: nil)
        #expect(paused.state == .stopped)
        #expect(paused.details.contains { $0.label == "Note" })
        let running = DockerDesktopRecordBuilder.record(settings: DockerDesktopSettings(parsing: "{\"Cpus\":4}"), vmProcessIDs: [2], backendRunning: true, host: host, settingsFile: "/s.json")
        #expect(running.state == .running)
        #expect(running.resources.cpus == 4)
        #expect(!running.capabilities.canEditAnything)
        #expect(running.capabilities.canStart && running.capabilities.canStop && running.capabilities.canRestart)
    }

    @Test("docker desktop CLI")
    func commands() {
        #expect(DockerDesktopCommands.plans(for: .start).map(\.arguments) == [["desktop", "start"]])
        #expect(DockerDesktopCommands.plans(for: .stop).map(\.arguments) == [["desktop", "stop"]])
        #expect(DockerDesktopCommands.plans(for: .restart).map(\.arguments) == [["desktop", "restart"]])
    }
}
