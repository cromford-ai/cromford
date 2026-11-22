#!/bin/bash
# tests/closeout-not-posted.bh-9879-test.sh — BH-9879 item 1: a builder close-out
# that did not post keeps its reason, on the RESULT line and in the ledger.
#
# THE INCIDENT. project-3 TK-747 (2026-11-21) ended PR_CREATED on a pool machine and
# no board close-out was posted. bin/lib/rb/result.sh sent the close-out's
# stderr only to pipeline.log, and a pool machine's pipeline.log is destroyed
# at reap. The RESULT line, the job meta and the `result` artifact all read
# "PR_CREATED …" with no word of why.
#
# THE FIX, driven here through the REAL `# >>> builder-direct close-out` block
# (extracted from the flattened pipeline, as tests/builder-direct-test.sh §6
# does) with a fake bin/board-closeout.sh that writes a say-shaped stderr line:
#   N1 rc!=0 on PR_CREATED appends ` | CLOSEOUT-NOT-POSTED: rc=<n> <why>`
#   N2 the second result_put carries the new line, pr_url unchanged
#   N3 pipeline.log keeps the stderr line and today's miss line
#   N4 every reader still reads the line right (bd_closed_out, the prefix case)
#   N5 rc 0: the CLOSED-OUT marker, no refusal note
#   N6 rc 4 on PLAN_BLOCKED: RESULT unchanged
#   N7 kill flag: RESULT byte-identical, close-out not called
#   N8 bd_refusal_note sanitizes and bounds the reason
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/closeout-not-posted.bh-9879-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/h/bin/lib" "$T/h/env" "$T/h/flags" "$T/h/logs" "$T/h/state" "$T/h/builds"
# scratch-closure-allow: unit-tests bd_refusal_note and the extracted close-out block, not a lane that sources a closure
cp "$DIR/bin/lib/builder-direct.sh" "$T/h/bin/lib/"
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> builder-direct close-out/{f=1;next} /^# <<< builder-direct close-out/{exit} f' \
  "$RB_ALL" > "$T/bd.sh"
[ -s "$T/bd.sh" ] && ok || bad "could not extract the builder-direct block — markers missing?"

# The fake close-out: records its call, writes one say-shaped stderr line
# (CLOSE_ERR, may be empty) and exits CLOSE_RC.
cat > "$T/h/bin/board-closeout.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$CLOSE_SINK"
[ -n "${CLOSE_ERR:-}" ] && printf '%s\n' "$CLOSE_ERR" >&2
[ "${CLOSE_RC:-0}" = 0 ] || exit "$CLOSE_RC"
echo "POSTED project-3/TK-747 -> review"
SH
chmod +x "$T/h/bin/board-closeout.sh"

B="$T/h/builds/bd"
SAY='2026-11-21 08:03:10Z [closeout/project-3/TK-747] client-court, not posting (BLOCKED harness-last)'
# run_bd <result-line> <BUILDER_DIRECT_ON> <CLOSE_RC> <CLOSE_ERR>
run_bd() {
  scratch_rm "$B"; mkdir -p "$B"
  printf '%s\nsecond line\nthird line\n' "$1" > "$B/RESULT"
  printf 'TIER: 2\nVERDICT: APPROVE\n' > "$B/review.md"
  : > "$B/pipeline.log"; : > "$T/close.txt"; : > "$T/calls.txt"
  ( export HARNESS="$T/h" PROJECT=project-3 KEY=TK-747 TICKET=T747 BUILD="$B" \
           BASE=main SLUG=org/repo JOB_ID=J747 BUILDER_EXEC=1 BUILDER_DIRECT_ON="$2" \
           CLOSE_RC="$3" CLOSE_ERR="$4" CLOSE_SINK="$T/close.txt" CALL_SINK="$T/calls.txt"
    bash -c 'set -uo pipefail
      STAMP() { echo TS; }
      STAGE_START() { echo 0; }
      STAGE_END() { :; }
      GH_LIVE() { :; }
      git() { case "$*" in "rev-parse HEAD") echo cafe1234 ;; *log*) printf -- "- did the thing\n" ;; esac; }
      job_result_put()  { printf "result_put %s %s\n" "$1" "$2" >> "$CALL_SINK"; }
      merge_queue_put() { printf "mq_put %s\n" "$*" >> "$CALL_SINK"; }
      wake_put()        { printf "wake %s\n" "$*" >> "$CALL_SINK"; }
      . "'"$T/h/bin/lib/builder-direct.sh"'"
      . "$0"' "$T/bd.sh" >/dev/null 2>&1 )
}
L1() { head -1 "$B/RESULT"; }

