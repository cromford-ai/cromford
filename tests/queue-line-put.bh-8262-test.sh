#!/bin/bash
# tests/queue-line-put.bh-8262-test.sh — triage writes READY-QUEUE lines key first.
#
# THE INCIDENT (project-3 TK-319, 2026-10-21). Sessions appended free-form lines
# to logs/READY-QUEUE.log. 23 of 23 lines on the project-3 box were timestamp-first,
# every reader kept only `^[A-Z]+-[0-9]`, and TK-319 waited about 45 h. The
# readers now re-lead such a line (_rq_norm). This suite pins the WRITER side:
#   A  bin/queue-line-put.sh writes the canonical shape under the sidecar lock,
#      refuses bad fields, keeps one line per key and mirrors through rq_put
#   B  bin/queue-line-lint.sh flags every live line that is not key first
#   C  bin/decision-log.sh runs the lint after a triage session, deduped
#   D  the text a DEFER-path session reads states the shape and the script,
#      and the contract's own command produces a key-first line
# Run: HARNESS_TEST_SANDBOX=1 bash tests/queue-line-put.bh-8262-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
unset HARNESS H HARNESS_CHECKOUT
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

export LANE_GATE_DISABLE=1 READY_QUEUE_ROWS=0 FLEET_CONF="$T/fleet.conf"
printf 'project-3 o/project-3 https://x /api/board 1 small 1.1.1.1\n' > "$FLEET_CONF"

# A scratch harness with COPIES of the shipped scripts and their bin/lib
# closure. bin/jobs-client.sh is not in it, so rq_put is a no-op (0 network).
# A stub written before mk_h wins (the closure install never clobbers).
mk_h() {
  local h="$1" s
  mkdir -p "$h/bin/lib" "$h/logs" "$h/locks" "$h/state"
  for s in bin/queue-line-put.sh bin/queue-line-lint.sh bin/queue-line-drop.sh; do
    scratch_install_closure "$s" "$h" >/dev/null || bad "mk_h: cannot install the closure of $s"
  done
}
put() { local h="$1"; shift; HARNESS="$h" "$h/bin/queue-line-put.sh" "$@"; }

FR='TK-319 cmv6fixture size=L kind=feature :: overlap-guard DEFER vs PR#550 project=project-3'

