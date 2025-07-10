import json
import os
import subprocess
import sys
import tempfile

import numpy as np
import pyperclip
import sounddevice as sd
from dotenv import load_dotenv
from pynput import keyboard as pynput_keyboard
from pynput.keyboard import Key

load_dotenv()


# === CONFIGURATION ===
BASE_DIR = os.path.dirname(os.path.realpath(__file__))
WHISPER_CPP_PATH = os.environ.get("WHISPER_CPP_PATH")
MODEL_PATH = os.path.join(WHISPER_CPP_PATH, "models", "ggml-large-v3-q5_0.bin")
VAD_MODEL_PATH = os.path.join(WHISPER_CPP_PATH, "models", "ggml-silero-v5.1.2.bin")
WHISPER_CLI = os.path.join(WHISPER_CPP_PATH, "build", "bin", "whisper-cli")
TEMP_DIR = os.path.join(BASE_DIR, "temp")

# === STATE ===
recording = False
recording_data = []
audio_stream = None


def audio_callback(indata, frames, time, status):
    if recording:
        recording_data.append(indata.copy())


def on_key_press(key):
    if key == Key.ctrl:
        global recording
        if recording:
            print("Recording stopped.")
            recording = False


def main():
    global recording, recording_data

    print("Recording started. Press Ctrl to stop and transcribe.")
    recording = True
    recording_data = []
    sample_rate = 16000

    # Start Escape key listener in a background thread
    esc_thread = pynput_keyboard.Listener(on_press=on_key_press)
    esc_thread.start()

    # Start audio stream in main thread
    global audio_stream
    audio_stream = sd.InputStream(
        samplerate=sample_rate,
        channels=1,
        callback=audio_callback,
        dtype="int16",
    )
    audio_stream.start()

    # Keep main thread alive until recording is stopped
    try:
        while recording:
            sd.sleep(100)
    except KeyboardInterrupt:
        print("\nExiting...")
        sys.exit(0)

    # Stop audio stream
    if audio_stream:
        audio_stream.stop()
        audio_stream.close()
        audio_stream = None

    # Process the recording
    if recording_data:
        # Save to temp WAV
        audio = np.concatenate(recording_data, axis=0)
        duration_sec = audio.shape[0] / sample_rate
        print(
            f"[DEBUG] stop_recording: concatenated audio shape: {audio.shape}, duration: {duration_sec:.2f}s"
        )
        if duration_sec < 0.5:
            print("[INFO] Audio too short (<0.5s), skipping transcription.")
            sys.exit(0)
        with tempfile.NamedTemporaryFile(
            delete=False, suffix=".wav", dir=TEMP_DIR
        ) as tmpfile:
            filename = tmpfile.name
            import soundfile as sf

            sf.write(filename, audio, sample_rate)

        # Transcribe
        print("Transcribing...")
        result = subprocess.run(
            [
                WHISPER_CLI,
                "--model",
                MODEL_PATH,
                "--file",
                filename,
                "--language",
                "en",
                "--beam-size",
                "5",
                "--no-timestamps",
                "--output-json-full",
                "--vad",
                "--vad-model",
                VAD_MODEL_PATH,
                "--vad-threshold",
                "0.6",
            ],
            capture_output=True,
            text=True,
        )
        text = result.stdout.strip()
        print(f"Transcribed text: {text}")
        # Debugging
        # Read the generated .json file
        json_file = filename + ".json"
        if os.path.exists(json_file):
            with open(json_file, "r") as f:
                data = json.load(f)
            os.remove(json_file)
            scores = []
            for transcription in data.get("transcription", []):
                scores += [t["p"] for t in transcription.get("tokens", []) if "p" in t]
            if scores:
                mean_conf = sum(scores) / len(scores)
                print(f"Mean confidence: {mean_conf:.2f}")
                # text += f" {mean_conf:.2f}"
        # Debugging finished

        pyperclip.copy(text)
        print("Text copied to clipboard.")
        if text:
            subprocess.run(
                [
                    "osascript",
                    "-e",
                    'tell application "System Events" to keystroke "v" using {command down}',
                ]
            )
            print("Text pasted from clipboard.")

        os.remove(filename)
        print("Done.")
        sys.exit(0)
    else:
        print("[ERROR] No audio was captured. Nothing to transcribe.")
        sys.exit(1)


if __name__ == "__main__":
    main()
