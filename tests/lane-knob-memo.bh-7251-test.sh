#!/bin/bash
# tests/lane-knob-memo.bh-7251-test.sh — BH-7251 part 2: one lane start reads
# the registry with ONE jq and the settings cache with ONE jq, and every knob
# read after that uses the memo. No jq per knob.
#
# Fixture: lane `memo-lane` with 20 knobs (settable with bounds, one
# zero_means=unlimited, one zero_means=off, two settable:false, two required
# with defaults), lib `memo-lib` with 3 knobs, lane `memo-closed` with one
# required knob that has no default. A jq shim first on PATH counts every jq.
# The real bin/lib/lane-gate.sh is sourced in a fresh bash per case.
#
#   M1 lane_env_apply + 20 lane_knob + 20 lane_knob_settable + 2
#      lane_knob_zero_means + 2 lane_knob_unlimited -> at most 2 jq.
#   M2 the exported and resolved values: clamp, unlimited 0, refused
#      unlimited, project row over global, default for an empty row, env for
#      an unset knob, raw required defaults, settable:false ignored.
#   M3 settings values round-trip byte for byte: spaces, `\`, `|`.
#   M4 a required knob with no default and no row -> exit 75 + one ALERTS line.
#   M5 the settings file rewritten in the same process -> the next lane_knob
#      returns the new value, with exactly 1 more jq.
#   M6 no settings file -> env, then default; at most 2 jq.
#   M7 lib_env_apply memo-lib -> at most 2 jq; the lib rows are applied.
#   M8 a corrupt settings file -> nothing exported from rows; the lane runs.
#   M9 an id missing from the registry -> settable rc 0, zero_means empty,
#      one jq for its first load and none after.
#
# Run: bash tests/lane-knob-memo.bh-7251-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=1758300000
H="$T/h"; SHIM="$T/shim"; REG="$T/registry.json"; SC="$H/state/settings-cache.json"
mkdir -p "$H/state" "$H/logs" "$H/flags" "$SHIM"
printf '#!/bin/bash\necho x >> "%s/jq-calls"\nexec %s "$@"\n' "$T" "$(command -v jq)" > "$SHIM/jq"
chmod +x "$SHIM/jq"

cat > "$REG" <<'JSON'
{"lanes":[
 {"id":"memo-lane","knobs":[
  {"env":"MK_CLAMP","default":5,"min":1,"max":10},
  {"env":"MK_PROJ","default":3,"min":0,"max":9},
  {"env":"MK_EMPTY","default":6,"min":0,"max":9},
  {"env":"MK_SPACES","default":"d"},
  {"env":"MK_BSLASH","default":"d"},
  {"env":"MK_PIPE","default":"d"},
  {"env":"MK_ENVONLY","default":2,"min":0,"max":9},
  {"env":"MK_DEF","default":4},
  {"env":"MK_N09","default":1,"min":0,"max":100},
  {"env":"MK_N10","default":1,"min":0,"max":100},
  {"env":"MK_N11","default":1,"min":0,"max":100},
  {"env":"MK_N12","default":1,"min":0,"max":100},
  {"env":"MK_ZERO","default":0,"min":0,"max":100},
  {"env":"MK_FLOAT","default":1.5},
  {"env":"MK_UNL","default":5,"min":0,"max":50,"zero_means":"unlimited"},
  {"env":"MK_OFF","default":5,"min":0,"max":50,"zero_means":"off"},
  {"env":"MK_NOSET","default":"cmd","settable":false},
  {"env":"MK_NOSET2","default":"","settable":false},
  {"env":"MK_REQ1","default":"a b","required":true},
  {"env":"MK_REQ2","default":"\\?|\\bplease\\b","required":true}]},
 {"id":"memo-closed","knobs":[{"env":"MC_REQ","required":true}]}],
 "libs":[
 {"id":"memo-lib","knobs":[
  {"env":"ML_A","default":1,"min":0,"max":50},
  {"env":"ML_B","default":"rq","required":true},
  {"env":"ML_C","default":"c"}]},
 {"id":"memo-lane","knobs":[{"env":"MK_CLAMP","default":77}]}]}
