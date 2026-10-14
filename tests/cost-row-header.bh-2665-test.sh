#!/bin/bash
# tests/cost-row-header.bh-2665-test.sh — the cost row's 26th column, guard_fp
# (BH-2537 slice 1, BH-2665), end to end on the shell side.
#
# guard_fp is the pre-call guard's input fingerprint. No writer emits it in this
# slice; what this suite pins is that every place a cost row is STORED or
# CARRIED knows the 26th name, so the writer sibling can start filling it
# without a column being dropped on the way (the BH-1032 lesson: the mirror's
# COLS list is a truncation point).
#
#   T1h  a fresh file gets the 26-name header ending lane_id,guard_fp
#   T6   a 25-name file is upgraded once; its old row stays byte-identical
#   T6b  a second append does not upgrade a 26-name header again
#   T4   ticket falls back COST_KEY -> AGENT_CALL_TICKET -> HARNESS_TICKET
#   T4b  pr falls back COST_PR -> AGENT_CALL_PR
#   T4c  cost_row_guard_fp reads $COST_GUARD_FP through cost_csv_field
#   T3r  cost-rows-read.sh's fallback header (COST_ROW_HDR unset) is 26 names
#   T8   the DB mirror's chunk carries guard_fp, null for a 25-field row
#   T9   schema.sql puts no index on guard_fp
#   W    the worker half (POST/GET columns, the lane-dedup route stub) runs
#        as worker/jobs/test/cost-row-identity.bh-2665.test.js when node has
#        node:sqlite; this suite runs it when it can.
# Run from anywhere: tests/cost-row-header.bh-2665-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
"$DIR/bin/llm-sites-build.sh" --compose --repo "$DIR" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
mkdir -p "$T/locks" "$T/bin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

HDR25="ts,host,project,stage,runner,model,rc,duration_s,input_toks,output_toks,cache_read,cache_write,cost_usd,billing_mode,auth_fp,auth_account,session_id,row_source,result_usd,ticket,job_id,pr,run_id,note,lane_id"
HDR26="$HDR25,guard_fp"
ROW25="2026-09-26T10:00:00Z,h,p,review,claude,m,0,1,1,1,0,0,0.50,api,fp,acct,s,transcript,0.5,K-1,,,,,lane-a"

# Every function under test comes from the real file, sourced, in a subshell
# per case so no env var leaks between cases.
LIB="$DIR/bin/lib/cost-row.sh"
HARNESS="$T"; export HARNESS

# --- T1h ---------------------------------------------------------------------
( . "$LIB"; COST="$T/t1.csv"; printf '%s\n' "$COST_ROW_HDR" > "$COST"; cost_append "$ROW25" )
[ "$(head -1 "$T/t1.csv")" = "$HDR26" ] && ok \
  || bad "T1h: fresh header is not the 26-name literal: $(head -1 "$T/t1.csv")"
[ "$(head -1 "$T/t1.csv" | awk -F, '{print NF, $26}')" = "26 guard_fp" ] && ok \
  || bad "T1h: header column 26 is not guard_fp"

# --- T6 / T6b ----------------------------------------------------------------
printf '%s\n%s\n' "$HDR25" "$ROW25" > "$T/t6.csv"
( . "$LIB"; COST="$T/t6.csv"; cost_append "NEW-ROW-1" )
[ "$(sed -n 1p "$T/t6.csv")" = "$HDR26" ] && ok \
  || bad "T6: 25-name header not upgraded to 26: $(sed -n 1p "$T/t6.csv")"
[ "$(sed -n 2p "$T/t6.csv")" = "$ROW25" ] && ok || bad "T6: old row changed by the upgrade"
[ "$(sed -n 3p "$T/t6.csv")" = "NEW-ROW-1" ] && ok || bad "T6: appended row is not line 3"
( . "$LIB"; COST="$T/t6.csv"; cost_append "NEW-ROW-2" )
[ "$(grep -c '^ts,host,' "$T/t6.csv")" = 1 ] && ok || bad "T6b: more than one header line"
[ "$(sed -n 1p "$T/t6.csv")" = "$HDR26" ] && ok \
  || bad "T6b: a 26-name header was rewritten: $(sed -n 1p "$T/t6.csv")"
[ "$(wc -l < "$T/t6.csv")" = 4 ] && ok || bad "T6b: expected 4 lines, got $(wc -l < "$T/t6.csv")"

# --- T4 / T4b / T4c ----------------------------------------------------------
tags() { ( unset COST_KEY AGENT_CALL_TICKET HARNESS_TICKET COST_PR AGENT_CALL_PR COST_JOB JOB_ID COST_RUN_ID
           for kv in "$@"; do export "${kv?}"; done; . "$LIB"; cost_row_tags ); }
