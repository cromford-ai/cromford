#!/bin/bash
# tests/br-rereview-gate.bh-9437-test.sh — a green fix push asks for a
# re-review of the head it pushed, and rebuild-fresh is held while that review
# is pending (BH-9437 item 4; project-12#9 closed a PR whose green fix push had no
# review yet). bin/blocked-resolver.d/bh-9437-rereview.sh:
#   brlad_rereview_ask   the push arm of br_fix_round: one lead-verdict.sh
#                        request <slug> <num> <sha>, .rereview={head,at,asked}
#   brlad_rereview_gate  br_rebuild_fresh, before the cap check: rc 1 = hold
#   §R1 the ask: one request with the pushed sha, asked=ok; a duplicate answer
#       is ok too; a refused one is asked=failed
#   §R2 a request row requested or running -> rc 3, nothing closed, nothing
#       enqueued, nothing abandoned (the cap close is held too)
#   §R3 release: the row is done with no verdict, a verdict stands, the head
#       moved -> the rebuild goes on
#   §R4 unreadable (verdict rc 2, the jobs read, the head) -> hold; asked=failed
#       with no row -> one re-ask, hold
#   §R5 the call sites: the ask after br_fix_push_note, the gate before the cap
#   §K  BR_REREVIEW_GATE=0 -> no ask, the rebuild goes on
#   §Z  0 vendor calls
# Run: bash tests/br-rereview-gate.bh-9437-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: br-rereview-gate.bh-9437: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
. "$DIR/tests/lib/br-9437.sh" || exit 1
FRAG="$DIR/bin/blocked-resolver.d/bh-9437-rereview.sh"
[ -r "$FRAG" ] && ok || bad "R0 $FRAG is missing"
[ -r "$DIR/catalog/lanes.d/blocked-resolver.knobs.d/BR_REREVIEW_GATE.json" ] && ok || bad "R0 the BR_REREVIEW_GATE knob row is missing"

bl9_extract "$DIR" "$T" br_rebuild_fresh br_cap_key br_rkey br_file br_load br_save br_record br_num \
  br_json_edit br_set_field br_ladder_class br_slug_of_url || exit 1
bl9_tripwire "$T" || exit 1
H="$T/h"; mkdir -p "$H/bin" "$H/state/blocked-resolver"
# The lead CLI: `request` answers per $T/lv-mode (ok | dup | refuse).
cat > "$H/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/lead-verdict.txt"
case "\$(cat "$T/lv-mode" 2>/dev/null || echo ok)" in
  ok)  echo "requested lead review #r1"; exit 0 ;;
  dup) echo "lead-verdict: request refused: a lead review request for this repo, pr and head_sha already exists" >&2; exit 1 ;;
  *)   echo "lead-verdict: worker answered 503" >&2; exit 1 ;;
esac
EOF
chmod +x "$H/bin/lead-verdict.sh"
HA=$(printf 'a%.0s' {1..40}); HB=$(printf 'b%.0s' {1..40})
URL=https://github.com/o/r/pull/9
cat > "$T/drv.sh" <<EOF
set -u
PATH="$T/fakebin:\$PATH"
H="$H"; ST="$H/state/blocked-resolver"; LOG="$T/say.txt"; OBSERVE="\${OBSERVE:-0}"
STAMP() { date -u +%Y-%m-%dT%H:%M:%SZ; }  # determinism: ok a record stamp; no assertion reads it
say() { printf '%s\n' "\$*" >> "\$LOG"; }
mc_slug_of_url() { printf '%s' "\${1#https://github.com/}" | sed 's#/pull/.*##'; }
mc_num_of_url() { grep -oE '[0-9]+\$' <<<"\$1"; }
br_pr_field() { [ -s "$T/head" ] || return 75; cat "$T/head"; }
gh_rest() { printf 'gh_rest %s\n' "\$*" >> "$T/vendor.txt"; return 1; }
# vd_standing: \$T/vd = rc 0 (a verdict stands), 1 (none), 2 (unreadable)
vd_standing() { local r; r=\$(cat "$T/vd" 2>/dev/null || echo 1); [ "\$r" = 0 ] && printf 'BLOCK\tlead\t1\tx\t-\t-\n'; return "\$r"; }
_jobs_req() { printf '%s\n' "\$*" >> "$T/jobs.txt"; [ -e "$T/jobs-fail" ] && return 1
  case "\$2" in /api/lead-reviews*) cat "$T/rows.json" 2>/dev/null || echo '{"requests":[]}' ;; esac; return 0; }
