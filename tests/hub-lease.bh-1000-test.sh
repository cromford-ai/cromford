#!/bin/bash
# tests/hub-lease.bh-1000-test.sh — the configured hub FAILS OPEN when its own
# worker errors, and says so out loud.
#
# THE INCIDENT (2026-09-19, 18:31–19:00Z). `hub_lease` was never applied to D1.
# The worker 500'd on every lease read, `_jobs_req` mapped a bodiless 500 to rc
# 1 ("unreachable"), and `check` exited 1 with NO cache — which meant no grace,
# no alert (the old code alerted only when a cache existed) and no lane. All 52
# `check &&` lines on the hub skipped for 29 minutes and nothing paged.
#
# THE RULE THIS PINS. Fail CLOSED is right when another box might be the hub.
# It is wrong when the box asking is the CONFIGURED hub and the only thing that
# could promote someone else is the very worker that is not answering. So: the
# configured hub keeps running its lanes on a worker ERROR (never a 404), pages
# `--critical` once the failure has lasted HUB_LEASE_PAGE_S, and repeats hourly.
# Every other shape stays exactly as fail-closed as it is today, and the cases
# below are mostly those negatives.
#
# Driven, not grepped: the REAL bin/hub-lease.sh runs against a stubbed curl and
# a fake bin/lane-alert.sh that records its argv. One pinned clock, every time
# expressed as an offset from it.
# Run from anywhere: tests/hub-lease.bh-1000-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/bin/jobs-client.sh"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/box-name.sh" "$T/bin/box-name.sh"
cp "$DIR/bin/lib/hub-box.sh" "$T/bin/lib/hub-box.sh"
printf 'box-hub\n' > "$T/state/box-name"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PINNED_NOW=1000000000   # 2001-09-09T01:46:40Z
FLAG="$T/flags/alerted-hub-lease-unreachable"
SINCE="$T/state/hub-lease-failing-since"
CALLS="$T/lane-alert.argv"

# The worker's real answers. CURL_MODE=schema is the incident verbatim: the 503
# the worker now returns for an unapplied table (worker/jobs, BH-1000 T1).
cat > "$T/fakebin/curl" <<'CURL'
#!/bin/bash
case "${CURL_MODE:-schema}" in
  schema)   printf '{"error":"hub_lease schema not applied","detail":"D1_ERROR: no such table: hub_lease"}\n503' ;;
  bodiless) printf '\n500' ;;
  down)     exit 7 ;;
  notfound) printf '{}\n404' ;;
  ok)       printf '{"lease":{"holder":"box-hub","epoch":4,"expired":false,"expires_at":"2001-09-09T02:46:40Z","updated_at":"2001-09-09T01:46:10Z"}}\n200' ;;
  expired)  printf '{"lease":{"holder":"box-hub","epoch":4,"expired":true,"expires_at":"2001-09-09T00:46:40Z","updated_at":"2001-09-09T00:46:10Z"}}\n200' ;;
esac
exit 0
CURL
chmod +x "$T/fakebin/curl"

# The alert path, recorded rather than sent. It also writes the ALERTS line, the
# way the real one does, so "did it page" and "is the line in the log" are two
# separate assertions and a fake that only records cannot satisfy both.
install_lane_alert() {
  cat > "$T/bin/lane-alert.sh" <<'LA'
#!/bin/bash
printf '%s\n' "$*" >> "$LANE_ALERT_SINK"
echo "fake-lane-alert $*" >> "${HARNESS:-/root/harness}/logs/ALERTS.log"
exit 0
LA
  chmod +x "$T/bin/lane-alert.sh"
}
install_lane_alert

