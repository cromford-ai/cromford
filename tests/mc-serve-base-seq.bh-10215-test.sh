#!/bin/bash
# tests/mc-serve-base-seq.bh-10215-test.sh — BH-10215: in step `record` of lane
# merge-conductor, an idle open-list row is served from the PR record until
# its base branch moves (the base sequence, GET /api/pr-base-seqs), and the
# branch lookup of prs_branch_tip reads the record's open rows through
# prr_read and the conductor seam. Steps off and shadow keep today's calls.
#
# Stubs only: gh (GitHub; every call logged) and curl (the jobs worker: the
# record row, the record list, the PUT and the base sequences). The libs run
# in fresh processes: bin/lib/merge-conductor-lib.sh + mc_init, then the two
# conductor fragments bin/merge-conductor.d/bh-9938-prr-open-list.sh and
# bh-8457-pr-record-serve.sh, as bin/merge-conductor.sh sources them.
#
#   R1  10 idle PRs, seq 5 = current 5, age 2,000 s, 3 ticks: 0 pulls/N, 1 base-seq GET per tick
#   R2  a push raises main to 6: next tick 10 reads and 10 PUTs with seq 6; then 0
#   R3  a push to another branch: 0 reads
#   R0  the round-1 red (BH-9938 AT1 shape): rows 10 s old, no sequence, the
#       base-seq route 404: 0 reads, 10 served by the age rule (rule 3)
#   S1-S9  the serve rule's misses
#   S10 rule 2 beats the age rule: a young row whose base moved is a miss
#   S11 PR_RECORD_SERVE_SEQ_MAX_AGE_S=0: rule 1 never serves; rule 3 still does
#   S12 (r4) a failed base-seq read writes the negative tick memo: 1 GET per
#       repo per tick, not 1 per row; the next tick asks again
#   S13 (r5) blocked/unstable/has_hooks get no sequence extension: CI and
#       reviews move them with no base push; clean/dirty/behind/draft do
#   S14 (r6) rule 1 times the state (fields_at.mergeable_state), not the
#       row: a write of another field does not extend the 3,600 s backstop
#   B1-B6  the branch lookup from the record
#   B7  pr_record_list takes only head_commit as its with
#   O1-O4  steps off and shadow, and the lib alone: today's rule
#   N1  the worker half: its files exist and its node suite passes (the suite
#       runs worker_catalogs first, so it passes on a fresh checkout too)
#   Z1  no call to api.github.com in the whole suite
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-serve-base-seq.bh-10215-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null || { echo "SKIP: jq missing"; exit 0; }
command -v flock >/dev/null || { echo "SKIP: flock missing"; exit 0; }

SLUG=example-org/demo-os
LR=example-org_demo-os
UPD=2026-11-26T10:00:00Z
hd() { printf '%040x' "$((0xbee000 + $1))"; }   # the list head of PR <n>
cnt() { local c=0; [ -f "$1" ] && c=$(grep -cE "$2" "$1"); echo "${c:-0}"; }

# ---- the harness tree --------------------------------------------------------
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
L="$T/l"; mkdir -p "$L"
( export HARNESS="$L/h"; fx_mc_harness "$DIR" "$L" ) || { echo "FAIL: fx_mc_harness"; exit 1; }
for s in bin/lib/merge-conductor-lib.sh bin/lib/gh-pr-list.sh bin/lib/pr-snapshot.sh bin/jobs-client.sh \
         bin/lib/pr-record.sh bin/lib/prr-shadow.sh bin/lib/prr-ci-state.sh bin/lib/prr-shadow.d/merge-conductor.sh \
         bin/lib/pr-record-serve.sh bin/lib/pr-snapshot-refs.sh; do
  scratch_install_closure "$s" "$L/h" >/dev/null || { echo "FAIL: closure install failed for $s"; exit 1; }
done
mkdir -p "$L/h/bin/merge-conductor.d"
cp "$DIR/bin/merge-conductor.d/bh-9938-prr-open-list.sh" "$DIR/bin/merge-conductor.d/bh-8457-pr-record-serve.sh" \
  "$L/h/bin/merge-conductor.d/" || { echo "FAIL: fragments"; exit 1; }
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: bin/lanes-build.sh could not compose the registry"; exit 1; }
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$L/h/fleet.conf"
mkdir -p "$L/log" "$L/tmp" "$L/pr" "$L/w"

# ---- gh: GitHub --------------------------------------------------------------
# $GHT/prs.json the open list; $GHT/pr/<n>.json pulls/<n>; $GHT/refs.json the
# matching-refs answer; $GHT/raise-on-read: copied over the base sequences
# during a pulls/<n> read (S8, a push that lands mid-read).
cat > "$L/fakebin/gh" <<'EOF'
#!/bin/bash
p=""; prev=""
for a in "$@"; do [ "$prev" = GET ] && p="$a"; prev="$a"; done
printf '%s\n' "$*" >> "$GHT/argv"
[ -n "$p" ] && printf '%s\n' "$p" >> "$GHT/paths"
pg=1; [[ " $* " =~ [\&\ ]page=([0-9]+) ]] && pg="${BASH_REMATCH[1]}"
case "$*" in
  *"auth token"*) echo tok-fixture-1; exit 0 ;;
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
  *"-X PATCH"*|*"-X PUT"*|*"-X DELETE"*|*"-X POST"*|*"pr merge"*) printf '%s\n' "$*" >> "$GHT/writes"; exit 1 ;;
  *"pr list"*) echo '[]'; exit 0 ;;
