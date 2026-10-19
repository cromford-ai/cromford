#!/bin/bash
# tests/digest-once.bh-5003-test.sh — BH-5003: two hubs ticking the same day
# send ONE daily digest. The ledger row daily_digest/<D> is the record and the
# claim (POST /api/ledger/claim) is its compare-and-set; state/daily-digest/
# sent-<D> stays as the row's mirror.
#
# WHAT IS STUBBED. Two scratch hubs, $T/a and $T/b (each a symlink tree of the
# repo's bin/ and its own state, logs and locks, as two boxes have), run the
# SHIPPED bin/daily-digest.sh. They share one fake jobs worker: a `curl` first
# in PATH that keeps every ledger row in $T/ledger.json under flock, and
# answers the claim with the worker's own rule and shape (worker/jobs/src/
# routes/ledger.js): `{claimed, ledger, as_of}`, taken when the row is absent,
# or not terminal and (another status, or the same one older than stale_s).
# Row ages are epoch seconds on the fake worker's clock. $T/claim.code forces
# 404 (route not deployed) or 503 on the claim alone. When $T/barrier exists,
# the dedupe GET for daily_digest waits until both hubs have made it (60 s cap),
# so both read "not sent" before either claims or sends: the lease-handover race.
# bin/archie-tg-send.sh appends "<box> <akey>" to $T/sends and exits
# $T/send.rc.<box> (0 when absent). dd_render is a fixed text (fixture seam).
#
# Cases: C1 C2 C3 C4 C5 C6 C6b C6c C7, the verb V1-V4 (job_ledger_claim's rc
# table through the same fake), and the mutation M3 (a sed copy of the lane
# with the claim block removed fails C1).
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/digest-once.bh-5003-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "digest-once: jq is required"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "digest-once: flock is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }

LANE_SRC="$DIR/bin/daily-digest.sh"
for f in "$LANE_SRC" "$DIR/bin/lib/jobs/jobs.sh" "$DIR/catalog/lanes.d/daily-digest.json"; do
  [ -f "$f" ] && ok || bad "missing $f"
done
check "the two knobs are registered" \
  'jq -e "[.knobs[].env] | index(\"DAILY_DIGEST_CLAIM\") and index(\"DAILY_DIGEST_CLAIM_STALE_S\")" "$DIR/catalog/lanes.d/daily-digest.json" >/dev/null'

mkdir -p "$T/fakebin"
mkhub() { # mkhub <dir>
  local h=$1
  mkdir -p "$h/catalog" "$h/env"
  cp -rs "$DIR/bin" "$h/bin"
  cp -r "$DIR/catalog/lanes.d" "$DIR/catalog/switches.d" "$h/catalog/"
  : > "$h/env/global.env"
  rm -f "$h/bin/lane-alert.sh" "$h/bin/archie-tg-send.sh"
  cat > "$h/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
exit 0
SH
  cat > "$h/bin/archie-tg-send.sh" <<'SH'
#!/bin/bash
printf '%s %s\n' "$JOBS_BOX" "$1" >> "$FXT/sends"
exit "$(cat "$FXT/send.rc.$JOBS_BOX" 2>/dev/null || echo 0)"
SH
  chmod +x "$h/bin/lane-alert.sh" "$h/bin/archie-tg-send.sh"
}
HA="$T/a"; HB="$T/b"
mkhub "$HA"; mkhub "$HB"

cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
m=GET; body=""; prev=""; wfmt=0
for a in "$@"; do
  case "$prev" in
    -X) m="$a" ;;
    --data-binary|-d) body="$a" ;;
    -w) wfmt=1 ;;
  esac
  prev="$a"
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
url="${!#}"
case "$url" in "$JOBS_URL"*) ;; *) exit 7 ;; esac
path="${url#"$JOBS_URL"}"
printf '%s %s %s %s\n' "$JOBS_BOX" "$m" "$path" "$body" >> "$FXT/reqlog"
code=200; out='{"ok":true}'
now=$(date +%s)
ledger() { # ledger <jq program> [args...] — read-modify-write under the lock
  local prog=$1; shift
  jq "$@" "$prog" "$FXT/ledger.json" > "$FXT/ledger.tmp.$$" && mv "$FXT/ledger.tmp.$$" "$FXT/ledger.json"
}
case "$m $path" in
  "GET /api/settings"*) out='{"settings":[]}' ;;
  "POST /api/ledger/claim")
    if [ -f "$FXT/claim.code" ]; then
      code=$(cat "$FXT/claim.code")
      case "$code" in 404) out='{"error":"unknown endpoint","worker":"harness-jobs"}' ;; *) out='{"error":"down"}' ;; esac
    else
      exec 8>"$FXT/ledger.lock"; flock 8
      id=$(jq -r '.kind + "/" + .key' <<<"$body")
      win=$(jq -r --arg i "$id" --argjson b "$body" --argjson now "$now" '
        .[$i] as $r
        | if $r == null then true
          elif ($b.terminal // [] | index($r.status)) != null then false
          elif $r.status != $b.status then true
          else ($r.updated_at < ($now - $b.stale_s)) end' "$FXT/ledger.json")
      if [ "$win" = true ]; then
        ledger '.[$i] = {status: $b.status, actor: ($b.actor // .[$i].actor // null),
                         detail: ($b.detail // .[$i].detail // ""), updated_at: $now}' \
          --arg i "$id" --argjson b "$body" --argjson now "$now"
      fi
      out=$(jq -c --arg i "$id" --argjson w "$win" '{claimed: $w, ledger: .[$i], as_of: "now"}' "$FXT/ledger.json")
      flock -u 8
    fi ;;
  "GET /api/ledger"*)
    if [ -f "$FXT/ledger.down" ]; then code=503; out='{"error":"down"}'; printf '%s\n%s' "$out" "$code"; exit 0; fi
    k=$(printf '%s' "$path" | sed -n 's/.*[?&]kind=\([^&]*\).*/\1/p')
    v=$(printf '%s' "$path" | sed -n 's/.*[?&]key=\([^&]*\).*/\1/p')
    if [ "$k" = daily_digest ] && [ -f "$FXT/barrier" ]; then
      # TEST-CHANGE (BH-7465): the cap was 5 s (50 polls). On a loaded Linux
      # runner one hub reached this read after the cap; the first hub had
      # already sent, so the late hub read `sent` and C7 ("knob 0 sends
      # twice") saw one send. The barrier holds the first hub's read until
      # the second hub has made its own, so neither can record a send before
      # both checked. 60 s is a hang guard only, never the order.
      touch "$FXT/read.$JOBS_BOX"
      for _ in $(seq 1 600); do
        [ -f "$FXT/read.hub-a" ] && [ -f "$FXT/read.hub-b" ] && break
        sleep 0.1
      done
    fi
    row=$(jq -c --arg i "$k/$v" '.[$i] // empty' "$FXT/ledger.json")
    if [ -n "$row" ]; then out=$(jq -nc --argjson r "$row" '{ledger: $r}'); else code=404; out='{"error":"not found"}'; fi ;;
  "PUT /api/ledger")
    exec 8>"$FXT/ledger.lock"; flock 8
    ledger '.[$b.kind + "/" + $b.key] = {status: $b.status, actor: ($b.actor // null),
              detail: ($b.detail // .[$b.kind + "/" + $b.key].detail // ""), updated_at: $now}' \
      --argjson b "$body" --argjson now "$now"
    flock -u 8 ;;
  "GET /api/metrics/daily-digest"*) out=$(cat "$FXT/route.json") ;;
  "GET "*) code=404; out='{"error":"not found"}' ;;
esac
printf '%s' "$out"
[ "$wfmt" = 1 ] && printf '\n%s' "$code"
exit 0
SH
chmod +x "$T/fakebin/curl"

cat > "$T/fx.sh" <<'SH'
dd_render() { printf 'Daily digest %s\nline two\n' "$(jq -r .day "$1")"; }
SH

