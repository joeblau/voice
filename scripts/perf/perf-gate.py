#!/usr/bin/env python3
"""Regression gate for the XCTest performance suite (#73).

Reads the metrics of a `make perf` run from its .xcresult (through
`xcrun xcresulttool get test-results metrics`), compares each one with the
committed baseline for the machine it ran on, and fails when one is worse
by more than its tolerance (10% unless the baseline says otherwise).

Behind `make perf-check` and `make perf-baseline`, and the nightly `perf` CI
job. See docs/performance.md, "Performance suite".

    perf-gate.py extract  (--xcresult X.xcresult | --xcresulttool-json saved.json)
                          [--output results.json]
    perf-gate.py check    (--xcresult X.xcresult | --results results.json)
                          --baseline BASELINE.json [--report report.md]
    perf-gate.py record   (--xcresult X.xcresult | --results results.json)...
                          --baseline BASELINE.json [--environment NAME] [--note TEXT]
                          [--calibrate]

`record` takes several runs (repeat --xcresult or --results): it pools their
iterations into each metric's baseline and reports how far each run's
statistic strayed from it. With --calibrate it widens a metric's tolerance to
1.5 times that spread (rounded up to 5%) where the default would be tighter,
so that a shared CI machine's run-to-run noise doesn't fail the gate.

Exit status: 0 when every baselined metric is within tolerance (check), 1 on
a regression or a baselined metric that wasn't measured, 2 on bad input.

Standard library only, so it runs on any CI image without installing
anything.
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import statistics
import subprocess
import sys

DEFAULT_TOLERANCE = 10.0
# --calibrate: a tolerance is this many times the largest spread seen between
# the recorded runs, rounded up to a multiple of CALIBRATION_STEP percent.
CALIBRATION_MARGIN = 1.5
CALIBRATION_STEP = 5
SMALLER = "prefers smaller"
LARGER = "prefers larger"
STATISTICS = {
    "median": statistics.median,
    "mean": statistics.fmean,
    "min": min,
    "max": max,
}


class GateError(Exception):
    """Bad input: a missing file, an unreadable result bundle."""


# MARK: - Reading results


def metrics_from_xcresulttool(document: list) -> dict:
    """Normalizes `xcresulttool get test-results metrics` output.

    Returns {"tests": {test id: {metric id: {name, unit, polarity, values}}},
             "devices": [device names]}. Values of the same metric from
    several runs (repetitions, configurations) are pooled.
    """
    tests: dict = {}
    devices: list = []
    for test in document:
        test_id = test.get("testIdentifier")
        if not test_id:
            continue
        for run in test.get("testRuns", []):
            device = run.get("device", {}).get("deviceName")
            if device and device not in devices:
                devices.append(device)
            for metric in run.get("metrics", []):
                identifier = metric.get("identifier") or metric.get("displayName")
                values = [float(value) for value in metric.get("measurements", [])]
                if not identifier or not values:
                    continue
                entry = tests.setdefault(test_id, {}).setdefault(
                    identifier,
                    {
                        "name": metric.get("displayName", identifier),
                        "unit": metric.get("unitOfMeasurement", ""),
                        "polarity": metric.get("polarity", SMALLER),
                        "values": [],
                    },
                )
                entry["values"].extend(values)
    return {"tests": tests, "devices": devices}


def extract(xcresult: str) -> dict:
    if not os.path.isdir(xcresult):
        raise GateError(f"{xcresult} doesn't exist; run `make perf` first")
    command = ["xcrun", "xcresulttool", "get", "test-results", "metrics", "--path", xcresult]
    try:
        output = subprocess.run(command, check=True, capture_output=True, text=True).stdout
    except (OSError, subprocess.CalledProcessError) as error:
        detail = getattr(error, "stderr", "") or str(error)
        raise GateError(f"xcresulttool failed on {xcresult}: {detail.strip()}") from error
    try:
        document = json.loads(output)
    except json.JSONDecodeError as error:
        raise GateError(f"xcresulttool printed something that isn't JSON: {error}") from error
    return metrics_from_xcresulttool(document)


def load_runs(arguments) -> list:
    """Every run given to `record` (--results or --xcresult, repeated)."""
    runs = []
    for path in arguments.results or []:
        with open(path, encoding="utf-8") as file:
            runs.append(json.load(file))
    for path in arguments.xcresult or []:
        runs.append(extract(path))
    if not runs:
        raise GateError("pass --xcresult or --results")
    return runs


def load_results(arguments) -> dict:
    if arguments.results:
        with open(arguments.results, encoding="utf-8") as file:
            return json.load(file)
    if arguments.xcresult:
        return extract(arguments.xcresult)
    raise GateError("pass --xcresult or --results")


def load_baseline(path: str) -> dict:
    try:
        with open(path, encoding="utf-8") as file:
            return json.load(file)
    except FileNotFoundError as error:
        raise GateError(f"no baseline at {path}; record one with `make perf-baseline`") from error
    except json.JSONDecodeError as error:
        raise GateError(f"{path} isn't valid JSON: {error}") from error


# MARK: - Comparing


def worse_by_percent(baseline: float, current: float, polarity: str) -> float:
    """How much worse `current` is than `baseline`, in percent (negative when
    better)."""
    if baseline == 0:
        return 0.0 if current == baseline else float("inf")
    change = (current - baseline) / abs(baseline) * 100
    return -change if polarity == LARGER else change


def compare(results: dict, baseline: dict) -> list:
    """One row per baselined metric, plus the measured metrics that have no
    baseline (not gated)."""
    statistic_name = baseline.get("statistic", "median")
    statistic = STATISTICS[statistic_name]
    default_tolerance = float(baseline.get("defaultTolerancePercent", DEFAULT_TOLERANCE))
    rows = []
    measured = results.get("tests", {})
    for test_id, metrics in sorted(baseline.get("tests", {}).items()):
        for metric_id, expected in sorted(metrics.items()):
            row = {
                "test": test_id,
                "metric": metric_id,
                "name": expected.get("name", metric_id),
                "unit": expected.get("unit", ""),
                "baseline": float(expected["baseline"]),
                "tolerance": float(expected.get("tolerancePercent", default_tolerance)),
                "current": None,
                "change": None,
                "status": "missing",
            }
            values = measured.get(test_id, {}).get(metric_id, {}).get("values", [])
            if values:
                current = float(statistic(values))
                change = worse_by_percent(row["baseline"], current, expected.get("polarity", SMALLER))
                minimum_delta = float(expected.get("minimumDelta", 0))
                too_small = abs(current - row["baseline"]) <= minimum_delta
                row.update(current=current, change=change)
                row["status"] = "regressed" if change > row["tolerance"] and not too_small else "ok"
            rows.append(row)
    for test_id, metrics in sorted(measured.items()):
        for metric_id, metric in sorted(metrics.items()):
            if metric_id in baseline.get("tests", {}).get(test_id, {}):
                continue
            current = float(statistic(metric["values"]))
            if not any(metric["values"]):
                status = "unavailable"
            elif current == 0:
                status = "zero"
            else:
                status = "new"
            rows.append(
                {
                    "test": test_id,
                    "metric": metric_id,
                    "name": metric.get("name", metric_id),
                    "unit": metric.get("unit", ""),
                    "baseline": None,
                    "tolerance": None,
                    "current": current,
                    "change": None,
                    "status": status,
                }
            )
    return rows


def number(value, unit="") -> str:
    if value is None:
        return "–"
    magnitude = abs(value)
    if magnitude >= 1000:
        text = f"{value:,.0f}"
    elif magnitude >= 10:
        text = f"{value:.1f}"
    else:
        text = f"{value:.3g}"
    return f"{text} {unit}".strip()


def report(rows: list, baseline: dict, results: dict) -> str:
    recorded = baseline.get("recorded", {})
    lines = [
        "## Performance suite",
        "",
        f"Baseline `{baseline.get('environment', '?')}` "
        f"({recorded.get('device', 'unknown device')}, {recorded.get('date', 'unknown date')}), "
        f"{baseline.get('statistic', 'median')} of each metric's iterations. "
        f"Measured on: {', '.join(results.get('devices', [])) or 'unknown'}.",
        "",
        "| Result | Test | Metric | Baseline | Current | Change | Tolerance |",
        "| --- | --- | --- | ---: | ---: | ---: | ---: |",
    ]
    marks = {
        "ok": "ok",
        "regressed": "**REGRESSED**",
        "missing": "**NOT MEASURED**",
        "new": "new, not gated",
        "unavailable": "all zero on this machine, not gated",
        "zero": "zero, not gated",
    }
    for row in rows:
        change = "–" if row["change"] is None else f"{row['change'] + 0.0:+.1f}%".replace("-0.0%", "+0.0%")
        tolerance = "–" if row["tolerance"] is None else f"{row['tolerance']:.0f}%"
        lines.append(
            f"| {marks[row['status']]} | `{row['test']}` | {row['name']} | "
            f"{number(row['baseline'], row['unit'])} | {number(row['current'], row['unit'])} | {change} | {tolerance} |"
        )
    failures = [row for row in rows if row["status"] in ("regressed", "missing")]
    lines.append("")
    if failures:
        lines.append(f"**{len(failures)} metric(s) failed the gate.** A positive change is worse.")
    else:
        lines.append("Every baselined metric is within its tolerance. A positive change is worse.")
    return "\n".join(lines) + "\n"


# MARK: - Recording


def pool(runs: list) -> dict:
    """Several runs' results as one: each metric's values from every run,
    and `runValues`, the values of each run on its own (for the spread)."""
    tests: dict = {}
    devices: list = []
    for results in runs:
        for device in results.get("devices", []):
            if device not in devices:
                devices.append(device)
        for test_id, metrics in results.get("tests", {}).items():
            for metric_id, metric in metrics.items():
                entry = tests.setdefault(test_id, {}).setdefault(
                    metric_id,
                    {
                        "name": metric.get("name", metric_id),
                        "unit": metric.get("unit", ""),
                        "polarity": metric.get("polarity", SMALLER),
                        "values": [],
                        "runValues": [],
                    },
                )
                entry["values"].extend(metric["values"])
                entry["runValues"].append(list(metric["values"]))
    return {"tests": tests, "devices": devices}


def spread_percent(baseline: float, run_statistics: list) -> float | None:
    """How far the furthest run's statistic is from the pooled baseline, in
    percent of it; None with fewer than two runs or a zero baseline."""
    if len(run_statistics) < 2 or baseline == 0:
        return None
    return max(abs(value - baseline) for value in run_statistics) / abs(baseline) * 100


def calibrated_tolerance(spread: float, floor: float) -> float:
    """CALIBRATION_MARGIN times `spread`, rounded up to CALIBRATION_STEP, and
    never below `floor`."""
    wanted = spread * CALIBRATION_MARGIN
    steps = -(-wanted // CALIBRATION_STEP)  # ceiling division
    return max(floor, float(steps * CALIBRATION_STEP))


def record(
    results: dict,
    baseline_path: str,
    environment: str | None,
    note: str | None,
    calibrate: bool = False,
    runs: int = 1,
) -> tuple:
    """A new baseline from `results` (one run, or several pooled by `pool`),
    keeping the hand-set tolerances, minimum deltas and notes of the metrics
    already in the file at `baseline_path`.

    With several runs, every metric records each run's statistic (`runs`)
    and the largest `spreadPercent` between them and the baseline. With
    `calibrate`, a metric whose spread calls for more than its hand-set (or
    the default) tolerance gets a calibrated one; metrics gated by a
    `minimumDelta` keep theirs. Returns the baseline and the calibration
    rows for the summary.
    """
    previous = {}
    if os.path.exists(baseline_path):
        previous = load_baseline(baseline_path)
    statistic_name = previous.get("statistic", "median")
    statistic = STATISTICS[statistic_name]
    default_tolerance = float(previous.get("defaultTolerancePercent", DEFAULT_TOLERANCE))
    tests = {}
    unavailable = []
    calibration = []
    for test_id, metrics in sorted(results.get("tests", {}).items()):
        for metric_id, metric in sorted(metrics.items()):
            # A counter the machine doesn't provide (CPU instructions and
            # cycles in a virtual machine) reads zero every time: nothing to
            # gate.
            if not any(metric["values"]):
                unavailable.append(f"{test_id} {metric.get('name', metric_id)}")
                continue
            old = previous.get("tests", {}).get(test_id, {}).get(metric_id, {})
            value = float(statistic(metric["values"]))
            # A metric that is usually zero (an idle app's CPU time) has no
            # percentage to gate: any non-zero value would be "infinitely"
            # worse. Gate it only with a hand-set minimumDelta.
            if value == 0 and "minimumDelta" not in old:
                unavailable.append(f"{test_id} {metric.get('name', metric_id)} ({statistic_name} 0)")
                continue
            entry = {
                "name": metric.get("name", metric_id),
                "unit": metric.get("unit", ""),
                "polarity": metric.get("polarity", SMALLER),
                "baseline": round(value, 6),
                "samples": [round(float(sample), 6) for sample in metric["values"]],
            }
            run_values = [values for values in metric.get("runValues", []) if values]
            run_statistics = [float(statistic(values)) for values in run_values]
            spread = spread_percent(value, run_statistics)
            if spread is not None:
                entry["runs"] = [round(item, 6) for item in run_statistics]
                entry["spreadPercent"] = round(spread, 1)

            # Hand-set overrides survive; a calibrated tolerance is only kept
            # until the next calibration.
            for kept in ("tolerancePercent", "minimumDelta", "note"):
                if kept in old and not (old.get("calibrated") and kept != "minimumDelta"):
                    entry[kept] = old[kept]
            hand_set = float(entry.get("tolerancePercent", default_tolerance))
            tolerance = hand_set
            if spread is not None and "minimumDelta" not in entry:
                suggested = calibrated_tolerance(spread, hand_set)
                if calibrate and suggested > hand_set:
                    tolerance = suggested
                    entry["tolerancePercent"] = suggested
                    entry["calibrated"] = True
                    entry.setdefault(
                        "note",
                        f"Calibrated: run {statistic_name}s strayed up to {spread:.0f}% from the pooled "
                        f"baseline across {len(run_statistics)} runs on this machine type, so the tolerance is "
                        f"{CALIBRATION_MARGIN:g} times that.",
                    )
                calibration.append(
                    {
                        "test": test_id,
                        "name": entry["name"],
                        "unit": entry["unit"],
                        "runs": run_statistics,
                        "spread": spread,
                        "suggested": suggested,
                        "tolerance": tolerance,
                    }
                )
            tests.setdefault(test_id, {})[metric_id] = entry
    commit = os.environ.get("GITHUB_SHA") or git_head()
    baseline = {
        "description": previous.get(
            "description",
            "Baselines for the XCTest performance suite (#73) on one machine type; see docs/performance.md.",
        ),
        "environment": environment or previous.get("environment", "local"),
        "statistic": statistic_name,
        "defaultTolerancePercent": default_tolerance,
        "recorded": {
            "date": datetime.date.today().isoformat(),
            "commit": commit,
            "device": ", ".join(results.get("devices", [])) or "unknown",
            "runs": runs,
            "note": note or previous.get("recorded", {}).get("note", ""),
        },
        "unavailable": unavailable,
        "tests": tests,
    }
    return baseline, calibration


def calibration_report(rows: list, statistic_name: str) -> str:
    """The spread of each metric between the recorded runs, and the
    tolerance it calls for."""
    lines = [
        f"Run-to-run spread ({statistic_name} of each run against the pooled baseline):",
        "",
        "| Test | Metric | Runs | Spread | Calls for | Tolerance |",
        "| --- | --- | --- | ---: | ---: | ---: |",
    ]
    for row in rows:
        runs = ", ".join(number(value, row["unit"]) for value in row["runs"])
        flag = " **(too tight)**" if row["tolerance"] < row["suggested"] else ""
        lines.append(
            f"| `{row['test']}` | {row['name']} | {runs} | {row['spread']:.1f}% | "
            f"{row['suggested']:.0f}% | {row['tolerance']:.0f}%{flag} |"
        )
    if any(row["tolerance"] < row["suggested"] for row in rows):
        lines += ["", "Some tolerances are tighter than the spread calls for; `--calibrate` widens them."]
    return "\n".join(lines) + "\n"


def git_head() -> str:
    try:
        return subprocess.run(
            ["git", "rev-parse", "--short", "HEAD"], check=True, capture_output=True, text=True
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return ""


# MARK: - Command line


def main(argv: list) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)

    extract_command = commands.add_parser("extract", help="normalize an .xcresult's metrics to JSON")
    extract_source = extract_command.add_mutually_exclusive_group(required=True)
    extract_source.add_argument("--xcresult")
    extract_source.add_argument(
        "--xcresulttool-json", help="saved output of `xcresulttool get test-results metrics` instead of a bundle"
    )
    extract_command.add_argument("--output", help="write here instead of stdout")

    for name, help_text in (("check", "compare with a baseline"), ("record", "write a baseline")):
        command = commands.add_parser(name, help=help_text)
        source = command.add_mutually_exclusive_group(required=True)
        if name == "check":
            source.add_argument("--xcresult")
            source.add_argument("--results", help="output of `extract`")
        else:
            source.add_argument("--xcresult", action="append", help="a run to record; repeat to pool several")
            source.add_argument("--results", action="append", help="output of `extract`; repeat to pool several")
        command.add_argument("--baseline", required=True)
        if name == "check":
            command.add_argument("--report", help="also write the Markdown report here")
            command.add_argument("--results-output", help="also write the extracted results here")
        else:
            command.add_argument("--environment", help="the machine type the baseline is for, e.g. ci-simulator")
            command.add_argument("--note", help="free text stored with the baseline")
            command.add_argument(
                "--calibrate",
                action="store_true",
                help="widen tolerances to 1.5x the spread between the runs where the default is tighter",
            )

    arguments = parser.parse_args(argv)
    try:
        if arguments.command == "extract":
            if arguments.xcresulttool_json:
                with open(arguments.xcresulttool_json, encoding="utf-8") as file:
                    results = metrics_from_xcresulttool(json.load(file))
            else:
                results = extract(arguments.xcresult)
            text = json.dumps(results, indent=2, sort_keys=True) + "\n"
            if arguments.output:
                with open(arguments.output, "w", encoding="utf-8") as file:
                    file.write(text)
            else:
                sys.stdout.write(text)
            return 0

        if arguments.command == "record":
            runs = load_runs(arguments)
            for index, run in enumerate(runs, start=1):
                if not run.get("tests"):
                    raise GateError(f"run {index} holds no metrics; did the perf tests run?")
            baseline, calibration = record(
                pool(runs),
                arguments.baseline,
                arguments.environment,
                arguments.note,
                calibrate=arguments.calibrate,
                runs=len(runs),
            )
            os.makedirs(os.path.dirname(os.path.abspath(arguments.baseline)), exist_ok=True)
            with open(arguments.baseline, "w", encoding="utf-8") as file:
                json.dump(baseline, file, indent=2, sort_keys=False)
                file.write("\n")
            count = sum(len(metrics) for metrics in baseline["tests"].values())
            print(f"perf-gate: recorded {count} metric(s) from {len(runs)} run(s) in {arguments.baseline}")
            if calibration:
                print()
                sys.stdout.write(calibration_report(calibration, baseline["statistic"]))
            elif arguments.calibrate:
                print("perf-gate: --calibrate needs two or more runs; tolerances unchanged.")
            return 0

        results = load_results(arguments)

        baseline = load_baseline(arguments.baseline)
        if arguments.results_output:
            with open(arguments.results_output, "w", encoding="utf-8") as file:
                json.dump(results, file, indent=2, sort_keys=True)
                file.write("\n")
        rows = compare(results, baseline)
        text = report(rows, baseline, results)
        sys.stdout.write(text)
        if arguments.report:
            os.makedirs(os.path.dirname(os.path.abspath(arguments.report)), exist_ok=True)
            with open(arguments.report, "w", encoding="utf-8") as file:
                file.write(text)
        failed = [row for row in rows if row["status"] in ("regressed", "missing")]
        return 1 if failed else 0
    except GateError as error:
        print(f"perf-gate: error: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