esac
case "$p" in
  repos/*/pulls|repos/*/pulls\?state=open*)
    printf 'HTTP/2 200\r\n\r\n'; [ "$pg" = 1 ] && cat "$GHT/prs.json" || echo '[]' ;;
  repos/*/pulls/*/files*) printf 'HTTP/2 200\r\n\r\n[]\n' ;;
  repos/*/pulls/[0-9]*)
    n="${p##*/pulls/}"; n="${n%%[!0-9]*}"
    [ -f "$GHT/raise-on-read" ] && cp "$GHT/raise-on-read" "$W/seqs-example-org_demo-os.json"
    if [ -f "$GHT/pr/$n.json" ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$GHT/pr/$n.json"
    else printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'; fi ;;
  repos/*/git/matching-refs/heads/*)
    printf 'HTTP/2 200\r\n\r\n'; cat "$GHT/refs.json" ;;
  repos/*/branches/*)
    printf 'HTTP/2 404\r\n\r\n{"message":"Branch not found"}\n' ;;
  *) printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n' ;;
esac
exit 0
EOF
# ---- curl: the jobs worker ---------------------------------------------------
# $W/rec-<repo>-<n>.json the row answer; $W/list-<repo>.json the list answer;
# $W/seqs-<repo>.json the base sequences {base_ref: seq}; $W/seq-down: the
# base-seq GET answers 500; $W/seq-404: it answers 404 (the route is unknown,
# as in the BH-9938 jobs stub); $W/seq-raw: its body (200). Every call is logged to
# $W/curl.log, an api.github.com URL also to $W/github-curl.log (Z1).
cat > "$L/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET; D=""
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; --data-binary|-d|--data) D="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s %s\n' "$M" "$URL" >> "$W/curl.log"
case "$URL" in *api.github.com*) printf '%s\n' "$URL" >> "$GHT/github-curl.log" ;; esac
r=${URL#*repo=}; r=${r%%&*}; r=${r//\//_}
case "$M $URL" in
  "GET "*"/api/pr-base-seqs?"*)
    [ -f "$W/seq-down" ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
    [ -f "$W/seq-404" ] && { printf '{"error":"not found"}\n404\n'; exit 0; }
    [ -f "$W/seq-raw" ] && { printf '%s\n200\n' "$(cat "$W/seq-raw")"; exit 0; }
    f="$W/seqs-$r.json"; [ -f "$f" ] || { printf '{"rows":[]}\n200\n'; exit 0; }
    printf '%s\n200\n' "$(jq -c '{rows: [to_entries[] | {base_ref: .key, seq: .value, pushed_at: "2026-11-26T09:00:00Z"}]}' "$f")" ;;
  "GET "*"/api/pr-records?"*"number="*)
    n=${URL##*number=}; n=${n%%&*}
    f="$W/rec-$r-$n.json"
    if [ -f "$f" ]; then printf '%s\n200\n' "$(cat "$f")"; else printf '{"row":null,"age_s":null}\n200\n'; fi ;;
  "GET "*"/api/pr-records?"*"state=open"*)
    f="$W/list-$r.json"
    if [ -f "$f" ]; then
      case "$URL" in *with=head_commit*) printf '%s\n200\n' "$(cat "$f")" ;;
        *) printf '%s\n200\n' "$(jq -c '.rows |= map(del(.head_commit))' "$f")" ;; esac
    else printf '{"error":"not found"}\n404\n'; fi ;;
  "PUT "*"/api/pr-records")
    printf '%s\n' "$D" >> "$W/puts"
    rr=$(jq -r .repo <<<"$D"); n=$(jq -r .number <<<"$D"); f="$W/rec-${rr//\//_}-$n.json"
    old=$(jq -c '.row // {}' "$f" 2>/dev/null); [ -n "$old" ] || old='{}'
    at=2026-11-26T10:00:00Z
    row=$(jq -c --argjson o "$old" --arg at "$at" '$o + .fields + {repo, number}
      + {fields_at: (($o.fields_at // {}) + (.fields | with_entries(.value = $at)))}' <<<"$D")
    printf '{"row":%s,"age_s":0}\n' "$row" > "$f"
    printf '{"row":%s,"applied":%s,"stale":[]}\n200\n' "$row" "$(jq -c '.fields | keys' <<<"$D")" ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$L/fakebin/gh" "$L/fakebin/curl"

# ---- the drivers -------------------------------------------------------------
# drv.sh: the conductor's libs as bin/merge-conductor.sh loads them.
# drv-alone.sh: gh-pr-list.sh and pr-record-serve.sh only (no prr_step: O4).
cat > "$L/drv.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/merge-conductor-lib.sh" || exit 99
mc_init
H="$HARNESS"
command -v harness_pr_list >/dev/null 2>&1 || . "$H/bin/lib/gh-pr-list.sh" || exit 98
. "$H/bin/merge-conductor.d/bh-9938-prr-open-list.sh"
. "$H/bin/merge-conductor.d/bh-8457-pr-record-serve.sh"
[ "${DRV_NO_PRR_OPEN:-0}" = 1 ] && unset PRS_OPEN_PRR
eval "$1"
EOF
cat > "$L/drv-alone.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
. "$HARNESS/bin/lib/gh-pr-list.sh" || exit 99
. "$HARNESS/bin/lib/pr-record-serve.sh" || exit 97
export HPL_PR_RECORD=1
eval "$1"
EOF
TICKN=0
# drv <snippet> [driver] — one process, one tick id. STEP (default record) is the pinned step.
drv() { TICKN=$((TICKN + 1)); ( unset -f gh; unset PR_SNAPSHOT_LIB PR_SNAPSHOT_REFS_LIB GH_SOURCE GH_SOURCE_LANE
  export HARNESS="$L/h" PATH="$L/fakebin:$PATH" GHT="$L" W="$L/w" TMPDIR="$L/tmp" LANE_GATE_DISABLE=1 GH_ETAG=0 \
    LANE_REGISTRY="$T/lanes.json" HARNESS_PR_AUTHORS=operator HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
    FLEET_CONF="$L/h/fleet.conf" MC_TICK_ID="t$TICKN" PR_SNAPSHOT="${PR_SNAPSHOT:-0}" PR_SNAPSHOT_TTL_S=60 \
    PR_RECORD_SERVE_MAX_AGE_S="${SERVE_MAX:-600}" PRS_COUNT_FILE="$L/count"
  [ "${STEP:-record}" = none ] || export GH_SOURCE="${STEP:-record}" GH_SOURCE_LANE=merge-conductor
  bash "$L/${DRVF:-drv.sh}" "$1" ) > "$L/drv.out" 2>>"$L/drv.err"; DRC=$?; }
reset() {
  scratch_rm "$L/pr"; scratch_rm "$L/w"; scratch_rm "$L/h/state"; mkdir -p "$L/pr" "$L/w" "$L/h/state"
  rm -f "$L/paths" "$L/argv" "$L/count" "$L/raise-on-read" "$L/refs.json" "$L/h/logs/pr-record.log" "$L/h/logs/prr-shadow.log"
  echo '[]' > "$L/prs.json"
}
pulls() { cnt "$L/paths" "^repos/$SLUG/pulls/${1:-[0-9]+}$"; }
seqget() { cnt "$L/w/curl.log" '^GET .*/api/pr-base-seqs\?'; }
mrefs() { cnt "$L/paths" "^repos/$SLUG/git/matching-refs/heads/"; }
newlog() { rm -f "$L/paths" "$L/argv" "$L/count" "$L/w/curl.log" "$L/w/puts"; }
seqs() { printf '%s\n' "$1" > "$L/w/seqs-$LR.json"; }
# memos: the positive base-seq tick memos; negmemos: the negative ones (r4).
memos() { find "$L/h/state" -name '*.memo-baseseq-*' ! -name '*.memo-baseseq-miss-*' 2>/dev/null | grep -c .; }
negmemos() { find "$L/h/state" -name '*.memo-baseseq-miss-*' 2>/dev/null | grep -c .; }

# pr <n> <mergeable_state> — one open PR on main: the list row and its pulls/<n> body.
pr() {
  local n=$1 h; h=$(hd "$1")
  jq -c --argjson n "$n" --arg h "$h" --arg u "$UPD" '. + [{number:$n,
    html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)), title:"t", draft:false, state:"open",
    updated_at:$u, created_at:"2026-11-01T00:00:00Z", labels:[], user:{login:"operator",type:"User"},
    head:{sha:$h, ref:("ticket/bh-"+($n|tostring)), repo:{full_name:"example-org/demo-os"}},
    base:{ref:"main", repo:{full_name:"example-org/demo-os"}}}]' "$L/prs.json" > "$L/prs.tmp" && mv "$L/prs.tmp" "$L/prs.json"
  jq -nc --argjson n "$n" --arg h "$h" --arg u "$UPD" --arg st "$2" '{number:$n, state:"open",
    merged_at:null, draft:false, html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)), user:{login:"operator"},
    labels:[], head:{sha:$h, ref:("ticket/bh-"+($n|tostring)), repo:{full_name:"example-org/demo-os"}},
    base:{ref:"main", sha:"'"$(printf 'f%.0s' {1..40})"'", repo:{full_name:"example-org/demo-os"}},
    mergeable:($st != "dirty"), mergeable_state:$st, updated_at:$u}' > "$L/pr/$n.json"
}
# rec <n> <age> <head|null> <mergeable_state|null> <seq|null> [fa_state] [fa_seq] [base_ref]
#   one record row; fields_at.mergeable_state / .mergeable_base_seq default to one time.
rec() {
  jq -nc --argjson n "$1" --argjson a "$2" --arg h "$3" --arg m "$4" --arg s "$5" \
    --arg fm "${6:-2026-11-26T09:00:00Z}" --arg fs "${7:-${6:-2026-11-26T09:00:00Z}}" --arg b "${8:-main}" '
    {row:{repo:"example-org/demo-os", number:$n, state:"open", base_ref:$b,
      head_sha:(if $h == "null" then null else $h end),
      mergeable_state:(if $m == "null" then null else $m end),
      mergeable_base_seq:(if $s == "null" then null else ($s | tonumber) end),
      fields_at:({mergeable_state:$fm} + (if $s == "null" then {} else {mergeable_base_seq:$fs} end)),
      refreshed_at:"2026-11-26T09:00:00Z"}, age_s:$a}' > "$L/w/rec-$LR-$1.json"
}
CF=number,url,headRefOid,headRefName,baseRefName,isDraft,mergeStateStatus,mergeable,state,labels,updatedAt,isCrossRepository
tick() { drv "harness_pr_list $SLUG open $CF 100 > \"\$TMPDIR/list.json\"; echo LRC=\$?"; }
served() { cnt "$L/count" '^RSERVED '; }
missed() { cnt "$L/count" '^RMISS '; }
seqmiss() { cnt "$L/count" '^RMISS-SEQ '; }
idle10() { local n; reset; for n in $(seq 1 10); do pr "$n" clean; rec "$n" 2000 "$(hd "$n")" clean 5; done; seqs '{"main":5,"ticket/other":2}'; }

