# Staff learning loop: outcomes, precision, proposals, demotion (BH-5563, wave 6 of #5556)

Doc: EVENTS, OPERATOR-SETUP

## What changed

A staff finding that was filed as a GitHub issue now gets an outcome when the
issue closes. The outcome feeds precision, demotion and two kinds of proposal.

- New hub lane `staff-outcomes` (`bin/staff-outcomes.sh`, registry
  `catalog/lanes.d/staff-outcomes.json`, cron
  `cron/lanes/730-staff-outcomes.cron`, hourly at :37 behind
  `hub-lease.sh check`). It makes no model call. The steps are in the script
  header.
- New worker routes in `worker/jobs/src/routes/staff-outcomes.js`:
  `POST /api/staff/outcomes`, `GET /api/staff/outcomes/pending`,
  `GET /api/staff/precision`, `POST /api/staff/suppressions/decide`. They
  register through the numbered fragment
  `worker/jobs/test/route-table.d/775-staff-outcomes.txt`. A ticket-keyed
  name (`bh-5563-...`) sorted after the zz-a/zz-b sentinels of
  `tests/route-keyed-merge.bh-5788-test.sh` M1, so it is numbered, like
  #6784's 773/774.
- New schema fragment `worker/jobs/schema.d/202610150612-bh-5563-staff-outcomes.sql`:
  tables `staff_outcomes` and `staff_promotions`, one pending row per agent
  and per suppression fingerprint (partial unique indexes), and two settings
  rows.
- `POST /api/staff/findings/claim` also matches an active suppression on the
  item's FAMILY: `familyFingerprint(agent, classSlug(class, else source.kind))`
  from `worker/jobs/src/lib/staff-family.js`. A pending row still never
  matches.
- `bin/staff.sh` sends `class` (`.class`, else `.source.kind`) in the claim
  body.
- New CLI `bin/staff-learn.sh`: the archie-learn replay gate on a staff
  agent's own skills tree.

## The outcome map

| Issue (GitHub REST) | outcome | verdict |
|---|---|---|
| open | none, nothing posted | — |
| closed, label `STAFF_NOISE_LABEL` (default `staff-noise`, exact after trim and lowercase) | `noise` | overrule |
| closed, `state_reason=completed`, no noise label | `merged` | agree |
| closed, any other `state_reason` or null | `rejected` | overrule |
| 404, any other non-2xx, or not an issue URL | none, retried next rotation | — |

The finding's status becomes the outcome word, so `/staff` counts it closed.
Its `staff_decisions` row gets `choice` approve (agree) or change (overrule)
and `counted=1`.

## The rules

- Precision: agent-core `precision()` over the agent's outcome verdicts,
  overall and per class slug. No outcome is `null`, never 0.
- Demotion is automatic: one overrule drops the agent one level (agent-core
  `nextLevel`, floor `automation`). It is a compare-and-set on the level the
  route read. A human change in between wins, and the answer says
  `demoted:false, reason:"raced"`. An overrule also voids a pending promotion.
- Promotion is a proposal only. When `nextLevel` with a hypothetical
  `delegate` after the agent's outcomes since its last level change would
  raise it (settings `staff.delegate_after` agreements in a row, never above
  the cap), one `staff_promotions` row is written with status `pending`. A
  human applies it with `POST /api/staff/agents/autonomy`. The next agree marks
  the row `applied` once the agent is at that level.
- Noise becomes a suppression proposal. When one family (agent + class slug)
  has K noise outcomes since its last proposal (settings
  `staff.noise_suppress_after`, default 3), and it has no pending row and no
  unexpired active row, one `staff_suppressions` row is written with status
  `pending` and no approver. The count runs from the outcome that made the
  last proposal (column `staff_outcomes.suppression_proposed`) or, if later,
  the last noise outcome that landed while the family had a pending or
  unexpired active row (column `staff_outcomes.suppression_window`). It does
  not use a clock. So a declined proposal needs K noise closures after the
  decline, and closures from the pending window do not count.
- Every effect of one outcome is one D1 batch. Each statement is conditioned
  on the outcome row still having `applied=0`, and the last statement sets it.
  A same-outcome replay is `200 existing:true` and writes nothing. A different
  outcome is `409 outcome_conflict`.
- A protected class slug (archie-autonomy `isProtectedSlug`) gets
  `never_delegable=1` on its first `staff_classes` row.

## How a human approves

- A suppression: `POST /api/staff/suppressions/decide {id, decision:
  approve|decline, approver}`. Approve makes it `active` until now +
  `staff.noise_suppress_days` (default 30). Decline makes it `revoked`. An
  approver that is `archie` or a staff agent name is `403 agent_approver`. No
  lane calls this route in this wave; a human calls it with the jobs client.
- A promotion: the existing `POST /api/staff/agents/autonomy`, which refuses
  an agent actor and a level above the cap.
