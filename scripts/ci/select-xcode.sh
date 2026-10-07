#!/usr/bin/env bash
#
# Picks the Xcode a CI job builds with and makes it the active developer
# directory for the rest of the job. Used by .github/workflows/ci.yml; see
# docs/ci.md.
#
# Usage: scripts/ci/select-xcode.sh
#
# By default the newest *release* Xcode installed in $XCODE_SEARCH_DIR wins.
# Betas are recognised by the "XcodeBeta" app icon Apple ships them with, not
# by the bundle's folder name: runner images sometimes keep a release build in
# a folder still called "..._beta.app" (and Apple has shipped release builds
# whose build number ends in a letter, so that is no signal either).
#
# Environment:
#   XCODE_VERSION     Pin a version instead of taking the newest release, e.g.
#                     "27.1" or "27". Matches that version or any x.y under it,
#                     betas included (pinning one is an explicit choice).
#   XCODE_SEARCH_DIR  Where to look for Xcode*.app bundles (default
#                     /Applications). Tests point it at fake bundles.
#   GITHUB_ENV        When set (GitHub Actions), DEVELOPER_DIR is appended so
#                     every later step uses the chosen Xcode. No sudo needed:
#                     xcrun, xcodebuild and swift all honour DEVELOPER_DIR.
#   GITHUB_OUTPUT     When set, writes the outputs `version`, `build`, `path`
#                     and `developer-dir` (cache keys use `build`).
#
# Prints the chosen Xcode as "version (build) path" on stdout.

set -euo pipefail

search_dir="${XCODE_SEARCH_DIR:-/Applications}"
wanted="${XCODE_VERSION:-}"

plist_value() {
    # plutil reads both XML and binary plists; prints nothing if the key is missing.
    plutil -extract "$1" raw -o - "$2" 2>/dev/null || true
}

candidates=()
seen=" "
shopt -s nullglob
for app in "$search_dir"/Xcode*.app; do
    [[ -d "$app" ]] || continue
    # Runner images add symlinks (Xcode.app, Xcode_27.1.app...) to the real
    # bundles; resolve them so each Xcode is considered once.
    real="$(cd -P -- "$app" && pwd)"
    case "$seen" in *" $real "*) continue ;; esac
    seen="$seen$real "

    version="$(plist_value CFBundleShortVersionString "$real/Contents/version.plist")"
    build="$(plist_value ProductBuildVersion "$real/Contents/version.plist")"
    icon="$(plist_value CFBundleIconName "$real/Contents/Info.plist")"
    [[ -n "$version" && -n "$build" ]] || continue
    beta=0
    [[ "$icon" == "XcodeBeta" ]] && beta=1

    if [[ -n "$wanted" ]]; then
        [[ "$version" == "$wanted" || "$version" == "$wanted".* ]] || continue
    elif [[ $beta -eq 1 ]]; then
        continue
    fi
    candidates+=("$version"$'\t'"$build"$'\t'"$real")
done

if [[ ${#candidates[@]} -eq 0 ]]; then
    if [[ -n "$wanted" ]]; then
        echo "select-xcode: no Xcode $wanted found in $search_dir." >&2
    else
        echo "select-xcode: no release Xcode found in $search_dir." >&2
    fi
    echo "select-xcode: installed bundles:" >&2
    for app in "$search_dir"/Xcode*.app; do echo "  $app" >&2; done
    exit 1
fi

# Newest version wins; ties (same version, two builds) break on the build.
chosen="$(printf '%s\n' "${candidates[@]}" | sort -t $'\t' -k1,1V -k2,2V | tail -n 1)"
IFS=$'\t' read -r version build path <<<"$chosen"
developer_dir="$path/Contents/Developer"

if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "DEVELOPER_DIR=$developer_dir" >>"$GITHUB_ENV"
fi
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "version=$version"
        echo "build=$build"
        echo "path=$path"
        echo "developer-dir=$developer_dir"
    } >>"$GITHUB_OUTPUT"
fi

echo "$version ($build) $path"
