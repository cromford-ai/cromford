#!/bin/bash
# tests/replan-check.bh-3955-test.sh — BH-3955: the replan check between waves.
# A split child (`<KEY>.<n>:` with n >= 1, `Part of #<p>`) whose `Blocked-by`
# siblings have all merged gets ONE cheap model call at PLAN time that answers
# keep / amend / escalate, and the build acts on that answer.
#
# HOW IT DRIVES. The REAL bin/replan-check.sh runs against a scratch $HARNESS in
# which every network seam is a stub that records what it was asked:
# bin/lib/gh-rest.sh (gh_rest reads fixture files keyed by the API path),
# bin/lib/model-route.sh (model_for), bin/jobs-client.sh (the ledger),
# bin/lib/ticket-hold-cmd.sh (thc_run), bin/beat.sh and bin/agent-call.sh. The
# real bin/decision-log.sh and bin/lib/file-children.sh are copied in, so the
# DECISION line and the fence-aware body reader are the shipped ones. A `gh` on
# PATH fails the suite if anything reaches GitHub directly.
#
# The three wiring blocks are EXTRACTED VERBATIM from the flattened pipeline
# (tests/lib/rb-all.sh) and executed: W1-W4 prove bin/lib/rb/plan.sh calls the
# script and acts on its verdict, so deleting the call line turns W1 red.
#
#   R1-R7  the script's verdicts, evidence, side effects and dedup
#   N1-N9  shapes that must SKIP (no model call)
#   E1-E4  model output that must NOT escalate
#   W1-W5  the plan.sh wiring
#   S1     the `replan` and `stage.replan` model_routes seeds in worker/jobs/schema.sql
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/replan-check.bh-3955-test.sh  (0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

SCRIPT="$DIR/bin/replan-check.sh"
[ -x "$SCRIPT" ] && ok || bad "bin/replan-check.sh is missing or not executable"

# ── scratch harness ──────────────────────────────────────────────────────────
H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/logs" "$H/flags" "$H/builds" "$T/fakebin" "$T/fix"
cp "$SCRIPT" "$H/bin/replan-check.sh" 2>/dev/null; chmod +x "$H/bin/replan-check.sh" 2>/dev/null
cp "$DIR/bin/decision-log.sh" "$H/bin/decision-log.sh"; chmod +x "$H/bin/decision-log.sh"
cp "$DIR/bin/lib/file-children.sh" "$H/bin/lib/file-children.sh"

cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "${2:-}" in repo) echo o/r ;; board_prefix) echo - ;; prod) echo - ;; esac
SH
# gh_rest: the API path names the fixture file; `<file>.rc` overrides the rc.
cat > "$H/bin/lib/gh-rest.sh" <<'SH'
gh_rest() {
  local m="$1" p="$2" f
  printf '%s %s\n' "$m" "$p" >> "$GH_REC"
  f="$FIX/$(printf '%s' "$p" | tr '/?&=:' '_____')"
  if [ -e "$f.rc" ]; then return "$(cat "$f.rc")"; fi
  [ -s "$f" ] || return 75
  cat "$f"
}
SH
cat > "$H/bin/lib/model-route.sh" <<'SH'
model_for() {
  printf '%s %s\n' "$1" "${2:-}" >> "$MR_REC"
  [ "${MR_RC:-0}" = 0 ] || return "$MR_RC"
  printf '%s\n' "$MR_MODEL"
}
SH
# The ledger: one file per key, holding the PUT body.
: > "$H/bin/lib/jobs/req.sh"
cat > "$H/bin/jobs-client.sh" <<'SH'
_jobs_req() {
  local m="$1" path="$2" k
  case "$m" in
    GET) k=$(printf '%s' "$path" | tr -c 'A-Za-z0-9' '_')
         [ -s "$LEDGER/$k" ] || return 2
         jq -c '{ledger:.}' "$LEDGER/$k" ;;
  esac
}
job_ledger_put() {
  local q k
  q=$(jq -nr --arg k "$1" --arg v "$2" '"kind="+($k|@uri)+"&key="+($v|@uri)')
  k=$(printf '%s' "/api/ledger?$q" | tr -c 'A-Za-z0-9' '_')
  printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$LEDGER/puts"
  jq -nc --arg s "$3" --arg d "${4:-}" '{status:$s,detail:$d}' > "$LEDGER/$k"
}
SH
cat > "$H/bin/lib/ticket-hold-cmd.sh" <<'SH'
thc_run() {
  printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$THC_REC"
  echo "held"
  return "${THC_RC:-0}"
}
SH
cat > "$H/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$BEAT_REC"
exit "${BEAT_RC:-0}"
SH
# agent-call: records <stage> <project> <model> and the prompt, writes the canned answer.
cat > "$H/bin/agent-call.sh" <<'SH'
#!/bin/bash
printf '%s %s %s lane=%s role=%s\n' "$1" "$2" "$3" "${AGENT_CALL_LANE:-}" "${AGENT_CALL_ROLE:-}" >> "$AC_REC"
case "$6" in @*) cp "${6#@}" "$AC_PROMPT" ;; *) printf '%s' "$6" > "$AC_PROMPT" ;; esac
cat "$AC_OUT" > "$5" 2>/dev/null
exit "${AC_RC:-0}"
SH
# alert-line: the line lands in the scratch ALERTS.log, no beat.
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
while [ $# -gt 0 ]; do case "$1" in --severity|--id|--project) shift 2 ;; *) break ;; esac; done
printf '%s\n' "$*" >> "$HARNESS/logs/ALERTS.log"
SH
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
echo "gh $*" >> "$GH_DIRECT"
exit 1
SH
chmod +x "$H/bin/"*.sh "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
export FIX="$T/fix" GH_REC="$T/gh.rec" MR_REC="$T/mr.rec" LEDGER="$T/ledger" THC_REC="$T/thc.rec"
export BEAT_REC="$T/beat.rec" AC_REC="$T/ac.rec" AC_OUT="$T/ac.out" AC_PROMPT="$T/ac.prompt" GH_DIRECT="$T/gh.direct"
export MR_MODEL="model-from-route"
mkdir -p "$LEDGER"

fx() { # fx <api path> <content>  — a gh_rest fixture
  printf '%s\n' "$2" > "$FIX/$(printf '%s' "$1" | tr '/?&=:' '_____')"
}
fx_rc() { printf '%s\n' "$2" > "$FIX/$(printf '%s' "$1" | tr '/?&=:' '_____').rc"; }

CHILD_BODY='Wire the widget to old_name().

---
Part of #40
Order: 3 of 3
Blocked-by: #49 (hard)'
meta() { # meta <dir> <title> <body> [labels-json]
  jq -nc --arg t "$2" --arg b "$3" --argjson l "${4:-[]}" '{title:$t,labels:$l,body:$b}' > "$1/ticket-meta.json"
}
# The default world: child #61 (BH-61), blocker #49 closed with merged PR #77,
# parent #40 with one comment before the split and one after.
world() {
  scratch_rm "$FIX"; scratch_rm "$LEDGER"; mkdir -p "$FIX" "$LEDGER"
  : > "$GH_REC"; : > "$MR_REC"; : > "$THC_REC"; : > "$BEAT_REC"; : > "$AC_REC"; : > "$GH_DIRECT"
  rm -f "$AC_PROMPT" "$H/logs/decisions.log" "$H/logs/ALERTS.log"
  scratch_rm "$H/builds"; mkdir -p "$H/builds"
  fx "repos/o/r/issues/61" '{"number":61,"state":"open","created_at":"2026-10-01T00:00:00Z"}'
  fx "repos/o/r/issues/49" '{"number":49,"state":"closed"}'
  fx "repos/o/r/pulls?state=closed&head=o:ticket/bh-49&per_page=100" \
     '[{"number":76,"merged_at":null,"merge_commit_sha":"aaa"},{"number":77,"merged_at":"2026-10-02T00:00:00Z","merge_commit_sha":"sha77"}]'
  fx "repos/o/r/pulls/77/files?per_page=100" \
     '[{"filename":"lib/widget.js","patch":"@@ -1 +1 @@\n-function old_name() {}\n+function new_name() {}"}]'
  fx "repos/o/r/issues/40/comments?since=2026-10-01T00:00:00Z&per_page=100" \
     '[{"id":901,"created_at":"2026-09-30T00:00:00Z","body":"COMMENT-BEFORE-SPLIT"},{"id":902,"created_at":"2026-10-02T05:00:00Z","body":"COMMENT-AFTER-SPLIT: keep v1 alive"}]'
  mkdir -p "$H/builds/proj-BH-49-202610020000"
  printf 'REVIEW-FINDING: rename landed cleanly\n' > "$H/builds/proj-BH-49-202610020000/review.md"
  printf 'QA-FINDING: widget page renders\n' > "$H/builds/proj-BH-49-202610020000/preview-qa.md"
  AC_RC=0; MR_RC=0; THC_RC=0; BEAT_RC=0
}
newbuild() { B="$T/build-$1"; scratch_rm "$B"; mkdir -p "$B"; }
run_check() { # run_check [env...] — the REAL script, from the scratch harness
  env HARNESS="$H" STACK_ON="${STACK_ON:-}" AC_RC="$AC_RC" MR_RC="$MR_RC" THC_RC="$THC_RC" BEAT_RC="$BEAT_RC" "$@" \
    "$H/bin/replan-check.sh" proj 61 BH-61 "$B" > "$B/check.out" 2>&1
  echo $?
}
verdict() { head -1 "$B/replan-verdict" 2>/dev/null; }
calls()   { grep -c . "$AC_REC" 2>/dev/null || true; }

AMEND_OUT='Looked at the blocker diff.
AMEND-BEGIN
Call new_name() instead of old_name(). Acceptance: tests call new_name.
AMEND-END
REPLAN: amend'

# ═══ R1 amend ════════════════════════════════════════════════════════════════
world; newbuild r1; meta "$B" "BH-50.2: wire the widget" "$CHILD_BODY"
printf '%s\n' "$AMEND_OUT" > "$AC_OUT"
rc=$(run_check)
[ "$rc" = 0 ] && ok || bad "R1: the script must exit 0, got $rc ($(cat "$B/check.out"))"
case "$(verdict)" in amend*) ok ;; *) bad "R1: verdict must be amend, got '$(verdict)'" ;; esac
grep -q 'new_name' "$B/replan-amendment.md" 2>/dev/null && ok || bad "R1: replan-amendment.md must carry the amended scope"
grep -q 'AMEND-BEGIN\|REPLAN:' "$B/replan-amendment.md" 2>/dev/null && bad "R1: the amendment must not carry the markers" || ok
[ -s "$B/replan-comment.md" ] && ok || bad "R1: replan-comment.md must be written"
grep -q '#77' "$B/replan-comment.md" 2>/dev/null && grep -q 'new_name' "$B/replan-comment.md" && ok \
  || bad "R1: the comment must name the merged PR and the amended scope ($(cat "$B/replan-comment.md" 2>/dev/null))"
