#!/bin/bash
# tests/ticket-edges.bh-6977-test.sh — BH-6977 (BH-6547.1): ticket edges and
# HOLD/RESUME comments are rows. bin/lib/ticket-edges.sh and its callers
# (bin/run-preplan.sh, bin/run-decompose.sh, bin/dep-verify.sh and the wake
# class bin/lib/wake-class-ticket-holds.sh), driven over real curl against the
# REAL jobs worker (tests/lib/ticket-edges.bh-6977.mjs) on node:sqlite with the
# composed schema. Every assertion reads rows back through /__rows.
#
#   P1-P7  te_edges_from_text decision table
#   H1-H6  te_holds_from_comments: what is a hold row and what is not
#   E1     the run-preplan block: two Blocked-by lines -> two hard planner rows
#   E1b    plan.md is byte-identical after the block
#   E4     te_put_edges twice with the same plan -> one row
#   K1     flags/ticket-edges-off -> the block sends no POST
#   F2     the worker answers 503 -> block rc 0, no stdout, one http=503 line
#   E2     the real dep-verify SOFT -> the row is soft, dep-verify, verified_at set
#   E2b    a HARD verdict -> the row is hard; a cached verdict sends nothing
#   E2c    DEP_VERIFY_DRY_RUN=1 -> no POST
#   F4     the worker port closed -> the preplan block writes no ALERTS line
#   F1/N1  the worker port closed -> dep-verify prints the same line, rc 0,
#          and no ALERTS line names a ticket-edges request
#   E3     the wake class: HOLD -> one hold row; RESUME -> two rows; a re-read
#          of the same thread -> still two rows
#   H8     a PR comment wake and a non-numeric key read no thread
#   H9     an issues.labeled wake (the minute's first event) whose thread
#          holds a HOLD -> the thread is read and one hold row is written
#   F3     the thread read fails rc 75 -> no row, one ticket-holds.log line
#   H7     3 issue wakes with ticket_holds.wake_reads_max=2 -> 2 reads, one
#          cap line naming 1 left; =0 -> no read
#   E5     the run-decompose block: a child written by fc_child_footer ->
#          one decompose row 41->42 with planned_files from its Owns: line
#   E5b    the child body is byte-identical after the block
#   E6     the same block with DRY=1, or on the board lane -> no POST
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/ticket-edges.bh-6977-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SRV="$DIR/tests/lib/ticket-edges.bh-6977.mjs"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  || { echo "SKIP: node, jq or curl missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/state" "$H/env" "$H/flags" "$H/plans" "$H/prompts"
for L in bin/jobs-client.sh bin/lib/ticket-edges.sh bin/dep-verify.sh bin/fleet-conf.sh \
         bin/lib/wake-class-ticket-holds.sh bin/lib/file-children.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
export HARNESS="$H" FLEET_CONF="$H/fleet.conf"
export HARNESS_SECRET=fixture-harness-secret
# JOBS_ALERT is left unset on purpose: F1 checks an outage pages nothing.
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0

: > "$T/srv.log"; : > "$T/srv.port"
node "$SRV" "$T/srv.log" > "$T/srv.port" 2> "$T/srv.err" &
SPID=$!
for _ in $(seq 1 200); do [ -s "$T/srv.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/srv.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: worker did not start: $(cat "$T/srv.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"
trap 'kill "$SPID" 2>/dev/null' EXIT

rows() { curl -sS "$JOBS_URL/__rows?table=$1"; }
nrows() { rows "$1" | jq 'length'; }
edge() { rows ticket_edges | jq -c --arg p "$1" --arg c "$2" '[.[] | select(.parent == $p and .child == $c)] | first // null'; }
posts() { grep -c "^POST /api/ticket-$1 " "$T/srv.log"; }
setting() { curl -sS -X PUT -d "$(jq -nc --arg k "$1" --arg v "$2" '{key:$k,value:$v}')" "$JOBS_URL/__setting" > /dev/null; }
answer() { curl -sS -X PUT -d "$1" "$JOBS_URL/__answer" > /dev/null; }
reset() { curl -sS -X POST "$JOBS_URL/__drop" > /dev/null; }  # only used last
LIB=". '$H/bin/lib/ticket-edges.sh'"

# ============================================================================
echo "P: te_edges_from_text"
ef() { printf '%s\n' "$1" > "$T/p.md"; ( eval "$LIB"; te_edges_from_text "$T/p.md" "${2:-20}" ) | tr '\t' ':' | paste -sd' ' -; }
[ "$(ef $'Blocked-by: #12, #13\n## Dependencies\nDEPENDS: #12 soft — no shared code')" = "12:soft 13:hard" ] \
  && ok "P1 DEPENDS soft beats a plain Blocked-by; the other stays hard" || bad "P1: $(ef $'Blocked-by: #12, #13\nDEPENDS: #12 soft — x')"
[ "$(ef 'Blocked-by: #14 (hard)')" = "14:hard" ] && ok "P2 (hard) -> hard" || bad "P2: $(ef 'Blocked-by: #14 (hard)')"
[ "$(ef 'Needs: #15 for the route')" = "15:hard" ] && ok "P3 Needs: -> hard" || bad "P3: $(ef 'Needs: #15 for the route')"
[ "$(ef $'Blocked-by: #3, #4, #5\nDEPENDS: #4 hard - imports x')" = "3:hard 4:hard 5:hard" ] \
  && ok "P4 a comma list -> one edge each" || bad "P4: $(ef 'Blocked-by: #3, #4, #5')"
[ "$(ef $'Blocked-by: #20, #21' 20)" = "21:hard" ] && ok "P5 a self edge is dropped" || bad "P5: $(ef 'Blocked-by: #20, #21' 20)"
[ -z "$(ef $'Part of #6547\nOrder: 1 of 4\nsee #6537 for the incident\n- A plan with `Blocked-by: #99` text')" ] \
  && ok "P6 Part of, Order, see #N and a quoted Blocked-by make no edge" || bad "P6: $(ef $'Part of #6547\nsee #6537')"
[ -z "$(ef $'## Scope\nNothing blocks this.')" ] && ok "P7 no blocker lines -> no output" || bad "P7: $(ef 'x')"
[ "$(ef 'DEPENDS: #16 soft — a sibling')" = "16:soft" ] && ok "P8 a DEPENDS line alone names its blocker" || bad "P8: $(ef 'DEPENDS: #16 soft — a sibling')"

# ============================================================================
echo "H: te_holds_from_comments"
cm() { # cm <type> <login> <body> -> a one-comment REST thread
  jq -nc --arg t "$1" --arg l "$2" --arg b "$3" '[{id:7001,body:$b,created_at:"2026-10-15T10:00:00Z",user:{login:$l,type:$t}}]'; }
hf() { ( eval "$LIB"; te_holds_from_comments ) <<<"$1"; }
[ "$(hf "$(cm User operator-fixture 'HOLD: wait for the vendor')")" = $'hold\toperator-fixture\t2026-10-15T10:00:00Z\t7001' ] \
  && ok "H1 a person HOLD -> hold" || bad "H1: $(hf "$(cm User operator-fixture 'HOLD: wait')")"
[ "$(hf "$(cm User operator-fixture 'RESUME')" | cut -f1)" = resume ] && ok "H2 a person RESUME -> resume" || bad "H2: $(hf "$(cm User x RESUME)")"
[ -z "$(hf "$(cm Bot 'harness-app[bot]' 'HOLD: from the app')")" ] && ok "H3 a bot HOLD -> none" || bad "H3: $(hf "$(cm Bot b 'HOLD: x')")"
[ -z "$(hf "$(cm User operator-fixture 'Do NOT RESUME this yet')")" ] && ok "H4 Do NOT RESUME this yet -> none" || bad "H4"
[ -z "$(hf "$(cm User operator-fixture 'NEEDS-HUMAN: set the secret')")" ] && ok "H5 NEEDS-HUMAN -> none" || bad "H5"
[ -z "$(hf "$(cm User operator-fixture 'RESUME once #12 merges, do not release before')")" ] \
  && ok "H6 RESUME once #12 merges, do not release before -> none" || bad "H6"
[ -z "$(hf "$(cm User operator-fixture 'HUMAN-STEP-DONE: done')")" ] && [ -z "$(hf '{"not":"an array"}')" ] \
  && ok "H6b HUMAN-STEP-DONE and a non-array -> none" || bad "H6b"

# ============================================================================
echo "E1: the run-preplan block writes one row per Blocked-by"
awk '/^  # >>> ticket edges/{f=1} f; /^  # <<< ticket edges/{exit}' "$DIR/bin/run-preplan.sh" > "$T/preplan-block.sh"
grep -q te_put_edges "$T/preplan-block.sh" || bad "E1 setup: no ticket edges block in bin/run-preplan.sh"
PD="$H/plans/proj-AB-20"; mkdir -p "$PD"
cat > "$PD/plan.md" <<'MD'
## Scope
Touch src/lib/brain-map.ts only.

## Dependencies
Blocked-by: #11
Blocked-by: #12
SIZE: S
MD
printf 'SOURCE: ticket-body\nsrc/lib/brain-map.ts\n\n' > "$PD/planned-files.txt"
cp "$PD/plan.md" "$T/plan.before"
preplan() { ( PROJECT=proj; TICKET=20; KEY=AB-20; PLANDIR="$PD"
  # shellcheck source=/dev/null
  . "$T/preplan-block.sh" ); }
OUT=$(preplan); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "E1 the block rc 0, no stdout" || bad "E1 rc=$RC out='$OUT'"
R11=$(edge 11 20); R12=$(edge 12 20)
[ "$(jq -r '[.kind,.source,.verified_at,.project]|@tsv' <<<"$R11")" = $'hard\tplanner\t\tproj' ] && ok "E1 11->20 hard planner, verified_at null" || bad "E1 11->20: $R11"
[ "$(jq -r '[.kind,.source]|@tsv' <<<"$R12")" = $'hard\tplanner' ] && ok "E1 12->20 hard planner" || bad "E1 12->20: $R12"
[ "$(jq -c ".planned_files|fromjson" <<<"$R11")" = '["src/lib/brain-map.ts"]' ] && ok "E1 planned_files from planned-files.txt, SOURCE line dropped" || bad "E1 files: $R11"
[ "$(nrows ticket_edges)" = 2 ] && ok "E1 exactly two rows" || bad "E1 rows: $(rows ticket_edges)"
cmp -s "$PD/plan.md" "$T/plan.before" && ok "E1b plan.md is byte-identical" || bad "E1b plan.md changed"

echo "E4: the same plan twice is one row per edge"
P0=$(posts edges)
( eval "$LIB"; te_put_edges proj 20 planner "$PD/plan.md" ) >/dev/null
[ "$(posts edges)" = $((P0 + 2)) ] && ok "E4 the second run POSTed again (2 requests)" || bad "E4 posts $P0 -> $(posts edges)"
[ "$(nrows ticket_edges)" = 2 ] && [ "$(rows ticket_edges | jq '[.[]|select(.parent=="11" and .child=="20")]|length')" = 1 ] \
  && ok "E4 still one row for (proj, 11, 20)" || bad "E4 rows: $(rows ticket_edges)"

echo "K1: flags/ticket-edges-off sends nothing"
: > "$H/flags/ticket-edges-off"; P0=$(posts edges)
preplan >/dev/null; ( eval "$LIB"; te_put_verdict proj 20 11 SOFT )
[ "$(posts edges)" = "$P0" ] && ok "K1 no POST with the kill flag" || bad "K1 posts $P0 -> $(posts edges)"
rm -f "$H/flags/ticket-edges-off"

echo "F2: a 503 answer"
answer '{"status":503,"body":"{\"error\":\"ticket_edges schema not applied\"}"}'
rm -f "$H/logs/ticket-edges.log"
OUT=$(preplan); RC=$?
answer '{}'
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "F2 the block rc 0, no stdout" || bad "F2 rc=$RC out='$OUT'"
[ "$(grep -c 'http=503' "$H/logs/ticket-edges.log" 2>/dev/null)" = 2 ] && grep -q 'POST 11->20 http=503' "$H/logs/ticket-edges.log" \
  && ok "F2 one http=503 line per failed POST" || bad "F2 log: $(cat "$H/logs/ticket-edges.log" 2>/dev/null)"

echo "F4: the worker down pages nothing"
# No settings cache: the kill-switch read must ask the (dead) worker too.
rm -f "$H/logs/ALERTS.log" "$H/logs/ticket-edges.log" "$H/state/settings-cache.json"
OUT=$(JOBS_URL="http://127.0.0.1:9" preplan); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "F4 the block rc 0, no stdout" || bad "F4 rc=$RC out='$OUT'"
grep -q 'POST 11->20 http=none' "$H/logs/ticket-edges.log" 2>/dev/null && ok "F4 one http=none line per failed POST" || bad "F4 log: $(cat "$H/logs/ticket-edges.log" 2>/dev/null)"
[ ! -s "$H/logs/ALERTS.log" ] && ok "F4 no ALERTS line" || bad "F4 ALERTS: $(cat "$H/logs/ALERTS.log")"

# ============================================================================
echo "E2: the real dep-verify writes its verdict"
cat > "$H/fleet.conf" <<'CONF'
proj  example-org/proj   -                 -           0 local -
CONF
echo 'setsid /root/harness/bin/run-build.sh proj <issue-number> AB-<issue-number> > x' > "$H/prompts/proj.md"
cat > "$H/bin/gh" <<'SH'
#!/bin/bash
[ "${1:-}" = api ] || exit 1
shift
INC=0; P=""
while [ $# -gt 0 ]; do
  case "$1" in
    -i) INC=1; shift ;;
    -X|-f|-F|-H) shift 2 ;;
    -*) shift ;;
    *) P="$1"; shift; break ;;
  esac