# ============================================================================
# R1-R3: the ticket's acceptance numbers
# ============================================================================
idle10
for k in 1 2 3; do
  newlog; tick
  grep -q '^LRC=0$' "$L/drv.out" && ok "R1 tick $k: the list answers" || bad "R1 tick $k: list rc ($(cat "$L/drv.out"); $(tail -3 "$L/drv.err"))"
  eq "R1 tick $k: 0 pulls/N reads" "$(pulls)" 0
  eq "R1 tick $k: 10 rows served" "$(served)" 10
  eq "R1 tick $k: 1 base-seq GET (the tick memo)" "$(seqget)" 1
done
eq "R1 every row reads CLEAN" "$(jq -r '[.[].mergeStateStatus] | unique | join(",")' "$L/tmp/list.json" 2>/dev/null)" CLEAN
seqs '{"main":6,"ticket/other":2}'
newlog; tick
eq "R2 the base moved: 10 pulls/N reads" "$(pulls)" 10
eq "R2 10 misses" "$(missed)" 10
eq "R2 10 RMISS-SEQ words" "$(seqmiss)" 10
eq "R2 10 note PUTs" "$(cnt "$L/w/puts" .)" 10
eq "R2 every PUT carries mergeable_base_seq 6" "$(jq -s '[.[] | .fields.mergeable_base_seq] | unique | map(tostring) | join(",")' -r "$L/w/puts" 2>/dev/null)" 6
eq "R2 every PUT carries mergeable_state" "$(jq -s '[.[] | .fields.mergeable_state] | unique | join(",")' -r "$L/w/puts" 2>/dev/null)" clean
newlog; tick
eq "R2 the tick after: 0 pulls/N reads" "$(pulls)" 0
eq "R2 the tick after: 10 served" "$(served)" 10
seqs '{"main":6,"ticket/other":3}'
newlog; tick
eq "R3 a push to another branch: 0 pulls/N reads" "$(pulls)" 0
eq "R3 10 served" "$(served)" 10
# R0: the round-1 red as this suite's own case. Records 10 s old with no
# mergeable_base_seq, and a jobs worker with no base-seq route (404): the
# sequence is unusable, so rule 3 (today's 600 s age rule) serves every row.
reset; for n in $(seq 1 10); do pr "$n" clean; rec "$n" 10 "$(hd "$n")" clean null; done; : > "$L/w/seq-404"
newlog; tick
eq "R0 no sequence, base-seq 404, rows 10 s old: 0 pulls/N reads" "$(pulls)" 0
eq "R0 10 RSERVED (rule 3)" "$(served)" 10
eq "R0 0 misses" "$(missed)" 0

