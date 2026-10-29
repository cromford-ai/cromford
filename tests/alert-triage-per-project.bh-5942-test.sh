#!/bin/bash
# tests/alert-triage-per-project.bh-5942-test.sh — BH-5942 (C3): alert-triage
# on the per-project runner. The cron tick (no argument) collects once, routes
# every collected line by its beat `project` into
# state/alert-triage/<project>/inbox.tsv, and dispatches one run per project.
# A project run triages only its own inbox and its own deferral spool.
#
# Runs the REAL bin/alert-triage.sh end to end: dispatch -> the real
# bin/project-lane-run.sh -> the lane with a project argument. Stubbed:
# agent-call.sh (records the prompt and the run's env, may block on a file),
# ssh, curl (the jobs worker, only in T7), gh-token.sh (the App token), the
# orientation map. The clock is pinned through TRIAGE_NOW.
#
#   T1  routing: a hub quarantine with lines for projfix-a, projfix-b and none
#       lands in each project's inbox; the no-project line and the adversarial
#       negatives (projfix-a-old, " projfix-a", project null, a torn payload)
#       land in cromford's inbox; the word projfix-a in the TEXT of a
#       projfix-b line goes to projfix-b; the quarantine is empty; the legacy
#       shared deferral spool is routed too and left empty.
#   T2  write first, then forget: an inbox that cannot be appended to keeps its
#       lines in the dispatch WORK file and the log says so; the next dispatch
#       delivers them.
#   T3  each run's prompt holds only its own project's alert text.
#   T4  two projects in parallel: run B ends its agent call while run A blocks
#       in its own; A holds only locks/alert-triage-projfix-a.lock and the old
#       global locks/alert-triage.lock is not held.
#   T5  per-project families file, seeded by copy from the shared file; the
#       shared file is unchanged.
#   T6  each run's ACCOUNT_PROJECT_FOR_LANE is alert-triage=<p> and its GH_TOKEN
#       is its own App token, after env/global.env set another one.
#   T7  a claimed row re-offered by the lease while its line is still queued
#       (inbox, deferral spool or a run's work file) is not queued twice, and
#       the project run triages it once.
#   T8  TRIAGE_MAX_FAMILIES applies per project run and the deferral goes to the
#       project's own spool; the tick line names the project.
#   T9  STEP 0's shared pr-state cache lock: a wait that fails skips STEP 0 for
#       this run with one log line, and the lines are still triaged.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/alert-triage-per-project.bh-5942-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

NOW=1790000000
H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$T/fakebin" "$T/calls"
for L in bin/alert-triage.sh bin/lib/triage-inbox.sh bin/project-lane-run.sh bin/fleet-conf.sh bin/triage-spool-retire.sh \
         bin/jobs-client.sh bin/lib/gh-app-auth.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
# The lane's own hub GRAB names /root/harness literally (it is the same string
# it sends over ssh). Repoint it, so this suite drains ITS quarantine.
sed "s|/root/harness|$H|g" "$DIR/bin/alert-triage.sh" > "$H/bin/alert-triage.sh"
cp "$DIR/bin/alert_family.py" "$H/bin/alert_family.py"
chmod +x "$H/bin/"*.sh
printf '#!/bin/sh\necho "=== HARNESS ORIENTATION (fixture)"\n' > "$H/bin/triage-map.sh"; chmod +x "$H/bin/triage-map.sh"
touch "$H/flags/triage-registry-off" "$H/flags/triage-close-off"

export HARNESS="$H" FLEET_CONF="$H/fleet.conf" JOBS_URL="" CONSOLE_URL="" LANE_GATE_DISABLE=0
export GH_TOKEN="tok-fixture-default" TRIAGE_NOW="$NOW" LLM_LANE_DISPATCH_SPREAD_SECS=0
export CALLDIR="$T/calls" PATH="$T/fakebin:$PATH"
cat > "$H/fleet.conf" <<'EOF'
projfix-a o/projfix-a - - 2 box-a 192.0.2.1
projfix-b o/projfix-b - - 2 box-b 192.0.2.2
cromford o/cromford - - 2 box-h 192.0.2.3
EOF
printf 'GH_TOKEN=tok-fixture-env\n' > "$H/env/global.env"
: > "$H/env/github-app.env"
printf '#!/bin/bash\nprintf "ghs_fixture_%%s" "$(printf "%%s" "$1" | tr / _)"\n' > "$H/bin/gh-token.sh"
chmod +x "$H/bin/gh-token.sh"

