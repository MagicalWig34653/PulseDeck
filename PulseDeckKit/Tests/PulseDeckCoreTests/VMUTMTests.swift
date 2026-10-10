import Foundation
import Testing
@testable import PulseDeckCore

@Suite("UTM parsing")
struct VMUTMTests {
    // Keys per UTMAppleConfiguration / UTMAppleConfigurationSystem / ...Drive / ...Boot.
    static let applePlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>Backend</key><string>Apple</string>
        <key>ConfigurationVersion</key><integer>4</integer>
        <key>Information</key>
        <dict>
            <key>Name</key><string>macOS Sequoia</string>
            <key>UUID</key><string>7B9D1F9C-33E6-4C6E-9A53-1D6D5B2C0A11</string>
            <key>IconCustom</key><false/>
        </dict>
        <key>System</key>
        <dict>
            <key>Architecture</key><string>aarch64</string>
            <key>CPUCount</key><integer>0</integer>
            <key>MemorySize</key><integer>8192</integer>
            <key>Boot</key>
            <dict><key>OperatingSystem</key><string>macOS</string></dict>
        </dict>
        <key>Drive</key>
        <array>
            <dict>
                <key>ImageName</key><string>0E9A5E55-7F9B-4D5D-B2B5-2B5A9A4B0C12.img</string>
                <key>Identifier</key><string>0E9A5E55-7F9B-4D5D-B2B5-2B5A9A4B0C12</string>
                <key>ReadOnly</key><false/>
                <key>Nvme</key><false/>
            </dict>
            <dict>
                <key>ImageName</key><string>installer.iso</string>
                <key>Identifier</key><string>AAAA</string>
                <key>ReadOnly</key><true/>
            </dict>
        </array>
    </dict>
    </plist>
    """

    // Keys per UTMQemuConfiguration / ...System / ...Drive (QEMUDriveImageType raw values).
    static let qemuPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <plist version="1.0">
    <dict>
        <key>ConfigurationVersion</key><integer>4</integer>
        <key>Information</key>
        <dict>
            <key>Name</key><string>Debian 12</string>
            <key>UUID</key><string>3F2504E0-4F89-41D3-9A0C-0305E82C3301</string>
        </dict>
        <key>System</key>
        <dict>
            <key>Architecture</key><string>aarch64</string>
            <key>Target</key><string>virt</string>
            <key>CPUCount</key><integer>4</integer>
            <key>MemorySize</key><integer>4096</integer>
        </dict>
        <key>Drive</key>
        <array>
            <dict>
                <key>ImageName</key><string>debian.qcow2</string>
                <key>ImageType</key><string>Disk</string>
                <key>Interface</key><string>virtio</string>
                <key>ReadOnly</key><false/>
            </dict>
            <dict>
                <key>ImageName</key><string>debian-12.iso</string>
                <key>ImageType</key><string>CD</string>
                <key>ReadOnly</key><true/>
            </dict>
            <dict>
                <key>ImageType</key><string>CD</string>
            </dict>
        </array>
    </dict>
    </plist>
    """

    @Test func parsesAppleConfig() throws {
        let config = try #require(UTMParsing.parseConfig(Data(Self.applePlist.utf8)))
        #expect(config.backend == .apple)
        #expect(config.name == "macOS Sequoia")
        #expect(config.uuid == "7B9D1F9C-33E6-4C6E-9A53-1D6D5B2C0A11")
        #expect(config.architecture == "arm64")
        #expect(config.cpuCount == nil) // 0 = automatic
        #expect(config.memoryMiB == 8192)
        #expect(config.guestOS == "macOS")
        #expect(UTMParsing.diskImageNames(config) == ["0E9A5E55-7F9B-4D5D-B2B5-2B5A9A4B0C12.img"])
    }

    @Test func parsesQEMUConfigWithoutBackendKey() throws {
        let config = try #require(UTMParsing.parseConfig(Data(Self.qemuPlist.utf8)))
        #expect(config.backend == .qemu)
        #expect(config.cpuCount == 4)
        #expect(config.memoryMiB == 4096)
        #expect(config.guestOS == nil)
        #expect(UTMParsing.diskImageNames(config) == ["debian.qcow2"])
    }

