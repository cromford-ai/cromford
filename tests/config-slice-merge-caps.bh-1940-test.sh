#!/bin/bash
# tests/config-slice-merge-caps.bh-1940-test.sh — BH-1940 (BH-1511.3), the
# merge/review and lane-caps config conversions.
#
# Eight knobs lose their `${VAR:-literal}` and become registry knobs marked
# `required: true`, with the registry default equal to the literal they replace:
#   lane blocked-resolver  BR_MAX_REGEN          1
#   lane review-rescue     RESCUE_PER_TICK       3
#   lane review-rescue     RESCUE_PARALLEL       0 (unlimited)
#   lib  gh-pr-merge       PR_MERGE_REST         1
#   lib  review-post       RP_RAW_CAP            20000
#   lib  review-post       RP_TEXT_CAP           55000
#   lib  lane-caps         LANE_CAPS_SCAN        4000
#   lib  lane-caps         LANE_CAPS_PRICE_MAX   500
# The value then resolves operator row > cached row > env > registry default >
# fail closed, through bin/lib/lane-gate.sh. The lib knobs resolve inside a
# subshell, so a fail-closed exit 75 never takes the calling lane down.
#
#   C0  the base carried none of the eight as a knob (when that commit exists);
#   C1  each is registered required, default == the old literal;
#   C2  no `${VAR:-literal}` read of any of them is left, and each is still read;
#   C3  an operator row wins, through the production entry points;
#   C4  no row: the env; no row and no env: the registry default;
#   C5  worker down + fresh cache: the cached row, a cache log line, no ALERTS;
#   C6  _lib.json and lane-gate.sh are untouched; the three new lib files compose;
#   C7  a row 0 is a value (zero_means honoured, never refilled to the default);
#   C8  LANE_GATE_DISABLE=1 still applies env and default;
#   C9  the non-config reads (RESCUE_ONLY, COST, LANE_CAPS_DAY, LANE_CAPS_CONF)
#       are left alone and are not registered;
#   C10 a required knob with no default fails closed: a lane exits 75, a lib
#       caller survives, and ALERTS gets ONE line per scope a day.
# Run from anywhere: tests/config-slice-merge-caps.bh-1940-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }

# The base this slice started from still carries every literal (A6).
BASE=66d9841

# var <TAB> scope <TAB> id <TAB> file <TAB> old literal
KNOBS="BR_MAX_REGEN	lanes	blocked-resolver	bin/blocked-resolver.sh	1
RESCUE_PER_TICK	lanes	review-rescue	bin/review-rescue.sh	3
RESCUE_PARALLEL	lanes	review-rescue	bin/review-rescue.sh	0
PR_MERGE_REST	libs	gh-pr-merge	bin/lib/gh-pr-merge.sh	1
RP_RAW_CAP	libs	review-post	bin/lib/review-post.sh	20000
RP_TEXT_CAP	libs	review-post	bin/lib/review-post.sh	55000
LANE_CAPS_SCAN	libs	lane-caps	bin/lib/lane-caps.sh	4000
LANE_CAPS_PRICE_MAX	libs	lane-caps	bin/lib/lane-caps.sh	500"

NOW=1758300000
mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/h/flags" "$T/h/catalog"
cp "$DIR/bin/lib/lane-gate.sh" "$T/h/bin/lib/"
REG0="$T/h/catalog/lanes.json"
HARNESS_TEST_SANDBOX=1 bash "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG0" >/dev/null 2>&1 \
  || { echo "FAIL: bin/lanes-build.sh could not render the registry"; exit 1; }

# The stub worker (settings-contract.bh-1511-test.sh): ROWS are operator rows
# as `key=value` words; UNREACHABLE makes every call fail.
cat > "$T/h/bin/stub-jobs-client.sh" <<'SH'
_jobs_req() {
  echo "$1 $2" >> "$CALLS"
  [ -n "${UNREACHABLE:-}" ] && return 1
  local out="[]" kv
  for kv in ${ROWS:-}; do
    out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"console"}]')
  done
  printf '{"settings":%s}' "$out"
}
SH

