#!/usr/bin/env bash
#
# Lints or formats the repo's Swift sources with swift-format, using the
# repo-root `.swift-format` configuration. `make lint`, `make format` and the
# pre-commit hook all go through this script so they agree on the file set,
# the tool and the flags.
#
# Usage:
#   scripts/swift-format.sh lint [--staged] [<path>...]
#   scripts/swift-format.sh format [--staged] [<path>...]
#
#   lint       Report style findings. Every finding is an error (--strict).
#   format     Rewrite files in place.
#   --staged   Only the Swift files staged for commit. `lint --staged` checks
#              the staged (index) contents, not the working copy, so it
#              matches exactly what is about to be committed.
#   <path>     Limit the run to these files or directories.
#
# The file set is every `.swift` file git tracks or would track (tracked plus
# untracked-but-not-ignored), so build output such as `.build/` and SwiftPM
# checkouts is never touched.
#
# Environment:
#   SWIFT_FORMAT  Command to run instead of the detected tool, e.g.
#                 SWIFT_FORMAT="swift format". By default the swift-format
#                 shipped with the selected Xcode toolchain is used (the same
#                 one Xcode's Editor > Format File uses), then one on PATH.

set -euo pipefail

usage() {
    sed -n '7,18p' "$0" | sed 's/^# \{0,1\}//' >&2
    exit 2
}

root="$(git rev-parse --show-toplevel)"
cd "$root"
config="$root/.swift-format"

[[ $# -ge 1 ]] || usage
mode="$1"
shift
case "$mode" in
    lint | format) ;;
    -h | --help) usage ;;
    *)
        echo "swift-format.sh: unknown mode '$mode'" >&2
        usage
        ;;
esac

staged=0
paths=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --staged) staged=1 ;;
        -h | --help) usage ;;
        -*)
            echo "swift-format.sh: unknown option '$1'" >&2
            usage
            ;;
        *) paths+=("$1") ;;
    esac
    shift
done

# Resolve the swift-format command.
tool=()
if [[ -n "${SWIFT_FORMAT:-}" ]]; then
    read -r -a tool <<<"$SWIFT_FORMAT"
elif command -v xcrun >/dev/null 2>&1 && toolchain_path="$(xcrun --find swift-format 2>/dev/null)"; then
    tool=("$toolchain_path")
elif command -v swift-format >/dev/null 2>&1; then
    tool=(swift-format)
else
    echo "swift-format.sh: swift-format not found." >&2
    echo "  It ships with Xcode 16 and later; select one with 'xcode-select -s'," >&2
    echo "  or install it with 'brew install swift-format', or set SWIFT_FORMAT." >&2
    exit 127
fi

# Collect the Swift files to process, NUL-safe and bash 3.2 compatible.
files=()
if [[ $staged -eq 1 ]]; then
    list_cmd=(git diff --cached --name-only -z --diff-filter=ACMR --)
else
    list_cmd=(git ls-files -z --cached --others --exclude-standard --)
fi
while IFS= read -r -d '' file; do
    [[ "$file" == *.swift ]] || continue
    # Staged files are read from the index; others must exist on disk
    # (a tracked file deleted in the working tree is skipped).
    if [[ $staged -eq 1 && "$mode" == lint ]] || [[ -f "$file" ]]; then
        files+=("$file")
    fi
done < <("${list_cmd[@]}" ${paths[@]+"${paths[@]}"})

if [[ ${#files[@]} -eq 0 ]]; then
    echo "swift-format.sh: no Swift files to $mode."
    exit 0
fi

if [[ "$mode" == format ]]; then
    printf '%s\0' "${files[@]}" |
        xargs -0 "${tool[@]}" format --in-place --parallel --configuration "$config"
    echo "swift-format.sh: formatted ${#files[@]} Swift file(s)."
    exit 0
fi

if [[ $staged -eq 1 ]]; then
    # Lint the index contents through stdin so partially staged files are
    # judged by what will actually be committed.
    status=0
    for file in "${files[@]}"; do
        git show ":$file" |
            "${tool[@]}" lint --strict --configuration "$config" --assume-filename "$file" - || status=1
    done
else
    status=0
    printf '%s\0' "${files[@]}" |
        xargs -0 "${tool[@]}" lint --strict --parallel --configuration "$config" || status=1
fi

if [[ $status -ne 0 ]]; then
    echo "swift-format.sh: lint failed. Run 'make format' to fix formatting, then fix the remaining findings by hand." >&2
    exit 1
fi
echo "swift-format.sh: ${#files[@]} Swift file(s) lint clean."