run_check() { # run_check <curl-mode> <now-offset> [extra env assignments...]
  local mode="$1" off="$2"
  shift 2
  env PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
      JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 CURL_MODE="$mode" \
      LANE_ALERT_SINK="$CALLS" HUB_LEASE_HOLDER="${HOLDER:-box-hub}" \
      HUB_LEASE_NOW=$(( PINNED_NOW + off )) "$@" \
      bash "$DIR/bin/hub-lease.sh" check >/dev/null 2>&1
  echo $?
}
run_renew() { # run_renew <curl-mode> [now-offset]
  env PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
      JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 CURL_MODE="$1" \
      LANE_ALERT_SINK="$CALLS" HUB_LEASE_HOLDER=box-hub \
      HUB_LEASE_NOW=$(( PINNED_NOW + ${2:-0} )) \
      bash "$DIR/bin/hub-lease.sh" renew >/dev/null 2>&1
  echo $?
}
calls()      { if [ -f "$CALLS" ]; then wc -l < "$CALLS" | tr -d ' '; else echo 0; fi; }
since_val()  { cat "$SINCE" 2>/dev/null || echo ABSENT; }
flag_val()   { cat "$FLAG" 2>/dev/null || echo ABSENT; }
setup() {
  rm -f "$T/state/hub-lease.json" "$FLAG" "$SINCE" "$CALLS" \
        "$T/logs/ALERTS.log" "$T/logs/hub-lease.log" "$T/logs/jobs-client.log"
  # The jobs-client daily-alert flag is burned deliberately: its once-a-day line
  # is a different condition, and leaving it unburned would let one suite's
  # ordering decide another suite's ALERTS count.
  mkdir -p "$T/flags"; touch "$T/flags/alerted-jobs-client-$(date -u +%Y%m%d)"
  install_lane_alert
}
cache() { # cache <held> <fetched-at-offset>
  local held="$1" off="$2" fa
  fa=$(( PINNED_NOW + off ))
  jq -nc --argjson held "$held" --argjson fa "$fa" \
    '{holder:"box-hub", epoch:4, expired:false,
      expires_at:"2001-09-09T02:46:40Z", updated_at:"2001-09-09T01:46:10Z",
      as_of:"2001-09-09T01:46:40Z", held:$held, fetched_at:$fa}' > "$T/state/hub-lease.json"
}

# ─────────────────────────────────────────────────────────────────────────────
# R1 — renew logs the worker's REASON, not "unreachable" (item 1, 2nd clause)
# ─────────────────────────────────────────────────────────────────────────────
setup
RC=$(run_renew schema)
[ "$RC" = 1 ] && ok || bad "R1: renew on a 503 must still exit 1 (got: $RC)"
grep -q 'hub_lease schema not applied' "$T/logs/hub-lease.log" \
  && ok || bad "R1: hub-lease.log must carry the worker's reason verbatim (got: $(cat "$T/logs/hub-lease.log" 2>/dev/null))"
grep -q 'http=503' "$T/logs/hub-lease.log" \
  && ok || bad "R1: hub-lease.log must name the status (got: $(cat "$T/logs/hub-lease.log" 2>/dev/null))"
grep -q 'unreachable' "$T/logs/hub-lease.log" \
  && bad "R1: a 503 with a reason must NOT be logged as unreachable" || ok

# ─────────────────────────────────────────────────────────────────────────────
# A — THE INCIDENT SHAPE: no cache, worker 503, configured hub
# ─────────────────────────────────────────────────────────────────────────────
setup
RC=$(run_check schema 0)
[ "$RC" = 0 ] && ok || bad "A: the configured hub must FAIL OPEN on a worker error with no cache (got: $RC)"
[ "$(since_val)" = "$PINNED_NOW" ] && ok || bad "A: failing-since must start at now (got: $(since_val))"
[ "$(calls)" = 0 ] && ok || bad "A: a 0-second outage must not page (got: $(calls) call(s))"

RC=$(run_check schema 700)
[ "$RC" = 0 ] && ok || bad "A: still fail-open at +700s (got: $RC)"
[ "$(calls)" = 1 ] && ok || bad "A: a 700s outage must page exactly once (got: $(calls))"
grep -q -- '--critical' "$CALLS" && ok || bad "A: the page must be --critical (got: $(cat "$CALLS"))"
grep -q -- '--id hub-lease-check-failing' "$CALLS" \
  && ok || bad "A: the page must carry its condition id (got: $(cat "$CALLS"))"
grep -q 'FAIL-OPEN' "$CALLS" && ok || bad "A: the page must say the lanes are running fail-open (got: $(cat "$CALLS"))"
grep -q 'hub_lease schema not applied' "$CALLS" \
  && ok || bad "A: the page must carry the worker's reason (got: $(cat "$CALLS"))"
[ "$(flag_val)" = "$(( PINNED_NOW + 700 ))" ] && ok || bad "A: the flag must record WHEN it paged (got: $(flag_val))"
[ "$(since_val)" = "$PINNED_NOW" ] && ok || bad "A: failing-since must not move during an outage (got: $(since_val))"

