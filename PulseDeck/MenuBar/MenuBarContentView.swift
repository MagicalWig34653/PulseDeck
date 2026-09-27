import AppKit
import PulseDeckCore
import SwiftUI

/// Compact overview shown from the menu bar (SPEC §23): CPU, memory, GPU, energy and
/// network plus actions to open the main window and quit.
struct MenuBarContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    private static let overviewCategories: [ResourceCategory] = [.cpu, .memory, .gpu, .energy, .network]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("PulseDeck")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                ForEach(Self.overviewCategories) { category in
                    GridRow {
                        Label {
                            Text(category.title)
                        } icon: {
                            Image(systemName: category.systemImage)
                        }
                        MetricStateText(state: appState.latestSnapshot?.preview(for: category))
                            .gridColumnAlignment(.trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            Divider()

            HStack {
                Button("Open PulseDeck", action: openMainWindow)
                    .keyboardShortcut("o")
                SettingsLink {
                    Text("Settings…")
                }
                Spacer()
                Button("Quit", action: quit)
                    .keyboardShortcut("q")
            }
            .buttonStyle(.glass)
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { appState.isMenuBarWindowVisible = true }
        .onDisappear { appState.isMenuBarWindowVisible = false }
    }

    private func openMainWindow() {
        // Show the Dock icon again before activating so the window comes to the front.
        NSApp.setActivationPolicy(.regular)
        openWindow(id: SceneID.mainWindow)
        NSApp.activate()
    }

    private func quit() {
        NSApp.terminate(nil)
    }
}
