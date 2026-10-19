#!/bin/bash
# tests/mc-full-label-expiry.bh-7290-test.sh — BH-7290 (BH-7033.4): the `full`
# label stays a human override for ONE batch. After one completed merge-queue
# batch, the conductor takes it off each open member and comments once.
#
#   §1  fle_tick over stubs (bin/lib/mc-full-label-expiry.sh sourced on its own):
#       L1 no label: no write, marked; L2 a cancelled-only draft is marked with no
#       write, a run in progress is not marked; L3 one comment then one DELETE on
#       the open `full` member only; L4 a second tick writes nothing; L5 a failed
#       DELETE is retried with no second comment; L6 no merge mode writes nothing,
#       and the near-miss labels and closed/merged members are left alone; L7 a
#       rate-limited read stops the tick, and the max_drafts knob bounds the reads.
#   §2  L8 the attempt keys round-trip through the REAL mc_attempt_has /
#       mc_attempt_put (bin/lib/mc/locks.sh, file mode).
#   §3  L9 THE WIRING: a real bin/merge-conductor.sh tick logs would-remove for
#       the open `full` member, and the same tick with the fle_tick call removed
#       logs nothing (D2).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
NOW=$(date -u +%s)
SLUG=example-org/demo-os
LIB="$DIR/bin/lib/mc-full-label-expiry.sh"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
h40() { printf '%s' "$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1$1" | cut -c1-40; }

# ============================================================================
# §1. fle_tick over stubs
# ============================================================================
U="$T/u"; mkdir -p "$U/gh"
export MC_LOG="$U/mc.log" MC_ATTEMPTS="$U/attempts.txt"
# TEST-CHANGE (BH-7290): fle_tick now reads closed drafts only for a repo opted in
# the way bres_tick is (a mergify conf with queue_mode=), so §1 gives its harness
# root that conf. §3 already writes one (demo-os.conf below). No assertion changed.
export HARNESS="$U/h"; mkdir -p "$HARNESS/config/mergify/repos"
printf 'slug=%s\nqueue_mode=serial\n' "$SLUG" > "$HARNESS/config/mergify/repos/${SLUG#*/}.conf"
mc_log() { echo "2026-10-17 00:00:00Z $*" >> "$MC_LOG"; }
mc_attempt_has() { grep -qxF "$1" "$MC_ATTEMPTS" 2>/dev/null; }
mc_attempt_put() { echo "$1" >> "$MC_ATTEMPTS"; }
mc_rest_var() {
  local _o="$1" _f="$2" _t _rc=0 _v=""
  shift 2
  _t=$(mktemp "$U/rest.XXXXXX")
  "$_f" "$@" > "$_t" || _rc=$?
  [ "$_rc" = 0 ] && _v=$(cat "$_t")
  rm -f "$_t"; printf -v "$_o" '%s' "$_v"; return "$_rc"
}
# gh_rest answers from $U/gh/<key>.json (absent = 404, rc 44), or $U/gh/<key>.rc.
ghkey() { local k a; k=$(printf '%s' "$2" | tr '/' '_'); shift 2
  for a in "$@"; do case "$a" in head_sha=*) k="${k}@${a#head_sha=}" ;; esac; done; printf '%s' "$k"; }
gh_rest() {
  local k rc
  printf '%s\n' "$*" >> "$U/gh-calls.txt"
  k=$(ghkey "$@")
  rc=$(cat "$U/gh/$k.rc" 2>/dev/null || echo 0)
  [ "$rc" = 0 ] || return "$rc"
  [ -f "$U/gh/$k.json" ] || return 44
  cat "$U/gh/$k.json"
}
mc_pr_comment() { printf '%s\t%s\n' "$1" "$2" >> "$U/comments.txt"; return "$(cat "$U/commentrc" 2>/dev/null || echo 0)"; }
mc_label_remove() { printf '%s %s\n' "$1" "$2" >> "$U/deletes.txt"; return "$(cat "$U/deleterc" 2>/dev/null || echo 0)"; }
bres_drafts() { [ -f "$U/bresrc" ] && return "$(cat "$U/bresrc")"; cat "$U/drafts.tsv"; }
setting_get() { [ "$1" = full_label_expiry.max_drafts ] && [ -f "$U/maxdrafts" ] && { cat "$U/maxdrafts"; return 0; }; return 1; }
# shellcheck source=/dev/null
[ -r "$LIB" ] && . "$LIB"
tick_u() { RC=0; if command -v fle_tick >/dev/null 2>&1; then fle_tick "$SLUG" "${1:-1}" || RC=$?; else RC=127; fi; }

