#!/bin/bash
# tests/unblock-rules-u13.bh-8390-test.sh — BH-8390 (UNB-7): the Tackler rules
# for the stalls a person fixed by hand on 2026-10-25/26.
#
#   R   per rule (tests/fixtures/unblock-rules-u13/rules.json): the record
#       through ub_rules_eval over the SHIPPED catalog/unblock-rules.d decides
#       to its own rule, with exactly one WOULD_<ACTION> line (act rules) or
#       one escalate decision with action card (card rules), and the fix-round
#       brief carries the evidence; the neighbour record decides to no U13 rule
#       and gives no WOULD line.
#   C1  a red batch (#8344, 6 members) through the REAL queue collector and
#       the rules: #8071 (its diff reads MC_LOG) owns the lanes-registry
#       section 7 failure -> U13-REG fix round with merge-conductor/MC_LOG in
#       the brief; #8341 #7882 #8204 #8332 own nothing -> U13-INNOCENT
#       requeue (MC_LOGGER and a docs mention are not MC_LOG); #8342 (its file
#       list answers 500) is owns_failure null -> no U13 decision.
#   C1b the same batch where no member reads MC_LOG: 0 requeue, 0 fix round.
#   C2  logs/lead-review-land.log: #8278 (1 empty BLOCK, BLOCK on head) ->
#       U13-EMPTY lead re-request with its request id; #8372 (2 lines) ->
#       U13-EMPTY-CARD; another repo's line -> nothing.
#   C3  #8136: MERGE-WITH-NOTES on an older head, nothing on the new head, no
#       open lead request, head commit 31 min old -> U13-RESTAMP (request_id
#       none). C3b an open lead request for the head -> no U13-RESTAMP.
#   C4  logs/pipeline-health.log: TK-2601 (3 passes, 296 min) -> U13-STARVE
#       launch_fastpath TK-2601; TK-9 (RESOLVED, then 1 pass) -> nothing.
#   C5  logs/cromford.log: BH-8452.1 REVIEW_BLOCKED suite-reach, no open
#       PR, 63 min -> U13-REACH card; BH-8475 PLAN_BLOCKED -> nothing; BH-8476
#       (20 min) -> no card yet.
#   A   act.sh, act mode: lead_rerequest request_id none sends 0 resets and
#       1 request with --priority; notes reach --notes; launch_fastpath
#       launches (done launched), a decline is refused with the log reason, a
#       bad key is bad input (rc 1), shadow is would WOULD_LAUNCH_FASTPATH.
#   A8-A11 (BLOCK #4376) UNBLOCK_FASTPATH_TIMEOUT_S reaches timeout (a bad
#       value is 300); a DISPATCH-MODE hotfix-only decline is refused with
#       that reason; another rc is failed; notes over UNBLOCK_NOTES_MAX_CHARS
#       are bad input.
#   C1c C2b C2c C3c C3d C4b C5b C5c C5d (BLOCK #4376) the cap knobs cut the
#       brief, lines and detail; UNBLOCK_EMPTY_BLOCK_MAX 2 re-requests a
#       second empty BLOCK and 0 cards the first; an unread or unparseable
#       verdict history is a queue-unreadable record for the PR; an unreadable
#       log is a source-unreadable record; ubc_collect passes the repo, so
#       has_pr is read.
#   K   every record's subject kind is a claim-route word (#8500).
#   B   0 non-GET gh calls, 0 model calls in every case.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-rules-u13.bh-8390-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }
PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "${2:0:1500}"; return 0; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want '$3' got '$2'"; fi; }

FX="$SRC/tests/fixtures/unblock-rules-u13"
RULES="$SRC/catalog/unblock-rules.d"
R=example-org/cromford