done
reply() { [ "$INC" = 1 ] && printf 'HTTP/2.0 %s\r\n\r\n' "$1"; [ -n "$2" ] && printf '%s\n' "$2"; case "$1" in 2*) exit 0 ;; *) exit 1 ;; esac; }
case "$P" in
  */pulls/*/files*) reply 200 "$(cat "$HARNESS/pr-files.json")" ;;
  */pulls*)         reply 200 "$(cat "$HARNESS/prs.json")" ;;
  */issues/[0-9]*)  reply 200 '{"body":"## Scope\nBlocked-by: #11\n"}' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$H/bin/gh"
echo '[{"number":99,"title":"AB-11: parent","head":{"ref":"ticket/ab-11","sha":"aaaa111"},"state":"open","merged_at":null}]' > "$H/prs.json"
echo '[{"filename":"src/lib/rollup.ts"}]' > "$H/pr-files.json"
cat > "$PD/plan.md" <<'MD'
## Dependencies
DEPENDS: #11 soft — reads no symbol #11 adds, ordering preference only
SIZE: S
MD
printf 'src/lib/brain-map.ts\n' > "$PD/planned-files.txt"
dv() { PATH="$H/bin:$PATH" GH_ISSUES_REPO=example-org/proj "$H/bin/dep-verify.sh" proj 20 11 2>/dev/null; }
OUT_UP=$(dv); RC=$?
R=$(edge 11 20)
[ "$RC" = 0 ] && [[ "$OUT_UP" == SOFT\ * ]] && ok "E2 dep-verify answers SOFT rc 0" || bad "E2 rc=$RC out='$OUT_UP'"
[ "$(jq -r '[.kind,.source]|@tsv' <<<"$R")" = $'soft\tdep-verify' ] && [ -n "$(jq -r '.verified_at // empty' <<<"$R")" ] \
  && ok "E2 the row is soft, dep-verify, verified_at set" || bad "E2 row: $R"
