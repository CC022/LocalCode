import SwiftUI

@main
struct LocalCodeApp: App {
    /// The last working directory, persisted across launches. Declared here
    /// so the key is part of the App's documented state; the actual read on
    /// launch happens synchronously in `init` to avoid a picker-flash, and
    /// writes go through `AppState.pickDirectory` under the same key.
    @AppStorage(AppState.workingDirKey) private var storedPath: String = ""

    @State private var app: AppState

    init() {
        let state = AppState()
        if let url = Self.restoredWorkingDir() {
            state.pickDirectory(url)
        }
        _app = State(initialValue: state)
    }

    /// Read the last working directory if it still exists on disk; otherwise
    /// clear the stale entry so we fall back to the picker.
    @MainActor
    private static func restoredWorkingDir() -> URL? {
        let path = UserDefaults.standard.string(forKey: AppState.workingDirKey) ?? ""
        guard !path.isEmpty else { return nil }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue else {
            UserDefaults.standard.removeObject(forKey: AppState.workingDirKey)
            return nil
        }
        return URL(fileURLWithPath: path)
    }

    var body: some Scene {
        WindowGroup {
            ContentView().environment(app)
        }
        .defaultSize(width: 900, height: 700)
    }
}
