#!/bin/bash
# tests/stuck-work-reads.bh-4656-test.sh — BH-4660 (BH-4656.2): the stuck-work
# fact readers re-read CI and comment threads only on change. The real
# swf_pr_facts / swf_ticket_facts run on top of the real verbs; only the
# transports (gh_rest, _jobs_req) and, per case, prs_wake_seen are doubles.
#
#   W1  same head + updated_at, no wake  -> pass 2 makes 0 status / 0 check-runs
#       reads, state/stuck-work/ci/o_r-5 holds the line, fields 6,7,12 equal
#   W2a new head / W2b checks wake / W2c pr wake / W2d past STUCK_WORK_CI_TTL_S
#       / W2e TTL 0 -> both re-read once; W2f a failed read is never cached;
#       W2g a row with no updated_at is never cached
#   W3  issue wake -> comments?since=<max updated_at>, never a full page 1;
#       a new HOLD there sets issue_hold; W3b no wake -> 0 comment reads;
#       W3c comments with no id are never cached
#   W4a an edited comment replaces its old copy; W4b past STUCK_WORK_THREAD_FULL_S
#       -> full read; W4c FULL_S 0 -> always full; W4d a failed since= read is ?,
#       never the cache
#   W5  a PR gone from pass 2's list gets no CI read
#   W6a Blocked-by a listed issue -> 0 issues/<b> reads; W6b an unlisted one -> 1
#   W7a the contract's own prs_wake_seen (rc 2, lazily loaded) -> since=, never a skip
#   W7b a settings row of 0 beats env STUCK_WORK_CI_TTL_S=900
#   W8  HARNESS unset under the sandbox -> no cache, nothing under /root/harness
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/stuck-work-reads.bh-4656-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

for f in "$DIR/bin/lib/stuck-work/facts-pr.sh" "$DIR/bin/lib/stuck-work/facts-ticket.sh" "$DIR/bin/lib/pr-snapshot.sh"; do
  [ -f "$f" ] || { echo "FAIL: $f is missing"; echo "stuck-work-reads: 0 passed, 1 failed"; exit 1; }
done

NOW=1700009999
T0=1700000000
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
sha() { printf 'a%039d' "$1"; }
H1=$(sha 1); H2=$(sha 2); H6=$(sha 6)
U1=2026-10-01T00:00:00Z
TS1=2026-09-02T00:00:00Z; TS2=2026-09-03T00:00:00Z; TS3=2026-09-04T00:00:00Z; TS4=2026-09-05T00:00:00Z

mkdir -p "$T/shim"
# The registry, composed into the scratch tree (catalog/lanes.json is git-ignored).
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 && [ -s "$T/lanes.json" ] \
  || { echo "FAIL: bin/lanes-build.sh could not compose the registry"; echo "stuck-work-reads: 0 passed, 1 failed"; exit 1; }
printf '#!/bin/bash\necho "gh $*" >> "%s/gh-shim.calls"\nexit 1\n' "$T" > "$T/shim/gh"
chmod +x "$T/shim/gh"

