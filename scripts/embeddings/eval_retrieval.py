#!/usr/bin/env python3
"""Runs Blau's personal retrieval eval (#59) on the reference (PyTorch) models.

For every candidate in `candidates.py` this embeds the eval set's 216
documents and 200 queries with the model card's prompts, then scores
retrieval at every Matryoshka width, as float32 and as the int8 vectors the
memory index stores (#62). It also scores BM25 alone and BM25 fused with each
model by reciprocal rank fusion (the hybrid retrieval of #64), and times
single-text embedding on this Mac's CPU (a reference, not an iPhone number:
the Core ML numbers come from `convert_coreml.py` and the Swift harness).

    uv venv --python 3.12 .venv && uv pip install --python .venv/bin/python -r scripts/embeddings/requirements.txt
    .venv/bin/python scripts/embeddings/eval_retrieval.py                     # every candidate
    .venv/bin/python scripts/embeddings/eval_retrieval.py --only qwen3-embedding-0.6b
    .venv/bin/python scripts/embeddings/eval_retrieval.py --output results.json

Gated models (EmbeddingGemma) need a Hugging Face token whose account has
accepted the model's terms (`hf auth login`); without access the candidate
is reported as skipped. Models download into the Hugging Face cache once
(about 1.3 GB in total).
"""

from __future__ import annotations

import argparse
import json
import platform
import statistics
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from candidates import CANDIDATES, Candidate  # noqa: E402
from evalset import (  # noqa: E402
    EvalSet,
    bm25_rankings,
    evaluate_rankings,
    load_eval_set,
    matryoshka,
    quantize_int8,
    rrf,
    vector_rankings,
)


class Encoder:
    """A loaded reference model that embeds lists of texts (no prompt added here)."""

    def __init__(self, candidate: Candidate):
        from huggingface_hub import snapshot_download

        self.candidate = candidate
        path = snapshot_download(candidate.repo, revision=candidate.revision)
        if candidate.runtime == "model2vec":
            from model2vec import StaticModel

            self.model = StaticModel.from_pretrained(path)
            self.parameters = int(self.model.embedding.shape[0] * self.model.embedding.shape[1])
        else:
            import torch
            from sentence_transformers import SentenceTransformer

            torch.set_grad_enabled(False)
            self.model = SentenceTransformer(path, device="cpu")
            self.model.eval()
            self.parameters = sum(p.numel() for p in self.model.parameters())

    def encode(self, texts: list[str]) -> np.ndarray:
        if self.candidate.runtime == "model2vec":
            return np.asarray(self.model.encode(texts), dtype=np.float32)
        return np.asarray(
            self.model.encode(texts, batch_size=16, convert_to_numpy=True, normalize_embeddings=False),
            dtype=np.float32,
        )


def query_texts(eval_set: EvalSet, candidate: Candidate) -> list[str]:
    return [candidate.query_prompt + q.text for q in eval_set.queries]


def document_texts(eval_set: EvalSet, candidate: Candidate) -> list[str]:
    return [candidate.document_prompt + d.text for d in eval_set.documents]


def time_single(encoder: Encoder, texts: list[str], warmup: int = 3) -> dict[str, float]:
    """p50 / p95 milliseconds to embed one text at a time (CPU reference)."""
    times = []
    for i, text in enumerate(texts):
        start = time.perf_counter()
        encoder.encode([text])
        if i >= warmup:
            times.append((time.perf_counter() - start) * 1000)
    times.sort()
    return {
        "p50": round(statistics.median(times), 2),
        "p95": round(times[int(0.95 * (len(times) - 1))], 2),
        "count": len(times),
    }


def evaluate_candidate(eval_set: EvalSet, candidate: Candidate, lexical: dict) -> dict:
    encoder = Encoder(candidate)
    start = time.perf_counter()
    documents = encoder.encode(document_texts(eval_set, candidate))
    queries = encoder.encode(query_texts(eval_set, candidate))
    encode_seconds = time.perf_counter() - start
    if not (np.isfinite(documents).all() and np.isfinite(queries).all()):
        raise RuntimeError(f"{candidate.key}: non-finite embeddings")

    variants = {}
    for width in candidate.dimensions:
        for precision in ("float32", "int8"):
            q = matryoshka(queries, width)
            d = matryoshka(documents, width)
            if precision == "int8":
                q, d = quantize_int8(q), quantize_int8(d)
            rankings = vector_rankings(eval_set, q, d)
            variants[f"{width}d-{precision}"] = {
                "vector": evaluate_rankings(eval_set, rankings),
                "hybrid": evaluate_rankings(eval_set, rrf([rankings, lexical])),
            }

    sample = [candidate.document_prompt + d.text for d in eval_set.documents[:43]]
    return {
        "repo": candidate.repo,
        "revision": candidate.revision,
        "license": candidate.license,
        "parameters": encoder.parameters,
        "fullDimensions": int(documents.shape[1]),
        "queryPrompt": candidate.query_prompt,
        "documentPrompt": candidate.document_prompt,
        "encodeAllSeconds": round(encode_seconds, 2),
        "cpuSingleTextMs": time_single(encoder, sample),
        "variants": variants,
    }


def summary_table(results: dict) -> str:
    lines = [
        "| Model | Vector | Recall@5 | Hit@5 | MRR@10 | Hybrid (BM25 + RRF) Recall@5 / MRR@10 |",
        "| --- | --- | --- | --- | --- | --- |",
    ]
    bm25 = results["bm25"]["overall"]
    lines.append(f"| BM25 only | n/a | {bm25['recall@5']:.3f} | {bm25['hit@5']:.3f} | {bm25['mrr@10']:.3f} | n/a |")
    for key, result in results["candidates"].items():
        if "skipped" in result:
            lines.append(f"| {key} | skipped: {result['skipped']} | | | | |")
            continue
        for variant, scores in result["variants"].items():
            v, h = scores["vector"]["overall"], scores["hybrid"]["overall"]
            lines.append(
                f"| {key} | {variant} | {v['recall@5']:.3f} | {v['hit@5']:.3f} | {v['mrr@10']:.3f} "
                f"| {h['recall@5']:.3f} / {h['mrr@10']:.3f} |"
            )
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", action="append", choices=sorted(CANDIDATES), help="candidate(s) to run")
    parser.add_argument("--output", type=Path, help="write the full results as JSON here")
    args = parser.parse_args()

    eval_set = load_eval_set()
    lexical = bm25_rankings(eval_set)
    results = {
        "evalSet": {"documents": len(eval_set.documents), "queries": len(eval_set.queries)},
        "machine": {"platform": platform.platform(), "processor": platform.processor()},
        "bm25": evaluate_rankings(eval_set, lexical),
        "candidates": {},
    }
    for key in args.only or list(CANDIDATES):
        candidate = CANDIDATES[key]
        print(f"== {key}", file=sys.stderr)
        try:
            results["candidates"][key] = evaluate_candidate(eval_set, candidate, lexical)
        except OSError as error:  # gated repo without access, or offline
            if candidate.gated or "offline" in str(error).lower() or "401" in str(error) or "403" in str(error):
                results["candidates"][key] = {"skipped": f"cannot download {candidate.repo}: {type(error).__name__}"}
            else:
                raise

    if args.output:
        args.output.write_text(json.dumps(results, indent=2) + "\n")
    print(summary_table(results))
    return 0


if __name__ == "__main__":
    sys.exit(main())
