# ASR evaluation

- Dataset: `blau-asr-fixtures`, 26 fixtures, 32 utterances, 165.4 s of audio (clean, cafe, tv, accented)
- Device: Mac15,8 (Apple M3 Max), macOS 27.2 (Build 26B5101f)
- Generated: 2026-10-07T12:37:29Z at `f4ad36f`
- Regression gate: **passed**

## `parakeet-eou-320ms`: Parakeet realtime EOU 120M, 320 ms chunks + Silero VAD (streaming)

streaming · model parakeetRealtimeEOU@40a23f4c · eouDebounce 640 ms · maximumUtterance 30 s · silenceCommitDelay 900 ms

| Category | Files | Words | WER | Sub | Del | Ins | First partial p50 / p95 | End of utterance p50 / p95 | EOU audio p95 | RTF | Missed | Split | Unended |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| clean | 6 | 74 | 4.1% | 2 | 1 | 0 | 942 / 970 ms | 930 / 962 ms | 940 ms | 0.052 | 0 | 0 | 0 |
| cafe | 6 | 70 | 2.9% | 1 | 0 | 1 | 821 / 1106 ms | 1958 / 4518 ms | 4496 ms | 0.073 | 0 | 0 | 3 |
| tv | 6 | 68 | 27.9% | 1 | 0 | 18 | 517 / 884 ms | – | – | 0.125 | 0 | 0 | 7 |
| accented | 8 | 84 | 6.0% | 2 | 3 | 0 | 961 / 1275 ms | 930 / 942 ms | 942 ms | 0.063 | 0 | 0 | 0 |
| all | 26 | 296 | 9.8% | 6 | 4 | 19 | 874 / 1267 ms | 930 / 2171 ms | 2149 ms | 0.076 | 0 | 0 | 10 |

<details><summary>10 fixtures with errors</summary>

| Fixture | WER | Reference | Hypothesis |
| --- | ---: | --- | --- |
| clean-03 | 16.7% | The meeting moved to three thirty so I have about twenty minutes | the meeting moved to threethirty so i have about twenty minutes |
| clean-05 | 11.1% | Add milk eggs and coffee to my shopping list | at milk eggs and coffee to my shopping list |
| cafe-04 | 18.2% | What were the three things I wanted to finish before Friday | what one of the three things i wanted to finish before friday |
| tv-02 | 20.0% | How long have we been talking about the pricing page Let us wrap that up | up to the how long have we been talking about the pricing page let us wrap that up |
| tv-03 | 30.0% | Please remember that the dentist appointment is on Tuesday morning | to the news please remember that the dentist appointment is on tuesday morning |
| tv-05 | 110.0% | Go back to what we said about the onboarding flow | possible in low back to what we said about the onboarding flow the city council has approved a new plan |
| tv-06 | 16.7% | I need a better answer for why now is the right time | terminal and i need a better answer for why now is the right time |
| accented-01 | 10.0% | Could you summarize the conversation we had about the budget | you summarize the conversation we had about the budget |
| accented-07 | 22.2% | I need to finish the presentation before the weekend | need till finish the presentation before the weekend |
| accented-08 | 20.0% | Please tell me what we decided about the new office | tell me what were decided about the new office |

</details>

## `parakeet-tdt-v3`: Parakeet TDT 0.6B v3 per utterance (second pass, offline)

offline · model parakeetTDTv3@7dd20fe6 · leadingPadding 100 ms · segmentation reference labels · trailingPadding 120 ms

| Category | Files | Words | WER | Sub | Del | Ins | First partial p50 / p95 | End of utterance p50 / p95 | EOU audio p95 | RTF | Missed | Split | Unended |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| clean | 6 | 74 | 0.0% | 0 | 0 | 0 | – | 180 / 184 ms | 120 ms | 0.012 | 0 | 0 | 0 |
| cafe | 6 | 70 | 0.0% | 0 | 0 | 0 | – | 179 / 187 ms | 120 ms | 0.012 | 0 | 0 | 0 |
| tv | 6 | 68 | 2.9% | 0 | 0 | 2 | – | 189 / 214 ms | 120 ms | 0.015 | 0 | 0 | 0 |
| accented | 8 | 84 | 3.6% | 1 | 2 | 0 | – | 180 / 186 ms | 120 ms | 0.011 | 0 | 0 | 0 |
| all | 26 | 296 | 1.7% | 1 | 2 | 2 | – | 182 / 197 ms | 120 ms | 0.012 | 0 | 0 | 0 |

<details><summary>2 fixtures with errors</summary>

| Fixture | WER | Reference | Hypothesis |
| --- | ---: | --- | --- |
| tv-02 | 13.3% | How long have we been talking about the pricing page Let us wrap that up | How long have we been talking about the pricing page? Let us wrap that up with the |
| accented-07 | 33.3% | I need to finish the presentation before the weekend | Inito finish the presentation before the weekend. |

</details>

