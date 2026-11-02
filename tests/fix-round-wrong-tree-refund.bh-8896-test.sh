#!/bin/bash
# tests/fix-round-wrong-tree-refund.bh-8896-test.sh — a fix round the hub reap
# closed as wrong-tree does not count against the fix rung, and the ladder
# offers the fix round again (BH-8896, comment 6558202642).
#
# project-6-os #3511, 2026-11-01: FXR-1465 ran on a reused pool machine, its
# record carried TK-3496's build, and br_fix_adopt acted on the round's
# `terminal` word with no read of the pool row: fixrounds went to 1 of cap 1 and
# the ladder had no fix round left to offer.
#   F1  br_fix_cap: `fixround_refunds` absent -> every branch as before; 1 -> +1
#   F2  pool row queued/claimed -> the adopt is held: no adopt call, no write
#   F3  pool row failed `wrong-tree: ...` + result terminal -> adopt once, no
#       br_fix_terminal, refunds 1, cap 2, br_ladder_rung answers fix-round
#       (large park at cap 1, and a review park at its review cap)
#   F4  failed with another reason (or `wrong-tree:` not at the start) -> as before
#   F5  done, none, unreadable -> as before; unreadable says so
#   F6  wrong-tree + setup-blocked result -> no refund, nothing spent
#   F7  the head reset and the PR reset set fixround_refunds back to 0
# br_fix_adopt is lifted from bin/blocked-resolver.sh; the record and ladder
# libs and the BH-8896 fragment are the real files. _jobs_req, fix_round_adopt
# and the rung functions are local stubs. 0 network calls.
# Run from anywhere: bash tests/fix-round-wrong-tree-refund.bh-8896-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "fix-round-wrong-tree-refund.bh-8896: jq absent — skipping"; exit 0; }

# shellcheck source=bin/lib/br/record.sh
. "$DIR/bin/lib/br/record.sh" || exit 1
# shellcheck source=bin/lib/br/ladder.sh
. "$DIR/bin/lib/br/ladder.sh" || exit 1
H="$T/h"; ST="$T/st"; LOG="$T/br.log"; OBSERVE=0
mkdir -p "$H/bin" "$ST"
STAMP() { echo 2026-11-01T12:00:00Z; }
FRAG="$DIR/bin/blocked-resolver.d/bh-8896-fix-round-tree.sh"
# shellcheck disable=SC1090
[ -f "$FRAG" ] && . "$FRAG"
awk '/^br_fix_adopt\(\) \{/,/^\}$/' "$DIR/bin/blocked-resolver.sh" > "$T/adopt.sh"
grep -q 'fix_round_adopt' "$T/adopt.sh" && ok || bad "could not extract br_fix_adopt from bin/blocked-resolver.sh"
# shellcheck disable=SC1090,SC1091
. "$T/adopt.sh"

# Counting stubs. Every call is one line in $T/calls; say goes to $T/say.
say() { printf '%s\n' "$*" >> "$T/say"; }
br_event() { echo "br_event $1" >> "$T/calls"; }
fix_round_adopt() { echo "fix_round_adopt $1" >> "$T/calls"; return 0; }
br_fix_terminal() { echo "br_fix_terminal $1" >> "$T/calls"; }
br_rebuild_fresh() { echo "br_rebuild_fresh $1" >> "$T/calls"; }
br_setup_blocked() { echo "br_setup_blocked $2" >> "$T/calls"; }
br_fix_terminal_word() { printf 'REBUILD FRESH instead'; }
# _jobs_req answers the body in $T/q.json, rc in $T/q.rc; the path goes to calls.
_jobs_req() { echo "_jobs_req $2" >> "$T/calls"; local rc; rc=$(cat "$T/q.rc" 2>/dev/null); [ "${rc:-0}" = 0 ] || return "$rc"; cat "$T/q.json"; }
c() { grep -c "$1" "$T/calls" 2>/dev/null || true; }

P=tproj; CK=tproj-TK-3508; ID=1465; URL=https://github.com/o/r/pull/3511
KEY="FXR-$ID-$(printf '%s' "$CK" | sha256sum | cut -c1-8)"
# The reason the T4 reap writes (config/fly-pool.d/3400, the wrong-tree arm):
# the same printf, fed here as the pool row's reason.
WT_REASON=$(printf 'wrong-tree: the record carried another job'"'"'s build (reviewed-sha %s); %s' 708294bb "FIX_ROUND_FINISHED terminal finish=ok")

