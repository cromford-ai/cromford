#!/bin/bash
# tests/lead-merge-carry.bh-8705-test.sh — BH-8705: a lead verdict carries
# across a pure merge of main on the lead-review worklist, before gate 10's
# CI wait. The gate is bin/lib/lead-gates.d/07-merge-carry.sh; it calls
# lead_carry (bin/lib/lead-carry.sh) with LC_MERGE_ONLY=1.
#
# lg_run (bin/lib/lead-gates.sh, the loader bin/lead-review.sh calls) is the
# entry point. The lane closure is installed with scratch_install_closure; the
# scratch gate dir keeps gates 07, 10 and 50 only. Real git (a bare remote, the
# hub clone under REPOS_ROOT). Stubs: the jobs worker (_jobs_req over a
# fixture history), the builder ledger (no row), CI (pending), la_decide,
# bin/lead-verdict.sh post, and curl/gh on PATH (any call is recorded).
#   M1   lead MERGE on H1, a clean `git merge main` to H2  -> rc 12, one post,
#        the note names H1 and H2; gate 50 then reads it as replayed; show
#        prints `carried from #5`
#   M2   a merge whose conflict in a PR file was resolved by hand -> 0 posts,
#        rc 11 (gate 10 holds as before). M2b an evil merge (no conflict, a
#        changed PR line in the merge commit) -> 0 posts
#   M3   a new commit that changes a PR line                -> 0 posts
#   M4   a new commit, then a clean main merge             -> 0 posts
#   M5   the newest lead row on H1 is a BLOCK              -> one BLOCK post,
#        never MERGE, la_decide not asked
#   M6   a byte-exact rebase (patch-id)                    -> 0 posts, logged
#   M7   a human MERGE row already on H2                   -> 0 posts
#   M8   LEAD_REVIEW_MERGE_CARRY=0                         -> 0 reads, 0 posts
#   M9   a truncated history -> 0 posts, no terminal mark, read again next
#        tick. M9b the post exits 7 -> no carried mark, rc 11
#   M10  a second tick on the same H2                      -> rc 12, one post
#   M11  the newest lead BLOCK is retracted               -> MERGE from #5,
#        with #5's review mode (intent); M1 and M5 post `full` (no mode)
#   M12  lead_carry with no LC_MERGE_ONLY: a BLOCK is refused; a MERGE note
#        is today's bytes
#   M13  a clean merge of a branch that is not main        -> 0 posts
#   M14  curl and gh were called 0 times
#   M15  the harness repo, a console-ui/src change, console QA on -> 0 posts
#   M16  lg_tick_state_sweep trims an 8-day merge-carry.tsv row, keeps 6-day
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-merge-carry.bh-8705-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
H="$T/h"
export HARNESS="$H" REPOS_ROOT="$T/repos" HOME="$T" TMPDIR="$T"
mkdir -p "$H/bin" "$H/state" "$H/logs" "$T/repos"
scratch_install_closure bin/lead-review.sh "$H" >/dev/null || { echo "FAIL: closure install of bin/lead-review.sh"; exit 1; }
for f in bin/lib/lead-gates.d/07-merge-carry.sh bin/lib/lead-carry.sh bin/lib/lead-gates.d/10-builder.sh bin/lib/lead-gates.d/50-replay-delta.sh; do
  [ -r "$H/$f" ] || { echo "FAIL: the closure of bin/lead-review.sh did not install $f"; exit 1; }
done
GD="$H/bin/lib/lead-gates.d"
for f in "$GD"/*.sh; do case "${f##*/}" in 07-*|10-*|50-*) ;; *) rm -f "$f" ;; esac; done
SLUG=example-org/demo-os
HSLUG=example-org/cromford-fixture

