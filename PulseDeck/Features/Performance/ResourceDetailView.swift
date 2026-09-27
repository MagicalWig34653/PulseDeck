import PulseDeckCore
import SwiftUI

/// Detail page of one performance category.
struct ResourceDetailView: View {
    @Environment(AppState.self) private var appState
    let category: ResourceCategory

    private var state: MetricState<String>? {
        appState.latestSnapshot?.preview(for: category)
    }

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
            case .gpu, .energy:
                capabilityState
            }
        }
        .navigationTitle(Text(category.title))
    }

    /// Categories without a collector yet show their capability state.
    @ViewBuilder
    private var capabilityState: some View {
        Group {
            switch state {
            case .unavailable(let reason)? where !reason.isTransient:
                ContentUnavailableView {
                    Label {
                        Text(category.title)
                    } icon: {
                        Image(systemName: category.systemImage)
                    }
                } description: {
                    Text("Not Available")
                    Text(reason.explanation)
                }
            default:
                VStack(alignment: .leading, spacing: 8) {
                    Text(category.title)
                        .font(.largeTitle.weight(.semibold))
                    MetricStateText(state: state)
                        .font(.title2)
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
        }
    }
}
