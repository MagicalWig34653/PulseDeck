import Foundation
import Testing
@testable import PulseDeckCore

@Suite("Podman machine parsing")
struct VMPodmanTests {
    private let image = "/Users/lino/.local/share/containers/podman/machine/applehv/podman-machine-default-arm64.raw"

    // Go's encoding/json output of vmconfigs.MachineConfig (field names from pkg/machine/vmconfigs/config.go).
    private var configJSON: String {
        """
        {
         "Created": "2025-03-01T10:15:43.123456+01:00",
         "GvProxy": {"GvProxy": {}},
         "HostUser": {"Rootful": false, "UID": 501, "HostUserModified": false},
         "LastUp": "2025-03-02T08:00:00.5Z",
         "Mounts": [{"OriginalInput": "/Users:/Users", "ReadOnly": false, "Source": "/Users", "Tag": "a1b2", "Target": "/Users", "Type": "virtiofs", "VSockNumber": null}],
         "Name": "podman-machine-default",
         "Resources": {"CPUs": 5, "DiskSize": 100, "Memory": 2048, "USBs": []},
         "SSH": {"IdentityPath": "/Users/lino/.local/share/containers/podman/machine/machine", "Port": 51122, "RemoteUsername": "core"},
         "Version": 1,
         "Swap": 0,
         "ImagePath": {"Path": "\(image)"},
         "AppleHypervisor": {"Vfkit": {"Endpoint": "http://localhost:51044", "Rosetta": true}},
         "Starting": false,
         "Rosetta": true,
         "Ansible": null,
         "ImportNativeCA": false
        }
        """
    }

    private func machine(starting: Bool = false) throws -> PodmanVMParsing.Machine {
        var machine = try #require(PodmanVMParsing.parseMachine(Data(configJSON.utf8), provider: "applehv", fileName: "podman-machine-default.json"))
        machine.starting = starting
        return machine
    }

    private func vfkit(pid: Int32, disk: String) -> VMHostProcess {
        VMHostProcess(pid: pid, parentPID: 1, name: "vfkit", executablePath: "/opt/homebrew/bin/vfkit", arguments: [
            "--cpus", "5", "--memory", "2048", "--restful-uri", "http://localhost:51044",
            "--device", "virtio-blk,path=\(disk)", "--device", "virtio-rng",
        ])
    }

    @Test func parsesConfig() throws {
        let machine = try machine()
        #expect(machine.name == "podman-machine-default")
        #expect(machine.provider == "applehv")
        #expect(machine.cpus == 5)
        #expect(machine.memoryMiB == 2048)
        #expect(machine.diskGiB == 100)
        #expect(machine.rootful == false)
        #expect(machine.starting == false)
        #expect(machine.imagePaths == [image])
    }

    @Test func symlinkedImageIsKept() throws {
        let json = #"{"Name": "m", "ImagePath": {"Path": "/long/path.raw", "symlink": "/tmp/short.raw"}}"#
        let machine = try #require(PodmanVMParsing.parseMachine(Data(json.utf8), provider: "libkrun", fileName: "m.json"))
        #expect(machine.imagePaths == ["/long/path.raw", "/tmp/short.raw"])
        #expect(machine.cpus == nil && machine.memoryMiB == nil && machine.diskGiB == nil)
    }

    @Test func fallsBackToFileNameAndRejectsGarbage() {
        let named = PodmanVMParsing.parseMachine(Data("{}".utf8), provider: "qemu", fileName: "dev.json")
        #expect(named?.name == "dev")
        #expect(PodmanVMParsing.parseMachine(Data("nope".utf8), provider: "qemu", fileName: "x.json") == nil)
        #expect(PodmanVMParsing.parseMachine(Data("[]".utf8), provider: "qemu", fileName: "x.json") == nil)
    }

    @Test func matchesHypervisorByDiskImage() throws {
        let machine = try machine()
        let other = "/Users/lino/.local/share/containers/podman/machine/applehv/second-arm64.raw"
        let processes = [
            vfkit(pid: 700, disk: image),
            vfkit(pid: 701, disk: other),
            VMHostProcess(pid: 702, parentPID: 1, name: "gvproxy", arguments: [image]),
            vfkit(pid: 703, disk: image + ".bak"),
        ]
        #expect(PodmanVMParsing.hostProcessIDs(machine: machine, processes: processes) == [700])
    }

