#!/bin/bash
# tests/mc-record-reads-s2.bh-10257-test.sh — BH-10257 slice 2: the rest of the
# merge conductor's QUEUED-pass reads come from the PR record, with GitHub as
# the fallback. No shadow step.
#
# A WHOLE bin/merge-conductor.sh keyed tick (MC_ONLY_PR=...#1), the world of
# tests/mc-record-reads.bh-10257-test.sh, with one QUEUED row #7 on a Mergify
# repo. The open list holds #7 at ANOTHER head than its QUEUED head, so the
# QUEUED pass cannot take #7's view from the list (the hub's case: 2 pulls/7
# reads per QUEUED row per tick). The tick never works #7 in its open pass, so
# every `pulls/7` and `pulls/7/reviews` read is the QUEUED pass's own.
#
# THE VIEW (mc_queued_view_rec: state, head ref, head sha of a QUEUED row)
#   V1  step record, a fresh row (open, head = the QUEUED head): 0 pulls/7
#   V2  a stale row: pulls/7 is read 1 time (not 2: the view's GitHub read is
#       written back, and the queue word then reads the fresh row), one
#       PRR_MISS why=stale line for the view
#   V3  no row: pulls/7 is read 1 time
#   V4  the row holds another head: pulls/7 is read 1 time, why=head
#   V5  step off: pulls/7 is read 2 times (the view and the queue word, as
#       today); the record is not asked
#   V6  safety: the record answers OPEN only. A merged row reads GitHub, and
#       GitHub's answer settles #7 MERGED; a closed row reads GitHub
#   V7  MC_RECORD_MAX_AGE_S=0 trusts no row
#   V8  a merged PR whose closed webhook was lost: the row's age_s is fresh
#       (a reviews write-back moved refreshed_at) but fields_at.state is old,
#       so the view reads GitHub and #7 settles MERGED; no fields_at.state
#       reads GitHub too
#
# THE REVIEWS (mc_cr_standing_rec: is a CHANGES_REQUESTED standing on a QUEUED
# row). The record answers "none stands" only from a review sync: the
# conductor's own full GitHub reviews read of THIS head, written into the
# record (reviews_sync {head_sha, at, cr}), younger than MC_RECORD_MAX_AGE_S,
# and with no review delivered at or after it (fields_at.reviews < reviews_sync.at).
#   R1  a fresh sync of the head, no later review: 0 pulls/7/reviews reads
#   R2  no sync: 1 reviews read, and the read is written back (reviews_sync of
#       the head, cr 0); the next tick makes 0 reviews reads
#   R3  a sync of another head: 1 reviews read
#   R4  a sync older than MC_RECORD_MAX_AGE_S: 1 reviews read
#   R5  a review delivered after the sync (incomplete set): 1 reviews read, and
#       the CHANGES_REQUESTED GitHub holds reaches the dequeue step
#   R6  a sync that says a CR stands (cr 1) never serves: 1 reviews read
#   R7  step off: 1 reviews read; no sync is written
#   R8  a stale row (age_s) with a fresh sync: 1 reviews read
#   R9  reviews NULL: 1 reviews read (why=field:reviews)
#   R10 a review in the same second as the sync: 1 reviews read (sync-later)
#   R11 the write-back dates reviews_sync.at MC_CR_SYNC_SKEW_S before the read,
#       and its own fields_at.reviews one second before that
#
#   C1  the call count of one keyed tick, step off vs step record (printed)
#   B1  no curl to api.github.com; every gh call hit the stub
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-record-reads-s2.bh-10257-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null || { echo "SKIP: jq missing"; exit 0; }
command -v flock >/dev/null || { echo "SKIP: flock missing"; exit 0; }
unset GH_TOKEN GITHUB_TOKEN GH_TOKEN_INSTALLATION_ID GH_SOURCE GH_SOURCE_LANE MC_RECORD_MAX_AGE_S

