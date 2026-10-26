#!/bin/bash
# tests/prequeue-group.bh-8327-test.sh — BH-8327: one pre-queue gate run per
# main sha for a group of READY heads. bin/lib/mc-prequeue.d/group.sh joins a
# head that would dispatch prequeue-gate.yml to the open group of its repo and
# main; pq_group_flush dispatches ONE prequeue-group-gate.yml run per group
# after the PR workers; pq_group_read gives each head its own verdict row from
# that run, once per group.
#
#   G1   5 heads, one main: 5 holds, then 1 group dispatch naming all 5, no
#        per-head dispatch, a .run file and a group-dispatch n=5 line
#   G1E  the real bin/merge-conductor.sh tick with 5 READY rows: 1 group
#        dispatch, 0 per-head dispatches, 0 enqueues
#   G2   the group run completed, 4 green and 1 red: 4 proceed, 1 red with its
#        suites; reads: 1 run list + 1 jobs + 5 annotations in total
#   G3   a 6th head after the flush opens a new group; group 1 is not re-run
#   G4   MC_PREQUEUE_GROUP=0: 5 per-head dispatches, no group file
#   G5   join 2, then the knob to 0 and flush: abandoned, 0 dispatch, the
#        members dispatch per head next
#   G6   an open group of another tick: abandoned, 0 dispatch
#   G7   the group dispatch is refused: each member could-not-run alerted,
#        exactly 1 alert, .refused; each member proceeds next
#   G8   one gate job concluded failure: that head could-not-run (1 alert),
#        the other 4 keep their verdicts
#   G9   MC_PREQUEUE_GROUP_MAX=2, 5 heads: 3 group runs of 2, 2 and 1
#   G10  the group workflow probe 404 (G10b: rc 75, G10c: a 200 that names
#        another path): per-head dispatch
#   G11  a per-PR machine run: hold, the defer word, 0 dispatch, no group
#        file; with the project lease and its fence: it joins
#   G12  a named-suites dispatch (batch-solo) stays per head with the knob on
#   G13  the workflows: inputs, the reusable call, the run-name, the main-red
#        skip regex, and a dry run of the plan step
#   G14  0 curl calls, the gh on PATH is the stub; the knob defaults
#   G15  near misses: an unknown head, a main mismatch, two verdicts for one
#        head, a red with no suites, a run title one character off
#   G16  5 gates at once: one group file, 5 members, no duplicate
#   G17  a member whose entry is no longer pending is not dispatched
#   G17b the fragment: no lib = rc 0 and no call; no open group = no gh call
#
# Driven, not grepped: the unit cases source the real bin/lib/mc-prequeue.sh
# (every hook in bin/lib/mc-prequeue.d/, group.sh included) and call pq_gate,
# the conductor's own entry, and pq_group_flush, the conductor's own call.
# GitHub is gh_rest (a function) and gh (a stub on PATH); 0 real calls.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prequeue-group.bh-8327-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping";    exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
GROUP_LIB="$DIR/bin/lib/mc-prequeue.d/group.sh"
GROUP_FRAG="$DIR/bin/merge-conductor.d/bh-8327-prequeue-group.sh"
GROUP_WF="$DIR/.github/workflows/prequeue-group-gate.yml"
GATE_WF="$DIR/.github/workflows/prequeue-gate.yml"
[ -r "$GROUP_LIB" ] || bad "setup: bin/lib/mc-prequeue.d/group.sh is missing"
[ -r "$GROUP_WF" ] || bad "setup: .github/workflows/prequeue-group-gate.yml is missing"
[ -r "$GROUP_FRAG" ] || bad "setup: bin/merge-conductor.d/bh-8327-prequeue-group.sh is missing"

SLUG=example-org/demo
U="https://github.com/$SLUG/pull"
# hd <case> <i> — a unique 40-hex head; mn <case> — a unique main.
hd() { printf '%02x%02x%036d' "$1" "$2" 0; }
mn() { printf 'ee%02x%036d' "$1" 0; }

# The stubs on PATH: gh records its argv and answers $GH_RC_FILE; curl records
# any call (G14). Nothing here reaches a network.
FB="$T/fakebin"; mkdir -p "$FB"
cat > "$FB/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "\${GH_LOG:-$T/gh-orphan.log}"
exit "\$(cat "\${GH_RC_FILE:-/nonexistent}" 2>/dev/null || echo 0)"
EOF
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/curl-calls"\nexit 7\n' "$T" > "$FB/curl"
chmod +x "$FB/gh" "$FB/curl"
export PATH="$FB:$PATH"

