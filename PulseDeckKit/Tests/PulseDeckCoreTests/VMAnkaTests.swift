import Foundation
import Testing
@testable import PulseDeckCore

@Suite("Anka parsing")
struct VMAnkaTests {
    // Output examples from Veertu's command-line reference (`anka --machine-readable list|show`).
    static let list = """
    {
      "status": "OK",
      "body": [
        {
          "name": "12.2.0-arm",
          "uuid": "a6f24306-2af7-45ed-9d70-3a3c1ee7f03a",
          "creation_date": "2022-01-06T12:34:52Z",
          "version": "vanilla",
          "status": "stopped"
        },
        {
          "name": "test_vm1",
          "uuid": "565e47ce-a9f9-4ac8-81bc-645d48473de1",
          "creation_date": "2022-01-06T12:34:52Z",
          "status": "running"
        }
      ]
    }
    """

    static let show = """
    {
      "status": "OK",
      "body": {
        "uuid": "a6f24306-2af7-45ed-9d70-3a3c1ee7f03a",
        "name": "12.2.0-arm",
        "version": "vanilla",
        "creation_date": "2022-01-06T12:34:52Z",
        "cpu_cores": 4,
        "cpu_frequency": 0,
        "cpu_htt": false,
        "arch": 2,
        "ram": "4294967296",
        "ram_size": 4294967296,
        "frame_buffers": 1,
        "hard_drive": 137438953472,
        "encrypted": false,
        "image_size": 19035295744,
        "addons_version": "3.0.0.135.13568747",
        "stop_date": "2022-01-06T18:10:17Z",
        "status": "stopped"
      }
    }
    """

    @Test func parsesList() {
        let entries = AnkaParsing.parseList(Self.list)
        #expect(entries.map(\.name) == ["12.2.0-arm", "test_vm1"])
        #expect(entries[0].tag == "vanilla")
        #expect(entries[1].tag == nil)
        #expect(entries[1].status == "running")
    }

    @Test func listErrorsGiveNothing() {
        #expect(AnkaParsing.parseList(#"{"status":"ERROR","message":"nope"}"#).isEmpty)
        #expect(AnkaParsing.parseList("anka: command not found").isEmpty)
        #expect(AnkaParsing.parseList("").isEmpty)
    }

    @Test func parsesShow() throws {
        let properties = try #require(AnkaParsing.parseShow(Self.show))
        #expect(properties == AnkaParsing.Properties(cpuCores: 4, ramBytes: 4_294_967_296, diskBytes: 137_438_953_472, arch: 2))
        #expect(AnkaParsing.parseShow("{}") == nil)
    }

    @Test func buildsRecords() throws {
        let entry = try #require(AnkaParsing.parseList(Self.list).first)
        let properties = AnkaParsing.parseShow(Self.show)
        let record = AnkaParsing.makeRecord(entry, properties: properties)
        #expect(record.nativeID == "a6f24306-2af7-45ed-9d70-3a3c1ee7f03a")
        #expect(record.state == .stopped)
        #expect(record.guestOS == "macOS")
        #expect(record.architecture == "arm64")
        #expect(record.resources == VMResources(cpus: 4, memoryBytes: 4_294_967_296, diskBytes: 137_438_953_472))
        #expect(record.hostProcessIDs.isEmpty)
        #expect(record.details.contains { $0.label == "Host usage" })
        #expect(record.capabilities.canEditAnything)

        // Without `show` the sizes are unknown and cannot be edited.
        let bare = AnkaParsing.makeRecord(entry, properties: nil)
        #expect(bare.resources == VMResources())
        #expect(!bare.capabilities.canEditAnything)
    }

    @Test func mapsStates() {
        #expect(AnkaParsing.state("running") == .running)
        #expect(AnkaParsing.state("suspended") == .suspended)
        #expect(AnkaParsing.state("stopped") == .stopped)
        #expect(AnkaParsing.state("???") == .unknown)
        #expect(AnkaParsing.state(nil) == .unknown)
    }

    @Test func commandLines() {
        #expect(AnkaParsing.listArguments == ["--machine-readable", "list"])
        #expect(AnkaParsing.showArguments(uuid: "u") == ["--machine-readable", "show", "u"])
        #expect(AnkaParsing.startArguments(uuid: "u") == ["start", "u"])
        #expect(AnkaParsing.stopArguments(uuid: "u") == ["stop", "u"])
        #expect(AnkaParsing.sizeArgument(bytes: 8 * 1_073_741_824) == "8G")
        #expect(AnkaParsing.sizeArgument(bytes: 6_144 * 1_048_576 + 1_048_576) == "6145M")
    }

    @Test func modifyCommandsOnlyForChanges() {
        let current = VMResources(cpus: 4, memoryBytes: 4 * 1_073_741_824, diskBytes: 128 * 1_073_741_824)
        #expect(AnkaParsing.modifyCommands(uuid: "u", new: current, current: current).isEmpty)
        let commands = AnkaParsing.modifyCommands(
            uuid: "u",
            new: VMResources(cpus: 6, memoryBytes: 8 * 1_073_741_824, diskBytes: 200 * 1_073_741_824),
            current: current
        )
        #expect(commands == [
            ["modify", "u", "cpu", "6"],
            ["modify", "u", "ram", "8G"],
            ["modify", "u", "disk", "--size", "200G"],
        ])
        // Anka cannot shrink a disk.
        #expect(AnkaParsing.modifyCommands(uuid: "u", new: VMResources(diskBytes: 64 * 1_073_741_824), current: current).isEmpty)
    }
}
