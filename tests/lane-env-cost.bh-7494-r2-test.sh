#!/bin/bash
# tests/lane-env-cost.bh-7494-r2-test.sh — BH-7494 r2: one `lane_env_apply` does
# a bounded amount of shell work, and what it exports is unchanged.
#
# #7499 cut the settings loader. What was left of one `lane_env_apply fly-pool
# <project>` on the hub (about 2.3-2.6 s at load5 70) was _lg_lower (a character
# loop per knob name), _lg_km_load (nine `read -d ''` and eight `printf -v` per
# knob), _lr_stamp (a `tr` fork, run once per subshell because the registry memo
# was lost), and a fork or two per knob read in _lg_setting_key and _lg_now.
#
# The bounds are COMMAND and FORK COUNTS (a DEBUG trap, an xtrace line count,
# PATH shims that count programs), never a clock. Fixture: a 72-knob lane and a
# 553-key settings cache, the shape of the hub's fly-pool.
#
#   C1  _lg_km_load of the 72-knob lane: at most 60 shell commands, exactly 1 jq.
#   C2  _lg_lower of one name: at most 8 commands on bash 4+ (the loop on 3.2).
#   C3  _lg_setting_key: no tr, no fork (bash 4+).
#   C4  one lane_env_apply from a real root: lanes_json_path resolves ONCE
#       (one cksum, one find), and the clock is not forked (bash 5).
#   C5  one lane_env_apply: at most 12,000 traced lines and 60 processes (bash 5;
#       the xtrace file needs 4.1+, so 3.2 skips it). The hub-shaped base: 16,686 and 352.
#   E1  the memo _lg_km_load builds is the one the old loader built: same env
#       list (first record wins, a non-shell name listed once and not memoised),
#       same eight fields per knob.
#   E2  _lg_lower equals `tr A-Z a-z` for words with digits, `_`, mixed case.
#   E3  the exports of lane_env_apply (5 lane/project pairs and one lib) are
#       byte for byte the golden file written by the BH-7494 (#7499) library.
#
# Run: bash tests/lane-env-cost.bh-7494-r2-test.sh   (exit 0 = all pass)
#      /bin/bash tests/lane-env-cost.bh-7494-r2-test.sh   (macOS 3.2)
# Regenerate the golden (only from the library the change started from):
#      GEN_GOLDEN=1 bash tests/lane-env-cost.bh-7494-r2-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
GOLDEN="$DIR/tests/fixtures/lane-env-cost.bh-7494-r2.golden"
NOW=1758300000
H="$T/h"; REG="$T/registry.json"; SC="$H/state/settings-cache.json"; SHIM="$T/shim"
mkdir -p "$H/state" "$H/logs" "$H/flags" "$SHIM"
BV=${BASH_VERSINFO[0]}

# --- fixture: registry --------------------------------------------------------
jq -n '
  def knob($n): "CK_" + ($n | tostring | if length < 2 then "0" + . else . end);
  {lanes: [
    {id: "cost-lane", knobs: (
      [range(0; 72) | . as $n | {env: knob($n)}
        + (if $n % 5 == 0 then {default: ($n + 1), min: 1, max: 40} else {default: $n} end)
        + (if $n % 9 == 0 then {settable: false} else {} end)
        + (if $n % 7 == 0 then {required: true} else {} end)
        + (if $n == 3 then {zero_means: "unlimited"} elif $n == 4 then {zero_means: "off"} else {} end)]
      + [{env: "CK_01", default: "second record loses"},
         {env: "NOT-A-NAME", default: "x"}, {env: "NOT-A-NAME", default: "y"},
         {env: "CK_TEXT", default: "a b|c"}])},
    {id: "other-lane", knobs: [{env: "OL_A", default: 1}]}],
   libs: [{id: "cost-lib", knobs: [{env: "CL_A", default: 2, min: 0, max: 9}, {env: "CL_B", required: true, default: "rq"}]}]}' > "$REG"