# ============================================================================
# S1-S9: the misses
# ============================================================================
idle10; : > "$L/w/seq-down"
newlog; tick
eq "S1 the base-seq read fails (500): 10 GitHub reads" "$(pulls)" 10
eq "S1 0 record serves" "$(served)" 0
eq "S1 10 misses" "$(missed)" 10
eq "S1 10 RMISS-SEQ words" "$(seqmiss)" 10
eq "S1 no memo is written" "$(memos)" 0
eq "S1 one negative memo is written" "$(negmemos)" 1
# S12 (r4): the failed read is made once per repo per tick, not once per row.
eq "S12 the base-seq route fails, 10 rows: exactly 1 base-seq GET this tick" "$(seqget)" 1
newlog; tick
eq "S12 the next tick (new MC_TICK_ID): 1 base-seq GET again" "$(seqget)" 1
eq "S12 the next tick: one negative memo per tick (2 in all)" "$(negmemos)" 2
H1=$(hd 1)
# serve <case> <n> [ENV=value ...] — prr_serve_state on demo-os#<n> at its list head.
serve() {
  local c=$1 n=$2; shift 2
  rm -f "$L/tmp/out.json" "$L/count"
  drv "$(printf '%q ' export SCASE="$c" "$@"); prr_serve_state $SLUG $n $(hd "$n") \"\$TMPDIR/out.json\"; echo SRC=\$?"
  DRC=$(sed -n 's/^SRC=//p' "$L/drv.out")
}
reset; seqs '{"ticket/other":2}'; rec 1 2000 "$H1" clean 5
serve S2 1; eq "S2 no base row for main: a miss" "$DRC" 1
eq "S2 RMISS-SEQ" "$(seqmiss)" 1
reset; seqs '{"main":5}'; rec 1 2000 "$H1" clean null
serve S3 1; eq "S3 the row has no mergeable_base_seq: a miss" "$DRC" 1
reset; seqs '{"main":5}'; rec 1 2000 "$(hd 2)" clean 5
serve S4 1; eq "S4 the head differs from the list head: a miss" "$DRC" 1
eq "S4 the miss is not a sequence miss" "$(seqmiss)" 0
reset; seqs '{"main":5}'; rec 1 2000 "$H1" unknown 5
serve S5 1; eq "S5 state unknown: a miss" "$DRC" 1
reset; seqs '{"main":5}'; rec 1 2000 "$H1" null 5
serve S5b 1; eq "S5b state NULL: a miss" "$DRC" 1
reset; seqs '{"main":5}'; rec 1 3601 "$H1" clean 5
serve S6 1; eq "S6 age 3,601 over the knob 3,600: a miss" "$DRC" 1
reset; seqs '{"main":5}'; rec 1 3600 "$H1" clean 5
serve S6a 1; eq "S6a age 3,600 (the knob): served" "$DRC" 0
eq "S6a the served body" "$(jq -c '[.mergeable_state, .head.sha, .mergeable]' "$L/tmp/out.json" 2>/dev/null)" "[\"clean\",\"$H1\",true]"
# S10: rule 2 (SEQ-MOVED) beats the age rule: young rows, stored 5, current 6.
idle10; for n in $(seq 1 10); do rec "$n" 10 "$(hd "$n")" clean 5; done; seqs '{"main":6}'
newlog; tick
eq "S10 a young row whose base moved: 10 GitHub reads" "$(pulls)" 10
eq "S10 0 RSERVED" "$(served)" 0
eq "S10 10 RMISS-SEQ" "$(seqmiss)" 10
# S11: the seq knob 0 turns rule 1 off; rule 3 still serves a young row.
reset; seqs '{"main":5}'; rec 1 3000 "$H1" clean 5
serve S11 1 PR_RECORD_SERVE_SEQ_MAX_AGE_S=0; eq "S11 seq knob 0, row 3,000 s old: a miss" "$DRC" 1
reset; seqs '{"main":5}'; rec 1 10 "$H1" clean 5
serve S11b 1 PR_RECORD_SERVE_SEQ_MAX_AGE_S=0; eq "S11b seq knob 0, row 10 s old: served (rule 3)" "$DRC" 0
reset; seqs '{"main":5}'; rec 1 10 "$H1" clean 5
newlog; serve S11c 1 PR_RECORD_SERVE_SEQ_MAX_AGE_S=0 PR_RECORD_SERVE_MAX_AGE_S=0
eq "S11c both knobs 0: a miss" "$DRC" 1
eq "S11c both knobs 0: no record peek" "$(cnt "$L/w/curl.log" '/api/pr-records\?')" 0
reset; seqs '{"main":5}'; rec 1 2000 "$H1" clean 5 2026-11-26T09:30:00Z 2026-11-26T09:00:00Z
serve S7 1; eq "S7 a webhook wrote mergeable_state after the sequence: a miss" "$DRC" 1
reset; seqs '{"main":5}'; rec 1 2000 "$H1" blocked 5 2026-11-26T09:00:00Z 2026-11-26T09:00:00Z feature/x
serve S7b 1; eq "S7b the row's base is not in the base-seq answer: a miss" "$DRC" 1
# S13 (r5, refute F1): CI and reviews move blocked/unstable/has_hooks with no
# base push, so rule 1 never extends those states past the age knob (600 s).
for st in blocked unstable has_hooks; do
  reset; seqs '{"main":5}'; rec 1 3000 "$H1" "$st" 5
  serve "S13-$st" 1; eq "S13 $st, seq match, age 3,000 s: a miss" "$DRC" 1
  eq "S13 $st: the miss is not a sequence miss" "$(seqmiss)" 0
  reset; seqs '{"main":5}'; rec 1 300 "$H1" "$st" 5
  serve "S13b-$st" 1; eq "S13b $st, seq match, age 300 s: served by the age rule" "$DRC" 0
