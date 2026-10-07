"""Blau's personal retrieval eval set, metrics, BM25 and fusion (#59).

Shared by `eval_retrieval.py` and `convert_coreml.py`. Everything here
mirrors the Swift side in `Packages/BlauKit/Sources/BlauMemory/Evaluation`
so the numbers agree:

- the eval set is the JSON in
  `Packages/BlauKit/Tests/BlauMemoryTests/Fixtures/RetrievalEval/`;
- a stored vector is the embedding's first `dimensions` components,
  L2-normalized, then quantized to int8 with one scale per vector
  (`MatryoshkaEmbedding` in Swift);
- ranking is by cosine over the int8 codes, ties broken by document order;
- Recall@k is |relevant in top k| / |relevant|, Hit@k is "any relevant in top
  k", MRR@10 is 1 / rank of the first relevant document within the top 10.

Only numpy is needed here.
"""

from __future__ import annotations

import json
import math
import re
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
EVAL_DIR = REPO / "Packages/BlauKit/Tests/BlauMemoryTests/Fixtures/RetrievalEval"


@dataclass(frozen=True)
class Document:
    id: str
    kind: str
    text: str
    title: str | None = None
    date: str | None = None


@dataclass(frozen=True)
class Query:
    id: str
    text: str
    relevant: tuple[str, ...]
    category: str
    style: str


@dataclass
class EvalSet:
    documents: list[Document]
    queries: list[Query]

    @property
    def document_ids(self) -> list[str]:
        return [d.id for d in self.documents]


def load_eval_set(directory: Path = EVAL_DIR) -> EvalSet:
    """Loads and validates every `*.json` file in `directory` (sorted by name)."""
    documents: list[Document] = []
    queries: list[Query] = []
    for path in sorted(directory.glob("*.json")):
        data = json.loads(path.read_text())
        category = data["category"]
        for d in data["documents"]:
            documents.append(Document(d["id"], d["kind"], d["text"], d.get("title"), d.get("date")))
        for q in data["queries"]:
            queries.append(Query(q["id"], q["text"], tuple(q["relevant"]), category, q.get("style", "paraphrase")))
    ids = [d.id for d in documents]
    if len(set(ids)) != len(ids):
        raise ValueError("duplicate document ids")
    known = set(ids)
    for q in queries:
        missing = [r for r in q.relevant if r not in known]
        if missing or not q.relevant:
            raise ValueError(f"{q.id}: unknown or missing relevant documents {missing}")
    return EvalSet(documents, queries)


# MARK: - Vectors


def matryoshka(vectors: np.ndarray, dimensions: int | None) -> np.ndarray:
    """First `dimensions` components of each row, L2-normalized."""
    kept = vectors[:, :dimensions] if dimensions else vectors
    norms = np.linalg.norm(kept, axis=1, keepdims=True)
    norms[norms == 0] = 1
    return kept / norms


def quantize_int8(vectors: np.ndarray) -> np.ndarray:
    """Symmetric per-vector int8 codes (scale dropped: cosine ignores it)."""
    largest = np.max(np.abs(vectors), axis=1, keepdims=True)
    largest[largest == 0] = 1
    return np.clip(np.rint(vectors / (largest / 127)), -127, 127).astype(np.int8)


def cosine_scores(queries: np.ndarray, documents: np.ndarray) -> np.ndarray:
    q = queries.astype(np.float64)
    d = documents.astype(np.float64)
    q /= np.maximum(np.linalg.norm(q, axis=1, keepdims=True), 1e-12)
    d /= np.maximum(np.linalg.norm(d, axis=1, keepdims=True), 1e-12)
    return q @ d.T


def rankings_from_scores(scores: np.ndarray) -> list[list[int]]:
    """Document indices by descending score; ties keep document order."""
    return [list(np.lexsort((np.arange(row.size), -row))) for row in scores]


# MARK: - Metrics


@dataclass
class Metrics:
    count: int = 0
    recall_at_5: float = 0
    hit_at_5: float = 0
    hit_at_1: float = 0
    recall_at_10: float = 0
    mrr_at_10: float = 0
    ndcg_at_10: float = 0

    def as_dict(self) -> dict[str, float]:
        return {
            "count": self.count,
            "recall@5": round(self.recall_at_5, 4),
            "hit@1": round(self.hit_at_1, 4),
            "hit@5": round(self.hit_at_5, 4),
            "recall@10": round(self.recall_at_10, 4),
            "mrr@10": round(self.mrr_at_10, 4),
            "ndcg@10": round(self.ndcg_at_10, 4),
        }


