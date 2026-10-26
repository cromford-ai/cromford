# Triage state — a per-ticket, DB-backed gate before the model

Approved by the operator on 2026-09-28: "everything should be DB based; the triage
should status-track with a database on each ticket, deterministically, before
it spends tokens to see if it even needs to triage." Plan:
`.harness/specs/TRIAGE-STATE/plan.md`.

The tick-level gate (`bin/triage-gate.sh`) answers "did the board move". Once
it answers yes, every pending ticket used to go back to the model: on
2026-09-28 cromford re-triaged 13 unchanged tickets every ~20 minutes at
$8-15 a tick, and the one buildable ticket was re-triaged instead of built.
This table is the per-ticket answer: what the model last decided about a
ticket, and which inputs it decided on.

## The table (Cloudflare D1, `worker/jobs/schema.sql`, the TRIAGE-STATE block)

`triage_state`, primary key `(project, ticket_key)`:

| column | what it holds |
|---|---|
| `ticket_key` | the tick's canonical unit key (`triage_shard_canon`): the issue number on a GitHub-Issues board, the board ticket id in-app |
| `ticket_label` | the human key (`BH-2657`, `TK-12`) |
| `input_hash` | the last pre-check's hash of the ticket's inputs |
| `verdict` | `buildable`, `needs_clarification`, `waiting_client`, `queued`, `hold`, `closed`, `blocked` or `triaged` |
| `waiting_on` | `client`, `team` or `none` |
| `verdict_hash` | the `input_hash` the verdict was made against |
| `triaged_at` / `next_recheck_at` | when the verdict was written, and when it is due back at the model on a timer (absent when the verdict has none: see "The timer") |
| `reason` | the `DECISION` line (or the seed) the verdict came from |
| `last_decision` / `last_decision_at` / `last_mode` | the pre-check's last answer (`llm <why>`, `skip <why>`, `enqueue`) and the mode it ran under |

D1 behind the bearer-authed worker: no RLS step, like every table in that file.
`CREATED_TABLES.triage_state` in `worker/jobs/src/lib/core.js` is the
self-create belt for a deploy that ran before the schema apply.

## The routes (`worker/jobs/src/routes/triage-state.js`)

| route | answer |
|---|---|
| `GET /api/triage-state/:project/:key` | `{triage_state: row}`, 404 when there is no row |
| `GET /api/triage-state?project=P[&due=1][&limit=N]` | the project's rows in key order (at most 1000), `truncated`; `due=1` keeps rows whose `next_recheck_at` has passed |
| `PUT /api/triage-state` | one row `{project, ticket_key, ...}` or `{project, rows:[...]}` (at most 200, refused whole past that) |

A PUT writes ONLY the columns it carries, so the pre-check's observe write
(`input_hash`, `last_decision`, `last_mode`) never erases the verdict a session
wrote. Every row of a batch is validated before the first write.

## The client (`bin/lib/jobs/queue.sh`, `bin/jobs-client.sh`)

`triage_state_get <project> <key>` (one compact JSON object; rc 2 on a 404),
`triage_state_list <project> [due] [limit]` (one JSON array),
`triage_state_put <json-file>`. CLI verbs: `triage-state-get`,
`triage-state-list`, `triage-state-put`. Fail-open like every verb in the
client: an unreachable worker is rc 1 and prints nothing.

## The pre-check (`bin/lib/triage-state.sh`, slice 2)

`ts_tick` runs at the top of `rt_shards` (`bin/lib/rt/shards.sh`), after the
tick-level gate said RUN and the scope was computed, and before any shard unit
is formed or any model is called.

### The input hash (`bin/triage-state.py hash`)

One function, every caller. sha256 over a canonical document of:

- the THREAD as `bin/triage-signal.py` digests it (imported, not copied): title,
  body, state/status, priority, attachments by identity, and every comment NOT
  written by us as (id, author, body). "Ours" is the BH-2133 / BH-2542 / BH-2604
  rule: one of our GitHub Apps, or the board's SELF_ACTORS / SELF_IDENTITIES. The
  PAT login is a person. Our own triage comments never move the hash;