done
for st in clean dirty behind draft; do
  reset; seqs '{"main":5}'; rec 1 3000 "$H1" "$st" 5
  serve "S13c-$st" 1; eq "S13c $st, seq match, age 3,000 s: served by the sequence rule" "$DRC" 0
done
# S13d: a full tick. A PR whose CI ran green after a BLOCKED read: 1 pulls/N read, CLEAN.
reset; pr 1 clean; rec 1 3000 "$H1" blocked 5; seqs '{"main":5}'
newlog; tick
eq "S13d blocked row 3,000 s old, seq match: 1 pulls/1 read" "$(pulls 1)" 1
eq "S13d the list reads the live CLEAN" "$(jq -r '.[0].mergeStateStatus' "$L/tmp/list.json" 2>/dev/null)" CLEAN
# S14 (r6): rule 1 times the STATE, not the row. A webhook write of another
# field moves refreshed_at; the state read 1 h before it is still 1 h older.
# Row: age_s 2,000, state and sequence written 08:00, refreshed_at 09:00.
reset; seqs '{"main":5}'; rec 1 2000 "$H1" clean 5 2026-11-26T08:00:00Z
serve S14 1; eq "S14 state 5,600 s old, row 2,000 s old, seq match: a miss" "$DRC" 1
eq "S14 the miss is not a sequence miss" "$(seqmiss)" 0
reset; seqs '{"main":5}'; rec 1 2000 "$H1" clean 5 2026-11-26T08:30:00Z
serve S14b 1; eq "S14b state 3,800 s old: a miss" "$DRC" 1
reset; seqs '{"main":5}'; rec 1 2000 "$H1" clean 5 2026-11-26T08:40:00Z
serve S14c 1; eq "S14c state 3,200 s old, seq match: served by the sequence rule" "$DRC" 0
reset; seqs '{"main":5}'; rec 1 100 "$H1" clean 5 2026-11-26T08:00:00Z
serve S14d 1; eq "S14d state 3,700 s old, row 100 s old: served by the age rule (today's rule)" "$DRC" 0
reset; seqs '{"main":5}'; rec 1 2000 "$H1" clean 5 2026-11-26T08:59:59.250Z
serve S14e 1; eq "S14e a fractional fields_at time parses: served" "$DRC" 0
# S8: a push lands while GitHub is read; the note keeps the sequence read first.
reset; pr 1 clean; rec 1 2000 "$H1" clean 4; seqs '{"main":5}'
printf '{"main":6}\n' > "$L/raise-on-read"
newlog; tick
eq "S8 tick 1 reads pulls/1 (seq 4 != 5)" "$(pulls 1)" 1
eq "S8 the note stores the sequence read before the GitHub read (5)" "$(jq -r .fields.mergeable_base_seq "$L/w/puts" 2>/dev/null)" 5
rm -f "$L/raise-on-read"
newlog; tick
eq "S8 next tick: seq 6 != 5, pulls/1 read again" "$(pulls 1)" 1
eq "S8 next tick's note stores 6" "$(jq -r .fields.mergeable_base_seq "$L/w/puts" 2>/dev/null)" 6
newlog; tick
eq "S8 the tick after: served, 0 reads" "$(pulls 1)" 0
reset; rec 1 2000 "$H1" clean 5; printf 'not json\n' > "$L/w/seq-raw"
serve S9 1; eq "S9 the base-seq answer is not JSON: a miss" "$DRC" 1
eq "S9 no memo" "$(memos)" 0
reset; rec 1 2000 "$H1" clean 5; printf '{"rows":"x"}\n' > "$L/w/seq-raw"
serve S9b 1; eq "S9b {rows:\"x\"}: a miss" "$DRC" 1
eq "S9b no memo" "$(memos)" 0
reset; rec 1 2000 "$H1" clean 5; printf '{"rows":[{"base_ref":"main","seq":"5"}]}\n' > "$L/w/seq-raw"
serve S9c 1; eq "S9c a seq that is a string: a miss" "$DRC" 1

