import Foundation

/// An axis-aligned rectangle in the treemap's own coordinate space (platform-independent, so
/// the layout can be unit tested without CoreGraphics).
public struct TreemapRect: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let zero = TreemapRect(x: 0, y: 0, width: 0, height: 0)

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var area: Double { width * height }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
}

/// One tile of the Traffic treemap: a group, or the merged remainder ("Other").
public struct TrafficTreemapEntry: Hashable, Sendable, Identifiable {
    /// The group ID, or `TrafficTreemap.otherID` for the merged remainder.
    public var id: String
    public var weight: Double
    /// Fraction of the total weight, 0…1.
    public var share: Double
    /// How many groups the tile stands for (1, or more for "Other").
    public var memberCount: Int

    public var isOther: Bool { id == TrafficTreemap.otherID }

    public init(id: String, weight: Double, share: Double, memberCount: Int) {
        self.id = id
        self.weight = weight
        self.share = share
        self.memberCount = memberCount
    }
}

/// Treemap maths for the Traffic section: which groups get a tile, and a squarified layout
/// (Bruls, Huizing, van Wijk) that keeps tiles close to square so labels stay readable.
public enum TrafficTreemap {
    /// ID of the merged "Other" tile. Cannot collide with a group key.
    public static let otherID = "\u{0}other"

    /// Chooses the tiles: the largest groups with at least `minimumShare` of the total, at most
    /// `maximumTiles` including a merged "Other" tile for everything else. Groups without weight
    /// get no tile. Sorted by weight, descending; ties keep the input order.
    public static func entries(ids: [String], weights: [Double], maximumTiles: Int, minimumShare: Double) -> [TrafficTreemapEntry] {
        precondition(ids.count == weights.count, "ids and weights must match")
        let order = ids.indices
            .filter { weights[$0] > 0 && weights[$0].isFinite }
            .sorted { weights[$0] != weights[$1] ? weights[$0] > weights[$1] : $0 < $1 }
        let total = order.reduce(0) { $0 + weights[$1] }
        guard total > 0, maximumTiles > 0 else { return [] }

        var kept: [TrafficTreemapEntry] = []
        var restWeight = 0.0
        var restCount = 0
        var restOnly: Int?
        for index in order {
            let share = weights[index] / total
            // One slot stays free for "Other" while there are more candidates than slots.
            if kept.count < maximumTiles - 1 && share >= minimumShare {
                kept.append(TrafficTreemapEntry(id: ids[index], weight: weights[index], share: share, memberCount: 1))
            } else {
                restWeight += weights[index]
                restCount += 1
                restOnly = restCount == 1 ? index : nil
            }
        }
        // A lone leftover is shown as itself: "Other" with one member would only hide its name.
        if restCount == 1, let index = restOnly, kept.count < maximumTiles {
            kept.append(TrafficTreemapEntry(id: ids[index], weight: weights[index], share: weights[index] / total, memberCount: 1))
        } else if restCount > 0 {
            kept.append(TrafficTreemapEntry(id: otherID, weight: restWeight, share: restWeight / total, memberCount: restCount))
        }
        return kept
    }

    /// Squarified treemap: a rectangle for each weight, filling `bounds`, with areas proportional
    /// to the weights. The result is in input order; weights that are not positive get
    /// `TreemapRect.zero`.
    public static func layout(weights: [Double], in bounds: TreemapRect) -> [TreemapRect] {
        var result = [TreemapRect](repeating: .zero, count: weights.count)
        guard bounds.width > 0, bounds.height > 0 else { return result }
        let order = weights.indices
            .filter { weights[$0] > 0 && weights[$0].isFinite }
            .sorted { weights[$0] != weights[$1] ? weights[$0] > weights[$1] : $0 < $1 }
        let total = order.reduce(0) { $0 + weights[$1] }
        guard total > 0 else { return result }
        let scale = bounds.area / total
        let areas = order.map { weights[$0] * scale }

        var free = bounds
        var start = 0
        while start < areas.count, free.width > 0, free.height > 0 {
            let side = min(free.width, free.height)
            var end = start + 1
            var sum = areas[start]
            // Grow the row while the worst aspect ratio does not get worse.
            while end < areas.count {
                let extended = sum + areas[end]
                let before = worstRatio(sum: sum, largest: areas[start], smallest: areas[end - 1], side: side)
                let after = worstRatio(sum: extended, largest: areas[start], smallest: areas[end], side: side)
                guard after <= before else { break }
                sum = extended
                end += 1
            }
            if free.width >= free.height {
                // A column along the left edge.
                let columnWidth = sum / free.height
                var y = free.y
                for index in start..<end {
                    let height = areas[index] / columnWidth
                    result[order[index]] = TreemapRect(x: free.x, y: y, width: columnWidth, height: height)
                    y += height
                }
                free.x += columnWidth
                free.width -= columnWidth
            } else {
                // A row along the top edge.
                let rowHeight = sum / free.width
                var x = free.x
                for index in start..<end {
                    let width = areas[index] / rowHeight
                    result[order[index]] = TreemapRect(x: x, y: free.y, width: width, height: rowHeight)
                    x += width
                }
                free.y += rowHeight
                free.height -= rowHeight
            }
            start = end
        }
        return result
    }

    /// Worst aspect ratio in a row of total area `sum` laid along a side of length `side`.
    private static func worstRatio(sum: Double, largest: Double, smallest: Double, side: Double) -> Double {
        let squaredSide = side * side
        let squaredSum = sum * sum
        return max(squaredSide * largest / squaredSum, squaredSum / (squaredSide * smallest))
    }
}
