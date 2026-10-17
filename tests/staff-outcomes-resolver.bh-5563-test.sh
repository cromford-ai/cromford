#!/bin/bash
# tests/staff-outcomes-resolver.bh-5563-test.sh — BH-5563 (BH-5556.6): the
# staff outcome resolver, driven through the SHIPPED bin/staff-outcomes.sh.
#
#   R1      flags/staff-off-all exits before any read: no /api/staff call, no
#           GitHub read, the cursor does not move
#   R2-R5   the outcome map: closed completed -> merged; not_planned,
#           duplicate and a null state_reason -> rejected; the staff-noise
#           label (trimmed, any case) -> noise, and it wins over completed;
#           an open issue, even with the label, posts nothing; a near-miss
#           label (staff-noise-candidate, noise) is not noise
#   R6      flags/staff-off-<agent> skips that agent's rows with no GitHub read;
#           the cursor still moves past them
#   R7      an unreadable pending list: exit 0, one log line, the cursor stays
#   R8      a GitHub 502 or 404, and a non-issue URL, post nothing
#   R9      a failed outcome POST is counted failed, never merged; the next run
#           re-posts it
#   R10     STAFF_OUTCOMES_MAX caps the GitHub reads; the cursor is saved at the
#           last id read and drains the list in rotation, back to 0 at the end
#   R11     a 200 existing:true is counted replayed, not merged
#   R12     no model call and no gh CLI: an agent-call and a gh on PATH are
#           never run
#   R13     a new proposal id in the answer is ONE digest line; none is none
#   R14     STAFF_OUTCOMES_ENABLED=0 and a held lock read nothing
#   R15     a 409 (outcome_conflict) is counted conflict and logged
#   C1      bin/staff.sh sends `class` in the claim body (.class, else
#           .source.kind), so a family suppression can match the claim
#
# MUTATIONS (D1), each tried by hand once against bin/staff-outcomes.sh: move
# the kill check after the pending read -> R1 red; map `completed` before the
# label -> R5 red; count a failed POST as its outcome -> R9 red; drop the cap
# check -> R10 red.
#
# The worker and gh_rest are stubs in the STAFF_OUTCOMES_FIXTURE file (sourced
# by bin/staff-outcomes.sh after its libs, sandbox only). flag_active is the
# real one, reading $H/flags. curl, gh and agent-call on PATH log and fail.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/staff-outcomes-resolver.bh-5563-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "staff-outcomes-resolver: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
count() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }

for SRC in "$DIR/bin/staff-outcomes.sh" "$DIR/catalog/lanes.d/staff-outcomes.json" \
           "$DIR/cron/lanes/730-staff-outcomes.cron" "$DIR/worker/jobs/src/routes/staff-outcomes.js" \
           "$DIR/worker/jobs/src/lib/staff-family.js" "$DIR/worker/jobs/test/route-table.d/775-staff-outcomes.txt" \
           "$DIR/worker/jobs/schema.d/202610150612-bh-5563-staff-outcomes.sql"; do
  [ -r "$SRC" ] || bad "missing $SRC"
done
[ -r "$DIR/bin/staff-outcomes.sh" ] || { echo "staff-outcomes-resolver: $PASS passed, $FAIL failed"; exit 1; }

# ═════ the scratch harness ═══════════════════════════════════════════════════
H="$T/h"; FXT="$T/fx"
mkdir -p "$H/env" "$T/fakebin"
for L in bin/staff-outcomes.sh bin/jobs-client.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
mkdir -p "$H/catalog"; cp -r "$DIR/catalog/lanes.d" "$H/catalog/"
: > "$H/env/global.env"
for b in curl gh agent-call agent-call.sh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 99\n' "$b" "$T" > "$T/fakebin/$b"
  chmod +x "$T/fakebin/$b"
done

