# PR-pair canary (two open PRs, one shared cause)

**What it is:** `bin/main-red-pr-pair.sh` — the half of the main-red signal that
fires before main's own history says anything. The streak detector
(`bin/main-red-detector.sh`) needs two consecutive red runs on `main` itself,
which it only gets once somebody merges into a red main. The open PRs know
first: when two or more of them fail the **same job** with the **same first
error** inside one window, that is a repo-level fact, and it gets exactly ONE
critical alert naming the job and that error.

It shares nothing with the detector's machinery: its own lock, its own log, its
own alert id namespace. It shares exactly one thing, and only since BH-1451: it
can raise `flags/main-red-<owner>-<repo>` — the same freeze every merge lane
already reads — in the ONE case where the detector has looked and cannot call
it. Everywhere the detector HAS a verdict the freeze stays bound to the
detector's evidence, because two PRs failing alike can also be one shared flake.

**The suspected freeze (BH-1451).** On 2026-09-22 main went red during a merge
burst. Every run on main was still in flight, so the detector decided nothing
for 15+ minutes; this lane knew at 12:40Z and, writing no flag, could not stop a
merge. Five more PRs landed on the red main. So a firing pair now raises the
freeze, marked `reason=pr-pair-suspected` and `owner=main-red-pr-pair`, when —
and only when — `state/main-red/<owner>-<repo>.verdict` says `decision=none`.
It raises nothing when the verdict says `decision=red` (already frozen),
`decision=green` (the detector looked; this lane does not overrule it) or
`decision=held` (the detector looked and is waiting on a re-test of the failing
workflow — BH-1281 — and a freeze raised there is handed to the next detector
tick, which pages `--critical` and resets the mtime the lift reads), when the
verdict file is ABSENT (fail OPEN — a hub on an older detector, or the minutes
between a deploy and the next tick, must not freeze a repo on a pair alone),
when the flag is already there whoever owns it, or when `MAIN_RED_PAIR_FREEZE=0`.
It clears ONLY a flag whose body says this lane raised it, and only from a
COMPLETE look that found no pair: a detector-owned or hand-written freeze
outlives every tick of this lane. If main's own history later turns red, the
detector rewrites the body with its own `sha=` and pages `--critical` as a first
red call — it owns the flag from then on. Driven by
`HARNESS_TEST_SANDBOX=1 bash tests/main-red-pair-suspected.bh-1451-test.sh`.

**How an operator reaches it:** `cron/hub.cron` runs it every 10 minutes on the
hub, next to `bin/pipeline-health.sh`. Alerts go through `bin/lane-alert.sh`
(lane `main-red`, ids `main-red-prs:<owner>-<repo>:<hash>`), so they reach the
10-minute medic like every other lane alert.

**How to drive it:**

| what | how |
|---|---|
| the whole script, against a fake `gh` and a scratch `$HARNESS` | `bash tests/main-red-pr-pair-test.sh` |
| what this tick would alert on AND would record, sending nothing, recording nothing, taking no lock | `HARNESS=<tree> bin/main-red-pr-pair.sh --explain` |
| that `--explain` really is read-only (lock + ledger bytes) | `bash tests/main-red-pr-pair.bh-997-test.sh` |
| one repo only | `bin/main-red-pr-pair.sh owner/repo` |
| the streak half, unchanged by this | `bash tests/main-red-detector-test.sh` |

**Files it owns on a live box:**

- `logs/main-red-pr-pair.log` — one line per decision, including the ones that
  decided nothing (no token, unreadable PR list, cap bit, alert already open).
- `state/main-red/pairs/<owner>-<repo>/<hash>` — one marker per OPEN condition
  (`job=`, `first_error=`, `prs=`, `detected=`). Empty directory = no pair open.
