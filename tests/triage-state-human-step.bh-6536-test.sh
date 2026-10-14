#!/bin/bash
# tests/triage-state-human-step.bh-6536-test.sh — BH-6536: the triage
# pre-check never sends to the model, and never launches, a GitHub ticket whose
# build ended REVIEW_BLOCKED on a human step that a person then did.
#
# Real code: bin/lib/triage-state.sh (ts_precheck, _ts_human_step),
# bin/triage-state.py, bin/triage-gate.sh --thread, bin/lib/gh-rest.sh,
# bin/lib/builds-of-record.sh, bin/lib/needs-human/step-done.sh and the jobs
# client. The network edges are stubs: `gh` on PATH serves the issue thread, and
# _jobs_req (the one function every jobs-client verb calls) serves the worker
# routes this pass reads, and records every request.
#
#   T1 a done comment and a ticket_stage row human-step-done: a `candidate`
#      decision becomes skip human-step:human-step-done, the observe write says
#      so, nothing is enqueued and run-build.sh is not started
#   T2 no stage row, newest build REVIEW_BLOCKED before the done comment:
#      skip human-step:done-unclaimed, one ticket_stage PUT by lane triage; no
#      local review.md, so the reason says this box cannot read the review
#   T2b the same with a local human-step-only review.md: the reason names the
#      rescue lane's check of that build
#   T2c the same with a local code BLOCK review.md: decision unchanged, no PUT
#   T3 no done comment: decision unchanged, 0 ledger / artifact requests
#   T4 the ledger read fails: decision unchanged
#   T5 the newest build is PR_CREATED: decision unchanged
#   T6 a stage row handed-to-resolver, then a newer PLAN_BLOCKED record (the
#      resolver's rebuild): decision unchanged, no PUT (the skip releases)
#   T7 a stage row newer than the REVIEW_BLOCKED record, and the local record
#      carries .blocked-resolver-superseded: decision unchanged
#
# Run from anywhere: tests/triage-state-human-step.bh-6536-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 is required"; exit 1; }
export PYTHONDONTWRITEBYTECODE=1
NOW=$(date -u +%s)
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

# ── the scratch harness ──────────────────────────────────────────────────────
H="$T/h"; P=project-5; SLUG=example-org/project-5
mkdir -p "$H/state" "$H/logs" "$H/locks" "$H/flags" "$H/env" "$H/builds" "$T/gbin" "$T/fx/issues" "$T/calls"
for s in bin/lib/triage-state.sh bin/triage-gate.sh bin/jobs-client.sh bin/fleet-conf.sh bin/triage-state.py bin/triage-signal.py; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: cannot install the closure of $s"; exit 1; }
done
: > "$H/env/global.env"
mkdir -p "$H/prompts"; echo "SOP. Keys are TK-<issue-number>." > "$H/prompts/$P.md"   # the board label prefix (_ts_prefix)
cat > "$H/bin/run-build.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$T/calls/run-build"
STUB
chmod +x "$H/bin/run-build.sh"

# gh, as gh_rest calls it (the shape tests/triage-state-precheck-test.sh serves)
cat > "$T/gbin/gh" <<STUB
#!/bin/bash
case "\$*" in
  *rate_limit*) echo '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0},"graphql":{"remaining":4000,"limit":5000,"reset":0}}}'; exit 0 ;;
  *repos/$SLUG/pulls*) printf 'HTTP/2 200\r\n\r\n[]\n'; exit 0 ;;
esac
N=\$(printf '%s\n' "\$*" | sed -nE 's#.*repos/$SLUG/issues/([0-9]+).*#\1#p' | head -1)
F="$T/fx/issues/\$N.json"
[ -n "\$N" ] && [ -s "\$F" ] || { printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'; exit 1; }
case "\$*" in
  *issues/\$N/comments*) printf 'HTTP/2 200\r\n\r\n'; jq -c '.comments' "\$F"; exit 0 ;;
  *) printf 'HTTP/2 200\r\n\r\n'; jq -c '.issue' "\$F"; exit 0 ;;
