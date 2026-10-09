#!/usr/bin/env python3
"""Write the reference features `LanguageIDFeatureExtractorTests` checks the
Swift front end against (#50).

`compute_fbank` below is the `frontend.py` published with the Core ML export
of SpeechBrain's VoxLingua107 language ID model
(huggingface.co/aufklarer/SpeechBrain-ECAPA-VoxLingua107-21M-CoreML, revision
2aa4d715a79e, Apache-2.0), which that export validates against SpeechBrain's
own `Fbank` module. It is copied here unchanged apart from formatting.

The input is a deterministic signal both sides can generate exactly (sines
and a linear chirp; see `LanguageIDFeatureExtractorTests.referenceSignal`).
Writes `Packages/BlauKit/Tests/BlauVoiceIDTests/Fixtures/LanguageIDFrontend.json`.

    scripts/language-id-frontend-reference.py

Needs python3 and numpy.
"""

import json
import os

import numpy as np

SAMPLE_RATE = 16_000
N_FFT = 400
WIN_LENGTH = 400
HOP_LENGTH = 160

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUTPUT = os.path.join(ROOT, "Packages/BlauKit/Tests/BlauVoiceIDTests/Fixtures/LanguageIDFrontend.json")


def periodic_hamming(length=WIN_LENGTH):
    positions = np.arange(length, dtype=np.float32)
    return (
        np.float32(0.54) - np.float32(0.46) * np.cos(np.float32(2.0 * np.pi) * positions / np.float32(length))
    ).astype(np.float32)


def speechbrain_filterbank(n_mels):
    def hz_to_mel(value):
        return 2595.0 * np.log10(1.0 + value / 700.0)

    def mel_to_hz(value):
        return 700.0 * (np.power(10.0, value / 2595.0) - 1.0)

    mel_points = np.linspace(hz_to_mel(0.0), hz_to_mel(SAMPLE_RATE / 2.0), n_mels + 2, dtype=np.float32)
    hz_points = mel_to_hz(mel_points).astype(np.float32)
    centers = hz_points[1:-1]
    bands = (hz_points[1:] - hz_points[:-1])[:-1]
    frequencies = np.linspace(0.0, SAMPLE_RATE // 2, N_FFT // 2 + 1, dtype=np.float32)
    slopes = (frequencies[:, None] - centers[None, :]) / bands[None, :]
    return np.maximum(0.0, np.minimum(slopes + 1.0, -slopes + 1.0)).astype(np.float32)


def compute_fbank(audio, n_mels):
    samples = np.asarray(audio, dtype=np.float32).reshape(-1)
    padded = np.pad(samples, (N_FFT // 2, N_FFT // 2), mode="constant")
    if padded.size < N_FFT:
        padded = np.pad(padded, (0, N_FFT - padded.size), mode="constant")
    frames = np.lib.stride_tricks.sliding_window_view(padded, N_FFT)[::HOP_LENGTH]
    windowed = frames * periodic_hamming()[None, :]
    spectrum = np.fft.rfft(windowed, n=N_FFT, axis=-1)
    power = (spectrum.real * spectrum.real + spectrum.imag * spectrum.imag).astype(np.float32)
    mel = power @ speechbrain_filterbank(n_mels)
    decibels = np.float32(10.0) * np.log10(np.maximum(mel, np.float32(1e-10)))
    floor = np.max(decibels) - np.float32(80.0)
    return np.maximum(decibels, floor).astype(np.float32)


def reference_signal(count):
    """0.12 sin(2π 173 t) + 0.06 sin(2π 271 t) + 0.03 sin(2π (300 t + 1500 t²)),
    silent for the first 0.1 s."""
    t = np.arange(count, dtype=np.float64) / SAMPLE_RATE
    signal = (
        0.12 * np.sin(2 * np.pi * 173 * t)
        + 0.06 * np.sin(2 * np.pi * 271 * t)
        + 0.03 * np.sin(2 * np.pi * (300 * t + 1500 * t * t))
    )
    signal[t < 0.1] = 0
    return signal.astype(np.float32)


def main():
    cases = []
    for count in [21_920, 32_000, 1_441, 4_000]:
        features = compute_fbank(reference_signal(count), 60)
        frames = features.shape[0]
        rows = sorted(r for r in {0, 5, 15, frames // 2, frames - 1} if r < frames)
        cases.append(
            {
                "sampleCount": count,
                "frameCount": int(frames),
                "rows": {str(r): [round(float(v), 4) for v in features[r]] for r in rows},
                "mean": round(float(features.mean()), 4),
                "max": round(float(features.max()), 4),
            }
        )
    filterbank = speechbrain_filterbank(60)
    with open(OUTPUT, "w") as f:
        json.dump(
            {
                "source": "scripts/language-id-frontend-reference.py",
                "cases": cases,
                "filterbankColumnSums": [round(float(v), 5) for v in filterbank.sum(axis=0)],
            },
            f,
            indent=1,
        )
        f.write("\n")
    print(f"Wrote {OUTPUT}")


if __name__ == "__main__":
    main()