reset() {
  rm -rf "$T/h/state/lane-gate" "$T/h/flags"; mkdir -p "$T/h/flags"
  rm -f "$T/h/state/settings-cache.json" "$T/h/logs/lane-gate.log" "$T/h/logs/ALERTS.log" \
        "$T/h/logs/lane-caps.log" "$T/plog"
  : > "$T/calls"; ROWS=""; UNREACHABLE=""; REG=""; NOW=1758300000
}
# run <env assignments...> -- <command...>: one process with the stub worker,
# the scratch harness and the rendered registry. Output in $out, rc in $RC.
RC=0
run() {
  local envs=()
  while [ "${1:-}" != "--" ] && [ "$#" -gt 0 ]; do envs+=("$1"); shift; done
  shift
  out=$(env -u RESCUE_PER_TICK -u RESCUE_PARALLEL -u BR_MAX_REGEN -u PR_MERGE_REST \
            -u RP_RAW_CAP -u RP_TEXT_CAP -u LANE_CAPS_SCAN -u LANE_CAPS_PRICE_MAX \
            HARNESS="$T/h" LANE_REGISTRY="${REG:-$REG0}" LANE_GATE_NOW="$NOW" \
            CALLS="$T/calls" ROWS="${ROWS:-}" UNREACHABLE="${UNREACHABLE:-}" DIR="$DIR" T="$T" \
            "${envs[@]}" bash -c '. "$HARNESS/bin/stub-jobs-client.sh"; '"$*" 2>"$T/err"); RC=$?
}
LG='. "$HARNESS/bin/lib/lane-gate.sh";'
RP='. "$DIR/bin/lib/review-post.sh";'
GPM='. "$DIR/bin/lib/gh-pr-merge.sh";'
LC='. "$DIR/bin/lib/lane-caps.sh";'
count() { local n; n=$(grep -c -- "$1" "$2" 2>/dev/null); printf '%s' "${n:-0}"; }

# A review of N chars, and the truncation marker rp_render prints for it.
review() { { printf 'VERDICT: APPROVE\n\n'; head -c "$1" /dev/zero | tr '\0' 'x'; printf '\n'; } > "$T/rev.md"; }
RENDER='rp_render "$T/rev.md" "" "" "$T/body"; echo "rc=$?"; grep -o "truncated at [0-9]* of" "$T/body" || echo "untruncated"'

# A cost ledger of ten $1.00 rows for lane alert-triage on one pinned day.
DAY=2026-09-20
HDR=$( . "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1; printf '%s' "$COST_ROW_HDR" )
NCOL=$(awk -F, '{print NF}' <<<"$HDR")
ledger() { # ledger <n priced rows> <n unpriced rows>
  { printf '%s\n' "$HDR"
    awk -v p="$1" -v u="$2" -v d="$DAY" -v nc="$NCOL" 'BEGIN{
      for (i = 0; i < p + u; i++) {
        r = d "T04:00:00Z,box,alert-triage,triage,openrouter,claude-fable-5.1,0,10,1000,100,0,0," (i < p ? "1.00" : "") ",api,fp,acct,sess,transcript"
        n = split(r, a, ","); while (n < nc) { r = r ","; n++ }
        print r } }'
  } > "$T/h/logs/cost.csv"
}
cat > "$T/prices.json" <<'EOF'
{"per_token": {"claude-fable-5.1": {"prompt": 0.000003, "completion": 0.000015, "cache_read": 3e-7, "cache_write": 0.00000375}}}
EOF
DAYUSD='. "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1; '"$LC"' lane_day_usd alert-triage'
LCENV=("COST=$T/h/logs/cost.csv" "LANE_CAPS_DAY=$DAY" "MODEL_PRICES=$T/prices.json")

echo "--- C0/C1 the registry"
while IFS=$'\t' read -r v scope id f lit; do
  if git -C "$DIR" cat-file -e "$BASE^{commit}" 2>/dev/null; then
    had=$(git -C "$DIR" grep -l "\"env\": \"$v\"" "$BASE" -- catalog/lanes.d 2>/dev/null)
    [ -z "$had" ] && ok || bad "C0 $v was already a knob at $BASE: $had"
    old=$(git -C "$DIR" show "$BASE:$f" 2>/dev/null | grep -o "\${$v:-[0-9]*}" | head -1)
    [ "$old" = "\${$v:-$lit}" ] && ok || bad "C1 the pinned literal for $v is $lit but $BASE:$f reads '$old'"
  else
    echo "note: $BASE is not in this clone; C0 and the literal cross-check are skipped, the pinned literals still assert"
  fi
  got=$(jq -c --arg k "$scope" --arg i "$id" --arg e "$v" \
    '[.[$k][]?|select(.id==$i)|.knobs[]?|select(.env==$e)|{required,default}]' "$REG0")
  [ "$got" = "[{\"required\":true,\"default\":$lit}]" ] && ok \
    || bad "C1 $scope/$id $v must be registered once, required, default $lit: got $got"
