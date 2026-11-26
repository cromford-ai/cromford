# BH-9262 C1: the chat callers file an owner approval; the owner acts in the console

Doc: worker/jobs/README.md, CONSOLE

Slice C1 of #9262, after C0 (`docs/notes/2026-11-13-BH-9262-owner-proof.md`).

## Why

C0 made owner commands and the human-only decisions accept exactly two proofs:
the Mac human token, or the Pages box-ops token with an Access identity in
`BOX_OPS_OWNERS`. The hub holds neither. The worker cannot check a Telegram
sender id, because the hub polls Telegram and the worker has no Telegram
webhook. So with `owner_proof_mode=enforce`, `bin/archie.sh` delegate and
`bin/box-request.sh` get a 403. The ticket's fallback applies: the hub files a
pending approval, and the owner approves it in the dashboard.

## What changed

- New table `owner_approvals` (`worker/jobs/schema.d/202611252112-bh-9262-owner-approvals.sql`).
  One row per `(kind, dedupe_key)`. Status `pending`, `approved` or `declined`.
  A pending row older than `owner_approvals.pending_ttl_h` reads as `expired`.
  That status is computed on read and never written.
- New routes (`worker/jobs/src/routes/owner-approvals.js`):
  - `POST /api/owner-approvals` (fleet bearer). Kinds `box_command` (an
    OWNER_ONLY type, only the keys `box, type, target, account, project, vcpus,
    mem_gb, disk_gb, cap, reason`) and `archie_delegation` (`{class, min_streak}`).
    201 for a new row, 200 `deduped:true` for an existing row.
  - `GET /api/owner-approvals[?status=pending|expired|approved|declined|all]`.
    Pending is the default. Newest first, at most `owner_approvals.list_limit`
    rows, and `truncated`.
  - `POST /api/owner-approvals/:id/decide` `{decision: approved|declined, result_ref?}`.
    It always needs one of the two proofs, whatever `owner_proof_mode` says.
    No proof: 403 `human_proof_required`. A decided row: 409 `already_decided`.
    A row past the TTL: 409 `expired`. An unknown id: 404.
- A row grants nothing. The worker never replays a stored payload. The console
  runs the action through the existing proved route, so every check of that
  route (quote TTL, price, open-row dedupe, `not_earned`, `never_delegable`)
  runs at click time.
- `POST /api/box-commands`: the enforce refusal is now
  `403 {error:"owner_only", proof:"required"}`. `error` does not change. The
  shadow "not an owner" refusal has no `proof` field. The hub uses the field
  to tell "no proof" from "not an owner".
- The hub files an approval only after the worker refused with a
  proof-required 403. It never reads `owner_proof_mode`. In shadow mode the
  chat flows work as before.
  - `bin/archie.sh` delegate: a 403 `human_proof_required` files an
    `archie_delegation` approval, with `via` `<transport>:<sender>` (from
    `ARCHIE_TRANSPORT`/`ARCHIE_FROM_USER`, which `bin/orchestrate.sh` now
    passes). The reply links `$CONSOLE_URL/machines#owner-approvals`.
  - `bin/box-request.sh`: a 403 with `proof:"required"` on the quote, the
    launch or the Fly pool command files a `box_command` approval. A launch
    files the quote spec (`orgo_launch_quote`), so the console prices it again.
- Console: the Machines screen has an "Owner approvals" panel
  (`/machines#owner-approvals`). REVIEW on a box command opens the existing
  priced or confirm dialog. APPROVE on a delegation opens an in-app confirm and
  posts the delegation. DECLINE declines. A row is marked approved only after
  the action answered 2xx. A refusal shows in the banner and the row stays
  pending.
- Retention: rule `owner_approvals.age` (`worker/jobs/src/routes/retention.d/bh-9262-owner-approvals.js`)
  deletes rows older than `retention.owner_approvals.days` (90) on the hourly
  `bin/d1-retention.sh` lane, with `retention.dry_run` honored.

## Knobs (settings rows, seeded)

| Row | Default | Reader |
|---|---|---|
| `owner_approvals.pending_ttl_h` | 72 | routes/owner-approvals.js |
| `owner_approvals.list_limit` | 50 | routes/owner-approvals.js |
| `owner_approvals.payload_max_bytes` | 4096 | routes/owner-approvals.js |
| `retention.owner_approvals.days` | 90 | retention.d/bh-9262-owner-approvals.js |

## Operator steps

1. Make sure C0's env is set: `BOX_OPS_TOKEN` as a jobs worker secret and on
   the console Pages project (production and preview); `BOX_OPS_OWNERS` on the
   jobs worker; `CF_ACCESS_TEAM_DOMAIN` and `CF_ACCESS_AUD` on Pages.
2. Deploy. `bin/harness-sync.sh` applies the schema fragment.
3. Watch `wrangler tail` for one day. Every `[owner-proof] would-refuse` line
   must have a known cause.
4. Send the human-token `PUT /api/settings {key:"owner_proof_mode", value:"enforce"}`.
5. Test from chat: `Archie delegate <class>` and `/box launch <project>` must
   reply with the console link, and the panel must show the row.