[ "$(wc -l <<<"$OUT_UP" | tr -d ' ')" = 1 ] && ok "E2 still exactly one stdout line" || bad "E2 stdout: $OUT_UP"
P0=$(posts edges); OUT=$(dv)
[ "$OUT" = "$OUT_UP" ] && [ "$(posts edges)" = "$P0" ] && ok "E2b a cached verdict sends no POST" || bad "E2b posts $P0 -> $(posts edges), out=$OUT"
echo "E2c: dry run"
scratch_rm "$H/state/dep-verify"; P0=$(posts edges)
OUT=$(DEP_VERIFY_DRY_RUN=1 dv)
[[ "$OUT" == SOFT\ * ]] && [ "$(posts edges)" = "$P0" ] && ok "E2c DEP_VERIFY_DRY_RUN=1 sends no POST" || bad "E2c posts $P0 -> $(posts edges), out=$OUT"
echo "E2b: a HARD verdict moves the row"
printf 'src/lib/rollup.ts\n' > "$PD/planned-files.txt"
OUT=$(dv)
[[ "$OUT" == HARD\ * ]] && [ "$(edge 11 20 | jq -r .kind)" = hard ] && [ "$(edge 11 20 | jq -r .source)" = dep-verify ] \
  && ok "E2b HARD -> the row is hard" || bad "E2b out=$OUT row=$(edge 11 20)"
