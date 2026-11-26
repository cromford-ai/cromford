#!/bin/bash
# tests/mc-record-tick.bh-9938-test.sh — BH-9938 slice C1 (BH-9926 wave 6): the
# merge conductor's full tick reads the PR record.
#
# A WHOLE bin/merge-conductor.sh tick over the fixture of
# tests/mc-pulls-quota.bh-8457-test.sh R2: 50 open PRs (40 blocked, 5 unstable,
# 3 clean, 2 draft). Each record is 10 s old, holds the list head, and carries
# a completed, successful check for that head (the wave-4 CI word reads it),
# and the record's open list is fresh. The default-branch and cross-repo memos
# hold what a GitHub list read wrote (main; every PR same-repo).
#
#   AT1  step record: one full tick makes 10 GitHub calls or less (the ticket
#        target). The count is printed.
#   AT2  step record: 0 GitHub calls that name a PR number or a PR head, on
#        the first tick and on a second tick with no change.
#   AT3  step shadow makes the same GitHub calls as step off (today), and the
#        conductor's per-PR decision lines are the same.
#   AT4  step record with a stale list stamp: 1 PRR_MISS ... why=stale
#        fallback=github line and the GitHub list read.
#   AT5  step record with a PR the cross-repo memo does not know: the miss
#        field:cross, and the GitHub list read (the record never says "same
#        repo" on its own).
#   B1   no curl to api.github.com; every gh call hit the stub.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-record-tick.bh-9938-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null || { echo "SKIP: jq missing"; exit 0; }
command -v flock >/dev/null || { echo "SKIP: flock missing"; exit 0; }

SLUG=example-org/demo-os
UPD=2026-10-26T10:00:00Z
hd() { printf '%040x' "$((0xabc000 + $1))"; }   # the list head of PR <n>

# ---- the stubs ----------------------------------------------------------------
# gh: $GHT/prs.json is the open list; $GHT/pr/<n>.json is pulls/<n>. Every
# call's argv goes to $GHT/argv (the GitHub call count), GET paths to $GHT/paths.
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
  *"pr merge"*|*"pr edit"*|*"pr close"*|*"-X PATCH"*|*"-X PUT"*|*"-X DELETE"*)
    printf '%s\n' "$*" >> "$GHT/writes"; exit 1 ;;
  *"pr list"*) echo '[]'; exit 0 ;;
  *"POST graphql"*) printf 'HTTP/2 200\r\n\r\n{"data":{"repository":{"mergeQueue":null}}}\n'; exit 0 ;;
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
  repos/*/actions/runs\?head_sha=*)
    printf 'HTTP/2 200\r\n\r\n{"total_count":0,"workflow_runs":[]}\n' ;;
  repos/*/git/ref/heads/main)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "$(printf 'f%.0s' {1..40})" '{ref:"refs/heads/main", object:{sha:$s}}' ;;
  *) printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n' ;;
esac
exit 0
EOF
# curl: the jobs worker. Row GETs answer $W/rec-<repo>-<n>.json; the open-list
# GET answers $W/list.json; PUTs merge into the row. Every URL on
# api.github.com goes to $W/github-curl.log (B1).
cat > "$T/stubs/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET; D=""
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; --data-binary|-d|--data) D="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s %s\n' "$M" "$URL" >> "$W/curl.log"
case "$URL" in *api.github.com*) printf '%s\n' "$URL" >> "$W/github-curl.log" ;; esac
case "$M $URL" in
  "GET "*"/api/pr-records?"*"&state=open"*)
    if [ -f "$W/list.json" ]; then printf '%s\n200\n' "$(cat "$W/list.json")"; else printf '{"error":"x"}\n500\n'; fi ;;
  "GET "*"/api/pr-records?"*number=*)
    n=${URL##*number=}; n=${n%%&*}; r=${URL#*repo=}; r=${r%%&*}
    f="$W/rec-${r//\//_}-$n.json"
    if [ -f "$f" ]; then printf '%s\n200\n' "$(cat "$f")"; else printf '{"row":null,"age_s":null}\n200\n'; fi ;;
  "PUT "*"/api/pr-records")
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

