# Voice ID evaluation: LibriSpeech dev-clean (40 speakers) with a test-clean cohort

- Date: 2026-10-07
- Model: `wespeaker-resnet34-lm@df2625ac`
- Consent / licence: LibriSpeech, CC BY 4.0 (public-domain LibriVox audiobooks), https://www.openslr.org/12
- Target speakers: 40 (160 enrollment clips)
- Probe recordings: 320 (person 320)
- AS-norm cohort: 800 embeddings
- Preprocessors: none

## Proposed thresholds

Scoring `cosine/centroid`, every condition pooled. `T_hi` is the lowest threshold with FAR <= 0.50%, `T_lo` the highest with FRR <= 2.00%, rounded outward to 0.01.

| Window | T_hi | T_lo | FAR at T_hi | FRR at T_hi | FRR at T_lo | FAR at T_lo | Owner uncertain | Impostor uncertain | Trials (owner / impostor) |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1.5 s | 0.38 | 0.20 | 0.47% (355) | 13.5% | 1.94% (31) | 11.3% | 11.6% | 10.8% | 1600 / 74880 |
| 3 s | 0.40 | 0.27 | 0.50% (372) | 5.88% | 1.88% (30) | 6.09% | 4.00% | 5.59% | 1600 / 74880 |

Counts in brackets are the errors behind the rate; fewer than about 30 makes it a rough estimate.

```swift
short: VoiceIDThresholds(accept: 0.38, reject: 0.20),
long: VoiceIDThresholds(accept: 0.40, reject: 0.27),
```

## Equal error rate by window

Every condition pooled.

| Scoring | 1 s | 1.5 s | 3 s | 6 s |
| --- | ---: | ---: | ---: | ---: |
| cosine/centroid | 6.12% | 4.50% | 3.00% | 3.00% |
| cosine/bestMatch | 6.33% | 4.31% | 2.81% | 2.88% |
| as-norm(100)/centroid | 5.95% | 4.50% | 3.17% | 3.09% |

## Operating points

Every condition pooled.

| Scoring | Window | EER | EER threshold | FAR @ FRR <= 1.00% | FAR @ FRR <= 3.00% | FRR @ FAR <= 1.00% | FRR @ FAR <= 0.50% | Trials (owner / impostor) |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| cosine/centroid | 1 s | 6.12% | 0.23 | 26.3% | 13.2% | 17.6% | 22.9% | 1600 / 74880 |
| cosine/centroid | 1.5 s | 4.50% | 0.27 | 20.2% | 6.70% | 10.4% | 13.1% | 1600 / 74880 |
| cosine/centroid | 3 s | 3.00% | 0.32 | 9.25% | 2.92% | 4.75% | 5.88% | 1600 / 74880 |
| cosine/centroid | 6 s | 3.00% | 0.33 | 9.35% | 2.95% | 3.56% | 4.19% | 1600 / 74880 |
| cosine/bestMatch | 1 s | 6.33% | 0.26 | 25.2% | 12.7% | 18.4% | 23.9% | 1600 / 74880 |
| cosine/bestMatch | 1.5 s | 4.31% | 0.30 | 15.0% | 7.16% | 10.6% | 13.9% | 1600 / 74880 |
| cosine/bestMatch | 3 s | 2.81% | 0.35 | 8.30% | 2.62% | 4.69% | 6.44% | 1600 / 74880 |
| cosine/bestMatch | 6 s | 2.88% | 0.36 | 7.90% | 1.95% | 3.62% | 4.56% | 1600 / 74880 |
| as-norm(100)/centroid | 1 s | 5.95% | -0.58 | 27.9% | 13.2% | 16.4% | 22.6% | 1600 / 74880 |
| as-norm(100)/centroid | 1.5 s | 4.50% | -0.01 | 18.1% | 7.64% | 9.62% | 13.5% | 1600 / 74880 |
| as-norm(100)/centroid | 3 s | 3.17% | 0.69 | 9.86% | 3.19% | 5.12% | 6.69% | 1600 / 74880 |
| as-norm(100)/centroid | 6 s | 3.09% | 0.89 | 10.7% | 3.27% | 3.81% | 5.00% | 1600 / 74880 |

## Equal error rate by condition

Scoring `cosine/centroid`, no preprocessing. Conditions without owner trials (loudspeaker) have no EER; see the decision breakdown.

| Condition | 1 s | 1.5 s | 3 s | 6 s |
| --- | ---: | ---: | ---: | ---: |
| clean | 2.64% | 1.88% | 2.02% | 2.19% |
| room-near | 3.00% | 2.34% | 2.19% | 2.50% |
| room-far | 8.12% | 5.62% | 3.44% | 3.86% |
| babble | 6.50% | 4.13% | 2.87% | 3.12% |
| loudspeaker | – | – | – | – |
| overlap | 8.12% | 6.58% | 3.75% | 3.12% |