echo "F1/N1: the worker down"
scratch_rm "$H/state/dep-verify"; OUT_UP=$(dv); RC_UP=$?
scratch_rm "$H/state/dep-verify"
OUT_DOWN=$(JOBS_URL="http://127.0.0.1:9" dv); RC_DOWN=$?
[ "$RC_DOWN" = 0 ] && [ "$OUT_DOWN" = "$OUT_UP" ] && [ "$RC_UP" = 0 ] \
  && ok "F1/N1 port closed: the same one line, rc 0" || bad "F1 up rc=$RC_UP '$OUT_UP' down rc=$RC_DOWN '$OUT_DOWN'"
grep -q 'POST 11->20 http=none' "$H/logs/ticket-edges.log" 2>/dev/null && ok "F1 one log line for the failed POST" || bad "F1 log: $(tail -2 "$H/logs/ticket-edges.log" 2>/dev/null)"
# dep-verify's own GitHub-auth flag read pages on an outage at the merge base
# too, so only a line naming this ticket's requests is a finding here (F4
# checks a writer alone).
grep -qE '/api/(ticket-|settings)' "$H/logs/ALERTS.log" 2>/dev/null && bad "F1 an ALERTS line names a ticket-edges request: $(cat "$H/logs/ALERTS.log")" \
  || ok "F1 no ALERTS line names a ticket-edges request"

