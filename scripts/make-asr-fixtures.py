#!/usr/bin/env python3
"""Generate the ASR evaluation fixtures (#32).

Writes `Packages/BlauKit/Tests/BlauTranscriptionTests/Fixtures/ASR/<id>.wav`
(16 kHz mono 16-bit PCM, stored in Git LFS) and `manifest.json`, which lists
every fixture with its category, the reference transcript of each utterance
and where that utterance's speech sits in the file (16 kHz sample offsets,
`start` inclusive, `end` exclusive).

Speech comes from macOS text to speech (`say`), so the reference transcript
and the extent of every utterance are exact: each utterance is synthesised
on its own, its speech is located on the clean clip (10 ms frames above
-50 dBFS), and the clip is placed on a timeline over a background:

    clean     quiet room tone, US English voices
    cafe      cafe: a babble of other talkers, cups and plates, room noise
    tv        a TV presenter talking in the same room (band-limited, reverberant)
    accented  regional English voices (UK, Ireland, Australia, India, South
              Africa) and non-native speakers (German, Spanish, French
              voices reading English), over room tone

The owner's own voice is not synthesisable: record it as described in
Datasets/asr/README.md and evaluate it with a manifest of the same format.

    scripts/make-asr-fixtures.py            # regenerate every fixture
    scripts/make-asr-fixtures.py --check    # report labels, write nothing
    scripts/make-asr-fixtures.py --only cafe-01 --only tv-02

Only the standard library is used. The audio depends on the installed voices
and the macOS version, so regenerating changes it slightly: re-run
`make eval-asr` afterwards and update docs/asr-eval.md and the thresholds if
the numbers move.
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
LEAD_IN_MS = 800
TAIL_MS = 2_200  # long enough for the VAD fallback (0.9 s after VAD's end of speech)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT_DIR = os.path.join(ROOT, "Packages/BlauKit/Tests/BlauTranscriptionTests/Fixtures/ASR")

# Each fixture: id, category, background, speech-to-background SNR in dB (for
# cafe and tv), seed, utterances. An utterance is (voice, text, pause after it
# in ms[, speaking rate in words per minute]); the last pause is replaced by
# the tail. Target speech uses the most natural voices macOS has ("Voice 1"
# is the Siri voice); the older formant-style voices (Eddy, Flo, Sandy...)
# only talk in the background: Parakeet decodes some of them poorly or not at
# all, which says little about real speakers.
FIXTURES = [
    # -- clean ---------------------------------------------------------------
    {"id": "clean-01", "category": "clean", "background": "room", "seed": 101, "utterances": [
        ("Samantha", "Can you remind me what we talked about yesterday", 0)]},
    {"id": "clean-02", "category": "clean", "background": "room", "seed": 102, "utterances": [
        ("Voice 1", "I want to practice my answers for the interview on Thursday", 1700),
        ("Voice 1", "Start with the hardest question", 0)]},
    {"id": "clean-03", "category": "clean", "background": "room", "seed": 103, "utterances": [
        ("Voice 1", "The meeting moved to three thirty so I have about twenty minutes", 0, 165)]},
    {"id": "clean-04", "category": "clean", "background": "room", "seed": 104, "utterances": [
        ("Samantha", "What did I say the budget for the trip was", 1600, 210),
        ("Samantha", "I think it was around two thousand dollars", 0, 210)]},
    {"id": "clean-05", "category": "clean", "background": "room", "seed": 105, "utterances": [
        ("Voice 1", "Add milk eggs and coffee to my shopping list", 0, 200)]},
    {"id": "clean-06", "category": "clean", "background": "room", "seed": 106, "utterances": [
        ("Samantha", "Let us switch topics and talk about the product launch", 0, 160)]},
    # -- cafe ----------------------------------------------------------------
    {"id": "cafe-01", "category": "cafe", "background": "cafe", "snr_db": 12, "seed": 201, "utterances": [
        ("Samantha", "Tell me again why the investors were worried about the timeline", 0)]},
    {"id": "cafe-02", "category": "cafe", "background": "cafe", "snr_db": 12, "seed": 202, "utterances": [
        ("Voice 1", "I just ordered a coffee so give me a second", 1600),
        ("Voice 1", "Okay go ahead with the summary", 0)]},
    {"id": "cafe-03", "category": "cafe", "background": "cafe", "snr_db": 10, "seed": 203, "utterances": [
        ("Daniel (English (UK))", "Remember that my sister is visiting next weekend", 0)]},
    {"id": "cafe-04", "category": "cafe", "background": "cafe", "snr_db": 8, "seed": 204, "utterances": [
        ("Samantha", "What were the three things I wanted to finish before Friday", 0)]},
    {"id": "cafe-05", "category": "cafe", "background": "cafe", "snr_db": 6, "seed": 205, "utterances": [
        ("Voice 1", "Can you read me the notes from this morning", 1600, 190),
        ("Voice 1", "Only the parts about hiring", 0, 190)]},
    {"id": "cafe-06", "category": "cafe", "background": "cafe", "snr_db": 6, "seed": 206, "utterances": [
        ("Karen", "I think the second design was much easier to understand", 0)]},
    # -- tv ------------------------------------------------------------------
    {"id": "tv-01", "category": "tv", "background": "tv", "snr_db": 12, "seed": 301, "utterances": [
        ("Samantha", "Turn this into a short list of action items", 0)]},
    {"id": "tv-02", "category": "tv", "background": "tv", "snr_db": 12, "seed": 302, "utterances": [
        ("Voice 1", "How long have we been talking about the pricing page", 1600),
        ("Voice 1", "Let us wrap that up", 0)]},
    {"id": "tv-03", "category": "tv", "background": "tv", "snr_db": 9, "seed": 303, "utterances": [
        ("Samantha", "Please remember that the dentist appointment is on Tuesday morning", 0, 190)]},
    {"id": "tv-04", "category": "tv", "background": "tv", "snr_db": 9, "seed": 304, "utterances": [
        ("Karen", "What is a good way to explain this to a new customer", 0)]},
    {"id": "tv-05", "category": "tv", "background": "tv", "snr_db": 6, "seed": 305, "utterances": [
        ("Voice 1", "Go back to what we said about the onboarding flow", 0)]},
    {"id": "tv-06", "category": "tv", "background": "tv", "snr_db": 6, "seed": 306, "utterances": [
        ("Daniel (English (UK))", "I need a better answer for why now is the right time", 0)]},
    # -- accented ------------------------------------------------------------
    {"id": "accented-01", "category": "accented", "background": "room", "seed": 401, "tags": {"accent": "en-GB"},
     "utterances": [("Daniel (English (UK))", "Could you summarize the conversation we had about the budget", 0)]},
    {"id": "accented-02", "category": "accented", "background": "room", "seed": 402, "tags": {"accent": "en-IE"},
     "utterances": [("Moira (English (Ireland))", "I would like to go over my notes before the call", 1600),
                    ("Moira (English (Ireland))", "Start from the top", 0)]},
    {"id": "accented-03", "category": "accented", "background": "room", "seed": 403, "tags": {"accent": "en-AU"},
     "utterances": [("Karen", "Remind me to send the contract to the lawyer tomorrow", 0)]},
    {"id": "accented-04", "category": "accented", "background": "room", "seed": 404, "tags": {"accent": "en-IN"},
     "utterances": [("Rishi (English (India))", "What questions do you think the panel will ask me", 0)]},
    {"id": "accented-05", "category": "accented", "background": "room", "seed": 405, "tags": {"accent": "en-ZA"},
     "utterances": [("Tessa (English (South Africa))", "Let us talk about the hiring plan for next quarter", 0)]},
    {"id": "accented-06", "category": "accented", "background": "room", "seed": 406, "tags": {"accent": "en-IN"},
     "utterances": [("Tara", "Can you explain the difference between the two options again", 0)]},
    {"id": "accented-07", "category": "accented", "background": "room", "seed": 407, "tags": {"accent": "de-DE"},
     "utterances": [("Anna", "I need to finish the presentation before the weekend", 0)]},
    {"id": "accented-08", "category": "accented", "background": "room", "seed": 408, "tags": {"accent": "es-MX"},
     "utterances": [("Paulina", "Please tell me what we decided about the new office", 0)]},
]

# What the background talkers say: unrelated to the fixtures, so their words
# show up as insertions if the engine transcribes them.
BABBLE_TEXTS = [
    "Did you see the game last night it went into overtime and nobody could believe the ending",
    "I am thinking about painting the kitchen a lighter color maybe something green",
    "We should get the table by the window next time the light is so much nicer there",
    "My brother just moved to a new apartment and the rent is completely ridiculous",
    "Can I get an oat milk latte and one of those blueberry muffins please",
    "She said the train was delayed again so she will be at least half an hour late",
]
BABBLE_VOICES = ["Grandma (English (US))", "Rocko (English (US))", "Flo (English (UK))", "Reed (English (UK))",
                 "Sandy (English (UK))", "Shelley (English (UK))"]
TV_TEXT = (
    "Good evening and welcome to the news at six. Heavy rain is expected across the region tonight, with "
    "flooding possible in low lying areas. In other news, the city council has approved a new plan for the "
    "harbor, which includes a park, a ferry terminal and more than two hundred new homes. Sports fans are "
    "celebrating after the home team won the championship in front of a sold out crowd. And finally, the "
    "weather for the weekend looks bright and warm, so get outside if you can."
)
TV_VOICE = "Daniel (English (UK))"
ROOM_DBFS = -60.0
SPEECH_DBFS = -24.0

_clip_cache = {}


def synthesize(voice, text, rate=None):
    key = (voice, text, rate)
    if key in _clip_cache:
        return _clip_cache[key]
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "clip.wav")
        command = ["say", "-v", voice, "-o", path, "--file-format=WAVE", f"--data-format=LEI16@{RATE}"]
        if rate:
            command += ["-r", str(rate)]
        subprocess.run(command + [text], check=True)
        with wave.open(path) as w:
            assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2
            n = w.getnframes()
            data = struct.unpack(f"<{n}h", w.readframes(n))
    samples = [x / 32768.0 for x in data]
    _clip_cache[key] = samples
    return samples


def rms(samples):
    return math.sqrt(sum(x * x for x in samples) / len(samples)) if samples else 0.0


def dbfs(value):
    return 20 * math.log10(value) if value > 0 else -160.0


def active_rms(samples):
    """RMS over the 10 ms frames that are speech, so pauses don't lower the level."""
    frames = [samples[i : i + FRAME] for i in range(0, len(samples) - FRAME + 1, FRAME)]
    loud = [f for f in frames if dbfs(rms(f)) > ACTIVE_DBFS]
    return rms([x for f in loud for x in f]) if loud else rms(samples)