export ROWS="$T/rows.json" POSTS="$T/posts" POSTRC=0 CALLS="$T/calls"
export FLEET_CONF="$T/fleet.conf" LEAD_VERDICT_TOKEN_FILE="$T/tok" LEAD_VERDICT_BIN="$T/lead-verdict-stub.sh" JOBS_BOX=testbox
printf 'demo-os %s\ncromford %s\n' "$SLUG" "$HSLUG" > "$FLEET_CONF"
printf 'tok-fixture-1\n' > "$LEAD_VERDICT_TOKEN_FILE"
LEDGER="$H/state/lead-review-enqueue/merge-carry.tsv"
GLOG="$T/gate.log"

# The bin/lead-verdict.sh post stub: records its argv, appends the lead row it
# was asked to post (in the shape GET /api/verdicts returns).
cat > "$LEAD_VERDICT_BIN" <<'EOF'
#!/bin/bash
echo "$*" >> "$POSTS"
[ "$POSTRC" = 0 ] || { echo "post refused (fixture)"; exit "$POSTRC"; }
note=""; prev=""
for a in "$@"; do [ "$prev" = --note ] && note="$a"; prev="$a"; done
jq --arg h "$4" --arg v "$5" --arg n "$note" \
  '.rows += [{id: ((.rows | map(.id) | max // 0) + 1), source: "lead", head_sha: $h, verdict: $v, note: $n, retracted_at: null}]' \
  "$ROWS" > "$ROWS.tmp" && mv "$ROWS.tmp" "$ROWS"
exit 0
EOF
chmod +x "$LEAD_VERDICT_BIN"
# Gate 50 calls $HARNESS/bin/lead-verdict.sh itself: the stub there too.
cp "$LEAD_VERDICT_BIN" "$H/bin/lead-verdict.sh"

# curl and gh on PATH record any call: the suite makes none (M14).
mkdir -p "$T/trapbin"
for b in curl gh; do
  printf '#!/bin/bash\necho "%s $*" >> "%s"\nexit 1\n' "$b" "$T/net-calls" > "$T/trapbin/$b"; chmod +x "$T/trapbin/$b"
done
export PATH="$T/trapbin:$PATH"
: > "$T/net-calls"

# ---- the seams (functions the gates find with command -v)
log() { echo "$*" >> "$GLOG"; }
_jobs_req() {
  echo "req $1 $2" >> "$CALLS"
  case "$2" in /api/verdicts\?repo=*) JOBS_HTTP=200; cat "$ROWS"; return 0 ;; esac
  JOBS_HTTP=404; return 1
}
job_verdict() { return 2; }                                # no builder row
job_verdict_headbound() { return 1; }
gh_rest_var() { printf -v "$1" '%s' '{"default_branch":"main"}'; }
gh_rest() { return 1; }
lr_ci_green() { LR_CI_WHY="checks pending (fixture)"; return 1; }
lgs_dir() { mkdir -p "$T/lgs" && printf '%s\n' "$T/lgs"; }
la_decide() { echo "la $*" >> "$CALLS"; LA_REASON=""; return 0; }
setting_get() { echo 1; }                                  # console QA row on
# shellcheck source=bin/lib/console-qa-gate.sh
. "$H/bin/lib/console-qa-gate.sh" || { echo "FAIL: cannot source console-qa-gate.sh"; exit 1; }
cqg_head_verdict() { echo MISSING; }                       # no QA: PASS comment
export -f log _jobs_req job_verdict job_verdict_headbound gh_rest_var gh_rest lr_ci_green lgs_dir la_decide setting_get

W="$T/work"
w() { git -C "$W" "$@"; }
edit() { sed -i.bak "${1}s/.*/$2/" "$W/f.txt" && rm -f "$W/f.txt.bak"; }
commit() { w add -A; w commit -qm "$1"; w rev-parse HEAD; }
push() { w push -q -f origin "$@" >/dev/null 2>&1; }