# --- A1: the canonical line, back from rq_lines unchanged ---------------------
H1="$T/a1"; mk_h "$H1"
OUT=$(put "$H1" project-3 TK-319 cmv6fixture L feature overlap-guard DEFER vs PR#550); RC=$?
[ "$RC" = 0 ] && ok || bad "A1 put must be rc 0 (got $RC)"
[ "$(cat "$H1/logs/READY-QUEUE.log" 2>/dev/null)" = "$FR" ] && ok || bad "A1 file must hold exactly the canonical line (got: '$(cat "$H1/logs/READY-QUEUE.log" 2>/dev/null)')"
[ "$OUT" = "queued $FR" ] && ok || bad "A1 stdout must be 'queued <line>' (got: '$OUT')"
RQ=$( . "$H1/bin/lib/ready-queue.sh" && rq_lines "$H1" project-3 )
[ "$RQ" = "$FR" ] && ok || bad "A1 rq_lines must return the line byte-identical (got: '$RQ')"
grep -q 'project=project-3$' <<<"$RQ" && ok || bad "A1 the line must carry project=project-3"

# --- A2: refused fields -> rc 2, field named, file untouched -----------------
H2="$T/a2"; mk_h "$H2"
printf 'BH-1 x size=S kind=bug :: keep project=cromford\n' > "$H2/logs/READY-QUEUE.log"
cp "$H2/logs/READY-QUEUE.log" "$T/a2.before"
refuse() {  # <field> <args...>
  local field="$1"; shift
  local err rc
  err=$(put "$H2" "$@" 2>&1 >/dev/null); rc=$?
  [ "$rc" = 2 ] && ok || bad "A2 '$*' must be rc 2 (got $rc)"
  grep -qi "$field" <<<"$err" && ok || bad "A2 '$*' stderr must name '$field' (got: '$err')"
  cmp -s "$H2/logs/READY-QUEUE.log" "$T/a2.before" && ok || bad "A2 '$*' must leave the file byte-identical"
}
for k in TK-319 BH- BH-12a BH-5235.2 2026-10-21T23:38:59Z FR319 'BH-1;rm' ''; do
  refuse key project-3 "$k" t1 S bug reason
done
for s in s XXL ''; do refuse size project-3 TK-1 t1 "$s" bug reason; done
for k in docs Feature ''; do refuse kind project-3 TK-1 t1 S "$k" reason; done
for p in project-3 project-32 project-3- -project-3 ''; do refuse project "$p" TK-1 t1 S bug reason; done
refuse ticket project-3 TK-1 '' S bug reason
refuse ticket project-3 TK-1 'a b' S bug reason
refuse ticket project-3 TK-1 'k=v' S bug reason
refuse reason project-3 TK-1 t1 S bug
refuse reason project-3 TK-1 t1 S bug '   '
refuse reason project-3 TK-1 t1 S bug x project=other
for p in project-3 cromford; do
  put "$H2" "$p" TK-77 t S bug "accepted $p" >/dev/null 2>&1 && ok || bad "A2 project '$p' must be accepted"
done
for k in TK-319 BH-8262 TK-4812; do
  put "$H2" project-3 "$k" t XL infra "accepted key" >/dev/null 2>&1 && ok || bad "A2 key '$k' must be accepted"
done

# --- A3: replace keeps one line per key; same args twice is unchanged ---------
H3="$T/a3"; mk_h "$H3"
printf 'TK-3190 other size=S kind=bug :: neighbour project=project-3\n%s\n' "$FR" > "$H3/logs/READY-QUEUE.log"
OUT=$(put "$H3" project-3 TK-319 cmv6fixture L feature new reason); RC=$?
NEW='TK-319 cmv6fixture size=L kind=feature :: new reason project=project-3'
[ "$RC" = 0 ] && [ "$OUT" = "replaced $NEW" ] && ok || bad "A3 a changed line must be 'replaced <line>' rc 0 (got $RC '$OUT')"
[ "$(grep -c '^TK-319[[:space:]]' "$H3/logs/READY-QUEUE.log")" = 1 ] && ok || bad "A3 exactly one TK-319 line after replace"
grep -qxF "$NEW" "$H3/logs/READY-QUEUE.log" && ok || bad "A3 the new line must be in the file"
grep -qxF 'TK-3190 other size=S kind=bug :: neighbour project=project-3' "$H3/logs/READY-QUEUE.log" && ok || bad "A3 the TK-3190 line (prefix near-miss) must be untouched"
cp "$H3/logs/READY-QUEUE.log" "$T/a3.before"
OUT=$(put "$H3" project-3 TK-319 cmv6fixture L feature new reason); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = "unchanged $NEW" ] && ok || bad "A3 the same args twice must be 'unchanged <line>' (got $RC '$OUT')"
cmp -s "$H3/logs/READY-QUEUE.log" "$T/a3.before" && ok || bad "A3 unchanged must leave the file byte-identical"
# a file whose last line has no newline still gets a separate line
printf 'TK-9 t size=S kind=bug :: no newline project=project-3' > "$H3/logs/READY-QUEUE.log"
put "$H3" project-3 TK-10 t S bug second >/dev/null 2>&1
[ "$(grep -c . "$H3/logs/READY-QUEUE.log")" = 2 ] && ok || bad "A3 an append after a line with no newline must start a new line"

# --- A4: tab and newline in the reason become one line of single spaces ------
H4="$T/a4"; mk_h "$H4"
put "$H4" project-3 TK-4 t M copy "$(printf 'one\ttwo\nthree  four\r')" >/dev/null 2>&1
[ "$(cat "$H4/logs/READY-QUEUE.log")" = 'TK-4 t size=M kind=copy :: one two three four project=project-3' ] && ok \
  || bad "A4 reason must be normalised to one line (got: '$(cat "$H4/logs/READY-QUEUE.log")')"

