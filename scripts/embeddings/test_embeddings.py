#!/usr/bin/env python3
"""Tests for the #59 embedding scripts. Hermetic: no network, no real weights.

    python3 scripts/embeddings/test_embeddings.py          # numpy-only tests
    .venv/bin/python scripts/embeddings/test_embeddings.py # plus the Core ML conversion tests

The conversion tests build tiny randomly initialized Gemma3 (bidirectional,
mean pooling, two dense layers: EmbeddingGemma's layout) and Qwen3 (causal,
last-token pooling) models locally and push them through
`convert_coreml.py`, so the conversion path for the gated EmbeddingGemma
weights is exercised without them. They skip when torch, transformers,
sentence-transformers or coremltools aren't installed.
"""

from __future__ import annotations

import dataclasses
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import evalset  # noqa: E402
from candidates import CANDIDATES  # noqa: E402


class EvalSetTests(unittest.TestCase):
    def test_personal_set_shape(self):
        s = evalset.load_eval_set()
        self.assertEqual(len(s.queries), 200)
        self.assertEqual(len(s.documents), 216)
        counts = {}
        for q in s.queries:
            counts[q.category] = counts.get(q.category, 0) + 1
        self.assertEqual(counts, {"company": 55, "yc": 45, "conversation": 65, "profile": 35})

    def test_metrics_match_the_swift_definitions(self):
        m = evalset.query_metrics(["x", "y", "a", "z", "b"], {"a", "b"})
        self.assertEqual(m["recall@5"], 1.0)
        self.assertEqual(m["hit@1"], 0.0)
        self.assertAlmostEqual(m["mrr@10"], 1 / 3)
        dcg = 1 / np.log2(4) + 1 / np.log2(6)
        ideal = 1 + 1 / np.log2(3)
        self.assertAlmostEqual(m["ndcg@10"], dcg / ideal)

    def test_int8_quantization_keeps_cosine(self):
        rng = np.random.default_rng(59)
        v = evalset.matryoshka(rng.normal(size=(20, 768)), 256)
        self.assertEqual(v.shape, (20, 256))
        np.testing.assert_allclose(np.linalg.norm(v, axis=1), 1, atol=1e-6)
        codes = evalset.quantize_int8(v)
        self.assertEqual(codes.dtype, np.int8)
        self.assertEqual(int(np.abs(codes).max()), 127)
        exact = evalset.cosine_scores(v, v)
        quantized = evalset.cosine_scores(codes, codes)
        self.assertLess(float(np.abs(exact - quantized).max()), 0.01)

    def test_ranking_ties_keep_document_order(self):
        self.assertEqual(evalset.rankings_from_scores(np.array([[0.5, 0.9, 0.9, 0.1]]))[0], [1, 2, 0, 3])

    def test_bm25_prefers_rarer_matching_terms(self):
        index = evalset.BM25([["the", "dog"], ["the", "cat"], ["the", "the", "bird"]])
        scores = index.scores(["the", "cat"])
        self.assertEqual(int(np.argmax(scores)), 1)
        self.assertTrue((index.scores(["absent"]) == 0).all())

    def test_rrf_matches_swift(self):
        fused = evalset.rrf([{"q": ["a", "b", "c"]}, {"q": ["b", "c", "a"]}])
        self.assertEqual(fused["q"], ["b", "a", "c"])
        self.assertEqual(evalset.rrf([{"q": ["x", "y"]}, {"q": ["y", "x"]}])["q"], ["x", "y"])

    def test_candidates_are_pinned(self):
        for c in CANDIDATES.values():
            if not c.gated:
                self.assertRegex(c.revision, r"^[0-9a-f]{40}$", c.key)
            self.assertIn(256, c.dimensions, c.key)


HAVE_CONVERSION_STACK = all(
    importlib.util.find_spec(name) for name in ("torch", "transformers", "sentence_transformers", "coremltools")
)


