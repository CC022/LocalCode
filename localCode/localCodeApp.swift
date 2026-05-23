import SwiftUI

@main
struct localCodeApp: App {
    @State private var app = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView().environment(app)
        }
        .defaultSize(width: 900, height: 700)
    }
}
