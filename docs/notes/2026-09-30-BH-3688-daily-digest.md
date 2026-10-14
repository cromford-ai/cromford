# The daily-digest lane: one triaged beat a day (BH-3706, BH-3688)

Doc: ALERTS-STATE-MACHINE

## What changed

BH-3688 sends the operator one Telegram digest of yesterday (UTC) per day. This is its
lane, slice 4 of 5. `bin/daily-digest.sh` is a hub cron lane
(`cron/lanes/722-daily-digest.cron`, every 15 minutes, behind
`hub-lease.sh check`). It is registered in `catalog/lanes.d/daily-digest.json`,
and its switch is `catalog/switches.d/daily-digest-off.json`. It reads the
BH-3703 route, hands the answer to the contract's `dd_summary` and `dd_render`,
and sends the text as ONE `fleet_alert` beat with `triaged:true` through
`BEAT_STRICT=1 bin/beat.sh`. It never calls Telegram itself: the console
relays the beat. `tests/daily-digest.bh-3706-test.sh` drives the shipped script.

Until #3707 lands, `dd_render` is the rc-3 stub. The lane then logs
` render-failed` and pages one warn `daily-digest-render:<day>` a day from the
send hour on. That is true (no digest went out). It is not a lane fault.

## Where each number comes from

The route answers one object per day. Its sections, as the BH-3703 fixture
`tests/fixtures/daily-digest/fixture-day.json` names them:

| section | fields | slice that fills it |
| --- | --- | --- |
| `throughput` | `merged`, `by_project`, `filing_to_merge` | #3704 |
| `spend` | `usd`, `calls`, `unpriced_calls`, `usd_per_merged_pr`, `top_tickets` | #3704 |
| `autonomy` | `rebuild_loops`, `batch_dequeues`, `manual_requeues`, `human_interventions` | #3704 |
| `tripwires` | `n`, `rows`, `truncated` | #3705 |
| `holds` | `n`, `basis`, `rows`, `truncated` | #3705 |
| `human_verdict_prs` | `n`, `rows`, `truncated` | #3705 |
| `model_watch` | `rows` (`vendor`, `model_id`, `suggestion`), `truncated` | #3705 |
| `spotcheck_candidates` | `rows` (`repo`, `pr`, `head_sha`, `project`), `truncated` | #3705 |
| `factory` | `all_off`, `fleet_pauses`, `factory_stop` | #3705 |

Every section carries `ok`. A section that failed to read is `{ok:false,
error}`, and the renderer says so rather than printing a zero.

## What usually lies

- **Flag-gated sources.** Some rows exist only when a flag is on: the
  `pr_attempts` / pr-state rows behind `pr-state-rows`, and the `ledgers` rows
  (batch members among them) behind `no-twin-ledgers`. With the flag off, the
  source is empty, not zero. Check the flag before believing a 0.
- **GitHub-only holds.** A NEEDS_HUMAN hold that lives only as a GitHub label or
  comment has no row, so the digest cannot count it.
- **Spend by day.** The parent plan records that the console's `/costs` view
  takes no day parameter, so a digest's spend figure cannot be checked against
  that page for a past day. Re-derive it from the route instead (below).
- **A standby hub after failover.** The dedupe authority is the jobs ledger row
  `daily_digest/<day>`, shared by both hubs. A hub that finds the ledger
  unreachable and has no local `sent-<day>` stamp sends. So a failover during a
  ledger outage can send the same day twice. That is accepted: at most one
  duplicate.
- **Before #3707.** The stub renderer gives ` render-failed` every tick, as said
  above.

## The lane's order, and why

1. Gate, then `lane_env_apply daily-digest`.
2. `NOW` is read once. `DAILY_DIGEST_NOW` counts only under
   `HARNESS_TEST_SANDBOX=1`. The day is the UTC date of `NOW - 86400`.
3. The `daily-digest-off` switch (summary ` off`), then
   `DAILY_DIGEST_ENABLED=0` (` disabled`).
4. Before `DAILY_DIGEST_SEND_HOUR_UTC` (default 7): exit with no log line and
   no request of its own.
5. `flock -n locks/daily-digest.lock`. Then files in `state/daily-digest/` whose
   name date is over 30 days old are removed.
6. Dedupe. A ledger `sent` is a quiet exit. Otherwise a `sent-<day>` stamp means
   the send happened and the ledger missed it. The lane sends nothing, logs
   ` dup`, and rewrites the `sent` row when the ledger answers. This goes one
   step past the ticket, which said a ledger miss continues. Taken literally,
   that re-sends the day after a send whose ledger write failed. Three failed
   sends end the day quietly.
7. `GET /api/metrics/daily-digest?day=&loop_min=&trip=&human=&limit=20`. `trip`
   is `NEEDS_HUMAN_TRIP_COUNT` from the `needs-human` library scope (default 2).
   A non-2xx, a body that is not a JSON object, or another `.day` gives one
   warn `daily-digest-read:<day>` a day and ` read-failed`.
8. `state/daily-digest/<day>.json`, then `dd_summary`, then `dd_render`. A
   non-zero or blank render gives one warn `daily-digest-render:<day>` a day and
   ` render-failed`.
9. `state/daily-digest/<day>.txt` holds the full text. The beat line is cut at
   `DAILY_DIGEST_TEXT_MAX_CHARS` characters, with a note naming that file.
10. The beat. rc 0: stamp first, then ledger `sent` with
    `{chars, empty, summary}`. Anything else, including rc 2 (no console):
    ledger `send-failed`, `attempts-<day>` + 1, and at 3 one warn
    `daily-digest-send:<day>`.
11. One line in `logs/daily-digest.log`:
    `<ts> day=<D> sent=0|1 empty=0|1 chars=<n> summary=none|new[ off| disabled| read-failed| render-failed| send-failed| dup]`.
    Notes, like an out-of-range knob, go to `logs/daily-digest.notes.log`.

## Re-deriving by hand (on the hub)

```bash
D=$(date -u -d yesterday +%F)
/root/harness/bin/jobs-client.sh ledger-get daily_digest "$D"          # sent | send-failed | nothing
grep "day=$D" /root/harness/logs/daily-digest.log | tail -3
cat "/root/harness/state/daily-digest/$D.txt"                          # the full text that was sent
. /root/harness/bin/jobs-client.sh && _jobs_req GET "/api/metrics/daily-digest?day=$D" | jq .
```

To re-send a day on purpose, remove both guards: the ledger row (it is kept
until someone deletes it) and `state/daily-digest/sent-<day>`. Also remove
`attempts-<day>` if it reached 3.
