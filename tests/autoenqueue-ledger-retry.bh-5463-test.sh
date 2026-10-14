#!/bin/bash
# tests/autoenqueue-ledger-retry.bh-5463-test.sh — BH-5463: an autoenqueue
# ledger read that answers rc 1 (unusable) is retried once after 2 s, the skip
# line names the HTTP code or curl rc, and a run of more than
# MC_AE_LEDGER_BURST (default 5) ledger skips in one project tick is ONE alert.
#
# On 2026-10-08 08:15:32-39Z job_ledger_get answered rc 1 for 18 READY PRs in a
# row, bin/lib/autoenqueue.sh skipped every one of them and nothing was sent
# that tick. Six minutes later the same reads answered rc 2 (no row).
#
# A1-A7 source "$DIR/bin/lib/autoenqueue.sh" into this shell and call
# ae_project with the conductor's 13-column rows, as tests/tier2-autoenqueue-test.sh
# does. job_ledger_get is a scripted stub: it reads its next answer from
# $T/fx/ledger-script (`1:http=503`, `1:curl_rc=28`, `2`, `0:enqueued`; the last
# line repeats) and writes the word after `:` to JOBS_STATUS_FILE, as the real
# client does. _ae_sleep is stubbed to record its argument.
# A8-A9 source the REAL "$DIR/bin/jobs-client.sh" (bin/lib/jobs/req.sh +
# bin/lib/jobs/jobs.sh) against a curl stub and read JOBS_STATUS_FILE.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/autoenqueue-ledger-retry.bh-5463-test.sh
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

# ============================================================================
# The unit harness (the shape of tests/tier2-autoenqueue-test.sh's).
# ============================================================================
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
    restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-10-08T08:00:00Z"}]}' ;;
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
# The scripted ledger read. One line of $T/fx/ledger-script per call; the last
# line repeats. `<rc>:<word>`: rc 0 prints the word as the status, rc 1 writes
# the word to JOBS_STATUS_FILE as the real _jobs_req does.
job_ledger_get() {
  echo "$2" >> "$T/ledger-calls"
  local n line rc word
  n=$(grep -c . "$T/ledger-calls")
  line=$(sed -n "${n}p" "$T/fx/ledger-script"); [ -n "$line" ] || line=$(tail -1 "$T/fx/ledger-script")
  rc="${line%%:*}"; word=""; [ "$line" != "$rc" ] && word="${line#*:}"
  if [ -n "${JOBS_STATUS_FILE:-}" ] && [ "$rc" != 0 ]; then
    if [ -n "$word" ]; then printf '%s\n' "$word" > "$JOBS_STATUS_FILE"; else echo http=404 > "$JOBS_STATUS_FILE"; fi
  fi
  case "$rc" in 0) printf '%s' "$word"; return 0 ;; 2) return 2 ;; *) return 1 ;; esac
}
job_ledger_put() { echo "$*" >> "$T/ledger-puts"; return 0; }
job_artifact_put() { return 0; }

# shellcheck source=bin/lib/autoenqueue.sh
. "$DIR/bin/lib/autoenqueue.sh" || exit 1
# The 2 s wait, recorded instead of slept (defined after the source on purpose).
_ae_sleep() { echo "$1" >> "$T/sleeps"; }
# BH-6433 made the default ladder 2 5 10; this suite pins the one-retry premise.
export MC_AE_LEDGER_BACKOFF=2

row() { printf '%s\t%s\t%s\tticket/mg-%s\tfalse\tCLEAN\tMERGEABLE\tOPEN\tfalse\t-\tmain\t-\tfalse' \
  "$1" "$U/$1" "$(hsha "$1")" "$1"; }
