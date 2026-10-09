#!/usr/bin/env python3
"""Generate the language ID fixtures (#50).

Writes `Packages/BlauKit/Tests/BlauVoiceIDTests/Fixtures/LanguageID/<id>.wav`
(16 kHz mono 16-bit PCM, stored in Git LFS) and `manifest.json`, which lists
every clip with its language (a VoxLingua107 code), where it came from and
whether the language filter should let it through (`expected`).

Three sources:

    mls       Real read speech in seven European languages from the test split
              of Multilingual LibriSpeech (CC BY 4.0, built from LibriVox's
              public-domain audiobooks), four different speakers each, fetched
              through the Hugging Face dataset viewer and decoded with ffmpeg.
    say       macOS text to speech: one sentence in each of 30 other
              languages, read by that language's own voice; and English read
              by US, UK, Irish, Australian, Indian and South African voices
              (expected through) and by non-native voices with a strong accent
              (German, French, Spanish, Japanese... reading English).
    arctic    The twelve CMU ARCTIC clips already in `Fixtures/Speakers`
              (US English, human): listed in the manifest, not copied.

Every clip is trimmed of leading silence (10 ms frames below 3% of the clip's
peak frame RMS, keeping 50 ms) and cut to 3 s; the filter only looks at the
first 2 s of a segment.

    scripts/make-language-id-fixtures.py            # regenerate every clip
    scripts/make-language-id-fixtures.py --only say # one source

Needs network access (for MLS), ffmpeg (`brew install ffmpeg`) and macOS with
the voices below installed (System Settings > Accessibility > Spoken
Content). The audio depends on the installed voices and the macOS version,
so regenerating changes it slightly: re-run the real-model evaluation
afterwards (docs/voice-id.md#language-filter-50) and update the numbers there.
"""

import argparse
import json
import math
import os
import struct
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import wave

RATE = 16_000
FRAME = RATE // 100  # 10 ms
CLIP_SECONDS = 3.0
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIXTURES = os.path.join(ROOT, "Packages/BlauKit/Tests/BlauVoiceIDTests/Fixtures")
OUT_DIR = os.path.join(FIXTURES, "LanguageID")

# -- Multilingual LibriSpeech -------------------------------------------------
# Dataset viewer config name -> VoxLingua107 code.
MLS = {
    "dutch": "nl",
    "french": "fr",
    "german": "de",
    "italian": "it",
    "polish": "pl",
    "portuguese": "pt",
    "spanish": "es",
}
MLS_SPEAKERS = 4
PAGES = 10
MLS_DATASET = "facebook/multilingual_librispeech"
VIEWER = "https://datasets-server.huggingface.co/rows"

