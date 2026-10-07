#!/usr/bin/env python3
"""Records one model's stored vectors for the memory evaluation set (#70).

The memory evaluation (docs/memory-eval.md) builds the memory index from
`Packages/BlauKit/Tests/BlauMemoryTests/Fixtures/MemoryEval` through the
app's own chunker, so the texts to embed are the chunks' key texts, which
only the Swift code knows. Export them first, then embed them here, exactly
as the memory index stores vectors (the model card's prompts, the first
`--dimensions` components, L2-normalized, int8 with one scale per vector):

    cd Packages/BlauKit && BLAU_MEMORY_EVAL_EXPORT=/tmp/memory-eval-texts.json \\
        swift test --filter MemoryEvalExportTests
    .venv/bin/python scripts/embeddings/record_memory_eval_vectors.py /tmp/memory-eval-texts.json

It writes

    Packages/BlauKit/Tests/BlauMemoryTests/Fixtures/MemoryEvalVectors/<model>-<dims>d-int8.json

    {"model": ..., "modelVersion": "<model>-<dims>d-int8@<revision[:8]>", "revision": ..., "dimensions": 256,
     "documents": {"<SHA-256 of the key text>": "<base64 int8 codes>", ...},
     "queries": {"<SHA-256 of the question>": "<base64 int8 codes>", ...}}

which `MemoryEvalRecordedEmbeddings` replays in the hermetic tests.

Set HF_HUB_OFFLINE=1 to use the Hugging Face cache only.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from candidates import CANDIDATES  # noqa: E402
from eval_retrieval import Encoder  # noqa: E402
from evalset import REPO, matryoshka, quantize_int8  # noqa: E402

OUTPUT_DIR = REPO / "Packages/BlauKit/Tests/BlauMemoryTests/Fixtures/MemoryEvalVectors"


def key(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def encode_codes(rows: np.ndarray) -> list[str]:
    return [base64.b64encode(row.astype(np.int8).tobytes()).decode("ascii") for row in rows]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("texts", type=Path, help="the JSON MemoryEvalExportTests wrote")
    parser.add_argument("--model", default="qwen3-embedding-0.6b", choices=sorted(CANDIDATES))
    parser.add_argument("--dimensions", type=int, default=256)
    parser.add_argument("--output", type=Path, help="defaults to the fixture path above")
    args = parser.parse_args()

    exported = json.loads(args.texts.read_text())
    documents = sorted(set(exported["documents"]))
    queries = sorted(set(exported["queries"]))

    candidate = CANDIDATES[args.model]
    encoder = Encoder(candidate)
    document_codes = quantize_int8(
        matryoshka(encoder.encode([candidate.document_prompt + text for text in documents]), args.dimensions)
    )
    query_codes = quantize_int8(
        matryoshka(encoder.encode([candidate.query_prompt + text for text in queries]), args.dimensions)
    )

    output = args.output or OUTPUT_DIR / f"{candidate.key}-{args.dimensions}d-int8.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "model": candidate.key,
        "modelVersion": f"{candidate.key}-{args.dimensions}d-int8@{candidate.revision[:8]}",
        "repo": candidate.repo,
        "revision": candidate.revision,
        "dimensions": args.dimensions,
        "documents": dict(zip([key(text) for text in documents], encode_codes(document_codes))),
        "queries": dict(zip([key(text) for text in queries], encode_codes(query_codes))),
    }
    output.write_text(json.dumps(payload, indent=1, sort_keys=True) + "\n")
    print(f"wrote {len(documents)} key texts and {len(queries)} questions to {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
