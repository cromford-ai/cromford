#!/bin/bash
# tests/closeout-relayed.bh-6956-test.sh — BH-6956: a RELAYED pool dir on the
# hub is a custody copy. The owning box closes the result out on its own copy
# and writes COMMENTED there, never here. So neither orphan-reconcile's
# awaiting-closeout guard nor closeout_overdue_note counts it (the same rule as
# bin/pipeline-health.sh, which already skips RELAYED dirs).
#
#   R1  an orphan whose only open dir is RELAYED is relaunched
#   R2  the same dir without RELAYED still holds it as awaiting-closeout
#   R3  a RELAYED dir next to a non-relayed open dir still holds it
#   C1  closeout_overdue_note: a RELAYED-only key sends no warn
#   C2  the same dir without RELAYED sends one warn
#   C3  age and count come from the non-relayed dir only
#   C4  the warn names the owning box from bin/box-for.sh, when it answers
#
# R1-R3 use tests/orphan-reconcile-closeout-guard.bh-5967-test.sh's rig: the
# real script against a scratch HARNESS, fake gh and curl. Exit 0 = pass.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" \
         "$H/prompts" "$H/builds" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
P=project-5
for L in bin/orphan-reconcile.sh bin/jobs-client.sh bin/lib/preplan-lib.sh bin/lib/gh-budget.sh bin/lib/hold.sh \
         bin/lib/closeout-overdue.sh bin/lib/gh-rest.sh bin/lib/gh-rest-var.sh bin/lib/gh-rest-list.sh bin/fleet-conf.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
for L in $(cd "$DIR" && printf '%s ' bin/lib/jobs/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
export FLEET_CONF="$DIR/fleet.conf"
echo 'setsid /root/harness/bin/run-build.sh project-5 <issue-number> TK-<issue-number> > x' > "$H/prompts/$P.md"
printf 'HARNESS_SECRET=fixture-secret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$HARNESS/launches.log"' > "$H/bin/run-build.sh"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$HARNESS/alerts-called.log"' > "$H/bin/lane-alert.sh"
printf '%s\n' '#!/bin/bash' 'printf "%s\n" "$*" >> "$HARNESS/needs-human.log"' 'exit 0' > "$H/bin/needs-human-hold.sh"
chmod +x "$H/bin/"*.sh

# gh: the open board, the all-states list, the PR list and one HOLD thread.
cat > "$T/fakebin/gh" <<'SH'
ARGS="$*"
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
PAGE=$(printf '%s' "$ARGS" | sed -nE 's/.*page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
[ "$PAGE" = 1 ] || SEND 200 '[]'
case "$ARGS" in
  "api repos/example-org/project-5 -q .id") echo 1; exit 0 ;;
  *"api rate_limit"*) exit 1 ;;
  *"/issues/"*"/comments"*)
    n=$(printf '%s' "$ARGS" | sed -nE 's#.*/issues/([0-9]+)/comments.*#\1#p')
    SEND 200 "$(jq -c --argjson n "$n" '[ .[] | select(.number==$n) | (.comments // [])[] ]' "$HARNESS/fixture/open.json")" ;;
  *"/pulls"*)
    SEND 200 "$(jq -c '[ .[] | {number, title, body, head:{ref:.headRefName}} ]' "$HARNESS/fixture/prs.json")" ;;
  *"/issues"*"state=all"*)
    SEND 200 "$(jq -c '[ .[] | {number, state:"open", closed_at:null} ]' "$HARNESS/fixture/open.json")" ;;
  *"/issues"*)
    SEND 200 "$(jq -c '[ .[] | {number, title, body, comments:((.comments // [])|length), updated_at:.updatedAt} ]' "$HARNESS/fixture/open.json")" ;;
  *) exit 1 ;;
esac
SH
# curl: the jobs ledger, the queue (a FAILED row per key, with its reason), and
# every POST to /api/queue recorded with its body.
cat > "$T/fakebin/curl" <<'SH'
URL="${!#}"; METHOD=GET; BODY=""
prev=""
for a in "$@"; do
  [ "$prev" = -X ] && METHOD="$a"
  [ "$prev" = --data-binary ] && BODY="$a"
  prev="$a"
done
case "$BODY" in @*) BODY=$(cat "${BODY#@}" 2>/dev/null) ;; esac
case "$METHOD $URL" in
  "POST "*/api/queue*) printf '%s\n' "$BODY" >> "$HARNESS/queue-posts.log"; printf '{"ok":true}\n200\n' ;;
  "GET "*/api/queue*"key="*)
    k=$(printf '%s' "$URL" | sed -nE 's/.*key=([^&]+).*/\1/p')
    printf '{"queue":[{"project":"project-5","ticket_key":"%s","status":"failed","reason":"deferred 12 times (BUILD_DEFERRED After: TK-5 in flight) — parked for the blocked-resolver"}]}\n200\n' "$k" ;;
  "GET "*/api/queue*) printf '{"queue":[]}\n200\n' ;;
  "GET "*/api/jobs*) printf '%s\n200\n' "$(cat "$HARNESS/fixture/jobs.json")" ;;
  *) printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"

