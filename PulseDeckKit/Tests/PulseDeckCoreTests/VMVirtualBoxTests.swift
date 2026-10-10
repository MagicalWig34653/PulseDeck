import Foundation
import Testing
@testable import PulseDeckCore

@Suite("VirtualBox parsing")
struct VMVirtualBoxTests {
    // Structure of ~/Library/VirtualBox/VirtualBox.xml (MachineRegistry as in VirtualBox's samples/real files).
    static let registry = """
    <?xml version="1.0"?>
    <VirtualBox xmlns="http://www.virtualbox.org/" version="1.12-macosx">
      <Global>
        <ExtraData>
          <ExtraDataItem name="GUI/LastItemSelected" value="m=dev"/>
        </ExtraData>
        <MachineRegistry>
          <MachineEntry uuid="{11742093-a8fa-4189-a88c-afc4cb7c70a6}" src="/Users/me/VirtualBox VMs/dev/dev.vbox"/>
          <MachineEntry uuid="{81ae80b4-2507-4fe8-bed8-33f14920d301}" src="Machines/%7B81ae80b4-2507-4fe8-bed8-33f14920d301%7D.xml"/>
        </MachineRegistry>
      </Global>
    </VirtualBox>
    """

    static let vbox = """
    <?xml version="1.0"?>
    <VirtualBox xmlns="http://www.virtualbox.org/" version="1.19-macosx">
      <Machine uuid="{11742093-a8fa-4189-a88c-afc4cb7c70a6}" name="dev" OSType="Ubuntu_64" snapshotFolder="Snapshots" lastStateChange="2026-10-01T10:00:00Z">
        <MediaRegistry>
          <HardDisks>
            <HardDisk uuid="{aaaaaaaa-0000-0000-0000-000000000001}" location="dev.vdi" format="VDI" type="Normal">
              <HardDisk uuid="{aaaaaaaa-0000-0000-0000-000000000002}" location="Snapshots/{diff}.vdi" format="VDI"/>
            </HardDisk>
          </HardDisks>
          <DVDImages>
            <Image uuid="{bbbbbbbb-0000-0000-0000-000000000001}" location="/Users/me/ubuntu.iso"/>
          </DVDImages>
        </MediaRegistry>
        <Hardware>
          <CPU count="2">
            <PAE enabled="true"/>
          </CPU>
          <Memory RAMSize="4096"/>
        </Hardware>
        <StorageControllers>
          <StorageController name="SATA" type="AHCI" PortCount="2">
            <AttachedDevice type="HardDisk" hotpluggable="false" port="0" device="0">
              <Image uuid="{aaaaaaaa-0000-0000-0000-000000000002}"/>
            </AttachedDevice>
            <AttachedDevice passthrough="false" type="DVD" hotpluggable="false" port="1" device="0">
              <Image uuid="{bbbbbbbb-0000-0000-0000-000000000001}"/>
            </AttachedDevice>
          </StorageController>
        </StorageControllers>
        <Snapshot uuid="{cccccccc-0000-0000-0000-000000000001}" name="old">
          <Hardware>
            <CPU count="1"/>
            <Memory RAMSize="1024"/>
          </Hardware>
        </Snapshot>
      </Machine>
    </VirtualBox>
    """

    @Test func parsesRegistry() {
        let entries = VirtualBoxParsing.registryEntries(Data(Self.registry.utf8), virtualBoxHome: "/Users/me/Library/VirtualBox")
        #expect(entries.count == 2)
        #expect(entries[0] == .init(uuid: "{11742093-a8fa-4189-a88c-afc4cb7c70a6}", path: "/Users/me/VirtualBox VMs/dev/dev.vbox"))
        #expect(entries[1].path == "/Users/me/Library/VirtualBox/Machines/{81ae80b4-2507-4fe8-bed8-33f14920d301}.xml")
        #expect(VirtualBoxParsing.registryEntries(Data("nonsense".utf8), virtualBoxHome: "/").isEmpty)
    }