RC=$(run_check schema 800)
[ "$RC" = 0 ] && ok || bad "A: still fail-open at +800s (got: $RC)"
[ "$(calls)" = 1 ] && ok || bad "A: a second page inside the same hour is noise (got: $(calls))"

RC=$(run_check schema 4400)
[ "$(calls)" = 2 ] && ok || bad "A: one loud line PER HOUR, so +4400s pages again (got: $(calls))"

# ─────────────────────────────────────────────────────────────────────────────
# B — cache held=1, fetched 700s ago: grace is already spent, so page at once
# ─────────────────────────────────────────────────────────────────────────────
setup; cache 1 -700
RC=$(run_check schema 0)
[ "$RC" = 0 ] && ok || bad "B: past grace, the configured hub fails open (got: $RC)"
[ "$(since_val)" = "$(( PINNED_NOW - 700 ))" ] \
  && ok || bad "B: failing-since must back-date to the cache's fetched_at, or the page is 10 min late (got: $(since_val))"
[ "$(calls)" = 1 ] && ok || bad "B: an outage already 700s old pages on the FIRST check (got: $(calls))"

# Inside grace it is not an outage yet: today's behaviour, no page, no marker.
setup; cache 1 -300
RC=$(run_check schema 0)
[ "$RC" = 0 ] && ok || bad "B: inside grace must still exit 0 (got: $RC)"
[ "$(calls)" = 0 ] && ok || bad "B: inside grace must not page (got: $(calls))"
[ "$(since_val)" = ABSENT ] && ok || bad "B: inside grace must not start an outage clock (got: $(since_val))"

# ─────────────────────────────────────────────────────────────────────────────
# C — a cache that names ANOTHER holder never fails open (split-brain guard)
# ─────────────────────────────────────────────────────────────────────────────
setup; cache 0 -700
RC=$(run_check schema 0)
[ "$RC" = 1 ] && ok || bad "C: held=0 must stay fail-CLOSED — another box may be the hub (got: $RC)"
[ "$(calls)" = 0 ] && ok || bad "C: held=0 must not page the fail-open alert (got: $(calls))"
grep -q 'grace exhausted' "$T/logs/ALERTS.log" \
  && ok || bad "C: held=0 keeps today's once-per-outage warn line (got: $(cat "$T/logs/ALERTS.log" 2>/dev/null))"

# ─────────────────────────────────────────────────────────────────────────────
# D — 404 is an ANSWER ("worker not deployed"), never an outage
# ─────────────────────────────────────────────────────────────────────────────
setup
RC=$(run_check notfound 0)
[ "$RC" = 1 ] && ok || bad "D: a 404 must stay fail-closed (got: $RC)"
[ "$(calls)" = 0 ] && ok || bad "D: a 404 must not page (got: $(calls))"
[ "$(since_val)" = ABSENT ] && ok || bad "D: a 404 must not start an outage clock (got: $(since_val))"

# ─────────────────────────────────────────────────────────────────────────────
# E — a box that is NOT the configured hub never fails open
# ─────────────────────────────────────────────────────────────────────────────
setup
RC=$(HOLDER=box-small run_check schema 700 HUB_BOX_NAME=box-hub)
[ "$RC" = 1 ] && ok || bad "E: a non-hub box must stay fail-closed (got: $RC)"
[ "$(calls)" = 0 ] && ok || bad "E: a non-hub box must not page (got: $(calls))"

# ...and the comparison is against the CONFIGURED hub name, not a hardcoded one.
setup
RC=$(run_check schema 700 HUB_BOX_NAME=box-other)
[ "$RC" = 1 ] && ok || bad "E: HUB_BOX_NAME decides who the hub is (got: $RC)"
[ "$(calls)" = 0 ] && ok || bad "E: a box the config does not call the hub must not page (got: $(calls))"

# ─────────────────────────────────────────────────────────────────────────────
# F — the knob turns it off
# ─────────────────────────────────────────────────────────────────────────────
setup
RC=$(run_check schema 700 HUB_LEASE_FAIL_OPEN=0)
[ "$RC" = 1 ] && ok || bad "F: HUB_LEASE_FAIL_OPEN=0 restores fail-closed (got: $RC)"

