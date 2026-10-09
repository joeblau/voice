#!/bin/sh
# Tests for the TestFlight release pipeline (#83, docs/release.md):
# scripts/release/release.py, scripts/release/testflight.sh,
# scripts/release/signing-keychain.sh and the guard rails of
# .github/workflows/release.yml.
# Hermetic: fake projects, a throwaway git repository, ad hoc signed fake app
# bundles and stand-in xcodebuild / xcrun / xcodegen on PATH, all in a
# temporary directory. Never archives, signs with a real identity, touches the
# keychain or talks to App Store Connect. Run with `make test-scripts`.

set -u

scripts_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
repo=$(CDPATH='' cd -- "$scripts_dir/.." && pwd)
release="$scripts_dir/release/release.py"
testflight="$scripts_dir/release/testflight.sh"
keychain="$scripts_dir/release/signing-keychain.sh"
make_app="$scripts_dir/tests/fixtures/make-release-app.py"
workflow="$repo/.github/workflows/release.yml"

work=$(mktemp -d "${TMPDIR:-/tmp}/blau-release-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT
work=$(CDPATH='' cd -P -- "$work" && pwd)

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

# expect_text <description> <file> <text the file must contain>
expect_text() {
    if [ -f "$2" ] && grep -qF -- "$3" "$2"; then
        pass "$1"
    else
        fail "$1 (no '$3' in $(basename "$2"))"
        [ -f "$2" ] && sed 's/^/       /' "$2"
    fi
}

# expect_no_text <description> <file> <text the file must not contain>
expect_no_text() {
    if [ -f "$2" ] && grep -qF -- "$3" "$2"; then
        fail "$1 ('$3' found in $(basename "$2"))"
        sed 's/^/       /' "$2"
    else
        pass "$1"
    fi
}

# Keep the scripts from appending to a real GitHub Actions output file.
unset GITHUB_OUTPUT GITHUB_ACTIONS GITHUB_REPOSITORY

# --- release.py version -------------------------------------------------------------

project="$work/project.yml"
cat >"$project" <<'EOF'
name: Blau
settings:
  base:
    SWIFT_VERSION: "6.0"
    MARKETING_VERSION: "1.2.0"
    CURRENT_PROJECT_VERSION: "1"
EOF

expect "version: a matching tag gives the marketing version and run-number build" \
    0 "$release" version --project "$project" --ref refs/tags/v1.2.0 --run-number 17
expect_text "version: prints the marketing version" "$work/out" "marketing_version=1.2.0"
expect_text "version: prints the build number" "$work/out" "build_number=17"
expect_text "version: prints the tag" "$work/out" "tag=v1.2.0"

expect "version: a pre-release suffix is allowed (v1.2.0-beta.2)" \
    0 "$release" version --project "$project" --ref refs/tags/v1.2.0-beta.2 --run-number 3
expect_text "version: the suffix is not part of the marketing version" "$work/out" "marketing_version=1.2.0"

expect "version: a tag that doesn't match MARKETING_VERSION fails" \
    1 "$release" version --project "$project" --ref refs/tags/v1.3.0 --run-number 3
expect_text "version: the failure says to bump MARKETING_VERSION" "$work/err" "bump MARKETING_VERSION"

expect "version: a tag that isn't v<major>.<minor>.<patch> fails" \
    1 "$release" version --project "$project" --ref refs/tags/vnext --run-number 3
expect "version: four version components are rejected" \
    1 "$release" version --project "$project" --ref refs/tags/v1.2.0.1 --run-number 3

expect "version: a branch ref has no tag" \
    0 "$release" version --project "$project" --ref refs/heads/main --run-number 5
if grep -qx 'tag=' "$work/out"; then pass "version: tag is empty for a branch"; else fail "version: tag is empty for a branch"; fi

expect "version: the build offset is added to the run number" \
    0 "$release" version --project "$project" --ref refs/heads/main --run-number 5 --build-offset 100
expect_text "version: offset build number" "$work/out" "build_number=105"

expect "version: --build-number overrides the run number" \
    0 "$release" version --project "$project" --build-number 900 --run-number 5
expect_text "version: explicit build number" "$work/out" "build_number=900"

expect "version: build number 0 is rejected" \
    1 "$release" version --project "$project" --build-number 0
expect "version: no run number or build number is a usage error" \
    2 "$release" version --project "$project"

cat >"$work/bad-project.yml" <<'EOF'
settings:
  base:
    MARKETING_VERSION: "1.2.0-beta"
EOF
expect "version: an invalid MARKETING_VERSION fails" \
    1 "$release" version --project "$work/bad-project.yml" --build-number 1

: >"$work/github_output"
GITHUB_OUTPUT="$work/github_output" "$release" version --project "$project" --ref refs/tags/v1.2.0 \
    --run-number 8 >/dev/null 2>&1
if grep -qx 'marketing_version=1.2.0' "$work/github_output" && grep -qx 'build_number=8' "$work/github_output" &&
    grep -qx 'tag=v1.2.0' "$work/github_output"; then
    pass "version: writes marketing_version, build_number and tag outputs"
else
    fail "version: writes marketing_version, build_number and tag outputs"
    sed 's/^/       /' "$work/github_output"
fi

expect "version: the repository's project.yml has a valid MARKETING_VERSION" \
    0 "$release" version --build-number 1

# --- release.py schema --------------------------------------------------------------

package="$work/BlauKit"
schema_dir="$package/Sources/BlauPersistence/Schema"
mkdir -p "$schema_dir"
echo 'public typealias CurrentSchema = SchemaV3' >"$schema_dir/CurrentSchema.swift"
cat >"$schema_dir/SchemaV3.swift" <<'EOF'
public enum SchemaV3: VersionedSchema {
    public static let versionIdentifier = Schema.Version(3, 1, 0)
}
EOF

expect "schema: passes when the deployed version matches" \
    0 "$release" schema --package "$package" --deployed 3.1.0
expect "schema: versions compare normalized (3.1 is 3.1.0)" \
    0 "$release" schema --package "$package" --deployed 3.1
expect "schema: fails when Production has an older schema" \
    1 "$release" schema --package "$package" --deployed 3.0.0
expect_text "schema: the failure points at the checklist" "$work/err" "docs/release.md"
expect "schema: fails when no deployed schema is recorded" \
    1 "$release" schema --package "$package"
expect "schema: --warn-only turns the failure into a warning (dry runs)" \
    0 "$release" schema --package "$package" --warn-only
expect_text "schema: the warning is a GitHub annotation" "$work/out" "::warning"
expect "schema: a malformed deployed version fails" \
    1 "$release" schema --package "$package" --deployed latest

echo 'public typealias CurrentSchema = SchemaV9' >"$schema_dir/CurrentSchema.swift"
expect "schema: fails when CurrentSchema names a missing file" \
    1 "$release" schema --package "$package" --deployed 3.1.0

expect "schema: reads the repository's CurrentSchema" \
    0 "$release" schema --warn-only
current_schema=$(sed -n 's/^schema_version=//p' "$work/out")
expect "schema: the repository passes with its own version deployed ($current_schema)" \
    0 "$release" schema --deployed "$current_schema"

# --- release.py notes ---------------------------------------------------------------

git_repo="$work/repo"
mkdir -p "$git_repo"
export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
g() { git -C "$git_repo" -c commit.gpgsign=false -c tag.gpgsign=false -c init.defaultBranch=main "$@"; }
g init -q
g commit -q --allow-empty -m "first commit"
g tag v0.1.0
g commit -q --allow-empty -m "Build the record button (#10)"
g checkout -q -b feature
g commit -q --allow-empty -m "fix(audio): something"
g checkout -q main
g merge -q --no-ff feature -m "Merge pull request #11 from someone/feature" -m "Fix the playback stall"
g commit -q --allow-empty -m "docs: fix a typo"
g tag -a v0.2.0 -m "Blau 0.2.0"

notes() { (cd "$git_repo" && "$release" notes "$@"); }

expect "notes: writes Markdown and What to Test text" \
    0 notes --to v0.2.0 --repo joeblau/voice --version 0.2.0 --build 12 \
    --markdown "$work/notes.md" --text "$work/notes.txt"
expect_text "notes: Markdown heading has the version and build" "$work/notes.md" "## Blau 0.2.0 (12)"
expect_text "notes: starts at the previous tag" "$work/notes.md" "Changes since v0.1.0:"
expect_text "notes: lists a squash-merged pull request with a link" "$work/notes.md" \
    "- Build the record button ([#10](https://github.com/joeblau/voice/pull/10))"
expect_text "notes: lists a merge-commit pull request by its title" "$work/notes.md" \
    "- Fix the playback stall ([#11](https://github.com/joeblau/voice/pull/11))"
expect_text "notes: lists a direct commit with its hash" "$work/notes.md" "- docs: fix a typo ("
expect_no_text "notes: leaves out the commits before the previous tag" "$work/notes.md" "first commit"
expect_no_text "notes: leaves out commits inside a merged branch" "$work/notes.md" "fix(audio): something"
expect_text "notes: links the full changelog" "$work/notes.md" \
    "https://github.com/joeblau/voice/compare/v0.1.0...v0.2.0"
expect_text "notes: the TestFlight text lists pull requests by number" "$work/notes.txt" \
    "- Build the record button (#10)"
expect_no_text "notes: the TestFlight text has no Markdown links" "$work/notes.txt" "]("

expect "notes: the first release lists every commit" \
    0 notes --to v0.1.0 --repo joeblau/voice --markdown "$work/first.md"
expect_text "notes: says it is the first release" "$work/first.md" "first release"
expect_text "notes: first release includes the first commit" "$work/first.md" "first commit"

expect "notes: --from overrides the previous tag" \
    0 notes --to v0.2.0 --from v0.1.0~0 --repo joeblau/voice
expect_text "notes: prints Markdown to stdout without --markdown/--text" "$work/out" "Changes since v0.1.0~0:"

expect "notes: an unknown ref fails" 1 notes --to v9.9.9

i=0
while [ $i -lt 120 ]; do
    i=$((i + 1))
    g commit -q --allow-empty -m "Build a long and very descriptive feature title for change number $i (#$((100 + i)))"
done
expect "notes: long histories still produce What to Test text" \
    0 notes --to HEAD --repo joeblau/voice --text "$work/long.txt" --markdown "$work/long.md"
length=$(wc -c <"$work/long.txt" | tr -d ' ')
if [ "$length" -le 4000 ]; then
    pass "notes: What to Test text fits TestFlight's 4,000 characters ($length)"
else
    fail "notes: What to Test text fits TestFlight's 4,000 characters ($length)"
fi
expect_text "notes: says how many changes were left out" "$work/long.txt" "more. See https://github.com/joeblau/voice/releases"
expect_text "notes: the Markdown keeps every change" "$work/long.md" "change number 1 (["

# --- release.py export-options --------------------------------------------------------

expect "export-options: writes the plist" \
    0 "$release" export-options --output "$work/ExportOptions.plist" --team ABCDE12345
# expect_option <description> <key> <expected value>
expect_option() {
    actual=$(plutil -extract "$2" raw -o - "$work/ExportOptions.plist" 2>/dev/null)
    if [ "$actual" = "$3" ]; then
        pass "export-options: $1"
    else
        fail "export-options: $1 ($2 is '$actual', expected '$3')"
    fi
}
expect_option "method app-store-connect" method app-store-connect
expect_option "exports locally, so the IPA is verified before upload" destination export
expect_option "automatic signing" signingStyle automatic
expect_option "team ID" teamID ABCDE12345
expect_option "Xcode keeps our build number" manageAppVersionAndBuildNumber false
expect_option "iCloud Production environment" iCloudContainerEnvironment Production
expect_option "uploads symbols" uploadSymbols true
expect_option "external testing allowed by default" testFlightInternalTestingOnly false
"$release" export-options --output "$work/ExportOptions.plist" --internal-only >/dev/null
expect_option "--internal-only" testFlightInternalTestingOnly true

# --- release.py verify-ipa -------------------------------------------------------------

# ipa <name> [overrides...]: an IPA of a fake Blau.app at $work/ipa/<name>.ipa
ipa() {
    name=$1
    shift
    dir="$work/ipa/$name"
    rm -rf "$dir" "$work/ipa/$name.ipa"
    mkdir -p "$dir/Payload"
    "$make_app" "$dir/Payload" "$@" >/dev/null || return 1
    (cd "$dir" && zip -qry "../$name.ipa" Payload)
    echo "$work/ipa/$name.ipa"
}

verify() {
    file=$1
    shift
    "$release" verify-ipa --ipa "$file" --version 0.1.0 --build 42 --allow-ad-hoc-signature "$@"
}

good=$(ipa good)
expect "verify-ipa: a correct App Store build passes" 0 verify "$good" --report "$work/verify-report.md"
expect_text "verify-ipa: writes a Markdown report" "$work/verify-report.md" "| ok | aps-environment is production"
expect "verify-ipa: an ad hoc signature fails without the test-only flag" \
    1 "$release" verify-ipa --ipa "$good" --version 0.1.0 --build 42
expect_text "verify-ipa: says it needs a distribution certificate" "$work/out" "signed with a distribution certificate"
expect "verify-ipa: a different build number fails" 1 verify "$good" --build 43
expect "verify-ipa: a different marketing version fails" 1 "$release" verify-ipa --ipa "$good" \
    --version 0.2.0 --build 42 --allow-ad-hoc-signature

# broken <description> <expected text in the output> <overrides...>
broken() {
    description=$1
    text=$2
    shift 2
    file=$(ipa broken "$@")
    expect "verify-ipa: $description" 1 verify "$file"
    expect_text "verify-ipa: names the problem ($description)" "$work/out" "FAIL - $text"
}

broken "aps-environment development fails" "aps-environment is production" aps=development
broken "a Development iCloud environment fails" "iCloud container environment is Production" \
    container_environment=Development
broken "a development signature (get-task-allow) fails" "Blau.app: get-task-allow is off" get_task_allow=true
broken "a widget with another build number fails" "BlauWidgets.appex: versions match the app" widget_build=41
broken "a Debug build fails" "built with the Release configuration" environment=debug
broken "an unsigned archive (CloudKit off) fails" "CloudKit sync is on" cloudkit=NO
broken "an embedded developer key fails" "no developer xAI key" dev_key=xai-0123456789
broken "missing export compliance fails" "export compliance is declared" encryption=true
broken "a development or ad hoc profile fails" "Blau.app: the provisioning profile is an App Store profile" provisioned_devices=true
broken "another bundle identifier fails" "bundle identifier is com.joeblau.blau" bundle_id=com.example.other
broken "a missing widget extension fails" "embeds the app extensions" no_widget=true

echo "not a zip" >"$work/not.ipa"
expect "verify-ipa: a file that isn't an IPA fails" 1 verify "$work/not.ipa"

# An archive built with CODE_SIGNING_ALLOWED=NO, checked as an .app.
mkdir -p "$work/unsigned"
"$make_app" "$work/unsigned" >/dev/null
codesign --remove-signature "$work/unsigned/Blau.app"
expect "verify-ipa: an unsigned app fails (--app)" 1 "$release" verify-ipa --app "$work/unsigned/Blau.app" \
    --version 0.1.0 --build 42 --allow-ad-hoc-signature
expect_text "verify-ipa: says the signature is missing" "$work/out" "FAIL - Blau.app: code signature is valid"
expect_text "verify-ipa: and the entitlements" "$work/out" "FAIL - aps-environment is production"

# --- testflight.sh ------------------------------------------------------------------

bin="$work/bin"
mkdir -p "$bin"
log="$work/stub.log"

# xcodebuild: archive builds a fake signed app into the archive (with the
# build number from CURRENT_PROJECT_VERSION unless FAKE_BUILD overrides it);
# -exportArchive zips it into an IPA. Records arguments and whether the API
# key file existed while it ran.
cat >"$bin/xcodebuild" <<EOF
#!/bin/sh
echo "xcodebuild \$*" >>"$log"
mode=build; archive=; export_path=; key=; build=
while [ \$# -gt 0 ]; do
    case "\$1" in
        archive) mode=archive ;;
        -exportArchive) mode=export ;;
        -archivePath) archive=\$2; shift ;;
        -exportPath) export_path=\$2; shift ;;
        -authenticationKeyPath) key=\$2; shift ;;
        CURRENT_PROJECT_VERSION=*) build=\${1#CURRENT_PROJECT_VERSION=} ;;
    esac
    shift
done
if [ -n "\$key" ]; then
    if grep -q 'BEGIN PRIVATE KEY' "\$key" 2>/dev/null; then echo "key-present \$mode" >>"$log"; fi
fi
case "\$mode" in
    archive)
        mkdir -p "\$archive/Products/Applications"
        "$make_app" "\$archive/Products/Applications" build="\${FAKE_BUILD:-\$build}" >/dev/null
        ;;
    export)
        mkdir -p "\$export_path/Payload"
        cp -R "\$archive/Products/Applications/Blau.app" "\$export_path/Payload/"
        (cd "\$export_path" && zip -qry Blau.ipa Payload && rm -rf Payload)
        ;;