ISO() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
board() {
  cat > "$H/fixture/open.json" <<JSON
[
 {"number":989,"title":"TK-989 stranded","body":"## Scope","comments":[],"updatedAt":"$(ISO 86400)"},
 {"number":902,"title":"TK-902 has an open PR","body":"## Scope","comments":[],"updatedAt":"$(ISO 86400)"},
 {"number":887,"title":"TK-887 held","body":"## Scope","comments":[{"body":"HOLD — do not build this yet.","user":{"type":"User"},"created_at":"$(ISO 86000)"}],"updatedAt":"$(ISO 86000)"},
 {"number":910,"title":"TK-910 tried half an hour ago","body":"## Scope","comments":[],"updatedAt":"$(ISO 86400)"}
]
JSON
  echo '[{"number":1044,"title":"TK-902: the PR that owns it","headRefName":"ticket/TK-902","body":""}]' > "$H/fixture/prs.json"
  cat > "$H/fixture/jobs.json" <<JSON
{"jobs":[
 {"id":"build-project-5-TK-989-0","ticket_id":"TK-989","kind":"build","status":"failed","updated_at":"$(ISO 9000)","meta":"{\"ticket_id\":\"989\"}"},
 {"id":"build-project-5-TK-910-0","ticket_id":"TK-910","kind":"build","status":"failed","updated_at":"$(ISO 1800)","meta":"{\"ticket_id\":\"910\"}"}
]}
JSON
}
reset() {
  scratch_rm "$H/state"; scratch_rm "$H/logs"; scratch_rm "$H/builds"
  mkdir -p "$H/state" "$H/logs" "$H/builds"
  rm -f "$H/launches.log" "$H/queue-posts.log" "$H/needs-human.log" "$H/alerts-called.log"
  board
}
run() { "$H/bin/orphan-reconcile.sh" "$P" 2>/dev/null; }
summary() { grep -o 'reconcile: open=.*' "$H/logs/$P.log" | tail -1; }

PR1='PR_CREATED https://github.com/example-org/project-5/pull/1'

# R1: the only open dir is the hub's RELAYED custody copy.
reset
mkdir -p "$H/builds/pool-$P-TK-989-202610150900"
echo "$PR1" > "$H/builds/pool-$P-TK-989-202610150900/RESULT"
: > "$H/builds/pool-$P-TK-989-202610150900/RELAYED"
run
grep -q 'project-5 989 TK-989' "$H/launches.log" 2>/dev/null && ok \
  || bad "R1: THE BUG: a RELAYED custody copy held TK-989 back ($(summary))"
grep -q 'TK-989:awaiting-closeout' <<<"$(summary)" && bad "R1: a RELAYED-only key is not awaiting-closeout ($(summary))" || ok

# R2: the same dir without RELAYED owes its close-out here.
reset
mkdir -p "$H/builds/pool-$P-TK-989-202610150900"
echo "$PR1" > "$H/builds/pool-$P-TK-989-202610150900/RESULT"
run
grep -q 'TK-989' "$H/launches.log" 2>/dev/null && bad "R2: a non-relayed RESULT must hold the relaunch: $(cat "$H/launches.log")" || ok
summary | grep -q 'TK-989:awaiting-closeout' && ok || bad "R2: the summary names it awaiting-closeout ($(summary))"

# R3: one owed close-out still holds the key, whatever the RELAYED copy says.
reset
mkdir -p "$H/builds/pool-$P-TK-989-202610150900" "$H/builds/pool-$P-TK-989-202610151000"
echo "$PR1" > "$H/builds/pool-$P-TK-989-202610150900/RESULT"
: > "$H/builds/pool-$P-TK-989-202610150900/RELAYED"
echo "$PR1" > "$H/builds/pool-$P-TK-989-202610151000/RESULT"
run
grep -q 'TK-989' "$H/launches.log" 2>/dev/null && bad "R3: a non-relayed open dir must still hold the relaunch: $(cat "$H/launches.log")" || ok
summary | grep -q 'TK-989:awaiting-closeout' && ok || bad "R3: the summary names it awaiting-closeout ($(summary))"

