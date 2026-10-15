#!/bin/bash
# BH-5781: setting_get answers from a FRESH state/settings-cache.json (the list
# lane-gate fills once a tick) and sends no request. A stale, future-dated or
# unreadable cache, a signed key, and JOBS_SETTINGS_CACHE_S=0 all go to the
# worker exactly as before. setting_set marks the cache stale after a 2xx only.
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
case "$STUB_PLAN" in
  ok)   printf '{"setting":{"key":"k","value":"net"}}\n200' ;;
  down) printf '{"error":"boom"}\n503' ;;
esac
exit 0
STUB
chmod +x "$T/bin/curl"
NOW=1800000000
C="$T/state/settings-cache.json"
cache() { # cache <fetched_at> — a cache as _lg_settings_refresh writes it
  jq -nc --argjson fa "$1" '{fetched_at:$fa,
    values:{closeout_aged_table:"1","archie.cap.p1":"3","archie.cap.p2":"3","archie.cap.p3":"3","archie.cap.p4":"3","archie.cap.p5":"3",
            "lead_authority.x":"cached","human_verdict_mode":"cached",empty_one:""},
    seeded:{only_seeded:"7"}}' > "$C"
}
# js <script> — runs <script> with the client sourced; prints "<stdout>|rc=<rc>|calls=<n>".
js() {
  echo 0 > "$T/calls"
  local out rc
  out=$(cd "$T" && PATH="$T/bin:$PATH" STUB_STATE="$T/calls" STUB_PLAN="${PLAN:-ok}" HARNESS="$T" HARNESS_SECRET=x \
    JOBS_ALERT=0 JOBS_RETRY_SLEEP=0 JOBS_OVERLOAD_SLEEP=0 JOBS_OVERLOAD_JITTER_S=0 LANE_GATE_NOW="${AT:-$NOW}" \
    bash -c 'source "$1"; eval "$2"' bash "$H/bin/jobs-client.sh" "$1" 2>/dev/null); rc=$?
  echo "$out|rc=$rc|calls=$(cat "$T/calls")"
}
fail=0
check() { if [ "$2" = "$3" ]; then echo "ok   $1 -> $3"; else echo "FAIL $1 -> $3 (want $2)"; fail=1; fi; }

cache "$NOW"
check "S1 fresh cache, row in values" '1|rc=0|calls=0' "$(js 'setting_get closeout_aged_table')"
check "S2 fresh cache, seeded row" '7|rc=0|calls=0' "$(js 'setting_get only_seeded')"
check "S3 fresh cache, no row" '|rc=2|calls=0' "$(js 'setting_get not_there')"
check "S3b fresh cache, empty value" '|rc=2|calls=0' "$(js 'setting_get empty_one')"
check "S4a 59 s old is fresh" '1|rc=0|calls=0' "$(AT=$((NOW+59)) js 'setting_get closeout_aged_table')"
check "S4 60 s old goes to the worker" 'net|rc=0|calls=1' "$(AT=$((NOW+60)) js 'setting_get closeout_aged_table')"
check "S5 lead_authority.x bypasses" 'net|rc=0|calls=1' "$(js 'setting_get lead_authority.x')"
check "S5 human_verdict_mode bypasses" 'net|rc=0|calls=1' "$(js 'setting_get human_verdict_mode')"
check "S5 human_verdict_sig_mode.sig bypasses" 'net|rc=0|calls=1' "$(js 'setting_get human_verdict_sig_mode.sig')"
check "S5 risk_tier.x bypasses" 'net|rc=0|calls=1' "$(js 'setting_get risk_tier.x')"
check "S5 human_verdict_mode.sig bypasses" 'net|rc=0|calls=1' "$(js 'setting_get human_verdict_mode.sig')"
# S6: the hot loops — archie's per-playbook loop and the $( )-lost memo.
check "S6 archie loop of 5" '33333|rc=0|calls=0' "$(js 'for i in 1 2 3 4 5; do setting_get archie.cap.p$i; done')"
check "S6 closeout_aged_table_on in \$( ) x3" 'yyy|rc=0|calls=0' \
  "$(js 'for i in 1 2 3; do r=$(closeout_aged_table_on && echo y); printf %s "$r"; done')"
# S7: setting_set marks the cache stale after a 2xx, keeps the file, and a
# failed PUT leaves it alone.
js 'setting_set foo 1' >/dev/null
check "S7 2xx PUT zeroes fetched_at" '0' "$(jq -r .fetched_at "$C" 2>/dev/null)"
check "S7 values kept for lane-gate's fallback" '1' "$(jq -r .values.closeout_aged_table "$C" 2>/dev/null)"
check "S7 next read goes to the worker" 'net|rc=0|calls=1' "$(js 'setting_get closeout_aged_table')"
cache "$NOW"
PLAN=down js 'setting_set foo 1' >/dev/null
check "S7 failed PUT leaves fetched_at" "$NOW" "$(jq -r .fetched_at "$C" 2>/dev/null)"
# S8: a future fetched_at and a cache that is not JSON both go to the worker.
cache $((NOW+5))
check "S8 future fetched_at" 'net|rc=0|calls=1' "$(js 'setting_get closeout_aged_table')"
printf 'not json' > "$C"
check "S8 non-JSON cache" 'net|rc=0|calls=1' "$(js 'setting_get closeout_aged_table')"
check "S8 non-JSON cache, worker down is rc 1 not 2" '|rc=1|calls=1' "$(PLAN=down js 'setting_get closeout_aged_table')"
# S9: JOBS_SETTINGS_CACHE_S=0 switches the cache path off.
cache "$NOW"
check "S9 JOBS_SETTINGS_CACHE_S=0" 'net|rc=0|calls=1' "$(JOBS_SETTINGS_CACHE_S=0 js 'setting_get closeout_aged_table')"
# S10: no cache file at all: the worker, as before.
rm -f "$C"
check "S10 no cache file" 'net|rc=0|calls=1' "$(js 'setting_get closeout_aged_table')"

# The worker half: the per-isolate snapshot both settings GET routes read.
WLIB="$H/worker/jobs/src/lib/settings-cache.js"
[ -r "$WLIB" ] && echo "ok   worker settings cache lib present" || { echo "FAIL $WLIB missing"; fail=1; }
if [ -r "$H/catalog/lanes.json" ] && node -e 'require("node:sqlite")' 2>/dev/null; then
  if (cd "$H/worker/jobs" && node --test test/settings-cache.bh-5781.test.js >"$T/w.out" 2>&1); then
    echo "ok   worker/jobs/test/settings-cache.bh-5781.test.js"
  else
    echo "FAIL worker/jobs/test/settings-cache.bh-5781.test.js"; cat "$T/w.out"; fail=1
  fi
else
  echo "SKIP worker test: needs catalog/lanes.json rendered (bin/lanes-build.sh --write) and node:sqlite"
fi
exit $fail