SLUG=example-org/demo-os
UPD=2026-10-26T10:00:00Z
hd() { printf '%040x' "$((0xabc000 + $1))"; }   # the head of PR <n>
cnt() { local c=0; [ -f "$1" ] && c=$(grep -cE "$2" "$1"); echo "${c:-0}"; }
OTHER=$(printf 'd%.0s' {1..40})

# ---- the stubs ----------------------------------------------------------------
# gh: $GHT/prs.json is the open list; $GHT/pr/<n>.json is pulls/<n>;
# $GHT/reviews-<n>.json is pulls/<n>/reviews (a `-q` filter is applied, as gh
# does); $GHT/checks-<head>.json is commits/<head>/check-runs. argv ->
# $GHT/argv, GET paths -> $GHT/paths.
mkdir -p "$T/stubs"
cat > "$T/stubs/gh" <<'EOF'
#!/bin/bash
p=""; prev=""; q=""
for a in "$@"; do [ "$prev" = GET ] && p="$a"; [ "$prev" = -q ] && q="$a"; prev="$a"; done
case "$*" in *"auth token"*) echo tok-fixture-1; exit 0 ;; esac
printf '%s\n' "$*" >> "$GHT/argv"
[ -n "$p" ] && printf '%s\n' "$p" >> "$GHT/paths"
pg=1; [[ " $* " =~ [\&\ ]page=([0-9]+) ]] && pg="${BASH_REMATCH[1]}"
case "$*" in
  *"api rate_limit"*)
    echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}'; exit 0 ;;
  *"pr merge"*|*"pr edit"*|*"pr close"*|*"-X PATCH"*|*"-X PUT"*|*"-X DELETE"*|*"-X POST"*)
    printf '%s\n' "$*" >> "$GHT/writes"; exit 1 ;;
  *"pr list"*) echo '[]'; exit 0 ;;
  *"/reviews"*)
    n="${p##*/pulls/}"; n="${n%%/*}"; f="$GHT/reviews-$n.json"; [ -f "$f" ] || f=/dev/null
    j=$(cat "$f"); [ -n "$j" ] || j='[]'
    if [ -n "$q" ]; then jq -r "$q" <<<"$j"; else printf '%s\n' "$j"; fi
    exit 0 ;;
  *"/collaborators/"*"/permission"*) echo write; exit 0 ;;
  "api repos/"*" -q .id") echo 1; exit 0 ;;
esac
case "$p" in
  repos/*/pulls|repos/*/pulls\?state=open*)
    printf 'HTTP/2 200\r\n\r\n'; [ "$pg" = 1 ] && cat "$GHT/prs.json" || echo '[]' ;;
  repos/*/pulls/*/files*) printf 'HTTP/2 200\r\n\r\n[]\n' ;;
  repos/*/issues/*/comments*) printf 'HTTP/2 200\r\n\r\n[]\n' ;;
  repos/*/pulls/[0-9]*)
    n="${p##*/pulls/}"; n="${n%%[!0-9]*}"
    if [ -f "$GHT/pr/$n.json" ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$GHT/pr/$n.json"
    else printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n'; fi ;;
  repos/*/commits/*/check-runs*)
    h="${p#*/commits/}"; h="${h%%/*}"
    if [ -f "$GHT/checks-$h.json" ]; then printf 'HTTP/2 200\r\n\r\n'; cat "$GHT/checks-$h.json"
    else printf 'HTTP/2 200\r\n\r\n{"total_count":0,"check_runs":[]}\n'; fi ;;
  repos/*/actions/runs\?head_sha=*)
    printf 'HTTP/2 200\r\n\r\n{"total_count":0,"workflow_runs":[]}\n' ;;
  repos/*/git/ref/heads/main)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "$(printf 'f%.0s' {1..40})" '{ref:"refs/heads/main", object:{sha:$s}}' ;;
  *) printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n' ;;