D=900; S=$(h40 a)
row() { printf '%s\tclosed\t%s\t%s\t%s\t%s\n' "$1" "$2" "$(iso $((NOW-1200)))" "$(iso $((NOW-600)))" "$3"; }
runs() { # runs <sha> <status:conclusion>...
  jq -nc '{total_count:($ARGS.positional|length),workflow_runs:($ARGS.positional|to_entries|map(.value|split(":") as $v|{id:1,status:$v[0],conclusion:$v[1]}))}' \
    --args "${@:2}" > "$U/gh/repos_${SLUG/\//_}_actions_runs@$1.json"
}
issue() { # issue <n> <state> <label>...
  jq -nc --argjson n "$1" --arg s "$2" '{number:$n,state:$s,labels:($ARGS.positional|map({name:.}))}' --args "${@:3}" \
    > "$U/gh/repos_${SLUG/\//_}_issues_$1.json"
}
reset_u() {
  scratch_rm "$U/gh"; mkdir -p "$U/gh"
  for f in bresrc commentrc deleterc maxdrafts; do scratch_rm "$U/$f"; done
  : > "$MC_LOG"; : > "$MC_ATTEMPTS"; : > "$U/gh-calls.txt"; : > "$U/comments.txt"; : > "$U/deletes.txt"
}
ncom() { grep -c . "$U/comments.txt"; }
ndel() { grep -c . "$U/deletes.txt"; }
KEY="fle $SLUG#$D ${S:0:12}"

# --- L1: no member carries `full`: no write, the draft is marked.
reset_u; row "$D" "$S" "11,12" > "$U/drafts.tsv"; runs "$S" completed:success; issue 11 open; issue 12 open bug
tick_u
[ "$RC" = 0 ] && [ "$(ncom)" = 0 ] && [ "$(ndel)" = 0 ] && ok || bad "L1 no label: no write (rc=$RC c=$(ncom) d=$(ndel))"
grep -qxF "$KEY" "$MC_ATTEMPTS" && ok || bad "L1 the draft is marked (marks: $(cat "$MC_ATTEMPTS"))"

# --- L2: only cancelled/skipped runs: marked, no write, a skip line. A run in progress, or no run: not marked.
for rs in "completed:cancelled" "completed:cancelled completed:skipped"; do
  reset_u; row "$D" "$S" 11 > "$U/drafts.tsv"; issue 11 open full
  # shellcheck disable=SC2086
  runs "$S" $rs; tick_u
  { [ "$(ncom)" = 0 ] && [ "$(ndel)" = 0 ] && grep -qxF "$KEY" "$MC_ATTEMPTS" \
    && grep -q "FULL_LABEL_EXPIRY draft=$D skip=no-completed-run" "$MC_LOG"; } && ok \
    || bad "L2 runs '$rs': no write, marked, skip line (c=$(ncom) d=$(ndel) log: $(cat "$MC_LOG"))"
done
for rs in "in_progress:null" "completed:success in_progress:null" ""; do
  reset_u; row "$D" "$S" 11 > "$U/drafts.tsv"; issue 11 open full
  # shellcheck disable=SC2086
  runs "$S" $rs; tick_u
  { [ "$RC" = 0 ] && [ "$(ncom)" = 0 ] && [ "$(ndel)" = 0 ] && [ ! -s "$MC_ATTEMPTS" ]; } && ok \
    || bad "L2 runs '$rs': no write and NOT marked (rc=$RC c=$(ncom) d=$(ndel) marks: $(cat "$MC_ATTEMPTS"))"
