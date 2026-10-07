#!/usr/bin/env python3
"""Compares the performance HUD's readings with an Instruments trace (#71).

Usage:
  hud_compare.py <hud.json> <signpost-intervals.xml> <activity-monitor.xml>

hud.json is what PerformanceHUDInstrumentsComparison wrote: the HUD's
statistics per interval, and its CPU % and footprint readings during the
steady load. The two XML files are `xctrace export` tables from the same
recording: os_signpost's paired intervals (OSSignpostIntervals) and Activity
Monitor's per-process samples (activity-monitor-process-live).

Exits non-zero, listing every mismatch, unless:

  - each interval has the same count in the HUD and in Instruments; at
    least PAIRED_SHARE of its instances, paired in the order they ended,
    have durations within SIGNPOST_ABSOLUTE_MS or SIGNPOST_RELATIVE
    (whichever is larger). The HUD reads its clock right before each
    os_signpost call, so an instance only disagrees when its thread was
    preempted between the two clock reads, which a heavily loaded host does
    now and then. Comparing every instance is stricter than comparing
    summary statistics, which a couple of preempted instances near the
    median can move;
  - the HUD's CPU % over the load (its CPU clock between the first and last
    Activity Monitor sample of the test process) is within CPU_POINTS
    percentage points or CPU_RELATIVE of Activity Monitor's ("CPU Time"
    over the same samples). Activity Monitor's samples land up to about a
    second after the CPU time they report, so the per-window table is
    printed for information only;
  - the HUD's mean footprint is within MEMORY_RELATIVE (or MEMORY_ABSOLUTE)
    of Activity Monitor's "Memory" for the same process.
"""

import json
import statistics
import sys
import xml.etree.ElementTree as ET

SUBSYSTEM = "com.joeblau.blau"
LOAD_INTERVAL = "hud.compare.load"
SAMPLE_INTERVAL = "hud.compare.sample"

SIGNPOST_ABSOLUTE_MS = 0.05
SIGNPOST_RELATIVE = 0.01
PAIRED_SHARE = 0.85
CPU_POINTS = 2.0
CPU_RELATIVE = 0.15
MEMORY_RELATIVE = 0.03
MEMORY_ABSOLUTE = 4 * 1024 * 1024


def rows(path):
    """Yields each row as {mnemonic: (raw text, formatted text)}.

    xctrace writes each distinct value once with an id and refers back to it
    with ref=, so ids are resolved while walking the rows in document order.
    """
    values = {}
    columns = []

    def register(element):
        for child in element.iter():
            identifier = child.get("id")
            if identifier is not None and identifier not in values:
                values[identifier] = (child.text, child.get("fmt", child.text), child)

    def value_of(element):
        ref = element.get("ref")
        if ref is not None:
            raw, fmt, original = values.get(ref, (None, None, None))
            return raw, fmt, original
        return element.text, element.get("fmt", element.text), element

    for _, element in ET.iterparse(path, events=("end",)):
        if element.tag == "mnemonic" and element.text:
            columns.append(element.text)
            continue
        if element.tag != "row":
            continue
        register(element)
        row = {}
        for column, child in zip(columns, list(element)):
            raw, fmt, original = value_of(child)
            row[column] = (raw, fmt, original)
        yield row
        element.clear()


def nested_pid(cell):
    """The pid inside a `process` cell (`<process><pid fmt="123">123</pid>`)."""
    if cell is None:
        return None
    _, fmt, original = cell
    if original is not None:
        pid = original.find("pid")
        if pid is not None:
            return int(pid.get("fmt", pid.text))
    if fmt and "(" in fmt and fmt.endswith(")"):
        try:
            return int(fmt.rsplit("(", 1)[1][:-1])
        except ValueError:
            return None
    return None


def number(cell):
    if cell is None or cell[0] is None:
        return None
    try:
        return float(cell[0])
    except ValueError:
        return None


def percentile(fraction, ordered):
    """Linear interpolation between the closest ranks (LatencySummary's)."""
    rank = fraction * (len(ordered) - 1)
    lower = int(rank)
    upper = min(lower + 1, len(ordered) - 1)
    weight = rank - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * weight