# The prelude every pass sources: the real libs, then the two transport stubs.
cat > "$T/prelude.sh" <<EOF
. "$DIR/bin/lib/gh-rest.sh"
. "$DIR/bin/lib/gh-rest-list.sh"
. "$DIR/bin/lib/verdicts.sh"
. "$DIR/bin/lib/jobs/jobs.sh"
. "$DIR/bin/lib/jobs/dequeue-watch.sh"
. "$DIR/bin/lib/stuck-work/seen.sh"
eval "\$(sed -n '/^vs_context()/p' "$DIR/bin/lib/verdict-status.sh")"
eval "\$(sed -n '/^mc_mergify_check() {/,/^}/p;/^mc_mergify_check_live() {/,/^}/p' "$DIR/bin/lib/mc/queue.sh")"
eval "\$(sed -n '/^mc_handoff_id()/p;/^mc_resolver_claim_file()/p;/^mc_resolver_claim_get() {/,/^}/p' "$DIR/bin/lib/mc/classify.sh")"
. "$DIR/bin/lib/stuck-work/facts-pr.sh"
. "$DIR/bin/lib/stuck-work/facts-ticket.sh"
EOF
cat >> "$T/prelude.sh" <<'EOF'
# gh_rest <method> <path> [args] — logs "METHOD path" to $T/gh.calls and answers
# $T/gh/<key>: comments by issue, since-or-full and page; the issue list by page;
# anything else by its path with / as _. <key>.rc makes it fail.
gh_rest() {
  local m="$1" p="$2" f n s
  printf '%s %s\n' "$m" "$p" >> "$T/gh.calls"
  GH_REST_STATUS=200; GH_REST_REASON=
  case "$p" in
    repos/o/r/issues/*/comments\?*)
      n=${p#repos/o/r/issues/}; n=${n%%/*}; s=full; case "$p" in *since=*) s=since ;; esac
      f="$T/gh/comments.$n.$s.${p##*&page=}" ;;
    repos/o/r/issues\?*) f="$T/gh/list.${p##*&page=}" ;;
    *) f="$T/gh/${p//\//_}" ;;
  esac
  if [ -f "$f.rc" ]; then GH_REST_STATUS=403; return "$(cat "$f.rc")"; fi
  if [ -f "$f" ]; then cat "$f"; return 0; fi
  case "$p" in
    */status) echo '{"state":"pending","statuses":[]}' ;;
    */check-runs) echo '{"total_count":0,"check_runs":[]}' ;;
    *) GH_REST_STATUS=404; return 44 ;;
  esac
}
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" k
  JOBS_HTTP=200; JOBS_BODY=
  case "$p" in
    /api/settings) if [ -f "$T/settings" ]; then cat "$T/settings"; else echo '{"settings":[]}'; fi ;;
    /api/verdicts\?*) echo '{"standing":null}' ;;
    /api/pr-state\?*) JOBS_HTTP=404; return 2 ;;
    /api/dequeue-watch/actions*) echo '{"rows":[],"truncated":false}' ;;
    /api/ledger\?*)
      k=$(sed -n 's/.*[?&]key=\([^&]*\).*/\1/p' <<<"$p")
      if [ -f "$T/ledger/$k" ]; then cat "$T/ledger/$k"; else JOBS_HTTP=404; return 2; fi ;;
    /api/ledger)
      [ "$m" = PUT ] || return 1
      k=$(jq -r '.key|@uri' <<<"$b"); mkdir -p "$T/ledger"
      jq -c '{ledger:{status, detail}}' <<<"$b" > "$T/ledger/$k" ;;
    *) return 1 ;;
  esac
}
# A wake table ($T/wake, lines `kind key rc`, `*` matches anything, first match
# wins, no match is rc 1) replaces the contract's prs_wake_seen. With no table,
# the contract's own default stands, loaded lazily by swf_pr_facts.
if [ -f "$T/wake" ]; then
  . "$DIR/bin/lib/pr-snapshot.sh"
  prs_wake_seen() {
    local r
    printf 'WAKE %s %s %s %s\n' "$@" >> "$T/wake.calls"
    r=$(awk -v k="$2" -v key="$3" '($1 == k || $1 == "*") && ($2 == key || $2 == "*") { print $3; exit }' "$T/wake")
    return "${r:-1}"
  }
fi
[ "${APPLY:-}" = 1 ] && { . "$DIR/bin/lib/lane-gate.sh"; lane_env_apply stuck-work; }
EOF

