import PulseDeckCore
import SwiftUI

/// Totals over all virtual machines: how many run, and the host CPU and memory their processes
/// use together, each with its last 60 seconds. (Host-side figures, see the footnote of the page.)
struct VMSummaryHeader: View {
    let machines: [VirtualMachineSnapshot]
    /// `VMHistory.aggregate`.
    let history: MetricHistory

    private static let chartHeight: CGFloat = 112
    /// 512 MiB: keeps a quiet period from stretching the memory scale.
    private static let minimumMemoryScale = 536_870_912.0

    var body: some View {
        let totals = VMHistory.totals(of: machines)
        let running = machines.count(where: { $0.state.isRunning })
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                StatisticView(label: "Running", value: .available(String(localized: "\(running) of \(machines.count)")))
                StatisticView(
                    label: "Host CPU",
                    value: Self.state(totals.cpu, Format.processCPU),
                    help: "CPU time that the processes of all virtual machines use on this Mac, as a share of one core (like Activity Monitor)."
                )
                StatisticView(
                    label: "Host Memory",
                    value: Self.state(totals.memoryBytes, Format.memory),
                    help: "Memory that the processes of all virtual machines occupy on this Mac."
                )
            }
            .frame(width: 150, alignment: .leading)

            TimeSeriesChart(
                history: history,
                series: [ChartSeries(label: "Host CPU", color: .blue, value: { $0.values[VMHistory.AggregateSeries.cpu] })],
                yAxis: .automatic(minimum: 1),
                format: Format.percent,
                accessibilityLabel: Text("Host CPU use of all virtual machines"),
                scrollsSmoothly: false
            )
            .frame(minWidth: 120, maxWidth: .infinity)
            .frame(height: Self.chartHeight)

            TimeSeriesChart(
                history: history,
                series: [ChartSeries(label: "Host Memory", color: .purple, value: { $0.values[VMHistory.AggregateSeries.memory] })],
                yAxis: .automatic(minimum: Self.minimumMemoryScale),
                format: Format.memory,
                accessibilityLabel: Text("Host memory use of all virtual machines"),
                scrollsSmoothly: false
            )
            .frame(minWidth: 120, maxWidth: .infinity)
            .frame(height: Self.chartHeight)
        }
    }

    private static func state(_ value: Double?, _ format: (Double) -> String) -> MetricState<String> {
        guard let value else { return .unavailable(.notApplicable) }
        return .available(format(value))
    }
}

/// The VM programs found on this Mac. Each is a toggle that limits the table to its machines;
/// a read-only badge marks programs PulseDeck can monitor but not control.
struct VMProviderStrip: View {
    let providers: [VMProviderStatus]
    let machines: [VirtualMachineSnapshot]
    @Binding var filter: String?
    @State private var showsNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(providers) { provider in
                        Toggle(isOn: isFiltering(provider.id)) {
                            HStack(spacing: 5) {
                                Text(verbatim: provider.name)
                                    .fontWeight(.medium)
                                if let version = provider.version {
                                    Text(verbatim: version)
                                        .foregroundStyle(.secondary)
                                }
                                Text(verbatim: "· \(provider.machineCount)")
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                                if isReadOnly(provider) {
                                    Text("Read-only")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(.quaternary, in: .capsule)
                                }
                            }
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .help(Text("Show only the machines of \(provider.name)"))
                    }
                }
                .padding(.vertical, 2)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)

            let notes = providers.filter { $0.note != nil }
            if !notes.isEmpty {
                DisclosureGroup(isExpanded: $showsNotes) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(notes) { provider in
                            Label {
                                Text(verbatim: "\(provider.name): \(provider.note ?? "")")
                            } icon: {
                                Image(systemName: "info.circle")
                            }
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("Notes on Providers")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func isFiltering(_ id: String) -> Binding<Bool> {
        Binding {
            filter == id
        } set: { isOn in
            filter = isOn ? id : nil
        }
    }

    /// Every machine of the provider is monitor-only (or the provider says so itself).
    private func isReadOnly(_ provider: VMProviderStatus) -> Bool {
        let own = machines.filter { $0.providerID == provider.id }
        if !own.isEmpty {
            return own.allSatisfy { $0.capabilities == .readOnly }
        }
        return provider.note?.lowercased().hasPrefix("read-only") ?? false
    }
}
