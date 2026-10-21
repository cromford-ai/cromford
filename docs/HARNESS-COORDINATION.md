# Cross-harness coordination — the lock service (2026-08-01)

Two harnesses work project-10: ours (box fleet) and reviewer-1/partner's
fork (project-10-sdlc-agent). Collisions are prevented by a shared LEASE service, not
JIRA state (JIRA writes are slow, rate-limited, and human-facing).

Service: https://harness-locks.operator.workers.dev (Cloudflare worker + D1, own
deployment, zero coupling to the console). Auth: per-harness bearer token.

## Contract
- POST /v1/acquire {kind:"ticket"|"file", key, ttl_s} → 201 {lease_id, expires_at}
  or 409 {holder, expires_at}. Re-acquire by the same holder renews (idempotent).
- POST /v1/renew {key, lease_id, ttl_s} → 200 | 404 (expired/stolen — STOP work).
- POST /v1/release {key, lease_id, outcome} → 200. Outcome is free text (pr/blocked/skipped).
- GET /v1/locks?prefix=project-10: → active leases (triage filters available tickets).
- Keys: "project-10:<JIRA-KEY>" (project-10) plus "project-1:TK-<n>", "project-2:TK-<n>", "project-3:TK-<n>", "project-4:TK-<n>" — the partner harness confirmed building on ALL boards (2026-08-01) — for tickets; "project-10:<repo>:<path>" reserved for file claims.
- TTLs: clamp 60s..24h. Expiry = available again automatically (crash-safe; no janitor).