# fixture [project] — a fresh remote with main and a PR branch whose one commit
#   (line 10) is H1; the hub clone under REPOS_ROOT/<project>; empty records.
fixture() {
  local p="${1:-demo-os}"
  scratch_rm "$T/remote.git" 2>/dev/null; scratch_rm "$W" 2>/dev/null; scratch_rm "$T/repos/$p" 2>/dev/null
  : > "$POSTS"; : > "$CALLS"; : > "$GLOG"; POSTRC=0
  unset LEAD_REVIEW_MERGE_CARRY
  git init -q --bare -b main "$T/remote.git"
  git init -q -b main "$W"; w remote add origin "$T/remote.git"
  seq 1 30 | sed 's/^/line /' > "$W/f.txt"; commit base >/dev/null; push main
  w checkout -qb pr; edit 10 'line 10 CHANGED BY PR'; H1=$(commit pr-change); push pr
  git clone -q "$T/remote.git" "$T/repos/$p"
}
main_edit() { w checkout -q main; edit "$1" "$2"; commit "main $1" >/dev/null; push main; w checkout -q pr; }
merge_main() { w merge -q --no-edit main >/dev/null 2>&1; H2=$(w rev-parse HEAD); push pr; }
rows() { printf '{"rows":[%s],"truncated":false}\n' "$1" > "$ROWS"; }
row() { printf '{"id":%s,"source":"%s","head_sha":"%s","verdict":"%s","note":"%s","retracted_at":%s}' \
          "$1" "$2" "$3" "$4" "${5:-}" "${6:-null}"; }
nposts() { grep -c . "$POSTS"; }
ngets() { grep -c '^req GET /api/verdicts?repo=' "$CALLS"; }
# run <slug> <pr> <head> — lg_run in a fresh process (the gates load once a process)
run() { ( . "$H/bin/lib/lead-gates.sh" || exit 3; lg_run "$1" "$2" "$3" ); }

# ============================================================================
# M1 — a clean merge of main after a lead MERGE: carried at once
# ============================================================================
fixture; main_edit 13 'line 13 EDITED ON MAIN'; merge_main
rows "$(row 5 lead "$H1" MERGE)"
run "$SLUG" 101 "$H2"; rc=$?
[ "$rc" = 12 ] && ok || bad "M1: lg_run on the merged head must be rc 12 (carried, no review, no CI wait), got $rc (log: $(cat "$GLOG"))"
want="post $SLUG 101 $H2 MERGE --source lead --reviewer box:testbox --note lead-replay:${H1:0:12} how:main-merge ref:#5 by:lead-review carried_from:#5 reason:merge-carry:${H2:0:12} --review-mode full"
[ "$(cat "$POSTS")" = "$want" ] && ok || bad "M1: want one post '$want', got '$(cat "$POSTS")'"
grep -q "lead MERGE carried from ${H1:0:12} (how:main-merge); no review, no CI wait" "$GLOG" \
  && ok || bad "M1: the gate's carried line is missing (log: $(cat "$GLOG"))"
grep -q "LEAD_CARRY carried from=${H1:0:12} to=${H2:0:12} word=MERGE ref=#5 how=main-merge" "$GLOG" \
  && ok || bad "M1: the LEAD_CARRY carried line is missing (log: $(cat "$GLOG"))"
grep -q "held" "$GLOG" && bad "M1: no hold may be logged (log: $(cat "$GLOG"))" || ok
grep -qP "^[0-9]+\tleadcarry-carried $SLUG#101 $H2\$" "$LEDGER" && ok || bad "M1: the ledger line 'leadcarry-carried' is missing ($(cat "$LEDGER" 2>/dev/null))"
grep -q '^la ' "$CALLS" && ok || bad "M1: a MERGE carry must ask la_decide first ($(cat "$CALLS"))"
(
  . "$H/bin/lib/lead-gates.sh" || exit 3
  _lgt_load || exit 3
  LGB_KEY="$SLUG#101@$H2"; LGB_APPROVED=0; LGB_REBOUND=0; LGB_CARRIED=0
  lg_gate_replay_delta "$SLUG" 101 "$H2"
); rc=$?
[ "$rc" = 12 ] && grep -q 'already replayed onto this head' "$GLOG" && [ "$(nposts)" = 1 ] \
  && ok || bad "M1: gate 50 must read the carried row as already replayed (rc $rc, posts $(nposts), log: $(cat "$GLOG"))"
