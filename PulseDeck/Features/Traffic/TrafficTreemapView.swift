import PulseDeckCore
import SwiftUI

/// The treemap of the Traffic page: one tile per group, its area proportional to the bytes
/// exchanged (connections without byte counters). The bottom edge of a tile splits received
/// (solid) from sent (light). Hover highlights the tile and the matching table row's group;
/// a click selects the group's row and opens the inspector.
struct TrafficTreemapView: View {
    let tiles: [TrafficTile]
    let grouping: FlowGrouping
    let hasByteCounters: Bool
    let selectedGroupIDs: Set<String>
    let hover: TrafficHover
    let select: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let height: CGFloat = 240
    private static let gap: CGFloat = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if tiles.isEmpty {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(.background.secondary)
                        .overlay {
                            Text("No traffic to show")
                                .foregroundStyle(.secondary)
                        }
                } else {
                    GeometryReader { geometry in
                        treemap(in: geometry.size)
                    }
                }
            }
            .frame(height: Self.height)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text(verbatim: accessibilitySummary))

            if hasByteCounters, !tiles.isEmpty {
                HStack(spacing: 14) {
                    legendKey(opacity: 1, text: "Received")
                    legendKey(opacity: 0.35, text: "Sent")
                    Text("The bar along each tile's bottom edge splits received from sent.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }
        }
    }

    @ViewBuilder
    private func treemap(in size: CGSize) -> some View {
        let rects = TrafficTreemap.layout(
            weights: tiles.map(\.weight),
            in: TreemapRect(x: 0, y: 0, width: Double(size.width), height: Double(size.height))
        )
        ZStack(alignment: .topLeading) {
            ForEach(Array(zip(tiles, rects)), id: \.0.id) { tile, rect in
                let width = max(CGFloat(rect.width) - Self.gap, 0)
                let height = max(CGFloat(rect.height) - Self.gap, 0)
                TrafficTileView(
                    tile: tile,
                    size: CGSize(width: width, height: height),
                    isSelected: selectedGroupIDs.contains(tile.id),
                    hover: hover,
                    select: { select(tile.id) }
                )
                .frame(width: width, height: height)
                .offset(x: CGFloat(rect.x) + Self.gap / 2, y: CGFloat(rect.y) + Self.gap / 2)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: rects)
    }

    private func legendKey(opacity: Double, text: LocalizedStringResource) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(opacity))
                .frame(width: 14, height: 6)
            Text(text)
        }
    }

    private var accessibilitySummary: String {
        let top = tiles.prefix(3).map(\.accessibilityLabel).joined(separator: "; ")
        if top.isEmpty { return String(localized: "Traffic by \(grouping.title): no traffic") }
        return String(localized: "Traffic by \(grouping.title). Largest: \(top)")
    }
}

private struct TrafficTileView: View {
    let tile: TrafficTile
    let size: CGSize
    let isSelected: Bool
    let hover: TrafficHover
    let select: () -> Void

    @Environment(\.colorSchemeContrast) private var contrast

    private static let cornerRadius: CGFloat = 8

    var body: some View {
        let color = TrafficPalette.color(forGroup: tile.id)
        let isHovered = hover.groupID == tile.id
        let isDimmed = hover.groupID != nil && !isHovered && !isSelected
        let isHighContrast = contrast == .increased
        let shape = RoundedRectangle(cornerRadius: Self.cornerRadius)

        ZStack(alignment: .topLeading) {
            shape.fill(color.opacity(fillOpacity(isHovered: isHovered, isSelected: isSelected, isHighContrast: isHighContrast)))
            labels
            if let fraction = tile.receivedFraction, size.height >= 28 {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    HStack(spacing: 0) {
                        Rectangle().fill(color)
                            .frame(width: size.width * fraction)
                        Rectangle().fill(color.opacity(0.35))
                    }
                    .frame(height: 5)
                }
            }
            shape.strokeBorder(color.opacity(isHighContrast ? 1 : 0.8), lineWidth: isSelected ? 3 : (isHovered ? 2 : 1))
        }
        .clipShape(shape)
        .opacity(isDimmed ? 0.55 : 1)
        .contentShape(shape)
        .onHover { inside in
            guard !tile.isOther else { return }
            if inside {
                hover.groupID = tile.id
            } else if hover.groupID == tile.id {
                hover.groupID = nil
            }
        }
        .onTapGesture {
            if !tile.isOther { select() }
        }
        // Tooltips only for the few tiles here; the table has none per cell.
        .help(Text(verbatim: tile.accessibilityLabel))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: tile.accessibilityLabel))
        .accessibilityAddTraits(tile.isOther ? [] : .isButton)
        .accessibilityAction {
            if !tile.isOther { select() }
        }
    }

    private func fillOpacity(isHovered: Bool, isSelected: Bool, isHighContrast: Bool) -> Double {
        let base = isHighContrast ? 0.3 : 0.2
        return isSelected || isHovered ? base + 0.14 : base
    }

    /// Larger tiles show more: the name, then the amount, then both directions.
    @ViewBuilder
    private var labels: some View {
        if size.width >= 64, size.height >= 34 {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if let flag = tile.flag {
                        Text(verbatim: flag)
                    }
                    Text(verbatim: tile.title)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                .font(.callout)
                if size.height >= 56 {
                    Text(verbatim: tile.valueText + " · " + Format.percent(tile.share))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if size.height >= 76, size.width >= 150, !tile.directionText.isEmpty {
                    Text(verbatim: tile.directionText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            .padding(8)
            .frame(width: size.width, alignment: .leading)
        }
    }
}
