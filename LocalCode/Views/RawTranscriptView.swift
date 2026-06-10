import AgentCore
import SwiftUI

/// Developer-mode replacement for the message bubble list. Renders every
/// message (including the normally hidden system + tool roles) wrapped in
/// Gemma 4's chat-template role markers, with assistant turns carrying the
/// `GemmaWireFormat`-serialized tool call + tool result inline.
///
/// Color scheme is strictly **direction-of-flow**, not role:
/// - **Output from model** (assistant text + emitted `<|tool_call>` wire
///   format): `.primary`. Markers that wrap a model turn are tinted the
///   same way so the turn reads as a single visual block.
/// - **Input to model** (system, user, tool, plus the `<|tool_response>`
///   block we append back inside an assistant turn): `.accentColor`.
///   Markers wrapping input turns are tinted toward accent too.
/// - Chat-template scaffolding (`<start_of_turn>X` / `<end_of_turn>`) is
///   rendered at reduced opacity so it reads as framing, not content.
///
/// The trailing `<start_of_turn>model\n` cue at the end shows where the
/// next generation would begin.
struct RawTranscriptView: View {
    let messages: [Message]

    /// While true, streaming keeps the viewport pinned to the bottom. Scrolling
    /// up detaches it; scrolling back to the bottom re-attaches it. Starts
    /// attached. Mirrors `ChatView`'s sticky-bottom behavior.
    @State private var followBottom = true

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // The same trick `messagesScroll` uses: push the actual
                // content to the bottom of the scroll viewport so short
                // transcripts hug the input bar instead of floating at the
                // top of the window.
                VStack(alignment: .leading, spacing: 0) {
                    Text(rendered)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .defaultScrollAnchor(.bottom)
            // Re-evaluate bottom-follow from geometry, but only on frames where
            // the content did NOT grow — streaming appends height a frame before
            // the offset catches up, which would falsely read as "scrolled up".
            // Pure scroll frames update `followBottom` straight from the
            // distance, so re-attach lands even after the gesture ends.
            .onScrollGeometryChange(for: Metrics.self) { geo in
                Metrics(offsetY: geo.contentOffset.y,
                        contentHeight: geo.contentSize.height,
                        containerHeight: geo.containerSize.height)
            } action: { old, new in
                guard new.contentHeight <= old.contentHeight + 0.5 else { return }
                followBottom = new.distanceFromBottom < Self.bottomEpsilon
            }
            // Streaming growth: keep the bottom pinned while attached.
            .onChange(of: scrollSignal) {
                guard followBottom else { return }
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            // New user turn: explicit intent — re-attach and snap.
            .onChange(of: lastUserID) {
                followBottom = true
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }

    /// Bumps on any growth — new message OR the last message's text/result
    /// extending during streaming.
    private var scrollSignal: Int {
        let lastText = messages.last?.text.count ?? 0
        let lastResult = messages.last?.toolResult?.count ?? 0
        return messages.count * 1_000_000 + lastText + lastResult
    }

    /// Identity of the most recent user message. Changes on send, which we
    /// treat as an explicit intent to follow the new turn.
    private var lastUserID: UUID? {
        messages.last(where: { $0.role == .user })?.id
    }

    /// Snapshot of the scroll geometry. `distanceFromBottom` is the gap between
    /// the viewport bottom and the content bottom (≈0 when parked).
    private struct Metrics: Equatable {
        var offsetY: CGFloat
        var contentHeight: CGFloat
        var containerHeight: CGFloat
        var distanceFromBottom: CGFloat { contentHeight - offsetY - containerHeight }
    }

    private static let bottomID = "raw-bottom"
    /// Slack between viewport bottom and content bottom that still counts as
    /// "parked". Roughly one line of body text.
    private static let bottomEpsilon: CGFloat = 24

    // MARK: - Rendering

    /// Build the colored transcript. Each message becomes
    /// `<start_of_turn>{role}\n{content}<end_of_turn>\n` and we append a
    /// final `<start_of_turn>model\n` to mark where the next generation
    /// would begin.
    private var rendered: AttributedString {
        var out = AttributedString()
        for msg in messages {
            let dir = direction(for: msg.role)
            out += marker("<start_of_turn>\(roleTag(msg.role))\n", direction: dir)
            out += body(of: msg)
            // Trim duplicate trailing newline so `<end_of_turn>` lines up
            // immediately under the last content line.
            if !(out.characters.last?.isNewline ?? false) {
                out += AttributedString("\n")
            }
            out += marker("<end_of_turn>\n", direction: dir)
        }
        // Trailing generation cue is the start of a future *model* turn.
        out += marker("<start_of_turn>model\n", direction: .output)
        return out
    }

    private enum Direction { case input, output }

    private func direction(for role: Message.Role) -> Direction {
        role == .assistant ? .output : .input
    }

    /// Chat-template control tokens — rendered at reduced opacity in the
    /// direction's color so the turn boundary reads as framing for *this*
    /// kind of turn instead of as neutral scaffolding.
    private func marker(_ s: String, direction: Direction) -> AttributedString {
        var a = AttributedString(s)
        a.foregroundColor = (direction == .output)
            ? Self.outputMarkerColor
            : Self.inputMarkerColor
        return a
    }

    /// Color-coded message body. Mirrors `InferenceEngine.stream`'s
    /// `Chat.Message` assembly: assistant turns inline the wire-format
    /// tool call + tool response.
    ///
    /// Within an assistant turn we still split colors by *direction*:
    /// the model-emitted tool call stays on the output side, but the
    /// tool response we append (which becomes input on the next turn)
    /// flips to the input color so the boundary is visible.
    private func body(of msg: Message) -> AttributedString {
        var out = AttributedString()
        // Assistant CoT block is stripped from `text` by GemmaWireFormat.parse
        // but kept on the message so we can re-emit it here in the same
        // wire form the model produced (`<|channel>thought\n…<channel|>`).
        if msg.role == .assistant, let thinking = msg.thinking, !thinking.isEmpty {
            var t = AttributedString("<|channel>thought\n\(thinking)<channel|>")
            t.foregroundColor = Self.outputColor
            out += t
        }
        if !msg.text.isEmpty {
            if out.characters.count > 0 { out += AttributedString("\n") }
            var t = AttributedString(msg.text)
            t.foregroundColor = (msg.role == .assistant) ? Self.outputColor : Self.inputColor
            out += t
        }
        if msg.role == .assistant, let call = msg.toolCall {
            // Match the engine's spacing between text and the wire-format call.
            if out.characters.count > 0 && !(out.characters.last?.isNewline ?? false) {
                out += AttributedString("\n")
            }
            var callStr = AttributedString(GemmaWireFormat.serialize(call))
            // The tool call wire format is what the model emitted — output.
            callStr.foregroundColor = Self.outputColor
            out += callStr

            if let result = msg.toolResult {
                var resp = AttributedString(
                    GemmaWireFormat.serializeResponse(toolName: call.name, output: result))
                // The tool response is INPUT to the next turn — flip color.
                resp.foregroundColor = Self.inputColor
                out += resp
            }
        }
        return out
    }

    private func roleTag(_ role: Message.Role) -> String {
        switch role {
        case .system:    return "system"
        case .user:      return "user"
        case .assistant: return "model"
        case .tool:      return "tool"
        }
    }

    // MARK: - Palette
    private static let inputColor: Color = .accentColor
    private static let outputColor: Color = .primary
    /// Markers around input turns: muted accent so they read as framing
    /// for input content.
    private static let inputMarkerColor: Color = .accentColor.opacity(0.45)
    /// Markers around model turns: muted primary so they read as framing
    /// for output content (visually distinct from the accent-tinted
    /// markers that wrap input turns).
    private static let outputMarkerColor: Color = .primary.opacity(0.35)
}
