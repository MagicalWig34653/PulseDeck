import Foundation
import Testing
@testable import PulseDeckCore

@Suite("Vagrant machine index parsing")
struct VMVagrantTests {
    // Structure documented in lib/vagrant/machine_index.rb.
    private let indexJSON = """
    {
      "version": 1,
      "machines": {
        "a1b2c3d4e5f60718293a4b5c6d7e8f90": {
          "local_data_path": "/Users/lino/code/web/.vagrant",
          "name": "default",
          "provider": "virtualbox",
          "state": "running",
          "vagrantfile_name": null,
          "vagrantfile_path": "/Users/lino/code/web",
          "updated_at": null,
          "extra_data": {"box": {"name": "ubuntu/jammy64", "provider": "virtualbox", "version": "20240101.0.0"}}
        },
        "0f9e8d7c6b5a49382716f5e4d3c2b1a0": {
          "local_data_path": "/Users/lino/code/api/.vagrant",
          "name": "db",
          "provider": "vmware_desktop",
          "architecture": "arm64",
          "state": "poweroff",
          "vagrantfile_path": "/Users/lino/code/api",
          "extra_data": {}
        },
        "11112222333344445555666677778888": {
          "local_data_path": "/Users/lino/code/gone/.vagrant",
          "name": "default",
          "provider": "virtualbox",
          "state": "not_created",
          "vagrantfile_path": "/Users/lino/code/gone"
        },
        "99998888777766665555444433332222": {
          "local_data_path": "/Users/lino/code/dock/.vagrant",
          "name": "app",
          "provider": "docker",
          "state": "running",
          "vagrantfile_path": "/Users/lino/code/dock"
        }
      }
    }
    """

    private let web = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
    private let uuid = "5e2d6a52-7c10-4a35-9e1f-0123456789ab"

    private func entries() throws -> [VagrantVMParsing.IndexEntry] {
        try #require(VagrantVMParsing.parseIndex(Data(indexJSON.utf8)))
    }

    private func virtualBoxVM(pid: Int32, id: String) -> VMHostProcess {
        VMHostProcess(pid: pid, parentPID: 1, name: "VBoxHeadless", arguments: ["--comment", "web_default_1700000000000_12345", "--startvm", id, "--vrde", "config"])
    }

    @Test func parsesIndex() throws {
        let entries = try entries()
        #expect(entries.count == 4)
        let entry = try #require(entries.first { $0.id == web })
        #expect(entry.name == "default" && entry.provider == "virtualbox" && entry.state == "running")
        #expect(entry.vagrantfilePath == "/Users/lino/code/web")
        #expect(entry.providerIDFilePath == "/Users/lino/code/web/.vagrant/machines/default/virtualbox/id")
    }

    @Test func rejectsUnknownVersionsAndGarbage() {
        #expect(VagrantVMParsing.parseIndex(Data(#"{"version": 2, "machines": {}}"#.utf8)) == nil)
        #expect(VagrantVMParsing.parseIndex(Data(#"{"machines": {}}"#.utf8)) == nil)
        #expect(VagrantVMParsing.parseIndex(Data("???".utf8)) == nil)
        #expect(VagrantVMParsing.parseIndex(Data(#"{"version": 1}"#.utf8)) == nil)
        #expect(VagrantVMParsing.parseIndex(Data(#"{"version": 1, "machines": {}}"#.utf8))?.isEmpty == true)
    }

    @Test func mapsStates() {
        #expect(VagrantVMParsing.vmState(indexState: "running") == .running)
        #expect(VagrantVMParsing.vmState(indexState: "poweroff") == .stopped)
        #expect(VagrantVMParsing.vmState(indexState: "aborted") == .stopped)
        #expect(VagrantVMParsing.vmState(indexState: "saved") == .suspended)
        #expect(VagrantVMParsing.vmState(indexState: "paused") == .paused)
        #expect(VagrantVMParsing.vmState(indexState: "gurumeditation") == .unknown)
        #expect(VagrantVMParsing.vmState(indexState: "not_created") == nil)
    }

    @Test func recordsConfirmRunningThroughTheProcessTable() throws {
        let records = VagrantVMParsing.records(entries: try entries(), providerVMIDs: [web: uuid], processes: [virtualBoxVM(pid: 40, id: uuid)])
        #expect(records.count == 3, "not_created is omitted")
        let record = try #require(records.first { $0.nativeID == web })
        #expect(record.state == .running)
        #expect(record.hostProcessIDs == [40])
        #expect(record.name == "default (web)")
        #expect(record.capabilities.canStart && record.capabilities.canStop && record.capabilities.canRestart)
        #expect(!record.capabilities.canEditAnything)
        #expect(record.details.contains { $0.label == "Provider" && $0.value == "virtualbox" })
        #expect(record.details.contains { $0.label == "Vagrant ID" && $0.value == "a1b2c3d" })
    }

