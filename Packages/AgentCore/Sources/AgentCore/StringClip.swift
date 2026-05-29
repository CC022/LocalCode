import Foundation

public extension String {
    /// Clip to `maxChars`, appending a marker when truncated: `"… (N more chars)"`
    /// when `withCount`, else a fixed `"…(truncated)"`. Returns `self` when it fits.
    func clipped(to maxChars: Int, withCount: Bool = true) -> String {
        guard count > maxChars else { return self }
        let head = String(prefix(maxChars))
        return head + (withCount ? "\n... (\(count - maxChars) more chars)" : "\n…(truncated)")
    }
}