# -- macOS voices ---------------------------------------------------------------
# (VoxLingua107 code, voice, sentence). Each sentence is long enough for 3 s.
FOREIGN_SAY = [
    ("ar", "Majed", "أريد أن أذهب إلى السوق صباح الغد لشراء بعض الخضروات والفواكه الطازجة."),
    ("bg", "Daria", "Утре сутринта ще отида до пазара, за да купя пресни зеленчуци и плодове."),
    ("ca", "Montse", "Demà al matí aniré al mercat a comprar verdures i fruita fresca per a tota la setmana."),
    ("cs", "Zuzana", "Zítra ráno půjdu na trh koupit čerstvou zeleninu a ovoce na celý týden."),
    ("da", "Sara", "I morgen tidlig tager jeg på markedet for at købe friske grøntsager og frugt til hele ugen."),
    ("de", "Anna", "Morgen früh gehe ich auf den Markt, um frisches Gemüse und Obst für die ganze Woche zu kaufen."),
    ("el", "Melina", "Αύριο το πρωί θα πάω στη λαϊκή αγορά για να αγοράσω φρέσκα λαχανικά και φρούτα."),
    ("es", "Mónica", "Mañana por la mañana voy a ir al mercado a comprar verduras y fruta fresca para toda la semana."),
    ("es", "Paulina", "¿Me puedes decir a qué hora sale el próximo autobús hacia el centro de la ciudad?"),
    ("fi", "Satu", "Huomenna aamulla menen torille ostamaan tuoreita vihanneksia ja hedelmiä koko viikoksi."),
    ("fr", "Thomas", "Demain matin, je vais au marché pour acheter des légumes et des fruits frais pour toute la semaine."),
    ("fr", "Amélie", "Est-ce que tu peux me dire à quelle heure part le prochain autobus pour le centre-ville?"),
    ("he", "Carmit", "מחר בבוקר אני הולכת לשוק לקנות ירקות ופירות טריים לכל השבוע."),
    ("hi", "Lekha", "कल सुबह मैं पूरे हफ्ते के लिए ताज़ी सब्ज़ियाँ और फल खरीदने बाज़ार जाऊँगी।"),
    ("hr", "Lana", "Sutra ujutro idem na tržnicu kupiti svježe povrće i voće za cijeli tjedan."),
    ("hu", "Tünde", "Holnap reggel kimegyek a piacra, hogy friss zöldséget és gyümölcsöt vegyek az egész hétre."),
    ("id", "Damayanti", "Besok pagi saya akan pergi ke pasar untuk membeli sayuran dan buah segar untuk seminggu."),
    ("it", "Alice", "Domani mattina vado al mercato a comprare verdura e frutta fresca per tutta la settimana."),
    ("ja", "Kyoko", "明日の朝、一週間分の新鮮な野菜と果物を買いに市場へ行くつもりです。"),
    ("ko", "Yuna", "내일 아침에 일주일 동안 먹을 신선한 채소와 과일을 사러 시장에 갈 거예요."),
    ("lt", "Ona", "Rytoj ryte eisiu į turgų nusipirkti šviežių daržovių ir vaisių visai savaitei."),
    ("ms", "Amira", "Esok pagi saya akan pergi ke pasar untuk membeli sayur-sayuran dan buah-buahan segar."),
    ("nl", "Xander", "Morgenochtend ga ik naar de markt om verse groenten en fruit voor de hele week te kopen."),
    ("no", "Nora", "I morgen tidlig skal jeg på markedet for å kjøpe ferske grønnsaker og frukt til hele uken."),
    ("pl", "Zosia", "Jutro rano pójdę na targ kupić świeże warzywa i owoce na cały tydzień."),
    ("pt", "Luciana", "Amanhã de manhã eu vou à feira comprar verduras e frutas frescas para a semana toda."),
    ("pt", "Joana", "Amanhã de manhã vou ao mercado comprar legumes e fruta fresca para a semana inteira."),
    ("ro", "Ioana", "Mâine dimineață merg la piață să cumpăr legume și fructe proaspete pentru toată săptămâna."),
    ("ru", "Milena", "Завтра утром я пойду на рынок, чтобы купить свежие овощи и фрукты на всю неделю."),
    ("sk", "Laura", "Zajtra ráno pôjdem na trh kúpiť čerstvú zeleninu a ovocie na celý týždeň."),
    ("sl", "Tina", "Jutri zjutraj grem na tržnico po sveže zelenjavo in sadje za ves teden."),
    ("sv", "Alva", "I morgon bitti går jag till torget för att köpa färska grönsaker och frukt för hela veckan."),
    ("th", "Kanya", "พรุ่งนี้เช้าฉันจะไปตลาดเพื่อซื้อผักและผลไม้สดสำหรับทั้งสัปดาห์"),
    ("tr", "Yelda", "Yarın sabah bütün hafta için taze sebze ve meyve almak üzere pazara gideceğim."),
    ("uk", "Lesya", "Завтра вранці я піду на ринок, щоб купити свіжі овочі та фрукти на весь тиждень."),
    ("vi", "Linh", "Sáng mai tôi sẽ đi chợ để mua rau và trái cây tươi cho cả tuần."),
    ("zh", "Tingting", "明天早上我要去市场买一个星期吃的新鲜蔬菜和水果。"),
    ("zh", "Meijia", "請問下一班開往市中心的公車是幾點出發呢？"),
]

ENGLISH_TEXTS = [
    "Can you remind me what we talked about yesterday afternoon before the meeting with the investors?",
    "I want to practice my answers for the interview on Thursday, so ask me the hardest questions first.",
    "Let us switch topics and talk about the product launch next month and what still has to happen.",
    "What were the three things I wanted to finish before Friday, and which one did I already start?",
]