| Condition | What it simulates |
| --- | --- |
| clean | The recording as is |
| room-near | Small room, phone close (RT60 0.3 s, DRR +8 dB), room tone at 30 dB SNR |
| room-far | Living room, phone 2-3 m away (RT60 0.6 s, DRR -3 dB), room tone at 15 dB SNR |
| babble | Four background talkers at 10 dB SNR in a small room (RT60 0.4 s, DRR +3 dB) |
| loudspeaker | Played through a small speaker (200 Hz-5 kHz, saturated) across a living room (RT60 0.5 s, DRR 0 dB) |
| overlap | A second talker 6 dB below the probe's talker |

## Decisions at the proposed thresholds

Share of trials accepted / uncertain / rejected. Owner trials should be accepted; impostor accepts are false accepts. Groups: `all`, the probe's `source`, and any manifest tags.

| Window | Condition | Group | Trials | Count | Accept | Uncertain | Reject |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: |
| 1.5 s | all | all | owner | 1600 | 86.5% | 11.6% | 1.94% |
| 1.5 s | all | session=cross-session | owner | 1160 | 84.7% | 12.9% | 2.33% |
| 1.5 s | all | session=mixed-session | owner | 440 | 91.1% | 7.95% | 0.91% |
| 1.5 s | all | all | impostor | 74880 | 0.47% | 10.8% | 88.7% |
| 1.5 s | all | session=cross-session | impostor | 54288 | 0.55% | 11.7% | 87.8% |
| 1.5 s | all | session=mixed-session | impostor | 20592 | 0.27% | 8.45% | 91.3% |
| 1.5 s | clean | all | owner | 320 | 96.2% | 3.44% | 0.31% |
| 1.5 s | clean | session=cross-session | owner | 232 | 94.8% | 4.74% | 0.43% |
| 1.5 s | clean | session=mixed-session | owner | 88 | 100.0% | 0% | 0% |
| 1.5 s | clean | all | impostor | 12480 | 0.64% | 12.1% | 87.3% |
| 1.5 s | clean | session=cross-session | impostor | 9048 | 0.80% | 13.2% | 86.0% |
| 1.5 s | clean | session=mixed-session | impostor | 3432 | 0.23% | 9.03% | 90.7% |
| 1.5 s | room-near | all | owner | 320 | 95.6% | 4.06% | 0.31% |
| 1.5 s | room-near | session=cross-session | owner | 232 | 94.4% | 5.17% | 0.43% |
| 1.5 s | room-near | session=mixed-session | owner | 88 | 98.9% | 1.14% | 0% |
| 1.5 s | room-near | all | impostor | 12480 | 0.58% | 11.6% | 87.8% |
| 1.5 s | room-near | session=cross-session | impostor | 9048 | 0.69% | 12.6% | 86.7% |
| 1.5 s | room-near | session=mixed-session | impostor | 3432 | 0.29% | 8.83% | 90.9% |
| 1.5 s | room-far | all | owner | 320 | 76.9% | 19.7% | 3.44% |
| 1.5 s | room-far | session=cross-session | owner | 232 | 72.8% | 22.4% | 4.74% |
| 1.5 s | room-far | session=mixed-session | owner | 88 | 87.5% | 12.5% | 0% |
| 1.5 s | room-far | all | impostor | 12480 | 0.35% | 9.61% | 90.0% |
| 1.5 s | room-far | session=cross-session | impostor | 9048 | 0.39% | 10.3% | 89.3% |
| 1.5 s | room-far | session=mixed-session | impostor | 3432 | 0.26% | 7.75% | 92.0% |
| 1.5 s | babble | all | owner | 320 | 80.0% | 18.4% | 1.56% |
| 1.5 s | babble | session=cross-session | owner | 232 | 78.9% | 19.0% | 2.16% |
| 1.5 s | babble | session=mixed-session | owner | 88 | 83.0% | 17.0% | 0% |
| 1.5 s | babble | all | impostor | 12480 | 0.39% | 9.43% | 90.2% |
| 1.5 s | babble | session=cross-session | impostor | 9048 | 0.43% | 10.3% | 89.3% |
| 1.5 s | babble | session=mixed-session | impostor | 3432 | 0.29% | 7.23% | 92.5% |
| 1.5 s | loudspeaker | all | impostor | 12480 | 0.39% | 10.9% | 88.7% |
| 1.5 s | loudspeaker | session=cross-session | impostor | 9048 | 0.45% | 11.6% | 87.9% |
| 1.5 s | loudspeaker | session=mixed-session | impostor | 3432 | 0.23% | 8.80% | 91.0% |
| 1.5 s | overlap | all | owner | 320 | 83.8% | 12.2% | 4.06% |
| 1.5 s | overlap | session=cross-session | owner | 232 | 82.8% | 13.4% | 3.88% |
| 1.5 s | overlap | session=mixed-session | owner | 88 | 86.4% | 9.09% | 4.55% |
| 1.5 s | overlap | all | impostor | 12480 | 0.49% | 11.2% | 88.3% |
| 1.5 s | overlap | session=cross-session | impostor | 9048 | 0.56% | 12.1% | 87.4% |
| 1.5 s | overlap | session=mixed-session | impostor | 3432 | 0.29% | 9.06% | 90.6% |

