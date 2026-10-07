#!/usr/bin/env python3
"""Writes the tiny tokenizers the hermetic BlauMemory tokenizer tests use (#60).

    .venv/bin/python scripts/embeddings/make_tokenizer_fixtures.py

Two small BPE tokenizers trained on the eval-set documents with the
Hugging Face `tokenizers` library, laid out like the real ones:

- `gemma-like`: `▁` for spaces (Replace normalizer), one pre-token per
  text, byte fallback, `<bos> $A <eos>`, special and non-special added
  tokens (EmbeddingGemma's tokenizer, in miniature).
- `qwen-like`: NFC, the Qwen/GPT-4 split regex, a byte-level alphabet,
  `$A <|endoftext|>` (Qwen3-Embedding's tokenizer, in miniature).

Each goes to `Packages/BlauKit/Tests/BlauMemoryTests/Fixtures/Tokenizers/<name>/`
with `tokenizer.json` and `tokenizer-parity.json` (the reference IDs for
the edge cases of `tokenizer_parity.py` and a sample of eval texts, plain
and truncated), which `HuggingFaceTokenizerTests` replays.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from evalset import load_eval_set  # noqa: E402
from tokenizer_parity import EDGE_CASES  # noqa: E402

OUT = Path(__file__).resolve().parents[2] / "Packages/BlauKit/Tests/BlauMemoryTests/Fixtures/Tokenizers"
QWEN_SPLIT = (
    r"(?i:'s|'t|'re|'ve|'m|'ll|'d)|[^\r\n\p{L}\p{N}]?\p{L}+|\p{N}| ?[^\s\p{L}\p{N}]+[\r\n]*|\s*[\r\n]+|\s+(?!\S)|\s+"
)


def gemma_like(corpus: list[str]):
    from tokenizers import AddedToken, Regex, Tokenizer, models, normalizers, pre_tokenizers, processors, trainers  # noqa: F401

    special = ["<pad>", "<eos>", "<bos>", "<unk>"]
    tokenizer = Tokenizer(models.BPE(unk_token="<unk>", fuse_unk=True, byte_fallback=True))
    tokenizer.normalizer = normalizers.Replace(" ", "▁")
    tokenizer.pre_tokenizer = pre_tokenizers.Split(" ", behavior="merged_with_previous")
    bytes_ = [f"<0x{b:02X}>" for b in range(256)]
    trainer = trainers.BpeTrainer(vocab_size=900, special_tokens=special + bytes_, show_progress=False)
    # Train on pieces split at the spaces' replacement so merges can span "▁".
    tokenizer.train_from_iterator(corpus, trainer=trainer)
    tokenizer.add_tokens([AddedToken("<mask>", normalized=False), AddedToken("<unused0>", normalized=False)])
    tokenizer.post_processor = processors.TemplateProcessing(
        single="<bos> $A <eos>", special_tokens=[("<bos>", tokenizer.token_to_id("<bos>")), ("<eos>", tokenizer.token_to_id("<eos>"))]
    )
    return tokenizer


def qwen_like(corpus: list[str]):
    from tokenizers import Regex, Tokenizer, models, normalizers, pre_tokenizers, processors, trainers

    tokenizer = Tokenizer(models.BPE())
    tokenizer.normalizer = normalizers.NFC()
    tokenizer.pre_tokenizer = pre_tokenizers.Sequence(
        [
            pre_tokenizers.Split(Regex(QWEN_SPLIT), behavior="isolated"),
            pre_tokenizers.ByteLevel(add_prefix_space=False, use_regex=False),
        ]
    )
    trainer = trainers.BpeTrainer(
        vocab_size=900,
        special_tokens=["<|endoftext|>", "<|im_start|>", "<|im_end|>"],
        initial_alphabet=pre_tokenizers.ByteLevel.alphabet(),
        show_progress=False,
    )
    tokenizer.train_from_iterator(corpus, trainer=trainer)
    tokenizer.post_processor = processors.Sequence(
        [
            processors.ByteLevel(trim_offsets=False),
            processors.TemplateProcessing(
                single="$A <|endoftext|>", special_tokens=[("<|endoftext|>", tokenizer.token_to_id("<|endoftext|>"))]
            ),
        ]
    )
    return tokenizer


def write(name: str, tokenizer, texts: list[str]) -> None:
    from tokenizers import Tokenizer

    folder = OUT / name
    folder.mkdir(parents=True, exist_ok=True)
    path = folder / "tokenizer.json"
    tokenizer.save(str(path))
    reference = Tokenizer.from_file(str(path))
    truncating = Tokenizer.from_file(str(path))
    truncating.enable_truncation(max_length=24)
    cases = [{"text": t, "ids": reference.encode(t).ids} for t in texts]
    cases += [{"text": t, "maximumLength": 24, "ids": truncating.encode(t).ids} for t in texts]
    (folder / "tokenizer-parity.json").write_text(
        json.dumps({"model": name, "cases": cases}, ensure_ascii=False, indent=0) + "\n"
    )
    print(f"wrote {folder} ({path.stat().st_size // 1024} KB, {len(cases)} cases)")


def main() -> int:
    eval_set = load_eval_set()
    corpus = [d.text for d in eval_set.documents]
    texts = EDGE_CASES + [d.text for d in eval_set.documents[:20]] + [q.text for q in eval_set.queries[:20]]
    write("gemma-like", gemma_like(corpus), texts)
    write("qwen-like", qwen_like(corpus), texts)
    return 0


if __name__ == "__main__":
    sys.exit(main())
