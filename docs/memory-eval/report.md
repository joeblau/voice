# Memory evaluation

Dataset `blau-memory-eval` v1: 115 questions over 80 sessions (89 exchanges), 110 documents and collection items, 59 facts and 24 entities; 259 chunks in the index. Commit `241364e+70`, 2026-10-07T20:44:19Z. Vectors: `qwen3-embedding-0.6b-256d-int8@97b0c614`.

## Retrieval

Over the 95 answerable questions (top 10).

| System | Recall@5 | Complete@5 | Hit@1 | MRR@10 | nDCG@10 | Recall@10 | Current first |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `hybrid` | 0.900 | 0.874 | 0.663 | 0.781 | 0.808 | 0.979 | 0.650 |
| `hybrid-no-entities` | 0.884 | 0.832 | 0.695 | 0.803 | 0.822 | 0.968 | 0.450 |
| `bm25-fallback` | 0.932 | 0.895 | 0.642 | 0.770 | 0.805 | 0.974 | 0.750 |
| `dense` | 0.805 | 0.726 | 0.579 | 0.717 | 0.743 | 0.926 | 0.550 |

## By question type (`hybrid`)

| Type | Questions | Recall@5 | Complete@5 | MRR@10 | Current first | Answer accuracy |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| single-fact | 30 | 1.000 | 1.000 | 0.772 | – | 93.3% (28/30) |
| temporal | 25 | 0.800 | 0.760 | 0.777 | – | 64.0% (16/25) |
| knowledge-update | 20 | 0.850 | 0.850 | 0.654 | 0.650 | 80.0% (16/20) |
| multi-hop | 20 | 0.925 | 0.850 | 0.925 | – | 70.0% (14/20) |
| abstention | 20 | – | – | – | – | 75.0% (15/20) |
| **all** | 115 | 0.900 | 0.874 | 0.781 | 0.650 | 77.4% (89/115) |

## Answers

Reader `apple-foundation-models`, judge `apple-foundation-models`, the top 8 memories from `hybrid`: 77.4% (89/115) correct, 0 failures, 217 s.

| Question | Type | First evidence | Response |
| --- | --- | ---: | --- |
| `sf-19` | single-fact | 1 | From September 1, 2026, you packed an allergy card in Japanese, eSIM QR codes printed, comfortable walking shoes, a small towel, cash for small shops, and noted |
| `sf-26` | single-fact | 1 | The Lawton Avenue place was listed at $3,900, but the renewed lease was $3,450. |
| `tr-08` | temporal | – | You mentioned The Overstory as one of the books listed on September 1, 2026. |
| `tr-11` | temporal | 1 | Yesterday, your run on Tuesday, June 1, 2026, was on a morning at Lake Merritt. The memory doesn't specify the details of the run. |
| `tr-14` | temporal | 1 | You first ran ten miles without knee pain on August 24, 2026, which was 109 days before the half marathon on November 8, 2026. |
| `tr-15` | temporal | 1 | You signed up on July 6, 2026, and today is October 7, 2026, so it was about 10 months ago. |
| `tr-17` | temporal | 1 | On October 5, 2026, you told me Keisha accepted the customer success lead offer, starting November 2, 2026. That was over a month ago, before the current week b |
| `tr-18` | temporal | 1 | On September 18, 2026, Jordan mentioned having two coffees after lunch on hard days. |
| `tr-19` | temporal | 6 | In mid-September, we planned a cooking class in Tokyo at Tsukiji, with a small market tour, and arranged for Biscuit to be watched by Sofia and a sitter who sta |
| `tr-21` | temporal | 1 | Two weeks ago, I mentioned that your neighbor Sofia offered to watch Biscuit while you were in Japan, suggesting a mix of her and an overnight sitter might work |
| `tr-22` | temporal | 4 | You asked about what to plant on the balcony for fall on September 29, 2026. |
| `ku-09` | knowledge-update | 3 | On September 19, Mei Hale is making a slideshow of old photos for Dad's 70th birthday dinner, and on September 22, we are booking a private room at Golden Lotus |
| `ku-14` | knowledge-update | 6 | Biscuit's ears now look completely clear, and the drops worked, but he still scratches them a lot. Moisture after baths can bring the yeast back. |
| `ku-15` | knowledge-update | 2 | [5] Tuesday, October 6, 2026 · conversation   The tempo run wasn't mentioned, but the easy four miles felt fine with no knee pain. |
| `ku-17` | knowledge-update | 1 | The most recent conversation on this topic was on September 23, 2026, where we discussed prioritizing the engineer based on growth bottlenecks. That was over tw |
| `mh-02` | multi-hop | 1 | On July 15, 2026, the vet said Biscuit has a yeast ear infection and gave drops twice a day for ten days. On October 2, 2026, the vet said his ears look complet |
| `mh-05` | multi-hop | 1 | On August 14, 2026, when Jordan asked about the seed deck, Blau said to lead with the cohort chart: restaurants open more than two years have had zero product c |
| `mh-09` | multi-hop | 2 | Biscuit is 32 pounds, which fits the 40-pound limit mentioned on September 16, 2026. The conversation from that date is the most recent. |
| `mh-10` | multi-hop | 1 | Tomás Ferreira owns the iOS app, as stated on June 1, 2026. He joined early, before the recent changes about the second iOS engineer. |
| `mh-17` | multi-hop | 1 | The candidate Rosa liked in the mock onboarding did not take the job, as Keisha accepted the customer success lead offer on November 2, 2026. The mock onboardin |
| `mh-20` | multi-hop | 1 | Linda Hale ran Hale's Kitchen for 22 years before selling it in 2023, but Larderly was founded in March 2025 by Jordan Hale and Priya Raman. There is no direct  |
| `ab-04` | abstention | – | I don't know. The memory from September 1, 2026, mentions a $750,000 pre-seed on an $8M post-money SAFE, but no valuation offered by Bayline Capital. |
| `ab-08` | abstention | – | Mei Hale is Alex's sister, a nurse in Portland with two kids. |
| `ab-13` | abstention | – | Biscuit is Sofia's dog. |
| `ab-14` | abstention | – | You ordered the ramen with yuzu shio broth at Menya Kotori on August 17, 2026. |
| `ab-19` | abstention | – | The most recent board meeting was on September 1, 2026, where Marcus Lee had observer rights but no direct comments from him. He previously suggested a short wr |

## Retrieval misses (`hybrid`)

No evidence in the top 5: `tr-04`, `tr-08`, `tr-09`, `tr-19`, `ku-01`, `ku-07`, `ku-14`.

## Regression gate

```
Regression gate: passed (30 checks)
```
