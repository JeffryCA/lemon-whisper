#!/bin/bash
set -e

echo "🍋 Lemon Whisper install script"
echo ""

# Create temp directory
mkdir -p temp

# Determine whisper.cpp location
if [ -z "$WHISPER_CPP_PATH" ]; then
  echo "No WHISPER_CPP_PATH provided, installing whisper.cpp locally..."
  WHISPER_CPP_PATH="$(pwd)/whisper.cpp"
  if [ -d "$WHISPER_CPP_PATH" ]; then
    echo "Found existing whisper.cpp directory."
  else
    echo "Cloning whisper.cpp..."
    git clone https://github.com/ggerganov/whisper.cpp.git
  fi
else
  echo "Using WHISPER_CPP_PATH from environment: $WHISPER_CPP_PATH"
fi

# Save to .env
echo "WHISPER_CPP_PATH=$WHISPER_CPP_PATH" > .env

# Build whisper.cpp
cd "$WHISPER_CPP_PATH"
echo "Building whisper.cpp..."
cmake -B build
cmake --build build -j

# Download model if missing
MODEL_FILE="models/ggml-large-v3-q5_0.bin"
if [ -f "$MODEL_FILE" ]; then
  echo "Quantized model already exists."
else
  echo "Downloading quantized model..."
  ./models/download-ggml-model.sh large-v3-q5_0
fi

# Download VAD model if missing
VAD_MODEL_FILE="models/ggml-silero-v5.1.2.bin"
if [ -f "$VAD_MODEL_FILE" ]; then
  echo "VAD model already exists."
else
  echo "Downloading VAD model..."
  ./models/download-vad-model.sh silero-v5.1.2
fi


echo ""
echo "✅ Whisper.cpp and models installed successfully."
echo "👉 Next step: Configure Hammerspoon."