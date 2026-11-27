#!/bin/bash
# tests/mc-record-reads.bh-10257-test.sh — BH-10257: the merge conductor's
# QUEUED pass reads the queue word of a QUEUED PR (mc_queue_state_rec: the PR
# facts `pulls/<n>` and, on Mergify, the queue check runs of the head) from the
# PR record, with GitHub as the fallback. No shadow step.
#
# A WHOLE bin/merge-conductor.sh keyed tick (MC_ONLY_PR=...#1) over the fixture
# of tests/mc-record-tick.bh-9938-test.sh, with one QUEUED row #7 on a Mergify
# repo. The tick never works #7 in its open pass, so every `pulls/7` and every
# `commits/<head of 7>/check-runs` read is the QUEUED pass's own.
#
#   F1  step record, a fresh record row (open, head = the QUEUED head, our
#       label, no red queue check): 0 pulls/7 and 0 check-runs reads; #7 stays
#       QUEUED
#   F2  step record, a stale row (age_s past MC_RECORD_MAX_AGE_S): pulls/7 is
#       read 1 time, one PRR_MISS why=stale line; the read is written back into
#       the record, and the next tick makes 0 pulls/7 reads
#   F3  step record, no row: pulls/7 is read 1 time (PRR_MISS)
#   F4  step record, the row's head is another sha: pulls/7 is read 1 time
#   F5  step off: pulls/7 1 time and check-runs 1 time (the read of today),
#       the pr-records row is never asked
#   F6  safety: the record never answers a word other than queued. A row that
#       says merged, one with the `dequeued` label, one without our label and
#       one with a red Mergify check on the head each read GitHub; the merged
#       row lets GitHub settle #7 MERGED
#   F7  the knob MC_RECORD_MAX_AGE_S=0 trusts no row
#   C1  the call count of one keyed tick, step off vs step record (printed)
#   B1  no curl to api.github.com; every gh call hit the stub
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-record-reads.bh-10257-test.sh
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

# ---- the stubs ----------------------------------------------------------------
# gh: $GHT/prs.json is the open list; $GHT/pr/<n>.json is pulls/<n>;
# $GHT/checks-<head>.json is commits/<head>/check-runs. argv -> $GHT/argv,
# GET paths -> $GHT/paths.
mkdir -p "$T/stubs"
cat > "$T/stubs/gh" <<'EOF'
#!/bin/bash
p=""; prev=""
for a in "$@"; do [ "$prev" = GET ] && p="$a"; prev="$a"; done
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
  *"/reviews"*) echo '[]'; exit 0 ;;
  "api repos/"*" -q .id") echo 1; exit 0 ;;
esac
case "$p" in
  repos/*/pulls|repos/*/pulls\?state=open*)
    printf 'HTTP/2 200\r\n\r\n'; [ "$pg" = 1 ] && cat "$GHT/prs.json" || echo '[]' ;;
  repos/*/pulls/*/files*) printf 'HTTP/2 200\r\n\r\n[]\n' ;;
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
# into the row (age_s 0). Every URL on api.github.com goes to $W/github-curl.log.
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
    row=$(jq -c --argjson o "$old" '$o + .fields + {repo, number}' <<<"$D")
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
[ -f "$DIR/bin/lib/mc/queue.sh" ] || exit 1   # impact: mc_queue_state_rec
# Loaded by name or by path at run time, so no closure scan of the tick sees them.
for s in bin/merge-conductor.d/bh-8457-pr-record-serve.sh bin/merge-conductor.d/bh-9938-prr-open-list.sh bin/lib/prr-shadow.d/merge-conductor.sh bin/lib/prr-shadow.sh \
         bin/lib/pr-record.sh bin/lib/prr-ci-state.sh bin/lib/pr-snapshot.sh bin/lib/mc/external-enqueue.sh; do
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