- `state/main-red/pr-errors/<owner>-<repo>/<head>.tsv` — the cost ledger:
  `job \t first_error \t run_created_at` for one head sha. `-` in every column
  means that head's required runs finished and none failed. A head sha is
  immutable, so a row is terminal and is never asked about again — which is why
  it is written only from a COMPLETE answer: every required run finished, and the
  runs/jobs/log reads that describe the failure all succeeded. A run still in
  flight (even alongside one that already finished green) and any read that
  failed both write nothing and are asked again next tick. A head with NO
  required run at all (empty list, or only skipped workflows) is terminal `-`
  once its PR has been quiet for `MAIN_RED_PAIR_WINDOW_S`, so one such PR cannot
  block every resolve in the repo. A re-run of the same run id to green is NOT
  seen: the row stands, and the pair resolves when its PRs merge or rebase.
  While the PR cap bites, a marker resolves only once every PR it names has
  left the open list. Pruned by age only (`MAIN_RED_PAIR_LEDGER_DAYS`, default
  14) — and only by a real tick: `--explain` reads the rows that exist, computes
  the rest into a scratch dir that dies with the process, prints
  `WOULD RECORD <slug> <head> :: <row>` for each, and prunes nothing.
- `flags/main-red-<owner>-<repo>` — only when it raised it itself, under the
  narrow conditions above. Body: `reason=pr-pair-suspected` FIRST (so it
  survives the conductor's `head -c 200`), then `owner=main-red-pr-pair`,
  `job=`, `first_error=`, `prs=`, `since=`, `detected=`. No `sha=`: this lane
  judged no run on main. Published as a `pause_flags` row like the detector's,
  so every box materialises it. Read (never written) by this lane:
  `state/main-red/<owner>-<repo>.verdict`, the detector's per-tick decision.
- `locks/main-red-pr-pair.lock` — `flock -n` dedupe, never a queue: a held lock
  logs one line and the tick leaves. **Not taken by `--explain`** (BH-997): a dry
  run sends nothing, so it has nothing to dedupe against, and opening the file
  truncated the one a live tick was holding.

**Knobs:** `MAIN_RED_PAIR=0` or `flags/main-red-pr-pair-off` (kill switch),
`MAIN_RED_PAIR_REPOS` [every fleet.conf repo plus `$HARNESS_REPO`, BH-9284], `MAIN_RED_PAIR_MAX_PRS` [15],
`MAIN_RED_PAIR_WINDOW_S` [3600], `MAIN_RED_PAIR_LEDGER_DAYS` [14],
`MAIN_RED_PAIR_FREEZE` [1] (0 = alert exactly as before and raise no freeze),
`MAIN_RED_ERR_RE`, `MAIN_RED_SKIP_RE`. Documented in the script header, in
`env-templates/lanes/355-main-red-burst-and-suspected-freeze.env.example` and in
`docs/TEST-DETERMINISM.md` §2b.

**What must never regress:** `--explain` is READ-ONLY — no lock, no `mkdir`, no
prune, no ledger row, no marker, no send. An operator's dry run runs next to the
live `*/10` tick without either silencing the other, and a `MAIN_RED_ERR_RE`
someone exported to test a matcher stays in that shell instead of landing a
terminal 14-day verdict the cron lane then trusts. Also: a read we could not make
must never RESOLVE an open pair, and must never be recorded as a verdict. An unreadable PR list, a missing
token, a head whose runs are still in progress and a jobs/log read that failed
all write nothing and leave existing markers exactly where they were — "we could
not look" is not "it is fixed". That holds for a PARTIAL look too: if the PR list
loads but any open head in it produced no verdict this tick (unreadable, or still
running), or the grouping step itself fails, the resolve sweep is skipped
entirely. Two PRs that rebase onto heads GitHub will not answer for would
otherwise take their own open pair down with them, and page a second time on the
same condition the moment the reads recover. The cap is the other half of the
same rule: when more PRs are open than
`MAIN_RED_PAIR_MAX_PRS`, the log says so, because a silent cap reads identically
to a repo with no red PRs.
