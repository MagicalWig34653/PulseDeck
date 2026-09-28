import PulseDeckCore
import SwiftUI

/// One row of the resource list: icon, name, compact live preview and a sparkline of the last
/// 60 seconds (SPEC §10).
struct ResourceListRow: View {
    @Environment(AppState.self) private var appState
    let category: ResourceCategory

    var body: some View {
        HStack(spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                    MetricStateText(state: appState.latestSnapshot?.preview(for: category))
                        .font(.caption)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: category.systemImage)
            }
            Spacer(minLength: 4)
            ResourceSparkline(category: category)
                .frame(width: 56, height: 26)
        }
        .accessibilityElement(children: .combine)
    }
}
