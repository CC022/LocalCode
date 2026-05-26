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
            VStack(alignment: .leading, spacing: 14) {
                WorkingDirectorySection()
                ModelSection()
                TasksSection()
                ConversationSection()
                DisplaySection()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 240, idealWidth: 280)
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
                .fill(.background.secondary)
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
        @Bindable var app = app
        Card(title: "Model") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: Binding(
                    get: { app.engine.backend },
                    set: { app.setBackend($0) }
                )) {
                    Text("Local").tag(InferenceEngine.Backend.local)
                    Text("API").tag(InferenceEngine.Backend.api)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                stateBody
            }
        }
        .sheet(isPresented: $app.showAPIConfig) {
            APIConfigSheet()
        }
    }

    @ViewBuilder
    private var stateBody: some View {
        switch (app.engine.backend, app.engine.state) {
        case (.api, .missing):
            apiUnconfiguredBody
        case (.api, _):
            apiReadyBody    // API mode shares one body — phase + model are what matter
        case (.local, .ready):
            readyBody
        case (.local, .downloading):
            downloadingBody
        case (.local, .loading):
            iconLine(spinner: true, text: "Loading model…")
        case (.local, .missing):
            missingBody
        case (.local, .failed(let m)):
            failedBody(m)
        case (.local, .idle):
            iconLine(text: "Idle", color: .secondary)
        }
    }

    private var apiReadyBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(stateDotColor)
                    .frame(width: 7, height: 7)
                Text(stateLabel)
                    .font(.callout)
                    .fontWeight(.medium)
                Spacer()
                if app.engine.inferencePhase != .idle {
                    Text("streaming")
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
            // Token count without progress bar — context window is unknown
            // for arbitrary API providers.
            if app.engine.tokenCount > 0 {
                HStack(spacing: 4) {
                    Text("Tokens").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Text(Self.formatTokens(app.engine.tokenCount))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Button {
                app.showAPIConfig = true
            } label: {
                Label("Configure", systemImage: "key")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var apiUnconfiguredBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            iconLine(systemImage: "key.slash", text: "API not configured", color: .secondary)
            Button {
                app.showAPIConfig = true
            } label: {
                Label("Configure API", systemImage: "key.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
    }

    private var stateDotColor: Color {
        switch app.engine.state {
        case .ready:        .green
        case .failed:       .red
        default:            .secondary
        }
    }

    private var stateLabel: String {
        switch app.engine.state {
        case .ready:        "Ready"
        case .failed:       "Failed"
        case .idle:         "Idle"
        case .loading:      "Loading…"
        case .downloading:  "Downloading…"
        case .missing:      "Not configured"
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

    @ViewBuilder
    private var contextMeter: some View {
        if app.engine.contextWindow > 0 {
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

// MARK: - Conversation

/// Action card for chat-level operations. Each row is a tappable label that
/// mirrors the Working Directory pattern — icon + name + trailing hint —
/// so the whole inspector reads as one consistent stack of cards.
private struct ConversationSection: View {
    @Environment(AppState.self) private var app
    @State private var justCopied = false
    @State private var confirmingClear = false

    var body: some View {
        Card(title: "Conversation") {
            VStack(alignment: .leading, spacing: 2) {
                ActionRow(
                    systemImage: "zipper.page",
                    title: "Compact",
                    busy: app.isStreaming,
                    disabled: app.isStreaming
                ) {
                    Task { await app.compactConversation() }
                }
                .help("Summarize the chat into a single seed message to free context")

                ActionRow(
                    systemImage: justCopied ? "checkmark" : "doc.on.clipboard",
                    title: justCopied ? "Copied" : "Copy"
                ) {
                    copyTranscript()
                }
                .help("Copy full transcript to clipboard")

                ActionRow(
                    systemImage: "trash",
                    title: "Clear"
                ) {
                    confirmingClear = true
                }
                .help("Erase all messages and reset the agent's context")
            }
        }
        .confirmationDialog(
            "Clear conversation?",
            isPresented: $confirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear", role: .destructive) { app.clearConversation() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This erases all messages and resets the agent's context.")
        }
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

private struct ActionRow: View {
    let systemImage: String
    let title: String
    var busy: Bool = false
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: systemImage)
                    }
                }
                .frame(width: 16, alignment: .center)
                .foregroundStyle(.secondary)
                Text(title)
                Spacer()
            }
            .font(.callout)
            .padding(.vertical, 4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }
}

// MARK: - Display

/// Toggle card for view-mode preferences. Uses native macOS switch toggles
/// so the on/off state is unambiguous without needing tint cues.
private struct DisplaySection: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        Card(title: "Display") {
            VStack(alignment: .leading, spacing: 6) {
                ToggleRow(
                    systemImage: "apple.intelligence",
                    title: "Thinking",
                    isOn: Binding(
                        get: { app.engine.thinkingEnabled },
                        set: { app.engine.thinkingEnabled = $0 }
                    )
                )
                .help("Enable chain-of-thought (slower, may OOM on long sessions)")

                ToggleRow(
                    systemImage: "curlybraces",
                    title: "Raw",
                    isOn: $app.developerMode
                )
                .help("Show raw model I/O (developer mode)")
            }
        }
    }
}

private struct ToggleRow: View {
    let systemImage: String
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, alignment: .center)
                Text(title)
                    .font(.callout)
            }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}
