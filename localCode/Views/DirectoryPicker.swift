import SwiftUI
import UniformTypeIdentifiers

struct DirectoryPicker: View {
    @Environment(AppState.self) private var app
    @State private var showing = false

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.fill")
                .font(.system(size: 64))
                .foregroundStyle(.tint)
            Text("Pick a working directory")
                .font(.title2.weight(.semibold))
            Text("Your local coding agent will run shell commands in this folder.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Choose Folder…") { showing = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(
            isPresented: $showing,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result { app.pickDirectory(url) }
        }
    }
}
