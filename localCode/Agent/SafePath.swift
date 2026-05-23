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
}

enum SafePathError: LocalizedError {
    case escapes(String)
    var errorDescription: String? {
        switch self {
        case .escapes(let p): "Path escapes workspace: \(p)"
        }
    }
}
