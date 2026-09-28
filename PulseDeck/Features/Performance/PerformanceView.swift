import SwiftUI

/// Performance section in top-bar mode: the Performance list with live previews on the leading
/// side — CPU, memory, each disk, each network interface, GPU, energy — and the selected entry's
/// page on the trailing side (SPEC §10).
struct PerformanceView: View {
    @Environment(AppState.self) private var appState
    @Binding var item: PerformanceItem

    private var selection: Binding<PerformanceItem?> {
        Binding { appState.resolve(item) } set: { newValue in
            if let newValue { item = newValue }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(appState.performanceItems, selection: selection) { item in
                PerformanceItemRow(item: item)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 270)
        } detail: {
            ResourceDetailView(item: appState.resolve(item))
        }
    }
}