# bin/lead-verdict.sh show (the real one) over a fixed GET answer: the carried row.
mkdir -p "$T/showbin" "$T/sh"
cat > "$T/showbin/curl" <<EOF
#!/bin/bash
URL="\${!#}"
case "\$URL" in */api/verdicts\?*) printf '%s\n200\n' "\$(cat "$T/answer.json")" ;; *) printf '{"error":"not found"}\n404\n' ;; esac
EOF
chmod +x "$T/showbin/curl"
jq -c --arg h "$H2" '{head: $h, standing: ([.rows[] | select(.head_sha == $h)] | last), rows: []}' "$ROWS" > "$T/answer.json"
out=$( export PATH="$T/showbin:$PATH" HARNESS="$T/sh" HARNESS_SECRET=s JOBS_URL=https://jobs.test
       bash "$SRC/bin/lead-verdict.sh" show "$SLUG" 101 "$H2" 2>"$T/show.err" ); rc=$?
[ "$rc" = 0 ] && grep -qxF "standing on ${H2:0:12}: MERGE (lead, #6, carried from #5)" <<<"$out" \
  && ok || bad "M1: show must print the carried row (rc $rc): $out $(cat "$T/show.err")"

# ============================================================================
# M10 — a second tick on the same H2: rc 12 from the ledger, no second post
# ============================================================================
: > "$CALLS"
run "$SLUG" 101 "$H2"; rc=$?
[ "$rc" = 12 ] && [ "$(nposts)" = 1 ] && [ "$(ngets)" = 0 ] \
  && ok || bad "M10: the second tick must be rc 12 with no read and no second post (rc $rc, posts $(nposts), calls: $(cat "$CALLS"))"

# ============================================================================
# M2 — main and the PR change line 10; the merge is resolved by hand
# ============================================================================
fixture; main_edit 10 'line 10 MAIN SIDE'
w merge -q --no-edit main >/dev/null 2>&1; edit 10 'line 10 RESOLVED BY HAND'; w add -A; w commit -qm resolved --no-edit
H2=$(w rev-parse HEAD); push pr
rows "$(row 5 lead "$H1" MERGE)"
run "$SLUG" 102 "$H2"; rc=$?
[ "$rc" = 11 ] && [ "$(nposts)" = 0 ] && grep -q "LEAD_CARRY refused" "$GLOG" \
  && ok || bad "M2: a hand-resolved merge must post nothing and gate 10 holds (rc $rc, posts: $(cat "$POSTS"), log: $(cat "$GLOG"))"
grep -q "CI not known green" "$GLOG" && ok || bad "M2: gate 10 must still run (log: $(cat "$GLOG"))"

# M2b — an evil merge: no conflict, but the merge commit changes a PR line.
fixture; main_edit 20 'line 20 MAIN SIDE'
w merge -q --no-commit main >/dev/null 2>&1; edit 10 'line 10 SNUCK INTO THE MERGE'; w add -A; w commit -qm evil --no-edit
H2=$(w rev-parse HEAD); push pr
rows "$(row 5 lead "$H1" MERGE)"
run "$SLUG" 112 "$H2"; rc=$?
[ "$(nposts)" = 0 ] && ok || bad "M2b: an evil merge must post nothing (rc $rc, posts: $(cat "$POSTS"))"

