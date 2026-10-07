#!/usr/bin/env bash
#
# Checks that the debug performance HUD's numbers match Instruments (#71).
#
# Starts the opt-in PerformanceHUDInstrumentsComparison suite, attaches the
# os_signpost and Activity Monitor instruments to its process, and lets it
# run a known workload with the HUD's sampler and signpost tap active. Then
# it compares:
#
#   - every timed interval's count, mean, p50, p95 and max with the same
#     statistics of that interval's durations in Instruments' os_signpost
#     table, and
#   - the HUD's CPU % and memory footprint during a steady load with
#     Activity Monitor's "% CPU" and "Memory" for the same process.
#
# Tolerances are in scripts/lib/hud_compare.py. The signpost path, the CPU
# clock and the footprint are the same on macOS and iOS, so the Mac run
# checks the HUD's arithmetic; on-device numbers are in docs/performance.md.
#
# Usage:
#   scripts/verify-hud.sh [--keep]
#
#   --keep   Keep the .trace bundle, the exports and the HUD's JSON
#            (printed at the end) so you can open the trace in Instruments.
#
# Requires Xcode (xctrace) and python3.

set -euo pipefail

keep=0
[[ "${1:-}" == "--keep" ]] && keep=1

root="$(git rev-parse --show-toplevel)"
kit="$root/Packages/BlauKit"
work="$(mktemp -d "${TMPDIR:-/tmp}/blau-hud.XXXXXX")"
trace="$work/hud.trace"
intervals="$work/intervals.xml"
activity="$work/activity.xml"
hud="$work/hud.json"
log="$work/xctrace.log"
xctrace_pid=""
test_pid=""
target=""

# Stops a recording and a workload left over from a failed attempt, so a
# retry doesn't wait on SwiftPM's lock or attach to the old process.
stop_attempt() {
    if [[ -n "$xctrace_pid" ]] && kill -0 "$xctrace_pid" 2>/dev/null; then
        kill -INT "$xctrace_pid" 2>/dev/null || true
        wait "$xctrace_pid" 2>/dev/null || true
    fi
    xctrace_pid=""
    if [[ -n "$target" ]]; then
        kill "$target" 2>/dev/null || true
    fi
    target=""
    if [[ -n "$test_pid" ]] && kill -0 "$test_pid" 2>/dev/null; then
        pkill -P "$test_pid" 2>/dev/null || true
        kill "$test_pid" 2>/dev/null || true
        wait "$test_pid" 2>/dev/null || true
    fi
    test_pid=""
}

cleanup() {
    stop_attempt
    if [[ $keep -eq 0 ]]; then
        rm -rf "$work"
    fi
}
trap cleanup EXIT

echo "==> Building BlauKit tests"
(cd "$kit" && swift build --build-tests >/dev/null)

# Runs the workload once with Instruments attached and exports both tables.
# Returns non-zero if any step fails.
record() {
    rm -rf "$trace" "$work/pid" "$work/go" "$hud" "$intervals" "$activity"
    echo "==> Starting the HUD workload (PerformanceHUDInstrumentsComparison)"
    (cd "$kit" && BLAU_HUD_COMPARE=1 BLAU_HUD_COMPARE_OUT="$hud" \
        BLAU_HUD_COMPARE_READY="$work/pid" BLAU_HUD_COMPARE_GO="$work/go" \
        swift test --skip-build --filter PerformanceHUDInstrumentsComparison >"$work/test.log" 2>&1) &
    test_pid=$!
    for _ in $(seq 1 240); do
        [[ -s "$work/pid" ]] && break
        kill -0 "$test_pid" 2>/dev/null || { cat "$work/test.log" >&2; return 1; }
        sleep 0.5
    done
    [[ -s "$work/pid" ]] || { echo "The workload did not start" >&2; cat "$work/test.log" >&2; return 1; }
    target="$(cat "$work/pid")"

    # Attached to the test process only: an all-processes recording of
    # Activity Monitor takes many minutes to save on a busy machine.
    echo "==> Recording os_signpost and Activity Monitor (pid $target)"
    xcrun xctrace record --instrument os_signpost --instrument "Activity Monitor" --attach "$target" \
        --time-limit 300s --output "$trace" >"$log" 2>&1 &
    xctrace_pid=$!
    # Starting can take minutes on a heavily loaded host.
    for _ in $(seq 1 600); do
        grep -q "Ctrl-C to stop" "$log" 2>/dev/null && break
        kill -0 "$xctrace_pid" 2>/dev/null || { cat "$log" >&2; return 1; }
        sleep 0.5
    done
    grep -q "Ctrl-C to stop" "$log" || { echo "xctrace did not start recording" >&2; cat "$log" >&2; return 1; }
    sleep 2
    touch "$work/go"

    if ! wait "$test_pid"; then
        echo "The workload failed" >&2
        cat "$work/test.log" >&2
        return 1
    fi
    tail -n 3 "$work/test.log"

    echo "==> Saving the trace"
    # The recording ends with the process it is attached to; stop it if it
    # hasn't noticed within ten seconds.
    for _ in $(seq 1 20); do
        kill -0 "$xctrace_pid" 2>/dev/null || break
        grep -qE "Stopping recording|Recording completed|Output file saved" "$log" && break
        sleep 0.5
    done
    if kill -0 "$xctrace_pid" 2>/dev/null && ! grep -qE "Stopping recording|Recording completed|Output file saved" "$log"; then
        kill -INT "$xctrace_pid" 2>/dev/null || true
    fi
    wait "$xctrace_pid" || true
    xctrace_pid=""
    test_pid=""
    target=""
    grep -q "Output file saved" "$log" || { echo "xctrace did not save the trace" >&2; cat "$log" >&2; return 1; }
    [[ -s "$hud" ]] || { echo "The workload wrote no HUD readings" >&2; return 1; }

    echo "==> Exporting the os_signpost and Activity Monitor tables"
    xcrun xctrace export --input "$trace" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="OSSignpostIntervals"]' >"$intervals"
    xcrun xctrace export --input "$trace" \
        --xpath '/trace-toc/run[@number="1"]/data/table[@schema="activity-monitor-process-live"]' >"$activity"
}

# The Xcode 27.2 beta's xctrace sometimes attaches without recording the
# os_signpost table; record once more when that happens.
recorded=0
for attempt in 1 2; do
    if record && grep -q "com.joeblau.blau" "$intervals"; then
        recorded=1
        break
    fi
    echo "==> The trace has no Blau signposts (attempt $attempt)" >&2
    stop_attempt
done
[[ $recorded -eq 1 ]] || { echo "Could not record the workload" >&2; exit 1; }

python3 -I "$root/scripts/lib/hud_compare.py" "$hud" "$intervals" "$activity"

if [[ $keep -eq 1 ]]; then
    echo "Trace kept at $trace (open it with: open '$trace'); HUD readings in $hud"
fi
