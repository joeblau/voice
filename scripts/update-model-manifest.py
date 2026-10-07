#!/usr/bin/env python3
"""Regenerates Blau's pinned on-device model manifest.

Blau downloads its Core ML models (Silero VAD, Parakeet realtime EOU,
Parakeet TDT v3, WeSpeaker) from Hugging Face at runtime. The app never asks
Hugging Face what to download: it reads a manifest compiled into BlauKit that
pins each model to an immutable repository commit and lists every file with
its exact size and SHA-256. This script writes that manifest:

    Packages/BlauKit/Sources/BlauTranscription/Models/PinnedModelManifest.swift

Usage:
    scripts/update-model-manifest.py            # re-pin to the revisions below
    scripts/update-model-manifest.py --latest   # move every pin to the repo's
                                                # current commit, then rewrite
                                                # this script's pins by hand

For Git LFS files the SHA-256 comes from the LFS pointer in the tree listing.
Small non-LFS files (JSON, model.mil) are downloaded at the pinned revision
and hashed here. Needs network access and python3; no third-party modules.

Bump a pin only after checking the new revision against the FluidAudio
version in Packages/BlauKit/Package.resolved (file names and tensor shapes
must match what FluidAudio's loaders expect). See docs/models.md.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys
import urllib.parse
import urllib.request

HF = "https://huggingface.co"

# Each model: the Swift `ModelID` case, the Hugging Face repository, the pinned
# commit, the directory inside the repo that holds the model (stripped from the
# local path), and the top-level entries to fetch from it. A `.mlmodelc` entry
# pulls every file in the compiled bundle.
MODELS = [
    {
        "id": "sileroVAD",
        "repo": "FluidInference/silero-vad-coreml",
        "revision": "b419383c55c110e2c9271fa6ee0ea83d03c70d96",
        "directory": "",
        # FluidAudio 0.17.5 `ModelNames.VAD.sileroVadFile`.
        "entries": ["silero-vad-unified-256ms-v6.2.1.mlmodelc"],
    },
    {
        "id": "parakeetRealtimeEOU",
        "repo": "FluidInference/parakeet-realtime-eou-120m-coreml",
        "revision": "40a23f4c0b333aa17ad8c0f2ea47ec2347f2f355",
        "directory": "320ms",
        # `ModelNames.ParakeetEOU.requiredModels`, loaded by
        # `StreamingEouAsrManager.loadModels(from:)`.
        "entries": [
            "streaming_encoder.mlmodelc",
            "decoder.mlmodelc",
            "joint_decision.mlmodelc",
            "vocab.json",
        ],
    },
    {
        "id": "parakeetTDTv3",
        "repo": "FluidInference/parakeet-tdt-0.6b-v3-coreml",
        "revision": "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe",
        "directory": "",
        # `ModelNames.ASR.requiredModelsV3(precision: .int8)` plus the shared
        # vocabulary, loaded by `AsrModels.loadLocal(from:version: .v3)`.
        "entries": [
            "Preprocessor.mlmodelc",
            "Encoder.mlmodelc",
            "Decoder.mlmodelc",
            "JointDecisionv3.mlmodelc",
            "parakeet_vocab.json",
        ],
    },
    {
        "id": "speakerEmbedding",
        "repo": "FluidInference/speaker-diarization-coreml",
        # The commit FluidAudio 0.17.5 itself pins in `Repo.diarizer.revision`.
        "revision": "df2625ac79a7ac6b65ad868fee6d80f320da4232",
        "directory": "",
        # `ModelNames.Diarizer.embeddingFile`: WeSpeaker ResNet34, 256-d.
        "entries": ["wespeaker_v2.mlmodelc"],
    },
    # The shared text embedding model (#59, #60): the `hosting/` folder
    # `scripts/embeddings/convert_coreml.py` writes, loaded by BlauMemory's
    # `TextEmbeddingBundle` (not FluidAudio). Uncomment once the converted
    # EmbeddingGemma is hosted, with its repository and full commit SHA
    # (docs/models.md, "The text embedding model is not pinned yet").
    # {
    #     "id": "textEmbedding",
    #     "repo": "<owner>/blau-embeddinggemma-300m-coreml",
    #     "revision": "<full commit SHA>",
    #     "directory": "",
    #     "entries": [
    #         "blau-embedding.json",
    #         "EmbeddingGemma300M.mlmodelc",
    #         "EmbeddingGemma300M.token-embeddings.i8",
    #         "tokenizer.json",
    #         "NOTICE",
    #     ],
    # },
]

OUTPUT = (
    pathlib.Path(__file__).resolve().parent.parent
    / "Packages/BlauKit/Sources/BlauTranscription/Models/PinnedModelManifest.swift"
)


def get_json(url: str):
    request = urllib.request.Request(url, headers={"User-Agent": "blau-manifest/1"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def quote(path: str) -> str:
    return urllib.parse.quote(path, safe="/")


def list_tree(repo: str, revision: str, path: str) -> list[dict]:
    """Every file under `path` (recursive), following pagination."""
    files: list[dict] = []
    url = f"{HF}/api/models/{repo}/tree/{revision}/{quote(path)}?recursive=true"
    while url:
        request = urllib.request.Request(url, headers={"User-Agent": "blau-manifest/1"})
        with urllib.request.urlopen(request, timeout=60) as response:
            items = json.load(response)
            url = next_link(response.headers.get("Link"))
        files += [item for item in items if item["type"] == "file"]
    return files


def next_link(header: str | None) -> str | None:
    if not header:
        return None
    for part in header.split(","):
        if 'rel="next"' in part:
            return part[part.index("<") + 1 : part.index(">")]
    return None


def sha256_of_remote(repo: str, revision: str, path: str) -> str:
    url = f"{HF}/{repo}/resolve/{revision}/{quote(path)}"
    request = urllib.request.Request(url, headers={"User-Agent": "blau-manifest/1"})
    digest = hashlib.sha256()
    with urllib.request.urlopen(request, timeout=300) as response:
        while chunk := response.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def resolve_files(model: dict) -> list[dict]:
    repo, revision, directory = model["repo"], model["revision"], model["directory"]
    prefix = f"{directory}/" if directory else ""
    out: list[dict] = []
    for entry in model["entries"]:
        remote = prefix + entry
        if entry.endswith(".mlmodelc"):
            items = list_tree(repo, revision, remote)
            if not items:
                sys.exit(f"{repo}@{revision}: {remote} is empty or missing")
        else:
            parent = remote.rsplit("/", 1)[0] if "/" in remote else ""
            listing = get_json(f"{HF}/api/models/{repo}/tree/{revision}/{quote(parent)}")
            items = [item for item in listing if item["path"] == remote and item["type"] == "file"]
            if not items:
                sys.exit(f"{repo}@{revision}: {remote} not found")
        for item in items:
            size = item["size"]
            lfs = item.get("lfs")
            if lfs:
                sha256 = lfs["oid"]
                size = lfs["size"]
            else:
                sha256 = sha256_of_remote(repo, revision, item["path"])
            out.append(
                {
                    "path": item["path"][len(prefix) :],
                    "remotePath": item["path"],
                    "size": size,
                    "sha256": sha256,
                }
            )
    return sorted(out, key=lambda f: f["path"])


def swift_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render(models: list[dict]) -> str:
    lines = [
        "// Generated by scripts/update-model-manifest.py. Do not edit by hand:",
        "// change the pins in the script and run it again. See docs/models.md.",
        "",
        "extension ModelManifest {",
        "    /// The models this build of Blau downloads, each pinned to an",
        "    /// immutable Hugging Face commit with per-file sizes and SHA-256s.",
        "    public static let pinned = ModelManifest(models: [",
    ]
    for model in models:
        total = sum(f["size"] for f in model["files"])
        lines += [
            f"        // {model['repo']}@{model['revision'][:12]}"
            + (f" ({model['directory']})" if model["directory"] else "")
            + f": {len(model['files'])} files, {total:,} bytes",
            "        ModelDescriptor(",
            f"            id: .{model['id']},",
            f"            repository: {swift_string(model['repo'])},",
            f"            revision: {swift_string(model['revision'])},",
            f"            remoteDirectory: {swift_string(model['directory'])},",
            "            files: [",
        ]
        for f in model["files"]:
            lines += [
                "                ModelFile(",
                f"                    path: {swift_string(f['path'])},",
                f"                    size: {f['size']},",
                f"                    sha256: {swift_string(f['sha256'])}",
                "                ),",
            ]
        lines += ["            ]", "        ),"]
    lines += ["    ])", "}", ""]
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--latest",
        action="store_true",
        help="print each repository's current commit instead of writing the manifest",
    )
    args = parser.parse_args()

    if args.latest:
        for model in MODELS:
            info = get_json(f"{HF}/api/models/{model['repo']}")
            marker = "" if info["sha"] == model["revision"] else "   <- differs from the pin"
            print(f"{model['id']:<22} {info['sha']}  ({info.get('lastModified', '?')}){marker}")
        return

    resolved = []
    for model in MODELS:
        print(f"Resolving {model['id']} at {model['repo']}@{model['revision'][:12]}...", file=sys.stderr)
        resolved.append({**model, "files": resolve_files(model)})
    OUTPUT.write_text(render(resolved))
    print(f"Wrote {OUTPUT}", file=sys.stderr)


if __name__ == "__main__":
    main()
