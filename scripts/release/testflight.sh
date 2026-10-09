#!/usr/bin/env bash
#
# Archives Blau in Release, exports an App Store Connect IPA, verifies it and
# uploads it to TestFlight. `make testflight` and `make release-archive` run
# it; so does .github/workflows/release.yml on every v* tag. See
# docs/release.md.
#
# Usage: scripts/release/testflight.sh
#
# Environment:
#   TEAM_ID           Apple Developer team ID (required): signs the archive.
#   BUILD_NUMBER      CFBundleVersion for the app and its extensions
#                     (required). CI uses the workflow run number.
#   UPLOAD            1 (default) uploads the IPA; 0 stops after verifying it.
#   ASC_KEY_ID        App Store Connect API key ID. With ASC_ISSUER_ID and the
#   ASC_ISSUER_ID     key itself, xcodebuild signs automatically through the
#                     API (no Apple ID in Xcode needed) and altool uploads.
#                     Required to upload; without them the archive and export
#                     use the accounts in Xcode > Settings > Accounts.
#   ASC_KEY_PATH      Path to the AuthKey_<id>.p8 file, or
#   ASC_KEY_P8        the key's contents: PEM text or base64 of the .p8 file
#                     (how CI passes the secret). Copied into a private
#                     temporary directory that is deleted on exit.
#   INTERNAL_ONLY     1 marks the build "internal testing only" in TestFlight.
#   RELEASE_DIR       Output directory (default .build/release): Blau.xcarchive,
#                     export/Blau.ipa, verify-report.md and summary.md.
#   DERIVED_DATA      DerivedData (default .build/DerivedData).
#   SKIP_GENERATE     1 skips `xcodegen generate` (the project already exists).
#   XCODEBUILD_FLAGS  Extra arguments for both xcodebuild invocations.
#   VERIFY_FLAGS      Extra arguments for `release.py verify-ipa` (tests only).
#
# Never prints the API key. The key file lives only for this script's run.

set -euo pipefail

repo="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$repo"
release_py="$repo/scripts/release/release.py"

die() {
    echo "testflight: $*" >&2
    exit 1
}

: "${TEAM_ID:=}"
: "${BUILD_NUMBER:=}"
: "${UPLOAD:=1}"
: "${ASC_KEY_ID:=}"
: "${ASC_ISSUER_ID:=}"
: "${ASC_KEY_PATH:=}"
: "${ASC_KEY_P8:=}"
: "${INTERNAL_ONLY:=0}"
: "${RELEASE_DIR:=.build/release}"
: "${DERIVED_DATA:=.build/DerivedData}"
: "${SKIP_GENERATE:=0}"
: "${XCODEBUILD_FLAGS:=}"
: "${VERIFY_FLAGS:=}"

[[ -n "$TEAM_ID" ]] || die "set TEAM_ID to your Apple Developer team ID (developer.apple.com > Membership)"
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || die "TEAM_ID must be the 10-character team ID, e.g. ABCDE12345"
[[ -n "$BUILD_NUMBER" ]] || die "set BUILD_NUMBER, higher than every build already in App Store Connect"
[[ "$UPLOAD" == 0 || "$UPLOAD" == 1 ]] || die "UPLOAD must be 0 or 1"

# Marketing version from project.yml; also validates the build number.
versions="$("$release_py" version --build-number "$BUILD_NUMBER")" || exit 1
marketing_version="$(sed -n 's/^marketing_version=//p' <<<"$versions")"
build_number="$(sed -n 's/^build_number=//p' <<<"$versions")"

# --- App Store Connect API key ----------------------------------------------------

key_dir=""
cleanup() {
    if [[ -n "$key_dir" ]]; then
        rm -rf "$key_dir"
    fi
}
trap cleanup EXIT

auth_flags=()
if [[ -n "$ASC_KEY_ID" || -n "$ASC_ISSUER_ID" || -n "$ASC_KEY_PATH" || -n "$ASC_KEY_P8" ]]; then
    [[ -n "$ASC_KEY_ID" && -n "$ASC_ISSUER_ID" ]] || die "set both ASC_KEY_ID and ASC_ISSUER_ID"
    [[ "$ASC_KEY_ID" =~ ^[A-Za-z0-9]+$ ]] || die "ASC_KEY_ID must be the key's alphanumeric ID"
    [[ -n "$ASC_KEY_PATH" || -n "$ASC_KEY_P8" ]] || die "set ASC_KEY_PATH or ASC_KEY_P8"
    key_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/blau-asc-key.XXXXXX")"
    chmod 700 "$key_dir"
    # altool looks the key up as AuthKey_<id>.p8 in $API_PRIVATE_KEYS_DIR.
    key_file="$key_dir/AuthKey_$ASC_KEY_ID.p8"
    (
        umask 077
        if [[ -n "$ASC_KEY_PATH" ]]; then
            [[ -f "$ASC_KEY_PATH" ]] || die "ASC_KEY_PATH: no such file"
            cp "$ASC_KEY_PATH" "$key_file"
        elif [[ "$ASC_KEY_P8" == *"-----BEGIN PRIVATE KEY-----"* ]]; then
            printf '%s\n' "$ASC_KEY_P8" >"$key_file"
        else
            printf '%s' "$ASC_KEY_P8" | tr -d ' \r\n' | base64 -D >"$key_file" 2>/dev/null ||
                die "ASC_KEY_P8 is neither PEM text nor base64"
        fi
    )
    grep -q -- '-----BEGIN PRIVATE KEY-----' "$key_file" ||
        die "the App Store Connect key is not a PEM private key (.p8)"
    auth_flags=(
        -authenticationKeyPath "$key_file"
        -authenticationKeyID "$ASC_KEY_ID"
        -authenticationKeyIssuerID "$ASC_ISSUER_ID"
    )
