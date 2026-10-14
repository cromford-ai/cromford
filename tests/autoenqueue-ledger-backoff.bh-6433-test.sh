#!/bin/bash
# tests/autoenqueue-ledger-backoff.bh-6433-test.sh — BH-6433: an unusable
# autoenqueue ledger read is read again after 2 s, 5 s and 10 s (knob
# MC_AE_LEDGER_BACKOFF), each failed read writes one log line with the endpoint,
# the answer code and the first 200 bytes of the answer body, and the G2 Sentry
# event is sent only after the last read, naming the endpoint, the last code and
# the attempt count.
#
# On 2026-10-13 07:15Z the worker answered GET /api/ledger with a 500
# (`error code: 1101`, a Cloudflare worker exception) and the row was skipped
# after one 2 s retry, with one Sentry event that named neither the endpoint nor
# the attempt count.
#
# B1-B7, B9 source "$DIR/bin/lib/autoenqueue.sh" and call ae_project with the
# conductor's 13-column rows (the shape of the bh-5463 suite). job_ledger_get is
# a scripted stub: one line of $T/fx/ledger-script per call (the last repeats),
# `<rc>:<code>[:<body>]`; rc 1 writes <code> to JOBS_STATUS_FILE and <body> (or
# $T/fx/body when it exists) to JOBS_BODY_FILE, as the real _jobs_req does.
# B8 sources the REAL "$DIR/bin/jobs-client.sh" against a curl stub.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/autoenqueue-ledger-backoff.bh-6433-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/mgfy-os
U="https://github.com/$SLUG/pull"
hsha() { printf '%040d' "$1"; }
EP='GET /api/ledger?kind=autoenqueue'

export HARNESS="$T/u"; H="$HARNESS"; MC_H="$H"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/env" "$T/fx" "$T/ubin"
printf 'GH_ADMIN_TOKEN=pat-admin-fixture\n' > "$H/env/github-admin.env"
printf '#!/bin/bash\n[ "$2" = board_prefix ] && echo X\nexit 0\n' > "$H/bin/fleet-conf.sh"; chmod +x "$H/bin/fleet-conf.sh"
cp "$DIR/tests/lib/rest-emit.sh" "$T/ubin/restpr"; chmod +x "$T/ubin/restpr"
MC_ATTEMPTS="$H/state/attempts.txt"; MC_LOG="$H/logs/merge-conductor.log"; : > "$MC_ATTEMPTS"; : > "$MC_LOG"
MC_TICK_ID=unit-tick; MC_TICK_DIR="$H/state/tick"
export MC_ATTEMPTS MC_LOG MC_TICK_ID MC_TICK_DIR

cat > "$T/ubin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
FX="$T/fx"
num_of() { printf '%s' "\$1" | sed -nE 's#.*/(pulls|issues)/([0-9]+).*#\2#p'; }
case "\$*" in
  "api repos/$SLUG -q .id") echo 1 ;;
  *"api -i -X GET repos/$SLUG/commits/"*"/check-runs"*)
    restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-13T07:00:00Z"}]}' ;;
  *"api -i -X POST repos/$SLUG/issues/"*"/comments"*)
    printf '%s\n' "\$*" >> "$T/posts.txt"
    restpr --raw 201 '{"id":777,"body":"@mergifyio queue"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/"*)
    n=\$(num_of "\$*"); read -r st hd base ms login < "\$FX/pr-\$n"
    restpr "\$st" "\$hd" "ticket/mg-\$n" "\$base" "" MERGEABLE "\$ms" "\$login" ;;
  *) exit 1 ;;
esac
exit 0
EOF
chmod +x "$T/ubin/gh"
export PATH="$T/ubin:$PATH"
export GH_TOKEN=pat-default-fixture
# shellcheck source=bin/lib/gh-rest.sh
. "$DIR/bin/lib/gh-rest.sh" || exit 1
# shellcheck source=bin/lib/gh-repo-token.sh
. "$DIR/bin/lib/gh-repo-token.sh" || exit 1
export GH_ETAG=0

