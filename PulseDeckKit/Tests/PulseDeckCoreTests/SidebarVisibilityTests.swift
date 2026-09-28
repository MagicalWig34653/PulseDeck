import Foundation
import Testing
@testable import PulseDeckCore

@Suite("Sidebar visibility")
struct SidebarVisibilityTests {
    @Test func defaultsApplyWithoutOverrides() {
        let visibility = SidebarVisibility()
        #expect(visibility.isVisible("disk:disk0", hiddenByDefault: false))
        #expect(!visibility.isVisible("network:lo0", hiddenByDefault: true))
    }

    @Test func hidingAndShowingOverrideDefaults() {
        var visibility = SidebarVisibility()
        visibility.setVisible(false, "disk:disk0", hiddenByDefault: false)
        visibility.setVisible(true, "network:lo0", hiddenByDefault: true)
        #expect(!visibility.isVisible("disk:disk0", hiddenByDefault: false))
        #expect(visibility.isVisible("network:lo0", hiddenByDefault: true))
        #expect(visibility.hasOverrides)
    }

    @Test func choosingTheDefaultRemovesTheOverride() {
        var visibility = SidebarVisibility()
        visibility.setVisible(false, "network:en5", hiddenByDefault: false)
        visibility.setVisible(true, "network:en5", hiddenByDefault: false)
        #expect(!visibility.hasOverrides)
        // An interface that was hidden by default and starts carrying traffic now appears.
        #expect(visibility.isVisible("network:en5", hiddenByDefault: false))
    }

    @Test func survivesEncoding() throws {
        var visibility = SidebarVisibility()
        visibility.setVisible(false, "disk:disk4", hiddenByDefault: false)
        let decoded = try JSONDecoder().decode(SidebarVisibility.self, from: JSONEncoder().encode(visibility))
        #expect(decoded == visibility)
    }

    @Test func defaultRules() {
        let image = DiskSnapshot(id: "disk5", name: "Image", connection: .diskImage, isRemovable: true,
                                 capacityBytes: .available(1), availableBytes: .available(1),
                                 readBytesPerSecond: .available(0), writeBytesPerSecond: .available(0),
                                 totalBytesRead: .available(0), totalBytesWritten: .available(0),
                                 activeTime: .unavailable(.noPublicAPI))
        var internalDisk = image
        internalDisk.connection = .internal
        #expect(SidebarVisibility.isHiddenByDefault(image))
        #expect(!SidebarVisibility.isHiddenByDefault(internalDisk))

        func interface(_ id: String, kind: NetworkInterfaceKind, received: UInt64) -> NetworkInterfaceSnapshot {
            NetworkInterfaceSnapshot(id: id, displayName: nil, kind: kind, isUp: true,
                                     receivedBytesPerSecond: .available(0), sentBytesPerSecond: .available(0),
                                     totalBytesReceived: received, totalBytesSent: 0)
        }
        #expect(SidebarVisibility.isHiddenByDefault(interface("lo0", kind: .loopback, received: 100)))
        #expect(SidebarVisibility.isHiddenByDefault(interface("en3", kind: .ethernet, received: 0)))
        #expect(!SidebarVisibility.isHiddenByDefault(interface("utun4", kind: .vpnTunnel(friendlyName: nil), received: 10)))
        #expect(SidebarVisibility.key(disk: "disk0") == "disk:disk0")
        #expect(SidebarVisibility.key(networkInterface: "en0") == "network:en0")
    }
}
