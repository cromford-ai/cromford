#!/bin/bash
# tests/watchdog-url-side-lanes.bh-3322-test.sh — BH-3322 (slice 2 of BH-2091):
# fleet-status-push, cost-rollup, progress-push and state-restore --standby no
# longer default to the fleet watchdog host. Each resolves WATCHDOG_URL through
# bin/lib/watchdog-url.sh; unset skips ONLY the watchdog call and every other
# step of the lane still runs. Each lane is driven through its REAL script with
# a fake curl that records its argv and never touches the network.
#
#   F-unset/F-set  fleet-status-push: unset = no /api/status POST, no standby
#                  GET, the console beat still sent with standby_error
#                  "unconfigured", one watchdog-url.log line after two runs;
#                  set = both calls go to WATCHDOG_URL
#   C-unset/C-set  cost-rollup: unset = no cost-snapshot call, a "not set" line,
#                  no FAILED line, no alert flag, no ALERTS line; set = the call
#                  goes to WATCHDOG_URL
#   P-unset/P-set  progress-push: unset = no /api/progress POST, the tick line
#                  still logged and says watchdog=skipped; set = POST to it
#   S-unset/S-set  state-restore --standby: unset = the skip line, no report,
#                  the heartbeat still runs; set = report to it
#   H              the fleet watchdog host is in none of the four scripts or
#                  the three lane JSONs
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/watchdog-url-side-lanes.bh-3322-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

WD=http://watchdog.invalid
# The fake curl: full argv (one line per call) to $CURL_LOG; the standby list
# is [], anything else {}; a --data-binary @- body is drained from stdin.
mkdir -p "$T/fakebin"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$CURL_LOG"
case "$*" in *"@-"*) cat >/dev/null ;; esac
case "$*" in */api/standby*) printf '[]' ;; *) printf '{}' ;; esac
exit 0
SH
chmod +x "$T/fakebin/curl"
has() { grep -qF -- "$2" "$1" 2>/dev/null; }

# ── F: fleet-status-push ─────────────────────────────────────────────────────
fsetup() { # fsetup <name> [global.env extra line]
  F="$T/$1"
  mkdir -p "$F/bin/lib" "$F/logs" "$F/state" "$F/flags" "$F/env" "$F/builds"
  cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$DIR/bin/alert_family.py" "$F/bin/"
  cp "$DIR/bin/lib/watchdog-url.sh" "$F/bin/lib/"
  { printf 'HARNESS_SECRET=test-secret\nWATCHDOG_SECRET=fixture-watchdog-secret\n'; [ -n "${2:-}" ] && printf '%s\n' "$2"; } > "$F/env/global.env"
  printf '#!/bin/bash\nprintf %%s "$1" > %s/BEAT.json\n' "$F" > "$F/bin/beat.sh"; chmod +x "$F/bin/beat.sh"
  printf 'alpha-os Org/alpha https://a.example /api/board 2 box-alpha\n' > "$F/fleet.conf"
  : > "$F/curl.log"
}
frun() {
  rm -f "$F/BEAT.json"
  env -u WATCHDOG_URL PATH="$T/fakebin:$PATH" CURL_LOG="$F/curl.log" HARNESS="$F" FLEET_CONF="$F/fleet.conf" \
    LANE_GATE_DISABLE=1 bash "$DIR/bin/fleet-status-push.sh" </dev/null >/dev/null 2>&1
}

fsetup f-unset
frun; frun
has "$F/curl.log" /api/status && bad "F-unset: no /api/status POST without WATCHDOG_URL (got: $(grep api/status "$F/curl.log"))" || ok
has "$F/curl.log" '-X POST' && bad "F-unset: no snapshot POST at all without WATCHDOG_URL (got: $(grep -F -- '-X POST' "$F/curl.log"))" || ok
has "$F/curl.log" /api/standby && bad "F-unset: no standby GET without WATCHDOG_URL (got: $(grep api/standby "$F/curl.log"))" || ok
[ -s "$F/BEAT.json" ] && ok || bad "F-unset: the console beat must still be sent"
[ "$(jq -r '.standby_error' "$F/BEAT.json" 2>/dev/null)" = unconfigured ] \
  && ok || bad "F-unset: standby_error must be unconfigured (got: $(jq -c '[.standby,.standby_error]' "$F/BEAT.json" 2>/dev/null))"
[ "$(jq -r '.standby' "$F/BEAT.json" 2>/dev/null)" = null ] && ok || bad "F-unset: standby must be null, never []"
[ "$(grep -c '\[fleet-status-push\]' "$F/logs/watchdog-url.log" 2>/dev/null)" = 1 ] \
  && ok || bad "F-unset: exactly one watchdog-url.log line after two runs (got: $(cat "$F/logs/watchdog-url.log" 2>/dev/null))"

