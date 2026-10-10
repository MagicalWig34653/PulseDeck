import PulseDeckCore
import SwiftUI

/// Top of the Traffic page: totals since recording started, live rates and a rolling 60-second
/// chart of the rate to all destinations the scope toggles let through.
struct TrafficHeader: View {
    let model: TrafficModel
    let filter: TrafficFilter

    private var totals: TrafficTotals { model.snapshot.totals }
    private var hasCounters: Bool { model.snapshot.hasByteCounters }

    private var sinceText: String? {
        model.snapshot.recordingSince.map {
            String(localized: "since \($0.formatted(date: .omitted, time: .shortened))")
        }
    }

    private var includedClasses: Set<TrafficScopeClass> {
        Set(TrafficScopeClass.allCases.filter(filter.includes))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                TrafficStatTile(label: "↓ Received", value: TrafficFormat.bytes(totals.bytesReceived, counters: hasCounters),
                                detail: sinceText)
                TrafficStatTile(label: "↑ Sent", value: TrafficFormat.bytes(totals.bytesSent, counters: hasCounters),
                                detail: sinceText)
                TrafficStatTile(label: "Rate now", value: TrafficFormat.rate(totals.receiveBytesPerSecond, counters: hasCounters),
                                detail: "↑ " + TrafficFormat.rate(totals.sendBytesPerSecond, counters: hasCounters),
                                leadingArrow: "↓ ")
                TrafficStatTile(label: "Active flows", value: totals.activeFlows.formatted(), detail: nil)
                TrafficStatTile(label: "Destinations", value: totals.destinationCount.formatted(), detail: nil)
            }
            chart
        }
    }

    private var chart: some View {
        let classes = includedClasses
        return TimeSeriesChart(
            history: model.rateHistory.history,
            series: [
                ChartSeries(label: "Download", color: .blue, value: {
                    TrafficRateHistory.value(in: $0, direction: .received, including: classes)
                }),
                ChartSeries(label: "Upload", color: .orange, value: {
                    TrafficRateHistory.value(in: $0, direction: .sent, including: classes)
                }),
            ],
            yAxis: .automatic(minimum: 10_000),
            format: Format.rate,
            accessibilityLabel: Text("Network traffic rate to all destinations"),
            // One point per second, so a static window is steadier than scrolling between samples.
            scrollsSmoothly: false
        )
        .frame(height: 130)
    }
}

/// A figure with a caption, like the tiles of a dashboard.
private struct TrafficStatTile: View {
    let label: LocalizedStringResource
    let value: String
    let detail: String?
    /// Prefix of `value` for tiles that show two directions ("↓ ").
    var leadingArrow = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: leadingArrow + value)
                .font(.system(.title2, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(verbatim: detail ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.background.secondary, in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}