- every LABEL except the ones we write (`TRIAGE_STATE_SELF_LABELS`);
- every DEPENDENCY: on GitHub, each `#N` / `<PREFIX>-N` the title, body or a
  non-self comment names, with its state from the gate's own board fingerprint
  (the issue's state, `pr-open` for an open PR). A `#N` the fingerprint cannot
  place (a blocker without the ai-build label, an old PR) is looked up by REST
  inside the fetch cap and cached in `state/triage-state/<p>/refs.json`
  (`CLOSED` / `MERGED` / `MISSING` are final; `OPEN` is re-asked while the cap
  allows), so its closing still moves the hash. In-app, `blocked`, `parentId` and `dependsOn` with the statuses the
  fingerprint carries, plus keys the thread names;
- every REASON REF: each `#N` / `KEY-N` the stored verdict's `reason` names
  (the model's DECISION words, or the seed's), resolved by the SAME path as a
  thread ref (fingerprint, else the bounded REST lookup cached in `refs.json`,
  inside the same fetch cap). Only `reason`: `last_decision` is the pre-check's
  own per-tick answer and would churn the hash. The incident this closes
  (first shadow tick, 2026-09-28): BH-3149 / BH-3154 were deferred "until
  #3165", a PR their threads never named; #3165 merged and the hash did not
  move, so enforce would have held both until their recheck.

  The hash is composed: `base` = the thread-only hash (the formula before
  reason refs), and `input_hash = base` when the reason names no ref, else
  `sha256({v:2, base, reason_deps})`. `decisions.tsv` column 8 carries `base`.

  MERGED REASON REFS (in-app, BH-3829). An in-app ticket's status does not
  move when its PR merges, so a verdict that waited on `KEY-N` ("PLAN_BLOCKED,
  build after TK-2185 lands") never saw the merge. `ts_precheck` now asks
  `gr_key_merged` (`bin/lib/gate-release.sh`) about every undotted `KEY-N` the
  stored reasons name, at most `GATE_RELEASE_MAX_LOOKUPS` keys in row order
  (a key past the cap is not in the map, which is the hash it had before),
  writes `state/triage-state/<p>/merged-refs.json` (`{KEY: [pr,
  merged_at]}`) and passes `hash --merged-refs`. A reason ref merged AFTER the
  row's `triaged_at` resolves to `"<status>|merged"`, so the hash moves and the
  ticket goes to the model as `llm changed`. It moves ONCE: `record` never
  reads the map, so the re-triage stamps the plain status, and the next tick
  (whose `triaged_at` is now after the merge) computes that same hash. A
  `|merged` state is settled for the legacy-row transition below (to the
  model, never re-stamped). Thread refs and GitHub boards are untouched; no
  map, an empty one or an unreadable file is byte-identical. DARK: nothing is
  asked or written while `lib.gate-release.GATE_RELEASE_MAX_LAUNCHES` is 0
  (its default) or the `gate-release-off` switch is on.

Timestamps, comment counts, waitingOn / triageVerdict / turn are out.

The thread is read through `bin/triage-gate.sh <p> --thread <id>` (the same
reads `--signal` makes, now one shared `thread_doc`) only when the ticket's
board-fingerprint row moved (its cached `<key>.entry` is not this tick's entry
hash), or when nothing is cached for it (no `<key>.raw`, no `<key>.entry`).
Otherwise the cached raw thread (`state/triage-state/<p>/<key>.raw`) is
re-hashed against the current fingerprint, so a dependency changing state moves
the hash with no read. A webhook naming the ticket and a due recheck do NOT
force a read (BH-3921): a real change moves the board row, and `scope.sh` runs
`--pending` for an event-wake first, so it reaches the fingerprint on that tick
(a lagging board API is caught by the next board-changed tick); a due recheck is
the model's, and the session reads the thread itself. Reads per tick:
`TRIAGE_STATE_MAX_FETCH` (30). A low GitHub budget reads nothing.

The reads ROTATE (BH-3920). Every open ticket that needs a read is ranked
first by tier (0 = a webhook named it this tick, 1 = everything else; the tier
only orders the tickets that need a read), then by
its last read ATTEMPT (`<key>.tried`, touched on success and failure, else the
cached `<key>.raw` mtime, else 0 = never read), with a stable sort keeping board
order on a tie. The first `TRIAGE_STATE_MAX_FETCH` are read. So N tickets that
all need a read are all read within `ceil(N / cap)` ticks whatever their board
order (84 at cap 30: 3 ticks). Before BH-3920 the loop walked the board in
order and spent the cap on the same head every tick: on project-4 the 30 due keys
first in board order were read every tick and the other 54 never were.

A ticket that needs a read and is past the cap (or every ticket, on a low
budget) keeps its cached thread AND its entry stamp, so it stays owed. It is
decided `skip deferred:cap` (`skip deferred:budget` on a low budget), with or
without a cached thread: carried to the next tick, never sent to the model
unread, never `unhashable` and never counted unchanged. Column 5 is the hash of
the stale cached thread when there is one, else `-`. The pre-check writes the
deferred keys to `state/triage-state/<p>/deferred.tick`, and under enforce moves
that to `deferred.keys` (rewritten whole every enforce pre-check); in any other
mode `deferred.keys` is left empty. The lane-log summary carries
`[reads=N cap=N budget=N]`.

THE `ts-deferred` GATE STEP. `bin/triage-gate.sh` step 1d (right after the
split-ready step 1c, before the queue / results / board brakes) answers
`RUN ts-deferred` when `deferred.keys` is non-empty, younger than 86400 s, the
mode is `enforce`, the effective `TRIAGE_STATE_MAX_FETCH` is above 0 (read
through the same `_ts_knobs` as the pre-check) and, on a GitHub-Issues board,
`gh_budget_low triage-state` does not hold. A ts-deferred tick is a full-SOP
tick that `ts_tick` enforces: when the reads change nothing it ends
`rc=skip :: triage-state: 0 changed` at $0, and a changed ticket goes to the
session. That $0 end absorbs the board fingerprint but never stamps
`state/<p>.gate-meta` (the daily sweep's clock): it read owed keys, not the
board. N owed reads drain within `ceil(N / cap)` such ticks. A cap of 0, a
stale file, a non-enforce mode or a low GitHub budget never fires: under a low
budget the pre-check reads nothing and rewrites the same list, so firing would
answer `RUN ts-deferred` every tick and starve the queue, results and sweep
steps. The list is kept, and the first gate after the budget recovers drains
it.

### The decision, per open ticket

| state | decision |
|---|---|
| no hash: a read that ran and failed, or a thread the hash pass cannot parse (300+ comments) | `llm unhashable` |
| needed a read, past the cap | `skip deferred:cap`, with or without a cached thread (column 5: the hash of the stale cached thread, else `-`). Ahead of the hand-off hold; the legacy re-stamp never runs on it |
| needed a read, low GitHub budget | `skip deferred:budget`, the same way |
| CLOSED on the board, stored verdict is not `closed` (or no row at all) | `stamp closed-on-board`: the pre-check writes `verdict=closed`, reason `closed on the board; stamped without a model call`, a salted hash (a reopen moves it), NO model call; logged `triage-state <mode>: stamped N closed ticket(s) without a model call: KEYS`. It replaced `llm closed`, which looped: no session ever runs for a closed ticket, so the row stayed `triaged` (BH-3316 / 3320 / 2649 / 2652 / 3321, 2026-09-29) |
| no row and nothing to seed it from | `llm new` |
| `input_hash != verdict_hash` | `llm changed` |
| legacy row (below) whose reason names a ref that has since merged / closed / gone | `llm changed` |
| due on the timer (below): a DEFER-LIKE verdict naming no ref older than `TRIAGE_STATE_DEFER_TTL_S` (2h), a client-turn verdict older than `TRIAGE_STATE_CLIENT_NUDGE_S` (14 days), or with `TRIAGE_STATE_TTL_S` > 0 any `next_recheck_at` passed | `llm recheck-due` |
| would be `llm new` / `changed` / `recheck-due`, the row's reason is `handed-no-decision <marker>` with the marker equal to this tick's hash, before its `next_recheck_at` (never a deferred ticket) | `skip handed-no-decision` |
| `buildable`, unchanged, nothing owns it | `enqueue` |
| `buildable`, unchanged, owned | `skip buildable-owned:<enqueued, building, build-dir, abandoned, queue-*, pr-N, builds-paused, overlap, *-unreadable>` |
| `buildable`, unchanged, held (`bin/lib/hold.sh` on GitHub, `triage-gate.sh --buildable-strict` in-app, which is BLOCKED on any read it cannot make) | `skip buildable-held:<why>` |
| anything else, unchanged | `skip unchanged:<verdict>` |

`build-dir` is any build directory for the key newer than the verdict: a
failed build is not re-launched in a loop. At the default TTL 0 nothing
re-offers it on a timer: `bin/blocked-resolver.sh` owns failed builds. With
`TRIAGE_STATE_TTL_S` > 0 the TTL re-offers it.

### The timer

`bin/triage-state.py` `due_at` is the one rule (`due` and `decide` both ask it),
and `recheck_ttl` is what `record` stamps:

- a `handed-no-decision` row is due at its `next_recheck_at` (the backoff);
- `TRIAGE_STATE_TTL_S` = 0 (the default; unset or junk also reads as 0): a
  verdict whose inputs did not move is never re-offered on a timer, EXCEPT a
  DEFER-LIKE verdict naming no ref (due at the earlier of its `next_recheck_at`
  and `triaged_at + TRIAGE_STATE_DEFER_TTL_S`) and a client-turn verdict
  (`needs_clarification` / `waiting_client`, or `waiting_on=client`), due at
  `triaged_at + TRIAGE_STATE_CLIENT_NUDGE_S` (default 1209600, 0 = off, floored
  at 3600). Any other row's leftover `next_recheck_at` is ignored, so rows
  stamped under the old 24h TTL cause no mass recheck;
- `TRIAGE_STATE_TTL_S` > 0 (floored at 600) is the per-ticket sweep: every
  verdict is due at its `next_recheck_at`, else `triaged_at + ttl`, with the
  defer clamp, and a client turn also at `triaged_at + nudge` if sooner.

`record`, the decisions.log seed and the closed seed leave `next_recheck_at`
out when the verdict has no timer; they never stamp `now + 0`. The worker then
keeps an existing row's old stamp, which the rule above ignores. The TTL is
shared with the PR pre-check (`bin/lib/triage-state-pr.sh`).

DEFER-LIKE verdicts (`bin/triage-state.py` `DEFER_LIKE`): `queued` (DECISION
`defer` or `queue`) and `blocked`, WHEN THEIR REASON NAMES NO REF (a defer that
names one is re-offered by the hash when the ref moves, so it gets no defer
timer; `attempt #2`, `round #3` and the like are counts, not refs). They may wait on something no ref names (a
harness code change, a gate another lane owns), so they are rechecked after
`TRIAGE_STATE_DEFER_TTL_S` (default 7200; settings row
`lib.triage-state.triage_state_defer_ttl_s`): `next_recheck_at = triaged_at +
defer_ttl` (`min(defer_ttl, ttl)` when a TTL is set), and a defer stamped under
the old 24h recheck is due at `triaged_at + defer_ttl`. Not defer-like:
`needs_clarification` / `waiting_client` (the client's reply moves the thread
hash; its only timer is the client nudge), `hold` (a person's
comment or label moves it), `buildable`, `triaged`, `closed`.

THE REASON-REFS TRANSITION. A row stamped before reason refs joined the hash
(or seeded from decisions.log, whose seed reason is not in the hash it was
seeded against) has `verdict_hash == base`. It is not a blanket `changed`, which
would re-triage every such row at once. Its reason refs' verdict-time state was
never recorded, so the pre-check decides from their state now:
- one has SETTLED (MERGED / CLOSED / MISSING, or a closed in-app status): the
  thing the verdict waited on may have happened, which is the incident: `llm changed`;
- one is not looked up yet (GitHub `absent`: fetch cap, low budget): decided as
  unchanged, nothing re-stamped, asked again next tick;
- all still open: `verdict_hash` is re-stamped in place to the new hash with no
  model call, and the lane log says `triage-state <mode>: re-stamped N legacy
  verdict(s) with their reason refs, no model call: <KEYS>`.
Cost: one model call per legacy row whose reason ref has settled (each one a
ticket the old formula was wrongly holding), zero for the rest.

BACKFILL: a ticket with no row is seeded, against today's hash, from the newest
`logs/decisions.log` line for it when that decision is newer than the ticket's
last update of ANY kind (its own updated stamp and every comment, ours
included), or in-app from the board's `waitingOn=client`.
Everything else has no row, so the first enforce tick sends it to the model once.

### What each mode does

- `shadow` (default): the decisions go to `state/triage-state/<p>/decisions.tsv`,
  to one lane-log line (`triage-state shadow: N open, L to the model: …, S
  unchanged, E would enqueue: …`) and to each row's `last_decision` /
  `last_mode`. The prompt, the shard loop and every launch are untouched.
- `enforce`, on a board-changed / event-wake / daily-sweep / queue-pending /
  results-sweep / remote-results-pending / split-ready tick:
  - each `enqueue` ticket is launched through `bin/run-build.sh <p> <id> <KEY>`
    (at most `TRIAGE_STATE_ENQUEUE_MAX`), with a marker holding the verdict hash
    so one verdict launches once;
  - when nothing goes to the model and the scope holds no queue line, no
    finished build, no UNBLOCKED/STACKABLE line and no PR line, the tick ends at
    $0: `rc=skip :: triage-state: 0 changed`, gate consumed, job claim closed.
    Never on a `daily-sweep` tick (the consume would stamp the full-sweep
    clock for a sweep that swept nothing) or a `remote-results-pending` tick
    (its result JSON has no board line);
  - otherwise a shard key whose only units are board units and whose decision
    is not `llm` is not dispatched, and the single session's prompt gets one
    `TRIAGE STATE` directive: re-triage only the changed tickets, leave the
    unchanged ones alone. A key with a queue line or a finished build in the
    tick is never on the do-not-touch list: the pre-check marks it once, as
    `decisions.tsv` column 9 (`work`, 1 or 0), and the directive reads that
    column. A work key is the board label on an in-app board (`TK-2182`, from
    a queue line or `<p>-TK-2182-<stamp>`) and the number on GitHub (`13`), so
    a ticket matches on its key (column 1) OR its label (column 2), whole
    tokens only (`TK-218` never matches `TK-2182`). The same match places
    an in-app work key in a scoped tick's scope (column 7).
  A `forced`, `gate-error`, `gate-fetch-failed` or `no-gate-state` tick is
  observed, never skipped.
- `off`, or the kill switch: nothing runs, nothing is written.

### The re-offer (BH-3829)

The other half of the merged-reason-ref fix lives in
`bin/lib/gate-release/reoffer.sh`, run by `bin/gate-release.sh` every tick
before the gate. A `PLAN_BLOCKED` result marked `COMMENTED` is re-offered when
the key is open in the keymap, nothing newer or in flight covers it, its
build-key lock is free, and every STATED blocker merged after the RESULT's
mtime. Stated blockers are the key's own READY-QUEUE line (`gr_parse_gate`;
a prose `gate:` vetoes the offer) plus the keys in its newest
`logs/decisions.log` line, when that line is newer than the RESULT and says
`PLAN_BLOCKED`. An offer writes `state/gate-release/<p>/offered/<KEY>` first,
then the one-shot `state/gate-reoffer-keys-<p>`, then one
`GATE_REOFFER <KEY>: PLAN_BLOCKED result re-offered, <KEY-N> merged (#pr)`
log line. `bin/triage-gate.sh` step 1d answers `RUN gate-reoffer` while that
file is younger than `GATE_RELEASE_REMIND_S` (older: deleted unread), and the
tick's scope (`inapp_released_lines`) consumes it, re-verifies each key and
adds one line per key still due:
`board gate: REOFFER <KEY> "<title>" (PLAN_BLOCKED result <dir> is not settled: ...)`.
`gate-reoffer` is an enforce reason, the REOFFER key is a work key (never on
the do-not-touch list), and a tick that carries the line is never ended at $0.
One offer per key per `GATE_RELEASE_REMIND_S`, at most
`GATE_RELEASE_MAX_LAUNCHES` per pass, and dark at 0 like the hash half.

### After the session

`ts_after_session` (`bin/lib/rt/launch.sh` for the single session,
`bin/triage-shard.sh` for a shard) writes each verdict from the session's own
`DECISION:` lines, stamped with the hash of the inputs the pre-check read BEFORE
the session: the pre-session `base` composed with the refs the NEW reason
names, at their pre-session state (the tick's fingerprint and `refs.json`), so
the next tick computes the same hash when nothing moved. (Stamping the
pre-session composite would carry the OLD reason's refs and re-offer every
ticket whose new reason names a new ref.) A new reason ref neither place can
resolve is looked up by REST after the session, inside the fetch cap, before
the stamp; only an OPEN answer is stamped (a ref found CLOSED / MERGED /
MISSING may have settled during the session, so it stays `absent` and the next
tick re-offers the ticket once). A SHARD is detached and may record after the
next tick's pre-check rewrote `world.json` / `refs.json` / `decisions.tsv`, so
the dispatcher snapshots all three per shard (`ts_shard_hash`,
`state/triage-state/<p>/snap/<key>.<hash>/`) and the shard stamps against that
snapshot only. `refs.json` is shared by concurrent writers (pre-check, single
session, shards): each REST body lands in a per-process temp, and each entry
is merged under an flock into the CURRENT file and renamed in. Mapping: `launch` -> `buildable`, `queue` / `defer` -> `queued`, `escalate` ->
`hold`, `close` -> `closed`, a reason about the client or a question ->
`needs_clarification` (waiting on the client), anything else -> `triaged`. Every
DECISION line is read. A model-set ticket with no line is `triaged` ONLY when it
was IN THIS TICK'S SCOPE (`decisions.tsv` column 7: every open ticket on a full
tick; the board lines, queue lines and finished builds on a scoped one) and the
session printed its `tickets=` summary or at least one DECISION line. A `llm
closed` ticket, and ANY ticket closed in this tick's world (the single session
and every shard), is recorded `closed` whatever the DECISION action (`skip`, a
close-out `comment`, ...), with the model's reason kept: `verdict_of` maps
those to `triaged`, which was `llm closed` again every tick (the BH-3316 /
BH-3320 loop, enforce 2026-09-28). The `closed` stamp is a salted hash, so a
reopened ticket always moves its hash and goes back to the model. rc != 0 writes nothing, so the ticket is
offered again.

HANDED, NO DECISION (BH-3920). An rc-0 session that printed no DECISION line
and no `tickets=` summary at all used to record nothing, so every model-set
ticket stayed due and was bought again every tick until the call-guard refused
the identical prompt (project-4, 2026-10-03). Now each in-scope model-set ticket it
was handed gets a partial row: `reason` = `handed-no-decision <marker>: the
session was handed this ticket and returned no DECISION line; offered again
after <backoff>s[; was: <previous reason>]` and `next_recheck_at` = now +
`TRIAGE_STATE_HANDED_NO_DECISION_BACKOFF_S` (7200). No `verdict`,
`verdict_hash`, `triaged_at` or `waiting_on` is written: nothing is claimed
about the ticket. The marker is the input hash the next tick computes when
nothing moves, so a new comment, label or ref state re-offers the ticket at
once; otherwise it is `skip handed-no-decision` until the backoff ends. A
second hand-off keeps only the original `was:` text. A row with a marker is due
at its `next_recheck_at`, never earlier through the DEFER-LIKE clamp. `pr-*`
keys never get one (the BH-3417 PR record contract). The lane log says
`triage-state: handed-no-decision N: <KEYS> — the session returned no DECISION
line for them; offered again after <backoff>s`, the single session leaves
`state/triage-state/<p>/hnd.last` (`<epoch> <N> <KEYS>`), and a refused row PUT
logs `triage-state: recording N row(s) failed (rc R)`.

STUCK ALERT (BH-3920). When `rt_gate_fail_consume` (`bin/lib/rt/gate.sh`)
consumes a fingerprint after `TRIAGE_FAIL_CONSUME_AFTER` failures and the last
failure was the call-guard refusing the same prompt (`AGENT_CALL_REFUSED
call-guard repeat` in the session output), it writes ONE more alert,
`--id triage-stuck:<p>`: `[<p>] triage is stuck: the call-guard refused the
same full triage N times (fingerprint F). K key(s) in the model set: <KEYS>.
Reason: <why>.` The reason is `model returned no DECISION for N handed keys`
when `hnd.last` is younger than twice the backoff, else the model set by
reason (`recheck-due=27 changed=3 unhashable=2`). If `bin/lane-alert.sh`
does not run, the same text goes to `logs/ALERTS.log` raw.

In shadow, a DECISION for a ticket the pre-check marked `skip unchanged` that
would have CHANGED something is logged as `triage-state shadow:
would-have-missed N: <KEY> (<action>)`. Read that line before flipping to
enforce: every entry is a ticket enforce would have kept from the model. "Would
have changed something" comes from the verdict vocabulary (`has_effect` in
`bin/triage-state.py`): `launch` and `escalate` always count (a launch on a
ticket stored `buildable` but skipped as owned is a lost launch being redone,
BH-1174), `close` counts unless the ticket is already `closed`, and any other
action counts when its verdict (`verdict_of`) differs from the stored one. A
ticket skipped as `buildable-owned` / `buildable-held` counts as stored
`buildable`. A `skip` DECISION (`NOOP_ACTIONS`: the model looked and left it,
e.g. BH-3223 "skip :: QUEUED_FLY on pool, still running") and a DECISION that
lands on the stored verdict are no-ops, logged apart as `triage-state shadow:
model-noop-on-skip N: <KEY> (<action>)`.

