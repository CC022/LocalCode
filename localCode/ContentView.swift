import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Group {
            if app.cwd == nil {
                DirectoryPicker()
            } else {
                ChatView()
            }
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}
