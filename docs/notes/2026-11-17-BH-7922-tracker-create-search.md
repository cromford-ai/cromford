# Create and search on every tracker, one ticket-ref regex, slice C0 (BH-7922)

Doc: tracker-adapter

## What changed

Wave 4 of #7916, slice C0. Three additions. No caller changes.

- `tracker_create <titlefile> <bodyfile> [--label <l>]... [--parent <id>]
  [--blocked-by <id>]...` (`bin/lib/tracker.sh`) on all four adapters. It
  prints the new ticket's `tracker_read` object plus `relationErrors`. The
  body carries `Part of` and `Blocked-by:` text footers on every tracker.
  Linear also sends `parentId` and `issueRelationCreate type: blocks`. Jira
  also sends `fields.parent` (when the project has the field) and an
  `issueLink` "Blocks". The legacy `tracker_create <payload-json> <out>`
  form (BH-8706) is chosen by its shape and is unchanged.
- `tracker_search <query>` on all four adapters. One title check in
  `bin/lib/tracker.sh` keeps the rows whose title holds the query, at most
  `trk_search.max_rows`.
- `bin/lib/ticket-ref.sh`: `TICKET_REF_ERE` (`#N` or `KEY-N`) and the
  `Blocked-by:` / `Part of` line parsers.

## Knobs

- `trk_search.max_rows` (seed and fallback 50, valid 1..100): the most
  rows a search answers, and the page size Jira and Linear are asked for.
  Fragment `worker/jobs/schema.d/202611171924-bh-7922-tracker-search-settings.sql`.
- `tracker_jira.<project>.issue_type` (no seed, fallback `Task`): the issue
  type a Jira create files.

## Exit codes of the new create

rc 0: the ticket exists (a failed relation or read-back is an entry or
`readBack: false`, never rc 1). rc 1: no ticket, except a 2xx that named no
key (`... the ticket may exist`). rc 75: rate-limited on the create.

## Not in this slice

C1: `bin/lib/file-children.sh` writes the key in its footers, and the 17
footer parsers use `bin/lib/ticket-ref.sh`. C2: `bin/lib/fc-tracker.sh`, the
routing on `tracker_kind` in the six scripts, the ratchet allowlist, the three
stub end-to-end suites, and the live sandbox proof of the Jira link direction
and the Linear relation.
