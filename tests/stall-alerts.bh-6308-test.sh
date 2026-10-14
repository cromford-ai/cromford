#!/bin/bash
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# tests/stall-alerts.bh-6308-test.sh — BH-6308: two silent stalls page.
#
#   stalehold:<p>:<n>                an ai-build ticket whose newest decisive
#                                    comment is a HOLD older than STALL_HOLD_MAX_H
#                                    (STALL_HOLD_HOTFIX_H with `hotfix`) and whose
#                                    owner is not active.
#   stalledblocker:<p>:<child>:<P>   a hard Blocked-by on an open parent whose last
#                                    merged slice is older than STALL_PARENT_MERGED_H,
#                                    with no open child, no open PR, no build.
#
#   J1-J12  the pure HOLD judge and the owner check (bin/lib/stall-alerts.sh)
#   B1-B6   the parent judge and the hard-blocker reader, plus negatives
#   D1      the knob defaults and clamps
#   S1-S8   the `# >>> stall alerts` block of bin/pipeline-health.sh, extracted
#           VERBATIM by its markers, then the real retraction epilogue, against
#           the gh REST fixture (tests/lib/gh-rest-fx.sh) and a stub _jobs_req
#
#   HARNESS_TEST_SANDBOX=1 bash tests/stall-alerts.bh-6308-test.sh   exit 0 = pass
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/gh-rest-fx.sh
. "$DIR/tests/lib/gh-rest-fx.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

STLIB="$DIR/bin/lib/stall-alerts.sh"
PH="$DIR/bin/pipeline-health.sh"
NOW=$(date +%s)
[ -r "$STLIB" ] && ok || bad "setup: $STLIB is missing"

mkdir -p "$T/h/logs" "$T/h/state" "$T/h/env" "$T/h/prompts" "$T/tmp"
scratch_install_closure bin/lib/stall-alerts.sh "$T/h" >/dev/null || bad "setup: the stall-alerts closure did not install"
# pipeline-health sources the list helpers itself, before the block runs.
scratch_install_closure bin/lib/gh-rest-list.sh "$T/h" >/dev/null || bad "setup: the gh-rest-list closure did not install"
printf 'demo o/demo - - 2 box\n' > "$T/h/fleet.conf"
printf 'Branch names use BH-<issue-number>.\n' > "$T/h/prompts/demo.md"
: > "$T/h/env/global.env"
ghfx_init
export HARNESS="$T/h" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH" GH_ETAG=0
unset STALL_HOLD_CHECK STALL_HOLD_MAX_H STALL_HOLD_HOTFIX_H STALL_OWNER_WINDOW_H \
      STALL_PARENT_CHECK STALL_PARENT_MERGED_H STALL_MAX_THREADS
LIB="$T/h/bin/lib/stall-alerts.sh"

# ── fixtures ──────────────────────────────────────────────────────────────
iso() { jq -nr --argjson e "$1" '$e | todate'; }
# cm <body> <epoch> [login] [type] — one REST issue comment
cm() { jq -nc --arg b "$1" --arg at "$(iso "$2")" --arg u "${3:-operator}" --arg ty "${4:-User}" --argjson id "$2" \
         '{id:$id, body:$b, created_at:$at, user:{login:$u, type:$ty}}'; }
# iss <n> <labels-csv> [title] [body] — one REST issue (search items share the shape)
iss() { jq -nc --argjson n "$1" --arg l "$2" --arg t "${3:-BH-$1: some work}" --arg b "${4:-}" \
          '{number:$n, state:"open", title:$t, body:$b, html_url:("https://github.com/o/demo/issues/" + ($n|tostring)),
            labels:($l | split(",") | map(select(. != "") | {name:.}))}'; }
# pr <n> <title> <head-ref> <sha> — one REST pull
pr() { jq -nc --argjson n "$1" --arg t "$2" --arg r "$3" --arg s "$4" \
         '{number:$n, title:$t, state:"open", html_url:("https://github.com/o/demo/pull/" + ($n|tostring)), head:{ref:$r, sha:$s}}'; }
commit() { jq -nc --arg s "$1" --arg d "$(iso "$2")" '{sha:$s, commit:{committer:{date:$d}}}'; }
# xmerged <pr> <epoch> <body> — a timeline cross-reference from a merged PR
xmerged() { jq -nc --argjson n "$1" --arg at "$(iso "$2")" --arg b "$3" \
  '{event:"cross-referenced", source:{issue:{number:$n, title:("BH-" + ($n|tostring) + ": slice"), body:$b, state:"closed",
    html_url:("https://github.com/o/demo/pull/" + ($n|tostring)), repository:{full_name:"o/demo"},
    pull_request:{merged_at:$at, html_url:("https://github.com/o/demo/pull/" + ($n|tostring))}}}}'; }
# xchild <n> <body> — a timeline cross-reference from an open issue
xchild() { jq -nc --argjson n "$1" --arg b "$2" \
  '{event:"cross-referenced", source:{issue:{number:$n, title:"child", body:$b, state:"open", pull_request:null,
    repository:{full_name:"o/demo"}}}}'; }
arr() { if [ "$#" -eq 0 ]; then echo '[]'; else printf '%s\n' "$@" | jq -sc .; fi; }

HOLDL='HOLD: the Mac lead session (fix-5129) owns this until the refactor lands'
PART0='{"participants":[],"online_window_s":300}'