# pr <n> [labels-json]: one open PR in GitHub's list and its pulls/<n> body.
pr() {
  local n=$1 h lb="${2:-[]}"; h=$(hd "$1")
  jq -c --argjson n "$n" --arg h "$h" --arg u "$UPD" --argjson lb "$lb" '. + [{number:$n,
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
# rec7 <age_s> [state] [head] [labels-json] [mergify-conclusion]: the record row of #7.
rec7() {
  jq -nc --argjson a "$1" --arg s "${2:-open}" --arg h "${3:-$H7}" --argjson lb "${4:-[\"merge-queue\"]}" --arg c "${5:-success}" \
    '{row:{repo:"example-org/demo-os", number:7, state:$s, draft:0, head_sha:$h, head_ref:"ticket/bh-7", base_ref:"main",
      mergeable_state:"clean", labels:$lb,
      checks:{"Mergify Merge Queue": {status:"completed", conclusion:$c, sha:$h, at:"2026-10-26T09:59:00Z"},
              "workflow:CI": {status:"completed", conclusion:"success", sha:$h, at:"2026-10-26T09:59:00Z"}},
      refreshed_at:"2026-10-26T10:00:00Z"}, age_s:$a}' > "$LT/w/rec-example-org_demo-os-7.json"
}
# world: a fresh world. #1 open (the keyed PR), #7 open with our label and
# QUEUED in the conductor's rows, Mergify the provider, no record rows.
world() {
  scratch_rm "$LT/pr"; scratch_rm "$LT/w"; scratch_rm "$LT/h/state"; mkdir -p "$LT/pr" "$LT/w" "$LT/h/state/merge-conductor"
  rm -f "$LT/paths" "$LT/argv" "$LT/writes" "$MCLOG" "$SHADOW" "$LT"/checks-*.json; echo '[]' > "$LT/prs.json"
  pr 1; pr 7 '["merge-queue"]'
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
c7()  { cnt "$LT/paths" "^repos/$SLUG/commits/$H7/check-runs"; }
calls() { grep -c . "$LT/argv" 2>/dev/null || true; }
row7() { jq -r "${1:-.row.state}" "$LT/w/rec-example-org_demo-os-7.json" 2>/dev/null; }
queued7() { awk -F'\t' -v k="$SLUG#7" '$1 == k { print $2 }' "$LT/h/state/merge-conductor/pr-state.tsv" 2>/dev/null; }

# ── F5 / C1: step off is the read of today ─────────────────────────────────────
world; rec7 10
ltick off; RC=$?
eq "F5 tick rc (off)" "$RC" 0
# A `queued` word logs no line (the row simply stays), so the setup proof is
# the QUEUED pass's own reads of #7: the keyed tick (#1) never works #7.
[ "$(p7)" -ge 1 ] && ok "F5 setup: the tick ran the QUEUED pass for #7" \
  || bad "F5 setup: no QUEUED pass: $(tail -5 "$MCLOG" 2>/dev/null) $(tail -3 "$LT/tick.err")"
eq "F5 step off: pulls/7 is read 1 time" "$(p7)" 1
eq "F5 step off: check-runs of the head of #7 is read 1 time" "$(c7)" 1
eq "F5 step off: the record row of #7 is never asked" "$(cnt "$LT/w/curl.log" 'pr-records\?repo=example-org/demo-os&number=7')" 0
eq "F5 #7 stays QUEUED" "$(queued7)" QUEUED
OFF_CALLS=$(calls); OFF_P7=$(p7); OFF_C7=$(c7)

# ── F1: step record, a fresh row ───────────────────────────────────────────────
world; rec7 10
ltick record; RC=$?
eq "F1 tick rc (record)" "$RC" 0
eq "F1 fresh row: 0 pulls/7 reads" "$(p7)" 0
eq "F1 fresh row: 0 check-runs reads of the head of #7" "$(c7)" 0
eq "F1 #7 stays QUEUED" "$(queued7)" QUEUED
grep -q "PRR_MISS lane=merge-conductor key=$SLUG#7@" "$SHADOW" 2>/dev/null \
  && bad "F1 a PRR_MISS line for #7: $(grep "key=$SLUG#7@" "$SHADOW")" || ok "F1 no PRR_MISS line for #7"
REC_CALLS=$(calls); REC_P7=$(p7); REC_C7=$(c7)

# ── C1: the call count of one keyed tick ───────────────────────────────────────
echo "  info C1 one keyed tick, 1 QUEUED PR on Mergify: step off $OFF_CALLS GitHub call(s) (pulls/7 $OFF_P7, check-runs $OFF_C7);" \
     "step record $REC_CALLS (pulls/7 $REC_P7, check-runs $REC_C7)"
[ "$REC_CALLS" -le $((OFF_CALLS - 2)) ] && ok "C1 step record makes at least 2 GitHub calls fewer ($OFF_CALLS -> $REC_CALLS)" \
  || bad "C1 step record made $REC_CALLS GitHub calls, step off $OFF_CALLS: want at least 2 fewer"

# ── F2: step record, a stale row; the read is written back ──────────────────────
world; rec7 5000
ltick record
eq "F2 stale row: pulls/7 is read 1 time" "$(p7)" 1
eq "F2 one PRR_MISS why=stale line" "$(cnt "$SHADOW" "PRR_MISS lane=merge-conductor key=$SLUG#7@${H7:0:12}:queue why=stale fallback=github")" 1
eq "F2 #7 stays QUEUED" "$(queued7)" QUEUED
eq "F2 the GitHub read was written back into the record (age_s 0)" "$(row7 .age_s)" 0
eq "F2 the written row holds our label" "$(row7 '.row.labels | index("merge-queue") != null')" true
rm -f "$LT/paths" "$LT/argv" "$SHADOW"
ltick record
eq "F2 the next tick reads the written row: 0 pulls/7 reads" "$(p7)" 0
eq "F2 the next tick: 0 check-runs reads" "$(c7)" 0

# ── F3: no row ─────────────────────────────────────────────────────────────────
world
ltick record
eq "F3 no row: pulls/7 is read 1 time" "$(p7)" 1
eq "F3 one PRR_MISS line for #7" "$(cnt "$SHADOW" "PRR_MISS lane=merge-conductor key=$SLUG#7@")" 1
eq "F3 #7 stays QUEUED" "$(queued7)" QUEUED

# ── F4: the row holds another head ──────────────────────────────────────────────
world; rec7 10 open "$(printf 'd%.0s' {1..40})"
ltick record
eq "F4 head mismatch: pulls/7 is read 1 time" "$(p7)" 1
eq "F4 one PRR_MISS why=head line" "$(cnt "$SHADOW" "PRR_MISS lane=merge-conductor key=$SLUG#7@${H7:0:12}:queue why=head fallback=github")" 1

# ── F6: the record answers queued and nothing else ─────────────────────────────
world; rec7 10 merged
jq '.state = "closed" | .merged_at = "2026-10-26T11:00:00Z" | .merged = true' "$LT/pr/7.json" > "$LT/pr/7.tmp" && mv "$LT/pr/7.tmp" "$LT/pr/7.json"
ltick record
[ "$(p7)" -ge 1 ] && ok "F6 a merged row reads GitHub ($(p7))" || bad "F6 a merged row made no pulls/7 read"
grep -qE "$SLUG#7 QUEUED -> MERGED" "$MCLOG" 2>/dev/null && ok "F6 GitHub's answer settles #7 MERGED" \
  || bad "F6 #7 not settled: $(grep '#7' "$MCLOG" 2>/dev/null | tail -3)"
world; rec7 10 open "$H7" '["merge-queue","dequeued"]'
ltick record
eq "F6 a row with the dequeued label reads GitHub" "$(p7)" 1
world; rec7 10 open "$H7" '[]'
ltick record
eq "F6 a row without our label reads GitHub" "$(p7)" 1
world; rec7 10 open "$H7" '["merge-queue"]' failure
ltick record
eq "F6 a row with a red Mergify check on the head reads GitHub (pulls/7)" "$(p7)" 1
eq "F6 a row with a red Mergify check on the head reads GitHub (check-runs)" "$(c7)" 1

# ── F7: the knob 0 trusts no row ───────────────────────────────────────────────
world; rec7 10
ltick record MC_RECORD_MAX_AGE_S=0
eq "F7 MC_RECORD_MAX_AGE_S=0: pulls/7 is read 1 time" "$(p7)" 1

# ── B1 ──────────────────────────────────────────────────────────────────────────
[ ! -s "$LT/w/github-curl.log" ] && ok "B1 no curl to api.github.com" || bad "B1 curl reached GitHub: $(head -3 "$LT/w/github-curl.log")"

echo "mc-record-reads.bh-10257: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
