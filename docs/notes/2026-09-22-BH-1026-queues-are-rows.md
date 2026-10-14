# BH-1026.0 (BH-1364): the queues-are-rows contract — three dark knobs, one shared active-key read

**What this is.** The interface slice of #1026, landed first and deliberately
small so the three sibling slices can be built at the same time instead of
queueing behind each other. It ships the schema and the readers; it changes no
lane's source of truth. Every flag it adds seeds `'0'`, and at `'0'` the fleet
behaves byte for byte as it did the day before.

**Why the split needed a contract slice.** Two facts more than one sibling
needs had to be written once: `worker/jobs/schema.sql`, which three siblings
would otherwise all edit, and the `ACTIVE_KEY` read that exists TWICE — in
`bin/run-build.sh` and in `bin/lib/rb/gates.sh`. Changing one and not the other
is two answers to one question, and both of those reads are DEDUPE guards: the
answer they get decides whether a second Fly machine is spawned for a key that
is already building. That is the TK-70 shape, and it is why the read is now one
helper with both call sites in this same diff (D27).

**What changed.**

- `worker/jobs/schema.sql` — a `deploy_queue` table keyed `(project, sha)` plus
  `idx_deploy_queue_status`; a nullable `machine TEXT` on the
  `build_queue` CREATE; three `INSERT OR IGNORE` settings rows seeded `'0'` —
  `build_queue_rows_only`, `merge_queue_rows_only`, `deploy_queue_rows`. All
  additive, all `IF NOT EXISTS`, no `ALTER` and no `DROP` anywhere in the file.
  It ships APPLIABLE: `bin/harness-sync.sh` applies each statement before
  `wrangler deploy` and skips the deploy if one fails, so there is no "re-run
  the schema by hand" step (BH-1000's rule).
- `worker/jobs/src/lib/core.js` — `ADDED_COLUMNS.build_queue = [["machine","TEXT"]]`.
  The CREATE reaches only a FRESH database; D1 has no `ADD COLUMN IF NOT EXISTS`,
  so this map is the only thing that can widen the live table, exactly as it is
  for `lanes` and `box_status`.
- `worker/jobs/src/routes/queue.js` — `POST /api/queue/claim` accepts an
  optional `machine` and records it on the row it CASes to `claimed`, running
  `ensureColumns` BEFORE the CAS so a machine the caller sent can never be
  dropped by a missing column. With no `machine` in the body there is no PRAGMA,
  no ALTER and no statement naming the column. `GET /api/queue` needed no
  change: it is `SELECT *`. The release (`PATCH … status=queued`) and the
  re-queue both CLEAR the column — see below.
- `bin/lib/jobs/queue.sh` — `build_queue_rows_only_on`, `merge_queue_rows_only_on`
  and `deploy_queue_rows_on`, each one line through the existing `_flag_on_row`
  (row → documented env → `0`, a real answer memoised, an outage never memoised);
  `build_queue_active_key <project> [key]`, printing `ticket_key<TAB>machine`
  (`-` when the row has none) and rc 1 with empty stdout when nothing is active;
  and an optional 4th `machine` argument on `queue_claim`, omitted from the body
  when empty. `queue_claim`'s output TSV is unchanged — existing parsers read its
  four columns positionally.
- `bin/run-build.sh` and `bin/lib/rb/gates.sh` — both `ACTIVE_KEY` reads now
  call the helper behind `command -v`, passing the KEY this launch is about, so
  an unarmed box with no client on PATH stays on today's `jq -r '.key // ""'`.

**The one judgement call worth recording.** `build_queue_active_key` is
ROW-FIRST-THEN-FILE, never row-authoritative. With the flag on and a reachable
worker that reports no `claimed` row, it still reads
`state/fly/<p>-active.json`. The ticket pins the row case and the outage case
but not that one, and the parent's Rules line decides it: *keep the file as a
write-through cache for one full cycle before deleting the file read.* Nothing
writes a `claimed` row for the fly lane until a sibling slice lands, so an empty
answer from a reachable worker is not evidence that nothing is building — and
treating it as one would switch the dedupe guard off the moment an operator
flipped the knob.

