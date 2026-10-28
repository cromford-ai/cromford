#!/bin/bash
# tests/prequeue-group-release.bh-8610-test.sh — BH-8610: a passed prequeue
# group releases its members, and a re-gate stays one group.
#
# WAKE (bin/lib/wake-prequeue-keys.sh, wpk_done_prs):
#   W1   6 heads join one group through the real pq_gate and the flush; a
#        completed run titled `prequeue group=<gid> main=<M>`: all 6 printed,
#        rc 0, exactly 1 read (the group runs path)
#   W3   1 per-head + 2 grouped pending on one main, both runs completed:
#        2 reads, 3 printed
#   W4   a group title for another main (W4b another gid, W4c one char off):
#        rc 3, nothing printed
#   W5   the group run in progress: rc 3
#   W6   a member whose entry is green is not printed
#   W7   a malformed .group sidecar: the per-head read only
#   W8   the group read fails: rc 2, every pending PR printed
#   W9   wpk_group_title equals pq_group_title
# SWEEP (bin/lib/mc-prequeue.d/group-release.sh through mc_pq_group_tick_end):
#   S1   a dispatched group, its run completed (6 green): the verdicts file has
#        6 lines, the 6 backstop counters are gone, .released, one
#        group-release n=6 line; S5 a non-member counter and S5b another
#        repo's counter for the same PR number stay
#   S1b  one red member: its next pq_gate answers red, the others proceed
#   S2   the run not completed: no marker, the counters stay
#   S3   the verdicts already read by a member: counters go with 0 reads
#   S4   .released present: 0 reads, 0 removals
#   S6   the run read fails (rc 75): no marker, the counters stay
#   S7   no .run file: 0 reads, no lock file, no marker
# JOIN AND FLUSH (bin/lib/mc-prequeue.d/group.sh):
#   J1   3 runs (ticks t1, t2, t3) on one main: 1 group of 3; J7 the last run
#        flushes it (it joined): 1 dispatch naming all 3; the other flushes 0
#   J2   one tick, 3 heads: 1 group, as before
#   J3   MC_PREQUEUE_GROUP_SHARE_S=0: 3 groups of 1
#   J4   a group older than the knob: a new group
#   J5   another main: a new group
#   J6   MC_PREQUEUE_GROUP_MAX=2: groups of 2 and 1
#   J8   a run with no member in the group: abandoned (BH-8327 G6)
#   J8b  a joined group older than the knob: abandoned
# THE INCIDENT (fix idea 4):
#   R1   a group passes on M1; main moves to M2, 1 commit: 6 proceed, 0 dispatch
#   R2   main moves 6 commits (past MC_PREQUEUE_FRESH_COMMITS=3), disjoint from
#        the impact map: 6 proceed through impact reuse, 0 dispatch, 6 .reuse
#   R3   the move hits the members' reach; each member asks from its own tick:
#        ONE group dispatch naming all 6
# Z1 0 curl calls, the gh on PATH is the stub; Z2 0 alerts in the S cases;
# Z3 the knob default equals its JSON row.
#
# Driven, not grepped: the cases source the real bin/lib/mc-prequeue.sh (every
# hook in bin/lib/mc-prequeue.d/), the real bin/lib/wake-prequeue-keys.sh and
# the real BH-8327 fragment, and call pq_gate, pq_group_flush,
# mc_pq_group_tick_end and wpk_done_prs. GitHub is gh_rest / gh_rest_var
# (functions) and gh (a stub on PATH); 0 real calls.
# Run from anywhere: bash tests/prequeue-group-release.bh-8610-test.sh (the R cases
# set HARNESS_TEST_SANDBOX=1 themselves).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq flock git; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done
WPK_LIB="$DIR/bin/lib/wake-prequeue-keys.sh"   # impact: bin/lib/wake-prequeue-keys.sh bin/lib/mc-prequeue.d/group.sh bin/lib/mc-prequeue.d/group-release.sh bin/merge-conductor.d/bh-8327-prequeue-group.sh
GROUP_FRAG="$DIR/bin/merge-conductor.d/bh-8327-prequeue-group.sh"
KNOB_JSON="$DIR/catalog/lanes.d/merge-conductor.knobs.d/MC_PREQUEUE_GROUP_SHARE_S.json"

SLUG=example-org/demo
LSLUG="${SLUG,,}"
U="https://github.com/$SLUG/pull"
hd() { printf '%02x%02x%036d' "$1" "$2" 0; }
mn() { printf 'ee%02x%036d' "$1" 0; }

FB="$T/fakebin"; mkdir -p "$FB"
cat > "$FB/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "\${GH_LOG:-$T/gh-orphan.log}"
exit "\$(cat "\${GH_RC_FILE:-/nonexistent}" 2>/dev/null || echo 0)"
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/curl-calls"\nexit 7\n' "$T" > "$FB/curl"
chmod +x "$FB/gh" "$FB/curl"
export PATH="$FB:$PATH"