    @Test func parsesMachineIgnoringSnapshotHardware() throws {
        let config = try #require(VirtualBoxParsing.parseMachine(Data(Self.vbox.utf8), machineFolder: "/Users/me/VirtualBox VMs/dev"))
        #expect(config.name == "dev")
        #expect(config.osType == "Ubuntu_64")
        #expect(config.cpus == 2)
        #expect(config.memoryMiB == 4096)
        #expect(!config.hasSavedState)
        // The attached image is the snapshot's differencing disk; only HardDisk devices count (not the ISO).
        #expect(config.diskPaths == ["/Users/me/VirtualBox VMs/dev/Snapshots/{diff}.vdi"])
    }

    @Test func detectsSavedState() throws {
        let saved = Self.vbox.replacingOccurrences(of: "snapshotFolder=\"Snapshots\"", with: "snapshotFolder=\"Snapshots\" stateFile=\"Snapshots/2026-10-01T10-00-00-000000000Z.sav\"")
        let config = try #require(VirtualBoxParsing.parseMachine(Data(saved.utf8), machineFolder: "/m"))
        #expect(config.hasSavedState)
        #expect(VirtualBoxParsing.makeRecord(config: config, vboxPath: "/m/dev.vbox", diskBytes: nil, processes: []).state == .suspended)
    }

    @Test func mapsOSTypes() {
        #expect(VirtualBoxParsing.guestInfo(osType: "Ubuntu_64") == ("Linux", "x86_64"))
        #expect(VirtualBoxParsing.guestInfo(osType: "Windows11_64") == ("Windows", "x86_64"))
        #expect(VirtualBoxParsing.guestInfo(osType: "MacOS_arm64") == ("macOS", "arm64"))
        #expect(VirtualBoxParsing.guestInfo(osType: "Debian_arm64") == ("Linux", "arm64"))
        #expect(VirtualBoxParsing.guestInfo(osType: "Other") == (nil, nil))
        #expect(VirtualBoxParsing.guestInfo(osType: nil) == (nil, nil))
    }

    // Command lines as recorded by an EDR on macOS (Vagrant-created VM).
    @Test func attributesVMProcessesByStartvm() {
        let uuid = "{11742093-a8fa-4189-a88c-afc4cb7c70a6}"
        let processes = [
            VMHostProcess(pid: 1, parentPID: 1, name: "VBoxHeadless", arguments: ["--comment", "dev", "--startvm", "11742093-a8fa-4189-a88c-afc4cb7c70a6", "--vrde", "config"]),
            VMHostProcess(pid: 2, parentPID: 1, name: "VirtualBoxVM", arguments: ["--comment", "dev", "--startvm", "11742093-A8FA-4189-A88C-AFC4CB7C70A6", "--no-startvm-errormsgbox"]),
            VMHostProcess(pid: 3, parentPID: 1, name: "VBoxHeadless", arguments: ["--comment", "x", "--startvm", "99999999-a8fa-4189-a88c-afc4cb7c70a6"]),
            VMHostProcess(pid: 4, parentPID: 1, name: "VBoxSVC", arguments: ["--startvm", "11742093-a8fa-4189-a88c-afc4cb7c70a6"]),
            VMHostProcess(pid: 5, parentPID: 1, name: "VBoxHeadless", arguments: ["--startvm", "dev"]),
        ]
        #expect(VirtualBoxParsing.hostProcesses(forUUID: uuid, name: "dev", in: processes).map(\.pid) == [1, 2, 5])
        #expect(VirtualBoxParsing.hostProcesses(forUUID: uuid, name: "other", in: processes).map(\.pid) == [1, 2])
    }

