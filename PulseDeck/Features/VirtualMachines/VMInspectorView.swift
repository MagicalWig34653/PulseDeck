import PulseDeckCore
import SwiftUI

/// Inspector of the selection: nothing, several machines, or one machine with live charts and
/// facts. All usage shown here is what the machine's processes use on the Mac (host side).
struct VMInspectorView: View {
    let selection: [VirtualMachineSnapshot]
    let providers: [VMProviderStatus]
    let history: VMHistory
    let isBusy: (VirtualMachineSnapshot) -> Bool
    let onEditResources: (VirtualMachineSnapshot) -> Void

    var body: some View {
        if selection.count == 1, let machine = selection.first {
            VMDetailView(
                machine: machine,
                providerNote: providers.first { $0.id == machine.providerID }?.note,
                history: history.history(for: machine.id) ?? MetricHistory(seriesCount: VMHistory.Series.count),
                isBusy: isBusy(machine),
                onEditResources: { onEditResources(machine) }
            )
        } else if selection.isEmpty {
            ContentUnavailableView {
                Label("No Selection", systemImage: AppSection.machines.systemImage)
            } description: {
                Text("Select a virtual machine to see its resource use and settings.")
            }
        } else {
            ContentUnavailableView {
                Label("\(selection.count) Virtual Machines", systemImage: AppSection.machines.systemImage)
            } description: {
                Text("Select a single virtual machine to see its details.")
            }
        }
    }
}

private struct VMDetailView: View {
    let machine: VirtualMachineSnapshot
    let providerNote: String?
    let history: MetricHistory
    let isBusy: Bool
    let onEditResources: () -> Void

    private static let chartHeight: CGFloat = 130
    /// 100 kB/s: keeps idle metadata writes from filling the chart (as on the Disk page).
    private static let minimumDiskScale = 100_000.0
    /// 512 MiB.
    private static let minimumMemoryScale = 536_870_912.0
    private static let shownProcessIDs = 6

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if isMonitorOnly {
                    SourceNote(text: "\(monitorOnlyNote)")
                }
                cpuChart
                memoryChart
                diskChart
                facts
                SourceNote(text: "CPU, memory and disk figures are what this machine’s processes use on this Mac (host side). What happens inside the guest is not readable without an agent in the guest.")
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isMonitorOnly: Bool {
        machine.capabilities == .readOnly
    }

    private var monitorOnlyNote: String {
        providerNote ?? String(localized: "\(machine.providerName) can be monitored here, but not controlled.")
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VMStatusSymbol(state: machine.state)
                VStack(alignment: .leading, spacing: 3) {
                    Text(verbatim: machine.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text(verbatim: [machine.providerName, machine.guestDescription].filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("Working"))
                }
            }
            if machine.capabilities.canEditAnything {
                Button(action: onEditResources) {
                    Label("Resources…", systemImage: "slider.horizontal.3")
                }
                .disabled(isBusy)
            }
        }
    }

    // MARK: - Charts

    private var cpuChart: some View {
        chartBlock(title: "Host CPU", value: machine.usage.cpu.map(Format.processCPU)) {
            TimeSeriesChart(
                history: history,
                series: [ChartSeries(label: "Host CPU", color: .blue, value: { $0.values[VMHistory.Series.cpu] })],
                // 100 % per configured CPU: the scale shows how much of its allotment the machine uses.
                yAxis: .automatic(minimum: Double(max(machine.resources.cpus ?? 1, 1))),
                format: Format.percent,
                accessibilityLabel: Text("Host CPU use of \(machine.name)")
            )
        }
    }

    private var memoryChart: some View {
        let configured = machine.resources.memoryBytes.map { Double($0) }
        var series = [ChartSeries(label: "Resident", color: .purple, value: { $0.values[VMHistory.Series.memory] })]
        if let configured {
            // The memory the machine is configured with, as a reference line (also part of the scale).
            series.append(ChartSeries(label: "Configured", color: .secondary, value: { _ in configured }, isFilled: false))
        }
        return chartBlock(title: "Memory", value: machine.usage.memoryBytes.map(Format.memory)) {
            TimeSeriesChart(
                history: history,
                series: series,
                yAxis: .automatic(minimum: Self.minimumMemoryScale),
                format: Format.memory,
                accessibilityLabel: Text("Host memory use of \(machine.name)")
            )
        }
    }

    private var diskChart: some View {
        chartBlock(title: "Disk", value: Self.diskText(machine.usage)) {
            TimeSeriesChart(
                history: history,
                series: [
                    ChartSeries(label: "Read", color: .teal, value: { $0.values[VMHistory.Series.diskRead] }),
                    ChartSeries(label: "Write", color: .orange, value: { $0.values[VMHistory.Series.diskWrite] }),
                ],
                yAxis: .automatic(minimum: Self.minimumDiskScale),
                format: Format.rate,
                accessibilityLabel: Text("Disk throughput of \(machine.name)")
            )
        }
    }

    private func chartBlock<ChartContent: View>(title: LocalizedStringResource, value: MetricState<String>, @ViewBuilder chart: () -> ChartContent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.headline)
                Spacer()
                MetricStateText(state: value)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            chart()
                .frame(height: Self.chartHeight)
        }
    }

    private static func diskText(_ usage: VMUsage) -> MetricState<String> {
        usage.diskReadBytesPerSecond.flatMap { read in
            usage.diskWriteBytesPerSecond.map { write in "R \(Format.rate(read))  W \(Format.rate(write))" }
        }
    }

    // MARK: - Facts

    private var facts: some View {
        VStack(alignment: .leading, spacing: 14) {
            factGroup("Configuration") {
                fact("CPUs", .text(machine.resources.cpus.map { String($0) }))
                fact("Memory", .text(machine.resources.memoryBytes.map(Format.memory)))
                fact("Disk", .text(machine.resources.diskBytes.map(Format.memory)))
            }
            factGroup("Status") {
                fact("State", .available(machine.state.label))
                if machine.state.isRunning, let startedAt = machine.startedAt {
                    fact("Uptime", .available(Format.uptime(since: startedAt)))
                }
                fact("IP Address", .text(machine.ipAddress))
                fact("Host Processes", .text(processText))
            }
            if !machine.details.isEmpty {
                factGroup("Details") {
                    ForEach(machine.details, id: \.self) { detail in
                        LabeledContent {
                            Text(verbatim: detail.value)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        } label: {
                            Text(verbatim: detail.label)
                        }
                    }
                }
            }
        }
    }

    private var processText: String? {
        guard machine.usage.processCount > 0 || !machine.hostProcessIDs.isEmpty else { return nil }
        let count = max(machine.usage.processCount, machine.hostProcessIDs.count)
        let shown = machine.hostProcessIDs.prefix(Self.shownProcessIDs).map { String($0) }.joined(separator: ", ")
        let more = machine.hostProcessIDs.count - Self.shownProcessIDs
        let pids = more > 0 ? String(localized: "\(shown) and \(more) more") : shown
        return pids.isEmpty ? String(localized: "\(count) processes") : String(localized: "\(count) processes (PID \(pids))")
    }

    private func factGroup<Content: View>(_ title: LocalizedStringResource, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } label: {
            Text(title)
                .font(.headline)
        }
    }

    private func fact(_ label: LocalizedStringResource, _ value: MetricState<String>) -> some View {
        LabeledContent {
            MetricStateText(state: value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(label)
        }
    }
}
