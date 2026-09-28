import Accessibility
import PulseDeckCore
import SwiftUI

/// One line in a `TimeSeriesChart`.
struct ChartSeries {
    let label: LocalizedStringResource
    let color: Color
    /// Extracts this series' value from a history sample; `nil` is drawn as a gap.
    let value: (HistorySample) -> Double?
    /// Draw the line (and area). Undrawn series only appear in the hover callout.
    var isDrawn = true
    var isFilled = true
    /// Formatter for this series in the hover callout; defaults to the chart's formatter.
    var format: ((Double) -> String)?
}

/// Vertical scale of a chart.
enum ChartYAxis {
    /// Fractions in 0…1, labelled as percent.
    case fraction
    /// Automatically scaled to the visible maximum (never below `minimum`).
    case automatic(minimum: Double)
}

/// A lightweight time-series chart drawn with `Canvas` (SPEC §11): the last 60 seconds of a
/// `MetricHistory`, gaps for missing samples, and hover inspection of the nearest recorded
/// sample (SPEC §12). It only reads history; hovering never triggers telemetry.
struct TimeSeriesChart: View {
    let history: MetricHistory
    let series: [ChartSeries]
    let yAxis: ChartYAxis
    /// Formats a value for axis labels and the hover callout.
    let format: (Double) -> String
    let accessibilityLabel: Text
    /// Small variant (sparklines, per-core grid): no axis labels.
    var isCompact = false
    var allowsHover = true
    /// Decorative charts (list sparklines whose row already states the value) are hidden from
    /// VoiceOver and skip building their accessibility summary each tick.
    var isDecorative = false
    /// Draw the plot background and border. Defaults to framed for full charts only.
    var isFramed: Bool?