# load <case> — the real libs and the stubs, in the caller's subshell. The
# case's GitHub lives in $C: main.sha, gruns.json (the group run list),
# jobs.json, ann.<job id>.json; no-gwf / gwf-rc / gwf-body shape the group
# workflow probe. Every read is one line in $C/reads.
load() {
  C="$T/$1"; mkdir -p "$C/tmp" "$C/h/bin" "$C/h/locks"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$C" > "$C/h/bin/lane-alert.sh"; chmod +x "$C/h/bin/lane-alert.sh"
  : > "$C/alerts"; : > "$C/reads"; : > "$C/log"; : > "$C/gh.log"
  [ -s "$C/main.sha" ] || mn "$2" > "$C/main.sha"
  MC_H="$C/h"; HARNESS="$C/h"
  . "$DIR/bin/lib/mc/queue.sh"; . "$DIR/bin/lib/mc-prequeue.sh"
  MC_STATE_DIR="$C/state"; MC_TICK_ID="${TICK:-t1}"; MC_TICK_DIR="$C/tick"
  TMPDIR="$C/tmp"; GH_LOG="$C/gh.log"; GH_RC_FILE="$C/gh.rc"; MAIN=$(cat "$C/main.sha")
  export GH_LOG GH_RC_FILE
  mc_safe_name() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
  mc_log() { printf '%s\n' "$*" >> "$C/log"; }
  mc_use_token() { :; }
  mc_defer_word() { printf '%s\n' "$1" >> "$MC_PR_DEFERRED_FILE"; }
  pq_status_gate() { :; }
  pq_restamp() { :; }
  pq_impact_reuse() { _pq_ir=none; }
  gh_rest() {
    printf '%s\n' "$2" >> "$C/reads"
    case "$2" in
      */commits/main) printf '{"sha":"%s"}' "$MAIN" ;;
      */actions/workflows/prequeue-gate.yml) printf '{"path":".github/workflows/prequeue-gate.yml"}' ;;
      */actions/workflows/prequeue-group-gate.yml)
        [ -e "$C/no-gwf" ] && return 44
        [ -s "$C/gwf-rc" ] && return "$(cat "$C/gwf-rc")"
        if [ -s "$C/gwf-body" ]; then cat "$C/gwf-body"; else printf '{"id":9,"path":".github/workflows/prequeue-group-gate.yml"}'; fi ;;
      */actions/workflows/prequeue-gate.yml/runs\?*) printf '{"workflow_runs":[]}' ;;
      */actions/workflows/prequeue-group-gate.yml/runs\?*) cat "$C/gruns.json" 2>/dev/null || printf '{"workflow_runs":[]}' ;;
      */actions/runs/*/jobs*) cat "$C/jobs.json" ;;
      */check-runs/*/annotations) local j="${2#*check-runs/}"; j="${j%%/*}"; cat "$C/ann.$j.json" 2>/dev/null || printf '[]' ;;
      *) return 44 ;;
    esac
  }
}
# gate <num> <head> — the conductor's call; prints `<num> <verdict> <suites>`.
gate() { pq_gate "$SLUG" "$1" "$U/$1" "$2" main >/dev/null; printf '%s %s %s\n' "$1" "$PQ_VERDICT" "$PQ_SUITES"; }
ngroup()  { grep -c '^workflow run prequeue-group-gate.yml ' "$1/gh.log" 2>/dev/null; }
nperhead() { grep -c '^workflow run prequeue-gate.yml ' "$1/gh.log" 2>/dev/null; }
entry() { head -n1 "$1/state/prequeue/${SLUG//\//_}_$2_$3_$(cat "$1/main.sha")" 2>/dev/null; }
# gid <case> — the one group id of the case's .run file.
gid() { local f; f=$(ls "$1/state/prequeue/groups/"*.run 2>/dev/null | head -1); f="${f##*_}"; printf '%s' "${f%.run}"; }
# finish_run <case> <gid> <main> — the group run in the list, completed, with a
# plan job and one gate job per member (ids 900+i); ann <case> <job> <msg>...
finish_run() {
  jq -nc --arg t "prequeue group=$2 main=$3" '{workflow_runs:[{id:7701,display_title:$t,status:"completed",conclusion:"success",created_at:"2026-10-25T01:00:00Z"}]}' > "$1/gruns.json"
}
jobs() {  # jobs <case> <n> [failed job id]
  local c="$1" n="$2" f="${3:-}" i
  { printf '{"id":899,"name":"plan","conclusion":"success"}\n'
    for i in $(seq 1 "$n"); do
      jq -nc --argjson id $((900 + i)) --arg c "$([ "$((900 + i))" = "$f" ] && echo failure || echo success)" '{id:$id,name:"gate (x) / gate",conclusion:$c}'
    done; } | jq -sc '{total_count: length, jobs: .}' > "$c/jobs.json"
}
ann() {
  local c="$1" j="$2"; shift 2
  { printf '%s\n' '{"title":"other","message":"x"}'
    for m in "$@"; do jq -nc --arg m "$m" '{title:"prequeue-verdict",message:$m,annotation_level:"notice"}'; done; } | jq -sc . > "$c/ann.$j.json"
}

# ============================================================================
# G1. 5 heads, one main: 5 holds, then ONE group dispatch.
# ============================================================================
g1_setup() {  # g1_setup <case> <n> — n heads join, then the flush (in the subshell)
  local i
  for i in $(seq 1 "$2"); do gate $((100 + i)) "$(hd "$1" "$i")"; done > "$C/words"
  pq_group_flush "$SLUG"
}
( load g1 1; g1_setup 1 5 )
C="$T/g1"; M1=$(cat "$C/main.sha")
[ "$(awk '{print $2}' "$C/words" | sort | uniq -c | tr -s ' ')" = " 5 hold" ] && ok || bad "G1: 5 gates answer hold (got $(cat "$C/words"); log $(cat "$C/log"))"
[ "$(ngroup "$C")" = 1 ] && ok || bad "G1: exactly 1 group dispatch (gh: $(cat "$C/gh.log"); log $(tail -5 "$C/log"))"
[ "$(nperhead "$C")" = 0 ] && ok || bad "G1: 0 per-head dispatches (gh: $(cat "$C/gh.log"))"
W="$(for i in 1 2 3 4 5; do printf '%s%s:%s' "$([ $i = 1 ] || echo ,)" $((100 + i)) "$(hd 1 $i)"; done)"
grep -qF -- "workflow run prequeue-group-gate.yml -R $SLUG --ref main -f main=$M1 -f group_id=$(gid "$C") -f members=$W" "$C/gh.log" && ok \
  || bad "G1: the dispatch argv names main, the group and all 5 members (got $(cat "$C/gh.log"); want members=$W)"
[ "$(ls "$C/state/prequeue/groups/"*.run 2>/dev/null | wc -l)" = 1 ] && [ -z "$(ls "$C/state/prequeue/groups/"*.open 2>/dev/null)" ] && ok \
  || bad "G1: one .run file and no .open file ($(ls "$C/state/prequeue/groups/" 2>/dev/null | tr '\n' ' '))"
grep -q "^PREQUEUE group-dispatch $SLUG main=${M1:0:12} group=$(gid "$C") n=5 prs=#101,#102,#103,#104,#105\$" "$C/log" && ok \
  || bad "G1: one group-dispatch n=5 line ($(grep group- "$C/log"))"
[ "$(grep -c 'PREQUEUE group-join' "$C/log")" = 5 ] && ok || bad "G1: 5 group-join lines ($(grep group-join "$C/log"))"
for i in 1 2 3 4 5; do
  case "$(entry "$C" $((100 + i)) "$(hd 1 $i)")" in "pending "*" -"*) ok ;; *) bad "G1: #$((100 + i)) is pending (got '$(entry "$C" $((100 + i)) "$(hd 1 $i)")')" ;; esac
done
[ "$(cat "$C/state/prequeue/${SLUG//\//_}_101_$(hd 1 1)_$M1.group" 2>/dev/null)" = "$(gid "$C")" ] && ok || bad "G1: the .group sidecar names the group"
printf '%s\n' "$W" > "$T/g1.members"

# ============================================================================
# G2. The group run lands: 4 green, 1 red. Each head its own row.
# ============================================================================
g2_land() {  # g2_land <case> <casenum> [failed job]: the run, 5 jobs, one verdict per job (#103 red)
  local c="$1" g m i
  g=$(gid "$c"); m=$(cat "$c/main.sha")
  finish_run "$c" "$g" "$m"; jobs "$c" 5 "${3:-}"
  for i in 1 2 3 4 5; do
    if [ "$i" = 3 ]; then ann "$c" $((900 + i)) "red main=$m head=$(hd "$2" $i) suites=tests/x.sh"
    else ann "$c" $((900 + i)) "green main=$m head=$(hd "$2" $i) suites="; fi
  done
}
( load g2 2; g1_setup 2 5 )
g2_land "$T/g2" 2
( TICK=t2 load g2 2
  for i in 1 2 3 4 5; do gate $((100 + i)) "$(hd 2 "$i")"; done > "$C/words2" )
C="$T/g2"
[ "$(tr '\n' '|' < "$C/words2")" = "101 proceed |102 proceed |103 red tests/x.sh|104 proceed |105 proceed |" ] && ok || bad "G2: 4 proceed, #103 red with its suite (got $(tr '\n' '|' < "$C/words2"); log $(tail -5 "$C/log"))"
for i in 1 2 4 5; do
  case "$(entry "$C" $((100 + i)) "$(hd 2 $i)")" in "green "*" 7701 "*) ok ;; *) bad "G2: #$((100 + i)) recorded green from run 7701 (got '$(entry "$C" $((100 + i)) "$(hd 2 $i)")')" ;; esac
done
case "$(entry "$C" 103 "$(hd 2 3)")" in "red "*" 7701 tests/x.sh") ok ;; *) bad "G2: #103 recorded red tests/x.sh (got '$(entry "$C" 103 "$(hd 2 3)")')" ;; esac
[ "$(grep -c 'prequeue-group-gate.yml/runs' "$C/reads")" = 1 ] && [ "$(grep -c '/jobs' "$C/reads")" = 1 ] && [ "$(grep -c '/annotations' "$C/reads")" = 5 ] && ok \
  || bad "G2: 1 run list + 1 jobs + 5 annotation reads (got $(grep -c 'group-gate.yml/runs' "$C/reads")/$(grep -c '/jobs' "$C/reads")/$(grep -c '/annotations' "$C/reads"))"
grep -q "/jobs?per_page=11\$" "$C/reads" && ok || bad "G2: the jobs read asks for MAX + 1 jobs ($(grep /jobs "$C/reads"))"
grep -q "^PREQUEUE group-read $SLUG group=$(gid "$C") run=7701 green=4 red=1 other=0\$" "$C/log" && ok || bad "G2: one group-read line ($(grep group-read "$C/log"))"
# gh.log holds the second tick's calls only (load starts it empty).
[ "$(nperhead "$C")" = 0 ] && [ "$(ngroup "$C")" = 0 ] && ok || bad "G2: nothing dispatched on the read tick ($(cat "$C/gh.log"))"
[ -s "$C/alerts" ] && bad "G2: a verdict is no alert ($(cat "$C/alerts"))" || ok

# ============================================================================
# G3. A 6th head after the flush: a new group; group 1 is never re-run.
# ============================================================================
( load g3 3; g1_setup 3 5 )
( TICK=t2 load g3 3; gate 106 "$(hd 3 6)" > "$C/words2"; pq_group_flush "$SLUG"; cat "$C/gh.log" > "$C/gh2.log" )
C="$T/g3"
grep -q '^106 hold' "$C/words2" && ok || bad "G3: the 6th head holds ($(cat "$C/words2"))"
[ "$(grep -c '^workflow run prequeue-group-gate.yml ' "$C/gh2.log")" = 1 ] && grep -q -- "-f members=106:$(hd 3 6)\$" "$C/gh2.log" && ok \
  || bad "G3: the next flush dispatches 1 run with only the 6th head ($(cat "$C/gh2.log"))"
[ "$(ls "$C/state/prequeue/groups/"*.run | wc -l)" = 2 ] && ok || bad "G3: two dispatched groups ($(ls "$C/state/prequeue/groups/"))"

# ============================================================================
# G4. The kill knob: one run per head, as before.
# ============================================================================
( load g4 4; export MC_PREQUEUE_GROUP=0; g1_setup 4 5 )
C="$T/g4"
[ "$(nperhead "$C")" = 5 ] && [ "$(ngroup "$C")" = 0 ] && ok || bad "G4: 5 per-head dispatches, 0 group (gh: $(cat "$C/gh.log"))"
[ -z "$(ls -A "$C/state/prequeue/groups" 2>/dev/null)" ] && ok || bad "G4: no group file ($(ls "$C/state/prequeue/groups"))"
[ "$(awk '{print $2}' "$C/words" | sort -u)" = hold ] && ok || bad "G4: each per-head dispatch holds ($(cat "$C/words"))"

# ============================================================================
# G5. Joined, then the knob to 0 before the flush: abandoned.
# ============================================================================
( load g5 5; gate 101 "$(hd 5 1)" >/dev/null; gate 102 "$(hd 5 2)" >/dev/null
  MC_PREQUEUE_GROUP=0 pq_group_flush "$SLUG"; cp "$C/gh.log" "$C/gh.flush"
  MC_PREQUEUE_GROUP=0; export MC_PREQUEUE_GROUP; gate 101 "$(hd 5 1)" >/dev/null; gate 102 "$(hd 5 2)" >/dev/null )
C="$T/g5"
[ ! -s "$C/gh.flush" ] && ok || bad "G5: the abandon dispatches nothing ($(cat "$C/gh.flush"))"
grep -q "^PREQUEUE group-abandon $SLUG main=$(head -c12 "$C/main.sha") group=g[0-9a-f]* n=2 (MC_PREQUEUE_GROUP=0)" "$C/log" && ok || bad "G5: one group-abandon line ($(grep group- "$C/log"))"
[ -z "$(ls "$C/state/prequeue/groups/" 2>/dev/null)" ] && ok || bad "G5: the group file is gone ($(ls "$C/state/prequeue/groups/"))"
[ "$(nperhead "$C")" = 2 ] && ok || bad "G5: next, both heads dispatch per head ($(cat "$C/gh.log"))"
[ ! -e "$C/state/prequeue/${SLUG//\//_}_101_$(hd 5 1)_$(cat "$C/main.sha").group" ] && ok || bad "G5: the .group sidecar is removed"

# ============================================================================
# G6. An open group of another tick: abandoned, nothing dispatched.
# ============================================================================
( load g6 6; gate 101 "$(hd 6 1)" >/dev/null; MC_TICK_ID=t9; pq_group_flush "$SLUG" )
C="$T/g6"
[ "$(ngroup "$C")" = 0 ] && grep -q 'group-abandon .* n=1 (the group is from another run)' "$C/log" && ok || bad "G6: abandoned, 0 dispatch ($(cat "$C/gh.log"); $(grep group- "$C/log"))"
[ -z "$(entry "$C" 101 "$(hd 6 1)")" ] && ok || bad "G6: the member's pending entry is removed (got '$(entry "$C" 101 "$(hd 6 1)")')"

# ============================================================================
# G7. The group dispatch is refused.
# ============================================================================
mkdir -p "$T/g7"; echo 1 > "$T/g7/gh.rc"
( load g7 7; g1_setup 7 5; rm -f "$C/gh.rc"; for i in 1 2 3 4 5; do gate $((100 + i)) "$(hd 7 "$i")"; done > "$C/words2" )
C="$T/g7"
for i in 1 2 3 4 5; do
  case "$(entry "$C" $((100 + i)) "$(hd 7 $i)")" in "could-not-run "[0-9]*" group-dispatch-refused alerted"*) ok ;; *) bad "G7: #$((100 + i)) could-not-run alerted (got '$(entry "$C" $((100 + i)) "$(hd 7 $i)")')" ;; esac
done
[ "$(grep -c . "$C/alerts")" = 1 ] && grep -q "prequeue group g[0-9a-f]* on main .* (group-dispatch-refused) for #101,#102,#103,#104,#105" "$C/alerts" && ok \
  || bad "G7: exactly 1 alert naming the group and its PRs ($(cat "$C/alerts"))"
[ "$(ls "$C/state/prequeue/groups/"*.refused 2>/dev/null | wc -l)" = 1 ] && ok || bad "G7: a .refused file ($(ls "$C/state/prequeue/groups/"))"
grep -q 'PREQUEUE group-dispatch' "$C/log" && bad "G7: no group-dispatch line on a refusal" || ok
[ "$(awk '{print $2}' "$C/words2" | sort -u)" = proceed ] && ok || bad "G7: each member proceeds next ($(cat "$C/words2"))"
[ "$(nperhead "$C")" = 0 ] && ok || bad "G7: no per-head dispatch after the refusal ($(cat "$C/gh.log"))"

# ============================================================================
# G8. One gate job concluded failure: only that head is could-not-run.
# ============================================================================
( load g8 8; g1_setup 8 5 )
g2_land "$T/g8" 8 904
( TICK=t2 load g8 8; for i in 1 2 3 4 5; do gate $((100 + i)) "$(hd 8 "$i")"; done > "$C/words2" )
C="$T/g8"
[ "$(cat "$C/words2" | tr '\n' '|')" = "101 proceed |102 proceed |103 red tests/x.sh|104 proceed |105 proceed |" ] && ok || bad "G8: #104 proceeds (could-not-run), the rest keep theirs ($(tr '\n' '|' < "$C/words2"))"
case "$(entry "$C" 104 "$(hd 8 4)")" in "could-not-run "*" annotation-count-0 alerted"*) ok ;; *) bad "G8: #104 could-not-run annotation-count-0 (got '$(entry "$C" 104 "$(hd 8 4)")')" ;; esac
[ "$(grep -c . "$C/alerts")" = 1 ] && grep -q "#104 prequeue gate could-not-run on head $(hd 8 4 | cut -c1-12)" "$C/alerts" && ok || bad "G8: one alert, for #104 ($(cat "$C/alerts"))"
[ "$(grep -c '/annotations' "$C/reads")" = 4 ] && ok || bad "G8: a failed job's annotations are not read ($(grep -c /annotations "$C/reads"))"

# ============================================================================
# G9. A full group opens the next one.
# ============================================================================
( load g9 9; export MC_PREQUEUE_GROUP_MAX=2; g1_setup 9 5 )
C="$T/g9"
[ "$(ngroup "$C")" = 3 ] && ok || bad "G9: 3 group dispatches ($(cat "$C/gh.log"))"
[ "$(sed -n 's/.*-f members=\([^ ]*\).*/\1/p' "$C/gh.log" | awk -F, '{print NF}' | sort | tr '\n' ' ')" = "1 2 2 " ] && ok || bad "G9: of 2, 2 and 1 members ($(cat "$C/gh.log"))"