# ── N1: rc 4 with a client-court line on PR_CREATED ────────────────────────
PRL='PR_CREATED https://github.com/o/r/pull/1269 | MIGRATION GATE: x'
run_bd "$PRL" 1 4 "$SAY"
[ "$(L1)" = "$PRL | CLOSEOUT-NOT-POSTED: rc=4 client-court, not posting (BLOCKED harness-last)" ] && ok \
  || bad "N1: line 1 must end with the refusal note, got: $(L1)"
[ "$(tail -n +2 "$B/RESULT")" = "second line
third line" ] && ok || bad "N1: lines 2+ of RESULT must survive: $(tail -n +2 "$B/RESULT")"
grep -q 'close-out refusal recorded on the RESULT line (rc=4)' "$B/pipeline.log" && ok \
  || bad "N1: pipeline.log must say the refusal was recorded: $(cat "$B/pipeline.log")"
[ ! -e "$B/RESULT.bd" ] && ok || bad "N1: the rewrite left RESULT.bd behind"

# ── N2: the ledger carries the new line ────────────────────────────────────
[ "$(grep -c '^result_put ' "$T/calls.txt")" = 2 ] && ok \
  || bad "N2: the row must be re-written after the note lands (got $(grep -c '^result_put ' "$T/calls.txt") result_put calls)"
META=$(grep '^result_put ' "$T/calls.txt" | tail -1 | cut -d' ' -f3-)
[ "$(jq -r .result <<<"$META")" = "$(L1)" ] && ok \
  || bad "N2: the last result_put .result must be RESULT line 1, got: $(jq -r .result <<<"$META")"
[ "$(jq -r .pr_url <<<"$META")" = "https://github.com/o/r/pull/1269" ] && ok \
  || bad "N2: .pr_url must still be the PR URL, got: $(jq -r .pr_url <<<"$META")"

# ── N3: pipeline.log keeps what it had ─────────────────────────────────────
grep -qF "$SAY" "$B/pipeline.log" && ok || bad "N3: pipeline.log lost the close-out's stderr line"
grep -q 'no board close-out from this machine' "$B/pipeline.log" && ok \
  || bad "N3: pipeline.log lost today's miss line"

# ── N4: the readers of line 1 ──────────────────────────────────────────────
( . "$T/h/bin/lib/builder-direct.sh"; bd_closed_out "$(head -1 "$B/RESULT")" ) \
  && bad "N4: bd_closed_out must answer NO on a refusal note" || ok
case "$(L1)" in PR_CREATED\ http*) ok ;; *) bad "N4: the line lost its PR_CREATED prefix" ;; esac
grep -q 'CLOSED-OUT:' "$B/RESULT" && bad "N4: a refusal must never carry CLOSED-OUT:" || ok

# rc 1 with comment POST refused on PR_MERGED
run_bd 'PR_MERGED https://github.com/o/r/pull/7' 1 1 '2026-11-21 08:03:10Z [closeout/project-3/TK-747] comment POST refused: {"error":"x"}'
[ "$(L1)" = 'PR_MERGED https://github.com/o/r/pull/7 | CLOSEOUT-NOT-POSTED: rc=1 comment POST refused: {"error":"x"}' ] && ok \
  || bad "N1b: PR_MERGED refusal note wrong, got: $(L1)"
# rc 1 with an empty stderr
run_bd 'PR_CREATED https://github.com/o/r/pull/8' 1 1 ''
[ "$(L1)" = 'PR_CREATED https://github.com/o/r/pull/8 | CLOSEOUT-NOT-POSTED: rc=1 no reason on stderr' ] && ok \
  || bad "N1c: empty stderr must give 'no reason on stderr', got: $(L1)"

# ── N5: rc 0 → the marker, no note ─────────────────────────────────────────
run_bd "$PRL" 1 0 ''
grep -q 'CLOSED-OUT:' <<<"$(L1)" && ok || bad "N5: a posted close-out must carry CLOSED-OUT:, got: $(L1)"
grep -q 'CLOSEOUT-NOT-POSTED' "$B/RESULT" && bad "N5: a posted close-out must carry no refusal note" || ok

