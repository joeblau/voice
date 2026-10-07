#!/bin/sh
# Downloads the DeepFilterNet3 streaming Core ML conversion used by the noise
# suppression evaluation (#51, docs/noise-suppression.md), pinned to one
# Hugging Face commit, and checks every file's size and SHA-256.
#
# Usage:
#   scripts/fetch-deepfilternet3.sh [directory]
#
# The default directory is .build/deepfilternet3/<revision>; the script
# prints it on the last line. Keep it out of a ModelStore root such as
# .build/models (ASR_EVAL_MODELS): ModelManager deletes what its manifest
# doesn't list there. Files already present with the right checksum are
# kept. Needs curl and shasum (both ship with macOS).
#
# The model is iky1e/DeepFilterNet3-Streaming-CoreML (DeepFilterNet3 by
# Hendrik Schröter, Apache-2.0 or MIT), about 4.5 MB. Blau doesn't ship it;
# see docs/noise-suppression.md for why.

set -eu

repo=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
repository="iky1e/DeepFilterNet3-Streaming-CoreML"
# Keep in sync with DeepFilterNet3Model.revision (BlauAudio).
revision="dfc12319b3a62d09e9d51aace480c981067b9d7b"
directory=${1:-"$repo/.build/deepfilternet3/$revision"}

# path size sha256
files="DeepFilterNet3-Streaming.mlpackage/Manifest.json 617 1a9e9a167e295175f2ff7704e11e7fdf573afdebee1b5a3ee0e5d72cc0ed89f0
DeepFilterNet3-Streaming.mlpackage/Data/com.apple.CoreML/model.mlmodel 122117 6796e71c000712f22c30a9b8359b139ad363ea425fcae302ab85b85d728a2742
DeepFilterNet3-Streaming.mlpackage/Data/com.apple.CoreML/weights/weight.bin 4276352 1114ff972e25679e7f9707da85eee62659e1bdf50199035ecacba12e4ec0425d
auxiliary.npz 128774 332f9e9c4ee639e9edd61b27a873e84270b1aab1355c728b97efe7bb1d1563a1
LICENSE-APACHE 10837 1eaee808c5fb6b4e895ba30425285a5cdc5dd25bba2cd230f264c2200c331aec
LICENSE-MIT 1083 24e6bb09c928af8d8e56268082f87413247ce36b39dd5d33add2f9893968065e"

checksum() {
    shasum -a 256 "$1" | cut -d ' ' -f 1
}

mkdir -p "$directory"
echo "$files" | while read -r path size sha; do
    target="$directory/$path"
    if [ -f "$target" ] && [ "$(checksum "$target")" = "$sha" ]; then
        continue
    fi
    mkdir -p "$(dirname "$target")"
    echo "downloading $path ($size bytes)" >&2
    curl --fail --silent --show-error --location --retry 3 \
        --output "$target.partial" \
        "https://huggingface.co/$repository/resolve/$revision/$path"
    actual_size=$(wc -c < "$target.partial" | tr -d ' ')
    actual_sha=$(checksum "$target.partial")
    if [ "$actual_size" != "$size" ] || [ "$actual_sha" != "$sha" ]; then
        rm -f "$target.partial"
        echo "error: $path: expected $size bytes, sha256 $sha; got $actual_size bytes, $actual_sha" >&2
        exit 1
    fi
    mv "$target.partial" "$target"
done

echo "$directory"