# ============================================================================
# G10. No group workflow, or a probe that cannot be read: per head.
# ============================================================================
mkdir -p "$T/g10" "$T/g10b" "$T/g10c"; touch "$T/g10/no-gwf"; echo 75 > "$T/g10b/gwf-rc"
echo '{"id":5,"path":".github/workflows/prequeue-gate.yml"}' > "$T/g10c/gwf-body"
for c in g10 g10b g10c; do
  ( load "$c" 10; g1_setup 10 2 )
  [ "$(nperhead "$T/$c")" = 2 ] && [ "$(ngroup "$T/$c")" = 0 ] && ok || bad "$c: per-head dispatches only ($(cat "$T/$c/gh.log"))"
done

# ============================================================================
# G11. A per-PR machine run defers to the hub; a leased run joins.
# ============================================================================
( load g11 11; export MC_ON_MACHINE=1 MC_PR_DEFERRED_FILE="$C/deferred"; g1_setup 11 1; echo "$PQ_WHY" > "$C/why" )
C="$T/g11"
grep -q '^101 hold' "$C/words" && ok || bad "G11: hold ($(cat "$C/words"))"
grep -qx prequeue-group "$C/deferred" 2>/dev/null && ok || bad "G11: the defer word prequeue-group ($(cat "$C/deferred" 2>/dev/null))"
[ ! -s "$C/gh.log" ] && [ -z "$(ls -A "$C/state/prequeue/groups" 2>/dev/null)" ] && [ -z "$(entry "$C" 101 "$(hd 11 1)")" ] && ok \
  || bad "G11: 0 dispatch, no group file, no entry ($(cat "$C/gh.log"); $(entry "$C" 101 "$(hd 11 1)"))"