# pr <n> <mergeable_state> [draft]: one open PR in GitHub's list and its body.
pr() {
  local n=$1 h; h=$(hd "$1")
  jq -c --argjson n "$n" --arg h "$h" --arg u "$UPD" --argjson dr "${3:-false}" '. + [{number:$n,
    html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)), title:"t", draft:$dr, state:"open",
    updated_at:$u, created_at:"2026-10-01T00:00:00Z", labels:[], user:{login:"operator",type:"User"},
    head:{sha:$h, ref:("ticket/bh-"+($n|tostring)), repo:{full_name:"example-org/demo-os"}},
    base:{ref:"main", repo:{full_name:"example-org/demo-os", default_branch:"main"}}}]' "$LT/prs.json" > "$LT/prs.tmp" && mv "$LT/prs.tmp" "$LT/prs.json"
  jq -nc --argjson n "$n" --arg h "$h" --arg u "$UPD" --arg st "$2" --argjson dr "${3:-false}" '{number:$n, state:"open",
    merged_at:null, draft:$dr, html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)), user:{login:"operator"},
    labels:[], head:{sha:$h, ref:("ticket/bh-"+($n|tostring)), repo:{full_name:"example-org/demo-os"}},
    base:{ref:"main", sha:"'"$(printf 'f%.0s' {1..40})"'", repo:{full_name:"example-org/demo-os"}},
    mergeable:($st != "dirty"), mergeable_state:$st, updated_at:$u}' > "$LT/pr/$n.json"
}
# rec <n> <mergeable_state> [draft]: its record, 10 s old, with a green check on the head.
rec() {
  local n=$1 h; h=$(hd "$1")
  jq -nc --argjson n "$n" --arg h "$h" --arg m "$2" --argjson dr "${3:-false}" \
    '{row:{repo:"example-org/demo-os", number:$n, state:"open", draft:(if $dr then 1 else 0 end), head_sha:$h,
      head_ref:("ticket/bh-"+($n|tostring)), base_ref:"main", mergeable_state:$m, labels:[],
      checks:{"workflow:CI": {status:"completed", conclusion:"success", sha:$h, at:"2026-10-26T09:59:00Z"}},
      refreshed_at:"2026-10-26T10:00:00Z"}, age_s:10}' > "$LT/w/rec-example-org_demo-os-$n.json"
}
# lrow <n> [draft]: one row of the record's open list.
lrow() {
  jq -nc --argjson n "$1" --arg h "$(hd "$1")" --arg u "$UPD" --argjson dr "${2:-false}" \
    '{number:$n, title:"t", head_ref:("ticket/bh-"+($n|tostring)), head_sha:$h, base_ref:"main", author:"operator",
      labels:[], body:"", mergeable_state:null, updated_at:$u, created_at:"2026-10-01T00:00:00Z",
      url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)), draft:(if $dr then 1 else 0 end), merged_at:null}'
}
PR50=(); for n in $(seq 1 50); do
  if [ "$n" -le 40 ]; then PR50+=("$n:blocked"); elif [ "$n" -le 45 ]; then PR50+=("$n:unstable")
  elif [ "$n" -le 48 ]; then PR50+=("$n:clean"); else PR50+=("$n:clean:true"); fi
done
# world [list-age]: a fresh world: GitHub, the records, the record list, the memos, empty logs.
world() {
  local s n st dr age="${1:-10}"
  scratch_rm "$LT/pr"; scratch_rm "$LT/w"; scratch_rm "$LT/h/state"; mkdir -p "$LT/pr" "$LT/w" "$LT/h/state"
  rm -f "$LT/paths" "$LT/argv" "$LT/writes" "$MCLOG" "$SHADOW"; echo '[]' > "$LT/prs.json"
  for s in "${PR50[@]}"; do
    IFS=: read -r n st dr <<<"$s"; pr "$n" "$st" "${dr:-false}"; rec "$n" "$st" "${dr:-false}"
    lrow "$n" "${dr:-false}"
  done | jq -sc --argjson a "$age" '{rows: ., truncated: false, sync: {synced_at: "2026-10-26T10:00:00Z", age_s: $a}, missing: null, unknown: 0}' > "$LT/w/list.json"
  mkdir -p "$LT/h/state/prr-default-branch"
  echo main > "$LT/h/state/prr-default-branch/example-org_demo-os"
  for n in $(seq 1 50); do printf '%s\tfalse\n' "$n"; done > "$LT/h/state/prr-default-branch/example-org_demo-os.cross"
}
# ltick <GH_SOURCE> [VAR=value ...]: one whole tick.
ltick() { local src="$1"; shift; ( cd "$LT" && env PATH="$LT/fakebin:$PATH" HARNESS="$LT/h" GHT="$LT" W="$LT/w" HARNESS_SECRET=fixture-secret \
  JOBS_URL=https://jobs.test JOBS_RETRIES=0 TMPDIR="$LT/h/tmp" LANE_GATE_DISABLE=1 GH_ETAG=0 GH_APP_TOKENS=0 \
  MC_REPOS="$LT/repos" MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_PR_PARALLEL=8 MC_TICK_SECS=0 \
  MC_HEAD_LAG_MINS=0 PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=600 PR_RECORD_MAX_AGE_S=900 PR_RECORD_LIST_MAX_AGE_S=900 \
  PRR_CI_NOW=1793000000 GH_SOURCE="$src" "$@" \
  bash "$LT/h/bin/merge-conductor.sh" >/dev/null 2>"$LT/tick.err" ); }
calls() { grep -c . "$LT/argv" 2>/dev/null || true; }
pr_calls() {   # GitHub calls that name a PR number or a PR head
  local heads; heads=$(for n in $(seq 1 50); do hd "$n"; echo; done | paste -sd'|' -)
  grep -cE "/(pulls|issues)/[0-9]+|$heads" "$LT/argv" 2>/dev/null || true
}
decisions() { grep -oE "$SLUG#[0-9]+[: ].*" "$MCLOG" 2>/dev/null | sed -E 's/[0-9]+(s|ms)\b/N\1/g' | sort; }