done <<<"$KNOBS"

echo "--- C2 no literal left, every var still read"
LINT=$(HARNESS_TEST_SANDBOX=1 bash "$DIR/tests/config-literal-lint.sh" "$DIR" 2>&1)
grep -q 'config-literal-lint:' <<<"$LINT" && ok || bad "C2 the literal lint did not run: $LINT"
HITS=$(printf '%s\n' "$LINT" | grep -E ':(BR_MAX_REGEN|PR_MERGE_REST|RESCUE_PER_TICK|RESCUE_PARALLEL|RP_RAW_CAP|RP_TEXT_CAP|LANE_CAPS_SCAN|LANE_CAPS_PRICE_MAX):')
[ -z "$HITS" ] && ok || bad "C2 the literal lint still lists a slice var: $HITS"
while IFS=$'\t' read -r v scope id f lit; do
  n=$(grep -cE "\\\$\\{$v:?[-=][^}]" "$DIR/$f"); [ "${n:-0}" = 0 ] && ok || bad "C2 $f still has a \${$v:-literal} read"
  n=$(grep -v '^[[:space:]]*#' "$DIR/$f" | grep -cw -- "$v"); [ "${n:-0}" -gt 0 ] && ok || bad "C2 $f no longer reads $v at all"
done <<<"$KNOBS"

