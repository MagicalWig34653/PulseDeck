import PulseDeckCore
import SwiftUI

/// One entry of the Performance list: a whole category (CPU, memory, GPU, energy) or an
/// individual disk or network interface, as in Task Manager's Performance tab.
///
/// `.category(.disks)` / `.category(.network)` mean "the default device of that kind" (first
/// disk, primary interface). They are used before devices are known (e.g. `-initialCategory`)
/// and as the fallback entry when the collector has no devices to list.
enum PerformanceItem: Hashable, Identifiable, RawRepresentable {
    case category(ResourceCategory)
    case disk(String)
    case networkInterface(String)

    var id: Self { self }

    var category: ResourceCategory {
        switch self {
        case .category(let category): category
        case .disk: .disks
        case .networkInterface: .network
        }
    }

    /// Persisted form (scene storage): "cpu", "disk:disk0", "network:en0".
    init?(rawValue: String) {
        if rawValue.hasPrefix(Self.diskPrefix) {
            self = .disk(String(rawValue.dropFirst(Self.diskPrefix.count)))
        } else if rawValue.hasPrefix(Self.networkPrefix) {
            self = .networkInterface(String(rawValue.dropFirst(Self.networkPrefix.count)))
        } else if let category = ResourceCategory(rawValue: rawValue) {
            self = .category(category)
        } else {
            return nil
        }
    }

    var rawValue: String {
        switch self {
        case .category(let category): category.rawValue
        case .disk(let id): SidebarVisibility.key(disk: id)
        case .networkInterface(let id): SidebarVisibility.key(networkInterface: id)
        }
    }

    private static let diskPrefix = SidebarVisibility.key(disk: "")
    private static let networkPrefix = SidebarVisibility.key(networkInterface: "")
}

extension AppState {
    /// The Performance list: CPU, memory, each visible disk, each visible network interface,
    /// GPU, energy. A device kind whose collector reports no devices keeps its category entry,
    /// so "Not Available" stays reachable instead of the kind silently disappearing.
    var performanceItems: [PerformanceItem] {
        var items: [PerformanceItem] = [.category(.cpu), .category(.memory)]
        items += deviceItems(disks: visibleDisks, network: visibleInterfaces)
        items += [.category(.gpu), .category(.energy)]
        return items
    }

    private func deviceItems(disks: [DiskSnapshot]?, network: [NetworkInterfaceSnapshot]?) -> [PerformanceItem] {
        var items: [PerformanceItem] = []
        if let disks {
            items += disks.map { .disk($0.id) }
        } else {
            items.append(.category(.disks))
        }
        if let network {
            items += network.map { .networkInterface($0.id) }
        } else {
            items.append(.category(.network))
        }
        return items
    }

    /// Disks shown in the list, or `nil` if the collector has no disk list yet (or failed).
    var visibleDisks: [DiskSnapshot]? {
        guard let disks = latestSnapshot?.disks.value else { return nil }
        return disks.filter {
            sidebarVisibility.isVisible(SidebarVisibility.key(disk: $0.id), hiddenByDefault: SidebarVisibility.isHiddenByDefault($0))
        }
    }

    /// Interfaces shown in the list — primary first, then connected ones, then by name — or
    /// `nil` if the collector has no interface list yet (or failed).
    var visibleInterfaces: [NetworkInterfaceSnapshot]? {
        guard let network = latestSnapshot?.network.value else { return nil }
        return network.interfaces
            .filter {
                sidebarVisibility.isVisible(SidebarVisibility.key(networkInterface: $0.id),
                                            hiddenByDefault: SidebarVisibility.isHiddenByDefault($0))
            }
            .sorted { lhs, rhs in
                let lhsPrimary = lhs.id == network.primaryInterfaceID
                let rhsPrimary = rhs.id == network.primaryInterfaceID
                if lhsPrimary != rhsPrimary { return lhsPrimary }
                if lhs.isUp != rhs.isUp { return lhs.isUp }
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
    }

    /// Turns "the default disk/interface" into the concrete device once devices are known, so
    /// the list highlights the page that is shown.
    func resolve(_ item: PerformanceItem) -> PerformanceItem {
        switch item {
        case .category(.disks):
            return visibleDisks?.first.map { .disk($0.id) } ?? item
        case .category(.network):
            let primary = latestSnapshot?.network.value?.primaryInterfaceID
            if let primary, visibleInterfaces?.contains(where: { $0.id == primary }) == true {
                return .networkInterface(primary)
            }
            return visibleInterfaces?.first.map { .networkInterface($0.id) } ?? item
        default:
            return item
        }
    }

    /// Hides one device from the list (context menu "Hide in Sidebar").
    func hide(_ item: PerformanceItem) {
        switch item {
        case .disk(let id):
            let hiddenByDefault = latestSnapshot?.disks.value?.first { $0.id == id }.map { SidebarVisibility.isHiddenByDefault($0) } ?? false
            sidebarVisibility.setVisible(false, SidebarVisibility.key(disk: id), hiddenByDefault: hiddenByDefault)
        case .networkInterface(let id):
            let hiddenByDefault = latestSnapshot?.network.value?.interfaces.first { $0.id == id }.map { SidebarVisibility.isHiddenByDefault($0) } ?? false
            sidebarVisibility.setVisible(false, SidebarVisibility.key(networkInterface: id), hiddenByDefault: hiddenByDefault)
        case .category:
            break
        }
    }
}
