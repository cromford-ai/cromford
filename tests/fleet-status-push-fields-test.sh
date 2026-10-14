#!/bin/bash
# tests/fleet-status-push-fields-test.sh — the six state fields added to the
# fleet-status snapshot on 2026-09-14, driven against a fixture harness with
# curl and beat.sh replaced by capture stubs so nothing leaves the machine.
#
# The question this file answers is not "does the JSON have the keys" but
# "does each field say the true thing, and does an ABSENT source still push":
#   1. lanes_down is TODAY's flags only — yesterday's lanedown flag is history,
#      and a lane that recovered this morning must not read as down;
#   2. a remote-result json whose build dir is stamped RELAYED is NOT pending
#      (custody moved through the ledger; counting it paged 73 keys once), while
#      one with no RELAYED sibling still is;
#   3. a missing quota-status.sh yields quota:null + quota_error:"missing" —
#      a closed vocabulary, never a half-parsed table;
#   4. a missing deferred spool is zeros, not a blank field; one missing spool
#      among others is skipped, and an unreadable one is unknown (-1);
#   5. with EVERY new source absent the payload is still valid JSON and still
#      carries the fields the watchdog already had. The push is the watchdog's
#      layer-2 liveness signal: a helper that is not installed must never cost
#      us the dead-man.
# Run from anywhere: tests/fleet-status-push-fields-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin" "$T/logs" "$T/state" "$T/flags" "$T/env" "$T/builds" "$T/fakebin"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/fleet-fly-block.sh" "$T/bin/"
cp "$DIR/bin/alert_family.py" "$T/bin/"
printf 'HARNESS_SECRET=test-secret\nWATCHDOG_URL=http://watchdog.invalid\n' > "$T/env/global.env"
printf '#!/bin/bash\nprintf %%s "$1" > %s/BEAT.json\n' "$T" > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
printf '#!/bin/bash\ncat > %s/PUSH.json\n' "$T" > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
cat > "$T/fleet.conf" <<'EOF'
alpha-os Org/alpha https://a.example /api/board 2 box-alpha
beta-os  Org/beta  https://b.example /api/board 4 box-beta
EOF

run() { rm -f "$T/PUSH.json" "$T/BEAT.json"; PATH="$T/fakebin:$PATH" HARNESS="$T" FLEET_CONF="$T/fleet.conf" bash "$DIR/bin/fleet-status-push.sh"; }
q()   { jq -r "$1" "$T/PUSH.json" 2>/dev/null; }

TODAY=$(date -u +%Y%m%d)
YDAY=$(date -u -d yesterday +%Y%m%d 2>/dev/null || date -u -v-1d +%Y%m%d)
# LOCAL time, not UTC: `touch -t` reads its stamp in local time, so a UTC one
# lands the fixture in the FUTURE west of Greenwich and the >30m test inverts.
OLDSTAMP=$(date -d '2 hours ago' +%Y%m%d%H%M 2>/dev/null || date -v-2H +%Y%m%d%H%M)

# ─────────────────────────────────────────────────────────────────────────────
# A. every source present
# ─────────────────────────────────────────────────────────────────────────────
# lanedown flags: two lanes down on one box today, one on another box YESTERDAY.
touch "$T/flags/lanedown-box-alpha-codex-$TODAY" \
      "$T/flags/lanedown-box-alpha-grok-$TODAY" \
      "$T/flags/lanedown-box-beta-codex-$YDAY"

# remote-results: one old + unrelayed (pending), one old + RELAYED (not pending),
# one fresh + unrelayed (not pending yet).
mkdir -p "$T/state/remote-results/alpha-os" "$T/state/remote-results/beta-os"
echo '{}' > "$T/state/remote-results/alpha-os/TK-11.json"
echo '{}' > "$T/state/remote-results/alpha-os/TK-22.json"
echo '{}' > "$T/state/remote-results/alpha-os/TK-33.json"
touch -t "$OLDSTAMP" "$T/state/remote-results/alpha-os/TK-11.json" \
                     "$T/state/remote-results/alpha-os/TK-22.json"
