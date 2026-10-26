#!/bin/bash
# tests/mc-pulls-quota.bh-8457-test.sh — BH-8457: the merge conductor's
# `GET repos/{o}/{r}/pulls/{n}` reads come from the PR record, the open list
# and two memos, not from one GitHub GET per open PR per tick.
#
# Stubs only: gh (GitHub; every call logged with the path it asked and the
# HPL_READ_ROLE it ran under) and curl (the jobs worker: GET and PUT
# /api/pr-records; every other jobs path answers 404). The record answer for
# <repo>#<n> is $W/rec-<owner>_<repo>-<n>.json ({row, age_s}).
#
#   R1  a WHOLE bin/merge-conductor.sh keyed tick (MC_ONLY_PR=…#7) over 50
#       open PRs, 40 of them blocked, no records: no list read for any PR but
#       #7, and at most 1 `pulls/<n>` read in all
#   R2  a WHOLE full tick over 50 open PRs (40 blocked, 5 unstable, 3 clean,
#       2 draft), each with a 10 s old record at the list head: at most 5
#       `pulls/<n>` reads, and the log line `PR-RECORD served=48 miss=0`
#   S1-S13  prr_serve_state's decision rule (bin/lib/pr-record-serve.sh)
#   W1  harness_pr_list with HPL_PR_RECORD=1: a miss reads live and puts the
#       body into the record; the next list serves it with 0 gh calls (with
#       the snapshot off, then on with a blocked body)
#   W2  the put fails (500): the row is the live body, one pr-record.log line
#   K1-K6  HPL_LAZY_ONLY in bin/lib/gh-pr-list.sh
#   P1-P5  the bg_reviewer_can_write per-tick memo (bin/lib/block-gate.sh)
#   V1-V7  the repo visibility probe memo (bin/lib/gh-repo-token.sh)
#   Q1-Q4  the QUEUED pass of a whole tick takes state, branch and head from
#       the open list (one live read, not two), and reads live otherwise
#   B1  no curl to api.github.com in the whole suite; every gh call hit the stub
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-pulls-quota.bh-8457-test.sh
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
cnt() { local c=0; [ -f "$1" ] && c=$(grep -cE "$2" "$1"); echo "${c:-0}"; }

