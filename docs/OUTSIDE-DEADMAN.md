# K2 — the outside dead-man (progress, not just liveness)

## Why

The watchdog worker (`worker/watchdog/`) was built to page when the fleet stops
being ALIVE: a box stops pinging, or the hub stops pushing status. Nothing
outside the fleet checked whether the fleet was making PROGRESS, so every
silent stop of 2026-09 went unpaged:

| incident | what liveness saw | what was actually happening |
|---|---|---|
| 09-19 hub-lease outage | hub pinging, status flowing | no hub lane ran for 29 min |
| merge conductor, GraphQL budget empty | hub fine | 0 merges for hours |
| share mirror | nothing: it runs on GitHub | frozen for two days on leak-guard hits |
| `fleet-slo.sh` | nothing | never scheduled at all |
| project-9 | boxes fine | $643 spent in 7 days, 0 merges |

The in-fleet detectors (fleet-slo, pipeline-health, jobs-watchdog) live on the
same hub that stopped, so they cannot be the answer. K2 puts a progress judge
where the liveness judge already is: in the Cloudflare worker, on its own cron,
paging Telegram directly. No LLM and no fleet box sits in the paging path.

## How

```
jobs D1 rows ──GET /api/progress/stamps──▶ bin/progress-push.sh (hub, */10)
                                            + held rows, owed tickets, pause flags,
                                              hub-scope detectors (catalog/lanes.json)
                                            + cfg = this lane's settings rows
                                                │ POST /api/progress   (watchdog secret)
.github/workflows/publish-cromford.yml ──POST /api/stamp/share-mirror──┐  (STAMP_SECRET only)
                                                ▼                   ▼
                          harness-watchdog KV (progress:snap, progress:cfg, stamp:*)
                                                │ scheduled */5, step 5
                                                ▼
                                   worker/watchdog/src/progress.js ──▶ Telegram (Fleet topic)
```

* **Stamps** (`worker/jobs/src/routes/progress.js`, read-only, rows the fleet
  already writes, no GitHub call): per project, the last DONE triage job
  (`triage`), last DONE build/fix (`build_ok`), last finished build/fix of any
  status (`build_result`), last review verdict (`review`, `verdict_history`
  joined to its job), last merge (`merge`: the merge ledger, `merge_queue`
  landed, `merge_trains` landed), last finished qa job (`qa`), last PRICED
  cost row (`cost`); priced spend per stage over the short window and per
  project over each no-merge window — one `cost_rows` scan for all of them;
  queued build and merge rows; the `lane_ticks` rows of every named detector.
  The stamp lookback widens to the longest no-merge window, so a window never
  judges a merge older than the stamps can see.
  Each section is its own try/catch: an unreadable table is named in `errors`
  and its fields are null, never 0.
* **Hub push** (`bin/progress-push.sh`, lane `progress-push`, behind the hub
  lease): restricts to fleet.conf projects, subtracts held build rows
  (`state/pool/<p>/*.held`, BH-1461), adds tickets owed
  (`state/stale-owed.json`) as pending triage, marks paused projects
  (`flags/paused-<p>`), names the hub-scope detectors (from the lane registry
  resolved through `lanes_json_path`; unreadable is `errors: ["registry"]`
  plus one ALERTS warn, never a silent per-box reading), and attaches `cfg`. An
  unreachable jobs worker still pushes, with `errors: ["jobs-unreachable"]`.
  Under all-off (file or row) it pushes only an `all_off` marker.
* **Direct stamps**: anything that runs outside the fleet POSTs
  `/api/stamp/<name>` with `STAMP_SECRET`; the worker stamps its own clock.

## Rules

All thresholds are the `progress-push` lane's settings rows
(`catalog/lanes.d/progress-push.json`), pushed as `cfg`. The worker CLAMPS
in-band values to sane bounds (and names each clamp), rejects a config with a
non-positive or non-numeric field, or without the `progress-push` detector,
and keeps the last valid copy. It holds no threshold of its own: with no config
stored nothing is judged.

| rule | fires when | knobs (default) |
|---|---|---|
| (a) spend without progress, per (project, lane) | the lane's priced spend in the short window >= floor AND its success stamp is older than quiet (or absent). Stage -> lane via `PROGRESS_STAGE_LANES`; `any` (or unmapped) is judged against the project's newest progress of any kind. A failed build is not progress here. Paused projects skip. | `PROGRESS_SPEND_WINDOW_MIN` 60, `PROGRESS_SPEND_MIN_USD` 5, `PROGRESS_SPEND_QUIET_MIN` 180, `PROGRESS_STAGE_LANES` (lead-review:any) |
| (a2) spend with no merge, per (project, window) | spend over the window >= its floor AND no merge inside it. Paused projects skip. | `PROGRESS_NOMERGE` 1440:50, 10080:250 |
| (b) silent stop, per (project, lane) | pending work AND the lane's last result older than mult x cadence. Only lanes WITH a cadence are judged; build reads ANY finished build. Paused projects skip. | `PROGRESS_SILENT_MULT` 2, `PROGRESS_LANE_CADENCE` build:120, merge:60 — triage is out (its owed tickets already page via stale-owed, and a finished triage job exists only when the gate runs) |
| (c) watch the watchers | box-scope detectors: per watched box (`boxes.json`); hub-scope ones (`scope: hub` in the lane catalog): by the NEWEST row across boxes, since a standby hub's row is stale by design. No run on record also pages; rows from unwatched hostnames stand in only when no watched box has one; a paused lane never pages. | `PROGRESS_DETECTORS` fleet-slo:15, pipeline-health:15, cost-rollup:60, alert-warn-flush:30, ci-minutes-watch:360, progress-push:10; `PROGRESS_DETECTOR_MULT` 2 |
| (c0) the push itself | `progress:snap` older than mult x the `progress-push` cadence (20 min: the 29-min 09-19 outage pages at about 25). Every other rule is HELD while it is stale: stale stamps prove nothing. If the last push was the all-off marker, it says so instead of blaming the lease. | as (c) |
| all-off | the push is the `all_off` marker: one `fleet:all-off` incident, nothing else judged | — |
| (d) hub status stale | unchanged (step 2 of `scheduled`) | — |
| sources | each entry of the snapshot's `errors` is an incident, and every rule that reads that source is held | — |

