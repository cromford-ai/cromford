# dequeue-watch acts once per (PR, head, class), bounds its fix rounds, and has an LLM fallback (BH-3729)

Doc: MERGE-CONDUCTOR

## What changed

This is slice 4 of BH-3719. It adds two sourced libs. Nothing calls either one
yet. The lane that sources them, `bin/dequeue-watch.sh`, is a sibling slice.

- `bin/lib/dequeue-watch/act.sh`
  - `dqw_act <P> <slug> <num> <url> <head> <class> <ctx-json>` picks one action
    per class and claims it with `dqw_action_claim` before it does anything:
    - bystander or flake: requeue
    - stale-status: lead-request
    - main-red: main-red-wait
    - rule-break, scanner-fp, semantic-test or textual-conflict: fix-round
    - unclassified: hold
  - A bystander or flake with no standing verdict (anything but `MERGE` /
    `MERGE-WITH-NOTES`) is claimed as stale-status / lead-request instead, so it
    never reaches `mc_requeue_mergify`.
  - A requeue writes the conductor's `requeued` mark first, then calls
    `mc_requeue_mergify` once. If the conductor already marked that head, it
    posts nothing.
  - A fix round reads `dqw_rounds_count` before the claim. At the cap, or for a
    class listed in `DEQUEUE_WATCH_HOLD_CLASSES`, the action becomes a hold. A
    hold places a needs-human marker on the ticket issue and sends exactly one
    critical `dqw-hold:` line.
  - A fix round writes the `dqwculprit` mark, then calls `fix_round_enqueue`
    with reason `queue-dequeued`.
  - `dqw_mainred_recheck <P> <slug>` requeues (or asks the lead) on the same
    main-red-wait row once `main_red_flag` clears. The standing verdict rides in
    the row's note as `verdict=<word>`.
  - `dqw_watchdog <P> <slug> <num> <head> <age_s> <url>` pages once
    (`dqw-unowned:`) when no non-failed action row owns a dequeued head past the
    window. It resolves that page once a row owns the head.
- `bin/lib/dequeue-watch/llm.sh`
  - `dqw_llm_classify` fingerprints the failure as
    `sha1(repo|suites|normalized FAIL lines)`, then checks `dequeue_events` for
    that fp before it spends anything.
  - It stamps `llm_attempted_at` before the one `agent-call.sh dequeue-classify`
    call, and accepts only an exact class word.
  - Junk, an empty answer or a failed call is recorded as `llm_class=none` and
    never asked again.
  - The model and runner come from the `dequeue.classify` route. There is no
    model literal.
- `catalog/llm-sites.json` gets the `dequeue-classify` site and
  `catalog/prompts/dequeue-classify.md` is its prompt.

Every failed read (claim, count, action list, events) means nothing happens for
that PR this tick. It never reads as "no rows".

## Knobs (env; the lane slice registers them, these are the code fallbacks)

| Knob | Default | Meaning |
|---|---|---|
| `DEQUEUE_WATCH_ACT` | 1 | 0 claims `observe` and logs `WOULD_<ACTION>`. Anything else but 1 is treated as 0 and logged. |
| `DEQUEUE_WATCH_FIX_ROUNDS` | 2 | Fix rounds per (PR, class) before a hold. A junk value sends one warn and uses 2. |
| `DEQUEUE_WATCH_HOLD_CLASSES` | empty | Comma or space list of fix-round classes that always hold. |
| `DEQUEUE_WATCH_UNOWNED_MIN` | 30 | Watchdog window in minutes. A junk value is logged and 30 is used. |
| `DEQUEUE_WATCH_LLM_USD` | 0.05 | Per-call budget for the classify call. |
| `DEQUEUE_WATCH_MODEL` | route | Override read by `lane_model` for role `dequeue.classify`. |

## Known residual

A crash between the claim and the side effect leaves a `claimed` row. The
watchdog counts that row as owning the head, so it does not page. The lane's
own heartbeat is what pages a dead lane.