# ─────────────────────────────────────────────────────────────────────────────
# G — a 2xx is an ANSWER: an expired lease is "you are not the hub", not an outage
# ─────────────────────────────────────────────────────────────────────────────
setup
RC=$(run_check expired 0)
[ "$RC" = 1 ] && ok || bad "G: an expired lease must exit 1 (got: $RC)"
[ "$(calls)" = 0 ] && ok || bad "G: an answered request must not page (got: $(calls))"
[ "$(since_val)" = ABSENT ] && ok || bad "G: a 200 must not start an outage clock (got: $(since_val))"

# ─────────────────────────────────────────────────────────────────────────────
# H — recovery resolves the page exactly once and clears the outage clock
# ─────────────────────────────────────────────────────────────────────────────
setup
run_check schema 0    >/dev/null
run_check schema 700  >/dev/null   # pages
[ "$(calls)" = 1 ] && ok || bad "H: precondition — one page before recovery (got: $(calls))"
RC=$(run_check ok 900)
[ "$RC" = 0 ] && ok || bad "H: recovery must exit 0 (got: $RC)"
[ "$(since_val)" = ABSENT ] && ok || bad "H: recovery must clear failing-since (got: $(since_val))"
[ "$(flag_val)" = ABSENT ] && ok || bad "H: recovery must clear the page flag (got: $(flag_val))"
[ "$(calls)" = 2 ] && ok || bad "H: recovery must send exactly one more call (got: $(calls))"
tail -1 "$CALLS" | grep -q -- '--resolve' && ok || bad "H: the last call must be a --resolve (got: $(tail -1 "$CALLS"))"
tail -1 "$CALLS" | grep -q -- '--id hub-lease-check-failing' \
  && ok || bad "H: the resolve must close the SAME id it opened (got: $(tail -1 "$CALLS"))"

# A recovery with no page sent resolves nothing — retracting something nobody
# was told about is noise with a minus sign.
setup
run_check schema 0 >/dev/null
RC=$(run_check ok 60)
[ "$RC" = 0 ] && ok || bad "H: recovery without a page must exit 0 (got: $RC)"
[ "$(calls)" = 0 ] && ok || bad "H: recovery without a page must call nothing (got: $(calls))"
[ "$(since_val)" = ABSENT ] && ok || bad "H: recovery clears the clock either way (got: $(since_val))"

# ─────────────────────────────────────────────────────────────────────────────
# I — no lane-alert.sh on the box: the line still lands in ALERTS.log
# ─────────────────────────────────────────────────────────────────────────────
setup
rm -f "$T/bin/lane-alert.sh"
RC=$(run_check schema 0);   [ "$RC" = 0 ] && ok || bad "I: fail-open does not need lane-alert.sh (got: $RC)"
RC=$(run_check schema 700); [ "$RC" = 0 ] && ok || bad "I: still fail-open at +700s (got: $RC)"
N=$(grep -c 'FAIL-OPEN' "$T/logs/ALERTS.log" 2>/dev/null || echo 0)
[ "$N" = 1 ] && ok || bad "I: exactly one direct ALERTS line (got: $N)"
grep -q 'hub-lease' "$T/logs/ALERTS.log" && ok || bad "I: the direct line must name the lane"
RC=$(run_check schema 800); [ "$RC" = 0 ] && ok || bad "I: still fail-open at +800s (got: $RC)"
N=$(grep -c 'FAIL-OPEN' "$T/logs/ALERTS.log" 2>/dev/null || echo 0)
[ "$N" = 1 ] && ok || bad "I: the hourly cadence holds without lane-alert.sh too (got: $N)"
install_lane_alert

# ─────────────────────────────────────────────────────────────────────────────
# J — a BODILESS 500 (what Cloudflare actually sent during the incident) is
#     still an outage, and the page says so without inventing a reason.
# ─────────────────────────────────────────────────────────────────────────────
setup
run_check bodiless 0 >/dev/null
RC=$(run_check bodiless 700)
[ "$RC" = 0 ] && ok || bad "J: a bodiless 500 must fail open too (got: $RC)"
[ "$(calls)" = 1 ] && ok || bad "J: a bodiless 500 must page (got: $(calls))"
grep -q 'http=500' "$CALLS" && ok || bad "J: the page must name the status it saw (got: $(cat "$CALLS"))"

