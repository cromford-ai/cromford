# Direction is not a take-over, and a resolver hand-off acts, says why not, or pages (BH-5125)

Doc: MERGE-CONDUCTOR, TRIAGE-STATE, ALERTS-STATE-MACHINE

## What happened

On 2026-10-07 at 04:29:15Z, small-box triage logged this for BH-5022:
`skip :: fix round for the lead BLOCK on open PR #5067 is already in progress (orchestrator/operator)`.
It had read the operator's narrowing comment, which was direction for the next AGENT
fix round, as a person taking the fix. Nothing was running.

At 04:34:50Z `bin/review-rescue.sh` logged that #5067 "goes to
bin/blocked-resolver.sh for an agent fix round", and no round ran. That line
was false. `br_from_builds` maps a plain `REVIEW_BLOCKED` RESULT to
`rescue-giving-up`, which `br_action` sends to a fresh rebuild, and it only
offers that record once the RESULT is 90 minutes old. Nobody worked on the PR
until a hand round started at about 05:09Z, and BH-5023/BH-5024 sat in
STACK-WAIT behind it the whole time.

## What changed

- **The take-over marker.** `bin/lib/hold.sh` now has `HOLD_HUMAN_FIX_RE`. A
  person's comment with a line that opens `Taken by: <person>` or `[human-fix]`
  holds the ticket as `hold:human-fix <at> <line>`. That is a pause on every lane
  that reads `hold_is_pause`.
  - It is lifted the same way as `NEEDS-HUMAN:`: a person's `HUMAN-STEP-DONE:`
    directly above it, or the lift vocabulary (RESUME, UNHOLD and the rest).
  - A Bot comment never takes a fix, and neither does a title or a body.
  - The marker has to open the line. A mid-line mention, a `>` quote and
    `**Taken by:**` hold nothing.
- **The triage contract** (`catalog/agent-contracts/triage-system-append.txt`)
  gains two rules:
  - `DIRECTION:` a principal's comment is direction for the next round. Only
    the explicit marker means a person has the fix, and "in progress" is never
    inferred from free text.
  - `EVIDENCE:` a skip or defer that claims work is in progress ends with one
    tag: `[evidence: lock <path>]`, `[evidence: pid <n>]`, `[evidence: job <id>]`
    or `[evidence: hold:human-fix]`.
  - The BUILD DEDUPE example now carries the lock tag.
- **The skip audit.** New `bin/lib/triage-skip-evidence.sh`, called by
  `bin/decision-log.sh` after the harvest, so it covers both the full tick and
  the per-ticket shard.
  - It checks every `skip`/`defer` whose reason matches the in-progress
    matcher.
  - Lock and pid tags are verified on the box: the lock must sit under
    `locks/`, contain no `..`, and actually be held; the pid must answer
    `kill -0`. Job and human-fix tags count as named evidence.
  - An untagged or failed claim is not honoured. It gets a
    `gate=audit <KEY> :: handoff :: … — bin/blocked-resolver.sh owns it` line
    in `logs/decisions.log` on every tick, plus one ALERTS line per distinct
    claim (deduped through `state/triage-skip-evidence/<p>-<KEY>`).
