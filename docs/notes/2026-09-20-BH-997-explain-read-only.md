# Both main-red `--explain` arms are read-only

Doc: TEST-DETERMINISM

**What changed.** `--explain` on both main-red lanes shared one code path with
the live cron tick and differed only in that `log()` also echoed. Everything
each tick does, a dry run did.

`bin/main-red-pr-pair.sh --explain`:

- **Took the lane lock.** `exec 8>"$H/locks/main-red-pr-pair.lock"; flock -n 8`
  ran unconditionally, so a dry run and the `*/10` tick silenced each other in
  whichever order they arrived, and opening the file truncated the one the live
  tick was holding.
- **Pruned the ledger.** `find "$ledger" … -mtime +$LEDGER_DAYS -delete` ran
  before any explain guard.
- **Wrote verdicts.** Every open head with no row got one, computed with
  whatever `MAIN_RED_ERR_RE` was exported in the operator's shell. A head sha is
  immutable, so that row is terminal for `MAIN_RED_PAIR_LEDGER_DAYS` (14 days)
  and the cron lane trusts it — testing a matcher poisoned the real lane.

`bin/main-red-detector.sh --explain` was the worse half, because everything it
writes is fleet-visible: it took its own lock (and that arm's held-lock path is
a bare `exit 0`, so a dry run next to the live tick printed nothing at all),
WROTE `flags/main-red-<slug>` — which IS the merge freeze every lane reads —
PUT the `pause_flags` row that carries the freeze off the hub, paged
`--critical`, and on a repo that had gone green CLEARED the flag and sent the
resolve. An operator asking "what would this say?" froze or unfroze the fleet.

**Now.** In `EXPLAIN=1` mode each script creates only `logs/` (for `log()`),
never opens or flocks its lock, and prints what it would do:

- pr-pair: no `mkdir` or prune of `pr-errors/`/`pairs/`; the rows that exist are
  READ (so the output is what the lane would really say) and fresh verdicts go
  to a `mktemp -d` scratch removed on the way out, printed as
  `WOULD RECORD <slug> <head> :: <job> <err> <time>` next to `WOULD ALERT`.
- detector: `WOULD WRITE` / `WOULD UPDATE` / `WOULD CLEAR` for the flag,
  `WOULD PUBLISH` for the row, `WOULD ALERT(<kind>)` for the page, including the
  once-a-day invisible-repo page that also touches a flag.

Without `--explain` nothing changed: locks taken, prune run, rows and flags
written, rows published, alerts sent.

**Why explain reads instead of recomputing existing ledger rows.** A head with a
row is a head the lane will not ask about again, so recomputing would print an
answer the lane would never produce. `WOULD RECORD` appears only for rowless
heads. An explain mode that deliberately ignores the ledger would be a separate
flag; nobody asked for one.

**What `--explain` still writes.** Its own lines in `logs/main-red-pr-pair.log`
and `logs/main-red.log` (that is what `log()` is), and `logs/gh-pr-list.log` for
a PR list read. No state, no flag, no lock, no row, no alert.

**Proof.** `tests/main-red-pr-pair.bh-997-test.sh` (23 assertions) and
`tests/main-red-detector.bh-997-test.sh` (29) drive the real scripts against a
fake `gh`: a lock held by the test (explain still prints, file bytes unchanged),
`locks/`/`flags/` never created, the ledger snapshotted by size+mtime+sha256
across an explain run, an aged `old.tsv` surviving, `MAIN_RED_ERR_RE='NEVERMATCHES'`
never reaching disk, a seeded freeze flag surviving both a green tick and a
new-red-sha tick byte for byte, no `flag_set` call and no alert — each with a
control case where the plain tick does every one of those things.
