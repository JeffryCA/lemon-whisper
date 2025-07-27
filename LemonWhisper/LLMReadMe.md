# 🍋 LemonWhisper

## 🎯 Goal

Build a lightweight macOS app that offers simple local transcription functionality.

---

## User Engagement

User is a beginner swift programmer so explain the code and the concepts so that he learns as he goes along.
Always ask the user for context/access to other files if they are relevant to the task at hand.

---

## 🗺️ Feature Roadmap

Progressive implementation plan

- [x] Basic button to record and transcribe on testing-UI
- [x] Make sure the whisper setting match the ones in (pyLemonWhisper/common.py)
- [x] Remove the transcription button and now when we stop recording we transcribe the audio
- [x] when you stop recording, copy the transcription to the clipboard and also paste it into whatever text field is currently active (lets add a test text field to the testing-UI)
- [x] Add hotkey support for recording (control + Y to start and to stop) - hotkey should work even when the app is in the background!
- [ ] Move the functionality to a menu bar app - keep the testing-UI for debugging purposes
- [ ] Add language selection on the menu bar app
- [ ] Add an option to use live transcription (transcribe as you speak) using VAD see (pyLemonWhisper/live.py)
- [ ] Add toggle to enable/disable live transcription on the menu bar app
- [ ] Make sure the menu bar app stays active even when the main window is closed
- [ ] Add a quit option to the menu bar app
- [ ] Add a open window option to the menu bar app
- [ ] Fix the app icon and menu bar icon
- [ ] Make the UI of the app polished (onboarding to get permissions, settings page)
    - For the design lets try to use macOS new glass like effect
    - [ ] Let user define the hotkey for recording (start and stop in UI)
    - [ ] Language selection in settings
    - [ ] Download the models on first run IF they are not already downloaded


---

Possible future features:
- [ ] Offer online transcription for different providers
- [ ] "Hey Lemon" -> should automatically call a local LLM endpoint for assistant like features
- [ ] Instead of saving to clipboard and pasting offer optionalilty to save to a file
    - [ ] Save those transcriptions to a directory set by the user
    - [ ] Offer a way for the user to view, edit and delete those transcriptions
- [ ] Clean transcription using LLMs
- [ ] Reliably capture audio from the microphone AND the system audio for meetings
    - [ ] Create an index of peoples voices and when transcribing meetings, identify who is speaking.
- [ ] Obsidian integration
    - [ ] Long transcriptions get enriched with metadata (e.g. speakers, bulletpoints)