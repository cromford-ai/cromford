#!/bin/bash
# tests/unblock-prr-seam.bh-10158-test.sh — BH-10158 (BH-9926 wave 5, slice C2
# of #9937): the unblock lane's prr-shadow seam bin/lib/prr-shadow.d/unblock.sh
# and the wake-gated answer cache of bin/lib/unblock/prr.sh.
#
#   K1-K12  ubp_cached, the decision table (plan, Failure modes), first match
#           wins; E1-E2 a failed or non-JSON read writes no cache; R1-R2 the
#           repo-wide key `-`
#   O1-O4   ub_open_record: the 100-row window, a list miss, a null labels,
#           created_at descending
#   P1-P8   ub_pull_record: merged/closed/open, a bad head, no row, a need,
#           labels as strings, merge_commit_sha on a merged PR
#   B1-B6   ub_branch_record: exact head_ref only, case, open list only, two
#           matches, a list miss is a miss, the per-tick memo reads once
#   C1-C6   ub_cr_record: a login's latest stored review decides
#   T1-T4   ub_ci_record: green, pending -> running, red, unknown -> miss
#   I1-I4   the cache round trip, gc, two repos
#   S1-S5   each of the 5 triplets in step shadow with a forced mismatch:
#           exactly 1 PRR_SHADOW lane=unblock key=<site key> line, and <out>
#           holds the GitHub value; SR in step record a hit makes no GitHub call
#
# STUBS. _jobs_req answers /api/pr-records from fixture files in $FX (a list
# answer in list.json, honoring &limit=, and one row per row-<n>.json) and
# logs each call to $FX/jobs.log. The wake feed is the REAL prs_wake_seen
# (bin/lib/pr-snapshot-wakes.sh) on a seeded changed.tsv and wakes.state, and
# the gate is the REAL wb_due / wb_cache_get (bin/lib/wake-backstop.sh). The
# real prs_wake_seen bounds its window on the box clock, so every epoch is
# computed from one NOWR read, and wb_due's clock is pinned to the same value
# through WAKE_BACKSTOP_NOW (the sandbox seam). No GitHub, no network.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-prr-seam.bh-10158-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/unblock/prr.sh"
SEAM="$DIR/bin/lib/prr-shadow.d/unblock.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
for f in "$LIB" "$SEAM"; do
  [ -f "$f" ] || { echo "FAIL: $f is missing"; echo "unblock-prr-seam.bh-10158: 0 passed, 1 failed"; exit 1; }
done
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 && [ -s "$T/lanes.json" ] \
  || { echo "FAIL: bin/lanes-build.sh could not compose the registry"; echo "unblock-prr-seam.bh-10158: 0 passed, 1 failed"; exit 1; }

NOWR=$(date +%s)  # determinism: ok the real prs_wake_seen reads the box clock; wb_due is pinned to this value
H="$T/h"; FX="$T/fx"; mkdir -p "$H" "$FX"
SLUG=o/r; SD="$H/state/pr-snapshot/o_r"
A=$(printf 'a%.0s' {1..40}); B=$(printf 'b%.0s' {1..40}); C=$(printf 'c%.0s' {1..40}); AU=$(printf 'A%.0s' {1..40})
CACHE="$H/state/unblock-prr/o_r"

cat > "$T/stub.sh" <<'EOF'
_jobs_req() {
  local q lim
  printf '%s %s\n' "$1" "$2" >> "$FX/jobs.log"
  q="$2"
  case "$q" in
    /api/pr-records\?*number=*)
      if [ -f "$FX/row-${q##*number=}.json" ]; then cat "$FX/row-${q##*number=}.json"; else echo '{"row":null,"age_s":null}'; fi ;;
    /api/pr-records\?*state=*)
      [ -f "$FX/list.json" ] || return 1
      lim=""; case "$q" in *limit=*) lim=${q##*limit=} ;; esac
      if [ -n "$lim" ]; then jq -c --argjson l "$lim" '.rows |= (sort_by(.created_at) | reverse | .[:$l])' "$FX/list.json"
      else cat "$FX/list.json"; fi ;;
    /api/settings*) echo '{"settings":[]}' ;;
    *) return 1 ;;
  esac
}
# gh_rest is never reached by the seam; a call is a test failure.
gh_rest() { printf 'GH %s\n' "$*" >> "$FX/gh.log"; return 75; }
EOF

