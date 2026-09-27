import PulseDeckCore
import SwiftUI

/// One row of the resource list: icon, name and a compact live preview (SPEC §10).
struct ResourceListRow: View {
    @Environment(AppState.self) private var appState
    let category: ResourceCategory

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                MetricStateText(state: appState.latestSnapshot?.preview(for: category))
                    .font(.caption)
            }
        } icon: {
            Image(systemName: category.systemImage)
        }
        .accessibilityElement(children: .combine)
    }
}
