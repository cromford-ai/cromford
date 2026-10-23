#!/bin/bash
# tests/lead-carry-rebind.bh-8028-test.sh — BH-8028: the conductor's patch-id
# REBOUND carries the lead verdict onto the rebased head.
#
# rebind_patch_id (bin/lib/mc/settle.sh) is the production entry point: the
# conductor calls it when an approved PR's head moved. It moved the builder
# approval and REVIEWED to the new head B, so mc_lead_ready's gate 3 returned
# before its lead_carry call, and nothing stood on B for the lead lane: a
# second paid lead review on the same patch. Now the rebind calls lead_carry
# (bin/lib/lead-carry.sh) itself, with a reason.
#
#   R1   byte-exact rebase (same patch-id)            -> one carried row on B
#   R2   a new commit changes one PR line             -> rc 1, no post
#   R3   a main merge that resolved a conflict        -> rc 1, no post
#   R4   a clean main merge (same:main-merge arm)     -> rc 0, reason:same:main-merge
#   R5   the newest lead row is a BLOCK               -> rc 0, refused, no post
#   R6   two ticks on the same B                      -> one post; gate 50 reads it
#   R7   a reason with a space                        -> rc 1, no post
#   R8   MC_LEAD_CARRY=0                              -> rc 0, history not read
#   R9   the post fails (rc 7)                        -> rc 0, refused
#   R10  no lead row at all                           -> rc 0, no post, no line
#   S1-S4  bin/lead-verdict.sh show names the carried source verdict
# Real git (a bare remote, the hub clone under MC_REPOS, the real conductor
# lib); the verdicts worker, the authority and bin/lead-verdict.sh post are
# stubs. Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
export HARNESS="$T/h" MC_REPOS="$T/repos" REPOS_ROOT="$T/repos"
mkdir -p "$T/h/config" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/repos"
cp "$DIR/config/generated-paths.conf" "$T/h/config/" 2>/dev/null || true
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh" || { echo "FAIL: cannot source bin/lib/merge-conductor-lib.sh"; exit 1; }
mc_init
MCLOG="$T/h/logs/merge-conductor.log"
SLUG=example-org/demo-os

export ROWS="$T/rows.json" POSTS="$T/posts" POSTRC=0
export FLEET_CONF="$T/fleet.conf" LEAD_VERDICT_TOKEN_FILE="$T/tok" LEAD_VERDICT_BIN="$T/lead-verdict.sh" JOBS_BOX=testbox
printf 'demo-os %s\n' "$SLUG" > "$FLEET_CONF"
printf 'tok-fixture-1\n' > "$LEAD_VERDICT_TOKEN_FILE"

# The bin/lead-verdict.sh stub: records its argv, appends the lead row it was
# asked to post (the worker's recordLeadVerdict, in the shape the GET returns).
cat > "$LEAD_VERDICT_BIN" <<'EOF'
#!/bin/bash
echo "$*" >> "$POSTS"
[ "$POSTRC" = 0 ] || { echo "post refused (fixture)"; exit "$POSTRC"; }
note=""; prev=""
for a in "$@"; do [ "$prev" = --note ] && note="$a"; prev="$a"; done
jq --arg h "$4" --arg v "$5" --arg n "$note" \
  '.rows += [{id: ((.rows | map(.id) | max // 0) + 1), source: "lead", head_sha: $h, verdict: $v, note: $n}]' \
  "$ROWS" > "$ROWS.tmp" && mv "$ROWS.tmp" "$ROWS"
exit 0
EOF
chmod +x "$LEAD_VERDICT_BIN"

# ---- the seams: the remote is a local bare repo; the ledger, the verdicts
# history and the authority are recorded stubs.
CALLS="$T/calls"
mc_git_auth() { MC_REMOTE="$T/remote.git"; return 0; }
mc_git_auth_clear() { :; }
job_verdict_rebind() { printf '%s %s\n' "$1" "$2" >> "$T/rebinds"; return 0; }
_vd_get() { echo "get $2" >> "$CALLS"; cat "$ROWS"; }
la_decide() { echo "la $*" >> "$CALLS"; return 0; }

W="$T/work"
w() { git -C "$W" "$@"; }
edit() { sed -i.bak "${1}s/.*/$2/" "$W/f.txt" && rm -f "$W/f.txt.bak"; }
commit() { w add -A; w commit -qm "$1"; w rev-parse HEAD; }
push() { w push -q -f origin "$@" >/dev/null 2>&1; }

