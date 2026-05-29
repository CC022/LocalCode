import Foundation

enum SafePath {
    /// Resolve `path` relative to `cwd`, rejecting anything that escapes the workspace.
    static func resolve(_ path: String, cwd: URL) throws -> URL {
        let candidate = (path as NSString).isAbsolutePath
            ? URL(fileURLWithPath: path)
            : cwd.appendingPathComponent(path)
        let resolved = candidate.standardizedFileURL.resolvingSymlinksInPath()
        let root = cwd.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path == root.path
                || resolved.path.hasPrefix(root.path + "/") else {
            throw SafePathError.escapes(path)
        }
        return resolved
    }

    /// Render `url` relative to `cwd` when inside the workspace, else its
    /// absolute path. Pure string formatting for tool summaries.
    static func relativize(_ url: URL, to cwd: URL) -> String {
        let prefix = cwd.path.hasSuffix("/") ? cwd.path : cwd.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.path
    }
}

enum SafePathError: LocalizedError {
    case escapes(String)
    var errorDescription: String? {
        switch self {
        case .escapes(let p): "Path escapes workspace: \(p)"
        }
    }
}
