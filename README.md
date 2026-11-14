# Munshi

A Hinglish voice companion for the Mac. Press **⌃⌥Space** anywhere, talk, and Munshi talks back — like a friend who remembers you. It can also open apps and hand bigger tasks to Claude.

Native SwiftUI. Runs fully on your Mac if you want: local speech recognition (Whisper) and a local brain (Ollama). It can also use the Claude Code CLI on your own Claude plan.

## Features

- **Global hotkey** (⌃⌥Space) to talk from anywhere.
- **Speech to text** with whisper.cpp (`large-v3-turbo`, handles Hinglish), with automatic end-of-turn detection.
- **Two brains:**
  - **Local** — Ollama (`gemma3:4b` by default). Free and offline.
  - **Claude** — through the locally installed Claude Code CLI, with its tools (files, web, shell) to control the Mac.
- **Memory** — a `memory.md` of facts that gets updated automatically, plus recall of relevant past conversations through embeddings (`bge-m3`, multilingual).
- **Actions** — the local brain can add `[[open: …]]` or `[[claude: …]]` tags to open apps/URLs or delegate a task to Claude.
- **Voice out** — Hindi in Devanagari for natural pronunciation, English words stay English.
- **Animated face** with moods, and a calm chat window.
- Can import your past Claude conversations as history.

## Setup

One-time setup installs whisper.cpp and Ollama, downloads the models (~5 GB), then builds and installs the app:

```bash
./setup.sh
```

Just build (needs only the Xcode Command Line Tools):

```bash
./build.sh          # -> build/Munshi.app
```

Data lives in `~/Library/Application Support/Munshi/`.

## Layout

```
Sources/
  MunshiApp.swift   app entry, hotkey
  AppModel.swift    conversation state
  Brain.swift       Claude Code CLI bridge
  LocalBrain.swift  Ollama chat + embeddings + recall store
  Persona.swift     system prompt + memory rules
  Voice.swift       recorder, turn detector, Whisper transcriber, speaker
  Face.swift        animated face
  Views.swift       chat + settings UI
  Support.swift     paths, shell, memory, history import
scripts/            icon + snapshot helpers
```

Requires macOS 14+ on Apple Silicon.
