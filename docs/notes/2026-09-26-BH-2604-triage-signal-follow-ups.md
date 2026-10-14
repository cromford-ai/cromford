# Triage no-signal settle: four follow-ups (settled rows, alert row, relayed content, identities)

Doc: COST

Follow-ups to BH-2542 (PR #2593), from its review.

## What changed

- **A settle is `row_source=settled`.** The `triage-precheck` row a settle
  appends to `logs/cost.csv` used to say `refused`, the gate-refusal marker, so
  a saving and a refusal could not be counted apart. It now says `settled`.
  `bin/cost-rollup.sh` treats `settled` like `refused` in the unpriced count
  and in the stored-unpriced pair skip, because both are $0 rows where the $0
  is the answer. `GET /api/metrics/llm-spend` returns a new `settled` count
  beside `refused`, on both its `?lane=` and its general form. `refused` still
  means gate refusals only, and `usd` does not change. Rows written before this
  change still say `refused`.
- **The empty-allowlist guard is an alert row, not a flag file.** On a GitHub
  board with `HARNESS_SELF_APPS` empty, each tick calls `bin/lane-alert.sh
  --id triage-signal-self-apps-<project>-<YYYYMMDD> --severity warn`. The alert
  state machine keeps that as one row (the `alert_note` row when
  `flags/alerts-db` is on, `state/alerts/<id>.json` otherwise), so it gives one
  ALERTS line per project per day with its own auto-close and GC. The old
  `flags/alerted-triage-signal-self-apps-*` file is no longer written. When the
  state machine is off (`flags/alert-state-off` or `ALERT_STATE_ENABLED=0`),
  `lane-alert.sh` ignores `--id` and would page every tick, so the call is
  `--log-only`: an ALERTS line per tick, no beat.
- **Our own comment can carry a human's words.** On an in-app board, a comment
  that counts as ours stays IN the signal digest when the first non-blank line
  of its body (else `content`, else `text`) starts with `[human]` (any case) or
  with exactly `SIGNAL:`, after leading whitespace. The body can only move a
  comment from OUT to IN. A quoted marker (`> [human]`), a marker later in the
  line, `signal:`, `SIGNALS:` and `[humans]` do not count.
- **Self identities are settings rows.** `agent:build-harness` is no longer a
  literal in `bin/triage-signal.py`. The knob `TRIAGE_SIGNAL_SELF_IDENTITIES`
  (`catalog/lanes.d/_lib.triage-signal.json`, required, settable, default
  `agent:build-harness`) is resolved per project by
  `triage_signal_sfp` through `lib_env_apply triage-signal <project>`, which
  now takes an optional project. The resolved value reaches `bin/triage-gate.sh
  --signal` as `TRIAGE_SIGNAL_SELF_IDENTITIES`, and the in-app digest receives
  it as `SELF_IDENTITIES`. Each comma-separated entry matches whole-string,
  case-insensitive, against an author_actor/authorActor marker and the author
  object's name/userId, so a board that sends no marker can name our userId.
  Unset or empty means no identities, so a marked comment is treated as signal.

## Rows

- `lib.triage-signal.<project>.triage_signal_self_identities`, then
  `lib.triage-signal.triage_signal_self_identities`, then env, then the
  registry default.

## Probe

```
awk -F, '$4=="triage-precheck" {print $18}' /root/harness/logs/cost.csv | sort | uniq -c
curl -s -H "Authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/metrics/llm-spend?stage=triage-precheck" | jq '{refused, settled, calls}'
ls /root/harness/state/alerts/ | grep triage-signal-self-apps
```

Pinned by `tests/triage-signal.bh-2604-test.sh` and
`worker/jobs/test/llm-spend-settled.bh-2604.test.js`.
