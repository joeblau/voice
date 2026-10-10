#!/usr/bin/env bash
#
# Boots a CI job's simulator after the build and launches the app on it once,
# so the first UI test does not pay for a cold simulator. Used by the
# app-ui-tests jobs in .github/workflows/ci.yml; see docs/ci.md.
#
# Usage: scripts/ci/warm-simulator.sh <udid> <path to Blau.app>
#
# On a freshly booted runner simulator the app's first launch can take
# minutes, longer than XCUITest waits for a launch: the first UI test of a
# shard failed with "Timed out while launching application". In one job the
# app-hosted unit tests used to absorb that. Here the device is booted (and
# waited for) only once the build is done, because booting it before the
# build starves the runner, then the app is installed and launched with the
# UI tests' fake services (BLAU_APP_ENVIRONMENT=ui-test, so nothing reaches
# the network), given WARM_SECONDS to finish starting, and terminated.
#
# A failed boot fails the script: no test could run. A failed install or
# launch only warns; the tests will report what is wrong.
#
# Environment:
#   WARM_SECONDS  How long the app runs before it is terminated (default 20).
#   SIMCTL        The simctl command (default "xcrun simctl"); tests point it
#                 at a fake.

set -euo pipefail

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
    sed -n '3,24p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 0
fi
if [[ $# -ne 2 ]]; then
    echo "usage: scripts/ci/warm-simulator.sh <udid> <path to Blau.app>" >&2
    exit 2
fi

udid="$1"
app="$2"
seconds="${WARM_SECONDS:-20}"
read -r -a simctl <<<"${SIMCTL:-xcrun simctl}"

[[ "$seconds" =~ ^[0-9]+$ ]] || {
    echo "warm-simulator: WARM_SECONDS '$seconds' is not a number of seconds" >&2
    exit 2
}
[[ -d "$app" ]] || {
    echo "warm-simulator: no app at $app (build it first)" >&2
    exit 2
}
bundle_id="$(plutil -extract CFBundleIdentifier raw -o - "$app/Info.plist" 2>/dev/null || true)"
[[ -n "$bundle_id" ]] || {
    echo "warm-simulator: no CFBundleIdentifier in $app/Info.plist" >&2
    exit 2
}

step() {
    echo "warm-simulator: $1 ($((SECONDS - started)) s)" >&2
}

started=$SECONDS
step "booting $udid"
# bootstatus -b boots the device if needed and waits until it has finished
# booting, data migration included. It reports every second; only the end of
# that is worth showing, and only on failure.
if ! boot_log="$("${simctl[@]}" bootstatus "$udid" -b 2>&1)"; then
    printf '%s\n' "$boot_log" | tail -n 12 >&2
    echo "warm-simulator: could not boot $udid" >&2
    exit 1
fi

step "installing $bundle_id"
if ! "${simctl[@]}" install "$udid" "$app" >&2; then
    echo "::warning::warm-simulator: installing $app failed; the UI tests start cold"
    exit 0
fi

step "launching $bundle_id"
if ! SIMCTL_CHILD_BLAU_APP_ENVIRONMENT=ui-test "${simctl[@]}" launch "$udid" "$bundle_id" >&2; then
    echo "::warning::warm-simulator: launching $bundle_id failed; the UI tests start cold"
    exit 0
fi
sleep "$seconds"
"${simctl[@]}" terminate "$udid" "$bundle_id" >&2 || true
step "warm"
