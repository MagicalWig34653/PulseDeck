import PulseDeckCore
import SwiftUI

/// Traffic section: where this Mac's network traffic goes at layer 3 (remote IP addresses),
/// grouped by destination, country, provider, service, process, protocol or port, with the bytes
/// exchanged with each since PulseDeck started recording and the layer 4 breakdown in the
/// inspector. The flows are read only while this section is visible (or when Settings asks for
/// background recording).
struct TrafficView: View {
    @Environment(AppState.self) private var appState

    @AppStorage(Keys.grouping) private var storedGrouping = ""
    @AppStorage(Keys.hidesLocalNetwork) private var hidesLocalNetwork = false
    @AppStorage(Keys.hidesThisMac) private var hidesThisMac = true
    @AppStorage(Keys.onlyActive) private var onlyActive = false
    @AppStorage(PreferenceKey.resolveTrafficHostNames) private var resolvesHostNames = true

    @State private var model = TrafficModel()
    @State private var hover = TrafficHover()
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\TrafficRow.totalSort, order: .reverse)]
    @State private var selection = Set<TrafficRow.ID>()
    @State private var showsInspector = false
    @State private var isConfirmingReset = false

    private enum Keys {
        static let grouping = "trafficGrouping"
        static let hidesLocalNetwork = "trafficHidesLocalNetwork"
        static let hidesThisMac = "trafficHidesThisMac"
        static let onlyActive = "trafficOnlyActive"
    }

    /// Provider is the most telling default; without the database every provider is "Unknown", so
    /// the individual destinations are shown instead.
    private var grouping: FlowGrouping {
        FlowGrouping(rawValue: storedGrouping) ?? (TrafficClassifier.hasGeoData ? .provider : .destination)
    }

    private var filter: TrafficFilter {
        TrafficFilter(hidesLocalNetwork: hidesLocalNetwork, hidesThisMac: hidesThisMac, onlyActive: onlyActive,
                      searchText: searchText.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private var controls: TrafficControls {
        TrafficControls(
            grouping: grouping,
            filter: filter,
            sort: sortOrder.compactMap { TrafficSortOrder($0) }.first ?? .default,
            expanded: model.expanded,
            rowLimit: model.rowLimit,
            hostNamesVersion: model.hostNamesVersion,
            refreshToken: model.refreshToken
        )
    }

    private var selectedRows: [TrafficRow] {
        model.snapshot.rows.filter { selection.contains($0.id) }
    }

    private var selectedGroupIDs: Set<String> {
        Set(selection.compactMap { model.snapshot.rowsByID[$0]?.groupID })
    }

    var body: some View {
        let currentControls = self.controls
        content
            .navigationTitle(Text(AppSection.traffic.title))
            .searchable(text: $searchText, prompt: Text("Address, host, country, provider, service or process"))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        isConfirmingReset = true
                    } label: {
                        Label("Reset Totals", systemImage: "arrow.counterclockwise")
                    }
                    .help(Text("Forget the totals and start counting again"))
                    Button {
                        showsInspector.toggle()
                    } label: {
                        Label("Inspector", systemImage: "sidebar.trailing")
                    }
                    .help(Text("Show or hide the details of the selection"))
                }
            }
            .confirmationDialog("Reset traffic totals?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
                Button("Reset Totals", role: .destructive) {
                    appState.resetFlowLedger()
                    model.didResetLedger()
                    selection = []
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("The bytes counted for every destination are forgotten. PulseDeck starts counting from zero.")
            }
            .inspector(isPresented: $showsInspector) {
                TrafficInspector(rows: selectedRows, hostNames: model.hostNames)
                    .inspectorColumnWidth(min: 280, ideal: 340, max: 520)
            }
            .onChange(of: selection) {
                if !selection.isEmpty { showsInspector = true }
            }
            .onChange(of: storedGrouping) {
                model.expanded = []
                model.rowLimit = TrafficModel.pageSize
                selection = []
            }
            .task(id: currentControls) {
                await model.refreshLoop(appState: appState, controls: currentControls)
            }
            .task(id: resolvesHostNames) {
                if resolvesHostNames {
                    await model.resolveHostNamesLoop()
                } else {
                    model.clearHostNames()
                }
            }
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        let ledgerIsEmpty = model.snapshot.ledgerDestinationCount == 0
        if let reason = appState.latestFlows?.unavailableReason, !reason.isTransient, ledgerIsEmpty {
            ContentUnavailableView {
                Label("Traffic", systemImage: AppSection.traffic.systemImage)
            } description: {
                Text("Not Available")
                Text(reason.explanation)
            }
        } else if !model.hasBuilt || (ledgerIsEmpty && isWaitingForFirstSample) {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            page
        }
    }

    /// No flow snapshot has arrived yet (the section was just opened).
    private var isWaitingForFirstSample: Bool {
        switch appState.latestFlows {
        case nil, .notSampled?: true
        case .unavailable(let reason)?: reason.isTransient
        case .available?: false
        }
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !model.snapshot.hasByteCounters {
                    countersBanner
                }
                TrafficHeader(model: model, filter: filter)
                controlsBar
                TrafficTreemapView(
                    tiles: model.snapshot.tiles,
                    grouping: grouping,
                    hasByteCounters: model.snapshot.hasByteCounters,
                    selectedGroupIDs: selectedGroupIDs,
                    hover: hover,
                    select: { groupID in
                        selection = [TrafficRow.rowID(forGroup: groupID)]
                    }
                )
                tableSection
                SourceNote(text: sourceNote)
                    .frame(maxWidth: 760, alignment: .leading)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var countersBanner: some View {
        Label {
            Text("Byte counters unavailable — showing connections only")
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.18), in: .rect(cornerRadius: 8))
    }

    private var sourceNote: LocalizedStringResource {
        TrafficClassifier.hasGeoData
            ? "Bytes per destination come from the kernel's network statistics control (an undocumented interface; the same source as nettop). Totals only cover the time PulseDeck was recording. Recording stops when the Traffic tab is closed unless “Record traffic while the window is closed” is on in Settings. Countries and providers come from an offline database and can be wrong; host names are reverse DNS lookups."
            : "Bytes per destination come from the kernel's network statistics control (an undocumented interface; the same source as nettop). Totals only cover the time PulseDeck was recording. Recording stops when the Traffic tab is closed unless “Record traffic while the window is closed” is on in Settings. The country and provider database is not part of this build, so those are shown as Unknown."
    }

    // MARK: Controls

    private var groupingBinding: Binding<FlowGrouping> {
        Binding { grouping } set: { storedGrouping = $0.rawValue }
    }

    private var controlsBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                groupingPicker
                Spacer(minLength: 8)
                filterToggles
            }
            VStack(alignment: .leading, spacing: 8) {
                groupingPicker
                filterToggles
            }
        }
    }

    private var groupingPicker: some View {
        Picker("Group by", selection: groupingBinding) {
            ForEach(FlowGrouping.allCases, id: \.self) { option in
                Text(verbatim: option.title).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(maxWidth: 600)
    }

    private var filterToggles: some View {
        HStack(spacing: 8) {
            Toggle("Hide local network", isOn: $hidesLocalNetwork)
            Toggle("Hide this Mac", isOn: $hidesThisMac)
                .help(Text("Hide traffic that never leaves this Mac (loopback)"))
            Toggle("Only active", isOn: $onlyActive)
                .help(Text("Hide destinations without an open connection"))
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }

    // MARK: Table

    private var tableSection: some View {
        let snapshot = model.snapshot
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: grouping.title)
                    .font(.headline)
                Spacer()
                if grouping != .destination {
                    Button("Expand All") {
                        model.expanded = Set(snapshot.rows.filter(\.isExpandable).map(\.groupID))
                    }
                    Button("Collapse All") {
                        model.expanded = []
                    }
                    .disabled(model.expanded.isEmpty)
                }
            }
            .controlSize(.small)

            TrafficTable(
                rows: snapshot.rows,
                sortOrder: $sortOrder,
                selection: $selection,
                hover: hover,
                toggleExpansion: { model.toggleExpansion(of: $0) }
            )
            .frame(height: Self.tableHeight(rows: snapshot.rows.count))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
            .overlay {
                if snapshot.rows.isEmpty {
                    Group {
                        if snapshot.ledgerDestinationCount == 0 {
                            Text("No traffic recorded yet")
                        } else {
                            Text("No destinations match the filters")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }

            HStack {
                Text("\(snapshot.rows.count) rows")
                if snapshot.hiddenRowCount > 0 {
                    Text(verbatim: "·")
                    Text("\(snapshot.hiddenRowCount) more not shown")
                    Button("Show More") {
                        model.showMoreRows()
                    }
                }
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private static func tableHeight(rows: Int) -> CGFloat {
        let rowHeight: CGFloat = 26
        let headerHeight: CGFloat = 34
        return min(max(CGFloat(rows) * rowHeight + headerHeight, 160), 560)
    }
}
