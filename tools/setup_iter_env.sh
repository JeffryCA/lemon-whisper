#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "== LemonWhisper iteration environment bootstrap =="

mkdir -p eval/audio_corpus
mkdir -p eval/runs

if [[ -f "pyLemonWhisper/.env" ]]; then
  echo "Found env file: pyLemonWhisper/.env"
else
  echo "Missing pyLemonWhisper/.env"
  echo "Create it with: WHISPER_CPP_PATH=/absolute/path/to/whisper.cpp"
  exit 1
fi

WHISPER_CPP_PATH="$(awk -F= '/^WHISPER_CPP_PATH=/{print $2}' pyLemonWhisper/.env)"
if [[ -z "${WHISPER_CPP_PATH}" ]]; then
  echo "WHISPER_CPP_PATH not set in pyLemonWhisper/.env"
  exit 1
fi

if [[ ! -x "${WHISPER_CPP_PATH}/build/bin/whisper-cli" ]]; then
  echo "whisper-cli not found at ${WHISPER_CPP_PATH}/build/bin/whisper-cli"
  echo "Run: cd ${WHISPER_CPP_PATH} && cmake -B build && cmake --build build -j"
  exit 1
fi

if [[ ! -f "${WHISPER_CPP_PATH}/models/ggml-large-v3-turbo.bin" ]]; then
  echo "Model missing: ${WHISPER_CPP_PATH}/models/ggml-large-v3-turbo.bin"
  exit 1
fi

if [[ ! -f "${WHISPER_CPP_PATH}/models/ggml-silero-v5.1.2.bin" ]]; then
  echo "VAD model missing: ${WHISPER_CPP_PATH}/models/ggml-silero-v5.1.2.bin"
  exit 1
fi

echo "OK: whisper.cpp + models found"
echo "Audio corpus dir: ${ROOT_DIR}/eval/audio_corpus"
echo "Run eval:"
echo "  .venv/bin/python tools/run_local_eval.py --run-name baseline"
