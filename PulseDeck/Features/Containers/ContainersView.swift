import PulseDeckCore
import PulseDeckTelemetry
import SwiftUI

/// Containers section: local Docker containers (Colima, Docker Desktop or any engine on a local
/// Unix socket) with their resource use, and Start / Stop / Restart. Sampled only while visible.
struct ContainersView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\ContainerSnapshot.name)]
    @State private var selection = Set<ContainerSnapshot.ID>()
    @State private var pendingAction: PendingAction?
    @State private var failure: String?
    @State private var busy = Set<ContainerSnapshot.ID>()

    private var snapshot: ContainersSnapshot? { appState.latestContainers?.value }

    private var rows: [ContainerSnapshot] {
        let all = snapshot?.containers ?? []
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? all : all.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.image.localizedCaseInsensitiveContains(query)
                || ($0.composeProject?.localizedCaseInsensitiveContains(query) ?? false)
        }
        // Running containers first, then the chosen order.
        return filtered.sorted(using: sortOrder).sorted { $0.isRunning && !$1.isRunning }
    }

    private var selected: [ContainerSnapshot] {
        (snapshot?.containers ?? []).filter { selection.contains($0.id) }
    }

    var body: some View {
        content
            .navigationTitle(Text(AppSection.containers.title))
            .searchable(text: $searchText, prompt: Text("Name, image or project"))
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        request(.start, for: selected)
                    } label: {
                        Label("Start", systemImage: "play.fill")
                    }
                    .help(Text("Start the selected containers"))
                    .disabled(!selected.contains { !$0.isRunning })
                    Button {
                        request(.stop, for: selected)
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .help(Text("Stop the selected containers"))
                    .disabled(!selected.contains(where: \.isRunning))
                    Button {
                        request(.restart, for: selected)
                    } label: {
                        Label("Restart", systemImage: "arrow.clockwise")
                    }
                    .help(Text("Restart the selected containers"))
                    .disabled(!selected.contains(where: \.isRunning))
                }
            }
            .confirmationDialog(confirmationTitle, isPresented: isConfirming, titleVisibility: .visible, presenting: pendingAction) { pending in
                Button(pending.action == .stop ? "Stop" : "Restart", role: .destructive) {
                    perform(pending.action, on: pending.containers)
                }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Processes in the container receive SIGTERM and are killed if they do not exit within the container's stop timeout.")
            }
            .alert(Text("The container action failed"), isPresented: isShowingFailure, presenting: failure) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(verbatim: failure)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch appState.latestContainers {
        case .unavailable(.notApplicable)?:
            ContentUnavailableView {
                Label("No Container Engine", systemImage: AppSection.containers.systemImage)
            } description: {
                Text("No running Docker engine was found. Start Colima with “colima start” (or Docker Desktop) and its containers appear here.")
            }
        case .unavailable(let reason)? where !reason.isTransient:
            ContentUnavailableView {
                Label("Containers", systemImage: AppSection.containers.systemImage)
            } description: {
                Text("Not Available")
                Text(reason.explanation)
            }
        case .available?, .unavailable?:
            VStack(spacing: 0) {
                table
                Divider()
                footer
            }
        case .notSampled?, nil:
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { container in
                HStack(spacing: 6) {
                    Circle()
                        .fill(container.isRunning ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(verbatim: container.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if busy.contains(container.id) {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            .width(min: 140, ideal: 200)
            TableColumn("Image", value: \.image) { container in
                Text(verbatim: container.image)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .width(min: 100, ideal: 170)
            TableColumn("Status", value: \.status) { container in
                Text(verbatim: container.status)
                    .lineLimit(1)
                    .foregroundStyle(container.isRunning ? .primary : .secondary)
            }
            .width(min: 90, ideal: 130)
            TableColumn("CPU", value: \.cpuSortValue) { container in
                MetricStateText(state: container.cpu.map(Format.processCPU), isCompact: true)
            }
            .width(min: 50, ideal: 64)
            TableColumn("Memory", value: \.memorySortValue) { container in
                MetricStateText(state: container.memoryBytes.map(Format.memory), isCompact: true)
            }
            .width(min: 70, ideal: 84)
            TableColumn("Net ↓", value: \.receivedSortValue) { container in
                MetricStateText(state: container.networkReceivedBytesPerSecond.map(Format.rate), isCompact: true)
            }
            .width(min: 64, ideal: 80)
            TableColumn("Net ↑", value: \.sentSortValue) { container in
                MetricStateText(state: container.networkSentBytesPerSecond.map(Format.rate), isCompact: true)
            }
            .width(min: 64, ideal: 80)
            TableColumn("Ports") { container in
                Text(verbatim: container.ports.joined(separator: ", "))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .monospacedDigit()
            }
            .width(min: 70, ideal: 120)
            TableColumn("Project") { container in
                Text(verbatim: container.composeProject ?? "")
                    .foregroundStyle(.secondary)
            }
            .width(min: 60, ideal: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: ContainerSnapshot.ID.self) { ids in
            let targets = (snapshot?.containers ?? []).filter { ids.contains($0.id) }
            Button("Start") { request(.start, for: targets) }
                .disabled(!targets.contains { !$0.isRunning })
            Button("Stop…") { request(.stop, for: targets) }
                .disabled(!targets.contains(where: \.isRunning))
            Button("Restart…") { request(.restart, for: targets) }
                .disabled(!targets.contains(where: \.isRunning))
            Divider()
            Button("Copy Container ID") {
                ProcessActions.copy(targets.map(\.id).joined(separator: "\n"))
            }
            .disabled(targets.isEmpty)
        }
    }

    private var footer: some View {
        let containers = snapshot?.containers ?? []
        return HStack {
            Text("\(containers.count(where: \.isRunning)) running · \(containers.count) containers")
            Spacer()
            if let snapshot {
                Text(verbatim: [snapshot.engineName, snapshot.engineVersion.map { "Docker \($0)" }].compactMap { $0 }.joined(separator: " · "))
                    .help(Text(verbatim: snapshot.socketPath))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private struct PendingAction {
        let action: ContainerAction
        let containers: [ContainerSnapshot]
    }

    /// Start runs at once; Stop and Restart interrupt running work and are confirmed first.
    private func request(_ action: ContainerAction, for containers: [ContainerSnapshot]) {
        let targets = containers.filter { action == .start ? !$0.isRunning : $0.isRunning }
        guard !targets.isEmpty else { return }
        if action == .start {
            perform(action, on: targets)
        } else {
            pendingAction = PendingAction(action: action, containers: targets)
        }
    }

    private func perform(_ action: ContainerAction, on containers: [ContainerSnapshot]) {
        guard let socketPath = snapshot?.socketPath else { return }
        for container in containers {
            busy.insert(container.id)
            Task {
                let result = await ContainerControl.perform(action, containerID: container.id, socketPath: socketPath)
                busy.remove(container.id)
                switch result {
                case .success, .failure(.notFound):
                    break
                case .failure(.engineUnavailable):
                    failure = String(localized: "The container engine is not reachable.")
                case .failure(.failed(let message)):
                    failure = String(localized: "\(container.name): \(message)")
                }
            }
        }
    }

    private var isConfirming: Binding<Bool> {
        Binding { pendingAction != nil } set: { if !$0 { pendingAction = nil } }
    }

    private var isShowingFailure: Binding<Bool> {
        Binding { failure != nil } set: { if !$0 { failure = nil } }
    }

    private var confirmationTitle: Text {
        guard let pending = pendingAction else { return Text(verbatim: "") }
        let verb = pending.action == .stop ? String(localized: "Stop") : String(localized: "Restart")
        if pending.containers.count == 1, let container = pending.containers.first {
            return Text("\(verb) “\(container.name)”?")
        }
        return Text("\(verb) \(pending.containers.count) containers?")
    }
}

extension ContainerSnapshot {
    // Missing values sort as −1, below every real value.
    var cpuSortValue: Double { cpu.value ?? -1 }
    var memorySortValue: Double { memoryBytes.value.map(Double.init) ?? -1 }
    var receivedSortValue: Double { networkReceivedBytesPerSecond.value ?? -1 }
    var sentSortValue: Double { networkSentBytesPerSecond.value ?? -1 }
}
