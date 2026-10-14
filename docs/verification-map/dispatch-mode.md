# Dispatch mode per project (BH-6350)

**What it is:** one switch per project with three modes.

- `normal`: every buildable ticket builds.
- `hotfix-only`: only tickets with the hotfix label build, plus the issue
  numbers on the row's allow-list. Every other ticket keeps `ai-build` and
  waits. Nothing is written to a waiting ticket.
- `paused`: the existing `paused-<project>` row. Nothing launches. The mode
  only reports the pause; the existing pause readers decide it.

Precedence: `paused` > `hotfix-only` > `normal`.

**Where it is stored:** the harness_flags row `dispatch-mode-<project>`, scope
`fleet`. Its value is `hotfix-only` or `hotfix-only:<n>,<n>,...`. Row cleared
or absent means `normal`. Row ON with a value that does not parse means
`hotfix-only` with an empty allow-list (the stricter mode). Every PUT and
DELETE writes one `config_changes` audit row (kind `flag`).

**How to reach it (Mission Control):**

1. Open `/` (Fleet). Find the project row in the projects table.
2. The `MODE` column shows `normal`, `hotfix-only`, `hotfix-only (+N allowed)`
   or `paused`. Its title shows the allow-list and the set time.
3. Click `SET`. Choose a mode. For hotfix-only, type the allow-list (whole
   issue numbers, comma separated). Type a reason. Confirm.
4. Click `flags` to open `/flags`. Filter on `dispatch-mode` to see the row,
   its value, actor and reason.

**How to drive it by hand (a box):**

```
bin/jobs-client.sh flag-set dispatch-mode-<project> hotfix-only:6291,6292 "conflict fixes first"
bin/jobs-client.sh flag-clear dispatch-mode-<project> "back to normal"
```

`bin/flag.sh` does not take this name: its family list is fixed.

**What each lane does in hotfix-only:**

| Lane | Behavior | Evidence |
|---|---|---|
| `bin/launch-fastpath.sh` | condition 15c holds the key; it is printed as declined, with no per-key line | one `DISPATCH-MODE hotfix-only: <k> key(s) wait (...)` line per run in `logs/<p>.log` |
| `bin/run-triage.sh` | triage runs; the prompt gets a launch directive | one `DISPATCH-MODE hotfix-only (allow-list: ...)` line per tick in `logs/<p>.log` |
| `bin/run-build.sh` | `# >>> dispatch mode gate` answers `BUILD_DEFERRED dispatch mode hotfix-only: <KEY> waits ...`, exit 3, before the claim and the Fly enqueue | `pipeline.log` and `logs/<p>.log` |
| `bin/fly-pool.sh` | a held queued job is skipped in the spawn loop and the reuse handoff; it stays queued | one `DISPATCH-MODE hotfix-only: held <k> queued job(s)` line per tick in `logs/fly-pool.log` |
| `bin/fly-dispatch.sh` | the file pick and the rows pick skip a held job | one `DISPATCH-MODE hotfix-only, skipping: ...` line per tick |

**Still admitted in hotfix-only:** a hotfix ticket or job; an allow-listed
issue number; a resumed build (`RESUME_BUILD`, a fix round); a build on a pool
machine (`BUILDER_EXEC=1`); a conductor rebase job; a blocked-resolver rebuild
job (`rebuild:true` in the pool job file); a death requeue (`deaths > 0`); a
ticket whose hotfix label read failed (`HF_RC=2`). The review, merge-conductor,
merge-queue and fix-round lanes do not read the mode.

**The age alert:** when hotfix-only has stood for `DISPATCH_MODE_ALERT_H`
hours (default 24, settings row `lib.dispatch-mode.dispatch_mode_alert_h`, per
project `lib.dispatch-mode.<p>.dispatch_mode_alert_h`), triage raises one
warn alert (the digest, not a page), id `dispatch-mode-hotfix-only:<p>`. The clock is
`state/dispatch-mode/<p>.since`, seeded from the row's `set_at`, so an
allow-list edit does not restart it. On any other mode the file goes and the
alert is resolved.

**Back to normal:** clear the row. The next fastpath or triage tick launches
the waiting tickets. No label changes.

**What usually lies:**

- A local-box (not pool-routed) blocked-resolver REBUILD FRESH clears stamps,
  and the next triage tick re-claims the ticket like a new launch. In
  hotfix-only it waits like any other ticket. The pool path keeps its rebuild
  through `rebuild:true`.
- Under `paused-<p>`, `bin/fly-pool.sh` still spawns plain jobs that were
  already queued, and `bin/fly-dispatch.sh` does not read the pause. That is the
  pause's behavior before BH-6350, kept as it was. Hotfix-only does hold those
  queued jobs.
- A box whose `bin/` has not synced the regex reads `dispatch-mode-<p>` as a
  file flag, which is absent, so it reads normal.
- The allow-list numbers in the MODE cell link to GitHub only when the
  projects payload carries a `repo` slug. Without one they are plain text.