# ─────────────────────────────────────────────────────────────────────────────
# K — a TRANSPORT failure (worker genuinely unreachable) fails open the same way
# ─────────────────────────────────────────────────────────────────────────────
setup
run_check down 0 >/dev/null
RC=$(run_check down 700)
[ "$RC" = 0 ] && ok || bad "K: a transport outage on the configured hub fails open (got: $RC)"
[ "$(calls)" = 1 ] && ok || bad "K: a transport outage pages once past the threshold (got: $(calls))"
grep -q 'http=transport' "$CALLS" \
  && ok || bad "K: with no HTTP answer the page must say so, not print a blank (got: $(cat "$CALLS"))"

# ─────────────────────────────────────────────────────────────────────────────
# L — a fresh cache still short-circuits: no network, no clock, no page
# ─────────────────────────────────────────────────────────────────────────────
setup; cache 1 -10
RC=$(run_check schema 0)
[ "$RC" = 0 ] && ok || bad "L: a fresh held cache exits 0 without asking (got: $RC)"
[ "$(since_val)" = ABSENT ] && ok || bad "L: a cached answer is not an outage (got: $(since_val))"
[ "$(calls)" = 0 ] && ok || bad "L: a cached answer must not page (got: $(calls))"

# ─────────────────────────────────────────────────────────────────────────────
# M — an EMPTY flag left by an older fail-closed outage reads as "never paged",
#     never as "already paged" (D11: absent is not approved).
# ─────────────────────────────────────────────────────────────────────────────
setup
: > "$FLAG"
run_check schema 0 >/dev/null
RC=$(run_check schema 700)
[ "$RC" = 0 ] && ok || bad "M: an empty flag must not change the exit code (got: $RC)"
[ "$(calls)" = 1 ] && ok || bad "M: an empty flag must page at the threshold (got: $(calls))"

# ─────────────────────────────────────────────────────────────────────────────
# N — THE STATE DIR IS UNWRITABLE. `_req_capture` cannot park the response in a
#     file and falls back to a command substitution; the worker's VERDICT must
#     survive that fallback even though its reason cannot.
#
#     WHY THIS IS THE INCIDENT AGAIN (BH-1000 fix round 1). The fallback used to
#     end `printf -v "$__out" '%s' "$(_jobs_req ...)"; return $?` — and `$?`
#     there is PRINTF's status, which is 0 whatever the worker said. A 503 came
#     back as "rc 0, empty body", `check` parsed the empty body as a lease held
#     by nobody, and exited 1 on every one of the 52 gated hub lanes with no
#     `failing-since`, no `--critical` page and no log line: exactly the silent
#     half-hour this ticket exists to remove, just with a full /root/harness
#     partition as the trigger instead of a missing table.
#
#     mktemp is shadowed for the state/ templates only — jobs-client's own body
#     file in $TMPDIR keeps working, so the worker really answers 503 here.
# ─────────────────────────────────────────────────────────────────────────────
MKTEMP_REAL=$(command -v mktemp)
no_state_mktemp() {   # make ONLY $HARNESS/state/.hub-lease* templates fail
  cat > "$T/fakebin/mktemp" <<MK
#!/bin/bash
for a in "\$@"; do case "\$a" in */state/.hub-lease*) exit 1 ;; esac; done
exec $MKTEMP_REAL "\$@"
MK
  chmod +x "$T/fakebin/mktemp"
}
state_mktemp_back() { rm -f "$T/fakebin/mktemp"; }

setup
no_state_mktemp
RC=$(run_check schema 0)
[ "$RC" = 0 ] \
  && ok || bad "N: a 503 with an unwritable state/ must still fail open on the configured hub, not exit $RC — printf's rc is not the worker's"
[ ! -f "$T/state/hub-lease.json" ] \
  && ok || bad "N: an empty fallback body must never be written to the cache as a lease (got: $(cat "$T/state/hub-lease.json" 2>/dev/null))"
RC=$(run_check schema 700)
[ "$RC" = 0 ] && ok || bad "N: still fail-open at +700s with state/ unwritable (got: $RC)"
[ "$(calls)" = 1 ] \
  && ok || bad "N: the outage must still page at the threshold when the response file cannot be written (got: $(calls))"
# The verdict survives; the reason does not, and the page says "transport"
# rather than inventing one.
grep -q 'http=transport' "$CALLS" 2>/dev/null \
  && ok || bad "N: the fallback loses JOBS_HTTP, so the page must say transport, not a blank (got: $(cat "$CALLS" 2>/dev/null))"

