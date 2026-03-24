# LemonWhisper

LemonWhisper is a local-first macOS menu bar dictation app.

It lets you record from anywhere, transcribe speech on-device with local models, and send the result back into the app you were using before you started recording.

## What It Does

- Runs as a menu bar app instead of a full dock app.
- Records microphone audio with `Ctrl+Y` or the menu bar menu.
- Transcribes locally with either Whisper or Voxtral.
- Downloads and manages models inside the app.
- Switches between downloaded models without external scripts.
- Shows lightweight recording and transcription HUDs near the cursor.
- Saves recent transcriptions locally and lets you copy or delete them.
- Auto-pastes the transcript back into the field you started recording from.

## Current Product Shape

LemonWhisper handles the full dictation loop locally:

1. Start recording.
2. Speak.
3. Stop recording.
4. The app transcribes locally.
5. The transcript is copied to the clipboard and auto-pasted back into the field you started from.

It currently uses:

- Whisper
- Voxtral

Recommended starting point:

- Voxtral Mini 3B 4-bit

## Requirements

- macOS 15.5 or newer
- Apple Silicon is the intended development target

## Getting Started

### 1. Clone the repo

```bash
git clone https://github.com/JeffryCA/lemon-whisper.git
cd lemon-whisper
```

### 2. Open the app in Xcode

Open:

```text
LemonWhisper/LemonWhisper.xcodeproj
```

Xcode will resolve Swift Package Manager dependencies automatically.

### 3. Run the app

Select the `LemonWhisper` scheme and run it on `My Mac`.

### 4. Grant permissions on first launch

LemonWhisper needs:

- Microphone access to record audio
- Accessibility access to paste text back into other apps

If Accessibility is not enabled yet, the app will prompt for it.

## Local Storage

LemonWhisper stores app data under:

```text
~/Library/Application Support/LemonWhisper/
```

Important paths:

- Models: `~/Library/Application Support/LemonWhisper/models/`
- History database: `~/Library/Application Support/LemonWhisper/Transcriptions.sqlite`

Nothing in the normal transcription flow requires a cloud service.
