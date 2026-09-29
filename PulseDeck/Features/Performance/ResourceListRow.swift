import PulseDeckCore
import SwiftUI

/// One row of the Performance list: icon, name, compact live preview and a sparkline of the
/// last 60 seconds (SPEC §10). Disks and network interfaces each have their own row; those rows
/// offer "Hide in Sidebar" (restore in Settings → Sidebar).
struct PerformanceItemRow: View {
    @Environment(AppState.self) private var appState
    let item: PerformanceItem

    var body: some View {
        HStack(spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    MetricStateText(state: preview)
                        .font(.caption)
                        .lineLimit(1)
                }
            } icon: {
                Image(systemName: systemImage)
            }
            Spacer(minLength: 4)
            ResourceSparkline(item: item)
                .frame(width: 56, height: 26)
        }
        .accessibilityElement(children: .combine)
        .contextMenu {
            if isDevice {
                Button("Hide in Sidebar") {
                    appState.hide(item)
                }
            }
        }
    }

    private var isDevice: Bool {
        switch item {
        case .category: false
        case .disk, .networkInterface: true
        }
    }

    private var disk: DiskSnapshot? {
        guard case .disk(let id) = item else { return nil }
        return appState.latestSnapshot?.disks.value?.first { $0.id == id }
    }

    private var interface: NetworkInterfaceSnapshot? {
        guard case .networkInterface(let id) = item else { return nil }
        return appState.latestSnapshot?.network.value?.interfaces.first { $0.id == id }
    }

    private var title: String {
        switch item {
        case .category(let category): String(localized: category.title)
        case .disk(let id): disk?.name ?? id
        case .networkInterface(let id): interface?.title ?? id
        }
    }

    private var systemImage: String {
        switch item {
        case .category(let category): category.systemImage
        case .disk: disk?.connection.systemImage ?? ResourceCategory.disks.systemImage
        case .networkInterface: interface?.kind.systemImage ?? ResourceCategory.network.systemImage
        }
    }

    /// "disk0 · R 1.2 MB/s · W 0 kB/s", "en0 · ↓ 12 kB/s ↑ 3 kB/s".
    private var preview: MetricState<String>? {
        switch item {
        case .category(.usb):
            // The tree is read only while the USB page is open; show the last known count.
            return .available(appState.latestUSB?.devicesDescription ?? String(localized: "Buses and devices"))
        case .category(let category):
            return appState.latestSnapshot?.preview(for: category)
        case .disk(let id):
            guard let disk else { return .unavailable(.sourceRemoved) }
            return disk.readBytesPerSecond.flatMap { read in
                disk.writeBytesPerSecond.map { written in
                    String(localized: "\(id) · R \(Format.rate(read)) · W \(Format.rate(written))")
                }
            }
        case .networkInterface(let id):
            guard let interface else { return .unavailable(.sourceRemoved) }
            return interface.receivedBytesPerSecond.flatMap { received in
                interface.sentBytesPerSecond.map { sent in "\(id) · ↓ \(Format.rate(received)) ↑ \(Format.rate(sent))" }
            }
        }
    }
}
