# Memory evaluation

Dataset `blau-memory-eval` v1: 115 questions over 80 sessions (89 exchanges), 110 documents and collection items, 59 facts and 24 entities; 265 chunks in the index. Commit `ad4298a`, 2026-10-10T01:47:48Z. Vectors: `qwen3-embedding-0.6b-256d-int8@97b0c614`.

## Retrieval

Over the 95 answerable questions (top 10).

| System | Recall@5 | Complete@5 | Hit@1 | MRR@10 | nDCG@10 | Recall@10 | Current first |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `hybrid` | 0.911 | 0.884 | 0.663 | 0.785 | 0.814 | 0.979 | 0.700 |
| `hybrid-no-entities` | 0.895 | 0.842 | 0.695 | 0.807 | 0.828 | 0.968 | 0.550 |
| `bm25-fallback` | 0.921 | 0.884 | 0.642 | 0.763 | 0.801 | 0.974 | 0.700 |
| `dense` | 0.832 | 0.768 | 0.558 | 0.715 | 0.748 | 0.926 | 0.600 |

## By question type (`hybrid`)

| Type | Questions | Recall@5 | Complete@5 | MRR@10 | Current first | Answer accuracy |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| single-fact | 30 | 1.000 | 1.000 | 0.789 | – | 90.0% (27/30) |
| temporal | 25 | 0.860 | 0.840 | 0.783 | – | 68.0% (17/25) |
| knowledge-update | 20 | 0.850 | 0.850 | 0.667 | 0.700 | 70.0% (14/20) |
| multi-hop | 20 | 0.900 | 0.800 | 0.900 | – | 75.0% (15/20) |
| abstention | 20 | – | – | – | – | 80.0% (16/20) |
| **all** | 115 | 0.911 | 0.884 | 0.785 | 0.700 | 77.4% (89/115) |

## Answers

Reader `apple-foundation-models`, judge `apple-foundation-models`, the top 8 memories from `hybrid`: 77.4% (89/115) correct, 0 failures, 129 s.

