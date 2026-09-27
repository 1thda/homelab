#!/usr/bin/env python3
"""Compare completed GNU SHA-256 manifests; never modify the media or baseline."""
import argparse
import datetime
import json
from pathlib import Path
import re
import sys


def read_manifest(path):
    entries = {}
    with path.open(encoding="utf-8", errors="surrogateescape") as source:
        for number, line in enumerate(source, 1):
            line = line.rstrip("\n")
            escaped = line.startswith("\\")
            if escaped:
                line = line[1:]
            if not re.match(r"^[0-9a-fA-F]{64} [ *]", line):
                raise ValueError(f"{path.name}: invalid checksum line {number}")
            digest, name = line[:64].lower(), line[66:]
            if escaped:
                # GNU escapes backslash, newline and carriage return in names.
                name = re.sub(r"\\([\\nr])", lambda m: {"\\": "\\", "n": "\n", "r": "\r"}[m[1]], name)
            if not name or name in entries:
                raise ValueError(f"{path.name}: empty or duplicate filename on line {number}")
            entries[name] = digest
    return entries


def previous_manifest(current):
    for folder in sorted(current.parent.parent.iterdir(), reverse=True):
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", folder.name) or folder.name >= current.parent.name:
            continue
        manifest, log = folder / "manifest.sha256", folder / "run.log"
        if manifest.is_file() and log.is_file() and "checksum manifest done:" in log.read_text(errors="replace"):
            return manifest
    return None


def compare(current, previous, media_root=Path("/mnt/media")):
    now = read_manifest(current)
    before = read_manifest(previous) if previous else {}
    shared = now.keys() & before.keys()
    changed = sorted(name for name in shared if now[name] != before[name])
    missing = sorted(before.keys() - now.keys())
    generated_root = str(media_root / "_captioning") + "/"
    generated_changed = [name for name in changed if name.startswith(generated_root)]
    generated_missing = [name for name in missing if name.startswith(generated_root)]
    needs_review = len(changed) > len(generated_changed) or len(missing) > len(generated_missing)
    return {
        "checked_at_utc": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "current_manifest": str(current),
        "previous_manifest": str(previous) if previous else None,
        "status": "baseline_only" if previous is None else "changes_detected" if needs_review else "ok",
        "current_files": len(now),
        "previous_files": len(before),
        "unchanged": len(shared) - len(changed),
        "changed": changed,
        "new": sorted(now.keys() - before.keys()),
        "missing": missing,
        "generated_changed": generated_changed,
        "generated_missing": generated_missing,
        "note": "Edits, renames, deletion and corruption cannot be distinguished by hashes alone. Changes under _captioning are reported as generated staging data and do not raise a warning. This compares scan snapshots, not the live filesystem. Existing exclusions still apply.",
    }


def write_reports(result, directory):
    directory.mkdir(parents=True, exist_ok=True)
    text = (
        f"Status: {result['status']}\n"
        f"Current: {result['current_manifest']}\nPrevious: {result['previous_manifest']}\n"
        f"Unchanged: {result['unchanged']}; changed: {len(result['changed'])}; "
        f"new: {len(result['new'])}; missing: {len(result['missing'])}\n"
        f"Of these, generated staging files changed: {len(result['generated_changed'])}; missing: {len(result['generated_missing'])}\n"
        f"{result['note']}\n"
    )
    for kind in ("changed", "missing", "new", "generated_changed", "generated_missing"):
        text += f"\n{kind.upper()} ({len(result[kind])})\n"
        text += "".join(json.dumps(name, ensure_ascii=True) + "\n" for name in result[kind])
    for name, contents in (("checksum-verification.json", json.dumps(result, indent=2) + "\n"),
                           ("checksum-verification.txt", text)):
        target = directory / name
        temporary = directory / (name + ".tmp")
        temporary.write_text(contents, encoding="utf-8")
        temporary.replace(target)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("current", type=Path)
    parser.add_argument("--previous", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--media-root", type=Path, default=Path("/mnt/media"))
    args = parser.parse_args()
    try:
        previous = args.previous or previous_manifest(args.current)
        result = compare(args.current, previous, args.media_root)
        write_reports(result, args.output or args.current.parent)
    except (OSError, ValueError) as error:
        print(f"Checksum verification failed: {error}", file=sys.stderr)
        return 2
    print(f"checksum verification: {result['status']}; unchanged={result['unchanged']}, "
          f"changed={len(result['changed'])}, new={len(result['new'])}, missing={len(result['missing'])}; "
          f"generated changes={len(result['generated_changed'])}, generated missing={len(result['generated_missing'])}")
    return 1 if result["status"] == "changes_detected" else 0


if __name__ == "__main__":
    sys.exit(main())
