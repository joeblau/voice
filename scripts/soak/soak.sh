#!/usr/bin/env bash
#
# Runs the automated long-session soak test (#76, docs/soak.md): the
# BlauSoak test plan (BlauPerfTests/SoakTests) in Release with the BLAU_PERF
# condition, which plays SOAK_MINUTES of mixed audio through the app's
# pipeline against a local fake realtime server and judges memory growth,
# latency drift, dropped frames, session renewal and topic count. On a
# simulator it also reads the app's leaks with `leaks` every few minutes and
# once after the run, and fails if leaked memory grew.
#
# Usage: scripts/soak/soak.sh            (or `make soak`)
#
# Environment:
#   DESTINATION      xcodebuild destination (default: the newest "iPhone 17"
#                    simulator). A simulator by name is resolved to its UDID
#                    so the leaks readings find the app.
#   SOAK_MINUTES     Session length on the audio timeline (default 120).
#   SOAK_SPEED       A factor, `realtime` or `max` (default 10).
#   SOAK_ASR         `scripted` (default) or `parakeet` (a device with the
#                    models installed).
#   SOAK_ROLLOVER_MINUTES  Where the session renewal lands (default 60% of
#                    the session), or `xai` for xAI's real 110 minutes.
#   SOAK_OUTPUT      Where the results go (default .build/results/soak):
#                    soak.xcresult, xcodebuild.log, report.json, report.md,
#                    leaks.jsonl, leaks.json, leaks/*.txt and summary.md.
#   SOAK_LEAKS       1 to read leaks (default 1 on a simulator; a device
#                    needs Instruments, see docs/soak.md), 0 to skip.
#   SOAK_LEAKS_INTERVAL  Seconds between leak readings, the first one that
#                    long after the app starts (default a sixth of the run's
#                    expected wall time, 20 to 300 s).
#   SOAK_HOLD_SECONDS    How long the app stays open after the run for the
#                    last leak reading (default 90 with leaks, else 0).
#   DERIVED_DATA     DerivedData (default .build/DerivedData).
#   XCODEBUILD_FLAGS Extra xcodebuild arguments.
#
# Exit status: 0 when the soak passed and leaks didn't grow, 1 otherwise.

set -uo pipefail

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
cd "$repo" || exit 1

minutes="${SOAK_MINUTES:-120}"
speed="${SOAK_SPEED:-10}"
asr="${SOAK_ASR:-scripted}"
rollover="${SOAK_ROLLOVER_MINUTES:-}"
output="${SOAK_OUTPUT:-.build/results/soak}"
interval="${SOAK_LEAKS_INTERVAL:-}"
derived="${DERIVED_DATA:-.build/DerivedData}"
destination="${DESTINATION:-platform=iOS Simulator,name=iPhone 17,OS=latest}"
bundle_id="com.joeblau.blau"

log() { echo "soak: $*" >&2; }

# A simulator destination by name becomes `id=<udid>`, so xcodebuild and the
# leaks readings use the same device.
udid=""
if [[ "$destination" =~ (^|,)id=([0-9A-Fa-f-]+) ]]; then
    udid="${BASH_REMATCH[2]}"
    # Not a pipe into `grep -q`: with pipefail, grep quitting early can fail
    # the pipeline with SIGPIPE and turn a simulator into a device.
    simulators=$(xcrun simctl list devices -j 2>/dev/null)
    if ! grep -q "\"$udid\"" <<<"$simulators"; then
        udid="" # A physical device.
    fi
elif [[ "$destination" == *"iOS Simulator"* ]]; then
    name=$(sed -n 's/.*name=\([^,]*\).*/\1/p' <<<"$destination")
    udid=$(SIMULATOR_NAME="${name:-iPhone 17}" scripts/ci/simulator-destination.sh 2>/dev/null | sed -n 's/^id=//p')
    if [[ -z "$udid" ]]; then
        log "no simulator matches '$destination'"
        exit 1
    fi
    destination="id=$udid"
fi
is_simulator=0
[[ -n "$udid" ]] && is_simulator=1

leaks_enabled="${SOAK_LEAKS:-$is_simulator}"
if [[ "$leaks_enabled" == 1 && "$is_simulator" != 1 ]]; then
    log "leak readings need a simulator; on a device record the Leaks template in Instruments (docs/soak.md)"
    leaks_enabled=0
fi
if [[ -z "$interval" ]]; then
    interval=$(python3 -c '
import sys
minutes, speed = float(sys.argv[1]), sys.argv[2]
speed = {"realtime": 1.0, "max": 10.0}.get(speed) or float(speed)
print(int(min(300, max(20, minutes * 60 / speed / 6))))' "$minutes" "$speed")
fi
hold="${SOAK_HOLD_SECONDS:-}"
if [[ -z "$hold" ]]; then
    if [[ "$leaks_enabled" == 1 ]]; then hold=90; else hold=0; fi
fi

rm -rf "$output"
mkdir -p "$output/leaks"
result="$output/soak.xcresult"

log "$minutes min of audio at ${speed}x ($asr ASR) on $destination; results in $output"

runner_env=(
    "TEST_RUNNER_BLAU_SOAK_MINUTES=$minutes"
    "TEST_RUNNER_BLAU_SOAK_SPEED=$speed"
    "TEST_RUNNER_BLAU_SOAK_ASR=$asr"
    "TEST_RUNNER_BLAU_SOAK_HOLD_SECONDS=$hold"
)
[[ -n "$rollover" ]] && runner_env+=("TEST_RUNNER_BLAU_SOAK_ROLLOVER_MINUTES=$rollover")

signing=(CODE_SIGNING_ALLOWED=NO)
[[ "$is_simulator" != 1 ]] && signing=(-allowProvisioningUpdates)

# shellcheck disable=SC2086 # XCODEBUILD_FLAGS is a list of arguments.
env "${runner_env[@]}" xcodebuild test -project Blau.xcodeproj -scheme Blau-Perf -testPlan BlauSoak \
    -destination "$destination" -derivedDataPath "$derived" -resultBundlePath "$result" \
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) BLAU_PERF' ONLY_ACTIVE_ARCH=YES XAI_DEV_API_KEY= \
    "${signing[@]}" ${XCODEBUILD_FLAGS:-} >"$output/xcodebuild.log" 2>&1 &
