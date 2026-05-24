import AgentCore
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
            modelStatus
                .padding(.top, 12)
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

    @ViewBuilder
    private var modelStatus: some View {
        switch app.engine.state {
        case .missing:
            VStack(spacing: 8) {
                Text("Model not downloaded")
                Button("Download Model") { app.downloadModel() }
                    .buttonStyle(.bordered)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .downloading:
            VStack(spacing: 8) {
                ProgressView(value: app.engine.downloadProgress)
                    .frame(width: 220)
                Text("Downloading model \(Int(app.engine.downloadProgress * 100))%")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .idle, .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Loading model in background…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .ready:
            HStack(spacing: 6) {
                Image(systemName: "circle.fill").foregroundStyle(.green).font(.caption2)
                Text("Model ready")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        case .failed(let msg):
            Text(msg)
                .font(.callout)
                .foregroundStyle(.red)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
        }
    }
}