grep -q '—' "$B/replan-comment.md" 2>/dev/null && bad "R1: the fixed comment copy must carry no em dash" || ok
grep -q 'gate=replan scope=child BH-61 :: replan-amend ::' "$H/logs/decisions.log" 2>/dev/null && ok \
  || bad "R1: decisions.log must gain the replan-amend line ($(cat "$H/logs/decisions.log" 2>/dev/null))"
# R1 evidence: (a) the patch hunk
grep -q '+function new_name' "$B/replan-evidence.md" 2>/dev/null && ok || bad "R1: the evidence must carry the blocker's patch"
# R1b: review and preview-QA findings from the local record
grep -q 'REVIEW-FINDING' "$B/replan-evidence.md" && grep -q 'QA-FINDING' "$B/replan-evidence.md" && ok \
  || bad "R1b: the evidence must carry the blocker's review and preview-QA findings"
# R1c: parent comments since the split only
grep -q 'COMMENT-AFTER-SPLIT' "$B/replan-evidence.md" && ok || bad "R1c: a parent comment after the split must be in the evidence"
grep -q 'COMMENT-BEFORE-SPLIT' "$B/replan-evidence.md" && bad "R1c: a parent comment from before the split must not be in the evidence" || ok
# R1d: never re-splits or re-orders: no write verb to GitHub at all
grep -qv '^GET ' "$GH_REC" && bad "R1d: the script must only READ GitHub, got: $(grep -v '^GET ' "$GH_REC")" || ok
[ -s "$GH_DIRECT" ] && bad "R1: nothing may call gh directly ($(cat "$GH_DIRECT"))" || ok
[ -s "$THC_REC" ] && bad "R1: amend must not hold the ticket" || ok
[ -s "$BEAT_REC" ] && bad "R1: amend must not beat" || ok
# R6: the model is the one the replan route answered
[ "$(calls)" = 1 ] && ok || bad "R6: exactly one model call, got $(calls)"
grep -q '^replan proj model-from-route lane=fly-pool role=replan$' "$AC_REC" && ok \
  || bad "R6: agent-call must get stage replan and the routed model ($(cat "$AC_REC"))"
