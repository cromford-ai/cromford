#!/bin/bash
# tests/box-ops-orgo-lever.bh-9889-test.sh — BH-9889 (C0): a dead restart lever
# is loud. `bin/box-ops.sh restart <id> --apply` with the Orgo key unset still
# refuses (rc 2, "not configured: <KEYENV> unset"), and now also writes ONE
# warn alert with --id orgo-lever-<KEYENV> and the shared text of
# bin/lib/orgo-lever.sh. Before, the refusal was one stderr line that nobody
# read, and a dark box stayed dark for hours.
#
# Runs the REAL bin/box-ops.sh, bin/lib/box-ops-orgo.sh and bin/lib/orgo-lever.sh
# in a scratch repo root ($R) and a scratch harness root ($H). Stubbed:
# $H/bin/alert-line.sh (records its argv), curl (records any call; Orgo is
# never reached here) and bin/box-name.sh.
#   L1  restart --apply, ORGO_API_KEY unset: rc 2, the stderr refusal, exactly
#       1 alert-line call: --severity warn --id orgo-lever-ORGO_API_KEY and
#       the text 'ORGO_API_KEY is not set'; 0 curl calls; no lock file.
#   L1b the same for an --account whose key_env is unset (resize): the alert
#       names that key_env.
#   L2  the same without --apply: 0 alert-line calls.
#   L3  key set (fixture value): 0 orgo-lever alert calls.
#   L4  two refused calls: 2 calls, the same --id (one ALERTS row by id).
#   L5  orgo_lever_text is the same text for the same inputs, names the host
#       and the key, and orgo_lever_alert returns 0 with no alert-line.
#   L6  no key value reaches any output or alert argv.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

R="$T/repo"; H="$T/h"
mkdir -p "$R/bin" "$R/catalog" "$H/env" "$H/bin" "$T/fakebin"
for s in bin/box-ops.sh bin/lib/box-ops-orgo.sh bin/fleet-conf.sh bin/box-for.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$R" >/dev/null || { echo "FAIL: closure install $s"; exit 1; }
done
: > "$H/env/global.env"
cat > "$R/catalog/orgo-plans.json" <<'EOF'
{"accounts": {"fixture-acct": {"plan": "startup_v2", "key_env": "FIXTURE_ORGO_KEY",
  "limits": {"max_vcpus_per_computer": 4, "ram_tiers_gb": [4, 8, 16, 32]},
  "pool": {"computers": 10, "vcpus": 40, "ram_gb": 64, "disk_gb": null},
  "prices_usd_mo": {"computer": 1, "vcpu": 10, "ram_gb": 4, "disk_gb": null},
  "defaults": {"vcpus": 4, "mem_gb": 8, "disk_gb": null}}}}
EOF
printf '{"box_aliases": {}, "accounts": {}}\n' > "$R/catalog/cost-accounts.json"
printf '#!/bin/bash\necho node-selfbox\n' > "$R/bin/box-name.sh"
printf 'pa acme/pa - - 1 node-oldbox 192.0.2.5\n' > "$R/fleet.conf"
cat > "$H/bin/alert-line.sh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_DIR/alert.calls"
exit 0
EOF
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
echo "curl $*" >> "$STUB_DIR/curl.calls"
printf '%s\n%s' '{}' 500
EOF
chmod +x "$R/bin/box-name.sh" "$H/bin/alert-line.sh" "$T/fakebin/curl"
export STUB_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_BOX_PREFIX=node- \
       ORGO_API_BASE=https://orgo.fixture/api BOX_LAUNCH_POLL_S=1 BOX_LAUNCH_DEADLINE_S=1 \
       JOBS_URL=https://jobs.fixture HARNESS_SECRET=fixture-jobs-secret JOBS_RETRIES=0
KEY=sk-lever-SECRET

reset() {
  local d
  for d in "$T/alert.calls" "$T/curl.calls" "$H/locks" "$H/logs"; do scratch_rm "$d" || exit 1; done
  unset ORGO_API_KEY FIXTURE_ORGO_KEY
}
run() { bash "$R/bin/box-ops.sh" "$@" >"$T/out" 2>"$T/err"; RC=$?; cat "$T/out" "$T/err" >> "$T/all-output"; }
n() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }
ctx() { echo "rc=$RC out=[$(cat "$T/out")] err=[$(cat "$T/err")] alerts=[$(cat "$T/alert.calls" 2>/dev/null)]"; }