mkdir -p "$T/builds/pool-alpha-os-TK-22-abc"; touch "$T/builds/pool-alpha-os-TK-22-abc/RELAYED"

# quota table (the shape bin/quota-status.sh --json emits, trimmed to what the
# snapshot keeps).
cat > "$T/bin/quota-status.sh" <<'SH'
#!/bin/bash
cat <<'JSON'
[{"account":"default","vendor":"claude","label":"","enabled":true,"priority":50,
  "models":"","status":"ok","source":"oauth","polled_at":"2026-09-14T10:00:00Z",
  "five_hour":{"pct":41,"resets_at":"12:00Z"},"seven_day":{"pct":88,"resets_at":"Mon"},
  "per_model":{"opus":{"pct":12}},"error":null,"cooldown_until":null}]
JSON
SH
chmod +x "$T/bin/quota-status.sh"

# deferred spool: 3 lines, 2 families (two lines differ only in digits, which
# bin/alert_family.py folds to one signature). BH-5942: the lane spools per
# project, so the shared spool and a project's spool are both counted.
cat > "$T/state/alert-triage-deferred.tsv" <<'EOF'
hub	{"line":"build stuck for 12 minutes"}
hub	{"line":"build stuck for 47 minutes"}
EOF
mkdir -p "$T/state/alert-triage/projfix-a"
cat > "$T/state/alert-triage/projfix-a/deferred.tsv" <<'EOF'
10.0.0.9	{"line":"merge sweep saw nothing"}
EOF

# jobs-client: safe to source (defines nothing), answers `rules` as TSV.
cat > "$T/bin/jobs-client.sh" <<'SH'
#!/bin/bash
[ "${BASH_SOURCE[0]}" = "$0" ] || return 0
case "${1:-}" in
  rules) printf 'box\tbox-alpha\tbuild\t2\tcap per box\nproject\talpha-os\ttriage\t1\t\n' ;;
  *) exit 2 ;;
esac
SH
chmod +x "$T/bin/jobs-client.sh"

run
jq -e . >/dev/null 2>&1 < "$T/PUSH.json" && ok || bad "a fully-populated fixture must push valid JSON"

# --- lanes_down: today only -------------------------------------------------
[ "$(q '.lanes_down."box-alpha" | sort | join(",")')" = "codex,grok" ] \
  && ok || bad "today's lanedown flags must group by box (got: $(q '.lanes_down|tojson'))"
[ "$(q '.lanes_down | has("box-beta")')" = false ] \
  && ok || bad "YESTERDAY's lanedown flag is history, not state (got: $(q '.lanes_down|tojson'))"

# --- remote_results_pending: RELAYED siblings do not count ------------------
[ "$(q '.remote_results_pending."alpha-os"')" = 1 ] \
  && ok || bad "only the old json with no RELAYED sibling is pending (got: $(q '.remote_results_pending|tojson'))"
[ "$(q '.remote_results_pending."beta-os"')" = 0 ] \
  && ok || bad "a project with no remote results is 0, not absent (got: $(q '.remote_results_pending|tojson'))"

# --- quota: present, trimmed, and keyed the way the MCP reads it ------------
[ "$(q '.quota | length')" = 1 ] && ok || bad "the quota table must be embedded (got: $(q '.quota|tojson'))"
[ "$(q '.quota[0] | [.account,(.five_hour_pct|tostring),(.weekly_pct|tostring),.state] | join(",")')" \
  = "default,41,88,ok" ] && ok || bad "quota rows carry account/5h/weekly/state (got: $(q '.quota[0]|tojson'))"
[ "$(q '.quota[0] | has("per_model")')" = false ] \
  && ok || bad "quota rows are capped to the glanceable fields (got: $(q '.quota[0]|keys|tojson'))"
[ "$(q 'has("quota_error")')" = false ] \
  && ok || bad "a readable quota table must not report an error"

