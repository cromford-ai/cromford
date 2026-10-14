# Every automatic lane has one off-switch, one place its numbers live, and one page that shows both

**What it is:** BH-1132 phase A + BH-1165 phase C — `catalog/lanes.json` (the registry of every
mechanism this fleet runs on a timer), `bin/lib/lane-gate.sh`
(`lane_gate_or_exit` / `lane_knob`, the two calls a lane makes),
`bin/harness-ctl.sh` (the operator's hand), and three worker routes
(`GET /api/lanes/registry`, `GET /api/lanes/status`,
`POST /api/lanes/all-off|all-on`) that a settings screen reads.

**Why it exists:** the operator, 2026-09-20 — *"stop any automatic mechanisms on the
harness for now … and if not, add hot fixes so we can have control on all those
harness mechanisms and be able to stop or start them or change their values min
max etc."* That morning the fleet ran 267 cron lines behind about 40 `flags/*`
switches whose names nobody could derive from the lane they stopped, and whose
`0` meant *off* for `TRIAGE_MAX_FAMILIES` and *unlimited* for the autopilot
daily cap. `bin/alert-triage.sh` burned $793 in twelve hours (#1039) and the
only way to stop it was to know which file to touch on which box. Nothing
listed the mechanisms, so nothing could show an operator the one that was
burning.

**The three decisions that shape it:**

1. **Fail open, always.** With no flag, no row and no reachable worker, every
   gated lane behaves byte-for-byte as it did before this landed. A control
   plane that stops the fleet when a database blinks is worse than none: the
   pre-BH-1132 state of every one of these lanes is "runs with no gate at all",
   and that is the state a failure has to degrade to. An unreachable worker
   answers from the last cached answer, so a row an operator wrote a minute ago
   is not undone by an outage either.
2. **The gate writes no `lanes` row tick.** That table is keyed
   `(project, box)` and is the *triage* lane's staleness row. A `paused` tick
   posted by a gated `review-prs` or `merge-conductor` would refresh
   `last_tick_at` for that box and silence the stale-lane pager for a lane that
   was genuinely dead. `paused since` comes from the `pause_flags` row's own
   `updated_at` instead — when the operator flipped it, not when a cron next
   noticed.
3. **The registry records what is true today, not only what BH-1132 added.**
   Every pre-existing switch is listed as a `switch.aliases` entry, **with its
   polarity**, so the page can never report a lane as running while an old flag
   holds it — and never the reverse either. Not every one of those ~40 flags is
   an off-switch: `flags/fly-pool-<project>` is what makes the pool run at all,
   and `conductor-owns-merges` / `merge-conductor-merge` *arm* the conductor.
   Listed as plain off-aliases they made the status route show an armed
   conductor as OFF, held by the flag that armed it, with a toggle that was a
   no-op. So each alias carries `off_when`: `present` (an active row stops the
   lane), `absent` (an ENABLE flag — reported under `enables`, never as off) or
   `partial` (changes behaviour only — reported under `modifiers`).

**How an operator reaches it:**

| Surface | Where | What it says |
|---|---|---|
| the whole fleet | `bin/harness-ctl.sh status [project]` | one row per lane: on/off, cadence, $ today, $ 7d, and which switch is holding it |
| one lane | `bin/harness-ctl.sh show <lane> [project]` | the full status row, knobs included, as JSON |
| stop / start one | `bin/harness-ctl.sh off <lane> [project] "<reason>"` / `on <lane> [project] "<reason>"` | writes `flags/lane-off-<id>[-<project>]` and the `pause_flags` row of the same name, file first; since BH-1165 both halves take the same arguments and both record the reason |
| change a number | `bin/harness-ctl.sh set <lane> <ENV> <value> [project]` | writes settings key `lane.<id>[.<project>].<env>`, refusing anything outside the registry's `[min,max]`, and (BH-1985) a project fleet.conf does not list |
| put this box's numbers on the page | `bin/harness-ctl.sh seed [--dry-run] [project]` | writes a settings row for every registered knob this box's env sets and no row covers; prints MISMATCH rather than overwriting where a row disagrees |
| stop a box lane on ONE box | Settings → `/settings/<id>` → BOXES (no `harness-ctl` verb) | writes the `pause_flags` row `lane-off-<id>.box.<box>`; the gate of a `scope: "box"` lane reads it after `all-off` and `lane-off-<id>`, for THIS box only (`JOBS_BOX`, else `hostname -s`; an unusable name skips the check). Hub and project lanes never read a box name (BH-2327) |
| stop everything | `bin/harness-ctl.sh all-off "<reason>"` / `all-on` | one `pause_flags` row named `all-off`; `all-on` clears **only** that row |
| the gated ticks | `logs/lane-gate.log` | `[lane-gate] <id>[/<project>] SKIPPED — <why>`, one line per lane per hour |
| the paused marker | `state/lane-gate/<id>[-<project>].paused` | the ISO time and the reason the last gated tick saw |
| the tick rows | `lane_ticks` via `GET /api/lanes/status` | per lane, per project, per box: `last_tick_at` + `ran`/`paused` |
| a file nobody wrote a row for | `lane_flag_sightings` via the same route | `off_source: "flag"` and the box holding it |
| the sighting markers | `state/lane-gate/.seen-<flag>` | written only after the worker took the sighting, so a failed post is retried |
| the caches | `state/lane-gate/<name>.json`, `state/settings-cache.json` | `fetched_at` + the answer; these are what an outage falls back to |
| the API | `GET /api/lanes/registry`, `GET /api/lanes/status[?project=]` | what the Mission Control screen (phase B) reads |

**Knob resolution, most specific first:** settings
`lane.<id>.<project>.<key>` → settings `lane.<id>.<key>` → the process
environment (`env/global.env`, as today) → the registry default; then clamped to
the registry's `[min,max]`. One `GET /api/settings` per tick fills
`state/settings-cache.json`, so a lane reading 26 knobs costs one request.
`zero_means` travels with every knob, so no surface has to remember that `0`
means *off* for one lane and *unlimited* for the next.

**The settings key is `lane.<id>[.<project>].<env lowercased>`**, the form
published in the contract and written by the console. An earlier draft of this
work resolved it through a short alias in the registry to stay under 64
characters; it bought nothing (the longest real key across all eleven
`fleet.conf` projects is 61 characters, and a hub-scoped lane never gets a
project segment) and cost everything — the console wrote one spelling and the
reader looked up another, so a knob set on the page landed on a row the lane
never read and nothing errored anywhere. One knob, one key.
`tests/lanes-registry-test.sh` section 9 builds every key for every project and
fails on one the API would refuse.

**The clamp is never silent, and the environment is never clamped.** A settings
row outside the registry's bounds is trimmed and one line says so;
a value that came from `env/global.env` is used **as it stands**, with a line
saying it is out of bounds. Trimming what the env already says would change
fleet behaviour the first time a lane adopted `lane_knob`, with nobody deciding
— the opposite of additive.

**Spend nobody can attribute is reported as null, not as a number.**
`bin/agent-call.sh` writes `(stage, project)` and nothing else that names a
lane, so `merge-conductor`, `review-autopilot` and `review-prs` all land as
`stage=review` with a real project. Handing each of them the same fleet-wide sum
would tell an operator three lanes are each spending $X when one of them spent
it, so a shared signature reports `cost_attribution: "shared"`,
`cost_shared_with: [ids]` and null counts.

**Superseded: `<key>` was once a registry alias.**
`PUT /api/settings` validates every key against `^[a-z0-9_.-]{1,64}$`, and the
env name does not fit:
`lane.review-autopilot.project-8.review_autopilot_daily_cap` is past
64 characters before anyone has typed a value, and the 400 would arrive at the
operator's click. So every knob carries a short `key` beside the `env` the
script actually reads (`REVIEW_AUTOPILOT_DAILY_CAP` → `daily_cap`), the whole
key is lowercased, and `tests/lanes-registry-test.sh` builds every key for
**every** project in `fleet.conf` and fails on one that would be refused. The
reader (`lane_knob`), the CLI (`bin/harness-ctl.sh set`) and the console all
take the key from that one field, because two writers spelling one knob two ways
is two rows and an operator whose change does nothing.

**The status payload is a published contract:**
[lanes-status-contract.md](lanes-status-contract.md) is what the Mission Control
screen reads, and `worker/jobs/test/lanes-control.test.js` pins this route to it
field for field. Phase A stated two limits honestly rather than papering over
them, and **phase C (BH-1165) closed both**: `off_source` could never be
`"flag"` (a file under `flags/` that no row drove was box-local and unread), and
`last_tick_at` was null for every lane except the one the registry marks
`stats.lanes_row`. The gate now reports a box-local file as a SIGHTING and
posts its own tick row, so both answers exist — and neither is guessed: no
sighting, no `"flag"`; no tick row, still `null`. A lane no status source
mentions reports **null** counts, never zeros: "unknown" and "did nothing" are
different answers.

**Scope:** 79 lanes registered (every script any `cron/*.cron` line invokes,
plus `bin/fly-pool.sh`, which `bin/fly-pool-tick.sh` fans out per project).
Phase A gated nine; **phase C (BH-1165) gates 78 of the 79** — every lane whose
script this repo ships. The one exception is `orc-monitor`, whose script lives
in `/root/orchestrator`: it declares `external: true` with the reason, and
`tests/lanes-registry-test.sh` section 12 fails on any other unwired lane, and
on an `external` claim whose script turns out to be in this repo.

## Phase C (BH-1165) — what changed

1. **Every lane this repo owns gates.** Each cron-invoked script carries the
   same shipped header — source `bin/lib/lane-gate.sh`, `lane_gate_or_exit <id>
   [project]`, `lane_env_apply <id> [project]` — and section 5 of the registry
   suite EXTRACTS that header from the shipped file and EXECUTES it against a
   scratch harness holding `flags/all-off`. A grep would not do: PR #1136
   shipped nine wirings that sourced `$${HARNESS}` (`$$` is the PID), so every
   source failed silently and a grep passed on all nine.
2. **`lane_env_apply` moves the numbers without rewriting 320 reads.** The 79
   lanes read some 320 `${KNOB:-default}` variables between them. For every knob
   the REGISTRY declares for this lane, if a settings row exists, the resolved
   (and clamped) value is exported — so the script's own unmodified read picks
   it up. **Nothing is exported without a row**: not the registry default, not
   the env, so a box with no rows behaves byte-for-byte as it does today. The
   loop is over `catalog/lanes.json` and never over the settings table: a row is
   operator input arriving over HTTP, and walking the table would let
   `lane.alert-triage.path` export `PATH` into a lane that runs a model with a
   token in its environment.
1a. **And it runs ABOVE the lane's work, which section 5 cannot see.** Section 5
   lifts the header's two lines OUT of the script and runs them, so it proves the
   header works, never where it sits. `bin/untriaged-sweep.sh` carried it after
   three of its four board sweeps: `harness-ctl all-off "incident"` stopped a
   QUARTER of that lane — at the next `*/30` tick the hub still curled the
   project-1, project-2 and project-3 boards with each client's internal API token,
   wrote their `UNTRIAGED >1h` ALERTS lines and beat for them, and only then
   logged `untriaged-sweep SKIPPED — all-off`, so the stop looked like it had
   taken. Section 19 of the registry suite walks every wired script's TOP-LEVEL
   lines and fails when anything that leaves this box (`curl`, `gh`, `ssh`,
   `scp`, `rsync`, `node`/`npm`, `beat.sh`, `git push`, or a function in the
   same file that runs one) precedes the gate;
   `tests/untriaged-sweep-gate-test.sh` is the same fact behaviourally — the
   shipped script, a recording `curl` on PATH, zero board requests under
   `flags/all-off` and all four under no flag. That lane's env loads moved above
   the header together (the four files set disjoint project-prefixed names), so
   the gate still sits below the env load for 2a.
2a. **It runs BELOW the env load, and that is load-bearing.** The first cut of
   phase C put the whole header near the top of each script — above
   `set -a; . env/global.env` in 24 of them — so the env file re-assigned every
   knob the row had just exported. The lane ran on `env/global.env`, the page
   went on reporting `source: settings`, and nothing errored anywhere: the exact
   shape this ticket exists to close, shipped inside the fix for it. Scripts
   whose env load is late (`bin/cost-rollup.sh` at line 1586,
   `bin/review-rescue.sh` at 514) call it in BOTH places — the knobs they read
   before the load have no other way to see a row, and applying twice is
   idempotent because the settings cache is already warm. Section 16 of the
   registry suite computes each script's top-level env-load block and fails on
   any `lane_env_apply` above it, and section 13 of `tests/lane-knob-test.sh`
   runs `bin/clock-sync.sh`'s OWN preamble with an `env/global.env` saying 30
   and a settings row saying 777.
2b. **Not every registered name is settable.** Registering every `${X:-…}` a
   wired script reads (section 7) pulled 217 new names in. Today
   90 (recounted by BH-1291) registry knobs carry `settable: false`, because
   they are not numbers an operator tunes: the command the lane runs (`CLI_CHECK_SSH`,
   expanded UNQUOTED as `$SSH_CMD "root@$1" "bash -s"`;
   `PROMPT_EVAL_AGENT_CALL`; `OAUTH_USAGE_FETCH`, run with the OAuth token in
   its environment), the HOST it talks to (`JOBS_URL` — every request of that
   tick carries `authorization: Bearer $HARNESS_SECRET`; `*_API_BASE` —
   `MIGRATION_TOKEN` is POSTed to it), the PATH it deletes under
   (`DISK_CLEAN_REPOS`), the IDENTITY it claims (`JOBS_BOX`,
   `HARNESS_PR_AUTHORS`) or a TEST SEAM (`AUTH_CHECK_LIB`, `BACKUP_NOW`). Those
   carry `settable: false`: still REGISTERED (so section 7 keeps announcing a
   new one) and still printed by `show`, but refused at all four write surfaces
   — `harness-ctl set`, `harness-ctl seed`, the console (`laneRows` drops them
   and `validateKnob` refuses them) and `PUT /api/settings` itself — and ignored
   by `lane_knob`/`lane_env_apply` even if a row somehow exists, with one line
   an hour saying so. `bin/poll-commands.sh`, the other thing the console can
   drive, runs a fixed verb list for the same reason. Three hazard-SHAPED names are reviewed exceptions and stay settable —
   `RUNNER_TRIAGE` and the two `HOUSEKEEPING_RUNNER`s NAME a runner out of the
   closed list `bin/agent-call.sh` dispatches (`runner_ready` refuses anything
   else and the case has no default arm), and which runner triage runs on is the
   spend lever the $793 night turned on. Section 17 of the registry
   suite refuses a new hazard-shaped name that is not marked and not on that
   named list, and section 18
   refuses a `default` carrying shell text (`$(date +%s)`) that the page would
   render as a value an operator could copy.
3. **Per-lane liveness.** `lane_ticks` is keyed `(lane, project, box)` and every
   tick posts one (`POST /api/lanes/liveness`), gated or not — a paused lane is
   still alive, and a page that cannot tell "stopped" from "dead" is the page
   this ticket exists to stop shipping. It is a different route and a different
   table from `/api/lanes/tick`, for the reason in decision 2 above.
4. **A box-local flag file is visible.** The gate posts what it found
   (`POST /api/lanes/flag-seen`) into `lane_flag_sightings`, with the box. It is
   a SIGHTING and not a decision: nothing gates on that table, because writing
   the file back into `pause_flags` would turn one box's hand touch into a
   fleet-wide stop the next time every other box reconciled. A sighting named
   `all-off` holds **every** lane on that box, not just whichever one ticked
   first: the gate's marker is keyed on the flag NAME, so one lane posts the row
   and the other 77 are throttled for an hour — matching it by lane id reported
   1 of 79 as off while the box was fully stopped. It also surfaces at the top
   level as `all_off_flag_boxes`, kept apart from `all_off` because ALL ON
   clears the row and cannot touch the file. A sighting is matched on the switch
   NAME; the `lane` fallback (for a name this view did not build) is **scoped to
   the project it names**, or `?project=project-3` reported review-prs as stopped
   by `lane-off-review-prs-project-2` on orgo-2 and sent an operator to a box
   holding nothing of project-3's. A sighting with no project is box-wide and still
   holds for every project.
3a. **An outage costs one write attempt per TTL, not one per lane per tick.**
   The gate's flag reads and the settings GET are cached through a miss stamp;
   the liveness POST was not, so a worker that was down cost every tick of all
   78 lanes on every box a full `curl -m 8 --connect-timeout 3` plus its retry —
   ~7s against a black hole, ~17s against a host that accepts and hangs — BEFORE
   the lane did any work, and a per-minute lane lost a quarter of its cadence to
   it. `state/lane-gate/.post-miss` throttles every post for
   `LANE_GATE_CACHE_S` after the first failure and is cleared by the first
   success, so a healthy fleet writes exactly as often as before. A throttled
   post returns the same rc a failed one always did, so `_lg_flag_seen` leaves
   its marker in place and reports again next tick.
4a. **A box-wide lane can read a per-project switch inside its own tick.**
   `bin/lib/lane-gate.sh`'s `lane_paused <lane> <project>` is the predicate
   `lane_gate_or_exit` is built on, for a lane that is `scope: project` but
   sweeps every project in ONE tick: "this project is off" cannot be an exit
   there, because the others still have work waiting, so the loop asks and
   `continue`s. `tier2-merge-sweep` was its one caller and BH-1366 retired that
   lane; the predicate and its `tests/lane-gate-test.sh` §17 coverage stay for
   the next lane of that shape.
5. **`unlimited` is a row, not a magic zero.**
   `lane.<id>[.<project>].<env>.unlimited` is honoured only where the registry
   says `zero_means: "unlimited"`, and REFUSED with a line where `0` means
   *off* — there it would mean the exact opposite of what was asked.
6. **`on` takes the same arguments as `off`.** `on <lane> "<reason>"` used to
   read the reason as a project and refuse; the resume — a decision taken during
   an incident — recorded nothing. The one ambiguous case (a single argument on
   a project lane that NAMES a project) is refused rather than guessed, because
   guessing would clear the fleet-wide switch while printing a line an operator
   reads as "I resumed that project".
7. **`bin/harness-ctl.sh seed`** writes this box's env values into the rows the
   page shows, only where no row exists, printing a MISMATCH line where the row
   disagrees with this box — the rows are fleet-wide and the env files are per
   box, so a seeding that overwrote would silently re-tune the fleet.
8. **Credentials are never knobs.** A credential-shaped name may be registered
   only as a number (`POOL_GH_TOKEN_ROTATE_EVERY` is seconds); a string one is
   refused from the registry, from the missing-knob sweep and from `seed`.

The Mission Control screen is phase B; phase C added the file-held box, the
`partial` modifier pills and a text input for the knobs that are not numbers.

**How to drive it:**

| what | how |
|---|---|
| no flag, no row, no worker → the lane runs; a file flag, an `all-off` file, a D1 row or an `all-off` row stops it; a gated tick exits 0 | sections 1–5 of `HARNESS_TEST_SANDBOX=1 bash tests/lane-gate-test.sh` |
| project scope stops one project and leaves its sibling running | section 6, same file |
| the 60s cache costs one worker call; an outage with a cold cache runs and an outage with a paused answer cached stays stopped | sections 7–8, same file |
| one log line per lane per hour, and the gate posts no `lanes` tick | sections 9–10, same file |
| knob precedence (project row > global row > env > registry default), clamping, a string knob passing through unclamped, `zero_means` differing by lane, one settings fetch per tick, fail-open to env-then-default | `HARNESS_TEST_SANDBOX=1 bash tests/lane-knob-test.sh` |
| every cron script is registered, the boxes match cron, every wired lane gates on its own id, no phantom and no missing knobs | `HARNESS_TEST_SANDBOX=1 bash tests/lanes-registry-test.sh` |
| a typo'd lane, a project argument on a hub lane, a reasonless stop, an out-of-range knob are all refused and write nothing; the CLI writes `lane.<id>[.<project>].<env lowercased>` | `HARNESS_TEST_SANDBOX=1 bash tests/harness-ctl-test.sh` |
| `on` takes the reason `off` takes, records it, and refuses the one ambiguous form; `seed` writes only missing rows, never a credential, and `--dry-run` writes nothing | sections 12–13, same file |
| a settings row reaches an unmodified `${KNOB:-default}` reader, nothing is exported without a row, the export is clamped, and a row can never export a variable the registry does not declare | sections 11–12 of `HARNESS_TEST_SANDBOX=1 bash tests/lane-knob-test.sh` |
| every tick posts its own liveness row (`ran`/`paused`) to `/api/lanes/liveness` and never to `/api/lanes/tick`; a box-local file is reported as a sighting and never promoted to a `pause_flags` row; `lane_paused` answers instead of exiting | sections 15–17 of `HARNESS_TEST_SANDBOX=1 bash tests/lane-gate-test.sh` |
| every lane this repo ships is wired (or declares another repo owns it), no credential is a settable knob, a lane-wide knob really overflows the 64-char key, a built env name declares a real prefix | sections 12–15 of `HARNESS_TEST_SANDBOX=1 bash tests/lanes-registry-test.sh` |
| the two new routes, the per-lane tick beating the legacy row, a sighting reading as `off_source: "flag"`, and the status route FAILING OPEN when either table is missing | `cd worker/jobs && node --test test/lanes-control.test.js` |
| the screen names the box holding a file and draws a modifier without drawing a stop | `cd console-ui && npm test` (`tests/settings-render.test.js`) |
| every settings key the registry can build, for every project in `fleet.conf`, is legal and fits 64 chars; no knob carries a key alias; every switch alias declares its polarity | sections 9–11 of `HARNESS_TEST_SANDBOX=1 bash tests/lanes-registry-test.sh` |
| every wired lane's SHIPPED header block is EXTRACTED AND EXECUTED against a scratch harness holding `flags/all-off`, and must exit 0 without reaching the body | section 5, same file |
| a row flipped back to 0 resumes the lane on every box, for `lane-off-<id>` and for `all-off`; a file with no row still holds | sections 11–12 of `HARNESS_TEST_SANDBOX=1 bash tests/lane-gate-test.sh` |
| a box lane stops on its own box's `lane-off-<id>.box.<box>` row and on no other box's; the row flipped back resumes it; hub lanes never read a box name; fail open | `HARNESS_TEST_SANDBOX=1 bash tests/lane-gate-box-switch.bh-2327-test.sh` |
| the clamp logs, and an env value is not clamped | sections 9a–9d of `HARNESS_TEST_SANDBOX=1 bash tests/lane-knob-test.sh` |
| `harness-ctl status` runs against the worker's real payload and prints the lane's actual spend | section 11 of `HARNESS_TEST_SANDBOX=1 bash tests/harness-ctl-test.sh` |
| every wired lane CALLS `lane_env_apply`, and its last call is BELOW the script's top-level env-load block (above it, `global.env` overwrites the row) | section 16 of `HARNESS_TEST_SANDBOX=1 bash tests/lanes-registry-test.sh` |
| the SHIPPED preamble of `bin/clock-sync.sh`, run with `env/global.env` saying 30 and a settings row saying 777 — the row wins | section 13 of `HARNESS_TEST_SANDBOX=1 bash tests/lane-knob-test.sh` |
| no exec/host/path/identity/test-seam name is settable, `settable` is a boolean, and no `default` carries shell text | sections 17–18 of `HARNESS_TEST_SANDBOX=1 bash tests/lanes-registry-test.sh` |
| a `settable: false` knob is neither exported nor resolved from a row, and the refusal is logged | section 14 of `HARNESS_TEST_SANDBOX=1 bash tests/lane-knob-test.sh` |
| `harness-ctl set` refuses one, and `seed` publishes neither those nor a bearer-in-a-URL | sections 14–15 of `HARNESS_TEST_SANDBOX=1 bash tests/harness-ctl-test.sh` |
| an OUTAGE answer is cached for the same TTL, so the second tick asks nobody and the lane still fails open | section 18 of `HARNESS_TEST_SANDBOX=1 bash tests/lane-gate-test.sh` |
| a box-local `flags/all-off` holds every lane on that box and appears as `all_off_flag_boxes`; `PUT /api/settings` refuses a `settable: false` key | `cd worker/jobs && node --test test/lanes-control.test.js` |
| the routes: the payload's every contract field, the fleet tab strip, a pre-BH-1132 alias counting as off, a knob with no row ABSENT rather than defaulted, null counts for a lane nothing mentions, only the liveness row's owner reading it, `cost_rows` reaching the lane that owns them, `off_source` never `"flag"`, a fleet stop refused without a reason, `all-on` touching only `all-off` | `cd worker/jobs && node --test test/lanes-control.test.js` |

**Fail-open on a wiped box.** A brand-new box — or a hub whose `state/` was
wiped, which the hub-wipe plan makes a real case — has no cache, so with an
unreachable worker it runs every lane, including ones stopped only by a D1 row.
That is deliberate: the pre-BH-1132 state of all nine is "runs with no gate at
all", and a control plane that stops the fleet when a database blinks is worse
than none. The first reachable tick reconciles the files and the stop takes
effect.

**Deploy coupling:** `bin/lib/lane-gate.sh`, `bin/harness-ctl.sh`,
`catalog/lanes.json` and the 78 wired scripts reach every box through
`bin/harness-sync.sh` (rsync,
temp-file+rename per file, so a running tick never reads a half-written one).
The worker deploys separately, and the gate fails open to *on* while the two are
out of step, so neither order can stop the fleet.

**The two BH-1165 tables self-create.** `bin/harness-sync.sh` runs
`npx wrangler deploy` and nothing else, so a table that waits for a hand-run
`wrangler d1 execute` ships DEAD. `lane_ticks` and `lane_flag_sightings` are in
`CREATED_TABLES` (idempotent, additive, memoised per DB handle) and in
`schema.sql`, and every READER of them fails open with a log line: a worker that
deploys a minute before the first lane posts still renders the whole control
plane, with null ticks and no sightings.