# ── N6: rc 4 on PLAN_BLOCKED → unchanged ───────────────────────────────────
run_bd 'PLAN_BLOCKED see plan.md' 1 4 '2026-11-21 08:03:10Z [closeout/project-3/TK-747] not a PR close-out (PLAN_BLOCKED see plan.md) — left for the sweep'
[ "$(cat "$B/RESULT")" = "PLAN_BLOCKED see plan.md
second line
third line" ] && ok || bad "N6: a PLAN_BLOCKED RESULT must stay byte for byte, got: $(L1)"
[ "$(grep -c '^result_put ' "$T/calls.txt")" = 1 ] && ok \
  || bad "N6: no second result_put for a line that got no note"
run_bd 'BUILD_DEFERRED slots full' 1 4 'x'
[ "$(L1)" = 'BUILD_DEFERRED slots full' ] && ok || bad "N6b: BUILD_DEFERRED must stay unchanged, got: $(L1)"

# ── N7: kill flag and watcher → byte-identical ─────────────────────────────
run_bd "$PRL" 0 4 "$SAY"
[ "$(cat "$B/RESULT")" = "$PRL
second line
third line" ] && ok || bad "N7: KILL FLAG: the RESULT must be untouched"
[ ! -s "$T/close.txt" ] && ok || bad "N7: KILL FLAG: the close-out must not be called"

# ── N8: bd_refusal_note sanitizes and bounds ───────────────────────────────
note() { ( . "$T/h/bin/lib/builder-direct.sh"; bd_refusal_note "$@" ); }
LONG=$(printf 'y%.0s' $(seq 1 300))
printf '%s\n\n' "2026-11-21 08:03:10Z [closeout/p/K] a | b	c CLOSED-OUT: x $LONG" > "$T/err1"
N=$(note 4 "$T/err1")
WHY=${N#' | CLOSEOUT-NOT-POSTED: rc=4 '}
[ "${N:0:28}" = ' | CLOSEOUT-NOT-POSTED: rc=4' ] && ok || bad "N8: note prefix wrong: $N"
[ "$(tr -cd '|' <<<"$WHY")" = "" ] && ok || bad "N8: the reason must carry no '|': $WHY"
grep -q 'CLOSED-OUT' <<<"$N" && bad "N8: the note must never carry CLOSED-OUT: $N" || ok
grep -q 'CLOSED_OUT' <<<"$N" && ok || bad "N8: CLOSED-OUT must read CLOSED_OUT: $N"
[ "$(printf '%s' "$WHY" | tr -d '[:print:]' | wc -c)" = 0 ] && ok || bad "N8: control characters left in the reason"
[ "${#WHY}" -le 160 ] && [ "${#WHY}" -ge 150 ] && ok || bad "N8: the reason must be cut to 160 chars, got ${#WHY}"
grep -q '^a ' <<<"$WHY" && ok || bad "N8: the say prefix must be stripped: $WHY"
N=$(BUILDER_DIRECT_REASON_MAX=50 note 4 "$T/err1"); WHY=${N#' | CLOSEOUT-NOT-POSTED: rc=4 '}
[ "${#WHY}" -le 50 ] && ok || bad "N8: BUILDER_DIRECT_REASON_MAX=50 must bound the reason, got ${#WHY}"
N=$(BUILDER_DIRECT_REASON_MAX=junk note 4 "$T/err1"); WHY=${N#' | CLOSEOUT-NOT-POSTED: rc=4 '}
[ "${#WHY}" -le 160 ] && [ "${#WHY}" -ge 150 ] && ok || bad "N8: a junk knob must fall back to 160, got ${#WHY}"
: > "$T/err2"
[ "$(note 1 "$T/err2")" = ' | CLOSEOUT-NOT-POSTED: rc=1 no reason on stderr' ] && ok || bad "N8: empty file"
[ "$(note 1 "$T/no-such-file")" = ' | CLOSEOUT-NOT-POSTED: rc=1 no reason on stderr' ] && ok || bad "N8: missing file"
[ "$( . "$T/h/bin/lib/builder-direct.sh"; bd_refusal_marker )" = 'CLOSEOUT-NOT-POSTED:' ] && ok || bad "N8: bd_refusal_marker"

echo "closeout-not-posted.bh-9879: pass=$PASS fail=$FAIL"
[ "$FAIL" -eq 0 ]
