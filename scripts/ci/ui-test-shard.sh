#!/usr/bin/env bash
#
# Splits the UI tests (BlauUITests) into shards so CI can run them as parallel
# jobs, each well inside its time limit. Used by `make test-ui UI_SHARD=K/N`
# and .github/workflows/ci.yml; see docs/ci.md.
#
# Usage: scripts/ci/ui-test-shard.sh [--list] K/N
#        scripts/ci/ui-test-shard.sh --check K/N <result.xcresult>
#
# Lists every XCTest method in BlauUITests (a `func testX()` in a class or an
# extension of one), sorts them by "Class/testMethod" and deals them out like
# cards: the i-th test goes to shard (i mod N) + 1. Dealing single tests rather
# than whole classes spreads the slow classes (the accessibility audits take
# about twice as long per test as the rest) evenly over the shards, and a new
# test lands in a shard without anyone editing a list. Every test is in
# exactly one shard. In the default all suite the N shards cover the whole
# target; CI's functional shards plus its performance job do the same.
#
# The listing is read from the sources, so it fails rather than guess when a
# test-like method is not where XCTest would find it: a `func testX()` outside
# a top-level class or extension, or Swift Testing (`@Test`, `@Suite`), which
# `-only-testing:<target>/<class>/<method>` would not select.
#
# Modes:
#   K/N          Print shard K's xcodebuild arguments, one per line:
#                -only-testing:BlauUITests/<Class>/<testMethod>
#   --list K/N   Print shard K's tests, one "<Class>/<testMethod>" per line.
#                K/N = 1/1 lists every test.
#   --check K/N <xcresult>
#                Fail unless the result bundle ran exactly shard K's number of
#                tests (skipped ones included), so a selection that matched
#                nothing cannot pass silently.
#
# Environment:
#   UI_TESTS_DIR          Directory of the UI-test sources (default
#                         <repo>/BlauUITests).
#   UI_TEST_TARGET        Test target name (default BlauUITests).
#   UI_TEST_SUITE         all (default), functional, or performance. The
#                         performance suite is the tap-to-expand benchmark;
#                         functional plus performance covers every test once.
#   XCRESULT_SUMMARY_JSON For --check: read `xcrun xcresulttool get
#                         test-results summary` output from this file instead
#                         of running xcresulttool (tests).

set -euo pipefail

usage() {
    sed -n '3,40p' "$0" | sed 's/^# \{0,1\}//' >&2
}

die() {
    echo "ui-test-shard: $*" >&2
    exit 2
}

mode=args
case "${1:-}" in
    -h | --help)
        usage
        exit 0
        ;;
    --list)
        mode=list
        shift
        ;;
    --check)
        mode=check
        shift
        ;;
    -*)
        die "unknown option '$1'"
        ;;
esac

