import logging
import os
import queue
import subprocess
import sys
import tempfile
import threading
import time
from collections import deque

import numpy as np
import pyperclip
import sounddevice as sd
import torch
from dotenv import load_dotenv
from pynput import keyboard as pynput_keyboard
from pynput.keyboard import Key

from logger_config import setup_logging

load_dotenv()

# === CONFIGURATION ===
BASE_DIR = os.path.dirname(os.path.realpath(__file__))
WHISPER_CPP_PATH = os.environ.get("WHISPER_CPP_PATH")
MODEL_PATH = os.path.join(WHISPER_CPP_PATH, "models", "ggml-large-v3-turbo.bin")
VAD_MODEL_PATH = os.path.join(WHISPER_CPP_PATH, "models", "ggml-silero-v5.1.2.bin")
WHISPER_CLI = os.path.join(WHISPER_CPP_PATH, "build", "bin", "whisper-cli")
TEMP_DIR = os.path.join(BASE_DIR, "temp")

# Audio configuration
SAMPLE_RATE = 16000
CHUNK_DURATION = 0.032  # 32ms chunks for VAD analysis (512 samples at 16kHz)
CHUNK_SIZE = 512  # Silero VAD requires exactly 512 samples for 16kHz
PAUSE_THRESHOLD = 0.600  # seconds
VAD_THRESHOLD = 0.6

# === STATE ===
recording = False
finalizing = False  # Flag to indicate we're in finalization phase
audio_stream = None
transcription_queue = queue.Queue()
current_chunk_buffer = deque()
speech_detected_in_session = False
speech_detected_in_chunk = False
last_speech_time = 0
transcription_thread = None
accumulated_text = ""  # Accumulate all transcribed text
detected_language = None  # Store detected language after first transcription
audio_processor = None  # Will be initialized in main if needed


