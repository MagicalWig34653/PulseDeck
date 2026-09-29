import PulseDeckCore
import SwiftUI

/// Detail page of one Performance list entry. Tells `AppState` which demand-driven domains the
/// page needs beyond the list previews.
struct ResourceDetailView: View {
    @Environment(AppState.self) private var appState
    @AppStorage(PreferenceKey.memoryProcessPie) private var showsProcessPie = false
    let item: PerformanceItem

    var body: some View {
        Group {
            switch item {
            case .category(.cpu):
                CPUPerformanceView()
            case .category(.thermals):
            return [.thermals]
        case .category(.memory):
                MemoryPerformanceView()
            case .category(.disks):
                DiskPerformanceView(diskID: nil)
            case .disk(let id):
                DiskPerformanceView(diskID: id)
            case .category(.network):
                NetworkPerformanceView(interfaceID: nil)
            case .networkInterface(let id):
                NetworkPerformanceView(interfaceID: id)
            case .category(.gpu):
                GPUPerformanceView()
            case .category(.energy):
                EnergyPerformanceView()
            case .category(.thermals):
                ThermalsPerformanceView()
            }
        }
        .navigationTitle(Text(item.category.title))
        .defaultScrollAnchor(Self.initialScrollAnchor)
        .onChange(of: demand, initial: true) {
            appState.detailPageDemand = demand
        }
        .onDisappear {
            appState.detailPageDemand = []
        }
    }

    /// Launch preference for screenshots; `nil` (top) otherwise.
    private static let initialScrollAnchor: UnitPoint? =
        UserDefaults.standard.string(forKey: PreferenceKey.initialScrollAnchor) == "bottom" ? .bottom : nil

    private var demand: Set<MetricKind> {
        switch item {
        case .category(.cpu):
            return [.cpuFrequency]
        case .category(.thermals):
            return [.thermals]
        case .category(.memory):
            return showsProcessPie ? [.processes] : []
        case .networkInterface(let id):
            let interface = appState.latestSnapshot?.network.value?.interfaces.first { $0.id == id }
            return interface?.isTailscale == true ? [.tailscale] : []
        default:
            return []
        }
    }
}
