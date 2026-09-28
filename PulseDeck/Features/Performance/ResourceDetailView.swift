import PulseDeckCore
import SwiftUI

/// Detail page of one performance category.
struct ResourceDetailView: View {
    let category: ResourceCategory

    var body: some View {
        Group {
            switch category {
            case .cpu:
                CPUPerformanceView()
            case .memory:
                MemoryPerformanceView()
            case .disks:
                DiskPerformanceView()
            case .network:
                NetworkPerformanceView()
            case .gpu:
                GPUPerformanceView()
            case .energy:
                EnergyPerformanceView()
            }
        }
        .navigationTitle(Text(category.title))
    }
}