class AudioProcessor:
    def __init__(self, load_vad: bool = True):
        """Initialize the audio processor.

        Parameters
        ----------
        load_vad : bool, optional
            Whether to load the Silero VAD model immediately. Set to ``False``
            to defer loading until later, allowing recording to start
            without delay.
        """
        self.vad_model = None
        self.vad_utils = None
        if load_vad:
            self._init_vad()
        self.reset()

    def load_vad_async(self):
        """Load the Silero VAD model in a background thread."""
        threading.Thread(target=self._init_vad, daemon=True).start()

    def _init_vad(self):
        """Initialize Silero VAD model"""
        try:
            torch.set_num_threads(1)  # Optimize for real-time processing

            # Load Silero VAD model
            self.vad_model, self.vad_utils = torch.hub.load(
                repo_or_dir="snakers4/silero-vad",
                model="silero_vad",
                force_reload=False,
                onnx=False,
            )

            # Get utility functions
            (
                get_speech_timestamps,
                save_audio,
                read_audio,
                VADIterator,
                collect_chunks,
            ) = self.vad_utils
            self.get_speech_timestamps = get_speech_timestamps

            logging.info("✅ Silero VAD model loaded successfully")

        except Exception as e:
            logging.warning(f"⚠️  Failed to load Silero VAD: {e}")
            logging.info("📦 Install with: pip install torch torchaudio")
            self.vad_model = None

    def reset(self):
        self.audio_buffer = []
        self.chunk_buffer = []
        self.last_vad_check = 0
        self.speech_detected = False
        self.silence_start = None

    def add_audio(self, audio_data):
        """Add audio data and manage chunk processing"""
        self.audio_buffer.extend(audio_data.flatten())
        self.chunk_buffer.extend(audio_data.flatten())

        # Process in chunks for VAD
        while len(self.chunk_buffer) >= CHUNK_SIZE:
            chunk = np.array(self.chunk_buffer[:CHUNK_SIZE])
            self.chunk_buffer = self.chunk_buffer[CHUNK_SIZE:]
            self._process_chunk(chunk)

    def _process_chunk(self, chunk):
        """Process individual chunk for VAD and pause detection"""
        global speech_detected_in_chunk, speech_detected_in_session, last_speech_time

        # Apply VAD to chunk
        has_speech = self._apply_vad(chunk)

        current_time = time.time()

        if has_speech:
            speech_detected_in_chunk = True
            speech_detected_in_session = True
            last_speech_time = current_time
            self.speech_detected = True
            self.silence_start = None
            # logging.info("🎤 Speech detected")
        else:
            if self.speech_detected and self.silence_start is None:
                self.silence_start = current_time
                # logging.info("🔇 Silence started")

        # Check for pause (silence after speech)
        if (
            self.silence_start
            and current_time - self.silence_start >= PAUSE_THRESHOLD
            and self.speech_detected
            and len(self.audio_buffer) > 0
        ):

            logging.info(
                f"⏸️  Pause detected ({PAUSE_THRESHOLD}s), triggering transcription"
            )
            self._trigger_transcription()

    def _apply_vad(self, chunk):
        """Apply VAD to audio chunk using Silero VAD"""
        try:
            if self.vad_model is None:
                # Fallback to energy-based VAD if model not loaded
                energy = np.sqrt(np.mean(chunk.astype(np.float32) ** 2))
                return energy > 0.01

            # Ensure chunk is exactly 512 samples for Silero VAD
            if len(chunk) != 512:
                # Pad or truncate to exactly 512 samples
                if len(chunk) < 512:
                    # Pad with zeros
                    chunk = np.pad(chunk, (0, 512 - len(chunk)), mode="constant")
                else:
                    # Truncate to 512 samples
                    chunk = chunk[:512]

            # Convert chunk to the format expected by Silero VAD
            # Silero VAD expects float32 audio normalized to [-1, 1]
            audio_float = chunk.astype(np.float32) / 32768.0

            # Convert to torch tensor
            import torch

            audio_tensor = torch.from_numpy(audio_float)

            # Ensure tensor is 1D and add batch dimension
            if len(audio_tensor.shape) > 1:
                audio_tensor = audio_tensor.squeeze()
            audio_tensor = audio_tensor.unsqueeze(0)  # Add batch dimension

            # Get speech probability from VAD model
            speech_prob = self.vad_model(audio_tensor, SAMPLE_RATE).item()

            # Return True if speech probability exceeds threshold
            has_speech = speech_prob > VAD_THRESHOLD

            return has_speech

        except Exception as e:
            logging.warning(f"⚠️  VAD error, falling back to energy detection: {e}")
            # Fallback to energy-based VAD
            energy = np.sqrt(np.mean(chunk.astype(np.float32) ** 2))
            return energy > 0.01

    def _trigger_transcription(self):
        """Trigger transcription for current buffer"""
        if not speech_detected_in_session:
            logging.info("🚫 No speech detected in session, discarding audio")
            self.reset()
            return

        if len(self.audio_buffer) == 0:
            logging.info("🚫 No audio to transcribe")
            return

        # Prepare audio for transcription
        audio_array = np.array(self.audio_buffer, dtype=np.int16)
        duration = len(audio_array) / SAMPLE_RATE

        if duration < 0.5:
            logging.info(f"🚫 Audio too short ({duration:.2f}s), discarding")
            self.reset()
            return

        logging.info(f"📝 Queuing audio for transcription ({duration:.2f}s)")
        transcription_queue.put(audio_array.copy())

        # Reset for next chunk
        self.reset()

    def finalize(self):
        """Process any remaining audio when recording stops"""
        if len(self.audio_buffer) > 0 and speech_detected_in_session:
            logging.info("📝 Processing final audio chunk")

            # Prepare audio for transcription
            audio_array = np.array(self.audio_buffer, dtype=np.int16)
            duration = len(audio_array) / SAMPLE_RATE

            if duration >= 0.5:
                logging.info(
                    f"📝 Queuing final audio for transcription ({duration:.2f}s)"
                )
                transcription_queue.put(audio_array.copy())
            else:
                logging.info(f"🚫 Final audio too short ({duration:.2f}s), discarding")
        else:
            if len(self.audio_buffer) == 0:
                logging.info("🚫 No audio recorded")
            elif not speech_detected_in_session:
                logging.info("🚫 No speech detected in session")


