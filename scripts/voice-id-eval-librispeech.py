#!/usr/bin/env python3
"""Builds the public voice ID calibration set from LibriSpeech.

Writes a manifest for Blau's voice ID evaluation harness (VoiceIDEvaluator,
see docs/voice-id-eval.md) that points at LibriSpeech FLAC files in place:

- Targets and impostors: the 40 speakers of dev-clean. Each speaker enrolls
  with 4 utterances from one chapter (one recording session) and is probed
  with 8 utterances of at least 7 s from the speaker's other chapters, so
  enrollment and probes come from different sessions, like a voiceprint
  recorded one day and used the next.
- AS-norm cohort and background talkers: 20 utterances from each of the 40
  speakers of test-clean (800 embeddings, disjoint from the targets).

LibriSpeech (https://www.openslr.org/12) is CC BY 4.0. No audio is copied or
committed; the manifest lands next to the corpus.

Usage:
    scripts/voice-id-eval-librispeech.py --download ~/blau-eval
    # writes ~/blau-eval/LibriSpeech/blau-voiceid-manifest.json

    scripts/voice-id-eval-librispeech.py /path/to/LibriSpeech
    # when dev-clean and test-clean are already extracted there

Needs python3 only (no third-party modules); --download needs network
access and about 700 MB of disk.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import sys
import tarfile
import urllib.request

SUBSETS = {
    "dev-clean": "https://www.openslr.org/resources/12/dev-clean.tar.gz",
    "test-clean": "https://www.openslr.org/resources/12/test-clean.tar.gz",
}
ENROLLMENT_CLIPS = 4
ENROLLMENT_SECONDS = (4.0, 15.0)
PROBES = 8
PROBE_MIN_SECONDS = 7.0
COHORT_CLIPS = 20
COHORT_MIN_SECONDS = 3.0
MANIFEST_NAME = "blau-voiceid-manifest.json"


def flac_duration(path: pathlib.Path) -> float:
    """Duration in seconds from a FLAC file's STREAMINFO block."""
    with path.open("rb") as handle:
        header = handle.read(42)
    if header[:4] != b"fLaC" or header[4] & 0x7F != 0:
        raise ValueError(f"{path} is not a FLAC file with a leading STREAMINFO block")
    info = header[8:42]
    # Bits: min/max block (32), min/max frame (48), sample rate (20),
    # channels (3), bits per sample (5), total samples (36).
    packed = int.from_bytes(info[10:18], "big")
    sample_rate = packed >> 44
    total_samples = packed & ((1 << 36) - 1)
    if sample_rate == 0:
        raise ValueError(f"{path} has no sample rate")
    return total_samples / sample_rate


def utterances(speaker_dir: pathlib.Path) -> dict[str, list[tuple[pathlib.Path, float]]]:
    """Utterances by chapter, sorted by id."""
    chapters: dict[str, list[tuple[pathlib.Path, float]]] = {}
    for chapter_dir in sorted(p for p in speaker_dir.iterdir() if p.is_dir()):
        files = sorted(chapter_dir.glob("*.flac"))
        chapters[chapter_dir.name] = [(f, flac_duration(f)) for f in files]
    return chapters


