# A withheld lead-verdict is NEEDS_HUMAN_VERDICT, not QUEUED (BH-3777)

Doc: MERGE-CONDUCTOR, MERGIFY

## What happened

On 2026-09-30, #3753 and #3758 touched `catalog/switches.d/*-off.json`, a
protected path. BH-3683 withheld the `lead-verdict` status (`la_decide` rc 1),
but `mc_enqueue_mergify` still added the `merge-queue` label and posted
`@mergifyio queue`, so the rows went `READY -> QUEUED`. Mergify waited on
`queue_conditions` for a status only a person could publish. For 17 hours
every surface said QUEUED, the STUCK page said "the alert is the action",
and the one `lead-human-needed` beat was buried among 270 open alerts. Four
stacked children sat in STACKED_WAIT behind them.

## What changed

- **A new conductor state, `NEEDS_HUMAN_VERDICT`** (in `MC_STATES` after
  `BLOCKED_HUMAN`). On a Mergify repo, a row that would classify READY (and
  whose iron-law scan is clean and whose diff was read) first goes through
  `mc_nhv_gate` (`bin/lib/mc/classify.sh`), which calls `la_decide … conductor`.
  On rc 1 the row is `NEEDS_HUMAN_VERDICT`. Its reason is
  `lead-verdict withheld on <sha12>: <LA_REASON> — a human verdict publishes it:
  bin/lead-verdict.sh post <slug> <pr> <full head> MERGE --source human`.
- **No label, no ask.** The row never reaches the READY arm, so nothing is
  enqueued, labelled or asked. Each tick asks again. Once a human verdict
  stands on the head, `la_decide` answers rc 0, the row goes
  `NEEDS_HUMAN_VERDICT -> READY -> QUEUED` and is labelled once.
- **rc 2 is unchanged.** An undecidable authority is not a withheld verdict:
  the row stays READY and `mc_enqueue_mergify` makes its BH-2199 hold.
- **Not the blocked-resolver's.** No hand-off is recorded (only BLOCKED_HUMAN
  writes one). An agent ladder cannot produce a human verdict.
- **Age budget 3600s** (`mc_budget`, one warn page per state entry whose
  text carries the reason), the same hour QUEUED gave these rows.
- **TTL 3600s** (`MC_TTL_NEEDS_HUMAN_VERDICT` overrides it). The STUCK page
  says it is waiting on "a human lead verdict on this head (<reason>)", which
  includes the command. `stuck_rekick` logs "only a human verdict moves it",
  never "the alert is the action".
- **The beat repeats daily.** `la_human_needed` (`bin/lib/lead-authority.sh`)
  sends one more warn beat when its per-(PR, head) marker is older than
  `LA_HUMAN_REBEAT_S` (default 86400), under the id
  `lead-human-needed-<owner_name>-<pr>-<sha12>-r<YYYYMMDD>`, and re-stamps the
  marker only after the send returned 0. The first beat is unchanged. This
  also applies to `bin/lead-review-land.sh`, the other caller. The conductor
  calls it only in actions mode.
- **Stacked children name the parent.** When a child's parent row is
  NEEDS_HUMAN_VERDICT, the child's STACKED_WAIT reason reads
  `based on <branch>; parent #N needs a human verdict (<parent reason>), not
  the project base — …`.
- **Daily digest.** `human_verdict_prs` counts `NEEDS_HUMAN_VERDICT` rows
  beside `BLOCKED_HUMAN`.
- **Paused hold.** In observe or kill-switch mode this state's STUCK and
  BUDGET pages go through `mc_hold_page` like any other. The worker's
  `/api/conductor/held` route checks `state` against its own copy of
  `MC_STATES` (`worker/jobs/src/routes/conductor-held.js`), so the word is
  added there too. Without it the PUT answers 400 and the page is neither
  held nor sent.

## What did not change

`mc_enqueue_mergify` keeps its BH-3683 behaviour for its direct callers (the
console Merge button through `bin/poll-commands.sh`, `bin/rule-adopt.sh` and
the `bin/batch-resolve.sh` train). It withholds the status and still labels
and asks; `tests/lead-authority.bh-3683-test.sh` C1 pins that. Which paths are
protected, and the authority rule itself, are unchanged. Nothing here posts a
human verdict.

The kanban, `fleet_status` and `mcp__harness__pipeline` read the `pr_state`
row this lane writes. They are rendered by the console worker outside this
repo, which now receives the state name and the reason.

Probe: `grep 'NEEDS_HUMAN_VERDICT' /root/harness/logs/merge-conductor.log | tail`.
Proven by `tests/mc/needs-human-verdict.bh-3777-test.sh`,
`tests/mc/stacked-wait-parent-reason.bh-3777-test.sh`,
`tests/lead-human-rebeat.bh-3777-test.sh`,
`worker/jobs/test/daily-digest-nhv.bh-3777.test.js` and
`worker/jobs/test/conductor-held-nhv.bh-3777.test.js`.
