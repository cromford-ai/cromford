# Nightly filer labels as the App; the pool checks the label actor before a spawn (BH-6957)

Doc: OPERATING, FLY-BUILDER-TRIAL

## Why

The nightly-red filer (`bin/nightly-ticket.sh`) opened its issues with the
workflow's own `github.token`. So the `labeled ai-build` actor was
`github-actions[bot]`, and the trigger-actor gate (`bin/lib/trigger-actor.sh`,
BH-4490) refused every build of the ticket. The pool did not ask who added the
label. It spawned a Fly machine, the machine ran the gate and stopped with
`BUILD_REFUSED SKIP_ACTOR`. On 2026-10-15 this used 8 machines for BH-6853,
until the per-key spawn cap stopped it.

## What changed

1. **The filer writes as the App.** `create()` in `bin/nightly-ticket.sh` runs
   the issue create call and the label call with `GH_TOKEN=$NT_APP_TOKEN` when
   `NT_APP_TOKEN` is set. Searches, lists and comments keep `GH_TOKEN`. A
   refused App call is not retried as the workflow token.
   If `NT_APP_TOKEN` is empty, the filer files as `GH_TOKEN` (the old
   behavior). Stderr then gets one line per run,
   `nightly-ticket: NT_APP_TOKEN not set; filing as the workflow token, and the trigger-actor gate refuses that label`,
   plus a `::warning::` annotation under GitHub Actions.
2. **The workflow mints the App token.** The verdict job of
   `.github/workflows/harness-nightly.yml` has a new step,
   `harness App token for the ticket filer` (id `app-token`,
   `actions/create-github-app-token@v1`). It runs only on `main` when the repo
   variable `HARNESS_APP_ID` is set. It has `continue-on-error: true`, so a
   failed mint does not make the night red. The verdict step gets
   `NT_APP_TOKEN: ${{ steps.app-token.outputs.token }}`. `github-actions[bot]`
   is NOT added to any `trigger.actors.<p>` row.
3. **A human re-arm comment is part of the gate.** When `ta_gate` ignores the
   newest label on a GitHub-Issues board, `_ta_rearm_at` reads the issue
   comments created after that label. A comment re-arms the trigger when all of
   these are true:
   - `user.type` is not `Bot`.
   - The body matches `RETRY`, `REBUILD`, `RESUME` or `UNHOLD` in capitals.
   - The body has no negation or condition in front of the word.
   - `ta_decide` allows the author as `listed` or `human-default`, never `self`.

   The words are the twin of `POOL_REARM_RE` / `POOL_REARM_NEG_RE` in
   `bin/fly-pool.sh`. A re-arm answers `allow rearm actor=<login>
   event=comment-<id>` and closes the ignore episode in ledger `trigger-actor`.
   If the comments read fails, the ignore stays and `PROJECT_2_LINE` ends with
   `(re-arm read: <why>)`. The pool and the builder call the same function, so
   they give the same answer.
4. **The pool asks before it spawns.** `pool_spawn_decision` in
   `bin/fly-pool.sh` has a step 5, after the per-key spawn cap:
   `pool_actor_gate` (`bin/lib/pool-actor-gate.sh`) calls `ta_gate` with the
   pool's repo slug and slug token. The reuse handoff runs the same decision.
   - rc 1 (ignored): no machine. The queue row closes `failed` with the reason
     `SKIP_ACTOR <KEY> — <PROJECT_2_LINE> — pool pre-spawn check, no machine spawned; …`.
     The queue file and the hold marker go. One line goes in
     `logs/fly-pool.log` and one in `logs/<p>.log`. No ALERTS line, because
     `ta_gate` already commented once on the ticket. The refusal does not count
     against the spawn cap.
   - rc 2 (unverifiable): the pool spawns and logs
     `actor check unverifiable for <KEY> (…)`. The builder's own gate still
     defers. This is fail-open on purpose: a pool that refused on every
     unreadable read could stop all builds of a project.
   - rc 0, an `RB-*` rebase row, or no `trigger-actor.sh` on the box: spawn as
     before.
   The `lane_switch trigger-actor-off` kill switch turns off the pool check too.

## Operator setup (GitHub Actions, example-org/cromford)

Until both values exist, the filer keeps the old behavior plus the warning, and
the pool check stops the wasted machines.

1. Set the repo variable `HARNESS_APP_ID` to the harness App's id.
2. Set the repo secret `HARNESS_APP_PRIVATE_KEY` to the App's private key (PEM).

## Operator checks

1. After the next red nightly on main, show the label actor:
   `gh api repos/example-org/cromford/issues/<n>/events --jq '.[]|select(.event=="labeled")|.actor.login'`.
   With the setup above it is `cromford[bot]`.
2. Show the pool refusals: `grep 'SKIP_ACTOR' /root/harness/logs/fly-pool.log`.
3. Show the spawns for a refused key: `grep 'spawned [0-9a-z]* for <KEY> ' /root/harness/logs/fly-pool.log`.
   The count must be 0 after the refusal line.
4. Show the ignore episode: `bin/jobs-client.sh ledger-get trigger-actor "<p> <KEY>"`.