def speech_extent(samples):
    """First and last sample of the clean clip's speech (10 ms resolution)."""
    active = [dbfs(rms(samples[i : i + FRAME])) > ACTIVE_DBFS for i in range(0, len(samples) - FRAME + 1, FRAME)]
    first = active.index(True)
    last = len(active) - 1 - active[::-1].index(True)
    return first * FRAME, (last + 1) * FRAME


def scaled(samples, level_dbfs):
    gain = 10 ** (level_dbfs / 20) / active_rms(samples)
    return [x * gain for x in samples]


def room_noise(count, level_dbfs, rng):
    """Low-passed Gaussian noise at `level_dbfs` RMS."""
    out, state = [], 0.0
    for _ in range(count):
        state = 0.85 * state + rng.gauss(0, 1)
        out.append(state)
    scale = 10 ** (level_dbfs / 20) / rms(out)
    return [x * scale for x in out]


def biquad(samples, kind, freq, q=0.707):
    """RBJ cookbook low- or high-pass filter."""
    w0 = 2 * math.pi * freq / RATE
    alpha = math.sin(w0) / (2 * q)
    cos = math.cos(w0)
    if kind == "low":
        b0, b1, b2 = (1 - cos) / 2, 1 - cos, (1 - cos) / 2
    else:
        b0, b1, b2 = (1 + cos) / 2, -(1 + cos), (1 + cos) / 2
    a0, a1, a2 = 1 + alpha, -2 * cos, 1 - alpha
    b0, b1, b2, a1, a2 = b0 / a0, b1 / a0, b2 / a0, a1 / a0, a2 / a0
    out, x1, x2, y1, y2 = [], 0.0, 0.0, 0.0, 0.0
    for x in samples:
        y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
        x2, x1, y2, y1 = x1, x, y1, y
        out.append(y)
    return out


