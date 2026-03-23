# LemonWhisper

## Goal

Ship a local macOS dictation app with reliable hotkey capture, local model switching, and low-friction UX.

## Current State

- Menu bar app is implemented and installable.
- Recording is toggled by hotkey (`Ctrl+Y`) and works in background apps.
- Start/stop indicators and transcription loading indicator are shown near the cursor.
- Clipboard + paste flow is implemented.
- Local model management exists for Whisper and Voxtral.
- Runtime model download/reuse is in place (models are not bundled in app resources).
- Basic settings window exists (`Open Lemon`) with language/model selection and local model management.

## Done

- Record -> transcribe -> copy/paste flow.
- Global hotkey support.
- Menu bar mode with open/quit actions.
- Language selection.
- Model selection and model download/remove UI.
- Process memory indicator in UI/menu.

## Next Priorities

- Polish settings UX and onboarding for permissions.
- Finalize distribution pipeline (`.dmg`, signing, notarization).
- Add update mechanism (Sparkle) after release packaging is stable.
- Figure out a local agent iteration workflow so Codex can run and test the app directly.
- Support long audio transcription without blowing up memory.
- Add a settings option to keep models loaded in memory or unload when idle (fast vs low-memory mode).
- Persist user-selected default model and always restore it on app launch.
- Add optional trailing Enter behavior: if transcription ends with the spoken word "enter", send Return after paste.
- Add a "locked target field" mode: capture focused text field when recording starts and paste back into that same field even if focus/cursor changes before transcription ends.
- Suport live transcription with VAD.
- Explore a lightweight local GRU-based post-processor for text formatting.
- Design efficient local streaming for transcription + formatting pipeline.
- Improve silence handling (better VAD thresholds/segmentation) to avoid awkward cuts and loops.

## Current Bugs

- WhatsApp paste behavior can overwrite previous text on consecutive transcriptions instead of appending.
- Auto-paste does not work in some native macOS apps, including Anthropic's Claude app.
- Whisper can loop/repeat and degrade output quality on long audio.
- Whisper long-audio handling is still unstable and needs hardening.

## Later Ideas

- Offer online transcription providers.
- "Hey Lemon" mode that can call a local LLM endpoint for assistant-like actions.
- Save-to-file mode in addition to clipboard/paste:
  - Save transcriptions to a user-defined directory.
  - Provide a simple way to view, edit, and delete saved transcriptions.
- Clean/refine transcriptions with LLMs.
- Reliable meeting capture workflow:
  - Capture microphone + system audio.
  - Add speaker identification support.
- Obsidian integration:
  - Enrich long transcriptions with metadata (speakers, bullet points, summaries).
