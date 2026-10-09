#!/bin/sh
# Tests for scripts/check-privacy-manifest.py (#79, docs/privacy.md).
# Hermetic: manifests, sources and a fake app bundle in a temporary
# directory, plus the repository's own manifests. Never runs xcodebuild.
# Run with `make test-scripts`.

set -u

scripts_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
repository=$(CDPATH='' cd -- "$scripts_dir/.." && pwd)
check="$scripts_dir/check-privacy-manifest.py"

work=$(mktemp -d "${TMPDIR:-/tmp}/blau-privacy-manifest-tests.XXXXXX")
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

# expect_error <description> <text the last command's stderr must contain>
expect_error() {
    if grep -qF -- "$2" "$work/err"; then
        pass "$1"
    else
        fail "$1 (no '$2' in stderr)"
        sed 's/^/       /' "$work/err"
    fi
}

# manifest <file> <NSPrivacyAccessedAPITypes entries> [collected data entries]
manifest() {
    cat >"$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSPrivacyTracking</key>
	<false/>
	<key>NSPrivacyTrackingDomains</key>
	<array/>
	<key>NSPrivacyCollectedDataTypes</key>
	<array>${3:-}</array>
	<key>NSPrivacyAccessedAPITypes</key>
	<array>$2</array>
</dict>
</plist>
EOF
}

api() {
    printf '<dict><key>NSPrivacyAccessedAPIType</key><string>%s</string><key>NSPrivacyAccessedAPITypeReasons</key><array><string>%s</string></array></dict>' "$1" "$2"
}

user_defaults=$(api NSPrivacyAccessedAPICategoryUserDefaults CA92.1)
disk_space=$(api NSPrivacyAccessedAPICategoryDiskSpace E174.1)

# --- the repository ---------------------------------------------------------

expect "the repository's manifests and sources pass" 0 python3 -I "$check"
expect "the app manifest is a valid manifest" 0 \
    python3 -I "$check" manifest "$repository/Blau/Resources/PrivacyInfo.xcprivacy" \
    "$repository/BlauWidgets/PrivacyInfo.xcprivacy"

# --- manifest ---------------------------------------------------------------

manifest "$work/good.xcprivacy" "$user_defaults$disk_space"
expect "a well-formed manifest passes" 0 python3 -I "$check" manifest "$work/good.xcprivacy"

manifest "$work/bad-reason.xcprivacy" "$(api NSPrivacyAccessedAPICategoryUserDefaults E174.1)"
expect "a reason from another category fails" 1 python3 -I "$check" manifest "$work/bad-reason.xcprivacy"
expect_error "the wrong reason is named" "'E174.1' is not a reason for NSPrivacyAccessedAPICategoryUserDefaults"

manifest "$work/bad-category.xcprivacy" "$(api NSPrivacyAccessedAPICategoryClipboard CA92.1)"
expect "an unknown category fails" 1 python3 -I "$check" manifest "$work/bad-category.xcprivacy"

manifest "$work/twice.xcprivacy" "$user_defaults$user_defaults"
expect "a category listed twice fails" 1 python3 -I "$check" manifest "$work/twice.xcprivacy"

manifest "$work/no-reasons.xcprivacy" \
    '<dict><key>NSPrivacyAccessedAPIType</key><string>NSPrivacyAccessedAPICategoryDiskSpace</string><key>NSPrivacyAccessedAPITypeReasons</key><array/></dict>'
expect "a category without reasons fails" 1 python3 -I "$check" manifest "$work/no-reasons.xcprivacy"

collected='<dict><key>NSPrivacyCollectedDataType</key><string>NSPrivacyCollectedDataTypeOtherUserContent</string><key>NSPrivacyCollectedDataTypeLinked</key><true/><key>NSPrivacyCollectedDataTypeTracking</key><false/><key>NSPrivacyCollectedDataTypePurposes</key><array><string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string></array></dict>'
manifest "$work/collected.xcprivacy" "" "$collected"
expect "a collected data type with a purpose passes" 0 python3 -I "$check" manifest "$work/collected.xcprivacy"

manifest "$work/tracking.xcprivacy" "" "$(printf '%s' "$collected" | sed 's|<key>NSPrivacyCollectedDataTypeTracking</key><false/>|<key>NSPrivacyCollectedDataTypeTracking</key><true/>|')"
expect "data used for tracking without NSPrivacyTracking fails" 1 \
    python3 -I "$check" manifest "$work/tracking.xcprivacy"

