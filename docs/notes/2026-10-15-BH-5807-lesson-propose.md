# Propose fixes for repeat causes (BH-5807, wave 2 of #5794)

Doc: DB-COORDINATION-SPEC

## What changed

A new hub lane, `lesson-propose` (`bin/lesson-propose.sh`, daily at 06:41,
`cron/lanes/733-lesson-propose.cron`), reads the `block_findings` rows that
wave 1 (`bin/lesson-classify.sh`, BH-5806) writes. For a cause that repeats, it
drafts ONE change at the earliest stage that would have stopped it. Wave 3
(#5808) measures the effect. That is out of scope here.

## Why

the operator (2026-10-09): "after each Block we learn to see if we need to change
something in the plan or build process to avoid that block in the future".
Wave 1 names the cause of each BLOCK. This wave turns a repeat cause into a
proposed rule. A human or the lead review still decides: the lane opens PRs and
issues, and it never merges.

## One tick

1. Gate: `lane_gate_or_exit`, `lane_env_apply`, `LESSON_PROPOSE_ENABLED=0`
   stops before any request, `flock -n locks/lesson-propose.lock`.
2. `GET /api/lesson-propose/triggers` returns the triggers in the window. If it
   cannot be read, the lane writes one log line and stops.
3. A cluster of `other` findings with no category row: `POST
   /api/lesson-propose/categories` adds the row (`added_by=lesson-propose`, group
   `Lesson-propose`, a reason that names the count, the window and the verdict
   ids) and moves the window's matching `other` findings into it. The cluster is
   then a trigger. A retired slug is one log line and is skipped.
4. Each trigger goes through the dedup below, then one of three paths: deliver
   a stored draft, file a harness bug, or claim and make ONE model call.
5. One summary line in `logs/lesson-propose.log` for a tick with a trigger:
   `triggers= clusters= categories_added= proposed= filed= held= skipped= failed= calls=`.
   `proposed` counts PRs and `filed` counts issues, each only on a 201.

## Decision rules

- Trigger: an ACTIVE category other than `other` with at least
  `lesson_propose.min_blocks` DISTINCT BLOCK verdicts whose `verdict_at` is in
  the last `lesson_propose.since_days` days. Three findings of one verdict are
  one BLOCK.
- Cluster: the window's `other` findings grouped by the slug of
  `raw_category` (lowercase, every run of other characters one hyphen, trimmed,
  cut to 63). `Stale Lockfile`, `stale-lockfile` and `stale lockfile` are one
  slug. The slug `other` is never a cluster. The threshold is the same.
- Infra: `suggested_stage = 'harness-fix'`, or more than half the findings say
  `infra_false`. An infra category gets a harness bug issue built from the
  evidence, with no model call. It never gets a prompt lesson.
- Fingerprint: the first 16 hex of sha256 of `<category>|<sorted verdict ids>`.
  A new BLOCK in the window is new evidence and a new fingerprint. The
  window slides, so a verdict that ages out also changes the fingerprint. That
  is not new evidence: the row's `seen` list keeps the verdict ids of the
  window the lane last acted on, and the same evidence is the same fingerprint
  or no verdict id outside `seen`. An aged-out id never comes back, so `seen`
  keeps only the current window's ids, not every id ever seen.
- Detail size: `PUT /api/ledger` cuts a detail at 4000 chars, and a cut
  detail is no JSON. The lane checks the size (in bytes) before each write.
  Over 4000, `seen` is stored as `seen_max` (its largest id) with one log
  line, and then only a verdict id above `seen_max` is new evidence. Still
  over 4000, the lane writes nothing and logs the size. A detail that does not
  parse is logged; an `open` row with no lesson number goes to the marker
  search, which heals it.

## Dedup (before any spend)

The ledger row is `ledgers kind=lesson_proposal key=<category>`. Its detail is
`{fp, target, kind, path, number, url, at, attempts, blocks, seen, draft}`
(`seen_max` in place of `seen` when the window is too large).

| Row | Action |
|---|---|
| ledger unreadable | the whole tick stops; nothing is claimed or filed |
| `open` | the PR or issue is read live. Open: skip. Merged, or an issue closed as completed: `merged`. Otherwise `closed` |
| `merged`, `at` inside `lesson_propose.cooldown_days` | skip |
| `empty` or `closed` on the same evidence | skip (the evidence was already paid for) |
| `failed` on the same evidence, attempts at `lesson_propose.max_attempts` | skip |
| an open issue or PR of `HARNESS_REPO` with `[lesson:<category>]` in the title or `<!-- lesson-propose: <category> ` in the body | the row is set `open` with that number; skip. This also heals a row lost after a 201 |
| `undelivered` or `held` | the stored draft is delivered, with no new call |
| `drafting`, claimed less than 3600 s ago | the claim is refused; skip |

The open-issue and open-PR lists are read once a tick. If either cannot be
read, no trigger is drafted that tick.

## The model call

`bin/agent-call.sh`, stage `lesson-propose`, project `fleet`, role
`lesson.propose` (seeded as a copy of `rule.miner` rung 0), fingerprint
`lesson-propose:<fp>`, no tools. The findings and the diffs of up to 5 evidence
PRs (each cut to 3000 bytes) enter the prompt through `ui_wrap fetched-page`.
The answer is one JSON line:
`{"target":"plan-lesson|builder-rule|check|none","title":"...","text":"...","acceptance_tests":["..."],"why":"..."}`.

- rc 74 to 79 (refused before the vendor): `failed`, the attempt is not counted.
- Any other non-zero rc, an unparseable answer, an incomplete draft, or a
  `check` with no acceptance test: `failed`, attempts + 1.
- A blank answer or `target: none`: `empty` (billed and terminal until a
  verdict id outside `seen`, or above `seen_max`, arrives).

## Delivery

The draft (title cut to 120, text to 1200, at most 5 tests of 200) is written
to the ledger as `undelivered` BEFORE the first GitHub write. A failed delivery
keeps it, and the next tick delivers it with no new call.

- `plan-lesson`: a PR that inserts `- <text> (lesson-propose: <category>)` into
  §10 of `prompts/plan-contract.md`, directly above the last §10 bullet that
  starts `- docs/OPERATING`. With no such bullet, above the `## 11.` heading.
  With neither, the row is `failed` and no PR opens.
- `builder-rule`: a PR that appends `## Added <date> (lesson-propose: <category>)`
  and `- **D<n> <title>.** <text>` to `prompts/build-discipline.md`. `<n>` is 1 +
  the highest `**D<n>` in the file on main.
- Held: before either PR, if another `lesson_proposal` row is `open` on the
  same prompt file, the row is `held` and no PR opens. Two lesson PRs on one
  file is a guaranteed conflict. A later tick delivers it. Each other `open`
  row on the file is read live first, and a merged or closed one is recorded.
  Its category can be out of the trigger set, and then nothing else reads it.
  A stored draft that is held again uses no slot of the tick.
- `check` and the harness bug: one issue on `HARNESS_REPO`, label `ai-build`,
  title `Lesson: <title> [lesson:<category>]`. A `check` body has
  `#### Acceptance tests`.
- Every body names the category (id and name), the evidence PRs with their
  report URLs, the BLOCKs in the window,
  `Expected BLOCKs avoided: up to <blocks> in <since_days> days`, and the
  marker `<!-- lesson-propose: <category> fp=<fp> -->`. Em dashes are replaced
  by hyphens. A PR body also names `Prompt file:` and ends
  `Opened by bin/lesson-propose.sh. It never merges.`
- The PR is REST only: main's head sha, `POST git/refs` (a 422 is proven by
  reading the ref back), `GET contents` on the branch, `PUT contents`,
  `POST pulls`. Only a 201 with an `https://` `html_url` counts. The issue
  counts only on a 201 with a `number`. Then the row is `open`.