- **The hand-off watchdog.** New `bin/lib/handoff-watch.sh`, sourced by the
  resolver and by review-rescue.
  - Every candidate a resolver tick sees is claimed under
    `state/blocked-resolver/handoffs/claims/<id>`, and so is every BLOCK that
    review-rescue hands over. A rescue claim carries a `not_before` of
    RESULT mtime + 5400.
  - Acks come from three places: `br_event` (`acted`, which closes the claim;
    `resolver_preflight`/`resolver_yield` are `dispatched`), the main loop
    after each `br_one` (`dispatched`), and the key-lock exit (`lock-held`).
    A held project acks `held`.
  - At the end of each tick, a claim this tick did not dispatch gets
    `HANDOFF-WAIT <id>: claimed by <who> <age>m ago — not dispatched this tick: <why>`.
    Only the 10 oldest are named. Past that, one
    `HANDOFF-WAIT summary: <n> hand-off(s) not dispatched this tick (...)` line
    counts the rest by reason (a saturated hub leaves about 665 a tick).
    `<why>` is `tick stopped at <budget|tick-budget> before reaching it`,
    `its project's share of this tick was spent before it`,
    `not a candidate (a source floor or filter kept it out)` or
    `project held`.
  - A claim that has gone `BR_HANDOFF_SILENT_PAGE_S` (default 1800) with no ack
    of any kind is silent. Silence is counted from the later of first_at,
    not_before and the claim's last ack. A claim made during the tick being
    swept is never silent at that tick's end: the sweep runs when the tick
    ends, and a hub tick can last about 3000 s.
  - ONE page per sweep at most:
    `lane-alert.sh --severity critical --id br-handoff-silent`, with the count
    and at most 10 claims named. It is sent only when a claim went silent
    since the last page. If the page is still open, it is resolved and sent
    again with the new count, so an open page never mutes a later silent
    hand-off.
  - `paged_at` is stamped only when the page sends, so a failed page retries
    on the next tick. `state/blocked-resolver/handoffs/paged/<id>` records the
    claims the open page covers; the id is resolved once none is left.
  - A resolver candidate's own claim is dropped when the candidate list no
    longer holds it, because the source stopped reporting the park. Claims
    older than `BR_HANDOFF_MAX_AGE_SECS` are deleted.
- **The key lock speaks.** `flock -n 9 || exit 0` now writes
  `<p>/<rkey>: key lock held — a round for it is already running (…); not dispatched this tick`.
  The rc is still 0, so the rung accounting is unchanged.
- **The rescue line is true.** A rescued BLOCK now logs: `the record stays
  REVIEW_BLOCKED; bin/blocked-resolver.sh offers it as rescue-giving-up (a fresh
  rebuild) from <HH:MMZ> (its RESULT's 90-minute floor)`. The ladder itself is
  unchanged.
- **The DIRECTIVE.** `br_fix_round` reads the ticket thread
  (`pr_fetch_thread`, with the id from `br_ticket_id`) and appends the newest
  comment that is principal, not harness, and not from a `[bot]` login.
  - It goes in as `DIRECTIVE — the newest comment from a project principal on <KEY> (<author>, <at>) …`,
    wrapped by `ui_wrap ticket-thread` and capped at `BR_DIRECTIVE_MAX_CHARS`
    (default 4000; 0 turns it off).
  - An unreadable thread is logged with
    `the ticket thread of <KEY> is unreadable — round runs without a DIRECTIVE`,
    and the round still runs.
  - The `resolver_rung` event names `directive` when one was added.
- **Two knobs** in `catalog/lanes.d/blocked-resolver.json`:
  `BR_HANDOFF_SILENT_PAGE_S` (1800) and `BR_DIRECTIVE_MAX_CHARS` (4000).

## What it does not change

- Which rung a rescued `REVIEW_BLOCKED` gets is unchanged, and so is the
  90-minute floor.
- The conductor's `handed to bin/blocked-resolver.sh, not paged` branch is
  unchanged. Its parks are resolver candidates, so the watchdog covers them.
- There is no hub read of triage decisions and no cross-box hand-off queue. The
  resolver already owns the PR on the hub from its own sources.
- The DIRECTIVE cannot tell the operator's own comments from comments the harness
  posted on his PAT, because both are principal User comments. It skips
  harness comments (the Apps and the repro-stop marker) and `[bot]` logins
  only.

## Evidence on a box

- Hub, `logs/blocked-resolver.log`: `HANDOFF-WAIT`, `HANDOFF-PAGE` and
  `key lock held` lines.
- Hub, `ls state/blocked-resolver/handoffs/claims`.
- Hub, `logs/ALERTS.log`: `br-handoff-silent`.
- Hub, `logs/review-rescue.log`: `offers it as rescue-giving-up`.
- Owning box, `logs/blocked-resolver.log`: `resolver_rung … directive`.
- Project box, `logs/decisions.log`: `gate=audit`.

Tests: `tests/hold-human-fix.bh-5125-test.sh`,
`tests/triage-skip-evidence.bh-5125-test.sh`,
`tests/blocked-resolver-handoff-watch.bh-5125-test.sh`,
`tests/blocked-resolver-directive.bh-5125-test.sh` and section 16 of
`tests/review-rescue-test.sh`.
