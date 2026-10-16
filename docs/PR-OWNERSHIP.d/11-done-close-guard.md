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