**Clocks** (#2289 B3): every stamp inside the snapshot is aged against the
moment the snapshot was received, so a detector ticking in the same minute as
the push never sits on the line; the snapshot's own staleness is rule (c0).
Direct stamps are aged against the worker's clock, which wrote them.

## Paging

* **Confirm, then open** (#2289 B1): an incident opens only after 2
  CONSECUTIVE failing ticks (`pseen:<key>`); a tick where it does not fail
  resets the count.
* **Cooldown after a clear**: a clear sends one resolve and leaves
  `pcool:<key>` for `PROGRESS_REPAGE_MIN` (360); the same key never re-opens
  inside it, so a flapping condition pages at most once per cooldown.
* **Except the push itself**: `detector:progress-push` opens on the first
  failing tick and has no cooldown. Its limit already absorbs missed pushes,
  and a second hub outage right after a clear must still page.
* **Re-page**: an open incident is re-sent at most once per repage window,
  marked "still open".
* **Send first**: KV records a page or a clear only when Telegram answered ok
  (`tg()` returns a boolean); a failed send is retried next tick.
* One message per tick for everything new or due, one for everything cleared; a
  burst is cut to one Telegram-sized message with a "+N more" line.
* **Config pages**: a threshold change pages once with the diff (and any
  clamps); the first valid config pages "armed"; three rejected configs in a
  row page once with the reason. A changed config is put in force only after
  its page SENT; otherwise the previous one stays and the next push retries.

`GET /api/progress` shows the snapshot age, the config in force, rejects,
direct stamps, pending/cooling/open keys — readable while the hub is down.

## Credentials

| credential | opens | lives in |
|---|---|---|
| watchdog secret (`env/.watchdog-secret`, else `HARNESS_SECRET` — the same lookup as `bin/watchdog-ping.sh`) | `POST /api/progress`, `/api/progress/dry-run`, `GET /api/progress` (and the existing routes) | hub env; worker `HARNESS_SECRET` |
| `STAMP_SECRET` | ONLY `POST /api/stamp/<name>`, and only for a name in the stored `cfg.detectors`. `HARNESS_SECRET` does not open it; with it unset the route is closed. | worker secret; GitHub **Environment** `watchdog-stamp` secret `WATCHDOG_STAMP_SECRET`, deployment branches restricted to `main` |

The push is not given a separate secret: the hub already holds exactly one
watchdog credential for its ping and status push, and a second one on the same
box would not narrow what a compromised hub can do.

Follow-up (not in this change): a hub-only push secret file, so a builder box
holding `HARNESS_SECRET` cannot forge a progress snapshot.

## Dry run (before arming)

```
bin/progress-push.sh --dry-run
```

Builds the same payload from the live fleet and POSTs it to
`/api/progress/dry-run`, which validates the config (reasons and clamps) and
evaluates every rule with the stored direct stamps — and writes nothing and
pages nothing. It prints each incident that WOULD be raised (and whether it is
already open or cooling). It runs even with the lane switched off.

## Deploy order

1. `harness-jobs` worker (the stamps route; no schema change).
2. `harness-watchdog` worker (routes + step 5; KV only, no new binding). Set
   `STAMP_SECRET` only when the share-mirror stamp is wanted. Nothing is judged
   until the hub pushes a valid config.
3. **Before merging**, create the `watchdog-stamp` GitHub Environment with a
   deployment-branch rule of `main` only and no required reviewers.
   `publish-cromford.yml`'s job now names it, and GitHub silently auto-creates an
   environment a workflow names — without any branch rule.
4. Hub: land the lane with `bin/harness-ctl.sh off progress-push` set, run
   `bin/progress-push.sh --dry-run` on the hub, adjust settings rows until what
   it would page is real, then switch the lane on. The first push pages "armed".
5. Later, for the public copy: add `WATCHDOG_STAMP_SECRET` to that environment
   and `STAMP_SECRET` to the worker, and add `share-mirror:1440` to
   `PROGRESS_DETECTORS`. The daily `schedule:` trigger on `publish-cromford.yml`
   is already there (harmless without the secret), and only an armed publish
   stamps. The `share-mirror` stamp id predates Cromford: it was the retired
   mirror's, and keeping it leaves the deployed worker untouched.

Kill switch: `bin/harness-ctl.sh off progress-push` stops the push, and the
worker then pages `detector:progress-push` once — deliberately. To silence K2
entirely, remove `progress:cfg` from the watchdog KV as well.

## Tests

* `worker/watchdog/test/progress.k2.test.js` (shell: `tests/watchdog-progress.k2-test.sh`,
  which FAILS when node is missing) — every rule firing and not firing,
  config-as-data and clamps, source holds, snapshot-relative ages, hub-scope
  newest-row, confirm/cooldown/flap, send-first retry, repage, resolve,
  stale-push hold, all-off, burst truncation, config-change and reject pages,
  stamp credential and name restriction, dry-run writes nothing, `scheduled()`.
* `worker/jobs/test/progress-stamps.k2.test.js` — each section against the
  shipped schema in node:sqlite, one cost scan, section errors, clamps,
  detector name refusal.
* `tests/progress-push.k2-test.sh` — the payload the hub builds, the secret
  lookup, all-off marker, dry run.