    var body: some View {
        let window = ChartWindow(history: history)
        let upperBound = upperBound(in: window)
        VStack(alignment: .leading, spacing: 4) {
            if !isCompact {
                HStack {
                    Spacer()
                    Text(verbatim: axisFormat(upperBound))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            }
            ZStack {
                ChartCanvas(history: history, series: series, window: window, upperBound: upperBound, showsGrid: !isCompact)
                if allowsHover {
                    ChartHoverOverlay(history: history, series: series, window: window, upperBound: upperBound, format: format)
                }
            }
            .modifier(ChartFrame(isFramed: isFramed ?? !isCompact))
            if !isCompact {
                HStack(spacing: 12) {
                    Text("60 seconds")
                    Spacer()
                    let drawn = series.filter(\.isDrawn)
                    if drawn.count > 1 {
                        ForEach(Array(drawn.enumerated()), id: \.offset) { _, line in
                            HStack(spacing: 4) {
                                Circle().fill(line.color).frame(width: 7, height: 7)
                                Text(line.label)
                            }
                        }
                        Spacer()
                    }
                    Text(verbatim: axisFormat(0))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .modifier(ChartAccessibility(
            isEnabled: !isDecorative,
            label: accessibilityLabel,
            summary: { accessibilitySummary(in: window) },
            descriptor: {
                ChartAccessibilityDescriptor(
                    history: history,
                    series: series.filter(\.isDrawn),
                    window: window,
                    upperBound: upperBound,
                    format: format
                )
            }
        ))
    }

    /// Axis labels use whole percentages; the callout keeps the chart's (finer) format.
    private func axisFormat(_ value: Double) -> String {
        switch yAxis {
        case .fraction: Format.percent(value)
        case .automatic: format(value)
        }
    }

    private func upperBound(in window: ChartWindow) -> Double {
        switch yAxis {
        case .fraction:
            return 1
        case .automatic(let minimum):
            let maximum = history.samples
                .filter { window.contains($0.timestamp) }
                .flatMap { sample in series.compactMap { $0.value(sample) } }
                .max() ?? 0
            return ChartScale.niceUpperBound(for: maximum, minimum: minimum)
        }
    }

    /// "Current 12%, peak 48%" for the first series (SPEC §31: accessible chart summaries).
    private func accessibilitySummary(in window: ChartWindow) -> String {
        guard let primary = series.first else { return "" }
        let values = history.samples.filter { window.contains($0.timestamp) }.compactMap(primary.value)
        guard let current = history.latest.flatMap(primary.value), let peak = values.max() else {
            return String(localized: "No data")
        }
        return String(localized: "Current \(format(current)), peak \(format(peak)) in the last 60 seconds")
    }
}

/// Accessibility of a chart: label, spoken summary and Audio Graphs descriptor. Decorative
/// sparklines skip this work, which otherwise ran for every sparkline on every tick (M10).
private struct ChartAccessibility: ViewModifier {
    let isEnabled: Bool
    let label: Text
    let summary: () -> String
    let descriptor: () -> ChartAccessibilityDescriptor

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(label)
                .accessibilityValue(Text(verbatim: summary()))
                // Audio Graphs / data table for VoiceOver (SPEC §31).
                .accessibilityChartDescriptor(descriptor())
        } else {
            content
                .accessibilityHidden(true)
        }
    }
}

/// Background and border of the plot area. Sparklines stay unframed so they read as a quiet
/// glyph in lists, including on a selected (accent-colored) row.
private struct ChartFrame: ViewModifier {
    let isFramed: Bool

    func body(content: Content) -> some View {
        if !isFramed {
            content
        } else {
            content
                .background(.background.secondary, in: .rect(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
        }
    }
}

/// The visible time range: the 60 seconds ending at the newest sample. Anchoring to the newest
/// sample (not a running clock) means nothing redraws between samples.
struct ChartWindow {
    let end: MonotonicInstant
    let start: MonotonicInstant

    init(history: MetricHistory) {
        end = history.latest?.timestamp ?? MonotonicInstant(nanoseconds: 0)
        start = end.advanced(by: .zero - SystemHistory.window)
    }

    var durationNanoseconds: Double { Double(end.nanoseconds(since: start)) }

    func contains(_ instant: MonotonicInstant) -> Bool {
        instant >= start && instant <= end
    }

    /// Horizontal position of `instant` in a view of `width` points.
    func x(_ instant: MonotonicInstant, width: CGFloat) -> CGFloat {
        guard durationNanoseconds > 0 else { return width }
        return CGFloat(Double(instant.nanoseconds(since: start)) / durationNanoseconds) * width
    }

    /// Instant at horizontal position `x`.
    func instant(atX x: CGFloat, width: CGFloat) -> MonotonicInstant {
        guard width > 0 else { return end }
        let fraction = min(max(Double(x / width), 0), 1)
        return start.advanced(by: .nanoseconds(Int64(fraction * durationNanoseconds)))
    }
}

private struct ChartCanvas: View {
    let history: MetricHistory
    let series: [ChartSeries]
    let window: ChartWindow
    let upperBound: Double
    let showsGrid: Bool
    /// Increase Contrast: thicker lines, stronger fill and grid (SPEC §31).
    @Environment(\.colorSchemeContrast) private var contrast

    private var isHighContrast: Bool { contrast == .increased }

    /// Horizontal grid lines at quarters, vertical lines every 10 seconds.
    private static let horizontalDivisions = 4
    private static let verticalDivisions = 6

    var body: some View {
        Canvas { context, size in
            if showsGrid {
                drawGrid(in: &context, size: size)
            }
            for line in series where line.isDrawn {
                draw(line, in: &context, size: size)
            }
        }
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize) {
        var grid = Path()
        for step in 1..<Self.horizontalDivisions {
            let y = size.height * CGFloat(step) / CGFloat(Self.horizontalDivisions)
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
        }
        for step in 1..<Self.verticalDivisions {
            let x = size.width * CGFloat(step) / CGFloat(Self.verticalDivisions)
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
        }
        context.stroke(grid, with: .color(.secondary.opacity(isHighContrast ? 0.4 : 0.15)), lineWidth: isHighContrast ? 1 : 0.5)
    }

    private func draw(_ line: ChartSeries, in context: inout GraphicsContext, size: CGSize) {
        // Split into contiguous runs so missing samples become gaps, never zeros.
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        for sample in history.samples {
            guard sample.timestamp >= window.start else { continue }
            if let value = line.value(sample) {
                current.append(CGPoint(
                    x: window.x(sample.timestamp, width: size.width),
                    y: size.height * (1 - CGFloat(min(max(value / upperBound, 0), 1)))
                ))
            } else if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }

        for run in runs {
            guard let first = run.first, let last = run.last else { continue }
            var stroke = Path()
            stroke.addLines(run)
            if line.isFilled, run.count > 1 {
                var area = stroke
                area.addLine(to: CGPoint(x: last.x, y: size.height))
                area.addLine(to: CGPoint(x: first.x, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(line.color.opacity(isHighContrast ? 0.32 : 0.18)))
            }
            if run.count == 1 {
                context.fill(Path(ellipseIn: CGRect(x: first.x - 1.5, y: first.y - 1.5, width: 3, height: 3)), with: .color(line.color))
            } else {
                context.stroke(stroke, with: .color(line.color), style: StrokeStyle(lineWidth: isHighContrast ? 2.5 : 1.5, lineJoin: .round))
            }
        }
    }
}

/// Hover inspection layer. Kept separate from the canvas so pointer movement only redraws this
/// overlay, not the chart.
private struct ChartHoverOverlay: View {
    let history: MetricHistory
    let series: [ChartSeries]
    let window: ChartWindow
    let upperBound: Double
    let format: (Double) -> String

    @State private var pointer: CGPoint?

    private static let calloutSpacing: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location): pointer = location
                    case .ended: pointer = nil
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let pointer, let sample = nearestSample(to: pointer, width: geometry.size.width) {
                        inspection(of: sample, size: geometry.size)
                    }
                }
        }
    }

    private func nearestSample(to point: CGPoint, width: CGFloat) -> HistorySample? {
        let instant = window.instant(atX: point.x, width: width)
        guard let index = history.samples.nearestIndex(to: instant) else { return nil }
        let sample = history.samples[index]
        return window.contains(sample.timestamp) ? sample : nil
    }

    @ViewBuilder
    private func inspection(of sample: HistorySample, size: CGSize) -> some View {
        let x = window.x(sample.timestamp, width: size.width)
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(.secondary)
                .frame(width: 1, height: size.height)
                .offset(x: x - 0.5)
            ForEach(Array(series.enumerated()), id: \.offset) { _, line in
                if line.isDrawn, let value = line.value(sample) {
                    let y = size.height * (1 - CGFloat(min(max(value / upperBound, 0), 1)))
                    Circle()
                        .fill(line.color)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1.5))
                        .frame(width: 8, height: 8)
                        .offset(x: x - 4, y: y - 4)
                }
            }
            // Keep the callout inside the chart: right of the rule in the left half, left of it
            // in the right half.
            if x < size.width / 2 {
                callout(for: sample)
                    .fixedSize()
                    .offset(x: x + Self.calloutSpacing, y: Self.calloutSpacing)
            } else {
                callout(for: sample)
                    .fixedSize()
                    .frame(width: max(x - Self.calloutSpacing, 0), alignment: .trailing)
                    .offset(y: Self.calloutSpacing)
            }
        }
        .allowsHitTesting(false)
    }

    private func callout(for sample: HistorySample) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(sample.wallClock, format: .dateTime.hour().minute().second())
                .font(.caption.weight(.semibold))
            ForEach(Array(series.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 6) {
                    Circle().fill(line.color).frame(width: 7, height: 7)
                    Text(line.label)
                    Spacer(minLength: 12)
                    Text(verbatim: line.value(sample).map(line.format ?? format) ?? AppState.placeholder)
                        .monospacedDigit()
                }
                .font(.caption)
            }
        }
        .padding(8)
        .glassEffect(.regular, in: .rect(cornerRadius: 8))
    }
}

