import PulseDeckCore
import PulseDeckTelemetry
import SwiftUI

/// Virtual Machines section: the machines of the VM programs found on this Mac (Colima, Lima,
/// UTM, Tart, Parallels …) with their host-side resource use, Start / Stop / Restart, and — where
/// the program allows it — changing their CPUs, memory and disk. Sampled only while visible.
///
/// Layout: summary (totals with charts) and the program strip above a table; an inspector on
/// the right shows the selected machine with full-size charts and facts.
struct VirtualMachinesView: View {
    @Environment(AppState.self) private var appState
    private let controller = VMActionController.shared

    @State private var searchText = ""
    @State private var providerFilter: String?
    @State private var sortOrder = [
        KeyPathComparator(\VirtualMachineSnapshot.providerName),
        KeyPathComparator(\VirtualMachineSnapshot.name),
    ]
    @State private var selection = Set<VirtualMachineSnapshot.ID>()
    @State private var pendingAction: PendingAction?
    @State private var editingID: VirtualMachineSnapshot.ID?
    @State private var showsInspector = true

    private var snapshot: VirtualMachinesSnapshot? { appState.latestVMs?.value }

    private var selected: [VirtualMachineSnapshot] {
        (snapshot?.machines ?? []).filter { selection.contains($0.id) }
    }

    /// Filtered by program and search, sorted by the chosen column; running machines first.
    private func rows(in snapshot: VirtualMachinesSnapshot) -> [VirtualMachineSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = snapshot.machines.filter { machine in
            (providerFilter == nil || machine.providerID == providerFilter)
                && (query.isEmpty || Self.matches(machine, query: query))
        }
        // Ties keep the chosen order (the offset is part of the key).
        return filtered.sorted(using: sortOrder)
            .enumerated()
            .sorted { ($0.element.state.listRank, $0.offset) < ($1.element.state.listRank, $1.offset) }
            .map(\.element)
    }

    private static func matches(_ machine: VirtualMachineSnapshot, query: String) -> Bool {
        machine.name.localizedCaseInsensitiveContains(query)
            || machine.providerName.localizedCaseInsensitiveContains(query)
            || machine.guestDescription.localizedCaseInsensitiveContains(query)
            || (machine.ipAddress?.localizedCaseInsensitiveContains(query) ?? false)
    }

    var body: some View {
        content
            .navigationTitle(Text(AppSection.machines.title))
            .searchable(text: $searchText, prompt: Text("Name, program, system or IP address"))
            .toolbar { toolbarContent }
            .confirmationDialog(confirmationTitle, isPresented: isConfirming, titleVisibility: .visible, presenting: pendingAction) { pending in
                Button(pending.action == .stop ? "Stop" : "Restart", role: .destructive) {
                    controller.perform(pending.action, on: pending.machines)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("The virtual machine is shut down by its program. Unsaved work inside the machine can be lost.")
            }
            .alert(Text(verbatim: controller.failure?.title ?? ""), isPresented: isShowingFailure, presenting: controller.failure) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(verbatim: failure.message)
            }
            .sheet(isPresented: isEditing) {
                if let machine = editedMachine {
                    VMResourceEditor(machine: machine) { resources, plan in
                        controller.apply(resources, to: machine, plan: plan)
                    }
                } else {
                    ContentUnavailableView {
                        Label("Virtual Machine Not Found", systemImage: AppSection.machines.systemImage)
                    } description: {
                        Text("The virtual machine is no longer listed.")
                    } actions: {
                        Button("Close") { editingID = nil }
                    }
                    .frame(minWidth: 360, minHeight: 240)
                }
            }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch appState.latestVMs {
        case .unavailable(.notApplicable)?:
            NoVMSoftwareView()
        case .unavailable(.awaitingBaseline)?, .notSampled?, nil:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .unavailable(let reason)?:
            ContentUnavailableView {
                Label("Virtual Machines", systemImage: AppSection.machines.systemImage)
            } description: {
                Text("Not Available")
                Text(reason.explanation)
            }
        case .available(let snapshot)?:
            if snapshot.machines.isEmpty {
                NoVirtualMachinesView(providers: snapshot.providers)
            } else {
                list(snapshot)
            }
        }
    }