grep -q '^replan proj$' "$MR_REC" && ok || bad "R6: the model must come from model_for replan <project> ($(cat "$MR_REC"))"
grep -q 'REPLAN: escalate :: ' "$AC_PROMPT" 2>/dev/null && grep -q 'old_name' "$AC_PROMPT" && ok \
  || bad "R6: the prompt must carry the output contract and the child body"
grep -q '^amend ' "$LEDGER/puts" 2>/dev/null && bad "R1: ledger key misuse" || ok
grep -q '^replan|proj BH-61|amend [0-9a-f]\{64\}$' "$LEDGER/puts" && ok \
  || bad "R1: the clean verdict must be recorded in the ledger as '<verdict> <fp>' ($(cat "$LEDGER/puts" 2>/dev/null))"

# R7 dedup: a second build on the same evidence makes no model call and reuses the amendment.
newbuild r7; meta "$B" "BH-50.2: wire the widget" "$CHILD_BODY"
: > "$AC_OUT"
run_check >/dev/null
[ "$(calls)" = 1 ] && ok || bad "R7: same evidence must not buy a second model call (calls=$(calls))"
case "$(verdict)" in amend*) ok ;; *) bad "R7: the reused verdict must be amend, got '$(verdict)'" ;; esac
grep -q 'new_name' "$B/replan-amendment.md" 2>/dev/null && ok || bad "R7: the reused amendment must reach this build"
[ -e "$B/replan-comment.md" ] && bad "R7: a reused amendment must not comment on the child a second time" || ok
# ...and new evidence (a new parent comment) buys a new call.
newbuild r7b; meta "$B" "BH-50.2: wire the widget" "$CHILD_BODY"
fx "repos/o/r/issues/40/comments?since=2026-10-01T00:00:00Z&per_page=100" \
   '[{"id":902,"created_at":"2026-10-02T05:00:00Z","body":"COMMENT-AFTER-SPLIT"},{"id":903,"created_at":"2026-10-02T06:00:00Z","body":"one more"}]'
printf 'REPLAN: keep\n' > "$AC_OUT"
run_check >/dev/null
[ "$(calls)" = 2 ] && ok || bad "R7: changed evidence must buy a new call (calls=$(calls))"
case "$(verdict)" in keep*) ok ;; *) bad "R7: the new call's keep must stand, got '$(verdict)'" ;; esac
# Resume: a build dir that already has a verdict reuses it, no call.
run_check >/dev/null
[ "$(calls)" = 2 ] && ok || bad "R7: a resumed build dir must not buy a call (calls=$(calls))"

