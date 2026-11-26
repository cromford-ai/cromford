#!/bin/bash
# tests/mc-record-seam.bh-9938-test.sh — BH-9938 slice C1: the merge-conductor
# seam's open-list and flake reads (bin/lib/prr-shadow.d/merge-conductor.sh),
# one function at a time, with a stub jobs client.
#
#   O1  mc_open_record: the whole record list in the REST pulls shape, with
#       state open, user.type (Bot for <name>[bot]), the default branch and
#       the head and base repo full names from the cross-repo memo
#   O2  a PR the memo does not know is the miss field:cross; a PR the memo
#       knows as a fork gets head.repo.full_name "fork"
#   O3  no default-branch memo, or one that is not main: field:default_branch
#   O4  a stale list: stale
#   O5  mc_open_norm: equal for the record and the GitHub rows of the same
#       PRs; a changed head or label changes it
#   O6  mc_xe_record asks the record for the window of 100
#   F1  mc_flake_record: every check of the head completed, none cancelled:
#       a hit with an empty file ("no flake evidence")
#   F2  the misses: a cancelled or timed_out check (flake), an entry not
#       completed (pending), a row at another head (head), no entry for the
#       head (none), a row older than PR_RECORD_FIELD_MAX_AGE_S (default
#       3900: stale), as many
#       names as PRR_CI_CHECKS_MAX (checks-max)
#   F3  mc_flake_norm: the run ids, sorted
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-record-seam.bh-9938-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: got '$2', wanted '$3'"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/demo-os
H="$T/h"; mkdir -p "$H/logs" "$H/state/prr-default-branch" "$T/w"
MEMO="$H/state/prr-default-branch/example-org_demo-os"
hd() { printf '%040x' "$((0xabc000 + $1))"; }

# seam <fn> <args...>: one call in a fresh shell; stdout to $T/out, rc to $T/rc.
# The stub _jobs_req answers the list GET from $T/w/list.json and a row GET
# from $T/w/row.json, and logs each path to $T/w/jobs.log.
seam() {
  ( export HARNESS="$H" PR_RECORD_MAX_AGE_S=900 PR_RECORD_LIST_MAX_AGE_S=900
    . "$DIR/bin/lib/pr-record.sh" || exit 9
    _prr_client() { return 0; }
    _jobs_req() { printf '%s\n' "$2" >> "$T/w/jobs.log"
      case "$2" in *"&state=open"*) cat "$T/w/list.json" ;; *) cat "$T/w/row.json" ;; esac; }
    . "$DIR/bin/lib/prr-shadow.sh" || exit 9
    prr_seam_load merge-conductor || exit 8
    "$@" > "$T/out" 2>/dev/null; echo $? > "$T/rc" )
}
rc() { cat "$T/rc"; }
out() { cat "$T/out"; }
lrow() {   # lrow <n> [author]
  jq -nc --argjson n "$1" --arg h "$(hd "$1")" --arg a "${2:-operator}" \
    '{number:$n, title:"t", head_ref:("ticket/bh-"+($n|tostring)), head_sha:$h, base_ref:"main", author:$a,
      labels:["merge-queue"], body:"", mergeable_state:null, updated_at:"2026-10-26T10:00:00Z",
      created_at:"2026-10-01T00:00:00Z", url:("https://github.com/example-org/demo-os/pull/"+($n|tostring)), draft:0, merged_at:null}'
}
list() {   # list <age> <rows...>
  local age="$1"; shift
  printf '%s\n' "$@" | jq -sc --argjson a "$age" '{rows: ., truncated: false, sync: {synced_at: "2026-10-26T10:00:00Z", age_s: $a}, missing: null, unknown: 0}' > "$T/w/list.json"
}

# ── O1-O4: mc_open_record ─────────────────────────────────────────────────────
echo main > "$MEMO"; printf '1\tfalse\n2\tfalse\n3\ttrue\n' > "$MEMO.cross"
list 10 "$(lrow 1)" "$(lrow 2 'app-x[bot]')"
seam mc_open_record "$T/o1.json" "$SLUG"
eq "O1 rc" "$(rc)" 0
eq "O1 row shape" "$(jq -c '.[0] | {number, state, user, head, base}' "$T/o1.json")" \
  "$(jq -nc --arg h "$(hd 1)" '{number:1, state:"open", user:{login:"operator", type:"User"},
      head:{ref:"ticket/bh-1", sha:$h, repo:{full_name:"example-org/demo-os"}},
      base:{ref:"main", repo:{default_branch:"main", full_name:"example-org/demo-os"}}}')"
eq "O1 a [bot] author is type Bot" "$(jq -r '.[1].user.type' "$T/o1.json")" Bot
eq "O1 the whole list, no window" "$(grep -c 'limit=' "$T/w/jobs.log")" 0
list 10 "$(lrow 1)" "$(lrow 4)"
seam mc_open_record "$T/o2.json" "$SLUG"
eq "O2 a PR the memo does not know" "$(rc):$(out)" "1:field:cross"
list 10 "$(lrow 1)" "$(lrow 3)"
seam mc_open_record "$T/o2.json" "$SLUG"
eq "O2 a fork PR" "$(rc):$(jq -r '.[1].head.repo.full_name' "$T/o2.json")" "0:fork"
rm -f "$MEMO"
seam mc_open_record "$T/o3.json" "$SLUG"; eq "O3 no default-branch memo" "$(rc):$(out)" "1:field:default_branch"
echo develop > "$MEMO"
seam mc_open_record "$T/o3.json" "$SLUG"; eq "O3 a memo that is not main" "$(rc):$(out)" "1:field:default_branch"
echo main > "$MEMO"
list 5000 "$(lrow 1)"
seam mc_open_record "$T/o4.json" "$SLUG"; eq "O4 a stale list" "$(rc):$(out)" "1:stale"

