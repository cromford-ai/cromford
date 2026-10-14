# The three LLM alert lanes run per project (BH-5942)

Doc: ALERTS-GROOMING-SPEC, watchdog-spec, TRIAGE-STATE

## Why

Wave 2 of #5938. alert-triage, alerts-medic and watchdog-responder each took
one global lock and worked every project in one session. One project's backlog
held every other project, and every session ran on the shared Claude pool and
the box's GitHub token. This change moves the three lanes onto the BH-5913
per-project runner (`bin/lib/project-lanes.sh`,
docs/notes/2026-10-10-BH-5913-project-lanes.md) before anyone turns them back
on. The lanes stay off: no switch row, flag or `LLM_LANE_ENABLED` value
changed.

## The seam: `bin/lib/llm-lane-project.sh`

| Call | What it does |
|---|---|
| no argument, or `--dispatch` | `pl_dispatch <lane>`: one detached `<lane script> <project>` per fleet.conf project that is not held. Prints the runner's `<lane> dispatch: started N project run(s) ...` line and appends it to the lane log. The cron lines and `bin/watchdog-poll.sh` call the scripts with no argument, so they did not change. |
| `<project>` | One project's run. Under the runner it keeps the runner's lock. Started by hand, it takes `locks/<lane>-<project>.lock` itself; a held lock prints one line and exits 0. A name that is not a project name exits 2. State is `state/<lane>/<project>/`. |
| `llp_arm` | Called after `env/global.env` and `lane_env_apply`. Re-arms `GH_TOKEN` with the project's App token (`pl_token`; no App token on the box = the box token, one log line). Exports `ACCOUNT_PROJECT_FOR_LANE=<word>=<project>`. |
| `llp_route` / `llp_owns` | Which run owns an item. The item's project when it is exactly a fleet.conf project. Otherwise (no project, `harness`, a name not in fleet.conf, a name with a space) the home project. |

The entry runs below `lane_gate_or_exit`, so a lane that is off forks no run.

Knobs (catalog/lanes.d/_lib.llm-lane-project.json):
`LLM_LANE_DISPATCH_SPREAD_SECS` (default 300, 0 = all at once; a non-number
uses 300 and logs one line) and `LLM_LANE_HOME_PROJECT` (default
`cromford`).

## The account: `ACCOUNT_PROJECT_FOR_LANE`

The lanes still call `bin/agent-call.sh triage <word>` with the lane word
(`alert-triage`, `medic`, `responder`) as its project. The cost rows and the
BH-1039 daily dollar cap (`bin/lib/lane-caps.sh`) sum on that word, so it
must not change. `bin/lib/project-account.sh` now maps a lookup for exactly
`<word>` to `<project>` (`_pacct_project`) in `account_for_project` and in the
two pin alerts. So a pinned project's run uses the project's own Claude
account (BH-1657), and a project with no pin uses the shared pool, as before.
Any other name, and a `<project>` that is not a plain name, is not remapped.

## watchdog-responder

- A run reads `state/stale-owed.json` and keeps only its project's entry. It
  does not run `bin/stale-owed-tickets.sh` (that sweep loops over every
  project; its own hourly lane writes the snapshot).
- The 90-minute history is `state/watchdog-responder/<p>/stale-history.json`,
  this project only. The first pass after deploy writes it; the next pass
  90 minutes later can find a persisted item.
- Wedged jobs: only `state/build-queue/<p>/`.
- `state/responder/handled.json` stays one shared file (the console and the
  brake ledger read it). Every write is under `flock -w 5` on
  `handled.json.lock`: the run's stamp in `bin/watchdog-responder.sh` and the
  scripted-fix stamp in `bin/lib/responder-fix.sh` (`_rfix_stamp`, which had
  no lock before the fix round for the lead BLOCK at 897dab888). Each writer
  re-reads the file, changes only its own keys, and writes through its own
  temp file. If the lock is not free in 5 s, the run stamps nothing and logs one
  line, so the items come back next pass.
- `logs/responder-run.<p>.txt`, `logs/responder-decide.<p>.txt`.
- The escalation contract lists only the run's project.

## alerts-medic

- The dispatch runs after the lane gate, `lane_env_apply`, the dollar cap
  and the zero-session cap. It runs `bin/alerts-groom.sh` once (the groom is
  fleet-wide and has its own lock), then `llp_dispatch`. A project run never
  grooms.
- A run keeps a console row or an alerts-table row (TSV column 4) only when
  `llp_owns` its project field.
- A `medic:<fkey>` escalation parks its family in EVERY run. Its project field
  is the model's pick (from the whole fleet, or empty), so the park cannot
  depend on it. A park acts only on the run's own candidate rows.
- State is `state/alerts-medic/<p>/`: `medic-seen.txt`,
  `medic-families.json`, `medic-parked.json`. The old shared
  `state/medic-seen.txt` is a second seen source, read only. The shared
  families and parked files are copied once into a project file that does
  not exist yet, so 6-hour stamps and parks carry over.
- `logs/medic-run.<p>.txt`. The pass line ends `project=<p>`.
- The DEFERRAL BACKLOG line pages once per project per UTC day
  (`flags/alerted-medic-backlog-<p>-<day>`).
- `bin/alert-digest.sh`'s local parked fallback merges every
  `state/alerts-medic/*/medic-parked.json` by family key. It reads the
  shared file only when no project file exists yet.
- Unchanged and shared: `logs/medic.log`, the brake-ledger kinds
  `medic-seen`, `medic-family`, `medic-parked` and their keys. A family key
  that two projects share can hold the other project's family for up to
  6 hours (the plan's ASSUMPTIONS).

## alert-triage

- The quarantine reads are destructive, so the dispatch still collects
  once: the shared deferral spool, the alerts-table claim, the hub
  quarantine and the per-box ssh read. It routes each line by its beat
  `project` with `llp_route` into `state/alert-triage/<p>/inbox.tsv`
  (`bin/lib/triage-inbox.sh`). It removes its work file
  (`state/alert-triage/dispatch-work.tsv`) only after every append landed.
  A failed append leaves the lines for the next dispatch and logs one line.
  `locks/alert-triage.dispatch.lock` stops two collections at once; the
  dispatch releases it before `llp_dispatch`.
- A project run's work is its inbox, its own deferral spool
  `state/alert-triage/<p>/deferred.tsv` and its own work file. Every
  re-spool site writes the project spool.
- Per project, seeded once by a copy of the shared file: `alert-families.json`,
  `alert-fix-prs.json`, `alert-triage-cliff.json`.
- Shared: the cliff-parked and expired archives (append under their own
  lock), `state/triage-prstate.json` (STEP 0 runs under `flock -w 5` on
  `locks/triage-prstate.lock`; a busy lock skips STEP 0 and keeps every
  line), and the lane-wide daily pages.
- Each run mirrors only its own `brake:triage-deferred` rows.
- `bin/alert-verify/deferral-backlog.sh` reads the spool and lock of the
  project its page names. `bin/fleet-status-push.sh` counts the shared spool
  plus every project spool.
- `TRIAGE_MAX_FAMILIES` applies per project run.

## Known limits

- The daily dollar cap and the noise budget stay lane-wide and are read
  before spend. N project runs can each pass the check before any of them
  bills, so one tick can go over the cap by at most N sessions. The next
  tick stops.
- Each alert-triage project run reads the brake ledger itself: up to one
  request per project per tick instead of one.
- When the home project is not in fleet.conf, no run owns items with no
  project. Each dispatch logs one line that says so.
- A project removed from fleet.conf keeps its inbox and spool, and nothing
  reads them.
