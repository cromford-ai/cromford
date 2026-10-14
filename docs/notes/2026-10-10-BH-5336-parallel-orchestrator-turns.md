# Orchestrator turns run in parallel (BH-5336)

Doc: OPERATING

## What happened

`bin/orchestrate.sh` took one blocking `flock` on `$ORC/.turn.lock` for the whole turn. On
2026-10-07 one turn (command 21346) ran for 46 minutes, and six messages waited behind it.

## What changed

1. The whole-turn lock is gone. `bin/lib/orc-turns.sh` claims each command in
   `$ORC/state/turns/<key>.json` (key `c<command id>`), keeps the claim alive with a heartbeat, and
   admits up to `ORC_TURN_CONCURRENCY` turns at once (lane `orc-monitor`, default 4; 0 = free
   memory / `ORC_TURN_WORKER_MEM_MB`; 1 while `flags/orchestrator-continue` is active).
2. A waiting turn acks `queued_behind:<id>`, as before. It waits for a slot, or for an in-flight
   turn in its own thread: a Slack reply in the same `thread_id`. No other message waits.
   A Telegram reply does NOT wait yet. The gate also matches a Telegram `reply_to_message_id`
   against an in-flight turn's `message_id`, but the console's Telegram chat payload carries
   neither field (cromford-console `src/index.js` free-text arm, main e27f6db). The
   producer change is example-org/cromford-console#47. Until it ships, a Telegram reply
   runs at once, like any unrelated message.
3. A copy of a command that is in flight (live claim) or answered (`<key>.done`) exits before any
   model call, with no ack and no beat. A claim with no heartbeat for `ORC_TURN_STALE_S` (90 s) is
   stale and is taken over. A turn that stops before it answers (SIGTERM, an early exit through
   the EXIT trap) releases its own claim with no `.done` marker (`orct_release`, matched by the
   claim's token), so a re-delivered copy runs at once. The in-flight list in the briefing is a
   read: it never renames a stale claim (only the gate does, under `$ORCT_DIR/.lock`).
4. Each turn edits its own copies of STATE.md and facts.md. `bin/orc-state-merge.py` merges them back
   by `## ` section under `$ORC/.state.lock`. If two turns change one section, both texts stay.
5. `bin/orc-context.sh append` writes each record under a short flock on `<log>.lock`.
6. Each fresh turn passes its own `--session-id`, and `bin/claude-usage.sh --session=` prices only
   that session.
7. The briefing lists the other turns in flight (`=== OTHER TURNS IN FLIGHT`), and
   `prompts/archie-soul.d/55-parallel-turns.md` tells Archie to edit only the turn copies.

## Operator steps

1. Deploy when no turn is in flight. A turn on the old code still writes STATE.md whole.
2. On the hub, edit `/root/orchestrator/CLAUDE.md` where it says to update
   `/root/orchestrator/STATE.md`: point it to the per-turn copy that the briefing names.