# ═════ R: one record per rule ════════════════════════════════════════════════
NC=$(jq '.cases | length' "$FX/rules.json")
check "R the fixture has one case per U13 rule file" "$NC" "$(ls "$RULES"/U13-*.json | wc -l | tr -d ' ')"
for i in $(seq 0 $((NC - 1))); do
  c=$(jq -c ".cases[$i]" "$FX/rules.json")
  rule=$(jq -r .rule <<< "$c"); want=$(jq -r .want <<< "$c")
  [ -f "$RULES/$rule.json" ] || { no "R $rule: catalog/unblock-rules.d/$rule.json exists"; continue; }
  dec=$(jq -c .record <<< "$c" | (. "$SRC/bin/lib/unblock/rules.sh"; HARNESS="$SRC" ub_rules_eval "$RULES"))
  would=$(printf '%s\n' "$dec" | (. "$SRC/bin/lib/unblock/rules.sh"; ub_rules_would_lines))
  dn=$(jq -c .neighbour <<< "$c" | (. "$SRC/bin/lib/unblock/rules.sh"; HARNESS="$SRC" ub_rules_eval "$RULES"))
  check "R $rule: the record decides to $rule" "$(jq -r .rule_id <<< "$dec")" "$rule"
  check "R $rule: cites are non-empty claim-route words" "$(jq -r '(.cites | length > 0) and all(.cites[]; test("^[A-Za-z0-9._:-]{1,40}$"))' <<< "$dec") $(jq -r '(.cites | length > 0) and all(.cites[]; test("^[A-Za-z0-9._:-]{1,40}$"))' <<< "$dn")" "true true"
  if [ "$want" = escalate ]; then
    check "R $rule: escalate with action card, 0 WOULD lines" "$(jq -r '"\(.decision) \(.action.name)"' <<< "$dec") $(grep -c . <<< "$would")" "escalate card 0"
  else
    check "R $rule: exactly one $want line" "$(grep -c "^$want $rule " <<< "$would") $(grep -c . <<< "$would")" "1 1"
    bh=$(jq -r '.brief_has // empty' <<< "$c")
    if [ -n "$bh" ]; then
      case "$(jq -r '.action.args.brief // ""' <<< "$dec")" in
        *"$bh"*) ok "R $rule: the brief names '$bh'" ;;
        *) no "R $rule: the brief names '$bh'" "$(jq -c .action.args <<< "$dec")" ;;
      esac
    fi
  fi
  wn=$(printf '%s\n' "$dn" | (. "$SRC/bin/lib/unblock/rules.sh"; ub_rules_would_lines))
  case "$(jq -r '.rule_id // "null"' <<< "$dn")" in
    U13-*) no "R $rule: the neighbour decides to no U13 rule" "$(jq -r .rule_id <<< "$dn")" ;;
    *) ok "R $rule: the neighbour decides to no U13 rule" ;;
  esac
  check "R $rule: the neighbour gives 0 WOULD lines" "$(grep -c . <<< "$wn")" 0
done

# ═════ the collector harness ═════════════════════════════════════════════════
mkdir -p "$T/pathbin"
cat > "$T/pathbin/gh" <<'SH'
#!/bin/bash
m=GET; p=; hdr=0
while [ $# -gt 0 ]; do
  case "$1" in api) ;; -i) hdr=1 ;; -X) m="$2"; shift ;; -H|--input|-F|-f) shift ;; *) p="$1" ;; esac
  shift
done
echo "$m $p" >> "$GH_LOG"
if [ "$m" != GET ]; then [ "$hdr" = 1 ] && printf 'HTTP/2 405\r\n\r\n'; echo '{"message":"fixture: writes refused"}'; exit 1; fi
st=$(jq -r --arg p "$p" '.gh_status[$p] // empty' "$GH_FX")
if [ -n "$st" ]; then [ "$hdr" = 1 ] && printf 'HTTP/2 %s\r\ncontent-type: application/json\r\n\r\n' "$st"; echo '{"message":"fixture error"}'; exit 1; fi
if jq -e --arg p "$p" '.gh | has($p)' "$GH_FX" >/dev/null; then
  [ "$hdr" = 1 ] && printf 'HTTP/2 200\r\ncontent-type: application/json\r\n\r\n'; jq -c --arg p "$p" '.gh[$p]' "$GH_FX"; exit 0
fi
[ "$hdr" = 1 ] && printf 'HTTP/2 404\r\ncontent-type: application/json\r\n\r\n'; echo '{"message":"Not Found"}'; exit 1
SH
for s in claude agent-call.sh curl; do printf '#!/bin/bash\necho "%s $*" >> "$MODEL_LOG"\nexit 7\n' "$s" > "$T/pathbin/$s"; done
chmod +x "$T/pathbin/"*

mkcase() { # mkcase <name> <fixture> -> the case dir
  local C="$T/$1"
  mkdir -p "$C/h/logs" "$C/h/state"
  for f in bin/lib/unblock/collectors/queue.sh bin/lib/unblock/collectors/infra.sh bin/lib/unblock/rules.sh \
           bin/lib/unblock/signals.sh bin/lib/gh-rest.sh; do
    scratch_install_closure "$f" "$C/h" >/dev/null || return 1
  done
  mkdir -p "$C/h/catalog"
  cp -R "$RULES" "$C/h/catalog/unblock-rules.d"
  cp "$FX/$2" "$C/fx.json"
  : > "$C/gh.log"; : > "$C/model.log"
  printf '%s' "$C"
}