elif [[ "$UPLOAD" == 1 ]]; then
    die "uploading needs an App Store Connect API key: set ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH (or UPLOAD=0)"
fi

# --- Archive ----------------------------------------------------------------------

archive="$RELEASE_DIR/Blau.xcarchive"
export_dir="$RELEASE_DIR/export"
rm -rf "$archive" "$export_dir"
mkdir -p "$RELEASE_DIR"

if [[ "$SKIP_GENERATE" != 1 ]]; then
    command -v xcodegen >/dev/null || die "xcodegen not found: brew install xcodegen"
    xcodegen generate
fi

# shellcheck disable=SC2206 # XCODEBUILD_FLAGS is a space-separated list by design.
extra_flags=($XCODEBUILD_FLAGS)

echo "testflight: archiving Blau $marketing_version ($build_number) for team $TEAM_ID"
# XAI_DEV_API_KEY= keeps a local Secrets.xcconfig key out of the build (the
# embedded-secrets phase fails Release builds that see one). The command-line
# CURRENT_PROJECT_VERSION applies to every target, so the widget extension's
# CFBundleVersion matches the app's.
xcodebuild archive \
    -project Blau.xcodeproj \
    -scheme Blau \
    -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "$archive" \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    ${auth_flags[@]+"${auth_flags[@]}"} \
    ${extra_flags[@]+"${extra_flags[@]}"} \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    CURRENT_PROJECT_VERSION="$build_number" \
    XAI_DEV_API_KEY=

[[ -d "$archive" ]] || die "xcodebuild reported success but wrote no archive at $archive"

# The privacy manifests travel in the archive (docs/privacy.md).
"$repo/scripts/check-privacy-manifest.py" bundle "$archive"

# --- Export -----------------------------------------------------------------------

export_options="$RELEASE_DIR/ExportOptions.plist"
internal_flag=()
[[ "$INTERNAL_ONLY" == 1 ]] && internal_flag=(--internal-only)
"$release_py" export-options --output "$export_options" --team "$TEAM_ID" ${internal_flag[@]+"${internal_flag[@]}"}

echo "testflight: exporting for App Store Connect"
xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportPath "$export_dir" \
    -exportOptionsPlist "$export_options" \
    -allowProvisioningUpdates \
    ${auth_flags[@]+"${auth_flags[@]}"} \
    ${extra_flags[@]+"${extra_flags[@]}"}

shopt -s nullglob
ipas=("$export_dir"/*.ipa)
shopt -u nullglob
[[ ${#ipas[@]} -eq 1 ]] || die "expected one .ipa in $export_dir, found ${#ipas[@]}"
ipa="${ipas[0]}"

# --- Verify -----------------------------------------------------------------------

# shellcheck disable=SC2206 # VERIFY_FLAGS is a space-separated list by design.
verify_flags=($VERIFY_FLAGS)
"$release_py" verify-ipa --ipa "$ipa" --version "$marketing_version" --build "$build_number" \
    --report "$RELEASE_DIR/verify-report.md" ${verify_flags[@]+"${verify_flags[@]}"}

# --- Upload -----------------------------------------------------------------------

summary="$RELEASE_DIR/summary.md"
if [[ "$UPLOAD" == 1 ]]; then
    echo "testflight: uploading $(basename "$ipa") to App Store Connect"
    API_PRIVATE_KEYS_DIR="$key_dir" xcrun altool --upload-package "$ipa" \
        --api-key "$ASC_KEY_ID" --api-issuer "$ASC_ISSUER_ID" --output-format normal
    status="uploaded to App Store Connect; it appears in TestFlight once processing finishes (usually 5 to 30 minutes)"
else
    status="archived, exported and verified; not uploaded (UPLOAD=0)"
fi

{
    echo "## Blau $marketing_version ($build_number)"
    echo
    echo "- Status: $status"
    echo "- Team: $TEAM_ID"
    echo "- IPA: \`$ipa\` ($(du -h "$ipa" | cut -f1 | tr -d ' '))"
} >"$summary"
echo "testflight: Blau $marketing_version ($build_number) $status"