**The read is KEYED, and that is what makes it the same question the call sites
ask.** Both guards test `[ "$ACTIVE_KEY" = "$KEY" ]`, so a project-wide answer is
a different question wearing the same variable name. The file holds the ONE
non-pool fly job; `claimed` rows are written for every local build and every
pool machine, and `GET /api/queue` returns the OLDEST claimed row first — which,
among claims, is the one most likely to be a dead build the watchdog has not
swept for up to six hours. Armed with a project-wide read, a stale claim for
`TK-1` would mask the live `TK-9`, `ACTIVE_KEY` would not equal `KEY`, and the
hub would spawn a second Fly machine for a ticket already building: duplicate
machine-minutes and model spend, two sessions racing one branch. So the row read
is `&key=<key>`, and the unkeyed form is a UNION of the rows and the file (one
line per active key) — a row answer may only ever ADD an active key.

**`machine` belongs to the claim, not to the ticket.** A released row and a
re-queued row both have it cleared, so a `claimed` row names the machine of the
claim that set it or names none. Otherwise a dead machine's id survives the 6h
watchdog release into the next claim (every local claim sends none) and the row
reads "claimed, and here is where" while pointing at a machine that is gone or
recycled. A terminal row keeps the id as ledger; the re-queue clears that one.

**The machine validator is a shape check, not `str()`.** `String(v)` turns
`{"a":1}` into `"[object Object]"` and `[1,2]` into `"1,2"`, both inside any
length bound, and a coerced id is a WRONG id — the class the over-long case was
already refused for. Only `[A-Za-z0-9._:-]{1,64}` is recorded; anything else
records nothing and the claim still lands, because the guarantee is "never the
wrong machine", not "always a machine". The response echoes what was recorded.

**The `deploy_queue` primary key is a deliberate change of identity, not a copy
of the file store's.** `state/deploy-queue/<p>/<epoch>-<sha8>` is one file per
REQUEST carrying `<merge-sha> <build-dir>`, so the same sha asked for twice is
two files and the train departs on both. `(project, sha)` collapses that to one
row on purpose (departing twice on one sha is a double-move), and the collapse
imposes a writer contract the siblings must honour: a repeat request RE-OPENS
the row — `status` back to `queued`, `departed_at` and `reason` cleared — and is
never an `INSERT OR IGNORE`. The case that forces it is `bin/deploy-train.sh`'s
self-sourced departure, which fires exactly when a sha departed `done` and
production is still not serving it; an ignore there drops the retry and leaves
production stale with no departure and no alert. Both halves are pinned by a
test in this diff.

**Three knobs and not one**, for the same reason the slice exists: the siblings
land as separate PRs, and a single shared `queues_are_rows` row would arm a lane
whose PR had not merged yet.

**What is still owed (the siblings, not this PR).** Nothing reads the three
knobs yet except `build_queue_active_key` reading its own, nothing writes a
`deploy_queue` row, and nothing sends a `machine` on a claim. Those are the
three sibling slices of #1026. The readers are pinned by tests here regardless,
so none of it is untested code.

**Tests:** `worker/jobs/test/schema-deploy-queue.bh-1026.test.js` (the shipped
SQL against real `node:sqlite` behind the D1 shim, the column migration, and the
claim route driven through `worker.fetch`) and
`tests/queue-rows-flags.bh-1026-test.sh` (the three readers, the helper, both
`ACTIVE_KEY` blocks EXTRACTED from their real scripts and executed, and
`queue_claim`'s body). `tests/jobs-client-modules.bh-1194-test.sh` records the
four new exports; its header comment said "134 functions" while the map held
165, so that number is corrected to 169 in the same diff rather than to the 138
the stale count implied.

Doc: DB-COORDINATION-SPEC, MERGE-CONDUCTOR