def reverb(samples, rng, rt60=0.5, taps=24, wet=0.35):
    """A sparse late-reflection tail: delayed, decaying copies of the signal."""
    out = samples[:]
    for _ in range(taps):
        delay = rng.uniform(0.012, rt60 * 0.6)
        gain = wet * 10 ** (-3 * delay / rt60) * rng.choice([-1, 1]) / math.sqrt(taps / 4)
        offset = int(delay * RATE)
        for i in range(len(samples) - offset):
            out[i + offset] += gain * samples[i]
    return out


def looped(clip, count, start):
    """`count` samples of `clip` repeated, starting `start` samples in."""
    return [clip[(start + i) % len(clip)] for i in range(count)]


def cafe_background(count, rng):
    """Babble of six talkers, cups and plates, and room noise."""
    mix = [0.0] * count
    for voice, text in zip(BABBLE_VOICES, BABBLE_TEXTS):
        clip = synthesize(voice, text) + [0.0] * int(rng.uniform(0.2, 0.8) * RATE)
        talker = looped(scaled(clip, -30.0), count, rng.randrange(len(clip)))
        for i in range(count):
            mix[i] += talker[i]
    mix = reverb(biquad(mix, "low", 5_000), rng, rt60=0.6, wet=0.5)
    # Cups and plates: short, bright, decaying clinks.
    for _ in range(int(count / RATE * 1.2)):
        at = rng.randrange(count)
        freq = rng.uniform(2_500, 6_000)
        amplitude = 10 ** (rng.uniform(-34, -24) / 20)
        decay = rng.uniform(0.01, 0.04)
        for i in range(min(int(decay * 6 * RATE), count - at)):
            t = i / RATE
            mix[at + i] += amplitude * math.exp(-t / decay) * math.sin(2 * math.pi * freq * t + rng.random())
    noise = room_noise(count, -50.0, rng)
    return [m + n for m, n in zip(mix, noise)]


