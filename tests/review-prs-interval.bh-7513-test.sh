#!/bin/bash
# tests/review-prs-interval.bh-7513-test.sh — BH-7513: a per-project review-prs
# tick interval (10, 15 or 30 minutes; default 30), read from a settings row
# where the crontab is rendered.
#   R1 no row: every project-6-os project renders review-prs as two minutes 30 apart
#   R2 project-6-os row 10 on the real fleet.conf, box project-6-os: six minutes, 10 apart, first 0-9
#   R3 two projects at 10 on one box: disjoint minute sets
#   R4 a project at 10 next to a project at 30: no shared minute, the 30 line unchanged
#   R5 no distinct set left: the project keeps 30, one log line, the others stay distinct
#   R6 a refused value (7, abc, 0, 5, 60, empty) renders exactly as no row
#   R7 interval 15: four minutes, 15 apart
#   R8 the knob file and the seed fragment exist and say what the ticket says
# Run: HARNESS_TEST_SANDBOX=1 bash tests/review-prs-interval.bh-7513-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
unset REGISTRY_SOURCE

sched() { awk -v s="/root/harness/bin/$2.sh" -v p="$3" '$6 == s && $7 == p { print $1 }' <<<"$1"; }
count() { tr ',' '\n' <<<"$1" | grep -c .; }
dups()  { printf '%s\n' "$@" | tr ',' '\n' | sort | uniq -d | wc -l | tr -d ' '; }
# row <dir> <project:value>... — a fresh settings cache holding those interval rows
row() {
  local d="$1" vals="{}" kv; shift
  for kv in "$@"; do
    vals=$(jq -c --arg k "lane.review-prs.${kv%%:*}.review_prs_interval_min" --arg v "${kv#*:}" '.[$k]=$v' <<<"$vals")
  done
  mkdir -p "$d/state"
  jq -nc --argjson f "$(date -u +%s)" --argjson v "$vals" '{fetched_at:$f,values:$v,seeded:{}}' > "$d/state/settings-cache.json"
}
# render <root> <box> <harness> — the box's crontab; stderr lands in $T/err
render() { HARNESS="$3" bash "$DIR/bin/render-crontab.sh" --root "$1" --base "$T/base" "$2" 2>"$T/err"; }
# gaps <schedule> — the distinct differences between neighbouring minutes, wrap included
gaps() { awk -F, '{ for (i = 1; i <= NF; i++) { j = (i % NF) + 1; d = $j - $i; if (d <= 0) d += 60; print d } }' <<<"$1" | sort -u | tr '\n' ' '; }
fixture() { local f="$T/$1"; shift; mkdir -p "$f"; printf '%s\n' "$@" > "$f/fleet.conf"; printf '%s' "$f"; }
printf '# base\n' > "$T/base"

# --- R1: no row anywhere ----------------------------------------------------
OUT=$(render "$DIR" project-6-os "$T/none")
n=0; badn=0
while read -r p; do
  s=$(sched "$OUT" review-prs "$p"); [ -n "$s" ] || continue
  n=$((n+1)); [ "$(gaps "$s")" = "30 " ] || badn=$((badn+1))
done < <(awk '$1 !~ /^#/ && NF >= 6 && $6 == "box-project-6-os-1" { print $1 }' "$DIR/fleet.conf")
[ "$n" -ge 1 ] && [ "$badn" = 0 ] && ok || bad "R1 project-6-os default review-prs lines: $n seen, $badn not 30 apart"
# R1b: a root with no state/ dir (a repo checkout) is not read and gets no files
R1B="$T/checkout"; mkdir -p "$R1B"
render "$DIR" project-6-os "$R1B" >/dev/null
[ -z "$(find "$R1B" -mindepth 1 -print -quit)" ] && ok || bad "R1b the render wrote into a root with no state/: $(find "$R1B" -mindepth 1 | head -5 | tr '\n' ' ')"

# --- R2: project-6-os at 10 on the real registry ----------------------------
H="$T/h2"; row "$H" project-6-os:10
OUT=$(render "$DIR" project-6-os "$H"); RC=$?
S=$(sched "$OUT" review-prs project-6-os)
[ "$RC" -eq 0 ] && ok || bad "R2 render rc $RC: $(cat "$T/err")"
if [ -n "$S" ] && [ "$(count "$S")" = 6 ] && [ "$(gaps "$S")" = "10 " ] && [ "${S%%,*}" -le 9 ]; then ok; else bad "R2 project-6-os review-prs '$S' (want 6 minutes, 10 apart, first 0-9)"; fi
BASE_OUT=$(render "$DIR" project-6-os "$T/none")
[ "$(grep -v "review-prs.sh project-6-os\$" <<<"$BASE_OUT")" = "$(grep -v "review-prs.sh project-6-os\$" <<<"$OUT")" ] && ok || bad "R2 a line other than project-6-os review-prs changed"