    @Test func staleRunningIndexIsReportedAsUnknown() throws {
        let records = VagrantVMParsing.records(entries: try entries(), providerVMIDs: [web: uuid], processes: [])
        let record = try #require(records.first { $0.nativeID == web })
        #expect(record.state == .unknown)
        #expect(record.hostProcessIDs.isEmpty)
        #expect(record.details.contains { $0.label == "State" && $0.value.contains("outdated") })
    }

    @Test func runningProcessOverridesAStalePoweroffIndex() throws {
        var entry = try #require(try entries().first { $0.id == web })
        entry.state = "poweroff"
        let record = try #require(VagrantVMParsing.records(entries: [entry], providerVMIDs: [web: uuid], processes: [virtualBoxVM(pid: 7, id: "{\(uuid.uppercased())}")]).first)
        #expect(record.state == .running)
        #expect(record.hostProcessIDs == [7])
    }

    @Test func stoppedAndUnattributedProviders() throws {
        let records = VagrantVMParsing.records(entries: try entries(), providerVMIDs: [:], processes: [])
        let db = try #require(records.first { $0.name.hasPrefix("db") })
        #expect(db.state == .stopped)
        #expect(db.architecture == "arm64")

        let docker = try #require(records.first { $0.name.hasPrefix("app") })
        #expect(docker.state == .running, "no way to verify the docker provider, so the index state is shown")
        #expect(docker.hostProcessIDs.isEmpty)
        #expect(docker.details.contains { $0.label == "State" && $0.value.contains("index") })
    }

    @Test func matchingNeedsTheMachineIdentifierOrDataDirectory() throws {
        let entry = try #require(try entries().first { $0.id == web })
        let other = "11111111-2222-3333-4444-555555555555"
        let processes = [
            virtualBoxVM(pid: 1, id: other),
            VMHostProcess(pid: 2, parentPID: 1, name: "VBoxManage", arguments: ["showvminfo", uuid]),
            VMHostProcess(pid: 3, parentPID: 1, name: "VirtualBoxVM", arguments: ["--startvm", uuid]),
        ]
        #expect(VagrantVMParsing.hostProcessIDs(entry: entry, providerVMID: uuid, processes: processes) == [3])
        #expect(VagrantVMParsing.hostProcessIDs(entry: entry, providerVMID: nil, processes: processes).isEmpty)
        // A short id is no safe identifier.
        #expect(VagrantVMParsing.hostProcessIDs(entry: entry, providerVMID: "abc", processes: [VMHostProcess(pid: 5, parentPID: 1, name: "VBoxHeadless", arguments: ["abc"])]).isEmpty)

        var vmware = entry
        vmware.provider = "vmware_desktop"
        let vmx = VMHostProcess(pid: 6, parentPID: 1, name: "vmware-vmx", arguments: ["-s", "vmx.stdio.keep=TRUE", "/Users/lino/code/web/.vagrant/machines/default/vmware_desktop/xyz/box.vmx"])
        #expect(VagrantVMParsing.hostProcessIDs(entry: vmware, providerVMID: nil, processes: [vmx]) == [6])
    }

    @Test func commands() {
        #expect(VagrantVMParsing.actionCommands(.start, id: "abc", currentState: .stopped) == [["up", "abc"]])
        #expect(VagrantVMParsing.actionCommands(.stop, id: "abc", currentState: .running) == [["halt", "abc"]])
        #expect(VagrantVMParsing.actionCommands(.restart, id: "abc", currentState: .running) == [["reload", "abc"]])
        #expect(VagrantVMParsing.actionCommands(.restart, id: "abc", currentState: .stopped) == [["up", "abc"]])
    }

    @Test func indexIDFromVMID() {
        #expect(VagrantVMParsing.indexID(fromVMID: "vagrant:a1b2") == "a1b2")
        #expect(VagrantVMParsing.indexID(fromVMID: "a1b2") == "a1b2")
    }

    @Test func providerIDFile() {
        #expect(VagrantVMParsing.parseProviderID("5e2d6a52-7c10\n") == "5e2d6a52-7c10")
        #expect(VagrantVMParsing.parseProviderID(" \n") == nil)
    }

    @Test func versionFromGemDirectories() {
        let names = ["vagrant-2.4.9", "vagrant-2.4.10", "vagrant_cloud-3.1.0", "vagrant-vmware-desktop-3.0.3", "vagrant-spec-0.0.1", "rake-13.0"]
        #expect(VagrantVMParsing.version(fromGemDirectoryNames: names) == "2.4.10")
        #expect(VagrantVMParsing.version(fromGemDirectoryNames: ["rake-13.0"]) == nil)
        #expect(VagrantVMParsing.version(fromGemDirectoryNames: []) == nil)
    }
}
