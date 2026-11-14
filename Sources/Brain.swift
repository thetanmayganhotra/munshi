import Foundation

/// Talks to Claude through the locally installed Claude Code CLI, so it runs on the user's own Claude plan
/// and gets Claude Code's tools (files, web, shell) for controlling the Mac.
@MainActor
final class Brain {
    private var process: Process?
    private let sessionKey = "claudeSessionId"

    var sessionId: String? {
        get { UserDefaults.standard.string(forKey: sessionKey) }
        set { UserDefaults.standard.set(newValue, forKey: sessionKey) }
    }

    func reset() { sessionId = nil }

    func cancel() {
        process?.terminate()
        process = nil
    }

    func ask(
        _ text: String,
        systemPrompt: String,
        model: String,
        fullControl: Bool,
        onText: @escaping (String) -> Void,
        onTool: @escaping (String) -> Void
    ) async throws {
        do {
            try await run(text, systemPrompt: systemPrompt, model: model, fullControl: fullControl, onText: onText, onTool: onTool)
        } catch let error as MunshiError where sessionId != nil && error.message.contains("No conversation found") {
            // Session was deleted or expired on the CLI side; start fresh.
            reset()
            try await run(text, systemPrompt: systemPrompt, model: model, fullControl: fullControl, onText: onText, onTool: onTool)
        }
    }

    private func run(
        _ text: String,
        systemPrompt: String,
        model: String,
        fullControl: Bool,
        onText: @escaping (String) -> Void,
        onTool: @escaping (String) -> Void
    ) async throws {
        guard let claude = Paths.executable("claude") else {
            throw MunshiError("Claude Code CLI nahi mila. Install it from claude.com/claude-code and log in once in Terminal.")
        }
        let home = NSHomeDirectory()
        var args = [
            "-p", text,
            "--output-format", "stream-json", "--verbose",
            "--model", model,
            "--append-system-prompt", systemPrompt,
            "--add-dir", "\(home)/Desktop", "--add-dir", "\(home)/Documents",
            "--add-dir", "\(home)/.claude",
        ]
        if fullControl {
            args += ["--permission-mode", "bypassPermissions"]
        } else {
            args += ["--allowedTools",
                     "Read", "Glob", "Grep", "Edit", "Write", "WebSearch", "WebFetch",
                     "Bash(open:*)", "Bash(ls:*)", "Bash(date)", "Bash(mdfind:*)"]
        }
        if let sessionId { args += ["--resume", sessionId] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: claude)
        p.arguments = args
        p.currentDirectoryURL = Paths.support
        p.environment = Paths.childEnvironment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        process = p

        var resultError: String?
        for try await line in out.fileHandleForReading.bytes.lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let sid = obj["session_id"] as? String { sessionId = sid }
            switch obj["type"] as? String {
            case "assistant":
                let content = (obj["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
                for block in content {
                    if block["type"] as? String == "text", let t = block["text"] as? String, !t.isEmpty {
                        onText(t)
                    } else if block["type"] as? String == "tool_use", let name = block["name"] as? String {
                        onTool(Self.describe(tool: name, input: block["input"] as? [String: Any] ?? [:]))
                    }
                }
            case "result":
                if obj["is_error"] as? Bool == true {
                    resultError = (obj["result"] as? String) ?? (obj["errors"] as? [String])?.joined(separator: " ")
                }
            default:
                break
            }
        }
        p.waitUntilExit()
        process = nil

        if p.terminationReason == .uncaughtSignal { return } // cancelled by user
        if let resultError { throw MunshiError(resultError) }
        if p.terminationStatus != 0 {
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw MunshiError(e.isEmpty ? "Claude exited with code \(p.terminationStatus)" : String(e.suffix(500)))
        }
    }

    private static func describe(tool: String, input: [String: Any]) -> String {
        let detail = (input["command"] ?? input["file_path"] ?? input["query"] ?? input["url"] ?? input["pattern"]) as? String
        return detail.map { "\(tool): \($0)" } ?? tool
    }
}
