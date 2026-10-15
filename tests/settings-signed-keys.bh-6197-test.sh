#!/bin/bash
# BH-6197: lead_protected_paths_extra.* is not a signed key on the client side.
# setting_get answers it from a fresh state/settings-cache.json like any other
# key, while lead_authority.*, risk_tier.* and human_verdict_mode still go to
# the worker. The real bin/jobs-client.sh; only curl is stubbed.
#   C1  extras key in a fresh cache -> the cached value, rc 0, no request
#   C2  controls: lead_authority.x, risk_tier.x, human_verdict_mode -> 1 request each
#   C3  BH-4148's grep finds no extras key or TSV name under bin/ and catalog/
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/settings-signed-keys.bh-6197-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# scratch.sh blanks JOBS_URL; this suite's fake curl answers a worker URL.
export JOBS_URL=https://jobs.invalid
H="$(cd "$(dirname "$0")/.." && pwd)"
"$H/bin/llm-sites-build.sh" --compose --repo "$H" >/dev/null || { echo "FAIL: cannot compose catalog/llm-sites.json"; exit 1; }
mkdir -p "$T/bin" "$T/logs" "$T/state"
cat > "$T/bin/curl" <<'STUB'
#!/bin/bash
n=$(cat "$STUB_STATE" 2>/dev/null || echo 0); echo $((n+1)) > "$STUB_STATE"
printf '{"setting":{"key":"k","value":"net"}}\n200'
exit 0
STUB
chmod +x "$T/bin/curl"
NOW=1800000000
jq -nc --argjson fa "$NOW" '{fetched_at:$fa,
  values:{"lead_protected_paths_extra.x":"cached","lead_authority.x":"cached","risk_tier.x":"cached","human_verdict_mode":"cached"},
  seeded:{}}' > "$T/state/settings-cache.json"
# js <script> — runs <script> with the client sourced; prints "<stdout>|rc=<rc>|calls=<n>".
js() {
  echo 0 > "$T/calls"
  local out rc
  out=$(cd "$T" && PATH="$T/bin:$PATH" STUB_STATE="$T/calls" HARNESS="$T" HARNESS_SECRET=x \
    JOBS_ALERT=0 JOBS_RETRY_SLEEP=0 JOBS_OVERLOAD_SLEEP=0 JOBS_OVERLOAD_JITTER_S=0 LANE_GATE_NOW="$NOW" \
    bash -c 'source "$1"; eval "$2"' bash "$H/bin/jobs-client.sh" "$1" 2>/dev/null); rc=$?
  echo "$out|rc=$rc|calls=$(cat "$T/calls")"
}
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1 -> $3"; else echo "FAIL $1 -> $3 (want $2)"; fail=1; fi; }

check "C1 lead_protected_paths_extra.x answers from the cache" 'cached|rc=0|calls=0' "$(js 'setting_get lead_protected_paths_extra.x')"
check "C2 lead_authority.x goes to the worker" 'net|rc=0|calls=1' "$(js 'setting_get lead_authority.x')"
check "C2 risk_tier.x goes to the worker" 'net|rc=0|calls=1' "$(js 'setting_get risk_tier.x')"
check "C2 human_verdict_mode goes to the worker" 'net|rc=0|calls=1' "$(js 'setting_get human_verdict_mode')"
hits=$(grep -rn 'lead_protected_paths_extra\|lead-protected-paths.tsv' "$H/bin" "$H/catalog"); grc=$?
check "C3 BH-4148 grep under bin/ and catalog/ exits 1" '1' "$grc"
[ -z "$hits" ] || echo "$hits"

[ "$fail" = 0 ] && echo "settings-signed-keys.bh-6197: all passed"
exit "$fail"
