#!/bin/bash
# tests/eject-fix-now.bh-6000-test.sh — BH-6000 part 5: a PR the merge queue
# ejected twice gets its fix round NOW, and the round is handed the two failing
# batch runs.
#
# THE INCIDENT (2026-10-11): #4624, #5459, #5697 and #5920 sat parked
# `queue-ejected-twice` with no time bound, waiting for the blocked-resolver's
# next pass, whose first rung (merge main, re-run the PR's own CI) answers
# nothing about a batch build that is red against current main.
#
# Driven, not grepped: the functions and the resolver's marked blocks are
# extracted VERBATIM and run against stubs and the real Mergify dequeue
# comments in tests/fixtures/bh-4428/.
#   E1 bej_eject_runs_parse: the last two dequeues' failing run URLs, newest
#      first, each named with its check and draft
#   E2 mc_eject_fix_now: writes the runs for the resolver and starts
#      `BR_ONLY_PR=<key> blocked-resolver.sh <project>` in the same tick, once
#      per (PR, head); observe mode writes and starts nothing
#   R1 the resolver's ladder: with the runs handed over, a queue-ejected-twice
#      park goes straight to the fix round; without them, or for any other
#      reason, or with the fix rounds spent, the ladder is unchanged
#   R2 the fix-round brief carries both run URLs
#   R3 BR_ONLY_PR keeps only that PR's rows; unset keeps every row
#   R4 a runs file for another head (the fix round pushed a new one) moves
#      neither the ladder nor the brief, and is removed (lead review lr-6024)
#   E3 an unreadable comments read (rc 2) writes no stamp, no file and starts
#      nothing; a SECOND call asks again; the third unreadable read on the
#      head hands the park over without runs (lead reviews lr-6024)
#   E4 the caller of that retry: the conductor's parked-row pass (`parked
#      merged settle`, extracted verbatim) calls mc_eject_fix_now for an OPEN
#      queue-ejected-twice park on every tick, and for nothing else
#   R5 a one-PR run unsets BR_ONLY_PR (no child inherits it) and ends no
#      UNTOUCHED episode (br_untouched_alert, lead review lr-6024)
# Run from anywhere: tests/eject-fix-now.bh-6000-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v setsid >/dev/null || { echo "FAIL: jq/setsid missing"; exit 1; }

FX="$DIR/tests/fixtures/bh-4428"
SLUG=example-org/cromford
KEY="$SLUG#4121"; URL="https://github.com/$SLUG/pull/4121"; HEAD=2150c8f1f93ef0c0a94b05c09e87c425903e4eeb
RUN1="https://github.com/$SLUG/actions/runs/37180690428/job/111374696421"
RUN2="https://github.com/$SLUG/actions/runs/37172502842/job/111350523698"
jq -sc '[.[] | . + {user: {login: "mergify[bot]", type: "Bot"}}]' "$FX/pr4121-dequeue.json" "$FX/pr4049-dequeue.json" > "$T/comments.json"

fnx() { # fnx <file> <name> — one function, verbatim
  awk -v n="$2" '!f && $0 ~ "^"n"\\(\\)[[:space:]]*\\{" {f=1; print; if ($0 ~ /\}[[:space:]]*$/) exit; next} f {print} f && /^}/ {exit}' "$1"
}
blk() { awk -v b="$2" 'index($0, "# >>> " b) {f=1; next} index($0, "# <<< " b) {exit} f' "$1"; }
{ fnx "$DIR/bin/lib/mc-batch-eject.sh" bej_eject_runs_parse
  fnx "$DIR/bin/lib/mc-batch-eject.sh" bej_eject_runs
  fnx "$DIR/bin/lib/mc/queue.sh" mc_eject_runs_file
  fnx "$DIR/bin/lib/mc/queue.sh" mc_eject_fix_now
  fnx "$DIR/bin/lib/mc/classify.sh" mc_handoff_id
  # TEST-CHANGE (BH-5241): br_eject_runs lives in the ladder module since the cut.
  fnx "$DIR/bin/lib/br/ladder.sh" br_eject_runs; } > "$T/fns.sh"