# --- R3: two at 10 on one box -----------------------------------------------
F=$(fixture f3 'pa o/a - - 3 box-demo' 'pb o/b - - 3 box-demo')
H="$T/h3"; row "$H" pa:10 pb:10
OUT=$(render "$F" demo "$H"); A=$(sched "$OUT" review-prs pa); B=$(sched "$OUT" review-prs pb)
if [ "$(count "$A")" = 6 ] && [ "$(count "$B")" = 6 ]; then ok; else bad "R3 not six minutes each: '$A' '$B'"; fi
if [ "$A" != "$B" ] && [ "$(dups "$A" "$B")" = 0 ]; then ok; else bad "R3 shared minute: '$A' vs '$B'"; fi

# --- R4: 10 next to 30 ------------------------------------------------------
H="$T/h4"; row "$H" pb:10
OUT=$(render "$F" demo "$H"); A=$(sched "$OUT" review-prs pa); B=$(sched "$OUT" review-prs pb)
[ "$A" = "10,40" ] && ok || bad "R4 the 30 project changed: '$A' (want 10,40)"
if [ "$(count "$B")" = 6 ] && [ "$(dups "$A" "$B")" = 0 ]; then ok; else bad "R4 shared minute or wrong count: '$A' vs '$B'"; fi
OUT2=$(render "$F" demo "$H"); [ "$OUT" = "$OUT2" ] && ok || bad "R4 two renders differ"

# --- R5: no distinct set left ----------------------------------------------
LINES=('q1 o/q1 - - 0 box-demo' 'q2 o/q2 - - 0 box-demo' 'q3 o/q3 - - 0 box-demo')
ROWS=()
for i in 1 2 3 4 5 6 7 8; do LINES+=("t$i o/t$i - - 0 box-demo"); ROWS+=("t$i:10"); done
F=$(fixture f5 "${LINES[@]}"); H="$T/h5"; row "$H" "${ROWS[@]}"
OUT=$(render "$F" demo "$H"); RC=$?
[ "$RC" -eq 0 ] && ok || bad "R5 render rc $RC: $(cat "$T/err")"
SIX=0; TWO=""; PLACED=""
for i in 1 2 3; do PLACED="$PLACED $(sched "$OUT" review-prs "q$i")"; done
for i in 1 2 3 4 5 6 7 8; do
  s=$(sched "$OUT" review-prs "t$i")
  if [ "$(count "$s")" = 6 ]; then SIX=$((SIX+1)); PLACED="$PLACED $s"; else TWO="$TWO t$i"; fi
done
if [ "$SIX" = 7 ] && [ "$(wc -w <<<"$TWO")" -eq 1 ]; then ok; else bad "R5 want 7 projects at 10 and 1 kept at 30: six=$SIX rest='$TWO'"; fi
if [ "$(grep -c 'review-prs interval' "$T/err")" = 1 ]; then ok; else bad "R5 want exactly one log line: $(cat "$T/err")"; fi
[ "$(dups $PLACED)" = 0 ] && ok || bad "R5 a minute is shared among the placed projects: $PLACED"

# --- R6: refused values -----------------------------------------------------
F=$(fixture f6 'pa o/a - - 3 box-demo' 'pb o/b - - 3 box-demo')
BASELINE=$(render "$F" demo "$T/none")
for v in 7 abc 0 5 60 ''; do
  H="$T/h6"; row "$H" "pa:$v"
  [ "$(render "$F" demo "$H")" = "$BASELINE" ] && ok || bad "R6 value '$v' changed the render"
done

# --- R7: 15 -----------------------------------------------------------------
H="$T/h7"; row "$H" pa:15
S=$(sched "$(render "$F" demo "$H")" review-prs pa)
if [ "$(count "$S")" = 4 ] && [ "$(gaps "$S")" = "15 " ]; then ok; else bad "R7 interval 15 gave '$S'"; fi

# --- R8: the knob and the seed ----------------------------------------------
K="$DIR/catalog/lanes.d/review-prs.knobs.d/REVIEW_PRS_INTERVAL_MIN.json"
if [ -f "$K" ]; then
  [ "$(jq -r '[.default,.min,.max,(.zero_means|tostring),.unit]|join(" ")' "$K")" = "30 10 30 null minutes" ] && ok || bad "R8 knob fields: $(jq -c . "$K")"
else bad "R8 $K is missing"; fi
SEED=$(grep -l "lane.review-prs.project-6-os.review_prs_interval_min" "$DIR"/worker/jobs/schema.d/*.sql 2>/dev/null | head -1)
if [ -n "$SEED" ]; then
  if grep -q "INSERT OR IGNORE INTO settings" "$SEED" && grep -q "'lane.review-prs.project-6-os.review_prs_interval_min','10'" "$SEED"; then ok; else bad "R8 seed fragment shape: $SEED"; fi
else bad "R8 no schema.d fragment seeds project-6-os"; fi

echo "review-prs-interval.bh-7513: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
