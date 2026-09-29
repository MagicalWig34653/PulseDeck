/// Positions for drawing a tree left to right (root on the left): each node's column is its
/// depth; leaves take consecutive rows and a parent sits centred between its first and last
/// child, so no two nodes overlap and every edge runs rightwards.
public struct TreeLayout<ID: Hashable & Sendable>: Sendable {
    public struct Position: Hashable, Sendable {
        public var column: Int
        /// Fractional for parents (centred on their children).
        public var row: Double
    }

    public private(set) var positions: [ID: Position] = [:]
    /// Rows used (= number of leaves, at least 1).
    public private(set) var rowCount = 0
    public private(set) var columnCount = 0

    /// - Parameters:
    ///   - roots: top-level nodes, laid out one below the other.
    ///   - children: a node's children in display order.
    public init<Node>(roots: [Node], id: (Node) -> ID, children: (Node) -> [Node]) {
        var nextRow = 0
        func place(_ node: Node, column: Int) -> Double {
            columnCount = max(columnCount, column + 1)
            let kids = children(node)
            let row: Double
            if kids.isEmpty {
                row = Double(nextRow)
                nextRow += 1
            } else {
                let rows = kids.map { place($0, column: column + 1) }
                row = ((rows.first ?? 0) + (rows.last ?? 0)) / 2
            }
            positions[id(node)] = Position(column: column, row: row)
            return row
        }
        for root in roots {
            _ = place(root, column: 0)
        }
        rowCount = max(nextRow, 1)
    }
}
