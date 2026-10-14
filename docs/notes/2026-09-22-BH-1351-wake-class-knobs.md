# Wake-class cooldowns become knobs, and prompts_touched finally fetches

Doc: EVENTS

**What changed.** Round-4 review of #1091 left four code items and a wording
correction. All five are here.

- `bin/lib/wake-class-push.sh` — `prompts_touched` now FETCHES the pushed sha
  when the hub checkout does not have it, then diffs. This is the bug: a push
  wake carries the push's own `after` sha and the loop drains it within seconds,
  so nothing had fetched that commit into `/root/harness-checkout` yet and the
  old `cat-file -e` answered "unknown sha" on every real push. The prompt-eval
  dispatch BH-1061 shipped only ever fired when the sha happened to be local
  already, which on the normal path is never.
- `bin/lib/wake-class-push.sh` — the prompt-eval launch is `prompt-eval.sh
  --cron`, with the `cromford` positional dropped.
- `bin/lib/wake-class-flaky.sh` — the hardcoded `21600` becomes
  `${WAKE_FLAKY_COOLDOWN_S:-21600}`.
- `catalog/lanes.d/wake-loop.json` — three knob rows:
  `WAKE_PROMPT_EVAL_COOLDOWN_S` (int, 86400), `WAKE_FLAKY_COOLDOWN_S` (int,
  21600) and `HARNESS_CHECKOUT` (string, `settable: false`), each with a
  `read_in` naming the class lib that reads it.
- `tests/lanes-registry-test.sh` §7 — the scan set for a lane now includes the
  files its script sources, for the one lane that sources any:
  `bin/wake-loop.sh` plus `bin/lib/wake-class-*.sh`, using the loader's own glob.

**Why the fetch, and why this shape.** The alternative the ticket offered was to
document that prompt-eval is armed only after fleet-propagate has fetched. That
leaves the dispatch dead on every real push, because the next push carries a
different sha. So: fetch. It is `timeout 60 git fetch -q origin <sha>`, which
writes objects and `FETCH_HEAD` and moves no remote-tracking ref — `wc_push_dispatch`
launches `fleet-propagate.sh` two lines earlier and that run DOES move
`refs/remotes/origin/main` on the same checkout, and the two must not contend
for a ref lock. The 60 s bound is the same one `bin/fleet-propagate.sh` accepts
for its own fetch of this checkout, so no fourth knob. GitHub serves a reachable
commit by sha; a local origin needs `uploadpack.allowReachableSHA1InWant`, which
the new suite sets on its fixture.

The fetch's own exit code is not the verdict. A second `cat-file -e` is, and a
sha still missing returns 1 with one stderr line, so a failed or hung fetch
never launches the metered prompt-eval lane. The dedup-before-spend ordering is
unchanged: the persisted `cooled prompt-eval cromford` stamp under
`state/wake-cool/` is still written before the launch, and its key is still
`cromford` (changing it to `fleet` would orphan today's stamp and could
fire one extra metered run on the first drain after deploy).

**Why `--cron` with no positional.** `bin/prompt-eval.sh`'s cron branch builds
its project set from `PROMPT_EVAL_PROJECTS` or `fleet-conf.sh --projects` and
`exit`s before it reaches `[ -n "$PROJECT" ] || usage`. The positional was never
read — it did not scope the eval to cromford, and nothing behaves
differently without it. The weekly cron line in `docs/PROMPT-EVALS.md` is
`prompt-eval.sh --cron` for the same reason.

**Why §7 grew a scan set.** `WAKE_PROMPT_EVAL_COOLDOWN_S` sat in a sourced class
lib for a release and the registry suite never saw it, because §7 read only the
lane's own `script`. The control plane reported that it covered wake-loop while
a metered lane's window was invisible on the settings page. The scan is keyed on
the lane script being `bin/wake-loop.sh` and uses the loader's glob rather than a
generic "follow every `source`", which would pull `bin/lib/lane-gate.sh` and
friends into all 80 lanes' knob sets. The libs are concatenated into one buffer
so the assignment check still reads `WC_PR_CLOSED=0` and friends as the locals
they are. Red-first: with the scan in and the rows out, §7 prints
`7 wired lanes read env knobs the registry does not carry: wake-loop/HARNESS_CHECKOUT wake-loop/WAKE_PROMPT_EVAL_COOLDOWN_S`.

**Case 12 of `tests/wake-push-drives-lanes.bh-1061-test.sh`** asserted a bare
`ok` — it could not fail. It was trying to observe `bin/rebase-train.sh`'s wake
backstop, which is impossible from a scratch tree because that script hardcodes
`H=/root/harness` and `/root/repos/$PROJECT` and never reads `$HARNESS`. Fixing
that is a different ticket. The case now asserts the dispatched triple: the exact
argv `wc_push_dispatch` hands `remote_launch` (label, project, script, args) and
`launch` (label, script, args). Swapping the `remote_launch` argument order makes
it red.

**Corrections to `docs/notes/2026-09-19-BH-1034-push-flaky-classes.md`.** That
note is merged and stays byte-identical; these are the corrections.

- It says BH-1061 is "the first BH-1034 child to wire a wake class". BH-1060 was
  — it wired `pr-closed` and `pr-ci`. BH-1061 was the second, wiring `push` and
  `flaky`.
- Its "What it touches" list names `docs/verification-map/README.md`. That file
  is generated by `bin/verification-map-build.sh` and git-ignored (BH-1175), so
  no PR touches it; the touched file is the `entries/BH-1061.md` row it is built
  from.
- Its `prompt-eval.sh --cron` line now matches the code, which it did not when
  the note was written: the class launched `prompt-eval.sh cromford --cron`.

**What it touches.** `bin/lib/wake-class-push.sh`,
`bin/lib/wake-class-flaky.sh`, `catalog/lanes.d/wake-loop.json`,
`tests/lanes-registry-test.sh`, `tests/wake-push-drives-lanes.bh-1061-test.sh`,
the two new suites `tests/wake-push-prompts-fetch.bh-1351-test.sh` and
`tests/lanes-registry-class-libs.bh-1351-test.sh`,
`docs/verification-map/wake-lanes.md`,
`docs/verification-map/entries/BH-1351.md`, and this note.

**Operator note.** The two windows are now settings rows
(`lane.wake-loop.wake_prompt_eval_cooldown_s`,
`lane.wake-loop.wake_flaky_cooldown_s`), rendered from the registry at runtime.
`lane_env_apply wake-loop` runs before `bin/wake-loop.sh` sources the class
libs, so a row reaches the `${X:-}` read. No env var needs setting anywhere for
this PR: every new knob keeps its previous literal as its default.