manifest "$work/bad-type.xcprivacy" "" "$(printf '%s' "$collected" | sed 's/OtherUserContent/Thoughts/')"
expect "an unknown data type fails" 1 python3 -I "$check" manifest "$work/bad-type.xcprivacy"

manifest "$work/no-purpose.xcprivacy" "" "$(printf '%s' "$collected" | sed 's|<string>NSPrivacyCollectedDataTypePurposeAppFunctionality</string>||')"
expect "a data type without a purpose fails" 1 python3 -I "$check" manifest "$work/no-purpose.xcprivacy"

printf 'not a plist' >"$work/garbage.xcprivacy"
expect "a file that isn't a property list fails" 1 python3 -I "$check" manifest "$work/garbage.xcprivacy"

sed '/NSPrivacyTrackingDomains/,+1d' "$work/good.xcprivacy" >"$work/missing-key.xcprivacy"
expect "a missing top-level key fails" 1 python3 -I "$check" manifest "$work/missing-key.xcprivacy"
expect_error "the missing key is named" "missing NSPrivacyTrackingDomains"

# --- sources ----------------------------------------------------------------

mkdir -p "$work/src/Tests"
cat >"$work/src/Settings.swift" <<'EOF'
// UserDefaults in a comment doesn't count, nor does systemUptime here.
let flag = UserDefaults.standard.bool(forKey: "flag")
/* volumeTotalCapacity in a block comment doesn't count either */
EOF
cat >"$work/src/Models.swift" <<'EOF'
let free = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
EOF
cat >"$work/src/Tests/Clock.swift" <<'EOF'
let uptime = ProcessInfo.processInfo.systemUptime
EOF
expect "declared categories pass" 0 \
    python3 -I "$check" sources --manifest "$work/good.xcprivacy" "$work/src"

manifest "$work/defaults-only.xcprivacy" "$user_defaults"
expect "an undeclared category fails" 1 \
    python3 -I "$check" sources --manifest "$work/defaults-only.xcprivacy" "$work/src"
expect_error "the undeclared category and where it's used are named" \
    "src/Models.swift:1 (volumeAvailableCapacityForImportantUsageKey)"

cat >"$work/src/Uptime.swift" <<'EOF'
let started = mach_absolute_time()
EOF
expect "a boot-time clock needs SystemBootTime" 1 \
    python3 -I "$check" sources --manifest "$work/good.xcprivacy" "$work/src"
expect_error "SystemBootTime is reported" "NSPrivacyAccessedAPICategorySystemBootTime is used but not declared"
rm "$work/src/Uptime.swift"

manifest "$work/extra.xcprivacy" "$user_defaults$disk_space$(api NSPrivacyAccessedAPICategoryActiveKeyboards 3EC4.1)"
expect "a declared category nothing uses only warns" 0 \
    python3 -I "$check" sources --manifest "$work/extra.xcprivacy" "$work/src"
expect_error "the unused category is mentioned" \
    "NSPrivacyAccessedAPICategoryActiveKeyboards is declared but no scanned source uses it"

# --- bundle -----------------------------------------------------------------

app="$work/Blau.xcarchive/Products/Applications/Blau.app"
mkdir -p "$app/PlugIns/BlauWidgets.appex" "$app/GRDB_GRDB.bundle" "$app/Other.bundle"
cp "$work/good.xcprivacy" "$app/PrivacyInfo.xcprivacy"
cp "$work/good.xcprivacy" "$app/GRDB_GRDB.bundle/PrivacyInfo.xcprivacy"
expect "an extension without a manifest fails" 1 python3 -I "$check" bundle "$work/Blau.xcarchive"
expect_error "the extension is named" "BlauWidgets.appex: no PrivacyInfo.xcprivacy"
cp "$work/good.xcprivacy" "$app/PlugIns/BlauWidgets.appex/PrivacyInfo.xcprivacy"
expect "an archive whose app and extension have manifests passes" 0 \
    python3 -I "$check" bundle "$work/Blau.xcarchive"
expect "a built app passes too" 0 python3 -I "$check" bundle "$app"
cp "$work/bad-reason.xcprivacy" "$app/GRDB_GRDB.bundle/PrivacyInfo.xcprivacy"
expect "a resource bundle's invalid manifest fails" 1 python3 -I "$check" bundle "$app"
mkdir -p "$work/Empty.xcarchive/Products"
expect "an archive without an app fails" 1 python3 -I "$check" bundle "$work/Empty.xcarchive"

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
