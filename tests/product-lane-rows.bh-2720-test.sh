#!/bin/bash
# tests/product-lane-rows.bh-2720-test.sh — BH-2720 (BH-2531.3): the two product
# lanes restore the proposal ledger from harness-jobs rows before they decide
# anything, and write each ledger change through to its row.
#
#   R1-R3  the real bin/run-product.sh on a wiped ledger: rows restored before
#          SELECT, candidate and gate_pending rows written
#   C1-C3c the real bin/product-cmd.sh on a wiped ledger: kill / chat / revise
#   N1     fail-open: JOBS_URL empty, or a 503 worker, behaves as today
#
# The worker is a stub `curl` first on PATH. JOBS_URL=http://jobs.test answers
# /api/product-proposals from files under $T/db (one JSON row per
# <project>--<slug>), 404 {"error":"proposal not found"} for a missing one, and
# 503 while $T/db-down exists (and to a gate_pending PUT while
# $T/refuse-gate-pending exists). Every call is logged to $T/jobs.log.
# post-proposal is a stub that logs its slug (the real one hard-codes
# /root/harness until BH-2719). Every assertion is on an artifact: selected.json,
# the ledger file, the rows, draft.log, post.log, ALERTS.log, jobs.log.
#
# Run from anywhere: tests/product-lane-rows.bh-2720-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }
# The worker is ONLY the stub below: a box that exports the fleet's secret or
# URL must not have this suite talking to the live harness-jobs.
unset HARNESS_SECRET JOBS_URL JOBS_BOX JOBS_ALERT

P=proj-rows
H="$T/h"; DB="$T/db"
LEDGER="$H/state/product-$P.ledger.json"
ALERTS="$H/logs/ALERTS.log"
mkdir -p "$H/bin/lib/jobs" "$H/env" "$H/state" "$H/logs" "$H/flags" "$H/prompts/product-stages" "$T/stub" "$DB"

# ── the scratch harness: the real sources under test, stubs for the rest ────
cp "$DIR/bin/jobs-client.sh" "$H/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/"
cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/proposal-rows.sh" "$H/bin/lib/"
cp "$DIR/bin/run-product.sh" "$DIR/bin/product-cmd.sh" "$H/bin/"

global_env() { printf 'HARNESS_SECRET=test-secret\nJOBS_URL=%s\nJOBS_RETRIES=0\n' "$1" > "$H/env/global.env"; }
global_env http://jobs.test

for s in beat.sh mockup-shot.sh push-proposal-assets.sh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/calls.log"\nexit 0\n' "$s" "$T" > "$H/bin/$s"
done
printf 'lane_model() { echo stub-model; }\n' > "$H/bin/lib/lane-model.sh"
cat > "$H/bin/draft-proposal.sh" <<EOF
#!/bin/bash
echo "draft \$2" >> "$T/draft.log"
printf 'prd' > "\$2/prd.md"; printf '<p>x</p>{{MOCKUP_BLOCK}}' > "\$2/ticket.html"; printf '<html/>' > "\$2/mockup.html"
exit 0
EOF
cat > "$H/bin/post-proposal.sh" <<EOF
#!/bin/bash
echo "\$2" >> "$T/post.log"
exit 0
EOF
# agent-call <stage> <project> <model> <timeout> <outfile> <prompt>
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
stage=\$1; out=\$5; prompt=\$6
field() { printf '%s\n' "\$prompt" | sed -n "s/^\$1=\([^ ]*\).*/\1/p" | head -1; }
case "\$stage" in
  signals) printf '{"signals":[{"s":1}]}' > "\$(field SIGNALS_OUT)" ;;
  ideate)  cp "$T/ideas.json" "\$(field IDEAS_OUT)" ;;
  chat)    printf 'a reply' > "\$(field REPLY_OUT)"; cat "$T/chat-out.txt" > "\$out" ;;
  revise)  echo REVISE_DONE > "\$out" ;;
