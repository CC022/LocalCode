import AgentCore
import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Group {
            if app.cwd == nil {
                DirectoryPicker()
            } else {
                ChatView()
            }
        }
        .alert("Download Gemma 4 model?", isPresented: $app.showModelDownloadPrompt) {
            Button("Download") { app.downloadModel() }
            Button("Not Now", role: .cancel) {}
        } message: {
            Text("LocalCode needs \(InferenceEngine.modelRepository) before it can chat. The download is about 15.6 GB and will be stored in the app's Application Support folder.")
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}