# The impact root (R2, R3): the real bin/test-impact.sh with a tests/ dir and
# a pinned map. tests/a.sh reaches bin/lib/a.sh; tests/always.sh is `*`.
TI="$T/ti"; mkdir -p "$TI/tests"
scratch_install_closure bin/test-impact.sh "$TI" >/dev/null || exit 1
chmod +x "$TI/bin/test-impact.sh"
for s in always a; do printf '#!/bin/bash\nexit 0\n' > "$TI/tests/$s.sh"; done
printf 'tests/always.sh\t*\ntests/a.sh\tbin/lib/a.sh\n' > "$T/map"

# load <case> <n> — the real libs and the stubs, in the caller's subshell. The
# case's GitHub lives in $C: main.sha, gruns.json (the group run list; gruns.fail
# answers 75), jobs.json, ann.<job>.json, cmp.json (any compare). Each read is
# one line in $C/reads.
load() {
  C="$T/$1"; mkdir -p "$C/tmp" "$C/h/bin" "$C/h/locks"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$C" > "$C/h/bin/lane-alert.sh"; chmod +x "$C/h/bin/lane-alert.sh"
  : >> "$C/alerts"; : > "$C/reads"; : >> "$C/log"; : > "$C/gh.log"
  [ -s "$C/main.sha" ] || mn "$2" > "$C/main.sha"
  MC_H="$C/h"; HARNESS="$C/h"
  . "$DIR/bin/lib/mc/queue.sh"; . "$DIR/bin/lib/mc-prequeue.sh"
  . "$GROUP_FRAG"
  MC_STATE_DIR="$C/state"; MC_TICK_ID="${TICK:-t1}"; MC_TICK_DIR="$C/tick"
  TMPDIR="$C/tmp"; GH_LOG="$C/gh.log"; GH_RC_FILE="$C/gh.rc"; MAIN=$(cat "$C/main.sha")
  export GH_LOG GH_RC_FILE
  mc_safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
  mc_log() { printf '%s\n' "$*" >> "$C/log"; }
  mc_use_token() { :; }
  mc_defer_word() { :; }
  pq_status_gate() { :; }
  pq_restamp() { :; }
  # The merge test is clean (R cases); the PR changes bin/lib/a.sh.
  P=demo
  mc_git_locked() { shift; "$@"; }
  mc_merge_tree() { return 0; }
  mc_pr_files() { printf 'bin/lib/a.sh\n'; }
  _bim_root() { printf '%s\n' "$TI"; }
  gh_rest() {
    printf '%s\n' "$2" >> "$C/reads"
    case "$2" in
      */commits/main) printf '{"sha":"%s"}' "$MAIN" ;;
      */actions/workflows/prequeue-gate.yml) printf '{"path":".github/workflows/prequeue-gate.yml"}' ;;
      */actions/workflows/prequeue-group-gate.yml) printf '{"id":9,"path":".github/workflows/prequeue-group-gate.yml"}' ;;
      */actions/workflows/prequeue-gate.yml/runs\?*) printf '{"workflow_runs":[]}' ;;
      */actions/workflows/prequeue-group-gate.yml/runs\?*)
        [ -e "$C/gruns.fail" ] && return 75
        cat "$C/gruns.json" 2>/dev/null || printf '{"workflow_runs":[]}' ;;
      */actions/runs/*/jobs*) cat "$C/jobs.json" ;;
      */check-runs/*/annotations) local j="${2#*check-runs/}"; j="${j%%/*}"; cat "$C/ann.$j.json" 2>/dev/null || printf '[]' ;;
      */compare/*) cat "$C/cmp.json" 2>/dev/null || return 44 ;;
      *) return 44 ;;
    esac
  }
}
gate() { pq_gate "$SLUG" "$1" "$U/$1" "$2" main >/dev/null; printf '%s %s %s\n' "$1" "$PQ_VERDICT" "$PQ_SUITES"; }
ngroup() { grep -c '^workflow run prequeue-group-gate.yml ' "$1/gh.log" 2>/dev/null; }
nperhead() { grep -c '^workflow run prequeue-gate.yml ' "$1/gh.log" 2>/dev/null; }
GD() { printf '%s/state/prequeue/groups' "$1"; }
nfiles() { local n; n=$(ls "$(GD "$1")/"*."$2" 2>/dev/null | wc -l); printf '%s' "$n"; }
gid() { local f; f=$(ls "$(GD "$1")/"*.run 2>/dev/null | head -1); f="${f##*_}"; printf '%s' "${f%.run}"; }
ogid() { local f; f=$(ls "$(GD "$1")/"*.open 2>/dev/null | head -1); f="${f##*_}"; printf '%s' "${f%.open}"; }
finish_run() {  # finish_run <case> <gid> <main> [status]
  jq -nc --arg t "prequeue group=$2 main=$3" --arg s "${4:-completed}" '{workflow_runs:[{id:7701,display_title:$t,status:$s,conclusion:"success",created_at:"2026-10-27T13:03:00Z"}]}' > "$1/gruns.json"
}
jobs() {
  local c="$1" n="$2" i
  { printf '{"id":899,"name":"plan","conclusion":"success"}\n'
    for i in $(seq 1 "$n"); do jq -nc --argjson id $((900 + i)) '{id:$id,name:"gate (x) / gate",conclusion:"success"}'; done
  } | jq -sc '{total_count: length, jobs: .}' > "$c/jobs.json"
}
ann() {
  local c="$1" j="$2"; shift 2
  for m in "$@"; do jq -nc --arg m "$m" '{title:"prequeue-verdict",message:$m,annotation_level:"notice"}'; done | jq -sc . > "$c/ann.$j.json"
}
# land <case> <casenum> <n> [red index] — the group run completed, one verdict per member.
land() {
  local c="$1" g m i
  g=$(gid "$c"); m=$(cat "$c/main.sha")
  finish_run "$c" "$g" "$m"; jobs "$c" "$3"
  for i in $(seq 1 "$3"); do
    if [ "$i" = "${4:-0}" ]; then ann "$c" $((900 + i)) "red main=$m head=$(hd "$2" "$i") suites=tests/x.sh"
    else ann "$c" $((900 + i)) "green main=$m head=$(hd "$2" "$i") suites="; fi
  done
}
# six <case> <casenum> — 6 heads (#101..#106) gate on one tick, then the flush.
six() { local i; for i in 1 2 3 4 5 6; do gate $((100 + i)) "$(hd "$2" "$i")"; done > "$C/words"; pq_group_flush "$SLUG"; }
# counter <case> <key> — a backstop-unchanged counter in the backstop's own format.
counter() {
  local d="$1/state/backstop-unchanged"; mkdir -p "$d"
  printf '%s\t%s\t%s\n' "$2" 12345 3 > "$d/${2//[^A-Za-z0-9._-]/_}"
}
hascounter() { [ -f "$1/state/backstop-unchanged/${2//[^A-Za-z0-9._-]/_}" ]; }

# wake <case> <main> — wpk_done_prs on the case's state with a gh_rest_var stub:
# wper.json / wgrp.json are the per-head / group completed-run lists, wper.fail
# / wgrp.fail answer 75. Prints the keys, then rc=<n>. Reads go to $C/wreads.
wake() {
  ( gh_rest_var() {
      local -n _v="$1"; printf '%s\n' "$3" >> "$C/wreads"
      case "$3" in
        */prequeue-gate.yml/runs\?*) [ -e "$C/wper.fail" ] && { GH_REST_STATUS=403; return 75; }
          _v=$(cat "$C/wper.json" 2>/dev/null || echo '{"workflow_runs":[]}') ;;
        */prequeue-group-gate.yml/runs\?*) [ -e "$C/wgrp.fail" ] && { GH_REST_STATUS=403; return 75; }
          _v=$(cat "$C/wgrp.json" 2>/dev/null || echo '{"workflow_runs":[]}') ;;
        *) return 44 ;;
      esac
      GH_REST_STATUS=200; return 0; }
    # shellcheck source=bin/lib/wake-prequeue-keys.sh
    . "$WPK_LIB"
    wpk_done_prs "$C/state" "$LSLUG" "$2" 100; echo "rc=$?" )
}
wkeys() { grep -v '^rc=' <<<"$1" | sed '/^$/d' | tr '\n' ' '; }
wrc() { sed -n 's/^rc=//p' <<<"$1" | tail -1; }
# runs <title|status> ... — a workflow_runs body.
runs() {
  local e i=500
  for e in "$@"; do i=$((i + 1)); jq -nc --argjson id "$i" --arg t "${e%|*}" --arg s "${e##*|}" '{id:$id,display_title:$t,status:$s}'; done | jq -sc '{workflow_runs: .}'
}
# mk <case> <num> <head> <main> [gid] [state] — one cache entry (and .group).
mk() {
  local p="$1/state/prequeue/${SLUG//\//_}_$2_$3_$4"
  mkdir -p "${p%/*}"; printf '%s 1793100000 - \n' "${6:-pending}" > "$p"
  [ -n "${5:-}" ] && printf '%s\n' "$5" > "$p.group"
  return 0
}

