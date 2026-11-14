import AVFoundation
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    private var faceMood: Mood {
        switch model.state {
        case .listening: .listening
        case .transcribing, .thinking: .thinking
        default: model.mood
        }
    }

    var body: some View {
        ZStack {
            SereneBackground(tint: faceMood.look.tint[1])
            VStack(spacing: 0) {
                header
                Button { model.toggleListening() } label: {
                    FaceView(mood: faceMood, speaking: model.state == .speaking, level: model.level, size: 128)
                }
                .buttonStyle(.plain)
                .help("Click or ⌃⌥Space to talk")
                Text(statusText)
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.bottom, 6)
                    .animation(.easeInOut, value: statusText)
                transcript
                inputBar
            }
        }
        .preferredColorScheme(.dark)
        .fontDesign(.rounded)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("Munshi")
                .font(.system(.title3, design: .serif, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            Spacer(minLength: 8)
            if model.fullControl {
                Image(systemName: "bolt.fill").foregroundStyle(.orange.opacity(0.8)).help("Full control on")
            }
            Button { model.newChat() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).help("New chat (memory stays)")
            SettingsLink { Image(systemName: "slider.horizontal.3") }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 18)
        .padding(.top, 34)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if model.messages.isEmpty {
                        Text("Kya chal raha hai dimaag mein?")
                            .font(.system(.title3, design: .rounded))
                            .foregroundStyle(.white.opacity(0.4))
                            .frame(maxWidth: .infinity)
                            .padding(.top, 30)
                    }
                    ForEach(model.messages) { MessageRow(message: $0).id($0.id) }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.never)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                         .init(color: .black, location: 0.94), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .onChange(of: model.messages) {
                if let last = model.messages.last { withAnimation(.easeOut) { proxy.scrollTo(last.id, anchor: .bottom) } }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("", text: $model.draft, prompt: Text("Likh ke bolo…").foregroundStyle(.white.opacity(0.35)), axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...5)
                .onSubmit { model.sendDraft() }
            if model.state != .idle {
                Button { model.stopAll() } label: { Image(systemName: "stop.circle.fill").font(.title2) }
                    .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7))
                    .keyboardShortcut(.escape, modifiers: [])
            }
            Button { model.toggleListening() } label: {
                Image(systemName: model.state == .listening ? "waveform.circle.fill" : "mic.circle.fill").font(.title2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(model.state == .listening ? Color(hex: 0x8FE3D6) : .white.opacity(0.7))
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 22).fill(.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.08)))
        .padding([.horizontal, .bottom], 18)
    }

    private var statusText: String {
        switch model.state {
        case .idle: "⌃⌥Space — bolo, sun raha hoon"
        case .listening: "Sun raha hoon… aaram se bolo"
        case .transcribing: "Samajh raha hoon…"
        case .thinking: "Soch raha hoon…"
        case .speaking: "Click karke beech mein bolo"
        }
    }
}

/// Slow, drifting soft light — dusk sky that takes a hint of Munshi's mood colour.
struct SereneBackground: View {
    var tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 20)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                LinearGradient(colors: [Color(hex: 0x141A2E), Color(hex: 0x1B2B3A), Color(hex: 0x1E3437)],
                               startPoint: .top, endPoint: .bottom)
                Circle().fill(tint.opacity(0.22)).frame(width: 420).blur(radius: 90)
                    .offset(x: 120 * sin(t / 11), y: -180 + 40 * cos(t / 13))
                Circle().fill(Color(hex: 0x7A6FB0).opacity(0.18)).frame(width: 380).blur(radius: 100)
                    .offset(x: -140 * cos(t / 17), y: 220 + 50 * sin(t / 19))
            }
            .animation(.easeInOut(duration: 1.5), value: tint)
        }
        .ignoresSafeArea()
    }
}

struct MessageRow: View {
    let message: Message

    var body: some View {
        switch message.role {
        case .me:
            HStack {
                Spacer(minLength: 50)
                Text(message.text)
                    .textSelection(.enabled)
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 18).fill(.white.opacity(0.1)))
            }
        case .munshi:
            Text(LocalizedStringKey(message.text))
                .textSelection(.enabled)
                .font(.system(.body, design: .rounded))
                .lineSpacing(4)
                .foregroundStyle(Color(hex: 0xEDEAF6))
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            Label(message.text, systemImage: "sparkle")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
                .lineLimit(2)
        case .error:
            Label(message.text, systemImage: "exclamationmark.circle")
                .font(.system(.callout, design: .rounded))
                .foregroundStyle(Color(hex: 0xF5A3A3))
                .textSelection(.enabled)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            Section("Brain") {
                Picker("Main brain", selection: $model.backend) {
                    Text("Local — free, unlimited, private").tag("local")
                    Text("Claude — smarter, uses your Claude plan").tag("claude")
                }
                TextField("Local model (Ollama)", text: $model.localModel)
                Text("Local mode still hands big tasks to Claude when you say \"Claude se karwao\" or it needs to work on files/apps.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Claude model", selection: $model.model) {
                    Text("Opus (smartest)").tag("opus")
                    Text("Sonnet (faster)").tag("sonnet")
                    Text("Haiku (fastest)").tag("haiku")
                }
                Toggle("Full control of this Mac", isOn: $model.fullControl)
                Text(model.fullControl
                     ? "Can run any command, AppleScript, control apps. It'll ask before destructive stuff, but it CAN do anything."
                     : "Safe: read files, web search, open apps, edit files on Desktop/Documents.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Voice") {
                Picker("Voice", selection: $model.voiceId) {
                    Text("Auto — Lekha for Hindi, Tara for Roman").tag(Speaker.autoVoiceId)
                    ForEach(Speaker.indianVoices, id: \.identifier) { v in
                        Text("\(v.name) (\(v.language)\(v.quality == .default ? "" : ", HQ"))").tag(v.identifier)
                    }
                }
                Slider(value: $model.rate, in: 0.35...0.65) { Text("Speed") }
                Toggle("Hindi words in Devanagari (better pronunciation)", isOn: $model.devanagari)
                Toggle("Hands-free: listen again after it replies", isOn: $model.autoListen)
                Picker("Speech recognition language", selection: $model.whisperLanguage) {
                    Text("Hinglish (recommended)").tag("hi")
                    Text("Auto-detect").tag("auto")
                    Text("English only").tag("en")
                }
                Text("Better voices: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices → Hindi → download Lekha (Enhanced/Premium).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Memory") {
                Button("Open memory file") { NSWorkspace.shared.open(Paths.memory) }
                Button("Import claude.ai data export…") { model.importClaudeExport() }
                Button("Learn about me from imported chats") { model.buildMemoryFromHistory() }
                Text("Get your export at claude.ai → Settings → Privacy → Export data. Everything stays in ~/Library/Application Support/Munshi.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .onAppear { _ = Memory.load() }
    }
}
