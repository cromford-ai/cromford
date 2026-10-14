# Mission Control participants screen (BH-5353, BH-5348.4)

Doc: CONSOLE, worker/jobs/README.md

## What changed

- New console screen `/machines/participants` (`console-ui/src/screens/Participants.js`),
  reached from FLEET → MACHINES → SEE PARTICIPANTS. Pending enrollments get one
  approval card each, with a checkbox per requested role (all ticked to start),
  APPROVE and DENY. Approved, denied and revoked machines sit in one sortable
  table: name (links to the detail), owner, granted roles, status, last heartbeat
  with an online/offline tag, running claims and the last result (links to its
  `/pr/<project>/<n>` page).
- New detail screen `/machines/participants/<id>`: the row, its running claims
  and its other lead reviews, each linking to its PR page, and REVOKE on an
  approved machine. Every decision goes through the in-app confirm modal; the
  screen reloads from the worker after a 200 and shows the worker's error text
  in a warn banner otherwise.
- Worker (`worker/jobs/src/routes/participants.js`): `GET /api/participants`
  rows now carry `claims` (count of `lead_review_requests` with
  `status='running'` and `participant` = the row's name) and `last_result`
  (`{verdict, repo, pr, project, at}` of the newest verdict-bearing row, or
  null), and the body carries `online_window_s`. New `GET /api/participants/:id`
  answers `{participant, claims, results, truncated, online_window_s}`, at most
  50 review rows, never `token_sha256`, 404 `no such participant` for an unknown
  id. It sits after `/whoami` in the route table.
- `online_window_s` is the settings row `lead_review_claim_stale_s` (seeded
  900 by BH-5349), 900 when the row is absent or not a positive integer. This
  slice reads it for display only; the row's own note still says "no reader
  yet" because that note belongs to the claim-staleness sibling.
- Coord proxy (`console-ui/functions/api/coord/[[path]].js`): three new WRITES
  rows, `POST participants/<uuid>/approve|deny|revoke`. approve forwards
  `granted_roles` (non-empty, at most 8 strings of 1..32 chars, else 400); deny
  and revoke forward only the stamped actor. These three rows, and nothing else,
  send `x-lead-verdict-token`.

## New Pages secret

`LEAD_VERDICT_TOKEN` on the console Pages project (production; preview only if
decisions are wanted there), the same value as the harness-jobs worker's
`LEAD_VERDICT_TOKEN`. Without it the three decision writes answer 503 naming the
variable and forward nothing. Reads work either way.