# N2 — renew under the same condition still reports a FAILED request
setup
no_state_mktemp
RC=$(run_renew schema)
[ "$RC" = 1 ] && ok || bad "N2: renew on a 503 must exit 1 with state/ unwritable too (got: $RC)"
grep -q 'renew: _jobs_req rc=' "$T/logs/hub-lease.log" 2>/dev/null \
  && ok || bad "N2: renew must take the failure branch and log it, not parse an empty body as an answer (got: $(cat "$T/logs/hub-lease.log" 2>/dev/null))"
[ ! -f "$T/state/hub-lease.json" ] \
  && ok || bad "N2: a failed renew must not write a cache (got: $(cat "$T/state/hub-lease.json" 2>/dev/null))"
state_mktemp_back

# N3 — with state/ writable again the normal path is unchanged (the shadow is
#      gone, so a green N3 is also the proof that N/N2 measured the fallback)
setup
RC=$(run_check ok 0)
[ "$RC" = 0 ] && ok || bad "N3: the normal path still answers from the worker (got: $RC)"
[ -f "$T/state/hub-lease.json" ] && ok || bad "N3: the normal path still writes the cache"

# ─────────────────────────────────────────────────────────────────────────────
# O — A CORRUPT OUTAGE CLOCK MUST STILL PAGE. `state/hub-lease-failing-since`
#     can exist and be unreadable as a number: a full partition lets the
#     `printf '%s' "$since" > "$SINCE"` of the tick that STARTED the outage
#     allocate an empty inode and write nothing, and a half-written file is the
#     same shape. `_num` turns that into 0, the guard re-seats `since` to NOW —
#     and if that re-seat lives only in memory, every later tick re-seats it to
#     ITS own now, elapsed is 0 forever, and `_page` returns at the threshold
#     check. The box then runs fail-open with the lanes up and NOTHING pages:
#     the loud half of item 2 fails exactly when the box is already degraded.
#     So the repaired value is PERSISTED, and the next tick past the threshold
#     pages off it.
# ─────────────────────────────────────────────────────────────────────────────
setup
: > "$SINCE"                      # empty: the file exists, the number does not
RC=$(run_check schema 0)
[ "$RC" = 0 ] && ok || bad "O: an empty failing-since must not change the fail-open exit code (got: $RC)"
[ "$(since_val)" = "$PINNED_NOW" ] \
  && ok || bad "O: an empty failing-since must be REPAIRED on disk, not just in memory (got: $(since_val))"
RC=$(run_check schema 700)
[ "$RC" = 0 ] && ok || bad "O: still fail-open at +700s after the repair (got: $RC)"
[ "$(calls)" = 1 ] \
  && ok || bad "O: an outage that started with an empty failing-since must still page at the threshold (got: $(calls))"

# O2 — the same for a file that holds something that is not a number at all.
#      Nothing repairs itself by being re-read, so this must page too.
setup
printf 'abc' > "$SINCE"
run_check schema 0 >/dev/null
[ "$(since_val)" = "$PINNED_NOW" ] \
  && ok || bad "O2: a non-numeric failing-since must be repaired on disk (got: $(since_val))"
RC=$(run_check schema 7200)
[ "$RC" = 0 ] && ok || bad "O2: fail-open is unchanged by a corrupt clock (got: $RC)"
[ "$(calls)" = 1 ] \
  && ok || bad "O2: a non-numeric failing-since must not silence the page (got: $(calls))"

# O3 — a GOOD clock is never overwritten: the repair may only touch a value
#      that could not be read, or every tick would reset the outage to zero.
setup
printf '%s' "$(( PINNED_NOW - 3600 ))" > "$SINCE"
RC=$(run_check schema 0)
[ "$RC" = 0 ] && ok || bad "O3: a readable clock still fails open (got: $RC)"
[ "$(since_val)" = "$(( PINNED_NOW - 3600 ))" ] \
  && ok || bad "O3: a readable failing-since must be left exactly as it was (got: $(since_val))"
[ "$(calls)" = 1 ] \
  && ok || bad "O3: an hour-old clock pages on the FIRST tick, off its own value (got: $(calls))"

