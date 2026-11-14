import Foundation

struct MunshiError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Paths {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Munshi")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static var memory: URL { support.appendingPathComponent("memory.md") }
    static var history: URL { support.appendingPathComponent("claude-history") }
    static var transcript: URL { support.appendingPathComponent("transcript.json") }
    static var whisperModel: URL { support.appendingPathComponent("models/ggml-large-v3-turbo-q5_0.bin") }
    static let drafts: URL = {
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop/Munshi Drafts")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static let searchDirs: [String] = {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.claude/local", "/usr/bin", "/bin"]
    }()

    static func executable(_ name: String) -> String? {
        searchDirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// GUI apps launch with a bare PATH; give child processes the same one a terminal would have.
    static var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchDirs + [env["PATH"] ?? ""]).joined(separator: ":")
        return env
    }
}

enum Shell {
    /// `acceptOutputOnFailure`: some tools (whisper-cli) occasionally crash during exit cleanup after
    /// printing a perfectly good result; keep that result instead of failing.
    static func run(_ exe: String, _ args: [String], acceptOutputOnFailure: Bool = false) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                p.environment = Paths.childEnvironment
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                do { try p.run() } catch { cont.resume(throwing: error); return }
                // Drain both pipes while running so a chatty stderr can't fill its buffer and stall the process.
                var errData = Data()
                let errReader = DispatchQueue.global()
                let group = DispatchGroup()
                errReader.async(group: group) { errData = err.fileHandleForReading.readDataToEndOfFile() }
                let o = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                group.wait()
                p.waitUntilExit()
                let hasOutput = !o.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if p.terminationStatus == 0 && p.terminationReason == .exit || acceptOutputOnFailure && hasOutput {
                    cont.resume(returning: o)
                } else {
                    let e = String(decoding: errData, as: UTF8.self)
                    cont.resume(throwing: MunshiError("\(URL(fileURLWithPath: exe).lastPathComponent) failed: \(e.suffix(400))"))
                }
            }
        }
    }
}

enum Memory {
    static let seed = """
    # What Munshi knows about me

    (Munshi reads this before every reply and adds to it on its own. Edit freely.)

    ## Basics
    - Name: Tanmay (Ganhotra)
    - Stand-up comic. Writes screenplays (e.g. "Do Noori", "Comic's Comic").
    - Talks in Hinglish. Hates pretense and AI filler — plain talk only.

    ## Life & feelings

    ## Work in progress

    ## Things that help me / don't help me

    """

    static func load() -> String {
        if !FileManager.default.fileExists(atPath: Paths.memory.path) {
            try? seed.write(to: Paths.memory, atomically: true, encoding: .utf8)
        }
        return (try? String(contentsOf: Paths.memory, encoding: .utf8)) ?? ""
    }
}
