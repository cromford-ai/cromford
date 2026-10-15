#!/bin/bash
# tests/build-tripwire.bh-3501-test.sh — the mid-build spend tripwire
# (BH-3481.4 / BH-3501): the rules, the alert row, the one page, the launch
# guard in rb_gate_prelude, and CC() on a tripped build. Since BH-6705 a trip
# alerts and never stops a build (tests/build-tripwire-alert-only.bh-6705-test.sh).
#
# Every case drives the REAL bin/lib/build-tripwire.sh (a byte copy of it under
# a scratch $HARNESS, so its sibling libs resolve there) against a stub
# jobs-client and a stub lane-alert. The launch guard and CC() are lifted from
# the flattened pipeline and run, not read. Assertions are on artifacts: rc,
# stdout, $BUILD/tripwire-alert.txt, the ledger and alert sinks, RESULT and BB.
#
# Run from anywhere: tests/build-tripwire.bh-3501-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=1000000

# ---------- fixture: a scratch HARNESS with the real libs and stub clients ----
mkdir -p "$T/h/bin/lib" "$T/h/state" "$T/h/logs" "$T/b" "$T/noenv"
for f in build-tripwire.sh cost-budget.sh conf-row.sh lane-gate.sh lanes-registry.sh; do
  cp "$DIR/bin/lib/$f" "$T/h/bin/lib/$f" || { echo "cannot copy bin/lib/$f"; exit 1; }
done
cp "$DIR/bin/lib/build-tripwire.sh" "$T/h/bin/lib/build-tripwire.sh"
TWLIB="$T/h/bin/lib/build-tripwire.sh"
cat > "$T/h/bin/jobs-client.sh" <<'STUB'
#!/bin/bash
# sourced (lane-gate's settings refresh): no client functions, so it misses
[ "${BASH_SOURCE[0]}" != "$0" ] && return 0
echo "$*" >> "$TW_SINK/ledger.log"
if [ "${1:-}" = ledger-get ]; then printf '%s\n' "${JC_GET:-}"; exit "${JC_GET_RC:-0}"; fi
exit "${JC_RC:-0}"
STUB
cat > "$T/h/bin/lane-alert.sh" <<'STUB'
#!/bin/bash
echo "$*" >> "$TW_SINK/alert.log"
STUB
chmod +x "$T/h/bin/jobs-client.sh" "$T/h/bin/lane-alert.sh"
printf 'default 100 5\n' > "$T/caps.conf"
"$DIR/bin/lanes-build.sh" --to "$T/lanes.json" >/dev/null 2>&1 || { echo "cannot render the lane registry"; exit 1; }
unset JOBS_URL HARNESS_SECRET LANE_GATE_DISABLE SESSION_ID
for v in ${!BUILD_TRIPWIRE@}; do unset "$v"; done
export COST_CAPS_CONF="$T/caps.conf" LANE_REGISTRY="$T/lanes.json" LANE_GATE_NOW="$NOW" \
       HARNESS_ENV_DIR="$T/noenv" TW_SINK="$T"

