import PulseDeckCore
import SwiftUI

/// Processes section. Milestone 1 shows the collector's state; the process table is
/// implemented in Milestone 8.
struct ProcessesView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Group {
            switch appState.latestSnapshot?.processes {
            case .unavailable(let reason)?:
                ContentUnavailableView {
                    Label {
                        Text("Processes")
                    } icon: {
                        Image(systemName: AppSection.processes.systemImage)
                    }
                } description: {
                    Text("Not Available")
                    Text(reason.explanation)
                }
            default:
                ProgressView()
                    .controlSize(.small)
            }
        }
        .navigationTitle(Text(AppSection.processes.title))
    }
}