esac
exit 0
EOF
# curl: the jobs worker. Row GETs answer $W/rec-<repo>-<n>.json; PUTs merge
# into the row (age_s 0, fields_at.<field> = the PUT's at). Every URL on
# api.github.com goes to $W/github-curl.log.
cat > "$T/stubs/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET; D=""
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; --data-binary|-d|--data) D="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s %s\n' "$M" "$URL" >> "$W/curl.log"
case "$URL" in *api.github.com*) printf '%s\n' "$URL" >> "$W/github-curl.log" ;; esac
case "$M $URL" in
  "GET "*"/api/pr-records?"*"&state=open"*) printf '{"error":"x"}\n500\n' ;;
  "GET "*"/api/pr-records?"*number=*)
    n=${URL##*number=}; n=${n%%&*}; r=${URL#*repo=}; r=${r%%&*}
    f="$W/rec-${r//\//_}-$n.json"
    if [ -f "$f" ]; then printf '%s\n200\n' "$(cat "$f")"; else printf '{"row":null,"age_s":null}\n200\n'; fi ;;
  "PUT "*"/api/pr-records")
    printf '%s\n' "$D" >> "$W/puts"
    r=$(jq -r .repo <<<"$D"); n=$(jq -r .number <<<"$D"); f="$W/rec-${r//\//_}-$n.json"
    old=$(jq -c '.row // {}' "$f" 2>/dev/null); [ -n "$old" ] || old='{}'
    row=$(jq -c --argjson o "$old" '. as $d | $o + .fields + {repo, number}
      + {fields_at: (($o.fields_at // {}) + (.fields | with_entries(.value = $d.at)))}' <<<"$D")
    printf '{"row":%s,"age_s":0}\n' "$row" > "$f"
    printf '{"row":%s,"applied":%s,"stale":[]}\n200\n' "$row" "$(jq -c '.fields | keys' <<<"$D")" ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/stubs/gh" "$T/stubs/curl"

# ---- the tick world ------------------------------------------------------------
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
LT="$T/lt"; mkdir -p "$LT"
( export HARNESS="$LT/h"; fx_mc_harness "$DIR" "$LT" && fx_conductor_tick "$DIR" "$LT" ) || { echo "FAIL: conductor fixture"; exit 1; }
scratch_install_closure bin/merge-conductor.sh "$LT/h" >/dev/null || { echo "FAIL: closure install failed for bin/merge-conductor.sh"; exit 1; }
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
[ -f "$DIR/bin/lib/mc/queue.sh" ] || exit 1   # impact: mc_queued_view_rec, mc_cr_standing_rec
[ -f "$DIR/bin/lib/block-gate.sh" ] || exit 1   # impact: bg_cr_standing (the GitHub side of the reviews read)
# Loaded by name or by path at run time, so no closure scan of the tick sees them.
for s in bin/merge-conductor.d/bh-8457-pr-record-serve.sh bin/merge-conductor.d/bh-9938-prr-open-list.sh bin/lib/prr-shadow.d/merge-conductor.sh bin/lib/prr-shadow.sh \
         bin/lib/pr-record.sh bin/lib/prr-ci-state.sh bin/lib/pr-snapshot.sh bin/lib/mc/external-enqueue.sh bin/lib/block-gate.sh; do
  scratch_install_closure "$s" "$LT/h" >/dev/null || { echo "FAIL: closure install failed for $s"; exit 1; }
done
mkdir -p "$LT/repos/demo-os/.git" "$LT/h/tmp" "$LT/w" "$LT/pr"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$LT/h/fleet.conf"
: > "$LT/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$LT/h/bin/agent-call.sh"; chmod +x "$LT/h/bin/agent-call.sh"
cp "$T/stubs/gh" "$T/stubs/curl" "$LT/fakebin/"
MCLOG="$LT/h/logs/merge-conductor.log"
SHADOW="$LT/h/logs/prr-shadow.log"
H7=$(hd 7)
# iso_ago <s>: the UTC time <s> seconds ago, computed when called (the suite runs minutes).
iso_ago() { date -u -d '@'"$(( $(date +%s) - $1 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -r "$(( $(date +%s) - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }

# pr <n> [labels-json] [list-head]: one open PR in GitHub's list and its pulls/<n> body.
pr() {
  local n=$1 h lb="${2:-[]}" lh; h=$(hd "$1"); lh="${3:-$h}"
  jq -c --argjson n "$n" --arg h "$lh" --arg u "$UPD" --argjson lb "$lb" '. + [{number:$n,
    html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)), title:"t", draft:false, state:"open",
    updated_at:$u, created_at:"2026-10-01T00:00:00Z", labels:($lb | map({name:.})), user:{login:"operator",type:"User"},
    head:{sha:$h, ref:("ticket/bh-"+($n|tostring)), repo:{full_name:"example-org/demo-os"}},
    base:{ref:"main", repo:{full_name:"example-org/demo-os", default_branch:"main"}}}]' "$LT/prs.json" > "$LT/prs.tmp" && mv "$LT/prs.tmp" "$LT/prs.json"
  jq -nc --argjson n "$n" --arg h "$h" --arg u "$UPD" --argjson lb "$lb" '{number:$n, state:"open",
    merged_at:null, draft:false, html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)), user:{login:"operator"},
    labels:($lb | map({name:.})), head:{sha:$h, ref:("ticket/bh-"+($n|tostring)), repo:{full_name:"example-org/demo-os"}},
    base:{ref:"main", sha:"'"$(printf 'f%.0s' {1..40})"'", repo:{full_name:"example-org/demo-os"}},
    mergeable:true, mergeable_state:"clean", updated_at:$u}' > "$LT/pr/$n.json"
}
# rec7 <age_s> [state] [head] [reviews_sync-json|null] [fields_at.reviews|null]: the record row of #7.
# fields_at.state and fields_at.head_sha are now, or $REC7_FS; reviews is {},
# or the JSON in $REC7_REVIEWS.
rec7() {
  local rv='{}'; [ -n "${REC7_REVIEWS:-}" ] && rv="$REC7_REVIEWS"
  jq -nc --argjson a "$1" --arg s "${2:-open}" --arg h "${3:-$H7}" --argjson rs "${4:-null}" --arg fr "${5:-}" \
    --arg fs "${REC7_FS:-$(iso_ago 0)}" --argjson rv "$rv" \
    '{row:({repo:"example-org/demo-os", number:7, state:$s, draft:0, head_sha:$h, head_ref:"ticket/bh-7", base_ref:"main",
      mergeable_state:"clean", labels:["merge-queue"],
      checks:{"Mergify Merge Queue": {status:"completed", conclusion:"success", sha:$h, at:"2026-10-26T09:59:00Z"},
              "workflow:CI": {status:"completed", conclusion:"success", sha:$h, at:"2026-10-26T09:59:00Z"}},
      reviews:$rv, fields_at:({state:$fs, head_sha:$fs} + (if $fr == "" then {} else {reviews:$fr} end)),
      refreshed_at:"2026-10-26T10:00:00Z"} + (if $rs == null then {} else {reviews_sync:$rs} end)), age_s:$a}' > "$LT/w/rec-example-org_demo-os-7.json"
}
sync7() { jq -nc --arg h "${1:-$H7}" --arg at "${2:-$(iso_ago 0)}" --argjson cr "${3:-0}" '{head_sha:$h, at:$at, cr:$cr}'; }
# world [list-head]: a fresh world. #1 open (the keyed PR), #7 open with our
# label and QUEUED in the conductor's rows at H7, but in the open list at
# another head (or at <list-head>).
world() {
  scratch_rm "$LT/pr"; scratch_rm "$LT/w"; scratch_rm "$LT/h/state"; mkdir -p "$LT/pr" "$LT/w" "$LT/h/state/merge-conductor"
  rm -f "$LT/paths" "$LT/argv" "$LT/writes" "$MCLOG" "$SHADOW" "$LT"/checks-*.json "$LT"/reviews-*.json; echo '[]' > "$LT/prs.json"
  pr 1; pr 7 '["merge-queue"]' "${1:-$OTHER}"
  echo mergify > "$LT/h/tmp/merge-queue-example-org_demo-os.provider"
  printf '%s#7\tQUEUED\t%s\t%s\t%s\t-\tenqueued\thttps://github.com/%s/pull/7\n' "$SLUG" "$(date +%s)" "$H7" "$H7" "$SLUG" \
    > "$LT/h/state/merge-conductor/pr-state.tsv"
}
# ltick <GH_SOURCE> [VAR=value ...]: one whole keyed tick.
ltick() { local src="$1"; shift; ( cd "$LT" && env PATH="$LT/fakebin:$PATH" HARNESS="$LT/h" GHT="$LT" W="$LT/w" HARNESS_SECRET=fixture-secret \
  JOBS_URL=https://jobs.test JOBS_RETRIES=0 TMPDIR="$LT/h/tmp" LANE_GATE_DISABLE=1 GH_ETAG=0 GH_APP_TOKENS=0 \
  MC_REPOS="$LT/repos" MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_PR_PARALLEL=8 MC_TICK_SECS=0 \
  MC_HEAD_LAG_MINS=0 PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=600 PR_RECORD_MAX_AGE_S=900 PR_RECORD_LIST_MAX_AGE_S=900 \
  MC_QUEUE_TTL=3600 PRR_CI_NOW=1793000000 MC_ONLY_PR="$SLUG#1" GH_SOURCE="$src" "$@" \
  bash "$LT/h/bin/merge-conductor.sh" >/dev/null 2>"$LT/tick.err" ); }
