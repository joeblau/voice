# ASR evaluation recordings

This directory is for the owner's ASR evaluation set: real recordings of
the person who uses Blau, in the places they use it, with what was said.
The harness (`make eval-asr`, [docs/asr-eval.md](../../docs/asr-eval.md))
measures every engine's WER, first-partial and end-of-utterance latency and
RTF on it, the same way it does on the bundled synthetic fixtures.

**Status:** not recorded yet. Until it is, the numbers come from the
synthetic fixtures in
`Packages/BlauKit/Tests/BlauTranscriptionTests/Fixtures/ASR`.

## Consent and storage

- **Record only people who agree.** Everyone whose voice is in a recording,
  other than public broadcasts, agrees in writing to its use for evaluating
  Blau and to its storage in this public repository. Note who agreed and
  when in `consent.md` next to the manifest and summarize it in the
  manifest's `consent` field; the harness refuses a manifest without one.
- **Broadcast audio** in the background (TV, radio): short excerpts, for
  evaluation only.
- **Audio goes in Git LFS** (`.gitattributes` tracks `*.wav`, `*.m4a`,
  `*.caf` and `*.flac` under `Datasets/asr/`). Run `git lfs install` once
  before adding files.
- Anyone can ask for their recordings to be removed: delete the files and
  their manifest entries, then rewrite the LFS history if needed.

## What to record

Record on the iPhone Blau runs on (Voice Memos is fine: the harness converts
any Core Audio format to 16 kHz mono), holding it as you would when talking
to Blau. Each file is 3 to 15 seconds: half a second of lead-in, one or two
things you would say to Blau with a pause of at least 1.5 s between them,
and **at least 2 s of the room after the last word** (the end-of-utterance
rules need to hear it end).

| Category | What | How many |
| --- | --- | --- |
| `own-voice` | Quiet room, normal voice, phone at 30 cm to 1 m | 10+ |
| `cafe` | A cafe or a busy kitchen | 5+ |
| `tv` | The TV on across the room | 5+ |
| `car` | Driving, phone in a mount | 5+ |
| `accented` | Other people with other accents, with their consent | 5+ |

Say things you would really say to Blau: questions, reminders, numbers,
names. Write the reference transcript exactly as spoken, numbers in words
("three thirty", "twenty first"), no punctuation needed.

## The manifest

`manifest.json` lists every recording, in the format the bundled fixtures
use (the full description is in
[docs/asr-eval.md](../../docs/asr-eval.md#manifest-format)):

```json
{
  "name": "owner-asr",
  "consent": "Recorded by the owner on 2026-11-02; housemates agreed in writing (consent.md).",
  "sampleRate": 48000,
  "fixtures": [
    {
      "id": "own-voice-01",
      "path": "own-voice/01.m4a",
      "category": "own-voice",
      "utterances": [
        { "start": 24000, "end": 151200, "text": "Can you remind me what we decided about the launch date" }
      ],
      "tags": { "room": "office", "distance": "0.5m" }
    }
  ]
}
```

`start` and `end` mark where each utterance's speech starts and ends, in
samples at `sampleRate` (the recording's own rate is fine). Mark them in any
audio editor that shows sample positions (Audacity: set the selection format
to samples), from the first to the last audible sound of the utterance.

Evaluate the set with

```sh
make eval-asr ASR_EVAL_MANIFEST=Datasets/asr/manifest.json ASR_EVAL_BASELINE= ASR_EVAL_THRESHOLDS=
```

then add its results to [docs/asr-eval.md](../../docs/asr-eval.md).