# reset — a clean fixture tree (and no cache) for the next case.
reset() {
  rm -rf "$T/gh" "$T/ledger" "$T/h" "$T/wake" "$T/wake.calls" "$T/settings" "$T/count"
  mkdir -p "$T/gh" "$T/claims" "$T/h"; : > "$T/items"
}
# run <pr|ticket|both> [VAR=val...] — one pass in a clean env, HARNESS=$T/h.
# Outputs in $T/out.pr / $T/out.ticket, calls in $T/gh.calls, counts in $T/count.
run() {
  local w="$1"; shift
  : > "$T/gh.calls"; : > "$T/count"; rm -f "$T/out.pr" "$T/out.ticket"
  env -i PATH="$T/shim:$PATH" HOME="$T" T="$T" DIR="$DIR" HARNESS="$T/h" JOBS_BOX=test HARNESS_TEST_SANDBOX=1 \
    STUCK_WORK_NOW="$NOW" MC_RESOLVER_CLAIM_DIR="$T/claims" SWF_COUNT_FILE="$T/count" PR_SNAPSHOT_TTL_S=0 \
    LANE_REGISTRY="$T/lanes.json" W="$w" "$@" bash -c '
      . "$T/prelude.sh"
      case "$W" in pr|both) swf_pr_facts o/r > "$T/out.pr"; echo $? > "$T/rc.pr" ;; esac
      case "$W" in ticket|both) swf_ticket_facts o/r "$T/items" > "$T/out.ticket"; echo $? > "$T/rc.ticket" ;; esac
      type -t prs_open_list > "$T/loaded"' 2> "$T/err"
  return 0
}
calls() { grep -c -- "$1" "$T/gh.calls"; }
pf() { awk -F'\t' -v i="o/r#$1" -v n="$2" '$2 == i {print $n}' "$T/out.pr"; }
tf() { awk -F'\t' -v i="o/r#$1" -v n="$2" '$2 == i {print $n}' "$T/out.ticket"; }
# pr <num> <head> [updated_at] — one open-PR list row.
pr() {
  jq -nc --argjson n "$1" --arg h "$2" --arg u "${3:-}" --arg c "$(iso "$T0")" \
    '{number:$n, html_url:("https://github.com/o/r/pull/"+($n|tostring)), draft:false, created_at:$c,
      head:{sha:$h}, labels:[{name:"ai-build"}]} + (if $u == "" then {} else {updated_at:$u} end)'
}
prs() { printf '%s\n' "$@" | jq -sc . > "$T/gh/repos_o_r_pulls"; }
lead_ok() { # lead_ok <head> — a lead-verdict success on the head at T0
  jq -nc --arg t "$(iso "$T0")" '{state:"success",statuses:[{context:"lead-verdict",state:"success",updated_at:$t}]}' \
    > "$T/gh/repos_o_r_commits_$1_status"
}
queued() { # queued <head> — Mergify has the head queued
  jq -nc '{total_count:1,check_runs:[{name:"Mergify Merge Queue",status:"queued",conclusion:null,output:{title:"Queued"}}]}' \
    > "$T/gh/repos_o_r_commits_$1_check-runs"
}
CI="$T/h/state/stuck-work/ci/o_r-5"
TH="$T/h/state/stuck-work/thread/o_r-7"
# prime — PR #5 at H1/U1, wakes quiet, pass 1 run; extra args go to run.
prime() {
  reset
  prs "$(pr 5 "$H1" "$U1")"; lead_ok "$H1"; queued "$H1"
  printf '* * 1\n' > "$T/wake"
  run pr "$@"
}
# issue <n> <body> / comment <id> <body> <created> <updated>
issue() {
  jq -cn --argjson n "$1" --arg b "$2" \
    '{number:$n, state:"open", title:"t", body:$b, created_at:"2026-09-01T00:00:00Z",
      html_url:("https://github.com/o/r/issues/" + ($n|tostring)), labels:[{name:"ai-build"}], user:{login:"operator",type:"User"}}'
}
comment() { jq -cn --argjson id "$1" --arg b "$2" --arg c "$3" --arg u "$4" '{id:$id, body:$b, created_at:$c, updated_at:$u, user:{login:"operator", type:"User"}}'; }
list() { printf '%s\n' "$@" | jq -s . > "$T/gh/list.1"; }
thread_prime() { # issue #7 with comments 1 and 2, pass 1 with wakes quiet
  reset
  list "$(issue 7 body)"
  printf '%s\n' "$(comment 1 'Looks good.' "$TS1" "$TS1")" "$(comment 2 'Building.' "$TS2" "$TS2")" | jq -s . > "$T/gh/comments.7.full.1"
  printf '* * 1\n' > "$T/wake"
  run ticket "$@"
}
FULLRX='issues/7/comments?per_page=100'
SINCERX='issues/7/comments?since='

