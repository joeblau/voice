#!/bin/sh
# Runs the ASR evaluation harness (#32): every engine over the ASR fixtures,
# a table per engine (WER, first-partial and end-of-utterance latency, RTF),
# report.json / report.md / summary.txt in ASR_EVAL_OUTPUT, and the
# regression gate. Behind `make eval-asr` and the nightly `asr-eval` CI job.
# See docs/asr-eval.md.
#
# Environment (all optional; relative paths are from the repository root):
#   ASR_EVAL_MODELS         model store root (default .build/models); the
#                           pinned models are downloaded into it on first use
#   ASR_EVAL_DOWNLOAD       1 (default) downloads missing models, 0 fails instead
#   ASR_EVAL_OUTPUT         report directory (default .build/asr-eval)
#   ASR_EVAL_ENGINES        comma-separated engine ids (default: all)
#   ASR_EVAL_CATEGORIES     comma-separated fixture categories (default: all)
#   ASR_EVAL_MANIFEST       another evaluation set (default: the bundled fixtures)
#   ASR_EVAL_THRESHOLDS     regression gate (default docs/asr-eval/thresholds.json;
#                           empty disables it)
#   ASR_EVAL_GATE           1 (default) fails on a regression, 0 only reports it
#   ASR_EVAL_BASELINE       report to compare with (default docs/asr-eval/baseline.json;
#                           empty disables it)
#   ASR_EVAL_CONFIGURATION  swift build configuration (default debug, which
#                           shares `make test-kit`'s build; `swift test -c
#                           release` doesn't build on main yet, see
#                           docs/asr-eval.md)
#   ASR_EVAL_COMMIT         commit recorded in the report (default GITHUB_SHA or HEAD)
#   ASR_EVAL_COMPUTE_UNITS  default (the app's: Neural Engine with CPU fallback) or
#                           cpu, the streaming engine's models on the CPU only, as
#                           on the CI runners (no Neural Engine)

set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
fixtures="$repo/Packages/BlauKit/Tests/BlauTranscriptionTests/Fixtures/ASR"

absolute() {
    case $1 in
        "") echo "" ;;
        /*) echo "$1" ;;
        *) echo "$repo/$1" ;;
    esac
}

models=$(absolute "${ASR_EVAL_MODELS:-.build/models}")
output=$(absolute "${ASR_EVAL_OUTPUT:-.build/asr-eval}")
thresholds=$(absolute "${ASR_EVAL_THRESHOLDS-docs/asr-eval/thresholds.json}")
baseline=$(absolute "${ASR_EVAL_BASELINE-docs/asr-eval/baseline.json}")
manifest=$(absolute "${ASR_EVAL_MANIFEST:-}")
configuration=${ASR_EVAL_CONFIGURATION:-debug}
commit=${ASR_EVAL_COMMIT:-${GITHUB_SHA:-$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || true)}}

# The bundled fixtures live in Git LFS; a clone without it has pointer files.
if [ -z "$manifest" ]; then
    for wav in "$fixtures"/*.wav; do
        if [ ! -f "$wav" ] || head -c 64 "$wav" | grep -q 'git-lfs'; then
            echo "error: the ASR fixtures are Git LFS pointers, not audio." >&2
            echo "       Run: git lfs install && git lfs pull" >&2
            exit 1
        fi
    done
fi
for file in "$thresholds" "$baseline"; do
    if [ -n "$file" ] && [ ! -f "$file" ]; then
        echo "error: $file doesn't exist" >&2
        exit 1
    fi
done

mkdir -p "$models" "$output"
rm -f "$output/report.json" "$output/report.md" "$output/summary.txt"

echo "ASR evaluation: models in $models, reports in $output ($configuration build)"
status=0
(
    cd "$repo/Packages/BlauKit"
    env BLAU_ASR_EVAL=1 \
        BLAU_ASR_EVAL_MODELS="$models" \
        BLAU_ASR_EVAL_DOWNLOAD="${ASR_EVAL_DOWNLOAD:-1}" \
        BLAU_ASR_EVAL_OUTPUT="$output" \
        BLAU_ASR_EVAL_THRESHOLDS="$thresholds" \
        BLAU_ASR_EVAL_GATE="${ASR_EVAL_GATE:-1}" \
        BLAU_ASR_EVAL_BASELINE="$baseline" \
        BLAU_ASR_EVAL_ENGINES="${ASR_EVAL_ENGINES:-}" \
        BLAU_ASR_EVAL_CATEGORIES="${ASR_EVAL_CATEGORIES:-}" \
        BLAU_ASR_EVAL_MANIFEST="$manifest" \
        BLAU_ASR_EVAL_COMMIT="$commit" \
        BLAU_ASR_EVAL_COMPUTE_UNITS="${ASR_EVAL_COMPUTE_UNITS:-}" \
        swift test -c "$configuration" --filter ASREvaluationRunTests
) || status=$?

echo
if [ -f "$output/summary.txt" ]; then
    cat "$output/summary.txt"
    echo
    echo "Reports: $output/report.json, $output/report.md"
else
    echo "error: the evaluation wrote no report; see the output above." >&2
    [ "$status" -ne 0 ] || status=1
fi
exit "$status"
