#!/bin/bash
# tests/lead-verdict-carry-patchid.bh-6291-test.sh — BH-6291: the merge
# conductor carries a lead MERGE across a clean main merge in the same tick.
#
# mc_lead_ready (bin/lib/mc-lead-ready.sh) is the production entry point: the
# conductor calls it on every tick for a head the builder did not approve. When
# no lead row stands on the live head B, it now asks lead_carry
# (bin/lib/lead-carry.sh) to carry the newest lead word from an older head A,
# and only when bin/lib/patch-same.sh proves B carries A's patch.
#
#   C1   one clean main merge                       -> carried, how:main-merge
#   C1b  two clean main merges                      -> carried, how:main-merge
#   C1c  a byte-exact rebase onto a newer main      -> carried, how:patch-id
#   C2   a new commit changes one PR line           -> refused, no post
#   C3   a merge that resolved a conflict by hand   -> refused, no post
#   C4   the newest lead row is a BLOCK             -> refused, no post
#   C5   two ticks                                  -> one post, one line
#   N1   history unreadable, then readable          -> held, then carried
#   N2   MC_LEAD_CARRY=0, and ACTIONS=0             -> nothing read
#   N3   builder BLOCK                              -> nothing read
#   N4   evil merge (clean parents, extra edit)     -> refused
#   N5   gate 50 reads the carried row              -> rc 12 (no second post)
#   N6   the post fails (rc 7)                      -> refused, never carried
#   N7   la_decide rc 1 (protected path)            -> refused, no post
# Real git (a local origin and a hub clone); the verdicts worker, the authority
# and bin/lead-verdict.sh are stubs. Run from anywhere (exit 0 = all pass).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

[ -r "$DIR/bin/lib/lead-carry.sh" ] && ok || bad "setup: bin/lib/lead-carry.sh is missing"
# shellcheck source=bin/lib/mc-lead-ready.sh
. "$DIR/bin/lib/mc-lead-ready.sh" || { echo "FAIL: cannot source bin/lib/mc-lead-ready.sh"; exit 1; }

O="$T/origin"; C="$T/repos/proj"
export ROWS="$T/rows.json" POSTS="$T/posts" POSTRC=0
export REPOS_ROOT="$T/repos" FLEET_CONF="$T/fleet.conf" LEAD_VERDICT_TOKEN_FILE="$T/tok" LEAD_VERDICT_BIN="$T/lead-verdict.sh"
export JOBS_BOX=testbox
printf 'proj o/r\n' > "$FLEET_CONF"
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