# --- A5: lock held -> rc 1 within QUEUE_LINE_PUT_LOCK_S, file untouched ------
H5="$T/a5"; mk_h "$H5"
printf '%s\n' "$FR" > "$H5/logs/READY-QUEUE.log"; cp "$H5/logs/READY-QUEUE.log" "$T/a5.before"
flock "$H5/logs/READY-QUEUE.log.lock" sleep 8 & LP=$!
sleep 0.5
S0=$(date +%s)
QUEUE_LINE_PUT_LOCK_S=1 put "$H5" project-3 TK-5 t S bug locked >/dev/null 2>&1; RC=$?
S1=$(date +%s)
kill "$LP" 2>/dev/null; wait "$LP" 2>/dev/null
[ "$RC" = 1 ] && ok || bad "A5 a held lock must be rc 1 (got $RC)"
[ $((S1 - S0)) -le 4 ] && ok || bad "A5 the knob QUEUE_LINE_PUT_LOCK_S=1 must bound the wait (took $((S1 - S0))s)"
cmp -s "$H5/logs/READY-QUEUE.log" "$T/a5.before" && ok || bad "A5 a lock timeout must leave the file untouched"

# --- A6: queue-line-drop.sh consumes the put line ----------------------------
H6="$T/a6"; mk_h "$H6"
put "$H6" project-3 TK-319 cmv6fixture L feature overlap-guard DEFER vs PR#550 >/dev/null 2>&1
OUT=$(HARNESS="$H6" "$H6/bin/queue-line-drop.sh" TK-319 2>&1)
grep -q '^dropped 1 ' <<<"$OUT" && ok || bad "A6 queue-line-drop.sh must drop the put line (got: '$OUT')"

# --- A7: the row is mirrored through rq_put with the same line ---------------
H7="$T/a7"; mkdir -p "$H7/bin/lib"
cat > "$H7/bin/lib/ready-queue.sh" <<'EOF'
rq_put() { printf '%s|' "$@" > "$HARNESS/rq_put.args"; }
EOF
mk_h "$H7"
put "$H7" project-3 TK-319 cmv6fixture L feature overlap-guard DEFER vs PR#550 >/dev/null 2>&1
[ "$(cat "$H7/rq_put.args" 2>/dev/null)" = "$H7|project-3|TK-319|cmv6fixture|$FR|" ] && ok \
  || bad "A7 rq_put must get <harness> <project> <key> <tid> <line> (got: '$(cat "$H7/rq_put.args" 2>/dev/null)')"
# a refused put mirrors nothing
rm -f "$H7/rq_put.args"
put "$H7" project-3 bad-key t S bug x >/dev/null 2>&1
[ ! -e "$H7/rq_put.args" ] && ok || bad "A7 a refused put must not call rq_put"

# --- A8: replace on an append-only (+a) file keeps the flag ------------------
H8="$T/a8"; mk_h "$H8"
scratch_install_closure bin/harden-state.sh "$H8" >/dev/null || bad "A8 cannot install the closure of bin/harden-state.sh"
mkdir -p "$H8/env" "$T/ssh"
printf '%s\n' "$FR" > "$H8/logs/READY-QUEUE.log"
if [ "$(id -u)" = 0 ] && chattr +a "$H8/logs/READY-QUEUE.log" 2>/dev/null; then
  OUT=$(HARNESS_ENV_DIR="$H8/env" HARDEN_SSH_DIR="$T/ssh" put "$H8" project-3 TK-319 cmv6fixture L feature armed 2>&1); RC=$?
  [ "$RC" = 0 ] && grep -q '^replaced ' <<<"$OUT" && ok || bad "A8 replace on a +a file must succeed (got $RC '$OUT')"
  [[ "$(lsattr "$H8/logs/READY-QUEUE.log" 2>/dev/null | awk '{print $1}')" == *a* ]] && ok || bad "A8 the file must be +a again after the replace"
  [ "$(grep -c '^TK-319 ' "$H8/logs/READY-QUEUE.log")" = 1 ] && ok || bad "A8 one TK-319 line after the replace"
  chattr -a "$H8/logs/READY-QUEUE.log" 2>/dev/null
else
  echo "SKIP: A8 chattr +a is not available in this scratch fs (needs root and a fs with attributes)"
fi

# --- B: the lint -------------------------------------------------------------
LINT="$DIR/bin/queue-line-lint.sh"
B="$T/b"; mkdir -p "$B"
: > "$B/project-3.log"
for i in $(seq 1 23); do
  printf '2026-10-21T23:38:%02dZ project-3 cmv6 TK-%d size=L kind=feature :: overlap-guard DEFER\n' "$i" "$((300 + i))" >> "$B/project-3.log"
