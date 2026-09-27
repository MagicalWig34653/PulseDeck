import PulseDeckCore
import SwiftUI

/// GPU page (SPEC §18): Metal identification plus system-wide utilization where the driver
/// publishes it. Utilization comes from an undocumented IOAccelerator statistic and is labelled
/// as such; without it the page says *Not Available* (TECHNICAL_LIMITATIONS.md L‑1).
struct GPUPerformanceView: View {
    @Environment(AppState.self) private var appState
    @State private var selection: GPUDeviceSnapshot.ID?

    private var state: MetricState<GPUSnapshot>? { appState.latestSnapshot?.gpu }
    private var devices: [GPUDeviceSnapshot] { state?.value?.devices ?? [] }

    private var selectedDevice: GPUDeviceSnapshot? {
        devices.first { $0.id == selection } ?? devices.first
    }

    var body: some View {
        if let reason = state?.unavailableReason, !reason.isTransient {
            ContentUnavailableView {
                Label("GPU", systemImage: ResourceCategory.gpu.systemImage)
            } description: {
                Text("Not Available")
                Text(reason.explanation)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    let selected = selectedDevice
                    DetailHeader(
                        title: selected?.name ?? String(localized: "GPU"),
                        subtitle: selected?.kindLabel,
                        value: selected?.utilization.map(Format.percent)
                    )

                    if let selected, selected.utilization.unavailableReason == .noPublicAPI {
                        GroupBox {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("Utilization Not Available")
                                        .font(.headline)
                                    Text("This GPU's driver does not publish a utilization statistic, and macOS provides no public API for system-wide GPU utilization.")
                                        .foregroundStyle(.secondary)
                                }
                            } icon: {
                                Image(systemName: "chart.line.downtrend.xyaxis")
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                        }
                    } else {
                        TimeSeriesChart(
                            history: selected.flatMap { appState.history.gpus[$0.id] } ?? MetricHistory(seriesCount: 1),
                            series: [ChartSeries(label: "Utilization", color: .green, value: { $0.values[0] })],
                            yAxis: .fraction,
                            format: Format.precisePercent,
                            accessibilityLabel: Text("GPU utilization of \(selected?.name ?? "")")
                        )
                        .frame(height: 200)
                        SourceNote(text: "GPU utilization is read from an undocumented macOS driver statistic (IOAccelerator “Device Utilization %”).")
                    }

                    if let selected {
                        DetailSection(title: "Device") {
                            StatisticView(label: "Utilization", value: selected.utilization.map(Format.percent),
                                          help: "Share of time the GPU was busy, as reported by its driver (undocumented statistic).")
                            StatisticView(label: "Memory", value: .available(selected.hasUnifiedMemory ? String(localized: "Unified") : String(localized: "Dedicated")),
                                          help: "Unified memory is shared between CPU and GPU; see the Memory page for its usage.")
                            StatisticView(label: "Location", value: .available(selected.location.label))
                            StatisticView(label: "Low Power", value: .available(selected.isLowPower ? String(localized: "Yes") : String(localized: "No")))
                            StatisticView(label: "Removable", value: .available(selected.isRemovable ? String(localized: "Yes") : String(localized: "No")))
                            StatisticView(label: "Registry ID", value: .available(String(format: "0x%llx", selected.id)),
                                          help: "IORegistry entry ID reported by Metal.")
                        }
                    }

                    if devices.count > 1 {
                        SectionHeader(title: "Devices")
                        deviceTable
                    }
                }
                .padding(20)
            }
        }
    }

    private var deviceTable: some View {
        let rows = devices
        return Table(rows, selection: $selection) {
            TableColumn("Device") { device in
                Label {
                    Text(verbatim: device.name)
                } icon: {
                    Image(systemName: ResourceCategory.gpu.systemImage)
                        .foregroundStyle(.tint)
                }
            }
            .width(min: 160, ideal: 240)
            TableColumn("Type") { device in
                Text(verbatim: device.kindLabel).foregroundStyle(.secondary)
            }
            .width(min: 120, ideal: 200)
            TableColumn("Utilization") { device in
                MetricStateText(state: device.utilization.map(Format.percent), isCompact: true)
            }
            .width(min: 70, ideal: 90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .frame(height: NetworkPerformanceView.tableHeight(rows: rows.count))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
    }
}

/// A visible note naming an undocumented or derived data source (SPEC §3, owner decisions L‑1,
/// L‑2): the label is on screen, not only in a tooltip.
struct SourceNote: View {
    let text: LocalizedStringResource

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: "info.circle")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}