esac
STUB
chmod +x "$T/gbin/gh"

# ── fixtures ─────────────────────────────────────────────────────────────────
iss() { # iss <n> <title>
  jq -n --argjson n "$1" --arg t "$2" --arg at "$(iso $((NOW - 7200)))" \
    '{issue:{number:$n,title:$t,body:"Apply migration 0020",state:"open",labels:[{name:"ai-build"}],assignees:[],milestone:null,
      comments:0,updated_at:$at},comments:[]}' > "$T/fx/issues/$1.json"
}
comment() { # comment <n> <id> <login> <type> <body> <created_at>
  local f="$T/fx/issues/$1.json"
  jq --argjson id "$2" --arg u "$3" --arg ty "$4" --arg b "$5" --arg at "$6" \
    '.comments += [{id:$id,user:{login:$u,type:$ty},body:$b,created_at:$at,updated_at:$at,
       html_url:("https://github.com/x/y/issues/1#issuecomment-" + ($id|tostring))}]
     | .issue.comments = (.comments|length) | .issue.updated_at = $at' "$f" > "$f.t" && mv "$f.t" "$f"
}
world() {
  local rows
  rows=$(for f in "$T/fx/issues/"*.json; do jq -c '.issue | {number, state:(.state|ascii_upcase), title, comments, updatedAt: .updated_at}' "$f"; done | jq -sc 'sort_by(.number)')
  jq -cS -n --argjson i "$rows" '{issues:$i, prs:[], meta:{}}' > "$H/state/$P.gate.pending"
}
DONE_AT=$(iso $((NOW - 1800)))
iss 11 "Apply migration 0020"
comment 11 1101 operator-w User $'HUMAN-STEP-DONE: applied migration 0020 in prod\nSELECT ok' "$DONE_AT"
world
# The build records the ledger feed serves: kind=result rows.
result_feed() { # result_feed <result-line> <updated_at> [<result-line> <updated_at>]...
  local out='[]'
  while [ $# -ge 2 ]; do
    out=$(jq -c --arg r "$1" --arg u "$2" '. + [{job_id:("j-" + $u), artifact_ref:$r, box:"hub", ticket_id:"TK-11", updated_at:$u,
      detail:({build_dir:("project-5-TK-11-" + ($u | gsub("[^0-9]"; ""))), key:"TK-11"} | tojson)}]' <<<"$out")
    shift 2
  done
  jq -c '{artifacts: .}' <<<"$out" > "$T/fx/result.json"
}
echo '[]' > "$T/fx/rows.json"

# ── the worker stub: every jobs-client verb reaches it through _jobs_req ─────
LEDGER_DOWN=0
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$T/calls/jobs"
  case "$1 $2" in
    "GET /api/triage-state?"*) printf '{"triage_state":%s}' "$(cat "$T/fx/rows.json")" ;;
    "PUT /api/triage-state") printf '%s\n' "${3:-}" >> "$T/calls/observe"; printf '{"ok":true}' ;;
    "GET /api/ledger?kind=ticket_stage&"*)
      [ "$LEDGER_DOWN" = 1 ] && return 1
      [ -s "$T/fx/stage.json" ] || return 2
      cat "$T/fx/stage.json" ;;
    "PUT /api/ledger")
      printf '%s\n' "${3:-}" >> "$T/calls/ledger-put"
      [ "$(jq -r .kind <<<"${3:-}")" = ticket_stage ] && jq -c '{ledger:{status, detail}}' <<<"${3:-}" > "$T/fx/stage.json"
      printf '{"ok":true}' ;;
    "GET /api/artifacts?kind=result&"*) cat "$T/fx/result.json" ;;
    "GET /api/artifacts?"*) printf '{"artifacts":[]}' ;;
    *) return 2 ;;
  esac
}
_jobs_req_stub=$(declare -f _jobs_req)