# ============================================================================
echo "E3: the ticket-holds wake class"
# gh_rest_issue_comments stub: the thread is $T/thread-<n>.json, the rc is
# $T/thread-rc (0 when absent); every call is one line in $T/reads.
thread() { jq -c '.' > "$T/thread-$1.json"; }
wake() { # wake <rows as "kind key event repo" lines>...
  ( . "$H/bin/jobs-client.sh"; . "$H/bin/lib/wake-class-ticket-holds.sh"
    say() { printf '%s\n' "$*" >> "$T/say.log"; }
    gh_rest_issue_comments() { printf '%s#%s\n' "$1" "$2" >> "$T/reads"; cat "$T/thread-$2.json" 2>/dev/null
      return "$(cat "$T/thread-rc" 2>/dev/null || echo 0)"; }
    local r
    for r in "$@"; do
      # shellcheck disable=SC2086 # a row is four words on purpose
      set -- $r; wc_ticket_holds_row proj "$1" "$2" "$3" "$4" 1
    done
    wc_ticket_holds_dispatch ) >/dev/null 2>&1
}
HOLD1='{"id":8001,"body":"HOLD: wait for the vendor","created_at":"2026-10-15T10:00:00Z","user":{"login":"operator-fixture","type":"User"}}'
RES1='{"id":8002,"body":"RESUME","created_at":"2026-10-15T11:00:00Z","user":{"login":"pat-fixture","type":"User"}}'
BOT1='{"id":8003,"body":"HOLD: an app note","created_at":"2026-10-15T11:30:00Z","user":{"login":"harness-app[bot]","type":"Bot"}}'
printf '[%s,%s]\n' "$HOLD1" "$BOT1" | thread 30
wake "issue 30 issue_comment.created o/r"
H30=$(rows ticket_holds)
[ "$(jq 'length' <<<"$H30")" = 1 ] && [ "$(jq -r '.[0]|[.state,.by,.ticket,.comment_id,.at]|@tsv' <<<"$H30")" = $'hold\toperator-fixture\t30\t8001\t2026-10-15T10:00:00Z' ] \
  && ok "E3 one hold row, by the login; the bot comment made none" || bad "E3 rows: $H30"