# ---- the stubs, shared by every section ------------------------------------
# gh: $GHT/prs.json is the open list; $GHT/pr/<n>.json is pulls/<n> (absent =
# 404). Logs "<path> role=<HPL_READ_ROLE>" to $GHT/paths and argv to $GHT/argv.
mkdir -p "$T/stubs"
cat > "$T/stubs/gh" <<'EOF'
#!/bin/bash
p=""; prev=""
for a in "$@"; do [ "$prev" = GET ] && p="$a"; prev="$a"; done
printf '%s\n' "$*" >> "$GHT/argv"
[ -n "$p" ] && printf '%s role=%s\n' "$p" "${HPL_READ_ROLE:--}" >> "$GHT/paths"
pg=1; [[ " $* " =~ [\&\ ]page=([0-9]+) ]] && pg="${BASH_REMATCH[1]}"
case "$*" in
  *"auth token"*) echo tok-fixture-1; exit 0 ;;
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
  repos/*/git/ref/heads/main)
    printf 'HTTP/2 200\r\n\r\n'; jq -nc --arg s "$(printf 'f%.0s' {1..40})" '{ref:"refs/heads/main", object:{sha:$s}}' ;;
  *) printf 'HTTP/2 404\r\n\r\n{"message":"Not Found"}\n' ;;
esac
exit 0
EOF
# curl: the jobs worker. Logs "<method> <url>" to $W/curl.log, and any URL on
# api.github.com to $W/github-curl.log (B1). $W/rec-down: GET answers 500;
# $W/put-down: PUT answers 500.
cat > "$T/stubs/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET; D=""
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; --data-binary|-d|--data) D="$2"; shift 2 ;; *) shift ;; esac; done
printf '%s %s\n' "$M" "$URL" >> "$W/curl.log"
case "$URL" in *api.github.com*) printf '%s\n' "$URL" >> "$W/github-curl.log" ;; esac
case "$M $URL" in
  "GET "*"/api/pr-records?"*)
    [ -f "$W/rec-down" ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
    n=${URL##*number=}; n=${n%%&*}; r=${URL#*repo=}; r=${r%%&*}
    f="$W/rec-${r//\//_}-$n.json"
    if [ -f "$f" ]; then printf '%s\n200\n' "$(cat "$f")"; else printf '{"row":null,"age_s":null}\n200\n'; fi ;;
  "PUT "*"/api/pr-records")
    printf '%s\n' "$D" >> "$W/puts"
    [ -f "$W/put-down" ] && { printf '{"error":"boom"}\n500\n'; exit 0; }
    r=$(jq -r .repo <<<"$D"); n=$(jq -r .number <<<"$D"); f="$W/rec-${r//\//_}-$n.json"
    old=$(jq -c '.row // {}' "$f" 2>/dev/null); [ -n "$old" ] || old='{}'
    row=$(jq -c --argjson o "$old" '$o + .fields + {repo, number}' <<<"$D")
    printf '{"row":%s,"age_s":0}\n' "$row" > "$f"
    printf '{"row":%s,"applied":%s,"stale":[]}\n200\n' "$row" "$(jq -c '.fields | keys' <<<"$D")" ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/stubs/gh" "$T/stubs/curl"

# rec <W> <n> <age> <head|null> <mergeable_state|null> [state] [repo]
rec() {
  local w=$1 n=$2 r="${7:-example-org/demo-os}"
  jq -nc --arg r "$r" --argjson n "$n" --argjson a "$3" --arg h "$4" --arg m "$5" --arg s "${6:-open}" \
    '{row:{repo:$r, number:$n, state:$s, head_sha:(if $h == "null" then null else $h end),
      mergeable_state:(if $m == "null" then null else $m end), refreshed_at:"2026-10-26T10:00:00Z"}, age_s:$a}' \
    > "$w/rec-${r//\//_}-$n.json"
}
# pr <G> <n> <mergeable_state> [draft] — one open PR in the list and its pulls/<n> body.
pr() {
  local g=$1 n=$2 h; h=$(hd "$2")
  jq -c --argjson n "$n" --arg h "$h" --arg u "$UPD" --argjson dr "${4:-false}" '. + [{number:$n,
    html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)), title:"t", draft:$dr, state:"open",
    updated_at:$u, created_at:"2026-10-01T00:00:00Z", labels:[], user:{login:"operator",type:"User"},
    head:{sha:$h, ref:("ticket/bh-"+($n|tostring)), repo:{full_name:"example-org/demo-os"}},
    base:{ref:"main", repo:{full_name:"example-org/demo-os"}}}]' "$g/prs.json" > "$g/prs.tmp" && mv "$g/prs.tmp" "$g/prs.json"
  jq -nc --argjson n "$n" --arg h "$h" --arg u "$UPD" --arg st "$3" --argjson dr "${4:-false}" '{number:$n, state:"open",
    merged_at:null, draft:$dr, html_url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)), user:{login:"operator"},
    labels:[], head:{sha:$h, ref:("ticket/bh-"+($n|tostring)), repo:{full_name:"example-org/demo-os"}},
    base:{ref:"main", sha:"'"$(printf 'f%.0s' {1..40})"'", repo:{full_name:"example-org/demo-os"}},
    mergeable:($st != "dirty"), mergeable_state:$st, updated_at:$u}' > "$g/pr/$n.json"
}

# ============================================================================
# S / W / K: the libs, sourced in a fresh process per call
# ============================================================================
UH="$T/u/h"; UG="$T/u"; mkdir -p "$UH/bin/lib" "$UH/state" "$UH/logs" "$UG/fakebin" "$UG/pr" "$UG/w" "$UG/tmp"
for s in bin/lib/gh-pr-list.sh bin/lib/pr-snapshot.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$UH" >/dev/null || { echo "FAIL: closure install failed for $s"; exit 1; }
done
if [ -f "$DIR/bin/lib/pr-record-serve.sh" ]; then
  scratch_install_closure bin/lib/pr-record-serve.sh "$UH" >/dev/null || { echo "FAIL: closure install failed for bin/lib/pr-record-serve.sh"; exit 1; }
fi
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: bin/lanes-build.sh could not compose the registry"; exit 1; }
cp "$T/stubs/gh" "$T/stubs/curl" "$UG/fakebin/"
CONDUCTOR_FIELDS=number,url,headRefOid,headRefName,baseRefName,isDraft,mergeStateStatus,mergeable,state,labels,updatedAt,isCrossRepository
# drv <snippet> — one process: gh-pr-list.sh, the snapshot when DRV_SNAP=1,
# and pr-record-serve.sh when it exists. DRC is the snippet's rc.
cat > "$UG/drv.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
. "$HARNESS/bin/lib/gh-pr-list.sh" || exit 99
if [ "${DRV_SNAP:-0}" = 1 ]; then . "$HARNESS/bin/lib/pr-snapshot.sh" || exit 98; export HPL_SNAPSHOT=1; fi
if [ -r "$HARNESS/bin/lib/pr-record-serve.sh" ]; then . "$HARNESS/bin/lib/pr-record-serve.sh" || exit 97; fi
eval "$1"
EOF
drv() { ( export PATH="$UG/fakebin:$PATH" HARNESS="$UH" GHT="$UG" W="$UG/w" TMPDIR="$UG/tmp" LANE_GATE_DISABLE=1 GH_ETAG=0 \
    LANE_REGISTRY="$T/lanes.json" HARNESS_PR_AUTHORS=operator HARNESS_SECRET=fixture-secret JOBS_URL=https://jobs.test JOBS_RETRIES=0
    bash "$UG/drv.sh" "$1" ) 2>>"$UG/drv.err"; DRC=$?; }
ureset() {
  scratch_rm "$UG/pr"; scratch_rm "$UG/w"; scratch_rm "$UH/state/pr-snapshot"; mkdir -p "$UG/pr" "$UG/w"
  rm -f "$UG/paths" "$UG/argv" "$UH/logs/pr-record.log"; echo '[]' > "$UG/prs.json"
}
ureads() { cnt "$UG/paths" "^repos/$SLUG/pulls/${1:-[0-9]+} "; }
jget() { cnt "$UG/w/curl.log" '^GET .*/api/pr-records\?'; }