    private func list(_ snapshot: VirtualMachinesSnapshot) -> some View {
        let visible = rows(in: snapshot)
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VMSummaryHeader(machines: snapshot.machines, history: appState.vmHistory.aggregate)
                VMProviderStrip(providers: snapshot.providers, machines: snapshot.machines, filter: $providerFilter)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            table(visible, in: snapshot)
                .overlay {
                    if visible.isEmpty {
                        ContentUnavailableView {
                            Label("No Matching Virtual Machines", systemImage: "magnifyingglass")
                        } description: {
                            Text("Change the search or choose another program.")
                        }
                    }
                }
            Divider()
            footer(shown: visible.count, in: snapshot)
        }
        .inspector(isPresented: $showsInspector) {
            VMInspectorView(
                selection: selected,
                providers: snapshot.providers,
                history: appState.vmHistory,
                isBusy: { controller.isBusy($0) },
                onEditResources: { editingID = $0.id }
            )
            .inspectorColumnWidth(min: 280, ideal: 340, max: 480)
        }
    }

    private func table(_ rows: [VirtualMachineSnapshot], in snapshot: VirtualMachinesSnapshot) -> some View {
        // Eleven columns are more than one builder takes, so they are grouped.
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            Group {
                TableColumn("Name", value: \.name) { machine in
                    HStack(spacing: 6) {
                        VMStatusSymbol(state: machine.state)
                        Text(verbatim: machine.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if controller.isBusy(machine) {
                            ProgressView()
                                .controlSize(.mini)
                                .accessibilityLabel(Text("Working"))
                        }
                    }
                }
                .width(min: 140, ideal: 190)
                TableColumn("Program", value: \.providerName) { machine in
                    Text(verbatim: machine.providerName)
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 110)
                TableColumn("System", value: \.guestDescription) { machine in
                    MetricStateText(state: MetricState<String>.text(machine.guestDescription), isCompact: true)
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 110)
                TableColumn("State", value: \.stateLabel) { machine in
                    Text(verbatim: machine.state.label)
                        .lineLimit(1)
                        .foregroundStyle(machine.state.isRunning ? .primary : .secondary)
                }
                .width(min: 70, ideal: 84)
                TableColumn("CPUs", value: \.cpusSortValue) { machine in
                    MetricStateText(state: MetricState<String>.text(machine.resources.cpus.map { String($0) }), isCompact: true)
                }
                .width(min: 40, ideal: 50)
                TableColumn("Memory", value: \.configuredMemorySortValue) { machine in
                    MetricStateText(state: MetricState<String>.text(machine.resources.memoryBytes.map(Format.memory)), isCompact: true)
                }
                .width(min: 60, ideal: 74)
            }
            Group {
                TableColumn("Disk", value: \.configuredDiskSortValue) { machine in
                    MetricStateText(state: MetricState<String>.text(machine.resources.diskBytes.map(Format.memory)), isCompact: true)
                }
                .width(min: 60, ideal: 74)
                TableColumn("Host CPU", value: \.hostCPUSortValue) { machine in
                    MetricStateText(state: machine.usage.cpu.map(Format.processCPU), isCompact: true)
                }
                .width(min: 60, ideal: 74)
                TableColumn("Resident", value: \.residentMemorySortValue) { machine in
                    MetricStateText(state: machine.usage.memoryBytes.map(Format.memory), isCompact: true)
                }
                .width(min: 66, ideal: 80)
                TableColumn("Disk R/W", value: \.diskSortValue) { machine in
                    MetricStateText(state: Self.diskText(machine.usage), isCompact: true)
                        .lineLimit(1)
                }
                .width(min: 110, ideal: 150)
                TableColumn("IP Address", value: \.ipSortValue) { machine in
                    MetricStateText(state: MetricState<String>.text(machine.ipAddress), isCompact: true)
                        .lineLimit(1)
                }
                .width(min: 80, ideal: 110)
            }
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: VirtualMachineSnapshot.ID.self) { ids in
            let targets = snapshot.machines.filter { ids.contains($0.id) }
            Button("Start") { request(.start, for: targets) }
                .disabled(!targets.contains { $0.canStartNow })
            Button("Stop…") { request(.stop, for: targets) }
                .disabled(!targets.contains { $0.canStopNow })
            Button("Restart…") { request(.restart, for: targets) }
                .disabled(!targets.contains { $0.canRestartNow })
            if targets.count == 1, let machine = targets.first, machine.capabilities.canEditAnything {
                Divider()
                Button("Resources…") { editingID = machine.id }
                    .disabled(controller.isBusy(machine))
            }
            Divider()
            Button("Copy Name") {
                ProcessActions.copy(targets.map(\.name).joined(separator: "\n"))
            }
            .disabled(targets.isEmpty)
            Button("Copy IP Address") {
                ProcessActions.copy(targets.compactMap(\.ipAddress).joined(separator: "\n"))
            }
            .disabled(!targets.contains { $0.ipAddress != nil })
        }
    }

    private static func diskText(_ usage: VMUsage) -> MetricState<String> {
        usage.diskReadBytesPerSecond.flatMap { read in
            usage.diskWriteBytesPerSecond.map { write in "R \(Format.rate(read)) · W \(Format.rate(write))" }
        }
    }

    private func footer(shown: Int, in snapshot: VirtualMachinesSnapshot) -> some View {
        let running = snapshot.machines.count(where: { $0.state.isRunning })
        return HStack(spacing: 12) {
            if shown == snapshot.machines.count {
                Text("\(running) running · \(snapshot.machines.count) virtual machines")
            } else {
                Text("\(running) running · \(shown) of \(snapshot.machines.count) shown")
            }
            Spacer()
            // Visible, not only a tooltip: these numbers are not what the guest itself reports.
            Label {
                Text("CPU, memory and disk use are measured on this Mac (host side).")
            } icon: {
                Image(systemName: "info.circle")
            }
            .help(Text("They show what the processes that run each virtual machine use on this Mac. What happens inside the guest is not readable without an agent in the guest."))
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                request(.start, for: selected)
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .help(Text("Start the selected virtual machines"))
            .disabled(!selected.contains { $0.canStartNow && !controller.isBusy($0) })
            Button {
                request(.stop, for: selected)
            } label: {
                Label("Stop", systemImage: "stop.fill")
            }
            .help(Text("Stop the selected virtual machines"))
            .disabled(!selected.contains { $0.canStopNow && !controller.isBusy($0) })
            Button {
                request(.restart, for: selected)
            } label: {
                Label("Restart", systemImage: "arrow.clockwise")
            }
            .help(Text("Restart the selected virtual machines"))
            .disabled(!selected.contains { $0.canRestartNow && !controller.isBusy($0) })
            if snapshot?.machines.contains(where: { $0.capabilities.canEditAnything }) == true {
                Button {
                    editingID = selected.first?.id
                } label: {
                    Label("Resources…", systemImage: "slider.horizontal.3")
                }
                .help(Text("Change the CPUs, memory and disk of the selected virtual machine"))
                .disabled(!canEditSelection)
            }
            Button {
                showsInspector.toggle()
            } label: {
                Label("Inspector", systemImage: "sidebar.trailing")
            }
            .help(Text("Show or hide the details of the selected virtual machine"))
            .disabled(snapshot?.machines.isEmpty ?? true)
        }
    }

    /// Exactly one machine is selected and its program lets PulseDeck change something.
    private var canEditSelection: Bool {
        guard selected.count == 1, let machine = selected.first else { return false }
        return machine.capabilities.canEditAnything && !controller.isBusy(machine)
    }

    // MARK: - Actions

    private struct PendingAction {
        let action: VMAction
        let machines: [VirtualMachineSnapshot]
    }

    /// Start runs at once; Stop and Restart interrupt running work and are confirmed first.
    private func request(_ action: VMAction, for machines: [VirtualMachineSnapshot]) {
        let targets = machines.filter { $0.canPerformNow(action) && !controller.isBusy($0) }
        guard !targets.isEmpty else { return }
        if action == .start {
            controller.perform(action, on: targets)
        } else {
            pendingAction = PendingAction(action: action, machines: targets)
        }
    }

    private var editedMachine: VirtualMachineSnapshot? {
        guard let editingID else { return nil }
        return snapshot?.machines.first { $0.id == editingID }
    }

    private var isEditing: Binding<Bool> {
        Binding { editingID != nil } set: { if !$0 { editingID = nil } }
    }

    private var isConfirming: Binding<Bool> {
        Binding { pendingAction != nil } set: { if !$0 { pendingAction = nil } }
    }

    private var isShowingFailure: Binding<Bool> {
        Binding { controller.failure != nil } set: { if !$0 { controller.failure = nil } }
    }

    private var confirmationTitle: Text {
        guard let pending = pendingAction else { return Text(verbatim: "") }
        let verb = pending.action == .stop ? String(localized: "Stop") : String(localized: "Restart")
        if pending.machines.count == 1, let machine = pending.machines.first {
            return Text("\(verb) “\(machine.name)”?")
        }
        return Text("\(verb) \(pending.machines.count) virtual machines?")
    }
}

// MARK: - Empty states

/// None of the supported programs was found.
private struct NoVMSoftwareView: View {
    private var programs: String {
        VMProviderID.allCases.map(\.displayName).formatted(.list(type: .and))
    }

    var body: some View {
        ContentUnavailableView {
            Label("No Virtual Machine Software", systemImage: AppSection.machines.systemImage)
        } description: {
            Text("PulseDeck looks for \(programs). None of them was found on this Mac.")
            Text("Install one and create a virtual machine; it appears here with its live resource use.")
        }
    }
}

/// Programs are installed, but they have no machines yet.
private struct NoVirtualMachinesView: View {
    let providers: [VMProviderStatus]

    var body: some View {
        ContentUnavailableView {
            Label("No Virtual Machines", systemImage: AppSection.machines.systemImage)
        } description: {
            Text("The installed programs do not have a virtual machine yet.")
            ForEach(providers) { provider in
                let hint = VMProviderID(rawValue: provider.id)?.creationHint
                Text(verbatim: [provider.name, hint].compactMap { $0 }.joined(separator: ": "))
                if let note = provider.note {
                    Text(verbatim: note)
                        .font(.caption)
                }
            }
        }
    }
}