# fixture — a remote with main and a PR branch whose one commit (line 10) is
# the reviewed head R; the hub clone under MC_REPOS; a fresh record dir, log,
# attempts state and post record.
fixture() {
  scratch_rm "$T/remote.git" 2>/dev/null; scratch_rm "$W" 2>/dev/null; scratch_rm "$T/repos/demo-os" 2>/dev/null
  scratch_rm "$T/rec" 2>/dev/null; rm -f "$T/h/state/merge-conductor/attempts.txt"
  rm -f "$T/rebinds"; : > "$MCLOG"; : > "$POSTS"; : > "$CALLS"; POSTRC=0
  export ACTIONS=1; unset MC_LEAD_CARRY
  git init -q --bare -b main "$T/remote.git"
  git init -q -b main "$W"; w remote add origin "$T/remote.git"
  seq 1 30 | sed 's/^/line /' > "$W/f.txt"; commit base >/dev/null; push main
  w checkout -qb pr; edit 10 'line 10 CHANGED BY PR'; R=$(commit pr-change); push pr
  git clone -q "$T/remote.git" "$T/repos/demo-os"
  mkdir -p "$T/rec"; echo "$R" > "$T/rec/reviewed-sha"
}
main_edit() { w checkout -q main; edit "$1" "$2"; commit "main $1" >/dev/null; push main; w checkout -q pr; }
rebase_pr() { w checkout -q main; printf 'x\n' > "$W/o.txt"; commit other >/dev/null; push main; w checkout -q pr
              w rebase -q main; w rev-parse HEAD; push pr; }
rebind() { rebind_patch_id "demo-os#31" demo-os "$SLUG" 31 "https://github.com/$SLUG/pull/31" "$T/rec" "$R" "$1"; }
rows() { printf '{"rows":[%s],"truncated":false}\n' "$1" > "$ROWS"; }
leadrow() { printf '{"id":%s,"source":"lead","head_sha":"%s","verdict":"%s","note":"%s"}' "$1" "$2" "$3" "${4:-}"; }
nposts() { grep -c . "$POSTS"; }
pid_of() { sed -n 's/.*REBOUND .*: patch-id \([0-9a-f]*\) unchanged.*/\1/p' "$MCLOG" | tail -1; }