# --- alert_backlog: lines and families -------------------------------------
[ "$(q '.alert_backlog.deferred_lines')" = 3 ] \
  && ok || bad "deferred_lines counts spool lines (got: $(q '.alert_backlog|tojson'))"
[ "$(q '.alert_backlog.deferred_families')" = 2 ] \
  && ok || bad "deferred_families uses alert_family.family() (got: $(q '.alert_backlog|tojson'))"

# --- rules: the 'is the fleet capped' answer -------------------------------
[ "$(q '.rules | length')" = 2 ] && ok || bad "rules come from jobs-client (got: $(q '.rules|tojson'))"
[ "$(q '.rules[0] | [.scope,.selector,.kind,(.max_concurrent|tostring)] | join(",")')" \
  = "box,box-alpha,build,2" ] && ok || bad "a rule row keeps scope/selector/kind/max (got: $(q '.rules[0]|tojson'))"

# --- hub: the nine vitals (5 system + 3 lease + the lease verdict) ---------
[ "$(q '.hub | keys | join(",")')" = "disk_pct,epoch,holder,lease_age_s,lease_alert,load1,mem_total_mb,mem_used_mb,uptime_s" ] \
  && ok || bad "the hub block carries all nine vitals (got: $(q '.hub|tojson'))"

# --- the beat still carries the SAME snapshot ------------------------------
diff <(jq -S 'del(.kind,.rkey)' "$T/BEAT.json") <(jq -S . "$T/PUSH.json") >/dev/null \
  && ok || bad "beat and watchdog push must still carry the same snapshot"

# ─────────────────────────────────────────────────────────────────────────────
# B. a broken quota helper is named, not guessed
# ─────────────────────────────────────────────────────────────────────────────
printf '#!/bin/bash\necho "not json at all"\n' > "$T/bin/quota-status.sh"; chmod +x "$T/bin/quota-status.sh"
run
[ "$(q '.quota')" = null ] && [ "$(q '.quota_error')" = nonjson ] \
  && ok || bad "unparseable quota output must be null + nonjson (got: $(q '.quota|tojson') / $(q '.quota_error'))"

printf '#!/bin/bash\nexit 3\n' > "$T/bin/quota-status.sh"; chmod +x "$T/bin/quota-status.sh"
run
[ "$(q '.quota')" = null ] && [ "$(q '.quota_error')" = failed ] \
  && ok || bad "a failing quota script must be null + failed (got: $(q '.quota_error'))"

# --- alert_backlog: a missing spool is skipped, never zeroes the count -------
# (lead BLOCK at 801b69b7b) With no state/alert-triage/<p>/ dir the glob stays a
# literal path; `cat` of a missing file used to fail the whole count to 0.
mv "$T/state/alert-triage" "$T/alert-triage.aside"
run
[ "$(q '.alert_backlog | [.deferred_lines,.deferred_families] | join(",")')" = "2,1" ] \
  && ok || bad "the shared spool alone, no project dir: 2 lines, 1 family (got: $(q '.alert_backlog|tojson'))"
mv "$T/alert-triage.aside" "$T/state/alert-triage"; mv "$T/state/alert-triage-deferred.tsv" "$T/shared.aside"
run
[ "$(q '.alert_backlog | [.deferred_lines,.deferred_families] | join(",")')" = "1,1" ] \
  && ok || bad "a project spool alone, no shared spool: 1 line, 1 family (got: $(q '.alert_backlog|tojson'))"
# A spool path that cannot be read is unknown (-1), never 0 and never a guess.
mkdir -p "$T/state/alert-triage/projfix-b/deferred.tsv"
run
[ "$(q '.alert_backlog.deferred_lines')" = -1 ] \
  && ok || bad "an unreadable spool is unknown (-1) (got: $(q '.alert_backlog|tojson'))"
rmdir "$T/state/alert-triage/projfix-b/deferred.tsv" "$T/state/alert-triage/projfix-b"; mv "$T/shared.aside" "$T/state/alert-triage-deferred.tsv"

