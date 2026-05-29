import AgentCore
import Charts
import SwiftUI

/// Renders a `PlotSpec` (decoded from a `plot` tool call's arguments) as a
/// native SwiftUI chart inside a message bubble. Supports line / bar / scatter
/// marks and multiple series; a series with no explicit `x` is plotted against
/// its 0-based index.
struct PlotView: View {
    let spec: PlotSpec

    /// Flattened (series, x, y) rows — one per point. The series label drives
    /// `foregroundStyle(by:)` so multi-series plots get distinct colors + a legend.
    private struct Point: Identifiable {
        let id = UUID()
        let series: String
        let x: Double
        let y: Double
    }

    private var points: [Point] {
        spec.series.enumerated().flatMap { idx, s -> [Point] in
            let label = s.name ?? (spec.series.count > 1 ? "series \(idx + 1)" : "y")
            return s.y.enumerated().map { i, y in
                Point(series: label, x: s.x?[i] ?? Double(i), y: y)
            }
        }
    }

    private var hasLegend: Bool {
        spec.series.count > 1 || spec.series.contains { $0.name != nil }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = spec.title {
                Text(title).font(.callout.weight(.semibold))
            }
            labeledChart
                .frame(height: 240)
                .frame(maxWidth: 460)
        }
    }

    /// The chart with axis labels applied only when the spec provides them —
    /// an empty `chartXAxisLabel("")` would otherwise reserve a blank strip.
    @ViewBuilder
    private var labeledChart: some View {
        let base = Chart(points) { mark(for: $0) }
            .chartForegroundStyleScale(range: Self.palette)
            .chartLegend(hasLegend ? .visible : .hidden)
        switch (spec.xLabel, spec.yLabel) {
        case let (x?, y?): base.chartXAxisLabel(x, alignment: .center).chartYAxisLabel(y)
        case let (x?, nil): base.chartXAxisLabel(x, alignment: .center)
        case let (nil, y?): base.chartYAxisLabel(y)
        case (nil, nil):   base
        }
    }

    @ChartContentBuilder
    private func mark(for p: Point) -> some ChartContent {
        let xName = spec.xLabel ?? "x"
        let y = PlottableValue.value(spec.yLabel ?? "y", p.y)
        let color = PlottableValue.value("series", p.series)
        switch spec.kind {
        case .line:
            LineMark(x: .value(xName, p.x), y: y)
                .foregroundStyle(by: color)
                .symbol(by: color)
        case .scatter:
            PointMark(x: .value(xName, p.x), y: y)
                .foregroundStyle(by: color)
        case .bar:
            // Bars use a *categorical* x so they get a sensible width, and
            // `.position(by:)` dodges multiple series side-by-side instead of
            // stacking them (the default for a shared x value).
            BarMark(x: .value(xName, Self.category(p.x)), y: y)
                .foregroundStyle(by: color)
                .position(by: color)
        }
    }

    /// Format a numeric x as a bar-axis category label — integral values drop
    /// the trailing ".0" so an index axis reads "0, 1, 2" rather than "0.0…".
    private static func category(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e15 ? String(Int(x)) : String(x)
    }

    /// Muted, readable categorical palette that works on both light/dark bubbles.
    private static let palette: [Color] = [
        .blue, .orange, .green, .purple, .red, .teal, .pink, .brown,
    ]
}