mc_log()   { echo "$*" >> "$MC_LOG"; }
mc_alert() { echo "ALERT $*" >> "$H/logs/ALERTS.log"; }
mc_attempt_has() { grep -qxF "$1" "$MC_ATTEMPTS"; }
mc_attempt_put() { echo "$1" >> "$MC_ATTEMPTS"; }
mc_record_for() { echo "$T/rec"; }
mc_issue_of() { echo 1; }
mc_verdict() { local n="${1##*/}"; printf 'APPROVE\t-\t%s\tJ%s\t-' "$(hsha "$n")" "$n"; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
to_lane_hold() { return 1; }
bg_scan_read() { return 0; }
main_red_exempt() { return 1; }
hotfix_pr_is() { return 1; }
flag_active() { [ -f "$H/flags/$1" ]; }
hold_check_thread() { printf 'clear\t-'; return 0; }
# One Sentry event = one JSON line: level, lane, reason, message, extra.
sentry_report() {
  jq -nc --arg l "$1" --arg n "$2" --arg r "$3" --arg m "$4" --argjson x "${5:-null}" \
    '{level:$l,lane:$n,reason:$r,message:$m,extra:$x}' >> "$T/sentry.jsonl"
}
job_ledger_get() {
  echo "$2" >> "$T/ledger-calls"
  local n line rc rest code body=""
  n=$(grep -c . "$T/ledger-calls")
  line=$(sed -n "${n}p" "$T/fx/ledger-script"); [ -n "$line" ] || line=$(tail -1 "$T/fx/ledger-script")
  rc="${line%%:*}"; rest=""; [ "$line" != "$rc" ] && rest="${line#*:}"
  code="${rest%%:*}"; [ "$rest" != "$code" ] && body="${rest#*:}"
  if [ "$rc" != 0 ]; then
    [ -n "${JOBS_STATUS_FILE:-}" ] && printf '%s\n' "${code:-http=404}" > "$JOBS_STATUS_FILE"
    if [ -n "${JOBS_BODY_FILE:-}" ]; then
      if [ -f "$T/fx/body" ]; then head -c 200 "$T/fx/body" > "$JOBS_BODY_FILE"
      else head -c 200 <<<"$body" | tr -d '\n' > "$JOBS_BODY_FILE"; fi
    fi
  fi
  case "$rc" in 0) printf '%s' "$code"; return 0 ;; 2) return 2 ;; *) return 1 ;; esac
}
job_ledger_put() { echo "$*" >> "$T/ledger-puts"; return 0; }
job_artifact_put() { return 0; }

# shellcheck source=bin/lib/autoenqueue.sh
. "$DIR/bin/lib/autoenqueue.sh" || exit 1
_ae_sleep() { echo "$1" >> "$T/sleeps"; }

row() { printf '%s\t%s\t%s\tticket/mg-%s\tfalse\tCLEAN\tMERGEABLE\tOPEN\tfalse\t-\tmain\t-\tfalse' \
  "$1" "$U/$1" "$(hsha "$1")" "$1"; }
