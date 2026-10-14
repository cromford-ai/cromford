# The conductor's attempts go through the row helpers, and a wake can key a tick

Doc: MERGE-CONDUCTOR, EVENTS

BH-1387 (BH-1025.2). Both halves are dark. With `flags/pr-state-rows` absent and
`WAKE_CONDUCTOR_KEYED=0`, the conductor and the wake loop behave exactly as they
did before.

## What changed

**Attempts.** Every PR-keyed `attempts.txt` presence read and single-line write
in `bin/merge-conductor.sh` and `bin/lib/mc/{classify,queue,rebase,settle}.sh`
now goes through `mc_attempt_has` / `mc_attempt_put` (`bin/lib/mc/locks.sh`,
BH-1385). That's 86 sites. The file is still written first and read first. With
the flag up, a file miss asks `pr_attempts`, and a row hit warms the line back
into the file. An outage never reads as "already attempted".

**State events.** `mc_ledger_put` (`bin/lib/mc/settle.sh`) appends one
`pr_state_events` row after the `ledgers` row, when `pr_rows_on`. Both of its
callers come through it: `mc_transition` for a transition, and
`mc_budget_check` for the alert mark. So an alert event carries the same state
and since as its transition, plus the new `alerted`. `bin/lib/mc/log.sh` is not
edited. The write order is file, then `ledgers`, then event. A failed event
POST changes nothing upstream.

**Rehydrate.** With the flag up, `mc_rows_rehydrate` tries the `pr_state` view
first (`mc_rows_rehydrate_view`). It pages by id under the same
`MC_REHYDRATE_PAGES` cap and writes the file's eight columns, `alerted` sixth
and `since` as an epoch. An empty or unreachable page, or a cap hit with pages
still outstanding, drops everything it read, logs
`pr_state view empty/unreachable … falling back to ledgers`, and runs the old
`ledger_page pr_state` path unchanged.

**Keyed tick.** `bin/wake-loop.sh` collects the `owner/repo#n` keys of the
`pr`/`checks` wakes it drains. A key of `-`, empty or not all digits adds
nothing. With `WAKE_CONDUCTOR_KEYED=1` the one conductor launch per drain gets
them as `MC_ONLY_PR`, labelled `pr/checks[<keys>]`. The cap and cooldown are
unchanged. The held-launch line now ends `(the cron sweep still covers it)`.

`bin/merge-conductor.sh` parses `MC_ONLY_PR` once and logs
`keyed tick: <n> key(s) — <keys>`. On a keyed tick it:
- skips projects whose repo has no key (no token, no list read, no metrics line)
- keeps only keyed rows of the open and closed lists
- skips the LAND fan-out (the land sha is neither read nor advanced) and the
  batch-resolve spawn
- skips the main-red detector, every `*_gc` and `mc_dv_reap`
- never writes `tick-<p>.json`, so a wake cannot push back the cadence hold
  (BH-1486). It still honours that hold.

Per-PR locks and per-tick budget files are unchanged. A value with no valid key
logs `MC_ONLY_PR ignored: …` and runs the full tick.

## Round 2: the neighbours main landed after round 1

- **Closed-watch memo (BH-1592).** `closed_watch_seen` and `OPEN_NUMS` run on
  the unfiltered open list, before the keyed filter, so an open PR the tick
  doesn't own is never read as a closed candidate. A keyed tick still probes
  and settles its own keys. Every other candidate the probe found closed goes
  back through `closed_watch_reoffer` to "never probed", so the next cron tick
  settles it. The memo never says `closed` about a PR nothing settled.
- **Held-page flush (BH-1382).** `mc_hold_tick_begin` is a fleet-wide sweep
  with no PR lock, so a keyed tick skips it (`[ -z "$MC_ONLY_KEYS" ]`) and it
  stays with the cron tick. Two overlapping ticks can't both flush one held row.
- **The flush's alert mark emits an event.** `mc_state_event_put` (settle.sh)
  is the event half of `mc_ledger_put`, pulled out so `mc_hold_flush_one`'s
  BUDGET arm can call it right after its `mc_row_put`. The order is file row,
  then event. That arm never wrote a ledgers row and still doesn't, so with the
  flag off nothing changes.

## Sites that stay file reads on purpose

| site | why |
|---|---|
| `mergetree` writer, `bin/merge-conductor.sh` (next to its `grep -cxF` reader) | count semantics |
| `mergefail` writers (3, each on a line with its `grep -c`) | count semantics |
| `REDS=$(grep -c "^red …")`, `EJN=$(grep -cE …)` | counts; the `red`/`ejected`/`reejected` presence checks do go through the helpers |
| `requeued`, `cirerun`, `apread` writers in `bin/lib/mc/classify.sh`, and their awk readers | timestamped lines read by awk |
| `identityalert` in `bin/merge-conductor.sh` | not PR-keyed; inside a `$( )` under `$MC_ATTEMPTS.lock` |
| `mc_rr_lanefail_note` and the line-removal block in `bin/lib/mc/locks.sh` | locks.sh is the contract's file and is not edited here |
| `touch "$MC_ATTEMPTS"` in `mc_init` | creates the file |

`dvread`/`dvstale` (`bin/lib/mc/rebase.sh`), `queue-inactive <slug> <day>` and
`<not-harness> KEY` go through the helpers, but they are not keyed on a PR, so
`mc_attempt_pr_key` keeps them file-only at runtime.

## Operator steps

- Rows on: `bin/jobs-client.sh flag-set pr-state-rows on "BH-1387"`.
- Keyed wake launches: the settings row `lane.wake-loop.wake_conductor_keyed`
  set to `1` (`lane_env_apply wake-loop` runs before the knob is read), or
  `WAKE_CONDUCTOR_KEYED=1` in `env/global.env`. It is registered in
  `catalog/lanes.d/wake-loop.json` (int, default 0, 0..1).
- Check a keyed tick: `grep 'keyed tick' logs/merge-conductor.log`, and
  `grep 'pr/checks\[' logs/wake-loop.log`.

## Tests

`tests/pr-attempts-idempotent.bh-1387-test.sh`,
`tests/conductor-wake-keyed.bh-1387-test.sh`.