## Our side takes the lock in code (2026-10-20)
Every build on our side acquires `<ns>:<KEY>` in `bin/lib/rb/gates.sh` right after its
ledger claim (`bin/lib/ticket-lock.sh`; ns project-3 / project-2 / project-4 / project-1), renews it every
10 min, re-checks it before every push and PR open (a lost lock yields: nothing pushed),
and releases it from the EXIT hook with outcome pr / skipped / blocked. A 409 defers the
build (`BUILD_DEFERRED ticket lock <key> held by <holder>`); a lock-service outage is an
ALERTS line and the build goes on. Before this only the triage prompt asked for the lock,
and TK-249 (2026-10-04) was built by both harnesses. Pool machines get LOCKS_URL and
LOCKS_TOKEN through bin/fly-envbundle.sh. All our machines share that one token, so to
the lock service they are ONE holder: the lock keeps partner and us apart, and our own
ledger claim (job_open) keeps our machines apart. Because the worker gives a NEW lease id
whenever the same holder acquires, a renew 404 re-acquires the key: 201 = still ours,
409 = lost. Release is by key (the worker deletes only our holder's row).
Known gap: a pool build is QUEUED_FLY by the watcher before the acquire; from dispatch to
machine start only triage's 2 h lease covers the ticket. A pool wait longer than that
can reopen the TK-249 race until the dispatcher takes the lock too.

## Protocol (both harnesses, inside triage)
1. Before deciding to build a ticket: acquire project-10:<KEY> (ttl 2h).
2. 409 → skip the ticket this pass (it's the other harness's).
3. While building: renew on the heartbeat (builds >2h).
4. On terminal outcome (PR opened / blocked / skipped): release with outcome.
5. A 404 on renew means the lease expired and may have been taken: abandon
   gracefully — do not push branches for a ticket you no longer hold.
6. Branch naming: keep ticket/<key> BUT never push if you lost the lease (5).

Env on our boxes: LOCKS_URL + LOCKS_TOKEN in env/global.env. reviewer-1's fork:
same two vars, token issued by the operator. Rotation: reissue via the HARNESS_TOKENS
worker secret (JSON {token: harnessName}). CANONICAL COPY of the mapping lives on
the hub at /root/harness/env/locks-tokens.json (chmod 600) — update it FIRST,
then `wrangler secret put HARNESS_TOKENS < that-file`; the secret is write-only
at CF, so the local file is the only recoverable record. Per-person tokens for
the partner team since 2026-08-04 (partner-collaborator-1, partner-reviewer-1) — a shared
token makes two machines the SAME holder, so both can hold one ticket lock
(re-acquire-renews) and duplicate work.

Worker source: /root/harness-locks on the hub (wrangler deploy; CF token in
env/cloudflare.env). D1: harness-locks (2738f953-…).

## Minted machine tokens (2026-08-05, partner night-lane ask)

Second auth lane beside the static HARNESS_TOKENS secret: named, expiring,
revocable per-machine tokens in the D1 `tokens` table. Only sha-256 hashes are
stored — the mint response is the ONLY time a token is readable. Admin calls
ride the separate ADMIN_TOKEN worker secret (hub copy: LOCKS_ADMIN_TOKEN in
env/global.env); a minted token can never mint or revoke.

- Mint:   `POST /v1/admin/tokens {"name":"partner-office-1","ttl_days":90,"created_by":"…"}`
          → `{id, name, token, expires_at}` (name = the lock holder identity;
          one name per machine — a shared name makes two machines one holder).
- List:   `GET /v1/admin/tokens` (hashes never returned; shows last_used_at).
- Revoke: `POST /v1/admin/revoke {"name":…}` (all of that name) or `{"id":…}`.
- ttl_days clamps to 1–365, default 90. Expired/revoked tokens 401 like any
  bad bearer. Mints/revokes are logged in locks_log as token-mint/token-revoke.

First minted (2026-08-05): partner-office-1, partner-office-2 — 90d, delivered to
collaborator-1 via the operator; their machines use the same LOCKS_URL + their own token.

## Minter lane (2026-08-21, collaborator-1 self-serve ask)

Scoped delegation so partner can mint their own machine tokens without holding
the master ADMIN_TOKEN (which is never handed outside — it can revoke OUR
tokens and mints without attribution):

- A token with `role='minter'` + a `prefix` (e.g. `partner-`) authenticates to
  the admin endpoints but is CONSTRAINED: mints machine tokens only (never a
  minter), only names under its prefix, revokes/lists only under its prefix,
  capped at MINT_CAP mints per rolling 24h (worker var: deployed value 20,
  pinned in `locks-worker/wrangler.jsonc` `vars`, raised from 5 on 2026-10-07
  after the shared `partner-minter-collaborator-1` minter hit the cap; the code fallback
  when the var is unset is 5). It cannot hold leases (role check in the lease
  lane), is itself expiring (<=365d) and
  revocable by name like any minted token: `POST /v1/admin/revoke
  {"name":"partner-minter-collaborator-1"}` kills the delegation instantly without
  touching their machines' existing tokens.
- Only the master ADMIN_TOKEN can mint minters:
  `POST /v1/admin/tokens {"name":"partner-minter-collaborator-1","role":"minter","prefix":"partner-","ttl_days":90}`.
- `GET /v1/admin/log?since=&action=` (master only) feeds
  `bin/locks-mint-digest.sh` — daily hub cron, ONE consolidated beat when any
  token was minted/revoked in 24h, so delegated minting is never invisible.
- Worker source is CANONICAL in cromford `locks-worker/` (kept in sync
  with /root/harness-locks on the hub; deploy needs
  CLOUDFLARE_ACCOUNT_ID=00000000000000000000000000000000 — the CF token sees
  多accounts and wrangler refuses non-interactively without it). Tests:
  `locks-worker/tests/minter-test.sh` (16 assertions, red-first proven).
- First minter minted 2026-08-21: `partner-minter-collaborator-1` (prefix `partner-`,
  90d), delivered to collaborator-1 via the operator.

---

# The harness-jobs coordination API — contracts this fleet depends on

The lease service above coordinates us with ANOTHER harness. The section below
is about coordinating our own machines with each other through `harness-jobs`
(`worker/jobs/`, client `bin/jobs-client.sh`, schema and rationale in
docs/DB-COORDINATION-SPEC.md). It is here because the two answer the same
question — "may I start this work?" — and an operator debugging a duplicate
build should find both in one place.

## The build-queue claim (the conditional write, 2026-09-14)

At 4000 builders the same queued ticket key can be offered to any machine in the
pool, so "am I already building this?" cannot be answered by a file on one box
(docs/BUILD-CONCURRENCY.md, "The dedupe that only saw one box"). It is answered
by a **compare-and-swap on the row**, and this is the contract:

```
POST /api/queue/claim  {project, box, key}
  200 {queued:{…, status:"claimed", claimed_by:<box>}}   you own it
  409 {refused:true, scope:"queue", reason:"…"}          someone else got there
  404 {error:"nothing queued"}                           no such queued row
```

The worker takes the row with `UPDATE … WHERE project=?1 AND ticket_key=?2 AND
status='queued'` and reports `changes` — so the **expected status is part of the
write**, not a read-then-write the next caller can slip between.
`bin/jobs-client.sh:queue_claim` maps those to `rc 0 / 9 / 2`, and rc 1 for an
outage.

**A KEYED claim refuses; an unkeyed one walks on.** A caller that asked for "the
next build" and got a 409 would skip a whole tick while other work sat queued
behind the row it lost, so an unkeyed claim tries the next candidate (bounded at
5). A caller that named a key wanted *that* row: it gets the 409. `bin/run-build.sh`
always names its key, and with `BUILDER_DIRECT` armed a 409 is a clean
`BUILD_DEFERRED` — the row stays `queued` for whoever won it and this ticket is
re-offered next tick. Never an error, and never a second PR.

**What a 409 does NOT tell you.** It proves another claimant holds the row. It
does not prove that claimant is alive: a machine lost between claim and close
leaves the row `claimed` for ever, which is `bin/jobs-watchdog.sh`'s job
(`queue_stale` → `queue_release`) and not the claimer's.

**The transition graph is the guard on the PATCH side too.** `PATCH /api/queue`
runs the same status through `QUEUE_TRANSITIONS` and answers 409 on an illegal
move, so a close-out cannot walk a row backwards out of `done`.

## Endpoints this client calls that the worker still owes

`bin/jobs-client.sh` is fail-open by construction: a route the worker does not
serve is a 404, which prints nothing and returns nonzero, and every caller
carries on with the file path it has always had. That makes it safe to ship the
client first — and dangerous to leave the list unwritten, because an inert call
looks exactly like a working one from the outside. So:

| call | route owed | contract |
|---|---|---|
| `wake_put <repo> <kind> <key>` (2026-09-14) | `POST /api/wakes` | Body `{repo, kind, key, actor}`. Insert into the same `wakes` table the GitHub receiver writes, with the same two properties or it is not the same table: **identifiers only** (no titles, branches or claims about state — docs/EVENTS.md §3) and **idempotent on `(repo, kind, key, minute)`**, `ON CONFLICT DO NOTHING`, answering `{duplicate:true}`. Authed like every other lane route (bearer `HARNESS_SECRET`), never the webhook signature. |

Until that route lands, `wake_put` removes nothing and breaks nothing: the merge
conductor is still rung on the same PR by GitHub's own `pull_request` delivery
(docs/EVENTS.md §5.1).

## Pauses (BH-1672)

A pause stops one kind of work (`reviews`, `merges`, `builds` or `triage`) for
the fleet or for one project, with a reason, an actor and an expiry. It is a
row, not an env edit, so the console can show it and it ends on its own.

- **The store.** The jobs worker's `pauses` table (`worker/jobs/schema.sql`),
  with one live row per `(scope, what)` (`pauses_live`, `WHERE ended_at IS
  NULL`). `scope` is `fleet` or a project name.
- **The wire contract.** `GET /api/pauses?active=1|0&scope=`, `PUT
  /api/pauses`, `POST /api/pauses/:id/end` and `POST /api/pauses/expire`, as the
  header of `bin/lib/pause.sh` describes them. **Not yet deployed:** the routes
  are a BH-1672 sibling's work.
- **The box cache.** `state/pauses.json` holds the GET body verbatim and is
  overwritten whole by `pause_refresh`. The refresh body, the operator CLI
  `bin/pause.sh` and the `PAUSE_EXPIRED` logging of rows that expire are sibling
  **BH-1683, not yet merged**; until it lands `pause_refresh` is a no-op stub.
- **Reading it.** Only through `bin/lib/pause.sh`: `pause_active <project>
  <what>` (a fleet row matches every project) and `pause_label <project>`
  (`PAUSED(<what>,…) `). `bin/lib/pause-rows.sh` adds reason, actor and age for
  the lines that print them, and re-confirms every row with `pause_active`.
  Expiry is judged on every read against `expires_at`. An unreadable cache is
  not paused.
- **Env shapes.** `pause_env_shapes` prints a token for a pause that lives in
  an env value rather than a row, such as `env:review-cap=<n>` for a very low
  `REVIEW_AUTOPILOT_DAILY_CAP`. They are reported (autopilot TICK line, digest)
  and never enforced by the pause code; the cap itself still applies. The body
  is BH-1683's; on this branch it prints nothing.

| what | enforced by | effect |
|---|---|---|
| `merges` | `bin/merge-conductor.sh` | `MERGES=0` (fleet: process-wide, project: that project's subshell); KILL untouched, MODE reads `actions`, TICK lines prefixed `PAUSED(merges) ` |
| `merges` | the merge sweep | skip before the merge call, logged `PAUSED(merges)`, retryable |
| `reviews` | `bin/review-autopilot.sh` | project skipped before the PR list, `TICK <p> PAUSED(reviews) reason=… age=…` |
| `triage` | `bin/run-triage.sh` (`rt_pause_triage`, `bin/lib/rt/gate.sh`) | exit 0 before the job claim, `PAUSED(triage)` |
| `builds` | `bin/run-triage.sh` (`rt_pause_builds`, `bin/lib/rt/gate.sh`) | triage runs; a prompt directive forbids `run-build.sh` launches this tick (not a deterministic block) |
| all | `bin/alert-digest.sh` | one `PAUSED …` line per live pause in the daily beat |

Details and the reasons: [`notes/2026-09-24-BH-1684-lanes-honor-pauses.md`](notes/2026-09-24-BH-1684-lanes-honor-pauses.md).