| Question | Type | First evidence | Response |
| --- | --- | ---: | --- |
| `sf-03` | single-fact | 1 | I don't know; the syncs from Toast and Square were mentioned on September 1, 2026. |
| `sf-19` | single-fact | 1 | From September 1, 2026, you packed an allergy card in Japanese, eSIM QR codes printed, comfortable walking shoes, a small towel, cash for small shops, and noted |
| `sf-26` | single-fact | 1 | The Lawton Avenue place is listed at $3,900, but the current rent is $3,450. |
| `tr-08` | temporal | – | You said you were reading The Overstory at the end of September. |
| `tr-09` | temporal | 9 | In October 2, 2026, we talked about his ears after Dr. Okafor said they were clear, with advice to dry them after baths. There is no memory from July. |
| `tr-11` | temporal | 1 | Yesterday's tempo run felt awful, Jordan, you couldn't hold 8:50. That was after a five-hour sleep on Saturday. |
| `tr-14` | temporal | 1 | You first ran ten miles without knee pain on August 24, 2026, which was 109 days before the half marathon on November 8, 2026. |
| `tr-15` | temporal | 1 | You signed up on July 6, 2026, and today is October 7, 2026, so it was about 10 months ago. |
| `tr-18` | temporal | 1 | On September 18, 2026, Jordan mentioned having two coffees after lunch on hard days. |
| `tr-19` | temporal | 3 | In September, we planned a cooking class in Tokyo at Tsukiji, with a small market tour and a request to swap shellfish dishes. Sofia offered to watch Biscuit, a |
| `tr-22` | temporal | 4 | You asked about what to plant on the balcony for fall on September 29, 2026. |
| `ku-09` | knowledge-update | 3 | A framed map of Lake Alpine with a family cabin trip in June, and a private dinner at Golden Lotus on December 12. |
| `ku-11` | knowledge-update | 2 | We are planning to raise the seed round in early 2027, as noted in a document from September 1, 2026. The current conversation on October 2, 2026, mentioned app |
| `ku-14` | knowledge-update | 6 | Biscuit's ears now look completely clear, and the drops worked, but he still scratches them a lot. Moisture after baths can bring the yeast back. |
| `ku-15` | knowledge-update | 2 | [5] Tuesday, October 6, 2026 · conversation   The tempo run wasn't mentioned, but the easy four miles felt fine with no knee pain. |
| `ku-16` | knowledge-update | 1 | No, we haven't hired a customer success lead yet. The offer was accepted on November 2, 2026, which is after today. |
| `ku-17` | knowledge-update | 1 | The most recent conversation on this topic was on September 23, 2026, where we discussed hiring the second iOS engineer based on growth bottlenecks. That was ov |
| `mh-02` | multi-hop | 1 | On July 15, 2026, the vet said Biscuit has a yeast ear infection and gave drops twice a day for ten days. On October 2, 2026, the vet said his ears look complet |
| `mh-05` | multi-hop | 1 | On August 14, 2026, when Jordan asked about the seed deck, Blau said to lead with the cohort chart: restaurants open more than two years have had zero product c |
| `mh-09` | multi-hop | 2 | Biscuit is 32 pounds, which fits the 40-pound limit the landlord on Lawton allows. The lease must be in writing, and the policy should be confirmed. |
| `mh-10` | multi-hop | 1 | Tomás Ferreira owns the iOS app, as stated on June 1, 2026. He joined early, before the recent changes about the second iOS engineer. |
| `mh-17` | multi-hop | 1 | The candidate Rosa liked in the mock onboarding did not take the job, as Keisha accepted the customer success lead offer starting November 2, 2026. |
| `ab-08` | abstention | – | Mei Hale is Alex's sister, a nurse in Portland with two kids. |
| `ab-13` | abstention | – | Sofia's dog is Biscuit. |
| `ab-19` | abstention | – | The last board meeting was on September 1, 2026. Marcus said the team should lead with the cohort chart, highlighting zero product churn and 128% net revenue re |
| `ab-20` | abstention | – | Alex drives a 2017 hatchback, as mentioned on June 1, 2026. This information is no longer true since September 15, 2026, when Alex started using BART. |

## Retrieval misses (`hybrid`)

No evidence in the top 5: `tr-04`, `tr-08`, `tr-09`, `ku-01`, `ku-07`, `ku-14`.

## Regression gate

```
Regression gate: passed (30 checks)
```

## Against the baseline

| Metric | Baseline | Now | Change |
| --- | ---: | ---: | ---: |
| hybrid Recall@5 | 0.900 | 0.911 | +0.011 |
| hybrid Complete@5 | 0.874 | 0.884 | +0.011 |
| hybrid MRR@10 | 0.781 | 0.785 | +0.004 |
| hybrid-no-entities Recall@5 | 0.884 | 0.895 | +0.011 |
| hybrid-no-entities Complete@5 | 0.832 | 0.842 | +0.011 |
| hybrid-no-entities MRR@10 | 0.803 | 0.807 | +0.004 |
| bm25-fallback Recall@5 | 0.932 | 0.921 | -0.011 |
| bm25-fallback Complete@5 | 0.895 | 0.884 | -0.011 |
| bm25-fallback MRR@10 | 0.770 | 0.763 | -0.006 |
| dense Recall@5 | 0.805 | 0.832 | +0.026 |
| dense Complete@5 | 0.726 | 0.768 | +0.042 |
| dense MRR@10 | 0.717 | 0.715 | -0.002 |
| answer accuracy (apple-foundation-models) | 0.774 | 0.774 | +0.000 |
|   single-fact | 0.933 | 0.900 | -0.033 |
|   temporal | 0.640 | 0.680 | +0.040 |
|   knowledge-update | 0.800 | 0.700 | -0.100 |
|   multi-hop | 0.700 | 0.750 | +0.050 |
|   abstention | 0.750 | 0.800 | +0.050 |
