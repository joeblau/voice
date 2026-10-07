# Benchmark assets

Optional, gitignored inputs that `make generate` copies into the
`BlauBenchmarks` test bundle (as the `Assets` folder):

- `EmbeddingGemma*.mlmodelc` or `EmbeddingGemma*.mlpackage`: the
  EmbeddingGemma-300M Core ML model for `testEmbeddingGemma256`. Without it
  that test is skipped. A `.mlpackage` is compiled on the device and the
  compile counts toward the measured load time. Models from
  `scripts/embeddings/convert_coreml.py` take input embeddings, so copy their
  token table (`<name>.token-embeddings.f16` or `.i8`) next to them.
- A text embedding hosting folder (the `hosting/` folder
  `convert_coreml.py` writes, with `blau-embedding.json`, the compiled
  model, its token table and `tokenizer.json`), directly here or in a
  subfolder, for `testSharedTextEmbeddingBatch32` (#60). Without it that
  test is skipped.
- `DeepFilterNet3/`: the DeepFilterNet3 Core ML model for the noise
  suppression benchmarks (#51). Fetch it with
  `scripts/fetch-deepfilternet3.sh BlauBenchmarks/Assets/DeepFilterNet3`;
  without it those tests are skipped.
- `benchmark-speech.wav`: a speech recording (any format and rate
  AVFoundation reads) to use instead of synthesized speech.

See [docs/benchmarks.md](../../docs/benchmarks.md).
