#!/usr/bin/env python3
"""Exercise the bundled disposable Voxtral worker and check PID/RSS invariants."""

import argparse
import json
import os
import statistics
import subprocess
import sys
import time
import uuid


def rss_bytes(pid: int) -> int:
    output = subprocess.check_output(
        ["/bin/ps", "-o", "rss=", "-p", str(pid)], text=True
    ).strip()
    return int(output) * 1024


def receive(process: subprocess.Popen, expected: str) -> dict:
    line = process.stdout.readline()
    if not line:
        raise RuntimeError(
            f"worker exited before {expected}; status={process.poll()}"
        )
    event = json.loads(line)
    if event.get("type") != expected:
        raise RuntimeError(f"expected {expected}, received {event}")
    return event


def send(process: subprocess.Popen, message: dict) -> None:
    process.stdin.write(json.dumps(message, separators=(",", ":")) + "\n")
    process.stdin.flush()


def pid_is_gone(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return False
    except ProcessLookupError:
        return True


def slope(values: list[int]) -> float:
    if len(values) < 2:
        return 0.0
    xs = list(range(len(values)))
    x_mean = statistics.fmean(xs)
    y_mean = statistics.fmean(values)
    denominator = sum((x - x_mean) ** 2 for x in xs)
    return sum((x - x_mean) * (y - y_mean) for x, y in zip(xs, values)) / denominator


def run_cycle(args: argparse.Namespace, cycle: int) -> tuple[int, str]:
    process = subprocess.Popen(
        [args.helper],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        bufsize=1,
    )
    try:
        hello = receive(process, "hello")
        worker_pid = int(hello["payload"]["workerPID"])
        if worker_pid != process.pid:
            raise RuntimeError(f"handshake PID {worker_pid} != launched PID {process.pid}")

        prepare_id = str(uuid.uuid4())
        send(process, {
            "type": "prepare",
            "payload": {"id": prepare_id, "modelID": args.model},
        })
        prepared = receive(process, "prepared")
        if prepared["payload"]["requestID"].lower() != prepare_id.lower():
            raise RuntimeError("prepare response correlation mismatch")

        request_id = str(uuid.uuid4())
        send(process, {
            "type": "transcribe",
            "payload": {
                "id": request_id,
                "audioPath": os.path.abspath(args.audio),
                "modelID": args.model,
                "language": None if args.language == "auto" else args.language,
            },
        })
        result = receive(process, "result")
        if result["payload"]["requestID"].lower() != request_id.lower():
            raise RuntimeError("result correlation mismatch")
        text = result["payload"]["text"].strip()
        status = process.wait(timeout=args.timeout)
        if status != 0:
            raise RuntimeError(f"worker exited with {status}")
        for _ in range(100):
            if pid_is_gone(worker_pid):
                break
            time.sleep(0.01)
        if not pid_is_gone(worker_pid):
            raise RuntimeError(f"worker PID {worker_pid} survived cycle {cycle}")
        return worker_pid, text
    finally:
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
        if process.stdin:
            process.stdin.close()
        if process.stdout:
            process.stdout.close()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--helper", required=True)
    parser.add_argument("--audio", required=True)
    parser.add_argument("--cycles", type=int, default=100)
    parser.add_argument("--model", default="mini-3b-4bit")
    parser.add_argument("--language", default="auto")
    parser.add_argument("--timeout", type=float, default=300)
    parser.add_argument("--max-parent-growth-mb", type=float, default=20)
    parser.add_argument("--jsonl")
    args = parser.parse_args()

    if args.cycles < 1:
        parser.error("--cycles must be positive")
    if not os.access(args.helper, os.X_OK):
        parser.error("--helper must be executable")
    if not os.path.isfile(args.audio):
        parser.error("--audio must exist")

    parent_pid = os.getpid()
    baseline = rss_bytes(parent_pid)
    samples: list[int] = []
    seen_pids: set[int] = set()
    output = open(args.jsonl, "w", encoding="utf-8") if args.jsonl else None
    try:
        for cycle in range(1, args.cycles + 1):
            worker_pid, text = run_cycle(args, cycle)
            if worker_pid in seen_pids:
                raise RuntimeError(f"worker PID reused unexpectedly: {worker_pid}")
            seen_pids.add(worker_pid)
            current_rss = rss_bytes(parent_pid)
            samples.append(current_rss)
            record = {
                "cycle": cycle,
                "worker_pid": worker_pid,
                "worker_exited": True,
                "parent_rss_bytes": current_rss,
                "text": text,
            }
            if output:
                output.write(json.dumps(record) + "\n")
                output.flush()
            print(
                f"cycle={cycle} pid={worker_pid} parent_rss_mb={current_rss / 1048576:.2f} "
                f"text={text!r}",
                flush=True,
            )
    finally:
        if output:
            output.close()

    settled_growth = max(samples[-min(5, len(samples)):]) - baseline
    per_cycle = slope(samples)
    summary = {
        "cycles": args.cycles,
        "unique_worker_pids": len(seen_pids),
        "baseline_parent_rss_bytes": baseline,
        "settled_parent_growth_bytes": settled_growth,
        "parent_rss_slope_bytes_per_cycle": per_cycle,
    }
    print(json.dumps(summary, indent=2))
    if settled_growth > args.max_parent_growth_mb * 1048576:
        print("parent RSS growth exceeded threshold", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