export FXT="$T" JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 HARNESS_SECRET=test \
  CONSOLE_PAGES_URL=https://console.invalid/ PATH="$T/fakebin:$PATH"
unset DAILY_DIGEST_ENABLED DAILY_DIGEST_SEND_HOUR_UTC DAILY_DIGEST_CLAIM DAILY_DIGEST_CLAIM_STALE_S \
  DAILY_DIGEST_NOW DAILY_DIGEST_FIXTURE LANE_GATE_DISABLE DD_TIMED HARNESS 2>/dev/null || true

D=2026-09-29
NOW=1790751900          # 2026-09-30T07:05:00Z, so D is 2026-09-29

reset() {
  local p
  for p in "$T/sends" "$T/alerts.log" "$T/reqlog" "$T/ledger.json" "$T/claim.code" "$T/ledger.down" "$T/barrier" \
    "$T/read.hub-a" "$T/read.hub-b" "$T/send.rc.hub-a" "$T/send.rc.hub-b" \
    "$HA/state" "$HA/logs" "$HA/locks" "$HA/flags" "$HB/state" "$HB/logs" "$HB/locks" "$HB/flags"; do
    scratch_rm "$p" || exit 1
  done
  echo '{}' > "$T/ledger.json"
  jq --arg d "$D" '.day = $d' "$DIR/tests/fixtures/daily-digest/fixture-day.json" > "$T/route.json"
}
# tick <a|b> [VAR=value ...]: one tick of the lane on that hub.
tick() {
  local which=$1; shift
  local h="$T/$which"
  env HARNESS="$h" JOBS_BOX="hub-$which" HARNESS_TEST_SANDBOX=1 DAILY_DIGEST_NOW="$NOW" \
    DAILY_DIGEST_FIXTURE="$T/fx.sh" "$@" bash "$h/bin/daily-digest.sh" > "$T/out.$which" 2>&1
  echo $? > "$T/rc.$which"
}
n_send() { local n; n=$(wc -l 2>/dev/null < "$T/sends"); printf '%s' "${n:-0}" | tr -d ' '; }
summ() { tail -1 "$T/$1/logs/daily-digest.log" 2>/dev/null; }
notes() { cat "$T/$1/logs/daily-digest.notes.log" 2>/dev/null; }
row() { jq -r --arg i "daily_digest/$D" ".[\$i].${1:-status} // \"none\"" "$T/ledger.json"; }
seed() { # seed <status> <actor> <age-s>
  jq --arg i "daily_digest/$D" --arg s "$1" --arg a "$2" --argjson t "$(( $(date +%s) - $3 ))" \
    '.[$i] = {status: $s, actor: $a, detail: "", updated_at: $t}' "$T/ledger.json" > "$T/l.tmp" && mv "$T/l.tmp" "$T/ledger.json"
}
both() { # both [VAR=value ...]: the two hubs in the same second, both past the dedupe read
  touch "$T/barrier"
  tick a "$@" & local pa=$!
  tick b "$@" & local pb=$!
  wait "$pa"; wait "$pb"
}

# ── C1: two hubs at once send ONE digest (the ticket's acceptance test) ─────
reset; both
check "C1 both ticks exit 0 ($(cat "$T/rc.a" "$T/rc.b" | tr '\n' ' '))" '[ "$(cat "$T/rc.a")" = 0 ] && [ "$(cat "$T/rc.b")" = 0 ]'
check "C1 both hubs read the row before either claimed" '[ -f "$T/read.hub-a" ] && [ -f "$T/read.hub-b" ]'
check "C1 exactly one send ($(n_send): $(tr '\n' '|' < "$T/sends" 2>/dev/null))" '[ "$(n_send)" = 1 ]'
check "C1 the row is sent ($(row))" '[ "$(row)" = sent ]'
check "C1 the loser ends claimed-elsewhere ($(summ a) / $(summ b))" \
  '{ summ a; summ b; } | grep -c " claimed-elsewhere$" | grep -qx 1'
