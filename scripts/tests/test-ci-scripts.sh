#!/bin/sh
# Tests for scripts/ci/select-xcode.sh, scripts/ci/simulator-destination.sh and
# the guard rails of .github/workflows/ci.yml.
# Hermetic: fake Xcode bundles and recorded simctl output in a temporary
# directory; never boots, creates or selects a real simulator or Xcode.
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

for job in lint package-tests app-tests perf asr-eval memory-eval; do
    if grep -Eq "^  $job:" "$workflow"; then
        pass "ci.yml defines the $job job"
    else
        fail "ci.yml defines the $job job"
    fi
done

# The ASR evaluation needs the fixture audio, which is in Git LFS.
if awk '/^  asr-eval:/{job=1} job && /lfs: true/{found=1} END{exit !found}' "$workflow"; then
    pass "ci.yml checks out Git LFS files for asr-eval"
else
    fail "ci.yml checks out Git LFS files for asr-eval"
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