p7()  { cnt "$LT/paths" "^repos/$SLUG/pulls/7( |\$|\?)"; }
vmiss() { cnt "$SHADOW" "PRR_MISS lane=merge-conductor key=$SLUG#7@${H7:0:12}:view "; }
r7()  { cnt "$LT/paths" "^repos/$SLUG/pulls/7/reviews"; }
calls() { grep -c . "$LT/argv" 2>/dev/null || true; }
row7() { jq -r "${1:-.row.state}" "$LT/w/rec-example-org_demo-os-7.json" 2>/dev/null; }
state7() { awk -F'\t' -v k="$SLUG#7" '$1 == k { print $2 }' "$LT/h/state/merge-conductor/pr-state.tsv" 2>/dev/null; }

# ── V5 / C1: step off is the read of today ─────────────────────────────────────
world; rec7 10 open "$H7" "$(sync7)"
ltick off; RC=$?
eq "V5 tick rc (off)" "$RC" 0
[ "$(p7)" -ge 1 ] && ok "V5 setup: the tick ran the QUEUED pass for #7" \
  || bad "V5 setup: no QUEUED pass: $(tail -5 "$MCLOG" 2>/dev/null) $(tail -3 "$LT/tick.err")"
eq "V5 step off: pulls/7 is read 2 times (the view and the queue word)" "$(p7)" 2
eq "R7 step off: pulls/7/reviews is read 1 time" "$(r7)" 1
eq "V5 step off: the record row of #7 is never asked" "$(cnt "$LT/w/curl.log" 'pr-records\?repo=example-org/demo-os&number=7')" 0
eq "R7 step off: nothing is written into the record" "$(cnt "$LT/w/puts" '"number":7')" 0
eq "V5 #7 stays QUEUED" "$(state7)" QUEUED
OFF_CALLS=$(calls); OFF_P7=$(p7); OFF_R7=$(r7)