# pool <status> [reason] — the /api/queue body for $KEY (none = no row)
pool() {
  echo 0 > "$T/q.rc"
  if [ "$1" = none ]; then echo '{"queue":[]}' > "$T/q.json"; return; fi
  jq -nc --arg k "$KEY" --arg s "$1" --arg r "${2:-}" '{queue:[{ticket_key:$k,status:$s,reason:$r}]}' > "$T/q.json"
}
# setup <fixrounds-before> [extra jq on the hub record] — a fresh hub record
setup() {
  scratch_rm "$ST" 2>/dev/null; mkdir -p "$ST/$P"; : > "$T/calls"; : > "$T/say"
  jq -nc --argjson f "$1" --arg p "$P" --arg k "$CK" '{project:$p,rkey:$k,fixrounds:$f,mechanicals:0,rebuilds:0,outcome:"",
     attempts:[{at:"2026-11-01T11:00:00Z",action:"held",reason:"x"}]}' | jq -c "${2:-.}" > "$ST/$P/$CK.json"
}
# adopt <reason> <result> — the row the worker returns; record_out has the round's bump
adopt() {
  local out row
  out=$(jq -c '.fixrounds += 1 | .attempts += [{at:"2026-11-01T11:50:00Z",action:"fix-round",reason:"r",detail:"round ran"}]' "$ST/$P/$CK.json")
  row=$(jq -nc --argjson id "$ID" --arg res "$2" --arg ro "$out" '{id:$id,claimed_by:"pool:m1",result:$res,record_out:$ro}')
  br_fix_adopt "$P" TK-3508 "$1" "$URL" "-" TK-3508 "$CK" "$row"
}
rec() { jq -r "$1" "$ST/$P/$CK.json"; }

# ── F1: br_fix_cap, refunds absent and present ──────────────────────────────
f1() { ( unset MAX_FIXROUNDS MAX_FIXROUNDS_SMALL BR_MAX_FIXROUNDS BR_CONFLICT_FIX_ROUNDS BR_MAX_FIXROUNDS_SMALL BR_REVIEW_FIX_ROUNDS
         br_fix_cap "$1" "$2" "$P" ); }
[ "$(f1 '{}' review-changes-requested)" = 2 ] && ok || bad "F1: review cap, refunds absent, must stay 2 (got $(f1 '{}' review-changes-requested))"
[ "$(f1 '{}' queue-dequeued)" = 1 ] && ok || bad "F1: queue-dequeued, refunds absent, must stay 1"
[ "$(f1 '{"conflict_lines":10}' merge-conflict)" = 2 ] && ok || bad "F1: small shape must stay 2"
[ "$(f1 '{}' merge-conflict)" = 1 ] && ok || bad "F1: large shape must stay 1"
[ "$(f1 '{"conflict_lines":10,"fixround_bonus":1}' merge-conflict)" = 3 ] && ok || bad "F1: small + bonus 1 must stay 3"
[ "$(f1 '{"fixround_refunds":1}' review-changes-requested)" = 3 ] && ok || bad "F1: review cap + 1 refund must be 3 (got $(f1 '{"fixround_refunds":1}' review-changes-requested))"
[ "$(f1 '{"fixround_refunds":1}' queue-dequeued)" = 2 ] && ok || bad "F1: queue-dequeued + 1 refund must be 2"
[ "$(f1 '{"conflict_lines":10,"fixround_refunds":1}' merge-conflict)" = 3 ] && ok || bad "F1: small + 1 refund must be 3"
[ "$(f1 '{"fixround_refunds":1}' merge-conflict)" = 2 ] && ok || bad "F1: large + 1 refund must be 2"
[ "$(f1 '{"conflict_lines":10,"fixround_bonus":1,"fixround_refunds":1}' merge-conflict)" = 4 ] && ok || bad "F1: small + bonus 1 + refund 1 must be 4"