    @Test func rejectsForeignPlists() {
        #expect(UTMParsing.parseConfig(Data("garbage".utf8)) == nil)
        let other = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>A</key><string>b</string></dict></plist>"
        #expect(UTMParsing.parseConfig(Data(other.utf8)) == nil)
    }

    @Test func attributesQEMUProcessesByUUID() {
        let uuid = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
        let processes = [
            VMHostProcess(pid: 500, parentPID: 400, name: "QEMULauncher", arguments: ["/Applications/UTM.app/qemu-aarch64-softmmu", "-S", "-name", "Debian 12", "-uuid", uuid.lowercased(), "-m", "4096"]),
            VMHostProcess(pid: 501, parentPID: 400, name: "QEMULauncher", arguments: ["/x/qemu", "-uuid", "00000000-0000-0000-0000-000000000000"]),
            VMHostProcess(pid: 502, parentPID: 1, name: "bash", arguments: ["-uuid", uuid]),
            VMHostProcess(pid: 503, parentPID: 400, name: "QEMULauncher", arguments: ["-uuid"]),
        ]
        #expect(UTMParsing.qemuProcesses(forUUID: uuid, in: processes).map(\.pid) == [500])
    }

    @Test func qemuRecordRunningAndStopped() throws {
        let config = try #require(UTMParsing.parseConfig(Data(Self.qemuPlist.utf8)))
        let process = VMHostProcess(pid: 9, parentPID: 1, name: "QEMULauncher", arguments: ["-uuid", config.uuid])
        let running = UTMParsing.makeRecord(config: config, diskBytes: 64 * 1_073_741_824, bundlePath: "/b/Debian 12.utm", processes: [process])
        #expect(running.state == .running)
        #expect(running.hostProcessIDs == [9])
        #expect(running.resources == VMResources(cpus: 4, memoryBytes: 4096 * 1_048_576, diskBytes: 64 * 1_073_741_824))
        #expect(!running.capabilities.canEditAnything)
        #expect(running.capabilities.canStart && running.capabilities.canStop && running.capabilities.canRestart)
        let stopped = UTMParsing.makeRecord(config: config, diskBytes: nil, bundlePath: "/b", processes: [])
        #expect(stopped.state == .stopped)
        #expect(stopped.hostProcessIDs.isEmpty)
    }

    @Test func appleStateNeverClaimsAttribution() throws {
        let config = try #require(UTMParsing.parseConfig(Data(Self.applePlist.utf8)))
        let utm = VMHostProcess(pid: 1, parentPID: 1, name: "UTM", executablePath: "/Applications/UTM.app/Contents/MacOS/UTM")
        let service = VMHostProcess(pid: 2, parentPID: 1, name: "com.apple.Virtualization.VirtualMachine", executablePath: "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine")

        // UTM not running → stopped; UTM running without any VM service → stopped.
        #expect(UTMParsing.makeRecord(config: config, diskBytes: nil, bundlePath: "/b", processes: [service]).state == .stopped)
        #expect(UTMParsing.makeRecord(config: config, diskBytes: nil, bundlePath: "/b", processes: [utm]).state == .stopped)
        // UTM and a VM service: something runs, but which VM is unknowable.
        let unknown = UTMParsing.makeRecord(config: config, diskBytes: nil, bundlePath: "/b", processes: [utm, service])
        #expect(unknown.state == .unknown)
        #expect(unknown.hostProcessIDs.isEmpty)
        #expect(unknown.details.contains { $0.label == "Host usage" })
    }

    @Test func utmctlLines() {
        #expect(UTMParsing.startArguments(uuid: "U") == ["start", "U"])
        #expect(UTMParsing.stopArguments(uuid: "U") == ["stop", "--request", "U"])
        #expect(UTMParsing.statusArguments(uuid: "U") == ["status", "U"])
        #expect(UTMParsing.parseStatus("started\n") == .running)
        #expect(UTMParsing.parseStatus("stopped") == .stopped)
        #expect(UTMParsing.parseStatus("paused") == .paused)
        #expect(UTMParsing.parseStatus("") == .unknown)
    }
}
