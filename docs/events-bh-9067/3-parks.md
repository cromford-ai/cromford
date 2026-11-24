# Parks
<!-- owner: BH-9067.3 (BH-9075) -->

This slice puts every park in one D1 table, `parks`. The blocked-resolver and
the merge conductor then read only the rows that changed. The 2,367 state
record files stay as the cache. Their removal is a later ticket, after
`br_parks_mode=on` holds for 7 days.

Dated note: [docs/notes/2026-11-17-BH-9075-parks.md](../notes/2026-11-17-BH-9075-parks.md).
Conductor part: `docs/MERGE-CONDUCTOR.md` section 11, "Parks delta (BH-9075)".

## Surface

- Table `parks`, key `(project, ck)`:
  `worker/jobs/schema.d/202611150806-bh-9075-parks.sql`.
  - `idx_parks_project_updated(project, updated_at, ck)` serves the changed page.
  - `idx_parks_state_updated(state, updated_at)` serves the hotfix list and the prune.
- Routes (bearer), `worker/jobs/src/routes/parks.js`:
  - `PUT /api/parks {rows}`: 1 to `parks.put_max_rows` (100) rows in one
    `json_each` statement. A row older than the stored row loses
    (`WHERE excluded.updated_at >= parks.updated_at`). A text value `-` keeps
    the stored value.
  - `GET /api/parks/changed?project=&since=&limit=&hotfix=1`: rows with
    `updated_at > since`, ordered by `(updated_at, ck)`, `done` rows included.
    `since` is `<ts>` or the keyset token `<ts>:<ck>`. The answer is
    `{rows, hotfix?, next, truncated, as_of}`.
  - `GET /api/parks/prune` (always a dry run) and `POST /api/parks/prune`:
    delete `done` rows older than `parks.retention_days` (30), at most
    `parks.retention_batch` (500) per run. While `parks.prune_dry_run` is 1
    (the seed) every run is a dry run. Every run writes one `retention_runs`
    row (rule `parks.done`).
- Client `bin/lib/jobs/parks.sh`: `parks_put`, `parks_changed`, `parks_prune`.
  A failure prints nothing and answers rc 1. It never prints an empty "no changes".

## Writers (`bin/lib/parks-write.sh`)

Every note goes to `state/parks-outbox/` first. `pw_flush` sends the outbox
and deletes a file only after a 200 for its batch. A failed send keeps the
files for the next flush. Over `PW_OUTBOX_MAX` the oldest notes are deleted
and `pw_flush` writes the marker `state/parks-outbox/.dropped-at`. It does not
write in `state/blocked-resolver/`. The resolver's `_brp_cursor` reads a cursor
file older than the marker as 0, so the next resolver tick backfills.

| site | call | note |
|---|---|---|
| `bin/fly-pool.sh` reap, `deferred N times` park (fragment 3400) | `pw_queue_park` | `pool-deferred-max`, state `hotfix` for a hotfix row |
| `bin/fly-pool.sh` reap, `died N times` park, next to the `.failed.json` writer | `pw_queue_park` | `pool-died-twice` |
| `bin/lib/br/record.sh` `br_set_outcome` | `pw_note_outcome` | `done` on ABANDONED or RESOLVED_MERGED |
| `bin/merge-conductor.sh` `tick_project` end | `mc_parks_tick_end` -> `pw_conductor_sync` | `parked` for a new or changed BLOCKED_HUMAN / RED_TWICE row, `done` when it leaves |

The queue reason mapping is the one `br_from_queue` uses, case for case.

## Modes and knobs

| knob | where | default | what |
|---|---|---|---|
| `BR_PARKS_MODE` | `lane.blocked-resolver.br_parks_mode` | shadow | off / shadow / on |
| `BR_PARKS_PAGE` | `lane.blocked-resolver.br_parks_page` | 500 | rows per changed page |
| `BR_PARKS_MAX_PAGES` | `lane.blocked-resolver.br_parks_max_pages` | 20 | pages per project per tick |
| `BR_PARKS_LAG_S` | `lane.blocked-resolver.br_parks_lag_s` | 120 | cursor hold-back |
| `BR_PARKS_SHADOW_LIST_MAX` | `lane.blocked-resolver.br_parks_shadow_list_max` | 20 | cks named per list |
| `BR_PARKS_PRUNE_EVERY_S` | `lane.blocked-resolver.br_parks_prune_every_s` | 86400 | prune call period, 0 = never |
| `MC_PARKS_DELTA_MODE` | `lane.merge-conductor.mc_parks_delta_mode` | off | off / shadow / on |
| `MC_PARKS_DELTA_MAX_SKIP_S` | `lane.merge-conductor.mc_parks_delta_max_skip_s` | 1800 | longest skip |
| `MC_PARKS_DELTA_LAG_S` | `lane.merge-conductor.mc_parks_delta_lag_s` | 120 | read overlap |
| `PARKS_TIMEOUT_S` | `lib.parks.parks_timeout_s` | 5 | request timeout |
| `PW_ENABLED` | `lib.parks.pw_enabled` | 1 | writers on |
| `PW_BATCH` | `lib.parks.pw_batch` | 100 | rows per PUT |
| `PW_OUTBOX_MAX` | `lib.parks.pw_outbox_max` | 10000 | outbox cap |

Resolver modes:

- `off`: the file sources only. No parks request.
- `shadow`: the file sources are the tick output. Then one line compares them
  with the parks mirror:
  `parks-shadow: files=N parks=M missing=<cks>[+k] extra=<cks>[+k] queue=f/m conductor=f/m projects=K`.
  A read failure writes `parks-shadow: read failed (<why>) — files used`.
  No path writes an ALERTS line.
- `on`: the queue source is the parks mirror. Any read failure, a page cap or
  a project at cursor 0 uses `br_from_queue` for that tick. The conductor
  source always reads its own rows (ASSUMPTION A-3 of the plan).

The mirror is `state/blocked-resolver/parks/<p>.mirror` with
`<p>.cursor`. Cursor 0 (no cursor or no mirror) means backfill: the file
sources' queue and conductor rows are PUT with `updated_at=1`, so any real
write wins over them, and the mirror is read again from 0.

The cursor stays at most `now - BR_PARKS_LAG_S`. It also stays one second
below the oldest note of the project still in `state/parks-outbox/` on the
resolver's box. A note whose send failed reaches D1 later with its
write-time `updated_at`, and the next read still finds it. A note that waits
in the outbox of another box longer than `BR_PARKS_LAG_S` is not covered by
this rule.

## Flip steps

1. Deploy. The jobs worker deploy applies the schema fragment.
2. Read the shadow lines on the hub:
   `grep parks-shadow /root/harness/logs/blocked-resolver.log | tail -5`.
3. Read one dry prune: `grep parks-prune /root/harness/logs/blocked-resolver.log | tail -1`.
   Then set the settings row `parks.prune_dry_run` to 0.
4. When `missing=-` holds and every `extra=` ck has a known cause (a queue
   park the resolver already rebuilt stays until its outcome, ASSUMPTION A-4),
   set `lane.blocked-resolver.br_parks_mode` to `on`.
5. For the conductor, set `lane.merge-conductor.mc_parks_delta_mode` to
   `shadow`, read the `decision=parks-quiet-shadow` lines, then set `on`.

## Owed

- The PREQUEUE D1 read of the conductor delta is owed. Issue #9061 holds no
  prequeue read. This slice ships the non-prequeue skip plus a local guard: a
  pre-queue verdict file of the repo newer than the last walk always walks.
- The removal of the state record files (after 7 days of `on`).
