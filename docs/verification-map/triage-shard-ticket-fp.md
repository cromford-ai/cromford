# Triage-shard per-ticket dedup (the fingerprint that runs before the money)

**What it is:** a triage tick is a dispatcher — `bin/lib/rt/shards.sh` splits the
tick's scope by ticket key and buys one agent session per key. Until BH-1015 the
only brake in front of that spend was `bin/triage-gate.sh`'s tick-level
`state/<project>.queuefp`, and a tick-level brake is all-or-nothing: one
ticket's queue line gaining a word un-brakes the whole tick, and every OTHER key
in scope is re-bought having not moved at all. A shard that concludes "hold,
nothing to do" is a billed empty result, and it was re-offered on every RUN
tick. The 2026-09-17..19 runaway-spend audit measured it at project-4 2,073 shards
in three days, project-1 TK-265 153 sessions on one ticket, and cromford
$896/day.

So the unit of dedup moved to where the unit of spend already is. Before a key's
session is bought, the dispatcher takes a fingerprint of that ticket's world and
compares it with the one persisted at the last dispatch
(`state/triage-shards/<project>/<key>.fp`, `<fingerprint>\n<epoch>\n`). Same
value with a stamp younger than `TRIAGE_SHARD_FP_TTL_S` means no session and one
log line. The tick-level `queuefp` brake is untouched and stays as the backstop.

**What goes into the fingerprint**, and why each part earns its place:

- **The key's own scope lines.** A queue line is reduced to its MACHINE tokens —
  the ticket key, `PR #12` references, `project=`/`base=` pairs, a
  `[status/waitingOn]` bracket, ALL-CAPS status words — because a no-action
  session rewrites its prose and its `Re-checked <ts>` every tick, and that churn
  is precisely what defeated the tick-level brake. A board DIFF line has its
  verb and description normalised away (see below); an `UNBLOCKED`/`STACKABLE`
  line from `bin/unblocked-children.sh` is kept verbatim, because it carries
  dependency facts no fingerprint holds. Result lines are kept verbatim minus
  ISO timestamps.
- **The ticket's own entry in the live board fingerprint**
  (`state/<project>.gate.pending`), for any key the board named this tick. That
  entry is the world; the diff line is only a statement about what we consumed.
- **The state of every PR the queue line names**, from the carried-forward
  ledger `state/<project>.prstates` — never from `state/<project>.queuefp`. See
  the section below; that distinction is a BLOCKing review finding, not a
  preference.
- **This key's build dirs with their `RESULT`/`COMMENTED` marks.** A finished
  build reaches a `queue-pending` tick as no scope line at all, so without this a
  close-out could be deduped away and the client would never hear back.

Deliberately NOT in it: `state/<project>.result-rows`. It is a project-global
watermark with no ticket in it, so folding it in would move every key's
fingerprint whenever any build in the project finished. That is the tick brake's
job; the build it announces reaches the key through its own dirs.

**Three outcomes, never two** (`triage_shard_fp_fresh`): fresh (skip), stale or
different or never stamped (dispatch), and **unreadable** (dispatch, and say so).
A 0-byte or garbage stamp file reading as "already paid" is the BH-977 shape —
it would take that ticket dark until the daily sweep — so it fails open and logs.

**The PR states have their own carried-forward file, and that is not a detail.**
The obvious source was line 3 of `state/<project>.queuefp`, where
`bin/triage-gate.sh` parks its own 45-minute PR lookup. Probed against the real
gate: a first tick writes 2 lines, a quiet 50-minute tick writes 3 with
`12=OPEN;`, the next reworded-prose tick writes 2 again. The gate writes that
line on ONE of its three write branches and erases it on the other two, so the
same unchanged world gave one key two different fingerprints and bought a
session on each flip — twice per 45-minute cycle, on exactly the "still waiting
on PR #X" line this lane is about. Worse in the other direction: with the stamp
taken in the `?` state a merge was invisible until the TTL. And
`bin/lib/rt/shards.sh` deletes `queuefp` whenever the hourly cap defers a unit,
which erased the vector for every key at once.