# ══ C — closeout_overdue_note, called directly ══════════════════════════════
A="$T/a"; mkdir -p "$A/bin" "$A/builds"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/calls"\n' "$A" > "$A/bin/lane-alert.sh"
chmod +x "$A/bin/lane-alert.sh"
. "$DIR/bin/lib/closeout-overdue.sh" || { echo "setup: could not source closeout-overdue.sh"; exit 1; }
age() { touch -d "@$((NOW - $2))" "$1"; }
dres() { local d="$A/builds/$1"; mkdir -p "$d"; printf '%s\n' "$3" > "$d/RESULT"; age "$d/RESULT" "$2"; [ -z "${4:-}" ] || : > "$d/RELAYED"; }
dreset() { scratch_rm "$A/builds"; mkdir -p "$A/builds"; rm -f "$A/calls" "$A/bin/box-for.sh"; }
calls() { if [ -f "$A/calls" ]; then grep -c . "$A/calls"; else echo 0; fi; }

# C1: a RELAYED-only key, 2.5 h old: the hub does not own its close-out.
dreset
dres "pool-p-BH-1-202610150600" 9000 "$PR1" relayed
closeout_overdue_note "$A" p BH-1; RC=$?
[ "$RC" = 0 ] && ok || bad "C1: closeout_overdue_note must return 0 (got $RC)"
[ "$(calls)" = 0 ] && ok || bad "C1: THE BUG: a RELAYED-only key must send no warn, got: $(cat "$A/calls")"

# C2: the same dir without RELAYED is overdue here.
dreset
dres "pool-p-BH-1-202610150600" 9000 "$PR1"
closeout_overdue_note "$A" p BH-1
[ "$(calls)" = 1 ] && ok || bad "C2: expected one lane-alert call, got $(calls)"
case "$(cat "$A/calls" 2>/dev/null)" in "--id closeout-overdue:p:BH-1 --severity warn "*) ok ;; *) bad "C2: wrong alert id/severity: $(cat "$A/calls" 2>/dev/null)" ;; esac

# C3: age, oldest dir and count come from the owed dir only.
dreset
dres "pool-p-BH-1-202610150600" 9000 "$PR1" relayed
dres "pool-p-BH-1-202610150700" 3000 "REVIEW_BLOCKED tier 2"
closeout_overdue_note "$A" p BH-1
[ "$(calls)" = 1 ] && ok || bad "C3: expected one lane-alert call, got $(calls)"
C=$(cat "$A/calls" 2>/dev/null)
case "$C" in *"p BH-1 has waited 50m"*) ok ;; *) bad "C3: the age must come from the non-relayed dir: $C" ;; esac
case "$C" in *"pool-p-BH-1-202610150700"*"1 un-commented dir(s)"*) ok ;; *) bad "C3: the dir and count must skip the RELAYED copy: $C" ;; esac

# C4: the warn names the owning box when bin/box-for.sh answers, and not otherwise.
dreset
dres "pool-p-BH-1-202610150600" 9000 "$PR1"
printf '#!/bin/bash\n[ "$1" = p ] && echo box-fixture-1\n' > "$A/bin/box-for.sh"; chmod +x "$A/bin/box-for.sh"
closeout_overdue_note "$A" p BH-1
case "$(cat "$A/calls" 2>/dev/null)" in *"close-out owner: box-fixture-1"*) ok ;; *) bad "C4: the warn must name the owning box: $(cat "$A/calls" 2>/dev/null)" ;; esac
dreset
dres "pool-p-BH-1-202610150600" 9000 "$PR1"
closeout_overdue_note "$A" p BH-1; RC=$?
[ "$RC" = 0 ] && [ "$(calls)" = 1 ] && ok || bad "C4: no box-for.sh still warns once, rc 0 (rc $RC, calls $(calls))"
case "$(cat "$A/calls" 2>/dev/null)" in *"close-out owner"*) bad "C4: no box-for.sh, no owner text: $(cat "$A/calls")" ;; *) ok ;; esac
dreset
dres "pool-p-BH-1-202610150600" 9000 "$PR1"
printf '#!/bin/bash\nexit 1\n' > "$A/bin/box-for.sh"; chmod +x "$A/bin/box-for.sh"
closeout_overdue_note "$A" p BH-1
case "$(cat "$A/calls" 2>/dev/null)" in *"close-out owner"*) bad "C4: a failed lookup adds no owner text: $(cat "$A/calls")" ;; *) ok ;; esac
dreset
dres "pool-p-BH-1-202610150600" 9000 "$PR1"
printf '#!/bin/bash\necho local\n' > "$A/bin/box-for.sh"; chmod +x "$A/bin/box-for.sh"
closeout_overdue_note "$A" p BH-1
case "$(cat "$A/calls" 2>/dev/null)" in *"close-out owner: local (the hub)"*) ok ;; *) bad "C4: local prints as 'local (the hub)': $(cat "$A/calls" 2>/dev/null)" ;; esac

echo "closeout-relayed.bh-6956: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
