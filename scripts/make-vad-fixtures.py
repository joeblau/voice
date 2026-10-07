#!/usr/bin/env python3
"""Generate the labelled WAV fixtures for the voice activity segmenter tests.

Writes `Packages/BlauKit/Tests/BlauTranscriptionTests/Fixtures/VAD/<name>.wav`
(16 kHz mono 16-bit PCM) and `<name>.labels.json` for every fixture below.

Speech comes from macOS text to speech (`say`), so the true extent of every
utterance is known exactly: each clip is synthesised on its own, its speech
is located on the clean clip (10 ms frames above -50 dBFS), and the clip is
placed on a timeline of seeded room noise. The label is where the clean
speech sits on that timeline, before any noise is added.

    scripts/make-vad-fixtures.py            # regenerate every fixture
    scripts/make-vad-fixtures.py --check    # report labels, write nothing

Only the standard library is used. The output depends on the installed
voices, so regenerate on a Mac that has the voices listed below, then
re-record the Silero probabilities (see the fixtures README).
"""

import argparse
import json
import math
import os
import random
import struct
import subprocess
import sys
import tempfile
import wave

RATE = 16_000
FRAME = RATE // 100  # 10 ms analysis frames
ACTIVE_DBFS = -50.0  # a clean-clip frame louder than this is speech

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "Packages/BlauKit/Tests/BlauTranscriptionTests/Fixtures/VAD")

# Each fixture: noise level, seed, lead-in, utterances. An utterance is
# (voice, text, speech level in dBFS, silence after it in ms). A silence
# shorter than the segmenter's 300 ms hangover joins two utterances into one
# expected segment (`"join": True`).
FIXTURES = [
    {
        "name": "conversation-quiet",
        "description": "Five utterances from different voices over a quiet room (-62 dBFS), as voice processing delivers it.",
        "noise_dbfs": -62.0,
        "seed": 1,
        "lead_in_ms": 1200,
        "utterances": [
            ("Samantha", "Can you remind me what we decided about the launch date", -22, 1600),
            ("Daniel", "Yes", -20, 1300),
            ("Karen", "I think we moved it to the second week of March", -24, 2100),
            ("Moira", "Okay great", -26, 1100),
            ("Fred", "Then let us book the venue tomorrow morning", -21, 1500),
        ],
    },
    {
        "name": "conversation-noisy",
        "description": "Four utterances over loud room noise (-42 dBFS, about 18 dB SNR).",
        "noise_dbfs": -42.0,
        "seed": 2,
        "lead_in_ms": 1500,
        "utterances": [
            ("Daniel", "What is the weather going to be like this weekend", -23, 1800),
            ("Samantha", "Probably rain on Saturday", -24, 1400),
            ("Rishi", "Should we move the hike to Sunday then", -22, 2000),
            ("Tessa", "Sunday works for me", -25, 1500),
        ],
    },
    {
        "name": "monologue-long",
        "description": "Twelve seconds of continuous speech with only short breaths between sentences; longer than the 8 s maximum segment, so it must be force-split.",
        "noise_dbfs": -58.0,
        "seed": 3,
        "lead_in_ms": 1000,
        "utterances": [
            ("Samantha", "So the first thing I want to cover is the hiring plan for next quarter", -22, 120),
            ("Samantha", "we need two more engineers on the audio team and one designer", -22, 150),
            ("Samantha", "and I would like the offers out before the end of the month", -23, 100),
            ("Samantha", "because the candidates we interviewed are talking to other companies", -22, 1500),
        ],
        "join": True,
    },
    {
        "name": "pauses",
        "description": "A 200 ms pause (shorter than the hangover: one segment) and a 700 ms pause (two segments).",
        "noise_dbfs": -55.0,
        "seed": 4,
        "lead_in_ms": 900,
        "utterances": [
            ("Karen", "Let me think", -23, 200),
            ("Karen", "about that for a moment", -23, 700),
            ("Daniel", "Take your time", -22, 1400),
        ],
    },
]

# Pauses shorter than this inside an expected segment join its utterances.
JOIN_BELOW_MS = 300


