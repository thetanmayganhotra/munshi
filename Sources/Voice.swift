import AVFoundation
import Foundation

// MARK: - Mic

/// Captures mic audio as 16 kHz mono samples in memory, so we can measure loudness live and
/// transcribe "what he's said so far" mid-pause without stopping the recording.
final class Recorder {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
    private let lock = NSLock()
    private var samples: [Float] = []
    private var lastDB: Float = -160
    private(set) var isRecording = false

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start() throws {
        lock.lock(); samples = []; lastDB = -160; lock.unlock()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { throw MunshiError("Mic nahi mila. Check System Settings → Sound → Input.") }
        converter = AVAudioConverter(from: format, to: target)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.ingest(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    private func ingest(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = target.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32) else { return }
        var fed = false
        converter.convert(to: out, error: nil) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard let ch = out.floatChannelData?[0], out.frameLength > 0 else { return }
        let chunk = Array(UnsafeBufferPointer(start: ch, count: Int(out.frameLength)))
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
        lock.lock()
        samples += chunk
        lastDB = 20 * log10(max(rms, 1e-7))
        lock.unlock()
    }

    /// Current loudness in dBFS.
    var decibels: Float { lock.lock(); defer { lock.unlock() }; return lastDB }
    /// 0...1 for the UI.
    var level: Float { max(0, min(1, (decibels + 55) / 45)) }
    var seconds: Double { lock.lock(); defer { lock.unlock() }; return Double(samples.count) / 16000 }

    /// Writes everything captured so far to a WAV (recording keeps going).
    func snapshot(to url: URL) throws -> URL {
        lock.lock(); let copy = samples; lock.unlock()
        try Self.writeWAV(copy, to: url)
        return url
    }

    func stop() {
        guard isRecording else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        isRecording = false
    }

    private static func writeWAV(_ s: [Float], to url: URL) throws {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(s.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        let pcm = s.map { Int16(max(-1, min(1, $0)) * 32767).littleEndian }
        pcm.withUnsafeBytes { d.append(contentsOf: $0) }
        try d.write(to: url)
    }
}

/// Decides whether a pause means "I'm done" or "I'm thinking / pausing for effect".
enum TurnDetector {
    /// Silence needed before replying, given what he's said so far.
    static func requiredSilence(after text: String) -> Double {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return 3.0 }
        if t.hasSuffix("...") || t.hasSuffix("…") || t.hasSuffix(",") || t.hasSuffix("-") { return 3.5 }
        let last = t.lowercased().split(whereSeparator: { $0 == " " }).last.map {
            String($0).trimmingCharacters(in: .punctuationCharacters.union(CharacterSet(charactersIn: "।")))
        } ?? ""
        if continuers.contains(last) { return 3.5 }
        if "?!।.".contains(t.last!) || enders.contains(last) { return 1.1 }
        return 2.0
    }

    /// Words people trail off on when they're mid-thought.
    static let continuers: Set<String> = [
        "and", "but", "or", "so", "because", "like", "um", "umm", "uh", "hmm", "the", "a", "to", "of", "with", "if", "then", "that", "which",
        "aur", "lekin", "par", "ki", "ke", "ka", "toh", "to", "matlab", "kyunki", "jaise", "ya", "mein", "main", "jo", "agar", "phir", "fir", "woh", "ye",
        "और", "लेकिन", "पर", "कि", "के", "का", "की", "तो", "मतलब", "क्योंकि", "जैसे", "या", "में", "मैं", "जो", "अगर", "फिर", "वो", "ये",
        "हम्म", "उम्म", "अं", "एंड", "बट", "सो", "लाइक", "बिकॉज़", "द",
    ]

    /// Words Hindi/Hinglish sentences usually finish on.
    static let enders: Set<String> = [
        "hai", "hain", "tha", "thi", "the", "hoon", "hu", "ho", "gaya", "gayi", "yaar", "na", "right", "okay", "ok", "bro", "please", "thanks",
        "है", "हैं", "था", "थे", "थी", "हूँ", "हूं", "हो", "गया", "गई", "गए", "रहा", "रही", "रहे", "दिया", "चाहिए", "यार", "ना", "न",
        "ओके", "राइट", "प्लीज़", "थैंक्स", "क्या", "कैसे", "क्यों",
    ]
}

// MARK: - Speech to text (local Whisper)

enum Transcriber {
    static func transcribe(_ wav: URL, language: String) async throws -> String {
        guard let bin = Paths.executable("whisper-cli") else {
            throw MunshiError("whisper-cli nahi mila. Run Munshi/setup.sh once.")
        }
        guard FileManager.default.fileExists(atPath: Paths.whisperModel.path) else {
            throw MunshiError("Whisper model missing. Run Munshi/setup.sh once.")
        }
        // whisper-cli sometimes crashes in its exit cleanup; when stdout is a pipe the result is still sitting
        // in the stdio buffer and gets lost. The -otxt file is written and closed before exit, so read that.
        let base = wav.deletingPathExtension().path + "-transcript"
        let txt = URL(fileURLWithPath: base + ".txt")
        try? FileManager.default.removeItem(at: txt)
        // Hindi mode keeps both languages (English words come out in Devanagari, which the brain reads fine);
        // auto-detect tends to pick English and silently drop the Hindi half. A prompt made it worse, so none.
        let stdout = try? await Shell.run(bin, [
            "-m", Paths.whisperModel.path, "-f", wav.path,
            "-l", language, "-nt", "-np",
            "-mc", "0", // no carry-over context: stops "I am, I am, I am…" repetition loops
            "-sns",     // suppress non-speech tokens like (music) [applause]
            "-otxt", "-of", base,
        ], acceptOutputOnFailure: true)
        guard let raw = (try? String(contentsOf: txt, encoding: .utf8)) ?? stdout else {
            throw MunshiError("Awaaz samajh nahi aayi — ek baar aur bolo?")
        }
        return raw
            .replacingOccurrences(of: "[BLANK_AUDIO]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Text to speech (Apple voices, offline)

final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    var voiceId: String = ""
    var rate: Float = 0.5
    var onIdle: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    var isSpeaking: Bool { synth.isSpeaking }

    /// Hindi + Indian English voices, best quality first.
    static var indianVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == "hi-IN" || $0.language == "en-IN" }
            .sorted { ($0.quality.rawValue, $0.language) > ($1.quality.rawValue, $1.language) }
    }