# ─────────────────────────────────────────────────────────────────────────────
# C. every new source absent — the payload must still be valid and pushed
# ─────────────────────────────────────────────────────────────────────────────
rm -rf "$T/bin/quota-status.sh" "$T/bin/jobs-client.sh" "$T/state/alert-triage-deferred.tsv" "$T/state/alert-triage"
rm -rf "$T/state/remote-results" "$T/builds/pool-alpha-os-TK-22-abc"
rm -f "$T/flags/lanedown-"*
run
jq -e . >/dev/null 2>&1 < "$T/PUSH.json" \
  && ok || bad "a payload with EVERY new source absent must still be valid JSON"
[ "$(q '.quota')" = null ] && [ "$(q '.quota_error')" = missing ] \
  && ok || bad "an absent quota-status.sh is quota:null + quota_error:missing (got: $(q '.quota_error'))"
[ "$(q '.alert_backlog | [.deferred_lines,.deferred_families] | join(",")')" = "0,0" ] \
  && ok || bad "an absent deferred spool is zeros (got: $(q '.alert_backlog|tojson'))"
[ "$(q '.lanes_down | length')" = 0 ] \
  && ok || bad "no lanedown flags is an empty object (got: $(q '.lanes_down|tojson'))"
[ "$(q '.rules')" = null ] \
  && ok || bad "an unreachable rules source is null, not an empty cap list (got: $(q '.rules|tojson'))"
[ "$(q '.remote_results_pending | [.[]] | add')" = 0 ] \
  && ok || bad "no remote results is zero per project (got: $(q '.remote_results_pending|tojson'))"
# The fields the watchdog already alerted on survive the additions.
[ "$(q '.projects | keys | join(",")')" = "alpha-os,beta-os" ] \
  && ok || bad "the pre-existing projects block must be untouched"
[ -n "$(q '.pushed_at')" ] && [ "$(q '.pushed_at')" != null ] \
  && ok || bad "the pre-existing pushed_at must be untouched"


# --- hub-lease: absent state file → null fields (F2) ------------------------
[ "$(q '.hub.holder')" = "null" ] && ok || bad "F2: absent hub-lease.json → holder=null (got: $(q '.hub.holder'))"
[ "$(q '.hub.epoch')" = null ] && ok || bad "F2: absent hub-lease.json → epoch=null (got: $(q '.hub.epoch'))"
[ "$(q '.hub.lease_age_s')" = null ] && ok || bad "F2: absent hub-lease.json → lease_age_s=null (got: $(q '.hub.lease_age_s'))"



# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# D. hub-lease fields populated (F1) — state/hub-lease.json present
# ─────────────────────────────────────────────────────────────────────────────
# Place hub-lease cache with updated_at ~45s ago, assert three fields populated.
mkdir -p "$T/state"
F1_UPDATED=$(date -u -d '45 seconds ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
[ -z "$F1_UPDATED" ] && F1_UPDATED=$(date -u -v-45S '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
[ -z "$F1_UPDATED" ] && F1_UPDATED=$(date -u -d @$(( $(date +%s) - 45 )) '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
jq -nc --arg u "$F1_UPDATED" '{
  holder: "box-hub", epoch: 7, expired: false,
  expires_at: "2026-09-16T11:00:00Z", updated_at: $u,
  as_of: $u, held: 1, fetched_at: 0
}' > "$T/state/hub-lease.json"
run
[ "$(q '.hub.holder')" = 'box-hub' ] \
  && ok || bad "F1: holder must be box-hub (got: $(q '.hub.holder'))"
[ "$(q '.hub.epoch')" = 7 ] \
  && ok || bad "F1: epoch must be 7 (got: $(q '.hub.epoch'))"
LA=$(q '.hub.lease_age_s')
[ "$LA" -ge 0 ] && [ "$LA" -le 120 ] 2>/dev/null \
  && ok || bad "F1: lease_age_s ~45, got $LA (tolerance 0-120)"

echo "fleet-status-push-fields-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