HDR=$(. "$DIR/bin/lib/cost-row.sh" >/dev/null 2>&1; printf '%s' "${COST_ROW_HDR:-}")
[ -n "$HDR" ] || { echo "cannot read COST_ROW_HDR"; exit 1; }
# mkbuild <name> <S|M|L|XL|none|raw:<text>> [stage:cost:fp ...] -> the dir
mkbuild() {
  local d="$T/b/$1" sz="$2" r st c fp; shift 2
  scratch_rm "$d" || return 1; mkdir -p "$d"
  case "$sz" in
    none) ;;
    raw:*) printf '%s\n' "${sz#raw:}" > "$d/plan.md" ;;
    *) printf '# plan\n\n## Size\n\nSIZE: %s\n' "$sz" > "$d/plan.md" ;;
  esac
  printf '%s\n' "$HDR" > "$d/cost.csv"
  for r in "$@"; do
    IFS=: read -r st c fp <<<"$r"
    awk -v st="$st" -v c="$c" -v fp="$fp" 'BEGIN{
      for(i=1;i<=26;i++) f[i]=""; f[1]="2026-09-29T20:00:00Z"; f[3]="tproj"
      f[4]=st; f[13]=c; f[26]=fp; s=f[1]; for(i=2;i<=26;i++) s=s "," f[i]; print s }' >> "$d/cost.csv"
  done
  printf '%s' "$d"
}
reps() { local n="$1" row="$2" i; for ((i=0;i<n;i++)); do printf '%s\n' "$row"; done; }
# tw <fn> [args] — one lib function in a fresh bash under set -u; LIB= picks a copy
# BUILD_TRIPWIRE defaults to 0 (alert off) since BH-6705, so the helper turns it on.
tw() { BUILD_TRIPWIRE="${BUILD_TRIPWIRE:-1}" HARNESS="$T/h" bash -c 'set -uo pipefail; . "$0" || exit 99; "$@"' "${LIB:-$TWLIB}" "$@"; }
sinks_clear() { : > "$T/ledger.log"; : > "$T/alert.log"; }
nlines() { if [ -s "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi; }
TAB=$'\t'

# ============================== spend rule ===================================
# T1: 5.1x the expected 100 on an M plan trips: one alert, rc 1 (never a stop)
B=$(mkbuild t1 M execute:510:)
V=$(tw tw_eval "$B/cost.csv" 0 100 5 4)
case "$V" in "trip${TAB}spend${TAB}"*) ok ;; *) bad "T1 tw_eval at 510 vs 5x100: '$V'" ;; esac
case "$V" in *"${TAB}threshold=500.00${TAB}"*) ok ;; *) bad "T1 verdict lacks threshold=500.00: '$V'" ;; esac
sinks_clear; R=0; O=$(tw tw_check_build tproj BH-1 "$B" 0) || R=$?
[ "$R" = 1 ] && [ -z "$O" ] && ok || bad "T1 tw_check_build rc=$R out='$O', want 1 + silent"
[ "$(nlines "$T/alert.log")" = 1 ] && [ "$(grep -c 'ledger-put build-tripwire tproj BH-1 alerted' "$T/ledger.log")" = 1 ] \
  && ok || bad "T1 want one alert and one alerted row: alerts=$(nlines "$T/alert.log") ledger=$(cat "$T/ledger.log")"
grep -qx 'stages: execute=510.00' "$B/tripwire-alert.txt" 2>/dev/null && ok || bad "T1 tripwire-alert.txt stages line: $(grep '^stages' "$B/tripwire-alert.txt" 2>/dev/null)"
# T2: 4.9x does not
B=$(mkbuild t2 M execute:490:)
V=$(tw tw_eval "$B/cost.csv" 0 100 5 4)
case "$V" in "ok${TAB}"*) ok ;; *) bad "T2 tw_eval at 490: '$V'" ;; esac
R=0; O=$(tw tw_check_build tproj BH-2 "$B" 0) || R=$?
[ "$R" = 1 ] && [ -z "$O" ] && ok || bad "T2 tw_check_build rc=$R out='$O', want 1 + silent"
[ -e "$B/tripwire-alert.txt" ] && bad "T2 wrote a tripwire-alert.txt under the threshold" || ok

# ============================== repeat rule ==================================
# T3: five rows on one fp that cost 0 or nothing never count
B=$(mkbuild t3 M fix:0:a fix::a fix:0:a fix::a fix:0.0:a)
V=$(tw tw_eval "$B/cost.csv" 0 100 5 4)
case "$V" in "ok${TAB}"*) ok ;; *) bad "T3 unpaid repeats tripped: '$V'" ;; esac
# T4: six paid rows with an empty fp never count
B=$(mkbuild t4 M $(reps 6 fix:1:))
V=$(tw tw_eval "$B/cost.csv" 0 100 5 4)
case "$V" in "ok${TAB}"*) ok ;; *) bad "T4 empty guard_fp tripped: '$V'" ;; esac
# T5: four paid rows on four different fps
B=$(mkbuild t5 M fix:1:a fix:1:b fix:1:c fix:1:d)
V=$(tw tw_eval "$B/cost.csv" 0 100 5 4)
case "$V" in "ok${TAB}"*) ok ;; *) bad "T5 distinct fps tripped: '$V'" ;; esac
# T6: three paid `a` is under, the fourth trips
B=$(mkbuild t6 M fix:1:a fix:1:b fix:1:a fix:1:a)
V=$(tw tw_eval "$B/cost.csv" 0 100 5 4)
case "$V" in "ok${TAB}"*) ok ;; *) bad "T6 three repeats tripped: '$V'" ;; esac
B=$(mkbuild t6b M fix:1:a fix:1:b fix:1:a fix:1:a fix:2:a)
V=$(tw tw_eval "$B/cost.csv" 0 100 5 4)
case "$V" in "trip${TAB}repeat${TAB}fp=a${TAB}count=4${TAB}max=4${TAB}"*) ok ;; *) bad "T6 fourth repeat: '$V'" ;; esac