tick_env() {
  export HARNESS="$H" JOBS_HARNESS="$H" HARNESS_ENV_DIR="$H/env" FLEET_CONF="$REPO/fleet.conf" \
         HARNESS_SELF_APPS=cromford PATH="$T/gbin:$PATH" TRIAGE_STATE_MODE=shadow GH_TOKEN=fixture-token \
         LANE_GATE_DISABLE=1
  PROJECT=$P; STAMP="2026-10-13 10:00:00Z"; LOG="$H/logs/$P.log"
  GATE_REASON=board-changed; SCOPE_N=full; TICK_SCOPE=""; BOARD_SEC=""; QLINES=""; QDIRS=""; RDIRS=""; EW_KEYS=""
}
tick_env
# shellcheck source=/dev/null
. "$H/bin/jobs-client.sh"
eval "$_jobs_req_stub"   # jobs-client defined its own: put the stub back
# shellcheck source=/dev/null
. "$H/bin/lib/triage-state.sh"
# shellcheck source=/dev/null
. "$H/bin/lib/needs-human.sh"
DEC="$H/state/triage-state/$P/decisions.tsv"
dec_of() { awk -F'\t' -v k="$1" '$1==k {print $3 " " $4}' "$DEC" 2>/dev/null; }
observed() { jq -r --arg k "$1" '.rows[]? | select(.ticket_key==$k) | .last_decision' "$T/calls/observe" 2>/dev/null | tail -1; }
reset() { : > "$T/calls/jobs"; : > "$T/calls/observe"; : > "$T/calls/ledger-put"; rm -f "$T/fx/stage.json" "$H/state/ticket-stage/$P.tsv"; }
count() { grep -c "$1" "$T/calls/jobs" 2>/dev/null || true; }

# ═══ T1 — a stage row human-step-done: a `candidate` is skipped ═════════════
# A REVIEW_BLOCKED build one hour ago; the stage row is written now by the real
# writer (lane review-rescue), so it is newer than that build.
result_feed "REVIEW_BLOCKED: review BLOCK (migration 0020 not applied in prod)" "$(iso $((NOW - 3600)))"
reset
( ts_precheck ) >/dev/null 2>&1    # learn the input hash
HASH=$(awk -F'\t' '$1=="11" {print $5}' "$DEC")
[[ "$HASH" =~ ^[0-9a-f]{64}$ ]] && ok || bad "(T1) the first pass must hash ticket 11: [$HASH] $(cat "$DEC" 2>/dev/null)"
jq -n --arg h "$HASH" --arg at "$(iso $((NOW - 600)))" \
  '[{project:"project-5",ticket_key:"11",verdict:"buildable",verdict_hash:$h,input_hash:$h,triaged_at:$at,reason:"fixture"}]' > "$T/fx/rows.json"
reset
nh_sd_stage_put "$P" 11 TK-11 human-step-done "fixture: rescue re-review queued" 2>/dev/null
[ -s "$T/fx/stage.json" ] && ok || bad "(T1) the real writer must have stored the stage row"
: > "$T/calls/jobs"; : > "$T/calls/run-build"; : > "$H/logs/$P.log"
ts_precheck >/dev/null 2>&1
[ "$(dec_of 11)" = "skip human-step:human-step-done" ] && ok || bad "(T1) decision: [$(dec_of 11)]"
[ "$(observed 11)" = "skip human-step:human-step-done" ] && ok || bad "(T1) observe last_decision: [$(observed 11)]"
[ -z "$TS_ENQ" ] && case "$TS_LLM" in *TK-11*) false ;; *) true ;; esac && ok || bad "(T1) not enqueued, not to the model: enq=[$TS_ENQ] llm=[$TS_LLM]"
case "$TS_SKIPSET" in *" 11 "*) ok ;; *) bad "(T1) key 11 must be in TS_SKIPSET: [$TS_SKIPSET]" ;; esac
TS_MODE=enforce ts_enqueue >/dev/null 2>&1; sleep 0.3
[ ! -s "$T/calls/run-build" ] && ok || bad "(T1) run-build.sh must not start: $(cat "$T/calls/run-build")"
grep -q "triage-state: TK-11 skip :: human step: human-step-done" "$H/logs/$P.log" && ok || bad "(T1) lane log line: $(grep TK-11 "$H/logs/$P.log")"
[ "$(count 'kind=result&')" = 1 ] && ok || bad "(T1) bor_union reads the result feed once per tick: $(count 'kind=result&')"