esac
exit 0
EOF
chmod +x "$H"/bin/*.sh
echo 'stage' > "$H/prompts/product-stages/chat.md"
for s in map signals ideate-dept synth; do echo "$s" > "$H/prompts/product-stages/$s.md"; done
echo 'ctx' > "$H/prompts/product-$P.md"

# git: run-product pulls /root/repos/<p> when it is on main — never here.
printf '#!/bin/bash\nexit 0\n' > "$T/stub/git"
# curl: the jobs worker (lifted from tests/product-proposal-rows.bh-2531-test.sh
# at 8ca488f, board half dropped: this lane never calls a board).
cat > "$T/stub/curl" <<'CURL'
#!/bin/bash
M=GET; D=""; W=0; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) M=$2; shift ;;
    -d|--data-binary) D=$2; shift ;;
    -w) W=1; shift ;;
    -H|-m|--max-time|--connect-timeout) shift ;;
    -*) ;;
    *) URL=$1 ;;
  esac
  shift
done
case "$D" in @*) D=$(cat "${D#@}") ;; esac
case "$URL" in
  http://jobs.test/*)
    echo "$M $URL" >> "$STUB_T/jobs.log"
    ans() { printf '%s' "$2"; [ "$W" = 1 ] && printf '\n%s' "$1"; exit 0; }
    [ -e "$STUB_T/db-down" ] && ans 503 '{"error":"product_proposals unavailable"}'
    path=${URL#http://jobs.test}; q=${path#*\?}; path=${path%%\?*}
    [ "$path" = /api/product-proposals ] || ans 404 '{"error":"unknown endpoint","worker":"harness-jobs"}'
    qp() { printf '%s' "$q" | tr '&' '\n' | sed -n "s/^$1=//p" | head -1; }
    if [ "$M" = PUT ]; then
      p=$(jq -r .project <<<"$D"); s=$(jq -r .proposal_id <<<"$D")
      [ -e "$STUB_T/refuse-gate-pending" ] && [ "$(jq -r .status <<<"$D")" = gate_pending ] && ans 503 '{"error":"refused"}'
      grep -Eq '^[A-Za-z0-9._-]{1,128}$' <<<"$s" || ans 400 '{"error":"proposal_id"}'
      f="$STUB_T/db/$p--$s.json"; now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      if [ "$(jq -r '.if_absent // false' <<<"$D")" = true ]; then
        [ -f "$f" ] && ans 200 "$(jq -c '{proposal: ., inserted: false}' "$f")"
      fi
      created=$(jq -r '.created_at // empty' "$f" 2>/dev/null); created=${created:-$now}
      jq -c --arg c "$created" --arg u "$now" '{project, proposal_id, status, record: (.record | if type=="string" then fromjson else . end), actor, created_at: $c, updated_at: $u}' <<<"$D" > "$f"
      ans 200 "$(jq -c '{proposal: .}' "$f")"
    fi
    p=$(qp project); s=$(qp proposal_id)
    if [ -n "$s" ]; then
      [ -f "$STUB_T/db/$p--$s.json" ] || ans 404 '{"error":"proposal not found"}'
      ans 200 "$(jq -c '{proposal: .}' "$STUB_T/db/$p--$s.json")"
    fi
    ans 200 "$(cat /dev/null "$STUB_T"/db/"$p"--*.json 2>/dev/null | jq -sc '{proposals: ., truncated: false, as_of: "t"}')"
    ;;
esac
exit 7
CURL
chmod +x "$T/stub/git" "$T/stub/curl"
export STUB_T="$T"
RUNPATH="$T/stub:$PATH"

# ── fixtures ────────────────────────────────────────────────────────────────
# idir <slug> — an idea dir with a drafted prd.
idir() { local d="$T/ideas/$1"; mkdir -p "$d"; printf 'prd' > "$d/prd.md"; printf '{}' > "$d/idea.json"; echo "$d"; }
# entry <slug> <status> [dir] — one ledger record.
entry() { jq -nc --arg s "$1" --arg st "$2" --arg d "${3:-$(idir "$1")}" \
  '{slug:$s,title:("T "+$s),impact:5,confidence:5,effort:1,status:$st,rev:1,dir:$d,created_at:"2026-09-20T00:00:00Z",updated_at:"2026-09-20T00:00:00Z"}'; }
# putrow <slug> <status> [dir] — a row, written straight to the stub DB.
putrow() { local r; r=$(entry "$1" "$2" "${3:-}"); jq -nc --arg p "$P" --arg s "$1" --arg st "$2" --argjson r "$r" \
  '{project:$p,proposal_id:$s,status:$st,record:$r,actor:"x",created_at:"2026-09-20T00:00:00Z",updated_at:"2026-09-20T00:00:00Z"}' > "$DB/$P--$1.json"; }
rowst() { jq -r .status "$DB/$P--$1.json" 2>/dev/null; }
fst() { jq -r --arg s "$1" '[.[] | select(.slug == $s)] | last | .status // empty' "$LEDGER" 2>/dev/null; }
reset() {
  local f; for f in "$DB" "$T/db-down" "$T/refuse-gate-pending" "$T/jobs.log" "$T/draft.log" "$T/post.log" "$LEDGER" "$H/state/product-$P.chats" "$H/flags/product-autonomy-$P"; do scratch_rm "$f"; done
  scratch_rm "$H/products"; mkdir -p "$DB"; : > "$ALERTS"; global_env http://jobs.test
}

idea() { jq -nc --arg s "$1" --argjson i "$2" '{slug:$s,title:("T "+$s),summary:"s",dus:"derisk",impact:$i,confidence:10,effort:1}'; }
jq -n --argjson a "$(idea X 10)" --argjson b "$(idea Y 10)" --argjson c "$(idea Z 10)" --argjson d "$(idea W 0.1)" \
  '{ideas:[$a,$b,$c,$d]}' > "$T/ideas.json"
printf -- '---\ndepartments: [ops]\n---\n' > "$H/state/$P.company-map.md"
cycle() { echo "$H/products/$P/$(date -u +%Y-%m-%d)"; }
# run-product must honour an inherited HARNESS before this suite executes it:
# a copy that pins /root/harness would read and write the live harness.
RP_SAFE=0
grep -q '^HARNESS="${HARNESS:-/root/harness}"$' "$H/bin/run-product.sh" && RP_SAFE=1
runp() {
  [ "$RP_SAFE" = 1 ] || { echo "run-product.sh pins HARNESS=/root/harness; not executed" > "$T/out.txt"; return 99; }
  HARNESS="$H" PATH="$RUNPATH" bash "$H/bin/run-product.sh" "$P" > "$T/out.txt" 2>&1
}
cmd() { HARNESS="$H" PATH="$RUNPATH" bash "$H/bin/product-cmd.sh" "$@" > "$T/out.txt" 2>&1; }

# ════════════════════════════════════════════════════════════════════════════
# R1-R3 — bin/run-product.sh on a wiped ledger
# ════════════════════════════════════════════════════════════════════════════
reset; putrow X posted; putrow Y vetoed
runp; RC=$?
[ "$RC" = 0 ] && ok || bad "R1: run-product exits 0 (rc=$RC): $(cat "$T/out.txt") $(tail -3 "$ALERTS")"
[ "$(jq -c '[.selected[].slug]' "$(cycle)/selected.json" 2>/dev/null)" = '["Z"]' ] && ok \
  || bad "R1: only Z is selected on a wiped ledger (got $(jq -c '[.selected[].slug]' "$(cycle)/selected.json" 2>/dev/null))"
[ "$(fst X)/$(fst Y)" = posted/vetoed ] && ok || bad "R1: the ledger is restored with X/Y (got $(fst X)/$(fst Y))"
# R3 — the same run wrote its rows through.
[ "$(rowst Z)" = gate_pending ] && ok || bad "R3: Z's row is gate_pending (got $(rowst Z))"
[ "$(rowst W)" = candidate ] && ok || bad "R3: the unselected W has a candidate row (got $(rowst W))"
[ "$(rowst X)/$(rowst Y)" = posted/vetoed ] && ok || bad "R3: X/Y rows are untouched (got $(rowst X)/$(rowst Y))"

reset; putrow X posted; putrow Y vetoed; : > "$H/flags/product-autonomy-$P"
runp; RC=$?
[ "$RC" = 0 ] && ok || bad "R2: run-product with autonomy exits 0 (rc=$RC): $(cat "$T/out.txt")"
[ "$(cat "$T/draft.log" 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && grep -q '/Z$' "$T/draft.log" && ok \
  || bad "R2: draft-proposal runs once, for Z only: $(cat "$T/draft.log" 2>/dev/null)"
[ "$(cat "$T/post.log" 2>/dev/null)" = Z ] && ok || bad "R2: post-proposal runs once, for Z only: $(cat "$T/post.log" 2>/dev/null)"

# ════════════════════════════════════════════════════════════════════════════
# C1-C3c — bin/product-cmd.sh on a wiped ledger
# ════════════════════════════════════════════════════════════════════════════
reset; putrow X gate_pending
cmd "$P" kill_proposal X; RC=$?
[ "$RC" = 0 ] && ok || bad "C1: kill on a wiped ledger exits 0 (rc=$RC): $(cat "$ALERTS")"
grep -q 'no ledger' "$ALERTS" && bad "C1: kill on a wiped ledger alerts 'no ledger': $(cat "$ALERTS")" || ok
[ "$(rowst X)" = vetoed ] && ok || bad "C1: the row is vetoed (got $(rowst X))"

reset; putrow X gate_pending
echo 'IDEA_UPDATE: {"title":"New title"}' > "$T/chat-out.txt"
cmd "$P" chat_proposal X "$(printf '{"message":"hi"}' | base64 -w0)"; RC=$?
[ "$RC" = 0 ] && ok || bad "C2: chat on a wiped ledger exits 0 (rc=$RC): $(cat "$T/out.txt") $(cat "$ALERTS")"
[ "$(jq -r .record.title "$DB/$P--X.json" 2>/dev/null)" = "New title" ] && ok || bad "C2: the IDEA_UPDATE reaches the row: $(cat "$DB/$P--X.json")"

reset; putrow X gate_pending
cmd "$P" revise_proposal X "$(printf 'make it blue' | base64 -w0)"; RC=$?
[ "$RC" = 0 ] && ok || bad "C3: revise on a wiped ledger exits 0 (rc=$RC): $(cat "$T/out.txt") $(cat "$ALERTS")"
[ "$(rowst X)" = gate_pending ] && [ "$(jq -r .record.rev "$DB/$P--X.json" 2>/dev/null)" = 2 ] && ok \
  || bad "C3: the row is gate_pending at rev 2: $(cat "$DB/$P--X.json")"

# C3b — a candidate (cycle dir, no prd.md) takes the fresh-draft branch.
reset; mkdir -p "$T/cyc"; putrow V candidate "$T/cyc"
cmd "$P" revise_proposal V; RC=$?
[ "$RC" = 0 ] && ok || bad "C3b: revise of a candidate exits 0 (rc=$RC): $(cat "$T/out.txt") $(cat "$ALERTS")"
[ "$(jq -r .record.dir "$DB/$P--V.json" 2>/dev/null)" = "$T/cyc/V" ] && ok \
  || bad "C3b: the row's record.dir is the fresh draft dir: $(cat "$DB/$P--V.json")"
# C3c — the .dir put lands on its own: with the later gate_pending put refused,
# the row still carries the fresh draft dir (and stays a candidate).
reset; mkdir -p "$T/cyc"; putrow V candidate "$T/cyc"; : > "$T/refuse-gate-pending"
cmd "$P" revise_proposal V; RC=$?
[ "$RC" = 0 ] && ok || bad "C3c: revise with the gate_pending put refused still exits 0 (rc=$RC): $(cat "$ALERTS")"
[ "$(rowst V)/$(jq -r .record.dir "$DB/$P--V.json" 2>/dev/null)" = "candidate/$T/cyc/V" ] && ok \
  || bad "C3c: the fresh-draft .dir write reaches the row before the gate_pending one: $(cat "$DB/$P--V.json")"

# ════════════════════════════════════════════════════════════════════════════
# N1 — fail-open: no worker, or a worker that does not answer, is today
# ════════════════════════════════════════════════════════════════════════════
reset; global_env ""
runp; RC=$?
[ "$RC" = 0 ] && ok || bad "N1: run-product with JOBS_URL empty exits 0 (rc=$RC): $(cat "$T/out.txt")"
[ "$(jq -c '[.[] | .slug + "=" + .status] | sort' "$LEDGER" 2>/dev/null)" = '["W=candidate","X=gate_pending","Y=gate_pending","Z=gate_pending"]' ] && ok \
  || bad "N1: the ledger is created and filled as today: $(cat "$LEDGER" 2>/dev/null)"
[ ! -s "$T/jobs.log" ] && ok || bad "N1: JOBS_URL empty makes zero jobs calls: $(cat "$T/jobs.log")"

reset; : > "$T/db-down"; entry X gate_pending | jq -s . > "$LEDGER"
cmd "$P" kill_proposal X; RC=$?
[ "$RC" = 0 ] && ok || bad "N1: kill with a 503 worker exits 0 (rc=$RC): $(cat "$ALERTS")"
[ "$(fst X)" = vetoed ] && ok || bad "N1: kill with a 503 worker still vetoes X in the file (got $(fst X))"

echo "product-lane-rows: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