# T6c: an --advisor attempt (BH-3491) writes a second paid row, stage
# <stage>-advisor, with the SAME guard_fp. It is the same call: the repeat rule
# counts calls, so two advisor-on attempts on `a` are 2, not 4 — and the
# advisor's dollars still count toward the spend rule.
B=$(mkbuild t6c M fix:1:a fix-advisor:1:a fix:1:a fix-advisor:1:a)
V=$(tw tw_eval "$B/cost.csv" 0 100 5 4)
case "$V" in "ok${TAB}spend=4.00${TAB}"*"top_fp=a:2${TAB}"*) ok ;; *) bad "T6c advisor rows counted as repeats (or dropped from spend): '$V'" ;; esac
B=$(mkbuild t6d M execute:300:a execute-advisor:220:a)
V=$(tw tw_eval "$B/cost.csv" 0 100 5 4)
case "$V" in "trip${TAB}spend${TAB}spend=520.00${TAB}"*) ok ;; *) bad "T6c advisor dollars not in the spend rule: '$V'" ;; esac

# ============================== negatives ====================================
# T7: XL's threshold is 3x100x5 = 1500, so 1450 is ok; the same csv on M trips
B=$(mkbuild t7 XL execute:1000: fix:450:)
R=0; O=$(tw tw_check_build tproj BH-7 "$B" 0) || R=$?
[ "$R" = 1 ] && ok || bad "T7 XL at 1450 rc=$R out='$O', want 1"
B=$(mkbuild t7m M execute:1000: fix:450:)
sinks_clear; R=0; O=$(tw tw_check_build tproj BH-7 "$B" 0) || R=$?
[ "$R" = 1 ] && [ "$(nlines "$T/alert.log")" = 1 ] && ok || bad "T7 M at 1450 rc=$R alerts=$(nlines "$T/alert.log"), want 1 + one alert: shape did not bind"
# T8: no plan.md is XL (no-plan)
B=$(mkbuild t8 none execute:300:)
R=0; O=$(tw tw_check_build tproj BH-8 "$B" 0) || R=$?
[ "$R" = 1 ] && ok || bad "T8 no plan at 300 rc=$R out='$O', want 1"
[ "$(tw _tw_shape "$B")" = "XL${TAB}no-plan" ] && ok || bad "T8 _tw_shape: '$(tw _tw_shape "$B")'"
# T9: unpriced rows are counted, not summed, and nothing is said on stderr
B=$(mkbuild t9 M fix:abc: fix:UNPRICED: fix:: fix:12.5:)
V=$(tw tw_eval "$B/cost.csv" 0 100 5 4 2>"$T/t9.err")
case "$V" in "ok${TAB}spend=12.50${TAB}"*"${TAB}unpriced_rows=3") ok ;; *) bad "T9 verdict: '$V'" ;; esac
[ -s "$T/t9.err" ] && bad "T9 stderr: $(cat "$T/t9.err")" || ok
# T10: no csv at all, the live meter's figure alone
V=$(tw tw_eval "$T/b/nope/cost.csv" 50 100 5 4)
case "$V" in "ok${TAB}spend=50.00${TAB}"*) ok ;; *) bad "T10 verdict: '$V'" ;; esac
# T11: the master switch, and a repeat rule unarmed by env
B=$(mkbuild t11 M execute:900:)
sinks_clear; R=0; O=$(BUILD_TRIPWIRE=0 tw tw_check_build tproj BH-11 "$B" 0) || R=$?
[ "$R" = 1 ] && [ -z "$O" ] && ok || bad "T11 BUILD_TRIPWIRE=0 rc=$R out='$O', want 1 + silent"
[ -e "$B/tripwire-alert.txt" ] && bad "T11 switch off still wrote tripwire-alert.txt" || ok
[ ! -s "$T/ledger.log" ] && [ ! -s "$T/alert.log" ] && ok || bad "T11 switch off still wrote a ledger row or an alert"
B=$(mkbuild t11b M $(reps 10 fix:1:a))
R=0; O=$(BUILD_TRIPWIRE_REPEAT_MAX=0 tw tw_check_build tproj BH-11 "$B" 0) || R=$?
[ "$R" = 1 ] && ok || bad "T11 REPEAT_MAX=0 with 10 repeats rc=$R out='$O', want 1"
# T12: the LAST SIZE line is the plan's size; an unknown word is XL
B=$(mkbuild t12 "raw:SIZE: S
some text
SIZE: M")
[ "$(tw _tw_shape "$B")" = "M${TAB}plan" ] && ok || bad "T12 last-SIZE shape: '$(tw _tw_shape "$B")'"
[ "$(tw tw_expected tproj "$B")" = 100.0000 ] && ok || bad "T12 tw_expected: '$(tw tw_expected tproj "$B")'"
B=$(mkbuild t12b "raw:SIZE: S
SIZE: huge")
[ "$(tw _tw_shape "$B")" = "XL${TAB}unparseable" ] && ok || bad "T12 unparseable: '$(tw _tw_shape "$B")'"

# ============================== synthetic runaway ============================
# T13: an empty csv and a live session at 900 on an M build
t13() { # t13 <lib> -> 0 when every T13 assertion holds, else prints why
  local lib="$1" b o r=0 why=""
  b=$(mkbuild t13 M); sinks_clear
  o=$(LIB="$lib" tw tw_check_build tproj BH-9 "$b" 900) || r=$?
  [ "$r" = 1 ] && [ -z "$o" ] || why="$why rc=$r out='$o';"
  [ -e "$b/TRIPWIRE" ] && why="$why TRIPWIRE written;"
  case "$(head -1 "$b/tripwire-alert.txt" 2>/dev/null)" in "trip${TAB}spend${TAB}"*) ;; *) why="$why tripwire-alert.txt line 1 is not the verdict;" ;; esac
  for l in 'rule: spend' 'shape: M (plan)' 'alert_row: written'; do
    grep -qxF "$l" "$b/tripwire-alert.txt" 2>/dev/null || why="$why tripwire-alert.txt lacks '$l';"
  done
  [ "$(grep -c 'ledger-put build-tripwire tproj BH-9 alerted' "$T/ledger.log")" = 1 ] || why="$why ledger lines: $(cat "$T/ledger.log");"
  [ "$(nlines "$T/alert.log")" = 1 ] || why="$why alert lines $(nlines "$T/alert.log");"
  grep -q -- "--severity critical --id tripwire:tproj:BH-9:t13 build-tripwire " "$T/alert.log" \
    && grep -q 'alert_row=written' "$T/alert.log" || why="$why alert: $(cat "$T/alert.log");"
  r=0; o=$(LIB="$lib" tw tw_check_build tproj BH-9 "$b" 900) || r=$?
  [ "$r" = 1 ] || why="$why second rc=$r;"
  [ "$(grep -c 'ledger-put' "$T/ledger.log")" = 1 ] && [ "$(nlines "$T/alert.log")" = 1 ] || why="$why second check paged again;"
  [ -z "$why" ] || { echo "$why"; return 1; }
}
W=$(t13 "$TWLIB") && ok || bad "T13 runaway:$W"
# T13b: the ledger write fails -> said in the page and in tripwire-alert.txt
B=$(mkbuild t13b M); sinks_clear
R=0; O=$(JC_RC=1 tw tw_check_build tproj BH-9 "$B" 900) || R=$?
[ "$R" = 1 ] && grep -q 'alert_row=FAILED' "$T/alert.log" && grep -qx 'alert_row: FAILED' "$B/tripwire-alert.txt" 2>/dev/null \
  && ok || bad "T13b rc=$R alert='$(cat "$T/alert.log")' tw='$(grep alert_row "$B/tripwire-alert.txt" 2>/dev/null)'"