- New proposals are one line each in `logs/staff-digest.log`:
  `proposal promotion id=<n> agent=<a> to=<level> fp=<fp12>` or
  `proposal suppression id=<n> agent=<a> class=<slug> fp=<fp12>`.

## Staff skill replays

`bin/staff-learn.sh <edit|correct|propose|adopt> <agent> <args...>` runs the
unchanged `bin/archie-learn.sh` with `ARCHIE_ORC_DIR` =
`state/staff/<agent>/skills-home` and `ARCHIE_SKILLS_SRC` =
`$HARNESS_CHECKOUT/prompts/staff/skills/<agent>`. A failing replay is rejected
(rc 1) and the live staff skill does not change. `correct facts`, `report` and
`unused` are Archie's (rc 2). No staff skill ships in this wave, and staff
ticks do not load skills yet.

## Apply order

1. The worker deploy applies the fragment through `bin/harness-sync.sh`
   before `wrangler deploy`.
2. `bin/harness-sync.sh` installs the scripts, the registry entry and the cron
   line.
3. Create the label `staff-noise` in `STAFF_FILE_REPO` once by hand. Without
   it, no closure is noise.
4. Check in prod: `SELECT COUNT(*) FROM staff_outcomes` succeeds and
   `GET /api/staff/precision` answers 200.

## Knobs

Lane knobs: `STAFF_OUTCOMES_ENABLED` (1), `STAFF_OUTCOMES_MAX` (60 GitHub reads
a run), `STAFF_NOISE_LABEL` (`staff-noise`). Settings rows:
`staff.noise_suppress_after` (3), `staff.noise_suppress_days` (30),
`staff.delegate_after` (5, from BH-5559), and the three retention windows
above. Off: `flags/staff-off-all` (both
staff lanes), `flags/staff-off-<agent>` (that agent's rows).

## Retention (BH-6730)

The staff tables this wave writes grow, and they are history: precision and noise counts read
them. The BH-6750 job (`POST /api/retention/run`, hourly from
`bin/d1-retention.sh`) has three rules for them. No archive store exists yet
(#6777), so the windows are long. Each window is a settings row (0 = off), and
the seeded `retention.dry_run=1` counts first and removes nothing.

| Rule | Removes | Window row (seed) |
|---|---|---|
| `staff_outcomes.age` | an applied outcome past the window AND older than its agent's last change | `retention.staff_outcomes.days` (180) |
| `staff_promotions.void` | a void proposal decided past the window | `retention.staff_promotions.void_days` (30) |
| `staff_promotions.applied` | an applied promotion decided past the window | `retention.staff_promotions.applied_days` (180) |
| `staff_findings.done` | a finished finding last updated past the window, with its outcome and decision rows | `retention.staff_findings.done_days` (365) |
| `staff_suppressions.revoked` | a revoked suppression created past the window | `retention.staff_suppressions.revoked_days` (180) |
| `staff_suppressions.expired` | an active suppression that expired past the window | `retention.staff_suppressions.expired_days` (180) |

Why these windows: 180 days keeps two quarters of precision and promotion
history. The promotion read uses only the outcomes since the agent's last
change, and the rule never removes one of those. A void proposal changed
nothing, so 30 days is enough. A pending promotion is never removed. The
removed outcomes are always the oldest ids of a family (resolved_at is the
insert time), so the noise count after the newest kept marker does not change.
When #6777 merges, these rules can archive first instead.

A finished finding (digested, refused, unsupported, failed, merged, rejected
or noise) stays 365 days because it is the claim dedup for its fingerprint:
while it exists, the same source item is never claimed again. Its outcome row
and its `staff:<fp>` decision row go with it, in the same D1 batch and before
it. Left behind, a re-filed finding would meet the old outcome (409
`ticket_mismatch` every hour) and the old decision (the new choice never
counted). This is also the bound on `staff_outcomes` for an agent whose level
never changes.

Pairs checked: an outcome or decision never outlives its finding (S5b). The
outcome rule can remove an outcome first and keep its finding; that finding is
no longer filed, so nothing reads the missing outcome. Promotions, suppressions
and outcomes do not reference each other's rows: a promotion stores a count, a
suppression is keyed by a fingerprint or a family, and the noise count reads
marker rows in `staff_outcomes`, not suppressions. A
claimed or filed finding is live work and never goes, and a pending
suppression (a noise proposal) never goes. The staff_findings and
staff_suppressions indexes and rows are in
`worker/jobs/schema.d/202610150613-bh-5563-staff-findings-retention.sql`. That
fragment also adds `idx_staff_findings_status_id`, so the resolver's hourly
work list reads only the filed rows.

## Not in this wave

The `/staff` screen's precision column still reads "not built: BH-5563"
(`worker/jobs/src/routes/staff-screen.js`). A follow-up wires
`GET /api/staff/precision` into it.
