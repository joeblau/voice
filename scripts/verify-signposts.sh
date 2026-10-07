#!/usr/bin/env bash
#
# Checks that BlauTelemetry's canonical signpost intervals reach Instruments.
#
# Records an os_signpost trace (the same instrument Instruments shows under
# "os_signpost") while the opt-in SignpostSmokeTests suite emits every
# interval through the real OSSignposter backend, exports the trace's paired
# intervals table, and checks that every interval listed in
# docs/performance.md appears under the `com.joeblau.blau` subsystem with the
# documented category. It also checks that exactly the intervals in the
# "Intervals reported to MetricKit" table are emitted with mxSignpost (they
# show up under MetricKit's `com.apple.metrickit.log` subsystem).
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

python3 -I "$root/scripts/lib/tracetemplate.py" check-intervals --metrickit "$xml" "$doc"

if [[ $keep -eq 1 ]]; then
    echo "Trace kept at $trace (open it with: open '$trace')"
fi
