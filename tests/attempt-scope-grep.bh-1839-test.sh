#!/bin/bash
# tests/attempt-scope-grep.bh-1839-test.sh — BH-1839 (BH-1831 item 1): the
# BH-1677 / BH-1670 attempt sites go through mc_attempt_has / mc_attempt_put,
# so the BH-1387 scope grep finds no file-only site outside its allowlist.
#
# WHY. #1635 (BH-1387) routed the attempt ledger through two helpers that keep
# the file AND the pr_attempts row twin. BH-1677 (`ejectconflict`, `ejectrebase`,
# `ejectrebased`, the `rebase` read and writes in eject_rebase_arm) and BH-1670
# (`stackfollow`) landed after #1635's base and still grepped and appended the
# file alone: lose attempts.txt and those heads forget they were tried.
#
# WHAT IT PINS.
#   A. SOURCE. Every hit of the BH-1387 scope grep over bin/merge-conductor.sh
#      and bin/lib/mc/*.sh is an allowlisted kind (on the hit line) or sits in a
#      helper body in locks.sh (by enclosing function, never by line number).
#      The grep must hit at all, and each converted kind must be called through
#      a helper, so a renamed file or a deleted site cannot pass vacuously.
#   B. mc_eject_conflict_note with pr-state-rows up: one GET (the has) and one
#      PUT carrying "kind":"ejectconflict", plus the file line.
#   C. eject_rebased_note with the file EMPTY and an `ejectrebase` row on the
#      worker: the row is read, `ejectrebased` is written to file and row.
#   D. eject_rebase_arm reads `ejectconflict` from the row, then marks
#      `ejectrebase` and `rebase` in the file and the row.
#   E. flag down: the same drives make 0 pr-attempts requests and write the
#      same file lines as before.
#
# HOW IT MEASURES. A curl shim's request log (method, url, body), the attempts
# file and the conductor log. The functions under test are the REAL ones, loaded
# through the REAL bin/lib/merge-conductor-lib.sh. Only the network edges the
# arms reach (Mergify's reason, the spawn, the transition) are redefined.
#
# Run from anywhere: tests/attempt-scope-grep.bh-1839-test.sh  (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

echo "== A. the scope grep: every hit is allowlisted =="
# TEST-CHANGE (BH-2199): `mergifyhold` joins the allowlist. It is a per-(PR,
# head) COUNTER read with `grep -c`, the same class as `mergefail`: the helpers
# are exact-line has/put and cannot count, and losing the file costs only an
# earlier queue re-ask, never a merge (the held path merges nothing).
ALLOW_KINDS=" identityalert mergefail requeued cirerun apread mergetree lanefail mergifyhold "
HELPERS=" mc_attempt_put mc_attempt_has mc_attempt_clear "
HITS=$(cd "$DIR" && grep -nE 'grep -q?xF [^|]*\$MC_ATTEMPTS|>> *"\$MC_ATTEMPTS"' bin/merge-conductor.sh bin/lib/mc/*.sh)
[ -n "$HITS" ] && ok || bad "A: the scope grep hit nothing — files moved? The test would pass vacuously"
# enclosing <file> <line> -> the top-level function whose body holds the line
enclosing() {
  awk -v L="$2" '
    /^[A-Za-z_][A-Za-z0-9_]*\(\) *\{/ { fn=$1; sub(/\(\).*/, "", fn) }
    NR==L { print fn; exit }
    /^\}/ { fn="" }' "$DIR/$1"
}
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  f=${hit%%:*}; rest=${hit#*:}; n=${rest%%:*}; text=${rest#*:}
  fn=$(enclosing "$f" "$n")
  if [ "$f" = bin/lib/mc/locks.sh ] && [[ "$HELPERS" == *" $fn "* ]]; then ok; continue; fi
  kinds=$(grep -oE '"\^?[a-z]+ \$' <<<"$text" | sed -E 's/^"\^?//; s/ \$$//' | sort -u)
  good=1; [ -n "$kinds" ] || good=0
  for k in $kinds; do [[ "$ALLOW_KINDS" == *" $k "* ]] || good=0; done
  [ "$good" = 1 ] && ok || bad "A: file-only attempt site outside the allowlist: $f:$n (${fn:-top level}) kinds=[$(echo $kinds)]: $text"
done <<<"$HITS"
# Absent-symbol guard: each converted kind is called through a helper.
for k in ejectconflict ejectrebase ejectrebased stackfollow rebase; do
  c=$(cat "$DIR/bin/lib/mc/queue.sh" "$DIR/bin/lib/mc/rebase.sh" | grep -cE "mc_attempt_(has|put) \"$k ")
  [ "${c:-0}" -ge 1 ] && ok || bad "A: no mc_attempt_has/put call for kind '$k' in queue.sh/rebase.sh"
done

H="$T/h"
mkdir -p "$H/bin/lib/jobs" "$H/bin/lib/mc" "$H/env" "$H/flags" "$H/logs" \
         "$H/state/merge-conductor" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$H/bin/" || exit 1
cp "$DIR"/bin/lib/jobs/*.sh "$H/bin/lib/jobs/" || exit 1
cp "$DIR/bin/lib/env-path.sh" "$H/bin/lib/" || exit 1
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$H/bin/lib/" || exit 1
cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/" || exit 1
# TEST-CHANGE (BH-8035): every conductor rebase spawn asks mc_rebase_gate, which
# loads bin/lib/migration-hold.sh and reads the hold rows, and defers when it
# cannot. This suite has no hold rows: the lib is installed, setting_get says "no row".
scratch_install_closure bin/lib/migration-hold.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
setting_get() { return 2; }; export -f setting_get

ATT="$H/state/merge-conductor/attempts.txt"
MCLOG="$H/logs/merge-conductor.log"
REQ="$T/req.log"
ERR="$T/err.log"

# The curl shim: logs "METHOD URL BODY". /api/flags/* is a 404 (flag_active
# falls to the flag FILE). A pr-attempts GET is a 200 (row there) when its
# query names kind=$HIT_KINDS (space-separated), a 404 (real miss) otherwise;
# every other call is a 200.
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
URL=""; METHOD=GET; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2;;
    --data-binary) BODY="$2"; shift 2;;
    -H|-m|--connect-timeout|-w) shift 2;;
    -*) shift;;
    *) URL="$1"; shift;;
  esac
done
printf '%s %s %s\n' "$METHOD" "$URL" "$BODY" >> "$REQ_LOG"
case "$URL" in */api/flags/*) printf '{"error":"no such flag"}\n404\n'; exit 0 ;; esac
if [ "$METHOD" = GET ] && [[ "$URL" == */api/pr-attempts\?* ]]; then
  for k in ${HIT_KINDS:-}; do
    [[ "$URL" == *"kind=$k&"* ]] && { printf '{"ok":true}\n200\n'; exit 0; }
  done
  printf '{"error":"no row"}\n404\n'; exit 0