def synthesize(voice, text):
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "clip.wav")
        subprocess.run(
            ["say", "-v", voice, "-o", path, "--file-format=WAVE", f"--data-format=LEI16@{RATE}", text],
            check=True,
        )
        with wave.open(path) as w:
            assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2
            n = w.getnframes()
            data = struct.unpack(f"<{n}h", w.readframes(n))
    return [x / 32768.0 for x in data]


def rms(samples):
    return math.sqrt(sum(x * x for x in samples) / len(samples)) if samples else 0.0


def dbfs(value):
    return 20 * math.log10(value) if value > 0 else -160.0


def speech_extent(samples):
    """First and last sample of the clean clip's speech (10 ms resolution)."""
    active = [
        dbfs(rms(samples[i : i + FRAME])) > ACTIVE_DBFS for i in range(0, len(samples) - FRAME + 1, FRAME)
    ]
    first = active.index(True)
    last = len(active) - 1 - active[::-1].index(True)
    # Longest internal pause, to make sure an utterance is one segment.
    longest, run = 0, 0
    for flag in active[first : last + 1]:
        run = 0 if flag else run + 1
        longest = max(longest, run)
    return first * FRAME, (last + 1) * FRAME, longest * 10


def room_noise(count, level_dbfs, seed):
    """Seeded low-passed Gaussian noise at `level_dbfs` RMS."""
    rng = random.Random(seed)
    out, state = [], 0.0
    for _ in range(count):
        state = 0.85 * state + rng.gauss(0, 1)
        out.append(state)
    scale = 10 ** (level_dbfs / 20) / rms(out)
    return [x * scale for x in out]


def build(fixture):
    timeline_parts, placements = [], []
    cursor = int(fixture["lead_in_ms"] * RATE / 1000)
    for voice, text, level, after_ms in fixture["utterances"]:
        clip = synthesize(voice, text)
        start, end, pause = speech_extent(clip)
        if pause >= 250:
            print(f"warning: '{text}' has an internal pause of {pause} ms", file=sys.stderr)
        speech = clip[start:end]
        gain = 10 ** (level / 20) / rms(speech)
        speech = [x * gain for x in speech]
        placements.append((cursor, cursor + len(speech), after_ms))
        timeline_parts.append((cursor, speech))
        cursor += len(speech) + int(after_ms * RATE / 1000)

    total = cursor
    noise = room_noise(total, fixture["noise_dbfs"], fixture["seed"])
    mix = noise[:]
    for offset, speech in timeline_parts:
        for i, x in enumerate(speech):
            mix[offset + i] += x
    peak = max(abs(x) for x in mix)
    assert peak < 1.0, f"{fixture['name']} clips ({peak})"

    # Expected segments: utterances joined across pauses shorter than the hangover.
    segments = []
    for start, end, _ in placements:
        if segments and start - segments[-1][1] < JOIN_BELOW_MS * RATE // 1000:
            segments[-1][1] = end
        else:
            segments.append([start, end])
    if fixture.get("join"):
        segments = [[segments[0][0], segments[-1][1]]]
    return mix, segments


def write(fixture, mix, segments):
    os.makedirs(OUT_DIR, exist_ok=True)
    name = fixture["name"]
    with wave.open(os.path.join(OUT_DIR, f"{name}.wav"), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", max(-32768, min(32767, round(x * 32767)))) for x in mix))
    labels = {
        "description": fixture["description"],
        "sampleRate": RATE,
        "sampleCount": len(mix),
        "noiseDBFS": fixture["noise_dbfs"],
        "segments": [{"start": s, "end": e} for s, e in segments],
    }
    with open(os.path.join(OUT_DIR, f"{name}.labels.json"), "w") as f:
        json.dump(labels, f, indent=2)
        f.write("\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="print the labels without writing files")
    args = parser.parse_args()
    for fixture in FIXTURES:
        mix, segments = build(fixture)
        spans = ", ".join(f"{s / RATE:.3f}-{e / RATE:.3f}" for s, e in segments)
        print(f"{fixture['name']}: {len(mix) / RATE:.2f} s, segments {spans}")
        if not args.check:
            write(fixture, mix, segments)


if __name__ == "__main__":
    main()