check "C1 the winner's summary is sent=1" '{ summ a; summ b; } | grep -c " sent=1 " | grep -qx 1'
check "C1 the loser names the holder ($(notes a; notes b))" 'grep -qE "claim held by (sending|sent) for $D" "$HA/logs/daily-digest.notes.log" "$HB/logs/daily-digest.notes.log" 2>/dev/null'

# ── C2: one after the other ──────────────────────────────────────────────────
reset; tick a; tick b
check "C2 one send" '[ "$(n_send)" = 1 ] && grep -q "^hub-a daily-digest:$D$" "$T/sends"'
check "C2 hub-a wrote the sent-<D> mirror" '[ -f "$HA/state/daily-digest/sent-$D" ]'
check "C2 hub-b exits on the sent read: no log line, no claim" \
  '[ ! -s "$HB/logs/daily-digest.log" ] && ! grep -q "^hub-b POST /api/ledger/claim" "$T/reqlog"'

# ── C3: a dead hub's claim, an hour old, is taken over ─────────────────────
reset; seed sending hub-a 3600; tick b
check "C3 hub-b sends once" '[ "$(n_send)" = 1 ] && grep -q "^hub-b " "$T/sends"'
check "C3 row sent ($(row))" '[ "$(row)" = sent ]'

# ── C4: a fresh claim held elsewhere ─────────────────────────────────────────
reset; seed sending hub-a 10; tick b
check "C4 no send" '[ "$(n_send)" = 0 ]'
check "C4 claimed-elsewhere ($(summ b))" '[[ "$(summ b)" == *" claimed-elsewhere" ]]'
check "C4 the row is still hub-a's" '[ "$(row actor)" = hub-a ] && [ "$(row)" = sending ]'
check "C4 no attempt counted" '[ ! -e "$HB/state/daily-digest/attempts-$D" ]'

# ── C5: a failed send releases the claim ─────────────────────────────────────
reset; echo 1 > "$T/send.rc.hub-a"; tick a
check "C5 hub-a tried once and the row is send-failed ($(row))" '[ "$(n_send)" = 1 ] && [ "$(row)" = send-failed ]'
check "C5 no sent-<D> mirror after a failed send" '[ ! -e "$HA/state/daily-digest/sent-$D" ]'
tick b
check "C5 hub-b's next tick claims and sends" '[ "$(n_send)" = 2 ] && [ "$(sed -n 2p "$T/sends")" = "hub-b daily-digest:$D" ] && [ "$(row)" = sent ]'

# ── C6: the claim route is not deployed yet ──────────────────────────────────
reset; echo 404 > "$T/claim.code"; tick a
check "C6 sends once on the read dedupe alone" '[ "$(n_send)" = 1 ] && [ "$(row)" = sent ]'
check "C6 one note line" '[ "$(grep -c "claim route absent" "$HA/logs/daily-digest.notes.log")" = 1 ]'
check "C6 the note names the claim's own rc, not an earlier request's http code" \
  'grep "claim route absent" "$HA/logs/daily-digest.notes.log" | grep -q "(claim rc=2)" && ! grep "claim route absent" "$HA/logs/daily-digest.notes.log" | grep -q "http="'
reset; echo 503 > "$T/claim.code"; tick a
check "C6b claim 503: no send" '[ "$(n_send)" = 0 ]'
check "C6b summary claim-failed ($(summ a))" '[[ "$(summ a)" == *" claim-failed" ]]'
check "C6b no attempt counted" '[ ! -e "$HA/state/daily-digest/attempts-$D" ]'
check "C6b the note names the claim's own rc" 'grep "ledger claim for $D failed" "$HA/logs/daily-digest.notes.log" | grep -q "(claim rc=1)"'
# C6c: the whole ledger is down (the dedupe read failed too): today's path, the
# send goes ahead and archie-tg-send.sh's own ledger read decides.
reset; touch "$T/ledger.down"; echo 503 > "$T/claim.code"; tick a
check "C6c ledger down: the dedupe read and the claim both failed" \
  'grep -q "^hub-a GET /api/ledger" "$T/reqlog" && grep -q "^hub-a POST /api/ledger/claim" "$T/reqlog"'