fi
printf '{"ok":true}\n200\n'
CURL
chmod +x "$T/fakebin/curl"

cat > "$T/drive.sh" <<'DRV'
#!/bin/bash
set -uo pipefail
# shellcheck source=/dev/null
. "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1 || exit 90
# shellcheck source=/dev/null
. "$HARNESS/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1 || exit 91
eval "$DRIVE_CODE"
DRV

drv() {
  env DRIVE_CODE="$1" HIT_KINDS="${HIT_KINDS:-}" \
    PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=x JOBS_BOX=testbox \
    JOBS_RETRIES=0 JOBS_ALERT=0 JOBS_URL=http://jobs.test REQ_LOG="$REQ" \
    bash "$T/drive.sh" 2>>"$ERR"
}
reset() { : > "$REQ"; : > "$ERR"; : > "$ATT"; : > "$MCLOG"; : > "$H/flags/pr-state-rows"; }
nreq() { grep -c "^$1 http://jobs.test/api/pr-attempts" "$REQ" 2>/dev/null || true; }
nput_kind() { grep "^PUT http://jobs.test/api/pr-attempts" "$REQ" 2>/dev/null | grep -c "\"kind\":\"$1\"" || true; }
nget_kind() { grep "^GET http://jobs.test/api/pr-attempts" "$REQ" 2>/dev/null | grep -c "kind=$1&" || true; }

NOTE="mc_dequeue_conflict() { printf base-conflict; }; mc_eject_conflict_note example-org/x example-org/x#12 https://github.com/example-org/x/pull/12 abc; echo rc=\$?"
REBASED="eject_rebased_note example-org/x#12 https://github.com/example-org/x/pull/12 abc 0 def1234; echo rc=\$?"
# eject_rebase_arm reads its PR from the worker's globals; the spawn and the
# transition are the edges it reaches, redefined to succeed without a network.
ARM="KEY=example-org/x#12 HEAD=abc SLUG=example-org/x NUM=12 P=x BR=ticket/x URL=https://github.com/example-org/x/pull/12
  REC=- REVIEWED=- VERDICT=- MSTATE=- MERGES=1
  mc_pool_rebase_enabled() { return 1; }; mc_rebase_spawn() { return 0; }; mc_transition() { :; }
  eject_rebase_arm; echo rc=\$?"

