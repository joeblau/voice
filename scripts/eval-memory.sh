#!/bin/sh
# Runs the memory retrieval and answer evaluation harness (#70): hybrid
# retrieval over the memory eval set (Recall@k, MRR, by question type and per
# retrieval system), then, where a language model can run, an LLM reader and
# an LLM judge for end-to-end answer accuracy. Writes report.json, report.md
# and summary.txt to MEMORY_EVAL_OUTPUT and applies the regression gate.
# Behind `make eval-memory` and the nightly `memory-eval` CI job. Text only,
# no audio, no network unless MEMORY_EVAL_READER=xai. See docs/memory-eval.md.
#
# Environment (all optional; relative paths are from the repository root):
#   MEMORY_EVAL_OUTPUT           report directory (default .build/memory-eval)
#   MEMORY_EVAL_READER           auto (default: Apple's on-device model when it
#                                can run here, else retrieval only),
#                                foundation-models, xai or none
#   MEMORY_EVAL_JUDGE            the same choices; auto follows the reader
#   MEMORY_EVAL_XAI_MODEL        the xAI model id, required for xai (the key
#                                comes from XAI_API_KEY; never in CI)
#   MEMORY_EVAL_REQUIRE_ANSWERS  1 fails when no reader can run (default 0)
#   MEMORY_EVAL_TYPES            comma-separated question types (default: all)
#   MEMORY_EVAL_QUESTIONS        comma-separated question ids (default: all)
#   MEMORY_EVAL_LIMIT            only the first N questions
#   MEMORY_EVAL_DATASET          another dataset directory (default: the bundled set)
#   MEMORY_EVAL_VECTORS          another recorded-vectors file, or none for BM25 only
#   MEMORY_EVAL_THRESHOLDS       regression gate (default docs/memory-eval/thresholds.json;
#                                empty disables it)
#   MEMORY_EVAL_GATE             1 (default) fails on a regression, 0 only reports it
#   MEMORY_EVAL_BASELINE         report to compare with (default
#                                docs/memory-eval/baseline.json; empty disables it)
#   MEMORY_EVAL_CONFIGURATION    swift build configuration (default debug, which
#                                shares `make test-kit`'s build)
#   MEMORY_EVAL_COMMIT           commit recorded in the report (default GITHUB_SHA or HEAD)

set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

absolute() {
    case $1 in
        "") echo "" ;;
        none) echo "none" ;;
        /*) echo "$1" ;;
        *) echo "$repo/$1" ;;
    esac
}

output=$(absolute "${MEMORY_EVAL_OUTPUT:-.build/memory-eval}")
thresholds=$(absolute "${MEMORY_EVAL_THRESHOLDS-docs/memory-eval/thresholds.json}")
baseline=$(absolute "${MEMORY_EVAL_BASELINE-docs/memory-eval/baseline.json}")
dataset=$(absolute "${MEMORY_EVAL_DATASET:-}")
vectors=$(absolute "${MEMORY_EVAL_VECTORS:-}")
configuration=${MEMORY_EVAL_CONFIGURATION:-debug}
commit=${MEMORY_EVAL_COMMIT:-${GITHUB_SHA:-$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || true)}}

for file in "$thresholds" "$baseline"; do
    if [ -n "$file" ] && [ ! -f "$file" ]; then
        echo "error: $file doesn't exist" >&2
        exit 1
    fi
done

mkdir -p "$output"
rm -f "$output/report.json" "$output/report.md" "$output/summary.txt"

echo "Memory evaluation: reader ${MEMORY_EVAL_READER:-auto}, reports in $output ($configuration build)"
status=0
(
    cd "$repo/Packages/BlauKit"
    env BLAU_MEMORY_EVAL=1 \
        BLAU_MEMORY_EVAL_OUTPUT="$output" \
        BLAU_MEMORY_EVAL_READER="${MEMORY_EVAL_READER:-auto}" \
        BLAU_MEMORY_EVAL_JUDGE="${MEMORY_EVAL_JUDGE:-auto}" \
        BLAU_MEMORY_EVAL_XAI_MODEL="${MEMORY_EVAL_XAI_MODEL:-}" \
        BLAU_MEMORY_EVAL_REQUIRE_ANSWERS="${MEMORY_EVAL_REQUIRE_ANSWERS:-0}" \
        BLAU_MEMORY_EVAL_TYPES="${MEMORY_EVAL_TYPES:-}" \
        BLAU_MEMORY_EVAL_QUESTIONS="${MEMORY_EVAL_QUESTIONS:-}" \
        BLAU_MEMORY_EVAL_LIMIT="${MEMORY_EVAL_LIMIT:-}" \
        BLAU_MEMORY_EVAL_DATASET="$dataset" \
        BLAU_MEMORY_EVAL_VECTORS="$vectors" \
        BLAU_MEMORY_EVAL_THRESHOLDS="$thresholds" \
        BLAU_MEMORY_EVAL_GATE="${MEMORY_EVAL_GATE:-1}" \
        BLAU_MEMORY_EVAL_BASELINE="$baseline" \
        BLAU_MEMORY_EVAL_COMMIT="$commit" \
        swift test -c "$configuration" --filter MemoryEvalRunTests
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