# The jobs ledger stub: /api/participants from $T/participants.json, a jobs row
# per ticket key from $T/jobs-<KEY>.json, {"jobs":[]} when none. $T/jobs-down
# fails every jobs read, $T/part-down every participants read (rc 1).
_jobs_req() {
  local f k
  case "$2" in
    /api/participants*) [ -e "$T/part-down" ] && return 1; f="$T/participants.json" ;;
    /api/jobs*) [ -e "$T/jobs-down" ] && return 1
      k="${2#*ticket_id=}"; k="${k%%&*}"; f="$T/jobs-$k.json" ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$2" >> "$T/jobs-calls.log"
  if [ -r "$f" ]; then cat "$f"; else case "$2" in /api/jobs*) echo '{"jobs":[]}' ;; *) echo "$PART0" ;; esac; fi
  return 0
}
jobrow() { jq -nc --arg s "$1" --arg c "$(iso "$2")" '{jobs:[{status:$s, created_at:$c, updated_at:$c, last_beat_at:null}]}'; }
reset_fx() { ghfx_routes_reset; ghfx_log_reset; rm -f "$T"/jobs-*.json "$T/participants.json" "$T/jobs-down" "$T/part-down" "$T/budget-low"; : > "$T/jobs-calls.log"; }

# fn <function> [args...] — run one lib function in a subshell; stdout to
# $T/fn.out, rc to $T/fn.rc
fn() { ( . "$LIB" || exit 99; "$@" ) > "$T/fn.out" 2> "$T/fn.err"; echo $? > "$T/fn.rc"; }
out() { cat "$T/fn.out"; }
rc()  { cat "$T/fn.rc"; }
f1()  { cut -f1 "$T/fn.out" | head -n 1; }

# ── the lib sources clean ──────────────────────────────────────────────────
SRC=$( set -u; . "$LIB" 2>&1; echo "rc=$?" )
[ "$SRC" = "rc=0" ] && ok || bad "sourcing bin/lib/stall-alerts.sh under set -u must print nothing and answer 0, got: $SRC"

# ════════════════════════════════════════════════════════════════════════════
# J. stall_hold_judge and stall_owner_active
# ════════════════════════════════════════════════════════════════════════════
I5=$(iss 5 ai-build)
# J1 — a bot comment with the word HOLD decides nothing.
fn stall_hold_judge "$I5" "$(arr "$(cm "$HOLDL" $((NOW-46800)) harness-bot Bot)")" "$NOW"
[ "$(f1)" = clear ] && [ "$(rc)" = 1 ] && ok || bad "J1: a bot HOLD must judge clear rc 1, got '$(out)' rc $(rc)"

# J2 — `Do NOT RESUME` after the HOLD: still held, and old, so stale.
fn stall_hold_judge "$I5" "$(arr "$(cm "$HOLDL" $((NOW-46800)))" "$(cm 'Do NOT RESUME this yet' $((NOW-3600)) operator)")" "$NOW"
[ "$(f1)" = stale ] && [ "$(rc)" = 0 ] && ok || bad "J2: Do NOT RESUME keeps the HOLD; a 13h HOLD must judge stale, got '$(out)' rc $(rc)"

# J3 — the edges: 11:59 fresh, 12h + 1s stale.
fn stall_hold_judge "$I5" "$(arr "$(cm "$HOLDL" $((NOW-43140)))")" "$NOW"
[ "$(f1)" = fresh ] && [ "$(rc)" = 1 ] && ok || bad "J3: an 11h59m HOLD must judge fresh, got '$(out)' rc $(rc)"
fn stall_hold_judge "$I5" "$(arr "$(cm "$HOLDL" $((NOW-43201)))")" "$NOW"
[ "$(f1)" = stale ] && [ "$(rc)" = 0 ] && ok || bad "J3: a 12h+1s HOLD must judge stale, got '$(out)' rc $(rc)"
[ "$(cut -f2 "$T/fn.out")" = 43201 ] && ok || bad "J3: the age field must be 43201, got '$(out)'"
[ "$(cut -f5 "$T/fn.out")" = "$HOLDL" ] && ok || bad "J3: the line field must be the HOLD line, got '$(out)'"
[ "$(cut -f3 "$T/fn.out")" = "$(iso $((NOW-43201)))" ] && ok || bad "J3: the at field must be the comment's created_at, got '$(out)'"

# J4 — a hotfix HOLD: 2h fresh, 4h stale.
IH=$(iss 5 ai-build,hotfix)
fn stall_hold_judge "$IH" "$(arr "$(cm "$HOLDL" $((NOW-7200)))")" "$NOW"
[ "$(f1)" = fresh ] && ok || bad "J4: a 2h hotfix HOLD must judge fresh, got '$(out)'"
fn stall_hold_judge "$IH" "$(arr "$(cm "$HOLDL" $((NOW-14400)))")" "$NOW"
[ "$(f1)" = stale ] && ok || bad "J4: a 4h hotfix HOLD must judge stale, got '$(out)'"

# J5 — a title HOLD is out of scope: other, never stale.
fn stall_hold_judge "$(iss 5 ai-build 'BH-5 (HOLD): later')" '[]' "$NOW"
[ "$(f1)" = other ] && [ "$(rc)" != 0 ] && ok || bad "J5: a title HOLD must judge other, got '$(out)' rc $(rc)"

# The owner check. Ticket BH-5, no PR, no job row unless set.
owner() { # owner <prs-json> <participants-json|?>
  fn stall_owner_active demo o/demo 5 BH-5 "$HOLDL" "$NOW" "$1" "$2"; }