# ═══ T2 — no stage row: the done comment is claimed by triage ══════════════
echo '[]' > "$T/fx/rows.json"; reset
ts_precheck >/dev/null 2>&1
[ "$(dec_of 11)" = "skip human-step:done-unclaimed" ] && ok || bad "(T2) decision: [$(dec_of 11)]"
[ "$(observed 11)" = "skip human-step:done-unclaimed" ] && ok || bad "(T2) observe last_decision: [$(observed 11)]"
[ "$(jq -s '[.[] | select(.kind=="ticket_stage")] | length' "$T/calls/ledger-put")" = 1 ] && ok \
  || bad "(T2) exactly one ticket_stage PUT: $(cat "$T/calls/ledger-put")"
PUTD=$(jq -r 'select(.kind=="ticket_stage") | "\(.key)|\(.status)|\(.detail)"' "$T/calls/ledger-put")
case "$PUTD" in "project-5#11|review|human-step-done by triage at "*": @operator-w posted HUMAN-STEP-DONE at $DONE_AT; this box cannot read the review of build project-5-TK-11-"*"; the rescue lane decides from $(iso $((NOW - 3600 + 5400)))") ok ;;
  *) bad "(T2) the stage row: [$PUTD]" ;; esac
[ "$(cut -f1,3 "$H/state/ticket-stage/$P.tsv" 2>/dev/null)" = "TK-11	human-step-done" ] && ok \
  || bad "(T2) the local stage line: $(cat "$H/state/ticket-stage/$P.tsv" 2>/dev/null)"

# ═══ T2b — a local human-step-only review.md: the reason names the check ═══
RB="$H/builds/project-5-TK-11-$(iso $((NOW - 3600)) | tr -dc 0-9)"
mkdir -p "$RB"
printf 'B1 migration 0020 not applied in prod.\n\nNEEDS_HUMAN: apply migration 0020 in prod\nTIER: 2\nVERDICT: BLOCK\n' > "$RB/review.md"
reset
ts_precheck >/dev/null 2>&1
[ "$(dec_of 11)" = "skip human-step:done-unclaimed" ] && ok || bad "(T2b) decision: [$(dec_of 11)]"
PUTD=$(jq -r 'select(.kind=="ticket_stage") | .detail' "$T/calls/ledger-put" 2>/dev/null)
case "$PUTD" in *"; bin/review-rescue.sh checks build ${RB##*/} from $(iso $((NOW - 3600 + 5400)))") ok ;;
  *) bad "(T2b) the stage reason names the rescue lane's check: [$PUTD]" ;; esac

# ═══ T2c — a local code BLOCK review.md: not this flow, the decision stands ═
printf 'B1 migration 0020 not applied in prod.\nB2 the guard returns early on empty input.\n\nNEEDS_HUMAN: apply migration 0020 in prod\nTIER: 2\nVERDICT: BLOCK\n' > "$RB/review.md"
reset
ts_precheck >/dev/null 2>&1
[ "$(dec_of 11)" = "llm new" ] && ok || bad "(T2c) a code BLOCK leaves the decision: [$(dec_of 11)]"
[ ! -s "$T/calls/ledger-put" ] && ok || bad "(T2c) no stage write for a code BLOCK: $(cat "$T/calls/ledger-put")"
scratch_rm "$RB"

# ═══ T4 — the ledger read fails: the decision stands ════════════════════════
reset; LEDGER_DOWN=1
ts_precheck >/dev/null 2>&1
[ "$(dec_of 11)" = "llm new" ] && ok || bad "(T4) a ledger outage leaves the decision: [$(dec_of 11)]"
[ ! -s "$T/calls/ledger-put" ] && ok || bad "(T4) no write on an outage: $(cat "$T/calls/ledger-put")"
LEDGER_DOWN=0

