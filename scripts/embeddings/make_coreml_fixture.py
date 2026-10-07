#!/usr/bin/env python3
"""Writes the tiny split Core ML embedding model the BlauMemory tests load.

    .venv/bin/python scripts/embeddings/make_coreml_fixture.py

Output, in `Packages/BlauKit/Tests/BlauMemoryTests/Fixtures/CoreML/`:

- `TinySplitEmbedding.mlpackage`: the contract `convert_coreml.py` produces
  (inputs `inputs_embeds` `[1, 8, 4]` float16 and `attention_mask` `[1, 8]`
  float16, output `embedding` `[1, 4]` float32), computing the masked mean
  of the input rows, so a test can predict the exact output.
- `TinySplitEmbedding.token-embeddings.f16`: 10 rows of 4 float16 values,
  row i = [i, i + 0.5, -i, 1].

Needs torch and coremltools (requirements.txt).
"""

from pathlib import Path

import coremltools as ct
import numpy as np
import torch

OUT = Path(__file__).resolve().parents[2] / "Packages/BlauKit/Tests/BlauMemoryTests/Fixtures/CoreML"
LENGTH, WIDTH, VOCABULARY = 8, 4, 10


class MaskedMean(torch.nn.Module):
    def forward(self, inputs_embeds, attention_mask):
        weights = attention_mask.unsqueeze(-1)
        weights = weights / weights.sum(dim=1, keepdim=True).clamp(min=1)
        return (inputs_embeds * weights).sum(dim=1)


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    traced = torch.jit.trace(MaskedMean().eval(), (torch.zeros(1, LENGTH, WIDTH), torch.ones(1, LENGTH)))
    model = ct.convert(
        traced,
        inputs=[
            ct.TensorType(name="inputs_embeds", shape=(1, LENGTH, WIDTH), dtype=np.float16),
            ct.TensorType(name="attention_mask", shape=(1, LENGTH), dtype=np.float16),
        ],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.iOS18,
    )
    model.short_description = "Blau test fixture: masked mean of input embeddings (#59)"
    package = OUT / "TinySplitEmbedding.mlpackage"
    model.save(str(package))
    # The model has no weights, so coremltools writes an empty `weights/`
    # directory that Manifest.json still lists. Git does not track empty
    # directories, and Core ML refuses a package whose listed item is
    # missing ("Item does not exist for identifier"), so keep it committable.
    weights = package / "Data/com.apple.CoreML/weights"
    weights.mkdir(parents=True, exist_ok=True)
    (weights / ".gitkeep").touch()
    rows = np.array([[i, i + 0.5, -i, 1] for i in range(VOCABULARY)], dtype="<f2")
    rows.tofile(OUT / "TinySplitEmbedding.token-embeddings.f16")
    print(f"wrote {OUT}")


if __name__ == "__main__":
    main()