# J6 — participants unreadable: inactive, with a note.
reset_fx; owner '[]' '?'
[ "$(f1)" = inactive ] && [ "$(rc)" = 1 ] && ok || bad "J6: an unreadable participant list must answer inactive rc 1, got '$(out)' rc $(rc)"
grep -q 'participants unreadable' "$T/fn.out" && ok || bad "J6: the notes must say 'participants unreadable', got '$(out)'"
# J7 — a running build row for BH-5: active.
reset_fx; jobrow running $((NOW-90000)) > "$T/jobs-BH-5.json"; owner '[]' "$PART0"
[ "$(f1)" = active ] && [ "$(rc)" = 0 ] && ok || bad "J7: a running build row must answer active, got '$(out)' rc $(rc)"
grep -q 'ticket_id=BH-5' "$T/jobs-calls.log" && ok || bad "J7: the jobs read must ask for ticket_id=BH-5: $(cat "$T/jobs-calls.log")"
# A finished build row 2h old is inside the 12h window: active. 13h old: not.
reset_fx; jobrow succeeded $((NOW-7200)) > "$T/jobs-BH-5.json"; owner '[]' "$PART0"
[ "$(f1)" = active ] && ok || bad "J7b: a build row updated 2h ago must answer active, got '$(out)'"
reset_fx; jobrow succeeded $((NOW-46800)) > "$T/jobs-BH-5.json"; owner '[]' "$PART0"
[ "$(f1)" = inactive ] && ok || bad "J7c: a build row 13h old must answer inactive, got '$(out)'"
# J8 — a live participant named in the line: active.
P8=$(jq -nc --arg t "$(iso $((NOW-60)))" '{participants:[{name:"FIX-5129", last_seen_at:$t}], online_window_s:300}')
reset_fx; owner '[]' "$P8"
[ "$(f1)" = active ] && [ "$(rc)" = 0 ] && ok || bad "J8: participant fix-5129 seen 60s ago and named in the line must answer active, got '$(out)'"
# word-bounded: fix-512 is not fix-5129
P8b=$(jq -nc --arg t "$(iso $((NOW-60)))" '{participants:[{name:"fix-512", last_seen_at:$t}], online_window_s:300}')
reset_fx; owner '[]' "$P8b"
[ "$(f1)" = inactive ] && ok || bad "J8b: participant fix-512 is not named by 'fix-5129' (word-bounded), got '$(out)'"
# J9 — named but last seen an hour ago (window 300s): inactive.
P9=$(jq -nc --arg t "$(iso $((NOW-3600)))" '{participants:[{name:"fix-5129", last_seen_at:$t}], online_window_s:300}')
reset_fx; owner '[]' "$P9"
[ "$(f1)" = inactive ] && [ "$(rc)" = 1 ] && ok || bad "J9: a named participant seen 1h ago must answer inactive, got '$(out)'"
# J10 — the ticket's open PR head commit is 13h old: inactive. 1h old: active.
reset_fx; ghfx_route GET 'repos/o/demo/commits/abc123' 200 "$(commit abc123 $((NOW-46800)))"
owner "$(arr "$(pr 90 'BH-5: the fix' ticket/bh-5 abc123)")" "$PART0"
[ "$(f1)" = inactive ] && ok || bad "J10: a PR head commit 13h old must answer inactive, got '$(out)'"
grep -q 'repos/o/demo/commits/abc123' "$T/gh-argv.log" && ok || bad "J10: the head commit must be read: $(cat "$T/gh-argv.log")"
reset_fx; ghfx_route GET 'repos/o/demo/commits/abc123' 200 "$(commit abc123 $((NOW-3600)))"
owner "$(arr "$(pr 90 'chore: rename' ticket/bh-5-r2 abc123)")" "$PART0"
[ "$(f1)" = active ] && ok || bad "J10b: a PR on ticket/bh-5-r2 pushed 1h ago must answer active, got '$(out)'"
# a PR of ANOTHER ticket (ticket/bh-50) pushed 1h ago is not this owner
reset_fx; ghfx_route GET 'repos/o/demo/commits/abc123' 200 "$(commit abc123 $((NOW-3600)))"
owner "$(arr "$(pr 91 'BH-50: other' ticket/bh-50 abc123)")" "$PART0"
[ "$(f1)" = inactive ] && ok || bad "J10c: a PR of BH-50 must not count for BH-5, got '$(out)'"
# the head commit read fails: inactive, with a note
reset_fx; ghfx_route GET 'repos/o/demo/commits/abc123' 502 '{}'
owner "$(arr "$(pr 90 'BH-5: the fix' ticket/bh-5 abc123)")" "$PART0"
[ "$(f1)" = inactive ] && grep -q 'head abc123 unreadable' "$T/fn.out" && ok || bad "J10d: an unreadable head must answer inactive with 'head abc123 unreadable', got '$(out)'"
# J11 — the jobs read fails: inactive, with a note.
reset_fx; touch "$T/jobs-down"; owner '[]' "$PART0"
[ "$(f1)" = inactive ] && grep -q 'jobs unreadable' "$T/fn.out" && ok || bad "J11: a failed jobs read must answer inactive with 'jobs unreadable', got '$(out)'"
# J12 — the author is the person whose comment is at `at`, not the newest commenter.
fn stall_hold_judge "$I5" "$(arr "$(cm "$HOLDL" $((NOW-46800)) alice)" "$(cm 'Noted, thanks.' $((NOW-3600)) bob)" "$(cm 'build log' $((NOW-46800)) harness-bot Bot)")" "$NOW"
[ "$(cut -f4 "$T/fn.out")" = alice ] && ok || bad "J12: the author must be alice (the HOLD comment), got '$(out)'"

