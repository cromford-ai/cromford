# Guarded-lane agents no longer push; the harness does (BH-2741)

Doc: ALERT-REMEDIATION

## What changed

- **`bin/iron-law-guard.sh` has a second family-2 rule, `agent-push`.** Any
  `git push` from a guarded lane (`plan execute review fix qa triage`) is
  denied, not only a push to main. `push-main` is still judged first and keeps
  its name, and it now also covers `git push origin HEAD` while on main.
  A push with no refspec, or with `HEAD` as the refspec, is resolved against
  the directory the command actually runs in (`cd X &&` and `git -C X` both
  count), not only the payload cwd.
- **The deny names the hold.** After the verdict is decided, the guard does one
  `hold_push_verdict` read, bounded at 6 s, with `HARNESS_LANE` dropped. The one
  `family=actguard-agent-push` row in `logs/findings.log` ends in
  ` :: hold=held|clear|unreadable|unchecked …`. A held ticket also adds
  "The ticket is on HOLD (…): stop working this branch" to the model's reason.
  The read changes that wording and never the verdict.
- **`hold_push` runs its `git push` with `HARNESS_LANE` unset** (a subshell `unset`, so a caller's `git` function still applies). On codex
  lanes the PATH shim and the pre-push hook judge every push in the session's
  process tree through the same classifier, so without the scrub they would
  refuse the one push that has just been hold-checked.
- **Prompts stop telling the agent to push.** The QA-fix prompt in
  `bin/lib/rb/pr.sh` says "Commit your work. Do NOT push" (`RB_PUSH` on the
  next line is unchanged). The remediator loses its lease-push allowance: a
  branch that needs a rebase is an ESCALATE, and
  `bin/remediator-settings.json` denies `Bash(git push:*)`. D38 in
  `prompts/build-discipline.md` says "before your final commit".
  `tests/agent-push-ratchet.bh-2741-test.sh` keeps `prompts/` and the inline
  `CC` prompts of `bin/lib/rb/*.sh` free of push instructions.

## Why

BH-2504 put every harness push to a PR branch behind `bin/lib/hold-push.sh`,
which re-reads the ticket's HOLD at the push. An agent that pushed by itself
inside its session never went through that read, so a lead's HOLD could still
lose the race to the agent.

## Not covered

A REST ref write by an agent (`gh api … git/refs`) is not `git push`, and the
classifier does not model it.