def tv_background(count, rng):
    """A presenter on a TV across the room: band-limited, reverberant, with room noise."""
    clip = synthesize(TV_VOICE, TV_TEXT) + [0.0] * int(0.4 * RATE)
    speech = looped(clip, count, rng.randrange(len(clip)))
    speech = biquad(biquad(speech, "high", 180), "low", 5_000)
    speech = reverb(speech, rng, rt60=0.5, wet=0.4)
    noise = room_noise(count, -56.0, rng)
    return [s + n for s, n in zip(speech, noise)]


def build(fixture):
    rng = random.Random(fixture["seed"])
    placements, parts = [], []
    cursor = int(LEAD_IN_MS * RATE / 1000)
    utterances = fixture["utterances"]
    for index, (voice, text, after_ms, *rate) in enumerate(utterances):
        clip = synthesize(voice, text, rate[0] if rate else None)
        start, end = speech_extent(clip)
        speech = scaled(clip[start:end], SPEECH_DBFS)
        placements.append(
            {"start": cursor, "end": cursor + len(speech), "text": text, "voice": voice, "rate": rate[0] if rate else None}
        )
        parts.append((cursor, speech))
        last = index == len(utterances) - 1
        cursor += len(speech) + int((TAIL_MS if last else after_ms) * RATE / 1000)
    total = cursor

    background = fixture["background"]
    if background == "room":
        bed = room_noise(total, ROOM_DBFS, rng)
    else:
        bed = cafe_background(total, rng) if background == "cafe" else tv_background(total, rng)
        # Scale the bed so speech is `snr_db` above it (active speech RMS
        # against the bed's RMS over the whole file).
        target = SPEECH_DBFS - fixture["snr_db"]
        gain = 10 ** (target / 20) / rms(bed)
        bed = [x * gain for x in bed]

    mix = bed[:]
    for offset, speech in parts:
        for i, x in enumerate(speech):
            mix[offset + i] += x
    peak = max(abs(x) for x in mix)
    if peak >= 0.99:
        mix = [x * 0.98 / peak for x in mix]
    return mix, placements


