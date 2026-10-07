"""The text-embedding candidates compared in #59, pinned to exact revisions.

Prompts follow each model card. `revision` is a full commit SHA so a rerun
evaluates exactly the same weights. Keep this in sync with
`TextEmbeddingModelSpec` in BlauMemory (the Swift side reads the same
prompts when it embeds).
"""

from __future__ import annotations

from dataclasses import dataclass, field

# Blau's retrieval instruction for instruction-tuned models (Qwen3 asks for a
# one-sentence task description in English).
MEMORY_INSTRUCTION = (
    "Given a question about the user's life, work or past conversations, retrieve the memory that answers it"
)


@dataclass(frozen=True)
class Candidate:
    key: str
    repo: str
    revision: str
    runtime: str  # "sentence-transformers" or "model2vec"
    query_prompt: str = ""
    document_prompt: str = ""
    full_dimensions: int = 0
    dimensions: tuple[int, ...] = field(default_factory=tuple)  # Matryoshka widths to evaluate
    license: str = ""
    gated: bool = False
    pooling: str = "mean"  # how the Core ML wrapper pools: mean, last-token, static
    notes: str = ""


CANDIDATES: dict[str, Candidate] = {
    c.key: c
    for c in [
        Candidate(
            key="embeddinggemma-300m",
            repo="google/embeddinggemma-300m",
            # Pinned when access is granted; `main` until then (see docs/benchmarks.md).
            revision="main",
            runtime="sentence-transformers",
            query_prompt="task: search result | query: ",
            document_prompt="title: none | text: ",
            full_dimensions=768,
            dimensions=(768, 512, 256, 128),
            license="Gemma Terms of Use (gated: accept on Hugging Face first)",
            gated=True,
            pooling="mean",
            notes="308M parameters; mean pooling, then two dense layers (768 > 3072 > 768) and L2 normalization",
        ),
        Candidate(
            key="qwen3-embedding-0.6b",
            repo="Qwen/Qwen3-Embedding-0.6B",
            revision="97b0c614be4d77ee51c0cef4e5f07c00f9eb65b3",
            runtime="sentence-transformers",
            query_prompt=f"Instruct: {MEMORY_INSTRUCTION}\nQuery:",
            document_prompt="",
            full_dimensions=1024,
            dimensions=(1024, 512, 256, 128),
            license="Apache-2.0",
            pooling="last-token",
            notes="596M parameters; last-token pooling over a Qwen3 decoder, Matryoshka 32 to 1024",
        ),
        Candidate(
            key="potion-retrieval-32m",
            repo="minishlab/potion-retrieval-32M",
            revision="6fc8051fab2a1e0ee76689cf08c853792ac285e7",
            runtime="model2vec",
            full_dimensions=512,
            dimensions=(512, 256),
            license="MIT",
            pooling="static",
            notes="Model2Vec static embeddings (no transformer at inference): BGE-base tokenizer, a 63k x 512 token table (32M parameters), mean of token vectors",
        ),
    ]
}