# ============================================================================
# R1 — a byte-exact rebase: the REBOUND carries lead MERGE #7 onto B
# ============================================================================
fixture; B=$(rebase_pr)
rows "$(leadrow 7 "$R" MERGE)"
rebind "$B"; rc=$?
[ "$rc" = 0 ] && ok || bad "R1: rebind_patch_id must stay rc 0, got $rc (log: $(cat "$MCLOG"))"
PID=$(pid_of)
[ -n "$PID" ] && ok || bad "R1: setup: the rebind must take the patch-id arm (log: $(cat "$MCLOG"))"
want="post $SLUG 31 $B MERGE --source lead --reviewer box:testbox --note lead-replay:${R:0:12} how:patch-id ref:#7 by:merge-conductor carried_from:#7 reason:patch-id:$PID"
[ "$(cat "$POSTS")" = "$want" ] && ok || bad "R1: no lead post after REBOUND, or the wrong one: want '$want', got '$(cat "$POSTS")'"
[ "$(grep -c "Z demo-os#31 LEAD_CARRY carried from=${R:0:12} to=${B:0:12} word=MERGE ref=#7 how=patch-id" "$MCLOG")" = 1 ] \
  && ok || bad "R1: want one LEAD_CARRY carried line, got: $(cat "$MCLOG")"
lr=$(grep -n 'REBOUND' "$MCLOG" | head -1 | cut -d: -f1); lc=$(grep -n 'LEAD_CARRY carried' "$MCLOG" | head -1 | cut -d: -f1)
[ -n "$lr" ] && [ -n "$lc" ] && [ "$lr" -lt "$lc" ] && ok || bad "R1: the REBOUND line must come before the LEAD_CARRY line (log: $(cat "$MCLOG"))"
[ "$(cat "$T/rec/reviewed-sha")" = "$B" ] && ok || bad "R1: the builder approval must still move to B"
jq -e --arg h "$B" '[.rows[] | select(.head_sha == $h and .source == "lead" and .verdict == "MERGE")] | length == 1' "$ROWS" >/dev/null \
  && ok || bad "R1: one lead MERGE row must stand on B: $(cat "$ROWS")"

# ============================================================================
# R6 — a second tick on the same B: no second post; gate 50 sees the row
# ============================================================================
: > "$CALLS"
rebind "$B"; rc=$?
[ "$rc" = 0 ] && [ "$(nposts)" = 1 ] && ok || bad "R6: the second tick must be rc 0 with still one post (rc $rc, posts: $(cat "$POSTS"))"
mc_attempt_has "leadcarry demo-os#31 $B" && ok || bad "R6: the terminal attempts line 'leadcarry <key> <B>' is missing"
grep -q '^get ' "$CALLS" && bad "R6: the second tick must not read the history ($(cat "$CALLS"))" || ok
(
  # shellcheck source=bin/lib/lead-gates.d/50-replay-delta.sh
  . "$DIR/bin/lib/lead-gates.d/50-replay-delta.sh" || exit 3
  # shellcheck source=bin/lib/patch-same.sh
  command -v patch_same >/dev/null 2>&1 || . "$DIR/bin/lib/patch-same.sh" || exit 3
  _jobs_req() { [ "$1" = GET ] && cat "$ROWS"; }
  lgs_dir() { mkdir -p "$T/lgs" && printf '%s\n' "$T/lgs"; }
  _lgt_log() { echo "$*" >> "$T/r6.log"; }
  LGB_KEY="$SLUG#31@$B"; LGB_APPROVED=0; LGB_REBOUND=0
  lg_gate_replay_delta "$SLUG" 31 "$B"
); rc=$?
[ "$rc" = 12 ] && ok || bad "R6: gate 50 must read the carried row as already replayed (rc 12), got $rc ($(cat "$T/r6.log" 2>/dev/null))"
[ "$(nposts)" = 1 ] && ok || bad "R6: gate 50 must not post a second row, posts: $(cat "$POSTS")"

# ============================================================================
# R2 — a new commit changes one PR line: the patch-id changed, nothing carried
# ============================================================================
fixture; edit 11 'line 11 FIX ROUND'; B=$(commit fix); push pr
rows "$(leadrow 7 "$R" MERGE)"
rebind "$B"; rc=$?
[ "$rc" = 1 ] && [ "$(nposts)" = 0 ] && ! grep -q 'LEAD_CARRY carried' "$MCLOG" \
  && ok || bad "R2: a changed patch-id must be rc 1 with no post (rc $rc, posts: $(cat "$POSTS"), log: $(cat "$MCLOG"))"

# ============================================================================
# R3 — main and the PR change line 10; the main merge is resolved by hand
# ============================================================================
fixture; main_edit 10 'line 10 MAIN SIDE'
w merge -q --no-edit main >/dev/null 2>&1; edit 10 'line 10 RESOLVED BY HAND'; w add -A; w commit -qm resolved --no-edit
B=$(w rev-parse HEAD); push pr
rows "$(leadrow 7 "$R" MERGE)"
rebind "$B"; rc=$?
[ "$rc" = 1 ] && [ "$(nposts)" = 0 ] && ok || bad "R3: a hand-resolved merge must be rc 1 with no post (rc $rc, posts: $(cat "$POSTS"))"

# ============================================================================
# R4 — a clean main merge next to the hunk: the same:main-merge arm carries
# ============================================================================
fixture; main_edit 13 'line 13 EDITED ON MAIN'
w merge -q --no-edit main >/dev/null 2>&1; B=$(w rev-parse HEAD); push pr
rows "$(leadrow 7 "$R" MERGE-WITH-NOTES)"
rebind "$B"; rc=$?
[ "$rc" = 0 ] && grep -q "REBOUND .*own commits unchanged (main-merge" "$MCLOG" && ok \
  || bad "R4: setup: the rebind must take the same:main-merge arm (rc $rc, log: $(cat "$MCLOG"))"
want="post $SLUG 31 $B MERGE-WITH-NOTES --source lead --reviewer box:testbox --note lead-replay:${R:0:12} how:main-merge ref:#7 by:merge-conductor carried_from:#7 reason:same:main-merge"
[ "$(cat "$POSTS")" = "$want" ] && ok || bad "R4: want '$want', got '$(cat "$POSTS")'"

# ============================================================================
# R5 — the newest lead row is a BLOCK: the approval still rebinds, no carry
# ============================================================================
fixture; B=$(rebase_pr)
rows "$(leadrow 5 "$R" MERGE),$(leadrow 7 "$R" BLOCK)"
rebind "$B"; rc=$?
[ "$rc" = 0 ] && [ "$(nposts)" = 0 ] && grep -q 'LEAD_CARRY refused .*reason=newest lead verdict is a BLOCK' "$MCLOG" \
  && ok || bad "R5: a BLOCK must not carry and the rebind stays rc 0 (rc $rc, posts: $(cat "$POSTS"), log: $(cat "$MCLOG"))"

# ============================================================================
# R7 — a reason with whitespace is refused: no post
# ============================================================================
fixture; B=$(rebase_pr)
rows "$(leadrow 7 "$R" MERGE)"
command -v lead_carry >/dev/null 2>&1 || . "$DIR/bin/lib/lead-carry.sh"
( lead_carry K "$SLUG" 31 "$B" "patch-id:x y" ); rc=$?
[ "$rc" = 1 ] && [ "$(nposts)" = 0 ] && ok || bad "R7: a reason with a space must be rc 1 and post nothing (rc $rc, posts: $(cat "$POSTS"))"
( lead_carry K2 "$SLUG" 31 "$B" "$(printf 'patch-id:x\ty')" ); rc=$?
[ "$rc" = 1 ] && [ "$(nposts)" = 0 ] && ok || bad "R7: a reason with a tab must be rc 1 and post nothing (rc $rc, posts: $(cat "$POSTS"))"

# ============================================================================
# R8 — MC_LEAD_CARRY=0: the rebind still rc 0, history not read
# ============================================================================
fixture; B=$(rebase_pr)
rows "$(leadrow 7 "$R" MERGE)"; export MC_LEAD_CARRY=0
rebind "$B"; rc=$?
[ "$rc" = 0 ] && [ "$(nposts)" = 0 ] && ! grep -q '^get ' "$CALLS" && ! grep -q LEAD_CARRY "$MCLOG" \
  && ok || bad "R8: MC_LEAD_CARRY=0 must read and post nothing (rc $rc, calls: $(cat "$CALLS"), log: $(cat "$MCLOG"))"
unset MC_LEAD_CARRY

# ============================================================================
# R9 — the post fails: the rebind still rc 0, refused, never carried
# ============================================================================
fixture; B=$(rebase_pr)
rows "$(leadrow 7 "$R" MERGE)"; POSTRC=7
rebind "$B"; rc=$?
[ "$rc" = 0 ] && ! grep -q 'LEAD_CARRY carried' "$MCLOG" && grep -q 'LEAD_CARRY refused .*reason=post rc 7' "$MCLOG" \
  && ok || bad "R9: a failed post must be refused, rebind rc 0 (rc $rc, log: $(cat "$MCLOG"))"
POSTRC=0

# ============================================================================
# R10 — a builder-only PR (no lead row): rc 0, no post, no LEAD_CARRY line
# ============================================================================
fixture; B=$(rebase_pr)
rows ""
rebind "$B"; rc=$?
[ "$rc" = 0 ] && [ "$(nposts)" = 0 ] && ! grep -q LEAD_CARRY "$MCLOG" \
  && ok || bad "R10: no lead row must post nothing and log no LEAD_CARRY line (rc $rc, log: $(cat "$MCLOG"))"

# ============================================================================
# S — bin/lead-verdict.sh show, through a fake curl over a fixed GET answer
# ============================================================================
SB=bbbbbbbb22222222222222222222222222222222
SA=aaaaaaaa11111111111111111111111111111111
mkdir -p "$T/fakebin" "$T/sh"
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"
case "\$URL" in */api/verdicts\?*) printf '%s\n200\n' "\$(cat "$T/answer.json")" ;; *) printf '{"error":"not found"}\n404\n' ;; esac
EOF
chmod +x "$T/fakebin/curl"
answer() { jq -nc --arg h "$SB" --argjson s "$1" '{head: $h, standing: $s, rows: []}' > "$T/answer.json"; }
show() { ( export PATH="$T/fakebin:$PATH" HARNESS="$T/sh" HARNESS_SECRET=s JOBS_URL=https://jobs.test TMPDIR="$T"
           bash "$DIR/bin/lead-verdict.sh" show o/r 31 "$SB" ) 2>"$T/show.err"; }