done
# a failure with a cancelled one is a completed batch
reset_u; row "$D" "$S" 11 > "$U/drafts.tsv"; issue 11 open full; runs "$S" completed:failure completed:cancelled; tick_u
[ "$(ndel)" = 1 ] && grep -q "CI failure" "$U/comments.txt" && ok || bad "L2 failure + cancelled is a completed batch (d=$(ndel) comments: $(cat "$U/comments.txt"))"

# --- L3: one comment on #11 that names #900, then one DELETE; #12 untouched.
reset_u; row "$D" "$S" "11,12" > "$U/drafts.tsv"; runs "$S" completed:success; issue 11 open full bug; issue 12 open
tick_u
[ "$RC" = 0 ] && [ "$(ncom)" = 1 ] && [ "$(ndel)" = 1 ] && ok || bad "L3 one comment, one DELETE (rc=$RC c=$(ncom) d=$(ndel))"
grep -qF "https://github.com/$SLUG/pull/11"$'\t' "$U/comments.txt" && grep -q "(#$D, CI success)" "$U/comments.txt" && ok \
  || bad "L3 the comment is on #11 and names #$D (got $(cat "$U/comments.txt"))"
[ "$(cat "$U/deletes.txt")" = "https://github.com/$SLUG/pull/11 full" ] && ok || bad "L3 the DELETE is full on #11 (got $(cat "$U/deletes.txt"))"
grep -q "/pull/12" "$U/comments.txt" "$U/deletes.txt" && bad "L3 #12 has no label: nothing written on it" || ok
grep -q "FULL_LABEL_EXPIRY removed pr=11 draft=$D$" "$MC_LOG" && ok || bad "L3 the removed line (log: $(cat "$MC_LOG"))"
grep -qxF "$KEY" "$MC_ATTEMPTS" && ok || bad "L3 the draft is marked"
# the comment is posted BEFORE the DELETE (order of the log lines)
CL=$(grep -n 'commented pr=11' "$MC_LOG" | cut -d: -f1); RL=$(grep -n 'removed pr=11' "$MC_LOG" | cut -d: -f1)
[ -n "$CL" ] && [ -n "$RL" ] && [ "$CL" -lt "$RL" ] && ok || bad "L3 the comment comes first (log: $(cat "$MC_LOG"))"
grep -q '—' "$U/comments.txt" && bad "L3 the comment has no em dash" || ok

# --- L4: a second tick over L3's state writes nothing and reads nothing.
: > "$U/comments.txt"; : > "$U/deletes.txt"; : > "$U/gh-calls.txt"; tick_u
[ "$(ncom)" = 0 ] && [ "$(ndel)" = 0 ] && [ ! -s "$U/gh-calls.txt" ] && ok || bad "L4 a marked draft: zero writes and zero reads (c=$(ncom) d=$(ndel) calls: $(cat "$U/gh-calls.txt"))"

# --- L5: the DELETE fails: comment once, no mark; the next tick retries the DELETE only.
reset_u; row "$D" "$S" 11 > "$U/drafts.tsv"; runs "$S" completed:success; issue 11 open full; echo 1 > "$U/deleterc"
tick_u
{ [ "$(ncom)" = 1 ] && [ "$(ndel)" = 1 ] && ! grep -qxF "$KEY" "$MC_ATTEMPTS" \
  && grep -q "remove-failed pr=11" "$MC_LOG" && ! grep -q "removed pr=11" "$MC_LOG"; } && ok \
  || bad "L5 a failed DELETE: one comment, no mark, remove-failed (c=$(ncom) d=$(ndel) log: $(cat "$MC_LOG"))"
scratch_rm "$U/deleterc"; tick_u
{ [ "$(ncom)" = 1 ] && [ "$(ndel)" = 2 ] && grep -qxF "$KEY" "$MC_ATTEMPTS"; } && ok \
  || bad "L5 the retry: no second comment, a second DELETE, marked (c=$(ncom) d=$(ndel))"
