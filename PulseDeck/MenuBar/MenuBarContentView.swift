import AppKit
import PulseDeckCore
import SwiftUI

/// Compact overview shown from the menu bar (SPEC §23): CPU, memory, GPU, energy and network
/// with live values and 60-second sparklines, plus actions to open the main window, open
/// Settings and quit. Each row opens its Performance page.
///
/// While the panel is open, sampling runs at the foreground rate and GPU/energy are collected
/// (`SamplingDemand`); closing it returns to background sampling.
struct MenuBarContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openWindow) private var openWindow

    private static let overviewCategories: [ResourceCategory] = [.cpu, .memory, .gpu, .energy, .network]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("PulseDeck")
                    .font(.headline)
                Spacer()
                if let mode = appState.latestSnapshot?.samplingMode {
                    Text(mode == .foreground ? "Live" : "Updating every few seconds")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(spacing: 2) {
                ForEach(Self.overviewCategories) { category in
                    MenuBarOverviewRow(category: category) {
                        open(category)
                    }
                }
            }

            Divider()

            HStack {
                Button("Open PulseDeck", action: { openMainWindow() })
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
        .padding(14)
        .frame(width: 340)
        .onAppear { appState.isMenuBarWindowVisible = true }
        .onDisappear { appState.isMenuBarWindowVisible = false }
    }

    private func open(_ category: ResourceCategory) {
        // `.category(.network)` resolves to the primary interface's own page.
        appState.requestedItem = .category(category)
        openMainWindow()
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

/// One resource in the menu bar panel: icon, name, current value and sparkline. The whole row
/// is a button that opens the resource's Performance page.
private struct MenuBarOverviewRow: View {
    @Environment(AppState.self) private var appState
    @State private var isHovered = false
    let category: ResourceCategory
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: category.systemImage)
                    .font(.body)
                    .foregroundStyle(.tint)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(category.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    MetricStateText(state: appState.latestSnapshot?.preview(for: category))
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                ResourceSparkline(category: category)
                    .frame(width: 72, height: 24)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(.rect)
            .background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(Text("Show \(String(localized: category.title)) in PulseDeck"))
        .accessibilityElement(children: .combine)
        .accessibilityHint(Text("Opens the Performance page"))
    }
}