JSON

# settings_write <MK_CLAMP value> — the cache in the shape _lg_settings_refresh writes.
settings_write() {
  jq -nc --argjson fa "$NOW" --arg c "$1" '{fetched_at:$fa, values:{
    "lane.memo-lane.mk_clamp":$c,
    "lane.memo-lane.mk_proj":"4",
    "lane.memo-lane.p.mk_proj":"7",
    "lane.memo-lane.mk_empty":"",
    "lane.memo-lane.mk_spaces":"x y  z",
    "lane.memo-lane.mk_bslash":"a\\b\\\\c",
    "lane.memo-lane.mk_pipe":"p|q|r",
    "lane.memo-lane.mk_n09":"11",
    "lane.memo-lane.mk_n10":"12",
    "lane.memo-lane.mk_n11":"13",
    "lane.memo-lane.mk_n12":"14",
    "lane.memo-lane.mk_unl":"20",
    "lane.memo-lane.mk_unl.unlimited":"1",
    "lane.memo-lane.mk_off":"12",
    "lane.memo-lane.mk_off.unlimited":"1",
    "lane.memo-lane.mk_noset":"evil",
    "lib.memo-lib.ml_a":"9"}, seeded:{"lane.memo-lane.mk_def":"99"}}' > "$SC.tmp" && mv "$SC.tmp" "$SC"
}

ALL="MK_CLAMP MK_PROJ MK_EMPTY MK_SPACES MK_BSLASH MK_PIPE MK_ENVONLY MK_DEF MK_N09 MK_N10 MK_N11 MK_N12 MK_ZERO MK_FLOAT MK_UNL MK_OFF MK_NOSET MK_NOSET2 MK_REQ1 MK_REQ2"
# The driver: one fresh bash that sources the real lib, as a lane does.
cat > "$T/drive.sh" <<'SH'
. "$LG" || exit 3
jqn() { grep -c . "$JQC" 2>/dev/null || echo 0; }
out() { printf '%s\t%s\n' "$1" "$2" >> "$OUT"; }
case "$CASE" in
main)
  lane_env_apply memo-lane p
  for e in $ALL; do out "exp.$e" "${!e-<unset>}"; done
  for e in $ALL; do v=$(lane_knob memo-lane "$e" p); out "knob.$e" "$v"; done
  for e in $ALL; do if lane_knob_settable memo-lane "$e"; then out "set.$e" 1; else out "set.$e" 0; fi; done
  out zm.MK_UNL "$(lane_knob_zero_means memo-lane MK_UNL)"
  out zm.MK_OFF "$(lane_knob_zero_means memo-lane MK_OFF)"
  if lane_knob_unlimited memo-lane MK_UNL p; then out unl.MK_UNL 1; else out unl.MK_UNL 0; fi
  if lane_knob_unlimited memo-lane MK_OFF p; then out unl.MK_OFF 1; else out unl.MK_OFF 0; fi
  out jq.m1 "$(jqn)"
  # M5: the cache rewritten under this process, as a refresh mv does.
  "$REWRITE"
  out jq.m5a "$(jqn)"
  out m5.MK_CLAMP "$(lane_knob memo-lane MK_CLAMP p)"
  out m5.MK_CLAMP2 "$(lane_knob memo-lane MK_CLAMP p)"
  out jq.m5b "$(jqn)"
  # M9: an id the registry does not have.
  if lane_knob_settable nope-lane MK_X; then out m9.set 1; else out m9.set 0; fi
  out m9.zm "$(lane_knob_zero_means nope-lane MK_X)"
  if lane_knob_settable nope-lane MK_X; then out m9.set2 1; else out m9.set2 0; fi
  out jq.m9 "$(jqn)"
  ;;