grep -q "the hub's; asked on its next tick" "$C/why" && ok || bad "G11: PQ_WHY says the hub dispatches ($(cat "$C/why"))"
( load g11l 11; export MC_ON_MACHINE=1 MC_LEASED_RUN=1 MC_LEASE_FENCE=fence-fixture-1 MC_PR_DEFERRED_FILE="$C/deferred"; g1_setup 11 2 )
[ "$(ngroup "$T/g11l")" = 1 ] && [ ! -s "$T/g11l/deferred" ] && ok || bad "G11 leased: joins and flushes ($(cat "$T/g11l/gh.log"))"
( load g11f 11; export MC_ON_MACHINE=1 MC_LEASED_RUN=1 MC_PR_DEFERRED_FILE="$C/deferred"; g1_setup 11 1 )
grep -qx prequeue-group "$T/g11f/deferred" 2>/dev/null && [ ! -s "$T/g11f/gh.log" ] && ok || bad "G11 lease without a fence: deferred ($(cat "$T/g11f/gh.log"))"

# ============================================================================
# G12. A named-suites dispatch (the batch-solo path) stays per head.
# ============================================================================
( load g12 12; pq_dispatch "$SLUG" 120 "$(hd 12 1)" "$MAIN" "tests/a.sh" fp1; echo "rc=$?" > "$C/rc" )
C="$T/g12"
grep -qx rc=0 "$C/rc" && [ "$(nperhead "$C")" = 1 ] && grep -q -- '-f suites=tests/a.sh' "$C/gh.log" && [ "$(ngroup "$C")" = 0 ] && ok \
  || bad "G12: one per-head named-suites dispatch ($(cat "$C/rc") $(cat "$C/gh.log"))"