# --- stubs -------------------------------------------------------------------
printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/ssh"; chmod +x "$T/fakebin/ssh"
# curl: the jobs worker for T7 only. The claim answers $T/claim.json; anything
# else is a 404. With JOBS_URL empty nothing reaches it.
{ echo '#!/bin/bash'; echo "FIX=$T"; cat <<'CURLEOF'
URL="${!#}"; METHOD=GET
while [ $# -gt 0 ]; do case "$1" in -X) METHOD="$2"; shift 2 ;; -H|-d|--data-binary) shift 2 ;; *) shift ;; esac; done
case "$METHOD $URL" in
  "POST "*jobs.invalid/api/alerts/claim) printf '%s\n200\n' "$(cat "$FIX/claim.json" 2>/dev/null || echo '{"alerts":[]}')" ;;
  *jobs.invalid*) printf '{"error":"not found"}\n404\n' ;;
  *) exit 7 ;;
esac
CURLEOF
} > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

# agent-call.sh <stage> <lane> <model> <turns> <outfile> <prompt>: one record
# dir per project (read from the account map the run exported), with the
# prompt, the env this ticket owns and the lock files the run has open.
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
A="\${ACCOUNT_PROJECT_FOR_LANE:-none}"; P="\${A#*=}"
D="$T/calls/\$P"; mkdir -p "\$D"
N=\$(ls "\$D" | grep -c '^prompt-')
printf '%s' "\$6" > "\$D/prompt-\$N.txt"
printf '%s\n' "\$A" > "\$D/acct"; printf '%s\n' "\${GH_TOKEN:-none}" > "\$D/token"
for f in /proc/\$\$/fd/*; do readlink "\$f"; done 2>/dev/null | grep '/locks/' | sed 's|.*/||' | sort -u > "\$D/locks"
echo started >> "\$D/started"
if [ -e "$T/hold-\$P" ]; then for i in \$(seq 1 300); do [ -e "$T/release" ] && break; sleep 0.2; done; fi
echo "handled=1 escalated=0 noise=0" > "\$5"
echo done >> "\$D/done"
EOF
chmod +x "$H/bin/agent-call.sh"

WAITFOR() { local i; for i in $(seq 1 150); do eval "$1" && return 0; sleep 0.2; done; return 1; }
Q="$H/state/alert-quarantine.jsonl"
S="$H/state/alert-triage"
LOG="$H/logs/alert-triage.log"
q() { # q <project-json-value> <marker> [akey] — one quarantine line, real format (epoch<TAB>beat-json)
  printf '%s\t{"kind":"fleet_alert","project":%s,"akey":"%s","line":"the %s subsystem is unhappy"}\n' \
    "$NOW" "$1" "${3:-akey-$2}" "$2" >> "$Q"; }
inbox() { cat "$S/$1/inbox.tsv" 2>/dev/null; }
has() { grep -q -F -- "$2" <<<"$(inbox "$1")"; }
nlines() { local n; n=$(grep -c . "$1" 2>/dev/null); printf '%s' "${n:-0}"; }
prompts() { cat "$T/calls/$1"/prompt-*.txt 2>/dev/null; }
ndone() { nlines "$T/calls/$1/done"; }
fresh() { scratch_rm "$S"; scratch_rm "$T/calls"; rm -f "$T"/hold-* "$T/release" "$H/state/alert-triage-deferred.tsv" "$H/state/alert-families.json"
          mkdir -p "$T/calls"; : > "$Q"; : > "$LOG"; : > "$H/logs/alert-triage-cron.log"; }
dispatch() { bash "$H/bin/alert-triage.sh" >>"$T/dispatch.out" 2>&1; }
HELD_FDS=""
hold_all() { # take every project's run lock, so a dispatched run starts nothing
  exec 41>"$H/locks/alert-triage-projfix-a.lock" 42>"$H/locks/alert-triage-projfix-b.lock" \
       43>"$H/locks/alert-triage-cromford.lock"
  flock -n 41 && flock -n 42 && flock -n 43 || bad "setup: could not take the project locks"
  HELD_FDS=1; }
