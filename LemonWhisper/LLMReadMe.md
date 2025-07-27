# 🍋 LemonWhisper

## 🎯 Goal

Build a lightweight macOS app that offers simple local transcription functionality.

---

## User Engagement

User is a beginner swift programmer so explain the code and the concepts so that he learns as he goes along.

---

## 🗺️ Feature Roadmap

Progressive implementation plan

- [x] Basic button to record and transcribe on testing-UI
- [x] Make sure the whisper setting match the ones in (pyLemonWhisper/common.py)
- [x] Remove the transcription button and now when we stop recording we transcribe the audio
- [x] when you stop recording, copy the transcription to the clipboard and also paste it into whatever text field is currently active (lets add a test text field to the testing-UI)
- [ ] Add hotkey support for recording (control + Y to start and to stop) - hotkey should work even when the app is in the background!
- [ ] Move the functionality to a menu bar app - keep the testing-UI for debugging purposes
- [ ] Add language selection on the menu bar app
- [ ] Add an option to use live transcription (transcribe as you speak) using VAD see (pyLemonWhisper/live.py)
- [ ] Add toggle to enable/disable live transcription on the menu bar app
- [ ] Make sure the menu bar app stays active even when the main window is closed
- [ ] Add a quit option to the menu bar app
- [ ] Add a open window option to the menu bar app

