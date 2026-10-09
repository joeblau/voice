#!/usr/bin/env bash
#
# Optional: puts a stable Apple Development signing certificate on a CI
# runner before `scripts/release/testflight.sh` archives. Used by
# .github/workflows/release.yml; see docs/release.md, "Signing".
#
# Usage: scripts/release/signing-keychain.sh setup | cleanup
#
# Why: automatic signing archives with an Apple Development identity and
# re-signs with a cloud-managed Apple Distribution certificate on export. A
# fresh runner has no development identity, so xcodebuild creates a new
# certificate through the API on every run, and the team's certificate limit
# fills up. Importing one long-lived certificate avoids that. Without
# CERTIFICATE_P12 this script does nothing and Xcode creates one as needed.
#
# Environment (setup):
#   CERTIFICATE_P12       base64 of an Apple Development .p12 (certificate + key)
#   CERTIFICATE_PASSWORD  the .p12's password
#   KEYCHAIN_DIR          where the temporary keychain goes ($RUNNER_TEMP)
#
# The keychain gets a random password, is added to the user search list for
# this job and is deleted by `cleanup`, which is safe to run when `setup`
# did nothing.

set -euo pipefail

keychain_dir="${KEYCHAIN_DIR:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}}"
keychain="$keychain_dir/blau-signing.keychain-db"

usage() {
    echo "usage: $0 setup | cleanup" >&2
    exit 2
}

[[ $# -eq 1 ]] || usage

case "$1" in
setup)
    if [[ -z "${CERTIFICATE_P12:-}" ]]; then
        echo "signing-keychain: no CERTIFICATE_P12; xcodebuild will create a development certificate if it needs one"
        exit 0
    fi
    work="$(mktemp -d "$keychain_dir/blau-p12.XXXXXX")"
    trap 'rm -rf "$work"' EXIT
    (
        umask 077
        printf '%s' "$CERTIFICATE_P12" | tr -d ' \r\n' | base64 -D >"$work/certificate.p12"
    ) || {
        echo "signing-keychain: CERTIFICATE_P12 is not base64" >&2
        exit 1
    }
    keychain_password="$(openssl rand -hex 24)"
    rm -f "$keychain"
    security create-keychain -p "$keychain_password" "$keychain"
    security set-keychain-settings -lut 21600 "$keychain"
    security unlock-keychain -p "$keychain_password" "$keychain"
    security import "$work/certificate.p12" -k "$keychain" -f pkcs12 -t cert \
        -P "${CERTIFICATE_PASSWORD:-}" -T /usr/bin/codesign -T /usr/bin/security
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$keychain_password" "$keychain" >/dev/null
    # Prepend to the user search list so codesign and xcodebuild find it.
    existing=()
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%\"}"
        line="${line#\"}"
        [[ -n "$line" ]] && existing+=("$line")
    done < <(security list-keychains -d user)
    security list-keychains -d user -s "$keychain" ${existing[@]+"${existing[@]}"}
    echo "signing-keychain: imported $(security find-identity -v -p codesigning "$keychain" | grep -c '"') signing identity(ies)"
    ;;
cleanup)
    if [[ -f "$keychain" ]]; then
        security delete-keychain "$keychain" || true
        echo "signing-keychain: deleted the temporary keychain"
    fi
    ;;
*)
    usage
    ;;
esac