# The fixture. $FXT/pending.json is the filed list ([{id,agent,fingerprint,
# ticket_url}]); $FXT/issue.<n>.json is issue <n> (absent = 404) and
# $FXT/issue.<n>.status a non-200 status; $FXT/answer.<id> a POST answer.
cat > "$T/fx.sh" <<'SH'
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/jobs.log"
  local after limit
  case "$2" in
    /api/staff/outcomes/pending*)
      [ -f "$FXT/pending.down" ] && return 1
      after=$(sed -n 's/.*[?&]after_id=\([0-9]*\).*/\1/p' <<<"$2"); limit=$(sed -n 's/.*[?&]limit=\([0-9]*\).*/\1/p' <<<"$2")
      jq -c --argjson a "${after:-0}" --argjson l "${limit:-50}" '
        [.[] | select(.id > $a)] as $r
        | {findings: $r[0:$l], truncated: ($r | length > $l), next_after_id: ($r[0:$l] | last | .id? // null)}' "$FXT/pending.json"
      return 0 ;;
  esac
  return 1
}
_jobs_req_file() {
  printf '%s %s %s\n' "$1" "$2" "$(jq -c . "$3")" >> "$FXT/jobs.log"
  local fp
  case "$2" in
    /api/staff/outcomes)
      jq -c . "$3" >> "$FXT/posts.jsonl"
      [ -f "$FXT/post.fail" ] && return 1
      fp=$(jq -r .fingerprint "$3")
      if [ -f "$FXT/answer.$fp" ]; then
        cat "$FXT/answer.$fp"; return "$(cat "$FXT/answer.$fp.rc" 2>/dev/null || echo 0)"
      fi
      jq -c '{ok: true, outcome, proposals: {promotion_id: null, suppression_id: null}}' "$3"; return 0 ;;
  esac
  return 1
}
gh_rest() {
  printf '%s %s\n' "$1" "$2" >> "$FXT/gh.log"
  local n=${2##*/}
  GH_REST_STATUS=$(cat "$FXT/issue.$n.status" 2>/dev/null || echo 200)
  [ "$GH_REST_STATUS" = 200 ] || return 75
  [ -f "$FXT/issue.$n.json" ] || { GH_REST_STATUS=404; return 44; }
  cat "$FXT/issue.$n.json"
}
SH

URL() { printf 'https://github.com/example-org/cromford/issues/%s' "$1"; }
fpof() { printf 'fixture-%s' "$1" | sha256sum | cut -c1-64; }
# row <id> <agent> [url]: one pending row; the issue number is 100+id.
row() { jq -cn --argjson i "$1" --arg a "$2" --arg f "$(fpof "$1")" --arg u "${3:-$(URL $((100 + $1)))}" \
  '{id: $i, agent: $a, fingerprint: $f, ticket_url: $u}'; }
# issue <id> <state> <state_reason|null> [labels...]
issue() {
  local n=$((100 + $1)) st=$2 r=$3; shift 3
  jq -cn --arg s "$st" --arg r "$r" '{number: 1, state: $s, state_reason: (if $r == "null" then null else $r end),
    labels: [$ARGS.positional[] | {name: .}]}' --args "$@" > "$FXT/issue.$n.json"
}
reset() {
  local d
  for d in "$H/state" "$H/logs" "$H/flags" "$H/locks" "$FXT" "$T/net.log"; do scratch_rm "$d" || exit 1; done
  mkdir -p "$FXT" "$H/flags"
  echo '[]' > "$FXT/pending.json"
}
pending() { local r; for r in "$@"; do printf '%s\n' "$r"; done | jq -s . > "$FXT/pending.json"; }
run() { # the shipped entry point, sandboxed
  env HARNESS="$H" FXT="$FXT" STAFF_OUTCOMES_FIXTURE="$T/fx.sh" HARNESS_TEST_SANDBOX=1 \
    LANE_GATE_DISABLE=1 STAFF_OUTCOMES_TIMED=1 JOBS_URL= PATH="$T/fakebin:$PATH" "$@" \
    bash "$H/bin/staff-outcomes.sh" >"$T/out.txt" 2>&1
}
posted() { jq -r --arg f "$(fpof "$1")" 'select(.fingerprint == $f) | .outcome' "$FXT/posts.jsonl" 2>/dev/null | paste -sd, -; }
cursor() { cat "$H/state/staff-outcomes/cursor" 2>/dev/null || echo absent; }
LOGF="$H/logs/staff-outcomes.log"
DIG="$H/logs/staff-digest.log"