/// VoiceOver chart description (Audio Graphs): one data series per drawn line over the last
/// 60 seconds. X is seconds before the newest sample; gaps (missing samples) are omitted rather
/// than reported as zero.
private struct ChartAccessibilityDescriptor: AXChartDescriptorRepresentable {
    let history: MetricHistory
    let series: [ChartSeries]
    let window: ChartWindow
    let upperBound: Double
    let format: (Double) -> String

    func makeChartDescriptor() -> AXChartDescriptor {
        let windowSeconds = SystemHistory.window.secondsDouble
        let xAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Time"),
            range: -windowSeconds...0,
            gridlinePositions: []
        ) { seconds in
            String(localized: "\(Int((-seconds).rounded())) seconds ago")
        }
        let yAxis = AXNumericDataAxisDescriptor(
            title: String(localized: "Value"),
            range: 0...max(upperBound, 1),
            gridlinePositions: []
        ) { value in
            value.formatted(.number.precision(.significantDigits(3)))
        }
        let samples = history.samples.filter { window.contains($0.timestamp) }
        let dataSeries = series.map { line in
            AXDataSeriesDescriptor(
                name: String(localized: line.label),
                isContinuous: true,
                dataPoints: samples.compactMap { sample in
                    guard let value = line.value(sample) else { return nil }
                    let secondsBeforeEnd = Double(window.end.nanoseconds(since: sample.timestamp)) / 1e9
                    return AXDataPoint(x: -secondsBeforeEnd, y: value, additionalValues: [], label: (line.format ?? format)(value))
                }
            )
        }
        return AXChartDescriptor(
            title: nil,
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: dataSeries
        )
    }

    func updateChartDescriptor(_ descriptor: AXChartDescriptor) {
        let fresh = makeChartDescriptor()
        descriptor.series = fresh.series
        descriptor.yAxis = fresh.yAxis
    }
}
