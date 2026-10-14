#!/bin/bash
# tests/pr-create-failed-owned.bh-614-test.sh — a build whose PR never opened is
# OWNED: the queue row closes FAILED, the job row records `failed` by name, and
# the ledger keeps a row an operator can list by branch.
#
# THE DEFECT (BH-614, the 2026-09-17 project-5 shape). A stacked child's
# `gh pr create` 422'd on a parent branch that had been deleted mid-build, so the
# build ended with no PR. bin/run-build.sh's RESULT ratchet (#749) already writes
# `PR_CREATE_FAILED:` for that, and bin/fly-pool.sh's url-shape gate (BH-765)
# already rewrites an older image's url-less `PR_CREATED` claim to
# `RESULT_MALFORMED PR_CREATED …`. What neither did was tell the LEDGER: the reap
# closed every reaped row `done`, so the queue said finished work about a
# reviewed, pushed branch with no PR; `_job_finish` reached `failed` only through
# its `*)` default; and nothing anywhere listed such a build by branch.
#
# WHAT THIS SUITE PINS:
#   A — bin/fly-pool.sh `# >>> reap row close (BH-614)`: a reaped record whose
#       line 1 is either failed-create word closes the queue row FAILED, and
#       every other terminal — including `RESULT_UNVERIFIED PR_CREATED`, which is
#       an unread PR and not a failed create — still closes `done`.
#   B — bin/run-build.sh `_job_finish`: PR_CREATE_FAILED is named in the status
#       map, and a real PR_CREATED still closes `done`.
#   C — bin/run-build.sh `# >>> pr create call`: a create that returns no url
#       writes one `pr_create_failed` ledger artifact, ref = the branch, detail =
#       gh's own words, and the existing ALERTS line is unchanged.
#
# HOW IT DRIVES: every block is EXTRACTED VERBATIM from the production scripts by
# its column-1 `# >>>` / `# <<<` markers (and `_job_finish` as a whole function)
# and then EXECUTED with the seams recorded — `queue_done`, `job_update`,
# `job_artifact_put`, `gh_pr_create_ladder`. Assertions are on artifacts: the
# recorded call arguments, ALERTS.log, the artifact JSON. No network, no live
# harness.
#
# Run from anywhere: tests/pr-create-failed-owned.bh-614-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
. "$DIR/tests/lib/hold-gate-fixture.sh" || exit 1  # BH-6091: the pr-open HOLD gate for a pipeline slice
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
NOW=$(date +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required to drive these blocks"; exit 1; }

FP="$DIR/bin/fly-pool.sh"
RB="$RB_ALL"

# ── the production blocks, lifted verbatim ───────────────────────────────────
marked() { # marked <start> <end> <file>
  awk -v s="$1" -v e="$2" 'index($0,s){f=1;next} index($0,e){f=0} f' "$3"
}
ROWCLOSE="$T/rowclose.sh"; CREATE="$T/create.sh"; JOBFIN="$T/jobfin.sh"; QROWSH="$T/qrow.sh"
marked '# >>> reap row close (BH-614)' '# <<< reap row close' "$FP" > "$ROWCLOSE"
marked '# >>> pr create call'          '# <<< pr create call' "$RB" > "$CREATE"
# QROW is a plain function and the row close calls it, so the real one comes too:
# a driver that stubbed QROW would be asserting against its own stub.
sed -n '/^QROW() {/,/^}$/p' "$FP" > "$QROWSH"
# _job_finish is a function, not a marked block: from its opening line to the
# closing brace in column 1.
awk '/^_job_finish\(\) \{/{f=1} f{print} f && /^\}/{exit}' "$RB" > "$JOBFIN"

# A suite that extracted nothing must FAIL, not pass vacuously.
[ -s "$ROWCLOSE" ] && ok || bad "extract: the reap row close block is missing from bin/fly-pool.sh"
[ -s "$QROWSH" ]   && ok || bad "extract: QROW is missing from bin/fly-pool.sh"
[ -s "$CREATE" ]   && ok || bad "extract: the pr create call block is missing from bin/run-build.sh"
hold_gate_prepend "$RB_ALL" "$CREATE"   # BH-6091: the real gate, a no-HOLD ticket read
[ -s "$JOBFIN" ]   && ok || bad "extract: _job_finish is missing from bin/run-build.sh"
grep -q 'QROW' "$ROWCLOSE" && ok || bad "extract: the row close block does not close a row"

# ═══════════════════════════════════════════════════════════════════════════
# Section A — the reap closes the row (bin/fly-pool.sh)
# ═══════════════════════════════════════════════════════════════════════════
# The driver sources the REAL QROW and the REAL row-close block with `queue_done`
# — the jobs-client seam QROW itself probes for — replaced by a recorder. What
# the ledger is told is therefore a fact about the shipped code, not a paraphrase.
cat > "$T/drive-row.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
STAMP() { echo "2026-09-18 00:00:00Z"; }
if [ "${WITH_QUEUE_DONE:-1}" = 1 ]; then
  # The reason is `head -c 200 RESULT`, which spans the tail lines too. Newlines
  # are squashed so one close is one recorded line and "how many closes" stays a
  # countable fact.
  queue_done() { printf '%s\t%s\t%s\t%s\n' "${1:-}" "${2:-}" "${3:-}" "$(printf '%s' "${4:-}" | tr '\n' ' ')" >> "$REC"; }
fi
. "$QROWSH"
. "$ROWCLOSE"
printf 'rc=%s\n' "$?" >> "$REC"
DRIVE

REC="$T/row.rec"
row() { # row <line1> [tail lines...] -> the recorded queue_done call
  : > "$REC"
  LOCAL="$T/reap-build"; scratch_rm "$LOCAL"; mkdir -p "$LOCAL"
  local l1="$1"; shift
  { printf '%s\n' "$l1"; [ $# -gt 0 ] && printf '%s\n' "$@"; } > "$LOCAL/RESULT"
  WITH_QUEUE_DONE="${WITH_QUEUE_DONE:-1}" REC="$REC" QROWSH="$QROWSH" ROWCLOSE="$ROWCLOSE" \
    LOCAL="$LOCAL" P=project-5 KEY=TK-1883 HARNESS="$T/nohub" \
    bash "$T/drive-row.sh" >/dev/null 2>&1
  grep -v '^rc=' "$REC"
}
status_of() { cut -f3 <<<"$1"; }
ncloses()   { grep -cv '^rc=' "$REC"; }
rc_of()     { sed -n 's/^rc=//p' "$REC"; }

FAILED_RATCHET="PR_CREATE_FAILED: GraphQL: API rate limit already exceeded for installation ID 161623167. — refused a url-less create claim carrying ''"
FAILED_REAPED="RESULT_MALFORMED PR_CREATED  | STACKED on ticket/TK-1883 (https://github.com/example-org/project-5/pull/1925) - parent PR not resolved"

# ── A1 — the ratchet's own word: a build with no PR is not finished work ─────
G=$(row "$FAILED_RATCHET" 'TIER: 2')
[ "$(status_of "$G")" = failed ] && ok \
  || bad "A1: PR_CREATE_FAILED must close the queue row failed, got '$G'"
case "$(cut -f4 <<<"$G")" in PR_CREATE_FAILED:*) ok ;;
  *) bad "A1: the row must carry the RESULT as its reason, got '$(cut -f4 <<<"$G")'" ;; esac
[ "$(cut -f1 <<<"$G")" = project-5 ] && [ "$(cut -f2 <<<"$G")" = TK-1883 ] && ok \
  || bad "A1: the row must be closed for this project and key, got '$G'"
[ "$(ncloses)" = 1 ] && ok || bad "A1: exactly one row close, got $(ncloses)"

# ── A2 — BH-765's spelling of the same park closes the same way ──────────────
# The reap's word for a url-less claim written by an older pool image is
# RESULT_MALFORMED (BH-765 owns it and its suite pins it byte for byte). This
# block does not re-spell it; it reads it as the same failed create.
G=$(row "$FAILED_REAPED" 'TIER: 2')
[ "$(status_of "$G")" = failed ] && ok \
  || bad "A2: a reaped RESULT_MALFORMED PR_CREATED must close the row failed, got '$G'"

# ── A3..A6 — every other terminal still closes done ─────────────────────────
G=$(row "PR_MERGED https://github.com/example-org/cromford/pull/3" 'TIER: 1')
[ "$(status_of "$G")" = done ] && ok || bad "A3: PR_MERGED must still close done, got '$G'"
G=$(row "PR_CREATED https://github.com/o/r/pull/12 | STACKED on ticket/p (https://github.com/o/r/pull/9)")
[ "$(status_of "$G")" = done ] && ok || bad "A4: a real PR_CREATED must still close done, got '$G'"
# THE NEGATIVE THAT MATTERS. RESULT_UNVERIFIED is a PR that could not be READ,
# not a create that failed: the alert medic owns it and the row stays done.
# Reading it as a failed create would hand the resolver a rebuild of a ticket
# whose PR is probably open.
G=$(row "RESULT_UNVERIFIED PR_CREATED https://github.com/o/r/pull/12")
[ "$(status_of "$G")" = done ] && ok \
  || bad "A5: RESULT_UNVERIFIED is an unread PR, not a failed create — the row closes done, got '$G'"
G=$(row "PLAN_BLOCKED the thread asks how the rep sets the discount")
[ "$(status_of "$G")" = done ] && ok || bad "A6: PLAN_BLOCKED must still close done, got '$G'"

# ── A7 — fail-open: a box with no jobs client records nothing and errors not ─
WITH_QUEUE_DONE=0
G=$(row "$FAILED_RATCHET")
[ -z "$G" ] && ok || bad "A7: with no queue_done there is nothing to close, got '$G'"
[ "$(rc_of)" = 0 ] && ok || bad "A7: the row close must return 0 with no jobs client, got rc=$(rc_of)"
WITH_QUEUE_DONE=1

# ═══════════════════════════════════════════════════════════════════════════
# Section B — the job row (bin/run-build.sh `_job_finish`)
# ═══════════════════════════════════════════════════════════════════════════
cat > "$T/drive-jobfin.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
job_beat_stop() { :; }
job_update()      { printf 'job_update %s\n' "$*" >> "$REC"; }
queue_done()      { printf 'queue_done %s\n' "$*" >> "$REC"; }
job_artifact_put(){ printf 'job_artifact_put %s\n' "$*" >> "$REC"; }
job_event()       { printf 'job_event %s\n' "$*" >> "$REC"; }
job_phase_close_open() { printf 'phase_close %s\n' "$*" >> "$REC"; echo ""; }
. "$JOBFIN"
_job_finish
DRIVE
jobfin() { # jobfin <result-line-1> -> everything the job seams were told
  JREC="$T/jobfin.rec"; : > "$JREC"
  B="$T/jobfin-build"; scratch_rm "$B"; mkdir -p "$B"; printf '%s\n' "$1" > "$B/RESULT"
  JOB_ID=7 JOB_BEAT="" BUILD="$B" QUEUE_CLAIMED=1 PROJECT=project-5 KEY=TK-1883 \
    REC="$JREC" JOBFIN="$JOBFIN" bash "$T/drive-jobfin.sh" >/dev/null 2>&1
  cat "$JREC"
}
OUT=$(jobfin "$FAILED_RATCHET")
grep -q 'job_update .*failed' <<<"$OUT" && ok \
  || bad "B1: PR_CREATE_FAILED must close the job row failed, got: $OUT"
grep -q 'job_update .*done' <<<"$OUT" \
  && bad "B1: PR_CREATE_FAILED must never close the job row done, got: $OUT" || ok
# B2 — the negative the `D` in FAILED buys: `PR_CREATED*` must not swallow it,
# and a real PR_CREATED must not be dragged into `failed` by the new case.
OUT=$(jobfin "PR_CREATED https://github.com/example-org/cromford/pull/12")
grep -q 'job_update .*done' <<<"$OUT" && ok \
  || bad "B2: a real PR_CREATED must still close done, got: $OUT"
# The ticket asks for the word in the RESULT->status map by name, and `*)`
# already answers `failed` — so the behaviour assertions above cannot tell the
# two apart. This is the one place the suite pins source text, and it is guarded
# both ways: the arm must exist AND it must sit above the catch-all, so a file
# that lost the arm fails instead of passing on a missing symbol.
grep -qE '^[[:space:]]*PR_CREATE_FAILED\*\)[[:space:]]*st=failed' "$JOBFIN" && ok \
  || bad "B1: _job_finish must name PR_CREATE_FAILED in the status map, not reach failed through *)"
[ "$(grep -nE '^[[:space:]]*PR_CREATE_FAILED\*\)' "$JOBFIN" | head -1 | cut -d: -f1)" \
  -lt "$(grep -nE '^[[:space:]]*\*\)' "$JOBFIN" | head -1 | cut -d: -f1)" ] 2>/dev/null && ok \
  || bad "B1: the PR_CREATE_FAILED arm must sit above the catch-all, or it never matches"
# B3 — BH-765's word reaches _job_finish only on a hub-side re-read, and it is
# not in the map; `*)` already answers failed for it. Pinned so a later edit that
# reorders the map cannot quietly turn it into `done`.
OUT=$(jobfin "$FAILED_REAPED")
grep -q 'job_update .*failed' <<<"$OUT" && ok \
  || bad "B3: a reaped RESULT_MALFORMED line must not close the job row done, got: $OUT"

# ═══════════════════════════════════════════════════════════════════════════
# Section C — the ledger row for "built, reviewed, no PR"
# ═══════════════════════════════════════════════════════════════════════════
# The WHOLE `# >>> pr create call` block runs, with the create ladder stubbed to
# answer nothing: that is the production path through GH_ERR_AT and the ladder,
# not a paraphrase of the failure branch.
cat > "$T/drive-create.sh" <<'DRIVE'
#!/bin/bash
set -uo pipefail
STAMP() { echo "2026-09-18 00:00:00Z"; }
PR_BODY_FOR() { printf 'body\n'; }
git() { case "$*" in "remote get-url origin") echo "git@github.com:example-org/project-5.git" ;; *) echo "a commit subject" ;; esac; }
gh() { printf 'gh %s\n' "$*" >> "$REC"; exit 1; }
# The real ladder appends gh's words to the stderr log it is handed ($6) while it
# runs. GH_ERR_AT is read BEFORE the ladder, so only these bytes are this
# create's own — a fixture that pre-seeded the file would be testing the wrong
# thing (the block is deliberately blind to a previous run's error).
gh_pr_create_ladder() {
  printf 'ladder %s\n' "$*" >> "$REC"
  printf 'pull request create failed: 422 Base ref must be a branch\n' >> "${6:-/dev/null}"
  cat "$LADDER_OUT" 2>/dev/null
}
job_artifact_put() { printf 'artifact\t%s\t%s\t%s\n' "${1:-}" "${2:-}" "${3:-}" >> "$REC"; }
. "$CREATE"
DRIVE
create_run() { # create_run <ladder-stdout> <job-id>
  CREC="$T/create.rec"; : > "$CREC"
  B="$T/create-build-$NOW"; scratch_rm "$B"; mkdir -p "$B"; : > "$B/gh-stderr.log"
  printf '%s' "$1" > "$T/ladder.out"
  ALERTS="$T/ALERTS.log" BUILD="$B" BRANCH=ticket/TK-1884 BASE=main BASE_MAIN=main \
    PROJECT=project-5 KEY=TK-1884 EVIDENCE_SECTION="" HARNESS="$T/nohome" \
    JOB_ID="$2" LADDER_OUT="$T/ladder.out" REC="$CREC" CREATE="$CREATE" \
    bash "$T/drive-create.sh" >/dev/null 2>&1
}
: > "$T/ALERTS.log"
create_run "" job-1
ART=$(grep '^artifact	' "$T/create.rec" 2>/dev/null)
[ -n "$ART" ] && [ "$(grep -c . <<<"$ART")" = 1 ] && ok \
  || bad "C1: exactly one artifact must be put when the create fails, got: ${ART:-none}"