# ═════ R1: the kill flag exits before any read ═══════════════════════════════
reset; pending "$(row 1 watchman)"; issue 1 closed completed
mkdir -p "$H/state/staff-outcomes"; echo 5 > "$H/state/staff-outcomes/cursor"
touch "$H/flags/staff-off-all"
run; rc=$?
eq "R1 rc" "$rc" 0
eq "R1 no /api/staff worker call (the flag lookup itself is the only read: $(cat "$FXT/jobs.log" 2>/dev/null | paste -sd, -))" "$(count '/api/staff' "$FXT/jobs.log")" 0
eq "R1 GitHub reads" "$(count . "$FXT/gh.log")" 0
eq "R1 cursor" "$(cursor)" 5
eq "R1 one kill line" "$(count 'killed by staff-off-all' "$LOGF")" 1

# ═════ R2-R5: the outcome map ════════════════════════════════════════════════
reset
pending "$(row 1 watchman)" "$(row 2 watchman)" "$(row 3 watchman)" "$(row 4 watchman)" "$(row 5 watchman)" \
  "$(row 6 watchman)" "$(row 7 watchman)" "$(row 8 watchman)" "$(row 9 watchman)" "$(row 10 watchman)"
issue 1 closed completed
issue 2 closed not_planned
issue 3 closed duplicate
issue 4 closed null
issue 5 closed completed bug staff-noise
issue 6 closed not_planned " Staff-Noise "
issue 7 open null staff-noise
issue 8 closed completed staff-noise-candidate noise
issue 9 open null
issue 10 closed reopened
run; rc=$?
eq "R2 rc" "$rc" 0
eq "R2 completed -> merged" "$(posted 1)" merged
eq "R3 not_planned -> rejected" "$(posted 2)" rejected
eq "R3 duplicate -> rejected" "$(posted 3)" rejected
eq "R4 null state_reason -> rejected" "$(posted 4)" rejected
eq "R4 any other state_reason -> rejected" "$(posted 10)" rejected
eq "R5 the label wins over completed" "$(posted 5)" noise
eq "R5 the label is trimmed and lowercased" "$(posted 6)" noise
eq "R5 an open issue with the label posts nothing" "$(posted 7)" ""
eq "R5 a near-miss label is not noise" "$(posted 8)" merged
eq "R5 an open issue posts nothing" "$(posted 9)" ""
eq "R5 the body carries the row" "$(jq -c --arg f "$(fpof 1)" 'select(.fingerprint == $f) | [.agent, .ticket_url]' "$FXT/posts.jsonl")" \
  "[\"watchman\",\"$(URL 101)\"]"
grep -qE '^[0-9TZ:-]+ read=10 merged=2 rejected=4 noise=2 unresolved=2 skipped=0 replayed=0 failed=0 conflict=0 cursor=0$' "$LOGF" \
  && ok || bad "R2 summary line: $(cat "$LOGF" 2>/dev/null)"
eq "R2 the list ended: cursor 0" "$(cursor)" 0

# ═════ R6: a per-agent kill flag skips its rows, the cursor moves past ═══════
reset; pending "$(row 1 inspector)" "$(row 2 watchman)"; issue 1 closed completed; issue 2 closed completed
touch "$H/flags/staff-off-inspector"
run STAFF_OUTCOMES_MAX=1; rc=$?
eq "R6 rc" "$rc" 0
eq "R6 inspector posts nothing" "$(posted 1)" ""
eq "R6 no GitHub read for inspector" "$(count "issues/101" "$FXT/gh.log")" 0
eq "R6 watchman still resolves" "$(posted 2)" merged
eq "R6 cursor at the last id read" "$(cursor)" 2

# ═════ R7: an unreadable pending list ════════════════════════════════════════
reset; mkdir -p "$H/state/staff-outcomes"; echo 3 > "$H/state/staff-outcomes/cursor"; touch "$FXT/pending.down"
run; rc=$?
eq "R7 rc" "$rc" 0
eq "R7 cursor unchanged" "$(cursor)" 3
eq "R7 one log line" "$(count 'pending list unreadable' "$LOGF")" 1
eq "R7 no GitHub read" "$(count . "$FXT/gh.log")" 0

