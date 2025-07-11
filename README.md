
# 🍋 Lemon Whisper

Lemon Whisper is a minimal macOS tool to:

- Record your voice anywhere
- Transcribe locally with Whisper.cpp
- Paste the text automatically
- Never send your audio to the cloud


## ✨ Features

- Local-only transcription
- Quantized Whisper model (Q5)
- Voice Activity Detection to avoid false positives
- Hotkey integration (Hammerspoon)
- Menu bar indicator while working

## 🚀 Quickstart

Open your Terminal and run:

```sh
git clone https://github.com/JeffryCA/lemon-whisper.git
cd lemon-whisper
```

## 🛠️ Prerequisites

1. **Install Homebrew** (if you don’t have it):
   ```sh
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```
2. **Install dependencies:**
   ```sh
   brew install cmake
   ```
3. **Create and activate a Python virtual environment:**
   ```sh
   python3 -m venv .venv
   source .venv/bin/activate
   pip install -r requirements.txt
   ```
4. **Install Hammerspoon:**
   ```sh
   brew install --cask hammerspoon
   ```

## ⚙️ Install Whisper.cpp and Models

1. Make the installer script executable:
   ```sh
   chmod +x install.sh
   ```
2. If you **already have Whisper.cpp built elsewhere** and want to avoid duplication, set the environment variable:
   ```sh
   export WHISPER_CPP_PATH=/path/to/your/whisper.cpp
   ```
3. Run the installer:
   ```sh
   ./install.sh
   ```

This will:

- Clone and build Whisper.cpp if needed
- Download the quantized model and VAD model if missing
- Create the `temp` folder

✅ No additional edits needed.

## ⚙️ Configure Hammerspoon

Hammerspoon handles the global hotkey and the 🍋 indicator.

1. Open Hammerspoon (`/Applications/Hammerspoon.app`)
2. Click the menu bar icon > **Open Config**
3. Add the code from the `init.lua` file in this repository to your `init.lua` file.
   > **Important:** Replace `/full/path/to/lemon-whisper` with the absolute path to your Lemon Whisper folder.
4. Save the file.
5. In the Hammerspoon menu, click **Reload Config**.

## 🎤 Usage

1. Place your cursor where you want the transcribed text to appear.
2. Press `Ctrl + Y` to start recording.
3. Speak clearly. While the 📝 icon is visible in the menu bar, transcription is in progress.
4. Press `Ctrl` again to stop recording.
5. The transcribed text will be automatically copied and pasted.

**Notes:**

- While recording, macOS shows a microphone indicator in the menu bar.
- If you record less than 0.5s, transcription is skipped.

## ✨ Configuration

You can adjust transcription settings by editing `local-transcription.py`.


## ❤️ Contributing

PRs welcome! Feel free to open issues or suggest improvements.

## 🙏 Acknowledgements

- [ggerganov/whisper.cpp](https://github.com/ggerganov/whisper.cpp)
- [Hammerspoon](https://www.hammerspoon.org/)
- [Silero VAD](https://github.com/snakers4/silero-vad)