# ═══ R2 escalate ═════════════════════════════════════════════════════════════
world; newbuild r2; meta "$B" "BH-50.2: wire the widget" "$CHILD_BODY"
printf 'thinking\nREPLAN: escalate :: does the widget keep the v1 API?\n' > "$AC_OUT"
run_check >/dev/null
case "$(verdict)" in escalate*) ok ;; *) bad "R2: verdict must be escalate, got '$(verdict)'" ;; esac
grep -q '^hold|proj|' "$THC_REC" && ok || bad "R2: thc_run hold must be called ($(cat "$THC_REC"))"
[ "$(jq -r .ticket <<<"$(cut -d'|' -f3- "$THC_REC")" 2>/dev/null)" = BH-61 ] && ok || bad "R2: the hold payload must name the child key"
jq -r .reason <<<"$(cut -d'|' -f3- "$THC_REC")" 2>/dev/null | grep -q 'v1 API' && ok || bad "R2: the hold reason must carry the decision"
[ "$(grep -c . "$BEAT_REC")" = 1 ] && ok || bad "R2: exactly one beat, got $(grep -c . "$BEAT_REC")"
jq -e '.kind=="fleet_alert" and .project=="proj" and (.line|test("v1 API")) and (.akey=="replan-escalate-proj-BH-61") and (has("text")|not)' "$BEAT_REC" >/dev/null 2>&1 && ok \
  || bad "R2: the beat must be a fleet_alert naming the decision ($(cat "$BEAT_REC"))"
grep -q 'v1 API' "$B/replan-decision.txt" 2>/dev/null && ok || bad "R2: replan-decision.txt must hold the decision"
grep -q 'replan-escalate :: ' "$H/logs/decisions.log" 2>/dev/null && ok || bad "R2: decisions.log must gain replan-escalate"
[ "$(cat "$B/replan-beat" 2>/dev/null)" = 0 ] && ok || bad "R2: replan-beat must record the beat rc"

# R2d: same evidence, hold label still on -> escalate reused, no call, no second beat.
newbuild r2d; meta "$B" "BH-50.2: wire the widget" "$CHILD_BODY" '[{"name":"hold"}]'
: > "$THC_REC"; : > "$BEAT_REC"; n0=$(calls)
run_check >/dev/null
[ "$(calls)" = "$n0" ] && ok || bad "R2d: a standing escalation must not buy a call"
case "$(verdict)" in escalate*) ok ;; *) bad "R2d: a standing escalation must stay escalate, got '$(verdict)'" ;; esac
[ -s "$BEAT_REC" ] && bad "R2d: a reused escalation must not beat again" || ok

# R2c (on R2's ledger row): the human lifted the hold (no hold label now) on the same evidence -> keep, no call, no re-escalation.
newbuild r2c; meta "$B" "BH-50.2: wire the widget" "$CHILD_BODY" '[{"name":"ai-build"}]'
: > "$THC_REC"; : > "$BEAT_REC"
n0=$(calls)
run_check >/dev/null
[ "$(calls)" = "$n0" ] && ok || bad "R2c: an answered escalation must not buy a call"
case "$(verdict)" in "keep escalation answered"*) ok ;; *) bad "R2c: verdict must be keep (escalation answered), got '$(verdict)'" ;; esac
[ -s "$THC_REC" ] && bad "R2c: an answered escalation must not be held again" || ok

# R2b: the hold fails -> no beat, one ALERTS line, verdict says so.
world; newbuild r2b; meta "$B" "BH-50.2: wire the widget" "$CHILD_BODY"
printf 'REPLAN: escalate :: does the widget keep the v1 API?\n' > "$AC_OUT"
THC_RC=1 run_check THC_RC=1 >/dev/null
[ -s "$BEAT_REC" ] && bad "R2b: a failed hold must not beat" || ok
[ "$(grep -c 'BH-61' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok || bad "R2b: one ALERTS line naming the key"
case "$(verdict)" in "escalate hold-failed"*) ok ;; *) bad "R2b: verdict must be 'escalate hold-failed', got '$(verdict)'" ;; esac
# An escalation that never parked anything is not an answered question later.
[ -s "$LEDGER/puts" ] && bad "R2b: a failed hold must not be cached ($(cat "$LEDGER/puts"))" || ok


# ═══ R3 model failure ════════════════════════════════════════════════════════
world; newbuild r3; meta "$B" "BH-50.2: wire the widget" "$CHILD_BODY"
printf 'partial\n' > "$AC_OUT"
run_check AC_RC=1 >/dev/null
case "$(verdict)" in "keep model error: agent-call rc=1"*) ok ;; *) bad "R3: a failed call must be 'keep model error', got '$(verdict)'" ;; esac
grep -q 'replan-keep :: model error' "$H/logs/decisions.log" 2>/dev/null && ok || bad "R3: decisions.log must gain replan-keep"
[ -s "$LEDGER/puts" ] && bad "R3: a model failure must not be cached" || ok
# R3b: rc 0 but no REPLAN line
newbuild r3b; meta "$B" "BH-50.2: wire the widget" "$CHILD_BODY"
printf 'I think it is fine.\n' > "$AC_OUT"
run_check >/dev/null
case "$(verdict)" in "keep model error"*) ok ;; *) bad "R3b: no REPLAN line must be 'keep model error', got '$(verdict)'" ;; esac
# R3c: amend with an empty block
newbuild r3c; meta "$B" "BH-50.2: wire the widget" "$CHILD_BODY"
printf 'AMEND-BEGIN\nAMEND-END\nREPLAN: amend\n' > "$AC_OUT"
run_check >/dev/null
case "$(verdict)" in "keep model error"*) ok ;; *) bad "R3c: an empty amendment must be 'keep model error', got '$(verdict)'" ;; esac
[ -e "$B/replan-amendment.md" ] && bad "R3c: no amendment file on an empty block" || ok

# ═══ R4 no route ═════════════════════════════════════════════════════════════
world; newbuild r4; meta "$B" "BH-50.2: wire the widget" "$CHILD_BODY"
run_check MR_RC=75 >/dev/null
case "$(verdict)" in "keep no route"*) ok ;; *) bad "R4: verdict must be 'keep no route', got '$(verdict)'" ;; esac
[ "$(calls)" = 0 ] && ok || bad "R4: no route must not call agent-call"