# T13c: two callers racing on one build dir -> one row, one page
B=$(mkbuild t13c M); sinks_clear
tw tw_check_build tproj BH-9 "$B" 900 >/dev/null & P1=$!
tw tw_check_build tproj BH-9 "$B" 900 >/dev/null & P2=$!
wait "$P1"; wait "$P2"
[ "$(grep -c 'ledger-put' "$T/ledger.log")" = 1 ] && [ "$(nlines "$T/alert.log")" = 1 ] \
  && ok || bad "T13c race: ledger=$(nlines "$T/ledger.log") alert=$(nlines "$T/alert.log")"
# no root: tripwire-alert.txt still written, the row is FAILED, rc 0
B=$(mkbuild t13d M)
R=0; O=$(HARNESS= H= bash -c 'set -uo pipefail; . "$0"; tw_trip p K "$1" "$(printf "trip\tspend\tspend=900.00")"' "$TWLIB" "$B") || R=$?
[ "$R" = 0 ] && grep -qx 'alert_row: FAILED' "$B/tripwire-alert.txt" 2>/dev/null && [ ! -e "$B/TRIPWIRE" ] && ok || bad "T13d no-root tw_trip rc=$R"

# ============================== through the real CC() ========================
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh") || { echo "could not flatten the pipeline"; exit 1; }
python3 - "$RB_ALL" "$T/cc.sh" <<'PY'
import sys
src = open(sys.argv[1]).read()
start = src.index("CC() { # CC <stage>")
end = src.index("\n}\n", start) + len("\n}\n")
open(sys.argv[2], "w").write(src[start:end])
PY
[ -s "$T/cc.sh" ] && ok || bad "T14 could not extract CC()"
cat > "$T/h/bin/agent-call.sh" <<'STUB'
#!/bin/bash
echo "$1 $2" >> "$TW_SINK/ac.log"
STUB
chmod +x "$T/h/bin/agent-call.sh"
cc14() { # cc14 <build> -> CC's rc
  rm -f "$T/ac.log" "$T/bb.log" "$1/RESULT"; sinks_clear
  BUILD="$1" BUILD_TRIPWIRE=1 BUILD_TRIPWIRE_REPEAT_MAX=4 HARNESS="$T/h" bash -c '
    set -uo pipefail
    PROJECT=tproj; KEY=BH-14; CG_ORIENT=x
    BB() { echo "$*" >> "$TW_SINK/bb.log"; }
    RESULT() { echo "$*" > "$BUILD/RESULT"; }
    . "$0"; . "$1"
    CC plan m 60 "$BUILD/plan-run.txt" hi' "$DIR/bin/lib/build-tripwire.sh" "$T/cc.sh"
}
# T14: a tripped build (four repeats) alerts once and the call still runs
B=$(mkbuild t14 M fix:1:z fix:1:z fix:1:z fix:1:z)
R=0; cc14 "$B" || R=$?
[ "$R" = 0 ] && ok || bad "T14 CC rc=$R, want 0 (the stub agent-call's rc)"
[ "$(nlines "$T/ac.log")" = 1 ] && ok || bad "T14 agent-call did not run on a tripped build"
[ -e "$B/RESULT" ] && bad "T14 RESULT: $(cat "$B/RESULT" 2>/dev/null)" || ok
grep -q tripwire_paused "$T/bb.log" 2>/dev/null && bad "T14 BB: $(cat "$T/bb.log" 2>/dev/null)" || ok
[ "$(nlines "$T/alert.log")" = 1 ] && ok || bad "T14 alert lines $(nlines "$T/alert.log"), want 1"
B=$(mkbuild t14b M fix:1:z fix:1:z fix:1:z)
R=0; cc14 "$B" || R=$?
[ "$(nlines "$T/ac.log")" = 1 ] && [ ! -e "$B/RESULT" ] && [ ! -s "$T/alert.log" ] && ok || bad "T14 three repeats: rc=$R ac=$(nlines "$T/ac.log") alerts=$(nlines "$T/alert.log") result=$(cat "$B/RESULT" 2>/dev/null)"

