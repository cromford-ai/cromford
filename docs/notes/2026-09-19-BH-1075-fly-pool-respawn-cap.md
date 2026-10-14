# BH-1075 — Fly pool no longer re-spawns a ticket whose push was rejected

**What changed:** `bin/fly-pool.sh` now treats a *push-rejected*
`BUILD_DEFERRED push of ticket/<key> rejected ...` as a terminal outcome for
the pool lane instead of re-queueing it. The dispatcher writes
`state/pool/<project>/<key>.terminal` with the remote branch head SHA, leaves
the queue file removed, and stamps `TERMINAL` + `COMMENTED` sentinels in the
build dir so close-out sweeps do not page for it.

Every new pool spawn is now gated in `pool_spawn_decision` by, in order.
The same decision also runs on the machine-REUSE handoff in
`next_job_or_destroy`: that path hands a queued row straight to the machine it
just reaped, which is a build metered exactly like a spawned one, so a gate
that covered only fresh spawns left a back door open for every row below.

**A rebase row is exempt from all four.** `bin/merge-conductor.sh` enqueues its
pool rebases as `RB-<pr>-<head8>` rows whose `ticket_id` is a PR *number*.
Read as an issue, a PR carries no `ai-build` label, and `hold_classify` answers
`held label-absent` for anything without it — so gating rebase rows would skip
every one of them on every tick and stall the merge conductor's pool-rebase
lane fleet-wide at `MC_REBASE_POOL_TIMEOUT_SECS`. The other three are equally
wrong for a rebase (an open PR is the point of one; the terminal file is keyed
on a ticket branch; the cap's refusal deletes the queue file without failing
the row, so the conductor's view and the pool's would disagree). `RB-*` spawns
exactly as it did before BH-1075, and `spawn_one` records no cap entry for it.

1. **HOLD** — sourced from `bin/lib/hold.sh`; a held ticket skips the spawn and
   the queue file is left in place for the next tick.
2. **Open PR** — one REST lookup per key per tick for a PR whose `head` is
   `<owner>:ticket/<key-lower>`; if one exists, the ticket is commented once,
   the queue file is removed, and the spawn is skipped.
3. **Terminal state** — if a `.terminal` file exists and the remote head is
   unchanged, the spawn is skipped **and the queue file is kept**, which is what
   makes the re-arm reachable through the pool's own state: the next tick reads
   the head again off the same row. A changed remote head, or an explicit human
   re-arm comment, removes the terminal file and re-arms exactly one spawn.
   Two things deliberately do *not* re-arm: a terminal recorded with
   `head_sha=unknown` (the head read failed at reap time — the next readable
   tick records the real sha rather than reading it as a change), and any
   comment that is not an explicit, capitalised `RETRY` / `REBUILD` / `RESUME`
   / `UNHOLD` with no negation in front of it. Every comment this harness posts
   with the PAT is `user.type: "User"`, so a bot filter alone would have let the
   harness re-arm its own terminal — the incident `bin/lib/hold.sh`'s lift
   vocabulary exists to prevent, here at the price of a machine.
4. **Per-key spawn cap** — at most `pool_spawn_cap_per_key` spawns per key in
   `pool_spawn_cap_window_s` (default 2 / 86400). When the cap is reached the
   queue file is removed and a `POOL_DEFER_TO_HUMAN` line goes to
   `logs/ALERTS.log` — **once**, gated on a `.defer-to-human` sentinel. The
   refusal itself repeats (the ledger watchdog requeues a claimed-and-abandoned
   row and the cap refuses it again) and says so in `logs/fly-pool.log` every
   tick; the page is the interrupt and fires once per key. The sentinel is
   cleared as soon as the key is under the cap again, so a later trip pages
   afresh rather than being muted for the life of the box.

All four gates read GitHub, so **not configured is not unreadable**. The gates
apply only when `pool_gates_applicable` finds all three: an `owner/repo` in
`fleet.conf`, `gh` on PATH, and one cached probe read per tick that comes back
with an HTTP status line at all. A logged-out or network-less client exits
non-zero with no status line — it never made a request, so there is nothing to
fail closed on, and the tick spawns exactly as it did before this change with
one line saying so. A read that *was* made and came back 403 or 404 still fails
closed and skips the spawn for that tick.

**Why:** A branch that had drifted ahead on the remote produced a
`BUILD_DEFERRED push rejected` and was re-queued like any other stand-down.
The pool then spawned a new machine for it every two minutes until a human
noticed. The fix makes this outcome terminal and adds the gates that prevent
the same class of retry-loop elsewhere.

`hold_check` arms the repo's App installation token and says the caller owns
the reset, so `pool_hold_check` resets it (`gh_default_auth_reset`, else
`gh_auth_reset`) the moment the read returns: every later read in the tick runs
on the identity `gh_default_auth_for_project` declared (BH-470).

**What it touches:** `bin/fly-pool.sh` (new helper functions, the deferral
branch, the spawn-decision gate in the launch loop and in the reuse handoff,
and per-key spawn recording in `spawn_one`). It also adds
`tests/fly-pool-respawn-cap.bh-1075-test.sh`,
`docs/verification-map/fly-pool-respawn-cap.md`,
`docs/verification-map/entries/BH-1075.md`, and this note.

**Operator surfaces:** `logs/fly-pool.log`, `logs/ALERTS.log`,
`state/pool/<project>/<key>.terminal`, `.spawns`, `.pr-noted`, and
`.defer-to-human`.

Doc: FLY-POOL-RESPAWN-CAP