for f in bej_eject_runs_parse bej_eject_runs mc_eject_runs_file mc_eject_fix_now br_eject_runs; do
  grep -qE "^$f\(\)[[:space:]]*\{" "$T/fns.sh" && ok || bad "could not extract $f"
done
PAYLOAD_RE=$(sed -n "s/^BEJ_PAYLOAD_RE='\(.*\)'$/\1/p" "$DIR/bin/lib/mc-batch-eject.sh")
[ -n "$PAYLOAD_RE" ] && ok || bad "could not read BEJ_PAYLOAD_RE"
BR="$DIR/bin/blocked-resolver.sh"
blk "$BR" "ejected twice: fix round first" > "$T/ladder.sh"
blk "$BR" "eject runs brief" > "$T/brief.sh"
blk "$BR" "one-PR run" > "$T/onepr.sh"
for b in ladder brief onepr; do [ -s "$T/$b.sh" ] && ok || bad "could not extract the resolver's $b block"; done

# --- E1. the parser ------------------------------------------------------------
OUT=$(BEJ_PAYLOAD_RE="$PAYLOAD_RE"; . "$T/fns.sh"; bej_eject_runs_parse "$(cat "$T/comments.json")" "$SLUG")
[ "$(grep -c . <<<"$OUT")" = 2 ] && ok || bad "E1 two failing runs, one per dequeue: $OUT"
[ "$(sed -n 1p <<<"$OUT" | cut -d' ' -f1)" = "$RUN1" ] && [ "$(sed -n 2p <<<"$OUT" | cut -d' ' -f1)" = "$RUN2" ] && ok || bad "E1 newest dequeue first: $OUT"
grep -q "^$RUN2 (Pure-logic gate fixtures on draft #4279, dequeued 2026-10-03T22:33:09Z)$" <<<"$OUT" && ok || bad "E1 each run names its check, draft and time: $OUT"