# ============================== launch guard =================================
awk '/^# >>> tripwire paused skip/{f=1} f{print} /^# <<< tripwire paused skip/{exit}' "$RB_ALL" > "$T/guard.sh"
[ -s "$T/guard.sh" ] && ok || bad "T16 could not lift the 'tripwire paused skip' block"
AB=$(grep -n '^# <<< abandoned ticket skip' "$RB_ALL" | head -1 | cut -d: -f1)
TG=$(grep -n '^# >>> tripwire paused skip' "$RB_ALL" | head -1 | cut -d: -f1)
EQ=$(grep -n 'Fly builder trial (Phase 2): enqueue gate' "$RB_ALL" | head -1 | cut -d: -f1)
[ -n "$AB" ] && [ -n "$TG" ] && [ -n "$EQ" ] && [ "$AB" -lt "$TG" ] && [ "$TG" -lt "$EQ" ] \
  && ok || bad "T16 guard (line ${TG:-?}) must sit after the abandoned skip (${AB:-?}) and before the enqueue gate (${EQ:-?})"
mkdir -p "$T/gb"
guard() { # guard <ledger-rc> <status> -> stdout of the block + CONTINUED
  rm -f "$T/gres" "$T/qput" "$T/gb/pipeline.log"
  LRC="$1" LST="$2" HARNESS="$T/h" BUILD="$T/gb" PROJECT=tproj KEY=BH-16 bash -c '
    STAMP() { echo 2026-09-29T20:00:00Z; }
    RESULT() { echo "$*" > "$TW_SINK/gres"; }
    queue_put() { : > "$TW_SINK/qput"; }
    job_ledger_get() { [ "$1" = build-tripwire ] && [ "$2" = "tproj BH-16" ] || return 2; [ "$LRC" = 0 ] && printf "%s" "$LST"; return "$LRC"; }
    . "$0"
    echo CONTINUED
    queue_put' "$T/guard.sh" 2>/dev/null
}
# T16: a leftover paused row -> one log line, and the build goes on (BH-6705)
R=0; O=$(guard 0 paused) || R=$?
[ "$R" = 0 ] && ok || bad "T16 paused rc=$R, want 0"
[ -e "$T/gres" ] && bad "T16 RESULT: $(cat "$T/gres" 2>/dev/null)" || ok
case "$O" in *CONTINUED*) ok ;; *) bad "T16 did not go on past a leftover paused row" ;; esac
[ -e "$T/qput" ] && ok || bad "T16 queue_put did not run on a leftover paused row"
[ "$(grep -c 'leftover paused row for BH-16 ignored' "$T/gb/pipeline.log" 2>/dev/null)" = 1 ] && ok || bad "T16 pipeline.log lacks the one leftover line"
# T17: released, or no row, builds as today
O=$(guard 0 released); case "$O" in *CONTINUED*) [ ! -e "$T/gres" ] && ok || bad "T17 released wrote a RESULT" ;; *) bad "T17 released did not continue" ;; esac
O=$(guard 2 ""); case "$O" in *CONTINUED*) ok ;; *) bad "T17 no row did not continue" ;; esac
# T18: an unusable API fails open with one line
O=$(guard 1 "")
case "$O" in *CONTINUED*) ok ;; *) bad "T18 outage did not continue" ;; esac
[ -e "$T/gres" ] && bad "T18 outage wrote a RESULT" || ok
[ "$(grep -c 'tripwire pause row unreadable' "$T/gb/pipeline.log" 2>/dev/null)" = 1 ] && ok || bad "T18 want one unreadable line in pipeline.log"
# tw_paused through the CLI when no job_ledger_get is loaded
R=0; JC_GET=paused tw tw_paused tproj BH-16 || R=$?
[ "$R" = 0 ] && ok || bad "tw_paused via CLI 'paused' rc=$R, want 0"
R=0; JC_GET=released tw tw_paused tproj BH-16 || R=$?
[ "$R" = 1 ] && ok || bad "tw_paused via CLI 'released' rc=$R, want 1"
R=0; JC_GET= JC_GET_RC=2 tw tw_paused tproj BH-16 || R=$?
[ "$R" = 1 ] && ok || bad "tw_paused via CLI no row rc=$R, want 1"
R=0; JC_GET= JC_GET_RC=1 tw tw_paused tproj BH-16 || R=$?
[ "$R" = 2 ] && ok || bad "tw_paused via CLI outage rc=$R, want 2"

