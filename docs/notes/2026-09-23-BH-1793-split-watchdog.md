# The split-family watchdog lane (BH-1793, built in BH-1808)

Doc: OPERATOR-SETUP

## What it is

`bin/split-watchdog.sh` is a hub cron lane (`*/10 * * * *`,
`cron/lanes/719-split-watchdog.cron`, registry
`catalog/lanes.d/split-watchdog.json`). It walks split ticket families (a parent
plus the children decomposition filed for it) and, per family, asks the
contract decider for at most one next step and hands that step to the contract
actor. It is bash and REST only. It makes no model call.

The lane never decides or carries out a step itself:

- `sw_next_step` (`bin/lib/split-watchdog.sh`) decides.
- `sw_act` (`bin/lib/split-watchdog-act.sh`) acts, and owns the
  `split_watchdog_actions` ledger.

**Until BH-1807 and BH-1809 land, both are the contract stubs.** The decider
prints nothing, so the lane walks its families, logs one summary line and does
nothing else.

## It is off until an operator names a project

`SPLIT_WATCHDOG_PROJECTS` defaults to empty. With it empty the lane makes no
board, GitHub or queue read at all and writes
`<ts> projects=0 families=0 acted=0 skipped=0 deferred=0`.

Per project it also honours `lane_project_held split-watchdog <p>`
(`bin/harness-ctl.sh off split-watchdog --project <p>`) and reads its knobs
through `lane_env_apply split-watchdog <p>`. The whole lane stops on
`flags/lane-off-split-watchdog`. A second tick while one is running exits at
once (`flock -n locks/split-watchdog.lock`).

## How it finds families

- **In-app boards** (`fleet.conf` board_prefix is a path): `GET
  <base><prefix>/boards`, then each board's `/tickets`, with the token from
  `bin/internal-token-for.sh` and the base from the project's `*_API_BASE`
  (else fleet.conf prod). A family is a ticket with a non-empty `children[]`
  whose status is not `done`. Land order comes from the newest
  `builds/[pool-]<p>-<parentKey>-*/RESULT` that starts `DECOMPOSED k1,k2`, else
  `children[]` order. A board read that is not 200 defers the whole project for
  the tick.
- **GitHub boards** (board_prefix `-`): families are found from their
  parents, not from a window over the issue list. A 1000-row window of issues
  and PRs is a few days on a busy repo, so the stalled families this lane is for
  fall out of it first, and one that straddles the cut arrives with its first
  children missing. Candidate parents are the ones a line-anchored `Part of #N`
  names in the open issue list (an open list that reaches the page cap defers
  the project, because it may be truncated) or in the newest 1000 issues of all
  states (for families whose children have all closed; older ones are
  `bin/decompose-parent-close.sh`'s job). The parent must read `open` through
  `gh_rest_issue_state`. A closed parent drops the family. A read that fails
  defers it, and is never read as open or closed. The children are read from
  the open parent's own timeline: every cross-referenced issue of this repo
  whose body carries `Part of #<parent>`. A body that only mentions `#N`
  (`see #500`, `Blocked-by: #500`) is not a child. Every child must carry
  `Order: i of n` with one `n`, and the orders must be exactly `1..n`. A family
  that fails that, or whose timeline could not be read whole, is deferred and
  logged `PARTIAL_FAMILY <p> <parent>`; it is never handed to the decider,
  because a child whose predecessors are missing would read as the first
  child. Keys are `<prefix>-<n>` from `prompts/<p>.md` (`preplan_key_prefix`);
  a project with no prefix is skipped.

At most `SPLIT_WATCHDOG_MAX_FAMILIES` open families per project per tick, in
ascending parent id. The rest count as `deferred`.

## What it hands the decider

One 14-column TSV line per child, in land order, in the column order
`bin/lib/split-watchdog.sh` documents. The rules:

- PR: from the newest build RESULT (`PR_CREATED <url>` / `PR_MERGED <url>`,
  field two), else a head-branch search for `ticket/<key lower>`, then one
  `pulls/<n>` read. A failed read is `unknown` in pr_state, merged_at,
  mergeable and head_sha, never `none`.
- lock_held: `flock -n locks/build-key-<p>-<KEY>.lock true` when the project
  builds on this box, `0` when it is pool-routed, else `unknown`.
- Queue: one `GET /api/queue?project&key&limit=1`. An outage is `unknown`,
  and an empty queue is `none`. This is `queue_row`'s rc contract, read
  directly because `queue_row` does not print `finished_at`.
- waiting_on_client: in-app `waitingOn=client` or
  `triageVerdict=needs_clarification`, or a child the list did not carry. On
  GitHub, an open child without `ai-build`, an open child with a `HOLD` comment
  from the owner, or an open child whose comments could not be read. "The
  owner" is the harness's human-authority rule (`bin/lib/block-gate.sh`): never
  a bot, and `OWNER`, `MEMBER` or `COLLABORATOR`; any other association but
  `NONE` is asked `collaborators/<login>/permission`, and admin, maintain or
  write counts. That is how the fleet owner reads on an org repo, where GitHub
  reports them as `CONTRIBUTOR`. A permission read that fails counts as a hold.
- deploy_serves_merge: always `unknown`, because fleet.conf names no version
  endpoint.

## The tick

`SPLIT_WATCHDOG_TICK_CAP` decisions (acted plus skipped) per tick across all
projects. A due family past the cap counts `deferred`. `flags/automerge-disabled`
is OBSERVE mode: each decision is logged as
`OBSERVE <p> <family> <step> <child> <reason>` and `sw_act` is not called. When
`sw_act` exits 1 the summary ends ` worker-unreachable`, and the family it
failed on and that project's remaining families count `deferred`. A decider line that is not three tab
fields is logged `BAD_DECISION` and counted skipped.

`SPLIT_WATCHDOG_FAMILY_DAY_CAP` and `SPLIT_WATCHDOG_STALL_K` are registered here
but read by `sw_act`, not by the lane.

## What it never does

It never merges, pushes, rebases, writes board status, posts a comment, or
calls a model. When nothing is due it writes one summary line and nothing else:
no ALERTS line and no worker write.

Suite: `tests/split-watchdog-lane.bh-1793-test.sh`.
