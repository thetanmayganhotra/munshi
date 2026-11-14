import AppKit
import Carbon
import Foundation
import SwiftUI

struct Message: Identifiable, Codable, Equatable {
    enum Role: String, Codable { case me, munshi, tool, error }
    var id = UUID()
    var role: Role
    var text: String
}

@MainActor
final class AppModel: ObservableObject {
    enum State: Equatable { case idle, listening, transcribing, thinking, speaking }

    @Published var state: State = .idle
    @Published var messages: [Message] = []
    @Published var draft = ""
    @Published var level: Float = 0
    @Published var mood: Mood = .calm

    @AppStorage("model") var model = "opus"
    @AppStorage("fullControl") var fullControl = false
    @AppStorage("devanagari") var devanagari = true
    @AppStorage("sttLanguage") var whisperLanguage = "hi"
    @AppStorage("voice") var voiceId = Speaker.defaultVoiceId { didSet { speaker.voiceId = voiceId } }
    @AppStorage("rate") var rate = 0.5 { didSet { speaker.rate = Float(rate) } }
    @AppStorage("handsFree") var autoListen = true
    @AppStorage("backend") var backend = "local" // "local" (free, Ollama) or "claude" (uses Claude plan)
    @AppStorage("localModel") var localModel = "gemma3:4b"

    private let recorder = Recorder()
    private let speaker = Speaker()
    private let brain = Brain()
    private let recall = RecallStore()
    private var turnsSinceFacts = 0
    private var meterTimer: Timer?
    private var turn = TurnState()

    /// Live end-of-turn tracking while listening.
    private struct TurnState {
        var started = Date()
        var floorDB: Float = -60
        var floorSamples: [Float] = []
        var hasSpoken = false
        var voicedRun = 0.0
        var lastVoice = Date()
        var pauseFor: Date?          // which pause the partial transcript belongs to
        var partial: Task<Void, Never>?
        var partialText: String?
        var required: Double?
    }
    private var work: Task<Void, Never>?

    init() {
        speaker.voiceId = voiceId
        speaker.rate = Float(rate)
        speaker.onIdle = { [weak self] in
            guard let self, self.state == .speaking else { return }
            self.state = .idle
            if self.autoListen { self.toggleListening() }
        }
        loadTranscript()
        // Load the local model into memory now so the first reply isn't a 30s cold start.
        if backend == "local" {
            let m = localModel
            Task.detached { _ = try? await Ollama.complete(model: m, messages: [.init(role: "user", content: "hi")]) }
        }
        HotKey.register { [weak self] in self?.toggleListening() }
    }

    // MARK: Voice loop

    func toggleListening() {
        switch state {
        case .listening: finishListening()
        case .speaking, .thinking, .transcribing:
            stopAll()
            startListening()
        case .idle: startListening()
        }
    }