# run_queue <case dir> [pre]: ub_collect_queue | ub_rules_eval > decisions.jsonl
run_queue() {
  local C="$1" pre="${2:-}"
  (
    export HARNESS="$C/h" GH_FX="$C/fx.json" GH_LOG="$C/gh.log" MODEL_LOG="$C/model.log" PATH="$T/pathbin:$PATH" GH_ETAG=0 TMPDIR="$C"
    UNBLOCK_NOW=$(date -u -d "$(jq -r .now "$GH_FX")" +%s); export UNBLOCK_NOW
    . "$HARNESS/bin/lib/gh-rest.sh" || exit 9
    . "$HARNESS/bin/lib/unblock/collectors/queue.sh" || exit 9
    . "$HARNESS/bin/lib/unblock/rules.sh" || exit 9
    ubq_batch_drafts() { jq -c '.drafts[]' "$GH_FX"; }
    ubq_batch_failure() { jq -ce --arg d "$2" '.batch_failure[$d]' "$GH_FX"; }
    vd_standing() { local l; l=$(jq -r --arg k "$1#$2 $3" '.verdicts[$k] // empty' "$GH_FX"); [ -n "$l" ] || return 1; printf '%s\n' "$l"; }
    mc_attempt_has() { jq -e --arg l "$1" '.attempts | index($l) != null' "$GH_FX" >/dev/null; }
    mc_requeued_mark() { jq -r --arg k "$1 $2" '.requeued[$k] // empty' "$GH_FX"; }
    setting_get() { return 2; }
    pr_attempt_count() { printf '0'; return 0; }
    ubq_verdict_rows() { jq -ce --arg n "$2" '.verdict_rows[$n]' "$GH_FX"; }
    ubq_lead_open() { jq -ce '.lead_open' "$GH_FX"; }
    [ -n "$pre" ] && eval "$pre"
    ub_collect_queue cromford "$R" > "$C/records.jsonl"
    HARNESS="$C/h" ub_rules_eval < "$C/records.jsonl" > "$C/decisions.jsonl"
    ub_rules_would_lines < "$C/decisions.jsonl" > "$C/would.txt"
  )
}
dec_of() { jq -r --argjson n "$2" 'select(.pr == $n) | "\(.rule_id) \(.would // .decision)"' "$1/decisions.jsonl" | sort | tr '\n' ';'; }
budget() { # budget <case dir> <label>
  check "B $2: 0 non-GET gh calls" "$(grep -vc '^GET ' "$1/gh.log")" 0
  check "B $2: 0 model or network calls" "$(grep -c . "$1/model.log")" 0
}

kinds_ok() { # kinds_ok <case dir> <label>: every record's subject kind is a claim-route word (#8500)
  check "K $2: subject kinds are pr batch build box lane setting" \
    "$(jq -r 'select(.kind != "source-unreadable") | .subject_kind // (if (.pr | type) == "number" then "pr" else "none" end)' "$1/records.jsonl" \
       | grep -cvxE 'pr|batch|build|box|lane|setting')" 0
}
# ═════ C1: the red batch #8344 ═══════════════════════════════════════════════
C=$(mkcase c1 batch-8344.json) || { echo "FAIL: case setup"; exit 1; }
run_queue "$C"
check "C1 #8071 owns the section 7 failure: U13-REG fix round" "$(dec_of "$C" 8071)" "U13-REG WOULD_FIX_ROUND;"
case "$(jq -r 'select(.pr == 8071) | .action.args.brief' "$C/decisions.jsonl")" in
  *"merge-conductor/MC_LOG"*"catalog/lanes.d/<lane>.knobs.d/<KNOB>.json"*) ok "C1 #8071 brief names merge-conductor/MC_LOG and the fragment fix" ;;
  *) no "C1 #8071 brief names merge-conductor/MC_LOG and the fragment fix" "$(jq -c 'select(.pr == 8071) | .action.args' "$C/decisions.jsonl")" ;;
esac
check "C1 #8071 the fix round carries the head and the ticket" "$(jq -r 'select(.pr == 8071) | "\(.action.args.head) \(.action.args.ticket)"' "$C/decisions.jsonl")" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa BH-8070"
for n in 8341 7882 8204 8332; do
  check "C1 #$n owns nothing: U13-INNOCENT requeue" "$(dec_of "$C" $n)" "U13-INNOCENT WOULD_REQUEUE;"