br_is_external() { return 1; }
br_pr_state() { printf open; }
br_hold_gate() { return 0; }
br_board_done_gate() { return 0; }
br_cap_rows() { printf '%s' "\$4"; }
br_rebuild_cap() { printf 3; }
br_rebuild_inflight() { return 1; }
br_supersede_guard() { return 0; }
br_abandon() { printf '%s\n' "\$*" >> "$T/abandon.txt"; }
br_jobs_why() { :; }
br_close_pr() { printf '%s\n' "\$1" >> "$T/closed.txt"; }
br_close_facts() { :; }
br_event() { :; }
br_quiet() { :; }
br_jobs_count() { printf null; }
br_enqueue_fresh() { printf '%s\n' "\$*" >> "$T/enqueue.txt"; }
br_rebuild_settle() { br_json_edit "\$1" "\$2" '.rebuilds = ((.rebuilds // 0) + 1)'; }
. "$T/fns.sh"
for f in "$DIR"/bin/blocked-resolver.d/bh-9437-*.sh; do [ -r "\$f" ] && . "\$f"; done
EOF
RECF="$H/state/blocked-resolver/tproj/tproj-TP-9.json"
REC() { cat "$RECF" 2>/dev/null; }
n() { cat "$T/$1.txt" 2>/dev/null | grep -c .; }
RESET() { local f; for f in "$H/state/blocked-resolver/tproj" "$T"/{say,abandon,closed,enqueue,lead-verdict,jobs}.txt "$T"/{head,vd,rows.json,jobs-fail,lv-mode}; do scratch_rm "$f" 2>/dev/null; done
  mkdir -p "$H/state/blocked-resolver/tproj"
  jq -nc '{project:"tproj",rkey:"tproj-TP-9",rebuilds:0,fixrounds:1,outcome:"",attempts:[]}' > "$RECF"; }
ASK() { ( . "$T/drv.sh"; brlad_rereview_ask tproj tproj-TP-9 o/r "$URL" "$1" review-changes-requested ); }
REBUILD() { ( . "$T/drv.sh"; br_rebuild_fresh tproj o-r-9 "${1:-review-changes-requested}" "$URL" - TP-9 ); }
row() { jq -nc --arg s "$1" --arg h "$2" '{requests:[{id:"r1",repo:"o/r",pr:9,head_sha:$h,status:$s}]}' > "$T/rows.json"; }

# ── §R1: the ask ──────────────────────────────────────────────────────────
RESET; mkdir -p "$H/state/blocked-resolver/tproj"; printf 'old verify\n' > "$H/state/blocked-resolver/tproj/tproj-TP-9.fix-verify.prev.txt"
ASK "$HA"
[ "$(n lead-verdict)" = 1 ] && ok || bad "R1 one lead-verdict call, got $(n lead-verdict)"
grep -qx "request o/r 9 $HA" "$T/lead-verdict.txt" 2>/dev/null && ok || bad "R1 the request names (slug, num, pushed sha): $(cat "$T/lead-verdict.txt" 2>/dev/null)"
[ "$(REC | jq -r '.rereview.head + " " + .rereview.asked')" = "$HA ok" ] && ok || bad "R1 rereview={head,asked:ok}: $(REC | jq -c .rereview)"
[ "$(REC | jq '[.attempts[] | select(.action == "rereview-asked")] | length')" = 1 ] && ok || bad "R1 one rereview-asked attempt row"
[ -e "$H/state/blocked-resolver/tproj/tproj-TP-9.fix-verify.prev.txt" ] && bad "R1 a green push removes the previous round's verify copy" || ok
RESET; printf dup > "$T/lv-mode"; ASK "$HA"
[ "$(REC | jq -r '.rereview.asked')" = ok ] && ok || bad "R1 a duplicate request answer is asked=ok: $(REC | jq -c .rereview)"
RESET; printf refuse > "$T/lv-mode"; ASK "$HA"
[ "$(REC | jq -r '.rereview.asked')" = failed ] && ok || bad "R1 a refused request is asked=failed: $(REC | jq -c .rereview)"

# ── §R2: pending holds the rebuild ────────────────────────────────────────
for st in requested running; do
  RESET; ASK "$HA"; printf '%s' "$HA" > "$T/head"; row "$st" "$HA"
  REBUILD; RC=$?
  [ "$RC" = 3 ] && ok || bad "R2 a $st re-review holds the rebuild: rc $RC, want 3 ($(tail -2 "$T/say.txt"))"
  [ "$(n closed)" = 0 ] && [ "$(n enqueue)" = 0 ] && [ "$(n abandon)" = 0 ] && ok || bad "R2 ($st) nothing closed, enqueued or abandoned (closed $(n closed), enqueue $(n enqueue), abandon $(n abandon))"
done
grep -q 're-review' "$T/say.txt" && ok || bad "R2 the hold is said"
REBUILD; REBUILD
[ "$(grep -c 'rebuild held — the re-review of the pushed fix' "$T/say.txt")" = 1 ] && ok || bad "R2 the pending line is said once per head, got $(grep -c 'rebuild held — the re-review of the pushed fix' "$T/say.txt")"
# the cap close is held too
RESET; ASK "$HA"; printf '%s' "$HA" > "$T/head"; row requested "$HA"
jq -c '.rebuilds = 3' <<<"$(REC)" > "$RECF.new" && mv "$RECF.new" "$RECF"
REBUILD; RC=$?
[ "$RC" = 3 ] && [ "$(n abandon)" = 0 ] && ok || bad "R2 a pending re-review holds the ABANDONED close at the cap too (rc $RC, abandon $(n abandon))"