nofile|corrupt)
  lane_env_apply memo-lane p
  for e in MK_CLAMP MK_PROJ MK_ENVONLY MK_REQ1; do out "exp.$e" "${!e-<unset>}"; done
  for e in MK_CLAMP MK_PROJ MK_ENVONLY MK_DEF; do out "knob.$e" "$(lane_knob memo-lane "$e" p)"; done
  out ran 1
  out jq "$(jqn)"
  ;;
lib)
  lib_env_apply memo-lib p
  for e in ML_A ML_B ML_C MK_CLAMP; do out "exp.$e" "${!e-<unset>}"; done
  out jq "$(jqn)"
  ;;
closed)
  lane_env_apply memo-closed p
  out ran 1
  ;;
esac
SH
# The rewrite moves a prepared cache into place, as a refresh's mv does. It
# runs no jq, so the count after it is the reader's alone.
jq -nc --argjson fa "$NOW" '{fetched_at:$fa, values:{"lane.memo-lane.mk_clamp":"7"}}' > "$T/sc-new.json"
printf '#!/bin/bash\ncp "%s" "%s.tmp" && mv "%s.tmp" "%s"\n' "$T/sc-new.json" "$SC" "$SC" "$SC" > "$T/rewrite.sh"
chmod +x "$T/rewrite.sh"

# drive <case> — run the driver; leaves $OUT and $RC.
drive() {
  OUT="$T/out-$1"; : > "$OUT"; : > "$T/jq-calls"
  env -i PATH="$SHIM:$PATH" HOME="$T" HARNESS="$H" LANE_REGISTRY="$REG" LANE_GATE_NOW="$NOW" \
    LG="$DIR/bin/lib/lane-gate.sh" JQC="$T/jq-calls" OUT="$OUT" CASE="$1" ALL="$ALL" \
    REWRITE="$T/rewrite.sh" MK_ENVONLY=8 bash "$T/drive.sh" >/dev/null 2>"$T/err-$1"
  RC=$?
}
got() { awk -F'\t' -v k="$1" '$1==k{sub(/^[^\t]*\t/,""); print; exit}' "$OUT"; }
eqv() { local g; g=$(got "$2"); if [ "$g" = "$3" ]; then ok; else bad "$1: $2 = [$g], want [$3]"; fi; }

# ── M1-M3, M5, M9: one process ──────────────────────────────────────────────
settings_write 50
drive main
[ "$RC" = 0 ] || bad "main driver rc=$RC ($(head -3 "$T/err-main"))"
J=$(got jq.m1)
if [ -n "$J" ] && [ "$J" -le 2 ]; then ok; else bad "M1 jq for lane_env_apply + 44 knob reads = ${J:-none}, want <= 2"; fi
# M2: what lane_env_apply exported.
eqv M2 exp.MK_CLAMP 10
eqv M2 exp.MK_PROJ 7
eqv M2 exp.MK_EMPTY 6
eqv M2 exp.MK_UNL 0
eqv M2 exp.MK_OFF 12
eqv M2 exp.MK_N09 11
eqv M2 exp.MK_N12 14
eqv M2 exp.MK_NOSET '<unset>'
eqv M2 exp.MK_DEF '<unset>'
eqv M2 exp.MK_ZERO '<unset>'
eqv M2 exp.MK_ENVONLY 8
eqv M2 exp.MK_REQ1 'a b'
eqv M2 exp.MK_REQ2 '\?|\bplease\b'
# M2: what lane_knob resolves.
eqv M2 knob.MK_CLAMP 10
eqv M2 knob.MK_PROJ 7
eqv M2 knob.MK_EMPTY 6
eqv M2 knob.MK_ENVONLY 8
eqv M2 knob.MK_DEF 4
eqv M2 knob.MK_ZERO 0
eqv M2 knob.MK_FLOAT 1.5
eqv M2 knob.MK_UNL 0
eqv M2 knob.MK_OFF 12
eqv M2 knob.MK_NOSET cmd
eqv M2 knob.MK_NOSET2 ''
eqv M2 knob.MK_REQ2 '\?|\bplease\b'
eqv M2 set.MK_CLAMP 1
eqv M2 set.MK_NOSET 0
eqv M2 set.MK_NOSET2 0
eqv M2 set.MK_REQ1 1
eqv M2 zm.MK_UNL unlimited
eqv M2 zm.MK_OFF off
eqv M2 unl.MK_UNL 1
eqv M2 unl.MK_OFF 0
# M3: settings values byte for byte.
eqv M3 exp.MK_SPACES 'x y  z'
eqv M3 exp.MK_BSLASH 'a\b\\c'
eqv M3 exp.MK_PIPE 'p|q|r'
eqv M3 knob.MK_BSLASH 'a\b\\c'
# M5
eqv M5 m5.MK_CLAMP 7
eqv M5 m5.MK_CLAMP2 7
A=$(got jq.m5a); B=$(got jq.m5b)
if [ -n "$A" ] && [ -n "$B" ] && [ "$((B - A))" -le 2 ] && [ "$((B - A))" -ge 1 ]; then ok
else bad "M5 jq after a same-process rewrite = $A -> $B, want 1 or 2 more (one per subshell that sees the new file)"; fi
# M9
eqv M9 m9.set 1
eqv M9 m9.zm ''
eqv M9 m9.set2 1
C=$(got jq.m9)
if [ -n "$B" ] && [ -n "$C" ] && [ "$((C - B))" -le 1 ]; then ok
else bad "M9 jq for 3 reads of an id the registry lacks = $B -> $C, want at most 1 more"; fi
grep -q 'CLAMPED 50 -> 10' "$H/logs/lane-gate.log" 2>/dev/null && ok || bad "M2 the clamp is logged"