# --- fixture: settings cache (553 keys) --------------------------------------
jq -nc --argjson fa "$NOW" '{fetched_at: $fa, values: (
  ([range(0; 540) | {key: ("lane.other-lane.filler_\(.)"), value: "v\(.)"}] | from_entries)
  + {"lane.cost-lane.ck_05": "99", "lane.cost-lane.p.ck_05": "7", "lane.cost-lane.ck_10": "x y  z",
     "lane.cost-lane.ck_03": "12", "lane.cost-lane.ck_03.unlimited": "1",
     "lane.cost-lane.ck_04": "12", "lane.cost-lane.ck_04.unlimited": "1",
     "lane.cost-lane.ck_09": "evil", "lane.cost-lane.ck_text": "t|u\\v",
     "lane.cost-lane.ck_11": "", "lane.cost-lane.p.ck_12": "8",
     "lane.cost-lane.ck_20": "0", "lane.cost-lane.ck_25": "-5",
     "lib.cost-lib.cl_a": "9", "lane.cost-lane.single_run": "off"}), seeded: {}}' > "$SC"

# --- shims: count programs a lane would fork ----------------------------------
for prog in jq tr cksum find date; do
  real=$(command -v "$prog") || continue
  printf '#!/bin/bash\necho %s >> "%s/calls"\nexec %s "$@"\n' "$prog" "$T" "$real" > "$SHIM/$prog"
  chmod +x "$SHIM/$prog"
done
calls() { if [ -f "$T/calls" ]; then grep -c "^$1\$" "$T/calls" || true; else echo 0; fi; }

# run <script> — fresh bash, the real lib sourced, fixture registry and cache,
# the clock pinned to the cache so no lane asks the worker.
run() {
  : > "$T/calls"
  PATH="$SHIM:$PATH" HARNESS="$H" LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW" \
    "$BASH" -c '. "$1/bin/lib/lane-gate.sh"; eval "$2"' _ "$DIR" "$1" 2>&1
}
CNT='_C=0; trap '"'"'_C=$((_C+1))'"'"' DEBUG; set -T'

# --- C1: the registry loader ---------------------------------------------------
out=$(run "$CNT; _lg_km_load \"\$LANE_REGISTRY\" lanes cost-lane; trap - DEBUG; echo \"cmds=\$_C\"")
cmds=${out##*cmds=}; cmds=${cmds%% *}
case "$cmds" in ''|*[!0-9]*) bad "C1 no command count: $out" ;;
  *) if [ "$cmds" -le 60 ]; then ok; else bad "C1 _lg_km_load ran $cmds commands (bound 60)"; fi ;;
esac
if [ "$(calls jq)" = 1 ]; then ok; else bad "C1 _lg_km_load ran $(calls jq) jq (want 1)"; fi

# --- C2: lowercase -------------------------------------------------------------
out=$(run "$CNT; _lg_lower CK_TEXT_WORD_01; trap - DEBUG; echo \"cmds=\$_C low=\$_LG_LOW\"")
cmds=${out##*cmds=}; cmds=${cmds%% *}
if [ "$BV" -ge 4 ]; then
  if [ "$cmds" -le 8 ] 2>/dev/null; then ok; else bad "C2 _lg_lower ran $cmds commands (bound 8): $out"; fi
else ok; fi

# --- C3: the setting key -------------------------------------------------------
out=$(run 'k=$(_lg_setting_key cost-lane CK_05 p); echo "got=$k"')
case "$out" in *"got=lane.cost-lane.p.ck_05"*) ok ;; *) bad "C3 key wrong: $out" ;; esac
if [ "$BV" -ge 4 ]; then
  out=$(run '_lg_setting_key cost-lane CK_05 >/dev/null; _lg_setting_key cost-lane CK_05 p >/dev/null')
  if [ "$(calls tr)" = 0 ]; then ok; else bad "C3 _lg_setting_key ran tr $(calls tr) times"; fi