[ "$(cut -f2 <<<"$ART")" = pr_create_failed ] && ok \
  || bad "C1: the artifact kind must be pr_create_failed, got '$(cut -f2 <<<"$ART")'"
[ "$(cut -f3 <<<"$ART")" = ticket/TK-1884 ] && ok \
  || bad "C1: the artifact ref must be the branch an operator opens the PR from, got '$(cut -f3 <<<"$ART")'"
DET=$(cut -f4 <<<"$ART")
grep -q 'Base ref must be a branch' <<<"$(jq -r '.error // ""' <<<"$DET" 2>/dev/null)" && ok \
  || bad "C1: the artifact detail must carry gh's own words, got '$DET'"
[ "$(jq -r '.branch // ""' <<<"$DET" 2>/dev/null)" = ticket/TK-1884 ] && ok \
  || bad "C1: the artifact detail must name the branch, got '$DET'"
[ "$(jq -r '.base // ""' <<<"$DET" 2>/dev/null)" = main ] && ok \
  || bad "C1: the artifact detail must name the base, got '$DET'"
grep -q 'PR CREATE FAILED on ticket/TK-1884' "$T/ALERTS.log" && ok \
  || bad "C1: the existing ALERTS line must still be written: $(cat "$T/ALERTS.log")"

# ── C2/C3 — the negatives: no failure, or no ledger to write to ──────────────
create_run "https://github.com/example-org/project-5/pull/1930" job-1
[ "$(grep -c '^artifact	' "$T/create.rec")" = 0 ] && ok \
  || bad "C2: a create that returned a url must put no pr_create_failed artifact"
create_run "" ""
[ "$(grep -c '^artifact	' "$T/create.rec")" = 0 ] && ok \
  || bad "C3: with no JOB_ID there is no ledger row to write, and no error either"
grep -q 'PR CREATE FAILED on ticket/TK-1884' "$T/ALERTS.log" && ok \
  || bad "C3: the build must still end the same way with no ledger: $(cat "$T/ALERTS.log")"

echo "pr-create-failed-owned.bh-614: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