# serve <case> <n> <list-head> [ENV=value ...] — prr_serve_state on demo-os#<n>.
serve() {
  local c=$1 n=$2 h=$3; shift 3
  rm -f "$UG/out.json" "$UG/count"
  drv "$(printf '%q ' export DRV_CASE="$c" "$@" PRS_COUNT_FILE="$UG/count"); prr_serve_state $SLUG $n $h \"$UG/out.json\""
}
H5=$(hd 5)
ureset; rec "$UG/w" 5 10 "$H5" blocked
serve S1 5 "$H5"
eq "S1 age 10, head equal, blocked: served (rc)" "$DRC" 0
eq "S1 the served body's mergeable_state" "$(jq -r .mergeable_state "$UG/out.json" 2>/dev/null)" blocked
eq "S1 the served body's head" "$(jq -r .head.sha "$UG/out.json" 2>/dev/null)" "$H5"
eq "S1 the served body's mergeable" "$(jq -r .mergeable "$UG/out.json" 2>/dev/null)" true
eq "S1 no gh call" "$(cnt "$UG/argv" .)" 0
eq "S1 one jobs GET" "$(jget)" 1
eq "S1 the counter says served" "$(cat "$UG/count" 2>/dev/null)" "RSERVED 5"
ureset; rec "$UG/w" 5 120 "$H5" clean
serve S2 5 "$H5"; eq "S2 age 120 (the default boundary), clean: served" "$DRC" 0
ureset; rec "$UG/w" 5 10 "$(tr 'a-f' 'A-F' <<<"$H5")" blocked
serve S3 5 "$H5"; eq "S3 the record head in upper case: served" "$DRC" 0
eq "S3 the served head is lower case" "$(jq -r .head.sha "$UG/out.json" 2>/dev/null)" "$H5"
ureset; rec "$UG/w" 5 121 "$H5" clean
serve S4 5 "$H5"; eq "S4 age 121: a miss" "$DRC" 1
eq "S4 the counter says miss" "$(cat "$UG/count" 2>/dev/null)" "RMISS 5"
[ ! -s "$UG/out.json" ] && ok "S4 a miss writes no body" || bad "S4 a miss wrote: $(cat "$UG/out.json")"
ureset; rec "$UG/w" 5 10 "$H5" clean
serve S5 5 "$H5" PR_RECORD_SERVE_MAX_AGE_S=0; eq "S5 knob 0: a miss" "$DRC" 1
eq "S5 knob 0 asks the jobs worker nothing" "$(jget)" 0
ureset; rec "$UG/w" 5 100 "$H5" clean
serve S6 5 "$H5" PR_RECORD_SERVE_MAX_AGE_S=soon; eq "S6 a knob that is not an integer is 120: age 100 served" "$DRC" 0
grep -q "PR_RECORD_SERVE_MAX_AGE_S='soon' is not a non-negative integer" "$UH/logs/pr-record.log" 2>/dev/null \
  && ok "S6 one pr-record.log line names the bad knob" || bad "S6 no knob line: $(cat "$UH/logs/pr-record.log" 2>/dev/null)"
ureset; rec "$UG/w" 5 121 "$H5" clean
serve S6b 5 "$H5" PR_RECORD_SERVE_MAX_AGE_S=soon; eq "S6b a non-integer knob is 120: age 121 a miss" "$DRC" 1
ureset; rec "$UG/w" 5 10 "$(hd 6)" clean
serve S7 5 "$H5"; eq "S7 the record head differs from the list head: a miss" "$DRC" 1
ureset; rec "$UG/w" 5 10 null clean
serve S8 5 "$H5"; eq "S8 head_sha null: a miss" "$DRC" 1
ureset; rec "$UG/w" 5 10 "$H5" clean closed
serve S9 5 "$H5"; eq "S9 state closed: a miss" "$DRC" 1
ureset; rec "$UG/w" 5 10 "$H5" clean merged
serve S9b 5 "$H5"; eq "S9b state merged: a miss" "$DRC" 1
ureset; rec "$UG/w" 5 10 "$H5" null
serve S10 5 "$H5"; eq "S10 mergeable_state null (a base push nulled it): a miss" "$DRC" 1
ureset
serve S11 5 "$H5"; eq "S11 no row: a miss" "$DRC" 1
ureset; rec "$UG/w" 5 10 "$H5" clean; : > "$UG/w/rec-down"
serve S11b 5 "$H5"; eq "S11b the jobs read fails (500): a miss" "$DRC" 1
eq "S11b no gh call" "$(cnt "$UG/argv" .)" 0
ureset; rec "$UG/w" 5 10 "$H5" clean open example-org/other-os
serve S12 5 "$H5"; eq "S12 a row for another repo with the same number: a miss" "$DRC" 1
ureset; rec "$UG/w" 5 10 "$H5" dirty
serve S13 5 "$H5"; eq "S13 dirty: served" "$DRC" 0
eq "S13 dirty reads mergeable false" "$(jq -r .mergeable "$UG/out.json" 2>/dev/null)" false