release_all() { [ -n "$HELD_FDS" ] && exec 41>&- 42>&- 43>&-; HELD_FDS=""; }
idle() { local p; for p in projfix-a projfix-b cromford; do flock -n "$H/locks/alert-triage-$p.lock" true || return 1; done; }
nheld() { local n; n=$(grep -c 'is still live' "$H/logs/alert-triage-cron.log" 2>/dev/null); printf '%s' "${n:-0}"; }

# ============================================================================
# T1 — the dispatch routes every collected line to its owner's inbox.
# ============================================================================
fresh; hold_all
q '"projfix-a"' t1a
q '"projfix-b"' t1b
q '"projfix-b"' t1btext akey-t1btext
sed -i '$ s/the t1btext subsystem/projfix-a is named here but the t1btext subsystem/' "$Q"
q '""' t1none
q '"projfix-a-old"' t1old
q '" projfix-a"' t1space
q 'null' t1null
printf '%s\t{"kind":"fleet_alert","project":"projfix-a","line":"the t1torn subsystem\n' "$NOW" >> "$Q"
printf 'hub\t%s\t{"kind":"fleet_alert","project":"projfix-b","akey":"akey-t1legacy","line":"the t1legacy subsystem is unhappy"}\n' "$NOW" \
  > "$H/state/alert-triage-deferred.tsv"
dispatch; RC=$?
[ "$RC" = 0 ] && ok || bad "T1: dispatch exits 0 (rc=$RC; $(tail -3 "$T/dispatch.out"))"
WAITFOR '[ "$(nheld)" -ge 3 ]' || bad "T1: setup: the three dispatched runs did not report the held lock ($(cat "$H/logs/alert-triage-cron.log"))"
release_all
has projfix-a t1a && ok || bad "T1: projfix-a's line is in projfix-a's inbox ($(inbox projfix-a))"
[ "$(nlines "$S/projfix-a/inbox.tsv")" = 1 ] && ok || bad "T1: projfix-a's inbox holds only its own line ($(inbox projfix-a))"
has projfix-b t1b && has projfix-b t1btext && has projfix-b t1legacy && ok \
  || bad "T1: projfix-b's inbox holds its lines, the text-mention line and the legacy spool line ($(inbox projfix-b))"
[ "$(nlines "$S/projfix-b/inbox.tsv")" = 3 ] && ok || bad "T1: projfix-b's inbox holds exactly 3 lines ($(inbox projfix-b))"
for m in t1none t1old t1space t1null t1torn; do
  has cromford "$m" && ok || bad "T1: the $m line goes to the home project cromford ($(inbox cromford))"
done
[ "$(nlines "$S/cromford/inbox.tsv")" = 5 ] && ok || bad "T1: cromford's inbox holds exactly the 5 home lines ($(inbox cromford))"
grep -q '^hub	' "$S/projfix-a/inbox.tsv" 2>/dev/null && ok || bad "T1: an inbox line keeps the WORK format source<TAB>epoch<TAB>beat ($(inbox projfix-a))"
[ -e "$Q" ] && [ ! -s "$Q" ] && ok || bad "T1: the hub quarantine is drained ($(cat "$Q"))"
[ -e "$H/state/alert-triage-deferred.tsv" ] && [ ! -s "$H/state/alert-triage-deferred.tsv" ] && ok \
  || bad "T1: the legacy shared spool is drained and still exists"
[ ! -s "$S/dispatch-work.tsv" ] && ok || bad "T1: the dispatch WORK file is gone after every append landed"
[ -z "$(ls "$T/calls")" ] && ok || bad "T1: the dispatch itself buys no session ($(ls "$T/calls"))"
grep -q 'alert-triage dispatch: started 3 project run(s)' "$T/dispatch.out" && ok \
  || bad "T1: the dispatch line names 3 runs ($(cat "$T/dispatch.out"))"

# ============================================================================
# T2 — an append that fails keeps its lines in WORK, and the log says so.
# ============================================================================
fresh; hold_all
mkdir -p "$S/projfix-a/inbox.tsv"          # a directory: no append can land (root ignores modes)
q '"projfix-a"' t2a
q '"projfix-b"' t2b
dispatch
WAITFOR '[ "$(nheld)" -ge 3 ]' || bad "T2: setup: runs did not report the held lock"
release_all
grep -q -F 't2a subsystem' "$S/dispatch-work.tsv" 2>/dev/null && ok \
  || bad "T2: the line whose append failed is still in the WORK file ($(cat "$S/dispatch-work.tsv" 2>/dev/null))"