# ═══ R5 no evidence ══════════════════════════════════════════════════════════
world; newbuild r5; meta "$B" "BH-50.2: wire the widget" "$CHILD_BODY"
fx "repos/o/r/pulls/77/files?per_page=100" '[]'
fx "repos/o/r/issues/40/comments?since=2026-10-01T00:00:00Z&per_page=100" '[]'
scratch_rm "$H/builds"; mkdir -p "$H/builds"
run_check >/dev/null
case "$(verdict)" in "keep no evidence"*) ok ;; *) bad "R5: verdict must be 'keep no evidence', got '$(verdict)'" ;; esac
[ "$(calls)" = 0 ] && ok || bad "R5: no evidence must not call agent-call"

# ═══ N negatives: skip, never a call ═════════════════════════════════════════
neg() { # neg <label> <title> <body> <expected-skip-reason> [env...]
  local label="$1" title="$2" body="$3" want="$4"; shift 4
  world; newbuild "$label"; meta "$B" "$title" "$body"
  printf '%s\n' "$AMEND_OUT" > "$AC_OUT"
  run_check "$@" >/dev/null
  case "$(verdict)" in "skip $want"*) ok ;; *) bad "$label: want 'skip $want', got '$(verdict)'" ;; esac
  [ "$(calls)" = 0 ] && ok || bad "$label: a skip must not call the model"
  [ -e "$H/logs/decisions.log" ] && bad "$label: a skip must not write a DECISION line" || ok
}
neg N1 "BH-12: top level ticket" "$CHILD_BODY" "not a child"
neg N2 "BH-12.0: contract — the types" "$CHILD_BODY" "not a child"
neg N3 "Bump node to 20.1 in CI" "$CHILD_BODY" "not a child"
neg N4 "BH-12.1: no parent line" 'Blocked-by: #49' "not a child"
neg N5 "BH-12.2: parent only in a fence" $'```\nPart of #40\n```\nBlocked-by: #49' "not a child"
# N6: one merged blocker and one open one.
world; newbuild N6b; meta "$B" "BH-12.2: one blocker open" "$(printf '%s\nBlocked-by: #50' "$CHILD_BODY")"
fx "repos/o/r/issues/50" '{"number":50,"state":"open"}'
run_check >/dev/null
case "$(verdict)" in "skip blockers not merged"*) ok ;; *) bad "N6: one open blocker must skip, got '$(verdict)'" ;; esac
[ "$(calls)" = 0 ] && ok || bad "N6: one open blocker must not call the model"
neg N7 "BH-12.2: stacked" "$CHILD_BODY" "stacked build" STACK_ON=ticket/bh-49
# N8: blocker closed with no merged PR (closed as not planned)
world; newbuild N8; meta "$B" "BH-12.2: wire" "$CHILD_BODY"
fx "repos/o/r/pulls?state=closed&head=o:ticket/bh-49&per_page=100" '[{"number":76,"merged_at":null}]'
run_check >/dev/null
case "$(verdict)" in "skip blockers not merged"*) ok ;; *) bad "N8: closed-unmerged blocker must skip, got '$(verdict)'" ;; esac
[ "$(calls)" = 0 ] && ok || bad "N8: must not call the model"
# N9: an unreadable blocker read is NOT merged
world; newbuild N9; meta "$B" "BH-12.2: wire" "$CHILD_BODY"
fx_rc "repos/o/r/issues/49" 75
run_check >/dev/null
case "$(verdict)" in "skip blockers not merged"*) ok ;; *) bad "N9: an unreadable blocker must skip, got '$(verdict)'" ;; esac
[ "$(calls)" = 0 ] && ok || bad "N9: must not call the model"
neg N10 "BH-12.2: no blockers" $'Part of #40\nOrder: 2 of 3' "no blockers"
neg N11 "BH-12.2: kill switch" "$CHILD_BODY" "off" REPLAN_CHECK=0
world; newbuild N12; meta "$B" "BH-12.2: flag" "$CHILD_BODY"; touch "$H/flags/replan-check-off"
run_check >/dev/null; rm -f "$H/flags/replan-check-off"
case "$(verdict)" in "skip off"*) ok ;; *) bad "N12: flags/replan-check-off must skip, got '$(verdict)'" ;; esac
world; newbuild N13
run_check >/dev/null
case "$(verdict)" in "skip not a child"*) ok ;; *) bad "N13: no ticket-meta.json must skip, got '$(verdict)'" ;; esac

# ═══ E escalate-parse negatives: never a hold ════════════════════════════════
esc_neg() { # esc_neg <label> <model output>
  world; newbuild "$1"; meta "$B" "BH-50.2: wire the widget" "$CHILD_BODY"
  printf '%s\n' "$2" > "$AC_OUT"
  run_check >/dev/null
  [ -s "$THC_REC" ] && bad "$1: must not hold ($(cat "$THC_REC"))" || ok
  [ -s "$BEAT_REC" ] && bad "$1: must not beat" || ok
  case "$(verdict)" in escalate*) bad "$1: verdict must not be escalate, got '$(verdict)'" ;; *) ok ;; esac
}
esc_neg E1 'REPLAN: escalate'
esc_neg E2 'REPLAN: escalated :: something'
esc_neg E3 'I would write REPLAN: escalate :: is this right? but no.'
esc_neg E4 $'REPLAN: escalate :: should we?\nOn reflection:\nREPLAN: keep'
case "$(verdict)" in keep*) ok ;; *) bad "E4: the last REPLAN line wins, got '$(verdict)'" ;; esac

