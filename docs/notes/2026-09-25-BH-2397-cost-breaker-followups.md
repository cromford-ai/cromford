# Cost breaker card: RESET clears CAP HIT, the proxy wants a reason, the hub publishes autohalt

Doc: CALL-GUARD, COST

Follow-ups 1 to 3 from the #2382 (BH-2331) review. Item 4, the box gate running CI's orphan ratchet, shipped separately as BH-2414.

## RESET now clears CAP HIT

`GET /api/call-guard` (`worker/jobs/src/routes/call-guard.js`) adds two fields to each key's row. `refused` does not change.

- `reset_at` is the `at` of the key's newest `status='reset'` audit row inside the window, or null.
- `refused_since_reset` counts the refusals inserted after that reset row, by rowid, since `at` only has one-second resolution. With no reset it equals `refused`.

On the card, CAP HIT now follows `refused_since_reset`. A worker that predates the field sends nothing, and then `refused` decides as before, so the console can deploy first. The REFUSED cell still shows the window total and adds a faint "reset <when>" once a key has been reset. `bin/jobs-client.sh call-guard` reads the same route and ignores the new fields.

## The coord proxy refuses a blank reason

`console-ui/functions/api/coord/[[path]].js` answers a `DELETE call-guard` whose `reason` is missing, empty or whitespace with `400 {error:'a reason is required to reset the call guard'}` and forwards nothing. It checks auth and the allow-list first, so an unauthenticated call is still a 403. The worker keeps its `"manual reset"` default for the box CLI path.

## The hub publishes what autohalt actually does

`bin/pipeline-health.sh`'s cost budget block defines `cb_autohalt_effective`. It prints `on|off <flag-file|settings|env|default>`. On or off is `cb_autohalt_off`'s own answer, and the source follows `cb_knob`'s order. A value that is not a number counts as `default`, whichever rung it came from. `settings` means a settings row was really there, because `lane_knob` falls through to the env and the registry default by itself.

On the hub only (`is_hub_box "$(local_box_name)"`, from `bin/lib/hub-box.sh`), each time the block runs, which is at most every `COST_CHECK_INTERVAL_S` (1800 s by default), it writes `setting_set cost.autohalt.effective "<value>"`. A failed write is one line in `logs/pipeline-health.log`. It changes no halt and no exit code. Another box never writes the row.

The card's AUTOHALT line reads that row first and shows `ON`/`OFF` with "hub, <source>, as of <when>". The "flags/cost-autohalt-off is not visible from here" footnote is dropped when the row is present, because the row accounts for the flag file. A malformed row is UNKNOWN and quoted, never ON. Until the hub has published, the card keeps the old settings-row-or-registry-default reading and says the hub has not published its effective value.

Suites: `tests/cost-autohalt-publish.bh-2397-test.sh`, `tests/cost-breaker-followups.bh-2397-test.sh`, `console-ui/tests/cost-breaker.bh-2397.test.js`, `console-ui/tests/coord-reset-reason.bh-2397.test.js`, `worker/jobs/test/call-guard-reset.bh-2397.test.js`.