esac
EOF
cat >"$bin/xcrun" <<EOF
#!/bin/sh
echo "xcrun \$*" >>"$log"
for key in "\$API_PRIVATE_KEYS_DIR"/AuthKey_*.p8; do
    if grep -q 'BEGIN PRIVATE KEY' "\$key" 2>/dev/null; then echo "altool-key \$(basename "\$key")" >>"$log"; fi
done
EOF
cat >"$bin/xcodegen" <<EOF
#!/bin/sh
echo "xcodegen \$*" >>"$log"
EOF
chmod +x "$bin/xcodebuild" "$bin/xcrun" "$bin/xcodegen"

pem="-----BEGIN PRIVATE KEY-----
MIGTAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBHkwdwIBAQQgFAKEFAKEFAKEFAKE
-----END PRIVATE KEY-----"
pem_base64=$(printf '%s\n' "$pem" | base64)
mkdir -p "$work/tmp"

# run_testflight [VAR=value ...]: testflight.sh with the stubs first on PATH.
run_testflight() {
    : >"$log"
    rm -rf "$work/release"
    env PATH="$bin:$PATH" RUNNER_TEMP="$work/tmp" RELEASE_DIR="$work/release" DERIVED_DATA="$work/dd" \
        SKIP_GENERATE=1 VERIFY_FLAGS=--allow-ad-hoc-signature TEAM_ID=ABCDE12345 BUILD_NUMBER=42 \
        ASC_KEY_ID= ASC_ISSUER_ID= ASC_KEY_PATH= ASC_KEY_P8= UPLOAD= INTERNAL_ONLY= FAKE_BUILD= XCODEBUILD_FLAGS= \
        "$@" "$testflight"
}

