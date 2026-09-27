import Foundation

/// Y-axis scaling for charts whose values have no fixed maximum (throughput).
public enum ChartScale {
    /// Smallest "nice" upper bound (1, 2 or 5 × 10ⁿ) that is ≥ `value` and ≥ `minimum`, so the
    /// axis label stays readable and a quiet period does not blow up noise to full height.
    public static func niceUpperBound(for value: Double, minimum: Double) -> Double {
        let target = max(value.isFinite ? value : 0, minimum)
        guard target > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(target)))
        for step in [1.0, 2.0, 5.0, 10.0] where step * magnitude >= target {
            return step * magnitude
        }
        return 10 * magnitude
    }
}