fsetup f-set "WATCHDOG_URL=$WD"
frun
has "$F/curl.log" "$WD/api/status" && ok || bad "F-set: the status POST goes to WATCHDOG_URL (got: $(cat "$F/curl.log"))"
has "$F/curl.log" "$WD/api/standby" && ok || bad "F-set: the standby GET goes to WATCHDOG_URL (got: $(cat "$F/curl.log"))"
[ "$(jq -r 'has("standby_error")' "$F/BEAT.json" 2>/dev/null)" = false ] && ok || bad "F-set: a good [] list carries no standby_error"

# ── C: cost-rollup ───────────────────────────────────────────────────────────
csetup() { # csetup <name> [global.env extra line]
  C="$T/$1"
  mkdir -p "$C/bin/lib" "$C/logs" "$C/builds" "$C/state/cost" "$C/env" "$C/flags"
  cp "$DIR/bin/cost-rollup.sh" "$C/bin/"
  cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/builds-of-record.sh" "$DIR/bin/lib/cost-rows-read.sh" \
     "$DIR/bin/lib/watchdog-url.sh" "$C/bin/lib/"
  cat > "$C/bin/jobs-client.sh" <<'JC'
job_artifact_feed() { return 0; }
_jobs_req() { case "$2" in /api/metrics/cost-rows*) printf '{"cost_rows":[]}' ;; *) return 1 ;; esac; }
JC
  printf '#!/bin/bash\nexit 1\n' > "$C/bin/fleet-conf.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/logs/ALERTS.log"\n' "$C" > "$C/bin/alert-line.sh"
  chmod +x "$C/bin/fleet-conf.sh" "$C/bin/alert-line.sh"
  printf 'project-1 -\n' > "$C/fleet.conf"
  { [ -n "${2:-}" ] && printf '%s\n' "$2"; } > "$C/env/global.env"
  : > "$C/curl.log"
}
crun() {
  env -u WATCHDOG_URL PATH="$T/fakebin:$PATH" CURL_LOG="$C/curl.log" HARNESS="$C" HARNESS_ENV_DIR="$C/env" \
      COST_ROLLUP_TIMEBOXED=1 LANE_GATE_DISABLE=1 WINDOWS_ONLY=1 STAMP_DRY=1 HARNESS_SECRET=fixture-jobs-secret WATCHDOG_SECRET=fixture-cost-secret \
      bash "$C/bin/cost-rollup.sh" </dev/null > "$C/run.out" 2>&1
}

csetup c-unset
crun
[ -s "$C/state/cost/summary.json" ] && ok || bad "C-unset: the rollup must still write summary.json ($(tail -3 "$C/run.out"))"
has "$C/curl.log" cost-snapshot && bad "C-unset: no cost-snapshot call without WATCHDOG_URL (got: $(grep cost-snapshot "$C/curl.log"))" || ok
has "$C/logs/agent-rules.log" 'WATCHDOG_URL not set, cost snapshot NOT pushed' \
  && ok || bad "C-unset: agent-rules.log must say the snapshot was not pushed (got: $(grep -i snapshot "$C/logs/agent-rules.log" 2>/dev/null))"
has "$C/logs/agent-rules.log" FAILED && bad "C-unset: not configured is not a FAILED push: $(grep FAILED "$C/logs/agent-rules.log")" || ok
ls "$C/flags"/alerted-cost-snapshot-* >/dev/null 2>&1 && bad "C-unset: no cost-snapshot alert flag when not configured" || ok
has "$C/logs/ALERTS.log" cost-snapshot && bad "C-unset: no ALERTS line when not configured: $(cat "$C/logs/ALERTS.log")" || ok

csetup c-set "WATCHDOG_URL=$WD"
crun
has "$C/curl.log" "$WD/api/cost-snapshot" && ok || bad "C-set: the snapshot goes to WATCHDOG_URL (got: $(cat "$C/curl.log"))"
has "$C/logs/agent-rules.log" FAILED && bad "C-set: a 0-rc push is not FAILED" || ok

# ── P: progress-push ─────────────────────────────────────────────────────────
psetup() { # psetup <name> [global.env extra line]
  P="$T/$1"
  mkdir -p "$P/bin/lib" "$P/logs" "$P/state/pool/alpha-os" "$P/flags" "$P/env" "$P/catalog"
  cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$P/bin/"
  cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/watchdog-url.sh" "$P/bin/lib/"
  cp -R "$DIR/bin/lib/jobs" "$P/bin/lib/"
  { printf 'HARNESS_SECRET=test-secret\nWATCHDOG_SECRET=fixture-watchdog-secret\nJOBS_URL=https://jobs-fixture.invalid\n'; [ -n "${2:-}" ] && printf '%s\n' "$2"; } > "$P/env/global.env"
  printf '{"lanes":[{"id":"fleet-slo","scope":"hub"}]}\n' > "$P/catalog/lanes.json"
  printf 'alpha-os Org/alpha https://a.example /api/board 2 box-alpha\n' > "$P/fleet.conf"
  : > "$P/curl.log"
}
prun() {
  env -i PATH="$T/fakebin:$PATH" HOME="$T" CURL_LOG="$P/curl.log" HARNESS="$P" FLEET_CONF="$P/fleet.conf" \
    JOBS_RETRY_SLEEP=0 JOBS_RETRIES=0 LANE_REGISTRY="$P/catalog/lanes.json" LANE_GATE_DISABLE=1 \
    bash "$DIR/bin/progress-push.sh" </dev/null >/dev/null 2>&1
}