# ============================================================================
# M3 — a new commit changes a PR line
# ============================================================================
fixture; edit 11 'line 11 FIX ROUND'; H2=$(commit fix); push pr
rows "$(row 5 lead "$H1" MERGE)"
run "$SLUG" 103 "$H2"; rc=$?
[ "$(nposts)" = 0 ] && grep -q "LEAD_CARRY refused" "$GLOG" && ok || bad "M3: a new commit must post nothing (rc $rc, posts: $(cat "$POSTS"))"

# ============================================================================
# M4 — a new commit, then a clean main merge
# ============================================================================
fixture; edit 11 'line 11 FIX ROUND'; commit fix >/dev/null; main_edit 20 'line 20 MAIN SIDE'; merge_main
rows "$(row 5 lead "$H1" MERGE)"
run "$SLUG" 104 "$H2"; rc=$?
[ "$(nposts)" = 0 ] && ok || bad "M4: a new commit plus a merge must post nothing (rc $rc, posts: $(cat "$POSTS"))"

# ============================================================================
# M5 — the newest lead row on H1 is a BLOCK: BLOCK is carried, never MERGE
# ============================================================================
fixture; main_edit 13 'line 13 EDITED ON MAIN'; merge_main
rows "$(row 5 lead "$H1" MERGE),$(row 6 lead "$H1" BLOCK)"
run "$SLUG" 105 "$H2"; rc=$?
want="post $SLUG 105 $H2 BLOCK --source lead --reviewer box:testbox --note lead-replay:${H1:0:12} how:main-merge ref:#6 by:lead-review carried_from:#6 reason:merge-carry:${H2:0:12} --review-mode full"
[ "$rc" = 12 ] && [ "$(cat "$POSTS")" = "$want" ] && ok || bad "M5: want rc 12 and '$want', got rc $rc and '$(cat "$POSTS")'"
grep -q ' MERGE ' "$POSTS" && bad "M5: a BLOCK source must never post MERGE ($(cat "$POSTS"))" || ok
grep -q '^la ' "$CALLS" && bad "M5: a BLOCK carry does not ask la_decide ($(cat "$CALLS"))" || ok

# ============================================================================
# M6 — a byte-exact rebase: left to the existing paths
# ============================================================================
fixture; w checkout -q main; printf 'x\n' > "$W/o.txt"; commit other >/dev/null; push main; w checkout -q pr
w rebase -q main; H2=$(w rev-parse HEAD); push pr
rows "$(row 5 lead "$H1" MERGE)"
run "$SLUG" 106 "$H2"; rc=$?
[ "$(nposts)" = 0 ] && grep -q 'not a pure merge of main (how:patch-id)' "$GLOG" && grep -q "CI not known green" "$GLOG" \
  && ok || bad "M6: a rebase must post nothing, log the reason and go on to gate 10 (rc $rc, log: $(cat "$GLOG"))"

# ============================================================================
# M7 — a human MERGE row already stands on H2
# ============================================================================
fixture; main_edit 13 'line 13 EDITED ON MAIN'; merge_main
rows "$(row 5 lead "$H1" BLOCK),$(row 6 human "$H2" MERGE)"
run "$SLUG" 107 "$H2"; rc=$?
[ "$(nposts)" = 0 ] && grep -q 'a verdict already stands on this head' "$GLOG" \
  && ok || bad "M7: a human row on H2 must post nothing (rc $rc, posts: $(cat "$POSTS"), log: $(cat "$GLOG"))"

# ============================================================================
# M8 — the knob is 0: nothing read, nothing posted
# ============================================================================
fixture; main_edit 13 'line 13 EDITED ON MAIN'; merge_main
rows "$(row 5 lead "$H1" MERGE)"
( export LEAD_REVIEW_MERGE_CARRY=0; run "$SLUG" 108 "$H2" ); rc=$?
[ "$rc" = 11 ] && [ "$(nposts)" = 0 ] && [ "$(ngets)" = 0 ] \
  && ok || bad "M8: knob 0 must read and post nothing (rc $rc, posts $(nposts), calls: $(cat "$CALLS"))"

