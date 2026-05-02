# Intel Startup UX Plan

## Problem Summary

LemonWhisper currently behaves poorly on older Intel Macs:

- The app launches as a menu-bar-only app, so users may not see any visible UI.
- First run currently defaults into a Voxtral-first setup path.
- Voxtral is appropriate for Apple Silicon, but not for Intel Macs in practice.
- On Intel, this creates a confusing "nothing happens" experience even when the process is alive.

## Goals

- Make first launch visible and recoverable.
- Prevent Intel users from seeing or entering unsupported Voxtral flows.
- Remove surprise first-run auto-download behavior.
- Let users explicitly choose a model before any download starts.
- Keep Apple Silicon users on a strong local-first path without breaking Intel compatibility.

## Product Decisions

### 1. Platform-Specific Backend Availability

#### Apple Silicon

- Show both `Whisper` and `Voxtral`.
- Allow Voxtral to be selected, downloaded, and activated.
- Mark Voxtral as recommended if we want a preferred path, but do not force it.

#### Intel Macs

- Hide `Voxtral` entirely from the UI.
- Do not expose Voxtral models in menus, setup, or model management.
- Do not attempt Voxtral warmup, selection, or startup recovery.
- Ignore any previously stored Voxtral preference and fall back to Whisper behavior.

### 2. First-Run Setup

Current behavior:

- If no models are downloaded, the app auto-starts a default Voxtral download.

Proposed behavior:

- If no usable models are downloaded, always open a visible onboarding/setup window.
- Do not auto-download any model on first launch.
- Let the user explicitly choose which supported model to download.
- Preselect a sensible default choice in the UI, but require user confirmation before download.

### 3. Visible App Recovery

- First launch should never depend exclusively on the menu bar icon.
- If the app has no usable model, it should surface a normal window immediately.
- Setup and recovery should remain accessible even when the status item is hard to notice.
- If menu-bar-only presentation still proves unreliable during onboarding, add a stronger fallback such as temporary regular-app presentation during setup.

### 4. Stored Preference Fallback

- If `selectedBackend` is `Voxtral` on a machine that does not support it, the app must not block on that backend.
- The app should replace unsupported startup state with a valid Whisper-first setup state.

## UX Behavior Proposal

### Apple Silicon First Launch

- App starts.
- Visible setup window opens.
- User sees supported backend choices and available models.
- Voxtral can be shown as recommended, but nothing downloads automatically.
- Recording remains disabled until a supported model is downloaded and prepared.

### Intel First Launch

- App starts.
- Visible setup window opens.
- User sees Whisper-only setup.
- Voxtral is not mentioned as an actionable option.
- User chooses a Whisper model and starts download explicitly.
- Recording remains disabled until the selected Whisper model is ready.

### Existing Users With Models Downloaded

- If the stored backend is supported and the selected model is present, continue normal startup.
- If the stored backend is unsupported or missing, open the visible setup/recovery path instead of silently blocking.

## Implementation Outline

### Capability Detection

Add a platform capability layer that answers:

- whether the current Mac supports Voxtral
- whether the current architecture is Apple Silicon or Intel

Expected use:

- startup gating
- UI filtering
- stored preference fallback
- model management filtering

### Startup Flow Changes

Replace the current implicit "download default Voxtral model" behavior with:

- detect available supported backends
- detect already downloaded supported models
- if no usable model exists, show setup window
- wait for explicit user action

### UI Changes

Update the following areas:

- menu bar model menu
- main settings/home screen
- manage models screen
- setup status messaging

Desired result:

- Intel users never see unsupported Voxtral options
- Apple Silicon users see the full supported set
- first-run UI clearly explains why recording is disabled

### Messaging Changes

Current setup copy assumes Voxtral-first onboarding.

New setup copy should vary by platform:

- Apple Silicon: choose a model to get started
- Intel: Voxtral is unavailable on this Mac; choose a Whisper model

The copy should describe the blocked state without implying the app is broken.

## Files Likely To Change

- `LemonWhisper/LemonWhisper/LemonWhisperApp.swift`
- `LemonWhisper/LemonWhisper/Controllers/LemonWhisperController.swift`
- `LemonWhisper/LemonWhisper/Controllers/LemonWhisperController+ModelSetup.swift`
- `LemonWhisper/LemonWhisper/Views/ContentView.swift`
- `LemonWhisper/LemonWhisper/Views/ManageModelsView.swift`
- `LemonWhisper/LemonWhisper/Views/MenuBarContentView.swift`
- `LemonWhisper/LemonWhisper/Models/SetupState.swift`

Possible additional changes:

- a small platform capability helper
- onboarding-specific UI refinements

## Open Questions

- Should Apple Silicon also avoid all auto-download behavior? Current recommendation: yes.
- Should the app stay menu-bar-only after setup, or keep a stronger visible app presence on Intel?
- Should we add a dedicated onboarding screen instead of overloading the existing setup card?
- Should Intel default to a smaller recommended Whisper variant rather than `large-v3-turbo`?

## Recommended Next Step

Implement this in two passes:

1. Platform gating and visible first-run recovery.
2. UX polish for onboarding copy, supported-model presentation, and menu-bar discoverability.