# ═══ W wiring: the real plan.sh blocks ═══════════════════════════════════════
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
marked() { awk -v s="$1" -v e="$2" 'index($0,s){f=1;next} index($0,e){f=0} f' "$3"; }
marked '# >>> replan check (BH-3955)' '# <<< replan check (BH-3955)' "$RB" > "$T/w-check.sh"
marked '# >>> replan comment (BH-3955)' '# <<< replan comment (BH-3955)' "$RB" > "$T/w-comment.sh"
awk '/^# >>> preplan adopt$/{f=1} /^# <<< preplan adopt$/{exit} f' "$RB" > "$T/w-adopt.sh"
marked '# >>> plan prompt' '# <<< plan prompt' "$RB" > "$T/w-prompt.sh"
for f in w-check w-comment w-adopt w-prompt; do
  [ -s "$T/$f.sh" ] && ok || bad "W: block $f is missing from bin/lib/rb/plan.sh"
  bash -n "$T/$f.sh" 2>/dev/null && ok || bad "W: block $f is not valid bash on its own"
done
ln_of() { grep -nF -m1 "$1" "$RB" | cut -d: -f1; }
a=$(ln_of '# <<< rollout hook'); b=$(ln_of '# >>> replan check (BH-3955)'); c=$(ln_of '# >>> preplan adopt')
[ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && ok \
  || bad "W: the replan check must sit after the rollout hook ($a) and before the preplan adopt ($c): $b"
s=$(ln_of 'PLAN_STALE thread moved during planning'); g=$(ln_of '# <<< plan gate'); d=$(ln_of '# >>> replan comment (BH-3955)')
[ -n "$s" ] && [ -n "$d" ] && [ -n "$g" ] && [ "$s" -lt "$d" ] && [ "$g" -lt "$d" ] && ok \
  || bad "W: the comment post must sit after the thread-stability re-check ($s) and the plan gate ($g): $d"

cat > "$T/w-pre.sh" <<'SH'
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
BB() { printf 'BB %s\n' "$*" >> "$BUILD/bb.rec"; }
RESULT() { printf '%s\n' "$1" > "$BUILD/result"; }
SH
w_run() { # w_run — the extracted 2a block, then a sentinel that proves fall-through
  { cat "$T/w-pre.sh" "$T/w-check.sh"; printf '\nprintf "REACHED\\n%%s" "$REPLAN_LINE" > "$BUILD/reached"\n'; } > "$T/w-run.sh"
  env HARNESS="$H" PROJECT=proj TICKET=61 KEY=BH-61 BUILD="$B" STACK_ON="${STACK_ON:-}" AC_RC="$AC_RC" MR_RC="$MR_RC" "$@" bash "$T/w-run.sh" > /dev/null 2>&1
  echo $?
}
# W1: amend -> REPLAN_LINE carries the amendment, the plan path continues.
world; newbuild W1; meta "$B" "BH-50.2: wire the widget" "$CHILD_BODY"
printf '%s\n' "$AMEND_OUT" > "$AC_OUT"
rc=$(w_run)
[ "$rc" = 0 ] && head -1 "$B/reached" 2>/dev/null | grep -q REACHED && ok || bad "W1: amend must fall through to the plan (rc=$rc)"
grep -q 'AMENDED' "$B/reached" 2>/dev/null && grep -q 'new_name' "$B/reached" && ok \
  || bad "W1: REPLAN_LINE must carry the amendment ($(cat "$B/reached" 2>/dev/null))"
[ "$(calls)" = 1 ] && ok || bad "W1: the block must run the real replan-check.sh once (calls=$(calls))"
# W1': model failure -> empty REPLAN_LINE, no RESULT, no exit.
world; newbuild W1b; meta "$B" "BH-50.2: wire the widget" "$CHILD_BODY"
rc=$(w_run AC_RC=1)
[ "$rc" = 0 ] && [ "$(cat "$B/reached" 2>/dev/null)" = REACHED ] && ok || bad "W1': a failed model call must leave REPLAN_LINE empty and fall through (rc=$rc, $(cat "$B/reached" 2>/dev/null))"
[ -e "$B/result" ] && bad "W1': a failed model call must not write a RESULT" || ok
# W1'': a skip (not a child) falls through with an empty line too.
world; newbuild W1c; meta "$B" "BH-12: top" "$CHILD_BODY"
rc=$(w_run)
[ "$rc" = 0 ] && [ "$(cat "$B/reached" 2>/dev/null)" = REACHED ] && ok || bad "W1'': a skip must fall through untouched"
# W2: escalate -> plan.md BLOCKED, RESULT PLAN_BLOCKED, exit 4.
world; newbuild W2; meta "$B" "BH-50.2: wire the widget" "$CHILD_BODY"
printf 'REPLAN: escalate :: does the widget keep the v1 API?\n' > "$AC_OUT"
rc=$(w_run)
[ "$rc" = 4 ] && ok || bad "W2: escalate must exit 4, got $rc"
[ ! -e "$B/reached" ] && ok || bad "W2: escalate must not reach the plan"
head -1 "$B/plan.md" 2>/dev/null | grep -Eq '^[[:space:]]*([#*]+[[:space:]]*)*(PLAN[_ -])?BLOCKED([^_[:alnum:]]|$)' && ok \
  || bad "W2: plan.md line 1 must satisfy PLAN_IS_BLOCKED ($(head -1 "$B/plan.md" 2>/dev/null))"
grep -q 'v1 API' "$B/plan.md" 2>/dev/null && ok || bad "W2: plan.md must name the decision"
[ "$(cat "$B/result" 2>/dev/null)" = "PLAN_BLOCKED $B/plan.md" ] && ok || bad "W2: RESULT must be PLAN_BLOCKED <plan.md>, got '$(cat "$B/result" 2>/dev/null)'"
grep -q '^BB plan_blocked' "$B/bb.rec" 2>/dev/null && ok || bad "W2: BB plan_blocked must be emitted"
grep -q 'The `hold` label parks it' "$B/plan.md" 2>/dev/null && ok || bad "W2: a held escalate must say the label parks it"
# W2c: the hold failed -> still PLAN_BLOCKED, but plan.md must not claim a label is on.
world; newbuild W2c; meta "$B" "BH-50.2: wire the widget" "$CHILD_BODY"
printf 'REPLAN: escalate :: does the widget keep the v1 API?\n' > "$AC_OUT"
rc=$(w_run THC_RC=1)
[ "$rc" = 4 ] && [ "$(cat "$B/result" 2>/dev/null)" = "PLAN_BLOCKED $B/plan.md" ] && ok || bad "W2c: a hold-failed escalate must still PLAN_BLOCK (rc=$rc)"
case "$(head -1 "$B/replan-verdict" 2>/dev/null)" in "escalate hold-failed"*) ok ;; *) bad "W2c: verdict must be hold-failed, got '$(head -1 "$B/replan-verdict" 2>/dev/null)'" ;; esac
grep -q 'label parks it' "$B/plan.md" 2>/dev/null && bad "W2c: plan.md must not claim the hold label parks it ($(cat "$B/plan.md"))" || ok
grep -q 'could NOT be applied' "$B/plan.md" 2>/dev/null && ok || bad "W2c: plan.md must say the hold label was not applied"
# W2b: the script is not executable on this box -> the plan runs as today.
world; newbuild W2b; meta "$B" "BH-50.2: wire the widget" "$CHILD_BODY"
chmod -x "$H/bin/replan-check.sh"; rc=$(w_run); chmod +x "$H/bin/replan-check.sh"
[ "$rc" = 0 ] && [ "$(cat "$B/reached" 2>/dev/null)" = REACHED ] && [ "$(calls)" = 0 ] && ok || bad "W2b: no executable script must fall through with no call"