# ---- stubs for the readers mc_lead_ready and lead_carry use
CALLS="$T/calls"; ATT="$T/att"; LOG="$T/log"
VDGET_RC=0; LARC=0
_vd_get() { echo "get $2" >> "$CALLS"; [ "$VDGET_RC" = 0 ] || return "$VDGET_RC"; cat "$ROWS"; }
vd_standing() {
  local line
  echo "vd $*" >> "$CALLS"
  line=$(jq -r --arg h "$3" '[.rows[] | select(.head_sha == $h and (.source | IN("lead", "human")))]
    | max_by(.id) // empty | [.verdict, .source, (.id | tostring), "x", "-", "lead"] | @tsv' "$ROWS")
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}
la_scope()  { return 0; }
la_decide() { echo "la $*" >> "$CALLS"; LA_REASON="fixture reason $LARC"; return "$LARC"; }
mc_attempt_has() { grep -qxF "$1" "$ATT" 2>/dev/null; }
mc_attempt_put() { echo "$1" >> "$ATT"; }
mc_log() { echo "$*" >> "$LOG"; }

# ---- git fixture: f.txt has 30 numbered lines; the PR changes line 10 at A
og() { git -C "$O" "$@"; }
edit() { sed -i.bak "${1}s/.*/$2/" "$O/f.txt" && rm -f "$O/f.txt.bak"; }
commit() { og add -A; og commit -qm "$1"; og rev-parse HEAD; }
seed() {
  scratch_rm "$O" 2>/dev/null; scratch_rm "$C" 2>/dev/null
  mkdir -p "$O"; og init -q -b main
  seq 1 30 | sed 's/^/line /' > "$O/f.txt"; printf 'other\n' > "$O/o.txt"
  commit base >/dev/null
  og checkout -qb pr
  edit 10 'line 10 CHANGED BY PR'; A=$(commit pr-change)
  og checkout -q main
}
main_edit() { og checkout -q main; edit "$1" "$2"; commit "main-$1" >/dev/null; }
merge_main() { og checkout -q pr; og merge -q --no-edit main >/dev/null 2>&1; og rev-parse HEAD; }
clone() { mkdir -p "$REPOS_ROOT"; git clone -q "$O" "$C" 2>/dev/null; }

# rows <json rows> — the verdict history the worker serves
rows() { printf '{"rows":[%s],"truncated":false}\n' "$1" > "$ROWS"; }
leadrow() { printf '{"id":%s,"source":"lead","head_sha":"%s","verdict":"%s","note":"%s"}' "$1" "$2" "$3" "${4:-}"; }
reset() { : > "$CALLS"; : > "$ATT"; : > "$LOG"; : > "$POSTS"; VDGET_RC=0; LARC=0; POSTRC=0
          export ACTIONS=1; unset MC_LEAD_CARRY; }
ready() { mc_lead_ready K o/r 31 "$1" - - -; }
nposts() { grep -c . "$POSTS"; }
ncarried() { grep -c 'LEAD_CARRY carried' "$LOG"; }

# ============================================================================
# C1 — one clean main merge: carried, and the tick is an approval on B
# ============================================================================
seed; main_edit 25 'line 25 MAIN'; B=$(merge_main); clone
reset; rows "$(leadrow 7 "$A" MERGE)"
ready "$B"; rc=$?
[ "$rc" = 0 ] && ok || bad "C1: mc_lead_ready must answer rc 0 on the carried head, got $rc (log: $(cat "$LOG"))"
want="post o/r 31 $B MERGE --source lead --reviewer box:testbox --note lead-replay:${A:0:12} how:main-merge ref:#7 by:merge-conductor"
[ "$(cat "$POSTS")" = "$want" ] && ok || bad "C1: post argv: want '$want', got '$(cat "$POSTS")'"
[ "$(grep -c "^K LEAD_CARRY carried from=${A:0:12} to=${B:0:12} word=MERGE ref=#7 how=main-merge patch_old=[0-9a-f]\{12\} patch_new=[0-9a-f]\{12\} reason=.*post rc 0" "$LOG")" = 1 ] \
  && ok || bad "C1: want one LEAD_CARRY carried line with both patch ids and post rc 0, got: $(cat "$LOG")"
grep -qxF "leadcarry K $B" "$ATT" && ok || bad "C1: the terminal attempts line 'leadcarry K <head>' is missing ($(cat "$ATT"))"
grep -q 'LEAD_READY' "$LOG" && ok || bad "C1: the carried row must reach the LEAD_READY approval"

# ============================================================================
# C5 — a second tick on the same head: no second read of history, no post
# ============================================================================
: > "$CALLS"
ready "$B"; rc=$?
[ "$rc" = 0 ] && ok || bad "C5: the second tick must still be rc 0, got $rc"
[ "$(nposts)" = 1 ] && ok || bad "C5: exactly one post across two ticks, got $(nposts)"
[ "$(ncarried)" = 1 ] && ok || bad "C5: exactly one carried line across two ticks, got $(ncarried)"
grep -q '^get ' "$CALLS" && bad "C5: the second tick must not read the history ($(cat "$CALLS"))" || ok

# ============================================================================
# C1b — two clean main merges
# ============================================================================
seed; main_edit 25 'line 25 MAIN'; merge_main >/dev/null; main_edit 28 'line 28 MAIN'; B=$(merge_main); clone
reset; rows "$(leadrow 7 "$A" MERGE-WITH-NOTES)"
ready "$B"; rc=$?
[ "$rc" = 0 ] && grep -q "post o/r 31 $B MERGE-WITH-NOTES .*how:main-merge ref:#7" "$POSTS" \
  && ok || bad "C1b: two clean merges must carry how:main-merge (rc $rc, posts: $(cat "$POSTS"), log: $(cat "$LOG"))"

# ============================================================================
# C1c — a byte-exact rebase of A onto a newer main
# ============================================================================
seed; main_edit 28 'line 28 MAIN'
og checkout -qb rebased main; og cherry-pick "$A" >/dev/null 2>&1; B=$(og rev-parse HEAD); og checkout -q main; clone
reset; rows "$(leadrow 7 "$A" MERGE)"
ready "$B"; rc=$?
[ "$rc" = 0 ] && grep -q "how:patch-id ref:#7" "$POSTS" && grep -q 'LEAD_CARRY carried .*how=patch-id' "$LOG" \
  && ok || bad "C1c: a byte-exact rebase must carry how:patch-id (rc $rc, posts: $(cat "$POSTS"), log: $(cat "$LOG"))"

# ============================================================================
# C2 — a new commit after A changes one PR line
# ============================================================================
seed; og checkout -q pr; edit 11 'line 11 FIX ROUND'; B=$(commit fix); og checkout -q main; clone
reset; rows "$(leadrow 7 "$A" MERGE)"
ready "$B"; rc=$?
[ "$rc" = 1 ] && ok || bad "C2: a changed patch must leave mc_lead_ready rc 1, got $rc"
[ "$(nposts)" = 0 ] && ok || bad "C2: a changed patch must post nothing, got: $(cat "$POSTS")"
[ "$(grep -c "^K LEAD_CARRY refused from=${A:0:12} to=${B:0:12} word=MERGE ref=#7 how=- patch_old=[0-9a-f]\{12\} patch_new=[0-9a-f]\{12\} reason=patch changed" "$LOG")" = 1 ] \
  && ok || bad "C2: want one refused line naming both patch ids, got: $(cat "$LOG")"
grep -qxF "leadcarry K $B" "$ATT" && ok || bad "C2: a refusal is terminal for the head ($(cat "$ATT"))"
: > "$CALLS"; ready "$B" >/dev/null
! grep -q '^get ' "$CALLS" && [ "$(grep -c 'LEAD_CARRY refused' "$LOG")" = 1 ] \
  && ok || bad "C2: the next tick on a refused head must not read history or log again (calls: $(cat "$CALLS"), log: $(cat "$LOG"))"

# ============================================================================
# C3 — main and the PR change line 10; the merge resolves the conflict by hand
# ============================================================================
seed; main_edit 10 'line 10 MAIN SIDE'
og checkout -q pr; og merge -q --no-edit main >/dev/null 2>&1
edit 10 'line 10 RESOLVED BY HAND'; og add -A; og commit -qm resolved --no-edit; B=$(og rev-parse HEAD)
og checkout -q main; clone
reset; rows "$(leadrow 7 "$A" MERGE)"
ready "$B"; rc=$?
[ "$rc" = 1 ] && [ "$(nposts)" = 0 ] && grep -q 'LEAD_CARRY refused .*reason=patch changed' "$LOG" \
  && ok || bad "C3: a hand-resolved conflict must not carry (rc $rc, posts: $(cat "$POSTS"), log: $(cat "$LOG"))"

# ============================================================================
# C4 — the newest lead row on A is a BLOCK, an older MERGE on A0 under it
# ============================================================================
seed; main_edit 25 'line 25 MAIN'; B=$(merge_main); clone
A0=$(og rev-parse main~1)
reset; rows "$(leadrow 5 "$A0" MERGE),$(leadrow 7 "$A" BLOCK)"
ready "$B"; rc=$?
[ "$rc" = 1 ] && ok || bad "C4: a BLOCK source must leave rc 1, got $rc"
[ "$(nposts)" = 0 ] && ok || bad "C4: a BLOCK is never carried, got posts: $(cat "$POSTS")"
[ "$(grep -c "^K LEAD_CARRY refused from=${A:0:12} to=${B:0:12} word=BLOCK ref=#7 .*reason=newest lead verdict is a BLOCK" "$LOG")" = 1 ] \
  && ok || bad "C4: want one refused BLOCK line, got: $(cat "$LOG")"

# ============================================================================
# N1 — history unreadable: held (no mark), then the worker is back: carried
# ============================================================================
seed; main_edit 25 'line 25 MAIN'; B=$(merge_main); clone
reset; rows "$(leadrow 7 "$A" MERGE)"; VDGET_RC=2
ready "$B"; rc=$?
[ "$rc" = 1 ] && [ "$(nposts)" = 0 ] && ok || bad "N1: unreadable history must be rc 1 and no post (rc $rc)"
grep -q 'LEAD_CARRY held' "$LOG" && ok || bad "N1: want a held line, got: $(cat "$LOG")"
grep -qxF "leadcarry K $B" "$ATT" && bad "N1: held must not write the terminal mark" || ok
ready "$B" >/dev/null; [ "$(grep -c 'LEAD_CARRY held' "$LOG")" = 1 ] && ok || bad "N1: the held line is said once per head, got $(grep -c 'LEAD_CARRY held' "$LOG")"
VDGET_RC=0
ready "$B"; rc=$?
[ "$rc" = 0 ] && [ "$(nposts)" = 1 ] && [ "$(ncarried)" = 1 ] && ok || bad "N1: the next readable tick must carry (rc $rc, posts $(nposts), log: $(cat "$LOG"))"

# ============================================================================
# N2 — MC_LEAD_CARRY=0, and a dry-run tick: nothing read, nothing posted
# ============================================================================
reset; rows "$(leadrow 7 "$A" MERGE)"; MC_LEAD_CARRY=0
ready "$B"; rc=$?
[ "$rc" = 1 ] && [ "$(nposts)" = 0 ] && ! grep -q '^get ' "$CALLS" && [ ! -s "$LOG" ] \
  && ok || bad "N2: MC_LEAD_CARRY=0 must read and post nothing (rc $rc, calls: $(cat "$CALLS"), log: $(cat "$LOG"))"
reset; rows "$(leadrow 7 "$A" MERGE)"; ACTIONS=0
ready "$B"; rc=$?
[ "$rc" = 1 ] && [ "$(nposts)" = 0 ] && ! grep -q '^get ' "$CALLS" && [ ! -s "$LOG" ] \
  && ok || bad "N2: ACTIONS=0 must read and post nothing (rc $rc, calls: $(cat "$CALLS"), log: $(cat "$LOG"))"

# ============================================================================
# N3 — a builder BLOCK returns before the carry
# ============================================================================
reset; rows "$(leadrow 7 "$A" MERGE)"
mc_lead_ready K o/r 31 "$B" BLOCK "$A" -; rc=$?
[ "$rc" = 1 ] && [ ! -s "$CALLS" ] && [ "$(nposts)" = 0 ] \
  && ok || bad "N3: a builder BLOCK must read nothing (rc $rc, calls: $(cat "$CALLS"))"

# ============================================================================
# N4 — evil merge: clean parents, an extra edit in a non-PR file
# ============================================================================
seed; main_edit 25 'line 25 MAIN'
og checkout -q pr; og merge -q --no-commit --no-ff main >/dev/null 2>&1
printf 'other\nslipped in\n' > "$O/o.txt"; og add -A; og commit -qm evil --no-edit; B=$(og rev-parse HEAD)
og checkout -q main; clone
reset; rows "$(leadrow 7 "$A" MERGE)"
ready "$B"; rc=$?
[ "$rc" = 1 ] && [ "$(nposts)" = 0 ] && grep -q 'LEAD_CARRY refused .*reason=patch changed' "$LOG" \
  && ok || bad "N4: an evil merge must not carry (rc $rc, posts: $(cat "$POSTS"), log: $(cat "$LOG"))"

# ============================================================================
# N5 — round trip: gate 50 of the lead lane reads the row lead_carry wrote
# ============================================================================
seed; main_edit 25 'line 25 MAIN'; B=$(merge_main); clone
reset; rows "$(leadrow 7 "$A" MERGE)"
ready "$B" >/dev/null
(
  # shellcheck source=bin/lib/lead-gates.d/50-replay-delta.sh
  . "$DIR/bin/lib/lead-gates.d/50-replay-delta.sh" || exit 3
  export HARNESS="$T/h"; mkdir -p "$HARNESS"
  _jobs_req() { [ "$1" = GET ] && cat "$ROWS"; }
  lgs_dir() { mkdir -p "$T/lgs" && printf '%s\n' "$T/lgs"; }
  _lgt_log() { echo "$*" >> "$T/n5.log"; }
  LGB_KEY="o/r#31@$B"; LGB_APPROVED=0; LGB_REBOUND=0
  lg_gate_replay_delta o/r 31 "$B"
); rc=$?
[ "$rc" = 12 ] && ok || bad "N5: gate 50 must read the carried row as already replayed (rc 12), got $rc ($(cat "$T/n5.log" 2>/dev/null))"
[ "$(nposts)" = 1 ] && ok || bad "N5: gate 50 must not post a second row, posts: $(cat "$POSTS")"

# ============================================================================
# N6 — the post fails: refused, never carried
# ============================================================================
reset; rows "$(leadrow 7 "$A" MERGE)"; POSTRC=7
ready "$B"; rc=$?
[ "$rc" = 1 ] && ok || bad "N6: a failed post must leave rc 1, got $rc"
[ "$(ncarried)" = 0 ] && grep -q 'LEAD_CARRY refused .*reason=post rc 7' "$LOG" \
  && ok || bad "N6: want refused with post rc 7 and no carried line, got: $(cat "$LOG")"

# ============================================================================
# N7 — la_decide rc 1: refused before any post
# ============================================================================
reset; rows "$(leadrow 7 "$A" MERGE)"; LARC=1
ready "$B"; rc=$?
[ "$rc" = 1 ] && [ "$(nposts)" = 0 ] && grep -q 'LEAD_CARRY refused .*reason=fixture reason 1' "$LOG" \
  && ok || bad "N7: la_decide rc 1 must refuse before any post (rc $rc, posts: $(cat "$POSTS"), log: $(cat "$LOG"))"

# ============================================================================
# N8 — no fleet.conf root (FLEET_CONF, HARNESS and H all empty): held, never a
#   read of "/fleet.conf" built from an empty root (D43)
# ============================================================================
seed; main_edit 25 'line 25 MAIN'; B=$(merge_main); clone
reset; rows "$(leadrow 7 "$A" MERGE)"
( FLEET_CONF="" HARNESS="" H="" lead_carry K o/r 31 "$B" ); rc=$?   # direct: mc_lead_ready reads H itself
[ "$rc" = 1 ] && [ "$(nposts)" = 0 ] && grep -q 'LEAD_CARRY held .*reason=no fleet.conf' "$LOG" \
  && ok || bad "N8: an empty fleet.conf root must be held with reason 'no fleet.conf' (rc $rc, log: $(cat "$LOG"))"

# ============================================================================
# N9 — no clone for the project: held with its reason (the held call passes all
#   10 log fields; with 9 it died on an unset ${10} under set -u)
# ============================================================================
seed; main_edit 25 'line 25 MAIN'; B=$(merge_main)
reset; rows "$(leadrow 7 "$A" MERGE)"; scratch_rm "$C"
( lead_carry K o/r 31 "$B" ); rc=$?
[ "$rc" = 1 ] && grep -q "LEAD_CARRY held from=${A:0:12} to=${B:0:12} word=MERGE ref=#7 .*reason=no clone for o/r" "$LOG" \
  && ok || bad "N9: no clone must be one held line naming the source (rc $rc, log: $(cat "$LOG"))"
grep -qxF "leadcarry K $B" "$ATT" && bad "N9: held must not write the terminal mark" || ok
# N10 — la_decide undecidable (rc 2): held, no post
clone; reset; rows "$(leadrow 7 "$A" MERGE)"; LARC=2
( lead_carry K o/r 31 "$B" ); rc=$?
[ "$rc" = 1 ] && [ "$(nposts)" = 0 ] && grep -q "LEAD_CARRY held from=${A:0:12} .*reason=la_decide rc 2" "$LOG" \
  && ok || bad "N10: la_decide rc 2 must be one held line, no post (rc $rc, posts: $(cat "$POSTS"), log: $(cat "$LOG"))"
LARC=0

echo "lead-verdict-carry-patchid: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
