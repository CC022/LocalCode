import AgentCore
import Foundation

@MainActor
func printNewMessages(loop: AgentLoop, from: Int, to: Int) {
    for msg in loop.messages[from..<to] {
        switch msg.role {
        case .user:
            print("[USER] \(msg.text)")
        case .assistant:
            if !msg.text.isEmpty {
                print("[ASSISTANT] \(msg.text)")
            }
            if let call = msg.toolCall {
                print("[TOOL CALL] \(call.summary)")
                if let r = msg.toolResult {
                    let trimmed = r.count > 1000 ? String(r.prefix(1000)) + "\n…(truncated)" : r
                    print("[TOOL RESULT]\n\(trimmed)")
                }
            }
        case .tool, .system: break
        }
    }
    print("")
}

@MainActor
func run() async {
    let args = CommandLine.arguments
    let cwd = URL(
        fileURLWithPath: args.count > 1
            ? args[1]
            : FileManager.default.currentDirectoryPath
    )

    FileHandle.standardError.write(Data("Loading model from disk…\n".utf8))
    let engine = InferenceEngine()
    await engine.load()
    guard case .ready = engine.state else {
        FileHandle.standardError.write(Data("Failed to load: \(engine.state)\n".utf8))
        exit(1)
    }
    FileHandle.standardError.write(Data(
        "Ready · \(engine.modelName) · context \(engine.contextWindow)\n".utf8))
    FileHandle.standardError.write(Data("cwd: \(cwd.path)\n\n".utf8))

    let loop = AgentLoop(cwd: cwd, engine: engine)

    while true {
        FileHandle.standardError.write(Data("> ".utf8))
        guard let line = readLine(strippingNewline: true) else { break }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }
        if trimmed == "exit" || trimmed == "quit" || trimmed == "q" { break }

        let before = loop.messages.count
        await loop.send(trimmed)
        let after = loop.messages.count
        printNewMessages(loop: loop, from: before, to: after)
    }
}

await run()
