# Archie's research scout finishes its scoring and binds the cap per call (BH-4762)

Doc: LLM_CALL_SITES, OPERATOR-SETUP

## What happened on 2026-10-06

The first real scan ran on the hub. D1 `cost_rows` for stage
`archie-research` since 2026-10-05:

| run_id | rc | dur | in | out | cache_read | cache_write | cost_usd |
|---|---|---|---|---|---|---|---|
| `archie-research:wq:2026-10-06:a1` (web scan) | 0 | 60 s | 8 | 3,069 | 52,604 | 20,162 | 0.233229 |
| `archie-research:sb:f29db372ecdace9b:a1` (scoring, 18 finds) | 1 | 354 s | 2 | 7,046 | 0 | 211,506 | 2.29122 |

The scoring call was bounded at $0.50 (`AGENT_CALL_BUDGET_USD_ARCHIE_RESEARCH`
passed as `--max-budget-usd`) and billed $2.29. The vendor checks that flag
only between turns, and one turn was enough. The day cap check had passed
(0.23 + 0.50 is under 1.00). All 18 finds were settled `failed`, and nothing
ever offered a failed find again, so the day's research was lost.

Why one no-tools call wrote 211K tokens of cache is not known: the transcript
is not on the builder box. Nothing below depends on knowing.

## What changed

- **Scoring goes in chunks.** `ARCHIE_RESEARCH_SCORE_BATCH` (default 6, 1..25,
  a settable knob) finds per agent-call, each chunk claimed as its own
  `sb:<sha16>`. A chunk that billed and failed settles its own finds `failed`
  with the attempt counted and the find kept in `raw`, hands every later find
  back (`refund`, attempt restored, find kept in `raw`) and stops scoring for
  the run. The log line is `scoring: chunk <i>/<n> failed (agent-call rc=<rc>);
  its <k> finds retry next scan, <m> handed back`.
- **Failed finds come back.** Each scan first reads the items settled `failed`
  in the last 7 days that are still under `ARCHIE_RESEARCH_MAX_ATTEMPTS`
  (fewest attempts first) and offers them again, from their stored `raw`, or
  from title + url for a row written before this change (prod's 18 from
  10-06). A key that is also in today's search is claimed once. Log line:
  `retry: <n> failed finds re-offered`. The attempt cap still holds, so a
  poison find costs at most 3 tries.
- **The cap binds every call.** Each agent-call (the web scan and each scoring
  chunk) gets `--max-budget-usd = min(ARCHIE_RESEARCH_LLM_MAX_USD, cap minus
  today's spend)`, floored to the cent, and runs only when that is at least
  `ARCHIE_RESEARCH_RESERVE_USD`. The vendor can still overshoot by one turn,
  which is why chunks are small.
- **The cap is 3.00.** Script literal, registry default and the D1 seed row.
  `worker/jobs/schema.sql` seeds it with an upsert that moves ONLY an untouched
  seed (`actor = 'seed' AND value = '1.00'`): a row an operator set, or a seed
  already moved, is left alone, and a second apply changes nothing. It stays an
  `INSERT OR IGNORE` statement, which is what `tests/schema-additive.bh-1000-test.sh`
  allows.
- **Sources.** Two topics: new AI model releases and YouTube talks on automated
  SDLC. The default is seeded as settings row
  `lane.archie-research.archie_research_topics`. The scan prompt asks for
  `site:youtube.com` searches with title, channel, date and url, and the
  session cannot fetch, so every video is recorded "transcript not read": in
  the title (`(YouTube, <channel>, <date>)`), the scoring text, the item's
  note and the proposal's ticket. YouTube urls fold to one key
  (`youtu.be/<id>`, `/shorts/<id>`, `m.`/`www.` hosts and the `si`, `feature`,
  `pp` params). When the X half is off, the scan is also asked for
  `site:x.com` results.
- **Inward-facing scores.** A find that applies must name its `stage` (triage,
  plan, execute, review, merge, cost, model-routing), and may name `change`,
  `effect`, `cost` and, for a model release, the `model_routes` role to
  change. These land as lines in `proposal_summary`. An entry that applies
  with no valid stage is failed and retried. The lane never writes a model
  route.
- **The daily beat.** A run that made at least one proposal sends ONE triaged
  `fleet_alert` line (akey `archie-research:daily:<day>`):
  `Archie found <n> idea(s) worth a look today. Top: <title> (<score>/10,
  <stage>). They are on the Ideas screen as gate_pending.`, signed Archie. A
  per-day marker (`state/archie-research.daily-<day>`) is written only after
  the beat answered. A run with no proposal sends nothing. A run that proposes
  after a failed beat that day sends it then; a later run that day with no new
  proposal does not, which is accepted. The weekly digest is unchanged.
- **The X key alert** now says what to do: create a key at console.x.ai with
  its own monthly spend limit and put it in `/etc/harness/env/global.env` as
  `ARCHIE_XAI_API_KEY`. Still once a day.
- The run is under `timeout 1800` (was 900), and no scoring chunk starts with
  under 330 s of the run's 1700 left, so it stays clear of the 07:10Z digest
  on the same lock.

## How to read the proof

`tests/archie-research-scout.bh-4762-test.sh` drives the shipped lane against
the real routes over node:sqlite, with a stub agent-call. B1-B5 are the chunks
and the retry path, C1-C5 the ceiling and the seeds, P1-P4 the sources, S1-S4
the inward fields, D1-D4 the daily beat, K1-K2 the alert, T1 the deadline, and
M1-M3 mutate the shipped lane (no retry list, no chunking, no min with what is
left) and show B2, B1 and C1 go red. No live call was made. After a deploy, the
hub's `logs/archie-research.log` summary line shows `scored=` above 0 and
`spent=$x/$3.00`.