# ── O5: the norm ──────────────────────────────────────────────────────────────
list 10 "$(lrow 1)" "$(lrow 2)"
seam mc_open_record "$T/o5r.json" "$SLUG"
for n in 2 1; do
  jq -nc --argjson n "$n" --arg h "$(hd "$n")" '{number:$n, draft:false, labels:[{name:"merge-queue"}], head:{sha:$h, ref:"x"}}'
done | jq -sc . > "$T/o5g.json"
seam mc_open_norm "$T/o5r.json"; NR=$(out)
seam mc_open_norm "$T/o5g.json"; NG=$(out)
eq "O5 equal rows give equal norms" "$NR" "$NG"
jq -c '.[0].head.sha = "ffff"' "$T/o5g.json" > "$T/o5x.json"; seam mc_open_norm "$T/o5x.json"
[ "$(out)" != "$NR" ] && ok || bad "O5 a changed head left the norm equal"
jq -c '.[0].labels = []' "$T/o5g.json" > "$T/o5x.json"; seam mc_open_norm "$T/o5x.json"
[ "$(out)" != "$NR" ] && ok || bad "O5 a changed label left the norm equal"

# ── O6: the external-PR window ────────────────────────────────────────────────
: > "$T/w/jobs.log"
seam mc_xe_record "$T/o6.json" "$SLUG"
eq "O6 rc" "$(rc)" 0
eq "O6 the window of 100" "$(grep -c 'order=created&limit=100' "$T/w/jobs.log")" 1

# ── F1-F3: mc_flake_record ────────────────────────────────────────────────────
H7=$(hd 7)
row() {   # row <age> <head> <checks-json>
  jq -nc --argjson a "$1" --arg h "$2" --argjson c "$3" \
    '{row:{repo:"example-org/demo-os", number:7, state:"open", head_sha:$h, checks:$c}, age_s:$a}' > "$T/w/row.json"
}
ck() { jq -nc --arg h "${3:-$H7}" --arg s "$1" --arg c "$2" '{status:$s, conclusion:(if $c == "" then null else $c end), sha:$h, at:"2026-10-26T09:59:00Z"}'; }
row 10 "$H7" "{\"workflow:CI\":$(ck completed success),\"lint\":$(ck completed skipped)}"
seam mc_flake_record "$T/f1" "$SLUG" "$H7" 7
eq "F1 all completed, none cancelled: a hit" "$(rc):$(out)" "0:"
[ ! -s "$T/f1" ] && ok || bad "F1 the hit must be an empty file: $(cat "$T/f1")"
row 10 "$H7" "{\"workflow:CI\":$(ck completed cancelled)}"
seam mc_flake_record "$T/f2" "$SLUG" "$H7" 7; eq "F2 cancelled" "$(rc):$(out)" "1:flake"
row 10 "$H7" "{\"workflow:CI\":$(ck completed timed_out)}"
seam mc_flake_record "$T/f2" "$SLUG" "$H7" 7; eq "F2 timed_out" "$(rc):$(out)" "1:flake"
row 10 "$H7" "{\"workflow:CI\":$(ck in_progress '')}"
seam mc_flake_record "$T/f2" "$SLUG" "$H7" 7; eq "F2 not completed" "$(rc):$(out)" "1:pending"
row 10 "$(hd 8)" "{\"workflow:CI\":$(ck completed success)}"
seam mc_flake_record "$T/f2" "$SLUG" "$H7" 7; eq "F2 a row at another head" "$(rc):$(out)" "1:head"
row 10 "$H7" "{\"workflow:CI\":$(ck completed success "$(hd 8)")}"
seam mc_flake_record "$T/f2" "$SLUG" "$H7" 7; eq "F2 entries only for another head" "$(rc):$(out)" "1:none"
row 3901 "$H7" "{\"workflow:CI\":$(ck completed success)}"
seam mc_flake_record "$T/f2" "$SLUG" "$H7" 7; eq "F2 age = knob + 1" "$(rc):$(out)" "1:stale"
row 3900 "$H7" "{\"workflow:CI\":$(ck completed success)}"
seam mc_flake_record "$T/f2" "$SLUG" "$H7" 7; eq "F2 age = knob is a hit" "$(rc)" 0
row 10 "$H7" "$(for i in $(seq 1 100); do printf '{"key":"c%s","value":%s}\n' "$i" "$(ck completed success)"; done | jq -sc 'from_entries')"
seam mc_flake_record "$T/f2" "$SLUG" "$H7" 7; eq "F2 as many names as PRR_CI_CHECKS_MAX" "$(rc):$(out)" "1:checks-max"
printf '22|CI|%s\n11|Lint|%s\n' "$H7" "$H7" > "$T/f3"
seam mc_flake_norm "$T/f3"; eq "F3 flake norm" "$(out)" '[{"n":"flake","v":"11,22"}]'
: > "$T/f3"; seam mc_flake_norm "$T/f3"; eq "F3 no flake" "$(out)" '[{"n":"flake","v":""}]'

echo "mc-record-seam.bh-9938: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
