#!/usr/bin/env bash
#
# Checks that BlauTelemetry's canonical signpost intervals reach Instruments.
#
# Records an os_signpost trace (the same instrument Instruments shows under
# "os_signpost") while the opt-in SignpostSmokeTests suite emits every
# interval through the real OSSignposter backend, exports the trace's paired
# intervals table, and checks that every interval listed in
# docs/performance.md appears under the `com.joeblau.blau` subsystem with the
# documented category.
#
# Usage:
#   scripts/verify-signposts.sh [--keep]
#
#   --keep   Keep the .trace bundle and exports (printed at the end) so you
#            can open the trace in Instruments.
#
# Runs on the macOS host: BlauTelemetry uses the same os_signpost machinery
# on macOS and iOS. Requires Xcode (xctrace) and python3.

set -euo pipefail

keep=0
[[ "${1:-}" == "--keep" ]] && keep=1

root="$(git rev-parse --show-toplevel)"
kit="$root/Packages/BlauKit"
doc="$root/docs/performance.md"
work="$(mktemp -d "${TMPDIR:-/tmp}/blau-signposts.XXXXXX")"
trace="$work/signposts.trace"
xml="$work/intervals.xml"
log="$work/xctrace.log"
xctrace_pid=""

cleanup() {
    if [[ -n "$xctrace_pid" ]] && kill -0 "$xctrace_pid" 2>/dev/null; then
        kill -INT "$xctrace_pid" 2>/dev/null || true
        wait "$xctrace_pid" 2>/dev/null || true
    fi
    if [[ $keep -eq 0 ]]; then
        rm -rf "$work"
    fi
}
trap cleanup EXIT

echo "==> Building BlauKit tests"
(cd "$kit" && swift build --build-tests >/dev/null)

echo "==> Recording os_signpost trace"
xcrun xctrace record --instrument os_signpost --all-processes --time-limit 300s \
    --output "$trace" >"$log" 2>&1 &
xctrace_pid=$!
for _ in $(seq 1 120); do
    grep -q "Ctrl-C to stop" "$log" 2>/dev/null && break
    kill -0 "$xctrace_pid" 2>/dev/null || { cat "$log" >&2; exit 1; }
    sleep 0.5
done
grep -q "Ctrl-C to stop" "$log" || { echo "xctrace did not start recording" >&2; cat "$log" >&2; exit 1; }
sleep 2

echo "==> Emitting every canonical interval (SignpostSmokeTests)"
(cd "$kit" && BLAU_SIGNPOST_SMOKE=1 swift test --skip-build --filter SignpostSmokeTests 2>&1 | tail -n 3)
sleep 2

echo "==> Stopping and saving the trace (this can take a minute)"
kill -INT "$xctrace_pid"
wait "$xctrace_pid" || true
xctrace_pid=""
grep -q "Output file saved" "$log" || { echo "xctrace did not save the trace" >&2; cat "$log" >&2; exit 1; }

echo "==> Exporting the os_signpost intervals table"
xcrun xctrace export --input "$trace" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="OSSignpostIntervals"]' >"$xml"

python3 -I - "$xml" "$doc" <<'PY'
import collections
import re
import sys
import xml.etree.ElementTree as ET

xml_path, doc_path = sys.argv[1], sys.argv[2]
SUBSYSTEM = "com.joeblau.blau"

# Expected intervals: the "Canonical intervals" table in docs/performance.md
# (a unit test keeps it in sync with PipelineInterval).
expected = {}
in_section = False
for line in open(doc_path, encoding="utf-8"):
    if line.startswith("## "):
        in_section = line.startswith("## Canonical intervals")
        continue
    if in_section and line.startswith("| `"):
        cells = [c.strip().strip("`") for c in line.strip().strip("|").split("|")]
        expected[cells[0]] = cells[1]
if not expected:
    sys.exit("No canonical intervals found in docs/performance.md")

# xctrace writes each distinct value once with an id and refers back to it
# with ref=, so resolve refs while walking the rows in document order.
values = {}
def text_of(element):
    if element is None:
        return None
    ref = element.get("ref")
    if ref is not None:
        return values.get(ref)
    value = element.get("fmt", element.text)
    if element.get("id") is not None:
        values[element.get("id")] = value
    return value

found = collections.defaultdict(list)
for _, element in ET.iterparse(xml_path, events=("end",)):
    if element.tag != "row":
        # Register ids on leaf values as they stream past.
        if element.get("id") is not None and element.get("id") not in values:
            values[element.get("id")] = element.get("fmt", element.text)
        continue
    name = text_of(element.find("signpost-name"))
    category = text_of(element.find("category"))
    subsystem = text_of(element.find("subsystem"))
    duration = element.find("duration")
    if subsystem == SUBSYSTEM:
        found[name].append((category, text_of(duration)))

print(f"\n{'interval':<22} {'category':<10} {'count':>5}  example duration")
failures = []
for name, category in expected.items():
    rows = found.get(name, [])
    categories = {c for c, _ in rows}
    example = rows[0][1] if rows else "-"
    print(f"{name:<22} {category:<10} {len(rows):>5}  {example}")
    if not rows:
        failures.append(f"{name}: no intervals in the trace")
    elif categories != {category}:
        failures.append(f"{name}: categories {sorted(categories)}, expected {category}")

if failures:
    print("\nFAILED:\n  " + "\n  ".join(failures), file=sys.stderr)
    sys.exit(1)
print(f"\nOK: all {len(expected)} canonical intervals recorded under {SUBSYSTEM}.")
PY

if [[ $keep -eq 1 ]]; then
    echo "Trace kept at $trace (open it with: open '$trace')"
fi