srow() { jq -nc --arg h "$SB" --argjson id "$1" --arg n "$2" '{id: $id, head_sha: $h, verdict: "MERGE", source: "lead", note: $n}'; }

answer "$(srow 8 "lead-replay:${SA:0:12} how:patch-id ref:#7 by:merge-conductor carried_from:#7 reason:patch-id:abc")"
out=$(show); rc=$?
[ "$rc" = 0 ] && grep -qxF "standing on ${SB:0:12}: MERGE (lead, #8, carried from #7)" <<<"$out" \
  && ok || bad "S1: show must name the carried source verdict (rc $rc): $out $(cat "$T/show.err")"
answer "$(srow 8 "two blockers fixed")"
out=$(show)
grep -qxF "standing on ${SB:0:12}: MERGE (lead, #8)" <<<"$out" && ok || bad "S2: a plain row prints no 'carried from': $out"
answer "$(srow 8 "lead-replay:${SA:0:12} how:patch-id")"
out=$(show)
grep -qxF "standing on ${SB:0:12}: MERGE (lead, #8, carried from ${SA:0:12})" <<<"$out" && ok || bad "S3: a gate-50 replay prints the source head: $out"
answer "$(srow 8 "lead-replay:${SA:0:12} how:patch-id ref:#7 by:merge-conductor carried_from:#5 reason:x")"
out=$(show)
grep -qxF "standing on ${SB:0:12}: MERGE (lead, #8, carried from #5)" <<<"$out" && ok || bad "S4: carried_from wins over ref: $out"
answer null
out=$(show)
grep -qxF "standing on ${SB:0:12}: none" <<<"$out" && ok || bad "S5 (R2 Acceptance 2): no row on B prints none: $out"

echo "lead-carry-rebind.bh-8028: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
