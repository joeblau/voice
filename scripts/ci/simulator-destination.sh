#!/usr/bin/env bash
#
# Resolves the iOS Simulator a CI job tests on to a single device UDID and
# prints the xcodebuild destination ("id=<udid>"). Used by
# .github/workflows/ci.yml; see docs/ci.md.
#
# Usage: scripts/ci/simulator-destination.sh [--boot]
#
#   --boot   Also boot the device and wait until it has finished booting, so
#            the first UI test doesn't spend its launch timeout on a cold boot.
#
# A UDID instead of "platform=iOS Simulator,name=iPhone 17,OS=latest" because
# "OS=latest" means the selected Xcode's SDK version, and runner images often
# only ship an older runtime (Xcode 27.1 with only the iOS 27.0 runtime), which
# makes xcodebuild fail to find a destination. Here the newest installed iOS
# runtime that has a matching device wins.
#
# The device must exist already: this script never creates or deletes
# simulators. It fails, listing the available iPhones, rather than silently
# testing on a different model.
#
# Environment:
#   SIMULATOR_NAME        Device name to look for (default "iPhone 17").
#   SIMULATOR_OS          Only consider this iOS version, e.g. "27.0" or "27".
#   SIMCTL_DEVICES_JSON   Read `xcrun simctl list devices available -j` output
#                         from this file instead of running simctl (tests).
#   GITHUB_OUTPUT         When set, writes the outputs `destination`, `udid`
#                         and `os`.

set -euo pipefail

boot=0
for arg in "$@"; do
    case "$arg" in
        --boot) boot=1 ;;
        -h | --help)
            sed -n '7,10p' "$0" | sed 's/^# \{0,1\}//' >&2
            exit 0
            ;;
        *)
            echo "simulator-destination: unknown argument '$arg'" >&2
            exit 2
            ;;
    esac
done

name="${SIMULATOR_NAME:-iPhone 17}"
os="${SIMULATOR_OS:-}"

if [[ -n "${SIMCTL_DEVICES_JSON:-}" ]]; then
    devices_json="$(cat "$SIMCTL_DEVICES_JSON")"
else
    devices_json="$(xcrun simctl list devices available -j)"
fi

# One "<iOS version>\t<udid>\t<name>" line per available iOS device. Runtime
# keys look like com.apple.CoreSimulator.SimRuntime.iOS-27-0.
all_devices="$(
    jq -r '
        .devices
        | to_entries[]
        # Non-iOS runtimes do not match, produce no $version and are skipped.
        | (.key | capture("SimRuntime\\.iOS-(?<v>[0-9]+(-[0-9]+)*)$") | .v | gsub("-"; ".")) as $version
        | .value[]
        | select(.isAvailable != false)
        | [$version, .udid, .name]
        | @tsv
    ' <<<"$devices_json"
)"

chosen=""
while IFS=$'\t' read -r version udid device_name; do
    [[ -n "$version" && "$device_name" == "$name" ]] || continue
    if [[ -n "$os" && "$version" != "$os" && "$version" != "$os".* ]]; then
        continue
    fi
    chosen="$chosen$version"$'\t'"$udid"$'\n'
done <<<"$all_devices"

if [[ -z "$chosen" ]]; then
    echo "simulator-destination: no available '$name' simulator${os:+ on iOS $os}." >&2
    echo "simulator-destination: available iPhone simulators:" >&2
    grep -F $'\tiPhone' <<<"$all_devices" | sort -t $'\t' -k1,1V -k3,3 |
        awk -F '\t' '{ printf "  iOS %s  %s  (%s)\n", $1, $3, $2 }' >&2 || true
    echo "simulator-destination: set SIMULATOR_NAME (the BLAU_CI_SIMULATOR repository variable in CI)." >&2
    exit 1
fi

# Newest runtime wins; ties (two devices with the name) break on the UDID so
# the choice is stable.
IFS=$'\t' read -r version udid <<<"$(printf '%s' "$chosen" | sort -t $'\t' -k1,1V -k2,2 | tail -n 1)"
destination="id=$udid"
echo "simulator-destination: $name, iOS $version, $udid" >&2

if [[ $boot -eq 1 ]]; then
    # -b boots the device if needed and blocks until it has finished booting.
    # It prints a progress line a second; keep it out of the log unless it fails.
    boot_log="$(mktemp "${TMPDIR:-/tmp}/simulator-boot.XXXXXX")"
    SECONDS=0
    if ! xcrun simctl bootstatus "$udid" -b >"$boot_log" 2>&1; then
        cat "$boot_log" >&2
        rm -f "$boot_log"
        echo "simulator-destination: failed to boot $udid." >&2
        exit 1
    fi
    rm -f "$boot_log"
    echo "simulator-destination: booted in ${SECONDS}s" >&2
fi

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "destination=$destination"
        echo "udid=$udid"
        echo "os=$version"
    } >>"$GITHUB_OUTPUT"
fi

echo "$destination"
