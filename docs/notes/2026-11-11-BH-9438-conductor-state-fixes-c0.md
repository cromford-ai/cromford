# BH-9438 slice C0: merge conductor state fixes, items 1, 4 and 5

Doc: MERGE-CONDUCTOR

BH-9438 lists 8 conductor state defects. The ticket says to slice by item
number and to build items 1, 4 and 5 first. This slice (C0) builds items 1
and 4. Item 5 is already on main. Items 2, 3, 6, 7 and 8 are left for later
slices (C1+).

## Item 1: no paid re-review before the first verdict can bind

Cause in code. `mc_classify` (`bin/lib/mc/classify.sh`) answered
`HEAD_MOVED no verdict bound to head <h8> — fresh detached review` for every
head with no APPROVE. That included the conductor's first sight of a PR before
the builder's own verdict bound to it (reviewed `-`). The HEAD_MOVED arm called
`headbound_review moved`, which bought a paid detached re-review. The only
guard, `mc_job_running`, covers a job row that is still `running`. It does not
cover the gap after the job row settles and before the verdict binds.

Fix.

- `bin/merge-conductor.d/bh-9438-noverdict-grace.sh`: `mc_nvg_in_grace`. A
  head is in grace when the verdict is not APPROVE or BLOCK, the reviewed sha is
  empty or `-`, and the conductor first saw the head less than
  `MC_NOVERDICT_GRACE_S` seconds ago. The first-seen epoch is the attempt line
  `nvseen <key> <head> <epoch>`, written once.
- `pr_worker` sets the named variable `MC_NV_GRACE`.
- `mc_classify` keeps the state HEAD_MOVED with its own reason:
  `no verdict yet on head <h8> — first-verdict grace, <n>s left; no review bought`.
  With `MC_NV_GRACE` unset the old reason is byte-identical.
- `headbound_review` (moved mode only) returns after the free consumes
  (autopilot verdict, lead block, bound verdict) and before any tick budget,
  daily-cap unit or spawn. It logs `NV_GRACE <key> <h8>` once per (PR, head).
- Knob `MC_NOVERDICT_GRACE_S`: default 900 s, max 1500 s (below the 1800 s
  HEAD_MOVED stuck TTL), 0 = off. Row `lane.merge-conductor.mc_noverdict_grace_s`.

A real drift (reviewed is another sha) and a cleared verdict on a reviewed head
are not in grace. They buy the review as before.

## Item 4: re-read the cause of an old-label queue-ejected-twice park

Cause in code. Before f19be3261 (BH-9229, 2026-11-08) `ec_classify` read only
a `## Reason` heading. Current Mergify comments use `**Reason**` and a payload
JSON, so `ec_cause` answered `unknown\tno Mergify dequeue reason`
(`bin/lib/mc-eject-cause.sh`). The settle arm parked those PRs
`queue-ejected-twice: … unknown (no Mergify dequeue reason) …`. The parked-row
pass in `tick_project` visits every OPEN park each tick but never read the
cause again.

Fix.

- `bin/merge-conductor.d/bh-9438-eject-reread.sh`: `mc_ejr_reread`, called
  first for each OPEN BLOCKED_HUMAN `queue-ejected-twice` row in the parked-row
  pass. It reads the cause once per (PR, head) when the record line or the row
  reason carries the old label. The `ejreread` mark is written before the read.
- `conflict`: writes the BH-1677 `ejectconflict` mark, re-reasons the row
  `queue-ejected: conflict (…) — re-read (BH-9438); a rebase, not a fix round`
  and releases the hand-off. The next classification sends it to the rebase.
- Any other real cause: re-labels the park
  `queue-ejected-twice: <cause> (<detail>) on <h8> — re-read (BH-9438)`. The
  caller then runs `mc_bv_solo` / `mc_eject_fix_now` as before.
- Still `unknown`: the park keeps its label. When the answer is still `no
  Mergify dequeue reason`, the `ejreread` mark is swapped for
  `ejreread-none-r<EC_CLASSIFY_REV> <key> <head>`. That head is spent for this
  classifier revision only. A later change that maps a new payload code bumps
  `EC_CLASSIFY_REV` in `bin/lib/mc-eject-cause.sh`, and each such head is read
  once more.
- An unreadable comments list clears the mark. The third failure keeps it.
- Knobs `MC_EJECT_REREAD` (default 1) and `MC_EJECT_REREAD_PER_TICK`
  (default 10 reads per project per tick).

Current-format conflicts. `ec_classify` now maps the payload code
`CONFLICT_WITH_BASE_BRANCH` to `conflict` (detail: the code). Current Mergify
comments carry `**Reason**` and no `## Reason` heading, so before this a
conflict read `unknown` on the re-read. The fixture is the real #8713 comment
(`tests/fixtures/bh-9438/pr8713-conflict-comment.json`). Other payload codes
(for example `PR_MANUALLY_DEQUEUED`) still read `unknown`. The settle arm's
BH-1677 `ejectconflict` mark at ejection time still reads only the `## Reason`
text (`mc_dequeue_conflict`); this slice does not change it.

## Item 5: restamp loop (already on main)

b0cf3f0d1 (BH-9243, merged 2026-11-08T10:56Z) fixed it. `mc_pq_restamp_rebase`
(`bin/merge-conductor.d/bh-9243-restamp-rebase.sh`) spawns the restamp rebase
in the tick that finds the stale stamp. It holds the row READY with a
`prequeue-restamp` ready-why when it cannot spawn. It never writes NEEDS_REBASE
for a stamp-only rebase. `tests/mc-dequeued-restamp.bh-9243-test.sh` S1-S8 and
B1 are the acceptance test. This slice adds no code for item 5. Not verified
here: the hub `logs/merge-conductor.log` after 2026-11-08T10:56Z.

## Tests

- `tests/mc-noverdict-grace.bh-9438-test.sh`: G1-G10, R1-R4, W1 (a whole
  conductor tick), D1.
- `tests/mc-eject-reread.bh-9438-test.sh`: X1-X15, T1, T2 and T3 (whole
  conductor ticks on a park made before the fragment existed). X11 and T2 use
  the real #9189 Mergify comments (`tests/fixtures/bh-9229/`). X14, X15 and T3
  use the real current-format #8713 conflict comment (`tests/fixtures/bh-9438/`).

No test calls GitHub. Both suites use the stub `gh` of the BH-6161 rig.