printf '[%s,%s,%s]\n' "$HOLD1" "$BOT1" "$RES1" | thread 30
wake "issue 30 issue_comment.created o/r"
[ "$(rows ticket_holds | jq -r '[.[].state]|sort|join(",")')" = hold,resume ] && ok "E3 RESUME -> two rows: hold and resume" || bad "E3 rows: $(rows ticket_holds)"
wake "issue 30 issue_comment.edited o/r"
[ "$(nrows ticket_holds)" = 2 ] && ok "E3 the same thread again -> still two rows" || bad "E3 rows: $(rows ticket_holds)"
curl -sS "$JOBS_URL/api/ticket-holds?project=proj&ticket=30" -H "authorization: Bearer $HARNESS_SECRET" \
  | jq -e '.holds[0].state == "resume"' >/dev/null && ok "E3 GET /api/ticket-holds answers the newest first" || bad "E3 GET"

echo "H8: wakes the class ignores"
: > "$T/reads"
wake "pr 30 issue_comment.created o/r" "issue TK-3 issue_comment.created o/r"
[ ! -s "$T/reads" ] && ok "H8 a PR comment and a non-numeric key read no thread" || bad "H8 reads: $(cat "$T/reads")"

echo "H9: a HOLD that shares its minute with an issues.* event"
# Wake rows dedupe on (repo, kind, key, minute) and the first event wins, so a
# HOLD posted in the minute the issue was labeled is stored as issues.labeled.
: > "$T/reads"
printf '[%s]\n' "$HOLD1" | sed 's/8001/8012/' | thread 32
wake "issue 32 issues.labeled o/r"
[ "$(cat "$T/reads")" = 'o/r#32' ] && ok "H9 an issues.labeled wake reads the thread" || bad "H9 reads: $(cat "$T/reads")"
[ "$(rows ticket_holds | jq -r '[.[]|select(.ticket=="32")|[.state,.comment_id]|@tsv]|join(",")')" = $'hold\t8012' ] \
  && ok "H9 one hold row for the HOLD comment" || bad "H9 rows: $(rows ticket_holds)"

echo "F3: a failed thread read"
rm -f "$H/logs/ticket-holds.log"; printf '[%s]\n' "$HOLD1" | sed 's/8001/8009/' | thread 31
echo 75 > "$T/thread-rc"
wake "issue 31 issue_comment.created o/r"
rm -f "$T/thread-rc"
[ "$(rows ticket_holds | jq '[.[]|select(.ticket=="31")]|length')" = 0 ] && ok "F3 no row" || bad "F3 rows: $(rows ticket_holds)"
[ "$(grep -c 'o/r#31 thread read failed rc=75' "$H/logs/ticket-holds.log" 2>/dev/null)" = 1 ] && ok "F3 one log line" || bad "F3 log: $(cat "$H/logs/ticket-holds.log" 2>/dev/null)"

