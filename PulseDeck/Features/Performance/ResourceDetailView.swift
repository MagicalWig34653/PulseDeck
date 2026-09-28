import PulseDeckCore
import SwiftUI

/// Detail page of one Performance list entry.
struct ResourceDetailView: View {
    let item: PerformanceItem

    var body: some View {
        Group {
            switch item {
            case .category(.cpu):
                CPUPerformanceView()
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
            }
        }
        .navigationTitle(Text(item.category.title))
    }
}
