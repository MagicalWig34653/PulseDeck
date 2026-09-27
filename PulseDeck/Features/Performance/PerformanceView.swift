import SwiftUI

/// Performance section in top-bar mode: resource list with live previews on the leading
/// side, details of the selected resource on the trailing side (SPEC §10).
struct PerformanceView: View {
    @Binding var category: ResourceCategory

    private var selection: Binding<ResourceCategory?> {
        Binding { category } set: { newValue in
            if let newValue { category = newValue }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(ResourceCategory.allCases, selection: selection) { category in
                ResourceListRow(category: category)
                    .tag(category)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
        } detail: {
            ResourceDetailView(category: category)
        }
    }
}
