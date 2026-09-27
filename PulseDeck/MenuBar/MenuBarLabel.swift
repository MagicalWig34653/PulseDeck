import SwiftUI

/// The status item: the app symbol plus the optional live metric (SPEC §24).
struct MenuBarLabel: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "waveform.path.ecg")
            if let text = appState.menuBarLabelText {
                Text(verbatim: text)
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("PulseDeck"))
    }
}
