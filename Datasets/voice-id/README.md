# Voice ID evaluation recordings

This directory holds the owner's voice ID evaluation set: real recordings
of the enrolled user across rooms and microphone distances, and the
impostors Blau must ignore (other people, TV, podcasts, music with vocals,
other languages, overlapping talkers). The harness in `BlauVoiceID`
(`VoiceIDEvaluator`) measures FAR/FRR on it and calibrates the gate's
`T_hi` / `T_lo`; [docs/voice-id-eval.md](../../docs/voice-id-eval.md) has
the method and the results.

**Status:** not recorded yet. Until it is, the shipped thresholds come from
the public LibriSpeech calibration set (see the doc).

## Consent and storage

- **Record only people who agree.** Every person whose voice is in a
  recording, other than public broadcasts, gives written consent to its use
  for evaluating Blau and to its storage in this public repository. Keep the
  signed text (no signatures needed in git, just who agreed and when) in
  `consent.md` next to the manifest, and summarize it in the manifest's
  `consent` field. The harness refuses a manifest with an empty `consent`.
- **Broadcast audio** (TV, podcasts, music): short excerpts (under 15 s)
  for evaluation only; note the source in the file name.
- **Audio goes in Git LFS** (`.gitattributes` tracks `*.wav`, `*.m4a`,
  `*.caf`, `*.flac` and `*.aiff` under `Datasets/voice-id/`). Run
  `git lfs install` once before adding files. CI never fetches them: the
  evaluation run is opt-in.
- Anyone can ask for their recordings to be removed; delete the files and
  their manifest entries, then rewrite the LFS history if needed.

## What to record

Record on the iPhone Blau runs on (Voice Memos is fine; the harness
converts any Core Audio format to 16 kHz mono). Each file is one stretch of
speech, trimmed to start and end with speech (the harness trims silence
too).

| Group | Role | What | How many |
| --- | --- | --- | --- |
| Owner enrollment | `enrollment` | 3-6 s of natural speech, quiet room, phone at arm's length | 4 |
| Owner probes | `probe` | 6-15 s, every combination of room (kitchen, living room, office, car) and distance (0.3 m, 1 m, 3 m), on at least two different days | 40+ |
| Other people | `probe`, source `person` | Housemates, colleagues, friends; same rooms and distances | 20+ (several people) |
| TV | `probe`, source `tv` | News, shows, ads from the TV across the room | 15+ |
| Podcasts | `probe`, source `podcast` | Talk audio from a phone or laptop speaker | 15+ |
| Music | `probe`, source `music` | Songs with vocals from a speaker | 10+ |
| Other languages | `probe`, source `other-language` | People speaking other languages (tag `language`) | 10+ |
| Overlap | `probe`, source `overlap` | The owner talking over TV or another person (speaker `owner`), and two other people at once (speaker: the louder one) | 10+ |

Probes need at least 6 s of speech for the 6 s window; shorter ones are
scored at the windows they cover. Tag every probe with `room` and
`distance` so the report breaks the results down by both.

## The manifest

`manifest.json` lists every recording; paths are relative to it.
[`manifest.example.json`](manifest.example.json) shows the format:

| Field | Meaning |
| --- | --- |
| `name` | Report title |
| `consent` | Who agreed, or the licence. Required |
| `description` | Device, app, rooms, dates |
| `recordings[].path` | Audio file, relative to the manifest |
| `recordings[].speaker` | Who is talking; `owner` for the owner. The dominant talker in overlap mixes |
| `recordings[].role` | `enrollment`, `probe` or `cohort` (AS-norm cohort and background talkers; never the owner) |
| `recordings[].source` | `person` (default), `tv`, `podcast`, `music`, `other-language`, `overlap`, or any other label |
| `recordings[].tags` | Free key/value pairs for breakdowns: `room`, `distance`, `language`, `session` |

Add `cohort` recordings (other speakers, not in the probes) to run AS-norm
and the simulated babble and overlap conditions; the LibriSpeech test-clean
cohort from `scripts/voice-id-eval-librispeech.py` works.

## Running

```sh
cd Packages/BlauKit
BLAU_SPEAKER_MODEL_DIR=<speakerEmbedding model dir> \
BLAU_VOICEID_EVAL_MANIFEST=../../Datasets/voice-id/manifest.json \
BLAU_VOICEID_EVAL_OUTPUT=/tmp/blau-voiceid-owner \
  swift test --filter VoiceIDEvaluationRunTests
```

Then copy the proposed thresholds into `VoiceIDConfig.calibrated` and the
results into docs/voice-id-eval.md.