# ============================================================================
# W1. 6 grouped heads, one completed group run: all 6 woken by one read.
# ============================================================================
( load w1 1; six w1 1 )
C="$T/w1"; M=$(cat "$C/main.sha"); G=$(gid "$C")
[ "$(ngroup "$C")" = 1 ] && [ -n "$G" ] && ok || bad "W1 setup: one group dispatch ($(cat "$C/gh.log"))"
runs "prequeue group=$G main=$M|completed" > "$C/wgrp.json"
o=$(wake "$C" "$M")
[ "$(wrc "$o")" = 0 ] && ok || bad "W1: rc 0 (got $o)"
[ "$(wkeys "$o")" = "$LSLUG#101 $LSLUG#102 $LSLUG#103 $LSLUG#104 $LSLUG#105 $LSLUG#106 " ] && ok || bad "W1: all 6 members printed (got $(wkeys "$o"))"
[ "$(grep -c . "$C/wreads")" = 1 ] && grep -qx "repos/$LSLUG/actions/workflows/prequeue-group-gate.yml/runs?event=workflow_dispatch&head_sha=$M&status=completed&per_page=100" "$C/wreads" \
  && ok || bad "W1: exactly 1 read, the group runs path ($(cat "$C/wreads" 2>/dev/null))"

# W3. 1 per-head + 2 grouped on one main: 2 reads, 3 printed.
C="$T/w3"; M=$(mn 3); mkdir -p "$C"
mk "$C" 7 "$(hd 3 7)" "$M"; mk "$C" 8 "$(hd 3 8)" "$M" g17931063ab12; mk "$C" 9 "$(hd 3 9)" "$M" g17931063ab12
runs "prequeue pr=7 head=$(hd 3 7) main=$M|completed" > "$C/wper.json"
runs "prequeue group=g17931063ab12 main=$M|completed" > "$C/wgrp.json"
o=$(wake "$C" "$M")
[ "$(wrc "$o")" = 0 ] && [ "$(wkeys "$o")" = "$LSLUG#7 $LSLUG#8 $LSLUG#9 " ] && ok || bad "W3: #7 #8 #9 printed, rc 0 (got $o)"
[ "$(grep -c . "$C/wreads")" = 2 ] && grep -q 'prequeue-gate.yml/runs' "$C/wreads" && grep -q 'prequeue-group-gate.yml/runs' "$C/wreads" \
  && ok || bad "W3: 2 reads, one per workflow ($(cat "$C/wreads"))"

