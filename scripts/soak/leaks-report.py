#!/usr/bin/env python3
"""Leak readings for the long-session soak test (#76, docs/soak.md).

`scripts/soak/soak.sh` runs macOS's `leaks` tool (the same leak detection as
Instruments' Leaks instrument) against the app on the simulator every few
minutes of the soak and once more after the run, while the app sits idle.
This script turns those readings into a verdict: the leaked memory must not
grow over the run.

Subcommands:

  parse --phase <phase> --wall <seconds> [--input <leaks output>]
      Reads one `leaks <pid>` output (stdin by default) and prints one JSON
      line: {"phase", "wall", "leaks", "bytes", "process"}. Exits 1 if the
      output has no "Process N: X leaks for Y total leaked bytes." line.

  evaluate --readings <jsonl> [--markdown <file>] [--json <file>]
           [--tolerance-leaks N] [--tolerance-bytes N]
      Compares the first reading (taken a few minutes in, after start-up)
      with the last one (after the run, or the latest during it). Passes
      when neither the leak count nor the leaked bytes grew by more than the
      tolerances (default 0 leaks, 0 bytes). Exits 1 on growth, 2 when there
      are fewer than two readings.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

LEAKS_LINE = re.compile(
    r"^Process\s+(?P<pid>\d+):\s+(?P<leaks>\d+)\s+leaks?\s+for\s+(?P<bytes>\d+)\s+total\s+leaked\s+bytes",
    re.MULTILINE,
)
PROCESS_LINE = re.compile(r"^Process:\s+(?P<name>\S+)\s+\[(?P<pid>\d+)\]", re.MULTILINE)


def parse(text: str, phase: str, wall: float) -> dict | None:
    match = LEAKS_LINE.search(text)
    if not match:
        return None
    process = PROCESS_LINE.search(text)
    return {
        "phase": phase,
        "wall": round(wall, 1),
        "pid": int(match.group("pid")),
        "process": process.group("name") if process else None,
        "leaks": int(match.group("leaks")),
        "bytes": int(match.group("bytes")),
    }


def evaluate(readings: list[dict], tolerance_leaks: int, tolerance_bytes: int) -> dict:
    readings = sorted(readings, key=lambda reading: reading["wall"])
    if len(readings) < 2:
        return {
            "passed": False,
            "reason": f"{len(readings)} leak reading(s); at least two are needed to see growth",
            "readings": readings,
        }
    first, last = readings[0], readings[-1]
    leak_growth = last["leaks"] - first["leaks"]
    byte_growth = last["bytes"] - first["bytes"]
    peak = max(readings, key=lambda reading: reading["bytes"])
    passed = leak_growth <= tolerance_leaks and byte_growth <= tolerance_bytes
    reason = (
        "no growth"
        if passed
        else f"leaks grew by {leak_growth} ({byte_growth:+d} bytes) between {first['phase']} and {last['phase']}"
    )
    return {
        "passed": passed,
        "reason": reason,
        "first": first,
        "last": last,
        "leakGrowth": leak_growth,
        "byteGrowth": byte_growth,
        "peakBytes": peak["bytes"],
        "toleranceLeaks": tolerance_leaks,
        "toleranceBytes": tolerance_bytes,
        "readings": readings,
    }


def markdown(result: dict) -> str:
    lines = ["### Leaks", ""]
    verdict = "pass" if result["passed"] else "**FAIL**"
    lines.append(f"`leaks` (the Leaks instrument's detector) on the app process: {verdict}, {result['reason']}.")
    lines.append("")
    lines.append("| When | Wall | Leaks | Leaked bytes |")
    lines.append("| --- | ---: | ---: | ---: |")
    for reading in result.get("readings", []):
        lines.append(
            f"| {reading['phase']} | {reading['wall'] / 60:.1f} min | {reading['leaks']} | {reading['bytes']:,} |"
        )
    return "\n".join(lines) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    parse_command = commands.add_parser("parse")
    parse_command.add_argument("--phase", required=True)
    parse_command.add_argument("--wall", type=float, required=True)
    parse_command.add_argument("--input", type=Path)

    evaluate_command = commands.add_parser("evaluate")
    evaluate_command.add_argument("--readings", type=Path, required=True)
    evaluate_command.add_argument("--markdown", type=Path)
    evaluate_command.add_argument("--json", type=Path)
    evaluate_command.add_argument("--tolerance-leaks", type=int, default=0)
    evaluate_command.add_argument("--tolerance-bytes", type=int, default=0)

    arguments = parser.parse_args()
    if arguments.command == "parse":
        text = arguments.input.read_text() if arguments.input else sys.stdin.read()
        reading = parse(text, arguments.phase, arguments.wall)
        if reading is None:
            print("leaks-report: no leak summary in the leaks output", file=sys.stderr)
            return 1
        print(json.dumps(reading, sort_keys=True))
        return 0

    readings = []
    if arguments.readings.exists():
        for line in arguments.readings.read_text().splitlines():
            if line.strip():
                readings.append(json.loads(line))
    result = evaluate(readings, arguments.tolerance_leaks, arguments.tolerance_bytes)
    if arguments.json:
        arguments.json.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    text = markdown(result)
    if arguments.markdown:
        arguments.markdown.write_text(text)
    print(text, end="")
    if len(readings) < 2:
        return 2
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    sys.exit(main())
