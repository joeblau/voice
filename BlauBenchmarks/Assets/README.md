# Benchmark assets

Optional, gitignored inputs that `make generate` copies into the
`BlauBenchmarks` test bundle (as the `Assets` folder):

- `EmbeddingGemma*.mlmodelc` or `EmbeddingGemma*.mlpackage`: the
  EmbeddingGemma-300M Core ML model for `testEmbeddingGemma256`. Without it
  that test is skipped. A `.mlpackage` is compiled on the device and the
  compile counts toward the measured load time.
- `benchmark-speech.wav`: a speech recording (any format and rate
  AVFoundation reads) to use instead of synthesized speech.

See [docs/benchmarks.md](../../docs/benchmarks.md).