# a failed comment: no DELETE, no mark
reset_u; row "$D" "$S" 11 > "$U/drafts.tsv"; runs "$S" completed:success; issue 11 open full; echo 1 > "$U/commentrc"
tick_u
{ [ "$(ndel)" = 0 ] && [ ! -s "$MC_ATTEMPTS" ]; } && ok || bad "L5 a failed comment: no DELETE, no mark (d=$(ndel) marks: $(cat "$MC_ATTEMPTS"))"

# --- L6: no merge mode writes nothing; near-miss labels and closed members are left alone.
reset_u; row "$D" "$S" 11 > "$U/drafts.tsv"; runs "$S" completed:success; issue 11 open full
tick_u 0
{ [ "$(ncom)" = 0 ] && [ "$(ndel)" = 0 ] && grep -q "FULL_LABEL_EXPIRY would-remove pr=11 draft=$D$" "$MC_LOG" \
  && [ ! -s "$MC_ATTEMPTS" ]; } && ok || bad "L6 merges=0: zero writes, would-remove, no mark (c=$(ncom) d=$(ndel) log: $(cat "$MC_LOG"))"
reset_u; row "$D" "$S" "11,12,13,14,15" > "$U/drafts.tsv"; runs "$S" completed:success
issue 11 open full-ci; issue 12 open fullstack; issue 13 closed full; issue 14 closed full; issue 15 open nofull Full
tick_u
{ [ "$(ncom)" = 0 ] && [ "$(ndel)" = 0 ] && grep -qxF "$KEY" "$MC_ATTEMPTS"; } && ok \
  || bad "L6 near misses (full-ci, fullstack, closed, nofull, Full): zero writes (c=$(ncom) d=$(ndel) $(cat "$U/deletes.txt"))"
# an unreadable member: no write on it, no mark, retried
reset_u; row "$D" "$S" "11,12" > "$U/drafts.tsv"; runs "$S" completed:success; issue 12 open full
tick_u
{ [ "$(ndel)" = 1 ] && ! grep -qxF "$KEY" "$MC_ATTEMPTS" && grep -q "unread pr=11" "$MC_LOG"; } && ok \
  || bad "L6 an unread member holds the mark back (d=$(ndel) log: $(cat "$MC_LOG"))"

# --- L7: rate limits stop the tick; the knob bounds the run reads.
reset_u; echo 75 > "$U/bresrc"; tick_u
[ "$RC" = 75 ] && [ ! -s "$U/gh-calls.txt" ] && [ ! -s "$MC_ATTEMPTS" ] && ok || bad "L7 bres_drafts 75: rc 75, no read, no mark (rc=$RC)"
reset_u; row "$D" "$S" 11 > "$U/drafts.tsv"; issue 11 open full; echo 75 > "$U/gh/repos_${SLUG/\//_}_actions_runs@$S.rc"; tick_u
[ "$RC" = 75 ] && [ "$(ncom)" = 0 ] && [ ! -s "$MC_ATTEMPTS" ] && ok || bad "L7 a runs read 75: rc 75, no write (rc=$RC)"
reset_u; echo 2 > "$U/maxdrafts"; : > "$U/drafts.tsv"
for d in 901 902 903 904; do row "$d" "$(h40 "${d: -1}")" 11 >> "$U/drafts.tsv"; runs "$(h40 "${d: -1}")" completed:success; done
issue 11 open
tick_u
[ "$(grep -c 'actions/runs' "$U/gh-calls.txt")" = 2 ] && [ "$(grep -c 'deferred' "$MC_LOG")" = 2 ] && ok \
  || bad "L7 max_drafts=2: two run reads, two deferred (calls: $(cat "$U/gh-calls.txt"))"

