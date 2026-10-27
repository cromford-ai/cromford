#!/bin/bash
# tests/unblock-empty-block-owner.bh-8554-test.sh — BH-8554: one owner for an
# empty lead BLOCK. bin/lead-review-land.sh withholds a lead BLOCK report with
# no `^- \[BLOCK` line and logs "BLOCK report has no finding line". The queue
# family turns that line into a pr-empty-block record (U13-EMPTY, then
# U13-EMPTY-CARD). The review family must leave that report alone: before this
# fix it emitted lead-block-unrouted for it, so U5 posted (indented BLOCK
# lines) or U12 carded (zero BLOCK lines) on top of the U13-EMPTY action.
#
#   A1  0 BLOCK lines: both REAL collectors + the REAL ub_rules_eval over the
#       SHIPPED catalog/unblock-rules.d give 1 decision for the PR, U13-EMPTY
#       act WOULD_LEAD_REREQUEST; 0 U5, U12 or null decisions; 1 WOULD line.
#   A2  only indented `  - [BLOCK x]` lines: the same (U5 does not post).
#   A3  2 land lines for the head (past UNBLOCK_EMPTY_BLOCK_MAX 1): 1 decision,
#       U13-EMPTY-CARD escalate; 0 U12.
#   A4  bin/unblock.sh tick in act mode (the shipped entry point) over the real
#       review and queue collectors and the real rules engine: 1 CLAIM, 1 ACT
#       U13-EMPTY, 0 CARD; a second tick claims nothing new (409).
#   D1-D10 the review collector alone, one report body per case (the plan's
#       decision table): drop side D1-D4, keep side D5-D10.
#   B   0 non-GET gh calls, 0 worker writes, 0 model calls in every case.
#
# Stubs per case under $T/<case>: `gh` and `curl` on PATH answer from the
# case's copy of tests/fixtures/unblock/bh-8554/empty-block.json; claude and
# agent-call.sh on PATH log and fail. Every case has its own scratch harness.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-empty-block-owner.bh-8554-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq missing"; exit 1; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "${2:0:1500}"; return 0; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want '$3' got '$2'"; fi; }

FX="$SRC/tests/fixtures/unblock/bh-8554"
RULES="$SRC/catalog/unblock-rules.d"
R=example-org/cromford
HD=8554eeee0000000000000000000000000000e001
export JOBS_URL=https://jobs.example.test
BODY_HEAD='<!-- review-verdict: v2 -->\n# Lead review cromford#8554\n\nVerdict: BLOCK\n\n'

# ═════ stubs ═════════════════════════════════════════════════════════════════
mkdir -p "$T/pathbin"
cat > "$T/pathbin/gh" <<'SH'
#!/bin/bash
# gh api -i -X <method> <path>: exact path key in .gh of the case fixture.
m=GET; p=; hdr=0
while [ $# -gt 0 ]; do
  case "$1" in api) ;; -i) hdr=1 ;; -X) m="$2"; shift ;; -H|--input|-F|-f) shift ;; *) p="$1" ;; esac
  shift
done
echo "$m $p" >> "$CASE/gh.calls"
if [ "$m" != GET ]; then echo "gh $m $p" >> "$CASE/writes.txt"; [ "$hdr" = 1 ] && printf 'HTTP/2 405\r\n\r\n'; echo '{"message":"writes refused"}'; exit 1; fi
if jq -e --arg p "$p" '.gh | has($p)' "$CASE/fx.json" >/dev/null; then
  [ "$hdr" = 1 ] && printf 'HTTP/2 200\r\ncontent-type: application/json\r\n\r\n'; jq -c --arg p "$p" '.gh[$p]' "$CASE/fx.json"; exit 0
fi
[ "$hdr" = 1 ] && printf 'HTTP/2 404\r\ncontent-type: application/json\r\n\r\n'; echo '{"message":"Not Found"}'; exit 1
SH
cat > "$T/pathbin/curl" <<'SH'
#!/bin/bash
# The jobs worker: prints the body, a newline and the status (curl -w '\n%{http_code}').
m=GET; url=""
while [ $# -gt 0 ]; do
  case "$1" in -X) m="$2"; shift 2 ;; -H|-w|-m|--connect-timeout|--data-binary|-d) shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