# ============================================================================
# G13. The workflows.
# ============================================================================
if python3 -c 'import yaml' 2>/dev/null; then
  python3 - "$GATE_WF" "$GROUP_WF" "$T/w" <<'PY' || bad "G13: the workflows must parse (see above)"
import sys, yaml, os
g = yaml.safe_load(open(sys.argv[1])); w = yaml.safe_load(open(sys.argv[2])); out = sys.argv[3]
os.makedirs(out, exist_ok=True)
gon = g.get("on", g.get(True)); won = w.get("on", w.get(True))
d = gon["workflow_dispatch"]["inputs"]; c = gon["workflow_call"]["inputs"]
plan = w["jobs"]["plan"]; gate = w["jobs"]["gate"]
step = [s for s in plan["steps"] if s.get("id") == "plan"][0]
open(out + "/plan.sh", "w").write(step["run"])
facts = {
  "dispatch": ",".join(f"{k}:{bool(v.get('required'))}" for k, v in sorted(d.items())),
  "call": ",".join(f"{k}:{bool(v.get('required'))}" for k, v in sorted(c.items()) if k != "run_key_suffix"),
  "call_extra": ",".join(sorted(set(c) - set(d))),
  "gate_job": ",".join(sorted(g["jobs"])),
  "group_inputs": ",".join(f"{k}:{bool(v.get('required'))}" for k, v in sorted(won["workflow_dispatch"]["inputs"].items())),
  "group_on": ",".join(sorted(won)),
  "uses": gate.get("uses", ""),
  "secrets": str(gate.get("secrets")),
  "failfast": str(gate["strategy"].get("fail-fast")),
  "matrix": str(gate["strategy"].get("matrix")),
  "if": str(gate.get("if")),
  "needs": str(gate.get("needs")),
  "with": ",".join(f"{k}={v}" for k, v in sorted(gate["with"].items())),
  "run_name": w["run-name"],
  "name": w["name"],
  "perms": str(w.get("permissions")),
  "plan_env": ",".join(sorted(step.get("env", {}))),
  "plan_shell": str(step.get("shell")),
  "run_key": [s for s in g["jobs"]["gate"]["steps"] if s.get("id") == "verdict"][0]["env"]["SUITE_REUSE_RUN_KEY"],
}
open(out + "/facts", "w").write("".join(f"{k}={v}\n" for k, v in facts.items()))
PY
  fact() { sed -n "s/^$1=//p" "$T/w/facts" 2>/dev/null; }
  [ -n "$(fact dispatch)" ] && [ "$(fact call)" = "$(fact dispatch)" ] && ok || bad "G13: workflow_call inputs equal workflow_dispatch inputs (call '$(fact call)', dispatch '$(fact dispatch)')"
  [ "$(fact call_extra)" = run_key_suffix ] && ok || bad "G13: the only call-only input is run_key_suffix (got '$(fact call_extra)')"
  [ "$(fact gate_job)" = gate ] && ok || bad "G13: the per-head workflow still has its one gate job (got '$(fact gate_job)')"
  [ "$(fact run_key)" = 'prequeue-${{ github.run_id }}-${{ github.run_attempt }}${{ inputs.run_key_suffix }}' ] && ok || bad "G13: the ledger run key carries the suffix (got '$(fact run_key)')"
  [ "$(fact group_on)" = workflow_dispatch ] && ok || bad "G13: the group workflow is dispatched only (got '$(fact group_on)')"
  [ "$(fact group_inputs)" = "group_id:True,invariants:False,learned:False,main:True,members:True,trace:False" ] && ok || bad "G13: the group inputs (got '$(fact group_inputs)')"
  [ "$(fact uses)" = ./.github/workflows/prequeue-gate.yml ] && [ "$(fact secrets)" = inherit ] && [ "$(fact failfast)" = False ] && ok \
    || bad "G13: the gate job calls the per-head workflow, secrets inherit, fail-fast false (uses '$(fact uses)' secrets '$(fact secrets)' fail-fast '$(fact failfast)')"
  [ "$(fact needs)" = plan ] && [ "$(fact if)" = "needs.plan.outputs.ok == '1'" ] && [ "$(fact matrix)" = '${{ fromJSON(needs.plan.outputs.matrix) }}' ] && ok \
    || bad "G13: the gate job needs the plan and its matrix (needs '$(fact needs)' if '$(fact if)' matrix '$(fact matrix)')"
  [ "$(fact with)" = 'head=${{ matrix.head }},invariants=${{ inputs.invariants }},learned=${{ inputs.learned }},main=${{ inputs.main }},pr=${{ matrix.pr }},run_key_suffix=-${{ matrix.pr }},trace=${{ inputs.trace }}' ] && ok \
    || bad "G13: the per-head inputs (got '$(fact with)')"
  [ "$(fact perms)" = "{'contents': 'read'}" ] && ok || bad "G13: contents: read only (got '$(fact perms)')"
  [ "$(fact plan_env)" = PQ_GROUP,PQ_MAIN,PQ_MEMBERS ] && ! grep -q '\${{' "$T/w/plan.sh" && ok || bad "G13: the inputs reach the plan step through env only (env '$(fact plan_env)')"
  case "$(fact plan_shell)" in *-e*|None) bad "G13: the plan step must not use errexit ($(fact plan_shell))" ;; *) ok ;; esac
  RN=$(fact run_name); RN=${RN//'${{ inputs.group_id }}'/g1761000000abcd}; RN=${RN//'${{ inputs.main }}'/$M1}
  [ "$RN" = "$( . "$GROUP_LIB" >/dev/null 2>&1; pq_group_title g1761000000abcd "$M1")" ] && ok || bad "G13: run-name equals pq_group_title (got '$RN')"
  SKIP_RE=$(jq -r '.. | objects | select(.env? == "MAIN_RED_SKIP_RE") | .default' "$DIR/catalog/lanes.d/main-red-pr-pair.json")
  python3 -c 'import re,sys; sys.exit(0 if re.search(sys.argv[1], sys.argv[2], re.I) else 1)' "$SKIP_RE" "$(fact name)" && ok \
    || bad "G13: the main-red skip regex '$SKIP_RE' matches '$(fact name)'"
  # dry <case> <main> <group> <members> — the plan step, as the runner runs it.
  dry() {
    mkdir -p "$T/pd-$1"; : > "$T/pd-$1/out"
    ( cd "$T/pd-$1" && env PQ_MAIN="$2" PQ_GROUP="$3" PQ_MEMBERS="$4" GITHUB_OUTPUT="$T/pd-$1/out" bash "$T/w/plan.sh" ) > "$T/pd-$1/log" 2>&1
    echo "rc=$?" >> "$T/pd-$1/log"
  }
  out() { sed -n "s/^$2=//p" "$T/pd-$1/out"; }
  G1ID=$(gid "$T/g1")
  dry ok "$M1" "$G1ID" "$(cat "$T/g1.members")"
  [ "$(out ok ok)" = 1 ] && [ "$(out ok matrix | jq -c '[.include[] | "\(.pr):\(.head)"] | join(",")' -r)" = "$(cat "$T/g1.members")" ] && ok \
    || bad "G13 dry: G1's members string gives 5 matrix entries ($(cat "$T/pd-ok/out" "$T/pd-ok/log"))"
  [ "$(out ok matrix | jq '.include | length')" = 5 ] && ! grep -q 'prequeue-group-verdict' "$T/pd-ok/log" && ok || bad "G13 dry: 5 entries, no notice"
  dry badmem "$M1" "$G1ID" "101:$(hd 1 1),102"
  dry rep "$M1" "$G1ID" "101:$(hd 1 1),102:$(hd 1 1)"
  dry badmain "${M1:0:39}" "$G1ID" "101:$(hd 1 1)"
  dry badgid "$M1" "g1;x" "101:$(hd 1 1)"
  for c in badmem:bad-members rep:bad-members-repeated-head badmain:bad-main badgid:bad-group; do
    k="${c%%:*}"; why="${c#*:}"
    [ "$(out "$k" ok)" = 0 ] && [ "$(grep -c '^::notice title=prequeue-group-verdict::could-not-run main=[0-9a-f]* why='"$why"'$' "$T/pd-$k/log")" = 1 ] \
      && [ "$(out "$k" matrix)" = '{"include":[]}' ] && grep -qx rc=0 "$T/pd-$k/log" && ok \
      || bad "G13 dry $k: ok=0, an empty matrix and one could-not-run why=$why notice ($(cat "$T/pd-$k/out" "$T/pd-$k/log"))"
  done
else
  [ -n "${CI:-}" ] && bad "G13: PyYAML missing on a CI runner" || echo "prequeue-group: PyYAML missing — G13 skipped on this dev machine"
fi

# ============================================================================
# G14. No real vendor call; the knob defaults.
# ============================================================================
[ ! -e "$T/curl-calls" ] && ok || bad "G14: 0 curl calls ($(cat "$T/curl-calls"))"
[ ! -e "$T/gh-orphan.log" ] && ok || bad "G14: every gh call went to a case's stub log ($(cat "$T/gh-orphan.log"))"
[ "$(command -v gh)" = "$FB/gh" ] && ok || bad "G14: gh resolves to the stub ($(command -v gh))"
( unset MC_PREQUEUE_GROUP MC_PREQUEUE_GROUP_MAX MC_PREQUEUE_GROUP_PAGE; . "$DIR/bin/lib/mc-prequeue.sh"
  printf '%s %s %s\n' "$(pq_knob MC_PREQUEUE_GROUP)" "$(pq_knob MC_PREQUEUE_GROUP_MAX)" "$(pq_knob MC_PREQUEUE_GROUP_PAGE)" ) > "$T/g14.knobs"
[ "$(cat "$T/g14.knobs")" = "1 10 30" ] && ok || bad "G14: knob defaults 1 10 30 (got '$(cat "$T/g14.knobs")')"
for k in MC_PREQUEUE_GROUP MC_PREQUEUE_GROUP_MAX MC_PREQUEUE_GROUP_PAGE; do
  f="$DIR/catalog/lanes.d/merge-conductor.knobs.d/$k.json"
  [ "$(jq -r '"\(.env) \(.default) \(.read_in)"' "$f" 2>/dev/null)" = "$k $(sed -n "s/.*$k=\([0-9]*\).*/\1/p" <<<"$( . "$DIR/bin/lib/mc-prequeue.sh"; echo "$PQ_KNOB_DEFAULTS")" | head -1) bin/lib/mc-prequeue.d/group.sh" ] && ok \
    || bad "G14: the knob row $k names its default and bin/lib/mc-prequeue.d/group.sh ($(cat "$f" 2>/dev/null | head -5))"
done

# ============================================================================
# G15. Near misses: no head gets a verdict it did not earn.
# ============================================================================
( load g15 15; g1_setup 15 4 )
C="$T/g15"; G=$(gid "$C"); M=$(cat "$C/main.sha")
# A run whose title is one character off, completed: nobody reads it.
jq -nc --arg t "prequeue group=$G main=${M}x" '{workflow_runs:[{id:7702,display_title:$t,status:"completed",conclusion:"success",created_at:"2026-10-25T01:00:00Z"}]}' > "$C/gruns.json"
jobs "$C" 4; ann "$C" 901 "green main=$M head=$(hd 15 1) suites="
( TICK=t2 load g15 15; for i in 1 2 3 4; do gate $((100 + i)) "$(hd 15 "$i")"; done > "$C/words-off" )
[ "$(awk '{print $2}' "$C/words-off" | sort -u)" = hold ] && ok || bad "G15: a title one character off is no run: all hold ($(cat "$C/words-off"))"
finish_run "$C" "$G" "$M"; jobs "$C" 4
ann "$C" 901 "green main=$M head=$(hd 15 1) suites=" "red main=$M head=$(hd 15 9) suites=tests/z.sh"
ann "$C" 902 "green main=$(mn 99) head=$(hd 15 2) suites="
ann "$C" 903 "green main=$M head=$(hd 15 3) suites=" "red main=$M head=$(hd 15 3) suites=tests/c.sh"
ann "$C" 904 "red main=$M head=$(hd 15 4) suites="
( TICK=t3 load g15 15; for i in 1 2 3 4; do gate $((100 + i)) "$(hd 15 "$i")"; done > "$C/words2" )
[ "$(cat "$C/words2" | tr '\n' '|')" = "101 proceed |102 proceed |103 proceed |104 proceed |" ] && ok || bad "G15: no red is cross-assigned ($(tr '\n' '|' < "$C/words2"))"
case "$(entry "$C" 101 "$(hd 15 1)")" in "green "*) ok ;; *) bad "G15: #101 keeps its own green, the unknown head's red is ignored (got '$(entry "$C" 101 "$(hd 15 1)")')" ;; esac
case "$(entry "$C" 102 "$(hd 15 2)")" in "could-not-run "*" stale-main alerted"*) ok ;; *) bad "G15: #102 main mismatch (got '$(entry "$C" 102 "$(hd 15 2)")')" ;; esac
case "$(entry "$C" 103 "$(hd 15 3)")" in "could-not-run "*" annotation-count-2 alerted"*) ok ;; *) bad "G15: #103 two verdicts (got '$(entry "$C" 103 "$(hd 15 3)")')" ;; esac
case "$(entry "$C" 104 "$(hd 15 4)")" in "could-not-run "*" red-without-suites alerted"*) ok ;; *) bad "G15: #104 red without suites (got '$(entry "$C" 104 "$(hd 15 4)")')" ;; esac
[ "$(grep -c . "$C/alerts")" = 3 ] && ok || bad "G15: one alert per could-not-run head ($(cat "$C/alerts"))"