expect "testflight: TEAM_ID is required" 1 run_testflight TEAM_ID= UPLOAD=0
expect "testflight: TEAM_ID must be a 10-character team ID" 1 run_testflight TEAM_ID=nope UPLOAD=0
expect "testflight: BUILD_NUMBER is required" 1 run_testflight BUILD_NUMBER= UPLOAD=0
expect "testflight: uploading without an API key fails early" 1 run_testflight
expect_text "testflight: says which variables are missing" "$work/err" "ASC_KEY_ID"
if [ -s "$log" ]; then fail "testflight: fails before running xcodebuild"; else pass "testflight: fails before running xcodebuild"; fi
expect "testflight: ASC_KEY_ID without the issuer fails" 1 run_testflight ASC_KEY_ID=ABC123 ASC_KEY_P8="$pem"

expect "testflight: UPLOAD=0 archives, exports and verifies with Xcode's accounts" 0 run_testflight UPLOAD=0
expect_text "testflight: archives the Blau scheme in Release" "$log" "archive -project Blau.xcodeproj -scheme Blau -configuration Release"
expect_text "testflight: for any iOS device" "$log" "-destination generic/platform=iOS"
expect_text "testflight: lets Xcode manage signing" "$log" "-allowProvisioningUpdates"
expect_text "testflight: signs for the team" "$log" "DEVELOPMENT_TEAM=ABCDE12345"
expect_text "testflight: stamps the build number" "$log" "CURRENT_PROJECT_VERSION=42"
expect_text "testflight: keeps any developer xAI key out" "$log" "XAI_DEV_API_KEY="
expect_text "testflight: exports with the generated options" "$log" "-exportOptionsPlist $work/release/ExportOptions.plist"
expect_no_text "testflight: no API key flags without a key" "$log" "-authenticationKeyPath"
expect_no_text "testflight: UPLOAD=0 never calls altool" "$log" "xcrun"
expect_text "testflight: writes the verification report" "$work/release/verify-report.md" "| ok |"
expect_text "testflight: the summary says it was not uploaded" "$work/release/summary.md" "not uploaded"

