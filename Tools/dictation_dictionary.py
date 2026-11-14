#!/usr/bin/env python3
"""Edit the same local dictionary that Lemon Whisper reads when recording starts."""

import argparse
import contextlib
import fcntl
import json
import os
from pathlib import Path
import tempfile
import unicodedata


DEFAULT_PATH = Path.home() / "Library/Application Support/LemonWhisper/Dictionary.json"


def valid_phrase(value):
    return (
        isinstance(value, str)
        and value
        and value == value.strip()
        and len(value.encode("utf-8")) <= 160
        and not any(unicodedata.category(char) in {"Cc", "Cf"} for char in value)
    )


def match_key(entry):
    return entry.get("alias", entry["term"]).lower()


def load(path):
    try:
        dictionary = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"entries": []}
    if not isinstance(dictionary, dict) or not isinstance(dictionary.get("entries"), list):
        raise ValueError("Dictionary must contain an entries list")
    matches = set()
    for entry in dictionary["entries"]:
        if isinstance(entry, dict) and entry.get("alias") is None:
            entry.pop("alias", None)
        if not isinstance(entry, dict) or not valid_phrase(entry.get("term")) or (
            "alias" in entry and not valid_phrase(entry["alias"])
        ):
            raise ValueError("Invalid dictionary entry")
        key = match_key(entry)
        if key in matches:
            raise ValueError(f"Duplicate dictionary entry: {key}")
        matches.add(key)
    return dictionary


def save(path, dictionary):
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(dictionary, stream, indent=2, ensure_ascii=False)
            stream.write("\n")
            stream.close()
            temporary.replace(path)
        finally:
            with contextlib.suppress(FileNotFoundError):
                temporary.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--file", type=Path, default=DEFAULT_PATH, help="Use an alternate dictionary file")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("list")
    add = commands.add_parser("add")
    add.add_argument("term")
    add.add_argument("--alias", help="Transcribed phrase to replace with the preferred term")
    remove = commands.add_parser("remove")
    remove.add_argument("phrase", help="Alias, or the term for an entry without an alias")
    args = parser.parse_args()
    path = args.file.expanduser()

    try:
        if args.command == "list":
            print(json.dumps(load(path)["entries"], indent=2, ensure_ascii=False))
            return

        if args.command == "add":
            entry = {"term": args.term.strip()}
            if args.alias is not None:
                entry["alias"] = args.alias.strip()
            if not all(valid_phrase(value) for value in entry.values()):
                parser.error("Use nonempty phrases of up to 160 UTF-8 bytes without control characters")
            key = match_key(entry)
        else:
            key = args.phrase.strip().lower()

        path.parent.mkdir(parents=True, exist_ok=True)
        with path.with_name(path.name + ".lock").open("a", encoding="utf-8") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            dictionary = load(path)
            existing = dictionary["entries"]
            updated = [item for item in existing if match_key(item) != key]
            if args.command == "add":
                updated.append(entry)
            elif len(updated) == len(existing):
                parser.error(f"Entry not found: {args.phrase}")
            dictionary["entries"] = updated
            save(path, dictionary)
            print(json.dumps(entry, ensure_ascii=False) if args.command == "add" else f"Removed {args.phrase}")
    except (OSError, ValueError) as error:
        parser.exit(1, f"{error}\n")


if __name__ == "__main__":
    main()
