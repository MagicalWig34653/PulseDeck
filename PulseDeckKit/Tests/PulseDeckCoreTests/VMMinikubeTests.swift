import Foundation
import Testing
@testable import PulseDeckCore

@Suite("minikube profile parsing")
struct VMMinikubeTests {
    // Subset of ~/.minikube/profiles/<name>/config.json (ClusterConfig in pkg/minikube/config/types.go).
    private func configJSON(driver: String, nodes: String? = nil) -> String {
        let nodes = nodes ?? #"[{"Name": "", "IP": "192.168.105.4", "Port": 8443, "KubernetesVersion": "v1.32.0", "ContainerRuntime": "docker", "ControlPlane": true, "Worker": true}]"#
        return """
        {
         "Name": "minikube",
         "KeepContext": false,
         "MinikubeISO": "https://storage.googleapis.com/minikube/iso/minikube-v1.35.0-arm64.iso",
         "KicBaseImage": "gcr.io/k8s-minikube/kicbase:v0.0.46",
         "Memory": 4000,
         "CPUs": 2,
         "DiskSize": 20000,
         "Driver": "\(driver)",
         "KubernetesConfig": {"KubernetesVersion": "v1.32.0", "ClusterName": "minikube", "Namespace": "default", "ContainerRuntime": "docker"},
         "Nodes": \(nodes),
         "Addons": {"storage-provisioner": true}
        }
        """
    }

    private func profile(driver: String, directory: String = "minikube", nodes: String? = nil) throws -> MinikubeVMParsing.Profile {
        try #require(MinikubeVMParsing.parseProfile(Data(configJSON(driver: driver, nodes: nodes).utf8), directoryName: directory))
    }

    private func vfkit(pid: Int32, machine: String = "minikube") -> VMHostProcess {
        VMHostProcess(pid: pid, parentPID: 1, name: "vfkit", arguments: [
            "--memory", "4000", "--cpus", "2",
            "--restful-uri", "unix:///Users/lino/.minikube/machines/\(machine)/vfkit.sock",
            "--device", "virtio-blk,path=/Users/lino/.minikube/machines/\(machine)/disk.img",
        ])
    }

    @Test func parsesProfile() throws {
        let profile = try profile(driver: "vfkit")
        #expect(profile.name == "minikube")
        #expect(profile.driver == "vfkit")
        #expect(profile.cpus == 2)
        #expect(profile.memoryMiB == 4000)
        #expect(profile.diskMiB == 20000)
        #expect(profile.kubernetesVersion == "v1.32.0")
        #expect(profile.containerRuntime == "docker")
        #expect(profile.machineNames == ["minikube"])
        #expect(profile.controlPlaneIP == "192.168.105.4")
    }

    @Test func rejectsNonClusterConfigs() {
        #expect(MinikubeVMParsing.parseProfile(Data("{}".utf8), directoryName: "x") == nil)
        #expect(MinikubeVMParsing.parseProfile(Data("garbage".utf8), directoryName: "x") == nil)
    }

    @Test func machineNamesOfMultiNodeProfiles() throws {
        let nodes = #"[{"Name": "", "IP": "192.168.105.4", "ControlPlane": true}, {"Name": "m02", "IP": "192.168.105.5", "ControlPlane": false, "Worker": true}]"#
        let profile = try profile(driver: "vfkit", directory: "multi", nodes: nodes)
        #expect(profile.name == "multi")
        // The directory name is what `-p` takes; the config's own Name drives machine names.
        #expect(profile.machineNames == ["minikube", "minikube-m02"])
    }

    @Test func classifiesDrivers() {
        #expect(MinikubeVMParsing.driverKind("vfkit") == .virtualMachine)
        #expect(MinikubeVMParsing.driverKind("qemu2") == .virtualMachine)
        #expect(MinikubeVMParsing.driverKind("hyperkit") == .virtualMachine)
        #expect(MinikubeVMParsing.driverKind("virtualbox") == .otherVirtualMachine)
        #expect(MinikubeVMParsing.driverKind("docker") == .container)
        #expect(MinikubeVMParsing.driverKind("podman") == .container)
        #expect(MinikubeVMParsing.driverKind("none") == .notAVirtualMachine)
        #expect(MinikubeVMParsing.driverKind("ssh") == .notAVirtualMachine)
    }

    @Test func pidFiles() {
        #expect(MinikubeVMParsing.pidFileName(forDriver: "vfkit") == "vfkit.pid")
        #expect(MinikubeVMParsing.pidFileName(forDriver: "qemu2") == "qemu.pid")
        #expect(MinikubeVMParsing.pidFileName(forDriver: "docker") == nil)
        #expect(MinikubeVMParsing.parsePID("4242\n") == 4242)
        #expect(MinikubeVMParsing.parsePID("  17 ") == 17)
        #expect(MinikubeVMParsing.parsePID("abc") == nil)
        #expect(MinikubeVMParsing.parsePID("0") == nil)
        #expect(MinikubeVMParsing.parsePID("") == nil)
    }

