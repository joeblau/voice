#!/bin/sh
# Runs the ASR side of the noise suppression A/B (#51): every ASR engine on
# the ASR fixtures alone and behind each noise suppressor (DeepFilterNet3,
# Apple's AUSoundIsolation), plus each suppressor's compute cost. Behind
# `make eval-noise`. See docs/noise-suppression.md; the voice ID side runs
# through VoiceIDEvaluationRunTests with BLAU_VOICEID_EVAL_SUPPRESSORS.
#
# Environment (all optional; relative paths are from the repository root):
#   ASR_EVAL_MODELS         ASR model store root (default .build/models); the
#                           pinned models are downloaded into it on first use
#   ASR_EVAL_DOWNLOAD       1 (default) downloads missing models, 0 fails instead
#   ASR_EVAL_ENGINES        comma-separated base engine ids (default: all)
#   ASR_EVAL_CATEGORIES     comma-separated fixture categories (default: all)
#   DFN3_MODEL_DIR          DeepFilterNet3 model directory (default: fetched
#                           into .build/deepfilternet3/<revision>)
#   NOISE_EVAL_SUPPRESSORS  comma-separated suppressors (default: all)
#   NOISE_EVAL_OUTPUT       report directory (default .build/noise-eval)

set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

absolute() {
    case $1 in
        "") echo "" ;;
        /*) echo "$1" ;;
        *) echo "$repo/$1" ;;
    esac
}

models=$(absolute "${ASR_EVAL_MODELS:-.build/models}")
output=$(absolute "${NOISE_EVAL_OUTPUT:-.build/noise-eval}")
if [ -n "${DFN3_MODEL_DIR:-}" ]; then
    dfn3=$(absolute "$DFN3_MODEL_DIR")
else
    dfn3=$("$repo/scripts/fetch-deepfilternet3.sh" | tail -n 1)
fi

fixtures="$repo/Packages/BlauKit/Tests/BlauTranscriptionTests/Fixtures/ASR"
for wav in "$fixtures"/*.wav; do
    if [ ! -f "$wav" ] || head -c 64 "$wav" | grep -q 'git-lfs'; then
        echo "error: the ASR fixtures are Git LFS pointers, not audio. Run: git lfs install && git lfs pull" >&2
        exit 1
    fi
done

mkdir -p "$models" "$output"
rm -f "$output/report.json" "$output/report.md" "$output/comparison.md" "$output/cost.md" "$output/cost.json"
echo "Noise suppression A/B: ASR models in $models, DeepFilterNet3 in $dfn3, reports in $output"
(
    cd "$repo/Packages/BlauKit"
    env BLAU_NOISE_EVAL=1 \
        BLAU_ASR_EVAL_MODELS="$models" \
        BLAU_ASR_EVAL_DOWNLOAD="${ASR_EVAL_DOWNLOAD:-1}" \
        BLAU_ASR_EVAL_ENGINES="${ASR_EVAL_ENGINES:-}" \
        BLAU_ASR_EVAL_CATEGORIES="${ASR_EVAL_CATEGORIES:-}" \
        BLAU_DFN3_MODEL_DIR="$dfn3" \
        BLAU_NOISE_EVAL_SUPPRESSORS="${NOISE_EVAL_SUPPRESSORS:-}" \
        BLAU_NOISE_EVAL_OUTPUT="$output" \
        swift test --filter NoiseSuppressionEvaluationRunTests
)
echo
cat "$output/comparison.md"
echo
cat "$output/cost.md"