# ============================== settings row =================================
# T19: lib.build-tripwire.build_tripwire_mult=2 binds mid-build; without it 5 does
B=$(mkbuild t19 M execute:250:)
printf '{"fetched_at":%s,"values":{"lib.build-tripwire.build_tripwire_mult":"2"},"seeded":{}}\n' "$NOW" > "$T/h/state/settings-cache.json"
sinks_clear; R=0; O=$(tw tw_check_build tproj BH-19 "$B" 0) || R=$?
[ "$R" = 1 ] && [ "$(nlines "$T/alert.log")" = 1 ] && ok || bad "T19 a settings row of MULT=2 at 250 rc=$R alerts=$(nlines "$T/alert.log"), want 1 + one alert"
case "$(head -1 "$B/tripwire-alert.txt" 2>/dev/null)" in *"${TAB}mult=2${TAB}"*) ok ;; *) bad "T19 verdict lacks mult=2: '$(head -1 "$B/tripwire-alert.txt" 2>/dev/null)'" ;; esac
rm -f "$T/h/state/settings-cache.json"
B=$(mkbuild t19b M execute:250:)
sinks_clear; R=0; O=$(tw tw_check_build tproj BH-19 "$B" 0) || R=$?
[ "$R" = 1 ] && [ ! -s "$T/alert.log" ] && ok || bad "T19 no row at 250 rc=$R alerts=$(nlines "$T/alert.log"), want 1 + no alert"