# ============================================================================
# §2. L8 the keys through the REAL attempt store (file mode)
# ============================================================================
(
  unset -f mc_attempt_has mc_attempt_put
  export MC_H="$U/mch" MC_STATE_DIR="$U/mch/state" MC_ATTEMPTS="$U/real-attempts.txt"; : > "$MC_ATTEMPTS"
  # shellcheck source=bin/lib/mc/locks.sh
  . "$DIR/bin/lib/mc/locks.sh" || exit 9
  reset_u; export MC_ATTEMPTS="$U/real-attempts.txt"; : > "$MC_ATTEMPTS"
  row "$D" "$S" 11 > "$U/drafts.tsv"; runs "$S" completed:success; issue 11 open full
  fle_tick "$SLUG" 1 || exit 8
  grep -qxF "$KEY" "$MC_ATTEMPTS" && grep -qxF "fle-c $SLUG#11 $D" "$MC_ATTEMPTS" || exit 7
  : > "$U/comments.txt"; : > "$U/deletes.txt"; : > "$U/gh-calls.txt"
  fle_tick "$SLUG" 1 || exit 6
  [ ! -s "$U/comments.txt" ] && [ ! -s "$U/deletes.txt" ] && [ ! -s "$U/gh-calls.txt" ] || exit 5
  # a draft whose number only PREFIXES the marked one is not a hit
  mc_attempt_has "fle $SLUG#90 ${S:0:12}" && exit 4
  exit 0
); r=$?
[ "$r" = 0 ] && ok || bad "L8 the keys round-trip through the real mc_attempt_has/mc_attempt_put (rc=$r)"

# ============================================================================
# §3. L9 THE WIRING: a real conductor tick
# ============================================================================
export HARNESS="$T/h"
unset MC_LOG MC_ATTEMPTS
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" \
         "$T/h/env" "$T/h/tmp" "$T/h/config/mergify/repos" "$T/fakebin" "$T/repos"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || exit 1
scratch_install_closure bin/lib/mc-batch-reset.sh "$T/h" >/dev/null || exit 1
[ -f "$LIB" ] && { scratch_install_closure bin/lib/mc-full-label-expiry.sh "$T/h" >/dev/null || exit 1; }
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/" || exit 1
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
: > "$T/h/env/global.env"
printf 'demo-os %s - - 2 box-d\n' "$SLUG" > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
printf 'slug=%s\nqueue_mode=serial\n' "$SLUG" > "$T/h/config/mergify/repos/demo-os.conf"
for s in beat.sh deploy-request.sh pre-arm-guards.sh codegraph-ensure.sh deploy-verify.sh prod-url.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s"; chmod +x "$T/h/bin/$s"
done
printf '#!/bin/bash\nprintf "VERDICT: APPROVE\\n" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
cat > "$T/h/bin/jobs-client.sh" <<'EOF'
job_verdict_rebind() { return 0; }
job_ledger_put() { return 0; }
_jobs_req() { return 0; }
EOF
cat > "$T/h/bin/test-impact.sh" <<'EOF'
#!/bin/bash
printf 'tests/always-test.sh\talways\n'
EOF
chmod +x "$T/h/bin/test-impact.sh"

A=5001; HA=$(h40 a)
CA=$(iso $((NOW-1200))); XA=$(iso $((NOW-600)))
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: merge\n' | base64 | tr -d '\n')
{ printf '#!/bin/bash\nT=%s\nMGFY_YML=%s\nSLUG=%s\nHA=%s\n' "$T" "$MGFY_YML" "$SLUG" "$HA"; cat <<'SHIM'
printf '%s\n' "$*" >> "$T/gh-calls.txt"
file() { if [ -f "$1" ]; then restpr --raw 200 "$(cat "$1")"; else restpr --raw 404 '{"message":"Not Found"}'; fi; }
case "$*" in
  *"auth token"*) echo faketoken ;;
  *"-X DELETE"*) printf '%s\n' "$*" >> "$T/deletes.txt" ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 "{\"content\":\"$MGFY_YML\"}" ;;
  *"api -i -X GET repos/$SLUG/actions/runs -f head_sha=$HA "*)
    restpr --raw 200 '{"total_count":1,"workflow_runs":[{"id":9001,"status":"completed","conclusion":"success","name":"harness-ci"}]}' ;;
  *"api -i -X GET repos/$SLUG/actions/runs -f head_sha="*) restpr --raw 200 '{"total_count":0,"workflow_runs":[]}' ;;
  *"api -i -X GET repos/$SLUG/pulls "*"state=closed"*) file "$T/closed.json" ;;
  *"api -i -X GET repos/$SLUG/pulls -f"*|*"api -i -X GET repos/$SLUG/pulls?"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/commits?"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/issues/"*)
    N=$(sed -n 's|.*/issues/\([0-9]*\).*|\1|p' <<<"$*"); file "$T/issue-$N.json" ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"/files"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*) restpr --raw 404 '{"message":"Not Found"}' ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*) restpr --runs 'completed|success' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