else ok; fi
out=$(run '_LG_KIND=libs; echo "key=$(_lg_setting_key cost-lib CL_A)"')
case "$out" in *"key=lib.cost-lib.cl_a"*) ok ;; *) bad "C3 libs key wrong: $out" ;; esac

# --- C4: a real root: the registry is resolved once ---------------------------
R="$T/root"; mkdir -p "$R/catalog/lanes.d" "$R/bin/lib" "$R/state" "$R/logs" "$R/flags" "$T/tmp"
( cd "$DIR" && scratch_install_closure bin/lanes-build.sh "$R" && scratch_install_closure bin/lib/lanes-registry.sh "$R" ) >/dev/null \
  || { echo "setup: could not install the lanes-build closure"; exit 1; }
for f in "$DIR"/catalog/lanes.d/*.json; do cp "$f" "$R/catalog/lanes.d/"; done
cp "$SC" "$R/state/settings-cache.json"
ONE=fly-pool; sleep 3   # determinism: ok the copies must age past a stamp 2 s old by the wall clock; the clock is the only condition to wait on
: > "$T/calls"
PATH="$SHIM:$PATH" HARNESS="$R" LANE_GATE_NOW="$NOW" TMPDIR="$T/tmp" \
  "$BASH" -c '. "$1/bin/lib/lane-gate.sh"; lane_env_apply "$2" p' _ "$DIR" "$ONE" >/dev/null 2>&1 || :
: > "$T/calls"
PATH="$SHIM:$PATH" HARNESS="$R" LANE_GATE_NOW="$NOW" TMPDIR="$T/tmp" \
  "$BASH" -c '. "$1/bin/lib/lane-gate.sh"; lane_env_apply "$2" p' _ "$DIR" "$ONE" >/dev/null 2>&1 || :
if [ "$(calls cksum)" -le 1 ]; then ok; else bad "C4 cksum ran $(calls cksum) times in one lane_env_apply (want 1)"; fi
if [ "$(calls find)" -le 1 ]; then ok; else bad "C4 find ran $(calls find) times (want 1)"; fi
if [ "$BV" -ge 5 ]; then
  if [ "$(calls date)" = 0 ]; then ok; else bad "C4 date forked $(calls date) times on bash 5"; fi
fi

# --- C5: the whole call -------------------------------------------------------
cat > "$T/trace.sh" <<'SH'
. "$LG" || exit 3
exec 9> "$TRACE"; BASH_XTRACEFD=9
PS4='+ $BASHPID ${FUNCNAME[0]:-main} '
set -x
lane_env_apply cost-lane p
set +x
SH
PATH="$SHIM:$PATH" HARNESS="$H" LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW" LG="$DIR/bin/lib/lane-gate.sh" \
  TRACE="$T/trace.out" "$BASH" "$T/trace.sh" >/dev/null 2>&1 || :
lines=$(wc -l < "$T/trace.out" | tr -d ' ')
pids=$(awk '{print $2}' "$T/trace.out" | sort -u | wc -l | tr -d ' ')
echo "info: lane_env_apply cost-lane p: $lines traced lines, $pids processes (bash $BASH_VERSION)"
LB=12000; PB=60
if [ "$BV" -lt 5 ]; then :; elif [ "$lines" -le "$LB" ]; then ok; else bad "C5 one lane_env_apply traced $lines lines (bound $LB)"; fi
if [ "$BV" -lt 5 ]; then :; elif [ "$pids" -le "$PB" ]; then ok; else bad "C5 one lane_env_apply ran in $pids processes (bound $PB)"; fi

# --- E1: the registry memo ----------------------------------------------------
out=$(run '_lg_km_load "$LANE_REGISTRY" lanes cost-lane; _lg_km_triple "$LANE_REGISTRY" lanes cost-lane; t=$_LG_MI
  b="_LG_KM_E_$t"; printf "envs=%s\n" "$(printf "%s" "${!b}" | tr "\n" ",")"
  g() { n="_LG_KM_${t}_$1_$2"; printf "%s.%s=[%s]\n" "$1" "$2" "${!n-<unset>}"; }
  g default CK_01; g sa CK_09; g sk CK_09; g rq CK_07; g rq CK_08; g ad CK_05; g min CK_05; g max CK_05
  g zero_means CK_03; g zero_means CK_04; g default CK_TEXT; g sa CK_10; g sk CK_10; g ad CK_10
  printf "bad=%s\n" "$(compgen -v | grep -c NOT_A_NAME)"')
want_envs=$(jq -r '[.lanes[0].knobs[].env] | reduce .[] as $e ([]; if index($e) then . else . + [$e] end) | map(. + ",") | join("")' "$REG")
case "$out" in *"envs=$want_envs"*) ok ;; *) bad "E1 env list differs: $out" ;; esac
for w in 'default.CK_01=[1]' 'sa.CK_09=[false]' 'sk.CK_09=[false]' 'rq.CK_07=[true]' 'rq.CK_08=[false]' \
         'ad.CK_05=[6]' 'min.CK_05=[1]' 'max.CK_05=[40]' 'zero_means.CK_03=[unlimited]' 'zero_means.CK_04=[off]' \
         'default.CK_TEXT=[a b|c]' 'sa.CK_10=[true]' 'sk.CK_10=[true]' 'ad.CK_10=[11]' 'bad=0'; do
  case "$out" in *"$w"*) ok ;; *) bad "E1 memo lacks $w: $out" ;; esac
done

# --- E2: lowercase equals tr --------------------------------------------------
for w in CK_00 MK_CLAMP_X1 aBc_09 "" 0 ZZZ_ABC_; do
  want=$(printf '%s' "$w" | tr 'A-Z' 'a-z')
  got=$(run "_lg_lower '$w'; printf '%s' \"\$_LG_LOW\"")
  if [ "$got" = "$want" ]; then ok; else bad "E2 _lg_lower '$w' = '$got' (want '$want')"; fi
done

# --- E3: the exports are the old library's ------------------------------------
# exports <kind> <id> <project> — what the call exports, rc and the log lines.
exports() {
  run "$1_env_apply $2 ${3:-}; echo rc=\$?; export -p | grep -E ' (CK_|CL_)'" | grep -v '^$'
}
dump() {
  for c in "lane cost-lane p" "lane cost-lane q" "lane cost-lane" "lane other-lane p" "lib cost-lib p"; do
    echo "== $c"; exports $c
  done
  # The reader the exports go through, knob by knob: clamp, .unlimited, a row
  # on a settable:false knob, a name that is not a shell name, text values.
  echo "== lane_knob"
  run 'for k in CK_01 CK_03 CK_04 CK_05 CK_09 CK_10 CK_11 CK_12 CK_20 CK_25 CK_70 CK_TEXT CK_NONE; do
         for p in "" p q; do printf "%s/%s=[%s]" "$k" "$p" "$(lane_knob cost-lane "$k" "$p")"
           lane_knob_settable cost-lane "$k"; printf " set=%s" "$?"
           lane_knob_unlimited cost-lane "$k" "$p"; printf " unl=%s\n" "$?"; done; done
         printf "zm=[%s][%s]\n" "$(lane_knob_zero_means cost-lane CK_03)" "$(lane_knob_zero_means cost-lane CK_04)"'
}
if [ -n "${GEN_GOLDEN:-}" ]; then
  mkdir -p "$(dirname "$GOLDEN")"; dump > "$GOLDEN"; echo "golden written: $GOLDEN"
elif [ -r "$GOLDEN" ]; then
  if [ "$(dump)" = "$(cat "$GOLDEN")" ]; then ok; else bad "E3 exports differ from the golden file: $(diff <(dump) "$GOLDEN" | head -10)"; fi
else bad "E3 golden file $GOLDEN is missing"; fi

echo "lane-env-cost.bh-7494-r2: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
