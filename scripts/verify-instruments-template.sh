#!/usr/bin/env bash
#
# Checks that Tools/Instruments/Blau.tracetemplate opens and captures every
# Blau interval.
#
# Records a trace on the Mac with the template while the opt-in
# SignpostSmokeTests suite (BLAU_SIGNPOST_SMOKE=1) emits every canonical
# interval through BlauTelemetry's real OSSignposter, then checks:
#
#   1. xctrace loaded the template and the run used every instrument in
#      Tools/Instruments/instruments.txt, with no run errors.
#   2. os_signpost had dynamic tracing on for com.joeblau.blau.
#   3. Every interval in the "Canonical intervals" table of
#      docs/performance.md was captured under com.joeblau.blau with its
#      documented category.
#
# The template targets one process (Allocations can't record "All
# Processes"). On a Mac there is no Blau app process, so the script launches
# a stand-in (scripts/lib/trace-target.c) as the target, and, for this
# recording only, sets os_signpost's "record all processes in single process
# mode" option so it also picks up the signposts from the `swift test`
# process. Everything else comes from the template as committed.
#
# Usage:
#   scripts/verify-instruments-template.sh [--keep] [template]
#
#   --keep     Keep the .trace bundle and exports (printed at the end) so you
#              can open the trace in Instruments.
#   template   Defaults to Tools/Instruments/Blau.tracetemplate.
#
# Runs on the macOS host. Requires Xcode (xctrace, clang) and python3.

set -euo pipefail

keep=0
if [[ "${1:-}" == "--keep" ]]; then
    keep=1
    shift
fi

root="$(git rev-parse --show-toplevel)"
kit="$root/Packages/BlauKit"
doc="$root/docs/performance.md"
lib="$root/scripts/lib"
instruments="$root/Tools/Instruments/instruments.txt"
template="${1:-$root/Tools/Instruments/Blau.tracetemplate}"
template_name="$(basename "$template" .tracetemplate)"

work="$(mktemp -d "${TMPDIR:-/tmp}/blau-template-check.XXXXXX")"
trace="$work/blau.trace"
log="$work/xctrace.log"
sentinel="$work/done"
xctrace_pid=""

cleanup() {
    touch "$sentinel"
    if [[ -n "$xctrace_pid" ]] && kill -0 "$xctrace_pid" 2>/dev/null; then
        kill -INT "$xctrace_pid" 2>/dev/null || true
        wait "$xctrace_pid" 2>/dev/null || true
    fi
    if [[ $keep -eq 0 ]]; then
        rm -rf "$work"
    fi
}
trap cleanup EXIT

[[ -f "$template" ]] || { echo "No template at $template" >&2; exit 1; }

echo "==> Checking the template's instruments"
python3 -I "$lib/tracetemplate.py" check-instruments "$template" "$instruments"

echo "==> Building BlauKit tests and the stand-in target"
(cd "$kit" && swift build --build-tests >/dev/null)
xcrun clang -O2 -o "$work/trace-target" "$lib/trace-target.c"
codesign --force --sign - --entitlements "$lib/trace-target.entitlements" "$work/trace-target" 2>/dev/null

# The committed recording options plus "record all processes" for the two
# logging instruments, so the smoke test's process is recorded too.
python3 -I - "$root/Tools/Instruments/recording-options.json" "$work/recording-options.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    options = json.load(handle)
for instrument in ("os_signpost", "os_log"):
    options.setdefault(instrument, {})["recordAllProcessesInSingleProcessMode"] = True
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(options, handle, indent=2)
PY

# Records one trace with the template around the smoke test. Returns 1 when
# xctrace dies before saving: the Xcode 27.2 beta's xctrace occasionally
# crashes in its kernel-trace reader (ktraceDT) while stopping a recording,
# independent of the template, so the caller retries once.
record() {
    rm -rf "$trace" "$sentinel"
    echo "==> Recording with $template_name.tracetemplate"
    xcrun xctrace record --no-prompt --template "$template" \
        --recording-options "$work/recording-options.json" \
        --time-limit 600s --output "$trace" \
        --launch -- "$work/trace-target" "$sentinel" 600 >"$log" 2>&1 &
    xctrace_pid=$!
    for _ in $(seq 1 240); do
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
    touch "$sentinel"
    local status=0
    wait "$xctrace_pid" || status=$?
    xctrace_pid=""
    if ! grep -q "Output file saved" "$log"; then
        echo "xctrace exited with status $status without saving the trace:" >&2
        sed 's/^/    /' "$log" >&2
        return 1
    fi
}

record || { echo "==> Retrying the recording once" >&2; record; } \
    || { echo "xctrace did not save the trace" >&2; exit 1; }
if grep -q "\[Error\]" "$log"; then
    echo "The recording reported errors:" >&2
    grep -A1 "\[Error\]" "$log" >&2
    exit 1
fi

echo "==> Checking the recorded run"
python3 -I "$lib/tracetemplate.py" check-instruments "$trace/form.template" "$instruments"
xcrun xctrace export --input "$trace" --toc >"$work/toc.xml"
python3 -I "$lib/tracetemplate.py" check-toc "$work/toc.xml" "$template_name"

echo "==> Checking the captured intervals"
xcrun xctrace export --input "$trace" \
    --xpath '/trace-toc/run[@number="1"]/data/table[@schema="OSSignpostIntervals"]' >"$work/intervals.xml"
python3 -I "$lib/tracetemplate.py" check-intervals "$work/intervals.xml" "$doc"

if [[ $keep -eq 1 ]]; then
    echo "Trace kept at $trace (open it with: open '$trace')"
fi