! grep -q -F 't2b subsystem' "$S/dispatch-work.tsv" 2>/dev/null && has projfix-b t2b && ok \
  || bad "T2: the line that landed is in its inbox and not kept in WORK"
grep -q 'could not append' "$LOG" && grep -q 'dispatch-work.tsv' "$LOG" && ok \
  || bad "T2: the lane log names the failed append and where the lines are ($(grep -i append "$LOG"))"
[ ! -s "$Q" ] && ok || bad "T2: the quarantine was still drained (its lines are in WORK)"
rmdir "$S/projfix-a/inbox.tsv"; hold_all; : > "$H/logs/alert-triage-cron.log"
dispatch
WAITFOR '[ "$(nheld)" -ge 3 ]' || bad "T2: setup: runs did not report the held lock (2nd dispatch)"
release_all
has projfix-a t2a && [ ! -s "$S/dispatch-work.tsv" ] && ok \
  || bad "T2: the next dispatch delivers the kept lines and empties WORK ($(inbox projfix-a))"

# ============================================================================
# T3 + T5 + T6 — three runs, each reads only its own lines, writes only its own
# families file, and runs on its own account word and App token.
# ============================================================================
fresh
echo '{"aaaaaaaaaaaa": 1789990000}' > "$H/state/alert-families.json"
cp "$H/state/alert-families.json" "$T/fam.before"
q '"projfix-a"' t3a
q '"projfix-b"' t3b
q '""' t3none
dispatch
WAITFOR '[ "$(ndone projfix-a)" -ge 1 ] && [ "$(ndone projfix-b)" -ge 1 ] && [ "$(ndone cromford)" -ge 1 ]' \
  && ok || bad "T3: all three runs bought their session (calls: $(ls "$T/calls"); cron: $(tail -5 "$H/logs/alert-triage-cron.log"))"
PA=$(prompts projfix-a); PB=$(prompts projfix-b); PH=$(prompts cromford)
grep -q 't3a subsystem' <<<"$PA" && ! grep -q -e 't3b subsystem' -e 't3none subsystem' <<<"$PA" && ok \
  || bad "T3: run projfix-a's prompt holds only projfix-a's alert text"
grep -q 't3b subsystem' <<<"$PB" && ! grep -q -e 't3a subsystem' -e 't3none subsystem' <<<"$PB" && ok \
  || bad "T3: run projfix-b's prompt holds only projfix-b's alert text"
grep -q 't3none subsystem' <<<"$PH" && ! grep -q -e 't3a subsystem' -e 't3b subsystem' <<<"$PH" && ok \
  || bad "T3: run cromford's prompt holds only the unattributed alert"
[ -z "$(ls "$T/calls/none" 2>/dev/null)" ] && ok || bad "T6: no session ran without the account map"
for p in projfix-a projfix-b cromford; do
  [ "$(cat "$T/calls/$p/acct" 2>/dev/null)" = "alert-triage=$p" ] && ok \
    || bad "T6: run $p's ACCOUNT_PROJECT_FOR_LANE is alert-triage=$p (got $(cat "$T/calls/$p/acct" 2>/dev/null))"
  [ "$(cat "$T/calls/$p/token" 2>/dev/null)" = "ghs_fixture_o_$p" ] && ok \
    || bad "T6: run $p's GH_TOKEN is its own App token (got $(cat "$T/calls/$p/token" 2>/dev/null))"
done
WAITFOR idle || bad "T5: setup: the three runs did not end"
cmp -s "$H/state/alert-families.json" "$T/fam.before" && ok || bad "T5: the shared families file is unchanged ($(cat "$H/state/alert-families.json"))"
fkeys() { jq -r 'keys[]' "$S/$1/alert-families.json" 2>/dev/null | grep -v '^aaaaaaaaaaaa$' | sort; }
[ "$(jq -r '.aaaaaaaaaaaa' "$S/projfix-a/alert-families.json" 2>/dev/null)" = 1789990000 ] && ok \
  || bad "T5: projfix-a's families file is seeded by copy from the shared file ($(cat "$S/projfix-a/alert-families.json" 2>/dev/null))"
FA=$(fkeys projfix-a); FB=$(fkeys projfix-b)
[ "$(grep -c . <<<"$FA")" = 1 ] && [ "$(grep -c . <<<"$FB")" = 1 ] && [ "$FA" != "$FB" ] && ok \
  || bad "T5: each project's families file holds only its own new family (a: $FA; b: $FB)"