def write_wav(path, mix):
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", max(-32768, min(32767, round(x * 32767)))) for x in mix))


def manifest_entry(fixture, mix, placements):
    entry = {
        "id": fixture["id"],
        "path": f"{fixture['id']}.wav",
        "category": fixture["category"],
        "description": describe(fixture),
        "sampleCount": len(mix),
        "utterances": [{"start": p["start"], "end": p["end"], "text": p["text"]} for p in placements],
        "tags": {"background": fixture["background"], "voice": placements[0]["voice"], **fixture.get("tags", {})},
    }
    if placements[0]["rate"]:
        entry["tags"]["rate"] = f"{placements[0]['rate']}wpm"
    if "snr_db" in fixture:
        entry["tags"]["snr"] = f"{fixture['snr_db']}dB"
    return entry


def describe(fixture):
    voices = sorted({u[0] for u in fixture["utterances"]})
    count = len(fixture["utterances"])
    what = f"{count} utterance{'s' if count > 1 else ''} by {', '.join(voices)}"
    background = fixture["background"]
    if background == "room":
        return f"{what} over room tone"
    place = "a cafe" if background == "cafe" else "a TV presenter in the room"
    return f"{what} over {place} at {fixture['snr_db']} dB SNR"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--check", action="store_true", help="print the labels without writing files")
    parser.add_argument("--only", action="append", help="regenerate only these fixture ids (keeps the others)")
    args = parser.parse_args()

    manifest_path = os.path.join(OUT_DIR, "manifest.json")
    previous = {}
    if args.only and os.path.exists(manifest_path):
        with open(manifest_path) as f:
            previous = {entry["id"]: entry for entry in json.load(f)["fixtures"]}

    entries = []
    for fixture in FIXTURES:
        if args.only and fixture["id"] not in args.only:
            if fixture["id"] in previous:
                entries.append(previous[fixture["id"]])
            continue
        mix, placements = build(fixture)
        spans = ", ".join(f"{p['start'] / RATE:.2f}-{p['end'] / RATE:.2f}" for p in placements)
        print(f"{fixture['id']}: {len(mix) / RATE:.2f} s, speech {spans}")
        entries.append(manifest_entry(fixture, mix, placements))
        if not args.check:
            os.makedirs(OUT_DIR, exist_ok=True)
            write_wav(os.path.join(OUT_DIR, f"{fixture['id']}.wav"), mix)

    manifest = {
        "name": "blau-asr-fixtures",
        "consent": "Synthesised with macOS text to speech by scripts/make-asr-fixtures.py; no person was recorded.",
        "description": (
            "Short English utterances for the ASR evaluation harness (#32): clean speech, a cafe, a TV in the "
            "room and accented speakers. Speech extents are exact (placed on the timeline by the generator)."
        ),
        "sampleRate": RATE,
        "fixtures": entries,
    }
    if not args.check:
        with open(manifest_path, "w") as f:
            json.dump(manifest, f, indent=2, ensure_ascii=False)
            f.write("\n")
    seconds = sum(e["sampleCount"] for e in entries) / RATE
    print(f"{len(entries)} fixtures, {seconds:.1f} s of audio", file=sys.stderr)


if __name__ == "__main__":
    main()