SHIM
} > "$T/fakebin/gh"
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf '"'"'{"error":"not found"}\\n404\\n'"'"'\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
jq -nc --argjson n "$A" --arg s "$HA" --arg c "$CA" --arg x "$XA" \
  '[{number:$n,title:"merge queue: checking #101 + #102 together on main (abc1234)",state:"closed",merged_at:null,
     created_at:$c,closed_at:$x,updated_at:$x,head:{ref:("mergify/merge-queue/"+($n|tostring)),sha:$s},base:{ref:"main"},body:"x"}]' \
  > "$T/closed.json"
jq -nc '{number:101,state:"open",labels:[{name:"full"}]}' > "$T/issue-101.json"
jq -nc '{number:102,state:"open",labels:[]}' > "$T/issue-102.json"

LOG="$T/h/logs/merge-conductor.log"
CONDUCTOR="$T/h/bin/merge-conductor.sh"
tick() {
  : > "$LOG"; : > "$T/gh-calls.txt"; : > "$T/deletes.txt"
  [ -d "$T/h/state/merge-conductor" ] && : > "$T/h/state/merge-conductor/attempts.txt"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=https://jobs.test MC_REPOS="$T/repos" \
    MC_RR_PATH="$T/fakebin:$PATH" MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 \
    MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MERGE_TREE=0 MC_LAND_REBASE=0 \
    bash "$CONDUCTOR" >/dev/null 2>"$T/tick.err" ); TICK_RC=$?
}
tick
grep -q "$SLUG FULL_LABEL_EXPIRY would-remove pr=101 draft=$A$" "$LOG" && ok \
  || bad "L9 the conductor tick logs would-remove pr=101 draft=$A (rc=$TICK_RC, log: $(grep -E 'FULL_LABEL|UNREAD' "$LOG"); err: $(tail -3 "$T/tick.err"))"
grep -q "pr=102" "$LOG" && bad "L9 #102 has no full label: no line for it" || ok
[ ! -s "$T/deletes.txt" ] && ok || bad "L9 a tick that is not in merge mode DELETEs nothing ($(cat "$T/deletes.txt"))"
grep -q "repos/$SLUG/issues/101" "$T/gh-calls.txt" && ok || bad "L9 the tick reads member #101 through gh"
[ "$TICK_RC" = 0 ] && grep -q ' TICK demo-os tick=' "$LOG" && ok || bad "L9 the tick ends normally (rc=$TICK_RC)"
# D2: the call site is what writes the line.
sed '/fle_tick "\$SLUG"/d' "$T/h/bin/merge-conductor.sh" > "$T/h/bin/mc-nocall.sh"
if cmp -s "$T/h/bin/merge-conductor.sh" "$T/h/bin/mc-nocall.sh"; then
  bad "L9 the conductor carries a fle_tick \"\$SLUG\" call to remove"
else
  CONDUCTOR="$T/h/bin/mc-nocall.sh"; tick
  grep -q 'FULL_LABEL_EXPIRY' "$LOG" && bad "L9 without the call no FULL_LABEL_EXPIRY line is written" || ok
fi

echo "mc-full-label-expiry.bh-7290: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
