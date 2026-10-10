import Foundation
import Testing
@testable import PulseDeckCore

@Suite("Multipass VM parsing")
struct VMMultipassTests {
    // Shape produced by JsonFormatter::format(ListReply) in canonical/multipass.
    private let listJSON = """
    {
        "list": [
            {
                "ipv4": [
                    "192.168.64.5",
                    "10.42.0.1"
                ],
                "name": "primary",
                "release": "Ubuntu 24.04 LTS",
                "state": "Running",
                "zone": null
            },
            {
                "ipv4": [],
                "name": "dev",
                "release": "Ubuntu 22.04 LTS",
                "state": "Stopped",
                "zone": {"name": "zone1", "available": true}
            },
            {
                "ipv4": [],
                "name": "trash",
                "release": "Not Available",
                "state": "Deleted"
            },
            {
                "ipv4": [],
                "name": "booting",
                "release": "Not Available",
                "state": "Starting"
            }
        ]
    }
    """

    // Shape produced by JsonFormatter::format(InfoReply): cpu_count and disk values are strings,
    // memory values are integers.
    private let infoJSON = """
    {
        "errors": [],
        "info": {
            "primary": {
                "cpu_count": "2",
                "disks": {
                    "sda1": {
                        "total": "5019643904",
                        "used": "2154184704"
                    }
                },
                "image_hash": "5e8bd1e7f2d2a1c0",
                "image_release": "24.04 LTS",
                "ipv4": ["192.168.64.5"],
                "load": [0.12, 0.08, 0.03],
                "memory": {
                    "total": 1002815488,
                    "used": 187637760
                },
                "mounts": {},
                "release": "Ubuntu 24.04.1 LTS",
                "snapshot_count": "2",
                "state": "Running"
            },
            "dev": {
                "cpu_count": "4",
                "disks": {"sda1": {"total": "53687091200"}},
                "image_hash": "aaaa",
                "image_release": "22.04 LTS",
                "ipv4": [],
                "load": [],
                "memory": {"total": 4294967296},
                "mounts": {},
                "release": "",
                "state": "Stopped"
            }
        }
    }
    """

    private func data(_ text: String) -> Data { Data(text.utf8) }

    @Test func parsesList() throws {
        let list = try #require(MultipassVMParsing.parseList(data(listJSON)))
        #expect(list.map(\.name) == ["primary", "dev", "trash", "booting"])
        #expect(list[0].ipv4 == ["192.168.64.5", "10.42.0.1"])
        #expect(list[0].status == "Running")
        #expect(list[1].release == "Ubuntu 22.04 LTS")
    }

    @Test func rejectsGarbage() {
        #expect(MultipassVMParsing.parseList(data("not json")) == nil)
        #expect(MultipassVMParsing.parseList(data("{\"foo\": 1}")) == nil)
        #expect(MultipassVMParsing.parseInfo(data("[]")) == nil)
    }

    @Test func parsesInfoWithStringAndNumberValues() throws {
        let info = try #require(MultipassVMParsing.parseInfo(data(infoJSON)))
        let primary = try #require(info["primary"])
        #expect(primary.cpuCount == 2)
        #expect(primary.memoryTotalBytes == 1_002_815_488)
        #expect(primary.diskTotalBytes == 5_019_643_904)
        #expect(primary.snapshotCount == 2)
        #expect(info["dev"]?.diskTotalBytes == 53_687_091_200)
        #expect(info["dev"]?.memoryTotalBytes == 4_294_967_296)

        // Numbers instead of strings (other versions) work as well.
        let numeric = #"{"info": {"x": {"cpu_count": 3, "disks": {"sda1": {"total": 1024}}, "memory": {"total": 2048}}}}"#
        let parsed = try #require(MultipassVMParsing.parseInfo(data(numeric)))
        #expect(parsed["x"]?.cpuCount == 3)
        #expect(parsed["x"]?.diskTotalBytes == 1024)
        #expect(parsed["x"]?.memoryTotalBytes == 2048)
    }