! grep -q -x -F "$FA" <<<"$FB" && ok || bad "T5: projfix-a's family is not in projfix-b's file"
for p in projfix-a projfix-b cromford; do
  [ ! -s "$S/$p/inbox.tsv" ] && [ ! -e "$S/$p/work.tsv" ] && ok || bad "T3: run $p drained its inbox and removed its work file"
done

# ============================================================================
# T4 — two projects in parallel, each holding only its own lock.
# ============================================================================
fresh
q '"projfix-a"' t4a
q '"projfix-b"' t4b
touch "$T/hold-projfix-a"
dispatch
WAITFOR '[ "$(ndone projfix-b)" -ge 1 ]' && ok || bad "T4: run projfix-b ends its agent call while projfix-a blocks"
# The two runs start in parallel, so run B can end before run A has entered
# its agent call (the nightly 2026-10-29: started=0 done=0). Wait for A to be
# inside the call too; A stays there until $T/release, so done=0 still proves
# that B ended while A blocks.
WAITFOR '[ "$(nlines "$T/calls/projfix-a/started")" -ge 1 ]'
[ "$(nlines "$T/calls/projfix-a/started")" = 1 ] && [ "$(ndone projfix-a)" = 0 ] && ok \
  || bad "T4: run projfix-a is inside its own agent call (started=$(nlines "$T/calls/projfix-a/started") done=$(ndone projfix-a))"
[ "$(cat "$T/calls/projfix-a/locks" 2>/dev/null)" = "alert-triage-projfix-a.lock" ] && ok \
  || bad "T4: run projfix-a holds only locks/alert-triage-projfix-a.lock (open: $(tr '\n' ' ' < "$T/calls/projfix-a/locks" 2>/dev/null))"
[ "$(cat "$T/calls/projfix-b/locks" 2>/dev/null)" = "alert-triage-projfix-b.lock" ] && ok \
  || bad "T4: run projfix-b holds only locks/alert-triage-projfix-b.lock (open: $(tr '\n' ' ' < "$T/calls/projfix-b/locks" 2>/dev/null))"
! flock -n "$H/locks/alert-triage-projfix-a.lock" true && ok || bad "T4: projfix-a's lock is held while its run blocks"
flock -n "$H/locks/alert-triage.lock" true && ok || bad "T4: the old global locks/alert-triage.lock is not held"
touch "$T/release"
WAITFOR '[ "$(ndone projfix-a)" -ge 1 ]' && ok || bad "T4: run projfix-a ends after release"
WAITFOR idle || bad "T4: setup: the runs did not end"

# ============================================================================
# T7 — a re-offered claimed row is not queued twice and is triaged once.
# ============================================================================
fresh
touch "$H/flags/alerts-db"
printf 'JOBS_URL=https://jobs.invalid\nHARNESS_SECRET=fixture-secret\nJOBS_RETRIES=0\nGH_TOKEN=tok-fixture-env\n' > "$H/env/global.env"
row() { # row <id> <project> <marker>
  printf '{"id":"%s","family":"f","box":"box-a","project":"%s","state":"quarantined","count":1,"first_seen":"2026-09-21T12:00:00Z","last_seen":"2026-09-21T12:00:00Z","claimed_by":"alert-triage@hub","claimed_at":"2026-09-21T12:00:00Z","notified_at":"","severity":"warn","line":"the %s subsystem is unhappy"}' "$1" "$2" "$3"; }
printf '{"alerts":[%s,%s,%s,%s]}\n' "$(row fx-r1 projfix-a t7r1)" "$(row fx-r2 projfix-b t7r2)" \
  "$(row fx-r3 projfix-a t7r3)" "$(row fx-r4 projfix-b t7r4)" > "$T/claim.json"
