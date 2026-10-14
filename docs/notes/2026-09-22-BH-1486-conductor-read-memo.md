# The conductor stops making the same GitHub read twice

Doc: MERGE-CONDUCTOR

**What changed.** `bin/merge-conductor.sh` now memoises three reads, and one
project can be told to tick less often than the cron fires.

- **`updatedAt` is the open list's 12th tsv column.** It is a `gh pr list
  --json` field and a mappable REST one, so it rides the list read the tick
  already makes — zero extra calls. A list that does not carry it emits `-`,
  which `pr_worker` maps to the empty string and every memo reads as UNKNOWN.
- **The stacked-parent list is read once per tick per (repo, base branch)**
  (`stack_parent_memo`). Two children of one parent branch used to buy the same
  `pulls?state=all&head=owner:<branch>` list twice in the same tick, three
  children three times. The answer is shared through a file under `$MC_TICK_DIR`
  keyed by `$MC_TICK_ID` — the `hotfix_pending_file` shape, because the PR
  workers are concurrent subshells and a shell variable would buy the list once
  per child again. `mc_tick_gc` already collects that directory.
- **The check-run word and the iron-law scan are memoised ACROSS ticks**
  (`read_memo_get` / `read_memo_put`, `state/merge-conductor/read-memo/`), keyed
  on (head sha, `updated_at`, an attempts fingerprint) and bounded by
  `MC_READ_MEMO_TTL_SECS`. `read_memo_gc` drops entries after three days, the
  `mc_pr_files_gc` rule.
- **`MC_TICK_SECS`** holds a project whose last tick started less than that ago,
  above every GitHub read, with one `TICK <p> held … (decision=held)` line.
- **One `READ-MEMO tick=… stack_hits= ci_skipped= scan_skipped=` line per
  project per tick**, next to the existing `gh-etag lane=merge-conductor:<P>
  fetched= cached=` line. Those two together are the read ledger.

**Why the check-run memo is terminal-only, and why that is a deliberate
departure from the ticket's wording.** The ticket says: when a head's sha and
the PR's `updated_at` are unchanged since the last tick, do not re-read its diff
or its check-runs. That is right for the diff and wrong for the check-runs,
because **GitHub does not bump `updated_at` on check-run or status events** — it
bumps it on commits, comments, reviews, labels and base/state edits. Taken
literally the rule would leave a `WAIT_CI` row blind to its own CI going green
until some unrelated event touched the PR, which is a decision-path change the
acceptance forbids. So:

- only `green` and `red` are stored. `pending`, `none` and `unavailable` are the
  answers that change without anybody touching the PR, and they are read every
  tick exactly as they are today;
- `MC_READ_MEMO_TTL_SECS` (900 s, three cron fires) bounds how long a re-run
  somebody started from the Actions UI on an unchanged head can stay invisible;
- the **attempts fingerprint** — how many `<kind> <key> <head>` lines
  `state/merge-conductor/attempts.txt` holds for this (PR, head) — invalidates
  the entry the moment the conductor itself touches CI on that head (a kick, a
  rerun, a red mark, a restack). It is computed BEFORE the read, so a marker
  this same worker appends a few lines later already changes the number the next
  tick compares against;
- `MC_READ_MEMO=0` is the operator kill switch.

**What is never stored, and why each one is load-bearing (D11).** An answer for
a PR whose `updated_at` is unknown: there would be no second key to invalidate
it on, so absent must not read as unchanged. A `NONE` from a stacked-parent
read: `mc_stack_parent` answers NONE both for "there is no parent PR" and for
"GitHub would not tell us", so caching it would cache a refusal and keep a child
waiting on it for the rest of the tick. A scan whose diff came back
`DIFF_UNREAD`: an unread diff is not a clean diff, which is the whole of BH-784.
A memo file that is not exactly one line of five fields is a miss, not a hit.

**Why the stack memo's lock is a deadline and not a queue.** `flock -w 20` on fd
8 (6 is the hotfix marker, 7 the git lock, 9 the PR's own), around ONE list
read. A worker that cannot get it inside 20 s reads unmemoised — today's
behaviour — and never waits on a sibling worker's lifetime. The suite drives
exactly that: a stub that holds the read past the timeout, and both children
still classify in the same tick.

**Why no metrics line on a hold.** `mc_tick_metrics` rewrites
`state/merge-conductor/tick-<p>.json`, and `started_at` is what the hold's age
is measured from. A hold that stamped it would hold the project for ever. A
missing or unparseable row means the project ticks — fail open, the
`main_red_flag` rule.

**Why the knob is `mc_tick_secs` and not `tick_secs`.** The registry derives a
settings key from the env name (`lane.<id>[.<project>].<env lowercased>`,
`bin/lib/lane-gate.sh`), and every conductor knob is `MC_`-prefixed, so the row
is `lane.merge-conductor[.<project>].mc_tick_secs`. The hub cron is already
`*/5`, so the knob can only LENGTHEN a project's cadence, never shorten it below
five minutes.

**What is NOT in this change, named so nobody builds it by accident.**
`mc_ci_state` and `mc_ci_flake_runs` still read `actions/runs` through a bare
`gh api`, not `gh_rest`, so those reads can never answer 304 whatever the ETag
cache does — the memo, not the cache, is what takes them off the budget.
Converting them is its own ticket: it would change the call shape the existing
`tests/mc/classify-test.sh` and `tests/merge-conductor-test.sh` stubs are written
against, and the acceptance for this one says those suites stay green untouched.
The per-call REST ledger (#1484) has no PR yet either, so the before/after
numbers come from the BH-1295 `gh-etag lane=merge-conductor:<P>` counters plus
the new `READ-MEMO` line.

**What it touches.** `bin/merge-conductor.sh`,
`catalog/lanes.d/merge-conductor.json`, the new suite
`tests/conductor-read-memo.bh-1486-test.sh`,
`docs/verification-map/conductor-read-memo.md`,
`docs/verification-map/entries/BH-1486.md`, and this note.

**Operator note.** No env var needs setting anywhere: all three knobs keep
today's behaviour as their default (`MC_TICK_SECS=0`, `MC_READ_MEMO=1`,
`MC_READ_MEMO_TTL_SECS=900`). They are settings rows, e.g.
`bin/jobs-client.sh setting-set lane.merge-conductor.project-5.mc_tick_secs 600 "BH-1486"`.
`lane_env_apply merge-conductor` already runs before the lane body, and the
cadence knob is read per project through `lane_knob merge-conductor MC_TICK_SECS
"$P"`, so a project row reaches it.
