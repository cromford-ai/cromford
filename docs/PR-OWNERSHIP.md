# Every open PR has an owner state

**The rule, in one line:** an open pull request on a repo this fleet works is
either **OWNED**, **EXTERNAL**, **PARKED with an expiry**, or **CLOSED**. There
is no fifth option, and "it has just been sitting there since June" is not one
of the four.

Enforced by `bin/pr-owner-sweep.sh`. Tested by `tests/pr-owner-sweep-test.sh`;
the hook seams of §10 by `tests/pr-health-lib.bh-3929-test.sh`; the superseded close
by `tests/pr-superseded.bh-3929-test.sh`, the health rollup by
`tests/daily-digest-pr-health.bh-3929-test.sh`, and enroll, the ownerless clock
and the keyed conductor run by `tests/pr-owner-enroll.bh-3929-test.sh`.

---

## 1. Why this exists

On 2026-09-15, with the fleet running four businesses:

| PR | opened | state |
|---|---|---|
| `example-org/project-7` #323, #324, #325, #326, #327 | June 2026 | open, harness-authored |
| `example-org/project-7` #359 | August 2026 | open, harness-authored |
| `example-org/project-1` #630 | — | open, head **DIRTY** since 2026-08-30 |

Not one of them had a ledger row, a merge-conductor state, a park or a close.
Nobody rebased them, nobody closed them, nobody reported them. No log line in
this harness had ever named them.

`bin/orphan-reconcile.sh` (#356) closed the matching hole on the TICKET side —
"is every open `ai-build` issue actually being worked" — and it is the reason
this hole was load-bearing rather than merely untidy. The reconciler's owner
rule says **an open PR owns its ticket** (owner class (b)): whatever state that
PR is in, red CI or clean green, it is the conductor's job and not a reason to
build the ticket twice. That is exactly right while the conductor is working the
PR. It is exactly wrong the moment the PR has been abandoned — then the
abandoned PR is not merely unhandled, it is actively holding its ticket hostage,
and the ticket looks owned to every lane that asks.

So the two scripts are halves of one rule:

```
orphan-reconcile.sh   every open TICKET has exactly one owner
pr-owner-sweep.sh     every open PR     has exactly one owner state
```

They share their doctrine deliberately: compute the answer from scratch every
tick, trust no event, fail closed when the inputs cannot be read, and give the
event path a grace window so the backstop never races the lane it backs up.

## 2. The four classes

Decided in this order, first match wins.
UNREAD (BH-5124) is a fifth outcome that takes ORPHAN's place when the
conductor's rows cannot be read; it is never acted on.

### EXTERNAL — checked first, and touched only to close a superseded PR
The author is not in the harness author set (`bin/lib/gh-pr-list.sh`,
`HARNESS_PR_AUTHORS` — a PR opened on the GitHub App token is authored by
`app/cromford` and is just as much ours as a PAT-authored one). An external
PR belongs to `bin/review-prs.sh`, which reviews it and posts findings.

This lane **records it and stops**: no comment, no label, and no close, with
one exception. A superseded EXTERNAL PR (§10: its key already merged, its
ticket is done or rejected, or a newer PR for the same key is the one that
stays) is closed with one comment that starts `@<author>`. Its key must use a
ticket prefix this repo's own harness PRs use, and a bot author (dependabot,
renovate) never has one, so a branch like `vitest-4.1.2` or `fix/utf-8-encoding`
is never read as a ticket. At most it also enrolls it into the conductor
(below). It is first in the order rather than last because the cost of getting it
wrong is not symmetric — a sweep that can close a contractor's or a customer's
PR because our own ledger happens to have no row for it is a sweep that will
eventually do exactly that.