# W3: the comment post, after the plan.
COMMENT_PRE="$T/w-comment-pre.sh"
cat > "$COMMENT_PRE" <<'SH'
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
gh_rest_comment() { printf '%s %s %s\n' "$1" "$2" "$(cat "$3")" >> "$POST_REC"; return "${POST_RC:-0}"; }
TICKET_FP() { echo "fp-after-comment"; }
SH
c_run() {
  cat "$COMMENT_PRE" "$T/w-comment.sh" > "$T/c-run.sh"
  env HARNESS="$H" PROJECT=proj TICKET=61 KEY=BH-61 BUILD="$B" POST_REC="$T/post.rec" FP_BEFORE=fp-before "$@" bash "$T/c-run.sh" >/dev/null 2>&1
}
newbuild W3; printf 'We adjusted the scope.\n' > "$B/replan-comment.md"; printf 'fp-before\n' > "$B/ticket-fp"; : > "$T/post.rec"
c_run GH_TOKEN=ghs_apptoken
[ "$(grep -c . "$T/post.rec")" = 1 ] && grep -q '^o/r 61 We adjusted' "$T/post.rec" && ok || bad "W3: the comment must be posted once on the child ($(cat "$T/post.rec"))"
[ -e "$B/replan-commented" ] && ok || bad "W3: the marker must be touched after a post"
[ "$(cat "$B/ticket-fp" 2>/dev/null)" = fp-after-comment ] && ok || bad "W3: ticket-fp must be refreshed after our own comment"
c_run GH_TOKEN=ghs_apptoken
[ "$(grep -c . "$T/post.rec")" = 1 ] && ok || bad "W3: a resume must not post twice"
# W3b: no App identity -> skipped, logged, marker touched, nothing posted.
newbuild W3b; printf 'x\n' > "$B/replan-comment.md"; : > "$T/post.rec"
c_run GH_TOKEN=ghp_pat
[ -s "$T/post.rec" ] && bad "W3b: a PAT must never post model text" || ok
grep -q 'no App identity' "$B/pipeline.log" 2>/dev/null && [ -e "$B/replan-comment-skipped" ] && ok || bad "W3b: the skip must be logged and marked replan-comment-skipped"
[ -e "$B/replan-commented" ] && bad "W3b: a skip must never stamp replan-commented (nothing was delivered)" || ok
c_run GH_TOKEN=ghp_pat
[ "$(grep -c 'no App identity' "$B/pipeline.log" 2>/dev/null)" = 1 ] && ok || bad "W3b: a resume must not re-log the skip"
# W3c: a failed post leaves no marker, so a resume retries.
newbuild W3c; printf 'x\n' > "$B/replan-comment.md"; : > "$T/post.rec"
c_run GH_TOKEN=ghs_apptoken POST_RC=75
[ -e "$B/replan-commented" ] && bad "W3c: a failed post must not be marked done" || ok
grep -q 'replan comment' "$B/pipeline.log" 2>/dev/null && ok || bad "W3c: the failure must be logged"
# W3d: no comment file -> nothing at all.
newbuild W3d; : > "$T/post.rec"
c_run GH_TOKEN=ghs_apptoken
[ -s "$T/post.rec" ] && bad "W3d: no comment file must post nothing" || ok