# ============================================================================
# B1-B6: the branch lookup from the record
# ============================================================================
D="$L/h/state/pr-snapshot/example-org_demo-os"
PIN="$L/tmp/pin/t.refspin-"
# open50 — the shared open snapshot (50 PRs on ticket/bh-<n>) and the record list
# answer of the same 50, each with head_commit {sha = the list head}.
open50() {
  mkdir -p "$D" "$L/tmp/pin"
  seq 1 50 | jq -Rsc '[split("\n")[] | select(length > 0) | tonumber
    | {number: ., head: {ref: ("ticket/bh-" + tostring), sha: ""}, base: {ref: "main"}}]' > "$D/open.json"
  jq -c '[.[] | .head.sha = ($h[.number - 1])]' --argjson h "$(for n in $(seq 1 50); do hd "$n"; echo; done | jq -Rsc 'split("\n") | map(select(length > 0))')" \
    "$D/open.json" > "$D/open.tmp" && mv "$D/open.tmp" "$D/open.json"
  jq -c --argjson age "${1:-10}" '{rows: [.[] | {number, title: "t", head_ref: .head.ref, head_sha: .head.sha, base_ref: "main",
      author: "operator", labels: [], body: "", mergeable_state: "clean", updated_at: "2026-11-26T09:00:00Z",
      created_at: "2026-11-01T00:00:00Z", url: "https://github.com/x", draft: 0, merged_at: null, reviews: null,
      head_commit: {sha: .head.sha, at: "2026-11-26T08:00:00Z"}}],
    truncated: false, missing: null, unknown: 0, sync: {synced_at: "2026-11-26T09:00:00Z", age_s: $age, rows: 50}}' \
    "$D/open.json" > "$L/w/list-$LR.json"
  jq -c '[.[] | {ref: ("refs/heads/" + .head.ref), object: {sha: .head.sha, type: "commit"}}]
    + [{ref: "refs/heads/ticket/no-pr", object: {sha: "'"$(hd 99)"'", type: "commit"}}]' "$D/open.json" > "$L/refs.json"
}
# lag50 — prs_refs_pin over the 50 branches, then head_lag_tip for each at its head.
lag50() {
  drv 'br=(); for n in $(seq 1 50); do br+=("ticket/bh-$n"); done
    prs_refs_pin '"$SLUG"' '"$PIN"' "${br[@]}"
    bad=0; for n in $(seq 1 50); do
      h=$(printf "%040x" $((0xbee000 + n)))
      MC_REFS_PIN_PREFIX='"$PIN"' head_lag_tip '"$SLUG"' "ticket/bh-$n" "$TMPDIR/tip" "$h" || bad=$((bad + 1))
      [ "$(cat "$TMPDIR/tip")" = "$h" ] || bad=$((bad + 1))
    done; echo "BAD=$bad"'
}
listget() { cnt "$L/w/curl.log" '^GET .*/api/pr-records\?.*state=open.*with=head_commit'; }
reset; open50 10; newlog
PR_SNAPSHOT=1 lag50
eq "B1 50 tips right" "$(sed -n 's/^BAD=//p' "$L/drv.out")" 0
eq "B1 a trusted list: 0 GitHub calls in all" "$(cnt "$L/argv" 'GET ')" 0
eq "B1 1 record list GET with=head_commit" "$(listget)" 1
[ ! -f "$D/refs-ticket.json" ] && ok "B5 the record answer is not written to the shared refs cache" \
  || bad "B5 refs-ticket.json written ($(jq length "$D/refs-ticket.json") refs)"
