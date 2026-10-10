#!/bin/sh
# Tests for scripts/ci/select-xcode.sh, scripts/ci/simulator-destination.sh,
# scripts/ci/ui-test-shard.sh, scripts/ci/warm-simulator.sh and the guard rails
# of .github/workflows/ci.yml.
# Hermetic: fake Xcode bundles, test sources, xcresult summaries, a fake simctl
# and recorded simctl output in a temporary directory; never boots, creates or
# selects a real simulator or Xcode.
# Run with `make test-scripts`.

set -u

scripts_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH='' cd -- "$scripts_dir/.." && pwd)
select_xcode="$scripts_dir/ci/select-xcode.sh"
destination="$scripts_dir/ci/simulator-destination.sh"
workflow="$repo/.github/workflows/ci.yml"

work=$(mktemp -d "${TMPDIR:-/tmp}/blau-ci-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT
# select-xcode.sh reports physical paths; $TMPDIR is behind a symlink on macOS.
work=$(CDPATH='' cd -P -- "$work" && pwd)

passed=0
failed=0

pass() { passed=$((passed + 1)); echo "ok   - $1"; }
fail() { failed=$((failed + 1)); echo "FAIL - $1"; }

# expect <description> <expected exit status> <expected stdout or -> <command...>
expect() {
    description=$1
    expected_status=$2
    expected_out=$3
    shift 3
    "$@" >"$work/out" 2>"$work/err"
    actual=$?
    out=$(cat "$work/out")
    if [ "$actual" -ne "$expected_status" ]; then
        fail "$description (exit $actual, expected $expected_status)"
        sed 's/^/       /' "$work/out" "$work/err"
    elif [ "$expected_out" != "-" ] && [ "$out" != "$expected_out" ]; then
        fail "$description (stdout '$out', expected '$expected_out')"
        sed 's/^/       /' "$work/err"
    else
        pass "$description"
    fi
}

# --- select-xcode.sh ----------------------------------------------------------

# fake_xcode <dir> <bundle name> <version> <build> <icon>
fake_xcode() {
    contents="$1/$2/Contents"
    mkdir -p "$contents/Developer"
    cat >"$contents/version.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleShortVersionString</key>
    <string>$3</string>
    <key>ProductBuildVersion</key>
    <string>$4</string>
</dict>
</plist>
EOF
    cat >"$contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIconName</key>
    <string>$5</string>
</dict>
</plist>
EOF
}

apps="$work/Applications"
mkdir -p "$apps"
# Mirrors the GitHub xcode-27 image: a release kept in a "_beta" folder, a
# real beta, a release whose build ends in a letter, and symlinked aliases.
fake_xcode "$apps" Xcode_26.6.app 26.6 17F113 Xcode
fake_xcode "$apps" Xcode_26.10.app 26.10 17H50 Xcode
fake_xcode "$apps" Xcode_27.app 27.0 27A266a Xcode
fake_xcode "$apps" Xcode_27.1_beta.app 27.1 27A9269 Xcode
fake_xcode "$apps" Xcode_27.2_beta.app 27.2 27B5019j XcodeBeta
ln -s Xcode_27.app "$apps/Xcode.app"
ln -s Xcode_27.1_beta.app "$apps/Xcode_27.1.app"
mkdir -p "$apps/Xcode_broken.app/Contents" # no version.plist: ignored

expect "select-xcode: newest release wins, betas skipped by icon, not folder name" \
    0 "27.1 (27A9269) $apps/Xcode_27.1_beta.app" \
    env XCODE_SEARCH_DIR="$apps" XCODE_VERSION= GITHUB_ENV= GITHUB_OUTPUT= "$select_xcode"

expect "select-xcode: versions compare numerically (26.10 > 26.6)" \
    0 "26.10 (17H50) $apps/Xcode_26.10.app" \
    env XCODE_SEARCH_DIR="$apps" XCODE_VERSION=26 GITHUB_ENV= GITHUB_OUTPUT= "$select_xcode"

expect "select-xcode: XCODE_VERSION pins an exact version" \
    0 "26.6 (17F113) $apps/Xcode_26.6.app" \
    env XCODE_SEARCH_DIR="$apps" XCODE_VERSION=26.6 GITHUB_ENV= GITHUB_OUTPUT= "$select_xcode"

expect "select-xcode: pinning a beta's version selects the beta" \
    0 "27.2 (27B5019j) $apps/Xcode_27.2_beta.app" \
    env XCODE_SEARCH_DIR="$apps" XCODE_VERSION=27.2 GITHUB_ENV= GITHUB_OUTPUT= "$select_xcode"

expect "select-xcode: a version prefix does not match a longer number (2 is not 27)" \
    1 "" \
    env XCODE_SEARCH_DIR="$apps" XCODE_VERSION=2 GITHUB_ENV= GITHUB_OUTPUT= "$select_xcode"

expect "select-xcode: fails when the pinned version is missing" \
    1 "" \
    env XCODE_SEARCH_DIR="$apps" XCODE_VERSION=25.0 GITHUB_ENV= GITHUB_OUTPUT= "$select_xcode"

only_beta="$work/OnlyBeta"
mkdir -p "$only_beta"
fake_xcode "$only_beta" Xcode_28_beta.app 28.0 28A5123f XcodeBeta
expect "select-xcode: fails when only betas are installed and none is pinned" \
    1 "" \
    env XCODE_SEARCH_DIR="$only_beta" XCODE_VERSION= GITHUB_ENV= GITHUB_OUTPUT= "$select_xcode"

expect "select-xcode: fails when no Xcode is installed" \
    1 "" \
    env XCODE_SEARCH_DIR="$work/empty" XCODE_VERSION= GITHUB_ENV= GITHUB_OUTPUT= "$select_xcode"

: >"$work/github_env"
: >"$work/github_output"
env XCODE_SEARCH_DIR="$apps" XCODE_VERSION= GITHUB_ENV="$work/github_env" GITHUB_OUTPUT="$work/github_output" \
    "$select_xcode" >/dev/null 2>&1
if [ "$(cat "$work/github_env")" = "DEVELOPER_DIR=$apps/Xcode_27.1_beta.app/Contents/Developer" ]; then
    pass "select-xcode: exports DEVELOPER_DIR through GITHUB_ENV"
else
    fail "select-xcode: exports DEVELOPER_DIR through GITHUB_ENV"
    sed 's/^/       /' "$work/github_env"
fi
if grep -qx 'version=27.1' "$work/github_output" && grep -qx 'build=27A9269' "$work/github_output" &&
    grep -qx "path=$apps/Xcode_27.1_beta.app" "$work/github_output" &&
    grep -qx "developer-dir=$apps/Xcode_27.1_beta.app/Contents/Developer" "$work/github_output"; then
    pass "select-xcode: writes version, build, path and developer-dir outputs"
else
    fail "select-xcode: writes version, build, path and developer-dir outputs"
    sed 's/^/       /' "$work/github_output"
fi

# --- simulator-destination.sh -------------------------------------------------

devices="$work/devices.json"
# Shape of `xcrun simctl list devices available -j`, trimmed.
cat >"$devices" <<'EOF'
{
  "devices" : {
    "com.apple.CoreSimulator.SimRuntime.iOS-26-5" : [
      { "udid" : "26500000-0000-0000-0000-000000000017", "isAvailable" : true, "name" : "iPhone 17", "state" : "Shutdown" },
      { "udid" : "26500000-0000-0000-0000-0000000000A1", "isAvailable" : true, "name" : "iPhone Air", "state" : "Shutdown" }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-27-0" : [
      { "udid" : "27000000-0000-0000-0000-000000000017", "isAvailable" : true, "name" : "iPhone 17", "state" : "Shutdown" },
      { "udid" : "27000000-0000-0000-0000-000000000018", "isAvailable" : true, "name" : "iPhone 18 Pro", "state" : "Shutdown" }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-27-1" : [
      { "udid" : "27100000-0000-0000-0000-000000000017", "isAvailable" : false, "name" : "iPhone 17", "state" : "Shutdown" }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-26-10" : [
      { "udid" : "26100000-0000-0000-0000-0000000000A1", "isAvailable" : true, "name" : "iPhone Air", "state" : "Shutdown" }
    ],
    "com.apple.CoreSimulator.SimRuntime.watchOS-27-0" : [
      { "udid" : "W2700000-0000-0000-0000-000000000017", "isAvailable" : true, "name" : "iPhone 17", "state" : "Shutdown" }
    ],
    "com.apple.CoreSimulator.SimRuntime.iOS-27-2" : []
  }
}
EOF

expect "simulator-destination: newest iOS runtime with an available iPhone 17" \
    0 "id=27000000-0000-0000-0000-000000000017" \
    env SIMCTL_DEVICES_JSON="$devices" SIMULATOR_NAME= SIMULATOR_OS= GITHUB_OUTPUT= "$destination"

expect "simulator-destination: runtime versions compare numerically (26.10 > 26.5)" \
    0 "id=26100000-0000-0000-0000-0000000000A1" \
    env SIMCTL_DEVICES_JSON="$devices" SIMULATOR_NAME="iPhone Air" SIMULATOR_OS=26 GITHUB_OUTPUT= "$destination"

expect "simulator-destination: SIMULATOR_OS restricts the runtime" \
    0 "id=26500000-0000-0000-0000-000000000017" \
    env SIMCTL_DEVICES_JSON="$devices" SIMULATOR_NAME= SIMULATOR_OS=26.5 GITHUB_OUTPUT= "$destination"

expect "simulator-destination: SIMULATOR_NAME picks another model" \
    0 "id=27000000-0000-0000-0000-000000000018" \
    env SIMCTL_DEVICES_JSON="$devices" SIMULATOR_NAME="iPhone 18 Pro" SIMULATOR_OS= GITHUB_OUTPUT= "$destination"

expect "simulator-destination: fails instead of substituting a missing model" \
    1 "" \
    env SIMCTL_DEVICES_JSON="$devices" SIMULATOR_NAME="iPhone 99" SIMULATOR_OS= GITHUB_OUTPUT= "$destination"
if grep -q 'iOS 27.0  iPhone 18 Pro' "$work/err"; then
    pass "simulator-destination: the failure lists the available iPhones"
else
    fail "simulator-destination: the failure lists the available iPhones"
    sed 's/^/       /' "$work/err"
fi

expect "simulator-destination: ignores unavailable devices and non-iOS runtimes" \
    1 "" \
    env SIMCTL_DEVICES_JSON="$devices" SIMULATOR_NAME= SIMULATOR_OS=27.1 GITHUB_OUTPUT= "$destination"

expect "simulator-destination: rejects unknown arguments" \
    2 "" \
    env SIMCTL_DEVICES_JSON="$devices" "$destination" --bogus

: >"$work/github_output"
env SIMCTL_DEVICES_JSON="$devices" SIMULATOR_NAME= SIMULATOR_OS= GITHUB_OUTPUT="$work/github_output" \
    "$destination" >/dev/null 2>&1
if grep -qx 'destination=id=27000000-0000-0000-0000-000000000017' "$work/github_output" &&
    grep -qx 'udid=27000000-0000-0000-0000-000000000017' "$work/github_output" &&
    grep -qx 'os=27.0' "$work/github_output"; then
    pass "simulator-destination: writes destination, udid and os outputs"
else
    fail "simulator-destination: writes destination, udid and os outputs"
    sed 's/^/       /' "$work/github_output"
fi

# --- ui-test-shard.sh -----------------------------------------------------------

shard="$scripts_dir/ci/ui-test-shard.sh"
ui="$work/UITests"
mkdir -p "$ui/Nested"
cat >"$ui/AlphaUITests.swift" <<'EOF'
import XCTest

/// Not a test: func testInADocComment()
@MainActor
final class AlphaUITests: XCTestCase {
    private enum Identifier {
        static let url = "https://example.com/{"
    }

    private struct Row {
        func testableFrame() -> Int { 0 }
    }

    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testOne() throws {
        if true { XCTAssertTrue(true) }
    }

    @MainActor func testTwo() async throws {}

    private func testHelper() {}

    func testWithArgument(_ value: Int) {}

    func testThree() {
        let format = "{ \(1) }"
        _ = format
    }
}

final class BetaUITests: XCTestCase {
    override class func setUp() {
        super.setUp()
    }

    private final class FakeServer
    {
        func testDouble() {}
    }

    func testFour() {}
}
EOF
cat >"$ui/Nested/GammaUITests.swift" <<'EOF'
import XCTest

final class GammaUITests: XCTestCase {
    func testFive() {}
}

extension GammaUITests {
    func testSix() {}
}

extension XCTestCase {
    func tap(_ element: XCUIElement) {}
}

private struct Fixture {
    func testable() -> Bool { true }
}
EOF

expect "ui-test-shard: 1/1 lists every XCTest method, sorted, and nothing else" \
    0 "AlphaUITests/testOne
AlphaUITests/testThree
AlphaUITests/testTwo
BetaUITests/testFour
GammaUITests/testFive
GammaUITests/testSix" \
    env UI_TESTS_DIR="$ui" "$shard" --list 1/1

expect "ui-test-shard: deals the tests out round-robin (shard 1 of 4)" \
    0 "AlphaUITests/testOne
GammaUITests/testFive" \
    env UI_TESTS_DIR="$ui" "$shard" --list 1/4

expect "ui-test-shard: deals the tests out round-robin (shard 4 of 4)" \
    0 "BetaUITests/testFour" \
    env UI_TESTS_DIR="$ui" "$shard" --list 4/4

expect "ui-test-shard: a shard with no tests prints nothing" \
    0 "" \
    env UI_TESTS_DIR="$ui" "$shard" --list 7/7

expect "ui-test-shard: prints xcodebuild -only-testing arguments for the target" \
    0 "-only-testing:BlauUITests/AlphaUITests/testThree
-only-testing:BlauUITests/GammaUITests/testFive" \
    env UI_TESTS_DIR="$ui" "$shard" 2/3

# Every test in exactly one shard, for several shard counts.
for n in 1 2 3 5 6 9; do
    : >"$work/union"
    k=1
    while [ "$k" -le "$n" ]; do
        env UI_TESTS_DIR="$ui" "$shard" --list "$k/$n" >>"$work/union"
        k=$((k + 1))
    done
    env UI_TESTS_DIR="$ui" "$shard" --list 1/1 >"$work/all"
    if [ "$(LC_ALL=C sort "$work/union")" = "$(cat "$work/all")" ]; then
        pass "ui-test-shard: $n shards cover every test exactly once"
    else
        fail "ui-test-shard: $n shards cover every test exactly once"
        diff "$work/all" "$work/union" | sed 's/^/       /'
    fi
done

for spec in 0/3 4/3 3/0 1 a/b 1/2/3 -1/3; do
    expect "ui-test-shard: rejects the shard '$spec'" \
        2 "" \
        env UI_TESTS_DIR="$ui" "$shard" --list "$spec"
done
expect "ui-test-shard: rejects unknown options" \
    2 "" \
    env UI_TESTS_DIR="$ui" "$shard" --bogus 1/1

swift_testing="$work/SwiftTestingUITests"
mkdir -p "$swift_testing"
cat >"$swift_testing/MixedUITests.swift" <<'EOF'
import Testing
import XCTest

final class MixedUITests: XCTestCase {
    func testOne() {}
}

@Suite struct Other {
    @Test func works() {}
}
EOF
expect "ui-test-shard: fails on Swift Testing, which shards cannot select" \
    2 "" \
    env UI_TESTS_DIR="$swift_testing" "$shard" --list 1/1

stray="$work/StrayUITests"
mkdir -p "$stray"
cat >"$stray/StrayUITests.swift" <<'EOF'
import XCTest

extension XCTestCase {
    func testEverywhere() {}
}

final class StrayUITests: XCTestCase {
    func testOne() {}
}

func testAtTopLevel() {}
EOF
expect "ui-test-shard: fails on a test method it cannot place in a class" \
    2 "" \
    env UI_TESTS_DIR="$stray" "$shard" --list 1/1
if grep -q 'StrayUITests.swift:4: testEverywhere()' "$work/err" &&
    grep -q 'StrayUITests.swift:11: testAtTopLevel()' "$work/err"; then
    pass "ui-test-shard: the failure names each file and line"
else
    fail "ui-test-shard: the failure names each file and line"
    sed 's/^/       /' "$work/err"
fi

printf '{ "totalTestCount" : 2, "passedTests" : 2, "skippedTests" : 0 }\n' >"$work/summary-2.json"
printf '{ "totalTestCount" : 0, "passedTests" : 0 }\n' >"$work/summary-0.json"
printf '{ "title" : "no counts" }\n' >"$work/summary-none.json"
expect "ui-test-shard: --check passes when the bundle ran the shard's tests" \
    0 "" \
    env UI_TESTS_DIR="$ui" XCRESULT_SUMMARY_JSON="$work/summary-2.json" "$shard" --check 1/3 unused.xcresult
expect "ui-test-shard: --check fails when the bundle ran fewer tests" \
    1 "" \
    env UI_TESTS_DIR="$ui" XCRESULT_SUMMARY_JSON="$work/summary-0.json" "$shard" --check 1/3 unused.xcresult
expect "ui-test-shard: --check fails when the bundle ran more tests" \
    1 "" \
    env UI_TESTS_DIR="$ui" XCRESULT_SUMMARY_JSON="$work/summary-2.json" "$shard" --check 4/4 unused.xcresult
expect "ui-test-shard: --check fails on a summary without a test count" \
    1 "" \
    env UI_TESTS_DIR="$ui" XCRESULT_SUMMARY_JSON="$work/summary-none.json" "$shard" --check 1/3 unused.xcresult
expect "ui-test-shard: --check fails without a result bundle" \
    1 "" \
    env UI_TESTS_DIR="$ui" XCRESULT_SUMMARY_JSON= "$shard" --check 1/3 "$work/missing.xcresult"

# A performance build and the covered functional build must partition the
# same target without dropping or duplicating a test.
partitioned="$work/PartitionedUITests"
mkdir -p "$partitioned"
cat >"$partitioned/TopicDetailUITests.swift" <<'EOF'
import XCTest
final class TopicDetailUITests: XCTestCase {
    func testTappingExpandsWithinAHundredMilliseconds() {}
    func testShowsDetail() {}
}
final class OtherUITests: XCTestCase {
    func testOther() {}
}
EOF
expect "ui-test-shard: the functional suite excludes only the latency benchmark" \
    0 "OtherUITests/testOther
TopicDetailUITests/testShowsDetail" \
    env UI_TESTS_DIR="$partitioned" UI_TEST_SUITE=functional "$shard" --list 1/1
expect "ui-test-shard: the performance suite selects the existing benchmark" \
    0 "-only-testing:BlauUITests/TopicDetailUITests/testTappingExpandsWithinAHundredMilliseconds" \
    env UI_TESTS_DIR="$partitioned" UI_TEST_SUITE=performance "$shard" 1/1
expect "ui-test-shard: a renamed performance test fails the partition" \
    2 "" \
    env UI_TESTS_DIR="$ui" UI_TEST_SUITE=performance "$shard" --list 1/1
expect "ui-test-shard: functional selection also detects a missing performance test" \
    2 "" \
    env UI_TESTS_DIR="$ui" UI_TEST_SUITE=functional "$shard" --list 1/1
expect "ui-test-shard: rejects an unknown suite" \
    2 "" \
    env UI_TESTS_DIR="$partitioned" UI_TEST_SUITE=unknown "$shard" --list 1/1
printf '{ "totalTestCount" : 1, "passedTests" : 1 }\n' >"$work/summary-1.json"
expect "ui-test-shard: checks the executed performance test count" \
    0 "" \
    env UI_TESTS_DIR="$partitioned" UI_TEST_SUITE=performance XCRESULT_SUMMARY_JSON="$work/summary-1.json" \
    "$shard" --check 1/1 unused.xcresult
expect "ui-test-shard: a performance selector that ran zero tests fails" \
    1 "" \
    env UI_TESTS_DIR="$partitioned" UI_TEST_SUITE=performance XCRESULT_SUMMARY_JSON="$work/summary-0.json" \
    "$shard" --check 1/1 unused.xcresult

# The real UI tests: every test-like method is placed (the script fails
# otherwise), and the shards of ci.yml's app-ui-tests matrix (shard: [1, ..., N],
# run as K/N) cover them all exactly once.
if "$shard" --list 1/1 >"$work/real-all" 2>"$work/err" && [ -s "$work/real-all" ]; then
    pass "ui-test-shard: lists the real BlauUITests ($(wc -l <"$work/real-all" | tr -d ' ') tests)"
else
    fail "ui-test-shard: lists the real BlauUITests"
    sed 's/^/       /' "$work/err"
fi
matrix=$(awk '/^  app-ui-tests:/{job=1; next} job && /^  [a-z]/{exit} job && /^ +shard: \[/{print; exit}' "$workflow" |
    sed 's/.*\[//; s/\].*//; s/[[:space:]]//g')
shards=$(printf '%s\n' "$matrix" | tr ',' '\n' | grep -c . || true)
numbered=""
k=1
while [ "$k" -le "$shards" ]; do
    numbered="$numbered${numbered:+,}$k"
    k=$((k + 1))
done
if [ -n "$matrix" ] && [ "$matrix" = "$numbered" ]; then
    pass "ci.yml's app-ui-tests matrix numbers its $shards shards 1 to $shards"
else
    fail "ci.yml's app-ui-tests matrix numbers its shards 1 to N (found '$matrix')"
fi
: >"$work/real-union"
k=1
while [ "$k" -le "$shards" ]; do
    UI_TEST_SUITE=functional "$shard" --list "$k/$shards" >>"$work/real-union" 2>/dev/null
    k=$((k + 1))
done
UI_TEST_SUITE=performance "$shard" --list 1/1 >>"$work/real-union" 2>/dev/null
if [ "$shards" -gt 0 ] && [ "$(LC_ALL=C sort "$work/real-union")" = "$(cat "$work/real-all")" ]; then
    pass "ui-test-shard: CI's $shards functional shards and performance job cover BlauUITests exactly once"
else
    fail "ui-test-shard: CI's functional shards and performance job cover BlauUITests exactly once"
fi

# --- warm-simulator.sh ----------------------------------------------------------

warm="$scripts_dir/ci/warm-simulator.sh"
fake_app="$work/Blau.app"
mkdir -p "$fake_app"
cat >"$fake_app/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.example.blau</string>
</dict>
</plist>
EOF
# A fake simctl: records each call (with the launch environment) and fails
# the subcommand named in FAKE_SIMCTL_FAIL.
fake_simctl="$work/fake-simctl"
cat >"$fake_simctl" <<'EOF'
#!/bin/sh
echo "$* env=${SIMCTL_CHILD_BLAU_APP_ENVIRONMENT:-}" >>"$FAKE_SIMCTL_LOG"
[ "$1" = "${FAKE_SIMCTL_FAIL:-}" ] && exit 1
exit 0
EOF
chmod +x "$fake_simctl"

: >"$work/simctl.log"
expect "warm-simulator: boots, installs, launches with fake services, terminates" \
    0 "" \
    env SIMCTL="$fake_simctl" FAKE_SIMCTL_LOG="$work/simctl.log" WARM_SECONDS=0 "$warm" UDID-1 "$fake_app"
if [ "$(cat "$work/simctl.log")" = "bootstatus UDID-1 -b env=
install UDID-1 $fake_app env=
launch UDID-1 com.example.blau env=ui-test
terminate UDID-1 com.example.blau env=" ]; then
    pass "warm-simulator: simctl calls in order"
else
    fail "warm-simulator: simctl calls in order"
    sed 's/^/       /' "$work/simctl.log"
fi

: >"$work/simctl.log"
expect "warm-simulator: fails when the simulator does not boot" \
    1 "" \
    env SIMCTL="$fake_simctl" FAKE_SIMCTL_LOG="$work/simctl.log" FAKE_SIMCTL_FAIL=bootstatus WARM_SECONDS=0 \
    "$warm" UDID-1 "$fake_app"
if grep -q '^install' "$work/simctl.log"; then
    fail "warm-simulator: installs nothing after a failed boot"
else
    pass "warm-simulator: installs nothing after a failed boot"
fi

expect "warm-simulator: a failed launch only warns" \
    0 "::warning::warm-simulator: launching com.example.blau failed; the UI tests start cold" \
    env SIMCTL="$fake_simctl" FAKE_SIMCTL_LOG="$work/simctl.log" FAKE_SIMCTL_FAIL=launch WARM_SECONDS=0 \
    "$warm" UDID-1 "$fake_app"

expect "warm-simulator: fails without a built app" \
    2 "" \
    env SIMCTL="$fake_simctl" FAKE_SIMCTL_LOG="$work/simctl.log" "$warm" UDID-1 "$work/Missing.app"
expect "warm-simulator: rejects a bad WARM_SECONDS" \
    2 "" \
    env SIMCTL="$fake_simctl" FAKE_SIMCTL_LOG="$work/simctl.log" WARM_SECONDS=soon "$warm" UDID-1 "$fake_app"
expect "warm-simulator: needs a UDID and an app" \
    2 "" \
    env SIMCTL="$fake_simctl" FAKE_SIMCTL_LOG="$work/simctl.log" "$warm" UDID-1

# --- ci.yml guard rails ---------------------------------------------------------

# docs/configuration.md: CI never sees the xAI key, because .xcresult bundles
# are uploaded as artifacts and GitHub does not mask secrets inside them.
# Comments may mention the key; configuration may not.
grep -Ev '^[[:space:]]*#' "$workflow" >"$work/workflow-config"
if grep -q 'XAI_DEV_API_KEY' "$work/workflow-config"; then
    fail "ci.yml never references XAI_DEV_API_KEY"
else
    pass "ci.yml never references XAI_DEV_API_KEY"
fi
if grep -q 'secrets\.' "$work/workflow-config"; then
    fail "ci.yml maps no repository secrets into jobs"
else
    pass "ci.yml maps no repository secrets into jobs"
fi

# Third-party code runs with the repo token, so every action is pinned to a
# full commit SHA rather than a movable tag.
unpinned=$(grep -E '^[[:space:]-]*uses:' "$work/workflow-config" | grep -Ev 'uses: [^@[:space:]]+@[0-9a-f]{40}( |$)' || true)
if [ -z "$unpinned" ]; then
    pass "ci.yml pins every action to a commit SHA"
else
    fail "ci.yml pins every action to a commit SHA"
    echo "$unpinned" | sed 's/^/       /'
fi

for job in lint package-tests app-unit-tests app-ui-tests app-ui-performance app-tests perf-kit perf soak asr-eval memory-eval; do
    if grep -Eq "^  $job:" "$workflow"; then
        pass "ci.yml defines the $job job"
    else
        fail "ci.yml defines the $job job"
    fi
done

# app-tests is the required check for the app's tests (docs/ci.md): it needs
# the unit-test job and every UI shard, and always runs, because a skipped
# required check counts as passing.
app_tests=$(awk '/^  app-tests:/{job=1; next} job && /^  [a-z]/{exit} job' "$workflow")
if printf '%s\n' "$app_tests" | grep -Eq '^    needs: \[app-unit-tests, app-ui-tests, app-ui-performance\]$' &&
    printf '%s\n' "$app_tests" | grep -Eq '^    if: \$\{\{ always\(\) \}\}$' &&
    printf '%s\n' "$app_tests" | grep -Fq '[ "$PERFORMANCE_RESULT" != success ]'; then
    pass "ci.yml's app-tests needs every app test job and always runs"
else
    fail "ci.yml's app-tests needs every app test job and always runs"
fi

functional_job=$(awk '/^  app-ui-tests:/{job=1; next} job && /^  [a-z]/{exit} job' "$workflow")
performance_job=$(awk '/^  app-ui-performance:/{job=1; next} job && /^  [a-z]/{exit} job' "$workflow")
if printf '%s\n' "$functional_job" | grep -q 'UI_TEST_SUITE: functional' &&
    ! printf '%s\n' "$functional_job" | grep -q 'enableCodeCoverage NO'; then
    pass "ci.yml's functional UI shards retain coverage and select the functional suite"
else
    fail "ci.yml's functional UI shards retain coverage and select the functional suite"
fi
performance_flags=$(printf '%s\n' "$performance_job" | grep -c 'SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule -enableCodeCoverage NO' || true)
if printf '%s\n' "$performance_job" | grep -q 'UI_TEST_SUITE: performance' && [ "$performance_flags" -eq 2 ]; then
    pass "ci.yml's performance prebuild and test use identical optimized settings without coverage"
else
    fail "ci.yml's performance prebuild and test use identical optimized settings without coverage"
fi
# Each UI shard runs its slice as K/N, N being the size of the matrix.
# shellcheck disable=SC2016 # the workflow's ${{ }} expressions, literally
if awk '/^  app-ui-tests:/{job=1; next} job && /^  [a-z]/{exit} job' "$workflow" |
    grep -Fq 'UI_SHARD: ${{ matrix.shard }}/${{ strategy.job-total }}'; then
    pass "ci.yml's app-ui-tests runs shard matrix.shard of strategy.job-total"
else
    fail "ci.yml's app-ui-tests runs shard matrix.shard of strategy.job-total"
fi

# The ASR evaluation needs the fixture audio, which is in Git LFS.
if awk '/^  asr-eval:/{job=1} job && /lfs: true/{found=1} END{exit !found}' "$workflow"; then
    pass "ci.yml checks out Git LFS files for asr-eval"
else
    fail "ci.yml checks out Git LFS files for asr-eval"
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