A DECISION that would have changed something on a skipped ticket with
`decisions.tsv` column 9 = 1 (a queue line or a finished build this tick: the
launch, the defer, the close-out comment and status) is NOT a miss, because
enforce never keeps that ticket from the model. It is logged apart as
`triage-state shadow: work-on-skip N: <KEY> (<action>)` (BH-3774: on in-app
boards these were scored as misses because the work key never matched).

Each miss also logs `triage-state shadow: miss-detail: <KEY>=<gate reason>
...` (the pre-check's reason, e.g. `unchanged:triaged` or
`buildable-owned:build-dir`), and leaves the inputs the pre-check hashed for
that ticket in `state/triage-state/<p>/misses/<UTC stamp>-<KEY>/`:
`world-row.json` (its row of the board fingerprint), `thread.raw` (the thread
it hashed, when cached) and `decision.tsv` (its decisions line). That is what
to diff against what the session saw, to name a field the hash is missing.
Only the newest 50 are kept; shadow only; nothing decides from it.

### Flipping shadow -> enforce

Per project first, then the fleet (settings rows, `PUT /api/settings` or
`bin/harness-ctl.sh set`):

    lib.triage-state.<project>.triage_state_mode = enforce
    lib.triage-state.triage_state_mode           = enforce

Read the shadow lines first: `grep 'triage-state shadow' logs/<p>.log` and
`bin/jobs-client.sh triage-state-list <p>` (the rows' `last_decision`). A
`would-have-missed` line is a real miss; read its `misses/` snapshot
(`ls state/triage-state/<p>/misses/`) before flipping. `work-on-skip` and
`model-noop-on-skip` lines are not misses. Back to
`shadow` (or `off`) is the same row; `switch.triage-state-off = 1` (or
`touch flags/triage-state-off`) stops the pre-check on the spot.

What each tick still paid for unchanged input (`paid_unchanged=N`, the cost-row notes, the 3-tick alert and /costs TRIAGE PAID UNCHANGED): [docs/triage-state/paid-unchanged.md](triage-state/paid-unchanged.md).

## Starvation guard (BH-8475)

`bin/lib/triage-starve.sh`, enforce only. It stops a ticket from staying in the
"to the model" list with no triage run (project-6-os TK-2601: 27 h).

- **The ledger.** `state/triage-state/<p>/starve.tsv`, one row per key in the
  current model set (decisions.tsv `llm`): `key label first_listed passes
  last_run fastpath_epoch fastpath_outcome alerted`. `ts_tick` calls
  `tsv_pass` once per enforce pass with readable rows, before the $0-end
  check, so a $0 tick still counts. A key that leaves the model set loses its
  row; a relisting starts at passes=1. The ledger never holds more rows than
  the model set (the retention rule).
- **The run signal.** A triage run is read from the shard's own files:
  `logs/<p>.triage-<KEY>.out` written since the key was first listed, or a held
  `locks/triage-key-<p>-<KEY>.lock`. A full tick's single session marks every
  listed key run (`tsv_ran_all`). An out file older than first_listed is from
  an earlier episode and does not count.
- **The order.** `ts_tick` reorders `TICK_SCOPE` with `tsv_order_scope`:
  `[HOTFIX] ` lines first, then lines whose key has a ledger row by oldest
  `first_listed`, then every other line (PR lines, REOFFER, UNBLOCKED, unknown
  keys). Ties keep the scope order. The shard units are built in TICK_SCOPE
  order, so `TRIAGE_SHARDS_MAX` and the hour caps cut the youngest keys, not
  the same old ones every pass. `bin/lib/rt/shards.sh` is not edited (BH-3418
  B1). A scoped tick is not widened: a listed key outside its scope is covered
  by the fallback below.
- **The fallback.** A key listed `TRIAGE_STARVE_PASSES` passes, for at least
  `TRIAGE_STARVE_WINDOW_S`, with no run since it was first listed, gets ONE
  `bin/launch-fastpath.sh <p> <label...>` attempt per listing episode (GitHub
  boards; at most `TRIAGE_STARVE_FASTPATH_MAX` keys per pass, oldest first,
  under `timeout TRIAGE_STARVE_FASTPATH_TIMEOUT_S`). An in-app board records
  `n/a: in-app board`. A live builds pause withholds the attempt to the next
  pass.
- **The alert.** One warn `bin/lane-alert.sh` alert per project per pass
  (id `triage-starve-<p>`) names the keys tried and each outcome. A failed
  lane-alert writes one `bin/alert-line.sh` line instead.
- **Knobs** (`catalog/lanes.d/_lib.triage-starve.json`, rows
  `lib.triage-starve[.<p>].<knob>`): `TRIAGE_STARVE_PASSES` (3, 0 = off),
  `TRIAGE_STARVE_WINDOW_S` (7200), `TRIAGE_STARVE_FASTPATH_MAX` (10),
  `TRIAGE_STARVE_FASTPATH_TIMEOUT_S` (300), `TRIAGE_STARVE_LOCK_WAIT_S` (5).
- **Read it.** `grep TRIAGE-STARVE logs/<p>.log`:
  `TRIAGE-STARVE <label> listed <n> passes over <h>h with no triage run — fastpath launched`,
  `... — fastpath declined: <fastpath's own FASTPATH-DECLINED reason>`,
  `... — fastpath declined: fastpath exit <rc>`, `... — n/a: in-app board`,
  `TRIAGE-STARVE withheld <labels>: builds pause`.

## Follow-ups (out of scope here)

- Native GitHub issue dependencies ("blocked by" relations) and sub-issues are
  not read: only `#N` / `KEY-N` references in the thread and the in-app board's
  `blocked` / `parentId` / `dependsOn`.
- A skip writes no $0 `triage-precheck` cost row yet; the lane log and the rows
  are the record.
