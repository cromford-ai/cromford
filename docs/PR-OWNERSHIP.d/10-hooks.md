## 10. The hooks (BH-3929)

BH-3929 grows the sweep from "classify and act on ORPHANs" to "every open PR
gets a next move". It is split into five tickets. #3932 (this section) is the
seam the other four fill in. The superseded close and the health rollup are
built (#3936), and so is the age ladder (`po_stale`, #3935, below). Enroll and
the CI-only BLOCK step are still stubs that decline (rc 2).

**The order, per open PR, every class:**

1. `po_superseded` (`bin/lib/pr-owner/superseded.sh`). Runs before the class
   gate. rc 0 means it closed the PR, and nothing else runs for that PR, not
   even the ORPHAN arms of §3.
2. `po_enroll` (`bin/lib/pr-owner/enroll.sh`)
3. `po_stale` (`bin/lib/pr-owner/stale.sh`)
4. `po_health_add` (`bin/lib/pr-owner/health.sh`)
5. then the ORPHAN arms of §3, for an ORPHAN only

After each repo's summary line comes `po_health_flush <project> <slug>`. A repo
the sweep could not read never reaches it.

A missing hook file stops the run (`|| exit 1`) before anything leaves the box.

**What a hook reads.** The hooks read shell variables, never the env:

- per PR: `PO_PROJECT PO_SLUG PO_NUM PO_HEAD PO_AUTHOR PO_CLASS PO_KEY
  PO_CREATED PO_DRAFT PO_MERGEABLE PO_OWNED`. `PO_OWNED=1` for an OWNED PR. An
  empty field is `-`, so `PO_HEAD=-` means the head was not read.
  `PO_CLASS=UNREAD` (`PO_OWNED=0`) means the owner is unknown, not absent: a
  hook must never act on an UNREAD PR as if it were ownerless (BH-5124).
- per PR, the conductor's row: `PO_MC_STATE PO_MC_REASON PO_MC_HEAD
  PO_MC_SINCE` (`-` when there is none; `since` in epoch seconds; from
  `po_mc_read`'s detail file, the same source as the class), plus
  `PO_URL PO_BRANCH PO_GRACE_S`. An EXTERNAL PR with a non-terminal row gets
  `PO_OWNED=1`, unless the row's reason is `enroll-withdrawn`.
- per PR, for the superseded hook (#3936): `PO_EKEY` (the branch/title key,
  else the body's first line read with the same anchored title shape),
  `PO_MERGED_DUP` (the merged PR that carries `PO_EKEY`, never this PR),
  `PO_KEEPER` (for a key with 2+ open PRs, the one that stays: the
  highest-numbered one the conductor has READY/QUEUED/MERGING, else the
  highest-numbered harness one, else the highest-numbered one; never a PARKED
  PR) and `PO_MC_STATE` (this PR's conductor state).
- per run: `PO_TICK_NOW`, the one clock the health rollup reads, and `PO_MC_OK`
  (`1` when this repo's conductor rows were read).
- per run: `PO_STALE_REBASE_H PO_STALE_REPLAN_D PO_STALE_CLOSE_D
  PO_ENROLL_EXTERNAL PO_OWNERLESS_ALERT_H` (§8), and `PO_ENROLL_LIVE` (1 only
  on a fleet-wide run), `PO_DRY`, `PO_MAX_ACTIONS`.

A superseded close counts against `PR_OWNER_MAX_ACTIONS`, in the same count as
the ORPHAN arms; past the cap it is held as `#n:cap` and retried next tick.
Enrollments have their own per-repo counter, capped at the same
`PR_OWNER_MAX_ACTIONS` (`enroll-deferred` past it).

**Superseded close for every class** (#3936). `po_superseded` closes a PR when
the first of these matches, whatever its class:

1. its key merged in another PR AFTER this PR was opened, and no build job
   for the key is live (ledger or queue). An ORPHAN keyed by its branch or
   title is left to the close-duplicate arm of §3, which does the same close.
   This is the only rule that closes a PARKED PR.
2. its ticket is done or rejected (`ph_ticket_status`: on an Issues board the
   key's digits are the issue number, `completed` is done and `not_planned` is
   rejected; on a product board `done` is done and `closed` is rejected). An
   unreadable board, or a status it cannot name, stops here: nothing is closed
   for that PR this tick, not even by rule 3. On a product board the fleet
   sets `done` when the PR opens, before it merges, so there rule 2 skips an
   OWNED PR and any PR with a conductor row and goes on to rule 3.
3. another open PR for the same key is the keeper (`PO_KEEPER`), unless the
   blocked resolver owns this one (conductor row `BLOCKED_HUMAN` or
   `RED_TWICE`): its rebuild rung closes that PR after its own settle window.
   It never closes a PR that another open PR is stacked on (that PR's base is
   this PR's head branch): the close would strand it on a branch that never
   merges, so both stay open and the summary holds it as `#n:stacked`
   (BH-6814).

Rules 2 and 3 need the conductor's rows (`PO_MC_OK=1`): the product-board
skip, the keeper choice and the resolver guard all read them, so with the rows
unread nothing is closed by either rule that tick. An UNREAD PR is closed by
neither.

Before any close, `to_merge_hold` (`bin/lib/ticket-ownership.sh`) is asked: a
HOLD on the PR or its ticket, or a hold it cannot read, holds the PR
(`#n:hold`). `to_merge_hold` exempts a lead's PR (`lead_pr_authors`) from the
ticket hold, because it answers for a merge. A close is not a merge, so on an
issues board the hook then reads the ticket itself (the key's digits are the
issue) with no lead exemption: a HOLD newer than its last RESUME, or a thread
it cannot read, holds a lead's PR too (BH-6814).

The key (`PO_EKEY`) is the branch/title key, else the body's first line, and
only when its prefix is one a harness-authored PR in this repo (open, or in the
merged list) already uses. A bot author that is not ours never gets one. So
`WRANGLER-3` out of a dependabot branch neither "already shipped" nor reads
issue #3 on an issues board.

Rule 1 applies to OWNED PRs too, but only to one that was open before its key
merged elsewhere. A ticket rebuilt after an earlier PR for the same key merged
(a reopened ticket keeps its key) opens its new PR after that merge, so rule 1
leaves it alone. The `parked` label does not protect a leftover, because rule 1
closes PARKED too.

It posts one comment (EXTERNAL: starting `@<author>`), then closes over REST
(`gh_rest_comment`, `gh_rest_close`). A failed comment means no close. A close
counts only when a fresh read says `closed`. `ledgers(kind=pr_superseded,
key=<slug>#<n>)` remembers the comment, so a retried close is not commented on
twice. It also remembers the close: a PR whose row is `closed` and that is open
again was reopened by a human, as the comment invites, and this hook never
closes it again. A ledger it cannot read holds the PR (`#n:ledger-unreadable`)
rather than risk closing a reopened one. `PR_OWNER_DRY_RUN=1` logs `DRY-RUN would: superseded close #n (<by>)`
and writes nothing. Closes join the repo's one alert (§4).

**Health** (#3936). `po_health_add` counts every open PR that was not closed
above: open, the age buckets (<1d, 1-3d, 3-7d, >7d against `PO_TICK_NOW`),
ownerless (`PO_OWNED` is not 1), approved not merged (`ph_review_covered`
with `APPROVE` on this head) and blocked on CI only (conductor READY, and the
standing block-gate BLOCK passes `ph_ci_only_body`). `po_health_flush` writes
one `ledgers(kind=pr_health, key=<project>)` row, dry run included, and the
daily digest prints one `PR health:` line per project from those rows. The
ownerless alert after `pr_owner.ownerless_alert_hours` is not built yet.

**Enroll** (`po_enroll`, `bin/lib/pr-owner/enroll.sh`). Eligible: an ORPHAN
nobody owns, an EXTERNAL nobody owns when `pr_owner.enroll_external=1`, and
the **re-check set**: a `READY` or `WAIT_CI` row whose reason is the hook's own
(`enrolled-by-owner-sweep`, `enroll-withdrawn`), or one stranded on a head that
is no longer the PR's for longer than `PR_OWNER_GRACE_MIN`, on an EXTERNAL PR
or a branch that is not `ticket/*` or `main-red-revert/*`. A re-checked row is
re-decided on the current head, so a READY row never stays on an old one. A
harness ticket branch is left to the conductor's own tick, and a row in any
other state (`BLOCKED_HUMAN`, `REBASING`, `NEEDS_HUMAN_VERDICT` …) is a hand-off
and never touched. A target equal to the row, state and head, writes nothing.
PARKED is never enrolled. The head, draft flag
and `mergeable_state` are read over REST, the approval with
`ph_review_covered … APPROVE`, CI with `mc_ci_state`.

- APPROVE on the head + CI green + `clean` + not a draft: `pr_attempt_put
  <repo> <num> enrolled <head>` FIRST, then `mc_transition … READY
  enrolled-by-owner-sweep`. A failed attempt PUT means no READY.
- anything else: `mc_transition … WAIT_CI enrolled-by-owner-sweep`, no attempt
  row, no spawn. A draft never goes READY.
- a verdict outage or a CI read that is `unavailable` writes nothing.

Both writes run under the conductor's per-PR lock, taken `flock -n`; a held
lock is `enroll-deferred … conductor-holds-lock`, retried next tick. Every
READY key of the tick goes to ONE detached keyed conductor run
(`MC_ONLY_PR=<keys> timeout 240 bin/merge-conductor.sh`, through
`lock_spawn_unheld`). In a keyed run the conductor fetches each key the open
list does not carry by number (`mc_enrolled_rows`, outside authors only while
`pr_owner.enroll_external=1`), and `pr_worker`, in any tick, accepts a PR when
the `enrolled` attempt row is on its current head (`mc_enrolled_pr`, a
pre-check in front of the unchanged harness pr probe that reads the row only
for a PR with no build record off the `ticket/*` and `main-red-revert/*`
branches): a harness-authored ORPHAN on a feature branch is in the
open list, so the ordinary unkeyed tick drives it. Without the row, or on a new
head, it is not evaluated.
An ORPHAN that was just enrolled is not also handed back to its box.

**Ownerless.** After the hooks, a PR with no owner that is an ORPHAN, or an
EXTERNAL under `pr_owner.enroll_external=1`, is ownerless. The lane tick
carries the run's counts: `hb_tick pr-owner-sweep "repos= open= owned=
external= enrolled= ownerless= superseded= stale_rungs="`. A repo whose count
stays above zero for `pr_owner.ownerless_alert_hours` gets ONE alert,
`lane-alert.sh --id pr-owner-ownerless:<slug>`, naming the PRs. The clock is the
settings row `streak.pr-owner-ownerless.<slug>` (`0`, `<since>` or
`<since>:fired`, `ph_streak`): stamped `:fired` only after the alert was sent,
and resolved with `--resolve --id` once the repo has no ownerless PR. A repo
GitHub could not be read for neither advances nor resets it.

**What arrives, and with which ticket:**

- **The age ladder** (#3935, `bin/lib/pr-owner/stale.sh`). It ages an OWNED or
  EXTERNAL PR with a known head and a conductor row that is not
  READY/QUEUED/MERGING or terminal; no row means the PR is not ours to age.
  The clock is the newest of the head commit, the newest verdict (D1
  `verdicts` and the job's verdict artifact) and the PR's `created_at`; a side
  that cannot be read is no rung that tick. The highest rung that is due and
  switched on is the one taken (0 turns a rung off), once per head through a
  D1 `pr_attempts` row `stale-<rung>` written before the side effect:
  - `pr_stale.rebase_hours`: `mc_rebase`, the conductor's own merge of main
    (never `br_mechanical`). rc 3 (held, lease lost) forgets the row so the next
    tick asks again. Its push is not movement: rung 1 writes a `stale-carry`
    row (`<head> <clock>`) on the head it pushed (rc 0/5) or, on the pool path
    (rc 6), on the head it read. A head with a carry, or a merge commit whose
    first parent has one, keeps the carried clock (only a newer D1 verdict
    restarts it) and takes no second rebase, so rungs 2 and 3 still fire.
  - `pr_stale.replan_days`: the conductor row parks `BLOCKED_HUMAN stale-replan:
    no head or verdict change for <d>d`, which `mc_handoff_owns` and
    `mc_resolver_owns` (`bin/lib/mc/classify.sh`) hand to
    `bin/blocked-resolver.sh`. Its rung, `br_opt_stale_rung`
    (`bin/lib/br/opt/stale.sh`), writes a `KIND: stale-replan` build note and
    enqueues ONE fresh build of the ticket, under the CI park's
    `BR_CI_REPLAN_MAX` (the floor counts both note kinds). Once the re-plan's PR
    exists, the stale PR is closed as superseded, unless its head moved. A
    park the resolver already owns (CI_PARKED, red CI), a PR with no key, or a
    ticket carrying a `KIND: ci-replan` note is skipped.
  - `pr_stale.close_days`: one comment ("Closing this. Nothing has moved on it
    for N days: no new commits and no new review. The ticket goes back to todo
    so it gets picked up fresh.", `@author` first on an EXTERNAL PR, the last
    sentence dropped without a key), the PR closed (counted only on a re-read
    that says closed), then `ph_ticket_to_todo`: a product-board ticket is
    moved to `todo` (counted only when the answer says todo), an issues-board
    issue is left open and labelled, and both clear the ticket's `blocked` row.
    Never on a `hold`/`parked` label, a held PR, a held issues-board ticket, or
    a hold read that failed. A refused move is one `lane-alert.sh
    pr-owner-sweep/stale` line; the PR stays closed.
  Drafts get the close rung only. Every rung and every skip is one
  `STALE_RUNG <rung>|skip|held …` line in `logs/pr-owner-sweep.log`. The hook
  makes at most `PR_OWNER_MAX_ACTIONS` writes per repo per run, its own count,
  and a dry run (`PR_OWNER_DRY_RUN=1`) logs `DRY-RUN would:` and writes no row.
- **CI-only BLOCK** (#3934). `bin/merge-conductor.sh` calls `mc_block_ci_step`
  (`bin/lib/mc/block-ci.sh`) right after a block-gate refusal, with the
  block's id and an empty body. Its answer is ignored, and the refusal stands.
  The future step decides with `ph_ci_only_body` (`bin/lib/pr-health.sh`): rc 0
  only when every BLOCK finding says CI did not run, names CI or a workflow,
  and names no file. Any BLOCK in a shape it does not check (numbered or bold
  `[BLOCK]`, a second BLOCK paragraph, prose BLOCK beside `- [BLOCK]` lines) is
  rc 1. Today the hook declines.

**Design decisions** (the parent plan's, as far as this slice carries them):

- Hook state lives in D1 rows only (`settings`, `pr_attempts`, `ledgers`),
  never a new file under `state/` or `flags/`.
- Knob precedence is settings row > env > default, read once per run.
- EXTERNAL is enrolled behind a knob, never by default in code.
- The superseded close applies to every class.
- `ph_review_covered <slug> <num> <sha> [word]` answers "is this head already
  reviewed" from `job_verdict_covers` and `vd_standing` (0 yes, 2 no, 1
  outage). `po_enroll` reads it for the APPROVE on the head; #3934 will too.
  Review dedupe itself is #3930's.

### External authors: fix rounds and rebases (BH-4664)

On a project whose `external_pr.fix_rounds.<project>` row is above 0, the
blocked-resolver also takes an outsider's open, non-draft PR when a
CHANGES_REQUESTED stands on its head or its branch is dirty. It runs the PR
through the shared gates in `bin/lib/br/opt/external.sh` (push right, author
quiet) and hands it to a sibling module's hook. It never closes, rebuilds or
abandons an external PR. See
[docs/notes/2026-10-05-BH-4664-external-pr-fix-rounds.md](notes/2026-10-05-BH-4664-external-pr-fix-rounds.md).