# --- L1 restart --apply with no key ------------------------------------------
reset; run restart oldbox --apply
[ "$RC" = 2 ] && ok || bad "L1 rc must stay 2 $(ctx)"
grep -q 'not configured: ORGO_API_KEY unset' "$T/err" && ok || bad "L1 the stderr refusal is unchanged $(ctx)"
[ "$(n "$T/alert.calls")" = 1 ] && ok || bad "L1 exactly 1 alert-line call $(ctx)"
A=$(cat "$T/alert.calls" 2>/dev/null)
case "$A" in "--severity warn --id orgo-lever-ORGO_API_KEY "*) ok ;; *) bad "L1 alert argv starts --severity warn --id orgo-lever-ORGO_API_KEY, got [$A]" ;; esac
grep -q 'ORGO_API_KEY is not set' <<<"$A" && grep -q 'restart lever dead' <<<"$A" && ok || bad "L1 alert text, got [$A]"
[ "$(n "$T/curl.calls")" = 0 ] && ok || bad "L1 0 curl calls $(ctx)"
[ ! -e "$H/locks/box-ops-orgo-oldbox.lock" ] && ok || bad "L1 no lock is taken before the refusal"

# --- L1b an account key_env --------------------------------------------------
reset; run resize oldbox --account fixture-acct --mem-gb 8 --apply
[ "$RC" = 2 ] && grep -q 'not configured: FIXTURE_ORGO_KEY unset' "$T/err" && ok || bad "L1b refusal $(ctx)"
grep -q -- '--id orgo-lever-FIXTURE_ORGO_KEY .*FIXTURE_ORGO_KEY is not set' "$T/alert.calls" 2>/dev/null && [ "$(n "$T/alert.calls")" = 1 ] && ok \
  || bad "L1b one alert naming FIXTURE_ORGO_KEY $(ctx)"

# --- L2 dry run ----------------------------------------------------------------
reset; run restart oldbox
[ "$(n "$T/alert.calls")" = 0 ] && ok || bad "L2 a dry run writes no alert $(ctx)"

# --- L3 key set ----------------------------------------------------------------
reset; export ORGO_API_KEY=$KEY; run restart oldbox --apply
grep -q 'orgo-lever' "$T/alert.calls" 2>/dev/null && bad "L3 key set: no orgo-lever alert $(ctx)" || ok
grep -q 'not configured' "$T/err" && bad "L3 key set: no refusal $(ctx)" || ok
unset ORGO_API_KEY

# --- L4 two refusals, one id -----------------------------------------------------
reset; run restart oldbox --apply; run restart oldbox --apply
[ "$(n "$T/alert.calls")" = 2 ] && ok || bad "L4 2 calls for 2 refusals $(ctx)"
[ "$(grep -o -- '--id [^ ]*' "$T/alert.calls" 2>/dev/null | sort -u)" = "--id orgo-lever-ORGO_API_KEY" ] && ok || bad "L4 one --id for both"

# --- L5 the shared text ----------------------------------------------------------
T1=$(bash -c '. "$1/bin/lib/orgo-lever.sh" || exit 1; HOSTNAME=hubx orgo_lever_text ORGO_API_KEY unset' _ "$DIR")
T2=$(bash -c '. "$1/bin/lib/orgo-lever.sh" || exit 1; HOSTNAME=hubx orgo_lever_text ORGO_API_KEY unset' _ "$DIR")
[ -n "$T1" ] && [ "$T1" = "$T2" ] && ok || bad "L5 same text for same inputs: [$T1] [$T2]"
grep -q 'on hubx' <<<"$T1" && grep -q 'ORGO_API_KEY is not set' <<<"$T1" && grep -q 'bin/box-ops.sh restart' <<<"$T1" && ok || bad "L5 text names host, key and lever: [$T1]"
HARNESS="$T/nowhere" bash -c '. "$1/bin/lib/orgo-lever.sh" || exit 1; orgo_lever_alert ORGO_API_KEY unset' _ "$DIR"
[ $? = 0 ] && ok || bad "L5 orgo_lever_alert returns 0 with no alert-line.sh"

# --- L6 no key value anywhere ----------------------------------------------------
grep -qF "$KEY" "$T/all-output" "$T/alert.calls" 2>/dev/null && bad "L6 the key value reached an output" || ok

echo "box-ops-orgo-lever (BH-9889): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
