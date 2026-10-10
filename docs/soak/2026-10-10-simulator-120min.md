Measured at commit `da17a71` on an iPhone 17 simulator, iOS 27.0 (24A434), Xcode 27.2 beta (27B5019j).

Command: `make soak SOAK_MINUTES=120 SOAK_OUTPUT=.build/results/codex-120min DESTINATION='id=<dedicated simulator>' XCODEBUILD_FLAGS='-parallel-testing-enabled NO -collect-test-diagnostics never'`.

## Long-session soak: passed

121.0 min of audio (user speech from synthetic signal (seed 24301, no pauses); TV dialogue (194 bursts) from synthetic signal (seed 466661); and silence) at 10× real time, in 12.1 min on iPhone 17 (A19), Simulator, iOS Simulator 27.0 (Build 24A434). scripted ASR, energy VAD.

Realtime session renewal scheduled after 7.2 min of wall time (xAI's 110 minutes, scaled); renewed 1 time.

Transcript: the script's word alignment, judged line by line.

| Check | Result | Measured | Limit |
| --- | --- | --- | --- |
| `memory.slope` | pass | +0.80 MB/h (36.8 MB → 44.0 MB, peak 44.0 MB; live heap +1.48 MB/h, 19.1 MB → 22.9 MB) | ≤ 2 MB/h of audio |
| `asr.chunkLatency` | pass | 3.14 µs → 4.22 µs per chunk (108 intervals; median of the early and late thirds) | late ≤ 1.5× early, or +2 ms at most |
| `realtime.firstAudio` | pass | 64.1 ms → 64.3 ms to first audio (94 intervals; median of the early and late thirds) | late ≤ 1.5× early, or +50 ms at most |
| `capture.droppedFrames` | pass | 0 of 363022 lost in capture, 0 of 363022 missed by a subscriber | ≤ 0.1% of frames lost in capture, and of published frames missed by a subscriber |
| `conversation.complete` | pass | 265 transcribed, 265 answered, 0 failed | all 265 lines, no failed turn |
| `realtime.rollover` | pass | 1 renewed, 1 reseeded, 2 connections | ≥ 1 renewed, each reseeded on a new connection |
| `voiceid.background` | pass | 660 of 660 background scores rejected, 831 of 831 user scores accepted; the gate passed on 265 and kept back 0 | every background score rejected, every user score accepted, every line passed on |
| `topics.count` | pass | 43 boundaries for 44 topic changes | 22...67 |

265 lines, 194 background bursts, 44 scripted topic changes; 2 realtime connections.

<details><summary>Samples</summary>

| Audio | Wall | Footprint | Heap | ASR chunks | ms/chunk | First audio | Dropped | Utterances | Replies | Topics | Renewed |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0.0 min | 0.0 min | 36.8 MB | 19.1 MB | 0 | – | – | 0 | 0 | 0 | 0 | 0 |
| 1.0 min | 0.1 min | 37.4 MB | 19.7 MB | 84 | 4.42 µs | 70.0 ms | 0 | 4 | 3 | 0 | 0 |
| 2.0 min | 0.2 min | 37.5 MB | 20.1 MB | 161 | 2.97 µs | 62.5 ms | 0 | 6 | 6 | 0 | 0 |
| 3.0 min | 0.3 min | 37.5 MB | 20.1 MB | 225 | 2.08 µs | 64.6 ms | 0 | 7 | 7 | 0 | 0 |
| 4.0 min | 0.4 min | 37.6 MB | 20.1 MB | 304 | 2.76 µs | 64.9 ms | 0 | 11 | 10 | 1 | 0 |
| 5.0 min | 0.5 min | 37.5 MB | 20.2 MB | 403 | 1.64 µs | 64.6 ms | 0 | 12 | 12 | 1 | 0 |
| 6.0 min | 0.6 min | 37.5 MB | 20.3 MB | 451 | 3.86 µs | 62.6 ms | 0 | 14 | 13 | 1 | 0 |
| 7.0 min | 0.7 min | 37.5 MB | 20.8 MB | 525 | 3.38 µs | 64.0 ms | 0 | 17 | 17 | 2 | 0 |
| 8.0 min | 0.8 min | 37.5 MB | 20.2 MB | 604 | 1.89 µs | 63.5 ms | 0 | 18 | 18 | 2 | 0 |
| 9.0 min | 0.9 min | 37.4 MB | 20.3 MB | 670 | 4.37 µs | 62.7 ms | 0 | 21 | 20 | 2 | 0 |
| 10.0 min | 1.0 min | 37.4 MB | 20.4 MB | 743 | 3.49 µs | 63.2 ms | 0 | 24 | 24 | 3 | 0 |
| 11.0 min | 1.1 min | 37.4 MB | 20.7 MB | 818 | 2.36 µs | – | 0 | 24 | 24 | 3 | 0 |
| 12.0 min | 1.2 min | 37.4 MB | 20.4 MB | 902 | 4.95 µs | 63.6 ms | 0 | 28 | 27 | 3 | 0 |
| 13.0 min | 1.3 min | 37.5 MB | 20.5 MB | 980 | 1.90 µs | 62.8 ms | 0 | 30 | 30 | 4 | 0 |
| 14.0 min | 1.4 min | 37.4 MB | 20.3 MB | 1046 | 2.41 µs | 62.5 ms | 0 | 31 | 30 | 4 | 0 |
| 15.0 min | 1.5 min | 37.4 MB | 20.4 MB | 1119 | 2.89 µs | 64.5 ms | 0 | 35 | 34 | 5 | 0 |
| 16.0 min | 1.6 min | 37.5 MB | 20.5 MB | 1208 | 1.25 µs | 64.5 ms | 0 | 36 | 36 | 5 | 0 |
| 17.0 min | 1.7 min | 37.5 MB | 20.5 MB | 1258 | 2.41 µs | 62.8 ms | 0 | 38 | 37 | 5 | 0 |
| 18.0 min | 1.8 min | 37.5 MB | 20.5 MB | 1336 | 2.31 µs | 63.4 ms | 0 | 41 | 41 | 6 | 0 |
| 19.0 min | 1.9 min | 37.5 MB | 20.5 MB | 1408 | 1.85 µs | 62.5 ms | 0 | 42 | 42 | 6 | 0 |
| 20.0 min | 2.0 min | 37.7 MB | 20.6 MB | 1474 | 4.32 µs | 65.2 ms | 0 | 45 | 44 | 6 | 0 |
| 21.0 min | 2.1 min | 37.6 MB | 20.6 MB | 1544 | 2.67 µs | 62.1 ms | 0 | 48 | 48 | 7 | 0 |
| 22.0 min | 2.2 min | 37.6 MB | 21.0 MB | 1620 | 2.36 µs | – | 0 | 48 | 48 | 7 | 0 |
| 23.0 min | 2.3 min | 37.7 MB | 20.7 MB | 1697 | 4.47 µs | 63.6 ms | 0 | 52 | 51 | 7 | 0 |
| 24.0 min | 2.4 min | 37.7 MB | 20.7 MB | 1788 | 2.42 µs | 63.7 ms | 0 | 54 | 54 | 8 | 0 |
| 25.0 min | 2.5 min | 37.6 MB | 20.7 MB | 1846 | 2.94 µs | 62.4 ms | 0 | 55 | 55 | 8 | 0 |
| 26.0 min | 2.6 min | 37.7 MB | 21.2 MB | 1923 | 3.33 µs | 129.7 ms | 0 | 58 | 58 | 9 | 0 |
| 27.0 min | 2.7 min | 37.7 MB | 20.7 MB | 2019 | 2.59 µs | 63.8 ms | 0 | 60 | 60 | 9 | 0 |
| 28.0 min | 2.8 min | 37.6 MB | 20.8 MB | 2069 | 3.85 µs | 64.7 ms | 0 | 62 | 61 | 9 | 0 |
| 29.0 min | 2.9 min | 37.7 MB | 21.2 MB | 2136 | 3.59 µs | 68.2 ms | 0 | 65 | 65 | 10 | 0 |
| 30.0 min | 3.0 min | 37.7 MB | 20.8 MB | 2218 | 1.98 µs | 64.6 ms | 0 | 66 | 66 | 10 | 0 |
| 31.0 min | 3.1 min | 37.6 MB | 20.9 MB | 2282 | 4.59 µs | 64.6 ms | 0 | 69 | 68 | 10 | 0 |
| 32.0 min | 3.2 min | 37.6 MB | 20.9 MB | 2351 | 4.95 µs | 64.1 ms | 0 | 72 | 72 | 11 | 0 |
| 33.0 min | 3.3 min | 37.6 MB | 21.2 MB | 2424 | 4.71 µs | – | 0 | 72 | 72 | 11 | 0 |
| 34.0 min | 3.4 min | 37.7 MB | 20.9 MB | 2506 | 5.44 µs | 63.7 ms | 0 | 76 | 75 | 11 | 0 |
| 35.0 min | 3.5 min | 37.7 MB | 21.1 MB | 2589 | 2.74 µs | 63.2 ms | 0 | 78 | 78 | 12 | 0 |
| 36.0 min | 3.6 min | 37.7 MB | 21.0 MB | 2650 | 2.61 µs | 65.5 ms | 0 | 79 | 78 | 12 | 0 |
| 37.0 min | 3.7 min | 37.7 MB | 21.1 MB | 2727 | 5.68 µs | 64.8 ms | 0 | 83 | 82 | 13 | 0 |
| 38.0 min | 3.8 min | 37.7 MB | 21.0 MB | 2826 | 3.98 µs | 64.6 ms | 0 | 84 | 84 | 13 | 0 |
| 39.0 min | 3.9 min | 37.8 MB | 21.0 MB | 2874 | 7.10 µs | 64.8 ms | 0 | 86 | 86 | 13 | 0 |
| 40.0 min | 4.0 min | 37.8 MB | 21.1 MB | 2954 | 6.59 µs | 64.4 ms | 0 | 90 | 89 | 14 | 0 |
| 41.0 min | 4.1 min | 37.8 MB | 21.1 MB | 3025 | 2.32 µs | – | 0 | 90 | 90 | 14 | 0 |
| 42.0 min | 4.2 min | 37.8 MB | 21.1 MB | 3089 | 4.45 µs | 63.8 ms | 0 | 93 | 93 | 14 | 0 |
| 43.0 min | 4.3 min | 37.8 MB | 21.1 MB | 3167 | 3.45 µs | 64.3 ms | 0 | 96 | 96 | 15 | 0 |
| 44.0 min | 4.4 min | 37.8 MB | 21.9 MB | 3235 | 2.36 µs | – | 0 | 96 | 96 | 15 | 0 |
| 45.0 min | 4.5 min | 43.3 MB | 21.3 MB | 3309 | 5.90 µs | 63.0 ms | 0 | 100 | 99 | 15 | 0 |
| 46.0 min | 4.6 min | 43.6 MB | 21.3 MB | 3398 | 3.66 µs | 63.2 ms | 0 | 102 | 102 | 16 | 0 |
| 47.0 min | 4.7 min | 43.6 MB | 21.3 MB | 3456 | 2.84 µs | 64.7 ms | 0 | 103 | 103 | 16 | 0 |
| 48.0 min | 4.8 min | 43.6 MB | 21.4 MB | 3537 | 4.83 µs | 64.1 ms | 0 | 107 | 106 | 17 | 0 |
| 49.0 min | 4.9 min | 43.6 MB | 21.3 MB | 3635 | 2.80 µs | 66.0 ms | 0 | 108 | 108 | 17 | 0 |
| 50.0 min | 5.0 min | 43.6 MB | 21.3 MB | 3682 | 3.91 µs | 64.0 ms | 0 | 110 | 110 | 17 | 0 |
| 51.0 min | 5.1 min | 43.6 MB | 21.4 MB | 3759 | 4.87 µs | 64.4 ms | 0 | 114 | 113 | 18 | 0 |
| 52.0 min | 5.2 min | 43.6 MB | 21.4 MB | 3836 | 2.19 µs | – | 0 | 114 | 114 | 18 | 0 |
| 53.0 min | 5.3 min | 43.6 MB | 21.4 MB | 3904 | 5.68 µs | 66.0 ms | 0 | 117 | 117 | 18 | 0 |
| 54.0 min | 5.4 min | 43.6 MB | 21.4 MB | 3984 | 13.70 µs | 64.7 ms | 0 | 120 | 120 | 19 | 0 |
| 55.0 min | 5.5 min | 43.6 MB | 21.4 MB | 4054 | 3.49 µs | – | 0 | 120 | 120 | 19 | 0 |
| 56.0 min | 5.6 min | 43.6 MB | 21.5 MB | 4121 | 6.95 µs | 64.6 ms | 0 | 124 | 124 | 20 | 0 |
| 57.0 min | 5.7 min | 43.6 MB | 21.5 MB | 4209 | 4.17 µs | 65.0 ms | 0 | 126 | 126 | 20 | 0 |
| 58.0 min | 5.8 min | 43.6 MB | 21.5 MB | 4266 | 4.93 µs | 64.8 ms | 0 | 127 | 127 | 20 | 0 |
| 59.0 min | 5.9 min | 43.6 MB | 21.5 MB | 4343 | 4.19 µs | 63.6 ms | 0 | 131 | 130 | 21 | 0 |
| 60.0 min | 6.0 min | 43.6 MB | 21.5 MB | 4432 | 2.43 µs | 65.5 ms | 0 | 132 | 132 | 21 | 0 |
| 61.0 min | 6.1 min | 43.6 MB | 21.5 MB | 4486 | 7.85 µs | 64.9 ms | 0 | 134 | 134 | 21 | 0 |
| 62.0 min | 6.2 min | 43.7 MB | 21.6 MB | 4566 | 5.72 µs | 63.5 ms | 0 | 138 | 137 | 22 | 0 |
| 63.0 min | 6.3 min | 43.8 MB | 21.6 MB | 4642 | 2.65 µs | – | 0 | 138 | 138 | 22 | 0 |
| 64.0 min | 6.4 min | 43.7 MB | 21.6 MB | 4711 | 4.44 µs | 63.6 ms | 0 | 141 | 141 | 22 | 0 |
| 65.0 min | 6.5 min | 43.6 MB | 21.7 MB | 4796 | 4.40 µs | 64.2 ms | 0 | 144 | 144 | 23 | 0 |
| 66.0 min | 6.6 min | 43.6 MB | 22.2 MB | 4874 | 3.54 µs | – | 0 | 144 | 144 | 23 | 0 |
| 67.0 min | 6.7 min | 43.7 MB | 21.7 MB | 4941 | 4.48 µs | 64.7 ms | 0 | 148 | 148 | 24 | 0 |
| 68.0 min | 6.8 min | 43.7 MB | 21.7 MB | 5042 | 5.52 µs | 64.0 ms | 0 | 150 | 150 | 24 | 0 |
| 69.0 min | 6.9 min | 43.7 MB | 22.0 MB | 5093 | 3.78 µs | 64.3 ms | 0 | 151 | 151 | 24 | 0 |
| 70.0 min | 7.0 min | 43.6 MB | 21.9 MB | 5172 | 3.77 µs | 64.1 ms | 0 | 155 | 154 | 25 | 0 |
| 71.0 min | 7.1 min | 43.6 MB | 21.8 MB | 5268 | 3.67 µs | 63.6 ms | 0 | 156 | 156 | 25 | 0 |
| 72.0 min | 7.2 min | 43.8 MB | 21.9 MB | 5315 | 3.29 µs | 63.5 ms | 0 | 158 | 158 | 25 | 1 |
| 73.0 min | 7.3 min | 43.9 MB | 22.0 MB | 5392 | 5.50 µs | 63.4 ms | 0 | 162 | 161 | 26 | 1 |
| 74.0 min | 7.4 min | 43.8 MB | 21.9 MB | 5465 | 1.48 µs | – | 0 | 162 | 162 | 26 | 1 |
| 75.0 min | 7.5 min | 43.8 MB | 22.1 MB | 5534 | 4.93 µs | 62.6 ms | 0 | 165 | 165 | 26 | 1 |
| 76.0 min | 7.6 min | 43.8 MB | 22.0 MB | 5614 | 6.09 µs | 64.0 ms | 0 | 168 | 168 | 27 | 1 |
| 77.0 min | 7.7 min | 43.8 MB | 22.0 MB | 5679 | 2.63 µs | 61.9 ms | 0 | 169 | 168 | 27 | 1 |
| 78.0 min | 7.8 min | 43.8 MB | 22.0 MB | 5744 | 3.28 µs | 64.2 ms | 0 | 172 | 172 | 28 | 1 |
| 79.0 min | 7.9 min | 43.8 MB | 22.1 MB | 5848 | 2.42 µs | 63.4 ms | 0 | 174 | 174 | 28 | 1 |
| 80.0 min | 8.0 min | 43.8 MB | 22.3 MB | 5898 | 4.44 µs | 62.6 ms | 0 | 175 | 175 | 28 | 1 |
| 81.0 min | 8.1 min | 43.8 MB | 22.1 MB | 5965 | 5.59 µs | 64.8 ms | 0 | 179 | 179 | 29 | 1 |
| 82.0 min | 8.2 min | 43.8 MB | 22.1 MB | 6064 | 2.83 µs | 65.5 ms | 0 | 180 | 180 | 29 | 1 |
| 83.0 min | 8.3 min | 43.8 MB | 22.1 MB | 6130 | 6.09 µs | 65.0 ms | 0 | 183 | 182 | 29 | 1 |
| 84.0 min | 8.4 min | 43.8 MB | 22.2 MB | 6188 | 3.67 µs | 64.1 ms | 0 | 186 | 186 | 30 | 1 |
| 85.0 min | 8.5 min | 43.9 MB | 22.1 MB | 6269 | 2.15 µs | – | 0 | 186 | 186 | 30 | 1 |
| 86.0 min | 8.6 min | 43.8 MB | 22.2 MB | 6359 | 5.27 µs | 64.7 ms | 0 | 190 | 189 | 30 | 1 |
| 87.0 min | 8.7 min | 43.8 MB | 22.3 MB | 6437 | 4.47 µs | 64.2 ms | 0 | 192 | 192 | 31 | 1 |
| 88.0 min | 8.8 min | 43.7 MB | 22.5 MB | 6497 | 3.02 µs | 63.4 ms | 0 | 193 | 192 | 31 | 1 |
| 89.0 min | 8.9 min | 43.7 MB | 22.4 MB | 6574 | 6.18 µs | 64.4 ms | 0 | 197 | 196 | 32 | 1 |
| 90.0 min | 9.0 min | 43.6 MB | 22.4 MB | 6665 | 2.86 µs | 63.9 ms | 0 | 198 | 198 | 32 | 1 |
| 91.0 min | 9.1 min | 43.6 MB | 22.5 MB | 6715 | 3.55 µs | 64.0 ms | 0 | 200 | 199 | 32 | 1 |
| 92.0 min | 9.2 min | 43.7 MB | 22.9 MB | 6794 | 5.94 µs | 64.3 ms | 0 | 203 | 203 | 33 | 1 |
| 93.0 min | 9.3 min | 43.7 MB | 22.4 MB | 6880 | 3.57 µs | 64.8 ms | 0 | 204 | 204 | 33 | 1 |
| 94.0 min | 9.4 min | 43.7 MB | 22.5 MB | 6953 | 5.70 µs | 64.9 ms | 0 | 207 | 206 | 33 | 1 |
| 95.0 min | 9.5 min | 43.7 MB | 22.6 MB | 7013 | 5.14 µs | 65.0 ms | 0 | 210 | 210 | 34 | 1 |
| 96.0 min | 9.6 min | 43.7 MB | 22.5 MB | 7091 | 1.68 µs | – | 0 | 210 | 210 | 34 | 1 |
| 97.0 min | 9.7 min | 43.7 MB | 22.5 MB | 7178 | 5.72 µs | 64.7 ms | 0 | 214 | 213 | 34 | 1 |
| 98.0 min | 9.8 min | 43.7 MB | 22.6 MB | 7262 | 2.48 µs | 62.3 ms | 0 | 216 | 216 | 35 | 1 |
| 99.0 min | 9.9 min | 43.7 MB | 22.6 MB | 7310 | 4.06 µs | 64.5 ms | 0 | 217 | 217 | 35 | 1 |
| 100.0 min | 10.0 min | 43.7 MB | 22.7 MB | 7390 | 5.26 µs | 63.7 ms | 0 | 221 | 220 | 36 | 1 |
| 101.0 min | 10.1 min | 43.7 MB | 22.6 MB | 7486 | 2.17 µs | 65.5 ms | 0 | 222 | 222 | 36 | 1 |
| 102.0 min | 10.2 min | 43.7 MB | 22.7 MB | 7532 | 4.17 µs | 64.5 ms | 0 | 224 | 223 | 36 | 1 |
| 103.0 min | 10.3 min | 43.7 MB | 22.7 MB | 7607 | 5.71 µs | 64.3 ms | 0 | 228 | 227 | 37 | 1 |
| 104.0 min | 10.4 min | 43.7 MB | 22.6 MB | 7683 | 2.38 µs | 62.3 ms | 0 | 228 | 228 | 37 | 1 |
| 105.0 min | 10.5 min | 43.8 MB | 22.7 MB | 7752 | 5.31 µs | 64.3 ms | 0 | 231 | 230 | 37 | 1 |
| 106.0 min | 10.6 min | 44.0 MB | 22.7 MB | 7819 | 4.36 µs | 63.7 ms | 0 | 234 | 234 | 38 | 1 |
| 107.0 min | 10.7 min | 43.9 MB | 22.9 MB | 7884 | 1.93 µs | – | 0 | 234 | 234 | 38 | 1 |
| 108.0 min | 10.8 min | 43.8 MB | 22.7 MB | 7960 | 4.27 µs | 63.8 ms | 0 | 238 | 238 | 39 | 1 |
| 109.0 min | 10.9 min | 43.8 MB | 22.8 MB | 8048 | 4.01 µs | 63.8 ms | 0 | 240 | 240 | 39 | 1 |
| 110.0 min | 11.0 min | 43.8 MB | 22.9 MB | 8097 | 5.05 µs | 65.8 ms | 0 | 241 | 241 | 39 | 1 |
| 111.0 min | 11.1 min | 43.8 MB | 22.8 MB | 8173 | 5.38 µs | 64.4 ms | 0 | 245 | 244 | 40 | 1 |
| 112.0 min | 11.2 min | 43.8 MB | 22.8 MB | 8267 | 2.84 µs | 62.4 ms | 0 | 246 | 246 | 40 | 1 |
| 113.0 min | 11.3 min | 43.8 MB | 22.8 MB | 8316 | 3.87 µs | 64.9 ms | 0 | 248 | 248 | 40 | 1 |
| 114.0 min | 11.4 min | 43.9 MB | 22.9 MB | 8394 | 4.62 µs | 63.8 ms | 0 | 252 | 251 | 41 | 1 |
| 115.0 min | 11.5 min | 43.8 MB | 22.8 MB | 8470 | 1.94 µs | – | 0 | 252 | 252 | 41 | 1 |
| 116.0 min | 11.6 min | 43.8 MB | 22.9 MB | 8545 | 4.69 µs | 63.9 ms | 0 | 255 | 254 | 41 | 1 |
| 117.0 min | 11.7 min | 43.9 MB | 23.0 MB | 8610 | 13.93 µs | 64.4 ms | 0 | 258 | 258 | 42 | 1 |
| 118.0 min | 11.8 min | 43.9 MB | 22.9 MB | 8682 | 1.95 µs | – | 0 | 258 | 258 | 42 | 1 |
| 119.0 min | 11.9 min | 44.0 MB | 23.0 MB | 8769 | 4.91 µs | 64.1 ms | 0 | 262 | 261 | 42 | 1 |
| 120.0 min | 12.0 min | 44.0 MB | 23.1 MB | 8856 | 1.24 µs | 64.6 ms | 0 | 264 | 264 | 43 | 1 |
| 121.0 min | 12.1 min | 44.0 MB | 23.0 MB | 8903 | 2.71 µs | 64.3 ms | 0 | 265 | 265 | 43 | 1 |
| 121.0 min | 12.1 min | 44.0 MB | 22.9 MB | 8903 | – | – | 0 | 265 | 265 | 43 | 1 |

</details>