    /// "auto" = pick per sentence: Devanagari → best Hindi voice, Roman → best Indian-English voice.
    /// (Round-trip tests: Lekha mangles Roman Hinglish, but Tara reads it almost perfectly.)
    static let autoVoiceId = "auto"
    static var defaultVoiceId: String { autoVoiceId }

    private static func bestVoice(_ language: String, preferring name: String) -> AVSpeechSynthesisVoice? {
        let vs = indianVoices.filter { $0.language == language }
        return vs.first { $0.name.contains(name) } ?? vs.first
    }

    private func voice(for text: String) -> AVSpeechSynthesisVoice? {
        if voiceId != Self.autoVoiceId, let v = AVSpeechSynthesisVoice(identifier: voiceId) { return v }
        let devanagari = text.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) }
        return devanagari ? Self.bestVoice("hi-IN", preferring: "Lekha") : Self.bestVoice("en-IN", preferring: "Tara")
    }

    func speak(_ text: String) {
        let clean = Self.speakable(text)
        guard !clean.isEmpty else { return }
        // One utterance per sentence so auto-voice can pick Hindi vs English voice for each.
        var sentences: [String] = []
        clean.enumerateSubstrings(in: clean.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty { sentences.append(s) }
        }
        for sentence in sentences.isEmpty ? [clean] : sentences {
            let u = AVSpeechUtterance(string: sentence)
            u.voice = voice(for: sentence)
            u.rate = rate
            u.postUtteranceDelay = 0.05
            synth.speak(u)
        }
    }

    func stop() { synth.stopSpeaking(at: .immediate) }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        DispatchQueue.main.async { if !s.isSpeaking { self.onIdle?() } }
    }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) {
        DispatchQueue.main.async { self.onIdle?() }
    }

    /// Strip markdown/code so the voice doesn't read out asterisks and backticks.
    static func speakable(_ text: String) -> String {
        var t = text
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "https?://\\S+", with: "link", options: .regularExpression)
        t = t.replacingOccurrences(of: "[*_`#>|~]", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
