#!/bin/bash
# tests/mc/external-pr-enqueue.bh-4572-test.sh — BH-4580 (BH-4572.1): an approved,
# green, clean PR from an EXTERNAL author on a Mergify repo reaches the merge
# queue. project-4 had 19 such PRs: review-prs hands every Mergify-repo APPROVE to
# the merge conductor (bin/review-prs.sh, mc_queue_conductor_only), and the
# conductor lists harness-authored PRs only, so nothing consumed the hand-off.
#
# X1 drives the WHOLE bin/merge-conductor.sh in a scratch tree. X0 and X2..X16
# (minus X12/X13) source bin/lib/autoenqueue.sh and bin/lib/mc/external-enqueue.sh
# and call xe_project, with the GitHub reads and the POST going through the REAL
# bin/lib/gh-rest.sh against a stub `gh` that records every call. The verdict
# reads and the conductor's fences are stubbed at their entry points, as
# tests/tier2-autoenqueue-test.sh does. X12/X13 run bin/review-prs.sh's fresh
# merge decision, beat line and merge_retry blocks, extracted by their markers.
# TEST-CHANGE BH-5035: the tier_gate_mode human opt-in is removed; X12/X13 now pin that a human, off, missing or unreadable row is inert (merge_step runs, merge_retry spends an attempt, no hold line)
# Run from anywhere; exit 0 = all pass.
set -uo pipefail
. "$(dirname "$0")/../lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/../.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/project-4-fx
H1=$(printf 'a%.0s' $(seq 40)); H2=$(printf 'b%.0s' $(seq 40)); H0=$(printf 'c%.0s' $(seq 40))
U="https://github.com/$SLUG/pull"
EXT=collaborator-1

# ============================================================================
# The unit harness: both libs sourced into THIS shell, their neighbours stubbed.
# ============================================================================
export HARNESS="$T/u"; H="$HARNESS"; MC_H="$H"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$T/fx" "$T/ubin"
printf '#!/bin/bash\n[ "$2" = board_prefix ] && echo X\nexit 0\n' > "$H/bin/fleet-conf.sh"; chmod +x "$H/bin/fleet-conf.sh"
cp "$DIR/tests/lib/rest-emit.sh" "$T/ubin/restpr"; chmod +x "$T/ubin/restpr"
MC_ATTEMPTS="$H/state/attempts.txt"; MC_LOG="$H/logs/merge-conductor.log"; : > "$MC_ATTEMPTS"; : > "$MC_LOG"
MC_TICK_ID=unit-tick; MC_TICK_DIR="$H/state/tick"
export MC_ATTEMPTS MC_LOG MC_TICK_ID MC_TICK_DIR

cat > "$T/ubin/gh" <<EOF
#!/bin/bash
printf '%s GH_TOKEN=%s\n' "\$*" "\${GH_TOKEN:-<unset>}" >> "$T/gh-calls.txt"
FX="$T/fx"
num_of() { printf '%s' "\$1" | sed -nE 's#.*/(pulls|issues)/([0-9]+).*#\2#p'; }
case "\$*" in
  "api repos/$SLUG -q .id") echo 1 ;;
  *"api -i -X GET repos/$SLUG/pulls?state=open&per_page=100")
    [ -f "\$FX/list-status" ] && { restpr --raw "\$(cat "\$FX/list-status")" '{"message":"API rate limit exceeded"}'; exit 0; }
    [ -f "\$FX/list-raw" ] && { restpr --raw 200 "\$(cat "\$FX/list-raw")"; exit 0; }
    restpr --raw 200 "\$(cat "\$FX"/list.d/*.json 2>/dev/null | jq -sc .)" ;;
  *"api -i -X GET repos/$SLUG/commits/"*"/check-runs"*)
    sha=\$(printf '%s' "\$*" | sed -n 's|.*/commits/\([0-9a-f]*\)/check-runs.*|\1|p')
    restpr --raw 200 "\$(cat "\$FX/checks-\$sha" 2>/dev/null || echo '{"check_runs":[]}')" ;;
  *"api -i -X GET repos/$SLUG/issues/"*"/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X POST repos/$SLUG/issues/"*"/comments"*)
    printf '%s GH_TOKEN=%s\n' "\$*" "\${GH_TOKEN:-<unset>}" >> "$T/posts.txt"
    restpr --raw 201 '{"id":777,"body":"@mergifyio queue"}' ;;
  *"/pulls/"*"/merge"*) printf '%s\n' "\$*" >> "$T/merges.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"/reviews"*) restpr --raw 200 "\$(cat "\$FX/reviews-\$(num_of "\$*")" 2>/dev/null || echo '[]')" ;;
  *"api -i -X GET repos/$SLUG/pulls/"*"v3.diff"*)
    n=\$(num_of "\$*"); [ -f "\$FX/diff-down-\$n" ] && { restpr --raw 502 '{"message":"bad gateway"}'; exit 0; }
    restpr --diff "\$(cat "\$FX/diff-\$n" 2>/dev/null || printf '+++ b/src/x.ts\n+const a = 1;\n')" ;;
  *"api -i -X GET repos/$SLUG/pulls/"*)
    n=\$(num_of "\$*"); read -r st hd base ms login < "\$FX/pr-\$n"
    restpr "\$st" "\$hd" "feature/x-\$n" "\$base" "" MERGEABLE "\$ms" "\$login" ;;
  *) printf '%s\n' "\$*" >> "$T/gh-other.txt"; exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/ubin/gh"