## Knobs (catalog/lanes.d/lesson-propose.json)

| Knob | Default | Range | Effect |
|---|---|---|---|
| `LESSON_PROPOSE_ENABLED` | 1 | 0..1 | 0 stops the lane before any request |
| `LESSON_PROPOSE_MAX_PER_TICK` | 3 | 1..20 | triggers worked a tick (a call, a stored-draft delivery or a harness bug), and new category rows a tick |
| `LESSON_PROPOSE_TIMEOUT_S` | 300 | 60..1200 | seconds one drafting call may run |

A junk value is one warn line in the log and the default. The test seam
`LESSON_PROPOSE_NOW` (ISO) pins the clock of the cooldown math.

## Settings rows (worker/jobs/schema.d/202610160504-bh-5807-lesson-propose.sql)

| Key | Default | Range |
|---|---|---|
| `lesson_propose.min_blocks` | 3 | 2..50 |
| `lesson_propose.since_days` | 14 | 1..90 |
| `lesson_propose.cooldown_days` | 14 | 1..90 |
| `lesson_propose.max_attempts` | 3 | 1..10 |

The worker reads them on every `GET /api/lesson-propose/triggers` and returns
them as `settings`. The code constants are only the fallbacks for an absent or
junk row.

## Indexes and retention (BH-6730)

No new table. The two new reads use the indexes of #5806:

- The triggers window read (`TRIGGERS_WINDOW_SQL`, `WHERE verdict_at >= ?1`)
  uses `idx_block_findings_at`.
- The cluster move read (`CLUSTER_MOVE_SQL`, `WHERE category = 'other' AND
  verdict_at >= ?1`) uses `idx_block_findings_cat`.

Tests X1 and X2 seed 20 000 findings over 60 days and run `EXPLAIN QUERY PLAN`
on the exported SQL text. The grouping is done in JS over the one windowed
read. No query runs per category or per row.

The ledger kind `lesson_proposal` holds at most one row per category, so it
does not grow. It is not in `retention.ledgers.archive_kinds`.
`block_findings` itself has no retention rule yet. It is the table of #5806, so
the rule goes in a follow-up ticket for the block-learning flow.

## Context budget

`catalog/context-budgets.d/5807-lesson-propose.json`: instructions, the
category row, the section 10 bullets and the D<n> titles, 20 findings of 600
characters, and 5 diffs of 3,000 bytes. Target 15,000 tokens, ceiling 40,000.

## Off switches

`LESSON_PROPOSE_ENABLED=0`, `flags/lane-off-lesson-propose`, or
`bin/harness-ctl.sh off lesson-propose`.

## Tests

`tests/lesson-propose.bh-5807-test.sh` drives the shipped lane against the real
worker routes over a node:sqlite file and a fake GitHub on PATH. It ends by
running `worker/jobs/test/lesson-propose.bh-5807.test.js`, the route suite.
