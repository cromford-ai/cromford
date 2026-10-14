#!/bin/bash
# tests/alert-digest-pause.bh-1672-test.sh — the daily digest names every
# standing pause (BH-1672 / BH-1684 T7).
#
# A pause is a lane that stopped on purpose. That is only honest if the stop is
# stated somewhere every day, the same reasoning as the PARKED block above it:
# a pause nobody is reminded of is a lane nobody notices is off. So the digest
# sends on a day the triage log is empty when a pause is live, sends NOTHING
# when there is neither, and never shows an expired or ended row.
#
# Drives the REAL bin/alert-digest.sh (copied into a scratch $HARNESS so its
# $BIN resolves to the scratch lib tree) with bin/beat.sh stubbed to record
# its argument. The pause cache is hand-written and the clock pinned through
# PAUSE_NOW. The scratch pause.sh gets a recording pause_refresh appended, so
# this suite keeps driving the hand-written cache after #1683 fills the stub.
#
# Run from anywhere: tests/alert-digest-pause.bh-1672-test.sh   (exit 0 = all pass)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
NOW=1790000000
export PAUSE_NOW="$NOW"
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# setup [env-shapes-token] — a fresh scratch $HARNESS per case.
setup() {
  scratch_rm "$H"; scratch_rm "$T/beat.calls"; scratch_rm "$T/refresh.calls"
  mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags"
  cp "$DIR/bin/alert-digest.sh" "$H/bin/alert-digest.sh"
  cp "$DIR/bin/lib/alert-state.sh" "$DIR/bin/lib/pause.sh" "$DIR/bin/lib/pause-rows.sh" "$H/bin/lib/"
  printf '\npause_refresh(){ echo x >> "%s/refresh.calls"; return 0; }\n' "$T" >> "$H/bin/lib/pause.sh"
  [ -n "${1:-}" ] && printf 'pause_env_shapes(){ echo %s; }\n' "$1" >> "$H/bin/lib/pause.sh"
  cat > "$H/bin/beat.sh" <<STUB
#!/bin/bash
printf '%s\n' "\$1" >> "$T/beat.calls"
STUB
  chmod +x "$H/bin/beat.sh"
  : > "$H/logs/alert-triage.log"
}
digest()  { HARNESS="$H" bash "$H/bin/alert-digest.sh" "$@" >/dev/null 2>&1; }
calls()   { [ -f "$T/beat.calls" ] && wc -l < "$T/beat.calls" | tr -d ' ' || echo 0; }
line()    { jq -r '.line' "$T/beat.calls" 2>/dev/null; }
row()     { # row <scope> <what> <reason> <actor> <created_epoch> <expires_epoch> [ended_iso]
  local ended=null
  [ -n "${7:-}" ] && ended="\"$7\""
  printf '{"id":"%s-%s","scope":"%s","what":"%s","reason":"%s","actor":"%s","created_at":"%s","expires_at":"%s","ended_at":%s,"end_reason":null}' \
    "$1" "$2" "$1" "$2" "$3" "$4" "$(iso "$5")" "$(iso "$6")" "$ended"
}
cache()   { printf '{"pauses":[%s],"truncated":false}\n' "$(IFS=,; echo "$*")" > "$H/state/pauses.json"; }

FLEET_MERGES=$(row fleet merges "runaway fix" operator $((NOW - 2*86400 - 3*3600)) $((NOW + 21*3600)))
PROJ_REVIEWS=$(row project-1 reviews "cap hit" ops $((NOW - 3*3600 - 5*60)) $((NOW + 45*60)))

# ── A: two live rows, empty triage log → one beat, two PAUSED lines ─────────
setup
cache "$FLEET_MERGES" "$PROJ_REVIEWS"
digest
[ "$(calls)" = 1 ] && ok || bad "A: a live pause with an empty log must send once (calls=$(calls))"
L=$(line)
[ "$(printf '%s\n' "$L" | grep -c '^  - PAUSED ')" = 2 ] && ok || bad "A: want two PAUSED lines, got: $L"
grep -qxF '  - PAUSED merges · fleet · 2d 3h · "runaway fix" · by operator · expires in 21h' <<<"$L" \
  && ok || bad "A: fleet merges line not in the documented format: $L"