done
check "C1 #8342 file list unread: owns_failure null" "$(jq -r 'select(.pr == 8342) | "\(.owns_failure) \(.inputs_unreadable | index("files") != null)"' "$C/records.jsonl")" "null true"
case "$(dec_of "$C" 8342)" in U13-*) no "C1 #8342 gets no U13 decision" "$(dec_of "$C" 8342)" ;; *) ok "C1 #8342 gets no U13 decision" ;; esac
check "C1 owners and owner_count on every member record" "$(jq -sc '[.[] | select(.kind == "pr-ejected") | "\(.owners | tojson) \(.owner_count)"] | unique' "$C/records.jsonl")" '["[8071] 1"]'
check "C1 5 WOULD lines" "$(grep -c . "$C/would.txt")" 5
budget "$C" C1; kinds_ok "$C" C1

C=$(mkcase c1c batch-8344.json)
run_queue "$C" "export UNBLOCK_BRIEF_MAX_CHARS=200 UNBLOCK_SIGNAL_LINES=1"
check "C1c UNBLOCK_BRIEF_MAX_CHARS=200 cuts the brief to 200" "$(jq -r 'select(.pr == 8071) | .fix_brief | length' "$C/records.jsonl")" 200
check "C1c UNBLOCK_SIGNAL_LINES=1 keeps one line per signal" "$(jq -r 'select(.pr == 8071) | .signals | length' "$C/records.jsonl")" 1
budget "$C" C1c

C=$(mkcase c1b batch-8344.json)
jq --arg p "repos/$R/pulls/8071/files?per_page=100" '.gh[$p] = [{filename: "bin/merge-conductor.sh", status: "modified", patch: "+echo hi"}]' "$C/fx.json" > "$C/fx.new" && mv "$C/fx.new" "$C/fx.json"
run_queue "$C"
check "C1b no owner: 0 U13 act decisions" "$(jq -r 'select((.rule_id // "") | startswith("U13")) | .rule_id' "$C/decisions.jsonl" | grep -c .)" 0
check "C1b every member is owns_failure false, owner_count 0" "$(jq -sc '[.[] | select(.pr != 8342) | "\(.owns_failure) \(.owner_count)"] | unique' "$C/records.jsonl")" '["false 0"]'
budget "$C" C1b

# ═════ C2, C3: empty BLOCK and the carried verdict ═══════════════════════════
C=$(mkcase c2 review-stalls.json)
cp "$FX/logfiles/lead-review-land.txt" "$C/h/logs/lead-review-land.log"
run_queue "$C"
check "C2 #8278 one empty BLOCK: U13-EMPTY" "$(dec_of "$C" 8278)" "U13-EMPTY WOULD_LEAD_REREQUEST;"
check "C2 #8278 re-request args" "$(jq -r 'select(.pr == 8278) | "\(.action.args.request_id) \(.action.args.priority) \(.action.args.notes)"' "$C/decisions.jsonl")" "00000000-0000-0000-0000-000000008278 900 write each finding as a - [BLOCK <class>] line"
check "C2 #8372 two empty BLOCKs: U13-EMPTY-CARD" "$(dec_of "$C" 8372)" "U13-EMPTY-CARD escalate;"
check "C2 another repo's line gives no record" "$(jq -r 'select(.kind == "pr-empty-block") | .pr' "$C/records.jsonl" | sort | tr '\n' ' ')" "8278 8372 "
check "C3 #8136 carried MWN: U13-RESTAMP" "$(dec_of "$C" 8136)" "U13-RESTAMP WOULD_LEAD_REREQUEST;"
check "C3 #8136 request_id none, idle 31" "$(jq -r 'select(.pr == 8136) | "\(.action.args.request_id) \(.evidence.idle_min) \(.evidence.old_head[0:8])"' "$C/decisions.jsonl")" "none 31 3155722a"
budget "$C" C2; kinds_ok "$C" C2
check "C2 empty_block_max is the knob default 1" "$(jq -r 'select(.kind == "pr-empty-block") | .empty_block_max' "$C/records.jsonl" | sort -u)" 1