# ── W1 ─────────────────────────────────────────────────────────────────────
prime
[ "$(calls "commits/$H1/status")" = 1 ] && [ "$(calls "commits/$H1/check-runs")" = 1 ] && ok \
  || bad "W1 pass 1 wanted 1 status + 1 check-runs read, got $(calls status) / $(calls check-runs) ($(cat "$T/err"))"
want=$(printf '%s\t%s\t%s\tsuccess\t%s\tqueued' "$H1" "$U1" "$NOW" "$T0")
[ "$(cat "$CI" 2>/dev/null)" = "$want" ] && ok || bad "W1 the ci line is '$(cat "$CI" 2>/dev/null)', wanted '$want'"
p1="$(pf 5 6)|$(pf 5 7)|$(pf 5 12)"
[ "$p1" = "success|$T0|queued" ] && ok || bad "W1 pass 1 fields 6,7,12 '$p1'"
run pr STUCK_WORK_NOW=$((NOW+60))
[ "$(calls 'commits/.*/status')" = 0 ] && ok || bad "W1 pass 2 made $(calls 'commits/.*/status') status reads, wanted 0"
[ "$(calls 'commits/.*/check-runs')" = 0 ] && ok || bad "W1 pass 2 made $(calls 'commits/.*/check-runs') check-runs reads, wanted 0"
grep -qx 'CI-HIT 5' "$T/count" && ok || bad "W1 pass 2 count is '$(cat "$T/count")', wanted CI-HIT 5"
[ "$(pf 5 6)|$(pf 5 7)|$(pf 5 12)" = "$p1" ] && ok || bad "W1 pass 2 fields '$(pf 5 6)|$(pf 5 7)|$(pf 5 12)' != pass 1 '$p1'"
[ "$(pf 5 22)" = "$NOW" ] && ok || bad "W1 pass 2 first_seen '$(pf 5 22)', wanted the pass-1 anchor $NOW"
[ "$(cat "$T/rc.pr")" = 0 ] && ok || bad "W1 pass 2 rc $(cat "$T/rc.pr")"
grep -q "^WAKE o/r checks $H1 $NOW\$" "$T/wake.calls" && grep -q "^WAKE o/r pr 5 $NOW\$" "$T/wake.calls" && ok \
  || bad "W1 the wake feed was not asked about checks/pr since the line's epoch: $(cat "$T/wake.calls" 2>/dev/null)"

