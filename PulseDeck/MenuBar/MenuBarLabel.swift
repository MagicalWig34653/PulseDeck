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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("PulseDeck"))
        .accessibilityValue(accessibilityValue)
    }

    /// The live metric for VoiceOver, with the placeholder spoken as "Not Available".
    private var accessibilityValue: Text {
        guard let text = appState.menuBarLabelText else { return Text(verbatim: "") }
        guard text != AppState.placeholder else { return Text("\(String(localized: appState.menuBarMetric.title)): Not Available") }
        return Text(verbatim: "\(String(localized: appState.menuBarMetric.title)) \(text)")
    }
}
