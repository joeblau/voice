#!/bin/sh
# Tests for scripts/perf/perf-gate.py (the XCTest performance suite's
# regression gate) and the exit-code handling of scripts/perf/microbench.sh.
# Hermetic: recorded xcresulttool output and fake results in a temporary
# directory, and a stand-in `swift` on PATH; never runs xcodebuild, a
# simulator or the benchmarks. Run with `make test-scripts`.

set -u

scripts_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
gate="$scripts_dir/perf/perf-gate.py"
microbench="$scripts_dir/perf/microbench.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/blau-perf-gate-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT

passed=0
failed=0

pass() { passed=$((passed + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

# expect <description> <expected exit status> <command...>
expect() {
    description=$1
    expected_status=$2
    shift 2
    "$@" >"$work/out" 2>"$work/err"
    actual=$?
    if [ "$actual" -eq "$expected_status" ]; then
        pass "$description"
    else
        fail "$description (exit $actual, expected $expected_status)"
        sed 's/^/       /' "$work/out" "$work/err"
    fi
}

# expect_output <description> <text the last command's stdout must contain>
expect_output() {
    if grep -qF -- "$2" "$work/out"; then
        pass "$1"
    else
        fail "$1 (no '$2' in the output)"
        sed 's/^/       /' "$work/out"
    fi
}

# --- extract --------------------------------------------------------------------

# The shape `xcrun xcresulttool get test-results metrics` prints (Xcode 27),
# with two repetitions of one test pooled.
cat >"$work/xcresulttool.json" <<'EOF'
[
  {
    "testIdentifier": "ReplaySessionPerformanceTests/testScriptedSession()",
    "testRuns": [
      {
        "device": {"deviceId": "A", "deviceName": "iPhone 17"},
        "metrics": [
          {"displayName": "CPU Time", "identifier": "com.apple.dt.XCTMetric_CPU.time",
           "measurements": [10.0, 11.0, 12.0], "polarity": "prefers smaller", "unitOfMeasurement": "s"},
          {"displayName": "Throughput", "identifier": "throughput",
           "measurements": [100.0, 100.0], "polarity": "prefers larger", "unitOfMeasurement": "/s"}
        ]
      },
      {
        "device": {"deviceId": "A", "deviceName": "iPhone 17"},
        "metrics": [
          {"displayName": "CPU Time", "identifier": "com.apple.dt.XCTMetric_CPU.time",
           "measurements": [13.0], "polarity": "prefers smaller", "unitOfMeasurement": "s"}
        ]
      }
    ]
  },
  {"testIdentifier": "LaunchPerformanceTests/testColdLaunch()", "testRuns": [{"metrics": []}]}
]
EOF
expect "extract normalizes xcresulttool output" 0 \
    python3 -I "$gate" extract --xcresulttool-json "$work/xcresulttool.json" --output "$work/results.json"
if python3 -I -c '
import json, sys
results = json.load(open(sys.argv[1]))
cpu = results["tests"]["ReplaySessionPerformanceTests/testScriptedSession()"]["com.apple.dt.XCTMetric_CPU.time"]
assert cpu["values"] == [10.0, 11.0, 12.0, 13.0], cpu
assert cpu["unit"] == "s" and cpu["polarity"] == "prefers smaller"
assert results["devices"] == ["iPhone 17"]
assert "LaunchPerformanceTests/testColdLaunch()" not in results["tests"]
' "$work/results.json"; then
    pass "extract pools repetitions and drops tests without metrics"
else
    fail "extract pools repetitions and drops tests without metrics"
fi
expect "extract fails cleanly on a missing bundle" 2 \
    python3 -I "$gate" extract --xcresult "$work/missing.xcresult"

# --- record ---------------------------------------------------------------------

expect "record writes a baseline" 0 \
    python3 -I "$gate" record --results "$work/results.json" --baseline "$work/baseline.json" --environment ci-simulator
if python3 -I -c '
import json, sys
baseline = json.load(open(sys.argv[1]))
assert baseline["environment"] == "ci-simulator"
assert baseline["statistic"] == "median"
assert baseline["defaultTolerancePercent"] == 10.0
cpu = baseline["tests"]["ReplaySessionPerformanceTests/testScriptedSession()"]["com.apple.dt.XCTMetric_CPU.time"]
assert cpu["baseline"] == 11.5, cpu
' "$work/baseline.json"; then
    pass "record stores the median of every metric"
else
    fail "record stores the median of every metric"
fi

# results <cpu seconds...> [throughput]: results with one CPU metric and an
# optional throughput.
results() {
    python3 -I -c '
import json, sys
cpu = [float(value) for value in sys.argv[2].split(",")]
tests = {"com.apple.dt.XCTMetric_CPU.time": {"name": "CPU Time", "unit": "s", "polarity": "prefers smaller", "values": cpu}}
if len(sys.argv) > 3:
    tests["throughput"] = {"name": "Throughput", "unit": "/s", "polarity": "prefers larger", "values": [float(sys.argv[3])]}
json.dump({"devices": ["iPhone 17"], "tests": {"ReplaySessionPerformanceTests/testScriptedSession()": tests}}, open(sys.argv[1], "w"))
' "$@"
}

# --- check ----------------------------------------------------------------------

results "$work/same.json" 11.5 100
expect "check passes on the baseline itself" 0 \
    python3 -I "$gate" check --results "$work/same.json" --baseline "$work/baseline.json" --report "$work/report.md"
expect_output "check prints a Markdown table" "| ok | \`ReplaySessionPerformanceTests/testScriptedSession()\` | CPU Time |"
if [ -s "$work/report.md" ]; then pass "check writes the report file"; else fail "check writes the report file"; fi

results "$work/slower5.json" 12.0,12.1,12.2 100
expect "a 5% regression is within the 10% tolerance" 0 \
    python3 -I "$gate" check --results "$work/slower5.json" --baseline "$work/baseline.json"

results "$work/slower15.json" 13.0,13.2,13.4 100
expect "a 15% regression fails the gate" 1 \
    python3 -I "$gate" check --results "$work/slower15.json" --baseline "$work/baseline.json"
expect_output "the regression is named in the report" "| **REGRESSED** |"

results "$work/faster.json" 5.0 100
expect "an improvement passes" 0 \
    python3 -I "$gate" check --results "$work/faster.json" --baseline "$work/baseline.json"

results "$work/lower-throughput.json" 11.5 80
expect "a drop in a prefers-larger metric fails" 1 \
    python3 -I "$gate" check --results "$work/lower-throughput.json" --baseline "$work/baseline.json"

results "$work/missing-metric.json" 11.5
expect "a baselined metric that wasn't measured fails" 1 \
    python3 -I "$gate" check --results "$work/missing-metric.json" --baseline "$work/baseline.json"
expect_output "the missing metric is named" "| **NOT MEASURED** |"

expect "a missing baseline is an input error" 2 \
    python3 -I "$gate" check --results "$work/same.json" --baseline "$work/no-baseline.json"

# Per-metric tolerance and minimum delta, kept when re-recording.
python3 -I -c '
import json, sys
path = sys.argv[1]
baseline = json.load(open(path))
cpu = baseline["tests"]["ReplaySessionPerformanceTests/testScriptedSession()"]["com.apple.dt.XCTMetric_CPU.time"]
cpu["tolerancePercent"] = 20
cpu["note"] = "noisy on the simulator"
json.dump(baseline, open(path, "w"))
' "$work/baseline.json"
expect "a per-metric tolerance overrides the default" 0 \
    python3 -I "$gate" check --results "$work/slower15.json" --baseline "$work/baseline.json"
expect "record keeps per-metric tolerances" 0 \
    python3 -I "$gate" record --results "$work/slower15.json" --baseline "$work/baseline.json"
if python3 -I -c '
import json, sys
cpu = json.load(open(sys.argv[1]))["tests"]["ReplaySessionPerformanceTests/testScriptedSession()"]["com.apple.dt.XCTMetric_CPU.time"]
assert cpu["tolerancePercent"] == 20 and cpu["note"] == "noisy on the simulator" and cpu["baseline"] == 13.2, cpu
' "$work/baseline.json"; then
    pass "re-recording updates the value and keeps the overrides"
else
    fail "re-recording updates the value and keeps the overrides"
fi

python3 -I -c '
import json, sys
path = sys.argv[1]
baseline = json.load(open(path))
cpu = baseline["tests"]["ReplaySessionPerformanceTests/testScriptedSession()"]["com.apple.dt.XCTMetric_CPU.time"]
cpu["baseline"] = 0.010
cpu["tolerancePercent"] = 10
cpu["minimumDelta"] = 0.005
json.dump(baseline, open(path, "w"))
' "$work/baseline.json"
results "$work/tiny.json" 0.013 100
expect "a change below the minimum delta is ignored" 0 \
    python3 -I "$gate" check --results "$work/tiny.json" --baseline "$work/baseline.json"
results "$work/tiny-big.json" 0.020 100
expect "a change above the minimum delta still fails" 1 \
    python3 -I "$gate" check --results "$work/tiny-big.json" --baseline "$work/baseline.json"

# --- microbench.sh exit codes -----------------------------------------------------

# A stand-in `swift` that exits with $FAKE_SWIFT_STATUS, as package-benchmark
# does: 0 equal, 2 regression, 4 improvement.
mkdir -p "$work/bin"
cat >"$work/bin/swift" <<'EOF'
#!/bin/sh
echo "fake swift $*"
exit "${FAKE_SWIFT_STATUS:-0}"
EOF
chmod +x "$work/bin/swift"

microbench_check() {
    PATH="$work/bin:$PATH" FAKE_SWIFT_STATUS=$1 MICROBENCH_OUTPUT="$work/microbench.txt" "$microbench" check
}
expect "microbench check passes when equal to the thresholds" 0 microbench_check 0
expect_output "microbench check runs package-benchmark's thresholds check" "benchmark thresholds check --path Thresholds"
expect "microbench check fails on a regression" 1 microbench_check 2
expect "microbench check passes on an improvement" 0 microbench_check 4
expect_output "an improvement suggests tightening the thresholds" "make microbench-baseline"
expect "microbench check fails when the run fails" 1 microbench_check 3
if [ -s "$work/microbench.txt" ]; then pass "microbench check saves its report"; else fail "microbench check saves its report"; fi
expect "microbench rejects an unknown command" 64 "$microbench" frobnicate

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
