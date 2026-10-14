#!/bin/bash
# tests/fork-defaults.bh-1957-test.sh — an EMPTY JOBS_URL means "no coordination
# DB here", and the jobs client then makes no network call at all.
#
# WHY. The client used to read `${JOBS_URL:-<our worker>}`, so a fork that set
# `JOBS_URL=` to mean "I have no worker" still sent every coordination call,
# HARNESS_SECRET in the Authorization header, to our harness-jobs worker. An
# empty value is now "not configured": no curl, rc 1 (the outage contract every
# caller already handles), one log line a day and no page. UNSET keeps the
# legacy URL for this release, because pool machines carry no JOBS_URL today
# (§5 pins that, so nothing across the fleet goes dark). That leaves item 10
# PARTIAL: #2063 removes the literal and flips §5 to "unset → not configured".
#
# WHY DRIVEN. The claim is a negative — nothing is sent — so curl is a stub that
# RECORDS every call, and the assertions are on that record, driven through the
# real client (sourced, and as a CLI).
# Run from anywhere: tests/fork-defaults.bh-1957-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/h/bin/lib/jobs" "$T/h/env" "$T/h/logs" "$T/h/flags" "$T/fakebin"
cp "$DIR/bin/jobs-client.sh" "$T/h/bin/"
scratch_install_closure bin/jobs-client.sh "$T/h" >/dev/null || { echo "FAIL: closure bin/jobs-client.sh"; exit 1; }
cat > "$T/fakebin/curl" <<'STUB'
#!/bin/bash
echo "curl ${!#}" >> "$CURL_SINK"      # the URL only: never a header, never a token
printf '{}\n200'
STUB
printf '#!/bin/bash\necho gh-token\n' > "$T/fakebin/gh"
chmod +x "$T/fakebin"/*
printf 'x\n' > "$T/body.json"
TODAY=$(date -u +%Y%m%d)

# run <env assignments...> -- <script>
# A clean environment every time (env -i), so nothing on the box running the
# suite — a real JOBS_URL, a real HARNESS_SECRET — can leak into a case.
run() {
  local envs=()
  while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  env -i PATH="$T/fakebin:/usr/bin:/bin" HOME="$T" HARNESS="$T/h" ETC_HARNESS_ENV="$T/no-such-dir" JOBS_BOX=test-box \
    JOBS_RETRIES=0 CURL_SINK="$T/curl.txt" "${envs[@]}" bash -c "$1" 2>"$T/err.txt"
}
reset() { rm -f "$T/curl.txt" "$T/h/logs"/* "$T/h/flags"/*; }
# Sources the client and makes three calls through both request paths, printing
# each call's stdout and rc on its own line so a single capture proves both.
CALLS=". \"$T/h/bin/jobs-client.sh\"
o=\$(job_cap build project-3); echo \"cap rc=\$? out=[\$o]\"
o=\$(_jobs_req GET /api/x); echo \"req rc=\$? out=[\$o]\"
o=\$(_jobs_req_file POST /api/y \"$T/body.json\"); echo \"file rc=\$? out=[\$o]\""
EXPECT="cap rc=1 out=[]
req rc=1 out=[]
file rc=1 out=[]"

# ══ 1. JOBS_URL= → NO REQUEST TO ANY HOST ═════════════════════════════════════
reset
printf 'HARNESS_SECRET=s\n' > "$T/h/env/global.env"
OUT=$(run HARNESS_SECRET=s JOBS_URL= -- "$CALLS")
[ ! -s "$T/curl.txt" ] \
  && ok || bad "§1 THE POINT: an empty JOBS_URL must make no request to any host. curl saw: $(cat "$T/curl.txt" 2>/dev/null)"
[ "$OUT" = "$EXPECT" ] \
  && ok || bad "§1 every call must print nothing and return rc 1 (fail open, same as an outage). Got:
$OUT"
[ ! -s "$T/err.txt" ] && ok || bad "§1 nothing on stderr: $(cat "$T/err.txt")"

# ══ 2. ONE 'not configured' LINE A DAY, AND NO PAGE ═════════════════════════
OUT2=$(run HARNESS_SECRET=s JOBS_URL= -- "$CALLS")     # a second process, same day
[ "$OUT2" = "$EXPECT" ] && ok || bad "§2 the second process must fail open the same way: $OUT2"
N=$(grep -c 'coordination DB not configured' "$T/h/logs/jobs-client.log" 2>/dev/null)
[ "${N:-0}" = 1 ] \
  && ok || bad "§2 six calls in two processes must log 'coordination DB not configured' exactly once, got ${N:-0}: $(cat "$T/h/logs/jobs-client.log" 2>/dev/null)"
grep -q 'set JOBS_URL in env/global.env' "$T/h/logs/jobs-client.log" 2>/dev/null \
  && ok || bad "§2 the line must say how to fix it"
NF=$(ls "$T/h/flags"/alerted-jobs-not-configured-"$TODAY" 2>/dev/null | wc -l | tr -d ' ')
[ "$NF" = 1 ] && ok || bad "§2 exactly one dated dedupe flag expected, got $NF: $(ls "$T/h/flags")"
[ ! -s "$T/h/logs/ALERTS.log" ] \
  && ok || bad "§2 'not configured' is a choice, not an outage — it must not page: $(cat "$T/h/logs/ALERTS.log" 2>/dev/null)"
# A NEW day logs again: the flag is dated, so the state is never silent for ever.
rm -f "$T/h/flags"/alerted-jobs-not-configured-*
run HARNESS_SECRET=s JOBS_URL= -- "$CALLS" >/dev/null
N=$(grep -c 'coordination DB not configured' "$T/h/logs/jobs-client.log" 2>/dev/null)
[ "${N:-0}" = 2 ] && ok || bad "§2 a fresh day's flag must log again, got ${N:-0}"

# ══ 3. THE CLI: rc 1, no curl, no trace ══════════════════════════════════════
reset
run HARNESS_SECRET=s JOBS_URL= -- "bash \"$T/h/bin/jobs-client.sh\" cap build project-3" >/dev/null
RC=$?
[ "$RC" = 1 ] && ok || bad "§3 the CLI must exit 1 (fail open), got $RC"
[ ! -s "$T/curl.txt" ] && ok || bad "§3 the CLI must not call curl: $(cat "$T/curl.txt" 2>/dev/null)"
[ ! -s "$T/err.txt" ] && ok || bad "§3 the CLI must print no error: $(cat "$T/err.txt")"

# ══ 4. `JOBS_URL=` IN global.env IS THE SAME ANSWER ═════════════════════════
# The shipped template (env-templates/lanes/015-coordination-db.env.example)
# writes exactly this line. A caller that never set JOBS_URL must adopt the
# file's EMPTY value, not fall through to the legacy literal.
reset
printf 'HARNESS_SECRET=s\nJOBS_URL=\n' > "$T/h/env/global.env"
OUT=$(run -- "$CALLS")
[ ! -s "$T/curl.txt" ] \
  && ok || bad "§4 global.env's JOBS_URL= must mean not configured for a caller that left it unset. curl saw: $(cat "$T/curl.txt" 2>/dev/null)"
[ "$OUT" = "$EXPECT" ] && ok || bad "§4 fail open expected: $OUT"
grep -q 'coordination DB not configured' "$T/h/logs/jobs-client.log" 2>/dev/null \
  && ok || bad "§4 'not configured' must be logged"

# ...and a pool machine gets the same answer through its env bundle. The
# extractor is the exact REMOTE_SCRIPT fly-envbundle.sh runs on the owning box,
# pointed at this fixture's env dir instead of /root/harness.
awk "/^REMOTE_SCRIPT='\$/{f=1;next} f&&/^'\$/{exit} f" "$DIR/bin/fly-envbundle.sh" \
  | sed "s#/root/harness#$T/h#g; s#__PROJECT__#project-3#g" > "$T/extract.sh"
# HARNESS and ETC_HARNESS_ENV are pinned so the resolver can only ever find the
# fixture's env dir — never the live one on the box running this suite.
extract() {
  env -i PATH="$T/fakebin:/usr/bin:/bin" HOME="$T" HARNESS="$T/h" ETC_HARNESS_ENV="$T/no-such-dir" \
    bash "$T/extract.sh" 2>/dev/null
}
[ -s "$T/extract.sh" ] && ok || bad "§4 could not lift REMOTE_SCRIPT out of bin/fly-envbundle.sh"
: > "$T/h/env/project-3.env"
printf 'HARNESS_SECRET=s\nJOBS_URL=\nRUNNER_X=1\n' > "$T/h/env/global.env"
BUNDLE=$(extract)
BUNDLE_EMPTY="$BUNDLE"
grep -qx 'HARNESS_SECRET=s' <<<"$BUNDLE" \
  && ok || bad "§4 the extractor must read the FIXTURE env, not the box's (keys: $(grep -o '^[A-Z_]*=' <<<"$BUNDLE" | tr '\n' ' '))"
grep -qx 'JOBS_URL=' <<<"$BUNDLE" \
  && ok || bad "§4 a box that set JOBS_URL= must hand that EMPTY line to its pool machines (bundle keys: $(grep -o '^[A-Z_]*=' <<<"$BUNDLE" | tr '\n' ' '))"
printf 'HARNESS_SECRET=s\nRUNNER_X=1\n' > "$T/h/env/global.env"
BUNDLE=$(extract)
grep -q '^JOBS_URL' <<<"$BUNDLE" \
  && bad "§4 a box with no JOBS_URL line must bundle none (today's bundle, unchanged)" || ok
grep -qx 'RUNNER_X=1' <<<"$BUNDLE" && ok || bad "§4 the RUNNER_* lines must still ride (bundle keys: $(grep -o '^[A-Z_]*=' <<<"$BUNDLE" | tr '\n' ' '))"
# Driven end to end: the bundled global.env on a "machine" with no JOBS_URL in
# its environment makes no call. The split mirrors fly-envbundle.sh's awk.
reset
mkdir -p "$T/bundle-env"
printf '%s\n' "$BUNDLE_EMPTY" | awk '/^===GLOBAL===$/{g=1;next} /^===PROJECT===$/{g=0} g' \
  > "$T/bundle-env/global.env"
run HARNESS_ENV_DIR="$T/bundle-env" -- "$CALLS" >/dev/null
[ ! -s "$T/curl.txt" ] \
  && ok || bad "§4 a pool machine reading the bundled JOBS_URL= must make no call: $(cat "$T/curl.txt" 2>/dev/null)"

# ══ 5. FLEET SAFETY: UNSET AND NON-EMPTY ARE UNCHANGED ══════════════════════
# The literal is the ONLY URL pool machines reach the ledger by today. If this
# goes red the fleet's coordination DB just went dark. #2063 flips this section
# once every box and bundle carries JOBS_URL.
reset
printf 'HARNESS_SECRET=s\n' > "$T/h/env/global.env"
run HARNESS_SECRET=s -- ". \"$T/h/bin/jobs-client.sh\"; _jobs_req GET /api/x" >/dev/null
grep -q 'https://harness-jobs.operator.workers.dev/api/x' "$T/curl.txt" 2>/dev/null \
  && ok || bad "§5 an UNSET JOBS_URL must still reach the legacy worker this release: $(cat "$T/curl.txt" 2>/dev/null)"
[ ! -s "$T/h/logs/jobs-client.log" ] && ok || bad "§5 unset must not log 'not configured'"
reset
run HARNESS_SECRET=s JOBS_URL=https://x.invalid -- ". \"$T/h/bin/jobs-client.sh\"; _jobs_req GET /api/x" >/dev/null
grep -q 'https://x.invalid/api/x' "$T/curl.txt" 2>/dev/null \
  && ok || bad "§5 JOBS_URL=https://x.invalid must be used: $(cat "$T/curl.txt" 2>/dev/null)"
# caller empty + file non-empty → the file wins (the existing bootstrap rule).
reset
printf 'HARNESS_SECRET=s\nJOBS_URL=https://y.invalid\n' > "$T/h/env/global.env"
run JOBS_URL= -- ". \"$T/h/bin/jobs-client.sh\"; _jobs_req GET /api/x" >/dev/null
grep -q 'https://y.invalid/api/x' "$T/curl.txt" 2>/dev/null \
  && ok || bad "§5 caller-empty + global.env JOBS_URL=https://y.invalid must use y: $(cat "$T/curl.txt" 2>/dev/null)"

echo "fork-defaults.bh-1957-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