def audio_callback(indata, frames, time, status):
    """Audio callback for sounddevice"""
    if recording:
        audio_processor.add_audio(indata.copy())


def transcription_worker():
    """Background thread for handling transcription"""
    logging.info("🔧 Transcription worker started")
    while True:
        try:
            audio_data = transcription_queue.get(timeout=1.0)
            if audio_data is not None:
                # logging.info("🎯 Transcription worker processing audio data")
                _transcribe_audio(audio_data)
            transcription_queue.task_done()
        except queue.Empty:
            # Only exit if recording is stopped AND finalization is done AND queue is empty
            if not recording and finalizing and transcription_queue.empty():
                logging.info(
                    "⏰ Transcription worker timeout - recording stopped and queue empty"
                )
                break
            else:
                # logging.info("⏰ Transcription worker timeout - checking if recording stopped")
                continue
        except Exception as e:
            logging.error(f"❌ Transcription error: {e}")
            transcription_queue.task_done()  # Mark task as done even on error
    logging.info("🏁 Transcription worker finished")


def _transcribe_audio(audio_data):
    """Transcribe audio data"""
    global accumulated_text, detected_language

    try:
        # Save to temporary WAV file
        with tempfile.NamedTemporaryFile(
            delete=False, suffix=".wav", dir=TEMP_DIR
        ) as tmpfile:
            filename = tmpfile.name

        import soundfile as sf

        sf.write(filename, audio_data, SAMPLE_RATE)

        logging.info("🔄 Transcribing...")

        # Get language from command line args or use detected language
        if detected_language:
            language = detected_language
            logging.info(f"🔄 Using previously detected language: {language}")
        else:
            language = "auto"
            for arg in sys.argv[1:]:
                if arg.startswith("--lang="):
                    language = arg.split("=", 1)[1]
                    detected_language = language  # Store manually specified language
                    break
            if language != "auto":
                detected_language = language

        # Prepare whisper command with context if available
        whisper_cmd = [
            WHISPER_CLI,
            "--model",
            MODEL_PATH,
            "--file",
            filename,
            "--language",
            language,
            "--beam-size",
            "1",
            "--no-timestamps",
            "--vad",
            "--vad-model",
            VAD_MODEL_PATH,
            "--vad-threshold",
            str(VAD_THRESHOLD),
            "--max-context",
            "1024",
            "--max-len",
            "500",
            "--audio-ctx",
            "1000",
            "--split-on-word",
            "--threads",
            "2",
            "--no-fallback",
            "--temperature",
            "0.0",
        ]

        # Add context from previously transcribed text if available
        if accumulated_text and accumulated_text.strip():
            # Use the last 100 words as context to avoid making the prompt too long
            context_words = accumulated_text.split()
            if len(context_words) > 100:
                context = " ".join(context_words[-100:])
            else:
                context = accumulated_text
            whisper_cmd.extend(["--prompt", context])
            logging.info(f"🔍 Using context: {context}")

        # Run transcription
        result = subprocess.run(
            whisper_cmd,
            capture_output=True,
            text=True,
        )

        text = result.stdout.strip()

        if text:
            logging.info(f"✅ Transcribed: {text}")

            # If this was auto-detection, extract and store the detected language
            # if language == "auto" and not detected_language:
            #     stderr_output = result.stderr
            #     if "detected language:" in stderr_output.lower():
            #         # Parse detected language from whisper output
            #         import re

            #         match = re.search(
            #             r"detected language:\s*(\w+)", stderr_output, re.IGNORECASE
            #         )
            #         if match:
            #             detected_language = match.group(1)
            #             logging.info(f"🌍 Language detected and stored: {detected_language}")

            # Always accumulate text
            if accumulated_text:
                accumulated_text += " " + text
            else:
                accumulated_text = text

            # Paste immediately for live transcription
            # Add space if we already have text and this isn't the first chunk
            if len(accumulated_text.split()) > len(text.split()):
                text_to_paste = " " + text
            else:
                text_to_paste = text
            pyperclip.copy(text_to_paste)
            subprocess.run(
                [
                    "osascript",
                    "-e",
                    'tell application "System Events" to keystroke "v" using {command down}',
                ]
            )
            logging.info("📋 Text pasted to cursor position")
        else:
            logging.info("🔇 No text transcribed")

        # Clean up temp file
        os.remove(filename)

    except Exception as e:
        logging.error(f"❌ Transcription failed: {e}")