check "C6c ledger down: the send is handed to archie-tg-send ($(n_send))" '[ "$(n_send)" = 1 ]'
check "C6c ledger down: one note line, not claim-failed ($(summ a))" \
  '[ "$(grep -c "ledger claim failed with the ledger down" "$HA/logs/daily-digest.notes.log")" = 1 ] && [[ "$(summ a)" != *" claim-failed" ]]'

# ── C7: DAILY_DIGEST_CLAIM=0 is the rollback: main's behaviour, two sends ────
reset; both DAILY_DIGEST_CLAIM=0
check "C7 knob 0: no claim request" '! grep -q "POST /api/ledger/claim" "$T/reqlog"'
check "C7 knob 0: the race sends twice, as before BH-5003 ($(n_send))" '[ "$(n_send)" = 2 ]'
reset; tick a DAILY_DIGEST_CLAIM=5
check "C7 knob 5 is a note and the default (claims)" \
  'grep -q "DAILY_DIGEST_CLAIM=5" "$HA/logs/daily-digest.notes.log" && grep -q "^hub-a POST /api/ledger/claim" "$T/reqlog" && [ "$(n_send)" = 1 ]'
reset; tick a DAILY_DIGEST_CLAIM_STALE_S=60
check "C7 stale 60 is out of range: a note and the default 900" \
  'grep -q "DAILY_DIGEST_CLAIM_STALE_S=60" "$HA/logs/daily-digest.notes.log" && grep "^hub-a POST /api/ledger/claim" "$T/reqlog" | grep -q "\"stale_s\":900"'

# ── V: job_ledger_claim's rc table, through the same fake ───────────────────
verb() { # verb <args...>: prints "<rc> <stdout>"
  local o r
  o=$(HARNESS="$HA" JOBS_BOX=hub-a bash -c '. "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1; job_ledger_claim "$@"' _ "$@"); r=$?
  printf '%s %s' "$r" "$o"
}
reset
check "V1 absent row: rc 0, prints the status" '[ "$(verb vkind k1 sending 120 sent)" = "0 sending" ]'
check "V2 held fresh: rc 3, prints the holder status" '[ "$(verb vkind k1 sending 120 sent)" = "3 sending" ]'
check "V2 terminal list: rc 3" '[ "$(verb vkind k1 other 120 sending)" = "3 sending" ]'
echo 404 > "$T/claim.code"
check "V3 404: rc 2, never claimed" '[ "$(verb vkind k2 sending 120)" = "2 " ]'
echo 503 > "$T/claim.code"
check "V4 503: rc 1" '[ "$(verb vkind k2 sending 120)" = "1 " ]'
rm -f "$T/claim.code"
check "V4 a non-integer stale_s: rc 1 and no request" \
  '[ "$(verb vkind k3 sending abc)" = "1 " ] && ! grep -q "\"key\":\"k3\"" "$T/reqlog"'
check "V body carries actor and terminal as an array" \
  'grep "POST /api/ledger/claim" "$T/reqlog" | head -1 | cut -d" " -f4- | jq -e ".actor == \"hub-a\" and .terminal == [\"sent\"] and .stale_s == 120" >/dev/null'

# ── M3 (mutation): the lane with the claim block removed fails C1 ──────────
for h in "$HA" "$HB"; do
  rm -f "$h/bin/daily-digest.sh"
  sed '/# >>> claim/,/# <<< claim/d' "$LANE_SRC" > "$h/bin/daily-digest.sh"; chmod +x "$h/bin/daily-digest.sh"
done
check "M3 the mutation changed the lane" '! cmp -s "$HA/bin/daily-digest.sh" "$LANE_SRC"'
reset; both
check "M3 no claim: C1 sends twice ($(n_send))" '[ "$(n_send)" = 2 ]'
for h in "$HA" "$HB"; do rm -f "$h/bin/daily-digest.sh"; ln -s "$LANE_SRC" "$h/bin/daily-digest.sh"; done

echo "digest-once: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