# ─────────────────────────────────────────────────────────────────────────────
# P — THE SELF-FENCE (BH-1922). The watchdog promotes through the jobs worker
#     from Cloudflare's side, so it can demote a hub that is partitioned from
#     that worker. With HUB_LEASE_FENCE_S set, fail-open ends at the fence: after
#     a promote the old hub's `check` exits non-zero before the watchdog's lease
#     window (default 10 min) lets the new holder's first lane run.
# ─────────────────────────────────────────────────────────────────────────────
FENCED="$T/flags/alerted-hub-lease-fenced"
setup; rm -f "$FENCED"; cache 1 -60     # last answered renew 60 s ago, then the partition
RC=$(run_check down 0 HUB_LEASE_FENCE_S=480)
[ "$RC" = 0 ] && ok || bad "P: inside the fence the hub keeps its grace (got: $RC)"
RC=$(run_check down 419 HUB_LEASE_FENCE_S=480)
[ "$RC" = 0 ] && ok || bad "P: 479 s unreachable is still inside a 480 s fence (got: $RC)"
RC=$(run_check down 420 HUB_LEASE_FENCE_S=480)
[ "$RC" = 1 ] && ok || bad "P: 480 s unreachable must FENCE — the grace (600 s) is capped at the fence (got: $RC)"
grep -q -- '--id hub-lease-fenced' "$CALLS" 2>/dev/null \
  && ok || bad "P: the fence must page its own condition id (got: $(cat "$CALLS" 2>/dev/null))"
grep -q 'SELF-FENCED' "$CALLS" 2>/dev/null && ok || bad "P: the page must say the lanes stopped (got: $(cat "$CALLS" 2>/dev/null))"
# The watchdog promotes at the earliest 10 min after the last renew (+540 s here).
RC=$(run_check down 540 HUB_LEASE_FENCE_S=480)
[ "$RC" = 1 ] && ok || bad "P: at the watchdog's earliest promote the old hub must already be fenced (got: $RC)"
RC=$(run_check down 7200 HUB_LEASE_FENCE_S=480)
[ "$RC" = 1 ] && ok || bad "P: the fence holds for as long as the partition lasts (got: $RC)"
[ "$(grep -c -- '--id hub-lease-fenced' "$CALLS")" = 1 ] \
  && ok || bad "P: one fence page per outage (got: $(grep -c -- '--id hub-lease-fenced' "$CALLS"))"
grep -q 'FAIL-OPEN' "$CALLS" && bad "P: a fenced hub must never page that it is running fail-open" || ok

# P2 — the worker answers again: the fence page resolves and the hub is back.
RC=$(run_check ok 7260 HUB_LEASE_FENCE_S=480)
[ "$RC" = 0 ] && ok || bad "P2: an answered check lifts the fence (got: $RC)"
[ ! -f "$FENCED" ] && ok || bad "P2: recovery must clear the fence flag"
tail -1 "$CALLS" | grep -q -- '--resolve --id hub-lease-fenced' \
  && ok || bad "P2: recovery must resolve the fence page (got: $(tail -1 "$CALLS"))"

# P3 — no cache at all (the BH-1000 incident shape) fences too, off its own clock.
setup; rm -f "$FENCED"
RC=$(run_check schema 0 HUB_LEASE_FENCE_S=480);   [ "$RC" = 0 ] && ok || bad "P3: fail-open at +0 (got: $RC)"
RC=$(run_check schema 480 HUB_LEASE_FENCE_S=480); [ "$RC" = 1 ] && ok || bad "P3: fenced at +480 with no cache (got: $RC)"

# P4 — the fence can come from the env file a cron lane never sources.
setup; rm -f "$FENCED"; cache 1 -60
mkdir -p "$T/env"; printf 'export HUB_LEASE_FENCE_S=480 # BH-1922\n' > "$T/env/global.env"
RC=$(run_check down 420)
[ "$RC" = 1 ] && ok || bad "P4: HUB_LEASE_FENCE_S in global.env must fence (got: $RC)"
rm -f "$T/env/global.env"

# P5 — unset, 0 or junk = no fence: BH-1000 unchanged.
for v in "" 0 abc; do
  setup; rm -f "$FENCED"; cache 1 -60
  RC=$(run_check down 7200 HUB_LEASE_FENCE_S="$v")
  [ "$RC" = 0 ] && ok || bad "P5: HUB_LEASE_FENCE_S='$v' must leave fail-open as it is (got: $RC)"
done

echo "hub-lease.bh-1000-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