# Native and regional English: the filter must let these through.
ENGLISH_SAY = [
    ("Samantha", "en-US"),
    ("Voice 1", "en-US"),
    ("Kathy", "en-US"),
    ("Fred", "en-US"),
    ("Daniel (English (UK))", "en-GB"),
    ("Moira (English (Ireland))", "en-IE"),
    ("Karen", "en-AU"),
    ("Rishi (English (India))", "en-IN"),
    ("Tara", "en-IN"),
    ("Tessa (English (South Africa))", "en-ZA"),
]

# English read by other languages' voices: a strong foreign accent. Reported
# on its own; the owner is a native speaker, but a false rejection here shows
# how the filter treats accented English.
ACCENTED_SAY = [
    ("Anna", "de"),
    ("Thomas", "fr"),
    ("Mónica", "es"),
    ("Alice", "it"),
    ("Luciana", "pt"),
    ("Xander", "nl"),
    ("Milena", "ru"),
    ("Zosia", "pl"),
    ("Lekha", "hi"),
    ("Kyoko", "ja"),
    ("Tingting", "zh"),
    ("Yuna", "ko"),
]

ARCTIC = ["bdl", "clb", "rms", "slt"]


def read_wav(path):
    with wave.open(path) as w:
        assert w.getframerate() == RATE and w.getnchannels() == 1 and w.getsampwidth() == 2, path
        n = w.getnframes()
        return [x / 32768.0 for x in struct.unpack(f"<{n}h", w.readframes(n))]


def write_wav(path, samples):
    clipped = [max(-1.0, min(1.0, x)) for x in samples]
    with wave.open(path, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(struct.pack(f"<{len(clipped)}h", *(int(round(x * 32767)) for x in clipped)))


def rms(samples):
    return math.sqrt(sum(x * x for x in samples) / len(samples)) if samples else 0.0


def trimmed(samples):
    """From 50 ms before the first frame above 3% of the peak frame RMS, cut
    to CLIP_SECONDS."""
    frames = [rms(samples[i : i + FRAME]) for i in range(0, len(samples) - FRAME + 1, FRAME)]
    peak = max(frames)
    first = next(i for i, level in enumerate(frames) if level >= 0.03 * peak)
    start = max(0, first * FRAME - 5 * FRAME)
    clip = samples[start : start + int(CLIP_SECONDS * RATE)]
    if len(clip) < int(CLIP_SECONDS * RATE):
        raise ValueError(f"only {len(clip) / RATE:.2f} s of audio after trimming")
    return clip


def normalized(samples, peak_dbfs=-3.0):
    peak = max(abs(x) for x in samples)
    gain = 10 ** (peak_dbfs / 20) / peak if peak > 0 else 1.0
    return [x * gain for x in samples]


def synthesize(voice, text):
    with tempfile.TemporaryDirectory() as tmp:
        path = os.path.join(tmp, "clip.wav")
        subprocess.run(
            ["say", "-v", voice, "-o", path, "--file-format=WAVE", f"--data-format=LEI16@{RATE}", text], check=True
        )
        return read_wav(path)


def decode(url):
    """Any audio URL ffmpeg reads, as 16 kHz mono floats."""
    raw = subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error", "-i", url, "-ac", "1", "-ar", str(RATE), "-f", "s16le", "-"],
        check=True,
        capture_output=True,
    ).stdout
    n = len(raw) // 2
    return [x / 32768.0 for x in struct.unpack(f"<{n}h", raw[: n * 2])]


def get_json(url, attempts=6):
    """GET JSON, backing off when the dataset viewer rate-limits (429) or fails (5xx)."""
    for attempt in range(attempts):
        request = urllib.request.Request(url, headers={"User-Agent": "blau-fixtures/1"})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            if error.code not in (429, 500, 502, 503, 504) or attempt == attempts - 1:
                raise
            time.sleep(10 * 2**attempt)


def page(config, offset, length):
    query = urllib.parse.urlencode(
        {"dataset": MLS_DATASET, "config": config, "split": "test", "offset": offset, "length": length}
    )
    return get_json(f"{VIEWER}?{query}")