An EXTERNAL PR with no owner is **enrolled** into the merge conductor (§10),
behind the `pr_owner.enroll_external` knob (default `1`). At `0` it is recorded
and left alone, as above, and the log says `enroll-recorded-only`. Throwing the
switch also stops the merge of an EXTERNAL PR enrolled earlier, two ways:
the conductor reads the same knob (`mc_enroll_external_load`, once per run,
logged `pr_owner.enroll_external=<v> (<source>)`, a settings outage reads `0`)
and its keyed run no longer injects an outside author's key
(`mc_enrolled_rows`, logged `external enrollment off`); and the next sweep
withdraws that PR's READY row to `WAIT_CI enroll-withdrawn` with reviewed `-`,
so the backstop stops picking it (`enroll-withdrawn` in the log). Switching back
to `1` re-decides a withdrawn row. The knob is about OUTSIDE authors only: an
enrolled ORPHAN of ours is driven whatever it says. Enrolling never comments
on, labels or closes a PR: the conductor's own gates decide whether it merges. Once an EXTERNAL PR is enrolled (it has a merge-conductor row), the age
ladder (§10, #3935) ages it like ours, and its close comment names the author.

### OWNED
Either:
- a **ledger row** (`/api/jobs` or the build queue) for the PR's ticket key in
  `queued` / `claimed` / `running` — something is building it right now; or
- a **merge-conductor row** for `<owner/repo>#<number>` whose state is not
  terminal (`MERGED`, `CLOSED`, `ABANDONED`). The conductor is landing it, and a
  red CI, a rebase in flight and a provenance hold all read the same here — all
  three are the conductor's job. The log says `owner-source=d1|tsv` once per
  run (d1 when the `pr-state-rows` flag is up).

**Where the conductor rows come from** (`po_mc_read`,
`bin/lib/pr-owner/mc-read.sh`, BH-5124), first that answers:
1. the D1 `pr_state` view, when the conductor's own `pr-state-rows` flag is up
   (at most 5 pages of 1000; a failed or bounded read falls through);
2. `state/merge-conductor/pr-state.tsv`, but **only on the conductor's box**
   (`is_hub_box`, `bin/lib/hub-box.sh`) and only while its mtime is within
   `pr_owner.mc_max_age_s` (default 900 s, two conductor ticks).

Anything else is a failed read, and the repo's ownerless PRs are UNREAD (below).
With the view configured (`owner-source=d1`) and neither source answering, the
repo is swept not at all (`conductor rows unreadable (D1 pr_state) — swept
nothing`, BH-3933): no state file, no hook, no write. With the view not
configured, a failed read leaves the repo's PRs UNREAD; on an UNREAD repo
`po_enroll` does not run and the ownerless clock neither advances nor resets.
A stale file's rows are not used even as OWNED evidence. The row file is read
**read-only**. The conductor owns it; nothing here writes to it.

### PARKED
A human said "later, and here is when":
- the `parked` label, or
- a `Parked: <reason> until YYYY-MM-DD` line in the PR body.

An **expired** expiry is not a park. Writing the date is the whole point: the
park ends, and the PR falls through to ORPHAN on the next tick. A `parked` label
with no date, or a `Parked:` line with no date, parks indefinitely — that is a
deliberate operator act and the sweep honours it, but it is worth less than a
date, because nothing will ever ask about it again.

### OWNED by GRACE
A PR that moved less than `PR_OWNER_GRACE_MIN` (default 30) minutes ago is
OWNED, full stop. A PR opened four minutes ago has no conductor row yet because
the conductor has not ticked yet, and "no row yet" is not the same fact as
"nobody owns this" — the conductor runs every 5 minutes, and the build that
opened the PR may still be closing its own ledger row. **This lane is the
backstop, not a competitor**, and the window is what stops it closing a PR out
from under a live lane. Same reasoning, same shape, as
`bin/orphan-reconcile.sh`'s owner class (e).

It also covers the conductor's CI kick. `mc_kick_ci` closes a PR and reopens it
one REST call later to fire a `pull_request` workflow that a base change does
not fire; in the seconds between, the row can read `CLOSED` while the PR is
open. The reopen moves the PR, so grace owns it — the same hazard
`bin/reconcile-prs.sh` handles with `mc_closed_settled`.

### UNREAD
Harness-authored, no ledger owner, no park, not fresh, **and the conductor's
rows could not be read** (above). "No owner" is not a fact the sweep has, so it
does not act: no close, no label, no comment, no hand-back. `dirty_since` is
still remembered. The sweep writes one line per repo per run,
`<repo>: conductor rows unusable — <why>; <n> PR(s) with no ledger owner counted conductor-unread, no orphan action this run`,
and no alert. Until the `pr-state-rows` flag is up, a sweep on any box but the
conductor's classifies these PRs UNREAD every run.

### ORPHAN
Harness-authored, no owner, no park, not fresh, and the conductor's rows were
read. The only class this lane acts on.

## 3. What happens to an ORPHAN

At most `PR_OWNER_MAX_ACTIONS` (default 5) writes per repo per run; the rest are
logged as `held=#N:cap` and picked up next run.

| arm | when | what it does |
|---|---|---|
| **close-duplicate** | another PR carrying the same ticket key is already MERGED | comment naming the PR that shipped the work, then close. The work is not lost — the comment says to reopen if something in the diff did not make it across. |
| **stale-conflict** | the head has been `CONFLICTING` for more than `PR_OWNER_STALE_DAYS` (default 14) | one comment, then the `stale-conflict` label. **The label is the memory**: a PR that already carries it is never commented on again. It is not closed — a conflicting branch may still be somebody's work in progress. |
| **handback** | the ticket is still live and nothing is building it | the key goes back to the box that owns the project, the same way `bin/blocked-resolver.sh`'s `br_enqueue_fresh` does it: flip the `ledgers(kind=commented)` row `blocked <project> <KEY>` to `cleared` (BH-2317; a cleared row outvotes any stamp left on the box), and that box's next triage tick re-claims the ticket. When the jobs DB refuses that write nothing is handed back: the PR is held `handback-failed` and the next sweep retries (BH-2673). A pool-routed project is held `pool-routed` and a repo with no fleet project `no-project` (BH-5124); neither is a failure, and neither spends an action. |

**A HELD TICKET IS NEVER REBUILT, RE-ENQUEUED OR REOPENED.** Since BH-408
(2026-09-18) `bin/blocked-resolver.sh`'s rebuild rung and
`bin/orphan-reconcile.sh`'s owner class (d) both run `bin/lib/hold.sh` FIRST: an
issue that is closed, that has lost its `ai-build` label, or whose newest
decisive human comment is a `HOLD` gets one
`[resolver] HOLD respected <ticket>` line, keeps its PR exactly as it was, and
parks at the `HELD` terminal without spending a rung. A later comment that lifts
the hold releases it on the next tick with its counters intact — nothing here
waits on a person to clear state by hand. Console alert 6726 is why: project-5
#414 was de-labelled and put on HOLD by the operator at 07:03Z and rebuilt three times
that morning anyway. This sweep's own **handback** arm is NOT gated yet (it
clears the `blocked-commented-*` stamps, a third re-offer path) — one call of
`hold_check` wires it, and that is the named follow-up. See
docs/verification-map/resolver-hold.md.