# ── V1 / R1: step record, a fresh row with a fresh sync of the head ─────────────
world; rec7 10 open "$H7" "$(sync7)"
ltick record; RC=$?
eq "V1 tick rc (record)" "$RC" 0
eq "V1 fresh row: 0 pulls/7 reads" "$(p7)" 0
eq "R1 fresh sync of the head, no later review: 0 reviews reads" "$(r7)" 0
eq "V1 #7 stays QUEUED" "$(state7)" QUEUED
grep -q "PRR_MISS lane=merge-conductor key=$SLUG#7@" "$SHADOW" 2>/dev/null \
  && bad "V1 a PRR_MISS line for #7: $(grep "key=$SLUG#7@" "$SHADOW")" || ok "V1 no PRR_MISS line for #7"
REC_CALLS=$(calls); REC_P7=$(p7); REC_R7=$(r7)

# ── C1 ─────────────────────────────────────────────────────────────────────────
echo "  info C1 one keyed tick, 1 QUEUED PR on Mergify (not in the open list at its head): step off $OFF_CALLS GitHub call(s)" \
     "(pulls/7 $OFF_P7, reviews $OFF_R7); step record $REC_CALLS (pulls/7 $REC_P7, reviews $REC_R7)"
[ "$REC_CALLS" -le $((OFF_CALLS - 4)) ] && ok "C1 step record makes at least 4 GitHub calls fewer ($OFF_CALLS -> $REC_CALLS)" \
  || bad "C1 step record made $REC_CALLS GitHub calls, step off $OFF_CALLS: want at least 4 fewer"