# ── §R3: release ──────────────────────────────────────────────────────────
RESET; ASK "$HA"; printf '%s' "$HA" > "$T/head"; row done "$HA"
REBUILD; RC=$?
[ "$RC" = 0 ] && [ "$(n enqueue)" = 1 ] && ok || bad "R3 a done request with no verdict releases the gate (rc $RC, enqueue $(n enqueue))"
RESET; ASK "$HA"; printf '%s' "$HA" > "$T/head"; row requested "$HA"; printf 0 > "$T/vd"
REBUILD; RC=$?
[ "$RC" = 0 ] && [ "$(n enqueue)" = 1 ] && ok || bad "R3 a standing verdict releases the gate (rc $RC, enqueue $(n enqueue))"
RESET; ASK "$HA"; printf '%s' "$HB" > "$T/head"; row requested "$HA"
REBUILD; RC=$?
[ "$RC" = 0 ] && [ "$(n enqueue)" = 1 ] && ok || bad "R3 a moved head releases the gate (rc $RC, enqueue $(n enqueue))"
RESET; printf '%s' "$HA" > "$T/head"
REBUILD; RC=$?
[ "$RC" = 0 ] && [ "$(n enqueue)" = 1 ] && [ "$(n jobs)" = 0 ] && ok || bad "R3 no re-review on the record: today's rebuild, no read (rc $RC, jobs $(n jobs))"

# ── §R4: unreadable holds ─────────────────────────────────────────────────
RESET; ASK "$HA"; printf '%s' "$HA" > "$T/head"; printf 2 > "$T/vd"
REBUILD; RC=$?
[ "$RC" = 3 ] && [ "$(n enqueue)" = 0 ] && ok || bad "R4 an unreadable verdict holds (rc $RC)"
RESET; ASK "$HA"; printf '%s' "$HA" > "$T/head"; touch "$T/jobs-fail"
REBUILD; RC=$?
[ "$RC" = 3 ] && [ "$(n enqueue)" = 0 ] && ok || bad "R4 an unreadable request list holds (rc $RC)"
RESET; ASK "$HA"
REBUILD; RC=$?
[ "$RC" = 3 ] && [ "$(n enqueue)" = 0 ] && ok || bad "R4 an unreadable head holds (rc $RC)"
RESET; printf refuse > "$T/lv-mode"; ASK "$HA"; rm -f "$T/lv-mode"; printf '%s' "$HA" > "$T/head"
REBUILD; RC=$?
[ "$RC" = 3 ] && [ "$(n enqueue)" = 0 ] && ok || bad "R4 a failed ask with no row is asked again and held (rc $RC)"
[ "$(n lead-verdict)" = 2 ] && ok || bad "R4 one re-ask, got $(n lead-verdict) lead-verdict calls"
[ "$(REC | jq -r '.rereview.asked')" = ok ] && ok || bad "R4 the re-ask that landed is asked=ok"

# ── §R5: the call sites ───────────────────────────────────────────────────
BODY=$(bl9_fn_body "$T" br_fix_round)
LPN=$(grep -n 'br_fix_push_note "\$p"' <<<"$BODY" | head -1 | cut -d: -f1)
LASK=$(grep -n 'brlad_rereview_ask' <<<"$BODY" | head -1 | cut -d: -f1)
[ -n "$LASK" ] && [ -n "$LPN" ] && [ "$LASK" = $((LPN + 1)) ] && ok || bad "R5 br_fix_round asks right after br_fix_push_note (push note $LPN, ask ${LASK:-absent})"
BODY=$(bl9_fn_body "$T" br_rebuild_fresh)
LCAP=$(grep -n 'if \[ "\$cap" -ge "\$lim" \]; then' <<<"$BODY" | tail -1 | cut -d: -f1)
LG=$(grep -n 'brlad_rereview_gate' <<<"$BODY" | head -1 | cut -d: -f1)
LSG=$(grep -n 'br_supersede_guard' <<<"$BODY" | head -1 | cut -d: -f1)
[ -n "$LG" ] && [ "$LG" -gt "$LSG" ] && [ "$LG" -lt "$LCAP" ] && ok || bad "R5 the gate sits after the supersede guard ($LSG) and before the cap check ($LCAP), at '${LG:-absent}'"

# ── §K: the knob ──────────────────────────────────────────────────────────
RESET; ( export BR_REREVIEW_GATE=0; ASK "$HA" )
[ "$(n lead-verdict)" = 0 ] && ok || bad "K BR_REREVIEW_GATE=0 asks nothing"
RESET; ASK "$HA"; printf '%s' "$HA" > "$T/head"; row requested "$HA"
( export BR_REREVIEW_GATE=0; REBUILD ); RC=$?
[ "$RC" = 0 ] && [ "$(n enqueue)" = 1 ] && ok || bad "K BR_REREVIEW_GATE=0: the rebuild goes on (rc $RC, enqueue $(n enqueue))"

# ── §Z: no vendor ─────────────────────────────────────────────────────────
[ "$(bl9_vendor_calls "$T")" = 0 ] && ok || bad "Z vendor calls: $(cat "$T/vendor.txt")"

echo "br-rereview-gate.bh-9437: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