# ── M4: fail closed ─────────────────────────────────────────────────────────
drive closed
if [ "$RC" = 75 ]; then ok; else bad "M4 a required knob with nothing to answer -> rc 75, got $RC"; fi
[ -z "$(got ran)" ] && ok || bad "M4 the lane body ran"
N=$(grep -c 'memo-closed/p did NOT run' "$H/logs/ALERTS.log" 2>/dev/null)
[ "${N:-0}" = 1 ] && ok || bad "M4 one ALERTS line, got ${N:-0}"

# ── M6: no settings file ────────────────────────────────────────────────────
rm -f "$SC" "$H/state/lane-gate/.settings-miss"
drive nofile
[ "$RC" = 0 ] || bad "M6 driver rc=$RC"
eqv M6 exp.MK_CLAMP '<unset>'
eqv M6 exp.MK_REQ1 'a b'
eqv M6 knob.MK_CLAMP 5
eqv M6 knob.MK_ENVONLY 8
eqv M6 knob.MK_DEF 4
J=$(got jq); if [ -n "$J" ] && [ "$J" -le 2 ]; then ok; else bad "M6 jq with no settings file = ${J:-none}, want <= 2"; fi

# ── M7: a lib scope ─────────────────────────────────────────────────────────
settings_write 50
drive lib
[ "$RC" = 0 ] || bad "M7 driver rc=$RC"
eqv M7 exp.ML_A 9
eqv M7 exp.ML_B rq
eqv M7 exp.ML_C '<unset>'
eqv M7 exp.MK_CLAMP '<unset>'
J=$(got jq); if [ -n "$J" ] && [ "$J" -le 2 ]; then ok; else bad "M7 jq for lib_env_apply = ${J:-none}, want <= 2"; fi

# ── M8: a corrupt settings file ─────────────────────────────────────────────
printf '{"fetched_at":%s, "values": {"lane.memo-lane.mk_clamp": "3"' "$NOW" > "$SC"
rm -f "$H/state/lane-gate/.settings-miss"
drive corrupt
[ "$RC" = 0 ] || bad "M8 driver rc=$RC"
eqv M8 ran 1
eqv M8 exp.MK_CLAMP '<unset>'
eqv M8 exp.MK_REQ1 'a b'
eqv M8 knob.MK_CLAMP 5

echo "lane-knob-memo.bh-7251: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