# ── V2 / R8: a stale row ───────────────────────────────────────────────────────
world; rec7 5000 open "$H7" "$(sync7)"
ltick record
eq "V2 stale row: pulls/7 is read 1 time (the view's read is written back)" "$(p7)" 1
eq "V2 one PRR_MISS why=stale line for the view" "$(cnt "$SHADOW" "PRR_MISS lane=merge-conductor key=$SLUG#7@${H7:0:12}:view why=stale fallback=github")" 1
eq "V2 #7 stays QUEUED" "$(state7)" QUEUED
# R8: the view's GitHub read above refreshed the row before the CR read, so
# R8 holds #7 in the open list at its QUEUED head (no view read): the CR read
# then meets the stale row itself.
world "$H7"; rec7 5000 open "$H7" "$(sync7)"
ltick record
eq "R8 stale row, fresh sync: 1 reviews read" "$(r7)" 1
eq "R8 one PRR_MISS why=stale line for the CR read" "$(cnt "$SHADOW" "PRR_MISS lane=merge-conductor key=$SLUG#7@${H7:0:12}:cr why=stale fallback=github")" 1

# ── V3 / R2: no row; both reads are written back ────────────────────────────────
world
ltick record
eq "V3 no row: the view reads GitHub 1 time (one PRR_MISS line for the view)" "$(vmiss)" 1
# The queue word reads pulls/7 too: the written row has no checks (slice 1's
# field:checks rule on Mergify).
eq "V3 no row: pulls/7 is read 2 times (the view, then the queue word's field:checks miss)" "$(p7)" 2
eq "R2 no row: 1 reviews read" "$(r7)" 1
eq "R2 the reviews read is written back: reviews_sync of the head" "$(row7 .row.reviews_sync.head_sha)" "$H7"
eq "R2 the written sync says no CR stands" "$(row7 .row.reviews_sync.cr)" 0
eq "V3 #7 stays QUEUED" "$(state7)" QUEUED
rm -f "$LT/paths" "$LT/argv" "$SHADOW"
ltick record
eq "V3 the next tick: the view reads the written row (no PRR_MISS line for the view)" "$(vmiss)" 0
eq "V3 the next tick: pulls/7 is read 1 time (the queue word only)" "$(p7)" 1
eq "R2 the next tick: 0 reviews reads" "$(r7)" 0