p="${url#"$JOBS_URL"}"
echo "$m $p" >> "$CASE/curl.calls"
if [ "$m" != GET ]; then echo "curl $m $p" >> "$CASE/writes.txt"; printf '{"error":"write refused"}\n500'; exit 0; fi
path="${p%%\?*}"; key=""
case "$path" in
  /api/verdicts) key="verdicts.$(sed -n 's/.*[?&]pr=\([0-9]*\).*/\1/p' <<<"$p")" ;;
  /api/jobs/*/artifacts) j="${path#/api/jobs/}"; key="artifacts.${j%/artifacts}" ;;
  /api/lead-reviews) key=lead_reviews_running ;;
esac
body=""; [ -z "$key" ] || body=$(jq -c --arg k "$key" '.worker | getpath($k | split(".")) // empty' "$CASE/fx.json")
if [ -z "$body" ]; then printf '{"error":"not found"}\n404'; exit 0; fi
case "$key" in artifacts.*) body=$(jq -c '{artifacts: [to_entries[] | {artifact_kind: .key, detail: (.value | tojson)}]}' <<<"$body") ;; esac
printf '%s\n200' "$body"
SH
for s in claude agent-call.sh; do printf '#!/bin/bash\necho "%s $*" >> "$CASE/model.calls"\nexit 7\n' "$s" > "$T/pathbin/$s"; done
chmod +x "$T/pathbin/"*

# mkcase <name> [jq edit of the fixture] — a fresh scratch harness; sets C.
CASES=""
mkcase() {
  local f
  C="$T/$1"; CASES="$CASES $C"
  mkdir -p "$C/h/logs" "$C/h/locks" "$C/h/state" "$C/h/catalog"
  for f in bin/lib/unblock/collectors/review.sh bin/lib/unblock/collectors/queue.sh bin/lib/unblock/rules.sh \
           bin/lib/unblock/signals.sh bin/lib/gh-rest.sh bin/jobs-client.sh bin/lib/br/record.sh; do
    ( cd "$SRC" && scratch_install_closure "$f" "$C/h" ) >/dev/null || { no "$1: closure $f"; return 1; }
  done
  cp -R "$RULES" "$C/h/catalog/unblock-rules.d"
  if [ -n "${2:-}" ]; then jq "$2" "$FX/empty-block.json" > "$C/fx.json" || no "$1: fixture edit"; else cp "$FX/empty-block.json" "$C/fx.json"; fi
  cp "$FX/lead-review-land.log" "$C/h/logs/lead-review-land.log"
  : > "$C/gh.calls"; : > "$C/curl.calls"; : > "$C/writes.txt"; : > "$C/model.calls"
}
# body <text with \n escapes> — the jq edit that sets the report body.
body() { printf '.worker.artifacts["job-8554"].lead_review_report.body = "%s%s"' "$BODY_HEAD" "$1"; }

cenv() { # the environment every collector run gets
  export CASE="$C" HARNESS="$C/h" PATH="$T/pathbin:$PATH" GH_ETAG=0 TMPDIR="$C" HARNESS_SECRET=fixture-secret-1
  UNBLOCK_NOW=$(date -u -d "$(jq -r .now "$C/fx.json")" +%s); export UNBLOCK_NOW
}
# queue_seams — the queue collector reads that are not GitHub (8390 style).
queue_seams() {
  ubq_batch_drafts() { return 0; }
  vd_standing() { [ "$1#$2 $3" = "$R#8554 $HD" ] || return 1; jq -r .verdict_line "$CASE/fx.json"; }
  setting_get() { return 2; }
  pr_attempt_count() { printf '0'; return 0; }
}

# run_review — the review collector alone: records.jsonl (the CLI's stdout, meta included).
run_review() {
  ( cenv; bash "$HARNESS/bin/lib/unblock/collectors/review.sh" --project cromford --repo "$R" ) > "$C/review.jsonl" 2> "$C/review.err"
  echo $? > "$C/review.rc"
}
# run_both — ub_collect_review + ub_collect_queue into one file, then ub_rules_eval.
run_both() {
  (
    cenv
    . "$HARNESS/bin/lib/unblock/collectors/review.sh" || exit 9
    . "$HARNESS/bin/lib/unblock/collectors/queue.sh" || exit 9
    . "$HARNESS/bin/lib/unblock/rules.sh" || exit 9
    queue_seams
    ub_collect_review cromford "$R" > "$C/records.jsonl"
    ub_collect_queue cromford "$R" >> "$C/records.jsonl"
    ub_rules_eval < "$C/records.jsonl" > "$C/decisions.jsonl"
    ub_rules_would_lines < "$C/decisions.jsonl" > "$C/would.txt"
  )
}
recs() { jq -c --arg k "$1" 'select(.kind == $k)' "$C/review.jsonl" 2>/dev/null; }
dec_of() { jq -r 'select(.pr == 8554) | "\(.rule_id) \(.would // .decision)"' "$C/decisions.jsonl" | sort | tr '\n' ';'; }
# eval_one <record> — the real rules engine over one record: its rule_id.
eval_one() { ( cenv; . "$HARNESS/bin/lib/unblock/rules.sh"; printf '%s\n' "$1" | ub_rules_eval | jq -r '.rule_id // "null"' ); }

# ═════ A1-A3: both collectors, the real rules ════════════════════════════════
mkcase a1 "$(body '- [NOTE] the loop is slow\n- [HUMAN go-live] set the DNS\n- review level: smoke\n')"
run_both
check "A1 0 BLOCK lines: one decision for the PR, U13-EMPTY" "$(dec_of)" "U13-EMPTY WOULD_LEAD_REREQUEST;"
check "A1 0 U5, U12 or null decisions for the PR" "$(jq -r 'select(.pr == 8554) | .rule_id // "null"' "$C/decisions.jsonl" | grep -cE '^(U5|U12|null)$')" 0
check "A1 one WOULD line" "$(grep -c . "$C/would.txt")" 1
check "A1 the re-request names the land log's request id" "$(jq -r 'select(.pr == 8554) | .action.args.request_id' "$C/decisions.jsonl")" 00000000-0000-0000-0000-000000008554
check "A1 the review family emits no record for the PR" "$(jq -r 'select(.family == "review") | .kind' "$C/records.jsonl" | grep -c .)" 0

mkcase a2 "$(body '  - [BLOCK wrong-data] bin/x.sh:1 the value is wrong\n  - [BLOCK data-loss] bin/y.sh:2 rows are lost\n')"
run_both
check "A2 indented BLOCK lines only: one decision, U13-EMPTY" "$(dec_of)" "U13-EMPTY WOULD_LEAD_REREQUEST;"
check "A2 no U5 post_block" "$(jq -r 'select(.rule_id == "U5") | .rule_id' "$C/decisions.jsonl" | grep -c .)" 0
check "A2 one WOULD line" "$(grep -c . "$C/would.txt")" 1

mkcase a3 "$(body '- [NOTE] the loop is slow\n')"
sed 's/03:00:10Z/03:30:10Z/' "$FX/lead-review-land.log" >> "$C/h/logs/lead-review-land.log"
run_both
check "A3 2 empty BLOCKs on the head: one decision, U13-EMPTY-CARD" "$(dec_of)" "U13-EMPTY-CARD escalate;"
check "A3 0 U12 decisions" "$(jq -r 'select(.rule_id == "U12") | .rule_id' "$C/decisions.jsonl" | grep -c .)" 0

# ═════ D1-D10: the review collector alone ════════════════════════════════════
mkcase d1 "$(body '- review level: smoke\n')"
run_review
check "D1 0 BLOCK lines: rc 0, no record" "$(cat "$C/review.rc") $(grep -vc '"collector-meta"' "$C/review.jsonl")" "0 0"
check "D1 the meta line is still last" "$(tail -1 "$C/review.jsonl" | jq -r '"\(.kind) \(.prs_seen)"')" "collector-meta 1"
grep -q "review: $R prs=1 records=0 .* empty_owned=1:8554$" "$C/h/logs/unblock.log" && ok "D1 the log line names empty_owned=1:8554" \
  || no "D1 the log line names empty_owned=1:8554" "$(cat "$C/h/logs/unblock.log")"

mkcase d2 "$(body '  - [BLOCK wrong-data] x\n')"
run_review
check "D2 indented BLOCK only: no record" "$(grep -vc '"collector-meta"' "$C/review.jsonl")" 0

mkcase d3 "$(body '> - [BLOCK wrong-data] x\n')"
run_review
check "D3 quoted BLOCK only: no record" "$(grep -vc '"collector-meta"' "$C/review.jsonl")" 0

mkcase d4 "$(body '- [NOTE] a\n- [HUMAN go-live] b\n')"
run_review
check "D4 NOTE and HUMAN lines only: no record" "$(grep -vc '"collector-meta"' "$C/review.jsonl")" 0

mkcase d5 "$(body '- [NOTE] a\n- [BLOCK wrong-data] bin/x.sh:1 the value is wrong\n')"
run_review
r=$(recs lead-block-unrouted)
check "D5 one anchored BLOCK line: lead-block-unrouted, 1 line" "$(jq -r '.block_lines | length' <<<"$r")" 1
check "D5 U5 takes it" "$(eval_one "$r")" U5
if grep -q empty_owned "$C/h/logs/unblock.log"; then no "D5 no empty_owned in the log" "$(cat "$C/h/logs/unblock.log")"; else ok "D5 no empty_owned in the log"; fi

mkcase d6 "$(body '- [BLOCK wrong-data] a\n  - [BLOCK wrong-data] b\n')"
run_review
check "D6 anchored + indented: block_lines are the anchored lines" "$(recs lead-block-unrouted | jq -c .block_lines)" '["- [BLOCK wrong-data] a"]'

mkcase d7 "$(body '- [BLOCK a] x\r\n- [NOTE] y\r\n')"
run_review
check "D7 CRLF body: lead-block-unrouted, 1 line" "$(recs lead-block-unrouted | jq -r '.block_lines | length')" 1

mkcase d8 "$(body '- review level: smoke\n') | .worker.artifacts[\"job-8554\"].lead_review_report.truncated = true"
run_review
r=$(recs lead-block-unrouted)
check "D8 cut report: record kept, report_readable null, unknown has report" \
  "$(jq -r '"\(.report_readable) \(.unknown | index("report") != null)"' <<<"$r")" "null true"

mkcase d9 "$(body '- review level: smoke\n') | .worker.verdicts[\"8554\"].standing.note = \"lead-review:lr-fixture-8554\""
run_review
r=$(recs lead-block-unrouted)
check "D9 no lead-job token: record kept, unknown has report" "$(jq -r '"\(.job_id) \(.unknown | index("report") != null)"' <<<"$r")" "null true"

mkcase d10 "$(body '- outcome cap: 1 INCONCLUSIVE claim row (claim 2) on perf (LEAD_REVIEW_INCONCLUSIVE_BLOCK=1); agent verdict BLOCK\n')"
run_review
r=$(recs lead-block-cap-only)
check "D10 legacy cap-only: lead-block-cap-only, unchanged" "$(jq -r '"\(.cap_only_candidate) \(.block_lines | length)"' <<<"$r")" "true 0"
check "D10 U6 takes it" "$(eval_one "$r")" U6

# ═════ A4: bin/unblock.sh tick in act mode ═══════════════════════════════════
mkcase a4 "$(body '- [NOTE] the loop is slow\n')"
mkdir -p "$C/h/env"; : > "$C/h/env/global.env"; : > "$C/seq.log"
printf 'cromford example-org/cromford - - 3 hub 192.0.2.10\n' > "$C/h/fleet.conf"
for f in bin/unblock.sh bin/fleet-conf.sh bin/lib/unblock/act.sh bin/lib/unblock/collect.sh bin/lib/unblock/scope.sh; do
  ( cd "$SRC" && scratch_install_closure "$f" "$C/h" ) >/dev/null || no "A4: closure $f"
done
for f in "$C/h"/bin/lib/unblock/collectors/*.sh; do case "$(basename "$f")" in review.sh|queue.sh) ;; *) rm -f "$f" ;; esac; done
printf '#!/bin/bash\nexit 0\n' > "$C/h/bin/lane-alert.sh"; chmod +x "$C/h/bin/lane-alert.sh"
NOW4=$(date -u -d "$(jq -r .now "$C/fx.json")" +%s)
jq -nc --argjson fa "$NOW4" '{fetched_at: $fa, values: {"unblock.project.cromford.mode": "act"}, seeded: {}}' > "$C/h/state/settings-cache.json"
{ printf 'A4=%q\nR=%q\nHD=%q\n' "$C" "$R" "$HD"
  cat <<'SH'
a4_log() { printf '%s\n' "$*" >> "$A4/seq.log"; }
setting_get() { case "$1" in unblock.enabled) echo 1 ;; *) return 2 ;; esac; }
lane_gate_or_exit() { return 0; }
lane_env_apply() { return 0; }
lane_role_model() { echo stub-model-x; }
vd_standing() { [ "$1#$2 $3" = "$R#8554 $HD" ] || return 1; jq -r .verdict_line "$A4/fx.json"; }
pr_attempt_count() { printf '0'; return 0; }
declare -F _a4_real_jobs_req >/dev/null || eval "$(declare -f _jobs_req | sed '1s/^_jobs_req /_a4_real_jobs_req /')"
_jobs_req() {
  local k
  case "$1 $2" in
    "POST /api/unblock/decisions/claim")
      a4_log "CLAIM $(jq -r .rule_id <<<"$3")"; k=$(jq -r .decision_key <<<"$3"); mkdir -p "$A4/seen"
      if [ -f "$A4/seen/$k" ]; then printf '{"claimed":false,"id":1,"outcome":"would"}'; return 9; fi
      touch "$A4/seen/$k"; printf '{"claimed":true,"id":1}'; return 0 ;;
    "POST /api/unblock/decisions/record") a4_log "RECORD $(jq -r .outcome <<<"$3")"; printf '{"ok":true}'; return 0 ;;
  esac
  _a4_real_jobs_req "$@"
}
ub_act() { a4_log "ACT $(jq -r .rule_id <<<"$1")"; UB_ACT_OUTCOME=done; UB_ACT_DETAIL=stub; return 0; }
ubt_stage_card() { a4_log "CARD $(jq -r .rule_id <<<"$1")"; printf '{"outcome":"escalated","detail":"stub","model_calls":0,"cost_usd":0}'; }
SH
} > "$C/tick-fx.sh"
tick4() {
  ( export CASE="$C"
    env PATH="$T/pathbin:$PATH" HARNESS="$C/h" UNBLOCK_FIXTURE="$C/tick-fx.sh" UNBLOCK_COLLECTORS_DIR="$C/h/bin/lib/unblock/collectors" \
      HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 LANE_GATE_NOW="$NOW4" LANE_GATE_CACHE_S=60 UNBLOCK_ACT=1 TMPDIR="$C" \
      HARNESS_SECRET=fixture-secret-1 GH_ETAG=0 UNBLOCK_NOW="$NOW4" \
      bash "$C/h/bin/unblock.sh" tick --project cromford > "$C/tick.out" 2>&1 )
}
tick4; rc=$?
L=$(grep '^tick cromford ' "$C/tick.out" | tail -1)
check "A4 tick rc 0" "$rc" 0
[[ $L == *"mode=act collectors=2 unwired=0 failed=0 "* ]] && ok "A4 both collectors ran in act mode" || no "A4 both collectors ran in act mode" "$L $(cat "$C/h/logs/unblock.log")"
check "A4 one CLAIM, U13-EMPTY" "$(grep '^CLAIM ' "$C/seq.log" | tr '\n' ';')" "CLAIM U13-EMPTY;"
check "A4 one action: ACT U13-EMPTY, 0 CARD" "$(grep -E '^(ACT|CARD) ' "$C/seq.log" | tr '\n' ';')" "ACT U13-EMPTY;"
tick4
check "A4 a second tick claims nothing new (409)" "$(grep -c '^ACT \|^CARD ' "$C/seq.log") $(grep -c 'claimed=0 rows=0' "$C/tick.out")" "1 1"

# ═════ B: the budget ═════════════════════════════════════════════════════════
W=0; G=0; M=0
for c in $CASES; do
  W=$((W + $(grep -c . "$c/writes.txt"))); G=$((G + $(grep -c . "$c/gh.calls"))); M=$((M + $(grep -c . "$c/model.calls")))
done
check "B 0 GitHub or worker writes" "$W" 0
check "B 0 model calls" "$M" 0
[ "$G" -gt 0 ] && ok "B the stubs answered reads ($G gh calls)" || no "B the stubs answered no read: the suite ran nothing"

echo "unblock-empty-block-owner: PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" = 0 ]