def build(root: pathlib.Path) -> dict:
    recordings = []
    dev = root / "dev-clean"
    test = root / "test-clean"
    for subset in (dev, test):
        if not subset.is_dir():
            sys.exit(f"error: {subset} not found (extract dev-clean and test-clean there, or use --download)")

    for speaker_dir in sorted((p for p in dev.iterdir() if p.is_dir()), key=lambda p: int(p.name)):
        chapters = utterances(speaker_dir)
        names = sorted(chapters)
        # Enroll from the chapter with the most usable clips; probe the rest.
        enroll_chapter = max(
            names, key=lambda c: sum(ENROLLMENT_SECONDS[0] <= d <= ENROLLMENT_SECONDS[1] for _, d in chapters[c])
        )
        enrollment = [f for f, d in chapters[enroll_chapter] if ENROLLMENT_SECONDS[0] <= d <= ENROLLMENT_SECONDS[1]]
        enrollment = enrollment[:ENROLLMENT_CLIPS]
        other = [c for c in names if c != enroll_chapter]
        candidates = [f for c in other for f, d in chapters[c] if d >= PROBE_MIN_SECONDS]
        session = "cross-session"
        if len(candidates) < PROBES:
            # One-chapter speakers: probe the same session, without reusing
            # an enrollment clip.
            used = set(enrollment)
            candidates += [f for f, d in chapters[enroll_chapter] if d >= PROBE_MIN_SECONDS and f not in used]
            session = "mixed-session"
        probes = candidates[:PROBES]
        if len(enrollment) < ENROLLMENT_CLIPS or len(probes) < PROBES:
            print(f"warning: speaker {speaker_dir.name}: {len(enrollment)} enrollment, {len(probes)} probes",
                  file=sys.stderr)
        speaker = f"dev-{speaker_dir.name}"
        for path in enrollment:
            recordings.append({"path": str(path.relative_to(root)), "speaker": speaker, "role": "enrollment"})
        for path in probes:
            recordings.append({
                "path": str(path.relative_to(root)), "speaker": speaker, "role": "probe", "source": "person",
                "tags": {"session": session},
            })

    for speaker_dir in sorted((p for p in test.iterdir() if p.is_dir()), key=lambda p: int(p.name)):
        chapters = utterances(speaker_dir)
        clips = [f for c in sorted(chapters) for f, d in chapters[c] if d >= COHORT_MIN_SECONDS][:COHORT_CLIPS]
        for path in clips:
            recordings.append({
                "path": str(path.relative_to(root)), "speaker": f"test-{speaker_dir.name}", "role": "cohort",
            })

    return {
        "name": "LibriSpeech dev-clean (40 speakers) with a test-clean cohort",
        "consent": "LibriSpeech, CC BY 4.0 (public-domain LibriVox audiobooks), https://www.openslr.org/12",
        "description": (
            f"{ENROLLMENT_CLIPS} enrollment utterances from one chapter and {PROBES} probes of at least "
            f"{PROBE_MIN_SECONDS:.0f} s from other chapters per dev-clean speaker; {COHORT_CLIPS} utterances "
            "per test-clean speaker as the AS-norm cohort and background talkers. Built by "
            "scripts/voice-id-eval-librispeech.py."
        ),
        "recordings": recordings,
    }


def download(destination: pathlib.Path) -> pathlib.Path:
    destination.mkdir(parents=True, exist_ok=True)
    root = destination / "LibriSpeech"
    for subset, url in SUBSETS.items():
        if (root / subset).is_dir():
            continue
        archive = destination / f"{subset}.tar.gz"
        if not archive.exists():
            print(f"downloading {url}", file=sys.stderr)
            urllib.request.urlretrieve(url, archive)
        print(f"extracting {archive.name}", file=sys.stderr)
        with tarfile.open(archive) as tar:
            tar.extractall(destination, filter="data")
    return root


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("directory", type=pathlib.Path,
                        help="the LibriSpeech directory, or with --download where to put it")
    parser.add_argument("--download", action="store_true", help="download and extract dev-clean and test-clean")
    args = parser.parse_args()
    root = download(args.directory) if args.download else args.directory
    manifest = build(root)
    path = root / MANIFEST_NAME
    path.write_text(json.dumps(manifest, indent=2) + "\n")
    roles: dict[str, int] = {}
    for recording in manifest["recordings"]:
        roles[recording["role"]] = roles.get(recording["role"], 0) + 1
    print(f"wrote {path}: " + ", ".join(f"{count} {role}" for role, count in sorted(roles.items())))


if __name__ == "__main__":
    main()
