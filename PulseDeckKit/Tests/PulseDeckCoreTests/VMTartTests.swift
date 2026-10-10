import Foundation
import Testing
@testable import PulseDeckCore

@Suite("Tart parsing")
struct VMTartTests {
    // Shape of ~/.tart/vms/<name>/config.json as written by Tart's VMConfig.save
    // (keys from VMConfig.swift; hardwareModel/ecid are base64 blobs, abbreviated here).
    static let darwinConfig = """
    {
      "arch" : "arm64",
      "cpuCount" : 4,
      "cpuCountMin" : 4,
      "diskFormat" : "raw",
      "display" : { "height" : 1080, "unit" : "px", "width" : 1920 },
      "displayRefit" : true,
      "ecid" : "YnBsaXN0MDDRAQJURUNJRA==",
      "hardwareModel" : "YnBsaXN0MDDfEBMBAgM=",
      "macAddress" : "7a:11:22:33:44:55",
      "memorySize" : 8589934592,
      "memorySizeMin" : 4294967296,
      "os" : "darwin",
      "version" : 1
    }
    """

    @Test func parsesConfig() throws {
        let config = try #require(TartParsing.parseConfig(Data(Self.darwinConfig.utf8)))
        #expect(config.os == "darwin")
        #expect(config.arch == "arm64")
        #expect(config.cpuCount == 4)
        #expect(config.memoryBytes == 8_589_934_592)
        #expect(config.diskFormat == "raw")
        #expect(config.display == "1920x1080px")
    }

    @Test func oldConfigDefaultsLikeTart() throws {
        let config = try #require(TartParsing.parseConfig(Data(#"{"version":1,"cpuCount":2,"memorySize":2147483648}"#.utf8)))
        #expect(config.os == "darwin")
        #expect(config.arch == "arm64")
        #expect(config.diskFormat == "raw")
        #expect(TartParsing.parseConfig(Data("not json".utf8)) == nil)
    }

    @Test func mapsGuestAndArchitecture() {
        #expect(TartParsing.guestOS("darwin") == "macOS")
        #expect(TartParsing.guestOS("linux") == "Linux")
        #expect(TartParsing.guestOS("plan9") == nil)
        #expect(TartParsing.architecture("arm64") == "arm64")
        #expect(TartParsing.architecture("amd64") == "x86_64")
    }

    @Test func findsVMNameInRunCommandLine() {
        #expect(TartParsing.runningVMName(arguments: ["run", "--no-graphics", "sonoma-base"]) == "sonoma-base")
        #expect(TartParsing.runningVMName(arguments: ["run", "sonoma-base"]) == "sonoma-base")
        // Option values are not mistaken for the name.
        #expect(TartParsing.runningVMName(arguments: ["run", "--dir", "build:/tmp/x", "--net-softnet-allow", "10.0.0.0/8", "ci"]) == "ci")
        #expect(TartParsing.runningVMName(arguments: ["run", "--dir=src:ro", "ci"]) == "ci")
        #expect(TartParsing.runningVMName(arguments: ["stop", "ci"]) == nil)
        #expect(TartParsing.runningVMName(arguments: []) == nil)
        #expect(TartParsing.runningVMName(arguments: ["run", "--no-graphics"]) == nil)
    }

    @Test func attributesOnlyExactTartRunProcesses() {
        let processes = [
            VMHostProcess(pid: 10, parentPID: 1, name: "tart", executablePath: "/opt/homebrew/bin/tart", arguments: ["run", "--no-graphics", "ci"]),
            VMHostProcess(pid: 11, parentPID: 1, name: "tart", executablePath: "/opt/homebrew/bin/tart", arguments: ["run", "ci-2"]),
            VMHostProcess(pid: 12, parentPID: 1, name: "tart", executablePath: "/opt/homebrew/bin/tart", arguments: ["pull", "ci"]),
            VMHostProcess(pid: 13, parentPID: 1, name: "vim", arguments: ["run", "ci"]),
        ]
        #expect(TartParsing.hostProcesses(forVM: "ci", in: processes).map(\.pid) == [10])
        #expect(TartParsing.hostProcesses(forVM: "missing", in: processes).isEmpty)
    }