# ── W2 ─────────────────────────────────────────────────────────────────────
reread() { # reread <case> — both reads exactly once this pass
  [ "$(calls 'commits/.*/status')" = 1 ] && [ "$(calls 'commits/.*/check-runs')" = 1 ] && ok \
    || bad "$1 wanted 1 status + 1 check-runs read, got $(calls 'commits/.*/status') / $(calls 'commits/.*/check-runs')"
}
prime
prs "$(pr 5 "$H2" "$U1")"
run pr STUCK_WORK_NOW=$((NOW+60))
reread W2a; [ "$(calls "commits/$H2/status")" = 1 ] && ok || bad "W2a the new head was not the one read"
[ "$(cut -f1 "$CI")" = "$H2" ] && ok || bad "W2a the ci line was not rewritten for H2: $(cat "$CI")"
prime
printf 'checks %s 0\n* * 1\n' "$H1" > "$T/wake"
run pr STUCK_WORK_NOW=$((NOW+60)); reread W2b
prime
printf 'pr 5 0\n* * 1\n' > "$T/wake"
run pr STUCK_WORK_NOW=$((NOW+60)); reread W2c
# STUCK_WORK_CI_QUIET_TTL_S=0: a quiet feed no longer stretches the TTL (BH-6976).
prime STUCK_WORK_CI_TTL_S=300 STUCK_WORK_CI_QUIET_TTL_S=0
run pr STUCK_WORK_CI_TTL_S=300 STUCK_WORK_CI_QUIET_TTL_S=0 STUCK_WORK_NOW=$((NOW+299))
[ "$(calls 'commits/.*/status')" = 0 ] && ok || bad "W2d a line 299s old under TTL 300 was re-read"
run pr STUCK_WORK_CI_TTL_S=300 STUCK_WORK_CI_QUIET_TTL_S=0 STUCK_WORK_NOW=$((NOW+301)); reread W2d
[ "$(cut -f3 "$CI")" = $((NOW+301)) ] && ok || bad "W2d the line's epoch did not advance: $(cat "$CI")"
prime STUCK_WORK_CI_TTL_S=0
run pr STUCK_WORK_CI_TTL_S=0 STUCK_WORK_NOW=$((NOW+1)); reread W2e
reset
prs "$(pr 5 "$H1" "$U1")"; queued "$H1"; printf '* * 1\n' > "$T/wake"
echo 75 > "$T/gh/repos_o_r_commits_${H1}_status.rc"
run pr
[ "$(pf 5 6)" = '?' ] && ok || bad "W2f a 403 status read gave field 6 '$(pf 5 6)', wanted ?"
[ -e "$CI" ] && bad "W2f a failed read was cached: $(cat "$CI")" || ok
rm -f "$T/gh/repos_o_r_commits_${H1}_status.rc"
run pr STUCK_WORK_NOW=$((NOW+60)); reread W2f
reset
prs "$(pr 5 "$H1")"; queued "$H1"; printf '* * 1\n' > "$T/wake"
run pr
[ -e "$CI" ] && bad "W2g a row with no updated_at was cached: $(cat "$CI")" || ok
run pr STUCK_WORK_NOW=$((NOW+60)); reread W2g

# ── W5 ─────────────────────────────────────────────────────────────────────
reset
prs "$(pr 5 "$H1" "$U1")" "$(pr 6 "$H6" "$U1")"; printf '* * 1\n' > "$T/wake"
run pr
[ "$(calls "commits/$H6/")" = 2 ] && ok || bad "W5 pass 1 wanted #6's two CI reads, got $(calls "commits/$H6/")"
prs "$(pr 5 "$H1" "$U1")"
run pr STUCK_WORK_NOW=$((NOW+60))
[ "$(calls "commits/$H6/")" = 0 ] && ok || bad "W5 #6 left the list and was still CI-read: $(grep "$H6" "$T/gh.calls")"
grep -q $'\to/r#6\t' "$T/out.pr" && bad "W5 a facts line for o/r#6 was printed" || ok