def close(hud, trace):
    return abs(hud - trace) <= max(SIGNPOST_ABSOLUTE_MS, SIGNPOST_RELATIVE * abs(trace))


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    hud = json.load(open(argv[1]))
    pid = hud["pid"]
    failures = []

    # Signposts: the HUD's statistics against the trace's durations.
    durations = {}
    load_span = None
    sample_starts = []
    for row in rows(argv[2]):
        if row.get("subsystem", (None, None, None))[1] != SUBSYSTEM:
            continue
        process_pid = nested_pid(row.get("process"))
        if process_pid is not None and process_pid != pid:
            continue
        name = row.get("name", row.get("signpost-name", (None, None, None)))[1]
        start, duration = number(row.get("start")), number(row.get("duration"))
        if name is None or duration is None:
            continue
        if name == LOAD_INTERVAL:
            load_span = (start, start + duration)
            continue
        if name == SAMPLE_INTERVAL:
            # The clock was read inside the marker; take its midpoint.
            sample_starts.append(start + duration / 2)
            continue
        durations.setdefault(name, []).append((start + duration, duration / 1e6))

    print(
        f"\n{'interval':<22} {'n hud/trace':>12}  {'p50 ms hud/trace':>18}  {'p95 ms hud/trace':>18}"
        f"  {'paired within':>13}  {'worst':>8}"
    )
    for name, stats in sorted(hud["intervals"].items()):
        ended = [duration for _, duration in sorted(durations.get(name, []))]
        if not ended:
            failures.append(f"{name}: not in the trace")
            continue
        samples = sorted(ended)
        trace = {
            "count": len(samples),
            "mean": statistics.fmean(samples),
            "p50": percentile(0.5, samples),
            "p95": percentile(0.95, samples),
            "maximum": samples[-1],
        }
        # Pair each HUD sample with the trace interval that ended in the same
        # order: the same span, measured twice.
        pairs = list(zip(stats["samples"], ended))
        agreeing = sum(1 for hud_ms, trace_ms in pairs if close(hud_ms, trace_ms))
        worst = max((abs(hud_ms - trace_ms) for hud_ms, trace_ms in pairs), default=0)
        share = agreeing / len(pairs) if pairs else 0
        print(
            f"{name:<22} {stats['count']:>5}/{trace['count']:<6}  "
            f"{stats['p50']:>8.3f}/{trace['p50']:<9.3f}  {stats['p95']:>8.3f}/{trace['p95']:<9.3f}"
            f"  {agreeing:>5}/{len(pairs):<4} {share:>4.0%}  {worst:>6.2f} ms"
        )
        if stats["count"] != trace["count"]:
            failures.append(f"{name}: {stats['count']} intervals in the HUD, {trace['count']} in Instruments")
        if share < PAIRED_SHARE:
            failures.append(f"{name}: only {share:.0%} of the paired durations agree")

    # CPU and memory: Activity Monitor's samples of this process inside the
    # load. Activity Monitor reports the process's cumulative CPU time
    # ("CPU Time") and footprint per row. The HUD's clock was read inside
    # each hud.compare.sample interval, so both series sit on the trace's
    # timeline: the HUD's CPU time is interpolated at Activity Monitor's row
    # starts and the CPU % over the load is compared.
    if load_span is None or len(sample_starts) < 2:
        failures.append(f"{LOAD_INTERVAL} or its {SAMPLE_INTERVAL} markers are not in the trace")
    else:
        hud_times = list(zip(sorted(sample_starts), hud["cpuTimes"]))
        if len(sample_starts) != len(hud["cpuTimes"]):
            failures.append(
                f"{len(sample_starts)} {SAMPLE_INTERVAL} markers in the trace, {len(hud['cpuTimes'])} HUD readings"
            )

        def hud_cpu_at(time):
            for (t0, c0), (t1, c1) in zip(hud_times, hud_times[1:]):
                if t0 <= time <= t1:
                    return c0 + (c1 - c0) * (time - t0) / (t1 - t0)
            return None

        samples, memory = [], []
        for row in rows(argv[3]):
            row_pid = number(row.get("pid"))
            if row_pid is None or int(row_pid) != pid:
                continue
            start = number(row.get("start"))
            total = number(row.get("cpu-total"))
            footprint = number(row.get("memory-physical-footprint"))
            if start is None or not (load_span[0] + 1e9 <= start <= load_span[1]):
                continue
            hud_total = hud_cpu_at(start)
            if total is not None and hud_total is not None:
                samples.append((start, total, hud_total))
            if footprint is not None:
                memory.append(footprint)

        if len(samples) < 3 or not memory:
            failures.append("Activity Monitor has too few samples of the test process during the load")
        else:
            print(f"\n{'window':<20} {'CPU % HUD':>10} {'Instruments':>12}")
            for (t0, i0, h0), (t1, i1, h1) in zip(samples, samples[1:]):
                span = t1 - t0
                hud_percent = (h1 - h0) / span * 100
                trace_percent = (i1 - i0) / span * 100
                print(f"{t0 / 1e9:7.2f}-{t1 / 1e9:7.2f} s  {hud_percent:10.1f} {trace_percent:12.1f}")
            (t0, i0, h0), (t1, i1, h1) = samples[0], samples[-1]
            hud_overall = (h1 - h0) / (t1 - t0) * 100
            trace_overall = (i1 - i0) / (t1 - t0) * 100
            print(f"{'whole load':<20} {hud_overall:10.1f} {trace_overall:12.1f}")
            if abs(hud_overall - trace_overall) > max(CPU_POINTS, CPU_RELATIVE * trace_overall):
                failures.append(f"CPU over the load: {hud_overall:.1f}% in the HUD, {trace_overall:.1f}% in Instruments")

            hud_memory = statistics.fmean(hud["footprintBytes"])
            trace_memory = statistics.fmean(memory)
            print(
                f"\nFootprint  HUD {hud_memory / 1048576:6.1f} MB  Instruments {trace_memory / 1048576:6.1f} MB"
                f"  ({len(hud['footprintBytes'])} / {len(memory)} samples)"
            )
            if abs(hud_memory - trace_memory) > max(MEMORY_ABSOLUTE, MEMORY_RELATIVE * trace_memory):
                failures.append(
                    f"Memory: {hud_memory / 1048576:.1f} MB in the HUD, {trace_memory / 1048576:.1f} MB in Instruments"
                )

    if failures:
        print("\nFAILED:\n  " + "\n  ".join(failures), file=sys.stderr)
        return 1
    print(f"\nOK: {len(hud['intervals'])} intervals, CPU and memory match Instruments within tolerance.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
