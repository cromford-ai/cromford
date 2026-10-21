#!/bin/bash
# tests/sibling-serial-tick-cache.bh-7706-test.sh — the per-tick cache of
# bin/sibling-serial.sh (BH-7706). A pool tick runs `check` once per queued row,
# and each check read the project-wide inputs again: the parts map (a find over
# builds/), the active key and the job_claims rows (a jobs worker GET). With
# SIBLING_TICK_DIR set, `prime <project>` reads them once and `check` reads the
# cache.
#
#   S1  3 parts with planned files, one claim, one open sibling PR: for each key,
#       check after prime prints the same line and rc as check with no cache
#   S2  6 cached checks make 0 file-claims reads (prime made 1); 6 uncached
#       checks make 6
#   S3  a cache dir with no fc.ok reads the claims live; no SIBLING_TICK_DIR
#       writes no cache; a cache from prime keeps each key's list and source
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
NOW=1791860000   # 2026-10-13, pinned

H="$T/h"
QD="$H/state/build-queue/project-5"
mkdir -p "$H/bin" "$H/logs" "$H/plans" "$H/env" "$QD" "$H/state/fly-pool/project-5" \
         "$H/state/overlap-guard" "$H/builds" "$T/fakebin"
: > "$H/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/alert-line.sh"
scratch_install_closure bin/sibling-serial.sh "$H" >/dev/null || { echo "closure install of bin/sibling-serial.sh failed"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "closure install of bin/jobs-client.sh failed"; exit 1; }
chmod +x "$H/bin/alert-line.sh"

# The jobs worker: one claim for BH-50.0; every request URL goes to $T/calls.
# CLAIMS_DOWN=1 answers 500 (an outage).
cat > "$T/fakebin/curl" <<CURL
#!/bin/bash
T=$(printf '%q' "$T")
CURL
cat >> "$T/fakebin/curl" <<'CURL'
URL="${!#}"
echo "$URL" >> "$T/calls"
[ -n "${CLAIMS_DOWN:-}" ] && { printf '{"error":"fixture outage"}\n500'; exit 0; }
case "$URL" in
  */api/file-claims\?project=project-5*)
    jq -nc '{claims:[{ticket_id:"BH-50.0", files_claimed_at:"2026-10-13T02:30:00Z", planned_files:"src/a.ts"}]}'
    printf '\n200' ;;
  *) printf '{"error":"not found"}\n404' ;;
esac
CURL
chmod +x "$T/fakebin/curl"

plan_files() { local k="$1"; shift; mkdir -p "$H/plans/project-5-$k"; printf '%s\n' "$@" > "$H/plans/project-5-$k/planned-files.txt"; }
q() { jq -nc --arg k "$1" --arg t "$2" '{ticket_id:$t,key:$k,attempt:0,enqueued_at:"2026-10-13T02:00:00Z"}' > "$QD/$1.json"; }
# BH-50.1 shares src/a.ts with the claimed BH-50.0; BH-50.2 shares src/b.ts
# with BH-50.4's open PR; BH-50.3 shares src/c.ts with the lower BH-50.2.
plan_files BH-50.1 src/a.ts
plan_files BH-50.2 src/b.ts src/c.ts
plan_files BH-50.3 src/c.ts
q BH-50.1 501; q BH-50.2 502; q BH-50.3 503
jq -nc '[{number:44, headRefName:"ticket/bh-50.4", isDraft:false, files:[{path:"src/b.ts"}]}]' \
  > "$H/state/overlap-guard/project-5-prs.json"

ss() { # ss <verb> [key] [env...] — bin/sibling-serial.sh as the pool runs it
  local verb="$1" key="${2:-}"; shift 2 2>/dev/null || shift
  env PATH="$T/fakebin:$PATH" HARNESS="$H" JOBS_URL=http://jobs.fixture.test HARNESS_SECRET=fixture-secret \
      JOBS_RETRIES=0 SIBLING_SERIAL_NOW="$NOW" TMPDIR="$T" "$@" \
      bash "$H/bin/sibling-serial.sh" "$verb" project-5 ${key:+"$key"} 2>>"$T/err"
}
claims_reads() { local n; n=$(grep -c '/api/file-claims' "$T/calls" 2>/dev/null); echo "${n:-0}"; }

# ── S1/S2: the cache gives the same answers with one claims read ─────────────
: > "$T/calls"
declare -A LIVE=() LIVERC=()
for K in BH-50.1 BH-50.2 BH-50.3; do
  scratch_rm "$H/state/sibling-serial"
  LIVE[$K]=$(ss check "$K"); LIVERC[$K]=$?
done
for K in BH-50.1 BH-50.2 BH-50.3; do
  scratch_rm "$H/state/sibling-serial"
  LIVE[$K]=$(ss check "$K"); LIVERC[$K]=$?
