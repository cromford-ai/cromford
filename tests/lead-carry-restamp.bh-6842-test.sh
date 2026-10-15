#!/bin/bash
# tests/lead-carry-restamp.bh-6842-test.sh — BH-6842: the merge conductor
# carries a lead MERGE across a restamp-only commit (bin/lib/schema-restamp.sh),
# alone or with clean main merges, and refuses one that changes anything else.
#
# mc_lead_ready (bin/lib/mc-lead-ready.sh) is the production entry point. It
# asks lead_carry (bin/lib/lead-carry.sh), which asks patch_same and, when that
# refuses, restamp_same.
#
#   C1  lead MERGE on A, then the sr_apply restamp to B   -> carried, how=restamp
#   C2  the restamp commit also edits one line of a script -> refused, no post
#   C3  the restamp, then a clean main merge               -> carried, lead-replay:
#   C4  the newest lead row is a BLOCK                     -> refused, no post
#   M1  mutation: lead_carry without the restamp_same ask -> C1 refused
# Real git (a local origin and a hub clone); the verdicts worker, the authority
# and bin/lead-verdict.sh are stubs, as in tests/lead-verdict-carry-patchid.bh-6291-test.sh.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-carry-restamp.bh-6842-test.sh
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
export JOBS_BOX=testbox SR_NOW_EPOCH
SR_NOW_EPOCH=$(date -u -d '2026-10-15 09:00' +%s)
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
# seed — main forks with one stamp fragment; the PR (A) adds a fragment stamped
#   before the one main gains after the fork, and a script that names it.
seed() {
  scratch_rm "$O" 2>/dev/null; scratch_rm "$C" 2>/dev/null
  mkdir -p "$O/$SD" "$O/bin"; og init -q -b main
  printf 'CREATE TABLE z (id INTEGER);\n' > "$O/$SD/202610140000-bh-0-z.sql"
  printf '#!/bin/bash\necho base\n' > "$O/bin/x.sh"
  commit base >/dev/null
  og checkout -qb pr
  printf 'CREATE TABLE b (id INTEGER);\n' > "$O/$SD/202610142106-bh-2-b.sql"
  printf '#!/bin/bash\n# applies 202610142106-bh-2-b.sql\necho base\n' > "$O/bin/x.sh"
  A=$(commit pr-change)
  og checkout -q main
  printf 'CREATE TABLE a (id INTEGER);\n' > "$O/$SD/202610150259-bh-1-a.sql"
  commit main-a >/dev/null
  og checkout -q pr
}
restamp() { sr_apply "$O" main; }
merge_main() { og merge -q --no-edit main >/dev/null 2>&1; og rev-parse HEAD; }
clone() { og checkout -q main; mkdir -p "$REPOS_ROOT"; git clone -q "$O" "$C" 2>/dev/null; }
rows() { printf '{"rows":[%s],"truncated":false}\n' "$1" > "$ROWS"; }
leadrow() { printf '{"id":%s,"source":"lead","head_sha":"%s","verdict":"%s","note":""}' "$1" "$2" "$3"; }
reset() { : > "$CALLS"; : > "$ATT"; : > "$LOG"; : > "$POSTS"; POSTRC=0; export ACTIONS=1; unset MC_LEAD_CARRY; }
ready() { mc_lead_ready K o/r 31 "$1" - - -; }
nposts() { grep -c . "$POSTS"; }

