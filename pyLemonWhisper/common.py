import logging
import os
import subprocess
import sys

from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()


# === CONFIGURATION ===
BASE_DIR = os.path.dirname(os.path.realpath(__file__))
WHISPER_CPP_PATH = os.environ.get("WHISPER_CPP_PATH")

if not WHISPER_CPP_PATH or not os.path.isdir(WHISPER_CPP_PATH):
    logging.error(
        "WHISPER_CPP_PATH environment variable is not set or is not a valid directory."
    )
    sys.exit(1)

MODEL_PATH = os.path.join(WHISPER_CPP_PATH, "models", "ggml-large-v3-turbo.bin")
VAD_MODEL_PATH = os.path.join(WHISPER_CPP_PATH, "models", "ggml-silero-v5.1.2.bin")
WHISPER_CLI = os.path.join(WHISPER_CPP_PATH, "build", "bin", "whisper-cli")
TEMP_DIR = os.path.join(BASE_DIR, "temp")

# Audio configuration
SAMPLE_RATE = 16000


# === UTILITY FUNCTIONS ===
def safe_copy(text):
    """Safely copy text to the clipboard using pbcopy."""
    try:
        subprocess.run("pbcopy", text=True, input=text, check=True)
    except Exception as e:
        logging.warning(f"⚠️  Clipboard copy failed: {e}")


def paste_from_clipboard():
    """Simulates pasting from the clipboard using AppleScript."""
    try:
        subprocess.run(
            [
                "osascript",
                "-e",
                'tell application "System Events" to keystroke "v" using {command down}',
            ]
        )
        logging.info("📋 Text pasted from clipboard.")
    except Exception as e:
        logging.warning(f"⚠️  Paste failed: {e}")


def run_transcription(filename: str, language: str, prompt: str = "") -> str:
    """
    Runs the whisper-cli transcription process and returns the transcribed text.
    """
    command = [
        WHISPER_CLI,
        "--model",
        MODEL_PATH,
        "--file",
        filename,
        "--language",
        language,
        "--no-timestamps",
        "--max-context",
        "0",
        "--max-len",
        "500",
        "--audio-ctx",
        "1000",
        "--split-on-word",
        "--threads",
        "2",
        "--temperature",
        "0.2",
        "--vad",
        "--vad-model",
        VAD_MODEL_PATH,
        "--vad-threshold",
        "0.6",
    ]
    if prompt:
        command.extend(["--prompt", prompt])
        logging.info(f"🔍 Using context: {prompt}")

    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            check=True,
        )
        return result.stdout.strip()
    except subprocess.CalledProcessError as e:
        logging.error(f"❌ Transcription failed: {e.stderr}")
        return ""
    except Exception as e:
        logging.error(f"❌ An unexpected error occurred during transcription: {e}")
        return ""