export PATH="$T/ubin:$PATH"
export GH_TOKEN=pat-default GH_ETAG=0
# shellcheck source=bin/lib/gh-rest.sh
. "$DIR/bin/lib/gh-rest.sh" || exit 1
# shellcheck source=bin/lib/gh-repo-token.sh
. "$DIR/bin/lib/gh-repo-token.sh" || exit 1
# The real author test (harness_pr_author_match) and the real diff read and
# iron-law scan (mc_pr_diff, mc_iron_law_scan): the external path's own gates.
# shellcheck source=bin/lib/gh-pr-list.sh
. "$DIR/bin/lib/gh-pr-list.sh" || exit 1
# shellcheck source=bin/lib/mc/classify.sh
. "$DIR/bin/lib/mc/classify.sh" || exit 1

# --- neighbours, stubbed at their entry points (after classify.sh) -------------
mc_log()   { echo "$*" >> "$MC_LOG"; }
mc_alert() { echo "ALERT $*" >> "$H/logs/ALERTS.log"; }
mc_attempt_has() { grep -qxF "$1" "$MC_ATTEMPTS"; }
mc_attempt_put() { echo "$1" >> "$MC_ATTEMPTS"; }
mc_record_for() { return 1; }   # an external PR has no build record
mc_issue_of() { echo 1; }
mc_verdict() { # fixture: verdict-<num> = "VERDICT sha job" — review-prs' ledger row
  local n="${1##*/}" v s j; read -r v s j < "$T/fx/verdict-$n" 2>/dev/null || { printf -- '-\t-\t-\t-\t-'; return 0; }
  printf '%s\t-\t%s\t%s\t-' "$v" "$s" "$j"; }