echo "== B. mc_eject_conflict_note with rows up: file line + row PUT =="
reset
OUT=$(drv "$NOTE")
[ "$OUT" = rc=0 ] && ok || bad "B: rc: $OUT $(cat "$ERR")"
[ "$(nget_kind ejectconflict)" = 1 ] && ok || bad "B: want 1 GET kind=ejectconflict (the has), got $(nget_kind ejectconflict): $(cat "$REQ")"
[ "$(nreq PUT)" = 1 ] && ok || bad "B: want exactly 1 PUT /api/pr-attempts, got $(nreq PUT): $(cat "$REQ")"
[ "$(nput_kind ejectconflict)" = 1 ] && ok || bad "B: the PUT must carry kind ejectconflict: $(cat "$REQ")"
grep -q '"repo":"example-org/x","number":12,"kind":"ejectconflict","sha":"abc"' "$REQ" && ok || bad "B: PUT body must name repo/number/sha: $(cat "$REQ")"
[ "$(cat "$ATT")" = "ejectconflict example-org/x#12 abc" ] && ok || bad "B: want the one file line: $(cat "$ATT")"
grep -q 'EJECTED_CONFLICT example-org/x#12 abc' "$MCLOG" && ok || bad "B: EJECTED_CONFLICT not logged: $(cat "$MCLOG")"
# A row that already says so: no second mark, no PUT, and the file is warmed.
reset
OUT=$(HIT_KINDS=ejectconflict drv "$NOTE")
[ "$(nreq PUT)" = 0 ] && ok || bad "B: a row hit must not PUT again: $(cat "$REQ")"
[ ! -s "$MCLOG" ] && ok || bad "B: a row hit must not log EJECTED_CONFLICT again: $(cat "$MCLOG")"
[ "$(cat "$ATT")" = "ejectconflict example-org/x#12 abc" ] && ok || bad "B: a row hit warms the file for mc_eject_strikes: $(cat "$ATT")"

echo "== C. eject_rebased_note reads the ejectrebase ROW when the file lost it =="
reset
OUT=$(HIT_KINDS=ejectrebase drv "$REBASED")
[ "$OUT" = rc=0 ] && ok || bad "C: rc: $OUT"
grep -qxF "ejectrebased example-org/x#12 abc" "$ATT" && ok || bad "C: ejectrebased must be written after a row hit: $(cat "$ATT")"
[ "$(nput_kind ejectrebased)" = 1 ] && ok || bad "C: want 1 PUT kind ejectrebased: $(cat "$REQ")"
grep -q 'EJECT_REBASED example-org/x#12 abc -> def1234' "$MCLOG" && ok || bad "C: EJECT_REBASED not logged: $(cat "$MCLOG")"
# ...and an ejectrebased row stops a second audit.
reset
OUT=$(HIT_KINDS="ejectrebase ejectrebased" drv "$REBASED")
[ "$(nreq PUT)" = 0 ] && ok || bad "C: an ejectrebased row must stop the audit: $(cat "$REQ")"
[ ! -s "$MCLOG" ] && ok || bad "C: an ejectrebased row must not log again: $(cat "$MCLOG")"

echo "== D. eject_rebase_arm: ejectconflict from the row, marks to file + row =="
reset
OUT=$(HIT_KINDS=ejectconflict drv "$ARM")
[ "$OUT" = rc=0 ] && ok || bad "D: rc: $OUT $(cat "$ERR")"
[ "$(nget_kind ejectrebase)" = 1 ] && [ "$(nget_kind rebase)" = 1 ] && ok || bad "D: the ejectrebase and rebase reads must ask the row: $(cat "$REQ")"
[ "$(nput_kind ejectrebase)" = 1 ] && [ "$(nput_kind rebase)" = 1 ] && ok || bad "D: want PUTs for ejectrebase and rebase: $(cat "$REQ")"
grep -qxF "ejectrebase example-org/x#12 abc" "$ATT" && grep -qxF "rebase example-org/x#12 abc" "$ATT" && ok || bad "D: file marks missing: $(cat "$ATT")"
grep -q 'EJECT_REBASE_SPAWNED example-org/x#12 abc' "$MCLOG" && ok || bad "D: not spawned: $(cat "$MCLOG")"
# An ordinary `rebase` row for the head means the arm stands down.
reset
OUT=$(HIT_KINDS="ejectconflict rebase" drv "$ARM")
[ "$OUT" = rc=1 ] && ok || bad "D: a rebase row must stand the arm down: $OUT"
[ "$(nreq PUT)" = 0 ] && ok || bad "D: a stood-down arm writes nothing: $(cat "$REQ")"

echo "== E. flag down: zero row traffic, same file lines =="
reset; rm -f "$H/flags/pr-state-rows"
OUT=$(drv "$NOTE")
[ "$OUT" = rc=0 ] && ok || bad "E: rc: $OUT"
[ "$(cat "$ATT")" = "ejectconflict example-org/x#12 abc" ] && ok || bad "E: want the one file line: $(cat "$ATT")"
OUT=$(drv "$ARM")
[ "$OUT" = rc=0 ] && ok || bad "E: arm rc with the file mark: $OUT"
[ "$(cat "$ATT")" = "$(printf 'ejectconflict example-org/x#12 abc\nejectrebase example-org/x#12 abc\nrebase example-org/x#12 abc')" ] && ok || bad "E: file lines differ: $(cat "$ATT")"
OUT=$(drv "$REBASED")
grep -qxF "ejectrebased example-org/x#12 abc" "$ATT" && ok || bad "E: ejectrebased must still be written from the file: $(cat "$ATT")"
[ "$(nreq GET)" = 0 ] && [ "$(nreq PUT)" = 0 ] && ok || bad "E: flag down must make 0 pr-attempts requests: $(cat "$REQ")"

echo "attempt-scope-grep: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
