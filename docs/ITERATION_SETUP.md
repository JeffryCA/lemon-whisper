# LemonWhisper Autonomous Iteration Setup

This project now includes a local evaluation harness so we can iterate on:

- long-audio stability (loop/repetition failures)
- model/decoder setting comparisons

## 1) Bootstrap once

```bash
chmod +x tools/setup_iter_env.sh
./tools/setup_iter_env.sh
./tools/preflight_check.sh
```

## 2) Add local test audio corpus

Put files in:

```text
eval/audio_corpus/
```

Accepted formats: `wav`, `mp3`, `m4a`, `flac`, `ogg`, `mp4`, `aac`.

Suggested minimum set:

- 3 short clips (5-15s)
- 3 medium clips (30-60s)
- 3 long clips (2-5min, include pauses)

## 3) Run evaluation

```bash
.venv/bin/python tools/run_local_eval.py --run-name baseline
```

Common variants:

```bash
# No VAD
.venv/bin/python tools/run_local_eval.py --run-name no-vad --no-use-vad

# Force English + hotter decoding
.venv/bin/python tools/run_local_eval.py --run-name en-temp03 --language en --temperature 0.3
```

## 4) Read results

Artifacts:

- `eval/runs/<run-name>/results.json`
- `eval/runs/<run-name>/report.md`
- `eval/runs/<run-name>/transcripts/*.txt`

The report includes:

- loop-risk classification
- lexical diversity score
- repeated n-gram counts
- runtime and realtime factor

## What still requires manual action

Only macOS trust prompts and app permissions:

- Microphone
- Accessibility
- Input Monitoring
- Automation (System Events)

Everything else can now be iterated in code/scripts.
