# Tracker sheets and onboard-run use the secret envelope (BH-7968, BH-7937.4)

Doc: ONBOARDING, SECRETS-ENVELOPE

## What changed

This replaces the one-time KV path of BH-7936
(`docs/notes/2026-10-22-bh-7936-tracker-test.md`). That note's KV operator
step (bind `ONBOARD_KV`) is no longer needed.

- The tracker sheets (`console-ui/src/ui/TrackerSheets.js`,
  `console-ui/src/lib/tracker-sheets.js`) check the fields, seal them as one
  JSON plaintext `{"fields":{...}}` with `sealSecret` to the hub key (settings
  row `hub_envelope_public_key`, read once per page through
  `loadSheetConfig`), and store it: `POST /api/coord/secrets/envelope` with
  scope `tracker:<kind>:<project>`. Then they start the test with
  `{project, kind, envelope_id}`. No request carries a field value.
- `POST /api/onboarding/tracker-test` takes `envelope_id`. One primary-key read
  of `secret_envelopes` refuses an id that is gone, expired or not exactly
  `tracker:<kind>:<project>` (400, nothing filed), so an `ai-account:`
  envelope is never burned by a tracker test. The hub-probe args are
  `[kind, envelope_id]`. The KV put, `ONBOARD_KV` and
  `POST /api/onboarding/tracker-secret/take` are removed.
- The hub probe `tracker-test` reads the envelope once (`onb_open`, hub token),
  opens it with the new `envelope_decrypt` in `bin/lib/envelope.sh`, checks
  the scope, then checks the fields (`_onb_fields_check`). `hp_validate` takes a
  UUID as the second arg. `onb_take` is removed.
- The field table (a public https board host, a Jira site under
  atlassian.net, a secret of 8 chars or more, and the rest) moved from the
  worker to two places: the console (`checkTrackerFields`, so the user sees
  the error at once) and the hub probe (the check that counts, because only
  the hub sees the fields). The hub copy also refuses a numeric host form
  such as `0x7f.0.0.1`.
- `POST /api/onboarding/runs` accepts the optional input `ai_envelope` (a
  lower-case UUID). `bin/onboard-run.sh` runs `bin/envelope-consume.sh <id>`
  once for a run with a queued step, as soon as the run's project is
  registered: before the first station, or right after the register station
  (`obe_consume` in the new `bin/lib/onboard-envelopes.sh`). The log line is
  `envelope <run> <id> applied|gone|deferred rc=75|failed rc=<n>`,
  `envelope <run> <id> held (project <p> not registered)`, or
  `envelope <run> refused bad id`. No result fails the run.
- `bin/secrets-apply.sh` holds an `ai-account:...:project:<p>` envelope while
  `bin/fleet-conf.sh --projects` does not list `<p>`: one
  `held <id> (project <p> not registered)` line, the envelope stays pending.
  Before this, the Step 2 own account was read (and deleted) by the next tick,
  then refused as "unknown project": the secret was lost.
- `/projects/new` Step 2: the review line "AI account" has a `Change` button
  that opens `AiAccountChoiceSheet` for the form's project. The line shows the
  choice (`fleet pool` or the account label). The project's own new account
  sends its envelope id as `ai_envelope`; a choice made for another project
  name is dropped. `AiAccountChoiceSheet` results now also carry `choice` and,
  for the new account, `envelope_id` (Settings reads `status` only).
- `docs/ONBOARDING.md` has a Secrets section and links `docs/SECRETS-ENVELOPE.md`.

## Not in this change

The Ready card "AI account" (scope item 2) needs the Ready cards (#8000),
which are not built. It stays on #7968 for a later slice.
