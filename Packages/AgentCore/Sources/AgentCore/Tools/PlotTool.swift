import Foundation
import MLXLMCommon

/// Renders a chart in the chat using SwiftUI Charts. The model passes the whole
/// plot as a single JSON-encoded `spec` string — the same escape-hatch as
/// `todo_write` — because the Gemma tool-call parser splits arguments on
/// top-level commas without bracket-awareness, which would shred any raw array
/// argument like `[1, 2, 3]`.
///
/// This tool only validates the spec and returns a short confirmation; the
/// actual drawing happens in the app's `PlotView`, which decodes the very same
/// `PlotSpec` from the call's arguments. So the data lives in the tool call,
/// never in the (context-bloating) tool result.
struct PlotTool: Tool {
    let name = "plot"

    var toolSpec: ToolSpec {
        ToolSpecBuilder.make(
            name: name,
            description: """
            Render a chart that is shown to the user directly in the chat. Use this whenever the user asks to plot, chart, graph, or visualize numbers — do NOT describe the data as text instead. Pass the entire plot as a JSON-encoded string in 'spec'.

            spec fields:
              • "type": "line" (default), "bar", or "scatter".
              • "title", "x_label", "y_label": optional strings.
              • Data, in one of two forms:
                  - single series shorthand: "y": [numbers], with optional "x": [numbers].
                  - multiple series: "series": [{"name": "...", "y": [numbers], "x": [numbers]}, ...].
                When "x" is omitted the values are plotted against their index (0, 1, 2, …).

            Examples:
              {"y": [1, 4, 9, 16, 25]}
              {"type": "scatter", "x": [0, 1, 2, 3], "y": [1.1, 2.3, 2.0, 3.8], "x_label": "t", "y_label": "v"}
              {"title": "Sales", "type": "bar", "series": [{"name": "2023", "y": [3, 5, 4]}, {"name": "2024", "y": [4, 6, 7]}]}

            After calling this, just confirm briefly — the chart is already visible to the user.
            """,
            properties: [
                (name: "spec", type: "string",
                 description: #"JSON string describing the chart, e.g. '{"type":"line","y":[1,4,9]}'."#),
            ],
            required: ["spec"]
        )
    }

    nonisolated func run(_ arguments: [String: JSONValue]) async -> String {
        guard let json = arguments["spec"]?.string else {
            return "Error: missing 'spec' (expected a JSON string describing the chart)"
        }
        do {
            let spec = try PlotSpec.parse(json)
            let parts = spec.series.map { s -> String in
                let label = s.name ?? "series"
                return "\(label): \(s.y.count) points"
            }
            let titleSuffix = spec.title.map { " \"\($0)\"" } ?? ""
            return "Rendered \(spec.kind.rawValue) chart\(titleSuffix) with "
                + "\(spec.series.count) series (\(parts.joined(separator: ", "))). "
                + "The chart is now displayed to the user."
        } catch {
            return "Error: \(error.localizedDescription)"
        }
    }
}