    private func startListening() {
        Task {
            guard await Recorder.requestAccess() else {
                add(.error, "Mic permission nahi mili. System Settings → Privacy & Security → Microphone → Munshi on karo.")
                return
            }
            do {
                try recorder.start()
                turn = TurnState()
                state = .listening
                meterTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.tick() }
                }
            } catch {
                add(.error, error.localizedDescription)
            }
        }
    }

    /// Voice activity + turn detection, 20x a second.
    private func tick() {
        guard state == .listening else { return }
        let now = Date(), db = recorder.decibels
        level = recorder.level
        let elapsed = now.timeIntervalSince(turn.started)

        // Learn the room's background noise for the first 300 ms.
        if elapsed < 0.3 { turn.floorSamples.append(db); return }
        if !turn.floorSamples.isEmpty {
            turn.floorDB = turn.floorSamples.sorted()[turn.floorSamples.count / 2]
            turn.floorSamples = []
        }
        let threshold = max(turn.floorDB + 12, -52)
        let voiced = db > threshold

        if voiced {
            turn.voicedRun += 0.05
            if turn.voicedRun >= 0.15 { turn.hasSpoken = true }
            turn.lastVoice = now
            if turn.pauseFor != nil { // he kept going: drop the pause guess
                turn.partial?.cancel()
                turn.pauseFor = nil; turn.partialText = nil; turn.required = nil
            }
        } else {
            turn.voicedRun = 0
            turn.floorDB = turn.floorDB * 0.98 + db * 0.02 // follow slow changes (fan, AC)
        }

        guard turn.hasSpoken else {
            if elapsed > 10 { stopListeningQuietly() } // nobody spoke
            return
        }

        let silence = now.timeIntervalSince(turn.lastVoice)
        if silence >= 0.6, turn.pauseFor == nil {
            // Quick look at what he's said so far to judge: done, or thinking?
            let pause = turn.lastVoice
            turn.pauseFor = pause
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("munshi-partial.wav")
            guard let wav = try? recorder.snapshot(to: url) else { return }
            let lang = whisperLanguage
            turn.partial = Task {
                let text = (try? await Transcriber.transcribe(wav, language: lang)) ?? ""
                guard !Task.isCancelled, self.turn.pauseFor == pause else { return }
                self.turn.partialText = text
                self.turn.required = TurnDetector.requiredSilence(after: text)
            }
        }

        let required = turn.required ?? 4.0 // if the partial is slow, never wait longer than 4s
        if silence >= required || elapsed > 180 { finishListening() }
    }

    private func stopListeningQuietly() {
        meterTimer?.invalidate()
        recorder.stop()
        level = 0
        state = .idle
    }

    private func finishListening() {
        meterTimer?.invalidate()
        level = 0
        recorder.stop()
        guard turn.hasSpoken || recorder.seconds > 0.6 else { state = .idle; return }
        state = .transcribing
        // If nothing was said after the pause we already transcribed, reuse that instead of waiting again.
        let ready = turn.pauseFor == turn.lastVoice ? turn.partialText : nil
        let wav = try? recorder.snapshot(to: FileManager.default.temporaryDirectory.appendingPathComponent("munshi-input.wav"))
        let lang = whisperLanguage
        work = Task {
            do {
                var text = ready ?? ""
                if text.isEmpty, let wav { text = try await Transcriber.transcribe(wav, language: lang) }
                guard !Task.isCancelled else { return }
                if text.isEmpty { state = .idle; return }
                await send(text)
            } catch {
                add(.error, error.localizedDescription)
                state = .idle
            }
        }
    }

    func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        stopAll()
        work = Task { await send(text) }
    }

    private func send(_ text: String) async {
        add(.me, text)
        state = .thinking
        if backend == "claude" {
            let reply = await askClaude(text, recalled: await recall.search(text))
            await recall.add("Tanmay: \(text)\nMunshi: \(reply)")
            turnsSinceFacts += 1
            if turnsSinceFacts >= 4 { turnsSinceFacts = 0; Task { await self.extractFacts() } }
        } else {
            await askLocal(text)
        }
        if !speaker.isSpeaking, state != .listening { state = .idle }
    }

    /// Local model: free, unlimited. Pulls relevant old moments from recall, streams, speaks sentence by sentence.
    private func askLocal(_ text: String) async {
        let recalled = await recall.search(text)
        let history = messages.filter { $0.role == .me || $0.role == .munshi }.suffix(30).map {
            Ollama.ChatMessage(role: $0.role == .me ? "user" : "assistant", content: $0.text)
        }
        let system = Persona.systemPrompt(devanagari: devanagari, fullControl: fullControl, local: true, recalled: recalled)

        messages.append(Message(role: .munshi, text: ""))
        let idx = messages.count - 1
        var raw = "", spokenUpTo = 0
        func visible() -> String {
            let (v, m) = Self.parseReply(raw)
            if let m, m != mood { mood = m }
            return v
        }
        func speakCompleteSentences(final: Bool) {
            let v = visible()
            guard v.count > spokenUpTo else { return }
            let rest = String(v.dropFirst(spokenUpTo))
            var end = rest.endIndex
            if !final {
                guard let last = rest.lastIndex(where: { ".?!।\n".contains($0) }) else { return }
                end = rest.index(after: last)
            }
            let chunk = String(rest[..<end])
            spokenUpTo += chunk.count
            speaker.speak(chunk)
            state = .speaking
        }

        do {
            try await Ollama.chat(model: localModel, messages: [.init(role: "system", content: system)] + history) { [weak self] token in
                guard let self, !Task.isCancelled else { return }
                raw += token
                self.messages[idx].text = visible()
                speakCompleteSentences(final: false)
            }
            guard !Task.isCancelled else { return }
            speakCompleteSentences(final: true)
        } catch {
            messages.remove(at: idx)
            add(.error, error.localizedDescription)
            return
        }
        if messages[idx].text.isEmpty { messages.remove(at: idx) }
        saveTranscript()

        await recall.add("Tanmay: \(text)\nMunshi: \(visible())")
        await runActions(in: raw, userAsked: text)

        turnsSinceFacts += 1
        if turnsSinceFacts >= 4 {
            turnsSinceFacts = 0
            Task { await self.extractFacts() }
        }
    }

    /// Pulls the [[mood: x]] tag out of a reply and hides any action tags (or half-streamed ones) from display/speech.
    static func parseReply(_ raw: String) -> (visible: String, mood: Mood?) {
        let re = try! NSRegularExpression(pattern: "\\[\\[\\s*mood\\s*:\\s*(\\w+)\\s*\\]\\]", options: .caseInsensitive)
        let ns = raw as NSString
        let mood = re.firstMatch(in: raw, range: NSRange(location: 0, length: ns.length))
            .flatMap { Mood.parse(ns.substring(with: $0.range(at: 1))) }
        let stripped = re.stringByReplacingMatches(in: raw, range: NSRange(location: 0, length: ns.length), withTemplate: "")
        let cut = stripped.range(of: "[[")?.lowerBound ?? stripped.endIndex
        return (String(stripped[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines), mood)
    }

    /// Small local models sometimes invent Claude tasks nobody asked for; only hand off when his message asks for work.
    static func asksForWork(_ text: String) -> Bool {
        let t = text.lowercased()
        let cues = ["claude", "क्लॉड", "likh", "लिख", "bana", "बना", "draft", "ड्राफ्ट", "write", "research", "search", "dhundh", "ढूंढ",
                    "save", "सेव", "file", "फाइल", "kar de", "कर दे", "karo", "करो", "kar do", "कर दो", "bhej", "भेज", "open", "खोल", "khol",
                    "script", "स्क्रिप्ट", "notes", "नोट्स", "list", "लिस्ट", "plan", "प्लान", "fix", "code", "कोड"]
        return cues.contains { t.contains($0) }
    }

    private func runActions(in reply: String, userAsked: String) async {
        let re = try! NSRegularExpression(pattern: "\\[\\[(open|claude):\\s*([\\s\\S]+?)\\]\\]")
        let ns = reply as NSString
        for m in re.matches(in: reply, range: NSRange(location: 0, length: ns.length)) {
            let kind = ns.substring(with: m.range(at: 1)), arg = ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
            if kind == "open" {
                mood = .happy
                add(.tool, "open: \(arg)")
                let viaApp = (try? await Shell.run("/usr/bin/open", ["-a", arg])) != nil
                if !viaApp { _ = try? await Shell.run("/usr/bin/open", [arg]) }
            } else if Self.asksForWork(userAsked) {
                add(.tool, "Claude ko de raha hoon: \(arg)")
                state = .thinking
                let result = await askClaude(arg, recalled: [])
                await recall.add("Task given to Claude: \(arg)\nClaude: \(result)")
            }
        }
    }

    /// Claude Code: smarter + can control the Mac, but uses the Claude plan's limits.
    @discardableResult
    private func askClaude(_ text: String, recalled: [MemoryEntry]) async -> String {
        var reply = ""
        do {
            try await brain.ask(
                text,
                systemPrompt: Persona.systemPrompt(devanagari: devanagari, fullControl: fullControl, recalled: recalled),
                model: model,
                fullControl: fullControl,
                onText: { [weak self] t in
                    guard let self else { return }
                    let (visible, mood) = Self.parseReply(t)
                    if let mood { self.mood = mood }
                    guard !visible.isEmpty else { return }
                    reply += visible + "\n"
                    self.add(.munshi, visible)
                    self.speaker.speak(visible)
                    self.state = .speaking
                },
                onTool: { [weak self] t in self?.add(.tool, t) }
            )
        } catch {
            add(.error, error.localizedDescription)
        }
        return reply
    }

    /// Every few turns, the local model distills durable facts about Tanmay into memory.md.
    private func extractFacts() async {
        let recent = messages.filter { $0.role == .me || $0.role == .munshi }.suffix(12)
            .map { "\($0.role == .me ? "Tanmay" : "Munshi"): \($0.text)" }.joined(separator: "\n")
        let prompt = """
        Current memory file:
        \(Memory.load())

        Recent conversation:
        \(recent)

        List NEW, durable facts about Tanmay from the recent conversation that are not already in the memory file: \
        people in his life, feelings and struggles, projects, goals, preferences, what helps him, important events with dates. \
        One fact per line, each starting with "- ". Write in English. If there is nothing new and important, reply exactly NONE.
        """
        guard let out = try? await Ollama.complete(model: localModel, messages: [.init(role: "user", content: prompt)]) else { return }
        let facts = out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("- ") }
        guard !facts.isEmpty else { return }
        var mem = Memory.load()
        if !mem.contains("## Learned automatically") { mem += "\n## Learned automatically\n" }
        let stamp = Date().formatted(date: .abbreviated, time: .omitted)
        mem += facts.map { "\($0) (\(stamp))" }.joined(separator: "\n") + "\n"
        try? mem.write(to: Paths.memory, atomically: true, encoding: .utf8)
    }

    func stopAll() {
        work?.cancel()
        brain.cancel()
        speaker.stop()
        if state == .listening { recorder.stop(); meterTimer?.invalidate(); level = 0 }
        state = .idle
    }

    func newChat() {
        stopAll()
        brain.reset()
        messages = []
        saveTranscript()
    }

    // MARK: Memory & history

    func buildMemoryFromHistory() {
        stopAll()
        work = Task {
            await send("""
            Go through my imported Claude conversations in \(Paths.history.path)/ and update your memory.md with the important, \
            durable stuff about me: people in my life, what I'm working on, recurring struggles, what I care about, how I like \
            to be talked to. Be selective — facts, not summaries of chats. Then tell me in two lines what you learned.
            """)
        }
    }

    func importClaudeExport() {
        let panel = NSOpenPanel()
        panel.message = "Pick the folder (or conversations.json) from your claude.ai data export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let (count, chunks) = try HistoryImporter.importExport(at: url)
            add(.tool, "Imported \(count) Claude conversations. Ab sab yaad kar raha hoon (\(chunks.count) pieces)…")
            Task {
                do {
                    try await recall.addMany(chunks, source: "claude.ai") { _ in }
                    add(.tool, "Done — saari purani Claude chats ab memory mein hain.")
                } catch {
                    add(.error, "Recall indexing failed: \(error.localizedDescription)")
                }
            }
        } catch {
            add(.error, "Import failed: \(error.localizedDescription)")
        }
    }

    // MARK: Transcript

    private func add(_ role: Message.Role, _ text: String) {
        messages.append(Message(role: role, text: text))
        if messages.count > 400 { messages.removeFirst(messages.count - 400) }
        saveTranscript()
    }

    private func saveTranscript() {
        try? JSONEncoder().encode(messages).write(to: Paths.transcript)
    }

    private func loadTranscript() {
        guard let data = try? Data(contentsOf: Paths.transcript) else { return }
        messages = (try? JSONDecoder().decode([Message].self, from: data)) ?? []
    }
}

