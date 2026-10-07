#!/usr/bin/env python3
"""Writes reference token IDs for Blau's Swift tokenizer to match (#60).

    .venv/bin/python scripts/embeddings/tokenizer_parity.py <dir with tokenizer.json> --model embeddinggemma-300m

Tokenizes, with the Hugging Face `tokenizers` library (the implementation
sentence-transformers and `convert_coreml.py` use):

- every eval-set query and document with the model's prompts (the texts the
  #59 numbers were measured on),
- the same texts truncated to the model's sequence length (128), and
- hand-picked edge cases: empty text, runs of spaces and newlines, accents
  and combining marks, CJK, emoji with joiners, digits, contractions,
  characters outside the vocabulary, and added tokens written in the text.

and writes `<dir>/tokenizer-parity.json`. Then

    BLAU_TOKENIZER_PARITY=<dir> swift test --filter TokenizerParityTests

(in Packages/BlauKit) checks that `HuggingFaceTokenizer` produces exactly the
same IDs. The tokenizer files themselves are not committed (11 to 33 MB).
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from candidates import CANDIDATES  # noqa: E402
from evalset import load_eval_set  # noqa: E402

EDGE_CASES = [
    "",
    " ",
    "   leading and trailing spaces   ",
    "two  spaces, three   spaces and a\ttab",
    "line one\nline two\n\nline four\r\nwindows",
    "Café, naïve, coöperate, résumé, Ångström",
    "é (e + combining acute) vs é",
    "ﬁ ligature, ｆｕｌｌｗｉｄｔｈ, ① circled",
    "東京で寿司を食べました。北京欢迎你。서울",
    "Emoji: 👍🏽 👩‍👩‍👧‍👦 🇯🇵 ❤️",
    "Numbers: 3.14159, 1,000,000, 2026-10-07, $42.50, 50%",
    "Contractions: I'm, you're, we've, they'll, it's, don't, I'd, CAN'T",
    "Symbols: <> [] {} @#%^&*()_+=|\\/~`",
    "Control \u0007 bell and zero​width space",
    "Added tokens in text: <bos> <eos> <|endoftext|> <|im_start|> <unused3> <mask>",
    "A" * 300,
    "supercalifragilisticexpialidocious antidisestablishmentarianism",
    "Mixed: Larderly's MRR grew 12% month-over-month (from $41k to $46k) in Q3.",
]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("directory", type=Path, help="directory with tokenizer.json")
    parser.add_argument("--model", required=True, choices=sorted(CANDIDATES))
    parser.add_argument("--max-length", type=int, default=128)
    args = parser.parse_args()

    from tokenizers import Tokenizer

    candidate = CANDIDATES[args.model]
    eval_set = load_eval_set()
    texts = [candidate.query_prompt + q.text for q in eval_set.queries]
    texts += [candidate.document_prompt + d.text for d in eval_set.documents]
    texts += EDGE_CASES
    # Long enough (several hundred tokens) for truncation to bite.
    texts.append(" ".join(d.text for d in eval_set.documents[:12]))
    texts += [candidate.document_prompt + t for t in EDGE_CASES]

    full = Tokenizer.from_file(str(args.directory / "tokenizer.json"))
    truncating = Tokenizer.from_file(str(args.directory / "tokenizer.json"))
    truncating.enable_truncation(max_length=args.max_length)

    cases = [{"text": t, "ids": full.encode(t).ids} for t in texts]
    cases += [{"text": t, "maximumLength": args.max_length, "ids": truncating.encode(t).ids} for t in texts]
    out = args.directory / "tokenizer-parity.json"
    out.write_text(json.dumps({"model": args.model, "cases": cases}, ensure_ascii=False) + "\n")
    longest = max(len(c["ids"]) for c in cases[: len(texts)])
    print(f"wrote {len(cases)} cases to {out} (longest {longest} tokens)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