# ============================== no dollar literal ============================
L=$(grep -vE '^\s*#' "$DIR/bin/lib/build-tripwire.sh" | grep -nEi '\$[0-9]|[0-9](\.[0-9]+)?[[:space:]]*(usd|dollars?)\b|usd[_a-z]*[[:space:]]*=[[:space:]]*[0-9]|COST_BUDGET_DEFAULT')
[ -z "$L" ] && ok || bad "T20 a dollar literal in the lib: $L"
L=$(grep -vE '^\s*#' "$DIR/bin/lib/build-tripwire.sh" | grep -E ':-[0-9]' | grep -v 'BUILD_TRIPWIRE')
[ -z "$L" ] && ok || bad "T20 a numeric default that is not a BUILD_TRIPWIRE knob: $L"
grep -q ':-5}' "$DIR/bin/lib/build-tripwire.sh" && ok || bad "T20 the MULT fallback is not in the lib (vacuous scan)"

# ============================== mutation (D1) ================================
MUT="$T/h/bin/lib/build-tripwire.mut.sh"
awk '/^tw_eval\(\) \{/{print; print "  printf '"'"'ok\\tmutant\\n'"'"'"; print "}"; skip=1; next}
     skip && /^\}/{skip=0; next} !skip{print}' "$TWLIB" > "$MUT"
grep -q 'mutant' "$MUT" && ! cmp -s "$MUT" "$TWLIB" && ok || bad "mutation: the mutant was not built"
B=$(mkbuild tm M execute:510:)
V=$(LIB="$MUT" tw tw_eval "$B/cost.csv" 0 100 5 4)
case "$V" in "trip${TAB}spend${TAB}"*) bad "mutation: T1's assertion stayed green on the mutant" ;; *) ok ;; esac
W=$(t13 "$MUT") && bad "mutation: T13 stayed green on the mutant" || ok

echo "build-tripwire.bh-3501: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