[ "$(tags COST_KEY=K AGENT_CALL_TICKET=T | cut -d, -f1)" = K ] && ok || bad "T4: COST_KEY must win over AGENT_CALL_TICKET"
[ "$(tags AGENT_CALL_TICKET=T | cut -d, -f1)" = T ] && ok || bad "T4: AGENT_CALL_TICKET alone must give T"
[ "$(tags HARNESS_TICKET=H | cut -d, -f1)" = H ] && ok || bad "T4: HARNESS_TICKET alone must give H"
[ "$(tags AGENT_CALL_TICKET=T HARNESS_TICKET=H | cut -d, -f1)" = T ] && ok \
  || bad "T4: AGENT_CALL_TICKET must win over HARNESS_TICKET"
[ "$(tags AGENT_CALL_PR=https://github.com/o/r/pull/5 | cut -d, -f3)" = "https://github.com/o/r/pull/5" ] && ok \
  || bad "T4b: AGENT_CALL_PR must fill the pr field"
[ "$(tags COST_PR=X AGENT_CALL_PR=Y | cut -d, -f3)" = X ] && ok || bad "T4b: COST_PR must win over AGENT_CALL_PR"
[ "$(tags | awk -F, '{print NF}')" = 4 ] && ok || bad "T4: cost_row_tags must stay 4 fields"

gfp() { ( unset COST_GUARD_FP; [ $# -gt 0 ] && export COST_GUARD_FP="$1"; . "$LIB"; cost_row_guard_fp ); }
[ "$(gfp abc)" = abc ] && ok || bad "T4c: COST_GUARD_FP=abc must print abc, got '$(gfp abc)'"
[ -z "$(gfp)" ] && ok || bad "T4c: unset COST_GUARD_FP must print empty"
[ "$(gfp 'a,b')" = "a b" ] && ok || bad "T4c: a comma must not widen the row, got '$(gfp 'a,b')'"

# --- T3r ---------------------------------------------------------------------
H3=$( unset COST_ROW_HDR; . "$DIR/bin/lib/cost-rows-read.sh" >/dev/null 2>&1; printf '%s' "${COST_ROWS_READ_HDR:-}" )
[ "$H3" = "$HDR26" ] && ok || bad "T3r: COST_ROWS_READ_HDR fallback is not the 26-name header: $H3"

# --- T8 ----------------------------------------------------------------------
if command -v python3 >/dev/null && command -v jq >/dev/null; then
  printf '%s\n%s,fp-abc\n%s\n' "$HDR26" "$ROW25" "$ROW25" > "$T/t8.csv"
  ( . "$DIR/bin/lib/jobs/cost.sh"; _metric_cost_rows_chunk "$T/t8.csv" 0 100 hub "$T/t8.json" ) > /dev/null
  [ "$(jq -r '.rows[0].guard_fp' "$T/t8.json" 2>/dev/null)" = fp-abc ] && ok \
    || bad "T8: 26-field row lost guard_fp on the mirror: $(jq -c '.rows[0]' "$T/t8.json" 2>/dev/null)"
  [ "$(jq -c '.rows[1] | has("guard_fp"), .guard_fp' "$T/t8.json" 2>/dev/null | tr '\n' ' ')" = "true null " ] && ok \
    || bad "T8: 25-field row must carry guard_fp: null"
  [ "$(jq -r '.rows[0].lane_id' "$T/t8.json" 2>/dev/null)" = lane-a ] && ok || bad "T8: lane_id moved"
else
  echo "SKIP T8: python3/jq missing"
fi

# --- T9 ----------------------------------------------------------------------
if grep -Ei 'index.*guard_fp' "$DIR/worker/jobs/schema.sql" >/dev/null; then
  bad "T9: schema.sql indexes guard_fp (harness-sync applies it before ensureColumns adds the column)"
else ok; fi
grep -q '^  guard_fp TEXT,' "$DIR/worker/jobs/schema.sql" && ok || bad "T9: schema.sql cost_rows has no guard_fp column"

# --- W: the worker half, through the real worker.fetch -----------------------
DEDUP_SRC="$DIR/worker/jobs/src/lib/lane-dedup.js"
[ -f "$DEDUP_SRC" ] && ok || bad "W: $DEDUP_SRC missing"
if node -e "require('node:sqlite')" 2>/dev/null; then
  # worker/jobs imports the generated, git-ignored catalog/lanes.json (BH-1247).
  [ -r "$DIR/catalog/lanes.json" ] || (cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/lanes-build.sh --write >/dev/null 2>&1)
  ( cd "$DIR/worker/jobs" && node --test test/cost-row-identity.bh-2665.test.js ) > "$T/w.out" 2>&1 \
    && ok || { bad "W: worker/jobs/test/cost-row-identity.bh-2665.test.js failed"; grep -E '^not ok|# (pass|fail)' "$T/w.out"; }
else
  echo "SKIP W: node:sqlite not available"
fi

echo "cost-row-header.bh-2665: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
