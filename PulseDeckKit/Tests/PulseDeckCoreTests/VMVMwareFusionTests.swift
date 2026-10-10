import Foundation
import Testing
@testable import PulseDeckCore

@Suite("VMware Fusion parsing")
struct VMVMwareFusionTests {
    static let vmx = """
    .encoding = "UTF-8"
    config.version = "8"
    virtualHW.version = "21"
    # a comment
    displayName = "Ubuntu |22Dev|22 Box"
    guestOS = "arm-ubuntu-64"
    numvcpus = "4"
    cpuid.coresPerSocket = "2"
    memsize = "8192"
    scsi0.present = "TRUE"
    scsi0:0.present = "TRUE"
    scsi0:0.fileName = "Virtual Disk.vmdk"
    sata0:0.present = "TRUE"
    sata0:0.deviceType = "cdrom-image"
    sata0:0.fileName = "/Users/me/ubuntu.iso"
    nvme0:1.present = "FALSE"
    nvme0:1.fileName = "unused.vmdk"
    ethernet0.connectionType = "nat"
    """

    @Test func parsesVMX() {
        let config = VMwareFusionParsing.parseConfig(Self.vmx, fallbackName: "fallback")
        #expect(config.displayName == "Ubuntu \"Dev\" Box")
        #expect(config.guestOSID == "arm-ubuntu-64")
        #expect(config.cpus == 4)
        #expect(config.memoryMiB == 8192)
        #expect(config.diskFiles == ["Virtual Disk.vmdk"])
        let bare = VMwareFusionParsing.parseConfig("memsize = \"512\"", fallbackName: "Foo")
        #expect(bare.displayName == "Foo")
        #expect(bare.cpus == nil)
        #expect(bare.memoryMiB == 512)
    }