# ════════════════════════════════════════════════════════════════════════════
# B. stall_parent_judge and stall_hard_blockers. Child #60, parent #50.
# ════════════════════════════════════════════════════════════════════════════
OPEN50=$(arr "$(iss 50 ai-build)" "$(iss 60 ai-build 'BH-60: child' 'Blocked-by: #50 (hard)')")
pjudge() { fn stall_parent_judge demo o/demo 60 50 "$NOW" "$1" "$2" BH; }
tl50() { ghfx_route GET 'repos/o/demo/issues/50/timeline*' 200 "$(arr "$@")"; }
# B1 — merged 3h + 1s ago, no PR, no build: stale.
reset_fx; tl50 "$(xmerged 70 $((NOW-10801)) 'Part of #50')"
pjudge "$OPEN50" '[]'
[ "$(f1)" = stale ] && [ "$(rc)" = 0 ] && ok || bad "B1: a parent whose slice merged 3h+1s ago must judge stale rc 0, got '$(out)' rc $(rc)"
[ "$(cut -f2 "$T/fn.out")" = https://github.com/o/demo/pull/70 ] && ok || bad "B1: the url field must be the merged PR, got '$(out)'"
[ "$(cut -f3 "$T/fn.out")" = 10801 ] && ok || bad "B1: the age field must be 10801, got '$(out)'"
# B2 — merged 2h ago: ok.
reset_fx; tl50 "$(xmerged 70 $((NOW-7200)) 'Part of #50')"
pjudge "$OPEN50" '[]'
[ "$(f1)" = ok ] && [ "$(rc)" = 1 ] && ok || bad "B2: a slice merged 2h ago must judge ok rc 1, got '$(out)' rc $(rc)"
# B3 — an open PR for BH-50: ok.
reset_fx; tl50 "$(xmerged 70 $((NOW-14400)) 'Part of #50')"
pjudge "$OPEN50" "$(arr "$(pr 80 'BH-50: the rest' feature/x s80)")"
[ "$(f1)" = ok ] && ok || bad "B3: an open PR for the parent key must judge ok, got '$(out)'"
reset_fx; tl50 "$(xmerged 70 $((NOW-14400)) 'Part of #50')"
pjudge "$OPEN50" "$(arr "$(pr 81 'misc' ticket/bh-50-r2 s81)")"
[ "$(f1)" = ok ] && ok || bad "B3b: an open PR on ticket/bh-50-r2 must judge ok, got '$(out)'"
# B4 — the parent's build row is running: ok. An unreadable ledger: unknown.
reset_fx; tl50 "$(xmerged 70 $((NOW-14400)) 'Part of #50')"; jobrow running $((NOW-60)) > "$T/jobs-BH-50.json"
pjudge "$OPEN50" '[]'
[ "$(f1)" = ok ] && ok || bad "B4: a running parent build must judge ok, got '$(out)'"
reset_fx; tl50 "$(xmerged 70 $((NOW-14400)) 'Part of #50')"; touch "$T/jobs-down"
pjudge "$OPEN50" '[]'
[ "$(f1)" = unknown ] && [ "$(rc)" = 2 ] && ok || bad "B4b: an unreadable jobs ledger must judge unknown rc 2, got '$(out)' rc $(rc)"
# B5 — the parent has an open child `Part of #50`: ok.
reset_fx; tl50 "$(xmerged 70 $((NOW-14400)) 'Part of #50')" "$(xchild 65 'Part of #50')"
pjudge "$OPEN50" '[]'
[ "$(f1)" = ok ] && ok || bad "B5: a parent with an open child must judge ok, got '$(out)'"
# The parent is closed (not on the open list, the issue read says closed): ok.
reset_fx; tl50 "$(xmerged 70 $((NOW-14400)) 'Part of #50')"
ghfx_route GET 'repos/o/demo/issues/50' 200 '{"number":50,"state":"closed"}'
pjudge "$(arr "$(iss 60 ai-build)")" '[]'
[ "$(f1)" = ok ] && ok || bad "B-closed: a closed parent must judge ok, got '$(out)'"
# No merged PR names the parent: ok. The timeline fails: unknown.
reset_fx; tl50
pjudge "$OPEN50" '[]'
[ "$(f1)" = ok ] && ok || bad "B-noslice: a parent with no merged slice must judge ok, got '$(out)'"
reset_fx; ghfx_route GET 'repos/o/demo/issues/50/timeline*' 503 '{}'
pjudge "$OPEN50" '[]'
[ "$(f1)" = unknown ] && [ "$(rc)" = 2 ] && ok || bad "B-tl503: a failed timeline must judge unknown rc 2, got '$(out)' rc $(rc)"
# The open PR list is unreadable: unknown, never stale.
reset_fx; tl50 "$(xmerged 70 $((NOW-14400)) 'Part of #50')"
pjudge "$OPEN50" '?'
[ "$(f1)" = unknown ] && ok || bad "B-prs?: an unreadable PR list must judge unknown, got '$(out)'"
# B6 — only a hard Blocked-by line names a parent.
fn stall_hard_blockers $'Some text\nBlocked-by: #50\nBlocked-by: #51 (soft)'
[ -z "$(out)" ] && ok || bad "B6: a soft or unmarked Blocked-by must give no parent, got '$(out)'"
fn stall_hard_blockers $'Intro\nBlocked-by: #50 (hard), #52 (hard)\n- Blocked-by: #53'
[ "$(out | tr '\n' ' ')" = "50 52 " ] && ok || bad "B6b: 'Blocked-by: #50 (hard), #52 (hard)' must give 50 and 52, got '$(out | tr '\n' ' ')'"

# ════════════════════════════════════════════════════════════════════════════
# D1. knobs
# ════════════════════════════════════════════════════════════════════════════
fn stall_knob STALL_HOLD_MAX_H;   [ "$(out)" = 12 ] && ok || bad "D1: STALL_HOLD_MAX_H default must be 12, got '$(out)'"
fn stall_knob STALL_HOLD_HOTFIX_H; [ "$(out)" = 3 ] && ok || bad "D1: STALL_HOLD_HOTFIX_H default must be 3, got '$(out)'"
fn stall_knob STALL_OWNER_WINDOW_H; [ "$(out)" = 12 ] && ok || bad "D1: STALL_OWNER_WINDOW_H default must be 12, got '$(out)'"
fn stall_knob STALL_PARENT_MERGED_H; [ "$(out)" = 3 ] && ok || bad "D1: STALL_PARENT_MERGED_H default must be 3, got '$(out)'"
fn stall_knob STALL_MAX_THREADS;  [ "$(out)" = 30 ] && ok || bad "D1: STALL_MAX_THREADS default must be 30, got '$(out)'"
fn stall_knob STALL_HOLD_CHECK;   [ "$(out)" = 1 ] && ok || bad "D1: STALL_HOLD_CHECK default must be 1, got '$(out)'"
( export STALL_HOLD_MAX_H=x; fn stall_knob STALL_HOLD_MAX_H; [ "$(out)" = 12 ] ) && ok || bad "D1: STALL_HOLD_MAX_H=x must read 12, got '$(out)'"
( export STALL_HOLD_MAX_H=0; fn stall_knob STALL_HOLD_MAX_H; [ "$(out)" = 12 ] ) && ok || bad "D1: STALL_HOLD_MAX_H=0 must read 12, got '$(out)'"
( export STALL_HOLD_MAX_H=6; fn stall_knob STALL_HOLD_MAX_H; [ "$(out)" = 6 ] ) && ok || bad "D1: STALL_HOLD_MAX_H=6 must read 6, got '$(out)'"
( export STALL_MAX_THREADS=500; fn stall_knob STALL_MAX_THREADS; [ "$(out)" = 100 ] ) && ok || bad "D1: STALL_MAX_THREADS=500 must clamp to 100, got '$(out)'"
( export STALL_PARENT_CHECK=0; fn stall_knob STALL_PARENT_CHECK; [ "$(out)" = 0 ] ) && ok || bad "D1: STALL_PARENT_CHECK=0 must read 0, got '$(out)'"
( export STALL_PARENT_CHECK=yes; fn stall_knob STALL_PARENT_CHECK; [ "$(out)" = 1 ] ) && ok || bad "D1: STALL_PARENT_CHECK=yes must read 1, got '$(out)'"
# The hotfix knob is what the judge reads: STALL_HOLD_HOTFIX_H=5 makes a 4h hotfix HOLD fresh.
( export STALL_HOLD_HOTFIX_H=5; fn stall_hold_judge "$IH" "$(arr "$(cm "$HOLDL" $((NOW-14400)))")" "$NOW"; [ "$(f1)" = fresh ] ) \
  && ok || bad "D1: STALL_HOLD_HOTFIX_H=5 must make a 4h hotfix HOLD fresh, got '$(out)'"

# ════════════════════════════════════════════════════════════════════════════
# S. the pipeline-health block, then the real retraction epilogue
# ════════════════════════════════════════════════════════════════════════════
A=$(grep -c '^# >>> stall alerts (BH-6308)' "$PH")
B=$(grep -c '^# <<< stall alerts' "$PH")
[ "$A" = 1 ] && [ "$B" = 1 ] && ok || bad "bin/pipeline-health.sh must carry exactly one '# >>> stall alerts (BH-6308)' … '# <<< stall alerts' block (open=$A close=$B)"
awk '/^# <<< stale parent/{d=1} d && /^# >>> stall alerts \(BH-6308\)/{o=1} END{exit !o}' "$PH" \
  && ok || bad "the stall alerts block must follow '# <<< stale parent'"
awk '/^# >>> stall alerts \(BH-6308\)/{f=1;next} /^# <<< stall alerts/{f=0;n=1;next} n && /^fi # PH_ALL/{print "ok"; exit} n && /[^[:space:]]/{exit}' "$PH" | grep -qx ok \
  && ok || bad "the stall alerts block must end right before 'fi # PH_ALL' (inside the full run)"
awk '/^# >>> stall alerts \(BH-6308\)/{f=1;next} /^# <<< stall alerts/{exit} f' "$PH" > "$T/block.sh"
sed -n '/^# ── Retraction epilogue/,/^rm -f "\$FIRED"$/p' "$PH" > "$T/epi.sh"
RL=$(grep -m1 '^RETRACT_NS=' "$PH")
RNS=$( eval "$RL"; printf '%s' "$RETRACT_NS" )
grep -qE "^($RNS):" <<<"stalehold:demo:5" && ok || bad "stalehold is not in RETRACT_NS, so a RESUME never retracts its page"
grep -qE "^($RNS):" <<<"stalledblocker:demo:60:50" && ok || bad "stalledblocker is not in RETRACT_NS"
[ -s "$T/epi.sh" ] && ok || bad "setup: could not extract the retraction epilogue"

drive() { # drive [VAR=val...] — one tick: the block, then the epilogue
  : > "$T/alerts.txt"; ghfx_log_reset; : > "$T/jobs-calls.log"
  [ -s "$T/h/state/health-alerted.json" ] || echo '{}' > "$T/h/state/health-alerted.json"
  ( set -uo pipefail
    for kv in "$@"; do export "${kv?}"; done
    H="${DRIVE_H:-$T/h}"; PROJECTS=demo
    DEDUP="$H/state/health-alerted.json"; [ -s "$DEDUP" ] || echo '{}' > "$DEDUP"
    FIRED="$H/state/health-fired.test"; : > "$FIRED"
    ACTIVE="$H/state/health-active.txt"; touch "$ACTIVE"
    eval "$RL"
    STAMP() { echo "2026-10-12 20:00:00Z"; }
    alert_emit() { :; }
    gh_budget_low() { [ -e "$T/budget-low" ]; }
    alert() { printf '%s|%s\n' "$2" "$3" >> "$T/alerts.txt"; echo "$2" >> "$FIRED"; }
    # shellcheck source=/dev/null
    . "$T/h/bin/lib/gh-rest-list.sh"
    # shellcheck source=/dev/null
    . "$T/block.sh"; echo reached
    # shellcheck source=/dev/null
    . "$T/epi.sh" ) > "$T/drive.out" 2>&1
}
nalerts() { grep -c "^$1" "$T/alerts.txt"; }
ACT="$T/h/state/health-active.txt"
PLOG="$T/h/logs/pipeline-health.log"
search() { # search <item-json>... — the HOLD candidate search answers these
  ghfx_route GET 'search/issues*' 200 "$(jq -nc --argjson i "$(arr "$@")" '{total_count:($i|length), incomplete_results:false, items:$i}')"; }
quiet_parent() { ghfx_route GET 'repos/o/demo/issues' 200 '[]'; }
quiet_hold() { search; }

# S1 — a 13h HOLD, no job row, no PR, no participant: one alert that quotes it.
reset_fx; : > "$ACT"; : > "$PLOG"
search "$I5"; quiet_parent
ghfx_route GET 'repos/o/demo/issues/5/comments' 200 "$(arr "$(cm "$HOLDL" $((NOW-46800)))")"
ghfx_route GET 'repos/o/demo/pulls' 200 '[]'
drive
grep -qx reached "$T/drive.out" && ok || bad "S1: the block did not run to its end: $(cat "$T/drive.out")"
[ "$(nalerts stalehold:)" = 1 ] && ok || bad "S1: exactly one stalehold alert expected, got: $(cat "$T/alerts.txt")"
S1L=$(grep '^stalehold:demo:5|' "$T/alerts.txt")
[ -n "$S1L" ] && ok || bad "S1: the alert must be keyed stalehold:demo:5 (console row ph-stalehold_demo_5): $(cat "$T/alerts.txt")"
case "$S1L" in *"\"$HOLDL\""*) ok ;; *) bad "S1: the alert must quote the HOLD line: $S1L" ;; esac
case "$S1L" in *operator*) ok ;; *) bad "S1: the alert must name the author operator: $S1L" ;; esac
case "$S1L" in *13h*) ok ;; *) bad "S1: the alert must give the age 13h: $S1L" ;; esac
# lead review lr-6333 of 65b1c1765: the search is sorted oldest-updated first,
# so a thread a person touched lately (a RESUME) falls behind the stale ones.
grep -q 'search/issues?q=.*&sort=updated&order=asc' "$T/gh-argv.log" && ok || bad "S1: the HOLD search must sort by updated ascending: $(grep search "$T/gh-argv.log")"
case "$S1L" in *RESUME*) ok ;; *) bad "S1: the alert must name RESUME: $S1L" ;; esac
case "$S1L" in *https://github.com/o/demo/issues/5*) ok ;; *) bad "S1: the alert must link the issue: $S1L" ;; esac
grep -qx 'stalehold:demo:5' "$ACT" && ok || bad "S1: stalehold:demo:5 must stand in health-active.txt after the tick"

