# Staff findings ledger and suppressions (BH-5560, wave 3 of #5556)

Doc: DB-COORDINATION-SPEC

## What changed

The jobs DB has two new tables (`worker/jobs/schema.sql`, BH-5560 block):

- `staff_findings`: one row per claimed finding. `fingerprint` is UNIQUE
  across all agents. Other columns: agent, title, source kind, source URL,
  source labels (JSON), source filedBy, observedAt, status (`claimed`),
  ticket_url (no writer yet), claimed_at, updated_at.
- `staff_suppressions`: fingerprint, reason, approver, expires_at, status
  (`pending`, `active` or `revoked`), created_at. An `active` row must have an
  approver. `(fingerprint, approver, expires_at)` is UNIQUE.

Two new worker routes in `worker/jobs/src/routes/staff-findings.js`:

- `POST /api/staff/findings/claim`, body
  `{agent, item, title, source: {kind, url, labels, filedBy?}, observedAt}`.
  The worker computes `fingerprint(item)` with agent-core. The answers:
  - 200 `{claimed: true, fingerprint, finding}`: the row is written.
  - 409 `already_claimed`: a row for this fingerprint exists (any agent).
  - 409 `suppressed`: an active suppression for this fingerprint has
    `expires_at` after now.
  - 409 `staff_filed`: a source label starts with `staff:`, or `filedBy` is a
    staff agent on the roster (trimmed, case-insensitive).
  - 404 `agent not found`, 409 `agent_not_active`, 400 on a bad body.
  Every refusal writes no row. The claim and the suppression check are one
  SQL statement.
- `POST /api/staff/suppressions`, body `{fingerprint, reason, approver,
  expiresAt}`. It writes an `active` row. `expiresAt` is stored as
  `YYYY-MM-DDTHH:MM:SSZ` and must be after now. An approver of `archie` or a
  staff agent name is 403 `agent_approver`. The same body again answers 200
  `existing: true` and writes no second row.

## Why

Parent #5556: "Dedup before spend. A finding is claimed by fingerprint before
any filing or model call." and "A finding whose source is a staff-filed ticket
is refused." Wave 4 (#5561, the heartbeat) is the first caller. It must claim
before it files or calls a model.

## Rules this sets

- A suppression matches only when status is `active` and `expires_at` is
  after now. At or before now it has expired. `pending` and `revoked` rows
  never match.
- The stored `source_url` is agent-core `canonicalUrl()`: no query string, no
  fragment, no userinfo. A token in a URL does not reach the table.
- A claimed row is terminal for its fingerprint. Nothing in this wave
  releases or deletes it.

## Apply

The tables apply through `bin/harness-sync.sh` before `wrangler deploy`
(`CREATE ... IF NOT EXISTS` only). Before that apply, both routes answer 503
with the table name.