done
[ "$(claims_reads)" = 6 ] && ok || bad "S2: 6 uncached checks read the claims 6 times, got $(claims_reads)"
[ "${LIVE[BH-50.1]}" = "SIBLING_SERIAL BH-50.1 waits for BH-50.0 on src/a.ts" ] && [ "${LIVERC[BH-50.1]}" = 3 ] && ok \
  || bad "S1: the fixture must hold BH-50.1 behind the claim (rc ${LIVERC[BH-50.1]}, '${LIVE[BH-50.1]}')"
[ "${LIVE[BH-50.2]}" = "SIBLING_SERIAL BH-50.2 waits for BH-50.4 on src/b.ts stackable base=ticket/bh-50.4" ] && ok \
  || bad "S1: the fixture must hold BH-50.2 behind the open PR ('${LIVE[BH-50.2]}')"
[ "${LIVE[BH-50.3]}" = "SIBLING_SERIAL BH-50.3 waits for BH-50.2 on src/c.ts" ] && ok \
  || bad "S1: the fixture must hold BH-50.3 behind the lower queued part ('${LIVE[BH-50.3]}')"

TD="$T/tick"; mkdir -p "$TD"
: > "$T/calls"
ss prime "" SIBLING_TICK_DIR="$TD"; RC=$?
[ "$RC" = 0 ] && ok || bad "S1: prime must exit 0, got $RC"
[ -f "$TD/parts" ] && [ -f "$TD/fc.ok" ] && [ -f "$TD/fc/BH-50.0" ] && [ -f "$TD/active" ] && ok \
  || bad "S1: prime must write parts, active, fc/ and fc.ok: $(cd "$TD" && find . | sort | tr '\n' ' ')"
for i in 1 2; do
  for K in BH-50.1 BH-50.2 BH-50.3; do
    scratch_rm "$H/state/sibling-serial"
    OUT=$(ss check "$K" SIBLING_TICK_DIR="$TD"); RC=$?
    [ "$OUT" = "${LIVE[$K]}" ] && [ "$RC" = "${LIVERC[$K]}" ] && ok \
      || bad "S1: cached check of $K (pass $i) must equal the live one: rc $RC '$OUT' vs rc ${LIVERC[$K]} '${LIVE[$K]}'"
  done
done
[ "$(claims_reads)" = 1 ] && ok || bad "S2: prime plus 6 cached checks must read the claims once, got $(claims_reads)"
[ -s "$TD/lists/BH-50.2" ] && [ "$(cat "$TD/lists/BH-50.2.src" 2>/dev/null)" = plans-dir ] && ok \
  || bad "S3: the tick cache must keep BH-50.2's list and its source"
[ "$(sort "$TD/lists/BH-50.2" | tr '\n' ' ')" = "src/b.ts src/c.ts " ] && ok || bad "S3: the cached list must be the planned list"

# ── S3: no fc.ok reads live; no SIBLING_TICK_DIR writes no cache ─────────────
rm -f "$TD/fc.ok"
: > "$T/calls"
scratch_rm "$H/state/sibling-serial"
OUT=$(ss check BH-50.1 SIBLING_TICK_DIR="$TD"); RC=$?
[ "$(claims_reads)" = 1 ] && ok || bad "S3: a cache with no fc.ok must read the claims live, got $(claims_reads) reads"
[ "$OUT" = "${LIVE[BH-50.1]}" ] && [ "$RC" = 3 ] && ok || bad "S3: the live fallback answers the same (rc $RC '$OUT')"
# A claims outage at prime time: no fc.ok, so each check reads live as before.
TD2="$T/tick2"; mkdir -p "$TD2"
ss prime "" SIBLING_TICK_DIR="$TD2" CLAIMS_DOWN=1 >/dev/null
[ -f "$TD2/fc.ok" ] && bad "S3: a prime whose claims read failed must not write fc.ok" || ok
scratch_rm "$H/state/sibling-serial"
OUT=$(ss check BH-50.1); RC=$?
[ "$OUT" = "${LIVE[BH-50.1]}" ] && [ "$RC" = 3 ] && ok || bad "S3: with no SIBLING_TICK_DIR check is unchanged (rc $RC '$OUT')"
[ "$(find "$T" -maxdepth 1 -name 'sibling-tick*' | wc -l | tr -d ' ')" = 0 ] && ok || bad "S3: no cache dir may be made without SIBLING_TICK_DIR"
# A prime with no SIBLING_TICK_DIR does nothing and exits 0.
ss prime ""; RC=$?
[ "$RC" = 0 ] && ok || bad "S3: prime with no SIBLING_TICK_DIR must exit 0, got $RC"

echo "pass=$PASS fail=$FAIL"
[ "$FAIL" = 0 ]