mkdir -p "$S/projfix-a" "$S/projfix-b"
# fx-r3 is in projfix-a's deferral spool and fx-r2 in a projfix-b run's work
# file: both are still queued, so the re-offer must not queue them again.
printf 'box-a\t%s\t{"kind":"fleet_alert","project":"projfix-a","akey":"orclane:fx-r3","alertid":"fx-r3","line":"the t7r3 subsystem is unhappy","dbrow":true}\n' "$NOW" > "$S/projfix-a/deferred.tsv"
printf 'box-a\t%s\t{"kind":"fleet_alert","project":"projfix-b","akey":"orclane:fx-r2","alertid":"fx-r2","line":"the t7r2 subsystem is unhappy","dbrow":true}\n' "$NOW" > "$S/projfix-b/work.tsv"
hold_all; dispatch
WAITFOR '[ "$(nheld)" -ge 3 ]' || bad "T7: setup: runs did not report the held lock"
: > "$H/logs/alert-triage-cron.log"; dispatch
WAITFOR '[ "$(nheld)" -ge 3 ]' || bad "T7: setup: runs did not report the held lock (2nd dispatch)"
release_all
[ "$(grep -c -F '"akey":"orclane:fx-r1"' "$S/projfix-a/inbox.tsv" 2>/dev/null)" = 1 ] && ok \
  || bad "T7: the row offered twice is queued once ($(inbox projfix-a))"
! grep -q -F 'orclane:fx-r3' "$S/projfix-a/inbox.tsv" 2>/dev/null && ok || bad "T7: a row in the deferral spool is not queued again"
! grep -q -F 'orclane:fx-r2' "$S/projfix-b/inbox.tsv" 2>/dev/null && ok || bad "T7: a row in a run's work file is not queued again"
[ "$(grep -c -F 'orclane:fx-r4' "$S/projfix-b/inbox.tsv" 2>/dev/null)" = 1 ] && ok || bad "T7: a new row is queued once ($(inbox projfix-b))"
bash "$H/bin/alert-triage.sh" projfix-a >/dev/null 2>&1
[ "$(prompts projfix-a | grep -c 't7r1 subsystem')" = 1 ] && ok \
  || bad "T7: the project run triages the re-offered row once ($(prompts projfix-a | grep -c 't7r1 subsystem'))"
prompts projfix-a | grep -q 't7r3 subsystem' && ok || bad "T7: the project run triages its deferral spool"
rm -f "$H/flags/alerts-db"; printf 'GH_TOKEN=tok-fixture-env\n' > "$H/env/global.env"

# ============================================================================
# T8 — the family cap per project run; the deferral goes to the project spool.
# ============================================================================
fresh; hold_all
q '"projfix-a"' t8one; q '"projfix-a"' t8two; q '"projfix-b"' t8three
dispatch
WAITFOR '[ "$(nheld)" -ge 3 ]' || bad "T8: setup: runs did not report the held lock"
release_all
TRIAGE_MAX_FAMILIES=1 bash "$H/bin/alert-triage.sh" projfix-a >/dev/null 2>&1
TRIAGE_MAX_FAMILIES=1 bash "$H/bin/alert-triage.sh" projfix-b >/dev/null 2>&1
[ "$(ls "$T/calls/projfix-a" | grep -c '^prompt-')" = 1 ] && [ "$(ls "$T/calls/projfix-b" | grep -c '^prompt-')" = 1 ] && ok \
  || bad "T8: TRIAGE_MAX_FAMILIES=1 gives each project run one session"
[ "$(nlines "$S/projfix-a/deferred.tsv")" = 1 ] && ok || bad "T8: projfix-a's deferred family is in its own spool ($(cat "$S/projfix-a/deferred.tsv" 2>/dev/null))"
[ ! -s "$H/state/alert-triage-deferred.tsv" ] && ok || bad "T8: nothing is deferred to the legacy shared spool"
grep -q 'across 1 famil(ies) — one session each.*project=projfix-a' "$LOG" && ok \
  || bad "T8: the tick line names the project ($(grep 'one session each' "$LOG"))"

# ============================================================================
# T9 — the shared pr-state cache lock: a failed wait skips STEP 0, loses nothing.
# ============================================================================
fresh; hold_all
q '"projfix-a"' t9a
dispatch
WAITFOR '[ "$(nheld)" -ge 3 ]' || bad "T9: setup: runs did not report the held lock"
release_all
exec 44>"$H/locks/triage-prstate.lock"; flock -n 44 || bad "T9: setup: could not take the pr-state lock"
bash "$H/bin/alert-triage.sh" projfix-a >/dev/null 2>&1
exec 44>&-
grep -q 'STEP 0 skipped' "$LOG" && ok || bad "T9: a failed lock wait is one log line ($(grep 'STEP 0' "$LOG"))"
prompts projfix-a | grep -q 't9a subsystem' && ok || bad "T9: the line is still triaged"

echo "alert-triage-per-project: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