# ============================================================================
# G16. 5 gates at once: one group, 5 members, no duplicate.
# ============================================================================
( load g16 16
  for i in 1 2 3 4 5; do gate $((100 + i)) "$(hd 16 "$i")" > "$C/w.$i" & done; wait
  pq_group_flush "$SLUG" )
C="$T/g16"
GF=$(ls "$C/state/prequeue/groups/"*.run 2>/dev/null)
[ "$(printf '%s\n' "$GF" | grep -c .)" = 1 ] && [ "$(tail -n +2 "$GF" | grep -c .)" = 5 ] && [ "$(tail -n +2 "$GF" | sort -u | grep -c .)" = 5 ] && ok \
  || bad "G16: one group file with 5 distinct members ($(ls "$C/state/prequeue/groups/"); $(cat $GF 2>/dev/null))"
[ "$(ls "$C/state/prequeue/"*.group | wc -l)" = 5 ] && [ "$(ngroup "$C")" = 1 ] && ok || bad "G16: 5 .group sidecars and 1 dispatch ($(cat "$C/gh.log"))"

# ============================================================================
# G17. A member whose entry is no longer pending is not dispatched.
# ============================================================================
( load g17 17; gate 101 "$(hd 17 1)" >/dev/null; gate 102 "$(hd 17 2)" >/dev/null; gate 103 "$(hd 17 3)" >/dev/null
  pq_cache_put "$(pq_key "$SLUG" 102 "$(hd 17 2)" "$MAIN")" green 1 - ""
  pq_group_flush "$SLUG" )