# W4/W4b/W4c. Near-miss titles: rc 3, nothing printed.
n=0
for t in "prequeue group=g17931063ab12 main=$(mn 99)" "prequeue group=g17931063ab13 main=$(mn 4)" "prequeue group=g17931063ab12 main=$(mn 4)x"; do
  n=$((n + 1)); C="$T/w4.$n"; M=$(mn 4); mkdir -p "$C"
  mk "$C" 8 "$(hd 4 8)" "$M" g17931063ab12
  runs "$t|completed" > "$C/wgrp.json"
  o=$(wake "$C" "$M")
  [ "$(wrc "$o")" = 3 ] && [ -z "$(wkeys "$o")" ] && ok || bad "W4.$n: '$t' wakes nothing, rc 3 (got $o)"
done

# W5. The group run is in progress: the completed filter leaves it out.
C="$T/w5"; M=$(mn 5); mkdir -p "$C"
mk "$C" 8 "$(hd 5 8)" "$M" g17931063ab12
runs "prequeue group=g17931063ab12 main=$M|in_progress" > "$C/wgrp.json"
o=$(wake "$C" "$M")
[ "$(wrc "$o")" = 3 ] && [ -z "$(wkeys "$o")" ] && ok || bad "W5: an in-progress run wakes nothing, rc 3 (got $o)"

# W6. A member whose entry is already green is not printed.
C="$T/w6"; M=$(mn 6); mkdir -p "$C"
mk "$C" 8 "$(hd 6 8)" "$M" g17931063ab12; mk "$C" 9 "$(hd 6 9)" "$M" g17931063ab12 green
runs "prequeue group=g17931063ab12 main=$M|completed" > "$C/wgrp.json"
o=$(wake "$C" "$M")
[ "$(wrc "$o")" = 0 ] && [ "$(wkeys "$o")" = "$LSLUG#8 " ] && ok || bad "W6: only the pending #8 (got $o)"

# W7. A malformed .group: the head is per-head, no group read.
C="$T/w7"; M=$(mn 7); mkdir -p "$C"
mk "$C" 8 "$(hd 7 8)" "$M" 'not-a-gid'
runs "prequeue group=not-a-gid main=$M|completed" > "$C/wgrp.json"
o=$(wake "$C" "$M")
[ "$(wrc "$o")" = 3 ] && [ "$(grep -c . "$C/wreads")" = 1 ] && grep -q 'prequeue-gate.yml/runs' "$C/wreads" && ok \
  || bad "W7: a malformed gid takes the per-head read only, rc 3 (got $o; reads $(cat "$C/wreads"))"

# W8. The group read fails: fail-open, every pending PR.
C="$T/w8"; M=$(mn 8); mkdir -p "$C"
mk "$C" 7 "$(hd 8 7)" "$M"; mk "$C" 8 "$(hd 8 8)" "$M" g17931063ab12
runs "prequeue pr=7 head=$(hd 8 7) main=$M|completed" > "$C/wper.json"; : > "$C/wgrp.fail"
o=$(wake "$C" "$M")
[ "$(wrc "$o")" = 2 ] && [ "$(wkeys "$o")" = "$LSLUG#7 $LSLUG#8 " ] && ok || bad "W8: rc 2, every pending PR (got $o)"