# ============================================================================
# M9 — a truncated history: held, no terminal mark, read again next tick
# ============================================================================
fixture; main_edit 13 'line 13 EDITED ON MAIN'; merge_main
printf '{"rows":[%s],"truncated":true}\n' "$(row 5 lead "$H1" MERGE)" > "$ROWS"
run "$SLUG" 109 "$H2"; rc=$?
[ "$(nposts)" = 0 ] && ! grep -qP "\tleadcarry $SLUG#109 " "$LEDGER" && ok \
  || bad "M9: a truncated history must post nothing and write no terminal mark (rc $rc, ledger: $(cat "$LEDGER"))"
run "$SLUG" 109 "$H2" >/dev/null 2>&1
[ "$(ngets)" = 2 ] && ok || bad "M9: the next tick must read the history again (calls: $(cat "$CALLS"))"
rows "$(row 5 lead "$H1" MERGE)"
run "$SLUG" 109 "$H2"; rc=$?
[ "$rc" = 12 ] && [ "$(nposts)" = 1 ] && ok || bad "M9: once readable, the head is carried (rc $rc, posts: $(cat "$POSTS"))"

# M9b — the post fails: no carried mark, the chain goes on
fixture; main_edit 13 'line 13 EDITED ON MAIN'; merge_main
rows "$(row 5 lead "$H1" MERGE)"; POSTRC=7
run "$SLUG" 119 "$H2"; rc=$?
[ "$rc" = 11 ] && ! grep -q "leadcarry-carried $SLUG#119 " "$LEDGER" && grep -q 'LEAD_CARRY refused .*reason=post rc 7' "$GLOG" \
  && ok || bad "M9b: a failed post must not mark carried (rc $rc, log: $(cat "$GLOG"))"
POSTRC=0

# ============================================================================
# M11 — the newest lead BLOCK is retracted: MERGE carried from #5
# ============================================================================
fixture; main_edit 13 'line 13 EDITED ON MAIN'; merge_main
rows "$(row 5 lead "$H1" MERGE | jq -c '. + {review_mode: "intent"}'),$(row 6 lead "$H1" BLOCK "" '"2026-10-28T10:00:00Z"')"
run "$SLUG" 111 "$H2"; rc=$?
[ "$rc" = 12 ] && grep -q "^post $SLUG 111 $H2 MERGE .* ref:#5 .* --review-mode intent\$" "$POSTS" \
  && ok || bad "M11: a retracted BLOCK is absent; MERGE #5 is carried with its mode intent (rc $rc, posts: $(cat "$POSTS"))"

# ============================================================================
# M12 — the conductor's default mode is unchanged
# ============================================================================
fixture; main_edit 13 'line 13 EDITED ON MAIN'; merge_main
rows "$(row 5 lead "$H1" MERGE),$(row 6 lead "$H1" BLOCK)"
m12() {
  ( mc_log() { echo "$*" >> "$GLOG"; }
    mc_attempt_has() { grep -qxF "$1" "$T/m12-att" 2>/dev/null; }
    mc_attempt_put() { echo "$1" >> "$T/m12-att"; }
    . "$H/bin/lib/verdicts.sh"; . "$H/bin/lib/patch-same.sh"; . "$SRC/bin/lib/lead-carry.sh" || exit 3
    ACTIONS=1 lead_carry "$1" "$SLUG" 120 "$H2" )
}
rm -f "$T/m12-att"; m12 K1; rc=$?
[ "$rc" = 1 ] && [ "$(nposts)" = 0 ] && grep -q 'LEAD_CARRY refused .*reason=newest lead verdict is a BLOCK' "$GLOG" \
  && ok || bad "M12: the default mode must refuse a BLOCK (rc $rc, log: $(cat "$GLOG"))"