# ── V4 / R3: another head ──────────────────────────────────────────────────────
world; rec7 10 open "$OTHER" "$(sync7 "$OTHER")"
ltick record
eq "V4 head mismatch: pulls/7 is read 1 time" "$(p7)" 1
eq "V4 one PRR_MISS why=head line for the view" "$(cnt "$SHADOW" "PRR_MISS lane=merge-conductor key=$SLUG#7@${H7:0:12}:view why=head fallback=github")" 1
world; rec7 10 open "$H7" "$(sync7 "$OTHER")"
ltick record
eq "R3 a sync of another head: 1 reviews read" "$(r7)" 1

# ── R4: an old sync ────────────────────────────────────────────────────────────
world; rec7 10 open "$H7" "$(sync7 "$H7" "$(iso_ago 7200)")"
ltick record
eq "R4 a sync older than MC_RECORD_MAX_AGE_S: 1 reviews read" "$(r7)" 1

# ── R5: a review after the sync (the set is incomplete) moves nothing forward ──
world; rec7 10 open "$H7" "$(sync7 "$H7" "$(iso_ago 60)")" "$(iso_ago 0)"
jq -nc --arg h "$H7" --arg at "$(iso_ago 0)" '[{id:91, submitted_at:$at, user:{login:"lead-x", type:"User"}, author_association:"MEMBER",
  state:"CHANGES_REQUESTED", commit_id:$h, html_url:"https://github.com/example-org/demo-os/pull/7#pullrequestreview-91", body:"BLOCK"}]' > "$LT/reviews-7.json"
ltick record
eq "R5 a review after the sync: 1 reviews read" "$(r7)" 1
grep -qE "$SLUG#7 (WOULD dequeue|CR_DEQUEUED): a standing CHANGES_REQUESTED" "$MCLOG" 2>/dev/null \
  && ok "R5 GitHub's standing CR reaches the dequeue step" \
  || bad "R5 the CR was not seen: $(grep '#7' "$MCLOG" 2>/dev/null | tail -3)"

# ── R6: a sync that says a CR stands never serves ──────────────────────────────
world; rec7 10 open "$H7" "$(sync7 "$H7" "$(iso_ago 0)" 1)"
ltick record
eq "R6 a sync with cr 1: 1 reviews read" "$(r7)" 1

# ── V8: a merged PR whose closed webhook was lost still settles ──────────────
# The row looks fresh (age_s 10: the CR read's reviews write-back moved
# refreshed_at) and says open, but its state field was last written 2 hours
# ago. GitHub says merged. The view must read GitHub and settle #7.
world; REC7_FS=$(iso_ago 7200) rec7 10 open "$H7" "$(sync7)"
jq '.state = "closed" | .merged_at = "2026-10-26T11:00:00Z" | .merged = true' "$LT/pr/7.json" > "$LT/pr/7.tmp" && mv "$LT/pr/7.tmp" "$LT/pr/7.json"
ltick record
eq "V8 an old state field (fresh age_s): one PRR_MISS why=state-age line for the view" "$(cnt "$SHADOW" "key=$SLUG#7@${H7:0:12}:view why=state-age")" 1
grep -qE "$SLUG#7 QUEUED -> MERGED" "$MCLOG" 2>/dev/null && ok "V8 GitHub's answer settles #7 MERGED" \
  || bad "V8 #7 not settled: $(grep '#7' "$MCLOG" 2>/dev/null | tail -3)"
world; rec7 10 open "$H7" "$(sync7)"
jq 'del(.row.fields_at.state)' "$LT/w/rec-example-org_demo-os-7.json" > "$LT/w/r.tmp" && mv "$LT/w/r.tmp" "$LT/w/rec-example-org_demo-os-7.json"
ltick record
eq "V8 no fields_at.state: the view reads GitHub (why=state-age)" "$(cnt "$SHADOW" "key=$SLUG#7@${H7:0:12}:view why=state-age")" 1