**A pool-routed project is not handed back from here.** Its re-offer is a queue
row with attempt counters behind it, which is `bin/blocked-resolver.sh`'s rung;
the sweep says so in its log rather than writing a second copy of that routing,
and the summary holds the PR as `#N:pool-routed`, never `handback-failed`. That
refusal writes nothing, so it does not count against `PR_OWNER_MAX_ACTIONS`.

### The ticket key of a PR, and why it is narrow
Letters 2-8, a dash, digits 1-6, at the **front** of the last segment of the
head branch (`ticket/TK-902` → `TK-902`) or of the title (`TK-902: …`,
`[TK-1617] …`), upper-cased.

This is byte-for-byte the shape `bin/blocked-resolver.sh`'s `br_key_shape` uses
(#358, merged 2026-09-15). Two lanes that both close PRs have to agree on which
ticket a PR *is*, or one of them closes the wrong one. That function is not
sourceable from a script today, so the shape is copied deliberately and said out
loud in both places — see the fold-in about lifting it into `bin/lib/`.

Anchoring matters as much as the character classes. A loose `[A-Z]+-[0-9]+`
anywhere in the text would read `UTF-8` out of `fix/utf-8-encoding` and then
close a PR because some other "UTF-8" merged; a key mid-title is usually a
reference to a different ticket ("supersedes TK-700"). **No key is a fine
answer**: it costs that PR the close-duplicate and hand-back arms and nothing
else — it is still recorded, and still labelled if its head is stale.

## 4. One alert per repo, and only when something happened

A repo where every PR has an owner produces **no alert**. That is the normal,
silent shape, and a sweep that pages on every quiet tick is a sweep nobody
reads.

When a run does act, it emits exactly ONE `bin/lane-alert.sh` line for the whole
repo, listing every PR it closed, every PR it newly labelled, and every key it
handed back — never one alert per PR. Already-labelled stale PRs are not in the
list, because nothing happened to them.

## 5. Fail closed, per repo

A `gh pr list` that fails, a ledger that cannot be read, a repo no token can
see: each of those means *we cannot name these PRs' owners*, which is a
different sentence from *these PRs have no owner*, and only one of them may
close a pull request. On any of them the sweep records nothing and acts on
nothing **for that repo**, logs why, and carries on with the others.

A repo that NO token can see is an ALERT, never a quiet skip
(`bin/lib/gh-repo-token.sh`): the hub's default PAT 404s on
`example-org/project-5` and `example-org/project-7`, and an empty PR list there reads
exactly like a repo with no open PRs. That is the 2026-09-12 project-5 shape —
six approved PRs invisible for days because a token could not see them and
nothing said so. The sweep resolves each repo through
`gh_repo_use_token`, which falls back to `GH_ADMIN_TOKEN` from
`env/github-admin.env`.

## 6. State

`state/pr-owners/<owner>_<repo>.json`, rewritten every run:

```json
{
  "repo": "example-org/project-5",
  "project": "project-5",
  "generated_at": "2026-09-15T16:20:03Z",
  "prs": {
    "907": {
      "number": 907, "state": "ORPHAN",
      "since": "2026-09-15T16:20:03Z",
      "reason": "head has been CONFLICTING for 40d (limit 14d)",
      "key": "TK-907", "author": "operator",
      "url": "https://github.com/example-org/project-5/pull/907",
      "dirty_since": 1754000000
    }
  }
}
```

- `since` means **the first tick this PR read this way**, not "now". It carries
  over while the state is unchanged, so "this has been ORPHAN for eleven days"
  is answerable from the file.
- `dirty_since` is remembered rather than recomputed. The first tick that sees a
  conflicting head with no record of one falls back to `updatedAt`, which is
  what makes `project-1` #630 (dirty since 2026-08-30) actionable on the
  first run instead of `PR_OWNER_STALE_DAYS` after it.
- The file is written even on a run that takes no action: it is the only durable
  record that these PRs were looked at at all.

### The D1 mirror, and which copy wins

The file is the ledger of record; `pr_owners` in the coordination DB is the warm
read-side that survives this box (`docs/DB-COORDINATION-SPEC.md`). Both halves
are in the per-repo loop, and both fail open:

- **After** the file is written (`mv -f` of the new state), `pr_owners_put
  <repo> <project> <state-file>` PUTs it — the body IS the file, with
  `complete:true` so D1 learns the full set this box owns. File first, row
  second, same as `bin/merge-sweep.sh`'s `sweep_record`. A dry run mirrors too:
  what `PR_OWNER_DRY_RUN=1` withholds is the GitHub writes, not the record.
- **Before** classification, `pr_owners_list <repo>` reads the rows back and
  overlays them onto the file — but a row only wins when
  `row.updated_at >= file.generated_at`. Those are two clocks in the normal
  case: `updated_at` is the worker's (`nowIso()`), `generated_at` is this box's,
  written when the sweep built the file. Same second-precision ISO format, so
  the string compare is a time compare, and the `>=` is biased toward the file —
  a box running ahead of the worker just makes the overlay a no-op, and the file
  is the record anyway. A file written after a PUT that failed therefore
  survives the stale row that PUT did not replace.
  An absent file is `{}`, its `generated_at` is `""`, and every row is `>= ""` —
  which is the back-fill a rebuilt box wants: `since` and `dirty_since` come
  home instead of restarting at now.
- The sweep never writes `updated_at`. The worker stamps it.
- Worker unreachable: one `pr-owners ledger unreachable … (degraded)` line in
  `logs/pr-owner-sweep.log` per run, the file is used alone, and the page is
  `bin/jobs-client.sh`'s existing once-a-day `harness-jobs unreachable` ALERTS
  line. There is no second alert. D1 with no rows for the repo is silent and
  normal.
- A `PR_OWNER_EXTRA_REPOS` repo has project `-` and reads and writes rows like
  any other.

Driven end to end in `tests/ledger-writethrough-test.sh`.

## 7. Running it

```bash
bin/pr-owner-sweep.sh                      # every repo in fleet.conf + PR_OWNER_EXTRA_REPOS
bin/pr-owner-sweep.sh --explain            # …and print the per-PR verdict table
bin/pr-owner-sweep.sh --repo example-org/project-7
bin/pr-owner-sweep.sh project-5 project-1
PR_OWNER_DRY_RUN=1 bin/pr-owner-sweep.sh --explain    # decide everything, write nothing
```

The repo list comes from `bin/fleet-conf.sh --projects`, never from a copy of
the fleet's project list (`tests/fleet-projects-not-hardcoded-test.sh`, and the
2026-09-10 incident behind it). `example-org/project-7` is in the sweep because it
is enrolled in `fleet.conf` as the `project-7` project.

