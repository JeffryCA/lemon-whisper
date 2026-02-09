import logging
import os
import sys
import tempfile

import sounddevice as sd
import soundfile as sf
from pynput import keyboard as pynput_keyboard
from pynput.keyboard import Key

from common import (
    SAMPLE_RATE,
    TEMP_DIR,
    paste_from_clipboard,
    run_transcription,
    safe_copy,
)
from logger_config import setup_logging

# === STATE ===
recording = False
audio_stream = None
audio_file = None
temp_filename = None
sample_count = 0


def audio_callback(indata, frames, time, status):
    global sample_count
    if recording and audio_file is not None:
        audio_file.write(indata)
        sample_count += len(indata)


def on_key_press(key):
    if key == Key.ctrl:
        global recording
        if recording:
            logging.info("Recording stopped.")
            recording = False


def main():
    global recording, audio_file, temp_filename, sample_count

    # Ensure the temp directory exists before we try to write files
    os.makedirs(TEMP_DIR, exist_ok=True)
    log_file = setup_logging("base.log", TEMP_DIR)

    # Parse command line arguments
    language = "auto"
    for arg in sys.argv[1:]:
        if arg.startswith("--lang="):
            language = arg.split("=", 1)[1]

    logging.info(f"Using language: {language}")

    logging.info("Recording started. Press Ctrl to stop and transcribe.")
    recording = True
    sample_count = 0

    # Create temporary file for streaming audio
    fd, temp_filename = tempfile.mkstemp(suffix=".wav", dir=TEMP_DIR)
    os.close(fd)
    audio_file = sf.SoundFile(
        temp_filename,
        mode="w",
        samplerate=SAMPLE_RATE,
        channels=1,
        subtype="PCM_16",
    )

    # Start exit-key listener (Ctrl by default) in a background thread
    exit_thread = pynput_keyboard.Listener(on_press=on_key_press)
    exit_thread.start()

    # Start audio stream in main thread
    global audio_stream
    audio_stream = sd.InputStream(
        samplerate=SAMPLE_RATE,
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
        logging.info("\nExiting...")
        sys.exit(0)

    # Stop audio stream
    if audio_stream:
        audio_stream.stop()
        audio_stream.close()
        audio_stream = None

    # Close audio file to flush data
    if audio_file:
        audio_file.close()

    # Process the recording
    if sample_count > 0:
        filename = temp_filename
        duration_sec = sample_count / SAMPLE_RATE
        logging.info(
            f"[DEBUG] stop_recording: recorded samples: {sample_count}, duration: {duration_sec:.2f}s"
        )
        if duration_sec < 0.5:
            logging.info("[INFO] Audio too short (<0.5s), skipping transcription.")
            os.remove(filename)
            sys.exit(0)

        # Transcribe
        logging.info("Transcribing...")
        text = run_transcription(filename, language)
        logging.info(f"Transcribed text: {text}")
        safe_copy(text)
        logging.info("Text copied to clipboard.")
        if text:
            paste_from_clipboard()

        os.remove(filename)
        logging.info("Done.")
        if os.path.exists(log_file):
            os.remove(log_file)
        sys.exit(0)
    else:
        logging.error("[ERROR] No audio was captured. Nothing to transcribe.")
        if temp_filename and os.path.exists(temp_filename):
            os.remove(temp_filename)
        if os.path.exists(log_file):
            os.remove(log_file)
        sys.exit(1)


if __name__ == "__main__":
    main()