C="$T/g17"; GF=$(ls "$C/state/prequeue/groups/"*.run 2>/dev/null)
grep -q -- "-f members=101:$(hd 17 1),103:$(hd 17 3)\$" "$C/gh.log" && ok || bad "G17: only the 2 waiting members are dispatched ($(cat "$C/gh.log"))"
[ "$(tail -n +2 "$GF" 2>/dev/null | tr '\n' '|')" = "101 $(hd 17 1)|103 $(hd 17 3)|" ] && ok || bad "G17: the .run file lists the dispatched members only ($(cat "$GF" 2>/dev/null))"

# G17b. The fragment: no lib = rc 0 and no call; no open group = no gh call.
( C="$T/g17b"; mkdir -p "$C"; GH_LOG="$C/gh.log"; export GH_LOG
  unset -f pq_group_flush 2>/dev/null; . "$GROUP_FRAG"
  mc_pq_group_tick_end "$SLUG"; echo "rc=$?" > "$C/rc.nolib" )
C="$T/g17b"
[ "$(cat "$C/rc.nolib" 2>/dev/null)" = rc=0 ] && [ ! -s "$C/gh.log" ] && ok || bad "G17b: no pq_group_flush: rc 0, 0 calls ($(cat "$C/rc.nolib" "$C/gh.log" 2>/dev/null))"
( load g17c 18; . "$GROUP_FRAG"; mc_pq_group_tick_end "$SLUG"; echo "rc=$?" > "$C/rc" )
C="$T/g17c"
[ "$(cat "$C/rc")" = rc=0 ] && [ ! -s "$C/gh.log" ] && [ ! -s "$C/reads" ] && ok || bad "G17b: no open group: rc 0, 0 gh calls, 0 reads ($(cat "$C/gh.log" "$C/reads"))"

# ============================================================================
# G1E. The real conductor tick: 5 READY rows, 1 group dispatch.
# ============================================================================
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
command -v git >/dev/null || { echo "FAIL: G1E needs git"; exit 1; }
E="$T/e"; mkdir -p "$E"
export GIT_CONFIG_GLOBAL="$E/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --global user.email t@example.com; git config --global user.name t
git config --global init.defaultBranch main; git config --global commit.gpgsign false
git config --global protocol.file.allow always
git config --global "url.$E/origin.git.insteadOf" "https://x-access-token@github.com/$SLUG.git"
git config --global "url.$E/origin.git.insteadOf" "https://github.com/$SLUG.git" --add
S="$E/seed"; git init -q --bare "$E/origin.git"; git init -q "$S"
echo base > "$S/x.txt"; git -C "$S" add -A; git -C "$S" commit -qm base; EM=$(git -C "$S" rev-parse HEAD)
git -C "$S" push -q "$E/origin.git" "$EM:refs/heads/main"
mkdir -p "$E/heads"
for i in 1 2 3 4 5; do
  git -C "$S" checkout -q -b "b$i" "$EM"; echo "$i" > "$S/f$i.txt"; git -C "$S" add -A; git -C "$S" commit -qm "h$i"
  git -C "$S" rev-parse HEAD > "$E/heads/$((40 + i))"; git -C "$S" push -q "$E/origin.git" "HEAD:refs/pull/$((40 + i))/head"