    @Test func vfkitProfileStates() throws {
        let profile = try profile(driver: "vfkit")

        let stopped = try #require(MinikubeVMParsing.records(profiles: [profile], pidFilePIDs: [:], processes: []).first)
        #expect(stopped.state == .stopped)
        #expect(stopped.ipAddress == nil, "the stored IP of a stopped VM is not shown")
        #expect(stopped.capabilities.canStart && stopped.capabilities.canStop && !stopped.capabilities.canEditAnything)

        let byPath = try #require(MinikubeVMParsing.records(profiles: [profile], pidFilePIDs: [:], processes: [vfkit(pid: 800)]).first)
        #expect(byPath.state == .running)
        #expect(byPath.hostProcessIDs == [800])
        #expect(byPath.ipAddress == "192.168.105.4")

        let byPidFile = try #require(MinikubeVMParsing.records(profiles: [profile], pidFilePIDs: ["minikube": 801], processes: [VMHostProcess(pid: 801, parentPID: 1, name: "vfkit")]).first)
        #expect(byPidFile.state == .running)
        #expect(byPidFile.hostProcessIDs == [801])
    }

    @Test func recycledPidAndForeignProcessesDoNotMatch() throws {
        let profile = try profile(driver: "vfkit")
        let recycled = VMHostProcess(pid: 900, parentPID: 1, name: "Safari", arguments: ["/Users/lino/.minikube/machines/minikube/x"])
        let other = vfkit(pid: 901, machine: "other")
        let records = MinikubeVMParsing.records(profiles: [profile], pidFilePIDs: ["minikube": 900], processes: [recycled, other])
        #expect(records.first?.state == .stopped)
        #expect(records.first?.hostProcessIDs.isEmpty == true)

        // "minikube" must not claim the machine directory of "minikube-m02".
        let sibling = vfkit(pid: 902, machine: "minikube-m02")
        #expect(MinikubeVMParsing.records(profiles: [profile], pidFilePIDs: [:], processes: [sibling]).first?.state == .stopped)
    }

    @Test func multiNodeProfileCollectsAllNodeProcesses() throws {
        let nodes = #"[{"Name": "", "IP": "192.168.105.4", "ControlPlane": true}, {"Name": "m02", "IP": "192.168.105.5"}]"#
        let profile = try profile(driver: "vfkit", nodes: nodes)
        let record = try #require(MinikubeVMParsing.records(profiles: [profile], pidFilePIDs: [:], processes: [vfkit(pid: 11), vfkit(pid: 12, machine: "minikube-m02")]).first)
        #expect(record.hostProcessIDs == [11, 12])
        #expect(record.details.contains { $0.label == "Nodes" })
    }

    @Test func unreadableHypervisorMeansUnknown() throws {
        let profile = try profile(driver: "vfkit")
        let record = try #require(MinikubeVMParsing.records(profiles: [profile], pidFilePIDs: [:], processes: [VMHostProcess(pid: 5, parentPID: 1, name: "vfkit")]).first)
        #expect(record.state == .unknown)
    }

    @Test func containerDriverIsReadOnly() throws {
        let profile = try profile(driver: "docker")
        let record = try #require(MinikubeVMParsing.records(profiles: [profile], pidFilePIDs: [:], processes: []).first)
        #expect(record.state == .unknown)
        #expect(record.capabilities == .readOnly)
        #expect(record.resources.diskBytes == nil)
        #expect(record.resources.cpus == 2)
        #expect(record.details.contains { $0.value.contains("Container driver") })
    }

    @Test func otherVMDriversAreReadOnlyWithUnknownState() throws {
        let record = try #require(MinikubeVMParsing.records(profiles: [try profile(driver: "virtualbox")], pidFilePIDs: [:], processes: []).first)
        #expect(record.state == .unknown)
        #expect(record.capabilities == .readOnly)
        #expect(record.details.contains { $0.label == "Resources" && $0.value.contains("delete") })
    }

    @Test func profilesWithoutAVMAreOmitted() throws {
        #expect(MinikubeVMParsing.records(profiles: [try profile(driver: "none")], pidFilePIDs: [:], processes: []).isEmpty)
    }

    @Test func resourcesConvertToBytes() throws {
        let record = try #require(MinikubeVMParsing.records(profiles: [try profile(driver: "qemu2")], pidFilePIDs: [:], processes: []).first)
        #expect(record.resources == VMResources(cpus: 2, memoryBytes: 4000 * 1_048_576, diskBytes: 20000 * 1_048_576))
    }

    @Test func profileNameFromVMID() {
        #expect(MinikubeVMParsing.profileName(fromVMID: "minikube:dev") == "dev")
        #expect(MinikubeVMParsing.profileName(fromVMID: "minikube:a:b") == "a:b")
        #expect(MinikubeVMParsing.profileName(fromVMID: "dev") == "dev")
    }

    @Test func actionCommands() {
        #expect(MinikubeVMParsing.actionCommands(.start, profile: "p") == [["start", "-p", "p"]])
        #expect(MinikubeVMParsing.actionCommands(.stop, profile: "p") == [["stop", "-p", "p"]])
        #expect(MinikubeVMParsing.actionCommands(.restart, profile: "p") == [["stop", "-p", "p"], ["start", "-p", "p"]])
    }
}