expect "testflight: uploads with a base64 API key" 0 run_testflight ASC_KEY_ID=ABC123 \
    ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 ASC_KEY_P8="$pem_base64"
expect_text "testflight: passes the key to the archive" "$log" "key-present archive"
expect_text "testflight: passes the key to the export" "$log" "key-present export"
expect_text "testflight: passes the key ID and issuer" "$log" \
    "-authenticationKeyID ABC123 -authenticationKeyIssuerID 00000000-0000-0000-0000-000000000000"
expect_text "testflight: uploads the IPA with altool" "$log" "xcrun altool --upload-package $work/release/export/Blau.ipa --api-key ABC123 --api-issuer 00000000-0000-0000-0000-000000000000"
expect_text "testflight: altool finds AuthKey_<id>.p8" "$log" "altool-key AuthKey_ABC123.p8"
expect_text "testflight: the summary says it was uploaded" "$work/release/summary.md" "uploaded to App Store Connect"
if find "$work/tmp" -name 'blau-asc-key.*' | grep -q .; then
    fail "testflight: deletes the key file when done"
else
    pass "testflight: deletes the key file when done"
fi
if grep -qF -- "MIGTAgEAMBMG" "$work/out" "$work/err" "$log"; then
    fail "testflight: never prints the key"
else
    pass "testflight: never prints the key"