done
export HARNESS="$E/h"
mkdir -p "$E/h/bin/lib" "$E/h/logs" "$E/h/state" "$E/h/flags" "$E/h/locks" "$E/h/builds" "$E/h/env" "$E/h/tmp" "$E/fb" "$E/repos"
cat > "$E/h/bin/lib/ticket-ownership.sh" <<'EOF'
to_lane_hold() { return 1; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
to_lead_merge_hold() { return 1; }
EOF
: > "$E/h/bin/lib/pr-snapshot.sh"
scratch_install_closure bin/merge-conductor.sh "$E/h" >/dev/null || exit 1
# The tick calls the flush through its merge-conductor.d fragment; the
# closure does not follow the fragment glob, so install it by name.
( cd "$DIR" && scratch_install_closure bin/merge-conductor.d/bh-8327-prequeue-group.sh "$E/h" >/dev/null ) || exit 1
scratch_install_closure bin/jobs-client.sh "$E/h" >/dev/null || exit 1
scratch_rm "$E/h/bin/lib/gh-limit-logger.sh"
cp "$DIR/bin/fleet-conf.sh" "$E/h/bin/" || exit 1
cp "$DIR/tests/lib/rest-emit.sh" "$E/fb/restpr" && chmod +x "$E/fb/restpr" || exit 1
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$E/h/bin/$s.sh"; chmod +x "$E/h/bin/$s.sh"; done
printf '#!/bin/bash\necho "[lane-alert] $*" >> "%s/h/logs/ALERTS.log"\n' "$E" > "$E/h/bin/lane-alert.sh"; chmod +x "$E/h/bin/lane-alert.sh"
printf 'demo %s - - 2 box-demo\n' "$SLUG" > "$E/h/fleet.conf"; export FLEET_CONF="$E/h/fleet.conf"
: > "$E/h/env/global.env"
for i in 1 2 3 4 5; do
  R="$E/h/builds/pool-demo-BH-2$i-202610250001"; mkdir -p "$R"
  echo "PR_CREATED $U/$((40 + i))" > "$R/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$R/review.md"
  cp "$E/heads/$((40 + i))" "$R/reviewed-sha"; : > "$R/pipeline.log"
done
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
LIST=$(for i in 1 2 3 4 5; do n=$((40 + i)); printf '{"number":%s,"url":"%s/%s","headRefOid":"%s","headRefName":"ticket/bh-2%s","baseRefName":"main","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN","isInMergeQueue":false,"labels":[]}\n' "$n" "$U" "$n" "$(cat "$E/heads/$n")" "$i"; done | jq -sc .)
printf '%s\n' "$LIST" > "$E/list.json"
cat > "$E/fb/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"auth token"*) echo faketoken-fixture ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  "workflow run "*) printf '%s\n' "\$*" >> "$E/dispatch.txt"; exit 0 ;;
  *"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml/runs?"*|*"api -i -X GET repos/$SLUG/actions/workflows/prequeue-group-gate.yml/runs?"*) restpr --raw 200 '{"workflow_runs":[]}' ;;
  *"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml"|*"api -i -X GET repos/$SLUG/actions/workflows/prequeue-gate.yml "*)
    restpr --raw 200 '{"id":5,"path":".github/workflows/prequeue-gate.yml"}' ;;
  *"api -i -X GET repos/$SLUG/actions/workflows/prequeue-group-gate.yml"|*"api -i -X GET repos/$SLUG/actions/workflows/prequeue-group-gate.yml "*)
    restpr --raw 200 '{"id":9,"path":".github/workflows/prequeue-group-gate.yml"}' ;;
  *"api -i -X GET repos/$SLUG/commits/main"|*"api -i -X GET repos/$SLUG/commits/main "*) restpr --raw 200 '{"sha":"$EM"}' ;;
  *"api -i -X GET repos/$SLUG/compare/"*) restpr --raw 200 '{"status":"ahead","ahead_by":1}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"actions/runs?head_sha="*) restpr --raw 200 '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"success","run_started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T01:00:00Z"}]}' ;;
  *"api -i -X POST repos/$SLUG/issues/"*"/comments -f body=@mergifyio"*) printf '%s\n' "\$*" >> "$E/c-enq.txt"; restpr --raw 201 '{"id":901}' ;;
  *"/issues/"*"/labels"*) printf '%s\n' "\$*" >> "$E/c-enq.txt" ;;
  *"api -X POST repos/"*"/issues/"*"/comments"*) case "\$*" in *mergifyio*) printf '%s\n' "\$*" >> "$E/c-enq.txt" ;; esac ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$E/c-enq.txt"; exit 0 ;;
  *"/pulls/"*"/merge"|*"/pulls/"*"/merge "*) printf '%s\n' "\$*" >> "$E/c-enq.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*)
    n=\$(printf '%s' "\$*" | sed -n 's|.*repos/$SLUG/pulls/\([0-9]*\).*|\1|p')
    restpr OPEN "\$(cat "$E/heads/\$n")" "ticket/bh-2\$((n - 40))" main "" MERGEABLE CLEAN operator "" "Closes #2\$((n - 40))" ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$E/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$E/fb/gh"
# The jobs worker is a local fake at worker.test; any other host is a real
# vendor call and lands in $T/curl-calls (G14).
cat > "$E/fb/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET
case "\$URL" in http://worker.test/*) ;; *) printf '%s\n' "\$*" >> "$T/curl-calls" ;; esac
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
  "PUT "*) printf '{"ok":true}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$E/fb/curl"
: > "$E/dispatch.txt"; : > "$E/c-enq.txt"
touch "$E/h/flags/merge-conductor-actions" "$E/h/flags/merge-conductor-merge"
( cd "$E" && env PATH="$E/fb:$PATH" HARNESS="$E/h" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default \
    MC_REPOS="$E/repos" MC_MERGE_BUDGET=5 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 \
    MC_MAIN_RED_DETECT=0 MC_DETACHED_REBASE=0 PR_DEP_GATE_TICKET=0 bash "$E/h/bin/merge-conductor.sh" >/dev/null 2>"$E/tick.err" ) \
  || echo "G1E: tick rc=$? stderr: $(tail -5 "$E/tick.err")"
MCLOG="$E/h/logs/merge-conductor.log"
[ "$(grep -c '^workflow run prequeue-group-gate.yml ' "$E/dispatch.txt")" = 1 ] && ok \
  || bad "G1E: the tick dispatches 1 group run (dispatch: $(cat "$E/dispatch.txt"); log: $(grep -i 'prequeue' "$MCLOG" 2>/dev/null | grep -v PREQUEUE_CALL | tail -8); err: $(tail -3 "$E/tick.err"))"
[ "$(grep -c '^workflow run prequeue-gate.yml ' "$E/dispatch.txt")" = 0 ] && ok || bad "G1E: 0 per-head dispatches ($(cat "$E/dispatch.txt"))"
EW=$(for i in 1 2 3 4 5; do printf '%s%s:%s' "$([ $i = 1 ] || echo ,)" $((40 + i)) "$(cat "$E/heads/$((40 + i))")"; done)
D=$(grep '^workflow run prequeue-group-gate.yml ' "$E/dispatch.txt")
M5=$(sed -n 's/.*-f members=\([^ ]*\).*/\1/p' <<<"$D" | tr ',' '\n' | sort | paste -sd, -)
[ "$M5" = "$EW" ] && grep -q -- "-f main=$EM " <<<"$D" && ok || bad "G1E: the group run names main and the 5 heads (got '$D')"
[ ! -s "$E/c-enq.txt" ] && ok || bad "G1E: 0 enqueues this tick ($(cat "$E/c-enq.txt"))"
[ "$(grep -c 'PREQUEUE group-join' "$MCLOG" 2>/dev/null)" = 5 ] && grep -q "PREQUEUE group-dispatch $SLUG main=${EM:0:12} group=g[0-9a-f]* n=5 " "$MCLOG" && ok \
  || bad "G1E: 5 joins and one n=5 dispatch line ($(grep 'PREQUEUE group' "$MCLOG" 2>/dev/null))"
[ ! -e "$T/curl-calls" ] && ok || bad "G1E: 0 curl calls to a real host ($(cat "$T/curl-calls"))"

echo "prequeue-group.bh-8327: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