def mls_clips():
    clips = []
    for config, code in MLS.items():
        # The split is sorted by speaker: sample pages spread across it.
        total = page(config, 0, 1)["num_rows_total"]
        rows = []
        for index in range(PAGES):
            rows += page(config, index * total // PAGES, 10)["rows"]
        speakers = set()
        for item in rows:
            row = item["row"]
            if row["speaker_id"] in speakers or row["audio_duration"] < CLIP_SECONDS + 1:
                continue
            samples = trimmed(decode(row["audio"][0]["src"]))
            speakers.add(row["speaker_id"])
            clip_id = f"mls-{code}-{row['speaker_id']}"
            clips.append(
                (
                    clip_id,
                    samples,
                    {
                        "language": code,
                        "source": "mls",
                        "speaker": row["speaker_id"],
                        "reference": row["id"],
                        "text": row["transcript"],
                        "expected": "rejected",
                        "category": "foreign",
                    },
                )
            )
            print(f"  {clip_id}")
            if len(speakers) == MLS_SPEAKERS:
                break
        if len(speakers) < MLS_SPEAKERS:
            sys.exit(f"MLS {config}: only {len(speakers)} speakers in the sampled rows")
    return clips


def say_clips():
    clips = []
    for code, voice, text in FOREIGN_SAY:
        clip_id = f"say-{code}-{voice.lower().replace(' ', '')}"
        clip_id = clip_id.encode("ascii", "ignore").decode()
        clips.append(
            (
                clip_id,
                trimmed(synthesize(voice, text)),
                {"language": code, "source": "say", "speaker": voice, "text": text, "expected": "rejected",
                 "category": "foreign"},
            )
        )
        print(f"  {clip_id}")
    for index, (voice, accent) in enumerate(ENGLISH_SAY):
        text = ENGLISH_TEXTS[index % len(ENGLISH_TEXTS)]
        clip_id = f"say-{accent.lower()}-{voice.split(' (')[0].lower().replace(' ', '')}"
        clips.append(
            (
                clip_id,
                trimmed(synthesize(voice, text)),
                {"language": "en", "source": "say", "speaker": voice, "accent": accent, "text": text,
                 "expected": "allowed", "category": "english"},
            )
        )
        print(f"  {clip_id}")
    for index, (voice, accent) in enumerate(ACCENTED_SAY):
        text = ENGLISH_TEXTS[index % len(ENGLISH_TEXTS)]
        clip_id = f"say-en-accent-{accent}-{voice.lower()}".encode("ascii", "ignore").decode()
        clips.append(
            (
                clip_id,
                trimmed(synthesize(voice, text)),
                {"language": "en", "source": "say", "speaker": voice, "accent": accent, "text": text,
                 "expected": "allowed", "category": "accented"},
            )
        )
        print(f"  {clip_id}")
    return clips


def arctic_entries():
    entries = []
    for speaker in ARCTIC:
        for utterance in ["a0001", "a0002", "a0003"]:
            name = f"{speaker}_{utterance}"
            entries.append(
                {"id": f"arctic-{name}", "file": f"Speakers/{name}.wav", "language": "en", "source": "arctic",
                 "speaker": speaker, "expected": "allowed", "category": "english"}
            )
    return entries


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", choices=["mls", "say"], help="regenerate one source, keep the other's entries")
    args = parser.parse_args()

    os.makedirs(OUT_DIR, exist_ok=True)
    manifest_path = os.path.join(OUT_DIR, "manifest.json")
    previous = []
    if args.only and os.path.exists(manifest_path):
        with open(manifest_path) as f:
            previous = [c for c in json.load(f)["clips"] if c["source"] not in (args.only, "arctic")]

    clips = []
    if args.only in (None, "mls"):
        print("Multilingual LibriSpeech")
        clips += mls_clips()
    if args.only in (None, "say"):
        print("macOS voices")
        clips += say_clips()

    entries = list(previous)
    for clip_id, samples, info in clips:
        write_wav(os.path.join(OUT_DIR, f"{clip_id}.wav"), normalized(samples))
        entries.append({"id": clip_id, "file": f"LanguageID/{clip_id}.wav", **info})
    entries += arctic_entries()
    entries.sort(key=lambda e: (e["category"], e["id"]))
    with open(manifest_path, "w") as f:
        json.dump({"sampleRate": RATE, "clipSeconds": CLIP_SECONDS, "clips": entries}, f, indent=2,
                  ensure_ascii=False)
        f.write("\n")
    counts = {}
    for entry in entries:
        counts[entry["category"]] = counts.get(entry["category"], 0) + 1
    print(f"Wrote {len(entries)} entries: {counts}")


if __name__ == "__main__":
    main()