# ── W3 ─────────────────────────────────────────────────────────────────────
thread_prime
[ "$(calls "$FULLRX")" = 1 ] && [ "$(calls "$SINCERX")" = 0 ] && ok || bad "W3 pass 1 was not one full read: $(cat "$T/gh.calls")"
[ "$(jq 'length' "$TH.json" 2>/dev/null)" = 2 ] && ok || bad "W3 pass 1 cached '$(cat "$TH.json" 2>/dev/null)', wanted 2 comments"
[ "$(cat "$TH.meta" 2>/dev/null)" = "$(printf '%s\t%s\t%s' "$TS2" "$NOW" "$NOW")" ] && ok || bad "W3 the meta is '$(cat "$TH.meta" 2>/dev/null)'"
grep -qx 'THREAD-FULL 7' "$T/count" && ok || bad "W3 pass 1 count '$(cat "$T/count")'"
[ "$(tf 7 20)" = 0 ] && ok || bad "W3 pass 1 issue_hold '$(tf 7 20)', wanted 0"
printf '%s\n' "$(comment 2 'Building.' "$TS2" "$TS2")" "$(comment 3 'HOLD — vendor' "$TS3" "$TS3")" | jq -s . > "$T/gh/comments.7.since.1"
printf 'issue 7 0\n* * 1\n' > "$T/wake"
run ticket STUCK_WORK_NOW=$((NOW+60))
grep -q "issues/7/comments?since=$TS2&per_page=100&page=1" "$T/gh.calls" && ok || bad "W3 pass 2 did not read since=$TS2: $(cat "$T/gh.calls")"
[ "$(calls "$FULLRX")" = 0 ] && ok || bad "W3 pass 2 read the whole thread again"
[ "$(tf 7 20)" = 1 ] && ok || bad "W3 the HOLD served on since= gave issue_hold '$(tf 7 20)', wanted 1"
[ "$(jq -c '[.[].id]' "$TH.json")" = '[1,2,3]' ] && ok || bad "W3 the cache holds ids $(jq -c '[.[].id]' "$TH.json")"
grep -qx 'THREAD-SINCE 7' "$T/count" && ok || bad "W3 pass 2 count '$(cat "$T/count")'"
[ "$(cat "$TH.meta")" = "$(printf '%s\t%s\t%s' "$TS3" "$NOW" $((NOW+60)))" ] && ok || bad "W3 pass 2 meta '$(cat "$TH.meta")'"
# W3b — no wake for the issue: nothing read, the cached answer stands.
printf 'issue 7 1\n* * 1\n' > "$T/wake"
run ticket STUCK_WORK_NOW=$((NOW+120))
[ "$(calls 'issues/7/comments')" = 0 ] && ok || bad "W3b a quiet issue was still read: $(cat "$T/gh.calls")"
[ "$(tf 7 20)" = 1 ] && ok || bad "W3b the cached HOLD gave issue_hold '$(tf 7 20)', wanted 1"
grep -qx 'THREAD-SKIP 7' "$T/count" && ok || bad "W3b count '$(cat "$T/count")'"
grep -q "^WAKE o/r issue 7 $((NOW+60))\$" "$T/wake.calls" && ok || bad "W3b the wake was not asked since the last read: $(cat "$T/wake.calls")"
# W3c — comments with no id are never cached, so every pass reads in full.
reset
list "$(issue 7 body)"
jq -cn '[{body:"hi", created_at:"2026-09-02T00:00:00Z", user:{login:"operator",type:"User"}}]' > "$T/gh/comments.7.full.1"
printf '* * 1\n' > "$T/wake"
run ticket
[ -e "$TH.json" ] || [ -e "$TH.meta" ] && bad "W3c an id-less thread was cached" || ok
run ticket STUCK_WORK_NOW=$((NOW+60))
[ "$(calls "$FULLRX")" = 1 ] && ok || bad "W3c pass 2 was not a full read: $(cat "$T/gh.calls")"