# W9. One title format.
( . "$DIR/bin/lib/mc-prequeue.sh"; . "$WPK_LIB"
  [ "$(wpk_group_title g1 "$(mn 9)")" = "$(pq_group_title g1 "$(mn 9)")" ] && echo same ) > "$T/w9" 2>/dev/null
[ "$(cat "$T/w9")" = same ] && ok || bad "W9: wpk_group_title equals pq_group_title"

# ============================================================================
# S1. The sweep: a completed group run releases all 6 in one tick.
# ============================================================================
( load s1 11; six s1 11 )
C="$T/s1"; land "$C" 11 6; G=$(gid "$C")
for i in 1 2 3 4 5 6; do counter "$C" "$SLUG#$((100 + i))"; done
counter "$C" "$SLUG#999"; counter "$C" "other/repo#101"
( TICK=t2 load s1 11; declare -F pq_group_release_sweep >/dev/null || echo missing > "$C/s1.nosweep"; mc_pq_group_tick_end "$SLUG" )
[ ! -e "$C/s1.nosweep" ] && ok || bad "S1: pq_group_release_sweep is not defined"
[ "$(grep -c . "$(GD "$C")/$G.verdicts" 2>/dev/null)" = 6 ] && ok || bad "S1: the verdicts file has 6 lines ($(cat "$(GD "$C")/$G.verdicts" 2>/dev/null))"
n=0; for i in 1 2 3 4 5 6; do hascounter "$C" "$SLUG#$((100 + i))" && n=$((n + 1)); done
[ "$n" = 0 ] && ok || bad "S1: the 6 members' backstop counters are gone ($n left)"
hascounter "$C" "$SLUG#999" && ok || bad "S5: a non-member's counter stays"
hascounter "$C" "other/repo#101" && ok || bad "S5b: another repo's counter for #101 stays"
[ -s "$(GD "$C")/$G.released" ] && grep -q "^released [0-9]* 6\$" "$(GD "$C")/$G.released" && ok || bad "S1: a .released marker ($(cat "$(GD "$C")/$G.released" 2>/dev/null))"
grep -qx "PREQUEUE group-release $SLUG group=$G main=$(head -c12 "$C/main.sha") n=6 prs=#101,#102,#103,#104,#105,#106" "$C/log" && ok \
  || bad "S1: one group-release n=6 line ($(grep group- "$C/log"))"
[ "$(ngroup "$C")" = 0 ] && [ "$(nperhead "$C")" = 0 ] && ok || bad "S1: the sweep dispatches nothing ($(cat "$C/gh.log"))"
# The members' own arms now proceed from the verdicts file with 0 new reads.
: > "$C/reads.before"; cp "$C/reads" "$C/reads.before"
( TICK=t3 load s1 11; for i in 1 2 3 4 5 6; do gate $((100 + i)) "$(hd 11 "$i")"; done > "$C/words3" )
[ "$(awk '{print $2}' "$C/words3" | sort -u)" = proceed ] && ok || bad "S1: each member proceeds on its next gate ($(cat "$C/words3"))"
[ "$(grep -c 'prequeue-group-gate.yml/runs\|/jobs\|/annotations' "$C/reads")" = 0 ] && ok || bad "S1: the members' gates read no run again ($(cat "$C/reads"))"

# S1b. One red member: that member parks red, the release does not enqueue it.
( load s1b 12; six s1b 12 )
C="$T/s1b"; land "$C" 12 6 3
( TICK=t2 load s1b 12; mc_pq_group_tick_end "$SLUG"; for i in 1 2 3 4 5 6; do gate $((100 + i)) "$(hd 12 "$i")"; done > "$C/words2" )
[ "$(tr '\n' '|' < "$C/words2")" = "101 proceed |102 proceed |103 red tests/x.sh|104 proceed |105 proceed |106 proceed |" ] && ok \
  || bad "S1b: #103 red, the other 5 proceed (got $(tr '\n' '|' < "$C/words2" 2>/dev/null))"

# S2. The run is not completed: no marker, the counters stay.
( load s2 13; six s2 13 )
C="$T/s2"; finish_run "$C" "$(gid "$C")" "$(cat "$C/main.sha")" in_progress; counter "$C" "$SLUG#101"
( TICK=t2 load s2 13; mc_pq_group_tick_end "$SLUG" )
[ "$(nfiles "$C" released)" = 0 ] && hascounter "$C" "$SLUG#101" && [ ! -s "$(GD "$C")/$(gid "$C").verdicts" ] && ok \
  || bad "S2: an unfinished run releases nothing ($(ls "$(GD "$C")"))"

# S3. A member read the verdicts first: the sweep releases with 0 reads.
( load s3 14; six s3 14 )
C="$T/s3"; land "$C" 14 6
( TICK=t2 load s3 14; gate 101 "$(hd 14 1)" >/dev/null )
counter "$C" "$SLUG#102"
( TICK=t3 load s3 14; mc_pq_group_tick_end "$SLUG" )
[ ! -s "$C/reads" ] && ! hascounter "$C" "$SLUG#102" && [ "$(nfiles "$C" released)" = 1 ] && ok \
  || bad "S3: released with 0 reads ($(cat "$C/reads"); marker $(nfiles "$C" released))"