# run <shell> [VAR=val...] — one call in a clean env; sets OUT, RC
run() {
  local code="$1"; shift
  OUT=$(env -i PATH="$PATH" HOME="$T" T="$T" FX="$FX" LIB="$LIB" HARNESS="$H" HARNESS_TEST_SANDBOX=1 \
    PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=600 WAKE_BACKSTOP_NOW="$NOWR" LANE_REGISTRY="$T/lanes.json" \
    A="$A" B="$B" C="$C" SLUG="$SLUG" "$@" \
    bash -c '. "$T/stub.sh"; . "$LIB"; '"$code" 2>"$T/err")
  RC=$?
}
jobs_calls() { if [ -f "$FX/jobs.log" ]; then grep -c "${1:-.}" "$FX/jobs.log"; else echo 0; fi; }
reset_fx() { rm -f "$FX"/*.json "$FX"/*.log; }

# row <n> <head> <ref> <created> [labels-json] [reviews-json] — one list row
row() {
  jq -nc --argjson n "$1" --arg h "$2" --arg r "$3" --arg c "$4" --argjson l "${5:-[]}" --argjson rv "${6:-{\}}" \
    '{number: $n, title: "t", head_ref: $r, head_sha: $h, base_ref: "main", author: "u", labels: $l, body: "",
      mergeable_state: null, updated_at: $c, created_at: $c, url: "https://github.com/o/r/pull/\($n)", draft: 0,
      merged_at: null, reviews: $rv}'
}
# list <age_s> <missing|null> <row>... — the list answer
list() {
  local age="$1" miss="$2"; shift 2
  printf '%s\n' "$@" | jq -sc --argjson a "$age" --argjson m "$miss" \
    '{rows: ., truncated: false, sync: {age_s: $a, synced_at: "2026-11-26T00:00:00Z"}, missing: $m, unknown: 0}' > "$FX/list.json"
}
# one <n> <json-fields> — the single-row answer
one() { jq -nc --argjson f "$2" '{row: ({repo: "o/r", number: 0, url: "https://github.com/o/r/pull/0", labels: [], draft: 0} + $f), age_s: 30}' \
  | jq -c --argjson n "$1" '.row.number = $n | .row.url = "https://github.com/o/r/pull/\($n)"' > "$FX/row-$1.json"; }

# feed <complete> [kind:key:at]... — the mirror the real prs_wake_seen reads
feed() {
  local c="$1" r k y a i=100; shift
  scratch_rm "$SD"; mkdir -p "$SD"
  printf '%s\t%s\t1\t%s\n' "$NOWR" "$c" "$((NOWR - 7200))" > "$SD/wakes.state"
  echo 500 > "$SD/wakes.wm"; : > "$SD/changed.tsv"
  for r in "$@"; do
    IFS=: read -r k y a <<<"$r"; i=$((i + 1))
    printf '%s\t%s\t%s\t%s\n' "$k" "$y" "$i" "$a" >> "$SD/changed.tsv"
  done
}
# seed <n|repo> <kind> <head> <epoch> — a cache entry as wb_cache_put writes it
seed() {
  mkdir -p "$CACHE"
  echo '{"cached":true}' > "$CACHE/$1-$2.json"
  printf '%s\t%s\n' "$3" "$4" > "$CACHE/$1-$2.meta"
}
# The read the gate guards: logs CMD and writes {"fresh":true}.
CMD='rd() { echo CMD >> "$FX/cmd.log"; echo "{\"fresh\":true}" > "$1"; }; '
cmd_runs() { if [ -f "$FX/cmd.log" ]; then grep -c CMD "$FX/cmd.log"; else echo 0; fi; }
# gate <step> <n> <head> [VAR=val...] — one ubp_cached call; sets OUT to the answer
gate() {
  local step="$1" n="$2" h="$3"; shift 3
  rm -f "$FX/cmd.log" "$T/out.json"
  run "$CMD"'ubp_cached "$SLUG" "'"$n"'" "'"$h"'" reviews "$T/out.json" rd "$T/out.json"; echo "rc=$?"; cat "$T/out.json"' GH_SOURCE="$step" "$@"
}
M=$((NOWR - 30))

# ════ K: the gate ═══════════════════════════════════════════════════════════
scratch_rm "$H/state/unblock-prr"; feed 1
gate shadow 7 "$A"
eq "K1 shadow: the read runs" "$(cmd_runs)" 1
[ ! -e "$CACHE/7-reviews.json" ] && ok || bad "K1 shadow must write no cache file"
gate off 7 "$A"
eq "K2 off: the read runs" "$(cmd_runs)" 1
[ ! -e "$CACHE/7-reviews.json" ] && ok || bad "K2 off must write no cache file"
gate record 7 "$A"
eq "K3 record, no cache: the read runs" "$(cmd_runs)" 1
eq "K3 the meta is <head>\\t<start epoch>" "$(cat "$CACHE/7-reviews.meta" 2>/dev/null)" "$A	$NOWR"
eq "K3 the cache holds the answer" "$(jq -c . "$CACHE/7-reviews.json" 2>/dev/null)" '{"fresh":true}'
seed 7 reviews "$A" "$M"
gate record 7 "$A"
eq "K4 same head, no wake, 30 s old: served" "$(cmd_runs)" 0
eq "K4 the answer is the cached one" "$(printf '%s' "$OUT" | tail -1)" '{"cached":true}'
seed 7 reviews "$B" "$M"
gate record 7 "$A"
eq "K5 another head (a push): the read runs" "$(cmd_runs)" 1
seed 7 reviews "$AU" "$M"
gate record 7 "$A"
eq "K6 an upper-case copy of the head: a miss, the read runs" "$(cmd_runs)" 1
seed 7 reviews "$A" "$M"; feed 1 "pr:7:$((NOWR - 5))"
gate record 7 "$A"
eq "K7 a pr wake for this n after the read: the read runs" "$(cmd_runs)" 1
seed 7 reviews "$A" "$M"; feed 1 "pr:8:$((NOWR - 5))"
gate record 7 "$A"
eq "K8 a pr wake for another n: served" "$(cmd_runs)" 0
seed 7 reviews "$A" "$M"; feed 1 "pr:7:$((M - 120))"
gate record 7 "$A"
eq "K9 a pr wake for this n two minutes before the read: served" "$(cmd_runs)" 0
seed 7 reviews "$A" "$M"; feed 1 "checks:$A:$((NOWR - 5))"
gate record 7 "$A"
eq "K10 a checks wake on this head: served" "$(cmd_runs)" 0
seed 7 reviews "$A" "$M"; feed 0
gate record 7 "$A"
eq "K11 the feed is incomplete: the read runs" "$(cmd_runs)" 1
feed 1; seed 7 reviews "$A" "$((NOWR - 2000))"
gate record 7 "$A"
eq "K12 older than the 1800 s backstop: the read runs" "$(cmd_runs)" 1
seed 7 reviews "$A" "$M"
gate record 7 "$A" UNBLOCK_PRR_BACKSTOP_S=0
eq "K12b the knob 0 is always read" "$(cmd_runs)" 1
seed 7 reviews "$A" "$M"
gate record 7 "$A" UNBLOCK_PRR_BACKSTOP_S=86400
eq "K12c near miss: knob 86400, 30 s old: served" "$(cmd_runs)" 0

# E1 a read that fails writes no cache; E2 a non-JSON answer writes no cache
scratch_rm "$H/state/unblock-prr"; feed 1
rm -f "$FX/cmd.log"
run 'ubp_cached "$SLUG" 7 "$A" reviews "$T/out.json" false; echo "rc=$?"' GH_SOURCE=record
eq "E1 the read's rc is returned" "$OUT" "rc=1"
[ ! -e "$CACHE/7-reviews.json" ] && [ ! -e "$CACHE/7-reviews.meta" ] && ok || bad "E1 a failed read must write no cache"
run 'w() { echo "not json" > "$1"; }; ubp_cached "$SLUG" 7 "$A" reviews "$T/out.json" w "$T/out.json"; echo "rc=$?"' GH_SOURCE=record
eq "E2 rc 0" "$OUT" "rc=0"
[ ! -e "$CACHE/7-reviews.meta" ] && ok || bad "E2 a non-JSON answer must write no cache"

# R1 the repo-wide key: any pr wake of the repo is due; R2 a push wake is not
seed repo closed-list - "$M"; feed 1 "pr:99:$((NOWR - 5))"
rm -f "$FX/cmd.log"
run "$CMD"'ubp_cached "$SLUG" - - closed-list "$T/out.json" rd "$T/out.json"' GH_SOURCE=record
eq "R1 a pr wake of any PR makes the closed list due" "$(cmd_runs)" 1
seed repo closed-list - "$M"; feed 1 "push:$B:$((NOWR - 5))"
rm -f "$FX/cmd.log"
run "$CMD"'ubp_cached "$SLUG" - - closed-list "$T/out.json" rd "$T/out.json"' GH_SOURCE=record
eq "R2 a push wake does not" "$(cmd_runs)" 0

# ════ I: round trip, gc, two repos ══════════════════════════════════════════
scratch_rm "$H/state/unblock-prr"; feed 1
gate record 7 "$A"; gate record 7 "$A"
eq "I1 put, then get on the same head: a hit" "$(cmd_runs)" 0
gate record 7 "$B"
eq "I2 get on another head: a miss" "$(cmd_runs)" 1
seed 5 reviews "$A" "$M"; seed 6 reviews "$A" "$M"
touch -d '4 days ago' "$CACHE/5-reviews.json" "$CACHE/5-reviews.meta"
touch -d '1 day ago' "$CACHE/6-reviews.json" "$CACHE/6-reviews.meta"
run 'ubp_gc'
[ ! -e "$CACHE/5-reviews.json" ] && [ ! -e "$CACHE/5-reviews.meta" ] && ok || bad "I3 ubp_gc must delete a 4-day-old entry"
[ -e "$CACHE/6-reviews.json" ] && ok || bad "I3 ubp_gc must keep a 1-day-old entry"
scratch_rm "$H/state/unblock-prr"; seed 7 reviews "$A" "$M"
mkdir -p "$H/state/pr-snapshot/o_s"; cp "$SD/wakes.state" "$SD/wakes.wm" "$SD/changed.tsv" "$H/state/pr-snapshot/o_s/"
rm -f "$FX/cmd.log"
run "$CMD"'ubp_cached o/s 7 "$A" reviews "$T/out.json" rd "$T/out.json"' GH_SOURCE=record
eq "I4 another repo does not read o/r's entry" "$(cmd_runs)" 1
[ -e "$H/state/unblock-prr/o_s/7-reviews.json" ] && ok || bad "I4 o/s writes its own dir"

# ════ O: T-OPEN ═════════════════════════════════════════════════════════════
reset_fx
rows=(); for i in $(seq 1 120); do rows+=("$(row "$i" "$A" "ticket/bh-$i" "$(printf '2026-11-%02dT%02d:%02d:00Z' $((1 + i / 60)) $((i % 24)) $((i % 60)))")"); done
list 10 null "${rows[@]}"
run 'ub_open_record "$T/o.json" "$SLUG"; echo "rc=$?"'
eq "O1 rc 0" "$OUT" "rc=0"
eq "O1 the window is 100 rows" "$(jq length "$T/o.json")" 100
grep -q 'order=created&limit=100' "$FX/jobs.log" && ok || bad "O1 the read asks the 100 newest by created_at: $(cat "$FX/jobs.log")"
eq "O4 created_at descending" "$(jq -c '[.[].created_at] == ([.[].created_at] | sort | reverse)' "$T/o.json")" true
eq "O1 the REST shape" "$(jq -c '.[0] | {state, draft, h: (.head.sha | length), l: (.labels | type), u: (.html_url | startswith("https://github.com/o/r/pull/"))}' "$T/o.json")" \
  '{"state":"open","draft":false,"h":40,"l":"array","u":true}'
list 99999 null "$(row 1 "$A" ticket/bh-1 2026-11-01T00:00:00Z)"
run 'ub_open_record "$T/o.json" "$SLUG"; echo "rc=$?"'
eq "O2 a stale list is a miss" "$OUT" "$(printf 'stale\nrc=1')"
list 10 '"labels"' "$(row 1 "$A" ticket/bh-1 2026-11-01T00:00:00Z null)"
run 'ub_open_record "$T/o.json" "$SLUG"; echo "rc=$?"'
eq "O3 a null labels (worker missing) is field:labels" "$OUT" "$(printf 'field:labels\nrc=1')"
list 10 null "$(row 1 "$A" ticket/bh-1 2026-11-01T00:00:00Z null)"
run 'ub_open_record "$T/o.json" "$SLUG"; echo "rc=$?"'
eq "O3b a null labels on a row is field:labels" "$OUT" "$(printf 'field:labels\nrc=1')"

# ════ P: T-PULL ═════════════════════════════════════════════════════════════
reset_fx
one 7 "{\"state\":\"merged\",\"head_sha\":\"$A\",\"merged_at\":\"2026-11-25T00:00:00Z\",\"labels\":[\"merge-queue\"]}"
run 'ub_pull_record "$T/p.json" "$SLUG" 7; echo "rc=$?"; jq -c "{state, merged, h: .head.sha, l: .labels}" "$T/p.json"'
eq "P1 merged -> closed, merged true" "$OUT" "$(printf 'rc=0\n{"state":"closed","merged":true,"h":"%s","l":[{"name":"merge-queue"}]}' "$A")"
one 7 "{\"state\":\"closed\",\"head_sha\":\"$A\"}"
run 'ub_pull_record "$T/p.json" "$SLUG" 7; echo "rc=$?"; jq -c "{state, merged}" "$T/p.json"'
eq "P2 closed -> merged false" "$OUT" "$(printf 'rc=0\n{"state":"closed","merged":false}')"
one 7 "{\"state\":\"open\",\"head_sha\":\"$A\",\"head_ref\":\"ticket/bh-7\",\"mergeable_state\":\"clean\"}"
run 'ub_pull_record "$T/p.json" "$SLUG" 7 mergeable_state; echo "rc=$?"; jq -c "{number, state, merged, ref: .head.ref, mergeable_state, html_url}" "$T/p.json"'
eq "P3 open, 40-hex head, the need is set" "$OUT" \
  "$(printf 'rc=0\n{"number":7,"state":"open","merged":false,"ref":"ticket/bh-7","mergeable_state":"clean","html_url":"https://github.com/o/r/pull/7"}')"
one 7 '{"state":"open","head_sha":"abc123"}'
run 'ub_pull_record "$T/p.json" "$SLUG" 7; echo "rc=$?"'
eq "P4 a head that is not 40 hex" "$OUT" "$(printf 'field:head_sha\nrc=1')"
run 'ub_pull_record "$T/p.json" "$SLUG" 8; echo "rc=$?"'
eq "P5 no row" "$OUT" "$(printf 'unknown\nrc=1')"
one 7 "{\"state\":\"open\",\"head_sha\":\"$A\",\"mergeable_state\":null}"
run 'ub_pull_record "$T/p.json" "$SLUG" 7 mergeable_state; echo "rc=$?"'
eq "P6 need mergeable_state, null" "$OUT" "$(printf 'field:mergeable_state\nrc=1')"
run 'ub_pull_record "$T/p.json" "$SLUG" 7; echo "rc=$?"'
eq "P6b no need: not a miss" "$OUT" "rc=0"
one 7 "{\"state\":\"open\",\"head_sha\":\"$A\",\"labels\":[\"b\",\"a\"]}"
run 'ub_pull_record "$T/p.json" "$SLUG" 7 labels; echo "rc=$?"; jq -c .labels "$T/p.json"'
eq "P7 labels as strings become [{name}]" "$OUT" "$(printf 'rc=0\n[{"name":"b"},{"name":"a"}]')"
one 7 "{\"state\":\"merged\",\"head_sha\":\"$A\"}"
run 'ub_pull_record "$T/p.json" "$SLUG" 7 labels,merge_commit_sha; echo "rc=$?"'
eq "P8 merged and need merge_commit_sha: the record has none" "$OUT" "$(printf 'field:merge_commit_sha\nrc=1')"
one 7 "{\"state\":\"open\",\"head_sha\":\"$A\"}"
run 'ub_pull_record "$T/p.json" "$SLUG" 7 labels,merge_commit_sha; echo "rc=$?"'
eq "P8b open and need merge_commit_sha: not a miss" "$OUT" "rc=0"

# ════ B: T-BRANCH ═══════════════════════════════════════════════════════════
reset_fx
list 10 null "$(row 1 "$A" ticket/bh-1 2026-11-01T00:00:00Z)" "$(row 100 "$B" ticket/bh-100 2026-11-02T00:00:00Z)" \
  "$(row 11 "$C" ticket/BH-10 2026-11-03T00:00:00Z)"
run 'ub_branch_record "$T/b.json" "$SLUG" ticket/bh-10; echo "rc=$?"; jq -c . "$T/b.json"'
eq "B1 prefix near misses (bh-1, bh-100) do not match" "$OUT" "$(printf 'rc=0\n[]')"
eq "B2 ticket/BH-10 does not match ticket/bh-10" "$(printf '%s' "$OUT" | tail -1)" '[]'
grep -q 'state=open' "$FX/jobs.log" && ! grep -q 'state=closed' "$FX/jobs.log" && ok || bad "B3 the branch read reads the open list only: $(cat "$FX/jobs.log")"
list 10 null "$(row 10 "$A" ticket/bh-10 2026-11-01T00:00:00Z)" "$(row 12 "$B" ticket/bh-10 2026-11-02T00:00:00Z)"
run 'ub_branch_record "$T/b.json" "$SLUG" ticket/bh-10; echo "rc=$?"; jq -c "[.[] | {number, h: .head.sha, updated_at}] | sort_by(.number)" "$T/b.json"'
eq "B4 two matches give both rows" "$OUT" \
  "$(printf 'rc=0\n[{"number":10,"h":"%s","updated_at":"2026-11-01T00:00:00Z"},{"number":12,"h":"%s","updated_at":"2026-11-02T00:00:00Z"}]' "$A" "$B")"
list 99999 null "$(row 10 "$A" ticket/bh-10 2026-11-01T00:00:00Z)"
run 'ub_branch_record "$T/b.json" "$SLUG" ticket/bh-10; echo "rc=$?"; cat "$T/b.json"'
eq "B5 a stale list is a miss, never []" "$OUT" "$(printf 'stale\nrc=1')"
list 10 null "$(row 10 "$A" ticket/bh-10 2026-11-01T00:00:00Z)"
rm -f "$FX/jobs.log"; mkdir -p "$T/memo"
run 'ub_branch_record "$T/b.json" "$SLUG" ticket/bh-10; ub_branch_record "$T/b2.json" "$SLUG" ticket/bh-11; ub_branch_record "$T/b3.json" "$SLUG" ticket/bh-12' UBP_MEMO_DIR="$T/memo"
eq "B6 three branch reads in one tick: one list read" "$(jobs_calls pr-records)" 1
scratch_rm "$T/memo" || exit 1

# ════ C: T-CR ═══════════════════════════════════════════════════════════════
cr() { # cr <reviews-json> -> the set
  reset_fx
  list 10 null "$(row 5 "$A" ticket/bh-5 2026-11-01T00:00:00Z '[]' "$1")" "$(row 6 "$B" ticket/bh-6 2026-11-02T00:00:00Z '[]' '{}')"
  run 'ub_cr_record "$T/c.json" "$SLUG"; echo "rc=$?"; jq -c "[.items[].number]" "$T/c.json"'
}
cr '{"a":{"state":"CHANGES_REQUESTED"}}'
eq "C1 A CHANGES_REQUESTED: in the set" "$OUT" "$(printf 'rc=0\n[5]')"
cr '{"a":{"state":"APPROVED"}}'
eq "C2 A CR then A APPROVED (the stored latest is APPROVED): out" "$OUT" "$(printf 'rc=0\n[]')"
cr '{"a":{"state":"CHANGES_REQUESTED"},"b":{"state":"APPROVED"}}'
eq "C3 A CR and B APPROVED: in" "$OUT" "$(printf 'rc=0\n[5]')"
cr '{"a":{"state":"DISMISSED"}}'
eq "C4 A DISMISSED: out" "$OUT" "$(printf 'rc=0\n[]')"
cr '{"a":{"state":"COMMENTED"}}'
eq "C5 A COMMENTED only: out" "$OUT" "$(printf 'rc=0\n[]')"
cr 'null'
eq "C6 reviews null on a row is a miss, never no CR" "$(head -2 <<<"$OUT")" "$(printf 'field:reviews\nrc=1')"
jq -e '.incomplete_results == false' "$T/c.json" >/dev/null 2>&1 && bad "C6 a miss must leave no answer" || ok

# ════ T: T-CI ═══════════════════════════════════════════════════════════════
ci() { # ci <status> <conclusion|null> -> the word
  reset_fx
  one 7 "$(jq -nc --arg h "$A" --arg s "$1" --argjson c "$2" '{state: "open", head_sha: $h, checks: {"ci / t": {status: $s, conclusion: $c, sha: $h, at: "2026-11-26T00:00:00Z"}}}')"
  run 'ub_ci_record "$T/ci.json" "$SLUG" 7 "$A"; echo "rc=$?"; cat "$T/ci.json"'
}
ci completed '"success"'; eq "T1 green" "$OUT" "$(printf 'rc=0\n{"word":"green"}')"
ci in_progress null; eq "T2 pending is running" "$OUT" "$(printf 'rc=0\n{"word":"running"}')"
ci completed '"failure"'; eq "T3 red" "$OUT" "$(printf 'rc=0\n{"word":"red"}')"
reset_fx; one 7 "{\"state\":\"open\",\"head_sha\":\"$A\",\"checks\":{}}"
run 'ub_ci_record "$T/ci.json" "$SLUG" 7 "$A"; echo "rc=$?"'
eq "T4 no check entry is the miss ci:unknown" "$OUT" "$(printf 'ci:unknown\nrc=1')"

# ════ S: the five triplets in step shadow, one forced mismatch each ═════════
reset_fx; rm -f "$H/logs/prr-shadow.log"
list 10 null "$(row 5 "$A" ticket/bh-5 2026-11-01T00:00:00Z '[]' '{"a":{"state":"CHANGES_REQUESTED"}}')"
one 5 "{\"state\":\"open\",\"head_sha\":\"$A\",\"checks\":{\"t\":{\"status\":\"completed\",\"conclusion\":\"success\",\"sha\":\"$A\",\"at\":\"2026-11-26T00:00:00Z\"}}}"
# The GitHub side of each site: a value that differs from the record's.
GHF='g_open() { printf "[{\"number\":6,\"head\":{\"sha\":\"%s\"},\"draft\":false,\"labels\":[]}]\n" "$B" > "$1"; }
g_pull() { printf "{\"number\":5,\"state\":\"open\",\"merged\":false,\"head\":{\"sha\":\"%s\"},\"labels\":[]}\n" "$B" > "$1"; }
g_branch() { echo "[]" > "$1"; }
g_cr() { echo "{\"incomplete_results\":false,\"items\":[]}" > "$1"; }
g_ci() { echo "{\"word\":\"red\"}" > "$1"; }
'
shadow() { # shadow <case> <key> <call> <want-out-jq> <want>
  local before after
  before=$(grep -c "PRR_SHADOW lane=unblock key=$2 " "$H/logs/prr-shadow.log" 2>/dev/null) || before=0
  run "$GHF"'ubp_read "'"$2"'" "$T/s.json" '"$3"'; echo "rc=$?"; jq -c "'"$4"'" "$T/s.json"' GH_SOURCE=shadow
  after=$(grep -c "PRR_SHADOW lane=unblock key=$2 " "$H/logs/prr-shadow.log" 2>/dev/null) || after=0
  eq "$1 exactly 1 PRR_SHADOW line for $2" "$((after - before))" 1
  eq "$1 <out> holds the GitHub value" "$OUT" "$(printf 'rc=0\n%s' "$5")"
}
shadow S1 "$SLUG#open@review" 'ub_open_record g_open ub_open_norm "$SLUG"' '[.[].number]' '[6]'
shadow S2 "$SLUG#5@pull:s1" 'ub_pull_record g_pull ub_pull_norm "$SLUG" 5' '.head.sha' "\"$B\""
shadow S3 "$SLUG#branch:ticket/bh-5@s2" 'ub_branch_record g_branch ub_branch_norm "$SLUG" ticket/bh-5' '.' '[]'
shadow S4 "$SLUG#cr" 'ub_cr_record g_cr ub_cr_norm "$SLUG"' '.items' '[]'
shadow S5 "$SLUG#5@ci" 'ub_ci_record g_ci ub_ci_norm "$SLUG" 5 "$A"' '.word' '"red"'
eq "S the shadow log has exactly 5 lines" "$(grep -c 'PRR_SHADOW lane=unblock' "$H/logs/prr-shadow.log")" 5
# SR step record, a record hit: the GitHub side is not called, the record's value is used
run "$GHF"'g_pull() { echo CALLED >> "$FX/gcall.log"; }; ubp_read "$SLUG#5@pull:s1" "$T/s.json" ub_pull_record g_pull ub_pull_norm "$SLUG" 5; echo "rc=$?"; jq -r .head.sha "$T/s.json"' GH_SOURCE=record
eq "SR record hit: the record's head" "$OUT" "$(printf 'rc=0\n%s' "$A")"
[ ! -e "$FX/gcall.log" ] && ok || bad "SR record hit must not call the GitHub side"
# SM step record, a miss: one PRR_MISS line and the GitHub value
run "$GHF"'ubp_read "$SLUG#9@pull:s1" "$T/s.json" ub_pull_record g_pull ub_pull_norm "$SLUG" 9; echo "rc=$?"; jq -r .head.sha "$T/s.json"' GH_SOURCE=record
eq "SM record miss: GitHub's value" "$OUT" "$(printf 'rc=0\n%s' "$B")"
eq "SM one PRR_MISS line" "$(grep -c "PRR_MISS lane=unblock key=$SLUG#9@pull:s1 why=unknown fallback=github" "$H/logs/prr-shadow.log")" 1
# SL no seam and no prr_read: ubp_read is the GitHub side alone
run "$GHF"'unset -f prr_read; ubp_read "$SLUG#5@pull:s1" "$T/s.json" ub_pull_record g_pull ub_pull_norm "$SLUG" 5; echo "rc=$?"; jq -r .head.sha "$T/s.json"' GH_SOURCE=record
eq "SL no prr_read: today's read" "$OUT" "$(printf 'rc=0\n%s' "$B")"
[ ! -e "$FX/gh.log" ] && ok || bad "the seam made a gh_rest call: $(cat "$FX/gh.log")"

echo "unblock-prr-seam.bh-10158: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