WER: corpus word error rate after normalization (sub/del/ins: substituted, deleted, inserted words). First partial: start of speech to the first partial. End of utterance: end of speech to the final (offline engines: trailing padding + compute after the utterance is handed over). Latencies are audio time plus the compute of the emitting call; "audio" columns leave the compute out. RTF: compute / audio. Missed: utterances with no final; split: utterances cut into several finals; unended: utterances finalized only because the audio ended (nothing detected their end; left out of the end-of-utterance latency).

## Regression gate

| Engine | Metric | Value | Limit | Result |
| --- | --- | ---: | ---: | --- |
| `parakeet-eou-320ms` | WER | 9.8% | 13.0% | pass |
| `parakeet-eou-320ms` | WER accented | 6.0% | 10.0% | pass |
| `parakeet-eou-320ms` | WER cafe | 2.9% | 7.0% | pass |
| `parakeet-eou-320ms` | WER clean | 4.1% | 8.0% | pass |
| `parakeet-eou-320ms` | WER tv | 27.9% | 33.0% | pass |
| `parakeet-eou-320ms` | first partial p95 | 1267 ms | 2000 ms | pass |
| `parakeet-eou-320ms` | first partial p95 (audio) | 1240 ms | 1400 ms | pass |
| `parakeet-eou-320ms` | end of utterance p95 | 2171 ms | 3500 ms | pass |
| `parakeet-eou-320ms` | end of utterance p95 (audio) | 2149 ms | 2600 ms | pass |
| `parakeet-eou-320ms` | RTF | 0.076 | 0.500 | pass |
| `parakeet-eou-320ms` | missed utterances | 0 | 1 | pass |
| `parakeet-eou-320ms` | split utterances | 0 | 1 | pass |
| `parakeet-eou-320ms` | unended utterances | 10 | 12 | pass |
| `parakeet-eou-320ms` | failures | 0 | 0 | pass |
| `parakeet-tdt-v3` | WER | 1.7% | 3.0% | pass |
| `parakeet-tdt-v3` | WER accented | 3.6% | 8.0% | pass |
| `parakeet-tdt-v3` | WER cafe | 0.0% | 5.0% | pass |
| `parakeet-tdt-v3` | WER clean | 0.0% | 5.0% | pass |
| `parakeet-tdt-v3` | WER tv | 2.9% | 8.0% | pass |
| `parakeet-tdt-v3` | end of utterance p95 | 197 ms | 5000 ms | pass |
| `parakeet-tdt-v3` | end of utterance p95 (audio) | 120 ms | 180 ms | pass |
| `parakeet-tdt-v3` | RTF | 0.012 | 1.000 | pass |
| `parakeet-tdt-v3` | missed utterances | 0 | 0 | pass |
| `parakeet-tdt-v3` | split utterances | 0 | 0 | pass |
| `parakeet-tdt-v3` | failures | 0 | 0 | pass |

## Against the baseline

Against the baseline of 2026-10-07 (11b2890) on Mac15,8 (Apple M3 Max):

| Engine | Metric | Baseline | Now | Change |
| --- | --- | ---: | ---: | ---: |
| parakeet-eou-320ms | WER | 9.8% | 9.8% | ±0.0% |
| parakeet-eou-320ms | WER clean | 4.1% | 4.1% | ±0.0% |
| parakeet-eou-320ms | WER cafe | 2.9% | 2.9% | ±0.0% |
| parakeet-eou-320ms | WER tv | 27.9% | 27.9% | ±0.0% |
| parakeet-eou-320ms | WER accented | 6.0% | 6.0% | ±0.0% |
| parakeet-eou-320ms | first partial p95 | 1260 ms | 1267 ms | +7 ms |
| parakeet-eou-320ms | end of utterance p95 | 2168 ms | 2171 ms | +3 ms |
| parakeet-eou-320ms | end of utterance p95 (audio) | 2149 ms | 2149 ms | ±0 ms |
| parakeet-eou-320ms | RTF | 0.052 | 0.076 | +0.024 |
| parakeet-eou-320ms | unended utterances | 10 | 10 | ±0 |
| parakeet-tdt-v3 | WER | 0.0% | 1.7% | +1.7% |
| parakeet-tdt-v3 | WER clean | 0.0% | 0.0% | ±0.0% |
| parakeet-tdt-v3 | WER cafe | 0.0% | 0.0% | ±0.0% |
| parakeet-tdt-v3 | WER tv | 0.0% | 2.9% | +2.9% |
| parakeet-tdt-v3 | WER accented | 0.0% | 3.6% | +3.6% |
| parakeet-tdt-v3 | end of utterance p95 | 266 ms | 197 ms | -69 ms |
| parakeet-tdt-v3 | end of utterance p95 (audio) | 200 ms | 120 ms | -80 ms |
| parakeet-tdt-v3 | RTF | 0.010 | 0.012 | +0.002 |
| parakeet-tdt-v3 | unended utterances | 0 | 0 | ±0 |