eq "B1 the pin holds the record answer" "$(jq -r 'length' "${PIN}example-org_demo-os-ticket.json" 2>/dev/null)" 50
reset; open50 99999; newlog
PR_SNAPSHOT=1 lag50
eq "B2 a stale list: 50 tips right" "$(sed -n 's/^BAD=//p' "$L/drv.out")" 0
eq "B2 a stale list: exactly 1 matching-refs call" "$(mrefs)" 1
eq "B2 no branches/ read" "$(cnt "$L/paths" '/branches/')" 0
eq "B2 the GitHub answer is cached (today's rule)" "$(jq -r 'length' "$D/refs-ticket.json" 2>/dev/null)" 51
grep -q 'PRR_MISS lane=merge-conductor key=example-org/demo-os#refs:ticket why=stale fallback=github' "$L/h/logs/prr-shadow.log" 2>/dev/null \
  && ok "B2 one PRR_MISS line names stale" || bad "B2 no PRR_MISS stale line: $(cat "$L/h/logs/prr-shadow.log" 2>/dev/null)"
# B3: the branch is not in the record (a base branch with no open PR of its own).
reset; open50 10; newlog
PR_SNAPSHOT=1 drv 'prs_branch_tip '"$SLUG"' ticket/no-pr; echo "RC=$?"'
eq "B3 the branch from GitHub" "$(head -1 "$L/drv.out")" "$(hd 99)"
eq "B3 1 matching-refs call" "$(mrefs)" 1
grep -q 'why=field:absent' "$L/h/logs/prr-shadow.log" 2>/dev/null && ok "B3 PRR_MISS field:absent" \
  || bad "B3 no field:absent line: $(cat "$L/h/logs/prr-shadow.log" 2>/dev/null)"
# B4: a row without head_commit is absent.
reset; open50 10; jq -c '.rows |= map(if .number == 7 then del(.head_commit) else . end)' "$L/w/list-$LR.json" > "$L/w/l.tmp" \
  && mv "$L/w/l.tmp" "$L/w/list-$LR.json"; newlog
PR_SNAPSHOT=1 drv 'prs_branch_tip '"$SLUG"' ticket/bh-7; echo "RC=$?"'
eq "B4 no head_commit: the tip from GitHub" "$(head -1 "$L/drv.out")" "$(hd 7)"
eq "B4 1 matching-refs call" "$(mrefs)" 1
newlog; PR_SNAPSHOT=1 drv 'prs_branch_tip '"$SLUG"' ticket/bh-8; echo "RC=$?"'
eq "B4 another row (in the fresh cache) answers" "$(head -1 "$L/drv.out")" "$(hd 8)"
# B6: not the conductor: today's GitHub read, 0 jobs list GETs.
reset; open50 10; newlog
PR_SNAPSHOT=1 DRV_NO_PRR_OPEN=1 drv 'prs_branch_tip '"$SLUG"' ticket/bh-3; echo "RC=$?"'
eq "B6 without PRS_OPEN_PRR: the GitHub tip" "$(head -1 "$L/drv.out")" "$(hd 3)"
eq "B6 1 matching-refs call" "$(mrefs)" 1
eq "B6 0 jobs list GETs" "$(cnt "$L/w/curl.log" 'state=open')" 0