# S4. Already released: 0 reads, 0 removals.
counter "$C" "$SLUG#103"; : > "$C/log.s4"; cp "$C/log" "$C/log.s4"
( TICK=t4 load s3 14; rm -f "$(GD "$C")/$(gid "$C").verdicts"; mc_pq_group_tick_end "$SLUG" )
[ ! -s "$C/reads" ] && hascounter "$C" "$SLUG#103" && [ "$(grep -c 'group-release' "$C/log")" = 1 ] && ok \
  || bad "S4: a released group is not read or released again (reads $(cat "$C/reads"); $(grep group-release "$C/log"))"

# S6. The run read fails: nothing, the next tick retries.
( load s6 16; six s6 16 )
C="$T/s6"; land "$C" 16 6; : > "$C/gruns.fail"; counter "$C" "$SLUG#101"
( TICK=t2 load s6 16; mc_pq_group_tick_end "$SLUG" )
[ "$(nfiles "$C" released)" = 0 ] && hascounter "$C" "$SLUG#101" && ok || bad "S6: a failed read releases nothing ($(ls "$(GD "$C")"))"
rm -f "$C/gruns.fail"
( TICK=t3 load s6 16; mc_pq_group_tick_end "$SLUG" )
[ "$(nfiles "$C" released)" = 1 ] && ! hascounter "$C" "$SLUG#101" && ok || bad "S6: the next tick releases ($(ls "$(GD "$C")"))"

# S7. No .run file: no read, no lock, no marker.
( load s7 17; mc_pq_group_tick_end "$SLUG" )
C="$T/s7"
[ ! -s "$C/reads" ] && [ ! -s "$C/gh.log" ] && [ -z "$(ls -A "$C/h/locks")" ] && [ ! -d "$(GD "$C")" ] && ok \
  || bad "S7: no group, no call (reads $(cat "$C/reads"); locks $(ls "$C/h/locks"))"

# Z2. No alert in the S cases.
n=0; for c in s1 s1b s2 s3 s6 s7; do [ -s "$T/$c/alerts" ] && n=$((n + 1)); done
[ "$n" = 0 ] && ok || bad "Z2: 0 lane-alert calls in the S cases ($(cat "$T"/s*/alerts))"

# ============================================================================
# J. A re-gate joins one group across runs.
# ============================================================================
# J1 + J7: 3 runs on one main, then each run flushes.
for k in 1 2 3; do ( TICK=t$k load j1 21; gate $((100 + k)) "$(hd 21 "$k")" > "$C/words.$k" ); done
C="$T/j1"
[ "$(nfiles "$C" open)" = 1 ] && [ "$(tail -n +2 "$(ls "$(GD "$C")/"*.open)" | grep -c .)" = 3 ] && ok \
  || bad "J1: 3 runs, one open group of 3 ($(ls "$(GD "$C")"); $(grep group-join "$C/log"))"
( TICK=t3 load j1 21; pq_group_flush "$SLUG"; cp "$C/gh.log" "$C/gh.t3" )
( TICK=t1 load j1 21; pq_group_flush "$SLUG"; cp "$C/gh.log" "$C/gh.t1" )
( TICK=t2 load j1 21; pq_group_flush "$SLUG"; cp "$C/gh.log" "$C/gh.t2" )
W="101:$(hd 21 1),102:$(hd 21 2),103:$(hd 21 3)"
[ "$(grep -c '^workflow run prequeue-group-gate.yml ' "$C/gh.t3")" = 1 ] && grep -q -- "-f members=$W\$" "$C/gh.t3" && ok \
  || bad "J7: the run that joined flushes the group: 1 dispatch naming all 3 ($(cat "$C/gh.t3"); $(grep group- "$C/log"))"
[ ! -s "$C/gh.t1" ] && [ ! -s "$C/gh.t2" ] && ok || bad "J1: the other runs' flushes dispatch nothing ($(cat "$C/gh.t1" "$C/gh.t2"))"
[ -z "$(ls "$(GD "$C")/"*.joined.* 2>/dev/null)" ] && ok || bad "J7: the dispatch removes the .joined markers ($(ls "$(GD "$C")"))"
grep -q 'group-abandon' "$C/log" && bad "J1: nothing is abandoned ($(grep group-abandon "$C/log"))" || ok

# J2. One tick, 3 heads: one group, as before.
( load j2 22; for k in 1 2 3; do gate $((100 + k)) "$(hd 22 "$k")"; done >/dev/null; pq_group_flush "$SLUG" )
C="$T/j2"
[ "$(ngroup "$C")" = 1 ] && grep -q -- "-f members=101:$(hd 22 1),102:$(hd 22 2),103:$(hd 22 3)\$" "$C/gh.log" && ok || bad "J2: one group of 3 ($(cat "$C/gh.log"))"