# ── W1: a miss reads live and fills the record; the next list serves it ──
# lst <out> [ENV=value ...] — harness_pr_list with the conductor's fields.
lst() { local o=$1; shift; drv "$(printf '%q ' export DRV_LIST=1 "$@"); harness_pr_list $SLUG open $CONDUCTOR_FIELDS 100 > \"$o\""; }
ureset; pr "$UG" 3 blocked
lst "$UG/w1a.json" HPL_PR_RECORD=1
eq "W1 list 1 rc" "$DRC" 0
eq "W1 list 1 reads pulls/3 live once" "$(ureads 3)" 1
eq "W1 list 1 row" "$(jq -r '.[0].mergeStateStatus' "$UG/w1a.json" 2>/dev/null)" BLOCKED
PUT=$(tail -1 "$UG/w/puts" 2>/dev/null)
eq "W1 the live body was put into the record (source github)" "$(jq -r .source <<<"${PUT:-{\}}" 2>/dev/null)" github
eq "W1 the put carries head_sha" "$(jq -r .fields.head_sha <<<"${PUT:-{\}}" 2>/dev/null)" "$(hd 3)"
eq "W1 the put carries mergeable_state" "$(jq -r .fields.mergeable_state <<<"${PUT:-{\}}" 2>/dev/null)" blocked
eq "W1 the put carries state" "$(jq -r .fields.state <<<"${PUT:-{\}}" 2>/dev/null)" open
rm -f "$UG/paths" "$UG/argv"
lst "$UG/w1b.json" HPL_PR_RECORD=1
eq "W1 list 2 rc" "$DRC" 0
eq "W1 list 2 serves #3 from the record: 0 pulls/3 reads" "$(ureads 3)" 0
eq "W1 list 2 row" "$(jq -r '.[0].mergeStateStatus' "$UG/w1b.json" 2>/dev/null)" BLOCKED
# The same with the snapshot on: a blocked body is never served from disk
# (BH-4659 review F1), and with the record it is not read live either.
ureset; pr "$UG" 3 blocked
DRV_SNAP=1 lst "$UG/w1c.json" HPL_PR_RECORD=1 PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=600
eq "W1 snapshot list 1 reads pulls/3 live once" "$(ureads 3)" 1
rm -f "$UG/paths"
DRV_SNAP=1 lst "$UG/w1d.json" HPL_PR_RECORD=1 PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=600
eq "W1 snapshot list 2: 0 pulls/3 reads" "$(ureads 3)" 0
eq "W1 snapshot list 2 row" "$(jq -r '.[0].mergeStateStatus' "$UG/w1d.json" 2>/dev/null)" BLOCKED
# Without HPL_PR_RECORD nothing changes: no jobs call, a live read each list.
ureset; pr "$UG" 3 blocked
lst "$UG/w1e.json"; lst "$UG/w1e.json"
eq "W1 HPL_PR_RECORD unset: 2 lists read pulls/3 twice" "$(ureads 3)" 2
eq "W1 HPL_PR_RECORD unset: no jobs call" "$(cnt "$UG/w/curl.log" .)" 0

# ── W2: the put fails ──
ureset; pr "$UG" 3 clean; : > "$UG/w/put-down"
lst "$UG/w2.json" HPL_PR_RECORD=1
eq "W2 rc" "$DRC" 0
eq "W2 the row is the live body" "$(jq -r '.[0].mergeStateStatus' "$UG/w2.json" 2>/dev/null)" CLEAN
eq "W2 one pr-record.log line for the failed put" "$(cnt "$UH/logs/pr-record.log" 'serve-note example-org/demo-os#3 put=failed')" 1

# ── K1-K6: HPL_LAZY_ONLY ──
ureset; for n in 1 12 123; do pr "$UG" "$n" clean; done
lst "$UG/k1.json" HPL_LAZY_ONLY=12
eq "K1 rc" "$DRC" 0
eq "K1 only pulls/12 is read" "$(ureads)" 1
eq "K1 pulls/12 read" "$(ureads 12)" 1
eq "K1 #12 reads CLEAN" "$(jq -r '.[] | select(.number == 12) | .mergeStateStatus' "$UG/k1.json" 2>/dev/null)" CLEAN
eq "K1 #1 and #123 (no partial match) read UNKNOWN" "$(jq -r '[.[] | select(.number != 12) | .mergeStateStatus] | join(",")' "$UG/k1.json" 2>/dev/null)" UNKNOWN,UNKNOWN
eq "K1 every row is still in the list" "$(jq -c '[.[].number]' "$UG/k1.json" 2>/dev/null)" "[1,12,123]"
rm -f "$UG/paths"
lst "$UG/k2.json"
eq "K2 HPL_LAZY_ONLY unset: all 3 rows read" "$(ureads)" 3
rm -f "$UG/paths"
lst "$UG/k3.json" HPL_LAZY_ONLY=
eq "K3 set but empty: rc" "$DRC" 0
eq "K3 set but empty: no read" "$(ureads)" 0
ureset; pr "$UG" 1 clean; pr "$UG" 12 clean true
lst "$UG/k4.json" HPL_LAZY_ONLY=12
eq "K4 a draft in the set is not read" "$(ureads)" 0
eq "K4 the draft reads DRAFT" "$(jq -r '.[] | select(.number == 12) | .mergeStateStatus' "$UG/k4.json" 2>/dev/null)" DRAFT
ureset; for n in 1 12 123; do pr "$UG" "$n" clean; done; rm -f "$UG/pr/12.json"
lst "$UG/k5.json" HPL_LAZY_ONLY=12
[ "$DRC" != 0 ] && ok "K5 every in-scope row degraded: the list fails (rc $DRC)" || bad "K5 an all-degraded scope answered rc 0: $(cat "$UG/k5.json")"
rm -f "$UG/pr/1.json"; cp "$UG/pr/123.json" "$UG/pr/12.json"; jq '.head.sha = "'"$(hd 12)"'"' "$UG/pr/12.json" > "$UG/pr/12.tmp" && mv "$UG/pr/12.tmp" "$UG/pr/12.json"
lst "$UG/k6.json" "HPL_LAZY_ONLY=1 12"
eq "K6 one of two in-scope rows degraded: rc 0" "$DRC" 0
eq "K6 #1 reads UNVERIFIABLE" "$(jq -r '.[] | select(.number == 1) | .mergeStateStatus' "$UG/k6.json" 2>/dev/null)" UNVERIFIABLE
eq "K6 #123 (out of scope) reads UNKNOWN, not degraded" "$(jq -r '.[] | select(.number == 123) | .mergeStateStatus' "$UG/k6.json" 2>/dev/null)" UNKNOWN

