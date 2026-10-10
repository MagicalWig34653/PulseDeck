import PulseDeckCore
import SwiftUI

/// The outline table of the Traffic page: groups with their destinations beneath them. The rows
/// arrive sorted and formatted (see `TrafficBuilder`), so the table never sorts: header clicks only
/// change `sortOrder`, which the page turns into a new build. Disclosure is a button in the name
/// cell, which keeps the table an ordinary flat `Table`.
struct TrafficTable: View {
    let rows: [TrafficRow]
    @Binding var sortOrder: [KeyPathComparator<TrafficRow>]
    @Binding var selection: Set<TrafficRow.ID>
    let hover: TrafficHover
    let toggleExpansion: (String) -> Void

    private static let indentation: CGFloat = 18
    private static let disclosureWidth: CGFloat = 14

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.nameSort) { row in
                nameCell(row)
            }
            .width(min: 200, ideal: 300)
            TableColumn("Country") { row in
                Text(verbatim: row.location)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .width(min: 90, ideal: 120)
            TableColumn("Provider · Service") { row in
                Text(verbatim: row.providerService.isEmpty ? TrafficFormat.dash : row.providerService)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.secondary)
            }
            .width(min: 110, ideal: 170)
            TableColumn("Received", value: \.receivedSort) { row in
                numeric(row.receivedText)
            }
            .width(min: 70, ideal: 84)
            .alignment(.trailing)
            TableColumn("Sent", value: \.sentSort) { row in
                numeric(row.sentText)
            }
            .width(min: 70, ideal: 84)
            .alignment(.trailing)
            TableColumn("Total", value: \.totalSort) { row in
                totalCell(row)
            }
            .width(min: 90, ideal: 120)
            .alignment(.trailing)
            TableColumn("↓ Rate", value: \.receiveRateSort) { row in
                numeric(row.receiveRateText)
            }
            .width(min: 70, ideal: 84)
            .alignment(.trailing)
            TableColumn("↑ Rate", value: \.sendRateSort) { row in
                numeric(row.sendRateText)
            }
            .width(min: 70, ideal: 84)
            .alignment(.trailing)
            TableColumn("Flows", value: \.flowsSort) { row in
                numeric(row.flowsText)
            }
            .width(min: 60, ideal: 70)
            .alignment(.trailing)
            TableColumn("Last Seen", value: \.lastSeenSort) { row in
                Text(verbatim: row.lastSeenText)
                    .monospacedDigit()
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 110)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: TrafficRow.ID.self) { ids in
            let targets = rows.filter { ids.contains($0.id) }
            let addresses = targets.flatMap { row in
                row.destination.map { [$0.address] } ?? row.members.map(\.address)
            }
            Button("Copy Address") {
                ProcessActions.copy(addresses.joined(separator: "\n"))
            }
            .disabled(addresses.isEmpty)
            Button("Copy Host Name") {
                ProcessActions.copy(targets.compactMap(\.hostName).joined(separator: "\n"))
            }
            .disabled(!targets.contains { $0.hostName != nil })
            if let group = targets.first(where: \.isExpandable), targets.count == 1 {
                Divider()
                if group.isExpanded {
                    Button("Collapse") { toggleExpansion(group.groupID) }
                } else {
                    Button("Expand") { toggleExpansion(group.groupID) }
                }
            }
        }
    }

    // MARK: Cells

    private func nameCell(_ row: TrafficRow) -> some View {
        HStack(spacing: 4) {
            if row.depth > 0 {
                Color.clear.frame(width: CGFloat(row.depth) * Self.indentation, height: 1)
            }
            if row.isExpandable {
                Button {
                    toggleExpansion(row.groupID)
                } label: {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: Self.disclosureWidth)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(row.isExpanded ? Text("Collapse") : Text("Expand"))
            } else if row.reservesDisclosureSpace {
                Color.clear.frame(width: Self.disclosureWidth, height: 1)
            }
            if let flag = row.flag {
                Text(verbatim: flag)
                    .accessibilityLabel(Text(verbatim: row.location.isEmpty ? row.title : row.location))
            }
            Text(verbatim: row.title)
                .fontWeight(row.kind == .group ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.middle)
            if let detail = row.detail {
                Text(verbatim: detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside {
                hover.groupID = row.groupID
            } else if hover.groupID == row.groupID {
                hover.groupID = nil
            }
        }
    }

    private func numeric(_ text: String) -> some View {
        Text(verbatim: text)
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The total with a bar behind it showing the row's share of all traffic shown.
    private func totalCell(_ row: TrafficRow) -> some View {
        numeric(row.totalText)
            .background(alignment: .leading) {
                if row.share > 0 {
                    Rectangle()
                        .fill(TrafficPalette.color(forGroup: row.groupID).opacity(0.28))
                        .scaleEffect(x: row.share, y: 1, anchor: .leading)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityValue(Text(verbatim: row.hasCounters ? String(localized: "\(Format.percent(row.share)) of traffic") : ""))
    }
}
