# LemonWhisper

![LemonWhisper social preview](docs/social-preview.png)

LemonWhisper is a local-first macOS menu bar dictation app.

It lets you record from anywhere, transcribe speech on-device with local models, and send the result back into the app you were using before you started recording.

## What It Does

- Runs as a menu bar app instead of a full dock app.
- Start/Stop recording audio with `Ctrl+Y`.
- Cancel an in-progress recording with a double-tap of `Control`.
- Transcribes locally with Whisper, Voxtral, or Qwen3-ASR.
- Downloads and manages models inside the app (Qwen3-ASR 1.7B 4-bit is the default on Apple Silicon).
- Switches between downloaded models without external scripts.
- Shows lightweight recording and transcription HUDs near the cursor.
- Saves recent transcriptions locally and lets you copy, delete or export them.
- Auto-pastes the transcript back into the field you started recording from.

## Requirements

- macOS 15.5 or newer
- Apple Silicon is recommended

## Getting Started

### 1. Download the latest release

Download the latest `.dmg` from [GitHub Releases](https://github.com/JeffryCA/lemon-whisper/releases/latest).

### 2. Install LemonWhisper

- Open the DMG
- Drag `LemonWhisper.app` into `Applications`
- Launch LemonWhisper from `Applications`

### 3. Grant permissions on first launch

- Microphone access, so the app can record audio
- Accessibility access, so the app can paste text back into other apps

### 4. Download a model

Open **Manage Local Models** and click **Download** next to **Qwen3-ASR 1.7B (4-bit)** on
Apple Silicon. It's the default for new installs and becomes ready once downloaded.
You can choose Whisper or Voxtral instead. On Intel, choose a Whisper model.

## Development

If you want to work on the app locally:

```bash
git clone https://github.com/JeffryCA/lemon-whisper.git
cd lemon-whisper
open LemonWhisper/LemonWhisper.xcodeproj
```

Xcode will resolve Swift Package Manager dependencies automatically. Then run the `LemonWhisper` scheme on `My Mac`.

## Using Qwen3-ASR

If you already use another model, download Qwen3-ASR in **Manage Local Models**, then select it
in the model picker or the menu bar's **Model** menu. Language selection, history, paste, and
model idle unloading work with Qwen.
The model runs locally through the same disposable helper architecture as Voxtral; no Python or
transcription API is required. Its quality and peak memory have not been benchmarked against Voxtral.

For Voxtral and Qwen, recordings longer than 60 seconds are processed in bounded chunks, preferring
quiet boundaries. Each chunk has a 4,096-token output allowance instead of the previous 500-token
allowance for an entire Voxtral recording. Continuous speech at a chunk boundary can still affect
recognition; this does not establish error-free long-form transcription.

## Dictation Settings

Open **Dictation settings** from the main window to manage your dictionary. Add a preferred
term for recognition hints or pair it with a mishearing to replace that phrase before paste.
History keeps the raw text alongside any correction.

**Vocabulary hints** is off by default. Enable it with Whisper or Qwen3-ASR to pass dictionary
terms and optional custom context to the local decoder. Hints can bias recognition, so keep
the list focused on names and phrases you dictate.

On Qwen3-ASR, **Stream text into the focused field** adds words as you speak into supported
editable fields. Each update can revise the dictated text as more audio arrives. For longer
dictations, live recognition re-decodes one 24-second segment at a time. When you stop,
Lemon Whisper transcribes the full recording and finalizes only the range it inserted.
Editing the field starts a new segment, and the final pass uses audio since that edit.
Moving the caret or switching fields pauses live edits. With an unsupported or missing
field, Lemon Whisper uses its standard final paste. Live streaming is off by default.
With Qwen3-ASR selected, you can also turn **Live Transcription** on or off from the
Lemon menu bar menu. The menu and Dictation settings share the same preference, which
applies when you start your next recording.

**Spoken replacements** stores saved values in a separate local file. Add a spoken
shortcut such as “my email” or “my phone number.” The settings show the saved value and let you
edit it. Say the shortcut by itself to insert the value. Matching ignores capitalization and
punctuation between or around words. Lemon Whisper expands the shortcut during final insertion.
History shows the spoken shortcut.

Codex or a terminal can edit the same local dictionary with Python 3:

```sh
python3 Tools/dictation_dictionary.py list
python3 Tools/dictation_dictionary.py add Greptile --alias Graptile
python3 Tools/dictation_dictionary.py add 'make down'
```

The local diagnostic log records the model output, dictionary corrections, and final
text prepared for insertion, including expanded spoken replacements, alongside paste status.

## Local Storage

LemonWhisper stores app data under:

```text
~/Library/Application Support/LemonWhisper/
```

Your data:

- Models: `~/Library/Application Support/LemonWhisper/models/`
- Qwen model: `~/Library/Application Support/LemonWhisper/models/qwen3-asr-1.7b-4bit/`
- Dictionary: `~/Library/Application Support/LemonWhisper/Dictionary.json`
- History database: `~/Library/Application Support/LemonWhisper/Transcriptions.sqlite`

## Credits

LemonWhisper builds on open-source work from several projects and contributors:

- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) by Georgi Gerganov and contributors, which powers the local Whisper backend used by this app.
- [mlx-voxtral-swift](https://github.com/VincentGourbin/mlx-voxtral-swift) by Vincent Gourbin and contributors, which powers the local Voxtral backend integration.

- [MLX Audio Swift](https://github.com/Blaizzy/mlx-audio-swift) and [Qwen3-ASR](https://huggingface.co/Qwen/Qwen3-ASR-1.7B), which power the local Qwen backend.