So `state/<project>.prstates` (`<number>\t<STATE>\t<epoch>`) is written by
nothing else and deleted by nothing. It is FED from the gate's free lookup when
there is one (`triage_prstates_ingest`), REFRESHED once per tick when an entry
has aged past `TRIAGE_PRSTATES_TTL_S` (`triage_prstates_refresh` — one pass for
the numbers the queue lines name, capped at 20 exactly like the gate's own
lookup, never per key), and CARRIED FORWARD otherwise. That refresh goes through
`bin/lib/gh-rest.sh` and never a raw `gh` call: it is `no-graphql` by
construction, its `44`/`75` split is what lets a 404 be cached as `ABSENT` while
a rate limit leaves the carried-forward value and its stamp untouched, and the
App identity is armed around the pass (`gh_auth_for` / `gh_auth_reset`). The
pass is gated on `gh_budget_low triage-prstates` — a PR-state refresh is a
non-essential read and skipping it costs only a carried-forward value. `?` appears only
before the first successful read on a box and never flaps back; a failed lookup
leaves the previous value alone, because a transient outage must not turn a
known `OPEN` into a `?` and buy a session for every key that names it — and
since BH-1079 it also writes ONE line to `logs/<project>.log` saying which
number failed and how old the value it kept is, because a silent carry-forward
was indistinguishable from a successful read.

**The ledger's four age and spend rules** (BH-1079, the round-2 review):

- **An ingested pair carries the GATE's epoch, and a not-older stamp wins.**
  `queuefp` line 3 SURVIVES every tick the gate did not re-read on, so the same
  `12=OPEN;` is re-ingested tick after tick. Stamped `now` and written
  unconditionally, a ten-minute-old `OPEN` replaced the `MERGED` the REST
  refresh had just established, every key naming PR #12 flipped its fingerprint,
  and each one bought a session on a merge that had already happened. The epoch
  is `queuefp` line 2 now, and an entry is replaced only when that epoch is not
  OLDER than the one on file. Not strictly-newer, and the tie is not the
  refresh: `triage_prstates_refresh` runs after `triage_prstates_ingest` in the
  same tick and skips every row younger than `TRIAGE_PRSTATES_TTL_S`, so it
  never re-stamps what the ingest just wrote. The tie is two GATE reads landing
  in one second — 45 minutes apart on a box, back to back in the suites
  (`tests/triage-shards-ticket-fp-test.sh` case (B), and (B5) at the lib in
  `tests/triage-shards-prstates.bh-1079-test.sh`). Equal seconds are no evidence
  of staleness: both vectors read the same GitHub, so letting the later one land
  costs one identical rewrite, while a strict compare would hold a real merge
  for the gate's whole 45-minute window. A `queuefp`
  whose line 2 is not an epoch ingests NOTHING — a vector with no readable age
  cannot claim to be newer than anything.
- **`MERGED` and `CLOSED` are terminal.** Neither can change back on its own, so
  the REST refresh never re-reads one. A reopen still reaches the ledger, through
  the gate's own vector when it is newer — which is the only path that should
  move a terminal state. `ABSENT` (a cached 404) is NOT terminal: it is re-read
  once per `TRIAGE_PRSTATES_TTL_S` exactly like an `OPEN`, so a queue line that
  names a PR before it exists heals on its own — do not add it to the refresh's
  skip list.