# W4: the preplan adopt arm refuses a pre-plan once the scope was amended.
newbuild W4; printf 'amended\n' > "$B/replan-amendment.md"
{ printf 'STAMP() { date; }\nBB() { :; }\npreplan_find() { echo "%s"; }\npreplan_speculative() { echo 1; }\n' "$T"; cat "$T/w-adopt.sh"; } > "$T/a-run.sh"
env HARNESS="$H" PROJECT=proj KEY=BH-61 BUILD="$B" FP_BEFORE="" bash "$T/a-run.sh" >/dev/null 2>&1
grep -q '^MISS replan amended' "$B/preplan-outcome" 2>/dev/null && ok || bad "W4: an amended child must not adopt a pre-plan ($(cat "$B/preplan-outcome" 2>/dev/null))"
[ "$(grep -c 'PREPLAN_' "$B/pipeline.log" 2>/dev/null)" = 1 ] && ok || bad "W4: exactly one PREPLAN_ line"

# W5: the plan prompt carries REPLAN_LINE.
newbuild W5
# TEST-CHANGE (BH-7970): the block renders prompts/stages/plan.md through sp_render, so the driver sources the repo lib first.
{ printf 'CC() { printf "%%s" "$5" > "$BUILD/prompt"; }\n. "%s/bin/lib/stage-prompt.sh"\n' "$DIR"; cat "$T/w-prompt.sh"; } > "$T/p-run.sh"
env BUILD="$B" KEY=BH-61 TICKET=61 PROJECT=proj REPLAN_LINE=" REPLAN-LINE-MARKER" bash "$T/p-run.sh" >/dev/null 2>&1
grep -q 'REPLAN-LINE-MARKER' "$B/prompt" 2>/dev/null && ok || bad "W5: the CC plan prompt must carry \${REPLAN_LINE:-}"

# ═══ S1 the replan seed ══════════════════════════════════════════════════════
SEED=$(awk '/^-- >>> replan seed \(BH-3955\)/{f=1;next} /^-- <<< replan seed/{f=0} f' "$DIR/worker/jobs/schema.sql")
[ -n "$SEED" ] && ok || bad "S1: the replan seed is missing from worker/jobs/schema.sql"
grep -q "claude-\|gpt-\|grok-" <<<"$SEED" && bad "S1: the seed must carry no model literal" || ok
if command -v node >/dev/null 2>&1 && node -e 'require("node:sqlite")' 2>/dev/null; then
  cat > "$T/s1.sql" <<'SQL'
CREATE TABLE model_routes (id INTEGER PRIMARY KEY AUTOINCREMENT, scope TEXT NOT NULL, project TEXT, role TEXT NOT NULL, position INTEGER NOT NULL, model TEXT NOT NULL, runner TEXT NOT NULL, updated_by TEXT, updated_at TEXT NOT NULL);
CREATE UNIQUE INDEX idx_model_routes_key ON model_routes(coalesce(project,''), role, position);
CREATE TABLE model_route_changes (id INTEGER PRIMARY KEY AUTOINCREMENT, scope TEXT NOT NULL, project TEXT, role TEXT NOT NULL, position INTEGER NOT NULL, before_model TEXT, before_runner TEXT, after_model TEXT, after_runner TEXT, actor TEXT NOT NULL, reason TEXT, at TEXT NOT NULL);
INSERT INTO model_routes (scope,project,role,position,model,runner,updated_by,updated_at) VALUES ('hub',NULL,'triage.light',0,'light-model','claude','seed','x');
SQL
  printf '%s\n' "$SEED" > "$T/s1-seed.sql"
  printf "INSERT INTO model_route_changes (scope,project,role,position,actor,at) VALUES ('hub',NULL,'replan',0,'op','x');\n" > "$T/s1-tomb.sql"
  s1() { # s1 <with-tombstone 0|1> -> replan rows as model|runner (the seed applied twice)
    node --no-warnings -e '
const { DatabaseSync } = require("node:sqlite"); const fs = require("fs");
const db = new DatabaseSync(":memory:");
db.exec(fs.readFileSync(process.argv[2], "utf8"));
if (process.argv[3] === "1") db.exec(fs.readFileSync(process.argv[4], "utf8"));
const seed = fs.readFileSync(process.argv[1], "utf8"); db.exec(seed); db.exec(seed);
for (const role of ["replan", "stage.replan"]) for (const r of db.prepare("SELECT model, runner FROM model_routes WHERE project IS NULL AND role=?").all(role)) console.log(role + "=" + r.model + "|" + r.runner);
 ' "$T/s1-seed.sql" "$T/s1.sql" "$1" "$T/s1-tomb.sql" 2>&1
  }
  [ "$(s1 0)" = $'replan=light-model|claude\nstage.replan=light-model|claude' ] && ok \
    || bad "S1: the seed must copy triage.light rung 0 exactly once into replan and stage.replan, got '$(s1 0)'"
  [ "$(s1 1)" = 'stage.replan=light-model|claude' ] && ok || bad "S1: a tombstoned replan role must not be re-seeded, got '$(s1 1)'"
else
  echo "NOTE: S1 sqlite half skipped (no node:sqlite on this box)"
fi

echo "replan-check.bh-3955: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
