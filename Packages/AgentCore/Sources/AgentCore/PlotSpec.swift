import Foundation

/// Declarative description of a chart the agent asked to render. Produced by
/// `PlotTool` (which validates it) and consumed by the app's SwiftUI `Chart`
/// view. Lives in AgentCore — pure Foundation, no SwiftUI — so the tool and the
/// UI decode the *same* shape from the model's tool-call arguments.
///
/// The model passes the whole plot as a single JSON-encoded `spec` string
/// (see `PlotTool`), which sidesteps the Gemma tool-call parser's lack of
/// bracket-awareness around array arguments. We parse that JSON with
/// `JSONSerialization` here so integer and floating-point numbers coerce
/// uniformly to `Double`.
public struct PlotSpec: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case line, bar, scatter
    }

    /// One data series. `x` is optional: when nil the series is plotted against
    /// its 0-based index, which is the "single y-values" case.
    public struct Series: Equatable, Sendable {
        public var name: String?
        public var x: [Double]?
        public var y: [Double]

        public init(name: String? = nil, x: [Double]? = nil, y: [Double]) {
            self.name = name
            self.x = x
            self.y = y
        }
    }

    public var title: String?
    public var kind: Kind
    public var xLabel: String?
    public var yLabel: String?
    public var series: [Series]

    public init(
        title: String? = nil,
        kind: Kind = .line,
        xLabel: String? = nil,
        yLabel: String? = nil,
        series: [Series]
    ) {
        self.title = title
        self.kind = kind
        self.xLabel = xLabel
        self.yLabel = yLabel
        self.series = series
    }

    // MARK: - Parsing

    /// Decode and validate a plot from its JSON string. Accepts three shapes:
    ///   • single series shorthand:  `{"y": [1, 4, 9]}`
    ///   • x/y pair shorthand:       `{"x": [0, 1, 2], "y": [1, 4, 9]}`
    ///   • multi-series:             `{"series": [{"name":"a","y":[…]}, …]}`
    /// plus optional `title`, `type`/`chart_type`, `x_label`, `y_label`.
    public static func parse(_ json: String) throws -> PlotSpec {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            throw PlotSpecError.malformedJSON
        }

        let kind = try parseKind(root["type"] ?? root["chart_type"] ?? root["kind"])
        let title = nonEmptyString(root["title"])
        let xLabel = nonEmptyString(root["x_label"] ?? root["xlabel"] ?? root["x_axis"])
        let yLabel = nonEmptyString(root["y_label"] ?? root["ylabel"] ?? root["y_axis"])

        let series: [Series]
        if let raw = root["series"] {
            guard let arr = raw as? [Any] else {
                throw PlotSpecError.badSeries("'series' must be an array")
            }
            guard !arr.isEmpty else { throw PlotSpecError.emptySeries }
            series = try arr.enumerated().map { idx, element in
                guard let obj = element as? [String: Any] else {
                    throw PlotSpecError.badSeries("series[\(idx)] must be an object with a 'y' array")
                }
                return try parseSeries(obj, index: idx)
            }
        } else if root["y"] != nil {
            // Shorthand: top-level x/y describe a single series.
            series = [try parseSeries(root, index: 0)]
        } else {
            throw PlotSpecError.missingData
        }

        return PlotSpec(title: title, kind: kind, xLabel: xLabel, yLabel: yLabel, series: series)
    }

    private static func parseKind(_ raw: Any?) throws -> Kind {
        guard let raw else { return .line }   // default
        guard let s = raw as? String else {
            throw PlotSpecError.badKind(String(describing: raw))
        }
        switch s.lowercased() {
        case "line":             return .line
        case "bar":              return .bar
        case "scatter", "point": return .scatter
        default:                 throw PlotSpecError.badKind(s)
        }
    }

    private static func parseSeries(_ obj: [String: Any], index: Int) throws -> Series {
        guard let yRaw = obj["y"] else {
            throw PlotSpecError.badSeries("series[\(index)] is missing 'y'")
        }
        guard let y = numbers(yRaw), !y.isEmpty else {
            throw PlotSpecError.badSeries("series[\(index)] 'y' must be a non-empty array of finite numbers")
        }
        var x: [Double]? = nil
        if let xRaw = obj["x"] {
            guard let xs = numbers(xRaw) else {
                throw PlotSpecError.badSeries("series[\(index)] 'x' must be an array of finite numbers")
            }
            guard xs.count == y.count else {
                throw PlotSpecError.lengthMismatch(index: index, x: xs.count, y: y.count)
            }
            x = xs
        }
        return Series(name: nonEmptyString(obj["name"]), x: x, y: y)
    }

    /// Coerce a JSON array of numbers to `[Double]`. Returns nil if `raw` isn't
    /// an array or any element isn't a finite number (NaN/Inf rejected — Charts
    /// chokes on them and they're never a valid plot value).
    private static func numbers(_ raw: Any) -> [Double]? {
        guard let arr = raw as? [Any] else { return nil }
        var out: [Double] = []
        out.reserveCapacity(arr.count)
        for element in arr {
            guard let n = element as? NSNumber else { return nil }
            let d = n.doubleValue
            guard d.isFinite else { return nil }
            out.append(d)
        }
        return out
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let s = raw as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

public enum PlotSpecError: LocalizedError, Equatable {
    case malformedJSON
    case missingData
    case emptySeries
    case badSeries(String)
    case badKind(String)
    case lengthMismatch(index: Int, x: Int, y: Int)

    public var errorDescription: String? {
        switch self {
        case .malformedJSON:
            return "spec is not a valid JSON object"
        case .missingData:
            return "spec needs either a 'series' array or a top-level 'y' array"
        case .emptySeries:
            return "'series' array is empty"
        case .badSeries(let detail):
            return detail
        case .badKind(let s):
            return "unknown chart type '\(s)' (use line, bar, or scatter)"
        case .lengthMismatch(let index, let x, let y):
            return "series[\(index)] has \(x) x-values but \(y) y-values — they must match"
        }
    }
}