# ── AT1 / AT2: step record, a full tick ────────────────────────────────────────
world
ltick record; RC=$?
eq "AT1 full tick rc" "$RC" 0
N1=$(calls)
echo "  info AT1 measured: $N1 GitHub call(s) in one full tick over 50 PRs: $(tr '\n' ';' < "$LT/argv" 2>/dev/null)"
[ "$N1" -le 10 ] && ok "AT1 at most 10 GitHub calls in step record ($N1)" || bad "AT1 $N1 GitHub calls, want <= 10: $(head -12 "$LT/argv")"
eq "AT2 GitHub calls that name a PR or its head (tick 1)" "$(pr_calls)" 0
grep -q "PRR_MISS lane=merge-conductor key=$SLUG#open " "$SHADOW" 2>/dev/null && bad "AT2 the open list missed: $(grep 'PRR_MISS' "$SHADOW")" || ok "AT2 the open list was served by the record"
[ ! -s "$LT/writes" ] && ok "AT2 the observe tick wrote nothing to GitHub" || bad "AT2 GitHub writes: $(head -3 "$LT/writes")"
rm -f "$LT/argv" "$LT/paths"
ltick record
eq "AT2 GitHub calls that name a PR or its head (tick 2, no change)" "$(pr_calls)" 0
[ ! -e "$LT/h/state/pr-snapshot/example-org_demo-os/open.json" ] \
  || jq -e 'all(.[]; .head.repo.full_name == "example-org/demo-os")' "$LT/h/state/pr-snapshot/example-org_demo-os/open.json" >/dev/null \
  && ok "AT2 no record row was written into the shared snapshot" || bad "AT2 the shared snapshot holds record rows"

# ── AT3: step shadow = step off, for GitHub calls and decisions ─────────────────
world
ltick off; OFF_ARGV=$(sort "$LT/argv" 2>/dev/null); OFF_DEC=$(decisions)
world
ltick shadow; SH_ARGV=$(sort "$LT/argv" 2>/dev/null); SH_DEC=$(decisions)
[ -n "$OFF_ARGV" ] && ok "AT3 step off made GitHub calls ($(wc -l <<<"$OFF_ARGV"))" || bad "AT3 step off made no GitHub call: the fixture is wrong"
[ "$OFF_ARGV" = "$SH_ARGV" ] && ok "AT3 step shadow makes the same GitHub calls as step off" \
  || bad "AT3 GitHub calls differ: $(diff <(printf '%s\n' "$OFF_ARGV") <(printf '%s\n' "$SH_ARGV") | head -8)"
[ "$OFF_DEC" = "$SH_DEC" ] && ok "AT3 the per-PR decision lines are the same" \
  || bad "AT3 decisions differ: $(diff <(printf '%s\n' "$OFF_DEC") <(printf '%s\n' "$SH_DEC") | head -8)"
grep -q "PRR_SHADOW lane=merge-conductor key=$SLUG#open " "$SHADOW" 2>/dev/null \
  && bad "AT3 the record list differs from GitHub's: $(grep "key=$SLUG#open" "$SHADOW")" || ok "AT3 no PRR_SHADOW line for the open list (record = GitHub)"

# ── AT4: step record, a stale list stamp -> a miss and the GitHub list ─────────
world 5000
ltick record
eq "AT4 one PRR_MISS why=stale line for the open list" \
  "$(grep -c "PRR_MISS lane=merge-conductor key=$SLUG#open why=stale fallback=github" "$SHADOW" 2>/dev/null || true)" 1
[ "$(grep -cE "^repos/$SLUG/pulls(\$|\?)" "$LT/paths" 2>/dev/null || true)" -ge 1 ] && ok "AT4 the GitHub list was read" \
  || bad "AT4 no GitHub list read: $(cat "$LT/paths" 2>/dev/null | head -5)"

# ── AT5: step record, a PR the cross-repo memo does not know ───────────────────
world
sed -i '/^50\t/d' "$LT/h/state/prr-default-branch/example-org_demo-os.cross"
ltick record
eq "AT5 one PRR_MISS why=field:cross line" \
  "$(grep -c "PRR_MISS lane=merge-conductor key=$SLUG#open why=field:cross fallback=github" "$SHADOW" 2>/dev/null || true)" 1
grep -qP '^50\tfalse$' "$LT/h/state/prr-default-branch/example-org_demo-os.cross" \
  && ok "AT5 the GitHub list read wrote the memo back" || bad "AT5 the memo was not rewritten: $(tail -3 "$LT/h/state/prr-default-branch/example-org_demo-os.cross")"

# ── B1 ──────────────────────────────────────────────────────────────────────────
[ ! -s "$LT/w/github-curl.log" ] && ok "B1 no curl to api.github.com" || bad "B1 curl reached GitHub: $(head -3 "$LT/w/github-curl.log")"

echo "mc-record-tick.bh-9938: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