| Window | Condition | Group | Trials | Count | Accept | Uncertain | Reject |
| --- | --- | --- | --- | ---: | ---: | ---: | ---: |
| 3 s | all | all | owner | 1600 | 94.1% | 4.00% | 1.88% |
| 3 s | all | session=cross-session | owner | 1160 | 92.3% | 5.17% | 2.50% |
| 3 s | all | session=mixed-session | owner | 440 | 98.9% | 0.91% | 0.23% |
| 3 s | all | all | impostor | 74880 | 0.50% | 5.59% | 93.9% |
| 3 s | all | session=cross-session | impostor | 54288 | 0.55% | 6.24% | 93.2% |
| 3 s | all | session=mixed-session | impostor | 20592 | 0.34% | 3.87% | 95.8% |
| 3 s | clean | all | owner | 320 | 96.6% | 2.81% | 0.62% |
| 3 s | clean | session=cross-session | owner | 232 | 95.3% | 3.88% | 0.86% |
| 3 s | clean | session=mixed-session | owner | 88 | 100.0% | 0% | 0% |
| 3 s | clean | all | impostor | 12480 | 0.59% | 6.25% | 93.2% |
| 3 s | clean | session=cross-session | impostor | 9048 | 0.70% | 7.03% | 92.3% |
| 3 s | clean | session=mixed-session | impostor | 3432 | 0.32% | 4.20% | 95.5% |
| 3 s | room-near | all | owner | 320 | 96.6% | 2.81% | 0.62% |
| 3 s | room-near | session=cross-session | owner | 232 | 95.3% | 3.88% | 0.86% |
| 3 s | room-near | session=mixed-session | owner | 88 | 100.0% | 0% | 0% |
| 3 s | room-near | all | impostor | 12480 | 0.54% | 5.93% | 93.5% |
| 3 s | room-near | session=cross-session | impostor | 9048 | 0.61% | 6.80% | 92.6% |
| 3 s | room-near | session=mixed-session | impostor | 3432 | 0.35% | 3.64% | 96.0% |
| 3 s | room-far | all | owner | 320 | 92.2% | 4.69% | 3.12% |
| 3 s | room-far | session=cross-session | owner | 232 | 89.7% | 6.03% | 4.31% |
| 3 s | room-far | session=mixed-session | owner | 88 | 98.9% | 1.14% | 0% |
| 3 s | room-far | all | impostor | 12480 | 0.42% | 4.90% | 94.7% |
| 3 s | room-far | session=cross-session | impostor | 9048 | 0.45% | 5.46% | 94.1% |
| 3 s | room-far | session=mixed-session | impostor | 3432 | 0.35% | 3.41% | 96.2% |
| 3 s | babble | all | owner | 320 | 92.8% | 5.00% | 2.19% |
| 3 s | babble | session=cross-session | owner | 232 | 90.5% | 6.47% | 3.02% |
| 3 s | babble | session=mixed-session | owner | 88 | 98.9% | 1.14% | 0% |
| 3 s | babble | all | impostor | 12480 | 0.43% | 4.90% | 94.7% |
| 3 s | babble | session=cross-session | impostor | 9048 | 0.42% | 5.40% | 94.2% |
| 3 s | babble | session=mixed-session | impostor | 3432 | 0.47% | 3.55% | 96.0% |
| 3 s | loudspeaker | all | impostor | 12480 | 0.45% | 5.46% | 94.1% |
| 3 s | loudspeaker | session=cross-session | impostor | 9048 | 0.46% | 5.88% | 93.7% |
| 3 s | loudspeaker | session=mixed-session | impostor | 3432 | 0.41% | 4.34% | 95.3% |
| 3 s | overlap | all | owner | 320 | 92.5% | 4.69% | 2.81% |
| 3 s | overlap | session=cross-session | owner | 232 | 90.9% | 5.60% | 3.45% |
| 3 s | overlap | session=mixed-session | owner | 88 | 96.6% | 2.27% | 1.14% |
| 3 s | overlap | all | impostor | 12480 | 0.54% | 6.11% | 93.3% |
| 3 s | overlap | session=cross-session | impostor | 9048 | 0.69% | 6.89% | 92.4% |
| 3 s | overlap | session=mixed-session | impostor | 3432 | 0.17% | 4.08% | 95.7% |