vd_standing() {
  local w; w=$(cat "$T/fx/standing-$2" 2>/dev/null) || return 1
  [ "$w" = down ] && return 2; printf '%s\tlead\t1\t2026-10-05\t-\t-\n' "$w"; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
to_lane_hold() { return 1; }
bg_scan_read() { [ -f "$T/fx/block-$2" ] && return 1; return 0; }
main_red_exempt() { return 1; }
flag_active() { [ -f "$H/flags/$1" ]; }
hold_check_thread() { printf 'clear\t-'; return 0; }
job_ledger_get() {
  local s; s=$(jq -r --arg k "$1" --arg v "$2" 'select(.kind==$k and .key==$v) | .status' "$T/ledger.jsonl" 2>/dev/null | tail -1)
  [ -n "$s" ] || return 2; printf '%s' "$s"; }
job_ledger_put() { jq -nc --arg k "$1" --arg v "$2" --arg s "$3" '{kind:$k,key:$v,status:$s}' >> "$T/ledger.jsonl"; }
job_artifact_put() { :; }
setting_get() { echo "setting_get $*" >> "$T/settings-reads.txt"; printf human; }

# shellcheck source=bin/lib/autoenqueue.sh
. "$DIR/bin/lib/autoenqueue.sh" || exit 1
# shellcheck source=bin/lib/mc/external-enqueue.sh
[ -r "$DIR/bin/lib/mc/external-enqueue.sh" ] && . "$DIR/bin/lib/mc/external-enqueue.sh"
command -v xe_project >/dev/null 2>&1 || { bad "xe_project is not defined (bin/lib/mc/external-enqueue.sh missing)"; xe_project() { :; }; }

# xpr <num> <head> [login] [labels-csv] [base] [draft] — one open PR on the REST
# list, and the eligible default around it: review-prs' APPROVE on this head,
# the required check green, the re-read open/clean on main, a clean diff.
xpr() {
  local n="$1" h="$2" login="${3:-$EXT}" lbl="${4:-}" base="${5:-main}" draft="${6:-false}"
  mkdir -p "$T/fx/list.d"
  jq -nc --argjson n "$n" --arg u "$U/$n" --arg h "$h" --arg l "$login" --arg lb "$lbl" --arg b "$base" --argjson d "$draft" --arg s "$SLUG" \
    '{number:$n, html_url:$u, draft:$d, user:{login:$l}, updated_at:"2026-10-05T00:00:00Z",
      head:{sha:$h, ref:("feature/x-"+($n|tostring)), repo:{full_name:"collaborator-1/project-4-fx"}},
      base:{ref:$b, repo:{full_name:$s}},
      labels:($lb | split(",") | map(select(length>0)) | map({name:.}))}' > "$T/fx/list.d/$n.json"
  echo "APPROVE $h R$n" > "$T/fx/verdict-$n"
  printf '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T10:00:00Z"}]}' > "$T/fx/checks-$h"
  echo "open $h $base clean $login" > "$T/fx/pr-$n"
}
reset() {
  rm -rf "$T/fx"/* "$H/flags"/*; : > "$T/posts.txt"; : > "$MC_LOG"; : > "$MC_ATTEMPTS"; : > "$H/logs/ALERTS.log"
  : > "$T/gh-calls.txt"; : > "$T/gh-other.txt"; : > "$T/merges.txt"; : > "$T/settings-reads.txt"
  [ "${1:-}" = keep ] || { : > "$T/ledger.jsonl"; rm -f "$H/state/tier2-autoenqueue.txt"; }
}
xe() { ( MODE="${MODE:-merge}"; MERGES="${MERGES:-1}"; unset AE_POSTED AE_DEFERRED; xe_project project-4 "$SLUG" "${PROV:-mergify}" main ) ; }
posts() { grep -c . "$T/posts.txt" 2>/dev/null || true; }
lstat() { jq -r --arg v "$1" 'select(.key==$v)|.status' "$T/ledger.jsonl" | tail -1; }

# X0 the positive control every negative below differs from by one fixture.
reset; xpr 77 "$H1"; xe
[ "$(posts)" = 1 ] && ok || bad "X0 an approved, green, clean external PR gets exactly one POST (got $(posts); log: $(cat "$MC_LOG"))"
grep -q "api -i -X POST repos/$SLUG/issues/77/comments -f body=@mergifyio queue" "$T/posts.txt" && ok || bad "X0 the POST is '@mergifyio queue' on issues/77 (got $(cat "$T/posts.txt"))"
[ "$(lstat "$U/77@$H1")" = enqueued ] && ok || bad "X0 the ledger row is enqueued (got $(cat "$T/ledger.jsonl"))"
[ -s "$T/merges.txt" ] && bad "X0 never a direct merge call ($(cat "$T/merges.txt"))" || ok
[ "$(grep -c 'pulls?state=open&per_page=100' "$T/gh-calls.txt")" = 1 ] && ok || bad "X0 ONE list read (calls: $(grep 'pulls?' "$T/gh-calls.txt"))"
[ -s "$T/settings-reads.txt" ] && bad "X0 the external path reads no tier setting ($(cat "$T/settings-reads.txt"))" || ok
: > "$T/posts.txt"; : > "$MC_ATTEMPTS"; xe
[ "$(posts)" = 0 ] && ok || bad "X0 a second tick on the same head posts nothing (got $(posts))"

# X2 a standing BLOCK on the head; a REQUEST_CHANGES verdict on the head.
reset; xpr 77 "$H1"; echo BLOCK > "$T/fx/standing-77"; xe
[ "$(posts)" = 0 ] && ok || bad "X2 a standing BLOCK on the head must never post (got $(posts))"
reset; xpr 77 "$H1"; echo "REQUEST_CHANGES $H1 R77" > "$T/fx/verdict-77"; xe
[ "$(posts)" = 0 ] && ok || bad "X2 a REQUEST_CHANGES verdict on the head must never post (got $(posts))"

# X3 an APPROVE on an older head.
reset; xpr 77 "$H1"; echo "APPROVE $H0 R77" > "$T/fx/verdict-77"; xe
[ "$(posts)" = 0 ] && ok || bad "X3 an APPROVE on an older head must never post (got $(posts))"
grep -q "AUTOENQUEUE $SLUG#77 not enqueued at ${H1:0:8}: verdict" "$MC_LOG" && ok || bad "X3 the skip names the verdict gate (log: $(cat "$MC_LOG"))"

# X4 a draft.
reset; xpr 77 "$H1" "$EXT" "" main true; xe
[ "$(posts)" = 0 ] && ok || bad "X4 a draft must never post (got $(posts))"

# X5 hold / do-not-merge labels.
reset; xpr 77 "$H1" "$EXT" "bug,hold"; xe
[ "$(posts)" = 0 ] && ok || bad "X5 a PR labelled hold must never post (got $(posts))"
reset; xpr 77 "$H1" "$EXT" "do-not-merge"; xe
[ "$(posts)" = 0 ] && ok || bad "X5 a PR labelled do-not-merge must never post (got $(posts))"

# X6 the main-red freeze.
reset; xpr 77 "$H1"; ( MAIN_RED=main-red-project-4; xe )
[ "$(posts)" = 0 ] && ok || bad "X6 a main-red freeze must never post (got $(posts))"
grep -q "not enqueued at ${H1:0:8}: main-red" "$MC_LOG" && ok || bad "X6 a main-red skip line (log: $(cat "$MC_LOG"))"

# X7 kill switch: no POST, a WOULD line, no ledger write.
reset; xpr 77 "$H1"; touch "$H/flags/automerge-disabled"; xe
[ "$(posts)" = 0 ] && ok || bad "X7 flags/automerge-disabled must never post (got $(posts))"
grep -q "WOULD enqueue $SLUG#77 @${H1:0:8}" "$MC_LOG" && ok || bad "X7 a WOULD line (log: $(cat "$MC_LOG"))"
[ -s "$T/ledger.jsonl" ] && bad "X7 no ledger row ($(cat "$T/ledger.jsonl"))" || ok

# X8 mergeable_state unstable / blocked.
for ms in unstable blocked; do
  reset; xpr 77 "$H1"; echo "open $H1 main $ms $EXT" > "$T/fx/pr-77"; xe
  [ "$(posts)" = 0 ] && ok || bad "X8 mergeable_state $ms must never post (got $(posts))"
done

# X9 the iron-law scan in the READY mark's place; an unread diff is never clean.
reset; xpr 77 "$H1"; printf '+++ b/src/a.ts\n+if (window.confirm("sure?")) go();\n' > "$T/fx/diff-77"; xe
[ "$(posts)" = 0 ] && ok || bad "X9 an iron-law hit must never post (got $(posts))"
grep -q "not enqueued at ${H1:0:8}: iron-law — 1 iron-law hit" "$MC_LOG" && ok || bad "X9 an iron-law skip line (log: $(cat "$MC_LOG"))"
reset; xpr 77 "$H1"; touch "$T/fx/diff-down-77"; xe
[ "$(posts)" = 0 ] && ok || bad "X9 an unreadable diff must never post (got $(posts))"
grep -q "not enqueued at ${H1:0:8}: iron-law-read" "$MC_LOG" && ok || bad "X9 an iron-law-read skip line (log: $(cat "$MC_LOG"))"

# X10 a stranger's GitHub APPROVE, no harness verdict.
reset; xpr 77 "$H1"; rm -f "$T/fx/verdict-77"
echo "[{\"user\":{\"login\":\"randomdev\"},\"state\":\"APPROVED\",\"commit_id\":\"$H1\"}]" > "$T/fx/reviews-77"; xe
[ "$(posts)" = 0 ] && ok || bad "X10 an APPROVE by a non-verdict author must never post (got $(posts))"

# X11 a harness-authored PR is ae_project's, never xe_project's.
reset; xpr 31 "$H1" operator; xe
[ "$(posts)" = 0 ] && ok || bad "X11 a harness-authored PR gets nothing from xe_project (got $(posts))"
grep -q "#31" "$MC_LOG" && bad "X11 xe_project does not even consider it (log: $(cat "$MC_LOG"))" || ok

# X14 a stacked base; an already-queued label.
reset; xpr 77 "$H1" "$EXT" "" feature-x; xe
[ "$(posts)" = 0 ] && ok || bad "X14 a PR based on feature-x must never post (got $(posts))"
grep -q "not enqueued at ${H1:0:8}: base" "$MC_LOG" && ok || bad "X14 a base skip line (log: $(cat "$MC_LOG"))"
reset; xpr 77 "$H1" "$EXT" "queued"; xe
[ "$(posts)" = 0 ] && ok || bad "X14 a PR labelled queued must never post (got $(posts))"

# X15 the list read answering 75 is never "no PRs"; neither is a non-array.
reset; xpr 77 "$H1"; echo 429 > "$T/fx/list-status"; xe
[ "$(posts)" = 0 ] && ok || bad "X15 a rate-limited list read posts nothing (got $(posts))"
grep -q "external list .*rate limited" "$MC_LOG" && ok || bad "X15 a rate limited line (log: $(cat "$MC_LOG"))"
reset; xpr 77 "$H1"; echo '{"message":"odd"}' > "$T/fx/list-raw"; xe
[ "$(posts)" = 0 ] && ok || bad "X15 a non-array list posts nothing (got $(posts))"
grep -q "external list .*unread" "$MC_LOG" && ok || bad "X15 an unread line (log: $(cat "$MC_LOG"))"

# X16 the shared cap: CAP=1, two eligible -> one POST, one DEFERRED; next tick the other.
reset; xpr 77 "$H1"; xpr 78 "$H2"; MC_AUTOENQUEUE_CAP=1 xe
[ "$(posts)" = 1 ] && ok || bad "X16 CAP=1 over two eligible external PRs posts 1 (got $(posts))"
grep -q "DEFERRED 1" "$MC_LOG" && ok || bad "X16 a DEFERRED 1 line (log: $(cat "$MC_LOG"))"
: > "$T/posts.txt"; MC_AUTOENQUEUE_CAP=1 xe
[ "$(posts)" = 1 ] && ok || bad "X16 the deferred PR is offered next tick (got $(posts))"
# ...and the count ae_project already spent this tick is the same budget.
reset; xpr 77 "$H1"; ( MODE=merge; MERGES=1; MC_AUTOENQUEUE_CAP=1; AE_POSTED=1; AE_DEFERRED=0; xe_project project-4 "$SLUG" mergify main )
[ "$(posts)" = 0 ] && grep -q "DEFERRED 1" "$MC_LOG" && ok || bad "X16 a cap ae_project filled leaves the external PR DEFERRED (posts $(posts); log: $(cat "$MC_LOG"))"
# a non-Mergify provider is a no-op with no read
reset; xpr 77 "$H1"; PROV=github xe
[ "$(posts)" = 0 ] && [ ! -s "$T/gh-calls.txt" ] && ok || bad "X16b a non-Mergify provider is a no-op with no read"

# ============================================================================
# X12 / X13 — bin/review-prs.sh: no tier gate before either merge path (BH-5035).
# ============================================================================
RP="$DIR/bin/review-prs.sh"
awk '/^  # >>> review-prs fresh merge/{f=1;next} /^  # <<< review-prs fresh merge/{exit} f' "$RP" > "$T/rp-fresh.sh"
awk '/^  # >>> review-prs beat line/{f=1;next} /^  # <<< review-prs beat line/{exit} f' "$RP" > "$T/rp-beat.sh"
awk '/^# >>> review-prs merge-retry/{f=1;next} /^# <<< review-prs merge-retry/{exit} f' "$RP" > "$T/rp-retry.sh"
[ -s "$T/rp-fresh.sh" ] && ok || bad "X12 could not extract the review-prs fresh merge block — markers missing?"
[ -s "$T/rp-beat.sh" ] && ok || bad "X12 could not extract the review-prs beat line block — markers missing?"
[ -s "$T/rp-retry.sh" ] && ok || bad "X13 could not extract the review-prs merge-retry block — markers missing?"
mkdir -p "$T/rp/state"
# rp_fresh <tier> <setting: value|unreadable|none> [verdict] — prints MERGED and
# whether merge_step was called; the lane log is $T/rp.log.
rp_fresh() {
  : > "$T/rp.log"; : > "$T/rp-merge.txt"
  HARNESS="$T/rp" LOG="$T/rp.log" TIER="$1" SETV="$2" VERDICT="${3:-APPROVE}" T="$T" DIR="$DIR" bash -c '
    set -uo pipefail
    STAMP() { printf TS; }
    setting_get() { case "$SETV" in unreadable) return 1 ;; none) return 2 ;; *) printf %s "$SETV" ;; esac; }
    merge_step() { echo "merge_step $*" >> "$T/rp-merge.txt"; MERGED=yes; }
    PROJECT=project-4 NUM=77 SHA=aaaaaaaa1111 SERVED=claude AUTHOR=collaborator-1 RP_ADVISORY=0 RP_MODEL=-
    . "$0"
    printf "MERGED=%s\n" "$MERGED"' "$T/rp-fresh.sh" 2>"$T/rp.err"
}
# TEST-CHANGE BH-5035: was "human + tier 2: merge_step must not run, one hold line".
OUT=$(rp_fresh 2 human)
[ -s "$T/rp-merge.txt" ] && grep -q "MERGED=yes" <<<"$OUT" && ok || bad "X12 human + tier 2: the row is inert, merge_step runs (out '$OUT'; err $(cat "$T/rp.err"))"
grep -q "tier_gate_mode" "$T/rp.log" && bad "X12 human + tier 2: no hold line (log: $(cat "$T/rp.log"))" || ok
OUT=$(rp_fresh 1 human)
[ -s "$T/rp-merge.txt" ] && ok || bad "X12 human + tier 1: merge_step runs (out '$OUT'; err $(cat "$T/rp.err"))"
OUT=$(rp_fresh 2 off)
[ -s "$T/rp-merge.txt" ] && grep -q "MERGED=yes" <<<"$OUT" && ok || bad "X12 off + tier 2: merge_step runs (out '$OUT'; err $(cat "$T/rp.err"))"
OUT=$(rp_fresh 2 none)
[ -s "$T/rp-merge.txt" ] && ok || bad "X12 no row (default off) + tier 2: merge_step runs (out '$OUT')"
# TEST-CHANGE BH-5035: was "an unreadable row holds".
OUT=$(rp_fresh 2 unreadable)
[ -s "$T/rp-merge.txt" ] && ok || bad "X12 an unreadable row holds nothing: merge_step runs (out '$OUT')"
OUT=$(rp_fresh 2 human REQUEST_CHANGES)
[ ! -s "$T/rp-merge.txt" ] && ! grep -q "tier_gate_mode" "$T/rp.log" && ok || bad "X12 a REQUEST_CHANGES is neither merged nor reported as a tier hold (log: $(cat "$T/rp.log"))"
# the beat line names the real hand-off
rp_beat() { # rp_beat <mergify 0|1> <MERGED> [verdict]
  MQ="$1" MERGED="$2" VERDICT="${3:-APPROVE}" bash -c '
    set -uo pipefail
    mc_queue_conductor_only() { [ "$MQ" = 1 ]; }
    NUM=77 AUTHOR=collaborator-1 TIER=2 SLUG=example-org/project-4-fx
    . "$0"; printf "%s\n" "$LINE"' "$T/rp-beat.sh" 2>&1
}
grep -q "APPROVE tier 2, handed to the merge queue — " <<<"$(rp_beat 1 no)" && ok || bad "X12 Mergify beat says 'handed to the merge queue' (got '$(rp_beat 1 no)')"
grep -q "APPROVE tier 2, left for the merge step — " <<<"$(rp_beat 0 no)" && ok || bad "X12 non-Mergify beat says 'left for the merge step' (got '$(rp_beat 0 no)')"
grep -q "auto-merged" <<<"$(rp_beat 0 yes)" && ok || bad "X12 a merged beat still says auto-merged (got '$(rp_beat 0 yes)')"
grep -q "awaiting the operator" <<<"$(rp_beat 0 no)$(rp_beat 1 no)" && bad "X12 no beat says 'awaiting the operator'" || ok
grep -qE "handed|left for" <<<"$(rp_beat 1 no REQUEST_CHANGES)" && bad "X12 a REQUEST_CHANGES beat names no hand-off (got '$(rp_beat 1 no REQUEST_CHANGES)')" || ok

# X13 merge_retry: no tier hold, so a tier 2 under any row is an attempt (BH-5035).
rp_retry() { # rp_retry <tier> <setting>
  printf '{"77":{"verdict":"APPROVE","tier":"%s","served":"claude","merge_retries":0}}\n' "$1" > "$T/rp-state.json"
  : > "$T/rp.log"; : > "$T/rp-merge.txt"
  HARNESS="$T/rp" LOG="$T/rp.log" STATE="$T/rp-state.json" SETV="$2" T="$T" DIR="$DIR" bash -c '
    set -uo pipefail
    STAMP() { printf TS; }
    setting_get() { case "$SETV" in unreadable) return 1 ;; *) printf %s "$SETV" ;; esac; }
    rp_prov_is_claude() { return 0; }
    hold_conductor_owns_merges() { return 1; }
    mc_queue_conductor_only() { return 1; }
    hold_automerge_disabled() { return 1; }
    hold_paused_project() { return 1; }
    mc_pr_view() { echo "OPEN CLEAN"; }
    rp_state_write() { local t; t=$(mktemp); jq "$@" "$STATE" > "$t" && mv "$t" "$STATE"; }
    merge_step() { echo "merge_step $*" >> "$T/rp-merge.txt"; MERGED=no; }
    PROJECT=project-4 SLUG=example-org/project-4-fx MERGED=
    . "$0"
    merge_retry 77 aaaaaaaa1111' "$T/rp-retry.sh" 2>"$T/rp.err"
}
# TEST-CHANGE BH-5035: was "human + tier 2 is held and not an attempt".
rp_retry 2 human
[ -s "$T/rp-merge.txt" ] && ok || bad "X13 merge_retry: human + tier 2 calls merge_step (err $(cat "$T/rp.err"))"
[ "$(jq -r '.["77"].merge_retries' "$T/rp-state.json")" = 1 ] && ok || bad "X13 the tick is an attempt: merge_retries is 1 (state $(cat "$T/rp-state.json"))"
rp_retry 2 off
[ -s "$T/rp-merge.txt" ] && [ "$(jq -r '.["77"].merge_retries' "$T/rp-state.json")" = 1 ] && ok || bad "X13 merge_retry: off + tier 2 retries the merge (state $(cat "$T/rp-state.json"); err $(cat "$T/rp.err"))"

# ============================================================================
# X1 — the WHOLE bin/merge-conductor.sh in a scratch tree.
# ============================================================================
export PATH="${PATH#"$T/ubin:"}"
unset MC_TICK_ID MC_TICK_DIR
unset -f mc_log mc_alert mc_attempt_has mc_attempt_put mc_record_for mc_issue_of mc_verdict vd_standing to_lane_lead_fence \
  to_lane_hold bg_scan_read main_red_exempt flag_active hold_check_thread job_ledger_get job_ledger_put job_artifact_put setting_get
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/../lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/bin/lib/jobs" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/h/tmp" "$T/fakebin"
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || exit 1
scratch_install_closure bin/jobs-client.sh "$T/h" >/dev/null || exit 1
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
printf 'project-4 %s - - 2 box-c\n' "$SLUG" > "$T/h/fleet.conf"; export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s.sh"; chmod +x "$T/h/bin/$s.sh"; done
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
# The harness-authored open list is EMPTY: the external PR is on the REST page only.
echo '[]' > "$T/list.json"
jq -nc --arg u "$U/77" --arg h "$H1" --arg e "$EXT" --arg s "$SLUG" \
  '[{number:77, html_url:$u, draft:false, user:{login:$e}, updated_at:"2026-10-05T00:00:00Z",
     head:{sha:$h, ref:"feature/x-77", repo:{full_name:"collaborator-1/project-4-fx"}}, base:{ref:"main", repo:{full_name:$s}}, labels:[]}]' > "$T/ext-list.json"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s GH_TOKEN=%s\n' "\$*" "\${GH_TOKEN:-<unset>}" >> "$T/c-calls.txt"
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"api -i -X GET repos/$SLUG/pulls?state=open&per_page=100"|*"api -i -X GET repos/$SLUG/pulls?state=open&per_page=100 "*) restpr --raw 200 "\$(cat "$T/ext-list.json")" ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-05T10:00:00Z"}]}' ;;
  *"api -i -X POST repos/$SLUG/issues/77/comments -f body=@mergifyio queue"*)
    printf '%s GH_TOKEN=%s\n' "\$*" "\${GH_TOKEN:-<unset>}" >> "$T/c-posts.txt"; restpr --raw 201 '{"id":901}' ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$T/c-merges.txt"; exit 0 ;;
  *"/pulls/"*"/merge"|*"/pulls/"*"/merge "*) printf '%s\n' "\$*" >> "$T/c-merges.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) restpr --raw 201 '{"id":1}' ;;
  *"api -X POST repos/"*) printf '%s\n' "\$*" >> "$T/c-cond-cmds.txt" ;;
  *"api -i -X GET repos/$SLUG/issues/77/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/77"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/$SLUG/pulls/77"*) restpr OPEN "$H1" feature/x-77 main "" MERGEABLE CLEAN $EXT "" "" ;;
  *"api repos/$SLUG/"*"/comments --paginate"*|*"api repos/$SLUG/pulls/77/reviews --paginate"*) : ;;
  *"api repos/$SLUG/issues/"*) printf '{"state":"open","labels":[],"body":""}\n' ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"api -i -X GET repos/$SLUG/pulls?state=open&per_page=100&sort=created"*|*"api -i -X GET repos/$SLUG/pulls -f state=open"*) restpr --raw 200 "\$(cat "$T/list.json")" ;;
  *"pr list -R $SLUG --state open"*) cat "$T/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
# The worker: a file-backed ledger, review-prs' own verdict row for #77 (the
# shape bin/review-prs.sh's d1 artifacts write), no standing verdicts, and the
# tier_gate_mode row set to human — which the external path must never read.
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET; D=""
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; --data-binary) D="\$2"; shift 2 ;; *) shift ;; esac; done
printf '%s %s\n' "\$M" "\$URL" >> "$T/c-curl.txt"
case "\$M \$URL" in
  "PUT "*/api/ledger) printf '%s\n' "\$D" >> "$T/c-ledger.jsonl"; printf '{"ok":true}\n200\n' ;;
  "GET "*/api/ledger\?*)
    K=\$(printf '%s' "\${URL#*key=}" | sed 's/&.*//' | jq -Rr '@text|gsub("%3A";":")|gsub("%2F";"/")|gsub("%40";"@")')
    R=\$(jq -c --arg k "\$K" 'select(.kind=="autoenqueue" and .key==\$k)' "$T/c-ledger.jsonl" 2>/dev/null | tail -1)
    if [ -n "\$R" ]; then printf '{"ledger":%s}\n200\n' "\$R"; else printf '{"error":"not found"}\n404\n'; fi ;;
  "GET "*/api/verdict\?*pull%2F77*)
    printf '{"verdict":"APPROVE","tier":"2","provenance":"review-prs","job_id":"R77","reviewed_sha":"$H1","artifacts":[]}\n200\n' ;;
  "GET "*/api/verdicts\?*) printf '{"standing":null}\n200\n' ;;
  "GET "*/api/settings/lead_pr_authors) printf '{"setting":{"key":"lead_pr_authors","value":"operator"}}\n200\n' ;;
  "GET "*/api/settings/tier_gate_mode*) printf '{"setting":{"value":"human"}}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"; : > "$T/c-ledger.jsonl"