# ═══ T5 — the newest build is PR_CREATED: the decision stands ═══════════════
result_feed "REVIEW_BLOCKED: review BLOCK (migration 0020 not applied in prod)" "$(iso $((NOW - 7000)))" \
            "PR_CREATED https://github.com/example-org/project-5/pull/9" "$(iso $((NOW - 3600)))"
reset
ts_precheck >/dev/null 2>&1
[ "$(dec_of 11)" = "llm new" ] && ok || bad "(T5) a PR_CREATED newest record leaves the decision: [$(dec_of 11)]"
[ ! -s "$T/calls/ledger-put" ] && ok || bad "(T5) no stage write: $(cat "$T/calls/ledger-put")"

# ═══ T6 — the flow ended: a rebuild's newer PLAN_BLOCKED releases the skip ═
result_feed "REVIEW_BLOCKED: review BLOCK (migration 0020 not applied in prod)" "$(iso $((NOW - 7000)))" \
            "PLAN_BLOCKED: the thread has an open question" "$(iso $((NOW - 600)))"
reset
jq -n --arg d "handed-to-resolver by review-rescue at $(iso $((NOW - 3000))): human step done, but no open PR or pushed branch for TK-11" \
  '{ledger:{status:"review", detail:$d}}' > "$T/fx/stage.json"
ts_precheck >/dev/null 2>&1
[ "$(dec_of 11)" = "llm new" ] && ok || bad "(T6) a newer PLAN_BLOCKED record leaves the decision: [$(dec_of 11)]"
[ ! -s "$T/calls/ledger-put" ] && ok || bad "(T6) no stage write: $(cat "$T/calls/ledger-put")"

# ═══ T7 — the record the stage row is about is superseded by the resolver ══
result_feed "REVIEW_BLOCKED: review BLOCK (migration 0020 not applied in prod)" "$(iso $((NOW - 7000)))"
RB="$H/builds/project-5-TK-11-$(iso $((NOW - 7000)) | tr -dc 0-9)"
mkdir -p "$RB"; : > "$RB/.blocked-resolver-superseded"
reset
jq -n --arg d "rereview-gave-up by review-rescue at $(iso $((NOW - 3000))): re-review produced no verdict twice" \
  '{ledger:{status:"review", detail:$d}}' > "$T/fx/stage.json"
ts_precheck >/dev/null 2>&1
[ "$(dec_of 11)" = "llm new" ] && ok || bad "(T7) a superseded record leaves the decision: [$(dec_of 11)]"
[ ! -s "$T/calls/ledger-put" ] && ok || bad "(T7) no stage write: $(cat "$T/calls/ledger-put")"
rm -f "$RB/.blocked-resolver-superseded"
reset
jq -n --arg d "rereview-gave-up by review-rescue at $(iso $((NOW - 3000))): re-review produced no verdict twice" \
  '{ledger:{status:"review", detail:$d}}' > "$T/fx/stage.json"
ts_precheck >/dev/null 2>&1
[ "$(dec_of 11)" = "skip human-step:rereview-gave-up" ] && ok || bad "(T7) without the marker the skip holds: [$(dec_of 11)]"
scratch_rm "$RB"

# ═══ T3 — no done comment: unchanged, and no ledger or artifact read ═══════
result_feed "REVIEW_BLOCKED: review BLOCK (migration 0020 not applied in prod)" "$(iso $((NOW - 3600)))"
iss 11 "Apply migration 0020"
comment 11 1102 operator-w User "I will apply it tomorrow" "$(iso $((NOW - 1200)))"
world; reset
ts_precheck >/dev/null 2>&1
[ "$(dec_of 11)" = "llm new" ] && ok || bad "(T3) no done comment leaves the decision: [$(dec_of 11)]"
[ "$(count '/api/ledger')" = 0 ] && [ "$(count '/api/artifacts')" = 0 ] && ok \
  || bad "(T3) no ledger or artifact request without a done comment: $(grep -E 'ledger|artifacts' "$T/calls/jobs")"

echo "triage-state-human-step: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
