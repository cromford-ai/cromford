# The ticket-hold contract in the console (BH-3146, BH-2326.0)

Doc: DB-COORDINATION-SPEC

## What changed

- New `console-ui/src/lib/ticket-hold.js`, pure (no DOM, no fetch):
  `HOLD_LEDGER_KIND = 'ticket_hold'`, `HOLD_REASON_MAX = 500`,
  `holdKey(project, n)` (`<project>#<n>`, the closed-issue key shape in
  `functions/api/dash/kanban/pipeline.js`), `holdTarget(project, ticketKey)`
  (null unless the project is non-blank and the key matches
  `^[A-Za-z][A-Za-z0-9]*-([1-9][0-9]*)$`), `holdCommand(action, target, reason)`
  and `holdFromLedger(row)`.
- New `console-ui/src/ui/HeldTag.js`: a `HELD` tag, rendered only when held.
- `api.ticketHold(project, n)` reads the row through the coord proxy.
- `hold_ticket` and `unhold_ticket` joined the `BOARD` target set in
  `console-ui/src/lib/commands.js`, so their /history/commands rows link to
  `/p/<project>`.

Nothing mounts the tag and nothing sends the commands yet. The hub handler,
the proxy change and the card mount are the other three children of #2326.

## The mechanism (from the #2326 plan)

The hub, as the GitHub App, adds or removes the `hold` label (every hold
reader honours it through `hold_classify`, BH-2504; App-posted HOLD comments
are ignored because `bin/lib/hold.sh` drops Bot comments), posts one
explanatory App comment, and writes the ledger row below.

## The contract

- Ledger row: `ledgers(kind='ticket_hold', key='<project>#<n>')`, status
  `held|clear|unknown`, detail `'<verb> by <actor> at <iso>: <reason> | <why>'`.
- Command payload: `{type:'hold_ticket'|'unhold_ticket', project,
  ticket:'PREFIX-<n>', reason}`, reason trimmed then capped at 500 characters.
- Reading it: `held` is `{held:true, by, at, why}` (by/at/why null when the
  detail does not parse, never guessed); `clear` and an absent row (the
  worker's 404 `{error:"not found"}`) are `{held:false}`; `unknown`, any other
  status, a row of another kind, garbage and a load failure are
  `{unknown:true}`. A failed read never shows as "not held".
