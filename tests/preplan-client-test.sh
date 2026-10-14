#!/bin/bash
# tests/preplan-client-test.sh — the pre-plan CLIENT CONTRACT (BH-658.0): the
# three jobs-client verbs that move a pre-plan row, and the two preplan-lib
# helpers that read one. Every other BH-658 child imports this contract, so it
# is pinned on its own before any caller exists.
# Run from anywhere: tests/preplan-client-test.sh   (exit 0 = all pass)
#
# WHAT IS PINNED HERE, and why each one has a test rather than a comment:
#   - REFUSED vs UNREACHABLE. A 4xx is the worker JUDGING the request (the row
#     is not stored, a retry is refused identically) and a 5xx or a transport
#     failure is the worker FAILING (we do not know). They are rc 3 and rc 1
#     because they send whoever reads the log to different places (D10).
#   - ABSENT IS NOT "". A missing planned-files.txt or ticket-fp is OMITTED from
#     the body; an empty-string fingerprint is a VALUE that compares, and the
#     adopt's thread check has to fail OPEN on absence (D11).
#   - THE PLAN IS THE PAYLOAD. --rawfile, never --arg "$(cat …)": command
#     substitution eats the trailing newline, so the body is compared with `cmp`
#     against the file, not just as a string.
#   - "COULD NOT ASK" IS NOT "NO OVERLAP". preplan_planned_files prints nothing
#     and answers rc 1 when no list exists anywhere; it fails CLOSED, because its
#     consumer is an overlap guard and an empty answer there reads as safe.
#   - LAZY SOURCING. _preplan_client sources jobs-client.sh only when the verbs
#     are not already callable, so every preplan_speculative caller does not
#     inherit JOBS_*.
# Every assertion reads what the code produced — the fake curl's call log and
# request bodies, the function's own stdout and rc — never source text (D3).
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin/lib" "$T/fakebin" "$T/env" "$T/flags" "$T/logs" "$T/plans" "$T/curl"
cp "$DIR/bin/jobs-client.sh" "$T/bin/"
mkdir -p "$T/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/bin/lib/jobs/"
cp "$DIR/bin/lib/preplan-lib.sh" "$T/bin/lib/"
: > "$T/env/global.env"

# ── the fake curl ────────────────────────────────────────────────────────────
# Records every call (method + url + body) and answers from files in $CURL_DIR:
#   routes   pattern<TAB>http-code<TAB>body-file, first URL match wins
#   rc       a TRANSPORT failure code (28 = timeout), 0 = answer normally
# A URL that matches no route answers 404, which is what a worker that has not
# been redeployed yet actually does.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
D="${CURL_DIR:?CURL_DIR unset}"
M=GET; U=""; BODY=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) M="$2"; shift 2 ;;
    --data-binary) BODY="$2"; shift 2 ;;
    -H|-m|--connect-timeout|-w|-o) shift 2 ;;
    -*) shift ;;
    *) U="$1"; shift ;;
  esac
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}" 2>/dev/null) ;; esac
N=$(cat "$D/n" 2>/dev/null || echo 0); N=$((N+1)); printf '%s\n' "$N" > "$D/n"
printf '%s\t%s\n' "$M" "$U" >> "$D/calls"
printf '%s' "$BODY" > "$D/body.$N"
printf '%s' "$BODY" > "$D/body.last"
RC=$(cat "$D/rc" 2>/dev/null || echo 0)
[ "$RC" != 0 ] && exit "$RC"
CODE=404; FILE=""
if [ -s "$D/routes" ]; then
  while IFS=$'\t' read -r PAT C F; do
    [ -n "$PAT" ] || continue
    case "$U" in *"$PAT"*) CODE="$C"; FILE="$F"; break ;; esac
  done < "$D/routes"
fi
if [ -n "$FILE" ] && [ -r "$FILE" ]; then cat "$FILE"; else printf '{"error":"no route"}'; fi
printf '\n%s' "$CODE"
exit 0
SH
chmod +x "$T/fakebin/curl"
curl_reset() { rm -f "$T/curl/calls" "$T/curl/n" "$T/curl/body."* "$T/curl/routes"; printf '0\n' > "$T/curl/rc"; }
route() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$T/curl/routes"; }
curl_reset

# jc <snippet> — run a jobs-client verb with the fake curl on PATH.
jc() {
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box JOBS_RETRIES=0 \
           CURL_DIR="$T/curl"
    # shellcheck source=/dev/null
    . "$T/bin/jobs-client.sh"; eval "$1" )
}