# ── W4 ─────────────────────────────────────────────────────────────────────
thread_prime
printf '%s\n' "$(comment 3 'HOLD — vendor' "$TS3" "$TS3")" | jq -s . > "$T/gh/comments.7.since.1"
printf 'issue 7 0\n* * 1\n' > "$T/wake"
run ticket STUCK_WORK_NOW=$((NOW+60))
printf '%s\n' "$(comment 3 'RESUME' "$TS3" "$TS4")" | jq -s . > "$T/gh/comments.7.since.1"
run ticket STUCK_WORK_NOW=$((NOW+120))
grep -q "since=$TS3&" "$T/gh.calls" && ok || bad "W4a did not read since=$TS3: $(cat "$T/gh.calls")"
[ "$(jq '[.[] | select(.id == 3)] | length' "$TH.json")" = 1 ] && ok || bad "W4a the cache holds $(jq '[.[] | select(.id == 3)] | length' "$TH.json") copies of id 3"
[ "$(jq -r '.[] | select(.id == 3) | .body' "$TH.json")" = RESUME ] && ok || bad "W4a id 3's body is '$(jq -r '.[] | select(.id == 3) | .body' "$TH.json")'"
[ "$(tf 7 20)" = 0 ] && ok || bad "W4a the edited comment gave issue_hold '$(tf 7 20)', wanted 0"
# W4b — the full read is older than STUCK_WORK_THREAD_FULL_S: read it all again.
thread_prime STUCK_WORK_THREAD_FULL_S=600
printf 'issue 7 0\n* * 1\n' > "$T/wake"; echo '[]' > "$T/gh/comments.7.since.1"
run ticket STUCK_WORK_THREAD_FULL_S=600 STUCK_WORK_NOW=$((NOW+599))
[ "$(calls "$SINCERX")" = 1 ] && [ "$(calls "$FULLRX")" = 0 ] && ok || bad "W4b at +599 wanted a since= read only: $(cat "$T/gh.calls")"
run ticket STUCK_WORK_THREAD_FULL_S=600 STUCK_WORK_NOW=$((NOW+601))
[ "$(calls "$FULLRX")" = 1 ] && [ "$(calls "$SINCERX")" = 0 ] && ok || bad "W4b at +601 wanted a full read only: $(cat "$T/gh.calls")"
[ "$(cut -f2 "$TH.meta")" = $((NOW+601)) ] && ok || bad "W4b the full epoch did not advance: $(cat "$TH.meta")"
# W4c — STUCK_WORK_THREAD_FULL_S=0 always reads in full.
thread_prime STUCK_WORK_THREAD_FULL_S=0
printf 'issue 7 0\n* * 1\n' > "$T/wake"
run ticket STUCK_WORK_THREAD_FULL_S=0 STUCK_WORK_NOW=$((NOW+1))
[ "$(calls "$FULLRX")" = 1 ] && [ "$(calls "$SINCERX")" = 0 ] && ok || bad "W4c FULL_S 0 was not a full read: $(cat "$T/gh.calls")"
# W4d — a since= read that fails is ?, never the cached answer.
thread_prime
printf '%s\n' "$(comment 3 'HOLD — vendor' "$TS3" "$TS3")" | jq -s . > "$T/gh/comments.7.since.1"
printf 'issue 7 0\n* * 1\n' > "$T/wake"
run ticket STUCK_WORK_NOW=$((NOW+60))
[ "$(tf 7 20)" = 1 ] && ok || bad "W4d setup: issue_hold '$(tf 7 20)'"
echo 75 > "$T/gh/comments.7.since.1.rc"
run ticket STUCK_WORK_NOW=$((NOW+120))
[ "$(tf 7 20)" = '?' ] && ok || bad "W4d a failed since= read gave issue_hold '$(tf 7 20)', wanted ?"
[ "$(calls "$FULLRX")" = 0 ] && ok || bad "W4d a failed since= read fell back to a full read"

# ── W6 ─────────────────────────────────────────────────────────────────────
reset
list "$(issue 7 body)" "$(issue 8 $'Scope.\n\nBlocked-by: #7')"
run ticket
[ "$(grep -cx 'GET repos/o/r/issues/7' "$T/gh.calls")" = 0 ] && ok || bad "W6a a listed blocker was read: $(cat "$T/gh.calls")"
[ "$(tf 8 19)" = 1 ] && ok || bad "W6a a listed blocker gave issue_blocked '$(tf 8 19)', wanted 1"
reset
list "$(issue 8 'Blocked-by: #99')"
echo '{"number":99,"state":"closed"}' > "$T/gh/repos_o_r_issues_99"
run ticket
[ "$(grep -cx 'GET repos/o/r/issues/99' "$T/gh.calls")" = 1 ] && ok || bad "W6b an unlisted blocker read $(grep -cx 'GET repos/o/r/issues/99' "$T/gh.calls") times, wanted 1"
[ "$(tf 8 19)" = 0 ] && ok || bad "W6b a closed unlisted blocker gave issue_blocked '$(tf 8 19)', wanted 0"