C=$(mkcase c2b review-stalls.json)
cp "$FX/logfiles/lead-review-land.txt" "$C/h/logs/lead-review-land.log"
run_queue "$C" "export UNBLOCK_EMPTY_BLOCK_MAX=2"
check "C2b UNBLOCK_EMPTY_BLOCK_MAX=2: #8372 (2 lines) is re-requested, no card" "$(dec_of "$C" 8372)" "U13-EMPTY WOULD_LEAD_REREQUEST;"
C=$(mkcase c2c review-stalls.json)
cp "$FX/logfiles/lead-review-land.txt" "$C/h/logs/lead-review-land.log"
run_queue "$C" "export UNBLOCK_EMPTY_BLOCK_MAX=0"
check "C2c UNBLOCK_EMPTY_BLOCK_MAX=0: #8278 (1 line) is a card" "$(dec_of "$C" 8278)" "U13-EMPTY-CARD escalate;"
budget "$C" C2c

C=$(mkcase c3c review-stalls.json)
run_queue "$C" "ubq_verdict_rows() { return 1; }"
check "C3c verdict history unread: one queue-unreadable record for #8136" "$(jq -r 'select(.kind == "queue-unreadable") | "\(.input) \(.pr) \(.subject_kind)"' "$C/records.jsonl")" "verdict-history 8136 pr"
case "$(dec_of "$C" 8136)" in *U13-RESTAMP*) no "C3c no U13-RESTAMP on an unread history" ;; *) ok "C3c no U13-RESTAMP on an unread history" ;; esac
C=$(mkcase c3d review-stalls.json)
run_queue "$C" "ubq_verdict_rows() { echo 'not json'; }"
check "C3d verdict history unparseable: one queue-unreadable record for #8136" "$(jq -r 'select(.kind == "queue-unreadable") | "\(.input) \(.pr)"' "$C/records.jsonl")" "verdict-history 8136"

C=$(mkcase c3b review-stalls.json)
jq '.lead_open.requests = [{pr: 8136, head_sha: ("c7ace3fb" + ("1" * 32)), status: "requested"}]' "$C/fx.json" > "$C/fx.new" && mv "$C/fx.new" "$C/fx.json"
run_queue "$C"
case "$(dec_of "$C" 8136)" in *U13-RESTAMP*) no "C3b an open request: no U13-RESTAMP" "$(dec_of "$C" 8136)" ;; *) ok "C3b an open request: no U13-RESTAMP" ;; esac
check "C3b lead_request_open true" "$(jq -r 'select(.pr == 8136) | .lead_request_open' "$C/records.jsonl")" true
budget "$C" C3b

# ═════ C4, C5: the infra collector ═══════════════════════════════════════════
run_infra() { # run_infra <case dir> <project> <now> <family>
  local C="$1"
  (
    export HARNESS="$C/h" GH_FX="$C/fx.json" GH_LOG="$C/gh.log" MODEL_LOG="$C/model.log" PATH="$T/pathbin:$PATH" GH_ETAG=0 TMPDIR="$C" HARNESS_TEST_SANDBOX=1
    UNBLOCK_NOW=$(date -u -d "$3" +%s); export UNBLOCK_NOW
    . "$HARNESS/bin/lib/gh-rest.sh" || exit 9
    . "$HARNESS/bin/lib/unblock/collectors/infra.sh" || exit 9
    . "$HARNESS/bin/lib/unblock/rules.sh" || exit 9
    [ -n "${5:-}" ] && eval "$5"
    unblock_collect_infra --project "$2" --family "$4" --repo "$R" > "$C/records.jsonl"
    HARNESS="$C/h" ub_rules_eval < "$C/records.jsonl" > "$C/decisions.jsonl"
    ub_rules_would_lines < "$C/decisions.jsonl" > "$C/would.txt"
  )
}
C=$(mkcase c4 review-stalls.json)
cp "$FX/logfiles/pipeline-health.txt" "$C/h/logs/pipeline-health.log"
run_infra "$C" project-6-os "2026-10-26 03:10:00" starve
check "C4 TK-2601 starved: one WOULD_LAUNCH_FASTPATH" "$(grep -c '^WOULD_LAUNCH_FASTPATH U13-STARVE ticket:project-6-os:TK-2601 ' "$C/would.txt") $(grep -c . "$C/would.txt")" "1 1"
check "C4 the fastpath key is TK-2601" "$(jq -r 'select(.rule_id == "U13-STARVE") | .action.args.key' "$C/decisions.jsonl")" TK-2601
check "C4 TK-9 after RESOLVED: 1 pass, no fastpath" "$(jq -r 'select(.ticket == "TK-9") | "\(.passes) \(.queued_min)"' "$C/records.jsonl")" "1 10"
check "C4 subject_kind is build" "$(jq -r .subject_kind "$C/records.jsonl" | sort -u)" build
budget "$C" C4