done
OUT=$("$LINT" "$B/project-3.log"); RC=$?
[ "$RC" = 1 ] && ok || bad "B1 the 23-line project-3 shape must be rc 1 (got $RC)"
[ "$(grep -c '^NOT-KEY-FIRST ' <<<"$OUT")" = 23 ] && ok || bad "B1 all 23 lines must be flagged (got $(grep -c '^NOT-KEY-FIRST ' <<<"$OUT"))"
printf '%s\n' '# header' '' '   # indented comment' 'TK-319 cmv6 size=L :: ok project=project-3' 'BH-1 1 — ready project=proj' \
  '[HOTFIX] BH-1 hot' ' TK-319 leading space' 'TK-319 lower' > "$B/mixed.log"
OUT=$("$LINT" "$B/mixed.log"); RC=$?
[ "$RC" = 1 ] && ok || bad "B2 a mixed file must be rc 1 (got $RC)"
[ "$(grep -o '^NOT-KEY-FIRST [0-9]*' <<<"$OUT" | awk '{print $2}' | tr '\n' ' ')" = '6 7 8 ' ] && ok \
  || bad "B2 only lines 6 7 8 must be flagged (got: '$OUT')"
printf '%s\n' '# c' '' 'TK-1 a size=S kind=bug :: x project=project-3' 'BH-1 1 — ready project=proj' > "$B/clean.log"
OUT=$("$LINT" "$B/clean.log"); RC=$?
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "B3 a clean file must be rc 0 and silent (got $RC '$OUT')"
: > "$B/long.log"; for i in $(seq 1 29); do printf 'TK-%d t :: ok\n' "$i" >> "$B/long.log"; done
printf '2026-10-21T23:38:59Z project-3 late TK-99\n' >> "$B/long.log"
OUT=$("$LINT" "$B/long.log"); RC=$?
[ "$RC" = 1 ] && grep -q '^NOT-KEY-FIRST 30: ' <<<"$OUT" && ok || bad "B4 a bad line 30 must be flagged (got $RC '$OUT')"
printf '%s\n' "$FR" > "$B/put.log"
"$LINT" "$B/put.log" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "B4 the writer's line must pass the lint (got $RC)"
OUT=$("$LINT" "$B/absent.log"); RC=$?
[ "$RC" = 0 ] && [ "$OUT" = 'no queue file' ] && ok || bad "B4 an absent file must be rc 0 'no queue file' (got $RC '$OUT')"

# --- C: the hook in the real bin/decision-log.sh -----------------------------
HC="$T/c"; mkdir -p "$HC/bin" "$HC/logs"
ln -s "$DIR/bin/queue-line-lint.sh" "$HC/bin/queue-line-lint.sh"
printf '%s\n' 'TK-1 a :: ok project=project-3' '2026-10-21T23:38:59Z project-3 x TK-2 size=L' '2026-10-21T23:39:00Z project-3 y TK-3 size=S' > "$HC/logs/READY-QUEUE.log"
: > "$T/session.out"
dl() { HARNESS="$HC" "$DIR/bin/decision-log.sh" project-3 g s "$T/session.out"; }
dl; RC=$?
[ "$RC" = 0 ] && ok || bad "C1 decision-log.sh must stay rc 0 (got $RC)"
[ "$(grep -c 'QUEUE LINE NOT KEY-FIRST: 2 line(s)' "$HC/logs/ready-queue.log" 2>/dev/null)" = 1 ] && ok \
  || bad "C1 one 'QUEUE LINE NOT KEY-FIRST: 2 line(s)' line (got: '$(cat "$HC/logs/ready-queue.log" 2>/dev/null)')"
grep -q '\[project-3\].*first: 2026-10-21T23:38:59Z project-3 x TK-2.*queue-line-put.sh' "$HC/logs/ready-queue.log" 2>/dev/null && ok \
  || bad "C1 the line must name the project, the first bad line and the writer"
dl; RC=$?
[ "$RC" = 0 ] && [ "$(grep -c 'NOT KEY-FIRST' "$HC/logs/ready-queue.log")" = 1 ] && ok || bad "C2 the same bad set must not log twice"
printf '%s\n' 'TK-1 a :: ok project=project-3' > "$HC/logs/READY-QUEUE.log"
dl; RC=$?
[ "$RC" = 0 ] && [ ! -e "$HC/state/queue-line-lint.fp" ] && ok || bad "C3 a clean file must remove the fingerprint"
printf '%s\n' '2026-10-22T01:00:00Z project-3 z TK-4' >> "$HC/logs/READY-QUEUE.log"
dl; RC=$?
[ "$RC" = 0 ] && [ "$(grep -c 'NOT KEY-FIRST' "$HC/logs/ready-queue.log")" = 2 ] && ok || bad "C3 a new regression must log again"
[ ! -e "$HC/logs/ALERTS.log" ] && ok || bad "C3 the hook must never write ALERTS.log"