# S7 — the next tick, a person said RESUME: the epilogue retracts the key.
ghfx_routes_reset; search "$I5"; quiet_parent; ghfx_route GET 'repos/o/demo/pulls' 200 '[]'
ghfx_route GET 'repos/o/demo/issues/5/comments' 200 "$(arr "$(cm "$HOLDL" $((NOW-46800)))" "$(cm 'RESUME' $((NOW-600)))")"
drive
[ "$(nalerts stalehold:)" = 0 ] && ok || bad "S7: a RESUME must raise no stalehold: $(cat "$T/alerts.txt")"
grep -q 'RESOLVED stalehold:demo:5' "$PLOG" && ok || bad "S7: the epilogue must retract stalehold:demo:5: $(cat "$PLOG")"
grep -qx 'stalehold:demo:5' "$ACT" && bad "S7: stalehold:demo:5 still stands after the RESUME" || ok

# S2 — the same 13h HOLD, plus an open PR ticket/bh-5 pushed 1h ago: quiet.
reset_fx; : > "$ACT"
search "$I5"; quiet_parent
ghfx_route GET 'repos/o/demo/issues/5/comments' 200 "$(arr "$(cm "$HOLDL" $((NOW-46800)))")"
ghfx_route GET 'repos/o/demo/pulls' 200 "$(arr "$(pr 90 'fix things' ticket/bh-5 abc123)")"
ghfx_route GET 'repos/o/demo/commits/abc123' 200 "$(commit abc123 $((NOW-3600)))"
drive
[ "$(nalerts stalehold:)" = 0 ] && ok || bad "S2: a PR push 1h ago makes the owner active, no alert expected: $(cat "$T/alerts.txt")"
grep -q 'commits/abc123' "$T/gh-argv.log" && ok || bad "S2: the PR head commit must be read"