fi

expect "testflight: accepts a PEM API key" 0 run_testflight ASC_KEY_ID=ABC123 \
    ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 ASC_KEY_P8="$pem"
expect_text "testflight: the PEM key reaches altool" "$log" "altool-key AuthKey_ABC123.p8"

printf '%s\n' "$pem" >"$work/AuthKey_FILE.p8"
expect "testflight: accepts ASC_KEY_PATH" 0 run_testflight ASC_KEY_ID=ABC123 \
    ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 ASC_KEY_PATH="$work/AuthKey_FILE.p8"

expect "testflight: a key that isn't a .p8 fails" 1 run_testflight ASC_KEY_ID=ABC123 \
    ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 ASC_KEY_P8="not a key"
expect_no_text "testflight: a bad key never reaches xcodebuild" "$log" "xcodebuild"

expect "testflight: an IPA that fails verification is not uploaded" 1 run_testflight ASC_KEY_ID=ABC123 \
    ASC_ISSUER_ID=00000000-0000-0000-0000-000000000000 ASC_KEY_P8="$pem" FAKE_BUILD=7
expect_no_text "testflight: altool is not called after a failed verification" "$log" "xcrun"

expect "testflight: INTERNAL_ONLY=1 marks the build internal-only" 0 run_testflight UPLOAD=0 INTERNAL_ONLY=1
if [ "$(plutil -extract testFlightInternalTestingOnly raw -o - "$work/release/ExportOptions.plist")" = true ]; then
    pass "testflight: INTERNAL_ONLY reaches the export options"
