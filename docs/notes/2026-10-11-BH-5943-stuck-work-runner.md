# stuck-work on the per-project runner, its repeated reads cut; archie-fm-queue's settings fallback (BH-5943)

Doc: OPERATING

Parent: BH-5938. Two hub lanes had the same kind of fault: work that blocks
itself on every tick.

- stuck-work: a 320 s tick on a 5-minute cron. Every second tick found its
  own lock held and logged `busy`.
- archie-fm-queue: 5 or more projects logged `archie.manage settings could not
  be read; skipped` 14-15 times a day.

## stuck-work: the read census

One tick, per item, before this change:

| Read | Per | Cached before | After this change |
|---|---|---|---|
| `vd_standing` (worker GET) | open PR | no | no (on purpose, see below) |
| `sw_first_seen` (`GET /api/ledger?kind=stuck_work_seen`) | open PR, plus 1-2 per ai-build ticket | no | memo in `state/stuck-work/seen/` |
| commit status + Mergify check | open PR | yes (BH-4660) | unchanged |
| `mc_resolver_claim_get` | open PR | local file | unchanged |
| `pr_state_page` | tick | at most 5 GETs | unchanged |
| `job_ledger_row stuck_work <key>` | item past its SLA | no | mirror in `state/stuck-work/led/` |

With about 300 open cromford PRs, a tick made about 600 or more worker
GETs at `JOBS_TIMEOUT=8`. The two memos remove the `stuck_work_seen` GETs and
the `stuck_work` row GETs on every tick after the first.

`vd_standing` stays uncached. A "no verdict" answer changes when a lead
reviews, and a stale copy would send a false "awaiting lead review" page. If
the profile line shows it is still the top cost, that is a new ticket.

### The two memos

- `state/stuck-work/seen/<sha1 of key>`: one line, the epoch. A first-seen
  anchor is written once and never changed, so `sw_first_seen` reads the memo
  first. It writes the memo only after a good ledger answer (a parsed row, or a
  PUT that succeeded). It never writes one for `?`. A memo that is not all
  digits is ignored and replaced.
- `state/stuck-work/led/<sha1 of key>`: `{"status":…,"detail":"<JSON
  string>"}`, the shape `job_ledger_row` prints. Only this lane writes the
  `stuck_work` kind. The lane writes the mirror after a GET that answered rc 0
  and after a PUT that succeeded. A failed GET or PUT writes nothing, so the
  next tick tries the page again, as before. A mirror that does not parse, or
  that has an empty status, falls back to the GET.

Both use the CI cache's root rule: `${HARNESS:-${H:-}}`, and under
`HARNESS_TEST_SANDBOX=1` only an explicit `HARNESS`. Each run deletes memo and
mirror files older than 30 days.

Limits:

- The mirror is per box. During a hub lease failover the new box has no mirror
  and reads the ledger, which is the behaviour before this change.
- If a person deletes a `stuck_work` row by hand, the mirror still says
  `paged`. The lane does not page that episode again. A new episode has a new
  key (item, state, entered_at).

### The profile line

Each run that reads its facts appends one line to `logs/stuck-work-profile.log`:

    <ts> project=<p> secs=<n> facts_s=<n> loop_s=<n> items=<n> seen_hit=<n> seen_miss=<n> led_hit=<n> led_miss=<n> ci_hit=<n> ci_miss=<n> thread_skip=<n>

The counts come from `SWF_COUNT_FILE`, which the readers write in the same run.
The summary line in `logs/stuck-work.log` is unchanged.

## stuck-work: three modes

- `stuck-work.sh --dispatch`: the cron line. It calls `pl_dispatch stuck-work
  <spread> bin/stuck-work.sh`, prints the dispatch line to
  `logs/stuck-work-cron.log`, and exits. It takes no lock and reads no fact.
  `STUCK_WORK_DISPATCH_SPREAD_S` (default 240, 0..290) spreads the starts over
  the 5-minute cadence.
- `stuck-work.sh <project>`: one project's run, on its own lock
  `locks/stuck-work-<project>.lock`.
- `stuck-work.sh`: the home project's run, for hand runs.

The script checks its arguments before any worker request. A bad name, a
project fleet.conf does not resolve, or a name that is also a cache dir under
`state/stuck-work/` (`ci`, `thread`, `seen`, `led`) exits 2.

The dispatcher and each watched run both pass `lane_gate_or_exit`. At
:00/:15/:30/:45, `lane_start_offset` can sleep each of them by up to
`cadence*30` = 150 s when `lane_start_spread_s` is set. With the runner's
spread, a watched run can then start up to 150 + 240 + 150 s after the cron
tick, which is past the 5-minute cadence. With the default
`lane_start_spread_s` of 0, the gate adds 0 s. An unwatched run does not pass
the gate, so it never sleeps there (review F2).

The home run also takes the legacy `locks/stuck-work.lock` on fd 8. That covers
the deploy window, when a tick of the old code can still run.

### The watched set

`STUCK_WORK_PROJECTS` (settings row `lane.stuck-work.stuck_work_projects`):

- `self` (default, also empty): only the home project. This is the behaviour
  before this change: one repo, the same pages.