    @Test func recordRunning() throws {
        let config = try #require(VirtualBoxParsing.parseMachine(Data(Self.vbox.utf8), machineFolder: "/m"))
        let process = VMHostProcess(pid: 8, parentPID: 1, name: "VBoxHeadless", arguments: ["--startvm", "11742093-a8fa-4189-a88c-afc4cb7c70a6"])
        let record = VirtualBoxParsing.makeRecord(config: config, vboxPath: "/m/dev.vbox", diskBytes: 25 * 1_073_741_824, processes: [process])
        #expect(record.state == .running)
        #expect(record.hostProcessIDs == [8])
        #expect(record.resources == VMResources(cpus: 2, memoryBytes: 4096 * 1_048_576, diskBytes: 25 * 1_073_741_824))
        #expect(record.guestOS == "Linux")
        #expect(record.capabilities.canEditCPUs && record.capabilities.canEditMemory && !record.capabilities.canEditDisk)
        #expect(VirtualBoxParsing.makeRecord(config: config, vboxPath: "/m/dev.vbox", diskBytes: nil, processes: []).state == .stopped)
    }

    @Test func commandLines() {
        let id = "{11742093-a8fa-4189-a88c-afc4cb7c70a6}"
        #expect(VirtualBoxParsing.startArguments(uuid: id) == ["startvm", id, "--type", "headless"])
        #expect(VirtualBoxParsing.stopArguments(uuid: id) == ["controlvm", id, "acpipowerbutton"])
        #expect(VirtualBoxParsing.restartArguments(uuid: id) == ["controlvm", id, "reset"])
        let current = VMResources(cpus: 2, memoryBytes: 4096 * 1_048_576)
        #expect(VirtualBoxParsing.modifyArguments(uuid: id, new: current, current: current) == nil)
        #expect(VirtualBoxParsing.modifyArguments(uuid: id, new: VMResources(cpus: 4, memoryBytes: 8192 * 1_048_576), current: current) == ["modifyvm", id, "--cpus", "4", "--memory", "8192"])
        #expect(VirtualBoxParsing.modifyArguments(uuid: id, new: VMResources(memoryBytes: 2048 * 1_048_576), current: current) == ["modifyvm", id, "--memory", "2048"])
    }
}

@Suite("Disk image headers")
struct HypervisorDiskHeaderTests {
    @Test func qcow2() {
        var header = [UInt8](repeating: 0, count: 104)
        header.replaceSubrange(0..<4, with: [0x51, 0x46, 0x49, 0xFB])
        header[7] = 3 // version
        let size: UInt64 = 64 * 1_073_741_824
        for index in 0..<8 { header[24 + index] = UInt8((size >> (8 * UInt64(7 - index))) & 0xFF) } // big endian
        #expect(HypervisorDiskHeader.virtualSize(header: Data(header)) == size)
    }

    @Test func vdi() {
        var header = [UInt8](repeating: 0, count: HypervisorDiskHeader.headerLength)
        let text = Array("<<< Oracle VM VirtualBox Disk Image >>>\n".utf8)
        header.replaceSubrange(0..<text.count, with: text)
        header.replaceSubrange(0x40..<0x44, with: [0x7F, 0x10, 0xDA, 0xBE]) // 0xBEDA107F little endian
        let size: UInt64 = 25 * 1_073_741_824
        for index in 0..<8 { header[0x170 + index] = UInt8((size >> (8 * UInt64(index))) & 0xFF) }
        #expect(HypervisorDiskHeader.virtualSize(header: Data(header)) == size)
    }

    @Test func unknownAndShortInputs() {
        #expect(HypervisorDiskHeader.virtualSize(header: Data()) == nil)
        #expect(HypervisorDiskHeader.virtualSize(header: Data(repeating: 0, count: 512)) == nil)
        #expect(HypervisorDiskHeader.vmdkDescriptorSize("not a descriptor") == nil)
        #expect(HypervisorDiskHeader.vmdkDescriptorSize("# Disk DescriptorFile\nversion=1\n") == nil)
    }
}