# ── F2: the hub reap has not run -> the adopt is held this tick ─────────────
for s in queued claimed; do
  setup 0; pool "$s"; before=$(cat "$ST/$P/$CK.json")
  adopt merge-conflict terminal
  [ "$(c '^fix_round_adopt')" = 0 ] && ok || bad "F2 $s: the adopt must be held, got $(c '^fix_round_adopt') adopt calls"
  [ "$(cat "$ST/$P/$CK.json")" = "$before" ] && ok || bad "F2 $s: a held adopt wrote the record"
  [ "$(c '^br_fix_terminal')" = 0 ] && ok || bad "F2 $s: a held adopt ran the terminal rung"
  grep -q "adopt held: pool row $KEY is $s" "$T/say" && ok || bad "F2 $s: no hold line: $(cat "$T/say")"
  grep -q "^_jobs_req /api/queue?project=$P&key=$KEY&limit=1$" "$T/calls" && ok || bad "F2 $s: the pool row read is not the frp_put read: $(cat "$T/calls")"
done

# ── F3 THE POINT: a wrong-tree round is refunded, the ladder offers it again ─
setup 0; pool failed "$WT_REASON"
adopt merge-conflict terminal
[ "$(c '^fix_round_adopt')" = 1 ] && ok || bad "F3: the row must be adopted once, got $(c '^fix_round_adopt')"
[ "$(c '^br_fix_terminal')" = 0 ] && ok || bad "F3 THE POINT: a wrong-tree round ran the terminal rung"
[ "$(c '^br_rebuild_fresh')" = 0 ] && ok || bad "F3: a wrong-tree round ran rebuild-fresh"
[ "$(rec '.fixround_refunds // 0')" = 1 ] && ok || bad "F3 THE POINT: fixround_refunds is $(rec '.fixround_refunds // 0'), not 1"
[ "$(rec '.attempts[-1].action')" = fix-round-wrong-tree ] && ok || bad "F3: the last attempt is $(rec '.attempts[-1].action')"
[ "$(rec '[.attempts[] | select(.action=="fix-round")] | length')" = 1 ] && ok || bad "F3: the round's own attempt must stay in history"
[ "$(rec '.fixrounds')" = 1 ] && ok || bad "F3: the round's count stays (the refund raises the cap, not the count)"
cap=$(br_fix_cap "$(cat "$ST/$P/$CK.json")" merge-conflict "$P")
[ "$cap" = 2 ] && ok || bad "F3 THE POINT: br_fix_cap is $cap after the refund, not 2"
[ "$(br_ladder_rung review-blocked 0 "$(rec '.fixrounds')" "$cap")" = fix-round ] && ok || bad "F3 THE POINT: the ladder does not offer the fix round again"
[ "$(c '^br_event resolver_fix_wrong_tree')" = 1 ] && ok || bad "F3: one br_event resolver_fix_wrong_tree, got $(c '^br_event resolver_fix_wrong_tree')"
# The same for a review park at its review cap (2 rounds spent).
setup 1; pool failed "$WT_REASON"
adopt review-changes-requested terminal
[ "$(c '^br_fix_terminal')" = 0 ] && ok || bad "F3 review: a wrong-tree round ran the review terminal"
cap=$(BR_REVIEW_FIX_ROUNDS=2 br_fix_cap "$(cat "$ST/$P/$CK.json")" review-changes-requested "$P")
[ "$cap" = 3 ] && ok || bad "F3 review: br_fix_cap is $cap after the refund, not 3"
[ "$(br_ladder_rung review-blocked 0 "$(rec '.fixrounds')" "$cap")" = fix-round ] && ok || bad "F3 review: the ladder does not offer the fix round again"
# rebuild-fresh and done answers on a wrong-tree row are refunded too.
for r in rebuild-fresh done; do
  setup 0; pool failed "$WT_REASON"
  adopt merge-conflict "$r"
  [ "$(rec '.fixround_refunds // 0')" = 1 ] && ok || bad "F3 $r: no refund"
  [ "$(c '^br_rebuild_fresh')" = 0 ] && ok || bad "F3 $r: rebuild-fresh ran on a wrong-tree row"
done

