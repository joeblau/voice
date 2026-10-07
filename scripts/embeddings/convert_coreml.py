#!/usr/bin/env python3
"""Converts a text-embedding candidate to Core ML and checks it is numerically sound (#59).

    .venv/bin/python scripts/embeddings/convert_coreml.py --model embeddinggemma-300m
    .venv/bin/python scripts/embeddings/convert_coreml.py --model qwen3-embedding-0.6b --weights int8
    .venv/bin/python scripts/embeddings/convert_coreml.py --model embeddinggemma-300m --precision fp32

What it does:

1. Wraps the Hugging Face model in a small PyTorch module that reproduces
   sentence-transformers exactly (checked before converting): mean pooling
   plus the two dense layers for EmbeddingGemma, last-token pooling for
   Qwen3. The output, `embedding`, is the model's full-width pooled vector,
   *not* normalized: the app truncates it to 256-d, normalizes and quantizes
   (`MatryoshkaEmbedding`).
2. Converts it to an ML program (`.mlpackage`, iOS 18 target) with fp16 or
   fp32 compute, optionally compressing the weights to int8 or int4.

   **The token-embedding table is split out** (the default). With the
   table inside, Core ML's compute plan puts *every* operation of Qwen3 on
   the CPU: the gather over a 151,669-row table has no Neural Engine kernel
   and drags the whole graph with it. Without it, 100% of the operations
   are planned on the Neural Engine. So the model takes `inputs_embeds`
   (`[1, L, H]` fp16) and `attention_mask` (`[1, L]` fp16, 1 for real
   tokens, right padded), and the table ships next to it, one row of H
   values per token id, any embedding scale already applied: as int8 with
   a float32 scale per row, `<name>.token-embeddings.i8` (the default
   since #60, half the size), or as raw float16 with `--table float16`
   (`<name>.token-embeddings.f16`); see token_table.py. The app
   memory-maps it and copies the rows of each input
   (`TokenEmbeddingTable` in BlauMemory). Verification feeds the model
   the rows exactly as the app will (dequantized int8). `--no-split` keeps
   the table inside (`input_ids` and `attention_mask`, int32), for
   comparison.

   A single `--lengths` value (the default, 128) gives a fully static graph,
   which the Neural Engine compiler wants; several give enumerated shapes.
3. Verifies it. For every eval-set text it compares Core ML's output, on the
   CPU and on the Neural Engine (`cpuAndNeuralEngine`), with the PyTorch fp32
   reference: non-finite outputs (the fp16 NaN problem reported for
   EmbeddingGemma), cosine to the reference at full width and at 256-d, and
   the retrieval metrics of the Core ML vectors at 256-d int8. It records
   Core ML's compute plan (which device each operation is planned on) and
   times one prediction per sequence length.
4. Writes, next to the model, `<name>.verification.json`,
   `<name>.eval-tokens.json` (the eval set's token IDs, for the Swift harness:
   `BLAU_EMBEDDING_TOKENS`), and a `hosting/` folder (compiled `.mlmodelc`,
   token table, tokenizer, `blau-embedding.json` metadata, license notice and
   a manifest with every file's size and SHA-256) ready to upload with
   `hf upload`; see docs/benchmarks.md.

Needs the packages in requirements.txt and Xcode's `coremlcompiler`.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from candidates import CANDIDATES, Candidate  # noqa: E402
from token_table import dequantize_rows, quantize_rows, write_int8  # noqa: E402
from evalset import EvalSet, evaluate_rankings, load_eval_set, matryoshka, quantize_int8, vector_rankings  # noqa: E402

MODEL_NAMES = {
    "embeddinggemma-300m": "EmbeddingGemma300M",
    "qwen3-embedding-0.6b": "Qwen3Embedding06B",
}


@dataclass
class Wrapped:
    """The reference model and the pieces that get converted."""

    st: object  # the SentenceTransformer
    full: object  # ids + int mask -> embedding (fp32 reference, and --no-split)
    encoder: object  # inputs_embeds + float mask -> embedding (split)
    embed_tokens: object  # ids -> inputs_embeds, scale included
    hidden_size: int
    vocab_size: int


def build_wrapper(candidate: Candidate, path: str) -> Wrapped:
    import torch
    from sentence_transformers import SentenceTransformer
    from sentence_transformers.models import Dense, Normalize, Pooling, Transformer

    st = SentenceTransformer(path, device="cpu", model_kwargs={"attn_implementation": "eager"})
    st.eval()
    modules = list(st)
    if not isinstance(modules[0], Transformer) or not isinstance(modules[1], Pooling):
        raise SystemExit(f"{candidate.key}: unexpected sentence-transformers layout {modules}")
    dense = [m for m in modules[2:] if isinstance(m, Dense)]
    others = [m for m in modules[2:] if not isinstance(m, (Dense, Normalize))]
    if others:
        raise SystemExit(f"{candidate.key}: unsupported modules after pooling: {others}")
    backbone = modules[0].auto_model
    backbone.config.use_cache = False
    config = backbone.config
    bidirectional = bool(getattr(config, "use_bidirectional_attention", False))
    window = getattr(config, "sliding_window", None) or 1 << 30

    def attention_masks(mask):
        # The 4D additive masks transformers would build, built here instead:
        # its mask helpers use vmap, which torch.jit.trace can't record, and a
        # dict makes the model use them as they are. Only float arithmetic:
        # integer and boolean ops (comparisons, &) have no Neural Engine
        # kernel. With a fixed length the structural parts (causal triangle,
        # window band) fold into constants.
        #
        # 0 where attention is allowed, -1e4 elsewhere. Not -inf or float32's
        # minimum: both overflow to -inf in fp16, and a row of -inf turns
        # softmax into NaN.
        length = mask.shape[1]
        ones = torch.ones(length, length, dtype=mask.dtype)
        key = mask.unsqueeze(1)  # [B, 1, L], 1.0 for real tokens
        reach = min(window - 1, length)
        if bidirectional:
            full = ones * key
            sliding = full * torch.triu(torch.tril(ones, reach), -reach)
        else:
            causal = torch.tril(ones)
            full = causal * key
            sliding = full * torch.triu(causal, -reach)
        return {
            "full_attention": ((1.0 - full) * -1.0e4).unsqueeze(1),
            "sliding_attention": ((1.0 - sliding) * -1.0e4).unsqueeze(1),
        }

    def pool(hidden, mask):
        if candidate.pooling == "last-token":
            # Right padding: the last real token is the one followed by
            # padding (or the end). The decoder is causal, so padding after it
            # can't change it. A one-hot weighted sum rather than a gather.
            following = torch.cat([mask[:, 1:], torch.zeros_like(mask[:, :1])], dim=1)
            weights = (mask * (1.0 - following)).unsqueeze(-1)
        else:
            # Weights sum to one before multiplying, so the fp16 sum can't
            # overflow on long inputs.
            weights = mask.unsqueeze(-1)
            weights = weights / weights.sum(dim=1, keepdim=True).clamp(min=1)
        return (hidden * weights.to(hidden.dtype)).sum(dim=1)

    class Encoder(torch.nn.Module):
        """inputs_embeds [1, L, H] + attention_mask [1, L] (float) -> embedding."""

        def __init__(self):
            super().__init__()
            self.backbone = backbone
            self.dense = torch.nn.ModuleList(dense)

        def forward(self, inputs_embeds, attention_mask):
            mask = attention_mask.to(inputs_embeds.dtype)
            hidden = self.backbone(
                inputs_embeds=inputs_embeds, attention_mask=attention_masks(mask), use_cache=False
            ).last_hidden_state
            pooled = pool(hidden, mask)
            for layer in self.dense:
                pooled = layer.activation_function(layer.linear(pooled))
            return pooled

    encoder = Encoder().eval()
    embed_tokens = backbone.get_input_embeddings()  # Gemma's scaled embedding includes sqrt(hidden)

    class Full(torch.nn.Module):
        """input_ids [1, L] + attention_mask [1, L] (int) -> embedding."""

        def __init__(self):
            super().__init__()
            self.encoder = encoder
            self.embed_tokens = embed_tokens

        def forward(self, input_ids, attention_mask):
            return self.encoder(self.embed_tokens(input_ids.long()), attention_mask.float())

    return Wrapped(st, Full().eval(), encoder, embed_tokens, int(config.hidden_size), int(config.vocab_size))


def token_table(wrapped: Wrapped) -> np.ndarray:
    """Every token's input embedding (scale applied) as float16 [V, H]."""
    import torch

    rows = []
    with torch.no_grad():
        for start in range(0, wrapped.vocab_size, 8192):
            ids = torch.arange(start, min(start + 8192, wrapped.vocab_size)).unsqueeze(0)
            rows.append(wrapped.embed_tokens(ids)[0].float().numpy())
    table = np.concatenate(rows).astype(np.float16)
    if not np.isfinite(table).all():
        raise SystemExit("The token-embedding table overflows float16")
    return table