    @Test func parsesInventory() {
        let inventory = """
        .encoding = "UTF-8"
        vmlist1.config = "/Users/me/Virtual Machines.localized/Ubuntu.vmwarevm/Ubuntu.vmx"
        vmlist1.DisplayName = "Ubuntu"
        vmlist2.config = "/Volumes/Data/win.vmwarevm/win.vmx"
        vmlist2.ItemID = "2"
        vmlist3.config = "/Users/me/other.txt"
        vmlist4.config = "/Users/me/Virtual Machines.localized/Ubuntu.vmwarevm/Ubuntu.vmx"
        """
        #expect(VMwareFusionParsing.inventoryPaths(inventory) == [
            "/Users/me/Virtual Machines.localized/Ubuntu.vmwarevm/Ubuntu.vmx",
            "/Volumes/Data/win.vmwarevm/win.vmx",
        ])
    }

    @Test func mapsGuestIdentifiers() {
        #expect(VMwareFusionParsing.guestInfo("arm-ubuntu-64") == ("Linux", "arm64"))
        #expect(VMwareFusionParsing.guestInfo("windows11-64") == ("Windows", "x86_64"))
        #expect(VMwareFusionParsing.guestInfo("darwin23-64") == ("macOS", "x86_64"))
        #expect(VMwareFusionParsing.guestInfo("arm-windows11-64") == ("Windows", "arm64"))
        #expect(VMwareFusionParsing.guestInfo("otherlinux-64") == ("Linux", "x86_64"))
        #expect(VMwareFusionParsing.guestInfo(nil) == (nil, nil))
    }

    // Command line from a real vmware.log of Fusion 13.6.4.
    @Test func attributesVmwareVmxByVMXPath() {
        let path = "/Users/jijojohn/Desktop/ainux/vmware_build/TensorAgentOS.vmx"
        let processes = [
            VMHostProcess(pid: 900, parentPID: 1, name: "vmware-vmx", executablePath: "/Applications/VMware Fusion.app/Contents/Library/vmware-vmx",
                          arguments: ["-E", "en", "-s", "vmx.stdio.keep=TRUE", "-#", "product=64;name=VMware Fusion;version=13.6.4;", "-@", "duplex=3;msgs=ui", "-D", "4", path]),
            VMHostProcess(pid: 901, parentPID: 1, name: "vmware-vmx", arguments: ["-D", "4", "/Users/me/other.vmx"]),
            VMHostProcess(pid: 902, parentPID: 1, name: "vim", arguments: [path]),
        ]
        #expect(VMwareFusionParsing.hostProcesses(forVMX: path, in: processes).map(\.pid) == [900])
        #expect(VMwareFusionParsing.hostProcesses(forVMX: path.uppercased(), in: processes).map(\.pid) == [900])
        #expect(VMwareFusionParsing.hostProcesses(forVMX: "/nowhere.vmx", in: processes).isEmpty)
    }

    @Test func recordStates() {
        let config = VMwareFusionParsing.parseConfig(Self.vmx, fallbackName: "x")
        let vmx = "/Users/me/U.vmwarevm/U.vmx"
        let process = VMHostProcess(pid: 1, parentPID: 1, name: "vmware-vmx", arguments: [vmx])
        let running = VMwareFusionParsing.makeRecord(vmxPath: vmx, config: config, diskBytes: 100, hasSuspendState: true, processes: [process])
        #expect(running.state == .running)
        #expect(running.hostProcessIDs == [1])
        #expect(running.resources == VMResources(cpus: 4, memoryBytes: 8192 * 1_048_576, diskBytes: 100))
        #expect(running.guestOS == "Linux")
        #expect(VMwareFusionParsing.makeRecord(vmxPath: vmx, config: config, diskBytes: nil, hasSuspendState: true, processes: []).state == .suspended)
        let stopped = VMwareFusionParsing.makeRecord(vmxPath: vmx, config: config, diskBytes: nil, hasSuspendState: false, processes: [])
        #expect(stopped.state == .stopped)
        #expect(stopped.capabilities.canEditCPUs && stopped.capabilities.canEditMemory && !stopped.capabilities.canEditDisk)
    }

    @Test func diskSizeFromDescriptorOrSparseHeader() {
        let descriptor = """
        # Disk DescriptorFile
        version=1
        CID=fffffffe
        createType="twoGbMaxExtentSparse"

        # Extent description
        RW 4192256 SPARSE "Virtual Disk-s001.vmdk"
        RW 4192256 SPARSE "Virtual Disk-s002.vmdk"
        RW 8192 SPARSE "Virtual Disk-s003.vmdk"
        """
        let expectedSectors: UInt64 = 4_192_256 + 4_192_256 + 8_192
        let fromDescriptor = VMwareFusionParsing.diskSize(header: Data("# Disk DescriptorFile\n".utf8), descriptorText: descriptor)
        #expect(fromDescriptor == expectedSectors * 512)

        var header = [UInt8](repeating: 0, count: 512)
        header.replaceSubrange(0..<4, with: Array("KDMV".utf8))
        let sectors: UInt64 = 83_886_080 // 40 GiB
        for index in 0..<8 { header[12 + index] = UInt8((sectors >> (8 * UInt64(index))) & 0xFF) }
        let fromHeader = VMwareFusionParsing.diskSize(header: Data(header), descriptorText: nil)
        let forty: UInt64 = 40 * 1_073_741_824
        #expect(fromHeader == forty)
        let unknown = VMwareFusionParsing.diskSize(header: Data([1, 2, 3]), descriptorText: "junk")
        #expect(unknown == nil)
    }

    @Test func vmrunLines() {
        #expect(VMwareFusionParsing.startArguments(vmx: "/a.vmx") == ["-T", "fusion", "start", "/a.vmx", "nogui"])
        #expect(VMwareFusionParsing.stopArguments(vmx: "/a.vmx") == ["-T", "fusion", "stop", "/a.vmx", "soft"])
        #expect(VMwareFusionParsing.restartArguments(vmx: "/a.vmx") == ["-T", "fusion", "reset", "/a.vmx", "soft"])
    }

    @Test func memoryIsRoundedDownToMultipleOfFour() {
        #expect(VMwareFusionParsing.memoryMiB(forBytes: 4096 * 1_048_576) == 4096)
        #expect(VMwareFusionParsing.memoryMiB(forBytes: 4099 * 1_048_576) == 4096)
        #expect(VMwareFusionParsing.memoryMiB(forBytes: 1_048_576) == 4)
    }

    @Test func rewritesOnlyTheEditedKeys() {
        let edited = VMwareFusionParsing.applying(cpus: 8, memoryMiB: 16_384, to: Self.vmx)
        let values = VMwareFusionParsing.parseKeyValues(edited)
        #expect(values["numvcpus"] == "8")
        #expect(values["memsize"] == "16384")
        #expect(values["cpuid.corespersocket"] == "2") // 8 is a multiple of 2
        // Every other line is byte-identical and in place.
        let before = Self.vmx.components(separatedBy: "\n")
        let after = edited.components(separatedBy: "\n")
        #expect(before.count == after.count)
        for (old, new) in zip(before, after) where !old.hasPrefix("numvcpus") && !old.hasPrefix("memsize") {
            #expect(old == new)
        }
        #expect(edited.contains("numvcpus = \"8\""))
    }

    @Test func resetsCoresPerSocketWhenIncompatible() {
        let edited = VMwareFusionParsing.applying(cpus: 3, memoryMiB: nil, to: Self.vmx)
        let values = VMwareFusionParsing.parseKeyValues(edited)
        #expect(values["numvcpus"] == "3")
        #expect(values["cpuid.corespersocket"] == "1")
        #expect(values["memsize"] == "8192")
        #expect(edited.contains("cpuid.coresPerSocket = \"1\"")) // original key spelling kept
    }

    @Test func appendsMissingKeysAndKeepsCRLF() {
        let appended = VMwareFusionParsing.applying(cpus: 2, memoryMiB: 2048, to: "displayName = \"x\"\n")
        #expect(appended == "displayName = \"x\"\nmemsize = \"2048\"\nnumvcpus = \"2\"\n")
        let crlf = VMwareFusionParsing.applying(cpus: 2, memoryMiB: nil, to: "numvcpus = \"1\"\r\nmemsize = \"512\"\r\n")
        #expect(crlf == "numvcpus = \"2\"\r\nmemsize = \"512\"\r\n")
        #expect(VMwareFusionParsing.applying(cpus: nil, memoryMiB: nil, to: "a = \"b\"") == "a = \"b\"")
    }
}