**Callers.** The hub cron (`cron/lanes/412-pr-owner-sweep.cron`) runs it every
30 minutes over every `fleet.conf` repo, behind `bin/hub-lease.sh check`, so a
box that does not hold the hub lease runs nothing. `bin/orphan-reconcile.sh`
also rings it with `--repo` for its own repo at the end of each triage tick,
and an operator can run it by hand. A `--repo` run records only: it never
enrolls, never spawns the conductor and never moves the ownerless clock,
because the conductor and its rows live on the hub.

**The gate.** The sweep is a registered lane (`catalog/lanes.d/pr-owner-sweep.json`,
BH-3932). `flags/all-off`, `flags/lane-off-pr-owner-sweep`, the D1 pause row of
that name, and the older `pr-owner-sweep-off` switch all stop it, whichever
caller rang it.

The lock is **dedupe, never a queue** (CLAUDE.md): two callers reaching one repo
in the same minute means the second one does not run, not that it waits.

## 8. Config

Every threshold is a config value with a documented default — set any of them in
`env/global.env`.

| knob | default | what it does |
|---|---|---|
| `PR_OWNER_SWEEP` | `1` | `0` = the lane does nothing, silently |
| `flags/pr-owner-sweep-off` | absent | the same kill switch as a file |
| `PR_OWNER_DRY_RUN` | `0` | `1` = decide and log everything, write nothing to GitHub and clear no marker on any box |
| `PR_OWNER_STALE_DAYS` | `14` | how long a head may stay `CONFLICTING` before `stale-conflict` |
| `PR_OWNER_GRACE_MIN` | `30` | a PR that moved this recently is OWNED by the event path |
| `PR_OWNER_MAX_ACTIONS` | `5` | writes per repo per run |
| `PR_OWNER_PR_LIMIT` | `200` | `gh pr list --limit` for both the open and merged lists |
| `PR_OWNER_EXTRA_REPOS` | empty | space-separated repos that are ours before they are a project |