# S3 — hotfix, HOLD 4h old, no owner: one alert, age 4h.
reset_fx; : > "$ACT"
search "$IH"; quiet_parent; ghfx_route GET 'repos/o/demo/pulls' 200 '[]'
ghfx_route GET 'repos/o/demo/issues/5/comments' 200 "$(arr "$(cm "$HOLDL" $((NOW-14400)))")"
drive
[ "$(nalerts stalehold:demo:5)" = 1 ] && ok || bad "S3: a 4h hotfix HOLD must raise one alert: $(cat "$T/alerts.txt")"
grep -q '^stalehold:demo:5|.*4h' "$T/alerts.txt" && ok || bad "S3: the alert must give 4h: $(cat "$T/alerts.txt")"
# The participant list is unreadable: the alert still fires, and says so.
reset_fx; : > "$ACT"; touch "$T/part-down"
search "$I5"; quiet_parent; ghfx_route GET 'repos/o/demo/pulls' 200 '[]'
ghfx_route GET 'repos/o/demo/issues/5/comments' 200 "$(arr "$(cm "$HOLDL" $((NOW-46800)))")"
drive
grep -q '^stalehold:demo:5|.*participants unreadable' "$T/alerts.txt" && ok || bad "S3b: an unreadable participant list must page with the note: $(cat "$T/alerts.txt")"

# S4 — a RESUME by a person after the HOLD: quiet, and no PR or participant read.
reset_fx; : > "$ACT"
search "$I5"; quiet_parent; ghfx_route GET 'repos/o/demo/pulls' 200 '[]'
ghfx_route GET 'repos/o/demo/issues/5/comments' 200 "$(arr "$(cm "$HOLDL" $((NOW-46800)))" "$(cm 'RESUME' $((NOW-3600)))")"
drive
[ "$(nalerts stalehold:)" = 0 ] && ok || bad "S4: a RESUME after the HOLD must raise nothing: $(cat "$T/alerts.txt")"
grep -q 'participants' "$T/jobs-calls.log" && bad "S4: a cleared HOLD must not read the participant list" || ok