grep -qxF '  - PAUSED reviews · project-1 · 3h 5m · "cap hit" · by ops · expires in 45m' <<<"$L" \
  && ok || bad "A: project reviews line missing: $L"
[ "$(cat "$T/refresh.calls" 2>/dev/null | wc -l | tr -d ' ')" = 1 ] && ok || bad "A: pause_refresh not called exactly once"

# ── G: a created_at that does not parse → "age unknown", never epoch-0 age ──
setup
cache "$(row fleet merges "bad date" operator $((NOW - 3600)) $((NOW + 3600)) | jq -c '.created_at = "not-a-date"')"
digest
L=$(line)
grep -qxF '  - PAUSED merges · fleet · age unknown · "bad date" · by operator · expires in 1h' <<<"$L" \
  && ok || bad "G: an unparseable created_at must read 'age unknown': $L"
grep -qE '[0-9]{3,}d' <<<"$(printf '%s\n' "$L")" && bad "G: an epoch-0 age leaked into the line: $L" || ok

# ── N: no cache, empty log → nothing sent ───────────────────────────────────
setup
digest
[ "$(calls)" = 0 ] && ok || bad "N: no pause and no entries must send nothing (calls=$(calls))"

# ── X: expired row and ended row, empty log → nothing sent ──────────────────
setup
cache "$(row fleet merges "old one" operator $((NOW - 3*86400)) $((NOW - 60)))" \
      "$(row project-1 builds "ended one" operator $((NOW - 3600)) $((NOW + 3600)) "$(iso $((NOW - 60)))")"
digest
[ "$(calls)" = 0 ] && ok || bad "X: an expired/ended row must not make the digest send (calls=$(calls))"
! grep -q 'old one\|ended one' "$T/beat.calls" 2>/dev/null && ok || bad "X: expired/ended row shown"

# ── S: env shape only (no row) → one env line ───────────────────────────────
setup env:review-cap=1
digest
[ "$(calls)" = 1 ] && ok || bad "S: an env-shape pause must send (calls=$(calls))"
L=$(line)
[ "$(printf '%s\n' "$L" | grep -c '^  - PAUSED ')" = 1 ] && ok || bad "S: want one PAUSED line: $L"
grep -qxF '  - PAUSED env:review-cap=1 · env (reported only, no row)' <<<"$L" \
  && ok || bad "S: env line not in the documented format: $L"

# ── T: triage entries AND a pause → both in the one message ─────────────────
setup
cache "$FLEET_MERGES"
printf '%s alert-triage HANDLED something fixed\n' "$(date -u '+%Y-%m-%d %H:%M:%S')" > "$H/logs/alert-triage.log"
digest
[ "$(calls)" = 1 ] && ok || bad "T: want one send (calls=$(calls))"
L=$(line)
grep -q '1 fixed silently' <<<"$L" && ok || bad "T: triage counts missing: $L"
grep -qF '  - PAUSED merges · fleet · 2d 3h' <<<"$L" && ok || bad "T: pause line missing: $L"

# ── W: --warn-batch is unchanged by a live pause ────────────────────────────
warn_run() { # warn_run with|without → normalized beat payload on stdout
  setup
  [ "$1" = with ] && cache "$FLEET_MERGES"
  printf '%s\t%s\n' 1 '{"alertid":"w1","line":"a warn thing"}' > "$H/state/alert-warn-batch.jsonl"
  digest --warn-batch
  sed -E 's/warnbatch:[A-Za-z0-9_:-]+/warnbatch:X/' "$T/beat.calls" 2>/dev/null
}
W1=$(warn_run without); W2=$(warn_run with)
[ -n "$W1" ] && ok || bad "W: --warn-batch sent nothing"
[ "$W1" = "$W2" ] && ok || bad "W: --warn-batch output changed under a pause: [$W1] vs [$W2]"
[ ! -f "$T/refresh.calls" ] && ok || bad "W: --warn-batch reached the pause block"

echo "alert-digest-pause: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
