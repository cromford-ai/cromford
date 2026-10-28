# Tracker connect sheets: test on connect through a one-time KV row and the hub-probe ledger (BH-7936)

Doc: CONSOLE, DB-COORDINATION-SPEC, worker/jobs/README.md

## What changed

Onboarding wave 3 adds the backend and the sheets for connecting Linear, Jira
or the app's own board. The sheets are not mounted on a screen yet: wave 2's
`console-ui/src/screens/Onboard.js` (step 2) is not on main. Mounting them, the
`tracker` station, `POST /api/onboarding/tracker` and the
`docs/ONBOARDING.md` TEMPORARY section are the rest of BH-7936 and wait on
#7934 and #7935.

- `console-ui/src/ui/TrackerSheets.js` (`TrackerSheet`) and
  `console-ui/src/lib/tracker-sheets.js`: one sheet per tracker. Linear: API
  key, team key, build label. Jira: site, email, API token, project key and a
  status map of four editable rows (ready = To Do, building = In Progress,
  review = In Review, closed = Done, sent as
  `todo=To Do;in_progress=In Progress;review=In Review;closed=Done`). Board:
  Board API base and internal token. Test and connect is disabled while a
  required field is blank and names the field. Later and Escape call
  `onLater`. Below 720 px the sheet is a bottom sheet
  (`console-ui/src/ui/TrackerSheets.css`, imported in `src/main.js`).
- The test: `POST /api/coord/onboarding/tracker-test {project, kind, fields}`
  (coord row `console-ui/functions/_lib/coord-writes.d/7936-onboarding-tracker.js`)
  → `worker/jobs/src/routes/onboarding-tracker.js` checks the fields, puts
  them in KV `onb-tracker:<test_id>` with a 900 s TTL, then files a hub-probe
  row (probe `tracker-test`, ticket `onb-<test_id>`, args `[kind, test_id]`)
  and answers `202 {test_id}`. No field value is written to D1. The sheet
  polls `GET /api/coord/onboarding/tracker-test/<test_id>?project=` every 5 s
  and stops with an error after 20 minutes.
- The hub: `bin/hub-probe.sh` claims the row and runs
  `bin/lib/hub-probes/tracker-test.sh`. `onb_take` calls
  `POST /api/onboarding/tracker-secret/take`, which answers the KV row once
  and deletes it. `onb_tracker_check` runs `tracker_list` and one
  `TRK_DRY=1 tracker_comment` on the first listed ticket through
  `bin/lib/tracker.sh`. The output scrubs every secret value and the email.
  `tracker-test` is in the new `HP_SCREEN_PROBES` list in
  `bin/lib/hub-probes/common.sh`, not in `HP_PROBES` (the list a board
  comment may ask for). The lane stores the result and posts no comment for
  it; the summary line counts it as `silent=<n>`.
- Jira from fields: `trk_jira_cloud_id <site>` (one GET of
  `https://<site>/_edge/tenant_info`) and `trk_jira_context_fields` in
  `bin/lib/tracker/jira.sh`. `trk_jira_context` is unchanged.
- Contract suites: `tests/contract/tracker-linear.bh-7936-contract-test.sh`
  and `tests/contract/tracker-jira.bh-7936-contract-test.sh`, 5 real-vendor
  cases each, run by `.github/workflows/tracker-contract.yml` on main, nightly
  and on a PR that changes the tracker seam. The PR suite's budget test is
  `tests/onboard-tracker-vendor-budget.bh-7936-test.sh` (0 vendor calls).

## Not in this PR: C4 (a partial delivery of BH-7936)

This PR delivers C1-C3 of the plan. It does not close BH-7936. The plan's
`## Requirements coverage` rows for C4 say `C4 deferred`, so the merge
close-out (`bin/lib/slice-closeout.sh`) reads them as not covered and files
one child issue with the rest. The child issue text:

- Title: `Onboarding UI wave 3, C4: wire the tracker sheets into the run`
- `Blocked-by: #7934, #7935` and this PR (C1-C3).
- [ ] T11: station `tracker` in `bin/lib/onboard-stations.sh` runs
  `tracker_list` and one `TRK_DRY=1` comment, then writes the adapter's env
  lines to `env/<project>.env` (temp file and mv, mode 600). A failed read
  leaves the run `failed` at `tracker` with the scrubbed error in
  `log_excerpt` (AT3). Suite: `tests/onboard-station-tracker.bh-7936-test.sh`.
- [ ] T12: `POST /api/onboarding/tracker` saves the kind and the non-secret
  fields on the run inputs, a changed Jira status pair included (AT4). A
  secret field name answers 400. The `register` station writes
  `tracker_adapter.<project>` from the inputs.
- [ ] T13: step 2 of `console-ui/src/screens/Onboard.js` enables Linear, Jira
  and the board, opens `TrackerSheet`, and shows the tag "tested" after `ok`.
- [ ] T14: `docs/ONBOARDING.md` gains the TEMPORARY section for the KV row
  (decision 3), and `docs/connecting-a-board.md` gains "From the screen".

## Operator steps

1. Add the repo Actions secrets the contract workflow reads:
   `LINEAR_CONTRACT_KEY`, `LINEAR_CONTRACT_TEAM`, `JIRA_CONTRACT_SITE`,
   `JIRA_CONTRACT_EMAIL`, `JIRA_CONTRACT_TOKEN`, `JIRA_CONTRACT_PROJECT`.
   Without them each suite prints `SKIP: no contract credentials` and passes.

## The wait

The hub-probe lane runs every 10 minutes and caps each probe at 20 runs a UTC
day (`HUB_PROBE_DAILY_CAP`). A test can wait up to 10 minutes. BH-7968 replaced
the KV row with the secret envelope, so a deferred row no longer depends on a
15-minute KV TTL; see the envelope's own expiry in `docs/SECRETS-ENVELOPE.md`.

## Superseded by BH-7968

The KV row, `ONBOARD_KV`, `onb_take` and the take route are gone. BH-7968
(slice C0) moved the sheet to the secret envelope: the sheet seals the fields,
`POST /api/coord/onboarding/tracker-test` takes `{project, kind, envelope_id}`,
and the hub probe reads and decrypts the envelope. No KV operator step is
needed. See `docs/SECRETS-ENVELOPE.md` and `docs/ONBOARDING.md`.