# ═════ R8: GitHub 502, 404 and a non-issue URL post nothing ══════════════════
reset
pending "$(row 1 watchman)" "$(row 2 watchman)" "$(row 3 watchman https://github.com/example-org/cromford/pull/7)"
issue 1 closed completed; echo 502 > "$FXT/issue.101.status"
run; rc=$?
eq "R8 rc" "$rc" 0
eq "R8 nothing posted" "$(count . "$FXT/posts.jsonl")" 0
eq "R8 no GitHub read for a pull URL" "$(count 'pull' "$FXT/gh.log")" 0
eq "R8 two reads" "$(count . "$FXT/gh.log")" 2
grep -q 'read=2 merged=0 rejected=0 noise=0 unresolved=2 skipped=1 ' "$LOGF" && ok || bad "R8 summary: $(cat "$LOGF")"

# ═════ R9: a failed POST is failed, and the next run re-posts it ════════════
reset; pending "$(row 1 watchman)"; issue 1 closed completed; touch "$FXT/post.fail"
run
grep -q 'merged=0 .*failed=1 ' "$LOGF" && ok || bad "R9 a failed POST counted as merged: $(cat "$LOGF")"
rm -f "$FXT/post.fail"
run
eq "R9 re-posted" "$(posted 1)" "merged,merged"
grep -q 'merged=1 .*failed=0 ' "$LOGF" && ok || bad "R9 second run: $(cat "$LOGF")"

# ═════ R10: the cap and the rotating cursor ══════════════════════════════════
reset
pending "$(row 1 watchman)" "$(row 2 watchman)" "$(row 3 watchman)" "$(row 4 watchman)" "$(row 5 watchman)"
for i in 1 2 3 4 5; do issue "$i" open null; done
run STAFF_OUTCOMES_MAX=2
eq "R10 run 1 reads 2" "$(count . "$FXT/gh.log")" 2
eq "R10 run 1 cursor" "$(cursor)" 2
run STAFF_OUTCOMES_MAX=2
eq "R10 run 2 reads 101..105 in order" "$(sed 's#.*/##' "$FXT/gh.log" | paste -sd, -)" "101,102,103,104"
eq "R10 run 2 cursor" "$(cursor)" 4
run STAFF_OUTCOMES_MAX=2
eq "R10 run 3 reads the last row" "$(sed 's#.*/##' "$FXT/gh.log" | tail -1)" 105
eq "R10 run 3 the end: cursor 0" "$(cursor)" 0
run STAFF_OUTCOMES_MAX=2
eq "R10 run 4 starts again at the head" "$(sed 's#.*/##' "$FXT/gh.log" | tail -2 | paste -sd, -)" "101,102"
run STAFF_OUTCOMES_MAX=0
grep -q 'warn: STAFF_OUTCOMES_MAX=0 is outside 1..500' "$LOGF" && ok || bad "R10 an out-of-range cap is a warn line"

# ═════ R11: a replay is counted replayed ════════════════════════════════════
reset; pending "$(row 1 watchman)"; issue 1 closed completed
echo '{"ok":true,"existing":true,"outcome":"merged"}' > "$FXT/answer.$(fpof 1)"
run
grep -q 'merged=0 .*replayed=1 ' "$LOGF" && ok || bad "R11 summary: $(cat "$LOGF")"

# ═════ R12: no model, no gh CLI, no curl ═════════════════════════════════════
eq "R12 nothing on PATH ran" "$(count . "$T/net.log")" 0

# ═════ R13: a new proposal id is one digest line ═════════════════════════════
reset; pending "$(row 1 watchman)" "$(row 2 watchman)"; issue 1 closed completed; issue 2 closed completed staff-noise
echo '{"ok":true,"outcome":"merged","class":"leak","proposals":{"promotion_id":7,"promotion_to":"augmentation","suppression_id":null}}' > "$FXT/answer.$(fpof 1)"
echo '{"ok":true,"outcome":"noise","class":"cost-row","proposals":{"promotion_id":null,"suppression_id":9}}' > "$FXT/answer.$(fpof 2)"
run
eq "R13 two digest lines" "$(count . "$DIG")" 2
grep -qE '^[0-9TZ:-]+ proposal promotion id=7 agent=watchman to=augmentation fp=[0-9a-f]{12}$' "$DIG" && ok || bad "R13 promotion line: $(cat "$DIG")"
grep -qE '^[0-9TZ:-]+ proposal suppression id=9 agent=watchman class=cost-row fp=[0-9a-f]{12}$' "$DIG" && ok || bad "R13 suppression line: $(cat "$DIG")"
reset; pending "$(row 1 watchman)"; issue 1 closed completed
run
eq "R13 no proposal, no digest line" "$(count . "$DIG")" 0