def query_metrics(ranking: list[str], relevant: set[str]) -> dict[str, float]:
    def recall(k: int) -> float:
        return len(relevant.intersection(ranking[:k])) / len(relevant)

    first = next((i for i, doc in enumerate(ranking[:10]) if doc in relevant), None)
    dcg = sum(1 / math.log2(i + 2) for i, doc in enumerate(ranking[:10]) if doc in relevant)
    ideal = sum(1 / math.log2(i + 2) for i in range(min(len(relevant), 10)))
    return {
        "recall@5": recall(5),
        "hit@1": 1.0 if ranking[:1] and ranking[0] in relevant else 0.0,
        "hit@5": 1.0 if relevant.intersection(ranking[:5]) else 0.0,
        "recall@10": recall(10),
        "mrr@10": 0.0 if first is None else 1 / (first + 1),
        "ndcg@10": dcg / ideal,
    }


def aggregate(per_query: list[dict[str, float]]) -> Metrics:
    n = len(per_query)
    if n == 0:
        return Metrics()

    def mean(key: str) -> float:
        return sum(q[key] for q in per_query) / n

    return Metrics(n, mean("recall@5"), mean("hit@5"), mean("hit@1"), mean("recall@10"), mean("mrr@10"), mean("ndcg@10"))


def evaluate_rankings(eval_set: EvalSet, rankings: dict[str, list[str]]) -> dict:
    """Overall, per-category and per-style metrics, plus each query's rank."""
    rows = []
    for q in eval_set.queries:
        m = query_metrics(rankings[q.id], set(q.relevant))
        rows.append((q, m))
    result = {"overall": aggregate([m for _, m in rows]).as_dict(), "byCategory": {}, "byStyle": {}}
    for category in sorted({q.category for q, _ in rows}):
        result["byCategory"][category] = aggregate([m for q, m in rows if q.category == category]).as_dict()
    for style in sorted({q.style for q, _ in rows}):
        result["byStyle"][style] = aggregate([m for q, m in rows if q.style == style]).as_dict()
    result["misses"] = [q.id for q, m in rows if m["hit@5"] == 0]
    return result


def vector_rankings(eval_set: EvalSet, query_vectors: np.ndarray, doc_vectors: np.ndarray) -> dict[str, list[str]]:
    ids = eval_set.document_ids
    ranked = rankings_from_scores(cosine_scores(query_vectors, doc_vectors))
    return {q.id: [ids[i] for i in order] for q, order in zip(eval_set.queries, ranked)}


# MARK: - BM25 (the lexical half of hybrid retrieval, #62/#64)

_TOKEN = re.compile(r"[\w']+", re.UNICODE)


def lexical_tokens(text: str) -> list[str]:
    """Lower-cased word tokens, like SQLite FTS5's unicode61 tokenizer."""
    return [t.strip("'") for t in _TOKEN.findall(text.lower()) if t.strip("'")]


@dataclass
class BM25:
    """Okapi BM25 with FTS5's constants (k1 = 1.2, b = 0.75), OR semantics."""

    documents: list[list[str]]
    k1: float = 1.2
    b: float = 0.75
    _df: Counter = field(default_factory=Counter)

    def __post_init__(self) -> None:
        for doc in self.documents:
            self._df.update(set(doc))
        self._avgdl = sum(len(d) for d in self.documents) / max(1, len(self.documents))

    def scores(self, query: list[str]) -> np.ndarray:
        n = len(self.documents)
        out = np.zeros(n)
        for term in set(query):
            df = self._df.get(term, 0)
            if df == 0:
                continue
            # Lucene's always-positive idf. FTS5 uses log((N - df + 0.5) / (df + 0.5))
            # and clamps negatives to a tiny epsilon, so this is a close stand-in,
            # not FTS5 itself; the real index (#62) gets measured on its own.
            idf = math.log((n - df + 0.5) / (df + 0.5) + 1)
            for i, doc in enumerate(self.documents):
                tf = doc.count(term)
                if tf:
                    out[i] += idf * tf * (self.k1 + 1) / (tf + self.k1 * (1 - self.b + self.b * len(doc) / self._avgdl))
        return out


def bm25_rankings(eval_set: EvalSet) -> dict[str, list[str]]:
    index = BM25([lexical_tokens(d.text) for d in eval_set.documents])
    ids = eval_set.document_ids
    scores = np.stack([index.scores(lexical_tokens(q.text)) for q in eval_set.queries])
    return {q.id: [ids[i] for i in order] for q, order in zip(eval_set.queries, rankings_from_scores(scores))}


def rrf(rankings: list[dict[str, list[str]]], k: int = 60) -> dict[str, list[str]]:
    """Reciprocal rank fusion of several rankings per query."""
    fused: dict[str, list[str]] = {}
    for qid in rankings[0]:
        scores: dict[str, float] = {}
        order: dict[str, int] = {}
        for ranking in rankings:
            for rank, doc in enumerate(ranking[qid]):
                scores[doc] = scores.get(doc, 0) + 1 / (k + rank + 1)
                order.setdefault(doc, len(order))
        fused[qid] = sorted(scores, key=lambda doc: (-scores[doc], order[doc]))
    return fused