fx() { echo "open $(hsha "$1") main clean operator" > "$T/fx/pr-$1"; ae_mark mgfy ready "$SLUG#$1" "$(hsha "$1")"; }
reset() {
  rm -f "$T/fx"/* "$H/flags"/* "$T/ledger-calls" "$T/ledger-puts" "$T/sleeps" "$H/state/tier2-autoenqueue.txt"
  : > "$T/posts.txt"; : > "$MC_LOG"; : > "$MC_ATTEMPTS"; : > "$H/logs/ALERTS.log"; : > "$T/gh-calls.txt"
  scratch_rm "$MC_TICK_DIR"; mkdir -p "$MC_TICK_DIR"
}
script() { printf '%s\n' "$@" > "$T/fx/ledger-script"; }
ae() { ( MODE=merge; MERGES=1; ae_project mgfy "$SLUG" mergify main "$@" ); }
posts()  { grep -c . "$T/posts.txt" 2>/dev/null || true; }
calls()  { grep -c . "$T/ledger-calls" 2>/dev/null || echo 0; }
sleeps() { { tr '\n' ' ' < "$T/sleeps"; } 2>/dev/null | sed 's/ $//'; }
nalert() { grep -c '^ALERT' "$H/logs/ALERTS.log" 2>/dev/null || true; }

# ── A1: rc 1 then rc 2 sends the enqueue ─────────────────────────────────────
reset; fx 31; script 1:http=503 2
ae "$(row 31)"
[ "$(posts)" = 1 ] && ok || bad "A1 rc 1 then rc 2 must send one enqueue (got $(posts)); log: $(cat "$MC_LOG")"
[ "$(sleeps)" = 2 ] && ok || bad "A1 the retry must wait 2 s once (sleeps: '$(sleeps)')"
[ "$(calls)" -ge 2 ] && ok || bad "A1 the ledger must be read twice before the POST (calls: $(calls))"
grep -q ': ledger —' "$MC_LOG" && bad "A1 a retried read that answered must log no ledger skip: $(cat "$MC_LOG")" || ok

# ── A2: rc 1 twice -> the skip names the HTTP code ───────────────────────────
reset; fx 31; script 1:http=503 1:http=503
ae "$(row 31)"
[ "$(posts)" = 0 ] && ok || bad "A2 rc 1 twice must send nothing (got $(posts))"
grep -qF "not enqueued at $(hsha 31 | cut -c1-8): ledger — the autoenqueue ledger is unreadable (http=503, retried once after 2s)" "$MC_LOG" && ok \
  || bad "A2 the skip line must name http=503 and the retry: $(cat "$MC_LOG")"
[ "$(calls)" = 2 ] && ok || bad "A2 expected 2 ledger reads, got $(calls)"

# ── A3: a transport failure is named ─────────────────────────────────────────
reset; fx 31; script 1:curl_rc=28
ae "$(row 31)"
grep -q 'ledger is unreadable (curl_rc=28, retried once after 2s)' "$MC_LOG" && ok || bad "A3 the skip must name curl_rc=28: $(cat "$MC_LOG")"

# ── A4: the knob off -> one read, no wait ────────────────────────────────────
reset; fx 31; script 1:http=503 2
( MC_AE_LEDGER_RETRY=0; ae "$(row 31)" )
[ "$(posts)" = 0 ] && ok || bad "A4 MC_AE_LEDGER_RETRY=0 must not retry into a send (got $(posts))"
[ -z "$(sleeps)" ] && ok || bad "A4 MC_AE_LEDGER_RETRY=0 must not wait (sleeps: '$(sleeps)')"
[ "$(calls)" = 1 ] && ok || bad "A4 MC_AE_LEDGER_RETRY=0 must read once (calls: $(calls))"
grep -q 'unreadable (http=503, no retry: mc_ae_ledger_retry=0)' "$MC_LOG" && ok || bad "A4 the skip line must say no retry: $(cat "$MC_LOG")"

# ── A5: six skips in a row -> one ALERT; no retry after it ───────────────────
reset; R=()
for n in 41 42 43 44 45 46 47; do fx "$n"; R+=("$(row "$n")"); done
script 1:http=502
ae "${R[@]}"
[ "$(posts)" = 0 ] && ok || bad "A5 no POST in a ledger outage (got $(posts))"
[ "$(nalert)" = 1 ] && ok || bad "A5 expected exactly one ALERT, got $(nalert): $(cat "$H/logs/ALERTS.log")"
A5=$(grep '^ALERT' "$H/logs/ALERTS.log")
for want in "$SLUG" AUTOENQUEUE http=502 " 6 READY rows"; do
  [[ "$A5" == *"$want"* ]] && ok || bad "A5 the ALERT must carry '$want': $A5"
done
for n in 41 42 43 44 45 46; do
  [[ "$A5" == *"#$n"* ]] && ok || bad "A5 the ALERT must name #$n: $A5"
done
[ "$(grep -c . "$T/sleeps" 2>/dev/null)" = 6 ] && ok || bad "A5 rows 1-6 retry and row 7 does not (sleeps: $(grep -c . "$T/sleeps" 2>/dev/null))"
grep -qF "$SLUG#47 not enqueued at $(hsha 47 | cut -c1-8): ledger — the autoenqueue ledger is unreadable (http=502, no retry: the ledger burst alert fired this tick)" "$MC_LOG" && ok \
  || bad "A5 row 7's skip must say the burst alert stopped the retry: $(grep '#47' "$MC_LOG")"
grep -q "AUTOENQUEUE $SLUG ledger skip run ended at 7 rows" "$MC_LOG" && ok || bad "A5 the run's final count must be logged once: $(cat "$MC_LOG")"

# ── A6: five skips -> no ALERT ───────────────────────────────────────────────
reset; R=()
for n in 51 52 53 54 55; do fx "$n"; R+=("$(row "$n")"); done
script 1:http=503
ae "${R[@]}"
[ "$(nalert)" = 0 ] && ok || bad "A6 five skips must not alert: $(cat "$H/logs/ALERTS.log")"

# ── A7: a good read breaks the run ───────────────────────────────────────────
# Rows 61-63 fail twice each (6 reads), 64 answers rc 2 (read, then the
# send_locked re-read), 65-67 fail twice each.
a7() {
  reset; R=()
  for n in 61 62 63 64 65 66 67; do fx "$n"; R+=("$(row "$n")"); done
  script 1:http=503 1:http=503 1:http=503 1:http=503 1:http=503 1:http=503 2 2 1:http=503
  ae "${R[@]}"
}
a7
[ "$(posts)" = 1 ] && ok || bad "A7 the row that read rc 2 must send (got $(posts)): $(cat "$MC_LOG")"
[ "$(nalert)" = 0 ] && ok || bad "A7 3 + 3 skips split by a good read must not alert: $(cat "$H/logs/ALERTS.log")"
export MC_AE_LEDGER_BURST=2
a7
[ "$(nalert)" = 1 ] && ok || bad "A7 MC_AE_LEDGER_BURST=2 must alert once on a run of 3: $(cat "$H/logs/ALERTS.log")"
unset MC_AE_LEDGER_BURST

# ============================================================================
# A8-A9: the REAL side channel in _jobs_req, through the real job_ledger_get.
# ============================================================================
J="$T/j"; mkdir -p "$J/bin" "$J/logs"
cat > "$J/bin/curl" <<'EOF'
#!/bin/bash
mode=$(cat "$CURL_MODE")
case "$mode" in
  rc28) exit 28 ;;
  http-503) printf '{"error":"down"}\n503' ;;
  http-200-empty) printf '{"ledger":null}\n200' ;;
  http-404) printf '{"error":"not found"}\n404' ;;
  http-200-row) printf '{"ledger":{"status":"enqueued"}}\n200' ;;
esac
exit 0
EOF
chmod +x "$J/bin/curl"
# side <mode> <JOBS_URL> [status-file] — one real job_ledger_get in a fresh
# shell; prints "<rc> <file content|<none>>".
side() {
  echo "$1" > "$J/curl-mode"
  ( export PATH="$J/bin:$PATH" HARNESS="$J" CURL_MODE="$J/curl-mode" HARNESS_SECRET=fixture-secret \
           JOBS_RETRIES=0 JOBS_ALERT=0 JOBS_URL="$2"
    # shellcheck source=bin/jobs-client.sh
    . "$DIR/bin/jobs-client.sh" >/dev/null 2>&1 || { echo "99 <no-client>"; exit 0; }
    if [ -n "${3:-}" ]; then rm -f "$3"; JOBS_STATUS_FILE="$3" job_ledger_get autoenqueue "k@h" >/dev/null; rc=$?
      printf '%s %s\n' "$rc" "$(cat "$3" 2>/dev/null || echo '<none>')"
    else job_ledger_get autoenqueue "k@h" >/dev/null; echo "$? -"; fi )
}
SF="$J/st"
[ "$(side http-503 http://stub "$SF")" = "1 http=503" ] && ok || bad "A8 a 503 must give rc 1 and http=503 (got '$(side http-503 http://stub "$SF")')"
[ "$(side http-200-empty http://stub "$SF")" = "1 http=200" ] && ok || bad "A8 a 2xx with no status must give rc 1 and http=200 (got '$(side http-200-empty http://stub "$SF")')"
[ "$(side http-404 http://stub "$SF")" = "2 http=404" ] && ok || bad "A8 a 404 must give rc 2 and http=404 (got '$(side http-404 http://stub "$SF")')"
[ "$(side http-200-row http://stub "$SF")" = "0 http=200" ] && ok || bad "A8 a row must give rc 0 and http=200 (got '$(side http-200-row http://stub "$SF")')"
[ "$(side rc28 http://stub "$SF")" = "1 curl_rc=28" ] && ok || bad "A9 a transport failure must give rc 1 and curl_rc=28 (got '$(side rc28 http://stub "$SF")')"
[ "$(side http-503 "" "$SF")" = "1 no-url" ] && ok || bad "A9 an empty JOBS_URL must write no-url (got '$(side http-503 "" "$SF")')"
before=$(find "$J" -type f | sort)
[ "$(side http-503 http://stub)" = "1 -" ] && ok || bad "A9 the unset side channel must not change the rc"
[ "$(find "$J" -type f | sort | grep -v -e '/logs/' -e '/flags/' -e '/curl-mode$')" = "$(grep -v -e '/logs/' -e '/flags/' -e '/curl-mode$' <<<"$before")" ] && ok \
  || bad "A9 JOBS_STATUS_FILE unset must create no file: $(find "$J" -type f)"

echo "autoenqueue-ledger-retry.bh-5463-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
