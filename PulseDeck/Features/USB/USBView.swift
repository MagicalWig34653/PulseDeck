import PulseDeckCore
import SwiftUI

/// USB section: the USB tree as a diagram — this Mac, its buses (host controllers), hubs and
/// devices — with each link's negotiated speed (the most that device can transfer; devices
/// behind a hub share its link) and the bus power each device was allocated. macOS does not
/// measure per-port power (TECHNICAL_LIMITATIONS.md L‑12), so the section shows allocations and
/// says so. The tree is read only while the section is visible.
struct USBView: View {
    @Environment(AppState.self) private var appState

    private var state: MetricState<USBSnapshot>? { appState.latestSnapshot?.usb }
    /// The live tree, or the last one while the first sample of this visit is pending.
    private var snapshot: USBSnapshot? { state?.value ?? appState.latestUSB }

    var body: some View {
        Group {
            if let reason = state?.unavailableReason, !reason.isTransient {
                ContentUnavailableView {
                    Label("USB", systemImage: AppSection.usb.systemImage)
                } description: {
                    Text("Not Available")
                    Text(reason.explanation)
                }
            } else if let snapshot {
                content(snapshot)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle(Text(AppSection.usb.title))
    }

    private func content(_ snapshot: USBSnapshot) -> some View {
        // Vertical page; only the diagram scrolls sideways when it is wider than the window. (A
        // two-axis scroll view centres content smaller than the viewport.)
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 28) {
                    summary("Devices", snapshot.devicesDescription)
                    summary("Buses", "\(snapshot.controllers.count)")
                    summary("Allocated Power", Self.allocatedPower(snapshot) ?? AppState.placeholder,
                            help: "Bus power the Mac granted to all USB devices together.")
                    summary("Fastest Link", snapshot.controllers.compactMap(\.fastestSpeed).max()?.name ?? AppState.placeholder)
                }

                ScrollView(.horizontal) {
                    USBTreeDiagram(snapshot: snapshot)
                        .padding(.vertical, 4)
                }
                .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

                SpeedLegend()

                SourceNote(text: "Power is the bus power each device requested and was allocated at 5 V (undocumented IORegistry value “UsbPowerSinkAllocation”) — not a measurement. Devices with their own power supply and USB‑C Power Delivery beyond 5 V are not included. Link speed is the negotiated maximum, not current traffic.")
                    .frame(maxWidth: 720, alignment: .leading)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func summary(_ label: LocalizedStringResource, _ value: String, help: LocalizedStringResource? = nil) -> some View {
        StatisticView(label: label, value: .available(value), help: help)
            .fixedSize()
    }

    private static func allocatedPower(_ snapshot: USBSnapshot) -> String? {
        let milliamps = snapshot.controllers.compactMap(\.totalAllocatedMilliamps)
        guard !milliamps.isEmpty else { return nil }
        return USBNode(id: 0, kind: .device, name: "", allocatedMilliamps: milliamps.reduce(0, +)).allocatedPowerText
    }
}

/// The tree drawn left to right with `TreeLayout`: cards for nodes, curved connectors coloured
/// by link speed, and the speed written on each device's link.
private struct USBTreeDiagram: View {
    let snapshot: USBSnapshot

    private static let cardSize = CGSize(width: 220, height: 62)
    private static let columnGap: CGFloat = 96
    private static let rowGap: CGFloat = 18

    /// The diagram's root: this Mac, with the buses as children.
    private struct Item {
        enum Kind {
            case mac
            case bus(number: Int)
            case node
        }

        let id: UInt64
        let kind: Kind
        let node: USBNode?
        let children: [Item]
    }

    private var root: Item {
        Item(id: .max, kind: .mac, node: nil, children: snapshot.controllers.enumerated().map { index, controller in
            Item(id: controller.id, kind: .bus(number: index + 1), node: controller, children: controller.children.map(Self.item))
        })
    }

    private static func item(_ node: USBNode) -> Item {
        Item(id: node.id, kind: .node, node: node, children: node.children.map(item))
    }

    private static func flatten(_ item: Item) -> [Item] {
        [item] + item.children.flatMap(flatten)
    }

    var body: some View {
        let root = root
        let layout = TreeLayout(roots: [root], id: \.id, children: \.children)
        let items = Self.flatten(root)
        let size = CGSize(
            width: CGFloat(layout.columnCount) * (Self.cardSize.width + Self.columnGap) - Self.columnGap,
            height: CGFloat(layout.rowCount) * (Self.cardSize.height + Self.rowGap) - Self.rowGap
        )
        func center(_ id: UInt64) -> CGPoint {
            guard let position = layout.positions[id] else { return .zero }
            return CGPoint(
                x: CGFloat(position.column) * (Self.cardSize.width + Self.columnGap) + Self.cardSize.width / 2,
                y: CGFloat(position.row) * (Self.cardSize.height + Self.rowGap) + Self.cardSize.height / 2
            )
        }

        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                for parent in items {
                    let start = center(parent.id)
                    for child in parent.children {
                        let end = center(child.id)
                        let from = CGPoint(x: start.x + Self.cardSize.width / 2, y: start.y)
                        let to = CGPoint(x: end.x - Self.cardSize.width / 2, y: end.y)
                        let middle = (from.x + to.x) / 2
                        var path = Path()
                        path.move(to: from)
                        path.addCurve(to: to, control1: CGPoint(x: middle, y: from.y), control2: CGPoint(x: middle, y: to.y))
                        let speed = child.node?.speed
                        context.stroke(path, with: .color((speed?.color ?? .secondary).opacity(0.75)),
                                       style: StrokeStyle(lineWidth: speed.map(Self.lineWidth) ?? 1.5, lineCap: .round))
                    }
                }
            }
            .frame(width: size.width, height: size.height)

            // Speed labels sit on the last stretch of each link, just before the device card.
            ForEach(items.filter { $0.node?.speed != nil && $0.node?.kind != .controller }, id: \.id) { item in
                if let speed = item.node?.speed {
                    SpeedBadge(speed: speed)
                        .position(x: center(item.id).x - Self.cardSize.width / 2 - Self.columnGap / 2 + 10, y: center(item.id).y)
                }
            }

            ForEach(items, id: \.id) { item in
                card(for: item)
                    .frame(width: Self.cardSize.width, height: Self.cardSize.height)
                    .position(center(item.id))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("USB device tree"))
    }

    /// 1.5 pt for USB 1 up to 5 pt for 20 Gbit/s, on a logarithmic scale.
    private static func lineWidth(_ speed: USBSpeed) -> CGFloat {
        let minimum = 1.5, maximum = 5.0
        let lowest = log10(Double(USBSpeed.low.bitsPerSecond)), highest = log10(Double(USBSpeed.superSpeedPlusBy2.bitsPerSecond))
        let fraction = (log10(Double(speed.bitsPerSecond)) - lowest) / (highest - lowest)
        return minimum + (maximum - minimum) * min(max(fraction, 0), 1)
    }

    @ViewBuilder
    private func card(for item: Item) -> some View {
        switch item.kind {
        case .mac:
            NodeCard(
                systemImage: "laptopcomputer",
                title: String(localized: "This Mac"),
                subtitle: snapshot.devicesDescription,
                trailing: nil,
                emphasis: true
            )
        case .bus(let number):
            let controller = item.node
            NodeCard(
                systemImage: "point.3.filled.connected.trianglepath.dotted",
                title: String(localized: "Bus \(number)"),
                subtitle: [controller?.name, controller.map { USBSnapshot.devicesDescription(count: $0.deviceCount) }]
                    .compactMap { $0 }.joined(separator: " · "),
                trailing: controller?.totalAllocatedMilliamps.map { _ in controller?.totalPowerText ?? "" },
                emphasis: false
            )
        case .node:
            if let node = item.node {
                NodeCard(
                    systemImage: node.kind == .hub ? "rectangle.connected.to.line.below" : "cable.connector.horizontal",
                    title: node.name,
                    subtitle: node.cardSubtitle,
                    trailing: node.allocatedWatts.map(Format.watts),
                    emphasis: false
                )
                .help(Text(verbatim: node.helpText))
            }
        }
    }
}

/// One box of the diagram.
private struct NodeCard: View {
    let systemImage: String
    let title: String
    let subtitle: String
    /// Power, top right.
    let trailing: String?
    let emphasis: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(emphasis ? Color.accentColor : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(verbatim: title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    if let trailing {
                        Text(verbatim: trailing)
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(.orange)
                    }
                }
                Text(verbatim: subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.background, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(emphasis ? AnyShapeStyle(Color.accentColor.opacity(0.6)) : AnyShapeStyle(SeparatorShapeStyle())))
        .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
        .accessibilityElement(children: .combine)
    }
}

/// Link speed on a connector, in the generation's colour.
private struct SpeedBadge: View {
    let speed: USBSpeed

