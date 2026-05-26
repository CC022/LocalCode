import AgentCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Right-side inspector. Holds everything the chat needs to surface outside
/// the message stream: the working directory, model/runtime status, the live
/// todo list, and chat-level actions (copy transcript, toggle raw view).
/// The chat itself no longer has a bottom status bar — this is the one place.
struct TasksInspector: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                WorkingDirectorySection()
                ModelSection()
                TasksSection()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 240, idealWidth: 280)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ActionsRow()
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.bar)
        }
    }
}

// MARK: - Card chrome

/// Sectioned card used for every inspector group. Title is rendered as an
/// uppercased caption; an optional trailing string sits on the right (e.g.
/// "2/5" for tasks completed).
private struct Card<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(0.5)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            content()
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.quaternary.opacity(0.4))
        }
    }
}

// MARK: - Working directory

private struct WorkingDirectorySection: View {
    @Environment(AppState.self) private var app
    @State private var changingDir = false

    var body: some View {
        Card(title: "Working Directory") {
            Button {
                changingDir = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(.tint)
                    Text(app.cwd?.lastPathComponent ?? "Pick a folder…")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(app.cwd == nil ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .font(.callout)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(app.cwd == nil
                  ? "Choose a working directory for the agent"
                  : "Change working directory (resets chat)")
        }
        .fileImporter(
            isPresented: $changingDir,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result { app.pickDirectory(url) }
        }
    }
}

// MARK: - Model

private struct ModelSection: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Card(title: "Model") {
            switch app.engine.state {
            case .ready:       readyBody
            case .downloading: downloadingBody
            case .loading:     iconLine(spinner: true, text: "Loading model…")
            case .missing:     missingBody
            case .failed(let m): failedBody(m)
            case .idle:        iconLine(text: "Idle", color: .secondary)
            }
        }
    }

    private var readyBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(.green).frame(width: 7, height: 7)
                Text("Ready")
                    .font(.callout)
                    .fontWeight(.medium)
                Spacer()
                if app.engine.inferencePhase != .idle {
                    Text(app.engine.inferencePhase.rawValue)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.tint.opacity(0.18), in: .capsule)
                        .foregroundStyle(.tint)
                }
            }
            Text(app.engine.modelName)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            contextMeter
        }
    }

    private var contextMeter: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("Context")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(Self.formatTokens(app.engine.tokenCount)) / \(Self.formatTokens(app.engine.contextWindow))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: contextFraction)
                .progressViewStyle(.linear)
                .tint(contextFraction > 0.9 ? .red
                      : contextFraction > 0.7 ? .orange
                      : .accentColor)
        }
    }

    private var downloadingBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Downloading model")
                    .font(.callout)
                Spacer()
                Text("\(Int(app.engine.downloadProgress * 100))%")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            ProgressView(value: app.engine.downloadProgress)
                .progressViewStyle(.linear)
        }
    }

    private var missingBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            iconLine(systemImage: "arrow.down.circle", text: "Model not downloaded", color: .secondary)
            Button {
                app.downloadModel()
            } label: {
                Label("Download Model", systemImage: "arrow.down.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private func failedBody(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(msg)
                .font(.callout)
                .foregroundStyle(.red)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func iconLine(
        systemImage: String? = nil,
        spinner: Bool = false,
        text: String,
        color: Color = .primary
    ) -> some View {
        HStack(spacing: 6) {
            if spinner {
                ProgressView().controlSize(.small)
            } else if let systemImage {
                Image(systemName: systemImage).foregroundStyle(color)
            }
            Text(text).font(.callout).foregroundStyle(color)
        }
    }

    private var contextFraction: Double {
        let cw = app.engine.contextWindow
        guard cw > 0 else { return 0 }
        return min(1, max(0, Double(app.engine.tokenCount) / Double(cw)))
    }

    static func formatTokens(_ n: Int) -> String {
        switch n {
        case 0..<1_000:           "\(n)"
        case 1_000..<10_000:      String(format: "%.1fk", Double(n) / 1_000)
        case 10_000..<1_000_000:  "\(n / 1_000)k"
        default:                  String(format: "%.1fM", Double(n) / 1_000_000)
        }
    }
}

// MARK: - Tasks

private struct TasksSection: View {
    @Environment(AppState.self) private var app

    private var todos: [TodoItem] { app.loop?.todos ?? [] }
    private var completedCount: Int { todos.filter { $0.status == .completed }.count }

    var body: some View {
        Card(
            title: "Tasks",
            trailing: todos.isEmpty ? nil : "\(completedCount)/\(todos.count)"
        ) {
            if todos.isEmpty {
                Text("No active tasks")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(todos) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: icon(item.status))
                                .foregroundStyle(color(item.status))
                                .font(.callout)
                                .frame(width: 14, alignment: .center)
                                .padding(.top, 1)
                            Text(item.content)
                                .strikethrough(item.status == .completed, color: .secondary)
                                .foregroundStyle(item.status == .completed ? .secondary : .primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .font(.callout)
                        }
                    }
                }
            }
        }
    }

    private func icon(_ s: TodoItem.Status) -> String {
        switch s {
        case .pending:     "circle"
        case .in_progress: "arrow.right.circle.fill"
        case .completed:   "checkmark.circle.fill"
        }
    }

    private func color(_ s: TodoItem.Status) -> Color {
        switch s {
        case .pending:     .secondary
        case .in_progress: .accentColor
        case .completed:   .green
        }
    }
}

// MARK: - Actions

private struct ActionsRow: View {
    @Environment(AppState.self) private var app
    @State private var justCopied = false

    var body: some View {
        HStack(spacing: 6) {
            Button {
                copyTranscript()
            } label: {
                Label(justCopied ? "Copied" : "Copy",
                      systemImage: justCopied ? "checkmark" : "doc.on.clipboard")
            }
            .help("Copy full transcript to clipboard")

            Button {
                app.developerMode.toggle()
            } label: {
                Label("Raw", systemImage: "curlybraces")
            }
            .tint(app.developerMode ? .accentColor : .secondary)
            .help(app.developerMode
                  ? "Hide raw model I/O"
                  : "Show raw model I/O (developer mode)")

            Button {
                app.engine.thinkingEnabled.toggle()
            } label: {
                Label("Think", systemImage: "brain")
            }
            .tint(app.engine.thinkingEnabled ? .accentColor : .secondary)
            .help(app.engine.thinkingEnabled
                  ? "Disable chain-of-thought (faster, less memory)"
                  : "Enable chain-of-thought (slower, may OOM on long sessions)")

            Spacer()
        }
        .controlSize(.small)
        .buttonStyle(.bordered)
        .labelStyle(.titleAndIcon)
    }

    private func copyTranscript() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(app.exportTranscript(), forType: .string)
        justCopied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            justCopied = false
        }
    }
}