C=$(mkcase c4b review-stalls.json)
mkdir -p "$C/h/logs/pipeline-health.log"
run_infra "$C" project-6-os "2026-10-26 03:10:00" starve
check "C4b an unreadable pipeline-health log: one source-unreadable record" "$(jq -r '"\(.kind) \(.source)"' "$C/records.jsonl")" "source-unreadable pipeline_health_log"

C=$(mkcase c5 review-stalls.json)
cp "$FX/logfiles/cromford.txt" "$C/h/logs/cromford.log"
jq --arg a "repos/$R/pulls?state=open&head=example-org:ticket/bh-8452.1&per_page=10" --arg b "repos/$R/pulls?state=open&head=example-org:ticket/bh-8476&per_page=10" \
  '.gh[$a] = [] | .gh[$b] = []' "$C/fx.json" > "$C/fx.new" && mv "$C/fx.new" "$C/fx.json"
run_infra "$C" cromford "2026-10-26 19:40:00" reach
check "C5 BH-8452.1: U13-REACH card" "$(jq -r 'select(.evidence.ticket == "BH-8452.1") | "\(.rule_id) \(.decision)"' "$C/decisions.jsonl")" "U13-REACH escalate"
check "C5 BH-8452.1 evidence names the suite and #8481" "$(jq -r 'select(.ticket == "BH-8452.1") | "\(.suites[0]) \(.issue) \(.has_pr) \(.age_min)"' "$C/records.jsonl")" "tests/pr-health-lib.bh-8452-test.sh 8481 false 63"
check "C5 BH-8475 PLAN_BLOCKED: no record" "$(jq -r 'select(.ticket == "BH-8475") | .ticket' "$C/records.jsonl" | grep -c .)" 0
case "$(jq -r 'select(.evidence.ticket == "BH-8476") | .rule_id' "$C/decisions.jsonl")" in U13-REACH) no "C5 BH-8476 at 20 min: no card yet" ;; *) ok "C5 BH-8476 at 20 min: no card yet" ;; esac
budget "$C" C5; kinds_ok "$C" C5

C=$(mkcase c5b review-stalls.json)
mkdir -p "$C/h/logs/cromford.log"
run_infra "$C" cromford "2026-10-26 19:40:00" reach
check "C5b an unreadable project log: one source-unreadable record" "$(jq -r '"\(.kind) \(.source)"' "$C/records.jsonl")" "source-unreadable project_log"
C=$(mkcase c5c review-stalls.json)
cp "$FX/logfiles/cromford.txt" "$C/h/logs/cromford.log"
run_infra "$C" cromford "2026-10-26 19:40:00" reach "export UNBLOCK_DETAIL_MAX_CHARS=50"
check "C5c UNBLOCK_DETAIL_MAX_CHARS=50 cuts the detail" "$(jq -r 'select(.ticket == "BH-8452.1") | .detail | length' "$C/records.jsonl")" 50
C=$(mkcase c5d review-stalls.json)
cp "$FX/logfiles/cromford.txt" "$C/h/logs/cromford.log"
jq --arg a "repos/$R/pulls?state=open&head=example-org:ticket/bh-8452.1&per_page=10" '.gh[$a] = []' "$C/fx.json" > "$C/fx.new" && mv "$C/fx.new" "$C/fx.json"
( . "$SRC/bin/lib/unblock/collect.sh"; export HARNESS="$C/h" GH_FX="$C/fx.json" GH_LOG="$C/gh.log" PATH="$T/pathbin:$PATH" GH_ETAG=0 TMPDIR="$C" HARNESS_TEST_SANDBOX=1
  UNBLOCK_NOW=$(date -u -d "2026-10-26 19:40:00" +%s); export UNBLOCK_NOW
  # A tree with only the infra collector, so ubc_collect runs that one family.
  mkdir -p "$C/hi/logs" && scratch_install_closure bin/lib/unblock/collectors/infra.sh "$C/hi" >/dev/null \
    && scratch_install_closure bin/lib/gh-rest.sh "$C/hi" >/dev/null && cp "$C/h/logs/cromford.log" "$C/hi/logs/" || exit 9
  export HARNESS="$C/hi"
  ubc_collect cromford "$R" "$C/hi/bin/lib/unblock/collectors" > "$C/records.jsonl" )