    @Test func infoWithoutDiskOrMemoryLeavesValuesNil() throws {
        let info = try #require(MultipassVMParsing.parseInfo(data(#"{"errors": [], "info": {"x": {"state": "Stopped", "disks": {"sda1": {}}, "memory": {}}}}"#)))
        #expect(info["x"]?.cpuCount == nil)
        #expect(info["x"]?.memoryTotalBytes == nil)
        #expect(info["x"]?.diskTotalBytes == nil)
    }

    @Test func mapsStates() {
        #expect(MultipassVMParsing.vmState(forStatus: "Running") == .running)
        #expect(MultipassVMParsing.vmState(forStatus: "Stopped") == .stopped)
        #expect(MultipassVMParsing.vmState(forStatus: "Starting") == .starting)
        #expect(MultipassVMParsing.vmState(forStatus: "Restarting") == .starting)
        #expect(MultipassVMParsing.vmState(forStatus: "Suspended") == .suspended)
        #expect(MultipassVMParsing.vmState(forStatus: "Suspending") == .stopping)
        #expect(MultipassVMParsing.vmState(forStatus: "Delayed Shutdown") == .stopping)
        #expect(MultipassVMParsing.vmState(forStatus: "Unknown") == .unknown)
        #expect(MultipassVMParsing.vmState(forStatus: "Unavailable") == .unknown)
        #expect(MultipassVMParsing.vmState(forStatus: "Deleted") == nil)
    }

    @Test func matchesQemuByInstanceDirectory() {
        let base = "/var/root/Library/Application Support/multipassd/qemu/vault/instances"
        let processes = [
            VMHostProcess(pid: 500, parentPID: 1, name: "qemu-system-aarch64", arguments: [
                "-drive", "file=\(base)/primary/ubuntu-24.04-server-cloudimg-arm64.img,if=none,format=qcow2,discard=unmap,id=hda",
                "-smp", "2", "-m", "1024M", "-cdrom", "\(base)/primary/cloud-init-config.iso",
            ]),
            VMHostProcess(pid: 501, parentPID: 1, name: "qemu-system-aarch64", arguments: ["-drive", "file=\(base)/primary-2/disk.img"]),
            VMHostProcess(pid: 502, parentPID: 1, name: "ssh", arguments: ["\(base)/primary/x"]),
            VMHostProcess(pid: 503, parentPID: 1, name: "qemu-system-aarch64", arguments: []),
        ]
        #expect(MultipassVMParsing.hostProcessIDs(instance: "primary", processes: processes) == [500])
        #expect(MultipassVMParsing.hostProcessIDs(instance: "primary-2", processes: processes) == [501])
        #expect(MultipassVMParsing.hostProcessIDs(instance: "prim", processes: processes).isEmpty)
    }

    @Test func buildsRecords() throws {
        let list = try #require(MultipassVMParsing.parseList(data(listJSON)))
        let info = try #require(MultipassVMParsing.parseInfo(data(infoJSON)))
        let records = MultipassVMParsing.records(list: list, info: info, processes: [])
        #expect(records.map(\.name) == ["primary", "dev", "booting"], "deleted instances are not listed")

        let primary = records[0]
        #expect(primary.state == .running)
        #expect(primary.ipAddress == "192.168.64.5")
        #expect(primary.resources == VMResources(cpus: 2, memoryBytes: 1_002_815_488, diskBytes: 5_019_643_904))
        #expect(primary.hostProcessIDs.isEmpty)
        #expect(primary.details.contains { $0.label == "Host usage" }, "a running VM without an attributable process says why")
        #expect(primary.details.contains { $0.label == "Image" && $0.value == "Ubuntu 24.04 LTS" })
        #expect(primary.details.contains { $0.label == "Snapshots" && $0.value == "2" })
        #expect(primary.capabilities.canEditCPUs && primary.capabilities.editRequiresStopped && primary.capabilities.diskCanOnlyGrow)

        let dev = records[1]
        #expect(dev.state == .stopped)
        #expect(dev.ipAddress == nil)
        #expect(!dev.details.contains { $0.label == "Host usage" })
        #expect(dev.resources.cpus == 4)

        let booting = records[2]
        #expect(booting.state == .starting)
        #expect(!booting.capabilities.canEditCPUs, "no editing while the state is in flux")
        #expect(booting.resources == VMResources(), "no info entry, so no resources are invented")
    }