# J3. The knob 0: the BH-8327 rule, 3 groups of 1.
for k in 1 2 3; do ( export MC_PREQUEUE_GROUP_SHARE_S=0; TICK=t$k load j3 23; gate $((100 + k)) "$(hd 23 "$k")" >/dev/null ); done
C="$T/j3"
[ "$(nfiles "$C" open)" = 3 ] && ok || bad "J3: knob 0, 3 open groups ($(ls "$(GD "$C")"))"

# J4. A group older than the knob: a new group.
( TICK=t1 load j4 24; gate 101 "$(hd 24 1)" >/dev/null )
C="$T/j4"; f=$(ls "$(GD "$C")/"*.open); read -r st oat tk m < "$f"
{ printf 'open %s %s %s\n' $((oat - 400)) "$tk" "$m"; tail -n +2 "$f"; } > "$f.x" && mv "$f.x" "$f"
( TICK=t2 load j4 24; gate 102 "$(hd 24 2)" >/dev/null )
[ "$(nfiles "$C" open)" = 2 ] && ok || bad "J4: an old group is not joined ($(ls "$(GD "$C")"))"

# J5. Another main: a new group.
( TICK=t1 load j5 25; gate 101 "$(hd 25 1)" >/dev/null )
C="$T/j5"; mn 125 > "$C/main.sha"
( TICK=t2 load j5 25; gate 102 "$(hd 25 2)" >/dev/null )
[ "$(nfiles "$C" open)" = 2 ] && ok || bad "J5: another main opens its own group ($(ls "$(GD "$C")"))"

# J6. A full group opens the next one.
for k in 1 2 3; do ( export MC_PREQUEUE_GROUP_MAX=2; TICK=t$k load j6 26; gate $((100 + k)) "$(hd 26 "$k")" >/dev/null ); done
C="$T/j6"
[ "$(nfiles "$C" open)" = 2 ] && [ "$(for f in "$(GD "$C")/"*.open; do tail -n +2 "$f" | grep -c .; done | sort | tr '\n' ' ')" = "1 2 " ] && ok \
  || bad "J6: MAX=2, groups of 2 and 1 ($(ls "$(GD "$C")"))"

# J8. A run with no member: abandoned, as BH-8327 G6.
( TICK=t1 load j8 27; gate 101 "$(hd 27 1)" >/dev/null; MC_TICK_ID=t9; pq_group_flush "$SLUG" )
C="$T/j8"
[ "$(ngroup "$C")" = 0 ] && grep -q 'group-abandon .* n=1 (the group is from another run)' "$C/log" && [ -z "$(ls "$(GD "$C")/"*.joined.* 2>/dev/null)" ] && ok \
  || bad "J8: a run with no member abandons, 0 dispatch ($(cat "$C/gh.log"); $(grep group- "$C/log"))"

# J8b. A joined group older than the knob: abandoned.
( TICK=t1 load j8b 28; gate 101 "$(hd 28 1)" >/dev/null )
( TICK=t2 load j8b 28; gate 102 "$(hd 28 2)" >/dev/null )
C="$T/j8b"; f=$(ls "$(GD "$C")/"*.open); read -r st oat tk m < "$f"
{ printf 'open %s %s %s\n' $((oat - 400)) "$tk" "$m"; tail -n +2 "$f"; } > "$f.x" && mv "$f.x" "$f"
( TICK=t2 load j8b 28; pq_group_flush "$SLUG" )
[ "$(ngroup "$C")" = 0 ] && grep -q 'group-abandon .* n=2 (the group is from another run)' "$C/log" && ok \
  || bad "J8b: an old joined group is abandoned ($(cat "$C/gh.log"); $(grep group- "$C/log"))"

# ============================================================================
# R. The incident: a group passes on M1, then main moves.
# ============================================================================
# rfix <case> <casenum> <ahead_by> <main file> — the group passes on M1 (6
# green, verdicts read by the sweep), main moves to M2.
rfix() {
  ( load "$1" "$2"; six "$1" "$2" )
  land "$T/$1" "$2" 6
  ( TICK=t2 load "$1" "$2"; mc_pq_group_tick_end "$SLUG" )
  cat "$T/$1/main.sha" > "$T/$1/main1.sha"; mn $(($2 + 100)) > "$T/$1/main.sha"
  jq -nc --argjson n "$3" --arg f "$4" '{status:"ahead",ahead_by:$n,files:[{filename:$f}]}' > "$T/$1/cmp.json"
}
# pq_ir_map honours the pinned map only under HARNESS_TEST_SANDBOX=1, and the
# traced CI corpus does not set it (harness-ci.yml, #388), so the R cases set it
# themselves, as tests/prequeue-reuse.bh-6924-test.sh does.
export HARNESS_REPO="$SLUG" MC_PREQUEUE_IMPACT_MAP="$T/map" HARNESS_TEST_SANDBOX=1
# R1. One unrelated commit: the fresh rule reuses every green.
rfix r1 31 1 docs/x.md
( TICK=t5 load r1 31; for i in 1 2 3 4 5 6; do gate $((100 + i)) "$(hd 31 "$i")"; done > "$C/words5"; pq_group_flush "$SLUG" )
C="$T/r1"
[ "$(awk '{print $2}' "$C/words5" | sort | uniq -c | tr -s ' ')" = " 6 proceed" ] && ok || bad "R1: 6 proceed on M2 ($(cat "$C/words5"); $(grep reuse "$C/log" | tail -3))"
[ "$(ngroup "$C")" = 0 ] && [ "$(nperhead "$C")" = 0 ] && [ "$(nfiles "$C" open)" = 0 ] && [ "$(nfiles "$C" run)" = 1 ] && ok \
  || bad "R1: 0 new dispatches, no new group ($(cat "$C/gh.log"); $(ls "$(GD "$C")"))"