else
    fail "testflight: INTERNAL_ONLY reaches the export options"
fi

# --- signing-keychain.sh ----------------------------------------------------------------

expect "signing-keychain: setup without a certificate does nothing" \
    0 env CERTIFICATE_P12= KEYCHAIN_DIR="$work/tmp" "$keychain" setup
expect_text "signing-keychain: says Xcode will create a certificate" "$work/out" "no CERTIFICATE_P12"
expect "signing-keychain: cleanup without a keychain is a no-op" 0 env KEYCHAIN_DIR="$work/tmp" "$keychain" cleanup
expect "signing-keychain: rejects unknown commands" 2 "$keychain" install

# --- release.yml guard rails ----------------------------------------------------------------

grep -Ev '^[[:space:]]*#' "$workflow" >"$work/workflow-config"

if grep -Eq '^  push:' "$work/workflow-config" && grep -Eq 'tags: \["v\*"\]' "$work/workflow-config"; then
    pass "release.yml runs on v* tags"
else
    fail "release.yml runs on v* tags"
fi
if grep -q 'XAI_DEV_API_KEY' "$work/workflow-config"; then
    fail "release.yml never references XAI_DEV_API_KEY"
else
    pass "release.yml never references XAI_DEV_API_KEY"
fi
unpinned=$(grep -E '^[[:space:]-]*uses:' "$work/workflow-config" | grep -Ev 'uses: [^@[:space:]]+@[0-9a-f]{40}( |$)' || true)
if [ -z "$unpinned" ]; then
    pass "release.yml pins every action to a commit SHA"
