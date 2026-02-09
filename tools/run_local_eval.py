#!/usr/bin/env python3
"""Local Whisper evaluation harness for loop/repetition detection.

Runs whisper.cpp over a local audio corpus and writes JSON + Markdown reports.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shlex
import statistics
import subprocess
import sys
import tempfile
import time
from collections import Counter
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Iterable


AUDIO_EXTENSIONS = {".wav", ".mp3", ".m4a", ".flac", ".ogg", ".mp4", ".aac"}
WHISPER_NATIVE_EXTENSIONS = {".wav", ".mp3", ".flac", ".ogg"}
DEFAULT_MODEL = "ggml-large-v3-turbo.bin"
DEFAULT_VAD_MODEL = "ggml-silero-v5.1.2.bin"


def load_env_file(path: Path) -> dict[str, str]:
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for raw_line in path.read_text().splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip()
    return env


def shell_stdout(command: list[str]) -> str:
    return subprocess.check_output(command, text=True).strip()


def media_duration_seconds(path: Path) -> float | None:
    ffprobe = shutil_which("ffprobe")
    if ffprobe:
        try:
            out = shell_stdout(
                [
                    ffprobe,
                    "-v",
                    "error",
                    "-show_entries",
                    "format=duration",
                    "-of",
                    "default=nokey=1:noprint_wrappers=1",
                    str(path),
                ]
            )
            return float(out)
        except Exception:
            return None
    return None


def maybe_convert_for_whisper(input_path: Path) -> tuple[Path, tempfile.TemporaryDirectory[str] | None]:
    """Return an audio path guaranteed to work with installed whisper-cli.

    For non-native formats (e.g., m4a/mp4/aac), converts to mono 16k WAV via ffmpeg.
    """
    if input_path.suffix.lower() in WHISPER_NATIVE_EXTENSIONS:
        return input_path, None

    ffmpeg = shutil_which("ffmpeg")
    if not ffmpeg:
        raise RuntimeError(
            f"Audio format {input_path.suffix} requires ffmpeg conversion, but ffmpeg is not installed."
        )

    tmp_dir = tempfile.TemporaryDirectory(prefix="lw_eval_audio_")
    out_wav = Path(tmp_dir.name) / f"{input_path.stem}.wav"
    cmd = [
        ffmpeg,
        "-y",
        "-i",
        str(input_path),
        "-ac",
        "1",
        "-ar",
        "16000",
        str(out_wav),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if result.returncode != 0 or not out_wav.exists():
        tmp_dir.cleanup()
        raise RuntimeError(
            f"ffmpeg conversion failed for {input_path.name}: {result.stderr.strip()}"
        )
    return out_wav, tmp_dir


def tokenize(text: str) -> list[str]:
    return re.findall(r"[a-zA-Z0-9']+", text.lower())


def max_ngram_repeat(tokens: list[str], n: int) -> int:
    if len(tokens) < n:
        return 0
    counts: Counter[tuple[str, ...]] = Counter(
        tuple(tokens[i : i + n]) for i in range(len(tokens) - n + 1)
    )
    return max(counts.values(), default=0)


def repetition_metrics(text: str) -> dict[str, float]:
    tokens = tokenize(text)
    total_words = len(tokens)
    unique_words = len(set(tokens))
    unique_ratio = (unique_words / total_words) if total_words else 1.0
    max_repeat_2 = max_ngram_repeat(tokens, 2)
    max_repeat_3 = max_ngram_repeat(tokens, 3)
    max_repeat_4 = max_ngram_repeat(tokens, 4)
    return {
        "total_words": float(total_words),
        "unique_words": float(unique_words),
        "unique_ratio": unique_ratio,
        "max_repeat_2gram": float(max_repeat_2),
        "max_repeat_3gram": float(max_repeat_3),
        "max_repeat_4gram": float(max_repeat_4),
    }


def infer_loop_risk(metrics: dict[str, float]) -> tuple[bool, str]:
    words = metrics["total_words"]
    unique_ratio = metrics["unique_ratio"]
    rep3 = metrics["max_repeat_3gram"]
    rep4 = metrics["max_repeat_4gram"]

    if words >= 50 and (rep4 >= 4 or rep3 >= 6):
        return True, "high repeated n-grams"
    if words >= 50 and unique_ratio < 0.20:
        return True, "very low lexical diversity"
    if words >= 150 and unique_ratio < 0.28:
        return True, "low lexical diversity on long transcript"
    return False, ""


def shutil_which(binary: str) -> str | None:
    return subprocess.run(
        ["which", binary], capture_output=True, text=True, check=False
    ).stdout.strip() or None


@dataclass
class FileResult:
    file: str
    duration_seconds: float | None
    run_seconds: float
    realtime_factor: float | None
    transcript_chars: int
    transcript_preview: str
    loop_risk: bool
    loop_reason: str
    total_words: int
    unique_words: int
    unique_ratio: float
    max_repeat_2gram: int
    max_repeat_3gram: int
    max_repeat_4gram: int


def discover_audio_files(directory: Path) -> list[Path]:
    files: list[Path] = []
    for p in sorted(directory.rglob("*")):
        if p.is_file() and p.suffix.lower() in AUDIO_EXTENSIONS:
            files.append(p)
    return files


def run_whisper(
    whisper_cli: Path,
    model_path: Path,
    vad_model_path: Path | None,
    audio_file: Path,
    language: str,
    threads: int,
    temperature: float,
    use_vad: bool,
) -> str:
    with tempfile.TemporaryDirectory(prefix="lw_eval_") as tmp_dir:
        out_prefix = Path(tmp_dir) / "transcript"
        cmd = [
            str(whisper_cli),
            "--model",
            str(model_path),
            "--file",
            str(audio_file),
            "--language",
            language,
            "--threads",
            str(threads),
            "--temperature",
            str(temperature),
            "--no-timestamps",
            "--max-context",
            "0",
            "--max-len",
            "500",
            "--audio-ctx",
            "1000",
            "--split-on-word",
            "--output-txt",
            "--output-file",
            str(out_prefix),
            "--no-prints",
        ]
        if use_vad:
            cmd.extend(["--vad"])
            if vad_model_path is not None:
                cmd.extend(["--vad-model", str(vad_model_path)])
                cmd.extend(["--vad-threshold", "0.6"])

        result = subprocess.run(cmd, capture_output=True, text=True, check=False)
        if result.returncode != 0:
            raise RuntimeError(
                f"whisper-cli failed for {audio_file.name}\n"
                f"command: {shlex.join(cmd)}\n"
                f"stderr: {result.stderr.strip()}"
            )

        txt_path = Path(f"{out_prefix}.txt")
        if not txt_path.exists():
            raise RuntimeError(f"Expected output file not found: {txt_path}")
        return txt_path.read_text(encoding="utf-8", errors="ignore").strip()


def markdown_report(
    results: list[FileResult],
    run_name: str,
    whisper_cli: Path,
    model_path: Path,
    language: str,
    threads: int,
    temperature: float,
    use_vad: bool,
) -> str:
    loop_count = sum(1 for r in results if r.loop_risk)
    rtf_values = [r.realtime_factor for r in results if r.realtime_factor is not None]
    avg_rtf = statistics.mean(rtf_values) if rtf_values else None
    avg_unique = statistics.mean(r.unique_ratio for r in results) if results else 0.0

    lines = [
        f"# LemonWhisper Local Eval: {run_name}",
        "",
        "## Configuration",
        f"- whisper-cli: `{whisper_cli}`",
        f"- model: `{model_path}`",
        f"- language: `{language}`",
        f"- threads: `{threads}`",
        f"- temperature: `{temperature}`",
        f"- vad: `{use_vad}`",
        "",
        "## Summary",
        f"- files: `{len(results)}`",
        f"- loop-risk files: `{loop_count}`",
        f"- avg unique ratio: `{avg_unique:.3f}`",
        f"- avg realtime factor (run/audio): `{avg_rtf:.3f}`" if avg_rtf is not None else "- avg realtime factor: `n/a`",
        "",
        "## Per File",
        "| File | Dur(s) | Run(s) | RTF | Loop Risk | Unique Ratio | Max 3-gram | Max 4-gram |",
        "|---|---:|---:|---:|---|---:|---:|---:|",
    ]
    for r in results:
        dur = f"{r.duration_seconds:.1f}" if r.duration_seconds is not None else "n/a"
        rtf = f"{r.realtime_factor:.2f}" if r.realtime_factor is not None else "n/a"
        risk = f"YES ({r.loop_reason})" if r.loop_risk else "no"
        lines.append(
            f"| `{r.file}` | {dur} | {r.run_seconds:.2f} | {rtf} | {risk} | {r.unique_ratio:.3f} | {r.max_repeat_3gram} | {r.max_repeat_4gram} |"
        )

    lines.append("")
    lines.append("## Risky Transcript Previews")
    risky = [r for r in results if r.loop_risk]
    if not risky:
        lines.append("- none")
    else:
        for r in risky:
            lines.append(f"- `{r.file}`: {r.transcript_preview}")

    return "\n".join(lines) + "\n"


def validate_paths(*paths: Iterable[Path]) -> None:
    for seq in paths:
        for p in seq:
            if not p.exists():
                raise FileNotFoundError(f"Missing path: {p}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Run local whisper.cpp eval harness.")
    parser.add_argument(
        "--audio-dir",
        default="eval/audio_corpus",
        help="Audio corpus directory.",
    )
    parser.add_argument(
        "--out-dir",
        default="eval/runs",
        help="Output directory for run artifacts.",
    )
    parser.add_argument(
        "--env-file",
        default="pyLemonWhisper/.env",
        help="Env file that contains WHISPER_CPP_PATH.",
    )
    parser.add_argument("--model", default=DEFAULT_MODEL, help="Model file name.")
    parser.add_argument(
        "--vad-model",
        default=DEFAULT_VAD_MODEL,
        help="VAD model file name.",
    )
    parser.add_argument(
        "--language",
        default="auto",
        help="Whisper language value (auto, en, es, ...).",
    )
    parser.add_argument("--threads", type=int, default=2)
    parser.add_argument("--temperature", type=float, default=0.2)
    parser.add_argument(
        "--use-vad",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Enable whisper.cpp VAD flags.",
    )
    parser.add_argument(
        "--run-name",
        default=time.strftime("%Y%m%d-%H%M%S"),
        help="Run id used for output folder name.",
    )
    args = parser.parse_args()

    root = Path.cwd()
    audio_dir = (root / args.audio_dir).resolve()
    out_dir = (root / args.out_dir).resolve()
    env_file = (root / args.env_file).resolve()

    if not audio_dir.exists():
        raise FileNotFoundError(
            f"Audio corpus directory not found: {audio_dir}. Add samples first."
        )

    env = load_env_file(env_file)
    whisper_cpp_path = env.get("WHISPER_CPP_PATH") or os.environ.get("WHISPER_CPP_PATH")
    if not whisper_cpp_path:
        raise RuntimeError(
            "WHISPER_CPP_PATH missing. Set it in pyLemonWhisper/.env or shell env."
        )

    whisper_cpp = Path(whisper_cpp_path).resolve()
    whisper_cli = whisper_cpp / "build/bin/whisper-cli"
    model_path = whisper_cpp / "models" / args.model
    vad_model_path = whisper_cpp / "models" / args.vad_model if args.use_vad else None

    must_exist = [whisper_cli, model_path]
    if args.use_vad and vad_model_path is not None:
        must_exist.append(vad_model_path)
    validate_paths(must_exist)

    audio_files = discover_audio_files(audio_dir)
    if not audio_files:
        raise RuntimeError(f"No audio files found under {audio_dir}")

    run_dir = out_dir / args.run_name
    run_dir.mkdir(parents=True, exist_ok=True)
    transcripts_dir = run_dir / "transcripts"
    transcripts_dir.mkdir(parents=True, exist_ok=True)

    results: list[FileResult] = []
    print(f"Running eval on {len(audio_files)} files...")
    for audio_file in audio_files:
        converted_tmp: tempfile.TemporaryDirectory[str] | None = None
        whisper_input = audio_file
        whisper_input, converted_tmp = maybe_convert_for_whisper(audio_file)

        start = time.perf_counter()
        transcript = run_whisper(
            whisper_cli=whisper_cli,
            model_path=model_path,
            vad_model_path=vad_model_path,
            audio_file=whisper_input,
            language=args.language,
            threads=args.threads,
            temperature=args.temperature,
            use_vad=args.use_vad,
        )
        elapsed = time.perf_counter() - start

        if converted_tmp is not None:
            converted_tmp.cleanup()

        duration = media_duration_seconds(audio_file)
        rtf = (elapsed / duration) if duration and duration > 0 else None
        metrics = repetition_metrics(transcript)
        loop_risk, loop_reason = infer_loop_risk(metrics)

        relative_file = str(audio_file.relative_to(audio_dir))
        safe_name = re.sub(r"[^a-zA-Z0-9._-]+", "_", relative_file)
        (transcripts_dir / f"{safe_name}.txt").write_text(transcript, encoding="utf-8")

        results.append(
            FileResult(
                file=relative_file,
                duration_seconds=duration,
                run_seconds=elapsed,
                realtime_factor=rtf,
                transcript_chars=len(transcript),
                transcript_preview=transcript[:180].replace("\n", " "),
                loop_risk=loop_risk,
                loop_reason=loop_reason,
                total_words=int(metrics["total_words"]),
                unique_words=int(metrics["unique_words"]),
                unique_ratio=metrics["unique_ratio"],
                max_repeat_2gram=int(metrics["max_repeat_2gram"]),
                max_repeat_3gram=int(metrics["max_repeat_3gram"]),
                max_repeat_4gram=int(metrics["max_repeat_4gram"]),
            )
        )
        print(
            f" - {relative_file}: {elapsed:.2f}s"
            + (f" (loop-risk: {loop_reason})" if loop_risk else "")
        )

    json_path = run_dir / "results.json"
    md_path = run_dir / "report.md"
    json_path.write_text(
        json.dumps([asdict(r) for r in results], indent=2), encoding="utf-8"
    )
    md_path.write_text(
        markdown_report(
            results=results,
            run_name=args.run_name,
            whisper_cli=whisper_cli,
            model_path=model_path,
            language=args.language,
            threads=args.threads,
            temperature=args.temperature,
            use_vad=args.use_vad,
        ),
        encoding="utf-8",
    )

    print(f"\nWrote: {json_path}")
    print(f"Wrote: {md_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