@unittest.skipUnless(HAVE_CONVERSION_STACK, "needs torch, transformers, sentence-transformers and coremltools")
class ConversionTests(unittest.TestCase):
    """Tiny random models through the real conversion path."""

    words = ["[PAD]", "[UNK]", "[EOS]"] + [f"w{i}" for i in range(61)]

    def save_tokenizer(self, directory: Path):
        from tokenizers import Tokenizer, models, pre_tokenizers, processors
        from transformers import PreTrainedTokenizerFast

        vocab = {w: i for i, w in enumerate(self.words)}
        tokenizer = Tokenizer(models.WordLevel(vocab, unk_token="[UNK]"))
        tokenizer.pre_tokenizer = pre_tokenizers.Whitespace()
        tokenizer.post_processor = processors.TemplateProcessing(single="$A [EOS]", special_tokens=[("[EOS]", 2)])
        PreTrainedTokenizerFast(
            tokenizer_object=tokenizer, pad_token="[PAD]", unk_token="[UNK]", eos_token="[EOS]"
        ).save_pretrained(directory)

    def build(self, kind: str, root: Path):
        import torch
        from sentence_transformers import SentenceTransformer
        from sentence_transformers.models import Dense, Normalize, Pooling, Transformer

        torch.manual_seed(0)
        backbone_dir = root / "backbone"
        common = dict(
            vocab_size=len(self.words), hidden_size=32, intermediate_size=64, num_hidden_layers=2,
            num_attention_heads=4, num_key_value_heads=2, head_dim=8, max_position_embeddings=64,
        )
        if kind == "gemma":
            from transformers import Gemma3TextConfig, Gemma3TextModel

            config = Gemma3TextConfig(**common, sliding_window=4, use_bidirectional_attention=True, layer_types=["sliding_attention", "full_attention"])
            model = Gemma3TextModel(config)
        else:
            from transformers import Qwen3Config, Qwen3Model

            model = Qwen3Model(Qwen3Config(**common))
        model.save_pretrained(backbone_dir)
        self.save_tokenizer(backbone_dir)
        modules = [Transformer(str(backbone_dir), max_seq_length=16)]
        if kind == "gemma":
            modules += [
                Pooling(32, "mean"),
                Dense(32, 64, bias=False, activation_function=torch.nn.Identity()),
                Dense(64, 32, bias=False, activation_function=torch.nn.Identity()),
                Normalize(),
            ]
        else:
            modules += [Pooling(32, "lasttoken"), Normalize()]
        st_dir = root / "st"
        SentenceTransformer(modules=modules, device="cpu").save(str(st_dir))
        return st_dir

    def convert_and_check(self, kind: str, candidate_key: str):
        import coremltools as ct

        import convert_coreml as cc

        with tempfile.TemporaryDirectory() as tmp:
            st_dir = self.build(kind, Path(tmp))
            candidate = dataclasses.replace(CANDIDATES[candidate_key], full_dimensions=32)
            wrapped = cc.build_wrapper(candidate, str(st_dir))
            texts = ["w1 w2 w3", "w4 w5 w6 w7 w8 w9 w10", "w11"]
            ids = cc.tokenize(wrapped.st, texts, 16)
            expected = wrapped.st.encode(texts, convert_to_numpy=True)
            actual = np.stack([cc.reference(wrapped.full, i) for i in ids])
            self.assertGreater(float(cc.cosine_rows(actual, expected).min()), 0.9999)
            padded = cc.predict_padded_reference(wrapped.full, ids[0], 16)
            self.assertGreater(float(cc.cosine_rows(padded[None], actual[:1])[0]), 0.9999)

            table = cc.token_table(wrapped)
            self.assertEqual(table.shape, (len(self.words), 32))
            self.assertEqual(table.dtype, np.float16)
            for split, lengths in ((True, [16]), (True, [8, 16]), (False, [16])):
                with self.subTest(split=split, lengths=lengths):
                    model = cc.convert(wrapped, lengths, "fp32", "none", split)
                    path = Path(tmp) / f"tiny-{split}-{len(lengths)}.mlpackage"
                    model.save(str(path))
                    loaded = ct.models.MLModel(str(path), compute_units=ct.ComputeUnit.CPU_ONLY)
                    names = {i.name for i in loaded.get_spec().description.input}
                    self.assertEqual(names, {"inputs_embeds", "attention_mask"} if split else {"input_ids", "attention_mask"})
                    outputs = np.stack([cc.predict(loaded, i, lengths, table if split else None) for i in ids])
                    self.assertTrue(np.isfinite(outputs).all())
                    self.assertGreater(float(cc.cosine_rows(outputs, expected).min()), 0.999)

    def test_embeddinggemma_layout(self):
        self.convert_and_check("gemma", "embeddinggemma-300m")

    def test_qwen3_layout(self):
        self.convert_and_check("qwen", "qwen3-embedding-0.6b")


if __name__ == "__main__":
    unittest.main()