# ── R9: reviews NULL (review webhooks are dropped on such a row) ────────────────
world; REC7_REVIEWS=null rec7 10 open "$H7" "$(sync7)"
ltick record
eq "R9 reviews NULL: 1 reviews read" "$(r7)" 1
eq "R9 one PRR_MISS why=field:reviews line" "$(cnt "$SHADOW" "key=$SLUG#7@${H7:0:12}:cr why=field:reviews")" 1

# ── R10: a review in the same second as the sync ────────────────────────────────
SAME=$(iso_ago 5)
world; rec7 10 open "$H7" "$(sync7 "$H7" "$SAME")" "$SAME"
ltick record
eq "R10 fields_at.reviews = reviews_sync.at (same second): 1 reviews read" "$(r7)" 1
eq "R10 one PRR_MISS why=sync-later line" "$(cnt "$SHADOW" "key=$SLUG#7@${H7:0:12}:cr why=sync-later")" 1

# ── R11: the write-back is dated MC_CR_SYNC_SKEW_S before the read ──────────────
world
ltick record MC_CR_SYNC_SKEW_S=600
SAT=$(row7 .row.reviews_sync.at); FAT=$(row7 .row.fields_at.reviews)
AGE=$(( $(date -u +%s) - $(jq -rn --arg t "$SAT" '$t | fromdateiso8601' 2>/dev/null || echo 0) ))
[ "$AGE" -ge 600 ] && [ "$AGE" -le 900 ] && ok "R11 reviews_sync.at is about MC_CR_SYNC_SKEW_S before the read (${AGE}s)" \
  || bad "R11 reviews_sync.at $SAT is ${AGE}s old: want 600..900"
[[ "$FAT" < "$SAT" ]] && ok "R11 the write-back's own fields_at.reviews ($FAT) is before reviews_sync.at" \
  || bad "R11 fields_at.reviews $FAT is not before reviews_sync.at $SAT"

# ── V6: the record answers OPEN only ───────────────────────────────────────────
world; rec7 10 merged
jq '.state = "closed" | .merged_at = "2026-10-26T11:00:00Z" | .merged = true' "$LT/pr/7.json" > "$LT/pr/7.tmp" && mv "$LT/pr/7.tmp" "$LT/pr/7.json"
ltick record
[ "$(p7)" -ge 1 ] && ok "V6 a merged row reads GitHub ($(p7))" || bad "V6 a merged row made no pulls/7 read"
grep -qE "$SLUG#7 QUEUED -> MERGED" "$MCLOG" 2>/dev/null && ok "V6 GitHub's answer settles #7 MERGED" \
  || bad "V6 #7 not settled: $(grep '#7' "$MCLOG" 2>/dev/null | tail -3)"
world; rec7 10 closed
ltick record
[ "$(cnt "$SHADOW" "key=$SLUG#7@${H7:0:12}:view why=state")" = 1 ] && ok "V6 a closed row reads GitHub (why=state)" \
  || bad "V6 a closed row: $(grep "#7@" "$SHADOW" 2>/dev/null | head -3)"

# ── V7: the knob 0 trusts no row ───────────────────────────────────────────────
world; rec7 10 open "$H7" "$(sync7)"
ltick record MC_RECORD_MAX_AGE_S=0
[ "$(p7)" -ge 1 ] && ok "V7 MC_RECORD_MAX_AGE_S=0: pulls/7 is read ($(p7))" || bad "V7 MC_RECORD_MAX_AGE_S=0: no pulls/7 read"
eq "V7 MC_RECORD_MAX_AGE_S=0: 1 reviews read" "$(r7)" 1

# ── B1 ──────────────────────────────────────────────────────────────────────────
[ ! -s "$LT/w/github-curl.log" ] && ok "B1 no curl to api.github.com" || bad "B1 curl reached GitHub: $(head -3 "$LT/w/github-curl.log")"

echo "mc-record-reads-s2.bh-10257: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