# B7: pr_record_list takes only head_commit as its 6th arg.
reset; newlog
drv 'pr_record_list '"$SLUG"' open "$TMPDIR/l.json" "" "" body >/dev/null; echo "RC=$?"'
eq "B7 pr_record_list with=body: rc 2" "$(sed -n 's/^RC=//p' "$L/drv.out")" 2
eq "B7 no record list GET" "$(cnt "$L/w/curl.log" "/api/pr-records")" 0

# ============================================================================
# O1-O4: steps off and shadow, and the lib alone
# ============================================================================
idle10; newlog
STEP=off tick
eq "O1 step off, rows 2,000 s old (knob 600): 10 pulls/N reads" "$(pulls)" 10
eq "O1 step off: 0 base-seq GETs" "$(seqget)" 0
eq "O1 step off: the note carries no sequence" "$(jq -s '[.[] | .fields | has("mergeable_base_seq")] | any' "$L/w/puts" 2>/dev/null)" false
idle10; for n in $(seq 1 10); do rec "$n" 100 "$(hd "$n")" clean 5; done; newlog
STEP=off tick
eq "O1b step off, rows 100 s old: 0 pulls/N reads (today's age rule)" "$(pulls)" 0
eq "O1b 10 served" "$(served)" 10
idle10; newlog
STEP=shadow tick
eq "O2 step shadow: 10 pulls/N reads, as off" "$(pulls)" 10
eq "O2 step shadow: 10 note PUTs" "$(cnt "$L/w/puts" .)" 10
eq "O2 step shadow: the note carries the sequence" "$(jq -s '[.[] | .fields.mergeable_base_seq] | unique | map(tostring) | join(",")' -r "$L/w/puts" 2>/dev/null)" 5
eq "O2 step shadow: 1 base-seq GET" "$(seqget)" 1
for st in off shadow; do
  reset; open50 10; newlog
  STEP=$st PR_SNAPSHOT=1 lag50
  eq "O3 step $st: 50 tips right" "$(sed -n 's/^BAD=//p' "$L/drv.out")" 0
  eq "O3 step $st: 1 matching-refs call, as today" "$(mrefs)" 1
  eq "O3 step $st: the GitHub answer is cached" "$(jq -r 'length' "$D/refs-ticket.json" 2>/dev/null)" 51
done
idle10; newlog
STEP=none DRVF=drv-alone.sh tick
eq "O4 the lib alone, rows 2,000 s old: 10 pulls/N reads" "$(pulls)" 10
eq "O4 the lib alone: 0 base-seq GETs" "$(seqget)" 0
idle10; for n in $(seq 1 10); do rec "$n" 100 "$(hd "$n")" clean 5; done; newlog
STEP=none DRVF=drv-alone.sh tick
eq "O4 the lib alone, rows 100 s old: 0 reads" "$(pulls)" 0

# ============================================================================
# N1: the worker half, driven by its node suite (the writer of the sequences,
# the route, the PUT field and the list opt-in this suite's fake stands for)
# ============================================================================
for f in "$DIR/worker/jobs/src/lib/pr-base-seq.js" "$DIR/worker/jobs/src/routes/pr-base-seqs.js" \
         "$DIR/worker/jobs/src/lib/core.d/bh-10215-pr-base-seq.js" "$DIR/worker/jobs/src/routes/retention.d/bh-10215-pr-base-seqs.js" \
         "$DIR/worker/jobs/schema.d/202611261121-bh-10215-pr-base-seqs.sql" "$DIR/worker/jobs/test/route-table.d/bh-10215-pr-base-seqs.txt" \
         "$DIR/catalog/lanes.d/_lib.pr-record.knobs.d/PR_RECORD_SERVE_SEQ_MAX_AGE_S.json"; do
  [ -f "$f" ] && ok "N1 ${f#"$DIR"/} exists" || bad "N1 ${f#"$DIR"/} is missing"
done
if command -v node >/dev/null 2>&1; then
  NOUT=$(cd "$DIR/worker/jobs" && node --test test/pr-base-seq.bh-10215.test.js 2>&1); NRC=$?
  eq "N1 node --test worker/jobs/test/pr-base-seq.bh-10215.test.js" "$NRC" 0
  [ "$NRC" = 0 ] || printf '%s\n' "$NOUT" | grep -E '^not ok|# fail' | head -10
else
  echo "  skip N1 node suite: node is not installed on this box"
fi

# ============================================================================
# Z1
# ============================================================================
eq "Z1 no curl to api.github.com in the suite" "$(cnt "$L/github-curl.log" .)" 0

echo "mc-serve-base-seq.bh-10215: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
