import Foundation
import Testing
@testable import PulseDeckCore

@Suite("Parallels parsing")
struct VMParallelsTests {
    // `prlctl list -a -i --json`, reduced to the keys PulseDeck reads (key names from the
    // VirtualMachine / VirtualMachineHardware models of Parallels' VS Code extension).
    static let listJSON = """
    [
      {
        "ID": "{a80d8491-d2bf-43c7-bea6-663fe5fcd5ab}",
        "Name": "Windows 11",
        "Description": "",
        "Type": "VM",
        "State": "running",
        "OS": "win-11",
        "Uptime": "00:12:44 (since 2026-10-09T08:00:00Z)",
        "Home": "/Users/me/Parallels/Windows 11.pvm/",
        "Hardware": {
          "cpu": { "cpus": 4, "auto": "off", "VT-x": true, "hotplug": false, "accl": "high", "mode": "64", "type": "ARM" },
          "memory": { "size": "8192Mb", "auto": "off", "hotplug": false },
          "video": { "size": "256Mb" },
          "hdd0": { "enabled": true, "port": "nvme:0", "image": "/Users/me/Parallels/Windows 11.pvm/harddisk1.hdd", "type": "expand", "size": "262144Mb", "online-compact": "on" },
          "cdrom0": { "enabled": true, "port": "sata:0", "image": "auto detect" },
          "net0": { "enabled": true, "type": "shared" }
        }
      },
      {
        "ID": "{0d9f6b0a-1111-4c39-8bd9-2f3a3b0c9e11}",
        "Name": "Ubuntu 24.04",
        "Type": "VM",
        "State": "suspended",
        "OS": "ubuntu",
        "Home": "/Users/me/Parallels/Ubuntu 24.04.pvm/",
        "Hardware": {
          "cpu": { "cpus": 2, "type": "ARM" },
          "memory": { "size": "4096Mb" },
          "hdd0": { "enabled": true, "image": "a.hdd", "size": "65536Mb" },
          "hdd1": { "enabled": true, "image": "b.hdd", "size": "1024Mb" }
        }
      },
      { "ID": "{template}", "Name": "tpl", "Type": "CT", "State": "stopped" }
    ]
    """

    @Test func parsesList() {
        let machines = ParallelsParsing.parseList(Self.listJSON)
        #expect(machines.map(\.name) == ["Windows 11", "Ubuntu 24.04"])
        let windows = machines[0]
        #expect(windows.uuid == "{a80d8491-d2bf-43c7-bea6-663fe5fcd5ab}")
        #expect(windows.cpus == 4)
        #expect(windows.memoryMiB == 8192)
        #expect(windows.diskMiB == 262_144)
        #expect(windows.hasEditableDisk)
        #expect(windows.architecture == "arm64")
        // Two enabled disks: no single "the" disk size, not editable.
        #expect(machines[1].diskMiB == nil)
        #expect(!machines[1].hasEditableDisk)
    }

    @Test func toleratesNoiseAndSingleObject() {
        let single = "Reading...\n{\"ID\":\"{x}\",\"Name\":\"n\",\"Type\":\"VM\",\"State\":\"stopped\"}"
        #expect(ParallelsParsing.parseList(single).map(\.name) == ["n"])
        #expect(ParallelsParsing.parseList("").isEmpty)
        #expect(ParallelsParsing.parseList("Failed to connect").isEmpty)
        #expect(ParallelsParsing.parseList("[1, 2]").isEmpty)
    }

    @Test func parsesSizes() {
        #expect(ParallelsParsing.mebibytes(from: "4096Mb") == 4096)
        #expect(ParallelsParsing.mebibytes(from: "64Gb") == 65_536)
        #expect(ParallelsParsing.mebibytes(from: " 2 G ") == 2048)
        #expect(ParallelsParsing.mebibytes(from: 512) == 512)
        #expect(ParallelsParsing.mebibytes(from: "lots") == nil)
        #expect(ParallelsParsing.mebibytes(from: nil) == nil)
    }

    @Test func mapsStatesAndGuests() {
        #expect(ParallelsParsing.state("running") == .running)
        #expect(ParallelsParsing.state("suspended") == .suspended)
        #expect(ParallelsParsing.state("paused") == .paused)
        #expect(ParallelsParsing.state("resuming") == .starting)
        #expect(ParallelsParsing.state("suspending") == .stopping)
        #expect(ParallelsParsing.state("weird") == .unknown)
        #expect(ParallelsParsing.state(nil) == .unknown)
        #expect(ParallelsParsing.guestOS("win-11") == "Windows")
        #expect(ParallelsParsing.guestOS("macos") == "macOS")
        #expect(ParallelsParsing.guestOS("ubuntu") == "Linux")
        #expect(ParallelsParsing.guestOS("other") == nil)
    }

    // Process line from a Parallels problem report:
    // prl_vm_app --vm-name 'OS X Mavericks' --uuid '{a80d8491-…}' --dir-uuid '{e04b39f8-…}' --log-dir …
    @Test func attributesPrlVmAppByUUID() {
        let uuid = "{a80d8491-d2bf-43c7-bea6-663fe5fcd5ab}"
        let processes = [
            VMHostProcess(pid: 71667, parentPID: 1, name: "prl_vm_app", arguments: ["--vm-name", "Windows 11", "--uuid", uuid.uppercased(), "--dir-uuid", "{e04b39f8-b849-41f8-94d9-749d02e02a50}", "--log-dir", "/Users/me/Parallels/Windows 11.pvm"]),
            VMHostProcess(pid: 71668, parentPID: 1, name: "prl_vm_app", arguments: ["--vm-name", "Other", "--uuid", "{00000000-0000-0000-0000-000000000000}"]),
            VMHostProcess(pid: 71669, parentPID: 1, name: "prl_client_app", arguments: ["--uuid", uuid]),
        ]
        #expect(ParallelsParsing.hostProcesses(forUUID: uuid, in: processes).map(\.pid) == [71667])
    }