echo "--- C3 an operator row wins, through the entry points"
reset; ROWS="lane.review-rescue.rescue_per_tick=7 lane.review-rescue.rescue_parallel=2"
run RESCUE_PER_TICK=9 -- "$LG"' lane_env_apply review-rescue; echo "$RESCUE_PER_TICK $RESCUE_PARALLEL"'
[ "$out" = "7 2" ] && ok || bad "C3 review-rescue rows 7/2 must beat env 9: got '$out'"
reset; ROWS="lane.blocked-resolver.br_max_regen=4"
run BR_MAX_REGEN=1 -- "$LG"' lane_env_apply blocked-resolver; echo "$BR_MAX_REGEN"'
[ "$out" = 4 ] && ok || bad "C3 blocked-resolver row 4 must beat env 1: got '$out'"
reset; ROWS="lib.gh-pr-merge.pr_merge_rest=0"
run PR_MERGE_REST=1 -- "$GPM"' gh_pr_merge_rest o/r 1 "" /dev/null "$T/plog" t; echo "rc=$?"'
[ "$out" = rc=2 ] && ok || bad "C3 row pr_merge_rest=0 must switch the REST ladder off (rc 2): got '$out' $(cat "$T/err")"
grep -q 'switched off' "$T/plog" 2>/dev/null && ok || bad "C3 the off ladder must say so in the pipeline log"
reset; run -- "$GPM"' _gpm_on; echo "rc=$?"'
[ "$out" = rc=0 ] && ok || bad "C3 with no row the REST ladder must stay on: got '$out'"
reset; ROWS="lib.review-post.rp_text_cap=25000"; review 30000
run RP_TEXT_CAP=40000 -- "$RP$RENDER"
[ "$out" = "rc=0
truncated at 25000 of" ] && ok || bad "C3 row rp_text_cap=25000 must cap the review at 25000: got '$out'"
reset; ROWS="lib.review-post.rp_raw_cap=21000"; printf 'VERDICT: BLOCK\nsee finding #3\n' > "$T/rev.md"
head -c 30000 /dev/zero | tr '\0' 'y' >> "$T/rev.md"
run -- "$RP"' rp_render "$T/rev.md" "" "" "$T/body"; echo "rc=$?"; grep -o "truncated at [0-9]* of" "$T/body"'
[ "$out" = "rc=3
truncated at 21000 of" ] && ok || bad "C3 row rp_raw_cap=21000 must cap the raw review of a PARSE_INCOMPLETE at 21000: got '$out'"
reset; ROWS="lib.lane-caps.lane_caps_scan=500"; ledger 1000 0
run "${LCENV[@]}" LANE_CAPS_SCAN=900 -- "$DAYUSD"
[ "$out" = 500.00 ] && ok || bad "C3 row lane_caps_scan=500 must bound the window to 500 rows: got '$out' $(cat "$T/err")"
reset; ROWS="lib.lane-caps.lane_caps_price_max=2"; ledger 0 5
run "${LCENV[@]}" -- "$DAYUSD"
grep -q 'more than 2 unpriced rows' "$T/h/logs/lane-caps.log" 2>/dev/null && ok \
  || bad "C3 row lane_caps_price_max=2 must stop pricing after 2 rows: $(cat "$T/h/logs/lane-caps.log" 2>/dev/null)"

echo "--- C4 env, then the registry default"
reset; review 30000
run RP_TEXT_CAP=26000 -- "$RP$RENDER"
[ "$out" = "rc=0
truncated at 26000 of" ] && ok || bad "C4 env RP_TEXT_CAP=26000 with no row: got '$out'"
reset; review 56000
run -- "$RP$RENDER"
[ "$out" = "rc=0
truncated at 55000 of" ] && ok || bad "C4 no row, no env: the registry default 55000: got '$out'"
reset; ledger 4100 0
run "${LCENV[@]}" -- "$DAYUSD"
[ "$out" = 4000.00 ] && ok || bad "C4 no row, no env: the default window of 4000 rows: got '$out'"
reset; ledger 30 0
run "${LCENV[@]}" LANE_CAPS_SCAN=5 -- "$DAYUSD"
[ "$out" = 5.00 ] && ok || bad "C4 env LANE_CAPS_SCAN=5 with no row: got '$out'"
reset; run PR_MERGE_REST=0 -- "$GPM"' _gpm_on; echo "rc=$?"'
[ "$out" = rc=1 ] && ok || bad "C4 env PR_MERGE_REST=0 with no row must switch the ladder off: got '$out'"
reset; run -- "$LG"' lane_env_apply review-rescue; lane_env_apply blocked-resolver; echo "$RESCUE_PER_TICK $RESCUE_PARALLEL $BR_MAX_REGEN"'
[ "$out" = "3 0 1" ] && ok || bad "C4 no row, no env: the lane defaults 3 0 1: got '$out'"

echo "--- C5 worker down, fresh cache"
reset; ROWS="lib.review-post.rp_text_cap=24000"; review 10; run -- "$RP$RENDER"   # fills the cache
NOW=$(( NOW + 30 )); UNREACHABLE=1; ROWS=""; review 30000
run -- "$RP$RENDER"
[ "$out" = "rc=0
truncated at 24000 of" ] && ok || bad "C5 the cached row must be served with the worker down: got '$out'"
[ ! -s "$T/h/logs/ALERTS.log" ] && ok || bad "C5 a served cache must not page: $(cat "$T/h/logs/ALERTS.log")"
reset; ROWS="lane.review-rescue.rescue_per_tick=6"; run -- "$LG"' lane_env_apply review-rescue'
NOW=$(( NOW + 600 )); UNREACHABLE=1; ROWS=""
run -- "$LG"' lane_env_apply review-rescue; echo "$RESCUE_PER_TICK"'
[ "$out" = 6 ] && ok || bad "C5 the cached lane row must be served with the worker down: got '$out'"
[ "$(count 'served from the box cache' "$T/h/logs/lane-gate.log")" = 1 ] && ok \
  || bad "C5 the cache must be said once in lane-gate.log: $(cat "$T/h/logs/lane-gate.log" 2>/dev/null)"
[ ! -s "$T/h/logs/ALERTS.log" ] && ok || bad "C5 a served lane cache must not page"

echo "--- C6 what is and is not touched"
# Against the merge base, not origin/main's tip: main moves under a branch, and
# a sibling's edit there is not this slice's.
# Own slice ONLY (the BH-983 A11 pattern): a later ticket that edits lane-gate.sh
# or _lib.json for its OWN work (BH-2327's per-box lane switch did) must not be
# judged by BH-1940's "untouched" rule, and a Mergify batch carries sibling PRs'
# files. So C6/C6b bite only when this branch carries BH-1940's own spec.
MB=$(git -C "$DIR" merge-base origin/main HEAD 2>/dev/null)
C6REF="${GITHUB_HEAD_REF:-$(git -C "$DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)}"
C6OWN=0
if [ -n "$MB" ]; then
  # pr-scoped: ok slice-gated: inert unless this branch carries BH-1940's own slice
  C6FILES=$(git -C "$DIR" diff --name-only "$MB" HEAD 2>/dev/null)
  grep -qE '^\.harness/specs/BH-1940/' <<<"$C6FILES" && C6OWN=1
fi
case "$C6REF" in mergify/merge-queue/*) C6OWN=0 ;; esac
if [ -n "$MB" ] && [ "$C6OWN" = 0 ]; then
  echo "SKIP (scoped): C6/C6b judge only BH-1940's own branch; this diff is another ticket's"
elif [ -n "$MB" ]; then
  # pr-scoped: ok slice-gated: inert unless this branch carries BH-1940's own slice
  git -C "$DIR" diff --quiet "$MB" -- catalog/lanes.d/_lib.json && ok || bad "C6 catalog/lanes.d/_lib.json must not change"
  # pr-scoped: ok slice-gated: inert unless this branch carries BH-1940's own slice
  git -C "$DIR" diff --quiet "$MB" -- bin/lib/lane-gate.sh && ok || bad "C6b bin/lib/lane-gate.sh must not change"
else
  echo "note: no origin/main in this clone; C6/C6b are skipped"
fi
for id in gh-pr-merge review-post lane-caps; do
  [ -f "$DIR/catalog/lanes.d/_lib.$id.json" ] && ok || bad "C6 catalog/lanes.d/_lib.$id.json is missing"
  [ "$(jq --arg i "$id" '[.libs[]|select(.id==$i)]|length' "$REG0")" = 1 ] && ok || bad "C6 lib $id must compose exactly once"
done
[ "$(jq '[.libs[]|select(.id=="wake-lanes")]|length' "$REG0")" = 1 ] && ok || bad "C6 the _lib.json libs must still compose"

echo "--- C7 a row 0 is a value"
reset; ROWS="lane.review-rescue.rescue_parallel=0 lane.blocked-resolver.br_max_regen=0"
run RESCUE_PARALLEL=5 BR_MAX_REGEN=2 -- "$LG"' lane_env_apply review-rescue; lane_env_apply blocked-resolver; echo "$RESCUE_PARALLEL $BR_MAX_REGEN $(lane_knob_zero_means review-rescue RESCUE_PARALLEL)"'
[ "$out" = "0 0 unlimited" ] && ok || bad "C7 rows 0 must export 0 (unlimited / off), not the default: got '$out'"
reset; ROWS="lane.review-rescue.rescue_parallel.unlimited=1"
run RESCUE_PARALLEL=5 -- "$LG"' lane_env_apply review-rescue; echo "$RESCUE_PARALLEL"'
[ "$out" = 0 ] && ok || bad "C7 a .unlimited row must resolve to 0: got '$out'"

echo "--- C8 LANE_GATE_DISABLE=1 keeps env and default"
reset; run LANE_GATE_DISABLE=1 RESCUE_PER_TICK=5 -- "$LG"' lane_env_apply review-rescue; echo "$RESCUE_PER_TICK"'
[ "$out" = 5 ] && ok || bad "C8 env under LANE_GATE_DISABLE=1: got '$out'"
reset; run LANE_GATE_DISABLE=1 -- "$LG"' lane_env_apply review-rescue; echo "$RESCUE_PER_TICK"'
[ "$out" = 3 ] && ok || bad "C8 default under LANE_GATE_DISABLE=1: got '$out'"
reset; ROWS="lib.review-post.rp_text_cap=25000"; review 30000
run LANE_GATE_DISABLE=1 -- "$RP$RENDER"
[ "$out" = "rc=0
truncated at 25000 of" ] && ok || bad "C8 a lib row still applies under LANE_GATE_DISABLE=1: got '$out'"

echo "--- C9 the non-config reads are left alone"
grep -qF 'RESCUE_ONLY="${RESCUE_ONLY:-}"' "$DIR/bin/review-rescue.sh" && ok || bad "C9 RESCUE_ONLY read changed"
for s in '${COST:-$_LC_H/logs/cost.csv}' '${LANE_CAPS_DAY:-$(date' '${LANE_CAPS_CONF:-}'; do
  grep -qF -- "$s" "$DIR/bin/lib/lane-caps.sh" && ok || bad "C9 lane-caps.sh no longer reads $s"
done
for v in COST LANE_CAPS_DAY LANE_CAPS_CONF RESCUE_ONLY; do
  [ "$(jq --arg e "$v" '[(.lanes[]?,.libs[]?)|.knobs[]?|select(.env==$e)]|length' "$REG0")" = 0 ] && ok \
    || bad "C9 $v must not be registered"
done

echo "--- C10 fail closed"
REGX="$T/stripped.json"
jq '(.lanes[]?,.libs[]?) |= (.knobs |= map(if (.env|IN("BR_MAX_REGEN","RESCUE_PER_TICK","RESCUE_PARALLEL","PR_MERGE_REST","RP_RAW_CAP","RP_TEXT_CAP","LANE_CAPS_SCAN","LANE_CAPS_PRICE_MAX")) then del(.default) else . end))' \
  "$REG0" > "$REGX"
reset; REG="$REGX"
run -- "$LG"' lane_env_apply review-rescue; echo BODY-RAN'
[ "$RC" = 75 ] && [ -z "$out" ] && ok || bad "C10 review-rescue with no default must exit 75 before its body: rc=$RC out='$out'"
run -- "$LG"' lane_env_apply review-rescue; echo BODY-RAN'
[ "$RC" = 75 ] && ok || bad "C10 the second tick must exit 75 too: rc=$RC"
review 30000
for i in 1 2; do
  run -- "$RP$RENDER"' ; echo SURVIVED'
  case "$out" in *SURVIVED) ok ;; *) bad "C10 rp_render's caller must survive a fail-closed lib (call $i): rc=$RC out='$out'" ;; esac
  run -- "$GPM"' _gpm_on; echo "rc=$?"; echo SURVIVED'
  case "$out" in *SURVIVED) ok ;; *) bad "C10 _gpm_on's caller must survive a fail-closed lib (call $i): rc=$RC out='$out'" ;; esac
  ledger 3 0
  run "${LCENV[@]}" -- "$DAYUSD"'; echo SURVIVED'
  case "$out" in *SURVIVED) ok ;; *) bad "C10 lane_day_usd's caller must survive a fail-closed lib (call $i): rc=$RC out='$out'" ;; esac
done
for sc in 'review-rescue did NOT run' 'review-post did NOT run' 'gh-pr-merge did NOT run' 'lane-caps did NOT run'; do
  [ "$(count "$sc" "$T/h/logs/ALERTS.log")" = 1 ] && ok \
    || bad "C10 exactly ONE ALERTS line for '$sc' after two calls, got $(count "$sc" "$T/h/logs/ALERTS.log")"
done
grep -q 'did NOT run: required knob(s)' "$T/h/logs/ALERTS.log" 2>/dev/null && ok || bad "C10 the ALERTS line must name the required knobs"

echo "--- C11 a lib copied where nothing resolves its knobs"
# A box whose sync landed the library before its registry file, and the suites
# that copy the lib into a bare tree: no lane-gate, no registry, no checkout
# file next to it. A spend bound that cannot resolve must read MORE, never $0.00,
# or the daily cap never fires.
mkdir -p "$T/bare/bin/lib" "$T/bare/logs" "$T/bare/flags"
cp "$DIR/bin/lib/lane-caps.sh" "$T/bare/bin/lib/"; cp "$T/h/bin/stub-jobs-client.sh" "$T/bare/bin/"
reset; ledger 10 0; cp "$T/h/logs/cost.csv" "$T/bare/logs/cost.csv"
run HARNESS="$T/bare" COST="$T/bare/logs/cost.csv" LANE_CAPS_DAY="$DAY" LANE_REGISTRY="$T/none.json" -- \
  '. "$HARNESS/bin/lib/lane-caps.sh"; lane_day_usd alert-triage'
[ "$out" = 10.00 ] && ok || bad "C11 an unresolved scan bound must read the whole ledger (want 10.00): got '$out' $(cat "$T/err")"
grep -q 'unresolved' "$T/bare/logs/lane-caps.log" 2>/dev/null && ok \
  || bad "C11 the unresolved bound must be said in the lane log: $(cat "$T/bare/logs/lane-caps.log" 2>/dev/null)"

echo "config-slice-merge-caps: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