rows "$(row 5 lead "$H1" MERGE)"; rm -f "$T/m12-att"; m12 K2; rc=$?
want="post $SLUG 120 $H2 MERGE --source lead --reviewer box:testbox --note lead-replay:${H1:0:12} how:main-merge ref:#5 by:merge-conductor"
[ "$rc" = 0 ] && [ "$(cat "$POSTS")" = "$want" ] && ok || bad "M12: want today's note '$want', got rc $rc '$(cat "$POSTS")'"

# ============================================================================
# M13 — a clean merge of a branch that is not main
# ============================================================================
fixture; w checkout -q -b side main; printf 'side\n' > "$W/side.txt"; commit side >/dev/null; w checkout -q pr
w merge -q --no-edit side >/dev/null 2>&1; H2=$(w rev-parse HEAD); push pr
rows "$(row 5 lead "$H1" MERGE)"
run "$SLUG" 113 "$H2"; rc=$?
[ "$(nposts)" = 0 ] && ok || bad "M13: a merge of a non-main branch must post nothing (rc $rc, posts: $(cat "$POSTS"))"

# ============================================================================
# M15 — the harness repo: a console-ui/src change with console QA on
# ============================================================================
fixture cromford
w checkout -q main; mkdir -p "$W/console-ui/src"; echo a > "$W/console-ui/src/x.tsx"; commit ui-base >/dev/null; push main
w checkout -q pr; w merge -q --no-edit main >/dev/null 2>&1; push pr
H1=$(w rev-parse HEAD)
echo b > "$W/console-ui/src/x.tsx"; H1=$(commit ui-change); push pr
main_edit 13 'line 13 EDITED ON MAIN'; merge_main
rows "$(row 5 lead "$H1" MERGE)"
run "$HSLUG" 115 "$H2"; rc=$?
[ "$(nposts)" = 0 ] && grep -q 'console QA' "$GLOG" \
  && ok || bad "M15: a console-ui change on the harness repo must post nothing (rc $rc, posts: $(cat "$POSTS"), log: $(cat "$GLOG"))"

# ============================================================================
# M14 — no network across the suite
# ============================================================================
[ ! -s "$T/net-calls" ] && ok || bad "M14: curl or gh was called: $(cat "$T/net-calls")"

# ============================================================================
# M16 — the state sweep trims merge-carry.tsv
# ============================================================================
H16="$T/h16"; ST16="$H16/state/lead-review-enqueue"; mkdir -p "$ST16"
NOWS=$(date +%s)
printf '%s\tleadcarry-carried a#1 old\n%s\tleadcarry-carried a#2 new\n' $((NOWS - 8 * 86400)) $((NOWS - 6 * 86400)) > "$ST16/merge-carry.tsv"
sweep() { ( HARNESS="$H16" LEAD_REVIEW_GATE_STATE_KEEP_DAYS=7; _lgt_log() { echo "$*" >> "$GLOG"; }
            . "$SRC/bin/lib/lead-gates.d/99-state-sweep.sh" || exit 3; lg_tick_state_sweep x ); }
: > "$GLOG"; sweep
[ "$(grep -c . "$ST16/merge-carry.tsv")" = 2 ] && grep -q 'state-sweep: dry-run files=0 rows=1' "$GLOG" \
  && ok || bad "M16: the first run is a dry run that counts 1 row (log: $(cat "$GLOG"))"
touch -d "@$((NOWS - 2 * 86400))" "$H16/state/lead-review-gates/state-sweep.stamp"
: > "$GLOG"; sweep
grep -q 'a#2 new' "$ST16/merge-carry.tsv" && ! grep -q 'a#1 old' "$ST16/merge-carry.tsv" && grep -q 'state-sweep: deleted files=0 rows=1' "$GLOG" \
  && ok || bad "M16: the 8-day row must go and the 6-day row stay ($(cat "$ST16/merge-carry.tsv"); log: $(cat "$GLOG"))"

echo "lead-merge-carry.bh-8705: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