# S5 — a hard Blocked-by on parent #50, last slice 4h ago, no PR, no build.
reset_fx; : > "$ACT"
quiet_hold; ghfx_route GET 'repos/o/demo/pulls' 200 '[]'
ghfx_route GET 'repos/o/demo/issues' 200 "$OPEN50"
tl50 "$(xmerged 70 $((NOW-14400)) 'Part of #50')"
drive
grep -qx reached "$T/drive.out" && ok || bad "S5: the block did not run to its end: $(cat "$T/drive.out")"
[ "$(nalerts stalledblocker:)" = 1 ] && ok || bad "S5: exactly one stalledblocker alert expected: $(cat "$T/alerts.txt")"
S5L=$(grep '^stalledblocker:demo:60:50|' "$T/alerts.txt")
case "$S5L" in *"#60"*"#50"*) ok ;; *) bad "S5: the alert must name #60 and #50: ${S5L:-$(cat "$T/alerts.txt")}" ;; esac
case "$S5L" in *https://github.com/o/demo/pull/70*4h*) ok ;; *) bad "S5: the alert must name the slice PR and 4h: ${S5L:-none}" ;; esac
# the soft twin: a plain Blocked-by raises nothing
reset_fx; : > "$ACT"
quiet_hold; ghfx_route GET 'repos/o/demo/pulls' 200 '[]'
ghfx_route GET 'repos/o/demo/issues' 200 "$(arr "$(iss 50 ai-build)" "$(iss 60 ai-build 'BH-60: child' 'Blocked-by: #50')")"
tl50 "$(xmerged 70 $((NOW-14400)) 'Part of #50')"
drive
[ "$(nalerts stalledblocker:)" = 0 ] && ok || bad "S5b: a soft Blocked-by must raise nothing: $(cat "$T/alerts.txt")"
grep -q 'issues/50/timeline' "$T/gh-argv.log" && bad "S5b: a soft Blocked-by must not read the parent's timeline" || ok
# an unknown judge carries the standing pair key (timeline 503)
reset_fx; echo 'stalledblocker:demo:60:50' > "$ACT"
quiet_hold; ghfx_route GET 'repos/o/demo/pulls' 200 '[]'
ghfx_route GET 'repos/o/demo/issues' 200 "$OPEN50"
ghfx_route GET 'repos/o/demo/issues/50/timeline*' 503 '{}'
drive
[ "$(nalerts stalledblocker:)" = 0 ] && ok || bad "S5c: an unknown parent must raise nothing: $(cat "$T/alerts.txt")"
grep -qx 'stalledblocker:demo:60:50' "$ACT" && ok || bad "S5c: an unknown parent must carry its standing key (a skip is never a clear)"
# the open issue list fails: every standing stalledblocker key of the project is carried
reset_fx; echo 'stalledblocker:demo:60:50' > "$ACT"
quiet_hold; ghfx_route GET 'repos/o/demo/issues' 502 '{}'
drive
grep -qx 'stalledblocker:demo:60:50' "$ACT" && ok || bad "S5d: a failed issue list must carry stalledblocker:demo:60:50"

# S5e (lead review lr-6333) — two children of parent #50: ONE judge, so one
# timeline read of #50, and both pairs page.
reset_fx; : > "$ACT"
quiet_hold; ghfx_route GET 'repos/o/demo/pulls' 200 '[]'
ghfx_route GET 'repos/o/demo/issues' 200 "$(arr "$(iss 50 ai-build)" "$(iss 60 ai-build 'BH-60: child' 'Blocked-by: #50 (hard)')" "$(iss 61 ai-build 'BH-61: child' 'Blocked-by: #50 (hard)')")"
tl50 "$(xmerged 70 $((NOW-14400)) 'Part of #50')"
drive
[ "$(nalerts stalledblocker:)" = 2 ] && ok || bad "S5e: both children of #50 must page: $(cat "$T/alerts.txt")"
[ "$(grep -c 'issues/50/timeline' "$T/gh-argv.log")" -le 2 ] && ok || bad "S5e: #50's timelines must be read once for both children, got $(grep -c 'issues/50/timeline' "$T/gh-argv.log") reads"
# S5f — STALL_MAX_THREADS=1 and two parents: the second is not judged, its
# pair key is carried, and one page-cut alert says so.
reset_fx; echo 'stalledblocker:demo:62:51' > "$ACT"
quiet_hold; ghfx_route GET 'repos/o/demo/pulls' 200 '[]'
ghfx_route GET 'repos/o/demo/issues' 200 "$(arr "$(iss 50 ai-build)" "$(iss 51 ai-build)" "$(iss 60 ai-build 'BH-60: child' 'Blocked-by: #50 (hard)')" "$(iss 62 ai-build 'BH-62: child' 'Blocked-by: #51 (hard)')")"
tl50 "$(xmerged 70 $((NOW-14400)) 'Part of #50')"
drive STALL_MAX_THREADS=1
grep -q '^stalledblocker:demo:page-cut|' "$T/alerts.txt" && ok || bad "S5f: a parent past the cap must raise the page-cut alert: $(cat "$T/alerts.txt")"
grep -q 'issues/51/timeline' "$T/gh-argv.log" && bad "S5f: the parent past the cap must not be read" || ok
grep -qx 'stalledblocker:demo:62:51' "$ACT" && ok || bad "S5f: the pair past the cap must carry its standing key"

