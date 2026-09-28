import AppKit
import PulseDeckCore
import PulseDeckTelemetry
import SwiftUI

/// Processes section (SPEC §20–22): a native, sortable and searchable process table with Quit,
/// Force Quit and Show in Finder. Processes are sampled only while this section is visible.
///
/// There is no Network or Energy column: macOS has no public per-process network counters
/// (L‑4), and per-process energy is not validated (L‑5).
struct ProcessesView: View {
    @Environment(AppState.self) private var appState
    @State private var searchText = ""
    @State private var sortOrder = [KeyPathComparator(\ProcessSnapshot.cpuSortValue, order: .reverse)]
    @State private var selection = Set<ProcessSnapshot.ID>()
    @State private var pendingQuit: PendingQuit?
    @State private var failure: ProcessActionFailure?
    @State private var icons = ProcessIconCache()

    private var allProcesses: [ProcessSnapshot] { appState.latestProcesses?.value ?? [] }

    private var rows: [ProcessSnapshot] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? allProcesses : allProcesses.filter { $0.matches(query) }
        return filtered.sorted(using: sortOrder)
    }

    var body: some View {
        content
            .navigationTitle(Text(AppSection.processes.title))
            .searchable(text: $searchText, prompt: Text("Name or PID"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        requestQuit(selection, mode: .choose)
                    } label: {
                        Label("Quit Process", systemImage: "xmark.octagon")
                    }
                    .help(Text("Quit the selected process"))
                    .keyboardShortcut("q", modifiers: [.command, .option])
                    .disabled(selection.isEmpty)
                }
            }
            .confirmationDialog(quitTitle, isPresented: isConfirmingQuit, titleVisibility: .visible, presenting: pendingQuit) { pending in
                if pending.mode == .choose {
                    Button("Quit") { perform(pending.processes, force: false) }
                        .keyboardShortcut(.defaultAction)
                }
                Button("Force Quit", role: .destructive) { perform(pending.processes, force: true) }
                Button("Cancel", role: .cancel) {}
            } message: { pending in
                Text(pending.mode == .choose
                     ? "Quit asks the process to exit. Force Quit ends it immediately; unsaved changes are lost."
                     : "The process ends immediately; unsaved changes are lost.")
            }
            .alert(Text(verbatim: failure?.title ?? ""), isPresented: isShowingFailure, presenting: failure) { _ in
                Button("OK", role: .cancel) {}
            } message: { failure in
                Text(verbatim: failure.message)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch appState.latestProcesses {
        case .unavailable(let reason)? where !reason.isTransient:
            ContentUnavailableView {
                Label("Processes", systemImage: AppSection.processes.systemImage)
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
            TableColumn("Process Name", value: \.name) { process in
                HStack(spacing: 6) {
                    Image(nsImage: icons.icon(for: process))
                        .resizable()
                        .frame(width: 16, height: 16)
                        .accessibilityHidden(true)
                    Text(verbatim: process.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .width(min: 160, ideal: 260)
            TableColumn("PID", value: \.pid) { process in
                Text(verbatim: String(process.pid))
                    .monospacedDigit()
            }
            .width(min: 50, ideal: 64)
            TableColumn("CPU", value: \.cpuSortValue) { process in
                MetricStateText(state: process.cpu.map(Format.processCPU), isCompact: true)
            }
            .width(min: 56, ideal: 70)
            TableColumn("Memory", value: \.memorySortValue) { process in
                MetricStateText(state: process.memoryBytes.map(Format.memory), isCompact: true)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Threads", value: \.threadSortValue) { process in
                MetricStateText(state: process.threadCount.map { String($0) }, isCompact: true)
            }
            .width(min: 50, ideal: 64)
            TableColumn("Disk Read", value: \.diskReadSortValue) { process in
                MetricStateText(state: process.diskReadBytesPerSecond.map(Format.rate), isCompact: true)
            }
            .width(min: 70, ideal: 90)
            TableColumn("Disk Write", value: \.diskWriteSortValue) { process in
                MetricStateText(state: process.diskWriteBytesPerSecond.map(Format.rate), isCompact: true)
            }
            .width(min: 70, ideal: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu(forSelectionType: ProcessSnapshot.ID.self) { ids in
            let targets = processes(for: ids)
            Button("Quit…") { requestQuit(ids, mode: .choose) }
                .disabled(targets.isEmpty)
            Button("Force Quit…") { requestQuit(ids, mode: .force) }
                .disabled(targets.isEmpty)
            Divider()
            Button("Show in Finder") {
                if let process = targets.first { ProcessActions.showInFinder(process) }
            }
            .disabled(targets.count != 1 || targets.first?.path == nil)
            Button("Copy Path") {
                if let path = targets.first?.path { ProcessActions.copy(path) }
            }
            .disabled(targets.count != 1 || targets.first?.path == nil)
            Button("Copy PID") {
                ProcessActions.copyPIDs(of: targets)
            }
            .disabled(targets.isEmpty)
        }
        .onDeleteCommand {
            requestQuit(selection, mode: .choose)
        }
    }

    private var footer: some View {
        let total = allProcesses.count
        let restricted = allProcesses.count(where: { $0.cpu.unavailableReason == .permissionDenied })
        return HStack {
            Text("\(total) processes")
            if restricted > 0 {
                Text(verbatim: "·")
                Text("\(restricted) owned by other users show limited details")
                    .help(Text("macOS allows only name and PID for processes of other users (such as root) without administrator privileges."))
            }
            Spacer()
            if !selection.isEmpty {
                Text("\(selection.count) selected")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Actions

    private func processes(for ids: Set<ProcessSnapshot.ID>) -> [ProcessSnapshot] {
        allProcesses.filter { ids.contains($0.id) }
    }

    private func requestQuit(_ ids: Set<ProcessSnapshot.ID>, mode: PendingQuit.Mode) {
        let targets = processes(for: ids)
        guard !targets.isEmpty else { return }
        pendingQuit = PendingQuit(processes: targets, mode: mode)
    }

    private var isConfirmingQuit: Binding<Bool> {
        Binding { pendingQuit != nil } set: { if !$0 { pendingQuit = nil } }
    }

    private var isShowingFailure: Binding<Bool> {
        Binding { failure != nil } set: { if !$0 { failure = nil } }
    }

    private var quitTitle: Text {
        guard let pending = pendingQuit else { return Text(verbatim: "") }
        let verb: LocalizedStringResource = pending.mode == .force ? "Force quit" : "Quit"
        if pending.processes.count == 1, let process = pending.processes.first {
            return Text("\(String(localized: verb)) “\(process.name)” (PID \(String(process.pid)))?")
        }
        return Text("\(String(localized: verb)) \(pending.processes.count) processes?")
    }

    private func perform(_ targets: [ProcessSnapshot], force: Bool) {
        var denied: [String] = []
        var failed: [String] = []
        for process in targets {
            switch ProcessActions.quit(process, force: force) {
            case .success, .failure(.processExited):
                // Already gone counts as done; the next sample removes the row.
                break
            case .failure(.permissionDenied):
                denied.append(process.name)
            case .failure(.failed):
                failed.append(process.name)
            }
        }
        selection.subtract(targets.map(\.id))
        if !denied.isEmpty || !failed.isEmpty {
            failure = ProcessActionFailure(denied: denied, failed: failed)
        }
    }
}

// MARK: - Supporting types

private struct PendingQuit {
    enum Mode {
        /// Offer Quit and Force Quit.
        case choose
        /// Offer Force Quit only.
        case force
    }

    let processes: [ProcessSnapshot]
    let mode: Mode
}

private struct ProcessActionFailure: Identifiable {
    let id = UUID()
    let denied: [String]
    let failed: [String]

    var title: String {
        denied.isEmpty ? String(localized: "The process could not be quit") : String(localized: "Permission denied")
    }

    var message: String {
        var lines: [String] = []
        if !denied.isEmpty {
            lines.append(String(localized: "PulseDeck is not allowed to quit \(denied.joined(separator: ", ")). The process belongs to another user or is protected by macOS."))
        }
        if !failed.isEmpty {
            lines.append(String(localized: "macOS did not quit \(failed.joined(separator: ", "))."))
        }
        return lines.joined(separator: "\n\n")
    }
}

extension ProcessSnapshot {
    // Sort keys. Missing values sort below every real value; they are never displayed.
    var cpuSortValue: Double { cpu.value ?? -1 }
    var memorySortValue: Int64 { memoryBytes.value.map { Int64(clamping: $0) } ?? -1 }
    var threadSortValue: Int { threadCount.value ?? -1 }
    var diskReadSortValue: Double { diskReadBytesPerSecond.value ?? -1 }
    var diskWriteSortValue: Double { diskWriteBytesPerSecond.value ?? -1 }

    /// Search: name or path contains the query, or the query is the PID.
    func matches(_ query: String) -> Bool {
        name.localizedStandardContains(query)
            || String(pid) == query
            || (path?.localizedStandardContains(query) ?? false)
    }
}