if [[ "$mode" == check ]]; then
    [[ $# -eq 2 ]] || die "usage: --check K/N <result.xcresult>"
    xcresult="$2"
else
    [[ $# -eq 1 ]] || die "expected one argument K/N, e.g. 2/3"
fi

spec="$1"
if [[ ! "$spec" =~ ^([0-9]+)/([0-9]+)$ ]]; then
    die "shard '$spec' is not K/N, e.g. 2/3"
fi
shard=$((10#${BASH_REMATCH[1]}))
count=$((10#${BASH_REMATCH[2]}))
if ((count < 1 || shard < 1 || shard > count)); then
    die "shard '$spec' is out of range: need 1 <= K <= N"
fi

repo="$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)"
dir="${UI_TESTS_DIR:-$repo/BlauUITests}"
target="${UI_TEST_TARGET:-BlauUITests}"
[[ -d "$dir" ]] || die "no UI-test directory at $dir"

sources=()
while IFS= read -r file; do
    sources+=("$file")
done < <(find "$dir" -name '*.swift' -type f | LC_ALL=C sort)
((${#sources[@]} > 0)) || die "no Swift sources in $dir"

# Prints "<Class>/<testMethod>" for every test method, or fails naming the
# file and line of a test-like method it cannot place. Braces are counted
# after dropping string literals and // comments, so a declaration at depth 0
# is top-level, a method at depth 1 belongs to it, and a type declared deeper
# (a fixture struct inside a test class) is skipped until it closes.
all_tests="$(
    awk '
        FNR == 1 { depth = 0; type = ""; nested = -1; entered = 0 }
        {
            line = $0
            gsub(/"([^"\\]|\\.)*"/, "\"\"", line)
            sub(/\/\/.*/, "", line)
        }
        line ~ /(^|[^A-Za-z0-9_])@(Test|Suite)([^A-Za-z0-9_]|$)/ || line ~ /^[[:space:]]*import[[:space:]]+Testing([^A-Za-z0-9_]|$)/ {
            printf "%s:%d: Swift Testing in the UI tests; shards select XCTest methods only\n", FILENAME, FNR > "/dev/stderr"
            bad = 1
        }
        match(line, /(^|[[:space:]])(class|extension|struct|enum|actor|protocol)[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*/) {
            decl = substr(line, RSTART, RLENGTH)
            sub(/^[[:space:]]+/, "", decl)
            kind = decl
            sub(/[[:space:]].*$/, "", kind)
            sub(/^[a-z]+[[:space:]]+/, "", decl)
            if (decl ~ /^(func|var|let|subscript|init)$/) {
                # "class func", "class var": a member, not a type.
            } else if (depth == 0) {
                if (kind != "class" && kind != "extension") {
                    # Not an XCTestCase: its methods are never tests.
                    type = "-"
                } else if (decl == "XCTestCase") {
                    # A test method here would run in every class: not placeable.
                    type = ""
                } else {
                    type = decl
                }
            } else if (nested < 0) {
                nested = depth
                entered = 0
            }
        }
        match(line, /func[[:space:]]+test[A-Za-z0-9_]*[[:space:]]*\([[:space:]]*\)/) && line !~ /(private|fileprivate|static|class)[[:space:]]+([a-z@]+[[:space:]]+)*func[[:space:]]/ {
            name = substr(line, RSTART, RLENGTH)
            sub(/^func[[:space:]]+/, "", name)
            sub(/[[:space:]]*\(.*$/, "", name)
            if (nested >= 0 || (depth == 1 && type == "-")) {
                # A method of a nested or non-test type.
            } else if (depth == 1 && type != "") {
                print type "/" name
            } else {
                printf "%s:%d: %s() is not a method of a top-level test class\n", FILENAME, FNR, name > "/dev/stderr"
                bad = 1
            }
        }
        {
            opens = gsub(/\{/, "{", line)
            closes = gsub(/\}/, "}", line)
            depth += opens - closes
            if (nested >= 0) {
                if (depth > nested) entered = 1
                if (entered && depth <= nested) nested = -1
            }
        }
        END { exit bad }
    ' "${sources[@]}" | LC_ALL=C sort -u
)" || die "could not list the UI tests in $dir (see above)"

[[ -n "$all_tests" ]] || die "no test methods found in $dir"

suite="${UI_TEST_SUITE:-all}"
performance_test="TopicDetailUITests/testTappingExpandsWithinAHundredMilliseconds"
case "$suite" in
    all) ;;
    functional | performance)
        if ! awk -v test="$performance_test" '$0 == test { found = 1 } END { exit !found }' <<<"$all_tests"; then
            die "the performance test $performance_test is missing; update the suite partition"
        fi
        all_tests="$(awk -v test="$performance_test" -v suite="$suite" '(suite == "performance") == ($0 == test)' <<<"$all_tests")"
        ;;
    *) die "unknown UI_TEST_SUITE '$suite': expected all, functional, or performance" ;;
esac

selected="$(awk -v shard="$shard" -v count="$count" '(NR - 1) % count == shard - 1' <<<"$all_tests")"

case "$mode" in
    list)
        [[ -z "$selected" ]] || printf '%s\n' "$selected"
        ;;
    args)
        [[ -z "$selected" ]] || printf '%s\n' "$selected" | sed "s|^|-only-testing:$target/|"
        ;;
    check)
        expected=0
        [[ -z "$selected" ]] || expected="$(printf '%s\n' "$selected" | wc -l | tr -d ' ')"
        if [[ -n "${XCRESULT_SUMMARY_JSON:-}" ]]; then
            summary="$(cat "$XCRESULT_SUMMARY_JSON")"
        else
            [[ -d "$xcresult" ]] || { echo "ui-test-shard: no result bundle at $xcresult" >&2; exit 1; }
            summary="$(xcrun xcresulttool get test-results summary --path "$xcresult" --compact)"
        fi
        actual="$(jq -r '.totalTestCount // empty' <<<"$summary")"
        [[ -n "$actual" ]] || { echo "ui-test-shard: the summary has no totalTestCount" >&2; exit 1; }
        if [[ "$actual" != "$expected" ]]; then
            echo "ui-test-shard: shard $spec selected $expected tests but the result bundle ran $actual" >&2
            exit 1
        fi
        echo "ui-test-shard: shard $spec ran all $expected of its tests" >&2
        ;;
esac