    @Test func attributedProcessSuppressesTheNote() throws {
        let list = [MultipassVMParsing.ListedInstance(name: "primary", status: "Running")]
        let process = VMHostProcess(pid: 9, parentPID: 1, name: "qemu-system-aarch64", arguments: ["file=/x/vault/instances/primary/a.img"])
        let records = MultipassVMParsing.records(list: list, info: [:], processes: [process])
        #expect(records.first?.hostProcessIDs == [9])
        #expect(records.first?.details.contains { $0.label == "Host usage" } == false)
    }

    @Test func commandLines() {
        #expect(MultipassVMParsing.listArguments == ["list", "--format", "json"])
        #expect(MultipassVMParsing.infoArguments(names: ["a", "b"], skipRuntimeInformation: false) == ["info", "--format", "json", "a", "b"])
        #expect(MultipassVMParsing.infoArguments(names: ["a"], skipRuntimeInformation: true) == ["info", "--format", "json", "--no-runtime-information", "a"])
        #expect(MultipassVMParsing.actionCommands(.start, instance: "x") == [["start", "x"]])
        #expect(MultipassVMParsing.actionCommands(.stop, instance: "x") == [["stop", "x"]])
        #expect(MultipassVMParsing.actionCommands(.restart, instance: "x") == [["restart", "x"]])
    }

    private let gib: UInt64 = 1_073_741_824

    @Test func setCommandsOnlyForChangedValues() throws {
        let current = VMResources(cpus: 2, memoryBytes: 1 * gib, diskBytes: 5 * gib)
        let requested = VMResources(cpus: 4, memoryBytes: 4 * gib, diskBytes: 5 * gib)
        let commands = try MultipassVMParsing.setCommands(instance: "primary", current: current, requested: requested).get()
        #expect(commands == [["set", "local.primary.cpus=4"], ["set", "local.primary.memory=4096M"]])
    }

    @Test func setCommandsGrowDiskAndRoundUp() throws {
        let current = VMResources(cpus: 2, memoryBytes: gib, diskBytes: 5 * gib)
        let requested = VMResources(diskBytes: 20 * gib + 1)
        let commands = try MultipassVMParsing.setCommands(instance: "dev", current: current, requested: requested).get()
        #expect(commands == [["set", "local.dev.disk=20481M"]])
    }

    @Test func setCommandsNothingToDo() throws {
        let current = VMResources(cpus: 2, memoryBytes: gib, diskBytes: 5 * gib)
        #expect(try MultipassVMParsing.setCommands(instance: "x", current: current, requested: current).get().isEmpty)
        #expect(try MultipassVMParsing.setCommands(instance: "x", current: current, requested: VMResources()).get().isEmpty)
    }

    @Test func setCommandsValidate() {
        let current = VMResources(cpus: 2, memoryBytes: gib, diskBytes: 5 * gib)
        #expect(MultipassVMParsing.setCommands(instance: "x", current: current, requested: VMResources(cpus: 0)) == .failure(.invalidCPUCount))
        #expect(MultipassVMParsing.setCommands(instance: "x", current: current, requested: VMResources(memoryBytes: 256 * 1_048_576)) == .failure(.memoryBelowMinimum))
        #expect(MultipassVMParsing.setCommands(instance: "x", current: current, requested: VMResources(diskBytes: 2 * gib)) == .failure(.diskCannotShrink))
        #expect(MultipassVMParsing.setCommands(instance: "x", current: current, requested: VMResources(diskBytes: 512 * 1_048_576)) == .failure(.diskBelowMinimum))
    }
}
