# Own-account pins reach agent-call, the ladder, cost rows, the console and quota-status

Doc: ACCOUNT-ROUTING

## What was wrong

Child 1 of BH-1657 shipped the resolver (`bin/lib/project-account.sh`) and the
pool lease skip. Every other path still spent the shared accounts for a pinned
project: `bin/agent-call.sh` asked `account-pick.sh` when `ACCOUNT_ROUTING=1`,
the ladder rotated an exhausted pinned account onto the next shared one, cost
rows could not say which account paid, and nothing showed the pins.

## What it does now

- agent-call: a pinned project's claude rung runs on the label's token file, or
  on the live token when its fp already maps to the label (Fly builder), or
  fails closed with rc 76 and descends. The picker is never asked.
- Ladder: a pinned refusal never rotates and stamps no cooldown.
- Cost rows: `auth_account` = the label when the fp is unmapped.
- Resolver: the value `shared` unpins.
- Worker: `PUT /api/settings` refuses a token-shaped `account.*` value.
- Console: PROJECT ACCOUNTS on `/settings` (hub tab).
- `bin/quota-status.sh`: an OWN-ACCOUNT PROJECTS block with fp8.

## Still owed

The operator writes the `account.<project>` rows, then removes the
`#OWN-ACCOUNT-2026-09-23` env lines.