# --- E2. mc_eject_fix_now ------------------------------------------------------
H="$T/h"; mkdir -p "$H/bin" "$H/logs" "$H/state"
printf '#!/bin/bash\nprintf "only=%%s project=%%s\\n" "${BR_ONLY_PR:-}" "${1:-}" >> "%s/br-runs"\n' "$T" > "$H/bin/blocked-resolver.sh"
chmod +x "$H/bin/blocked-resolver.sh"
fixnow() { # fixnow [VAR=val...]
  : > "$T/log"
  ( cd "$T" && env T="$T" H="$H" PAYLOAD_RE="$PAYLOAD_RE" "$@" bash -c '
      set -uo pipefail
      MC_H="$H"; MC_STATE_DIR="$H/state"; BEJ_PAYLOAD_RE="$PAYLOAD_RE"
      mc_log() { printf "%s\n" "$*" >> "$T/log"; }
      mc_attempt_has() { grep -qxF "$1" "$T/attempts" 2>/dev/null; }
      mc_attempt_put() { printf "%s\n" "$1" >> "$T/attempts"; }
      mc_attempt_count() { grep -c "^$1 $2 $3\$" "$T/attempts" 2>/dev/null || true; }
      mc_attempt_put_n() { printf "%s\n" "$*" >> "$T/attempts"; }
      gh_rest_issue_comments() { cat "$T/comments.json"; }
      mc_rest_var() { local __v="$1"; shift; local __o; __o=$("$@") || return 1; printf -v "$__v" "%s" "$__o"; }
      . "$T/fns.sh"
      mc_eject_fix_now cromford "'"$SLUG"'" "'"$KEY"'" "'"$HEAD"'" "'"$URL"'"' )
  local n=0; while [ ! -s "$T/br-runs" ] && [ "$n" -lt 20 ]; do sleep 0.25; n=$((n + 1)); done
}
: > "$T/attempts"; rm -f "$T/br-runs"
fixnow ACTIONS=1
F="$H/state/eject-runs/example-org_cromford_4121"
[ -s "$F" ] && ok || bad "E2 the runs file is written for the resolver ($F)"
[ "$(sed -n 1p "$F" 2>/dev/null)" = "$HEAD" ] && ok || bad "E2 line 1 of the runs file is the head"
grep -qF "$RUN1" "$F" 2>/dev/null && grep -qF "$RUN2" "$F" 2>/dev/null && ok || bad "E2 both failing runs are handed over: $(cat "$F" 2>/dev/null)"
grep -qx "only=$KEY project=cromford" "$T/br-runs" 2>/dev/null && ok || bad "E2 the resolver is started now for this PR only: $(cat "$T/br-runs" 2>/dev/null)"
grep -qxF "ejectfix $KEY $HEAD" "$T/attempts" && ok || bad "E2 the hand-over is stamped for the head"
# TEST-CHANGE (Fable review of 9a72142b2, finding 1): the line said "started",
# which the detached launch cannot know; it now says "launch requested".
grep -q "launch requested for this PR now (BR_ONLY_PR), its fix round handed 2 failing batch run(s)" "$T/log" && ok || bad "E2 the log says so: $(cat "$T/log")"
rm -f "$T/br-runs"; fixnow ACTIONS=1; sleep 0.5
[ ! -s "$T/br-runs" ] && ok || bad "E2 a second call on the same head starts nothing (got: $(cat "$T/br-runs"))"
: > "$T/attempts"; rm -f "$T/br-runs" "$F"; fixnow ACTIONS=0; sleep 0.5
[ ! -s "$T/br-runs" ] && [ ! -e "$F" ] && [ ! -s "$T/attempts" ] && ok || bad "E2 observe mode writes and starts nothing"
grep -q 'would hand queue-ejected-twice to a fix round now' "$T/log" && ok || bad "E2 observe mode says what it would do: $(cat "$T/log")"
: > "$T/attempts"; fixnow ACTIONS=1   # leave the file in place for R

# --- R1. the resolver's ladder ----------------------------------------------------
ladder() { # ladder <reason> <action> <fixrounds> [runs-file-present 1|0]
  ( T="$T" H="$H" ROWHEAD="${ROWHEAD:-$HEAD}" bash -c '
      set -uo pipefail
      MC_H="$H"; MC_STATE_DIR="$H/state"
      say() { printf "%s\n" "$*" >> "$T/rlog"; }
      br_num() { [ "$2" = fixrounds ] && printf "%s" "$FIXN" || printf 0; }
      br_fix_cap() { printf 1; }
      mc_slug_of_url() { local u="${1#https://github.com/}"; printf "%s" "${u%/pull/*}"; }
      mc_num_of_url() { printf "%s" "${1##*/}"; }
      mc_row_field() { [ "$2" = 4 ] && printf "%s" "$ROWHEAD"; }
      . "$T/fns.sh"
      p=cromford; rkey=BH-4121; reason="$1"; action="$2"; ladder_action="$2"; FIXN="$3"; st="{}"; url="'"$URL"'"; rowhead=""
      . "$T/ladder.sh"
      printf "%s\n" "$action"' _ "$@" )
}
[ "$(ladder queue-ejected-twice mechanical 0)" = fix-round ] && ok || bad "R1 with the runs handed over, rung 1 becomes the fix round"
[ "$(ladder queue-ejected-twice regen 0)" = fix-round ] && ok || bad "R1 ...and so does the regenerate rung"
[ "$(ladder queue-ejected-twice mechanical 1)" = mechanical ] && ok || bad "R1 with the fix rounds spent, the ladder is unchanged"
[ "$(ladder red-twice mechanical 0)" = mechanical ] && ok || bad "R1 another reason keeps its ladder"
mv "$F" "$F.away"
[ "$(ladder queue-ejected-twice mechanical 0)" = mechanical ] && ok || bad "R1 without the runs file the ladder is unchanged"
mv "$F.away" "$F"

# --- R2. the brief -------------------------------------------------------------
BRIEF=$( T="$T" H="$H" bash -c '
  set -uo pipefail
  MC_H="$H"; MC_STATE_DIR="$H/state"
  mc_slug_of_url() { local u="${1#https://github.com/}"; printf "%s" "${u%/pull/*}"; }
  mc_num_of_url() { printf "%s" "${1##*/}"; }
  . "$T/fns.sh"
  brief=""; reason=queue-ejected-twice; url="'"$URL"'"; ejruns=""; head="${BHEAD:-'"$HEAD"'}"
  . "$T/brief.sh"
  printf "%s" "$brief"' )
grep -q 'THE MERGE QUEUE EJECTED THIS PR TWICE' <<<"$BRIEF" && ok || bad "R2 the brief names the ejections: $BRIEF"
grep -qF "$RUN1" <<<"$BRIEF" && grep -qF "$RUN2" <<<"$BRIEF" && ok || bad "R2 the brief carries both failing runs: $BRIEF"

# --- R4. a runs file for another head is stale (lead review lr-6024) ----------------
# The fix round pushed a new head and that head's runs could not be read: the old
# head's file must move neither the ladder nor the brief, and it is removed.
cp "$F" "$F.keep"
[ "$(ROWHEAD=fedcba9876543210fedcba9876543210fedcba98 ladder queue-ejected-twice mechanical 0)" = mechanical ] && ok \
  || bad "R4 a runs file for an older head must not send the ladder to the fix round"
[ ! -e "$F" ] && ok || bad "R4 the stale runs file is removed"
cp "$F.keep" "$F"
BRIEF4=$( T="$T" H="$H" bash -c '
  set -uo pipefail
  MC_H="$H"; MC_STATE_DIR="$H/state"
  mc_slug_of_url() { local u="${1#https://github.com/}"; printf "%s" "${u%/pull/*}"; }
  mc_num_of_url() { printf "%s" "${1##*/}"; }
  . "$T/fns.sh"
  brief=""; reason=queue-ejected-twice; url="'"$URL"'"; ejruns=""; head=fedcba9876543210fedcba9876543210fedcba98
  . "$T/brief.sh"
  printf "%s" "$brief"' )
grep -qF "$RUN1" <<<"$BRIEF4" && bad "R4 the brief must not carry an older head's runs: $BRIEF4" || ok
cp "$F.keep" "$F"
[ "$(ROWHEAD="${HEAD:0:12}" ladder queue-ejected-twice mechanical 0)" = fix-round ] && ok \
  || bad "R4 a short form of the same head still matches"

# --- E3. an unreadable read is retried, not stamped (lead reviews lr-6024) ---------
# TEST-CHANGE (lead review lr-6024 of 9a72142b2): E3 checked one call only, so it
# passed with no retry path at all. It now makes three calls on the same head:
# the first two stamp nothing and start nothing, the third hands the park over.
e3call() {
  : > "$T/log"
  ( cd "$T" && env T="$T" H="$H" PAYLOAD_RE="$PAYLOAD_RE" ACTIONS=1 bash -c '
      set -uo pipefail
      MC_H="$H"; MC_STATE_DIR="$H/state"; BEJ_PAYLOAD_RE="$PAYLOAD_RE"
      mc_log() { printf "%s\n" "$*" >> "$T/log"; }
      mc_attempt_has() { grep -qxF "$1" "$T/attempts" 2>/dev/null; }
      mc_attempt_put() { printf "%s\n" "$1" >> "$T/attempts"; }
      mc_attempt_count() { grep -c "^$1 $2 $3\$" "$T/attempts" 2>/dev/null || true; }
      mc_attempt_put_n() { printf "%s\n" "$*" >> "$T/attempts"; }
      gh_rest_issue_comments() { return 1; }
      mc_rest_var() { local __v="$1"; shift; local __o; __o=$("$@") || return 1; printf -v "$__v" "%s" "$__o"; }
      . "$T/fns.sh"
      mc_eject_fix_now cromford "'"$SLUG"'" "'"$KEY"'" "'"$HEAD"'" "'"$URL"'"' )
}
: > "$T/attempts"; rm -f "$T/br-runs" "$F"
e3call
! grep -qxF "ejectfix $KEY $HEAD" "$T/attempts" && ok || bad "E3 an unreadable read must not stamp the head: $(cat "$T/attempts")"
[ ! -e "$T/br-runs" ] && [ ! -e "$F" ] && ok || bad "E3 an unreadable read starts nothing and writes no file"
grep -q 'could not be read (rc 2, read 1 of 3) — the next tick' "$T/log" && ok || bad "E3 the log says the next tick asks again: $(cat "$T/log")"
e3call
! grep -qxF "ejectfix $KEY $HEAD" "$T/attempts" && [ ! -e "$T/br-runs" ] && ok || bad "E3 the second unreadable read still stamps and starts nothing"
grep -q 'read 2 of 3' "$T/log" && ok || bad "E3 the second call asked again: $(cat "$T/log")"
e3call
n=0; while [ ! -s "$T/br-runs" ] && [ "$n" -lt 20 ]; do sleep 0.25; n=$((n + 1)); done
grep -qxF "ejectfix $KEY $HEAD" "$T/attempts" && ok || bad "E3 the third unreadable read stamps the head: $(cat "$T/attempts")"
grep -qx "only=$KEY project=cromford" "$T/br-runs" 2>/dev/null && [ ! -e "$F" ] && ok || bad "E3 ...and hands the park over without runs: $(cat "$T/br-runs" 2>/dev/null)"
grep -q 'launch requested for this PR now (BR_ONLY_PR), its fix round handed 0 failing batch run(s)' "$T/log" && ok || bad "E3 the hand-over without runs is logged: $(cat "$T/log")"
rm -f "$T/br-runs"; cp "$F.keep" "$F"

# --- E4. the retry's caller: the conductor's parked-row pass -------------------------
blk "$DIR/bin/merge-conductor.sh" "parked merged settle" > "$T/parked.sh"
grep -q 'mc_eject_fix_now' "$T/parked.sh" && ok || bad "E4 the parked-row pass calls mc_eject_fix_now"
ROWS4="$T/rows4.tsv"
{ printf '%s\tBLOCKED_HUMAN\t1\t%s\t%s\t-\tqueue-ejected-twice\t%s\n' "$SLUG#4121" "$HEAD" "$HEAD" "$URL"
  printf '%s\tBLOCKED_HUMAN\t1\taaaa\taaaa\t-\tqueue-ejected-twice\thttps://github.com/%s/pull/4122\n' "$SLUG#4122" "$SLUG"
  printf '%s\tBLOCKED_HUMAN\t1\tbbbb\tbbbb\t-\tred-twice\thttps://github.com/%s/pull/4123\n' "$SLUG#4123" "$SLUG"
  printf '%s\tWAIT_CI\t1\tcccc\tcccc\t-\tqueue-ejected\thttps://github.com/%s/pull/4124\n' "$SLUG#4124" "$SLUG"; } > "$ROWS4"
parked() {
  : > "$T/fixnow-calls"
  ( T="$T" bash -c '
      set -uo pipefail
      SLUG="'"$SLUG"'"; P=cromford; MC_ROWS="$T/rows4.tsv"
      mc_only_has() { return 0; }
      mc_pr_lock() { printf "%s/lock-%s" "$T" "$2"; }
      mc_pr_view() { case "$1" in */4122) echo "MERGED br" ;; *) echo "OPEN br" ;; esac; }
      mc_log() { :; }; mc_record_for() { :; }; mc_verdict() { printf "APPROVE\t-\t-\t-\t-"; }
      conductor_settle() { printf "settle %s\n" "$1" >> "$T/fixnow-calls"; }
      mc_handoff_release() { :; }
      mc_eject_fix_now() { printf "fixnow %s %s %s\n" "$3" "$4" "$1" >> "$T/fixnow-calls"; }
      . "$T/parked.sh"' )
}
parked
grep -qx "fixnow $SLUG#4121 $HEAD cromford" "$T/fixnow-calls" && ok || bad "E4 an OPEN queue-ejected-twice park is offered to mc_eject_fix_now: $(cat "$T/fixnow-calls")"
[ "$(grep -c '^fixnow' "$T/fixnow-calls")" = 1 ] && ok || bad "E4 a merged park, another reason and a WAIT_CI row are not offered: $(cat "$T/fixnow-calls")"
grep -qx "settle $SLUG#4122" "$T/fixnow-calls" && ok || bad "E4 the merged park is still settled: $(cat "$T/fixnow-calls")"
parked
grep -qx "fixnow $SLUG#4121 $HEAD cromford" "$T/fixnow-calls" && ok || bad "E4 the next tick offers it again (mc_eject_fix_now returns at once for a stamped head)"

# --- R3. BR_ONLY_PR ------------------------------------------------------------
onepr() { # onepr [BR_ONLY_PR] — the CANDS lines left
  ( T="$T" ONLY_PR="${1:-}" bash -c '
      set -uo pipefail
      say() { printf "%s\n" "$*" >> "$T/rlog"; }
      [ -n "$ONLY_PR" ] && BR_ONLY_PR="$ONLY_PR"
      CANDS=( "$(printf "conductor\tcromford\tBH-1\tqueue-ejected-twice\thttps://github.com/example-org/cromford/pull/4121\t-\tBH-1\t-")"
              "$(printf "conductor\tcromford\tBH-2\tred-twice\thttps://github.com/example-org/cromford/pull/4122\t-\tBH-2\t-")"
              "$(printf "conductor\tproject-3\tOM-3\tred-twice\thttps://github.com/example-org/project-3/pull/4121\t-\tOM-3\t-")" )
      . "$T/onepr.sh"
      for l in ${CANDS[@]+"${CANDS[@]}"}; do printf "%s\n" "$l" | cut -f3; done' )
}
[ "$(onepr "$KEY" | paste -sd' ' -)" = "BH-1" ] && ok || bad "R3 BR_ONLY_PR keeps only that PR's row (got: $(onepr "$KEY" | paste -sd' ' -))"
[ "$(onepr | paste -sd' ' -)" = "BH-1 BH-2 TK-3" ] && ok || bad "R3 unset keeps every row (got: $(onepr | paste -sd' ' -))"

# --- R5. a one-PR run: the filter is not inherited, and no episode is ended -----------
[ "$( ( T="$T" bash -c '
    set -uo pipefail
    say() { :; }; BR_ONLY_PR="'"$KEY"'"; export BR_ONLY_PR; CANDS=()
    . "$T/onepr.sh"
    printf "%s|%s|%s" "${BR_ONLY_PR-unset}" "$(bash -c "printf %s \"\${BR_ONLY_PR-unset}\"")" "${br_only_pr_run:-}"' ) )" = "unset|unset|$KEY" ] \
  && ok || bad "R5 after the filter BR_ONLY_PR is unset for this run and its children, and br_only_pr_run names the PR"
UT="$DIR/bin/lib/br/opt/untouched.sh"
fnx "$UT" br_untouched_alert > "$T/ut.sh"
grep -q '^br_untouched_alert() {' "$T/ut.sh" && ok || bad "could not extract br_untouched_alert"
ut() { # ut [br_only_pr_run] -> kept|removed for an open episode the run did not see
  mkdir -p "$T/ust"; echo 1 > "$T/ust/.untouched-cromford"
  ( T="$T" ONEPR="${1:-}" bash -c '
      set -uo pipefail
      say() { :; }; ST="$T/ust"; H="$T"; declare -A BR_UNTOUCHED_OLDEST=()
      [ -n "$ONEPR" ] && br_only_pr_run="$ONEPR"
      . "$T/ut.sh"
      br_untouched_alert 1791800000' )
  [ -e "$T/ust/.untouched-cromford" ] && echo kept || echo removed
}
[ "$(ut "$KEY")" = kept ] && ok || bad "R5 a one-PR run ends no UNTOUCHED episode"
[ "$(ut)" = removed ] && ok || bad "R5 a full run still ends an episode it found no park for"

echo "eject-fix-now.bh-6000: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
