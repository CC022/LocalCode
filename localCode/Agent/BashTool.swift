import Foundation

struct BashTool: Sendable {
    let cwd: URL

    private static let blocked = ["rm -rf /", "sudo ", "shutdown", "reboot", "> /dev/"]
    private static let maxOutput = 50_000
    private static let timeoutSeconds = 120

    nonisolated func run(_ command: String) async -> String {
        if Self.blocked.contains(where: command.contains) {
            return "Error: Dangerous command blocked"
        }
        let cwd = self.cwd
        return await Task.detached(priority: .userInitiated) {
            BashTool.execute(command: command, cwd: cwd)
        }.value
    }

    private static func execute(command: String, cwd: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = cwd
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do { try process.run() }
        catch { return "Error: \(error.localizedDescription)" }

        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + .seconds(timeoutSeconds))
        timer.setEventHandler { if process.isRunning { process.terminate() } }
        timer.resume()

        process.waitUntilExit()
        timer.cancel()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let raw = String(data: data, encoding: .utf8) ?? ""
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let capped = String(trimmed.prefix(maxOutput))
        return capped.isEmpty ? "(no output)" : capped
    }
}