else
    fail "release.yml pins every action to a commit SHA"
    echo "$unpinned" | sed 's/^/       /'
fi
# Secrets only in a step's env (10+ spaces of indentation), never workflow-
# or job-wide.
shallow=$(grep -E 'secrets\.' "$work/workflow-config" | grep -Ev '^ {10,}[A-Z0-9_]+: \$\{\{ secrets\.[A-Z0-9_]+ \}\}$' || true)
if [ -z "$shallow" ]; then
    pass "release.yml maps secrets only into individual steps"
else
    fail "release.yml maps secrets only into individual steps"
    echo "$shallow" | sed 's/^/       /'
fi
if awk '/^  github-release:/{job=1} job && /secrets\./{found=1} END{exit found}' "$work/workflow-config"; then
    pass "release.yml keeps signing secrets out of the job with a write token"
else
    fail "release.yml keeps signing secrets out of the job with a write token"
fi
if grep -Eq '^permissions:' "$work/workflow-config" && awk '/^permissions:/{p=1; next} p && /contents: read/{ok=1} p && /^[^ ]/{exit} END{exit !ok}' "$work/workflow-config"; then
    pass "release.yml is read-only by default"
else
    fail "release.yml is read-only by default"
fi
if awk '/^  testflight:/{job=1} /^  github-release:/{job=0} job && /environment: testflight/{found=1} END{exit !found}' "$work/workflow-config"; then
    pass "release.yml reads its secrets from the testflight environment"
else
    fail "release.yml reads its secrets from the testflight environment"
fi
if grep -Eq '\.ipa|xcarchive|xcresult' "$work/workflow-config"; then
    fail "release.yml never uploads the IPA, archive or result bundles"
    grep -En '\.ipa|xcarchive|xcresult' "$work/workflow-config" | sed 's/^/       /'
else
    pass "release.yml never uploads the IPA, archive or result bundles"
fi
if grep -q 'make testflight' "$work/workflow-config"; then
    pass "release.yml runs the same make target as a local release"
else
    fail "release.yml runs the same make target as a local release"
fi
if command -v actionlint >/dev/null 2>&1; then
    if actionlint "$workflow" >"$work/actionlint" 2>&1; then
        pass "release.yml passes actionlint"
    else
        fail "release.yml passes actionlint"
        sed 's/^/       /' "$work/actionlint"
    fi
else
    echo "skip - actionlint not installed (brew install actionlint)"
fi

echo
echo "$passed passed, $failed failed"
[ "$failed" -eq 0 ]
