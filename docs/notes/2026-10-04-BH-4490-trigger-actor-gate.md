# Only a listed human or the harness itself makes a ticket buildable (BH-4490)

Doc: BOARD-API-CONTRACT

## What was wrong

A build started on whoever put `ai-build` on an issue or moved an in-app ticket.
A bot, or another agent, could do that as well as a person, and the harness
built on its say-so. That is the agent-triggers-agent loop: TK-88 ran to 213
comments, TK-135 ping-ponged.

## What changed

- New `bin/lib/trigger-actor.sh`, called from a new
  `# >>> trigger actor gate (BH-4490)` block in `bin/lib/rb/gates.sh`
  `rb_gate_prelude`, right after the abandoned-ticket skip and before the Fly
  enqueue gate. Every launch path goes through it, and a Fly builder runs it
  again at claim time.
- The trigger is the NEWEST `labeled ai-build` event on a GitHub-Issues board
  (`GET repos/<slug>/issues/<n>/events`, REST, 100 per page, at most 10 pages),
  or the NEWEST `status_change` in an in-app ticket's `activity[]`.
- The rule, first hit wins:

  | Actor | `trigger.actors.<p>` set | no row |
  |---|---|---|
  | the harness (GitHub: `hs_ours` over `HARNESS_SELF_APPS`; in-app: the board's harness name) | allow `self` | allow `self` |
  | listed (case-insensitive login, userId or display name) | allow `listed` | n/a |
  | anyone else, bots included | ignore `not-listed` | GitHub Bot: ignore `bot`; GitHub User: allow `human-default`; in-app: allow `unarmed`, board not read |
  | row unreadable | defer | defer |
  | GitHub board, `HARNESS_SELF_APPS` resolves empty | defer | defer |

  The empty-list row exists because `bin/lib/harness-self.sh` resolves an
  unresolved registry to `[]`. Its other readers can live with that, but here
  it would read our own App's label as a foreign bot and refuse it with a
  public comment.

  Entries are space-separated, or comma-separated when the value holds a comma
  (`u_7, Dana Ruiz`). The value `off` unarms the project.
- Outcomes: allow writes one `TRIGGER-ACTOR allow <why> actor=<a> event=<id>`
  line to `pipeline.log`. Ignore posts one comment (deduped), writes the ledger
  row, and ends the build `BUILD_REFUSED SKIP_ACTOR <KEY> — …` with
  `$BUILD/COMMENTED` touched. Anything unreadable (allowlist row, an events page,
  the ledger, an armed in-app board, the per-key lock) ends it
  `BUILD_DEFERRED trigger-actor unverifiable (…)` with no comment. A missing lib
  is `BUILD_DEFERRED trigger-actor lib missing on <host>`.
- Outcome record: ledger kind `trigger-actor`, key `"<p> <KEY>"`, status
  `ignored` or `allowed`, detail `{event, actor, why, source, commented, at}`.
  The claim (`commented: pending`) is written BEFORE the comment is posted, so a
  failed claim posts nothing. A row already `ignored` is the same episode: no
  comment, only a detail refresh. A later allowed trigger flips the row to
  `allowed`, so the next ignore comments again. A comment that fails after the
  claim is not retried (`commented: failed`).
- An unconfigured jobs client (`JOBS_URL` or `HARNESS_SECRET` empty) reads as no
  row. No `gh` on the box, or an issue number gh-rest refuses, reads as no
  trigger.
- `bin/pipeline-health.sh` does not count `SKIP_ACTOR` toward the pool-refusal
  halt, the same as `SKIP_CLOSED`.
- `worker/jobs/schema.sql` seeds `trigger.actors.cromford = operator`
  (`INSERT OR IGNORE`, applied by `bin/harness-sync.sh` before deploy).
- Kill switch: `lane_switch trigger-actor-off` (`catalog/switches.d/trigger-actor-off.json`).

## Operator verbs

- Set a list: `bin/jobs-client.sh setting-set trigger.actors.<p> "<login> <login>"`
- Unarm: `bin/jobs-client.sh setting-set trigger.actors.<p> off`
- Read an outcome: `bin/jobs-client.sh ledger-get trigger-actor "<p> <KEY>"`
- Turn the gate off: settings row `switch.trigger-actor-off` = `on`, or `flags/trigger-actor-off`.

## What deploy actually arms

- Only cromford has a row (`operator`). On every other GitHub-Issues project
  (project-5, project-6, project-7, harness-console) a foreign BOT is refused,
  but an unknown HUMAN still builds (`human-default`) until that project gets a
  row.
- No in-app board has a row, so in-app gating is opt-in, and none of the
  seven boards is armed. The `activity[]` shape it reads (`type:
  "status_change"`, `actor.{userId,name}`) is checked against a fixture only.
  If an armed board serves another shape, the gate lets it build as
  `no-activity`.
- Follow-up: seed `trigger.actors.<p>` per project (harness-console can take
  `operator` today), then arm one in-app board and probe its live `activity[]`.

## Known limits

- Two boxes deciding the same ignored trigger on the very same tick can each
  post a comment. The flock dedupes one box only. The ledger is still the one
  fleet-wide record.
- Any holder of the worker bearer can edit `trigger.actors.*`, like every other
  settings row. Adding the prefix to `PROTECTED_PREFIXES` in
  `worker/jobs/src/routes/verdicts.js` is a follow-up ticket.
- At claim time on a Fly builder the gate reads the events again and defers on
  any page error, including a rate limit (rc 75) or a 5xx. `bin/fly-pool.sh`
  counts that deferral toward `JOBS_QUEUE_DEFER_MAX` (6). So a GitHub outage
  that outlasts about six pool attempts can park tickets that were already
  allowed at enqueue. The closed-issue skip fails open for this reason. This
  gate fails closed, because failing open would let a bot's label build
  whenever GitHub is flaky. Follow-up: exempt this deferral reason from the
  defer count, the way a lane failure is exempted.
- `bin/triage-gate.sh --buildable` is unchanged. The triage session itself is
  not gated; the build (the spend and the PR) is.
- The in-app self names in `ta_self_names` mirror `bin/triage-gate.sh`'s
  SELF_ACTORS column. A change there needs the same change here.

Suite: `tests/trigger-actor-gate.bh-4490-test.sh` (the ticket names it
`tests/trigger-actor-gate-test.sh`).