# ── W7 ─────────────────────────────────────────────────────────────────────
# W7a — no wake table: the lane's own order (PR facts then ticket facts, one
# shell) loads the contract lazily, and its rc 2 never skips a comment read.
reset
prs "$(pr 5 "$H1" "$U1")"
list "$(issue 7 body)"
printf '%s\n' "$(comment 1 'Looks good.' "$TS1" "$TS1")" "$(comment 2 'Building.' "$TS2" "$TS2")" | jq -s . > "$T/gh/comments.7.full.1"
echo '[]' > "$T/gh/comments.7.since.1"
run both
[ "$(cat "$T/loaded")" = function ] && ok || bad "W7a swf_pr_facts did not load bin/lib/pr-snapshot.sh ($(cat "$T/err"))"
run both STUCK_WORK_NOW=$((NOW+60))
grep -qx 'THREAD-SINCE 7' "$T/count" && ok || bad "W7a an unknown feed gave count '$(cat "$T/count")', wanted THREAD-SINCE 7"
[ "$(calls "$SINCERX")" = 1 ] && [ "$(calls "$FULLRX")" = 0 ] && ok || bad "W7a wanted one since= read: $(cat "$T/gh.calls")"
grep -qx 'CI-HIT 5' "$T/count" && ok || bad "W7a an unknown feed did not leave CI to the TTL: '$(cat "$T/count")'"
# W7b — a settings row of 0 beats env 900.
prime STUCK_WORK_CI_TTL_S=900
rm -rf "$T/h/state/settings-cache.json" "$T/h/state/lane-gate"
echo '{"settings":[{"key":"lane.stuck-work.stuck_work_ci_ttl_s","value":"0","actor":"operator"}]}' > "$T/settings"
run pr STUCK_WORK_CI_TTL_S=900 APPLY=1 STUCK_WORK_NOW=$((NOW+60)); reread W7b
grep -qx 'CI-MISS 5' "$T/count" && ok || bad "W7b count '$(cat "$T/count")' ($(cat "$T/err"))"

# ── W8 ─────────────────────────────────────────────────────────────────────
reset
prs "$(pr 5 "$H1" "$U1")"; list "$(issue 7 body)"
before=$(find /root/harness/state/stuck-work 2>/dev/null | sort | md5sum)
env -i PATH="$T/shim:$PATH" HOME="$T" T="$T" DIR="$DIR" JOBS_BOX=test HARNESS_TEST_SANDBOX=1 STUCK_WORK_NOW="$NOW" \
  MC_RESOLVER_CLAIM_DIR="$T/claims" SWF_COUNT_FILE="$T/count" bash -c '
  . "$T/prelude.sh"; swf_pr_facts o/r > "$T/out.pr"; swf_ticket_facts o/r "$T/items" > "$T/out.ticket"' 2> "$T/err"
after=$(find /root/harness/state/stuck-work 2>/dev/null | sort | md5sum)
[ "$before" = "$after" ] && ok || bad "W8 a sandboxed pass with HARNESS unset changed /root/harness/state/stuck-work"
[ -e "$T/h/state/stuck-work" ] && bad "W8 wrote a cache with HARNESS unset" || ok
[ "$(wc -l < "$T/out.pr")" = 1 ] && [ "$(wc -l < "$T/out.ticket")" = 1 ] && ok || bad "W8 the pass did not run: $(cat "$T/err")"

# No GraphQL and no bare gh anywhere.
[ -s "$T/gh-shim.calls" ] && bad "the gh CLI was run directly: $(cat "$T/gh-shim.calls")" || ok

echo "stuck-work-reads: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
