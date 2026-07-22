# Voxtral in-process memory reproduction

This isolated Swift command-line package reproduces repeated in-process Voxtral
load → transcribe → unload cycles with the versions used by LemonWhisper:

- `mlx-swift` **0.31.6**
- `mlx-voxtral-swift` **2.2.0**

It is diagnostic tooling, not the production fix. Keep the worker-process boundary
until that boundary and this reproduction both pass the 100-cycle memory test.

## Safety and prerequisites

- Use a short, representative WAV file with an absolute path.
- Download the selected Voxtral model in LemonWhisper first, then quit LemonWhisper.
- Do not run this tool and LemonWhisper concurrently. The tool refuses to begin if
  the model is absent, so it never becomes a second model-download/cache owner.
- Expect 100 cycles to take a long time and consume substantial energy.

## Run

From this directory:

```sh
swift run -c release voxtral-memory-repro \
  --audio /absolute/path/to/sample.wav \
  --cycles 100 \
  --model mini-3b-4bit \
  --language auto \
  --settle-ms 1000 \
  --deep-sample-every 1
```

Run `swift run -c release voxtral-memory-repro --help` for every option. By
default the tool calls `Memory.clearCache()` after `pipeline.unload()`, matching
the known-insufficient cleanup and making the residual growth visible. Pass
`--no-clear-cache` for a control run.

## Results

Every sample is flushed immediately to both:

- `metrics.csv`
- `metrics.jsonl`

The run also writes `configuration.json`, a final `summary.json`, and raw
`/usr/bin/heap` reports in `heap/`. Samples include:

- `Memory.activeMemory` and `Memory.cacheMemory`
- `TASK_VM_INFO.phys_footprint`
- default malloc-zone blocks and bytes in use
- `/usr/bin/heap` all-zone node count
- `AGX*FamilyBuffer` object counts parsed from the heap class table

Deep heap values are nullable: hardened runtime permissions or OS/tool changes
can make `heap` unavailable. The raw report and `deep_sample_status` preserve why.
The summary calculates a least-squares post-unload footprint slope in bytes per
cycle; inspect the raw time series as well because settling and memory pressure
can make a single endpoint delta misleading.

## Comparing the worker boundary

This executable deliberately performs every cycle in one process. For the
production acceptance check, run each transcription in the disposable worker,
record the main-app PID separately, verify that each worker PID exits, and compare
the main process's settled footprint against its initial baseline. The main
process should remain within roughly 20 MiB with no meaningful upward slope.
