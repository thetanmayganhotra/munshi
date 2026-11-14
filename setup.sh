#!/bin/zsh
# One-time setup: local speech recognition (Whisper), local brain (Ollama), then build + install Munshi.
# Downloads roughly 5 GB total. Everything runs on your Mac afterwards.
set -euo pipefail
cd "$(dirname "$0")"

SUPPORT="$HOME/Library/Application Support/Munshi"
MODEL="$SUPPORT/models/ggml-large-v3-turbo-q5_0.bin"
LOCAL_MODEL="${LOCAL_MODEL:-gemma3:4b}"

echo "==> Installing whisper.cpp and Ollama"
brew install whisper-cpp
brew install --cask ollama-app 2>/dev/null || brew install ollama

echo "==> Downloading Whisper large-v3-turbo (~550 MB, handles Hinglish)"
mkdir -p "$SUPPORT/models"
[[ -f "$MODEL" ]] || curl -L --fail -o "$MODEL" \
  https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin

echo "==> Starting Ollama and pulling models (~4.5 GB)"
open -a Ollama 2>/dev/null || (ollama serve >/dev/null 2>&1 &)
until curl -s http://127.0.0.1:11434/api/tags >/dev/null; do sleep 1; done
ollama pull "$LOCAL_MODEL"
ollama pull bge-m3

echo "==> Building Munshi"
./build.sh
rm -rf /Applications/Munshi.app
cp -R build/Munshi.app /Applications/
echo "==> Done. Opening Munshi — press ⌃⌥Space anywhere to talk."
open /Applications/Munshi.app
