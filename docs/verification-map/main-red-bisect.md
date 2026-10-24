# Main-red bisect lane (which merge turned main red)

**What it is:** a hub cron lane, `bin/main-red-bisect.sh` (BH-3696, split child 3
of BH-3685). Every 10 minutes it takes the red episodes on main, proves the red
is real, bisects main's first-parent merges to the one that turned it red, and
hands the verdict to the act functions. It writes one terminal row per episode
to the coordination ledger, so a red is bisected once.

It calls only the BH-3693 contract, never a body of its own:
`mrb_detect_episodes` / `mrb_episode_still_red` (`bin/lib/mrb-detect.sh`),
`mrb_probe` / `mrb_bisect` (`bin/lib/mrb-probe.sh`) and `mrb_act_culprit` /
`mrb_act_notmerge` (`bin/lib/mrb-act.sh`). What an act does (a revert PR, a
ticket, a quarantine) belongs to the act slice, not to this lane.

**Status as of BH-3696:** the lane, its registry entry and its cron line exist.
The contract bodies are still the BH-3693 stubs until their siblings land:
detect writes no episode, so a live tick logs `episodes=0`; a probe answers
`norun`, which is `aborted`; an act answers rc 64, which writes no row and is
retried next tick.

**How an operator reaches it:** no UI. `cron/lanes/721-main-red-bisect.cron`
runs it on the hub behind `bin/hub-lease.sh check`. Off:
`bin/harness-ctl.sh off main-red-bisect` (`flags/lane-off-main-red-bisect`).
Knobs in `catalog/lanes.d/main-red-bisect.json`, settable as
`lane.main-red-bisect.<env lowercased>` rows: `MAIN_RED_BISECT_MAX_STEPS` (8,
probes per episode with P0 and P1), `MAIN_RED_BISECT_MAX_MERGES` (40),
`MAIN_RED_BISECT_SUITE_TIMEOUT_S` (900), `MAIN_RED_BISECT_REVERT` (1),
`MAIN_RED_BISECT_QUARANTINE_MAX` (3), `MAIN_RED_BISECT_PROTECTED_RE`. The last
four are validated and exported for the libs. `MAIN_RED_BISECT_REPOS` (default
`$HARNESS_REPO`) is not settable; any other slug is logged `unsupported`.

**What one episode goes through:**

1. The ledger row `main_red_bisect <slug>@<red>@<12 hex of sha256(sorted suites)>`
   is read FIRST. A row means done. A miss (rc 2) goes on. Anything else means
   the ledger is unreachable: the rest of the repo is skipped, nothing probed.
2. A pending file (`state/main-red-bisect/pending/<16 hex>.ep`) means an earlier
   tick reached a verdict whose act or row write did not finish: re-dispatch it,
   no probes.
3. `outcome=nosuite|noanchor` from detect: one warn, terminal row.
4. P0 probes the suites at green, P1 at red (`green` gives `flake`). P0 red
   gives `notmerge` only when P1 is also red. P0 red with P1 green gives
   `flake` (BH-4318). `norun` at either gives `aborted`. Over `MAX_MERGES`
   candidates gives `bounded` with no bisect. Otherwise
   `mrb_bisect _mrb_probe_at <MAX_STEPS-2> <merges oldest first>`; `found` is a
   `culprit` only when the merge subject is
   `Merge pull request #N from O/<branch>`.
5. `culprit` / `notmerge`: `mrb_episode_still_red` rc 1 gives `stale` and no act.
   Otherwise the episode goes to the pending file, then to the act. The row is
   written only on act rc 0, and `acted=1` goes on the pending file before it,
   so a failed row write is retried alone next tick, never the act.

**How to drive it:**

| what | how |
|---|---|
| every case below, through the real script, the real libs overridden by recording fakes, a real scratch git repo of 12 PR merges | `HARNESS_TEST_SANDBOX=1 bash tests/main-red-bisect.bh-3685-test.sh` |
| off flag and a non-hub box make no call | cases C-off, C-nothub |
| an unsupported repo, detect rc 75, a ledger 503 | C-unsupported, C-forge75, C-ledger503 |
| nosuite / noanchor warn and record | C-nosuite |
| A4: `MAX_STEPS=3`, 12 candidates, bounded, at most 3 probes, only the failing list | C-A4 |
| over `MAX_MERGES`, P0 red, P1 green, norun | C-maxmerges, C-notmerge, C-flake, C-norun |
| a found culprit: `culprit`, `pr=102`, `pr_branch`, `pr_title`, `steps`, the bisect table, the row, `.last`, the log line | C-found |
| a culprit that is not a PR merge, a stale episode | C-nonpr, C-stale |
| act rc 64: no row, re-dispatched without probes, row on rc 0 | C-act64 |
| the second tick on the same red does nothing | C-twice |
| P0 red needs P1 red for `notmerge` (P0 red + P1 green is `flake`, no act); the notmerge ticket says both were probed red | `HARNESS_TEST_SANDBOX=1 bash tests/main-red-bisect-p1-confirm.bh-4318-test.sh` (N1-N5) |

On a live hub: `tail logs/main-red-bisect.log`, and
`bin/jobs-client.sh ledger-get main_red_bisect <key>` for one episode.

**Files it writes on a live box:**

- `logs/main-red-bisect.log`: one line per repo per tick,
  `<ts> <slug> episodes=<n> <key>:<outcome> …` (or `unsupported`,
  `forge-unreachable rc=<n>`, `log-read-failed rc=<n>`, `ledger-unreachable`,
  `act-rc=<n> retry-next-tick`). BH-8223: a failed detect logs
  `log-read-failed` when the last REST status is 2xx (gh refused a log, or a
  read after a 200 broke) and `forge-unreachable` otherwise (000, 4xx, 5xx).
- `state/main-red-bisect/<owner>-<repo>.last`: `outcome= red= green= culprit=
  steps= at=` of the last episode handled, `outcome=none` when there was none.
  A status cell, nothing decides on it.
- `state/main-red-bisect/pending/<16 hex>.ep` and `.bisect`: a verdict whose act
  or row write has not finished. Removed when the row is written.
- `ledgers` row `kind=main_red_bisect` in the coordination DB: one terminal
  outcome per episode, with `green= red= culprit= pr= steps=` as its detail.
- warn alerts through `bin/lane-alert.sh --severity warn --id mrb:<outcome>:<16 hex>`.

**What must never regress:**

- **The ledger is read before any probe**, and an unreachable ledger is never
  read as "no row".
- **No row until the act answers rc 0.** A stub act (64) burns no episode.
- **An act that answered 0 never runs again.** A pending file carrying
  `acted=1` only retries the row write (suite case C-putfail).
- **A pending verdict is never re-probed.** Up to `MAX_STEPS` suite runs each
  tick forever is what the pending file stops.
- **Only a PR merge is ever acted on**; flake, bounded, aborted, stale and a
  non-PR subject dispatch nothing.
- **The probe only runs the failing suites**, never the corpus.
