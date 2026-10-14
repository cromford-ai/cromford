# Post-merge QA stops re-offering a merge the gate never saw served

Doc: OPERATOR-SETUP

`bin/postmerge-qa.sh` refuses to drive production until prod is serving the merge
sha. That gate is right — driving the previous build and calling it this ticket's
result is the one way the stage could manufacture a false FAIL — but it had
exactly one answer for "not serving yet": say it and come back next tick. It read
no clock and wrote no state, so a merge the gate never saw served was
re-offered on every `deploy` wake and every per-project cron tick, forever. The runaway-spend
audit of 2026-09-17..19 counted 30,698 `prod not yet serving sha — requeued`
lines for project-5 in three days (audit site 16, issue #1022). No model spend —
the agent lane sits behind the gate — but the feed never drained, and nobody was
ever told that a merge had not reached production.

## What changed, in `bin/postmerge-qa.sh`

**The clock is the PR's own `mergedAt`.** The `gh pr view` call the loop already
makes now asks for `state,mergeCommit,mergedAt` and reads three fields. Prod
cannot serve a sha before it is merged, so "N hours since merge and still not
serving" is exactly the audit's "N hours of not yet serving" — with no new state
file, no first-seen stamp to write before or after the send, and nothing that can
grow. `NOW` is read once per run, so every build in a tick is aged against the
same instant.

**The knob.** `POSTMERGE_QA_DEPLOY_MAX_HOURS`, default 12, `0` = never age out
(byte-for-byte the old behaviour). A value that is not a whole number is said out
loud in `logs/postmerge-qa.log` and the default is used — the same handling
`E2E_MAX_PERSONAS` already gets in this file, and for the same reason: an
unvalidated knob makes `[ "$AGE_S" -ge … ]` error and read as "under the limit",
which is no limit at all. Documented in `env-templates/project.env.example` next
to the other `POSTMERGE_QA_*` settings.

**The `# >>> deploy age-out` block** replaced the gate's two `continue` arms. Past
the limit a build gets, in this order: one `logs/ALERTS.log` line, one
`fleet_alert` beat (akey `prodqa-deploy:<project>:<sha>`), and one
`state/postmerge-qa-done.txt` row with the outcome `NOT_COVERED_DEPLOY_TIMEOUT`.
The order is the point: a crash between the alert and the row can duplicate an
alert, which is noise, while the other order could leave a build silently
terminal — the exact failure this ticket exists to remove. The done row is also
the dedup: `already_done` skips the build before the gate on every later tick, so
there is no second alert and no attempt counter to keep.

Under the limit both arms behave as before, including the two `say` strings
byte-for-byte (`tests/postmerge-qa-test.sh` greps them).

## The decisions worth knowing

- **Absent is never old.** An empty or unparseable `mergedAt` leaves the age
  UNKNOWN and the build requeues as it always did. Nothing reaches a terminal
  state on data that could not be read.
- **Only the rc-1 arm ages out.** "Cannot determine" (rc 2) means the SIGNAL was
  unreadable — `curl` failed or `gh api` did — which is a fact about this box,
  not about this build. Twelve hours of expired `gh` auth or an unreachable
  version host would otherwise write every merged build of every project
  terminal in one tick, and none of them would be driven when the signal came
  back. rc 2 keeps the old behaviour: say it, requeue, whatever the age. (Round
  1 of review; the first cut aged both arms out.)
- **Serving means the sha OR A DESCENDANT of it.** A `VERSION_URL` reports the
  one sha production is serving NOW, which is the NEWEST merge — so a strict
  match answers "not serving" forever for a merge that went live minutes after
  it landed. `bin/deploy-train.sh:135-141` has handled this since the 2026-07-28
  near-miss; the gate did not, and that is what the audited feed was actually
  made of: all seven of the most-requeued project-5 shas are on `origin/main`
  AND ancestors of the sha `project-5.example/api/internal/version` serves. Without
  this, the age-out would have written `NOT_COVERED_DEPLOY_TIMEOUT` plus a false
  `fleet_alert` beat — and `bin/alert-triage.sh` pays an `agent-call` per beat
  family — for merges that are live, on all four `VERSION_URL` projects. The
  live sha is read with `jq -r '.sha // .commit // empty'` (a non-JSON body
  keeps the old substring answer), the probe now sends `VERSION_AUTH` the way
  deploy-train does, and the ancestry question is asked of the local clone. A
  clone that has never seen one of the two shas answers *cannot tell*, not
  *no*: `git merge-base --is-ancestor` exits non-zero for an unknown object
  exactly as it does for a real no.
- **An empty `mergeCommit.oid` cannot shift the fields.** The `-q` expression
  defaults a null column to `-`, not to `""`. `read` collapses runs of
  separators (tab included, even with `IFS` set to just tab), so an empty middle
  column would have landed `mergedAt` in the sha variable — past the `-n "$MSHA"`
  guard, probing production for a date.
- **The outcome word is `NOT_COVERED_DEPLOY_TIMEOUT`**, following
  `NOT_COVERED_NO_QA_ENV` so `already_done` and every reader of the done file
  need no change. It says only what was observed — not served N hours after the
  merge, nothing driven — and never "never deployed" as a fact. It is not a FAIL
  and does not page anyone as a defect.
- **No spend was added and none was moved.** The age-out `continue`s before the
  drive and before the `prodqa` agent lane, and before `RAN` increments — so a
  timed-out build does not eat the `POSTMERGE_QA_MAX` slot a deployed build in
  the same tick needs.
- **No PR comment** for a timed-out build. `NOT_COVERED_NO_QA_ENV` posts none
  either; the audit asked for one alert, and the ALERTS line plus the beat are
  it.

## What an operator does when it fires

The alert names the sha, the PR, the age, and the two things that settle it: get
that sha deployed (`bin/deploy-train.sh` / the project's deploy lane), or set
`VERSION_URL` for a project whose prod has no version endpoint. Then remove that
build's row from `state/postmerge-qa-done.txt` and re-run
`bin/postmerge-qa.sh <project> <build-dir>` — the stage will not re-offer a build
it has already called terminal, and the alert line carries that exact command.

## How it is proven

    HARNESS_TEST_SANDBOX=1 bash tests/postmerge-qa.bh-1022-test.sh
    HARNESS_TEST_SANDBOX=1 bash tests/postmerge-qa-test.sh
    HARNESS_TEST_SANDBOX=1 bash tests/postmerge-qa-personas-test.sh

The first is this ticket's suite: it drives the real script against a scratch
harness with a fake GitHub — and, for the ancestry cases, a REAL three-commit
git clone — and asserts only on what the run wrote: the done file, `ALERTS.log`,
the beat argv, the drive sink, the `curl` argv. Cases A-K are the age-out
itself (past the limit, the silent second tick, under the limit, old-but-served,
knob `0`, a non-numeric knob, absent and unparseable `mergedAt`, the
unreadable-deploy arm, two builds in one tick where the timed-out one does not
consume the slot, the prescribed recovery, the documented knob). L-P are round
1's: a superseded merge is a served merge, the exact sha and a non-JSON body
still pass, an unrelated live sha still ages out, a live sha the clone has never
seen is cannot-tell, the probe carries `VERSION_AUTH`, and a null
`mergeCommit.oid` is skipped rather than read as a sha. Both rounds were checked
red first (round 1: 13 failing assertions on the pre-fix `bin/`, including the
field shift printing `prod not yet serving 2026-09-`), and the fake `gh` renders
a null column the way the caller's own `-q` filter asks — so reverting either
the field list or the sentinel goes red.

The map entry is [`docs/verification-map/postmerge-qa-deploy-age.md`](../verification-map/postmerge-qa-deploy-age.md).