    @Test func recordStates() throws {
        let config = try #require(TartParsing.parseConfig(Data(Self.darwinConfig.utf8)))
        let running = [VMHostProcess(pid: 77, parentPID: 1, name: "tart", arguments: ["run", "--no-graphics", "vm1"])]

        let up = TartParsing.makeRecord(name: "vm1", config: config, diskBytes: 50_000_000_000, hasSavedState: false, directory: "/Users/me/.tart/vms/vm1", processes: running)
        #expect(up.state == .running)
        #expect(up.hostProcessIDs == [77])
        #expect(up.guestOS == "macOS")
        #expect(up.resources == VMResources(cpus: 4, memoryBytes: 8_589_934_592, diskBytes: 50_000_000_000))
        #expect(up.capabilities.canEditDisk)
        #expect(up.capabilities.editRequiresStopped)

        let suspended = TartParsing.makeRecord(name: "vm1", config: config, diskBytes: 50_000_000_000, hasSavedState: true, directory: "/x", processes: [])
        #expect(suspended.state == .suspended)
        let stopped = TartParsing.makeRecord(name: "vm1", config: config, diskBytes: 50_000_000_000, hasSavedState: false, directory: "/x", processes: [])
        #expect(stopped.state == .stopped)
        #expect(stopped.hostProcessIDs.isEmpty)
    }

    @Test func asifOrMissingDiskIsNotReportedOrEditable() throws {
        var config = try #require(TartParsing.parseConfig(Data(Self.darwinConfig.utf8)))
        config.diskFormat = "asif"
        let asif = TartParsing.makeRecord(name: "a", config: config, diskBytes: 1_000, hasSavedState: false, directory: "/x", processes: [])
        #expect(asif.resources.diskBytes == nil)
        #expect(!asif.capabilities.canEditDisk)
        #expect(asif.details.contains(VMDetail(label: "Disk format", value: "ASIF")))

        config.diskFormat = "raw"
        let stacked = TartParsing.makeRecord(name: "b", config: config, diskBytes: nil, hasSavedState: false, directory: "/x", processes: [])
        #expect(stacked.resources.diskBytes == nil)
        #expect(!stacked.capabilities.canEditDisk)
    }

    @Test func commandLines() {
        #expect(TartParsing.startArguments(name: "ci") == ["run", "--no-graphics", "ci"])
        #expect(TartParsing.stopArguments(name: "ci") == ["stop", "ci"])
    }

    @Test func setArgumentsOnlyForChanges() {
        let current = VMResources(cpus: 4, memoryBytes: 8_589_934_592, diskBytes: 50_000_000_000)
        #expect(TartParsing.setArguments(name: "ci", new: current, current: current) == nil)
        #expect(TartParsing.setArguments(name: "ci", new: VMResources(cpus: 6, memoryBytes: 8_589_934_592, diskBytes: 50_000_000_000), current: current) == ["set", "ci", "--cpu", "6"])
        // 16 GiB → 16384 MiB; disk grown to 80 GB.
        #expect(TartParsing.setArguments(name: "ci", new: VMResources(cpus: 4, memoryBytes: 17_179_869_184, diskBytes: 80_000_000_000), current: current)
            == ["set", "ci", "--memory", "16384", "--disk-size", "80"])
        // Shrinking the disk is never requested; a non-whole number of GB rounds up.
        #expect(TartParsing.setArguments(name: "ci", new: VMResources(diskBytes: 40_000_000_000), current: current) == nil)
        #expect(TartParsing.setArguments(name: "ci", new: VMResources(diskBytes: 50_000_000_001), current: current) == ["set", "ci", "--disk-size", "51"])
    }
}