# ── a consumable pre-plan record on disk, the shape run-preplan.sh leaves ─────
PD="$T/plans/proj-AB-1"; mkdir -p "$PD"
printf '## Scope\nTouch src/lib/pay.ts and nothing else.\nSIZE: S\n' > "$PD/plan.md"
printf '1234567890abcdef1234567890abcdef12345678\n' > "$PD/base-sha"
printf 'src/lib/pay.ts\n' > "$PD/planned-files.txt"
printf '2026-09-17T10:00:00Z|2026-09-17T10:00:00Z||3\n' > "$PD/ticket-fp"
printf 'AB-1\n' > "$PD/key"

echo "--- 1. jobs-client verbs"
curl_reset
printf '{"preplan":{"project":"proj","ticket_key":"AB-1"}}' > "$T/curl/ok.json"
route /api/preplans 200 "$T/curl/ok.json"
OUT=$(jc 'preplan_put proj AB-1 '"$PD"'; echo "rc=$?"')
[ "$OUT" = "published
rc=0" ] && ok || bad "preplan_put on a 200 must print 'published' and rc 0, got: $OUT"
[ "$(grep -c 'POST' "$T/curl/calls")" = 1 ] && ok || bad "preplan_put must make exactly one POST (calls: $(cat "$T/curl/calls"))"
grep -q $'POST\thttps://jobs.invalid/api/preplans' "$T/curl/calls" \
  && ok || bad "preplan_put must POST /api/preplans (got: $(cat "$T/curl/calls"))"
B="$T/curl/body.last"
[ "$(jq -r '.plan_md' "$B")" = "$(cat "$PD/plan.md")" ] \
  && ok || bad "the POST body's plan_md must be the plan file byte for byte"
# ...and byte-for-byte INCLUDES the trailing newline, which the string compare
# above cannot see ($(…) strips it on both sides). --arg "$(cat plan.md)" passes
# that compare and ships a plan one byte short; `cmp` on the raw value is what
# makes the difference red.
cmp -s <(jq -j '.plan_md' "$B") "$PD/plan.md" \
  && ok || bad "the POST body's plan_md must keep the plan's trailing newline (--rawfile, never --arg \$(cat))"
[ "$(jq -r '.base_sha' "$B")" = 1234567890abcdef1234567890abcdef12345678 ] \
  && ok || bad "the POST body must carry the base sha"
[ "$(jq -r '.planned_files' "$B")" = "src/lib/pay.ts" ] \
  && ok || bad "the POST body must carry the planned-files list"
[ "$(jq -r '.ticket_fp' "$B")" = '2026-09-17T10:00:00Z|2026-09-17T10:00:00Z||3' ] \
  && ok || bad "the POST body must carry the thread fingerprint"
[ "$(jq -r '.ticket_key' "$B")" = AB-1 ] && ok || bad "the POST body must name its ticket key"
[ "$(jq -r '.box' "$B")" = test-box ] && ok || bad "the POST body must name the box that wrote it"

# D11: a missing ticket-fp is ABSENT, never an empty-string fingerprint — the
# adopt's thread check must fail OPEN on it, and "" is a value that compares.
mv "$PD/ticket-fp" "$T/fp.saved"
curl_reset; route /api/preplans 200 "$T/curl/ok.json"
jc 'preplan_put proj AB-1 '"$PD" >/dev/null
[ "$(jq -r 'has("ticket_fp")' "$T/curl/body.last")" = false ] \
  && ok || bad "a pre-plan with no ticket-fp must OMIT the field, never send \"\""
mv "$T/fp.saved" "$PD/ticket-fp"

# 413 and 404 are REFUSALS (the plan was not stored, and we know it); rc 28 is
# an outage. A caller that cannot tell them apart logs the wrong line.
curl_reset; route /api/preplans 413 ""
OUT=$(jc 'preplan_put proj AB-1 '"$PD"' >/dev/null; echo "rc=$?"')
[ "$OUT" = "rc=3" ] && ok || bad "a 413 must be rc 3 (refused), got: $OUT"
curl_reset; route /nothing 200 ""
OUT=$(jc 'preplan_put proj AB-1 '"$PD"' >/dev/null; echo "rc=$?"')
[ "$OUT" = "rc=3" ] && ok || bad "a 404 (worker not redeployed) must be rc 3 (refused), got: $OUT"
curl_reset; printf '28\n' > "$T/curl/rc"
OUT=$(jc 'preplan_put proj AB-1 '"$PD"' >/dev/null; echo "rc=$?"')
[ "$OUT" = "rc=1" ] && ok || bad "a transport failure must be rc 1 (unreachable), got: $OUT"
printf '0\n' > "$T/curl/rc"
# ...and so is a 5xx. The worker BROKE rather than judged: we do not know whether
# the row landed, and "REFUSED" would send whoever reads logs/preplan.log at the
# payload instead of at the worker.
curl_reset; route /api/preplans 500 ""
OUT=$(jc 'preplan_put proj AB-1 '"$PD"' >/dev/null; echo "rc=$?"')
[ "$OUT" = "rc=1" ] && ok || bad "a 500 must be rc 1 (unreachable), never rc 3 (refused), got: $OUT"
curl_reset; route /api/preplans 503 ""
OUT=$(jc 'preplan_put proj AB-1 '"$PD"' >/dev/null; echo "rc=$?"')
[ "$OUT" = "rc=1" ] && ok || bad "a 503 must be rc 1 (unreachable), got: $OUT"

curl_reset; route /nothing 200 ""
OUT=$(jc 'preplan_get proj AB-1 >/dev/null; echo "rc=$?"')
[ "$OUT" = "rc=2" ] && ok || bad "preplan_get on a 404 must be rc 2 (a real miss), got: $OUT"
cat > "$T/curl/row.json" <<'JSON'
{"preplan":{"project":"proj","ticket_key":"AB-1","base_sha":"1234567890abcdef1234567890abcdef12345678","ticket_fp":"2026-09-17T10:00:00Z|2026-09-17T10:00:00Z||3","planned_files":"src/lib/pay.ts\n","plan_md":"## Scope\nTouch src/lib/pay.ts and nothing else.\nSIZE: S\n","bytes":63,"box":"box-project-4-1","updated_at":"2026-09-17T10:01:00Z"}}
JSON
curl_reset; route /api/preplans 200 "$T/curl/row.json"
OUT=$(jc 'preplan_get proj AB-1')
[ "$(printf '%s' "$OUT" | jq -r '.ticket_key')" = AB-1 ] \
  && ok || bad "preplan_get must print the row JSON, got: $OUT"
cat > "$T/curl/index.json" <<'JSON'
{"preplans":[{"ticket_key":"AB-1","base_sha":"1234567","ticket_fp":"x","planned_files":"src/lib/pay.ts\nsrc/ui/card.tsx\n","updated_at":"2026-09-17T10:01:00Z"},{"ticket_key":"AB-2","base_sha":"89abcde","planned_files":"src/other.ts\n","updated_at":"2026-09-17T09:00:00Z"}]}
JSON
curl_reset; route /api/preplans 200 "$T/curl/index.json"
OUT=$(jc 'preplan_index proj')
[ "$(printf '%s\n' "$OUT" | wc -l)" = 2 ] && ok || bad "preplan_index must print one line per key, got: $OUT"
[ "$(head -1 <<<"$OUT" | cut -f4)" = 'src/lib/pay.ts|src/ui/card.tsx|' ] \
  && ok || bad "preplan_index must flatten newlines in planned_files so a TSV reader never shifts, got: $(head -1 <<<"$OUT")"

echo "--- 2. preplan_planned_files: local dir first, DB second"
plf() { # plf <key> -> the function's stdout, run with the fake curl on PATH
  ( export PATH="$T/fakebin:$PATH" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
           JOBS_BOX=test-box JOBS_RETRIES=0 CURL_DIR="$T/curl"
    # shellcheck source=/dev/null
    . "$T/bin/lib/preplan-lib.sh"; preplan_planned_files "$T" proj "$1"; echo "rc=$?" )
}
curl_reset; route /api/preplans 200 "$T/curl/index.json"
OUT=$(plf AB-1)
[ "$OUT" = "src/lib/pay.ts
rc=0" ] && ok || bad "the LOCAL plans/ list must win, got: $OUT"
[ ! -s "$T/curl/calls" ] && ok || bad "a local list must cost no request (calls: $(cat "$T/curl/calls" 2>/dev/null))"
curl_reset; route /api/preplans 200 "$T/curl/index.json"
OUT=$(plf AB-2)
[ "$OUT" = "src/other.ts
rc=0" ] && ok || bad "with no local dir the DB index row must answer, got: $OUT"
printf '{"preplans":[]}' > "$T/curl/empty-index.json"
curl_reset; route /api/preplans 200 "$T/curl/empty-index.json"
OUT=$(plf AB-3)
[ "$OUT" = "rc=1" ] && ok || bad "no list anywhere must print nothing and rc 1, got: $OUT"
# BH-6715: an index read that failed (404 here) is rc 2, "could not ask", not rc 1
curl_reset; route /nothing 200 ""
OUT=$(plf AB-3)
[ "$OUT" = "rc=2" ] && ok || bad "an index that did not answer must print nothing and rc 2, got: $OUT"

echo "--- 3. _preplan_client sources lazily"
# (a) the verbs are already callable here, so NOTHING may be sourced — proven by
# taking the file away: a version that sourced unconditionally would fail.
mv "$T/bin/jobs-client.sh" "$T/jc.saved"
OUT=$( ( export PATH="$T/fakebin:$PATH"
         . "$T/bin/lib/preplan-lib.sh"
         preplan_get() { :; }
         _preplan_client "$T"; echo "rc=$?" ) )
[ "$OUT" = "rc=0" ] && ok || bad "_preplan_client must answer rc 0 without sourcing when the verbs are defined, got: $OUT"
mv "$T/jc.saved" "$T/bin/jobs-client.sh"

# (b) not defined and the file is there: source it, and the verbs are callable
# AFTERWARDS (rc 0 alone would pass on a function that returns 0 and does nothing).
OUT=$( ( export PATH="$T/fakebin:$PATH"
         . "$T/bin/lib/preplan-lib.sh"
         _preplan_client "$T"; echo "rc=$?"
         command -v preplan_index >/dev/null 2>&1 && echo "index=yes" || echo "index=no" ) )
[ "$OUT" = "rc=0
index=yes" ] && ok || bad "_preplan_client must source jobs-client.sh and leave the verbs callable, got: $OUT"

# (c) no client to source: rc 1, never a silent success. ABSENCE is how this is
# pinned rather than `chmod 000` — these suites run as root on every box and root
# reads a mode-000 file, so a permissions fixture would pass on any code at all.
mkdir -p "$T/nolib/bin"
OUT=$( ( export PATH="$T/fakebin:$PATH"
         . "$T/bin/lib/preplan-lib.sh"
         _preplan_client "$T/nolib"; echo "rc=$?" ) )
[ "$OUT" = "rc=1" ] && ok || bad "_preplan_client must answer rc 1 when there is no jobs-client.sh to read, got: $OUT"

# (d) THE LAZINESS ITSELF: sourcing preplan-lib.sh must define no jobs-client
# verb and set no JOBS_* — 15 scripts source this lib, and preplan_speculative
# callers must not inherit a coordination client they never asked for.
OUT=$( ( unset JOBS_URL
         . "$T/bin/lib/preplan-lib.sh"
         command -v preplan_get >/dev/null 2>&1 && echo "get=yes" || echo "get=no"
         echo "url=${JOBS_URL:-unset}" ) )
[ "$OUT" = "get=no
url=unset" ] && ok || bad "sourcing preplan-lib.sh must not drag in jobs-client.sh or JOBS_URL, got: $OUT"

echo "--- 4. the CLI entry point"
# The three cases in bin/jobs-client.sh's own `if [ "${BASH_SOURCE[0]}" = "$0" ]`
# block, driven as a real process (D2): sourcing the file would never notice a
# missing case or an exit code the dispatcher swallowed.
cli() { # cli <verb> [args…] -> stdout then rc=N
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" HARNESS_SECRET=test-secret \
           JOBS_URL=https://jobs.invalid JOBS_BOX=test-box JOBS_RETRIES=0 \
           CURL_DIR="$T/curl"
    bash "$T/bin/jobs-client.sh" "$@"; echo "rc=$?" )
}
curl_reset; route /api/preplans 200 "$T/curl/ok.json"
OUT=$(cli preplan-put proj AB-1 "$PD")
[ "$OUT" = "published
rc=0" ] && ok || bad "the preplan-put CLI case must publish and exit 0, got: $OUT"
[ "$(jq -r '.ticket_key' "$T/curl/body.last")" = AB-1 ] \
  && ok || bad "the preplan-put CLI case must pass its arguments through to the POST body"
curl_reset; route /api/preplans 413 ""
OUT=$(cli preplan-put proj AB-1 "$PD" 2>/dev/null)
[ "$OUT" = "rc=3" ] && ok || bad "the CLI must exit with the verb's rc (3 on a refusal), got: $OUT"
curl_reset; route /api/preplans 200 "$T/curl/row.json"
OUT=$(cli preplan-get proj AB-1)
[ "$(head -1 <<<"$OUT" | jq -r '.ticket_key')" = AB-1 ] \
  && ok || bad "the preplan-get CLI case must print the row, got: $OUT"
curl_reset; route /api/preplans 200 "$T/curl/index.json"
OUT=$(cli preplan-index proj)
[ "$(head -1 <<<"$OUT" | cut -f1)" = AB-1 ] \
  && ok || bad "the preplan-index CLI case must print the TSV index, got: $OUT"
# The usage line is what an operator reads; a verb that is not in it is a verb
# nobody finds.
U=$( ( export HARNESS="$T"; bash "$T/bin/jobs-client.sh" bogus-verb ) 2>&1 )
grep -q 'preplan-put <project> <key> <plan-dir>|preplan-get <project> <key>|preplan-index <project>' <<<"$U" \
  && ok || bad "the usage line must document the three preplan verbs"

echo "preplan-client: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