# S6 — the search answers 502: no alert, and the standing key is carried.
reset_fx; echo 'stalehold:demo:5' > "$ACT"; : > "$PLOG"
ghfx_route GET 'search/issues*' 502 '{}'; quiet_parent
drive
grep -qx reached "$T/drive.out" && ok || bad "S6: the block did not run to its end: $(cat "$T/drive.out")"
[ -s "$T/alerts.txt" ] && bad "S6: a failed search paged: $(cat "$T/alerts.txt")" || ok
grep -qx 'stalehold:demo:5' "$ACT" && ok || bad "S6: a failed search must carry stalehold:demo:5 (a skip is never a clear)"
grep -q 'RESOLVED stalehold' "$PLOG" && bad "S6: a failed search retracted a page" || ok
# a failed comment read carries that ticket's key
reset_fx; echo 'stalehold:demo:5' > "$ACT"
search "$I5"; quiet_parent; ghfx_route GET 'repos/o/demo/issues/5/comments' 502 '{}'
drive
grep -qx 'stalehold:demo:5' "$ACT" && ok || bad "S6b: a failed comment read must carry stalehold:demo:5"
# gh budget low: no read at all, both namespaces carried
reset_fx; printf 'stalehold:demo:5\nstalledblocker:demo:60:50\n' > "$ACT"; touch "$T/budget-low"
drive
[ -s "$T/gh-argv.log" ] && bad "S6c: a low gh budget must make no gh read: $(cat "$T/gh-argv.log")" || ok
grep -qx 'stalehold:demo:5' "$ACT" && grep -qx 'stalledblocker:demo:60:50' "$ACT" \
  && ok || bad "S6c: a low gh budget must carry both namespaces: $(cat "$ACT")"
# the lib is missing: both namespaces carried
reset_fx; mkdir -p "$T/h0/state" "$T/h0/logs"; cp "$T/h/fleet.conf" "$T/h0/"
printf 'stalehold:demo:5\nstalledblocker:demo:60:50\n' > "$T/h0/state/health-active.txt"
drive DRIVE_H="$T/h0"
grep -qx reached "$T/drive.out" && ok || bad "S6d: the block must run to its end with no lib: $(cat "$T/drive.out")"
grep -qx 'stalehold:demo:5' "$T/h0/state/health-active.txt" && grep -qx 'stalledblocker:demo:60:50' "$T/h0/state/health-active.txt" \
  && ok || bad "S6d: a missing lib must carry both namespaces: $(cat "$T/h0/state/health-active.txt")"
# both switches off: no read
reset_fx; : > "$ACT"
drive STALL_HOLD_CHECK=0 STALL_PARENT_CHECK=0
[ -s "$T/gh-argv.log" ] && bad "S6e: both switches off must make no gh read: $(cat "$T/gh-argv.log")" || ok

# S8 — 35 stale candidates: 30 judged and paged, plus one page-cut.
reset_fx; : > "$ACT"
ITEMS=(); for n in $(seq 201 235); do ITEMS+=("$(iss "$n" ai-build)"); done
search "${ITEMS[@]}"; quiet_parent; ghfx_route GET 'repos/o/demo/pulls' 200 '[]'
ghfx_route GET 'repos/o/demo/issues/*/comments' 200 "$(arr "$(cm "$HOLDL" $((NOW-46800)))")"
drive
[ "$(grep -c '^stalehold:demo:[0-9]*|' "$T/alerts.txt")" = 30 ] && ok || bad "S8: 30 stalehold alerts expected, got $(grep -c '^stalehold:demo:[0-9]*|' "$T/alerts.txt")"
[ "$(nalerts 'stalehold:demo:page-cut|')" = 1 ] && ok || bad "S8: exactly one stalehold:demo:page-cut alert expected: $(grep page-cut "$T/alerts.txt")"
[ "$(grep -c '/comments' "$T/gh-argv.log")" = 30 ] && ok || bad "S8: exactly 30 comment threads must be read, got $(grep -c '/comments' "$T/gh-argv.log")"
[ "$(grep -c 'repos/o/demo/pulls' "$T/gh-argv.log")" = 1 ] && ok || bad "S8: the open PR list must be read once per project, got $(grep -c 'repos/o/demo/pulls' "$T/gh-argv.log")"
[ "$(grep -c participants "$T/jobs-calls.log")" = 1 ] && ok || bad "S8: the participant list must be read once per tick, got $(grep -c participants "$T/jobs-calls.log")"

# S8b (lead review lr-6333 of 5db9a1f05) — under the cut, a judged thread whose
# HOLD a person RESUMEd retracts its standing page; only the threads past the
# cut carry their keys. #201 is judged (RESUME after the HOLD), #235 is past it.
reset_fx; printf 'stalehold:demo:201\nstalehold:demo:235\n' > "$ACT"
ITEMS=(); for n in $(seq 201 235); do ITEMS+=("$(iss "$n" ai-build)"); done
search "${ITEMS[@]}"; quiet_parent; ghfx_route GET 'repos/o/demo/pulls' 200 '[]'
ghfx_route GET 'repos/o/demo/issues/201/comments' 200 "$(arr "$(cm "$HOLDL" $((NOW-46800)))" "$(cm 'RESUME' $((NOW-3600)))")"
ghfx_route GET 'repos/o/demo/issues/*/comments' 200 "$(arr "$(cm "$HOLDL" $((NOW-46800)))")"
drive
grep -qx 'stalehold:demo:201' "$ACT" && bad "S8b: a judged, resumed thread must retract its page under the cut" || ok
grep -qx 'stalehold:demo:235' "$ACT" && ok || bad "S8b: a thread past the cut must carry its standing key"

# S9 (lead review lr-6333 of 5db9a1f05) — a thread with 200 comments (the read
# cap) is cut short: the newest HOLD or RESUME may be past it. Not judged: no
# alert, and its standing key is carried.
reset_fx; echo 'stalehold:demo:5' > "$ACT"
search "$I5"; quiet_parent; ghfx_route GET 'repos/o/demo/pulls' 200 '[]'
CMS=("$(cm "$HOLDL" $((NOW-46800)))"); for i in $(seq 2 200); do CMS+=("$(cm "note $i" $((NOW-46000 + i)) bot Bot)"); done
ghfx_route GET 'repos/o/demo/issues/5/comments' 200 "$(arr "${CMS[@]}")"
drive
[ "$(nalerts stalehold:demo:5)" = 0 ] && ok || bad "S9: a thread at the read cap must not page: $(cat "$T/alerts.txt")"
grep -qx 'stalehold:demo:5' "$ACT" && ok || bad "S9: a thread at the read cap must carry its standing key"

echo "stall-alerts (BH-6308): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