- `all`: every fleet.conf project.
- a comma list of project names, exact match.

Any other value gives one stderr line in `logs/stuck-work-cron.log` and reads
as `self`. The dispatcher starts a run for every project. A run for a project
that is not watched exits 0 before the lane gate. It reads no flag, POSTs no
liveness row, reads no ledger row, and writes no log and no lane-gate stamp.
Its one read is `lane_env_apply`, because `STUCK_WORK_PROJECTS` can be a
settings row. That read uses the box settings cache. The cache has a TTL of
`LANE_GATE_CACHE_S` (60 s). The dispatcher refreshes it just before it starts
the runs. A run that starts more than 60 s later, or a hand run on a cold
cache, makes one `GET /api/settings` and rewrites `state/settings-cache.json`.
Other hub lanes share that same read. (Review F1: before this fix, each
unwatched run passed the gate first, which POSTed a liveness `ran` row. That
was 12 extra worker writes a tick with the default `self`, and it hid a dead
home run on the liveness page.)

The home project is the first fleet.conf project whose repo is `sw_repo`, else
`cromford`. It keeps every name it had: `logs/stuck-work.log`, the
`no-token-*` and `outage-*` marks in `state/stuck-work/`, `--project
<home>` on pages, ticket prefix `STUCK_WORK_KEY_PREFIX` (BH), and the snapshot
row `stuck_work_snapshot/latest`.

Any other watched project uses `logs/stuck-work-<p>.log`, marks in
`state/stuck-work/<p>/`, `--project <p>` on pages, and the ticket prefix from
the launch line in `prompts/<p>.md`. A project with no prefix gets PR facts
only. Its snapshot row is `stuck_work_snapshot/<p>`.

Known gap: the daily digest reads only `stuck_work_snapshot/latest`. Rows for
other projects have no reader yet. With the default `self` there is no gap.

Before an operator sets `all`: the first tick can send one page per past-SLA
item in each of the 13 fleet projects. Each page carries its own `--project`.

## archie-fm-queue: the settings fallback

The read fails because of a transient worker 503, not a bad row. #5781 counted
92 `GET /api/settings/archie…` 503s on the hub in 2 hours (2026-10-09,
19:00-21:00Z), all at :00, :15, :30 and :45. archie-fm-queue runs `*/10`, so
its :00 and :30 ticks meet that burst.

When `afm_mode` fails, the lane now calls `afq_mode_cached <project>
ARCHIE_FMQ_MODE_CACHE_MAX_S <now>`. It reads `state/settings-cache.json`, the
list lane-gate writes once a tick. If the cache is at most
`ARCHIE_FMQ_MODE_CACHE_MAX_S` old (default 1200, 0..3600, 0 = off), the project
runs on the cached mode and the log says:

    <p>: the archie.manage settings could not be read (<cause>); using the box settings cache from <n>s ago: mode=<m>

Otherwise the project is skipped, as before:

    <p>: the archie.manage settings could not be read (<cause>); skipped this tick (no action without the ledger)

`<cause>` is the word `bin/lib/jobs/req.sh` writes to `JOBS_STATUS_FILE`
(`http=503`, `curl_rc=28`, `no-secret`), or `unknown`.

The value order is afm_mode's: `archie.manage.<p>`, then `archie.manage` (each
from `values`, then `seeded`), then `AFM_MODE_DEFAULT` (`on`) when the list has
neither. A value that is not `on`, `observe` or `off` reads as `observe`. A
cache from the future, a `fetched_at` that is not all digits, and a
`fetched_at` of 0 (a write marked it stale) are refused.

Why 1200: two ticks. Today `archie.manage=off` reaches a project within one
tick (10 minutes). With the fallback, the worst case is 10 + 20 minutes.

Since BH-5781 (#5824, merged), `setting_get` already answers from that cache
when it is under 60 s old (`JOBS_SETTINGS_CACHE_S`). This fallback covers the
case where the cache is older than that and the worker also fails.

Limit: the fallback is for the mode read only. If a cap read
(`archie.cap.<playbook>`) also fails in the same burst, that playbook does
nothing for the project this tick, as before.

## Probes after deploy

The build does not run these. Run them on the hub:

1. `tail -n 5 /root/harness/logs/stuck-work-cron.log`: lines
   `stuck-work dispatch: started N project run(s)`.
2. `tail -n 20 /root/harness/logs/stuck-work-profile.log`: `secs=` under 300,
   and `seen_hit` and `led_hit` above 0 from the second run.
3. `grep -c ' busy$' /root/harness/logs/stuck-work.log` over 24 hours: it falls
   from about 144 towards 0.
4. `grep -c 'could not be read' /root/harness/logs/archie-fm-queue.log` over 24
   hours, and `grep -c 'box settings cache'` for the projects processed
   instead of skipped.

## Tests

- `tests/stuck-work-dispatch.bh-5943-test.sh`: the dispatcher, the per-project
  locks, the watched set, the argument checks.
- `tests/stuck-work-memo.bh-5943-test.sh`: the two memos, their fail-open
  rules, the profile line, the prune.
- `tests/archie-fm-queue-mode-cache.bh-5943-test.sh`: the fallback, its age
  bound, the knob, the cause word.