# ═════ R14: off and locked ═══════════════════════════════════════════════════
reset; pending "$(row 1 watchman)"; issue 1 closed completed
run STAFF_OUTCOMES_ENABLED=0
eq "R14 ENABLED=0 reads nothing" "$(count . "$FXT/gh.log")" 0
mkdir -p "$H/locks"
( exec 8>"$H/locks/staff-outcomes.lock"; flock -n 8; touch "$T/held"; sleep 5 ) &
LP=$!
for _ in $(seq 1 50); do [ -f "$T/held" ] && break; sleep 0.1; done
run; rc=$?
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
eq "R14 held lock rc" "$rc" 0
eq "R14 held lock reads nothing" "$(count . "$FXT/gh.log")" 0

# ═════ R15: a 409 is a conflict, logged ══════════════════════════════════════
reset; pending "$(row 1 watchman)"; issue 1 closed not_planned
echo '{"error":"outcome_conflict","outcome":"merged"}' > "$FXT/answer.$(fpof 1)"; echo 9 > "$FXT/answer.$(fpof 1).rc"
run
grep -q 'rejected=0 .*conflict=1 ' "$LOGF" && ok || bad "R15 summary: $(cat "$LOGF")"
grep -q 'outcome_conflict' "$LOGF" && ok || bad "R15 the 409 body is logged"

# ═════ C1: bin/staff.sh sends the class in the claim body ═══════════════════
C="$T/c"; CFX="$T/cfx"
mkdir -p "$C/prompts" "$C/env" "$C/catalog" "$CFX"
cp -rs "$DIR/bin" "$C/bin"
cp -rs "$DIR/agent-core" "$C/agent-core"
cp -r "$DIR/catalog/lanes.d" "$C/catalog/"
cp -r "$DIR/prompts/staff" "$C/prompts/"
: > "$C/env/global.env"
mkdir -p "$C/bin/staff"
# A symlink into the checkout once the real collector exists (BH-5565): remove it first.
rm -f "$C/bin/staff/watchman-collect.sh"
printf '#!/bin/bash\ncat "%s/items.jsonl"\n' "$CFX" > "$C/bin/staff/watchman-collect.sh"; chmod +x "$C/bin/staff/watchman-collect.sh"
{ jq -cn '{item: {id: "c1"}, title: "Fixture c1", class: "Cost Row", source: {kind: "fixture", url: "https://example.com/fx/c1", labels: []}, observedAt: "2026-10-14T00:00:00Z"}'
  jq -cn '{item: {id: "c2"}, title: "Fixture c2", source: {kind: "spend-alert", url: "https://example.com/fx/c2", labels: []}, observedAt: "2026-10-14T00:00:00Z"}'
} > "$CFX/items.jsonl"
cat > "$T/cfx.sh" <<'SH'
_jobs_req() {
  case "$1 $2" in
    "GET /api/staff/agent?name="*) printf '{"agent":{"name":"watchman","autonomy":"automation","cap":"augmentation","status":"active","soul":"prompts/staff/watchman-soul.md","lanes":[]}}'; return 0 ;;
  esac
  return 1
}
_jobs_req_file() {
  jq -c . "$3" >> "$CFX/claims.jsonl"
  printf '{"claimed":false,"error":"suppressed","fingerprint":"%s"}' "$(printf x | sha256sum | cut -c1-64)"; return 9
}
SH
env HARNESS="$C" CFX="$CFX" STAFF_FIXTURE="$T/cfx.sh" HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 STAFF_TIMED=1 \
  JOBS_URL= PATH="$T/fakebin:$PATH" bash "$C/bin/staff.sh" tick watchman >"$T/c-out.txt" 2>&1
eq "C1 the claim class is the item's class" "$(jq -r 'select(.item.id == "c1") | .class' "$CFX/claims.jsonl" 2>/dev/null)" "Cost Row"
eq "C1 no class: the claim class is source.kind" "$(jq -r 'select(.item.id == "c2") | .class' "$CFX/claims.jsonl" 2>/dev/null)" "spend-alert"

echo "staff-outcomes-resolver: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
