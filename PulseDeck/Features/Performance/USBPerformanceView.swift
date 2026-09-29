import PulseDeckCore
import SwiftUI

/// USB page: every bus (host controller) with its hubs and devices as a tree, the negotiated
/// link speed — the most each device can transfer; devices behind a hub share its link — and the
/// bus power each device was allocated. macOS does not measure per-port power
/// (TECHNICAL_LIMITATIONS.md L‑12), so the page shows allocations and says so.
struct USBPerformanceView: View {
    @Environment(AppState.self) private var appState

    private var state: MetricState<USBSnapshot>? { appState.latestSnapshot?.usb }
    /// The live tree, or the last one while the first sample of this visit is pending.
    private var snapshot: USBSnapshot? { state?.value ?? appState.latestUSB }

    var body: some View {
        if let reason = state?.unavailableReason, !reason.isTransient {
            CategoryUnavailableView(category: .usb, reason: reason)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    DetailHeader(
                        title: String(localized: "USB"),
                        subtitle: snapshot.map { String(localized: "\($0.controllers.count) buses") },
                        value: snapshot.map { .available($0.devicesDescription) }
                    )

                    if let snapshot {
                        DetailSection(title: "Power") {
                            StatisticView(label: "Allocated", value: Self.allocatedPower(snapshot),
                                          help: "Bus power the Mac granted to all USB devices together.")
                            StatisticView(label: "Devices", value: .available("\(snapshot.deviceCount)"))
                            StatisticView(label: "Fastest Link", value: snapshot.controllers.compactMap(\.fastestSpeed).max().map { .available($0.name) } ?? .unavailable(.notApplicable))
                        }

                        ForEach(snapshot.controllers) { controller in
                            USBBusView(controller: controller)
                        }

                        SourceNote(text: "Power is the bus power each device requested and was allocated at 5 V (undocumented IORegistry value “UsbPowerSinkAllocation”) — not a measurement. Devices with their own power supply and USB‑C Power Delivery beyond 5 V are not included.")
                    } else {
                        ProgressView()
                            .controlSize(.small)
                            .frame(maxWidth: .infinity, minHeight: 120)
                    }
                }
                .padding(20)
            }
        }
    }

    private static func allocatedPower(_ snapshot: USBSnapshot) -> MetricState<String> {
        let milliamps = snapshot.controllers.compactMap(\.totalAllocatedMilliamps)
        guard !milliamps.isEmpty else { return .unavailable(.unsupportedHardware) }
        let node = USBNode(id: 0, kind: .device, name: "", allocatedMilliamps: milliamps.reduce(0, +))
        return .available(node.allocatedPowerText)
    }
}

/// One bus: a header with its device count and fastest link, then its device tree.
private struct USBBusView: View {
    let controller: USBNode

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                if controller.children.isEmpty {
                    Text("No devices connected")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(Array(controller.children.enumerated()), id: \.element.id) { index, device in
                        USBTreeRow(node: device, depth: 0, isLast: index == controller.children.count - 1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Label {
                    Text(verbatim: controller.name)
                } icon: {
                    Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                }
                .font(.headline)
                Spacer()
                Text(verbatim: [
                    String(localized: "\(controller.deviceCount) devices"),
                    controller.totalAllocatedMilliamps.map { _ in controller.totalPowerText },
                ].compactMap { $0 }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// A hub or device with its children, indented with tree lines.
private struct USBTreeRow: View {
    let node: USBNode
    let depth: Int
    let isLast: Bool
    private static let indent: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: node.kind == .hub ? "rectangle.connected.to.line.below" : "cable.connector.horizontal")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: node.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(verbatim: node.detailText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 12)
                if let speed = node.speed {
                    SpeedBadge(speed: speed)
                }
                Text(verbatim: node.allocatedMilliamps != nil ? node.allocatedPowerText : AppState.placeholder)
                    .monospacedDigit()
                    .foregroundStyle(node.allocatedMilliamps != nil ? .primary : .secondary)
                    .frame(minWidth: 96, alignment: .trailing)
                    .help(Text(node.powerHelp))
            }
            .padding(.vertical, 5)
            .padding(.leading, CGFloat(depth) * Self.indent)
            .background(alignment: .leading) {
                if depth > 0 {
                    TreeConnector(isLast: isLast)
                        .stroke(.separator, lineWidth: 1)
                        .frame(width: Self.indent)
                        .padding(.leading, CGFloat(depth - 1) * Self.indent + 8)
                }
            }
            .accessibilityElement(children: .combine)

            ForEach(Array(node.children.enumerated()), id: \.element.id) { index, child in
                USBTreeRow(node: child, depth: depth + 1, isLast: index == node.children.count - 1)
            }
        }
    }
}

/// "├─" / "└─" connector drawn left of a nested row.
private struct TreeConnector: Shape {
    let isLast: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: isLast ? rect.midY : rect.maxY))
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX - 6, y: rect.midY))
        return path
    }
}

/// Link speed with the generation's colour: USB 1 grey, USB 2 blue, USB 3 green/teal.
private struct SpeedBadge: View {
    let speed: USBSpeed

    var body: some View {
        Text(verbatim: Format.bitRate(Double(speed.bitsPerSecond)))
            .font(.caption.weight(.medium))
            .monospacedDigit()
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(color.opacity(0.18), in: .capsule)
            .foregroundStyle(color)
            .help(Text(verbatim: speed.name))
            .accessibilityLabel(Text(verbatim: speed.name))
    }

    private var color: Color {
        switch speed {
        case .low, .full: .gray
        case .high: .blue
        case .superSpeed: .teal
        case .superSpeedPlus, .superSpeedPlusBy2: .green
        }
    }
}

extension USBNode {
    /// "Apple Inc. · 05ac:12a8 · USB 2.0 High Speed".
    var detailText: String {
        var parts: [String] = []
        if let vendor { parts.append(vendor) }
        if let vendorID, let productID {
            parts.append(String(format: "%04x:%04x", vendorID, productID))
        }
        if let speed { parts.append(speed.name) }
        if kind == .hub { parts.append(String(localized: "Hub")) }
        return parts.joined(separator: " · ")
    }

    /// "500 mA · 2.5 W".
    var allocatedPowerText: String {
        guard let milliamps = allocatedMilliamps, let watts = allocatedWatts else { return AppState.placeholder }
        return "\(milliamps) mA · \(Format.watts(watts))"
    }

    var totalPowerText: String {
        guard let total = totalAllocatedMilliamps else { return AppState.placeholder }
        return String(localized: "\(Format.watts(Double(total) / 1_000 * Self.busVoltage)) allocated")
    }

    var powerHelp: LocalizedStringResource {
        if let limit = portCurrentLimitMilliamps {
            return "Allocated bus power. The port can supply up to \(limit) mA."
        }
        return "Allocated bus power (requested by the device, not measured)."
    }
}
