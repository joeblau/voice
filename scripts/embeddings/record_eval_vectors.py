#!/usr/bin/env python3
"""Records one model's stored vectors for the retrieval eval set (#64).

Hybrid retrieval (`MemorySearch`, #64) is tuned and tested on #59's
personal eval set. Its tests must be hermetic (no model download), so this
script embeds every eval document and query once with a reference model,
exactly as the memory index stores vectors (the model card's prompts, the
first `--dimensions` components, L2-normalized, int8 with one scale per
vector), and writes the codes to a fixture the Swift tests replay:

    Packages/BlauKit/Tests/BlauMemoryTests/Fixtures/RetrievalEvalVectors/<model>-<dims>d-int8.json

    {"model": ..., "revision": ..., "dimensions": 256,
     "documents": {"<id>": "<base64 int8 codes>", ...},
     "queries": {"<id>": "<base64 int8 codes>", ...}}

Documents are embedded from their `text` with the document prompt, as in
`eval_retrieval.py`, so vector-only Recall@5 over the fixture reproduces
the #59 number in docs/benchmarks.md.

    .venv/bin/python scripts/embeddings/record_eval_vectors.py                     # Qwen3-Embedding-0.6B, 256-d
    .venv/bin/python scripts/embeddings/record_eval_vectors.py --model embeddinggemma-300m

Set HF_HUB_OFFLINE=1 to use the Hugging Face cache only.
"""

from __future__ import annotations

import argparse
import base64
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from candidates import CANDIDATES  # noqa: E402
from eval_retrieval import Encoder, document_texts, query_texts  # noqa: E402
from evalset import REPO, load_eval_set, matryoshka, quantize_int8  # noqa: E402

OUTPUT_DIR = REPO / "Packages/BlauKit/Tests/BlauMemoryTests/Fixtures/RetrievalEvalVectors"


def encode_codes(rows: np.ndarray) -> list[str]:
    return [base64.b64encode(row.astype(np.int8).tobytes()).decode("ascii") for row in rows]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", default="qwen3-embedding-0.6b", choices=sorted(CANDIDATES))
    parser.add_argument("--dimensions", type=int, default=256)
    parser.add_argument("--output", type=Path, help="defaults to the fixture path above")
    args = parser.parse_args()

    candidate = CANDIDATES[args.model]
    eval_set = load_eval_set()
    encoder = Encoder(candidate)
    documents = quantize_int8(matryoshka(encoder.encode(document_texts(eval_set, candidate)), args.dimensions))
    queries = quantize_int8(matryoshka(encoder.encode(query_texts(eval_set, candidate)), args.dimensions))

    output = args.output or OUTPUT_DIR / f"{candidate.key}-{args.dimensions}d-int8.json"
    output.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "model": candidate.key,
        "repo": candidate.repo,
        "revision": candidate.revision,
        "dimensions": args.dimensions,
        "documents": dict(zip(eval_set.document_ids, encode_codes(documents))),
        "queries": dict(zip([q.id for q in eval_set.queries], encode_codes(queries))),
    }
    output.write_text(json.dumps(payload, indent=1, sort_keys=True) + "\n")
    print(f"wrote {len(eval_set.documents)} documents and {len(eval_set.queries)} queries to {output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
