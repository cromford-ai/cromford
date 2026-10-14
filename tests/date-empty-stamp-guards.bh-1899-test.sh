#!/bin/bash
# tests/date-empty-stamp-guards.bh-1899-test.sh — an empty stamp takes each
# site's existing unparseable fallback (BH-1899, slice of BH-1816).
#
# GNU `date -u -d ""` exits 0 with today's 00:00, so `e=$(date -d "$x") || fb`
# never reached its fallback when $x was empty: the empty stamp read as a real
# stamp from midnight. Each production function below is extracted verbatim
# from bin/ and driven with an empty stamp and with a real one.
#   A1  the determinism lint over the 11 guarded/waived files: rc 0, no
#       date-empty-stamp finding, no waiver-no-reason
#   B1  quota-poll json_age_secs: empty or absent polled_at -> 999999999
#   B2  gh-token cache_read: empty expires_at -> rc 1, no token
#   B3  mc_job_running: empty updated_at -> rc 0 "running for 0s"
#   B4  remote-gate _rg_epoch '' -> rc 1, empty stdout
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
fn()  { sed -n "/^$1() {/,/^}/p" "$2"; }

# ── A1 the lint ──────────────────────────────────────────────────────────────
FILES="bin/quota-poll.sh bin/alert-digest.sh bin/alert-triage.sh bin/gh-token.sh
bin/lib/mc/classify.sh bin/main-red-pr-pair.sh bin/remote-gate.sh
bin/backup-records-sync.sh bin/lib/backup-freshness.sh bin/fly-pool.sh
bin/vendor-spend-pull.sh"
# shellcheck disable=SC2086
LINT=$(cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/test-determinism-lint.sh $FILES 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok || bad "A1: lint rc $rc"
if grep -q 'date-empty-stamp' <<<"$LINT"; then
  bad "A1: date-empty-stamp findings remain:"; printf '%s\n' "$LINT" | grep 'date-empty-stamp'
else ok; fi
if grep -q 'waiver-no-reason' <<<"$LINT"; then
  bad "A1: waiver-no-reason:"; printf '%s\n' "$LINT" | grep 'waiver-no-reason'
else ok; fi

# ── B1 json_age_secs ─────────────────────────────────────────────────────────
F=$(fn json_age_secs "$DIR/bin/quota-poll.sh")
[ -n "$F" ] || bad "B1: json_age_secs not found in bin/quota-poll.sh"
QUOTA_DIR="$T/quota"; mkdir -p "$QUOTA_DIR"
eval "$F"
printf '{"polled_at":""}\n' > "$QUOTA_DIR/acct.json"
out=$(json_age_secs acct)
[ "$out" = 999999999 ] && ok || bad "B1: empty polled_at gave '$out', want 999999999"
printf '{}\n' > "$QUOTA_DIR/acct.json"
out=$(json_age_secs acct)
[ "$out" = 999999999 ] && ok || bad "B1: absent polled_at gave '$out', want 999999999"
printf '{"polled_at":"%s"}\n' "$(date -u -d '@'$(( $(date -u +%s) - 120 )) +%Y-%m-%dT%H:%M:%SZ)" > "$QUOTA_DIR/acct.json"
out=$(json_age_secs acct)
case "$out" in ''|*[!0-9]*) bad "B1: real polled_at gave '$out'" ;;
  *) { [ "$out" -ge 110 ] && [ "$out" -le 200 ]; } && ok || bad "B1: real polled_at 120s ago gave $out" ;; esac

# ── B2 cache_read ────────────────────────────────────────────────────────────
F=$(fn cache_read "$DIR/bin/gh-token.sh")
[ -n "$F" ] || bad "B2: cache_read not found in bin/gh-token.sh"
eval "$F"
cache_file() { printf '%s/tok.json' "$T"; }
MIN_LIFE=300
printf '{"token":"ghs_x","expires_at":""}\n' > "$T/tok.json"
out=$(cache_read o/r); rc=$?
{ [ "$rc" -eq 1 ] && [ -z "$out" ]; } && ok || bad "B2: empty expires_at gave rc $rc out '$out'"
printf '{"token":"ghs_x","expires_at":"%s"}\n' "$(date -u -d '+1 hour' +%Y-%m-%dT%H:%M:%SZ)" > "$T/tok.json"
out=$(cache_read o/r); rc=$?
{ [ "$rc" -eq 0 ] && [ "$out" = ghs_x ]; } && ok || bad "B2: expires_at +1h gave rc $rc out '$out'"

# ── B3 mc_job_running ────────────────────────────────────────────────────────
F=$(fn mc_job_running "$DIR/bin/lib/mc/classify.sh")
[ -n "$F" ] || bad "B3: mc_job_running not found in bin/lib/mc/classify.sh"
eval "$F"
type mc_now >/dev/null 2>&1 || mc_now() { date -u +%s; }
JOB_UPD=""
_jobs_req() { printf '{"job_id":"j1","job":{"status":"running","stage":"review","updated_at":"%s"}}\n' "$JOB_UPD"; }
export MC_JOB_WAIT_SECS=60
out=$(mc_job_running https://github.com/o/r/pull/1); rc=$?
{ [ "$rc" -eq 0 ] && case "$out" in *'running for 0s'*) true ;; *) false ;; esac; } \
  && ok || bad "B3: empty updated_at gave rc $rc out '$out', want rc 0 'running for 0s'"
JOB_UPD=$(date -u -d '@'$(( $(date -u +%s) - 7200 )) +%Y-%m-%dT%H:%M:%SZ)
out=$(mc_job_running https://github.com/o/r/pull/1); rc=$?
[ "$rc" -eq 1 ] && ok || bad "B3: updated_at 2h ago with a 60s wait gave rc $rc out '$out', want rc 1"

# ── B4 _rg_epoch ─────────────────────────────────────────────────────────────
F=$(fn _rg_epoch "$DIR/bin/remote-gate.sh")
[ -n "$F" ] || bad "B4: _rg_epoch not found in bin/remote-gate.sh"
out=$(set -u; eval "$F"; _rg_epoch ""); rc=$?
{ [ "$rc" -eq 1 ] && [ -z "$out" ]; } && ok || bad "B4: _rg_epoch '' gave rc $rc out '$out', want rc 1 and no output"
out=$(set -u; eval "$F"; _rg_epoch); rc=$?
{ [ "$rc" -eq 1 ] && [ -z "$out" ]; } && ok || bad "B4: _rg_epoch with no arg gave rc $rc out '$out'"
out=$(set -u; eval "$F"; _rg_epoch 2026-01-02T03:04:05); rc=$?
{ [ "$rc" -eq 0 ] && case "$out" in ''|*[!0-9]*) false ;; *) true ;; esac; } \
  && ok || bad "B4: _rg_epoch 2026-01-02T03:04:05 gave rc $rc out '$out'"

echo "date-empty-stamp-guards.bh-1899: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
