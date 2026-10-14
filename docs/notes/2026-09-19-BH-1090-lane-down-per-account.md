# BH-1090: per-account lane-down markers and additive ACCOUNT_EXHAUST_REGEX

Date: 2026-09-19
Ticket: BH-1090

## What changed

- `mc_lane_account_fact` in `bin/lib/merge-conductor-lib.sh` no longer treats
  every `AGENT_CALL_REFUSED*` reason as an account fact. Only
  `AGENT_CALL_NO_HEADROOM*` and `AGENT_CALL_REFUSED*runners-restricted*` are
  facts. `hub-no-build` and `no-tools` refusals are not account facts.
- A bare `HTTP 429` no longer marks the lane down. The built-in exhaustion
  vocabulary still matches `429 session limit` and similar phrases, but `429`
  alone is not enough.
- `ACCOUNT_EXHAUST_REGEX` is now additive to the built-in exhaustion vocabulary
  instead of replacing it. A user-supplied regex is OR'd with the defaults.
- Lane-down markers are now per-account. The default account continues to use
  `state/merge-conductor/lane-down`; routed accounts use
  `state/merge-conductor/lane-down.d/<account>`.
- `agent-call.sh` writes the paying account name to `$OUT.account` after a
  claude attempt. `mc_lane_up` / `mc_lane_down_note` clear/write the marker for
  that account.
- The spawn gate in `bin/merge-conductor.sh` asks `bin/account-pick.sh` which
  account would pay for the next re-review and checks that account's marker.
  A routed account in cooldown blocks the spawn even when the default canary is
  healthy.
- The hourly canary in `bin/claude-auth-check.sh` clears only the default
  marker; routed-account markers survive it.
- `mc_lane_epoch` asks the same question as the gate, so a routed account going
  down or coming back moves the epoch. The caps that forget an outage when the
  epoch moves (`MC_RR_LANEFAIL_MAX`, `bin/blocked-resolver.sh`'s
  `BR_LANEFAIL_MAX`) would otherwise strand a row parked during a routed outage.

## Round 2 (the #1100 head-bound review)

Two blocking findings and six smaller ones, all closed here:

- **Every marker needs a release event it does not have to buy.** A routed
  marker's only clearer was a Claude answer through that account — the read the
  new gate refuses to buy while the marker stands — and the canary probes the
  box login, not a registry credential. So one routed exhaustion would have held
  every head-bound re-review on the box until an operator removed a file:
  an unbounded silent hold where the ticket asked for a bounded unbilled one.
  A routed marker now EXPIRES after `MC_LANE_ROUTED_RETRY_SECS` (3600, the
  canary's own cadence): the gate removes it and un-gates the parked heads, and
  the first read to land either answers (`mc_lane_up`) or writes a fresh marker.
  The default marker is still never timed — the canary owns it.
  Two bounds named honestly in review round 2: that hour bounds the HOLD on the
  box, not a re-ask of the exhausted account (`bin/account-pick.sh` skips an
  account under `ACCOUNT_COOLDOWN_SECS`, 21600), and the reads it frees are this
  tick's `MC_REREVIEW_BUDGET` (2) per project, not literally one.
- **`$out.account` is swept before the call.** `$out` is keyed on (PR, head), so
  a re-spawn reuses the path; `bin/agent-call.sh` writes `.account` only when an
  account was actually chosen, so a `NO_HEADROOM` or `runners-restricted`
  refusal left the previous attempt's account on disk — the marker then landed
  on an account this run never touched, `default` stayed clean, and the gate
  re-spawned every five minutes (the BH-1019 loop). Swept in `mc_rereview` (both
  copies), in `mc_rereview_gc` and in `bin/blocked-resolver.sh`, and cleared at
  the top of `run_attempt` in `bin/agent-call.sh` so the sidecar can never
  describe an older call.
- `ACCOUNT_EXHAUST_REGEX` is additive in **`bin/agent-call.sh` too**
  (`LADDER_EXHAUST_REGEX`), not only in the conductor: one knob cannot mean
  "widen" in one file and "replace" in another on the same box.
- **Fix round 2 — and in `bin/lib/orc-account.sh`, the third classifier.** The
  turn ladder (BH-996) carries `agent-call.sh`'s `LADDER_*_REGEX` defaults
  verbatim and classifies the same text with the same knob, so leaving its copy
  as a replace-override is the same "one knob, two meanings" defect one file
  over — and `tests/orc-turn-ladder.bh-996-test.sh` compares the two files line
  for line, so it said so out loud. Both files now compose
  `${ACCOUNT_EXHAUST_REGEX}|${_LADDER_EXHAUST_BUILTIN}` byte for byte.
- **Fix round 2 — `mc_lane_next_review_account` resolves its model.** It asked
  `bin/account-pick.sh` about a literal `claude-fable-5-1`, which BH-998 bans
  from this lib (`tests/mc-rereview-model.bh-998-test.sh` greps the file) and
  which is also wrong on its own terms: `mc_rereview` buys `review_model`'s
  answer, so a pick made for a different word hands back the account for a lane
  nobody is about to use and the gate consults that account's marker. It now
  calls `review_model "$MC_H"`, the same resolver the read itself uses, and the
  suite records `account-pick.sh`'s argv[3] to pin it.
- The shadowed duplicate `mc_rereview` in `bin/lib/mc/rebase.sh` (the BH-477
  shim's copy, dead only because the lib redefines it afterwards) carries the
  same change; the two function bodies are byte-identical again.
- Tests: section 7 now drives the real `bin/claude-auth-check.sh` `ok` arm
  instead of rm-ing the marker itself; new sections drive the real
  `mc_rereview` (the sidecar sweep, the per-account marker, the account-scoped
  `mc_lane_up`), the marker expiry and the gate releasing it, the epoch moving
  on routed transitions, and the real `bin/agent-call.sh` writing the sidecar
  `mc_rereview` reads.
- The account name is guarded before it becomes a filename
  (`mc_lane_down_marker_path`), so the marker path does not depend on
  `bin/account-pick.sh`'s own validation.

## Deviations and what was declined

- **`retry-after` is not honoured.** Ticket item 2 offered "an exhaustion word
  or a `retry-after`"; only the exhaustion-word half shipped. A bare 429 is
  transient on the ladder (`LADDER_TRANSIENT_REGEX`) and is retried there, so a
  `retry-after` would be a second, weaker copy of a bound that already exists.
  Declined deliberately, not missed.
- **`AGENT_CALL_NO_HEADROOM` and `runners-restricted` do NOT write
  `$OUT.account`**, although the plan's Task 3 said they would: neither reaches
  an account, so there is no account to name, and naming the default would be a
  claim the call never made. The marker falls back to `default` instead, which
  is the account the canary can clear.
- **Where this is dormant.** `docs/ACCOUNT-ROUTING.md` records
  `ACCOUNT_ROUTING=0` as the hub's intended setting, and the plan's Assumption 1
  ("the hub runs re-reviews with `ACCOUNT_ROUTING=1`") is wrong about the box
  this deploys to. With routing off, `mc_lane_next_review_account` always prints
  `default`, `$OUT.account` is always `default`, and items 1-3 (the regex work)
  are the whole of the live behaviour change. Item 4 is correct-when-enabled,
  and the tests drive it with routing on; no post-merge observation on the hub
  can prove or disprove it while routing is off there.

## Why

Review findings from BH-1019 (#1074). The global marker was cleared by the
default-account canary while routed accounts were still cooling, costing one
free refused read per parked head per hour. Also, non-account refusals and
bare 429s were incorrectly treated as account facts, and `ACCOUNT_EXHAUST_REGEX`
overwrote the built-in list.

## Files touched

- `bin/lib/merge-conductor-lib.sh`
- `bin/lib/mc/rebase.sh`
- `bin/agent-call.sh`
- `bin/blocked-resolver.sh`
- `bin/merge-conductor.sh`
- `bin/claude-auth-check.sh`
- `tests/merge-conductor-account-fact.bh-1090-test.sh`
- `tests/merge-conductor-rereview-lanefail-test.sh`
- `docs/verification-map/rereview-claude-only.md`
- `docs/ACCOUNT-ROUTING.md`

## Doc

- docs/verification-map/rereview-claude-only.md