# ── F4: another failed reason is adopted as before ──────────────────────────
for why in "FIX_ROUND_SETUP_FAILED x" "no wrong-tree: here"; do
  setup 0; pool failed "$why"
  adopt merge-conflict terminal
  [ "$(c '^br_fix_terminal')" = 1 ] && ok || bad "F4 '$why': the terminal rung must run as before"
  [ "$(rec '.fixround_refunds // 0')" = 0 ] && ok || bad "F4 '$why': refunded"
done

# ── F5: done, no row, unreadable -> as before ───────────────────────────────
for s in done none; do
  setup 0; pool "$s"
  adopt merge-conflict terminal
  [ "$(c '^br_fix_terminal')" = 1 ] && ok || bad "F5 $s: the terminal rung must run as before"
  [ "$(rec '.fixround_refunds // 0')" = 0 ] && ok || bad "F5 $s: refunded"
done
setup 0; pool failed "$WT_REASON"; echo 1 > "$T/q.rc"
adopt merge-conflict terminal
[ "$(c '^br_fix_terminal')" = 1 ] && ok || bad "F5 unreadable: fail-open, the adopt runs as before"
[ "$(rec '.fixround_refunds // 0')" = 0 ] && ok || bad "F5 unreadable: refunded on an unread row"
grep -q "pool row $KEY unreadable" "$T/say" && ok || bad "F5 unreadable: no unreadable line: $(cat "$T/say")"
setup 0; echo 0 > "$T/q.rc"; echo 'not json' > "$T/q.json"
adopt merge-conflict terminal
[ "$(c '^br_fix_terminal')" = 1 ] && ok || bad "F5 unparseable: fail-open, the adopt runs as before"

# ── F6: a setup-blocked wrong-tree round spent nothing, nothing refunded ────
setup 0; pool failed "$WT_REASON"
adopt merge-conflict "setup-blocked $(printf 'FIX_ROUND_WRONG_TREE: x' | base64 | tr -d '\n')"
[ "$(c '^fix_round_adopt')" = 1 ] && ok || bad "F6: the row must be adopted once"
[ "$(rec '.fixround_refunds // 0')" = 0 ] && ok || bad "F6: a setup-blocked round was refunded"
[ "$(c '^br_setup_blocked')" = 0 ] && ok || bad "F6: a wrong-tree setup-blocked row paged again"
grep -q 'nothing was spent, nothing refunded' "$T/say" && ok || bad "F6: no say line: $(cat "$T/say")"

# ── F7: the head reset and the PR reset clear the refund ────────────────────
awk '/^br_head_reset\(\) \{/,/^\}$/' "$DIR/bin/lib/br/headgate.sh" > "$T/hr.sh"
awk '/^bpr_is_pr_url\(\) \{/,/^\}$/; /^bpr_retire\(\) \{/,/^\}$/; /^bpr_scope\(\) \{/,/^\}$/' "$DIR/bin/blocked-resolver.d/bh-8339-pr-record.sh" > "$T/pr.sh"
grep -q '^bpr_scope()' "$T/pr.sh" && grep -q '^br_head_reset()' "$T/hr.sh" && ok || bad "F7: could not extract the reset functions"
# shellcheck disable=SC1090,SC1091
. "$T/hr.sh"; . "$T/pr.sh"
br_pr_state() { echo open; }
setup 1 '.fixround_refunds = 1'
br_head_reset "$P" "$CK" merge-conflict "$URL" "$(printf 'a%.0s' {1..40})" "$(printf 'b%.0s' {1..40})" >/dev/null
[ "$(rec '.fixround_refunds // 0')" = 0 ] && ok || bad "F7: the head reset kept fixround_refunds $(rec '.fixround_refunds // 0')"
setup 1 '.fixround_refunds = 1 | .outcome = "ABANDONED" | .abandoned_url = "https://github.com/o/r/pull/3500"'
bpr_scope "$P" TK-3508 "$CK" merge-conflict "$URL" >/dev/null
[ "$(rec '.outcome')" = "" ] && ok || bad "F7: the PR reset did not run"
[ "$(rec '.fixround_refunds // 0')" = 0 ] && ok || bad "F7: the PR reset kept fixround_refunds $(rec '.fixround_refunds // 0')"

echo "fix-round-wrong-tree-refund.bh-8896: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