def convert(wrapped: Wrapped, lengths: list[int], precision: str, weights: str, split: bool = True):
    import coremltools as ct
    import torch

    n = lengths[-1]
    mask = torch.zeros((1, n))
    mask[:, : n // 2] = 1  # half padded, so the traced graph handles padding
    with torch.no_grad():
        if split:
            traced = torch.jit.trace(wrapped.encoder, (torch.zeros((1, n, wrapped.hidden_size)), mask), check_trace=False)
        else:
            traced = torch.jit.trace(
                wrapped.full, (torch.ones((1, n), dtype=torch.int32), mask.to(torch.int32)), check_trace=False
            )
    fixed = len(lengths) == 1
    tokens = (1, n) if fixed else ct.EnumeratedShapes(shapes=[[1, k] for k in lengths], default=[1, n])
    if split:
        embeds = (
            (1, n, wrapped.hidden_size)
            if fixed
            else ct.EnumeratedShapes(shapes=[[1, k, wrapped.hidden_size] for k in lengths], default=[1, n, wrapped.hidden_size])
        )
        inputs = [
            ct.TensorType(name="inputs_embeds", shape=embeds, dtype=np.float16),
            ct.TensorType(name="attention_mask", shape=tokens, dtype=np.float16),
        ]
    else:
        inputs = [
            ct.TensorType(name="input_ids", shape=tokens, dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=tokens, dtype=np.int32),
        ]
    model = ct.convert(
        traced,
        inputs=inputs,
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
        compute_precision=ct.precision.FLOAT16 if precision == "fp16" else ct.precision.FLOAT32,
        compute_units=ct.ComputeUnit.ALL,
    )
    if weights != "none":
        from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights

        op_config = (
            OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int8", granularity="per_channel")
            if weights == "int8"
            else OpLinearQuantizerConfig(mode="linear_symmetric", dtype="int4", granularity="per_block", block_size=32)
        )
        model = linear_quantize_weights(model, OptimizationConfig(global_config=op_config))
    return model


def tokenize(st, texts: list[str], maximum: int) -> list[list[int]]:
    tokenizer = st.tokenizer
    return [tokenizer(text, truncation=True, max_length=maximum)["input_ids"] for text in texts]


def predict(model, ids: list[int], lengths: list[int], table: np.ndarray | None = None) -> np.ndarray:
    """One Core ML prediction, inputs built the way the app builds them."""
    length = next(n for n in lengths if n >= len(ids))
    if table is None:
        input_ids = np.zeros((1, length), dtype=np.int32)
        mask = np.zeros((1, length), dtype=np.int32)
        input_ids[0, : len(ids)] = ids
        mask[0, : len(ids)] = 1
        features = {"input_ids": input_ids, "attention_mask": mask}
    else:
        embeds = np.zeros((1, length, table.shape[1]), dtype=np.float16)
        embeds[0, : len(ids)] = table[ids]
        mask = np.zeros((1, length), dtype=np.float16)
        mask[0, : len(ids)] = 1
        features = {"inputs_embeds": embeds, "attention_mask": mask}
    return np.asarray(model.predict(features)["embedding"], dtype=np.float32)[0]


def reference(full, ids: list[int]) -> np.ndarray:
    import torch

    with torch.no_grad():
        out = full(torch.tensor([ids], dtype=torch.int32), torch.ones((1, len(ids)), dtype=torch.int32))
    return out[0].numpy().astype(np.float32)


def predict_padded_reference(full, ids: list[int], length: int) -> np.ndarray:
    """The wrapper's output for `ids` right-padded to `length`, as Core ML sees it."""
    import torch

    input_ids = torch.zeros((1, length), dtype=torch.int32)
    mask = torch.zeros((1, length), dtype=torch.int32)
    input_ids[0, : len(ids)] = torch.tensor(ids, dtype=torch.int32)
    mask[0, : len(ids)] = 1
    with torch.no_grad():
        return full(input_ids, mask)[0].numpy().astype(np.float32)


def cosine_rows(a: np.ndarray, b: np.ndarray) -> np.ndarray:
    a = a / np.maximum(np.linalg.norm(a, axis=1, keepdims=True), 1e-12)
    b = b / np.maximum(np.linalg.norm(b, axis=1, keepdims=True), 1e-12)
    return np.sum(a * b, axis=1)


def verify(
    package: Path,
    wrapped: Wrapped,
    eval_set: EvalSet,
    tokens: dict,
    lengths: list[int],
    units: list[str],
    table: np.ndarray | None,
) -> dict:
    import coremltools as ct

    texts = list(tokens)
    ids = [tokens[t] for t in texts]
    ref = np.stack([reference(wrapped.full, i) for i in ids])
    query_count = len(eval_set.queries)
    report = {"reference": "PyTorch fp32 on CPU", "computeUnits": {}}

    def retrieval(vectors: np.ndarray) -> dict:
        q = quantize_int8(matryoshka(vectors[:query_count], 256))
        d = quantize_int8(matryoshka(vectors[query_count:], 256))
        return evaluate_rankings(eval_set, vector_rankings(eval_set, q, d))["overall"]

    report["referenceRetrieval256Int8"] = retrieval(ref)
    for unit in units:
        start = time.perf_counter()
        model = ct.models.MLModel(str(package), compute_units=getattr(ct.ComputeUnit, unit))
        load_seconds = time.perf_counter() - start
        out = np.stack([predict(model, i, lengths, table) for i in ids])
        finite = np.isfinite(out).all(axis=1)
        safe = np.where(finite[:, None], out, 0)
        full = cosine_rows(safe, ref)[finite]
        short = cosine_rows(safe[:, :256], ref[:, :256])[finite]
        timings = {}
        for n in lengths:
            sample = [1000 + (k * 7919) % 20000 for k in range(n)]
            for _ in range(3):
                predict(model, sample, lengths, table)
            times = []
            for _ in range(20):
                t = time.perf_counter()
                predict(model, sample, lengths, table)
                times.append((time.perf_counter() - t) * 1000)
            times.sort()
            timings[f"{n}tok"] = {"p50": round(float(np.median(times)), 2), "p95": round(times[18], 2)}
        report["computeUnits"][unit] = {
            "loadSeconds": round(load_seconds, 2),
            "nonFiniteOutputs": int((~finite).sum()),
            "cosineToReference": {
                "full": {"min": round(float(full.min()), 5), "mean": round(float(full.mean()), 5)} if full.size else None,
                "256d": {"min": round(float(short.min()), 5), "mean": round(float(short.mean()), 5)} if short.size else None,
            },
            "retrieval256Int8": retrieval(safe),
            "predictMs": timings,
        }
        print(f"   {unit}: {json.dumps(report['computeUnits'][unit])}", file=sys.stderr)
    return report


def compute_plan(package: Path) -> dict:
    """Where Core ML would run each operation with `cpuAndNeuralEngine` on this Mac.

    `MLComputePlan` reports the preferred device per op and an estimated
    cost share; constants are skipped. A model planned on the CPU here won't
    reach the Neural Engine on an iPhone either.
    """
    import tempfile
    from collections import Counter

    import coremltools as ct
    from coremltools.models.compute_plan import MLComputePlan

    names = {
        "MLCPUComputeDevice": "cpu",
        "MLGPUComputeDevice": "gpu",
        "MLNeuralEngineComputeDevice": "neuralEngine",
    }
    with tempfile.TemporaryDirectory() as tmp:
        subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), tmp], check=True, capture_output=True)
        compiled = next(Path(tmp).glob("*.mlmodelc"))
        plan = MLComputePlan.load_from_path(path=str(compiled), compute_units=ct.ComputeUnit.CPU_AND_NE)
        ops: Counter = Counter()
        cost: Counter = Counter()

        def walk(block):
            for op in block.operations:
                # Constants, and the constexpr ops that decompress int8/int4
                # weights at load time, run on no device.
                if op.operator_name == "const" or "constexpr_" in op.operator_name:
                    continue
                usage = plan.get_compute_device_usage_for_mlprogram_operation(op)
                device = names.get(type(usage.preferred_compute_device).__name__, "other") if usage else "none"
                ops[device] += 1
                estimate = plan.get_estimated_cost_for_mlprogram_operation(op)
                if estimate:
                    cost[device] += estimate.weight
                for nested in op.blocks:
                    walk(nested)

        for function in plan.model_structure.program.functions.values():
            walk(function.block)
    total = sum(ops.values()) or 1
    return {
        "operations": dict(ops),
        "neuralEngineShareOfOps": round(ops["neuralEngine"] / total, 4),
        "estimatedCostShare": {k: round(v, 4) for k, v in cost.items()},
    }


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def package_for_hosting(
    package: Path, table_path: Path | None, source: Path, candidate: Candidate, name: str, lengths, args, wrapped
) -> Path:
    hosting = package.parent / "hosting"
    if hosting.exists():
        shutil.rmtree(hosting)
    hosting.mkdir()
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(hosting)], check=True, capture_output=True)
    if table_path:
        shutil.copy(table_path, hosting / table_path.name)
    table_dtype = "int8" if table_path and table_path.name.endswith(".i8") else "float16"
    for file in ("tokenizer.json", "tokenizer_config.json", "special_tokens_map.json", "tokenizer.model"):
        if (source / file).exists():
            shutil.copy(source / file, hosting / file)
    for file in ("LICENSE", "NOTICE"):
        if (source / file).exists():
            shutil.copy(source / file, hosting / file)
    if candidate.gated:
        (hosting / "NOTICE").write_text(
            "Gemma is provided under and subject to the Gemma Terms of Use found at ai.google.dev/gemma/terms\n"
        )
    metadata = {
        # TextEmbeddingModelSpec.id: the app checks the prompts and widths
        # below against its own spec for this model.
        "spec": candidate.key,
        "name": name,
        "source": {"repo": candidate.repo, "revision": candidate.revision, "license": candidate.license},
        "model": f"{name}.mlmodelc",
        "inputs": ["inputs_embeds", "attention_mask"] if table_path else ["input_ids", "attention_mask"],
        "tokenEmbeddings": (
            {"file": table_path.name, "dtype": table_dtype, "vocabularySize": wrapped.vocab_size, "width": wrapped.hidden_size}
            if table_path
            else None
        ),
        "output": "embedding",
        "sequenceLengths": lengths,
        "fullDimensions": candidate.full_dimensions,
        "storedDimensions": 256,
        "pooling": candidate.pooling,
        "queryPrompt": candidate.query_prompt,
        "documentPrompt": candidate.document_prompt,
        "computePrecision": args.precision,
        "weights": args.weights,
        "tokenizer": "tokenizer.json",
    }
    (hosting / "blau-embedding.json").write_text(json.dumps(metadata, indent=2) + "\n")
    files = sorted(p for p in hosting.rglob("*") if p.is_file())
    manifest = [{"path": str(p.relative_to(hosting)), "size": p.stat().st_size, "sha256": sha256(p)} for p in files]
    (package.parent / f"{name}.hosting-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return hosting


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", required=True, choices=sorted(MODEL_NAMES))
    parser.add_argument("--lengths", default="128", help="sequence length, or several (ascending) for enumerated shapes")
    parser.add_argument("--precision", choices=["fp16", "fp32"], default="fp16", help="Core ML compute precision")
    parser.add_argument("--weights", choices=["none", "int8", "int4"], default="none", help="weight compression")
    parser.add_argument("--no-split", action="store_true", help="keep the token-embedding table inside the model")
    parser.add_argument(
        "--table", choices=["int8", "float16"], default="int8", help="split token table format (int8: per-row scale)"
    )
    parser.add_argument("--units", default="CPU_ONLY,CPU_AND_NE", help="compute units to verify on")
    parser.add_argument("--output", type=Path, default=Path(".build/Embeddings"))
    parser.add_argument("--skip-hosting", action="store_true")
    args = parser.parse_args()

    from huggingface_hub import snapshot_download

    candidate = CANDIDATES[args.model]
    lengths = sorted(int(n) for n in args.lengths.split(","))
    split = not args.no_split
    suffix = (
        f"-{args.precision}"
        + ("" if args.weights == "none" else f"-w{args.weights}")
        + ("-tf16" if split and args.table == "float16" else "")
        + ("" if split else "-nosplit")
    )
    name = MODEL_NAMES[args.model]
    out = args.output / f"{name}{suffix}"
    out.mkdir(parents=True, exist_ok=True)

    source = Path(snapshot_download(candidate.repo, revision=candidate.revision))
    eval_set = load_eval_set()
    wrapped = build_wrapper(candidate, str(source))
    texts = [candidate.query_prompt + q.text for q in eval_set.queries] + [
        candidate.document_prompt + d.text for d in eval_set.documents
    ]
    ids = tokenize(wrapped.st, texts, lengths[-1])
    tokens = dict(zip(texts, ids))

    # The wrapper re-implements pooling and masking, so check it against
    # sentence-transformers itself before converting anything.
    sample = texts[:8] + texts[-8:]
    expected = wrapped.st.encode(sample, convert_to_numpy=True, normalize_embeddings=True)
    actual = np.stack([reference(wrapped.full, ids[texts.index(t)]) for t in sample])
    agreement = float(cosine_rows(actual, expected).min())
    padded = predict_padded_reference(wrapped.full, ids[0], lengths[-1])
    padding_agreement = float(cosine_rows(padded[None], reference(wrapped.full, ids[0])[None])[0])
    print(f"   wrapper vs sentence-transformers: min cosine {agreement:.6f}; padded {padding_agreement:.6f}", file=sys.stderr)
    if agreement < 0.9999 or padding_agreement < 0.9999:
        raise SystemExit("The wrapper doesn't reproduce the reference model; not converting")

    print(f"== converting {candidate.key} ({args.precision}, weights {args.weights}, split {split})", file=sys.stderr)
    start = time.perf_counter()
    model = convert(wrapped, lengths, args.precision, args.weights, split)
    package = out / f"{name}.mlpackage"
    if package.exists():
        shutil.rmtree(package)
    model.save(str(package))
    table = token_table(wrapped) if split else None
    table_path = None
    if table is not None and args.table == "int8":
        table_path = out / f"{name}.token-embeddings.i8"
        write_int8(table, table_path)
        # Verify with the rows the app will feed the model.
        table = dequantize_rows(*quantize_rows(table))
    elif table is not None:
        table_path = out / f"{name}.token-embeddings.f16"
        table.astype("<f2").tofile(table_path)
    convert_seconds = time.perf_counter() - start
    size = sum(p.stat().st_size for p in package.rglob("*") if p.is_file())
    table_bytes = table_path.stat().st_size if table_path else 0
    print(f"   saved {package} ({size / 1e6:.0f} MB, table {table_bytes / 1e6:.0f} MB) in {convert_seconds:.0f} s", file=sys.stderr)

    plan = compute_plan(package)
    print(f"   compute plan: {json.dumps(plan)}", file=sys.stderr)
    report = verify(package, wrapped, eval_set, tokens, lengths, args.units.split(","), table)
    report.update(
        {
            "model": candidate.key,
            "source": {"repo": candidate.repo, "revision": candidate.revision},
            "computePrecision": args.precision,
            "weights": args.weights,
            "splitTokenEmbeddings": split,
            "tokenTable": args.table if split else None,
            "sequenceLengths": lengths,
            "packageBytes": size,
            "tokenTableBytes": table_bytes,
            "convertSeconds": round(convert_seconds, 1),
            "maxTokensInEvalSet": max(len(i) for i in ids),
            "computePlan": plan,
        }
    )
    (out / f"{name}.verification.json").write_text(json.dumps(report, indent=2) + "\n")
    (out / f"{name}.eval-tokens.json").write_text(
        json.dumps({"model": candidate.key, "maximumLength": lengths[-1], "tokens": tokens}) + "\n"
    )
    if not args.skip_hosting:
        hosting = package_for_hosting(package, table_path, source, candidate, name, lengths, args, wrapped)
        print(f"   hosting folder: {hosting}", file=sys.stderr)
    print(json.dumps(report, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
