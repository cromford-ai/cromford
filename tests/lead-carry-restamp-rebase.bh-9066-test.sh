#!/bin/bash
# tests/lead-carry-restamp-rebase.bh-9066-test.sh — BH-9066 (slice C0): the
# merge conductor carries a lead MERGE across a schema restamp AFTER A REBASE.
# The lead's head A is not an ancestor of the new head B, so restamp_same
# (BH-6842) refuses it; lead_carry now asks patch_same_restamp
# (bin/lib/patch-same.sh) after it.
#
# mc_lead_ready (bin/lib/mc-lead-ready.sh) is the production entry point.
#   K1  lead MERGE on A; B = A rebased onto a newer main, then restamped
#       -> carried, one post with note `lead-replay:<A12> how:restamp-rebase`
#   K2  the same plus one changed code line -> refused, no post
#   K3  lead_carry in merge-only mode (LC_MERGE_ONLY=1, BH-8705) on the K1
#       shape -> refused: only a pure merge of main carries there
#   M1  mutation: lead_carry without the patch_same_restamp ask -> K1 refused
# Real git; the verdicts worker, the authority and bin/lead-verdict.sh are
# stubs, as in tests/lead-carry-restamp.bh-6842-test.sh.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

[ -r "$DIR/bin/lib/schema-restamp.sh" ] && ok || bad "setup: bin/lib/schema-restamp.sh is missing"
# shellcheck source=bin/lib/mc-lead-ready.sh
. "$DIR/bin/lib/mc-lead-ready.sh" || { echo "FAIL: cannot source bin/lib/mc-lead-ready.sh"; exit 1; }
# The writer of the restamp commit is the real one.
# shellcheck source=bin/lib/schema-restamp.sh
. "$DIR/bin/lib/schema-restamp.sh" || { echo "FAIL: cannot source bin/lib/schema-restamp.sh"; exit 1; }

O="$T/origin"; C="$T/repos/proj"; SD=worker/jobs/schema.d
export ROWS="$T/rows.json" POSTS="$T/posts" POSTRC=0
export REPOS_ROOT="$T/repos" FLEET_CONF="$T/fleet.conf" LEAD_VERDICT_TOKEN_FILE="$T/tok" LEAD_VERDICT_BIN="$T/lead-verdict.sh"
export JOBS_BOX=testbox
printf 'proj o/r\n' > "$FLEET_CONF"
printf 'tok-fixture-1\n' > "$LEAD_VERDICT_TOKEN_FILE"

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