# R2. Six commits (the incident), disjoint from the impact map: impact reuse.
rfix r2 32 6 docs/x.md
( TICK=t5 load r2 32; for i in 1 2 3 4 5 6; do gate $((100 + i)) "$(hd 32 "$i")"; done > "$C/words5"; pq_group_flush "$SLUG" )
C="$T/r2"; M2=$(cat "$C/main.sha")
[ "$(awk '{print $2}' "$C/words5" | sort | uniq -c | tr -s ' ')" = " 6 proceed" ] && ok || bad "R2: 6 proceed through impact reuse ($(cat "$C/words5"); $(grep reuse "$C/log" | tail -3))"
[ "$(ngroup "$C")" = 0 ] && [ "$(nperhead "$C")" = 0 ] && [ "$(nfiles "$C" open)" = 0 ] && [ "$(nfiles "$C" run)" = 1 ] && ok \
  || bad "R2: 0 new dispatches, no new group ($(cat "$C/gh.log"); $(ls "$(GD "$C")"))"
n=0; for i in 1 2 3 4 5 6; do grep -q 'reason=impact-disjoint' "$C/state/prequeue/${SLUG//\//_}_$((100 + i))_$(hd 32 "$i")_$M2.reuse" 2>/dev/null && n=$((n + 1)); done
[ "$n" = 6 ] && ok || bad "R2: a .reuse sidecar per member ($n of 6)"
# R3. The move hits the reach: each member asks from its own tick id, ONE group.
rfix r3 33 6 bin/lib/a.sh
for i in 1 2 3 4 5 6; do ( TICK=t1$i load r3 33; gate $((100 + i)) "$(hd 33 "$i")" >> "$C/words5" ); done
for i in 1 2 3 4 5 6; do ( TICK=t1$i load r3 33; pq_group_flush "$SLUG"; cat "$C/gh.log" >> "$C/gh.all" ); done
C="$T/r3"; W="$(for i in 1 2 3 4 5 6; do printf '%s%s:%s' "$([ "$i" = 1 ] || echo ,)" $((100 + i)) "$(hd 33 "$i")"; done)"
[ "$(awk '{print $2}' "$C/words5" | sort -u)" = hold ] && ok || bad "R3: each member holds for a re-gate ($(cat "$C/words5"))"
[ "$(grep -c '^workflow run prequeue-group-gate.yml ' "$C/gh.all" 2>/dev/null)" = 1 ] && grep -q -- "-f members=$W\$" "$C/gh.all" && ok \
  || bad "R3: ONE group dispatch naming all 6 ($(cat "$C/gh.all" 2>/dev/null); $(grep 'group-' "$C/log" | tail -8))"
unset HARNESS_REPO MC_PREQUEUE_IMPACT_MAP

# ============================================================================
# Z. No vendor call; the knob row.
# ============================================================================
[ ! -e "$T/curl-calls" ] && ok || bad "Z1: 0 curl calls ($(cat "$T/curl-calls"))"
[ ! -e "$T/gh-orphan.log" ] && ok || bad "Z1: every gh call went to a case's stub log ($(cat "$T/gh-orphan.log"))"
[ "$(command -v gh)" = "$FB/gh" ] && ok || bad "Z1: gh resolves to the stub ($(command -v gh))"
d=$( ( unset MC_PREQUEUE_GROUP_SHARE_S; . "$DIR/bin/lib/mc-prequeue.sh"; pq_knob MC_PREQUEUE_GROUP_SHARE_S ) 2>/dev/null)
[ -r "$KNOB_JSON" ] && [ "$(jq -r '.default' "$KNOB_JSON")" = "$d" ] && [ "$d" = 300 ] \
  && [ "$(jq -r '.read_in' "$KNOB_JSON")" = bin/lib/mc-prequeue.d/group.sh ] && ok \
  || bad "Z3: the knob default ($d) equals its JSON row ($(cat "$KNOB_JSON" 2>/dev/null | head -4))"

echo "prequeue-group-release.bh-8610: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