# ── C1: the restamp alone ──
seed; B=$(restamp); clone
[ "$(git -C "$O" log -1 --format=%s "$B")" = 'restamp schema fragments (no SQL change)' ] && ok || bad "C1 setup: B is not the restamp commit"
reset; rows "$(leadrow 7 "$A" MERGE)"
ready "$B"; rc=$?
[ "$rc" = 0 ] && ok || bad "C1 mc_lead_ready must be rc 0 on the restamped head, got $rc (log: $(cat "$LOG"))"
want="post o/r 31 $B MERGE --source lead --reviewer box:testbox --note lead-replay:${A:0:12} how:restamp ref:#7 by:merge-conductor"
[ "$(cat "$POSTS")" = "$want" ] && ok || bad "C1 post argv: want '$want', got '$(cat "$POSTS")'"
[ "$(grep -c "^K LEAD_CARRY carried from=${A:0:12} to=${B:0:12} word=MERGE ref=#7 how=restamp " "$LOG")" = 1 ] \
  && ok || bad "C1 want one 'LEAD_CARRY carried ... how=restamp' line, got: $(cat "$LOG")"
grep -q 'LEAD_READY' "$LOG" && ok || bad "C1 the carried row must reach the LEAD_READY approval"

# ── C2: the restamp commit also edits one line of a script ──
seed; restamp >/dev/null
sed -i 's/^echo base$/echo changed/' "$O/bin/x.sh"; og add -A; og commit -q --amend --no-edit; B=$(og rev-parse HEAD); clone
reset; rows "$(leadrow 7 "$A" MERGE)"
ready "$B"; rc=$?
[ "$rc" = 1 ] && [ "$(nposts)" = 0 ] && ok || bad "C2 a restamp with a code edit must refuse with no post (rc $rc, posts: $(cat "$POSTS"))"
grep -q "^K LEAD_CARRY refused from=${A:0:12} to=${B:0:12} .*reason=patch changed" "$LOG" && ok || bad "C2 want one refused line, got: $(cat "$LOG")"

# ── C3: the restamp, then a clean main merge ──
seed; restamp >/dev/null; B=$(merge_main); clone
reset; rows "$(leadrow 7 "$A" MERGE-WITH-NOTES)"
ready "$B"; rc=$?
[ "$rc" = 0 ] && grep -q "post o/r 31 $B MERGE-WITH-NOTES .*--note lead-replay:${A:0:12} how:restamp ref:#7" "$POSTS" \
  && ok || bad "C3 restamp + clean merge must carry with lead-replay: (rc $rc, posts: $(cat "$POSTS"), log: $(cat "$LOG"))"
jq -e --arg h "$B" '[.rows[] | select(.head_sha == $h and (.note | startswith("lead-replay:")))] | length == 1' "$ROWS" >/dev/null \
  && ok || bad "C3 the carried row on B must carry the lead-replay: token gate 50 reads"

# ── C4: the newest lead row is a BLOCK ──
seed; B=$(restamp); clone
reset; rows "$(leadrow 5 "$A" MERGE),$(leadrow 7 "$A" BLOCK)"
ready "$B"; rc=$?
[ "$rc" = 1 ] && [ "$(nposts)" = 0 ] && grep -q 'LEAD_CARRY refused .*word=BLOCK .*reason=newest lead verdict is a BLOCK' "$LOG" \
  && ok || bad "C4 a BLOCK is never carried (rc $rc, posts: $(cat "$POSTS"), log: $(cat "$LOG"))"

# ── M1: lead_carry without the restamp ask refuses C1 ──
sed 's/how=\$(restamp_same /how=$(false /' "$DIR/bin/lib/lead-carry.sh" > "$T/mut-carry.sh"
if cmp -s "$T/mut-carry.sh" "$DIR/bin/lib/lead-carry.sh"; then
  bad "M1 the mutation anchor 'how=\$(restamp_same ' is missing from bin/lib/lead-carry.sh"
else
  (
    # shellcheck source=/dev/null
    . "$T/mut-carry.sh"
    seed; B=$(restamp); clone
    reset; rows "$(leadrow 7 "$A" MERGE)"
    ready "$B"; echo "rc=$? posts=$(nposts)"
  ) > "$T/m1.out" 2>&1
  grep -qx 'rc=1 posts=0' "$T/m1.out" && ok || bad "M1 with the restamp ask removed C1 must refuse, got: $(cat "$T/m1.out")"
fi

echo "lead-carry-restamp: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