    var body: some View {
        Text(verbatim: Format.bitRate(Double(speed.bitsPerSecond)))
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.background, in: .capsule)
            .overlay(Capsule().strokeBorder(speed.color.opacity(0.7)))
            .foregroundStyle(speed.color)
            .fixedSize()
            .help(Text(verbatim: speed.name))
            .accessibilityLabel(Text(verbatim: speed.name))
    }
}

private struct SpeedLegend: View {
    private static let entries: [USBSpeed] = [.full, .high, .superSpeed, .superSpeedPlus, .superSpeedPlusBy2]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Self.entries, id: \.self) { speed in
                HStack(spacing: 5) {
                    Capsule().fill(speed.color).frame(width: 14, height: 4)
                    Text(verbatim: "\(speed.name) · \(Format.bitRate(Double(speed.bitsPerSecond)))")
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

extension USBSpeed {
    /// USB 1 grey, USB 2 blue, USB 3 Gen 1 teal, Gen 2 and faster green.
    var color: Color {
        switch self {
        case .low, .full: .gray
        case .high: .blue
        case .superSpeed: .teal
        case .superSpeedPlus, .superSpeedPlusBy2: .green
        }
    }
}

@MainActor
extension USBNode {
    /// "Apple Inc. · 05ac:12a8" (and "Hub").
    var cardSubtitle: String {
        var parts: [String] = []
        if kind == .hub { parts.append(String(localized: "Hub")) }
        if let vendor { parts.append(vendor) }
        if let vendorID, let productID {
            parts.append(String(format: "%04x:%04x", vendorID, productID))
        }
        return parts.isEmpty ? AppState.placeholder : parts.joined(separator: " · ")
    }

    /// "500 mA · 2.5 W".
    var allocatedPowerText: String {
        guard let milliamps = allocatedMilliamps, let watts = allocatedWatts else { return AppState.placeholder }
        return "\(milliamps) mA · \(Format.watts(watts))"
    }

    var totalPowerText: String {
        guard let total = totalAllocatedMilliamps else { return AppState.placeholder }
        return Format.watts(Double(total) / 1_000 * Self.busVoltage)
    }

    /// Tooltip: speed, allocation and port limit spelled out.
    var helpText: String {
        var lines = [name]
        if let speed { lines.append(String(localized: "Link: \(speed.name) (\(Format.bitRate(Double(speed.bitsPerSecond))))")) }
        if allocatedMilliamps != nil { lines.append(String(localized: "Allocated bus power: \(allocatedPowerText)")) }
        if let limit = portCurrentLimitMilliamps { lines.append(String(localized: "Port limit: \(limit) mA")) }
        return lines.joined(separator: "\n")
    }
}