    @Test func runningStoppedStartingAndUnknown() throws {
        let stopped = PodmanVMParsing.records(machines: [try machine()], processes: [])
        #expect(stopped.first?.state == .stopped)
        #expect(stopped.first?.hostProcessIDs.isEmpty == true)

        let running = PodmanVMParsing.records(machines: [try machine()], processes: [vfkit(pid: 700, disk: image)])
        #expect(running.first?.state == .running)
        #expect(running.first?.hostProcessIDs == [700])

        let starting = PodmanVMParsing.records(machines: [try machine(starting: true)], processes: [vfkit(pid: 700, disk: image)])
        #expect(starting.first?.state == .starting)

        // "Starting" left over from a crashed start must not matter without a process.
        let stale = PodmanVMParsing.records(machines: [try machine(starting: true)], processes: [])
        #expect(stale.first?.state == .stopped)

        let unreadable = PodmanVMParsing.records(machines: [try machine()], processes: [VMHostProcess(pid: 9, parentPID: 1, name: "vfkit")])
        #expect(unreadable.first?.state == .unknown)
        #expect(unreadable.first?.details.contains { $0.label == "State" } == true)
    }

    @Test func recordFields() throws {
        let record = try #require(PodmanVMParsing.records(machines: [try machine()], processes: []).first)
        #expect(record.nativeID == "applehv/podman-machine-default")
        #expect(record.resources == VMResources(cpus: 5, memoryBytes: 2048 * 1_048_576, diskBytes: 100 * 1_073_741_824))
        #expect(record.details.contains { $0.label == "Hypervisor" && $0.value.contains("vfkit") })
        #expect(record.details.contains { $0.label == "Mode" && $0.value == "Rootless" })
        #expect(record.capabilities.canEditDisk && record.capabilities.editRequiresStopped && record.capabilities.diskCanOnlyGrow)
    }

    @Test func highestCellarVersion() {
        #expect(PodmanVMParsing.highestVersion(of: ["5.4.2", "5.10.0", "5.9.9", ".metadata"]) == "5.10.0")
        #expect(PodmanVMParsing.highestVersion(of: ["10.1.0_1", "9.2.0"]) == "10.1.0_1")
        #expect(PodmanVMParsing.highestVersion(of: [".DS_Store"]) == nil)
        #expect(PodmanVMParsing.highestVersion(of: []) == nil)
    }

    @Test func actionCommands() {
        #expect(PodmanVMParsing.actionCommands(.start, machine: "m") == [["machine", "start", "m"]])
        #expect(PodmanVMParsing.actionCommands(.stop, machine: "m") == [["machine", "stop", "m"]])
        #expect(PodmanVMParsing.actionCommands(.restart, machine: "m") == [["machine", "stop", "m"], ["machine", "start", "m"]])
    }

    private let mib: UInt64 = 1_048_576
    private let gib: UInt64 = 1_073_741_824

    @Test func setCommandChangesOnlyDifferences() throws {
        let current = VMResources(cpus: 5, memoryBytes: 2048 * mib, diskBytes: 100 * gib)
        let requested = VMResources(cpus: 8, memoryBytes: 4096 * mib, diskBytes: 150 * gib)
        let commands = try PodmanVMParsing.setCommands(machine: "dev", current: current, requested: requested).get()
        #expect(commands == [["machine", "set", "--cpus", "8", "--memory", "4096", "--disk-size", "150", "dev"]])

        let memoryOnly = try PodmanVMParsing.setCommands(machine: "dev", current: current, requested: VMResources(cpus: 5, memoryBytes: 3072 * mib, diskBytes: 100 * gib)).get()
        #expect(memoryOnly == [["machine", "set", "--memory", "3072", "dev"]])
    }

    @Test func diskRulesFollowPodmansWholeGiB() throws {
        let current = VMResources(diskBytes: 100 * gib)
        #expect(PodmanVMParsing.setCommands(machine: "d", current: current, requested: VMResources(diskBytes: 90 * gib)) == .failure(.diskMustGrow))
        // 100 GiB + 1 byte rounds up to 101 GiB, which is a real growth.
        #expect(try PodmanVMParsing.setCommands(machine: "d", current: current, requested: VMResources(diskBytes: 100 * gib + 1)).get() == [["machine", "set", "--disk-size", "101", "d"]])
        // Same whole GiB: podman would reject it, so nothing is run.
        #expect(try PodmanVMParsing.setCommands(machine: "d", current: VMResources(diskBytes: 100 * gib + 5), requested: VMResources(diskBytes: 100 * gib)).get().isEmpty)
    }

    @Test func invalidCPUsAndNoChange() throws {
        let current = VMResources(cpus: 2, memoryBytes: 2048 * mib, diskBytes: 20 * gib)
        #expect(PodmanVMParsing.setCommands(machine: "d", current: current, requested: VMResources(cpus: 0)) == .failure(.invalidCPUCount))
        #expect(try PodmanVMParsing.setCommands(machine: "d", current: current, requested: current).get().isEmpty)
    }
}