// MARK: - Global hotkey (⌃⌥Space), no Accessibility permission needed

enum HotKey {
    private static var handler: (() -> Void)?
    private static var ref: EventHotKeyRef?

    static func register(_ action: @escaping () -> Void) {
        handler = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4D4E_5348), id: 1) // 'MNSH'
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}

// MARK: - claude.ai data export → markdown files Claude can grep

enum HistoryImporter {
    static func importExport(at url: URL) throws -> (Int, [(text: String, date: Date)]) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let file = isDir.boolValue ? url.appendingPathComponent("conversations.json") : url
        let data = try Data(contentsOf: file)
        guard let convos = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw MunshiError("conversations.json ka format samajh nahi aaya")
        }
        try FileManager.default.createDirectory(at: Paths.history, withIntermediateDirectories: true)
        var count = 0
        var chunks: [(text: String, date: Date)] = []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for c in convos {
            let msgs = c["chat_messages"] as? [[String: Any]] ?? []
            guard !msgs.isEmpty else { continue }
            let name = (c["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled"
            let date = String((c["created_at"] as? String ?? "").prefix(10))
            var md = "# \(name)\n_\(date)_\n\n"
            let when = iso.date(from: c["created_at"] as? String ?? "") ?? Date()
            var pending = ""
            for m in msgs {
                let who = (m["sender"] as? String) == "human" ? "Me" : "Claude"
                var text = m["text"] as? String ?? ""
                if text.isEmpty, let content = m["content"] as? [[String: Any]] {
                    text = content.compactMap { $0["text"] as? String }.joined(separator: "\n")
                }
                guard !text.isEmpty else { continue }
                md += "**\(who):** \(text)\n\n"
                if who == "Me" {
                    pending = "[\(name)] Tanmay: \(text.prefix(1200))"
                } else if !pending.isEmpty {
                    chunks.append((pending + "\nClaude: " + text.prefix(800), when))
                    pending = ""
                }
            }
            let safe = name.replacingOccurrences(of: "[/:\\\\]", with: "-", options: .regularExpression).prefix(80)
            let uuid = (c["uuid"] as? String ?? UUID().uuidString).prefix(8)
            try md.write(to: Paths.history.appendingPathComponent("\(date) \(safe) \(uuid).md"), atomically: true, encoding: .utf8)
            count += 1
        }
        return (count, chunks)
    }
}