# --- D: what a DEFER-path session reads, and what its command writes ---------
CONTRACT=$(HARNESS="$T/none" "$DIR/bin/triage-contract.sh"); RC=$?
[ "$RC" = 0 ] && [ -n "$CONTRACT" ] && ok || bad "D1 triage-contract.sh must print the contract"
SESSION=$(printf '%s\n%s\n' "$CONTRACT" "$(cat "$DIR/prompts/project-3.md")")
grep -qF '<KEY> <ticket-id> size=<S|M|L|XL>' <<<"$SESSION" && ok || bad "D1 the session text must state the shape '<KEY> <ticket-id> size=<S|M|L|XL> …'"
grep -qF 'queue-line-put.sh' <<<"$CONTRACT" && ok || bad "D1 the contract must name queue-line-put.sh"
grep -qF 'queue-line-put.sh' "$DIR/prompts/project-3.md" && ok || bad "D1 prompts/project-3.md must name queue-line-put.sh"
HAND=$(grep -nE "(echo [^|]*>> *[^ ]*READY-QUEUE|queue line into \`[^\`]*READY-QUEUE)" <<<"$SESSION")
[ -z "$HAND" ] && ok || bad "D1 the session text must not tell a session to write READY-QUEUE.log by hand: $HAND"
TPL=$(grep -oE '/root/harness/bin/queue-line-put\.sh( <[^>]+>)+' <<<"$CONTRACT" | head -1)
[ "$(grep -oE '<[^>]+>' <<<"$TPL" | tr '\n' ' ')" = '<project> <KEY> <ticket-id> <S|M|L|XL> <kind> <reason> ' ] && ok \
  || bad "D2 the contract must carry the command template '<project> <KEY> <ticket-id> <S|M|L|XL> <kind> <reason>' (got: '$TPL')"
HD="$T/d"; mk_h "$HD"
# Fill the contract's own template for the TK-319 DEFER case and run it.
CMD=$(sed -e 's#^/root/harness/bin/queue-line-put\.sh#queue-line-put.sh#' \
          -e 's#<project>#project-3#' -e 's#<KEY>#TK-319#' -e 's#<ticket-id>#cmv6fixture#' \
          -e 's#<S|M|L|XL>#L#' -e 's#<kind>#feature#' -e 's#<reason>#overlap-guard DEFER vs PR\#550#' <<<"$TPL")
ARGV=(); read -r -a ARGV <<<"$CMD"
HARNESS="$HD" "$HD/bin/${ARGV[0]:-missing-template}" "${ARGV[@]:1}" >/dev/null 2>&1; RC=$?
LINE=$(cat "$HD/logs/READY-QUEUE.log" 2>/dev/null)
[ "$RC" = 0 ] && ok || bad "D2 the contract's command must run rc 0 (got $RC, cmd '$CMD')"
grep -q '^TK-319 ' <<<"$LINE" && grep -q 'project=project-3$' <<<"$LINE" && ok || bad "D2 the line must start 'TK-319 ' and end 'project=project-3' (got: '$LINE')"
"$LINT" "$HD/logs/READY-QUEUE.log" >/dev/null; RC=$?
[ "$RC" = 0 ] && ok || bad "D2 the replayed line must pass the lint (got $RC)"
MISS=$(grep -nE 'READY-QUEUE' "$DIR"/prompts/*.md | grep -iE 'write|append|echo|>>' | grep -vE 'queue-line-(put|drop)\.sh')
[ -z "$MISS" ] && ok || bad "D3 every prompt line that writes READY-QUEUE must name queue-line-put.sh or queue-line-drop.sh: $(cut -c1-160 <<<"$MISS")"
[ "$(grep -lF "write the ticket's queue line into" "$DIR"/prompts/*.md | wc -l)" = 0 ] && ok || bad "D3 no prompt may say 'write the ticket's queue line into'"

echo "queue-line-put.bh-8262-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