    @Test func recordFromList() throws {
        let machine = try #require(ParallelsParsing.parseList(Self.listJSON).first)
        let process = VMHostProcess(pid: 5, parentPID: 1, name: "prl_vm_app", arguments: ["--uuid", machine.uuid])
        let record = ParallelsParsing.makeRecord(machine, processes: [process])
        #expect(record.state == .running)
        #expect(record.hostProcessIDs == [5])
        #expect(record.guestOS == "Windows")
        #expect(record.resources == VMResources(cpus: 4, memoryBytes: 8192 * 1_048_576, diskBytes: 262_144 * 1_048_576))
        #expect(record.capabilities.canEditDisk && record.capabilities.editRequiresStopped)
    }

    // config.pvs: structure of a real bundle (AlmaLinux Vagrant box template), shortened.
    static let pvs = """
    <?xml version="1.0" encoding="UTF-8"?>
    <ParallelsVirtualMachine dyn_lists="VirtualAppliance 0" schemaVersion="1.0">
       <AppVersion>26.3.2-57398</AppVersion>
       <Identification dyn_lists="">
          <VmUuid>{7c0ab1c2-3d4e-4f5a-8b6c-7d8e9f0a1b2c}</VmUuid>
          <VmType>0</VmType>
          <VmName>AlmaLinux 9</VmName>
       </Identification>
       <Settings dyn_lists="">
          <General dyn_lists="PrevOsNumber">
             <OsType>9</OsType>
             <OsNumber>2317</OsNumber>
          </General>
       </Settings>
       <Hardware dyn_lists="Fdd 0 CdRom 1 Hdd 2">
          <Cpu dyn_lists="">
             <Number>2</Number>
             <Mode>0</Mode>
          </Cpu>
          <Memory dyn_lists="">
             <RAM>4096</RAM>
             <RamAutoSizeEnabled>0</RamAutoSizeEnabled>
          </Memory>
          <CdRom id="0" dyn_lists=""><Enabled>1</Enabled><SystemName>/dev/cdrom</SystemName></CdRom>
          <Hdd id="1" dyn_lists="Partition 0">
             <Uuid>{11111111-2222-3333-4444-555555555555}</Uuid>
             <Enabled>1</Enabled>
             <SystemName>harddisk1.hdd</SystemName>
             <Size>65536</Size>
             <SizeOnDisk>1200</SizeOnDisk>
          </Hdd>
       </Hardware>
    </ParallelsVirtualMachine>
    """

    @Test func parsesConfigPVS() throws {
        let machine = try #require(ParallelsParsing.parsePVS(Data(Self.pvs.utf8), bundlePath: "/Users/me/Parallels/AlmaLinux 9.pvm"))
        #expect(machine.uuid == "{7c0ab1c2-3d4e-4f5a-8b6c-7d8e9f0a1b2c}")
        #expect(machine.name == "AlmaLinux 9")
        #expect(machine.cpus == 2)
        #expect(machine.memoryMiB == 4096)
        #expect(machine.diskMiB == 65_536)
        #expect(machine.state == nil)

        let stopped = ParallelsParsing.makeRecord(machine, processes: [])
        #expect(stopped.state == .stopped)
        #expect(stopped.guestOS == "Linux")
        #expect(!stopped.capabilities.canEditDisk) // device name unknown without prlctl
        let running = ParallelsParsing.makeRecord(machine, processes: [VMHostProcess(pid: 3, parentPID: 1, name: "prl_vm_app", arguments: ["--uuid", machine.uuid])])
        #expect(running.state == .running)
        #expect(ParallelsParsing.parsePVS(Data("<x/>".utf8), bundlePath: "/") == nil)
        #expect(ParallelsParsing.parsePVS(Data("<broken".utf8), bundlePath: "/") == nil)
    }

    @Test func commandLines() {
        #expect(ParallelsParsing.listArguments == ["list", "-a", "-i", "--json"])
        #expect(ParallelsParsing.arguments(for: .start, uuid: "{u}") == ["start", "{u}"])
        #expect(ParallelsParsing.arguments(for: .stop, uuid: "{u}") == ["stop", "{u}"])
        #expect(ParallelsParsing.arguments(for: .restart, uuid: "{u}") == ["restart", "{u}"])
    }

    @Test func setCommandsOnlyForChanges() {
        let current = VMResources(cpus: 4, memoryBytes: 8192 * 1_048_576, diskBytes: 262_144 * 1_048_576)
        #expect(ParallelsParsing.setCommands(uuid: "{u}", new: current, current: current).isEmpty)
        let commands = ParallelsParsing.setCommands(
            uuid: "{u}",
            new: VMResources(cpus: 6, memoryBytes: 16_384 * 1_048_576, diskBytes: 300_000 * 1_048_576),
            current: current
        )
        #expect(commands == [
            ["set", "{u}", "--cpus", "6"],
            ["set", "{u}", "--memsize", "16384"],
            ["set", "{u}", "--device-set", "hdd0", "--size", "300000"],
        ])
        // Shrinking is not requested.
        #expect(ParallelsParsing.setCommands(uuid: "{u}", new: VMResources(diskBytes: 100 * 1_048_576), current: current).isEmpty)
    }
}