# ============================================================================
# P: the collaborator-permission memo (bin/lib/block-gate.sh)
# ============================================================================
PT="$T/p"; mkdir -p "$PT/h/bin/lib" "$PT/fakebin" "$PT/memo"
scratch_install_closure bin/lib/block-gate.sh "$PT/h" >/dev/null || { echo "FAIL: closure install failed for bin/lib/block-gate.sh"; exit 1; }
cat > "$PT/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$PT/gh.log"
case "$*" in
  *"collaborators/"*"/permission"*)
    a="$*"; l="${a#*collaborators/}"; l="${l%%/*}"
    [ -f "$PT/fail" ] && exit 1
    case "$l" in reader) echo read ;; *) echo write ;; esac ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$PT/fakebin/gh"
# perm <memo-dir|-> <slug> <login> ... — one process, each pair asked once, rcs space-joined.
perm() {
  local m=$1; shift
  ( export PATH="$PT/fakebin:$PATH" HARNESS="$PT/h" PT="$PT"
    if [ "$m" = - ]; then unset BG_PERM_MEMO_DIR; else export BG_PERM_MEMO_DIR="$m"; fi
    . "$PT/h/bin/lib/block-gate.sh" >/dev/null 2>&1 || exit 99
    out=""
    while [ $# -gt 1 ]; do
      # In a subshell, as bg_cr_standing's caller runs it: a shell-variable memo would not survive it.
      r=$( bg_reviewer_can_write "$1" "$2"; echo $? ); out="$out $r"; shift 2
    done
    echo "${out# }" )
}
pcalls() { cnt "$PT/gh.log" 'collaborators/'; }
rm -f "$PT/gh.log"; scratch_rm "$PT/memo"; mkdir -p "$PT/memo"
eq "P1 two reads of one pair answer the same" "$(perm "$PT/memo" o/r alice o/r alice)" "0 0"
eq "P1 one permission call for the pair" "$(pcalls)" 1
rm -f "$PT/gh.log"
eq "P1b a read-only login is memoed too" "$(perm "$PT/memo" o/r reader o/r reader)" "1 1"
eq "P1b one call" "$(pcalls)" 1
rm -f "$PT/gh.log"
perm "$PT/memo" o/r bob >/dev/null
eq "P2 another login is read" "$(pcalls)" 1
rm -f "$PT/gh.log"
perm "$PT/memo" o/other alice >/dev/null
eq "P3 another slug is read" "$(pcalls)" 1
rm -f "$PT/gh.log"
eq "P4 BG_PERM_MEMO_DIR unset: rc" "$(perm - o/r alice o/r alice)" "0 0"
eq "P4 BG_PERM_MEMO_DIR unset: every call reads" "$(pcalls)" 2
rm -f "$PT/gh.log"; scratch_rm "$PT/memo"; mkdir -p "$PT/memo"; : > "$PT/fail"
eq "P5 a failed read stays fail-closed (rc 0)" "$(perm "$PT/memo" o/r alice)" 0
rm -f "$PT/fail"
eq "P5 a failed read is not stored: the next call reads, and answers it" "$(perm "$PT/memo" o/r reader)" 1
eq "P5 two calls in all" "$(pcalls)" 2
[ -z "$(ls -A "$PT/memo" 2>/dev/null | grep -i alice)" ] && ok "P5 no memo file for the failed pair" || bad "P5 a failed read was stored: $(ls "$PT/memo")"

# ============================================================================
# V: the repo visibility probe memo (bin/lib/gh-repo-token.sh)
# ============================================================================
VT="$T/v"; mkdir -p "$VT/bin/lib" "$VT/env" "$VT/flags" "$VT/logs" "$VT/fakebin" "$VT/memo"
scratch_install_closure bin/lib/gh-repo-token.sh "$VT" >/dev/null || { echo "FAIL: closure install failed for bin/lib/gh-repo-token.sh"; exit 1; }
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$MINT_LOG"\nprintf "apptok-fixture\\n"\n' > "$VT/bin/gh-token.sh"; chmod +x "$VT/bin/gh-token.sh"
cat > "$VT/fakebin/gh" <<'SH'
#!/bin/bash
printf 'GH_TOKEN=%s %s\n' "${GH_TOKEN:-unset}" "$*" >> "$GH_LOG"
case "$*" in
  "api repos/o/seen -q .id"|"api repos/o/seen2 -q .id") echo 1; exit 0 ;;
  "api repos/o/apponly -q .id") [ "${GH_TOKEN:-}" = apptok-fixture ] && { echo 1; exit 0; }; exit 1 ;;
  *) exit 1 ;;