fx() { echo "open $(hsha "$1") main clean operator" > "$T/fx/pr-$1"; ae_mark mgfy ready "$SLUG#$1" "$(hsha "$1")"; }
reset() {
  rm -f "$T/fx"/* "$H/flags"/* "$T/ledger-calls" "$T/ledger-puts" "$T/sleeps" "$T/sentry.jsonl" "$H/state/tier2-autoenqueue.txt"
  : > "$T/posts.txt"; : > "$MC_LOG"; : > "$MC_ATTEMPTS"; : > "$H/logs/ALERTS.log"; : > "$T/gh-calls.txt"
  scratch_rm "$MC_TICK_DIR"; mkdir -p "$MC_TICK_DIR"
}
script() { printf '%s\n' "$@" > "$T/fx/ledger-script"; }
ae() { ( MODE=merge; MERGES=1; ae_project mgfy "$SLUG" mergify main "$@" ); }
posts()  { grep -c . "$T/posts.txt" 2>/dev/null || true; }
calls()  { grep -c . "$T/ledger-calls" 2>/dev/null || echo 0; }
sleeps() { { tr '\n' ' ' < "$T/sleeps"; } 2>/dev/null | sed 's/ $//'; }
nsentry() { grep -c . "$T/sentry.jsonl" 2>/dev/null || echo 0; }
nalert() { grep -c '^ALERT' "$H/logs/ALERTS.log" 2>/dev/null || true; }
H31=$(hsha 31 | cut -c1-8)
E500='1:http=500:error code: 1101'

# ── B1: 500, 500, then a miss -> enqueued, no event ─────────────────────────
reset; fx 31; script "$E500" "$E500" 2
ae "$(row 31)"
[ "$(posts)" = 1 ] && ok || bad "B1 a read that recovers on try 3 must send one enqueue (got $(posts)); log: $(cat "$MC_LOG")"
[ "$(sleeps)" = "2 5" ] && ok || bad "B1 waits must be '2 5' (got '$(sleeps)')"
[ "$(nsentry)" = 0 ] && ok || bad "B1 a recovered read must send no Sentry event: $(cat "$T/sentry.jsonl" 2>/dev/null)"
grep -q ': ledger —' "$MC_LOG" && bad "B1 a recovered read must log no ledger skip: $(cat "$MC_LOG")" || ok

# ── B2: 500 on all 4 reads -> one event naming endpoint, status, attempts ───
reset; fx 31; script "$E500"
ae "$(row 31)"
[ "$(posts)" = 0 ] && ok || bad "B2 nothing sent (got $(posts))"
[ "$(calls)" = 4 ] && ok || bad "B2 expected 4 ledger reads, got $(calls)"
[ "$(sleeps)" = "2 5 10" ] && ok || bad "B2 waits must be '2 5 10' (got '$(sleeps)')"
[ "$(nsentry)" = 1 ] && ok || bad "B2 exactly one Sentry event (got $(nsentry)): $(cat "$T/sentry.jsonl" 2>/dev/null)"
EV=$(head -1 "$T/sentry.jsonl" 2>/dev/null)
MSG=$(jq -r '.message' <<<"$EV" 2>/dev/null)
for want in "$EP" http=500 "4 attempts"; do
  [[ "$MSG" == *"$want"* ]] && ok || bad "B2 the event message must carry '$want': $MSG"
done
jq -e --arg ep "$EP" '.extra.endpoint == $ep and .extra.attempts == "4" and .extra.ledger_code == "http=500"' <<<"$EV" >/dev/null 2>&1 && ok \
  || bad "B2 the event extra must name endpoint, attempts 4, ledger_code http=500: $EV"
grep -qF "$SLUG#31 not enqueued at $H31: ledger — the autoenqueue ledger is unreadable (http=500, read 4 times, waits 2s 5s 10s)" "$MC_LOG" && ok \
  || bad "B2 the skip line must name the read count and the waits: $(cat "$MC_LOG")"

# ── B3: one log line per failed read, body flattened and cut ────────────────
reset; fx 31; script "$E500"
{ printf 'error code: 1101 first-half\tafter-tab'; printf '\nSECONDHALF'; printf 'x%.0s' $(seq 1 300); } > "$T/fx/body"
ae "$(row 31)"
RL=$(grep -F "ledger read " "$MC_LOG")
[ "$(grep -c "ledger read [1-4]/4 failed — GET /api/ledger?kind=autoenqueue http=500 body=" <<<"$RL")" = 4 ] && ok \
  || bad "B3 expected 4 per-read lines: $(cat "$MC_LOG")"
[ "$(grep -o 'ledger read [1-4]/4' <<<"$RL" | tr '\n' ' ')" = "ledger read 1/4 ledger read 2/4 ledger read 3/4 ledger read 4/4 " ] && ok \
  || bad "B3 the lines must carry 1/4..4/4 in order: $RL"
grep -q "AUTOENQUEUE $SLUG#31 at $H31: ledger read 1/4 failed" <<<"$RL" && ok || bad "B3 the line must name the PR and head: $RL"
B3OK=1
while IFS= read -r l; do
  b="${l#*body=}"
  [ "${#b}" -le 200 ] || B3OK=0
  [[ "$b" == *$'\t'* ]] && B3OK=0
done <<<"$RL"
[ "$B3OK" = 1 ] && ok || bad "B3 each body= value must be at most 200 bytes with no tab: $RL"
grep -q '^SECONDHALF' "$MC_LOG" && bad "B3 the body newline must be flattened: $(cat "$MC_LOG")" || ok
grep -qF 'body=error code: 1101 first-half after-tab SECONDHALF' <<<"$RL" && ok || bad "B3 the body must keep its text on one line: $RL"

# ── B4: the first read answers -> one request per gate ──────────────────────
reset; fx 31; script 0:enqueued
ae "$(row 31)"
[ "$(calls)" = 1 ] && ok || bad "B4a an enqueued row is read once (calls $(calls))"
[ -z "$(sleeps)" ] && ok || bad "B4a no wait (sleeps '$(sleeps)')"
[ "$(posts)" = 0 ] && ok || bad "B4a nothing sent (got $(posts))"
grep -q 'ledger read' "$MC_LOG" && bad "B4a no per-read failure line: $(cat "$MC_LOG")" || ok
reset; fx 31; script 2
ae "$(row 31)"
[ "$(calls)" = 2 ] && ok || bad "B4b a miss is read at G2 and under the lock (calls $(calls))"
[ -z "$(sleeps)" ] && ok || bad "B4b no wait (sleeps '$(sleeps)')"
[ "$(posts)" = 1 ] && ok || bad "B4b one send (got $(posts))"

# ── B5: the knob ────────────────────────────────────────────────────────────
reset; fx 31; script "$E500"
( export MC_AE_LEDGER_BACKOFF="1 1"; ae "$(row 31)" )
[ "$(calls)" = 3 ] && [ "$(sleeps)" = "1 1" ] && ok || bad "B5 '1 1': want 3 calls, sleeps '1 1' (got $(calls), '$(sleeps)')"
reset; fx 31; script "$E500"
( export MC_AE_LEDGER_BACKOFF=0; ae "$(row 31)" )
[ "$(calls)" = 2 ] && [ "$(sleeps)" = 0 ] && ok || bad "B5 '0': want 2 calls, sleeps '0' (got $(calls), '$(sleeps)')"
grep -q 'unreadable (http=500, retried once after 0s)' "$MC_LOG" && ok || bad "B5 '0': skip text must say retried once after 0s: $(cat "$MC_LOG")"
for v in abc 61 -1 "1 2 3 4 5 6" ""; do
  reset; fx 31; script "$E500"
  ( export MC_AE_LEDGER_BACKOFF="$v"; ae "$(row 31)" )
  [ "$(sleeps)" = "2 5 10" ] && ok || bad "B5 '$v' must fall back to '2 5 10' (got '$(sleeps)')"
done
reset; fx 31; script "$E500"
( export MC_AE_LEDGER_BACKOFF=abc; ae "$(row 31)" )
grep -q 'MC_AE_LEDGER_BACKOFF' "$MC_LOG" && ok || bad "B5 an invalid ladder must be logged: $(cat "$MC_LOG")"
reset; fx 31; script "$E500"
( export MC_AE_LEDGER_RETRY=0; ae "$(row 31)" )
[ "$(calls)" = 1 ] && [ -z "$(sleeps)" ] && ok || bad "B5 MC_AE_LEDGER_RETRY=0: want 1 call, no sleeps (got $(calls), '$(sleeps)')"

# ── B6: a config fault is read once ─────────────────────────────────────────
reset; fx 31; script 1:no-url
ae "$(row 31)"
[ "$(calls)" = 1 ] && ok || bad "B6 no-url is read once (calls $(calls))"
[ -z "$(sleeps)" ] && ok || bad "B6 no wait on no-url (sleeps '$(sleeps)')"
grep -q 'unreadable (no-url, no retry: a config fault)' "$MC_LOG" && ok || bad "B6 the skip must say a config fault: $(cat "$MC_LOG")"
[ "$(grep -c 'ledger read 1/4 failed' "$MC_LOG")" = 1 ] && ok || bad "B6 one per-read line: $(cat "$MC_LOG")"
reset; fx 31; script 1:no-secret
ae "$(row 31)"
[ "$(calls)" = 1 ] && ok || bad "B6 no-secret is read once (calls $(calls))"

# ── B7: the burst alert still caps the waits ────────────────────────────────
reset; R=()
for n in 41 42 43 44 45 46 47; do fx "$n"; R+=("$(row "$n")"); done
script "$E500"
ae "${R[@]}"
[ "$(nalert)" = 1 ] && ok || bad "B7 exactly one ALERT, got $(nalert)"
[ "$(grep -c . "$T/sleeps" 2>/dev/null)" = 18 ] && ok || bad "B7 rows 41-46 wait 3 times each (sleeps: $(grep -c . "$T/sleeps" 2>/dev/null))"
[ "$(grep -c "$SLUG#47 at $(hsha 47 | cut -c1-8): ledger read 1/1 failed" "$MC_LOG")" = 1 ] && ok || bad "B7 row 47 reads once: $(grep '#47' "$MC_LOG")"
grep -q "$SLUG#47 not enqueued.*no retry: the ledger burst alert fired this tick" "$MC_LOG" && ok || bad "B7 row 47's skip must name the burst: $(grep '#47' "$MC_LOG")"

# ── B9: the send-lock path gets the ladder, no event ────────────────────────
reset; fx 31; script 2 "$E500"
ae "$(row 31)"
[ "$(posts)" = 0 ] && ok || bad "B9 nothing sent (got $(posts))"
grep -qF "the ledger went unreadable before the POST (http=500, read 4 times, waits 2s 5s 10s)" "$MC_LOG" && ok \
  || bad "B9 the send-lock line must name the reads: $(cat "$MC_LOG")"
[ "$(nsentry)" = 0 ] && ok || bad "B9 the send-lock path sends no Sentry event: $(cat "$T/sentry.jsonl" 2>/dev/null)"

# ============================================================================
# B8: the REAL JOBS_BODY_FILE side channel in _jobs_req.
# ============================================================================
J="$T/j"; mkdir -p "$J/bin" "$J/logs" "$J/empty"
cat > "$J/bin/curl" <<'EOF'
#!/bin/bash
mode=$(cat "$CURL_MODE")
case "$mode" in
  rc28) exit 28 ;;
  http-500) printf 'error code: 1101\n500' ;;
  http-500-long) printf 'y%.0s' $(seq 1 300); printf '\n500' ;;
esac
exit 0
EOF
chmod +x "$J/bin/curl"
# side <mode> [body-file] [status-file] — one real job_ledger_get; prints the rc.
side() {
  echo "$1" > "$J/curl-mode"
  ( export PATH="$J/bin:$PATH" HARNESS="$J" CURL_MODE="$J/curl-mode" HARNESS_SECRET=fixture-secret \
           JOBS_RETRIES=0 JOBS_ALERT=0 JOBS_URL=http://stub
    # shellcheck source=bin/jobs-client.sh
    . "$DIR/bin/jobs-client.sh" >/dev/null 2>&1 || { echo 99; exit 0; }
    if [ -n "${2:-}" ]; then JOBS_BODY_FILE="$2" JOBS_STATUS_FILE="${3:-}" job_ledger_get autoenqueue "k@h" >/dev/null
    else job_ledger_get autoenqueue "k@h" >/dev/null; fi
    echo $? )
}
BF="$J/empty/body"; SF="$J/empty/st"
RC=$(side http-500 "$BF" "$SF")
[ "$RC" = 1 ] && ok || bad "B8a a 500 is rc 1 (got $RC)"
[ "$(cat "$BF" 2>/dev/null)" = "error code: 1101" ] && ok || bad "B8a the body file must hold the answer (got '$(cat "$BF" 2>/dev/null)')"
[ "$(head -c 64 "$SF" | tr -d '\n')" = http=500 ] && ok || bad "B8a JOBS_STATUS_FILE stays one word (got '$(cat "$SF" 2>/dev/null)')"
side http-500-long "$BF" >/dev/null
[ "$({ wc -c < "$BF"; } 2>/dev/null || echo 999)" -le 200 ] && [ -s "$BF" ] && ok || bad "B8b the body file is cut at 200 bytes (got $({ wc -c < "$BF"; } 2>/dev/null))"
echo stale > "$BF"
side rc28 "$BF" >/dev/null
[ -f "$BF" ] && [ ! -s "$BF" ] && ok || bad "B8c a transport fault empties the body file (exists=$([ -f "$BF" ] && echo y || echo n), '$(cat "$BF" 2>/dev/null)')"
rm -f "$J/empty"/*
side http-500 >/dev/null
[ -z "$(ls -A "$J/empty")" ] && ok || bad "B8d JOBS_BODY_FILE unset must write no file: $(ls -A "$J/empty")"
# B8e the round trip: the real writer, then the reader autoenqueue.sh uses.
OUT=$( MC_TICK_DIR="$J/tick"; mkdir -p "$MC_TICK_DIR"
  cf=$(_ae_ledger_code_file)
  side http-500 "$cf.body" "$cf" >/dev/null
  _ae_ledger_body 2>/dev/null )
[ "$OUT" = "error code: 1101" ] && ok || bad "B8e _ae_ledger_body must read back the real body (got '$OUT')"

echo "autoenqueue-ledger-backoff.bh-6433-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
