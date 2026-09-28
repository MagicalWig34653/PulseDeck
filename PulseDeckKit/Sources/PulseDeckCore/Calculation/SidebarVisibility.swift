/// Which individual devices (disks, network interfaces) the Performance sidebar lists.
///
/// Every device has a default: loopback, never-used interfaces and disk images are hidden by
/// default, everything else is shown. The user can override either way per device; overrides
/// are kept by a stable key (e.g. `disk:disk0`, `network:en0`) so they survive restarts and
/// re-plugging. Hiding is only about the list — hidden devices are still sampled and charted.
public struct SidebarVisibility: Codable, Hashable, Sendable {
    /// Explicitly hidden, although shown by default.
    public private(set) var hidden: Set<String>
    /// Explicitly shown, although hidden by default.
    public private(set) var shown: Set<String>

    public init(hidden: Set<String> = [], shown: Set<String> = []) {
        self.hidden = hidden
        self.shown = shown
    }

    public func isVisible(_ key: String, hiddenByDefault: Bool) -> Bool {
        if hidden.contains(key) { return false }
        if shown.contains(key) { return true }
        return !hiddenByDefault
    }

    /// Records the user's choice. Choosing the default removes the override, so a later change
    /// of the default (e.g. an interface starting to carry traffic) applies again.
    public mutating func setVisible(_ visible: Bool, _ key: String, hiddenByDefault: Bool) {
        hidden.remove(key)
        shown.remove(key)
        if visible == hiddenByDefault {
            if visible { shown.insert(key) } else { hidden.insert(key) }
        }
    }

    public var hasOverrides: Bool { !hidden.isEmpty || !shown.isEmpty }

    /// Sidebar key of a disk.
    public static func key(disk id: String) -> String { "disk:\(id)" }
    /// Sidebar key of a network interface.
    public static func key(networkInterface id: String) -> String { "network:\(id)" }

    /// Devices hidden unless the user shows them: disk images (not physical storage).
    public static func isHiddenByDefault(_ disk: DiskSnapshot) -> Bool {
        disk.connection == .diskImage
    }

    /// Loopback and interfaces that have never received or sent a byte. Unclassified interfaces
    /// are not hidden for that reason alone (SPEC §17).
    public static func isHiddenByDefault(_ interface: NetworkInterfaceSnapshot) -> Bool {
        interface.kind == .loopback || (interface.totalBytesReceived == 0 && interface.totalBytesSent == 0)
    }
}