- **Both PR lookups consult `bin/lib/gh-budget.sh` first** (lane
  `triage-prstates` for the refresh, `triage-gate` for the gate's own). Under
  rate-limit exhaustion each was up to 20 silent calls per project per tick,
  competing with the lanes that must talk to GitHub. A low budget carries every
  value and stamp forward, which is exactly what a failed lookup already does;
  the gate leaves `PRV` empty, which is the branch it already takes on any `ERR`
  (`RUN queue-pending`, 2-line `queuefp`, identical outcome, zero lookups). An
  UNKNOWN budget (no library, or a `rate_limit` endpoint that did not answer)
  proceeds, like every other consumer — a broken endpoint must not freeze a
  ledger. The refresh decides which numbers need a call BEFORE it reads the
  budget, so a tick with nothing to look up stays free.
- **`triage_prstates_prune` runs once per tick**, right after the refresh, and
  drops the entries that are BOTH unnamed by any current `logs/READY-QUEUE.log`
  line AND older than `TRIAGE_PRSTATES_PRUNE_S`. Either condition alone keeps the
  row: a long-lived blocking PR is exactly the entry this ledger exists to carry.
  One locked rewrite, under the same sidecar lock as the writer.

**The diff VERB is normalised away, and a skipped key is NOT re-armed.**
`bin/gate-diff.sh` names a ticket `NEW` when the consumed fingerprint lacks it
and `CHANGED` when it has it, and only the `CHANGED` line carries
`(comments: 5 -> 6)`. A key re-armed out of `state/<project>.gate.json` sits on
`board issues: NEW 563 "c"` — byte-identical at five comments and at six — so
fingerprinting that text let a client's reply be skipped for the whole TTL, on a
webhook wake as well, because the wake scopes off the same line. The fingerprint
reads the ticket's live entry instead and treats the three verbs as one token;
and because `fp`-fresh now MEANS the thread has not moved, a skipped key is left
consumed rather than re-armed. Re-arming it (the first cut of this change) is
what kept it permanently on that count-less `NEW` line.

**And a tick that skipped EVERY key still consumes** (BH-1079). The dispatcher
used to absorb `state/<project>.gate.pending` only when it had actually
dispatched something, so a key the HELD path had re-armed out of
`state/<project>.gate.json` stayed out of it for ever: every following tick
re-fetched the board, `bin/gate-diff.sh` reported the same `NEW <id>` line, the
fingerprint correctly said "unchanged, no session", and the gate could never
answer `SKIP no-change` because the file it compares against was missing the very
ticket the board kept reporting — until the 4h TTL expired and bought one
spurious session. The consume condition is `SHARD_N > 0 OR SHARD_SAME non-empty`,
and the order is load-bearing: consume first, re-arm HELD/LEFT after, because
`triage_shard_rearm` edits `gate.json` in place and would be overwritten by the
`mv`.

**The stamp is released whenever the shard did not do the work.**
`REARM_UNOWNED` in `bin/triage-shard.sh` clears it on the three paths that mean
this shard does not own the world it was handed: the coordination ledger refused
the claim, the triage contract was missing, or the session exited nonzero. The
"key lock already held" path uses the plain `REARM` and leaves the stamp alone —
two shards meet on one key only when the dispatcher's held census races the
first shard's `flock`, and the loser must not delete the WINNER's stamp, which
is a live claim on work running right now.

**How an operator reaches it:** there is no UI. The lane is the per-project
`run-triage.sh` line in `cron/<box>.cron`.

**Primary lanes / scripts:**
- `bin/lib/rt/shards.sh` — the `# >>> per-ticket fingerprint` block (the check,
  the skip, the two log lines) and the `triage_shard_fp_put` call sited after the
  cap checks and before the `setsid` spawn.
- `bin/lib/triage-shards-lib.sh` — `triage_shard_fp`, `triage_shard_fp_fresh`,
  `triage_shard_fp_put`, `triage_shard_fp_clear`, `triage_shard_fp_ttl`,
  `triage_shard_fp_file`, the normalisers `_tsh_fp_qnorm` / `_tsh_fp_bnorm` /
  `_tsh_fp_line` / `_tsh_fp_builds` / `_tsh_fp_pending`, and the PR-state ledger
  `triage_prstates_file` / `_ttl` / `_prune_s` / `_get` / `_ingest` / `_refresh` /
  `_prune` (the refresh reading through `bin/lib/gh-rest.sh`, armed by
  `bin/lib/gh-app-auth.sh`), with `_tsh_prstates_ts` (an entry's epoch) and
  `_tsh_gh_budget_low` (the subshell consult of `bin/lib/gh-budget.sh`).
- `bin/triage-gate.sh` — the queue branch's own 45-minute lookup, through the
  same `gh_rest_pr_state`, which takes the same budget consult before it
  spends.
- `bin/triage-shard.sh` — `REARM_UNOWNED` releases the stamp beside the
  fingerprint re-arm on the three unowned paths; `REARM` (held path) does not.

**Knobs:** `TRIAGE_PRSTATES_TTL_S` (default `2700`, the gate's own queue-brake
window) sizes the REST refresh of the PR-state ledger.
`TRIAGE_PRSTATES_PRUNE_S` (default `604800`, seven days) is how long an entry no
queue line names may sit in the ledger before the per-tick prune drops it;
resolved by `_tsh_num` from the environment then `env/global.env`, like every
other `TRIAGE_*` knob.
`TRIAGE_SHARD_FP_TTL_S` (default `14400`, four hours — the same hard
backstop the gate's queue brake uses), resolved by `_tsh_num` from the
environment then `env/global.env`, exactly like every other `TRIAGE_SHARD_*`
knob. **`TRIAGE_SHARD_FP_TTL_S=0` is the off switch**: nothing can be younger
than zero seconds, so every key dispatches exactly as it did before BH-1015.
There is no flag file — the knob is the lever, and a fleet-wide kill is a line
in `env/global.env`.

**How to drive it:**
- `HARNESS_TEST_SANDBOX=1 bash tests/triage-shards-ticket-fp-test.sh` — drives
  the REAL `bin/run-triage.sh` against a scratch `$HARNESS` with the gate,
  `agent-call.sh` and `beat.sh` stubbed; the stub agent-call writes a cost row,
  so "no session was bought" is asserted on `logs/cost.csv` and not only on a log
  line. Covers: two ticks over an identical queue line whose `Re-checked` stamp
  and hold prose differ (second tick: 0 calls, 0 cost rows, one `unchanged` line);
  a referenced PR flipping `OPEN`→`MERGED`; a new `RESULT` dir for the key; a
  stamp backdated past the TTL (dispatches once, restamps, quiet again after);
  five consecutive quiet ticks;
  a 0-byte and a garbage `.fp` (both dispatch, with the fail-open line); and the
  knob resolving from both the environment and `env/global.env`.
  Part B drives the ACTUAL `bin/triage-gate.sh` through its 2/2/3/2-line write
  sequence and asserts the fingerprint never moves for an unchanged world, that
  a real merge does move it, that the ledger refreshes itself when the gate
  never looks, that three keys naming one PR produce ONE read, that a
  rate-limited read leaves the carried-forward value and its stamp alone, that a
  404 is cached as `ABSENT` and then stays quiet, and that losing `queuefp` to a
  cap deferral re-buys nothing.
  Part C moves only the live fingerprint and expects a dispatch, and moves only
  the diff verb and expects quiet, including the event-wake path.
- `HARNESS_TEST_SANDBOX=1 bash tests/triage-shards-prstates.bh-1079-test.sh` —
  the same scratch-tree shape for the ledger's age and spend rules and the
  skip-only consume. Part A drives the REAL `run-triage.sh` + `triage-gate.sh` +
  `gate-diff.sh` over a re-armed key for five ticks and asserts the gate reaches
  `SKIP no-change` on ticks 2-4 (and that a real client reply on tick 5 still
  dispatches). Part B pins the ingest epoch (older loses, newer wins, same-second
  wins, unreadable ingests nothing) at the lib AND through a real tick. Parts C-E
  pin terminal states, the failed-lookup log line and the budget consult
  (low/healthy/unknown/quiet). Part F drives the REAL gate under a low and a
  healthy budget. Part G pins the prune at the lib and through a real tick.
- `HARNESS_TEST_SANDBOX=1 bash tests/triage-shards-test.sh` and
  `HARNESS_TEST_SANDBOX=1 bash tests/rt-split-layout-test.sh` — the dispatcher's
  own contract and the prompt goldens, unchanged by this guard.

**Preconditions / seed needs:** none beyond the fixture suite. On a box, a
project with at least one `READY-QUEUE.log` line is needed to see a skip at all.

**Verify it works (on a box):**

```sh
ls -l /root/harness/state/triage-shards/<project>/*.fp        # one per dispatched key
cat /root/harness/state/triage-shards/<project>/<key>.fp      # fingerprint, then an epoch
grep 'unchanged since the last shard' /root/harness/logs/<project>.log | tail
grep 'dispatched .* — unchanged:' /root/harness/logs/<project>.log | tail
grep 'gate no-change' /root/harness/logs/<project>.log | tail   # after a skip-only tick
cat /root/harness/state/<project>.prstates                       # never MERGED -> OPEN
grep 'prstates refresh: PR #' /root/harness/logs/<project>.log | tail  # failed lookups
```

The user-visible effect is on the dispatch line itself: a busy board that used to
read `dispatched 9 shards:` on consecutive ticks starts reading `dispatched 1
shards: … — unchanged: 561 562 563 …`, and the project's `stage=triage` rows in
`logs/cost.csv` fall with it. A key that never leaves the `unchanged` list for
more than four hours is a bug in this guard, not a quiet board.

**Manual-only / not automatable:** the spend proof itself. Whether the fleet's
triage bill actually fell is read from `logs/cost.csv` across the boxes after
`bin/harness-sync.sh` has propagated this, which is an operator action and not a
check this repo can run.