The hook knobs (§10) are read once per run through `ph_knob`
(`bin/lib/pr-health.sh`). **The D1 settings row wins, then the env, then the
default.** A row or env value that is not a whole number is ignored and named
in `logs/pr-owner-sweep.log`. A settings outage falls through to env/default.
`0` is a value, and it turns that rung off. The seeds are in
`worker/jobs/schema.sql`.

| settings row | env fallback | default | read by |
|---|---|---|---|
| `pr_stale.rebase_hours` | `PR_STALE_REBASE_HOURS` | `24` | `po_stale` (#3935) |
| `pr_stale.replan_days` | `PR_STALE_REPLAN_DAYS` | `5` | `po_stale` (#3935) |
| `pr_stale.close_days` | `PR_STALE_CLOSE_DAYS` | `10` | `po_stale` (#3935) |
| `pr_owner.enroll_external` | `PR_OWNER_ENROLL_EXTERNAL` | `1` | `po_enroll`, `mc_enrolled_rows` |
| `pr_owner.ownerless_alert_hours` | `PR_OWNER_OWNERLESS_ALERT_HOURS` | `24` | the sweep's ownerless clock (`ph_streak`) |
| `pr_owner.mc_max_age_s` | `PR_OWNER_MC_MAX_AGE_S` | `900` | `po_mc_read` (BH-5124); `0` = never trust the file. No seed row. |

## 9. What it never does

Merge. Push. Approve. Close an EXTERNAL PR that is not superseded (§10) or
not aged out by the age ladder (§10, #3935; it ages only a PR with a conductor
row). Write to `state/merge-conductor/`, except through the conductor's own
writers: `mc_transition` / `mc_rebase`, which the age ladder and the enroll hook call (enroll under the conductor's
per-PR lock), and one
row for a PR the superseded hook just closed, `mc_transition <slug>#<n> CLOSED
superseded:<by>`, when the conductor already has a row for it.
It is a release-management sweep, not a merger — the
iron guardrail stands (CLAUDE.md §1: merging happens only through the gated
tier-1 step, the hub's merge sweep, or a command from the console).

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
## 11. The done-ticket close guard (BH-6815)

Three closes say "this ticket's work already shipped": superseded rule 1
(`merged-#N`), superseded rule 2 (`ticket-done` / `ticket-rejected`) and the
ORPHAN arm `close-duplicate` (§3). The sweep closed
project-6 #551, #564 and #577 that way, 7 to 20 minutes after each opened. All
three were reopened and merged later. Each of those three closes now goes
through `po_done_close_guard` (`bin/lib/pr-owner/shipped.sh`) first. Rule 3
(older duplicate of an open keeper) does not: its ticket is not done.

**The checks, in order. The first match keeps the PR open:**

1. A label in `PR_OWNER_DONE_SKIP_LABELS` (default `hold merge-queue
   queue-solo fix-main-red`, case-insensitive): `label:<name>`. Or a
   conductor row in `READY`, `QUEUED` or `MERGING`: `armed:<STATE>`.
2. The PR's `updatedAt` is less than `PR_OWNER_DONE_RECENT_MIN` (default 120)
   minutes before the sweep's clock: `recent:<m>m`. An unreadable `updatedAt`
   is `recent:unreadable`. 0 turns off this check only.
3. The PR's change is not on the default branch: `unshipped:<path>`, or
   `shipped-unknown:<why>` when the guard cannot tell.

**"Shipped" means merging the PR changes nothing.** It does not mean "its
commits are on main", because a squash merge never puts a branch's commits on
main. `po_shipped` reads `GET pulls/<n>/files` (one page) and pins main with
`GET commits/HEAD`. For each entry it reads main's blob with `GET
contents/<path>?ref=<main>`:

- `added`, `modified`, `changed`, `copied`, `unchanged`: main's sha must equal
  the entry's sha.
- `removed`: main must answer 404.
- `renamed`: the sha at `filename` must match, and `previous_filename` must
  answer 404.

An empty list is shipped. Any path whose blob differs keeps the PR open, and
that includes a path the merged PR never touched (#577's
`src/lib/home/launch-welcome.ts`).

**Fail closed.** These all read `shipped-unknown` and keep the PR open:

- a read that is not rc 0, or a body that is not a list
- 100 entries (there could be more)
- more than `PR_OWNER_SHIPPED_MAX_FILES` (default 60) entries
- an entry with no sha, or a status the guard does not know
- a directory where a file is expected
- a main sha it cannot read

**What a skip does.** It writes nothing to GitHub and spends no action. It adds
`#<n>:<word>` to `held=` (`label`, `armed`, `recent`, `unshipped`,
`shipped-unknown`). It logs one line:
`<slug>#<n>: done-ticket close skipped (<by>) — <reason>`. The next tick asks
again. The guard only reads, so it runs under `PR_OWNER_DRY_RUN=1` too. A clear
guard leaves today's close and its comment text unchanged.

**The memo.** `state/pr-owners/<owner_repo>.shipped.tsv` holds `unshipped`
answers only, as `num head main verdict detail epoch` rows. A row is reused
only when both the head sha and the main sha match, so it never goes stale.
Each write keeps the newest 200 rows. With no `HARNESS`/`H` root, no memo is
written.

**The replay.** `bin/pr-owner-close-replay.sh [--days N] [--repo
<owner/repo>]...` is read-only. It finds the sweep's close comments of the last
N days (default 7), rebuilds the guard's inputs at each close time, and prints
one row per close with `would=skip|close|n/a|unreadable` and the reasons. Its
last line is `replay: days=N closes=C would_skip=S would_close=K n/a=A
unreadable=U`. Its header names the inputs it can only approximate. The
conductor state at a past time has no history, so the replay does not use it.

## 12. The duplicate-close guard (BH-6929)

Every close of a PR as a DUPLICATE runs `po_dup_guard`
(`bin/lib/pr-owner/dup-guard.sh`) first. The three duplicate close paths are
`po_superseded` rule 1 (the key merged in another PR), `po_superseded` rule 3
(an older duplicate of the keeper) and the sweep's own `close-duplicate` arm
(§3). Rule 2 (the ticket is done or rejected) is not a duplicate close.

The guard keeps the PR when any of these hold. The first match wins:

| tag | the PR is kept when |
|---|---|
| `slice` | its title says `slice` or `part N` |
| `blocked-by` | another open PR's body has a `Blocked-by:` line that names `#<n>` or `/pull/<n>` |
| `armed` | the merge conductor has it `READY`, `QUEUED` or `MERGING` |
| `approved` | a latest review (`latestReviews` in the open-PR list) is `APPROVED` |
| `reopened` | its issue events hold a `reopened` event |
| `not-a-duplicate` | a PR comment says "not a duplicate" |
| `stacked` | its head is an ancestor of the head of another open PR with the same key, or that head is an ancestor of its head |

`stacked` uses `git merge-base --is-ancestor` in `$PR_OWNER_REPO_ROOT/<project>`
(default `/root/repos`) when that checkout has both commits. Otherwise it uses
REST `compare/<this>...<other>`: `ahead`, `behind` and `identical` keep the PR,
`diverged` does not.

A kept PR gets one log line, `<slug>#<n>: duplicate close refused — <tag>:
<detail>`, and `held=#<n>:<tag>` in the repo summary. It spends none of
`PR_OWNER_MAX_ACTIONS`.

**Fail closed.** A read that fails or does not parse keeps the PR as
`guard-unread`. The same applies to an open-PR list with no `latestReviews`,
a full page of events or comments, and a key with more than 10 other open PRs.
The next sweep tries again.

`reopened` and `not-a-duplicate` are GitHub's own records. A reopen, or a
comment that says "not a duplicate", stops the duplicate close for that PR on
every later sweep.

**The close itself is unchanged.** The comment still says to reopen the PR if
it has something the other PR does not. When a run closes a PR as a
duplicate, the repo's one alert of the run (§4) goes out as critical
(`bin/lane-alert.sh --severity critical`, Telegram now, not the digest). It
names every PR closed as a duplicate. A dry run never makes it critical.
