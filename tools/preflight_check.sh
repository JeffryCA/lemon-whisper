#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

ok() { echo "OK   $1"; }
warn() { echo "WARN $1"; }
fail() { echo "FAIL $1"; }

echo "== LemonWhisper preflight =="

if command -v xcodebuild >/dev/null 2>&1; then
  ok "Xcode: $(xcodebuild -version | tr '\n' ' ' | sed 's/  */ /g')"
else
  fail "Xcode not found"
fi

if command -v cmake >/dev/null 2>&1; then
  ok "cmake: $(cmake --version | head -n 1)"
else
  fail "cmake not found"
fi

if command -v ffmpeg >/dev/null 2>&1; then
  ok "ffmpeg: $(ffmpeg -version | head -n 1)"
else
  warn "ffmpeg not found (optional)"
fi

if [[ -f "pyLemonWhisper/.env" ]]; then
  ok "Found pyLemonWhisper/.env"
else
  fail "Missing pyLemonWhisper/.env"
fi

WHISPER_CPP_PATH="$(awk -F= '/^WHISPER_CPP_PATH=/{print $2}' pyLemonWhisper/.env 2>/dev/null || true)"
if [[ -n "${WHISPER_CPP_PATH}" ]]; then
  ok "WHISPER_CPP_PATH=${WHISPER_CPP_PATH}"
else
  fail "WHISPER_CPP_PATH is empty"
fi

if [[ -x "${WHISPER_CPP_PATH}/build/bin/whisper-cli" ]]; then
  ok "whisper-cli exists"
else
  fail "whisper-cli missing at ${WHISPER_CPP_PATH}/build/bin/whisper-cli"
fi

if [[ -f "${WHISPER_CPP_PATH}/models/ggml-large-v3-turbo.bin" ]]; then
  ok "base model exists"
else
  fail "missing model: ggml-large-v3-turbo.bin"
fi

if [[ -f "${WHISPER_CPP_PATH}/models/ggml-silero-v5.1.2.bin" ]]; then
  ok "VAD model exists"
else
  fail "missing model: ggml-silero-v5.1.2.bin"
fi

mkdir -p eval/audio_corpus eval/runs
ok "Eval directories ready: eval/audio_corpus, eval/runs"

echo ""
echo "Manual one-time checks still required in macOS Privacy & Security:"
echo "- Microphone"
echo "- Accessibility"
echo "- Input Monitoring"
echo "- Automation (System Events)"