psetup p-unset
prun
has "$P/curl.log" /api/progress? && bad "P-unset: no /api/progress POST without WATCHDOG_URL (got: $(grep 'api/progress?' "$P/curl.log"))" || ok
TICK=$(grep 'projects=' "$P/logs/progress-push.log" 2>/dev/null | tail -1)
[ -n "$TICK" ] && ok || bad "P-unset: the lane must still log its tick line (log: $(cat "$P/logs/progress-push.log" 2>/dev/null))"
case "$TICK" in *"watchdog=skipped"*) ok ;; *) bad "P-unset: the tick line must say watchdog=skipped (got: $TICK)" ;; esac
case "$TICK" in *"post failed"*) bad "P-unset: not configured is not a failed post (got: $TICK)" ;; *) ok ;; esac

psetup p-set "WATCHDOG_URL=$WD"
prun
has "$P/curl.log" "$WD/api/progress" && ok || bad "P-set: the POST goes to WATCHDOG_URL (got: $(cat "$P/curl.log"))"

# ── S: state-restore --standby ───────────────────────────────────────────────
# A scratch H whose bin/ holds the real state-restore.sh and stubs for its
# siblings; the fake aws fails the listing, so the run ends early (rc 1) and
# the EXIT trap reports, which is the path this ticket changes.
ssetup() { # ssetup <name> [global.env extra line]
  S="$T/$1"
  mkdir -p "$S/bin/lib" "$S/env" "$S/fakebin" "$S/live/state"
  cp "$DIR/bin/state-restore.sh" "$DIR/bin/restore-merge.sh" "$S/bin/"
  cp "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/watchdog-url.sh" "$S/bin/lib/"
  printf '#!/bin/bash\necho standby-box\n' > "$S/bin/box-name.sh"
  printf '#!/bin/bash\nexit 1\n' > "$S/bin/hub-lease.sh"
  printf '#!/bin/bash\ntouch %s/hb\n' "$S" > "$S/bin/standby-heartbeat.sh"
  printf '#!/bin/bash\nexit 1\n' > "$S/fakebin/aws"
  for b in zstd age; do printf '#!/bin/bash\nexit 0\n' > "$S/fakebin/$b"; done
  chmod +x "$S/bin/"*.sh "$S/fakebin/"*
  { printf 'BACKUP_S3_ENDPOINT=https://s3.test.invalid\nBACKUP_S3_BUCKET=bkt\nBACKUP_S3_ACCESS_KEY_ID=akid\nBACKUP_S3_SECRET_ACCESS_KEY=sak\n'
    [ -n "${2:-}" ] && printf '%s\n' "$2"; } > "$S/env/global.env"
  printf 'wd-secret\n' > "$S/env/.watchdog-secret"
  printf 'key\n' > "$S/age.key"
  : > "$S/curl.log"
}
srun() {
  env -u WATCHDOG_URL -u HARNESS_SECRET PATH="$S/fakebin:$T/fakebin:$PATH" CURL_LOG="$S/curl.log" \
      HARNESS_ROOT="$S" ETC_HARNESS_ENV="$T/no-such-etc" \
      bash "$S/bin/state-restore.sh" hub latest --apply --standby --identity "$S/age.key" --live "$S/live" </dev/null > "$S/rs.out" 2>&1
}

ssetup s-unset
srun
has "$S/rs.out" 'standby report skipped: WATCHDOG_URL not configured' \
  && ok || bad "S-unset: the skip line must be printed (got: $(cat "$S/rs.out"))"
has "$S/curl.log" /api/standby/ && bad "S-unset: no standby report without WATCHDOG_URL (got: $(cat "$S/curl.log"))" || ok
[ -e "$S/hb" ] && ok || bad "S-unset: the standby heartbeat must still run"

ssetup s-set "WATCHDOG_URL=$WD"
srun
has "$S/curl.log" "$WD/api/standby/standby-box" && ok || bad "S-set: the report goes to WATCHDOG_URL (got: $(cat "$S/curl.log"); out: $(cat "$S/rs.out"))"
[ -e "$S/hb" ] && ok || bad "S-set: the standby heartbeat must still run"

# ── H: the host is gone from the four scripts and three lane JSONs ───────────
h='harness-watchdog.'"operator"'.workers.dev'
HITS=$(cd "$DIR" && grep -lF "$h" bin/fleet-status-push.sh bin/cost-rollup.sh bin/progress-push.sh bin/state-restore.sh \
  catalog/lanes.d/fleet-status-push.json catalog/lanes.d/cost-rollup.json catalog/lanes.d/progress-push.json)
[ -z "$HITS" ] && ok || bad "H: the fleet watchdog host is still in: $HITS"

echo "watchdog-url-side-lanes: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