echo "H7: the read cap"
setting ticket_holds.wake_reads_max 2; : > "$T/reads"; : > "$T/say.log"
for n in 41 42 43; do printf '[]\n' | thread $n; done
wake "issue 41 issue_comment.created o/r" "issue 42 issue_comment.created o/r" "issue 43 issue_comment.created o/r" "issue 41 issue_comment.edited o/r"
[ "$(wc -l < "$T/reads" | tr -d ' ')" = 2 ] && ok "H7 two thread reads (a repeat wake is deduped)" || bad "H7 reads: $(cat "$T/reads")"
[ "$(grep -c '1 thread(s) left for the next wake' "$T/say.log")" = 1 ] && ok "H7 one cap line naming 1 left" || bad "H7 say: $(cat "$T/say.log")"
setting ticket_holds.wake_reads_max 0; : > "$T/reads"
wake "issue 41 issue_comment.created o/r"
[ ! -s "$T/reads" ] && ok "H7 wake_reads_max=0 reads nothing" || bad "H7 reads at 0: $(cat "$T/reads")"
setting ticket_holds.wake_reads_max 20

# ============================================================================
echo "E5: the run-decompose block"
awk '/^  # >>> ticket edges/{f=1} f; /^  # <<< ticket edges/{exit}' "$DIR/bin/run-decompose.sh" > "$H/bin/decompose-block.sh"
grep -q te_put_edges "$H/bin/decompose-block.sh" || bad "E5 setup: no ticket edges block in bin/run-decompose.sh"
B="$T/build"; mkdir -p "$B/children"
printf 'BH-41\nBH-42\n' > "$B/children.txt"
( . "$H/bin/lib/file-children.sh"
  { printf 'The contract.\n\n'; fc_child_footer decompose 40 1 2 "" "" "src/a.ts" "" ""; } > "$B/children/child-1.md"
  { printf 'The list view.\n\n'; fc_child_footer decompose 40 2 2 "#41 (hard)" "DEPENDS: #41 hard — imports the contract" "" "" ""
    printf 'Owns: src/list.ts, docs/list.md\n'; } > "$B/children/child-2.md" )
grep -q '^Blocked-by: #41 (hard)$' "$B/children/child-2.md" || bad "E5 setup: fc_child_footer wrote no Blocked-by line"
cp "$B/children/child-2.md" "$T/child-2.before"
decompose() { ( export HARNESS PROJECT=proj BUILD="$B" LANE="$1" DRY="$2"; bash "$H/bin/decompose-block.sh" ); }
P0=$(posts edges)
OUT=$(decompose issues 0); RC=$?
R=$(edge 41 42)
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok "E5 the block rc 0, no stdout" || bad "E5 rc=$RC out='$OUT'"
[ "$(jq -r '[.kind,.source]|@tsv' <<<"$R")" = $'hard\tdecompose' ] && ok "E5 one row 41->42 hard decompose" || bad "E5 row: $R"
[ "$(jq -c ".planned_files|fromjson" <<<"$R")" = '["src/list.ts","docs/list.md"]' ] && ok "E5 planned_files from the Owns: line" || bad "E5 files: $R"
[ "$(posts edges)" = $((P0 + 1)) ] && ok "E5 one POST: the contract child declares no blocker" || bad "E5 posts $P0 -> $(posts edges)"
cmp -s "$B/children/child-2.md" "$T/child-2.before" && ok "E5b the child body is byte-identical" || bad "E5b child body changed"
echo "E6: dry run and the board lane"
P0=$(posts edges)
decompose issues 1 >/dev/null; decompose board 0 >/dev/null
[ "$(posts edges)" = "$P0" ] && ok "E6 DRY=1 and LANE=board send no POST" || bad "E6 posts $P0 -> $(posts edges)"

echo
echo "ticket-edges.bh-6977: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
