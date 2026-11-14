import Foundation

/// Free, fully local brain via Ollama (http://localhost:11434).
enum Ollama {
    static let base = URL(string: "http://127.0.0.1:11434")!
    static let embedModel = "bge-m3" // multilingual, handles Hindi/Hinglish/English

    struct ChatMessage: Codable { let role: String; let content: String }

    /// Streams the reply token by token.
    static func chat(model: String, messages: [ChatMessage], onToken: @escaping (String) -> Void) async throws {
        var req = URLRequest(url: base.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.timeoutInterval = 600
        let body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
            "think": false,
            "keep_alive": "60m",
            "options": ["num_ctx": 8192, "temperature": 0.8],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (bytes, response) = try await perform(req)
        try check(response, model: model)
        for try await line in bytes.lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let err = obj["error"] as? String { throw MunshiError(err) }
            if let t = (obj["message"] as? [String: Any])?["content"] as? String, !t.isEmpty { onToken(t) }
        }
    }

    /// One-shot, non-streaming completion (used for memory extraction).
    static func complete(model: String, messages: [ChatMessage]) async throws -> String {
        var out = ""
        try await chat(model: model, messages: messages) { out += $0 }
        return out
    }

    static func embed(_ texts: [String]) async throws -> [[Float]] {
        var req = URLRequest(url: base.appendingPathComponent("api/embed"))
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.httpBody = try JSONSerialization.data(withJSONObject: ["model": embedModel, "input": texts, "keep_alive": "60m"])
        let (bytes, response) = try await perform(req)
        try check(response, model: embedModel)
        var data = Data()
        for try await b in bytes { data.append(b) }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let vecs = obj["embeddings"] as? [[Double]] else { throw MunshiError("Embedding failed") }
        return vecs.map { $0.map(Float.init) }
    }

    private static func perform(_ req: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        if let r = try? await URLSession.shared.bytes(for: req) { return r }
        // Ollama not running: start it quietly and retry for ~15s.
        _ = try? await Shell.run("/usr/bin/open", ["-g", "-a", "Ollama"])
        for _ in 0..<30 {
            try await Task.sleep(nanoseconds: 500_000_000)
            if let r = try? await URLSession.shared.bytes(for: req) { return r }
        }
        throw MunshiError("Ollama start nahi hua. Open the Ollama app once, then try again.")
    }

    private static func check(_ response: URLResponse, model: String) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 404 { throw MunshiError("Model '\(model)' downloaded nahi hai. Run: ollama pull \(model)") }
        if http.statusCode >= 400 { throw MunshiError("Ollama error \(http.statusCode)") }
    }
}

// MARK: - Total recall: every exchange saved + semantic search

struct MemoryEntry: Codable {
    var date: Date
    var source: String // "munshi" or "claude.ai"
    var text: String
    var vector: [Float]?
}

/// Every conversation turn ever, stored locally in recall.jsonl with an embedding so relevant old moments
/// can be pulled back into context — that's how it "remembers everything" without an infinite context window.
@MainActor
final class RecallStore {
    private(set) var entries: [MemoryEntry] = []
    private var url: URL { Paths.support.appendingPathComponent("recall.jsonl") }
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }()
    private let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }()

    init() {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return }
        entries = data.split(separator: "\n").compactMap { try? decoder.decode(MemoryEntry.self, from: Data($0.utf8)) }
    }

    func add(_ text: String, source: String = "munshi", date: Date = Date()) async {
        let vector = try? await Ollama.embed([text]).first
        append([MemoryEntry(date: date, source: source, text: text, vector: vector)])
    }

    /// Bulk add (for imports), embedding in batches.
    func addMany(_ items: [(text: String, date: Date)], source: String, progress: @escaping (Int) -> Void) async throws {
        var done = 0
        for batch in stride(from: 0, to: items.count, by: 16).map({ Array(items[$0..<min($0 + 16, items.count)]) }) {
            let vecs = try await Ollama.embed(batch.map(\.text))
            append(zip(batch, vecs).map { MemoryEntry(date: $0.date, source: source, text: $0.text, vector: $1) })
            done += batch.count
            progress(done)
        }
    }

    func search(_ query: String, limit: Int = 6, skipRecent: Int = 10) async -> [MemoryEntry] {
        let older = entries.dropLast(skipRecent)
        guard let q = try? await Ollama.embed([query]).first else { return keywordSearch(query, in: Array(older), limit: limit) }
        // bge-m3 scores on Hinglish sit in a narrow band (~0.35–0.65), so rank relative to the best match
        // instead of using a fixed cutoff.
        let ranked = older.filter { $0.vector != nil }
            .map { (entry: $0, score: cosine(q, $0.vector!)) }
            .sorted { $0.score > $1.score }
        guard let best = ranked.first?.score, best >= 0.4 else { return [] }
        return ranked.filter { $0.score >= max(0.4, best - 0.05) }.prefix(limit).map(\.entry)
    }

    /// Fallback when embeddings aren't available: rank by shared words.
    private func keywordSearch(_ query: String, in pool: [MemoryEntry], limit: Int) -> [MemoryEntry] {
        let words = Set(query.lowercased().split { !$0.isLetter }.map(String.init).filter { $0.count > 3 })
        guard !words.isEmpty else { return [] }
        let minHits = words.count == 1 ? 1 : 2
        var scored: [(entry: MemoryEntry, hits: Int)] = []
        for e in pool {
            let text = e.text.lowercased()
            let hits = words.filter { text.contains($0) }.count
            if hits >= minHits { scored.append((e, hits)) }
        }
        return scored.sorted { $0.hits > $1.hits }.prefix(limit).map(\.entry)
    }

    private func append(_ new: [MemoryEntry]) {
        entries += new
        let lines = new.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) + "\n" }
        let blob = Data(lines.joined().utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(blob); try? h.close()
        } else {
            try? blob.write(to: url)
        }
    }

    private func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in a.indices { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return dot / (sqrt(na) * sqrt(nb) + 1e-9)
    }
}
