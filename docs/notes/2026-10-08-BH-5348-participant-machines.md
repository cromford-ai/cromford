# Machines outside the pool can enroll as participants (BH-5348)

Doc: ADD-YOUR-OWN-MACHINE, OPERATOR-SETUP

## What changed

- New `bin/machine-enroll.sh`, the client for the BH-5349 participant routes in
  `worker/jobs/src/routes/participants.js`:
  - `request <name> --roles a,b [--owner o] [--billing-account x]` generates a
    32-byte token into the token file (mode 600), POSTs only its sha256 to
    `/api/participants/request`, and prints `pending <id> <name>`. It keeps the
    file only on a 201 with a pending row. Any other answer, an unreachable
    worker or a kill removes it. It refuses when the file already exists.
  - `status` calls `/api/participants/whoami`.
  - `approve <id> --roles a,b [--by who]`, `deny <id>`, `revoke <id>` need the
    lead token, same file and default as `bin/lead-verdict.sh`.
- New `docs/add-your-own-machine.md`: request, approve, run, revoke.

## Why

BH-5348 lets an approved machine take part in tickets like any lane. The worker
side (BH-5349) had routes and no client, so enrolling meant a hand-made curl
with the token on argv.

## What it touches

- Token file: `HARNESS_PARTICIPANT_TOKEN_FILE`, default
  `~/.config/cromford/participant-token`. This is the interface
  `bin/lead-review.sh` will read once BH-5348.2 (#5351) lands; it doesn't yet.
- Lead token: `LEAD_VERDICT_TOKEN_FILE`, default
  `~/.config/cromford/lead-verdict-token`.
- Every secret (bearer, participant token, lead token) goes to curl in a 0600
  header file removed on exit. None is ever on argv or printed.
- Exit codes: `request` 0 or 1. `status` 0 approved, 3 pending, denied or
  revoked, 1 on any error. `approve`, `deny`, `revoke` 0 or 1; a 403, 404 or
  409 is always 1.
- No worker, schema, cron, lane or settings change.
- Pinned by `tests/machine-enroll.bh-5348-test.sh`.
