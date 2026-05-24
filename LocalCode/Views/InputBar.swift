import SwiftUI

struct InputBar: View {
    @Environment(AppState.self) private var app
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var app = app
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message…", text: $app.input, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($focused)
                .lineLimit(1...8)
                .padding(8)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .onSubmit { Task { await app.send() } }
            if app.isStreaming {
                Button {
                    app.stop()
                } label: {
                    Image(systemName: "stop.circle.fill")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Stop the agent")
            } else {
                Button {
                    Task { await app.send() }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.title)
                        .foregroundStyle(.tint)
                        .opacity(app.canSend ? 1 : 0.4)
                }
                .buttonStyle(.plain)
                .disabled(!app.canSend)
            }
        }
        .padding(12)
        .onAppear { focused = true }
    }
}