CALLS="$T/calls"; ATT="$T/att"; LOG="$T/log"
_vd_get() { echo "get $2" >> "$CALLS"; cat "$ROWS"; }
vd_standing() {
  local line
  line=$(jq -r --arg h "$3" '[.rows[] | select(.head_sha == $h and (.source | IN("lead", "human")))]
    | max_by(.id) // empty | [.verdict, .source, (.id | tostring), "x", "-", "lead"] | @tsv' "$ROWS")
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}
la_scope()  { return 0; }
la_decide() { echo "la $*" >> "$CALLS"; LA_REASON="fixture reason"; return 0; }
mc_attempt_has() { grep -qxF "$1" "$ATT" 2>/dev/null; }
mc_attempt_put() { echo "$1" >> "$ATT"; }
mc_log() { echo "$*" >> "$LOG"; }

og() { git -C "$O" "$@"; }
commit() { og add -A; og commit -qm "$1"; og rev-parse HEAD; }
OLD=202610142106-bh-2-b.sql; NEW=202610151200-bh-2-b.sql
# seed — main with one fragment; the PR (A) adds fragment b and a script naming
#   it; main moves; B = the PR rebased onto main, then b restamped. $1 = code:
#   the restamp commit also changes one line.
seed() {
  scratch_rm "$O" 2>/dev/null; scratch_rm "$C" 2>/dev/null
  mkdir -p "$O/$SD" "$O/bin"; og init -q -b main
  printf 'CREATE TABLE z (id INTEGER);\n' > "$O/$SD/202610140000-bh-0-z.sql"
  printf '#!/bin/bash\necho base\n' > "$O/bin/x.sh"
  commit base >/dev/null
  og checkout -qb pr
  printf 'CREATE TABLE b (id INTEGER);\n' > "$O/$SD/$OLD"
  printf '#!/bin/bash\n# applies %s\necho base\n' "$OLD" > "$O/bin/x.sh"
  A=$(commit pr-change)
  og checkout -q main; printf 'other\n' > "$O/o.txt"; commit main-moved >/dev/null
  og checkout -q pr; og rebase -q main >/dev/null 2>&1
  og mv "$SD/$OLD" "$SD/$NEW"; sed -i "s/$OLD/$NEW/" "$O/bin/x.sh"
  [ "${1:-}" = code ] && sed -i 's/^echo base$/echo changed/' "$O/bin/x.sh"
  B=$(commit "restamp schema fragments (no SQL change)")
  og checkout -q main; mkdir -p "$REPOS_ROOT"; git clone -q "$O" "$C" 2>/dev/null
}
rows() { printf '{"rows":[%s],"truncated":false}\n' "$1" > "$ROWS"; }
leadrow() { printf '{"id":%s,"source":"lead","head_sha":"%s","verdict":"%s","note":""}' "$1" "$2" "$3"; }
reset() { : > "$CALLS"; : > "$ATT"; : > "$LOG"; : > "$POSTS"; POSTRC=0; export ACTIONS=1; unset MC_LEAD_CARRY; }
ready() { mc_lead_ready K o/r 31 "$1" - - -; }
nposts() { grep -c . "$POSTS"; }

# ── K1: rebase + restamp ──
seed
git -C "$O" merge-base --is-ancestor "$A" "$B" && bad "K1 setup: A is an ancestor of B" || ok
reset; rows "$(leadrow 7 "$A" MERGE)"
ready "$B"; rc=$?
[ "$rc" = 0 ] && ok || bad "K1 mc_lead_ready must be rc 0 on the rebased, restamped head, got $rc (log: $(cat "$LOG"))"
want="post o/r 31 $B MERGE --source lead --reviewer box:testbox --note lead-replay:${A:0:12} how:restamp-rebase ref:#7 by:merge-conductor"
[ "$(cat "$POSTS")" = "$want" ] && ok || bad "K1 post argv: want '$want', got '$(cat "$POSTS")'"
grep -q "^K LEAD_CARRY carried from=${A:0:12} to=${B:0:12} word=MERGE ref=#7 how=restamp-rebase " "$LOG" \
  && ok || bad "K1 want a 'LEAD_CARRY carried ... how=restamp-rebase' line, got: $(cat "$LOG")"

# ── K2: rebase + restamp + one code line ──
seed code
reset; rows "$(leadrow 7 "$A" MERGE)"
ready "$B"; rc=$?
[ "$rc" = 1 ] && [ "$(nposts)" = 0 ] && ok || bad "K2 a code change must refuse with no post (rc $rc, posts: $(cat "$POSTS"))"
grep -q "^K LEAD_CARRY refused from=${A:0:12} to=${B:0:12} .*reason=patch changed" "$LOG" && ok || bad "K2 want a refused line, got: $(cat "$LOG")"

# ── K3: merge-only mode keeps its own rule ──
seed
reset; rows "$(leadrow 7 "$A" MERGE)"
LC_MERGE_ONLY=1 lead_carry K o/r 31 "$B" >/dev/null 2>&1; rc=$?
[ "$rc" = 1 ] && [ "$(nposts)" = 0 ] && ok || bad "K3 merge-only mode must not carry a restamp (rc $rc, posts: $(cat "$POSTS"), log: $(cat "$LOG"))"
grep -q "LEAD_CARRY refused .* how=- " "$LOG" && ok || bad "K3 want a refused line with no rung (how=-), got: $(cat "$LOG")"

# ── M1: lead_carry without the patch_same_restamp ask refuses K1 ──
sed 's/how=\$(patch_same_restamp /how=$(false /' "$DIR/bin/lib/lead-carry.sh" > "$T/mut-carry.sh"
if cmp -s "$T/mut-carry.sh" "$DIR/bin/lib/lead-carry.sh"; then
  bad "M1 the mutation anchor 'how=\$(patch_same_restamp ' is missing from bin/lib/lead-carry.sh"
else
  (
    # shellcheck source=/dev/null
    . "$T/mut-carry.sh"
    seed
    reset; rows "$(leadrow 7 "$A" MERGE)"
    ready "$B"; echo "rc=$? posts=$(nposts)"
  ) > "$T/m1.out" 2>&1
  grep -qx 'rc=1 posts=0' "$T/m1.out" && ok || bad "M1 with the restamp-rebase ask removed K1 must refuse, got: $(cat "$T/m1.out")"
fi

echo "lead-carry-restamp-rebase.bh-9066: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