esac
SH
chmod +x "$VT/fakebin/gh"
# vdrive <snippet> [VAR=value ...] — one process; the memo dir is $VT/memo unless the snippet unsets it.
vdrive() {
  local s=$1; shift
  ( export PATH="$VT/fakebin:$PATH" HARNESS="$VT" MINT_LOG="$VT/mint.log" GH_LOG="$VT/gh.log" _GHRT_PROBE_MEMO_DIR="$VT/memo"
    unset GH_TOKEN _GHRT_PROBE_MEMO_TTL_S
    [ $# -gt 0 ] && export "$@"
    . "$VT/bin/lib/gh-repo-token.sh"; eval "$s" )
}
vcalls() { cnt "$VT/gh.log" "api repos/$1 -q .id"; }
vreset() { rm -f "$VT/gh.log" "$VT/mint.log" "$VT/env/github-app.env"; scratch_rm "$VT/memo"; mkdir -p "$VT/memo"; }
vreset
eq "V1 process 1 answers default" "$(vdrive 'gh_repo_token_for o/seen')" default
eq "V1 process 1 probes once" "$(vcalls o/seen)" 1
eq "V1 process 2 answers default from the memo" "$(vdrive 'gh_repo_token_for o/seen')" default
eq "V1 process 2 sends no repos/<slug> probe" "$(vcalls o/seen)" 1
eq "V1 the memo holds a verdict word, never a token" "$(cut -f2 "$VT/memo/"* 2>/dev/null | sort -u | tr '\n' ' ')" "default "
rm -f "$VT/gh.log"
for f in "$VT/memo/"*; do printf '%s\tdefault\n' "$(( $(date +%s) - 301 ))" > "$f"; done
vdrive 'gh_repo_token_for o/seen' >/dev/null
eq "V2 a verdict older than the default TTL (300 s) is probed again" "$(vcalls o/seen)" 1
rm -f "$VT/gh.log"
vdrive 'gh_repo_token_for o/seen' _GHRT_PROBE_MEMO_TTL_S=0 >/dev/null; vdrive 'gh_repo_token_for o/seen' _GHRT_PROBE_MEMO_TTL_S=0 >/dev/null
eq "V3 TTL 0 probes every process" "$(vcalls o/seen)" 2
vreset
vdrive 'unset _GHRT_PROBE_MEMO_DIR; gh_repo_token_for o/seen' >/dev/null; vdrive 'unset _GHRT_PROBE_MEMO_DIR; gh_repo_token_for o/seen' >/dev/null
eq "V4 no memo dir: every process probes" "$(vcalls o/seen)" 2
eq "V4 no memo dir writes nothing" "$(ls -A "$VT/memo" | wc -l | tr -d ' ')" 0
vreset
vdrive 'gh_repo_token_for o/seen' >/dev/null; vdrive 'gh_repo_token_for o/seen2' >/dev/null
eq "V5 another slug probes for itself" "$(vcalls o/seen2)" 1
vreset
eq "V6 an invisible repo answers none" "$(vdrive 'gh_repo_token_for o/blind')" none
eq "V6 none is never stored" "$(ls -A "$VT/memo" | wc -l | tr -d ' ')" 0
B6=$(vcalls o/blind); vdrive 'gh_repo_token_for o/blind' >/dev/null
[ "$(vcalls o/blind)" -gt "$B6" ] && ok "V6 the next process probes the invisible repo again" || bad "V6 the invisible repo was not probed again"
vreset; : > "$VT/env/github-app.env"
eq "V7 armed: process 1 answers app" "$(vdrive 'gh_repo_use_token o/apponly; gh_repo_token_for o/apponly; printf "%s\n" "$GH_TOKEN"' | tr '\n' ' ')" "app apptok-fixture "
eq "V7 process 1 probes once" "$(vcalls o/apponly)" 1
eq "V7 process 2 answers app with the minted token" "$(vdrive 'gh_repo_use_token o/apponly; gh_repo_token_for o/apponly; printf "%s\n" "$GH_TOKEN"' | tr '\n' ' ')" "app apptok-fixture "
eq "V7 process 2 sends no repos/<slug> probe" "$(vcalls o/apponly)" 1
eq "V7 process 2 still mints" "$(cnt "$VT/mint.log" 'o/apponly')" 2
! grep -rq 'apptok' "$VT/memo" && ok "V7 no token value in the memo" || bad "V7 a token reached the memo"

# ============================================================================
# R1 / R2 / Q: WHOLE conductor ticks (the production entry point)
# ============================================================================
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
LT="$T/lt"; mkdir -p "$LT"
( export HARNESS="$LT/h"; fx_mc_harness "$DIR" "$LT" && fx_conductor_tick "$DIR" "$LT" ) || { echo "FAIL: conductor fixture"; exit 1; }
scratch_install_closure bin/merge-conductor.sh "$LT/h" >/dev/null || { echo "FAIL: closure install failed for bin/merge-conductor.sh"; exit 1; }
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
# The fragment that turns HPL_PR_RECORD on rides in bin/merge-conductor.d/ (BH-6738).
scratch_install_closure bin/merge-conductor.d/bh-8457-pr-record-serve.sh "$LT/h" >/dev/null || { echo "FAIL: closure install failed for the BH-8457 fragment"; exit 1; }
[ -f "$LT/h/bin/merge-conductor.d/bh-8457-pr-record-serve.sh" ] && ok "R0 the BH-8457 fragment is installed with the conductor" || bad "R0 bin/merge-conductor.d/bh-8457-pr-record-serve.sh missing from the tick tree"
mkdir -p "$LT/repos/demo-os/.git" "$LT/h/tmp" "$LT/w"
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$LT/h/fleet.conf"
: > "$LT/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$LT/h/bin/agent-call.sh"; chmod +x "$LT/h/bin/agent-call.sh"
cp "$T/stubs/gh" "$T/stubs/curl" "$LT/fakebin/"
MCLOG="$LT/h/logs/merge-conductor.log"
# lreset <list of "n:state[:draft]"> — a fresh tick world: the list, the
# bodies, no records, no conductor state, empty logs.
lreset() {
  scratch_rm "$LT/pr"; scratch_rm "$LT/w"; scratch_rm "$LT/h/state"; mkdir -p "$LT/pr" "$LT/w" "$LT/h/state"
  rm -f "$LT/paths" "$LT/argv" "$LT/writes" "$MCLOG"; echo '[]' > "$LT/prs.json"
  local s n st dr
  for s in "$@"; do IFS=: read -r n st dr <<<"$s"; pr "$LT" "$n" "$st" "${dr:-false}"; done
}
# ltick [VAR=value ...] — one whole tick.
ltick() { ( cd "$LT" && env PATH="$LT/fakebin:$PATH" HARNESS="$LT/h" GHT="$LT" W="$LT/w" HARNESS_SECRET=fixture-secret \
  JOBS_URL=https://jobs.test JOBS_RETRIES=0 TMPDIR="$LT/h/tmp" LANE_GATE_DISABLE=1 GH_ETAG=0 GH_APP_TOKENS=0 \
  MC_REPOS="$LT/repos" MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_DETACHED_REBASE=0 MC_PR_PARALLEL=8 MC_TICK_SECS=0 \
  MC_HEAD_LAG_MINS=0 PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=600 "$@" \
  bash "$LT/h/bin/merge-conductor.sh" >/dev/null 2>"$LT/tick.err" ); }
pulls_reads() { cnt "$LT/paths" "^repos/$SLUG/pulls/[0-9]+ "; }
PR50=(); for n in $(seq 1 50); do
  if [ "$n" -le 40 ]; then PR50+=("$n:blocked"); elif [ "$n" -le 45 ]; then PR50+=("$n:unstable")
  elif [ "$n" -le 48 ]; then PR50+=("$n:clean"); else PR50+=("$n:clean:true"); fi
done

# ── R1: a keyed tick reads only the woken PR ──
lreset "${PR50[@]}"
ltick MC_ONLY_PR="$SLUG#7"; R1RC=$?
eq "R1 keyed tick rc" "$R1RC" 0
OTHERS=$(grep -E "^repos/$SLUG/pulls/[0-9]+ " "$LT/paths" 2>/dev/null | grep -vcE "^repos/$SLUG/pulls/7 ")
eq "R1 pulls/<n> reads for PRs that were not woken" "$OTHERS" 0
[ "$(pulls_reads)" -le 1 ] && ok "R1 at most 1 pulls/<n> read ($(pulls_reads))" || bad "R1 $(pulls_reads) pulls/<n> reads, want <= 1"

# ── R2: a full tick over 50 PRs with fresh records ──
lreset "${PR50[@]}"
for s in "${PR50[@]}"; do IFS=: read -r n st _ <<<"$s"; rec "$LT/w" "$n" 10 "$(hd "$n")" "$st"; done
# A permission memo dir a killed tick left (2 days old) and one of a tick
# still running (fresh): the full tick's mc_tick_gc prunes only the old one.
mkdir -p "$LT/h/state/merge-conductor/tick/perm-old" "$LT/h/state/merge-conductor/tick/perm-fresh"
touch -d '2 days ago' "$LT/h/state/merge-conductor/tick/perm-old"
ltick; R2RC=$?
eq "R2 full tick rc" "$R2RC" 0
[ ! -e "$LT/h/state/merge-conductor/tick/perm-old" ] && ok "R2 mc_tick_gc pruned a permission memo dir older than a day" || bad "R2 the old perm-* dir survived the full tick"
[ -d "$LT/h/state/merge-conductor/tick/perm-fresh" ] && ok "R2 mc_tick_gc kept a fresh permission memo dir" || bad "R2 mc_tick_gc removed a fresh perm-* dir"
eq "R2 the tick removed its own permission memo dir" "$(find "$LT/h/state/merge-conductor/tick" -maxdepth 1 -type d -name 'perm-2*' | wc -l | tr -d ' ')" 0
[ "$(pulls_reads)" -le 5 ] && ok "R2 at most 5 pulls/<n> reads ($(pulls_reads))" || bad "R2 $(pulls_reads) pulls/<n> reads, want <= 5"
grep -qE "$SLUG PR-RECORD served=48 miss=0" "$MCLOG" 2>/dev/null && ok "R2 the log carries PR-RECORD served=48 miss=0" \
  || bad "R2 no 'PR-RECORD served=48 miss=0' line: $(grep -E 'PR-RECORD|PR-SNAPSHOT' "$MCLOG" 2>/dev/null | tail -2)"
[ ! -s "$LT/writes" ] && ok "R2 the observe tick wrote nothing to GitHub" || bad "R2 GitHub writes: $(head -3 "$LT/writes")"

# ── Q1-Q4: the QUEUED pass of a keyed tick (it reads every QUEUED row) ──
# The tick is keyed to #1, so the open pass never works #7, #8, #9 or #60:
# every pulls/<n> read of those is the QUEUED pass's own. GitHub's native
# queue (provider github, cached); mc_queue_state on an OPEN PR reads once.
lreset 1:clean 7:clean 8:clean 9:clean
jq '.state = "closed" | .merged_at = "2026-10-26T11:00:00Z" | .merged = true' "$LT/pr/9.json" > "$LT/pr/9.tmp" && mv "$LT/pr/9.tmp" "$LT/pr/9.json"
pr "$LT" 60 clean; jq '.state = "closed" | .merged_at = "2026-10-26T11:00:00Z" | .merged = true' "$LT/pr/60.json" > "$LT/pr/60.tmp" && mv "$LT/pr/60.tmp" "$LT/pr/60.json"
jq '[.[] | select(.number != 60)]' "$LT/prs.json" > "$LT/prs.tmp" && mv "$LT/prs.tmp" "$LT/prs.json"
mkdir -p "$LT/h/state/merge-conductor"; echo github > "$LT/h/tmp/merge-queue-example-org_demo-os.provider"
QNOW=$(date +%s); OLD8=$(printf 'c%.0s' {1..40})
for q in "7 $(hd 7)" "8 $OLD8" "9 $(hd 9)" "60 $(hd 60)"; do
  read -r n h <<<"$q"
  printf '%s#%s\tQUEUED\t%s\t%s\t%s\t-\tenqueued\thttps://github.com/%s/pull/%s\n' "$SLUG" "$n" "$QNOW" "$h" "$h" "$SLUG" "$n" >> "$LT/h/state/merge-conductor/pr-state.tsv"
done
ltick MC_ONLY_PR="$SLUG#1" MC_QUEUE_TTL=3600; QRC=$?
eq "Q tick rc" "$QRC" 0
grep -q "$SLUG#7 still QUEUED" "$MCLOG" 2>/dev/null && ok "Q setup: the QUEUED pass worked #7" || bad "Q setup: no QUEUED line for #7: $(grep -E '#7|QUEUED' "$MCLOG" 2>/dev/null | tail -3)"
eq "Q1 #7 open in the list at its QUEUED head: one live read (mc_queue_state's), not two" "$(cnt "$LT/paths" "^repos/$SLUG/pulls/7 ")" 1
eq "Q2 #60 not in the open list: read live" "$(cnt "$LT/paths" "^repos/$SLUG/pulls/60 role=-")" 1
grep -qE "$SLUG#60.*MERGED|MERGED.*$SLUG#60" "$MCLOG" 2>/dev/null && ok "Q2 #60 is settled MERGED" || bad "Q2 #60 not settled: $(grep '#60' "$MCLOG" 2>/dev/null | tail -2)"
eq "Q3 #8's list head differs from its QUEUED head: read live twice, as before" "$(cnt "$LT/paths" "^repos/$SLUG/pulls/8 ")" 2
eq "Q4 #9 is OPEN in the list but merged on GitHub: one live read" "$(cnt "$LT/paths" "^repos/$SLUG/pulls/9 ")" 1
grep -q "$SLUG#9 QUEUED -> MERGED" "$MCLOG" 2>/dev/null && ok "Q4 the live read settles #9 MERGED" || bad "Q4 #9 not settled: $(grep '#9' "$MCLOG" 2>/dev/null | tail -3)"

# ── B1: the whole suite ran on the stubs ──
for w in "$UG/w" "$LT/w"; do
  [ ! -s "$w/github-curl.log" ] && ok "B1 no curl to api.github.com ($w)" || bad "B1 curl reached api.github.com: $(head -2 "$w/github-curl.log")"
done
grep -q . "$LT/argv" 2>/dev/null && ok "B1 the tick's gh calls went to the stub" || bad "B1 the tick made no stub gh call"

echo "mc-pulls-quota.bh-8457: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