def on_key_press(key):
    """Handle key presses"""
    global recording

    if key == Key.ctrl:
        if recording:
            logging.info("🛑 Recording stopped.")
            recording = False


def main():
    global recording, audio_stream, transcription_thread, speech_detected_in_session, finalizing, accumulated_text, detected_language, audio_processor

    # Create temp directory if it doesn't exist
    os.makedirs(TEMP_DIR, exist_ok=True)
    log_file = setup_logging("live.log", TEMP_DIR)

    # Parse command line arguments
    language = "auto"

    for arg in sys.argv[1:]:
        if arg.startswith("--lang="):
            language = arg.split("=", 1)[1]
        elif arg == "--help" or arg == "-h":
            logging.info("Usage: python live.py [OPTIONS]")
            logging.info("Options:")
            logging.info(
                "  --lang=LANGUAGE       Set transcription language (default: auto)"
            )
            logging.info("  --help, -h           Show this help message")
            return

    # Initialize audio processor without loading VAD to avoid startup delay
    audio_processor = AudioProcessor(load_vad=False)
    logging.info(f"🌍 Using language: {language}")

    # Reset state
    recording = True
    speech_detected_in_session = False
    accumulated_text = ""  # Reset accumulated text
    detected_language = None  # Reset detected language for new session
    audio_processor.reset()

    # Prepare background helpers
    key_listener = pynput_keyboard.Listener(on_press=on_key_press)
    transcription_thread = threading.Thread(target=transcription_worker, daemon=True)

    # Start audio stream as early as possible
    try:
        audio_stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            channels=1,
            callback=audio_callback,
            dtype="int16",
            blocksize=CHUNK_SIZE,
        )
        audio_stream.start()

        logging.info("🔴 Recording started...")

        # Start key listener and transcription worker
        key_listener.start()
        transcription_thread.start()

        # Load VAD model asynchronously so we don't miss early audio
        audio_processor.load_vad_async()

        # Keep main thread alive
        while recording:
            time.sleep(0.1)

    except KeyboardInterrupt:
        logging.info("\n🛑 Interrupted by user")
    except Exception as e:
        logging.error(f"❌ Audio stream error: {e}")
    finally:
        # Stop recording flag first
        recording = False

        # Now signal finalization phase
        finalizing = True

        # Process any remaining audio
        audio_processor.finalize()

        # Always wait for the queue to be fully processed to avoid race conditions.
        # .join() will block until all items that have been put() are task_done().
        logging.info("⏳ Finishing all remaining transcriptions...")
        transcription_queue.join()
        logging.info("✅ All transcriptions finished.")

        # Finalization complete
        finalizing = False

        # Stop key listener after finalization
        key_listener.stop()

        # At the end, show all accumulated text
        if accumulated_text and accumulated_text.strip():
            logging.info(f"💬 Full text: {accumulated_text}")
            pyperclip.copy(accumulated_text)
        else:
            logging.info("📋 No text was transcribed")
        logging.info("✅ Done.")
        if os.path.exists(log_file):
            os.remove(log_file)


if __name__ == "__main__":
    main()
