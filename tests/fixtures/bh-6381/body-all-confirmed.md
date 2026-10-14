## Summary

Cut the review spend of the lead lane (fixture body, BH-6381 suite).

| check | result |
|---|---|
| repo suite, run by the harness | `HARNESS_EXIT: 0` |
| claim 1: L1 the cap fires on a perf PR with one INCONCLUSIVE row | CONFIRMED — validate.txt:12 (agent-recorded) — exit=0 |
| claim 2: L2 the replay reads BLOCK from a capped report | CONFIRMED — validate.txt:20 (agent-recorded) — exit=0 — inconclusive on the first run |
| claim 3: L3 a non-perf PR is not capped under the default | CONFIRMED — validate.txt:30 (agent-recorded) — exit=0 |
| settled tier | 1 — EVIDENCE: 0 refuted, 0 inconclusive of 3 acceptance claims |

Digest: `suite=0 tamper=clean claims=3/0/0`