touch "$T/h/flags/merge-conductor-actions" "$T/h/flags/merge-conductor-merge"
run_tick() { ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x JOBS_URL=http://worker.test GH_TOKEN=pat-default \
  MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
  bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || { echo "tick rc=$? stderr:"; cat "$T/tick.err"; }; }
cposts() { grep -c . "$T/c-posts.txt" 2>/dev/null || true; }
: > "$T/c-posts.txt"; : > "$T/c-curl.txt"; run_tick
[ "$(cposts)" = 1 ] && ok || bad "X1 the whole conductor posts @mergifyio queue once on the external PR (posts: $(cposts); log: $(grep -i 'autoenqueue\|#77\|external' "$T/h/logs/merge-conductor.log" | tail -8))"
jq -e --arg k "$U/77@$H1" 'select(.kind=="autoenqueue" and .key==$k and .status=="enqueued")' "$T/c-ledger.jsonl" >/dev/null && ok || bad "X1 the worker ledger carries the enqueued row (got $(cat "$T/c-ledger.jsonl"))"
grep -q "AUTOENQUEUE $SLUG#77 posted @mergifyio queue at ${H1:0:8}" "$T/h/logs/merge-conductor.log" && ok || bad "X1 an AUTOENQUEUE line names the PR (log: $(grep -i autoenqueue "$T/h/logs/merge-conductor.log" | tail -4))"
grep -q 'GH_TOKEN=pat-default$' "$T/c-posts.txt" && ok || bad "X1 the post runs under the PAT"
grep -q "tier_gate_mode" "$T/c-curl.txt" && bad "X1 the external path reads no tier row ($(grep tier_gate "$T/c-curl.txt"))" || ok
run_tick
[ "$(cposts)" = 1 ] && ok || bad "X1 a second conductor tick does not re-post (posts: $(cposts))"
[ -s "$T/c-merges.txt" ] && bad "X1 never a direct merge call ($(cat "$T/c-merges.txt"))" || ok

echo "external-pr-enqueue: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