check "C5d through ubc_collect the repo reaches has_pr (a read, not null)" "$(jq -r 'select(.ticket == "BH-8452.1") | .has_pr' "$C/records.jsonl")" false
check "C5d ubc_collect asked GitHub for the ticket branch PR" "$(grep -c 'head=example-org:ticket/bh-8452.1' "$C/gh.log")" 1

# ═════ A: act.sh ═════════════════════════════════════════════════════════════
H42=$(printf '4%.0s' $(seq 40))
newact() {
  export HARNESS="$T/a-$1" CALLS="$T/a-$1/calls.txt"
  mkdir -p "$HARNESS/bin" "$HARNESS/logs" "$HARNESS/stub"
  : > "$CALLS"
  printf '#!/bin/bash\necho "lead-verdict $*" >> "$CALLS"\nexit 0\n' > "$HARNESS/bin/lead-verdict.sh"
  printf '#!/bin/bash\n[ "$1" = setting-get ] && { cat "$HARNESS/stub/mode"; echo; exit 0; }\nexit 2\n' > "$HARNESS/bin/jobs-client.sh"
  printf '#!/bin/bash\necho "fastpath $*" >> "$CALLS"\n[ -f "$HARNESS/stub/decline" ] || exit 0\necho "$(date -u) FASTPATH-DECLINED $2 :: blocker #77 is open" >> "$HARNESS/logs/$1.log"\necho "$2"\nexit 1\n' > "$HARNESS/bin/launch-fastpath.sh"
  printf '#!/bin/bash\nexit 0\n' > "$HARNESS/bin/lane-alert.sh"
  chmod +x "$HARNESS/bin/"*.sh
  printf '%s' "${2:-act}" > "$HARNESS/stub/mode"
  cat > "$T/a-$1/fx.json" <<EOF
{"gh": {"repos/$R/pulls/42": {"head": {"sha": "$H42"}},
        "repos/$R/issues/42/comments?per_page=100&page=1": [],
        "repos/$R/pulls/42/reviews?per_page=100&page=1": []}, "gh_status": {}}
EOF
  export GH_FX="$T/a-$1/fx.json" GH_LOG="$T/a-$1/gh.log" MODEL_LOG="$T/a-$1/model.log" UNBLOCK_ACT=1
  : > "$GH_LOG"; : > "$MODEL_LOG"
}
mkd() { # mkd <action> <args-json> [project]
  jq -nc --arg n "$1" --argjson a "$2" --arg s "$R" --arg h "$H42" --arg p "${3:-cromford}" \
    '{decision_key: ("k-" + $n), project: $p, repo: $s, subject_kind: "pr", subject: ($s + "#42"), pr: 42, head: $h,
      rule_id: "U13-X", class: "review-rerequest", cites: ["G21"], action: {name: $n, args: $a}}'
}
(
  PATH="$T/pathbin:$PATH"
  . "$SRC/bin/lib/unblock/act.sh" || exit 9
  newact a1
  ub_act "$(mkd lead_rerequest '{"request_id":"none","priority":900}')" >/dev/null; rc=$?
  check "A1 request_id none: done requested" "$rc $UB_ACT_OUTCOME $UB_ACT_DETAIL" "0 done requested"
  check "A1 0 resets, 1 request with --priority 900" "$(grep -c 'lead-verdict reset' "$CALLS") $(grep -c "lead-verdict request $R 42 $H42 --priority 900" "$CALLS")" "0 1"
  newact a2
  ub_act "$(mkd lead_rerequest '{"request_id":"91325b08-2165","priority":900,"notes":"write each finding as a - [BLOCK <class>] line"}')" >/dev/null
  check "A2 reset then request with --notes" "$(grep -c 'lead-verdict reset 91325b08-2165' "$CALLS") $(grep -c -- '--notes write each finding as a - \[BLOCK <class>\] line' "$CALLS") $UB_ACT_OUTCOME" "1 1 done"
  newact a3
  ub_act "$(mkd launch_fastpath '{"key":"TK-2601"}' project-6-os | jq -c '.class = "triage-launch"')" >/dev/null
  check "A3 launch_fastpath launches" "$UB_ACT_OUTCOME $UB_ACT_DETAIL $(grep -c 'fastpath project-6-os TK-2601' "$CALLS")" "done launched 1"
  newact a4; touch "$HARNESS/stub/decline"
  ub_act "$(mkd launch_fastpath '{"key":"TK-2601"}' project-6-os)" >/dev/null
  check "A4 a decline is refused with the reason" "$UB_ACT_OUTCOME $UB_ACT_DETAIL" "refused declined: blocker #77 is open"
  newact a5
  ub_act "$(mkd launch_fastpath '{"key":"TK-2601; rm -rf /"}' project-6-os)" >/dev/null; rc=$?
  check "A5 a bad key is bad input, 0 fastpath calls" "$rc $(grep -c fastpath "$CALLS")" "1 0"
  newact a6 shadow
  ub_act "$(mkd launch_fastpath '{"key":"TK-2601"}' project-6-os)" >/dev/null
  check "A6 shadow: would WOULD_LAUNCH_FASTPATH, 0 calls" "$UB_ACT_OUTCOME $UB_ACT_DETAIL $(grep -c . "$CALLS")" "would WOULD_LAUNCH_FASTPATH 0"
  newact a7
  ub_act "$(mkd lead_rerequest '{"request_id":"none","priority":900,"notes":"a\nb"}' | jq -c '.action.args.notes = "a\nb"')" >/dev/null; rc=$?
  check "A7 a notes value with a newline is bad input" "$rc" 1
  newact a8; mkdir -p "$HARNESS/tbin"
  printf '#!/bin/bash\necho "timeout $1" >> "$CALLS"\nshift\nexec "$@"\n' > "$HARNESS/tbin/timeout"; chmod +x "$HARNESS/tbin/timeout"
  PATH="$HARNESS/tbin:$PATH" UNBLOCK_FASTPATH_TIMEOUT_S=45 ub_act "$(mkd launch_fastpath '{"key":"TK-2601"}' project-6-os)" >/dev/null
  check "A8 UNBLOCK_FASTPATH_TIMEOUT_S=45 bounds the fastpath run" "$(grep -c '^timeout 45$' "$CALLS") $UB_ACT_OUTCOME" "1 done"
  newact a8b; mkdir -p "$HARNESS/tbin"
  printf '#!/bin/bash\necho "timeout $1" >> "$CALLS"\nshift\nexec "$@"\n' > "$HARNESS/tbin/timeout"; chmod +x "$HARNESS/tbin/timeout"
  PATH="$HARNESS/tbin:$PATH" UNBLOCK_FASTPATH_TIMEOUT_S=abc ub_act "$(mkd launch_fastpath '{"key":"TK-2601"}' project-6-os)" >/dev/null
  check "A8b a bad timeout knob is the documented default 300" "$(grep -c '^timeout 300$' "$CALLS")" 1
  newact a9
  printf '#!/bin/bash\necho "fastpath $*" >> "$CALLS"\necho "$(date -u) [$1] DISPATCH-MODE hotfix-only: 1 key(s) wait ($2); allow-list: none" >> "$HARNESS/logs/$1.log"\necho "$2"\nexit 1\n' > "$HARNESS/bin/launch-fastpath.sh"
  ub_act "$(mkd launch_fastpath '{"key":"TK-2601"}' project-6-os)" >/dev/null
  check "A9 a dispatch-mode decline (no per-key line) is refused with that reason" "$UB_ACT_OUTCOME $UB_ACT_DETAIL" "refused declined: DISPATCH-MODE hotfix-only"
  newact a10
  printf '#!/bin/bash\necho "fastpath $*" >> "$CALLS"\nexit 2\n' > "$HARNESS/bin/launch-fastpath.sh"
  ub_act "$(mkd launch_fastpath '{"key":"TK-2601"}' project-6-os)" >/dev/null
  check "A10 any other fastpath rc is failed" "$UB_ACT_OUTCOME $UB_ACT_DETAIL" "failed fastpath rc 2"
  newact a11
  UNBLOCK_NOTES_MAX_CHARS=20 ub_act "$(mkd lead_rerequest '{"request_id":"none","priority":900,"notes":"write each finding as a line"}')" >/dev/null; rc=$?
  check "A11 notes over UNBLOCK_NOTES_MAX_CHARS are bad input" "$rc $(grep -c 'lead-verdict' "$CALLS")" "1 0"
  check "B A: 0 non-GET gh calls" "$(grep -vc '^GET ' "$GH_LOG")" 0
  echo "SUB $PASS $FAIL" > "$T/act.counts"
)
if [ -s "$T/act.counts" ]; then read -r _ PASS FAIL < "$T/act.counts"
else FAIL=$((FAIL + 1)); echo "FAIL A: the act subshell did not finish"; fi

echo "unblock-rules-u13.bh-8390-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