xcodebuild_pid=$!
trap 'kill "$xcodebuild_pid" 2>/dev/null' INT TERM

started=$(date +%s)
elapsed() { echo $(($(date +%s) - started)); }

# The app's process on the soak's simulator.
app_pid() {
    ps -axo pid=,command= | awk -v device="CoreSimulator/Devices/$udid/" \
        'index($0, device) && $0 ~ /\/Blau\.app\/Blau( |$)/ { print $1; exit }'
}

# The directory holding this run's report, once the app has written it (a
# report from an earlier run, older than this script, doesn't count).
app_report() {
    local container report
    container=$(xcrun simctl get_app_container "$udid" "$bundle_id" data 2>/dev/null) || return 1
    report="$container/Documents/Soak/latest.json"
    [[ -f "$report" && $(stat -f %m "$report") -ge "$started" ]] || return 1
    echo "$container/Documents/Soak"
}

read_leaks() {
    local pid=$1 phase=$2 wall file
    wall=$(elapsed)
    file="$output/leaks/$(printf '%06d' "$wall")-$phase.txt"
    # `leaks` exits 1 when it finds leaks; the summary line is what counts.
    leaks "$pid" >"$file" 2>&1
    if scripts/soak/leaks-report.py parse --phase "$phase" --wall "$wall" --input "$file" >>"$output/leaks.jsonl"; then
        log "leaks ($phase, $((wall / 60)) min): $(tail -n 1 "$output/leaks.jsonl")"
    else
        log "couldn't read leaks ($phase): $(tail -n 3 "$file" | tr '\n' ' ')"
    fi
}

final_read=0
last_read=""
report_dir=""
while kill -0 "$xcodebuild_pid" 2>/dev/null; do
    sleep 5
    [[ "$is_simulator" == 1 ]] || continue
    if [[ -z "$report_dir" ]] && report_dir=$(app_report); then
        log "the run finished and saved its report"
    fi
    [[ "$leaks_enabled" == 1 ]] || continue
    pid=$(app_pid)
    [[ -n "$pid" ]] || continue
    # The first reading comes `interval` after the app appears, once the
    # soak is under way and start-up allocations are behind it.
    [[ -n "$last_read" ]] || last_read=$(elapsed)
    if [[ -n "$report_dir" && "$final_read" == 0 ]]; then
        # After the run, with its pipeline released: give the app a moment
        # to go idle, then take the reading that counts.
        sleep 10
        read_leaks "$pid" after-run
        final_read=1
    elif [[ -z "$report_dir" && $(($(elapsed) - last_read)) -ge "$interval" ]]; then
        read_leaks "$pid" during-run
        last_read=$(elapsed)
    fi
done
wait "$xcodebuild_pid"
test_status=$?
log "xcodebuild finished with status $test_status after $(($(elapsed) / 60)) min"

# The report: from the simulator's container, or from the test's
# attachments (a device).
if [[ -z "$report_dir" && "$is_simulator" == 1 ]]; then
    report_dir=$(app_report) || report_dir=""
fi
if [[ -n "$report_dir" ]]; then
    cp "$report_dir/latest.json" "$output/report.json"
    cp "$report_dir/latest.md" "$output/report.md" 2>/dev/null || true
elif [[ -d "$result" ]]; then
    attachments="$output/attachments"
    if xcrun xcresulttool export attachments --path "$result" --output-path "$attachments" >/dev/null 2>&1; then
        json=$(grep -l '"checks"' "$attachments"/* 2>/dev/null | head -n 1)
        [[ -n "$json" ]] && cp "$json" "$output/report.json"
        md=$(grep -l '^## Long-session soak' "$attachments"/* 2>/dev/null | head -n 1)
        [[ -n "$md" ]] && cp "$md" "$output/report.md"
    fi
fi

{
    if [[ -f "$output/report.md" ]]; then
        cat "$output/report.md"
    else
        echo "## Long-session soak: no report"
        echo
        echo "The run didn't produce a report; see xcodebuild.log in the artifact."
    fi
    echo
} >"$output/summary.md"

leaks_status=0
if [[ "$leaks_enabled" == 1 ]]; then
    scripts/soak/leaks-report.py evaluate --readings "$output/leaks.jsonl" --json "$output/leaks.json" \
        --markdown "$output/leaks.md" >/dev/null
    leaks_status=$?
    cat "$output/leaks.md" >>"$output/summary.md"
    if [[ "$leaks_status" != 0 ]]; then
        log "leaks: $(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["reason"])' "$output/leaks.json")"
    fi
fi

cat "$output/summary.md"
if [[ "$test_status" != 0 ]]; then
    log "FAILED: the soak test failed (see $output/report.md and $output/xcodebuild.log)"
    exit 1
fi
if [[ "$leaks_status" != 0 ]]; then
    log "FAILED: leaked memory grew over the run (see $output/leaks.md)"
    exit 1
fi
log "passed"
