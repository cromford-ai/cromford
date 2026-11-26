#!/bin/bash
# tests/fetch-log-test.sh — self-contained assertions for bin/fetch-log.sh.
# The whole point of this script is that a console user picks WHICH log to read,
# so the whitelist is the security boundary: anything outside it must be refused
# without ever touching a path built from the request.
# Run from anywhere: tests/fetch-log-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export HARNESS="$T"
mkdir -p "$T/logs"

cat > "$T/fleet.conf" <<'EOF'
# fixture registry
alpha-os  Org/alpha  https://alpha.example  /api/board  2 box-alpha
beta-os   Org/beta   https://beta.example   /api/board  4 box-beta
EOF
export FLEET_CONF="$T/fleet.conf"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
p()   { "$DIR/bin/fetch-log.sh" --path "$1" "${2:-}" 2>/dev/null; }
j()   { "$DIR/bin/fetch-log.sh" "$1" "$2" "$3" 2>/dev/null; }

# ---------- 1. whitelist mapping: every valid `which` resolves ----------
[ "$(p triage alpha-os)" = "$T/logs/alpha-os.log" ]        && ok || bad "triage -> logs/<project>.log"
[ "$(p alerts alpha-os)" = "$T/logs/ALERTS.log" ]          && ok || bad "alerts -> logs/ALERTS.log"
[ "$(p pipeline hub)" = "$T/logs/pipeline-health.log" ]    && ok || bad "pipeline -> logs/pipeline-health.log"
[ "$(p cost hub)" = "$T/logs/cost.csv" ]                   && ok || bad "cost -> logs/cost.csv"
[ "$(p decisions hub)" = "$T/logs/decisions.log" ]         && ok || bad "decisions -> logs/decisions.log"

# The project is checked for EVERY which, not just the one that names a file:
# it also picks the box the request forwards to, and it lands in the journal.
for W in alerts pipeline cost decisions triage; do
  OUT=$(p "$W" not-a-project); RC=$?
  [ "$RC" -ne 0 ] && [ -z "$OUT" ] || bad "which '$W' must refuse an unregistered project (rc=$RC)"
done
ok
# fleet-conf.sh's own row lookup is a REGEX, so a dotted near-match would resolve
# there and box-for.sh would route to that box. Exact matching kills it here.
[ -z "$(p alerts alpha.os)" ] && ok || bad "'alpha.os' must not match the alpha-os row"
# "hub" is the one non-project caller — the hub owns no project of its own but
# holds decisions.log, the cost roll-up and pipeline-health.
OUT=$(p triage hub); RC=$?
[ "$RC" -ne 0 ] && [ -z "$OUT" ] || bad "triage has no meaning for hub (rc=$RC out=$OUT)"

# ---------- 2. anything else is refused, and refused SILENTLY ----------
for W in '' shadow ALERTS ../../etc/passwd 'alerts;id' 'cost cost' 'triage/../..'; do
  OUT=$(p "$W" alpha-os); RC=$?
  [ "$RC" -ne 0 ] && [ -z "$OUT" ] || bad "which '$W' should be rejected (rc=$RC out=$OUT)"
done
ok

# A path-traversal PROJECT can never escape logs/ either: triage validates the
# project against fleet.conf rather than interpolating whatever arrived.
for BADP in '../../etc/passwd' 'alpha-os/../..' 'not-a-project' ''; do
  OUT=$(p triage "$BADP"); RC=$?
  [ "$RC" -ne 0 ] && [ -z "$OUT" ] || bad "project '$BADP' should be rejected (rc=$RC out=$OUT)"
done
ok
# ...while a registered one still resolves (the guard is not just "refuse all").
[ "$(p triage beta-os)" = "$T/logs/beta-os.log" ] && ok || bad "registered project still resolves"

# ---------- 3. truncation flag ----------
# A file under the cap is whole; one over it is tailed and says so.
# BH-10102: the cap is the FETCH_LOG_TAIL_BYTES knob (5 MiB by default); this
# section pins the same window edge at 16000 through the knob.
export FETCH_LOG_TAIL_BYTES=16000
printf 'small\n' > "$T/logs/alpha-os.log"
OUT=$(j alpha-os triage cmd-1)
[ "$(jq -r .truncated <<<"$OUT")" = false ] && [ "$(jq -r .content <<<"$OUT")" = "small" ] \
  && ok || bad "under-cap file should be whole and truncated=false (got: $OUT)"

head -c 20000 /dev/zero | tr '\0' 'x' > "$T/logs/alpha-os.log"
OUT=$(j alpha-os triage cmd-2)
[ "$(jq -r .truncated <<<"$OUT")" = true ] \
  && [ "$(jq -r .content <<<"$OUT" | wc -c)" -le 16001 ] \
  && ok || bad "over-cap file should be tailed with truncated=true (len=$(jq -r .content <<<"$OUT" | wc -c))"

# Exactly at the cap is NOT truncated — off-by-one here would cry wolf forever.
head -c 16000 /dev/zero | tr '\0' 'y' > "$T/logs/alpha-os.log"
OUT=$(j alpha-os triage cmd-3)
[ "$(jq -r .truncated <<<"$OUT")" = false ] && ok || bad "exactly-at-cap should be truncated=false"
unset FETCH_LOG_TAIL_BYTES

# ---------- 4. JSON encoding of nasty content ----------
# Quotes, newlines, backslashes and a lone brace are what a real log looks like;
# any of them concatenated into JSON by hand would produce an unparseable beat.
printf 'he said "hi"\\path\ttab\nsecond } line\n' > "$T/logs/ALERTS.log"
OUT=$(j hub alerts cmd-4)
jq -e . >/dev/null 2>&1 <<<"$OUT" && ok || bad "output must be parseable JSON (got: $OUT)"
[ "$(jq -r .content <<<"$OUT")" = "$(cat "$T/logs/ALERTS.log")" ] \
  && ok || bad "content must round-trip byte-for-byte"

# ---------- 5. beat envelope ----------
OUT=$(j alpha-os cost cmd-5)
[ "$(jq -r .kind <<<"$OUT")" = log_tail ]     && ok || bad "kind should be log_tail"
[ "$(jq -r .rkey <<<"$OUT")" = "log:cmd-5" ]  && ok || bad "rkey should be log:<command_id>"
[ "$(jq -r .command_id <<<"$OUT")" = cmd-5 ]  && ok || bad "command_id echoed"
[ "$(jq -r .which <<<"$OUT")" = cost ]        && ok || bad "which echoed"
[ "$(jq -r .project <<<"$OUT")" = alpha-os ]  && ok || bad "project echoed"
jq -e '.ts | test("^[0-9]{4}-")' >/dev/null <<<"$OUT" && ok || bad "ts should be an ISO stamp"

# ---------- 6. a log that does not exist yet is empty, not an error ----------
# (cost.csv on a box that has never run a build; pipeline-health.log before the
# first finding.) A dead pane must be honestly empty, never a failed command.
rm -f "$T/logs/cost.csv"
OUT=$(j alpha-os cost cmd-6); RC=$?
[ "$RC" -eq 0 ] && [ "$(jq -r .content <<<"$OUT")" = "" ] \
  && [ "$(jq -r .missing <<<"$OUT")" = true ] \
  && [ "$(jq -r .truncated <<<"$OUT")" = false ] \
  && ok || bad "missing file should be empty+missing:true, rc 0 (rc=$RC out=$OUT)"

# ---------- 6b. --error: a terminal beat for a request that cannot be served --
# The console pane is keyed on log:<cid>. Silence on a refusal or a dead box is
# indistinguishable from a fetch still in flight, so both must still answer.
OUT=$("$DIR/bin/fetch-log.sh" --error alpha-os triage cmd-e1 refused 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && jq -e . >/dev/null 2>&1 <<<"$OUT" && ok || bad "--error must emit JSON, rc 0 (rc=$RC)"
[ "$(jq -r .kind <<<"$OUT")" = log_tail ] && [ "$(jq -r .rkey <<<"$OUT")" = "log:cmd-e1" ] \
  && ok || bad "--error keeps the pane's kind and rkey"
[ "$(jq -r .error <<<"$OUT")" = refused ] && [ "$(jq -r .content <<<"$OUT")" = "" ] \
  && [ "$(jq -r .missing <<<"$OUT")" = true ] \
  && ok || bad "--error carries error, empty content, missing:true (got: $OUT)"
# It must answer even for input the whitelist rejects — that IS the refused case.
OUT=$("$DIR/bin/fetch-log.sh" --error '../../etc' 'not-a-which' cmd-e2 refused 2>/dev/null)
jq -e . >/dev/null 2>&1 <<<"$OUT" && [ "$(jq -r .rkey <<<"$OUT")" = "log:cmd-e2" ] \
  && ok || bad "--error must not itself validate (got: $OUT)"

# ---------- 6c. journal lines cannot be forged ----------
# project/which arrive from the console; a newline in one would let a caller
# write arbitrary extra journal lines and hide what really happened.
: > "$T/logs/console-commands.log"
"$DIR/bin/fetch-log.sh" "$(printf 'alpha-os\n2026-01-01 00:00:00Z FORGED LINE')" alerts cmd-f1 >/dev/null 2>&1
"$DIR/bin/fetch-log.sh" alpha-os "$(printf 'alerts\nANOTHER FORGERY')" cmd-f2 >/dev/null 2>&1
# The property is line integrity: two requests, two lines, and EVERY line still
# starts with a real stamp + command name. (The injected text may survive inside
# a field with its whitespace stripped — harmless; a forged LINE is not.)
[ "$(grep -c . "$T/logs/console-commands.log")" -eq 2 ] \
  && ok || bad "two requests should write exactly two journal lines (got $(grep -c . "$T/logs/console-commands.log"))"
if grep -qvE '^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}Z fetch_log id=' "$T/logs/console-commands.log"; then
  bad "a journal line was forged: $(cat "$T/logs/console-commands.log")"
else ok; fi

# ============================ bin/fetch-artifact.sh ==========================
# Same fire-and-poll shape as fetch_log, but the file lives in a BUILD DIR whose
# name is built from the project and the ticket key — so the key is a second
# untrusted path component and gets its own guard.
a()  { "$DIR/bin/fetch-artifact.sh" --file "$1" 2>/dev/null; }
ap() { "$DIR/bin/fetch-artifact.sh" --path "$1" "$2" "$3" 2>/dev/null; }
aj() { "$DIR/bin/fetch-artifact.sh" "$1" "$2" "$3" "$4" 2>/dev/null; }

# ---------- 7. artifact whitelist ----------
[ "$(a plan)" = plan.md ]              && ok || bad "plan -> plan.md"
[ "$(a review)" = review.md ]          && ok || bad "review -> review.md"
[ "$(a security)" = security-review.md ] && ok || bad "security -> security-review.md"
[ "$(a qa)" = qa.md ]                  && ok || bad "qa -> qa.md"
[ "$(a pipeline)" = pipeline.log ]     && ok || bad "pipeline -> pipeline.log"
[ "$(a cost)" = cost.csv ]             && ok || bad "cost -> cost.csv"
[ "$(a context)" = context.json ]      && ok || bad "context -> context.json"
for W in '' triage alerts decisions plan.md ../../etc/passwd 'plan;id'; do
  OUT=$(a "$W"); RC=$?
  [ "$RC" -ne 0 ] && [ -z "$OUT" ] || bad "artifact which '$W' should be rejected (rc=$RC out=$OUT)"
done
ok

# ---------- 8. key sanitisation ----------
# The key reaches a glob and an ssh command line, so it is REJECTED outright
# rather than stripped — a key silently rewritten into a different key would
# quietly answer about the wrong build.
mkdir -p "$T/builds/alpha-os-TK-88-202608230900"
echo "the plan" > "$T/builds/alpha-os-TK-88-202608230900/plan.md"
[ "$(ap alpha-os TK-88 plan)" = "$T/builds/alpha-os-TK-88-202608230900/plan.md" ] \
  && ok || bad "a clean key resolves (got: $(ap alpha-os TK-88 plan))"
for BADK in '' '../../etc' 'TK-88/../..' 'PB 88' 'PB;id' 'TK-88*' '.'; do
  OUT=$(ap alpha-os "$BADK" plan); RC=$?
  [ "$RC" -eq 1 ] && [ -z "$OUT" ] || bad "key '$BADK' should be refused rc=1 (rc=$RC out=$OUT)"
done
ok
# An unregistered project is refused for the same reason.
OUT=$(ap not-a-project TK-88 plan); RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] || bad "unregistered project should be refused (rc=$RC)"
ok

# ---------- 9. newest attempt across all three build-dir conventions ----------
# run-build writes <project>-<key>-<ts>, the pool reap writes pool-<...> and the
# fly ingest writes fly-<...>; a retried ticket leaves several behind.
mkdir -p "$T/builds/pool-alpha-os-TK-88-202608231100" "$T/builds/fly-alpha-os-TK-88-202608231000"
echo "pool plan"  > "$T/builds/pool-alpha-os-TK-88-202608231100/plan.md"
echo "fly plan"   > "$T/builds/fly-alpha-os-TK-88-202608231000/plan.md"
touch -t 202608230900 "$T/builds/alpha-os-TK-88-202608230900"
touch -t 202608231000 "$T/builds/fly-alpha-os-TK-88-202608231000"
touch -t 202608231100 "$T/builds/pool-alpha-os-TK-88-202608231100"
[ "$(ap alpha-os TK-88 plan)" = "$T/builds/pool-alpha-os-TK-88-202608231100/plan.md" ] \
  && ok || bad "newest attempt wins (got: $(ap alpha-os TK-88 plan))"
# A shorter key must not glob into a longer one: TK-8 is not TK-88.
OUT=$(ap alpha-os TK-8 plan); RC=$?
[ "$RC" -eq 2 ] && [ -z "$OUT" ] || bad "TK-8 must not match TK-88's dir (rc=$RC out=$OUT)"
ok

# ---------- 10. no build dir at all -> missing, not an error ----------
OUT=$(ap alpha-os TK-999 plan); RC=$?
[ "$RC" -eq 2 ] && ok || bad "valid input with no build dir should exit 2 (rc=$RC)"
OUT=$(aj alpha-os TK-999 plan cmd-a1); RC=$?
[ "$RC" -eq 0 ] && [ "$(jq -r .missing <<<"$OUT")" = true ] \
  && [ "$(jq -r .content <<<"$OUT")" = "" ] \
  && ok || bad "no build dir must still beat missing:true, rc 0 (rc=$RC out=$OUT)"
# Dir exists but this artifact was never written (a build that died before QA).
OUT=$(aj alpha-os TK-88 qa cmd-a2); RC=$?
[ "$RC" -eq 0 ] && [ "$(jq -r .missing <<<"$OUT")" = true ] \
  && ok || bad "absent artifact in a real build dir -> missing:true (rc=$RC out=$OUT)"

# ---------- 11. truncation at the 48000-byte cap ----------
B="$T/builds/pool-alpha-os-TK-88-202608231100"
head -c 60000 /dev/zero | tr '\0' 'z' > "$B/pipeline.log"
OUT=$(aj alpha-os TK-88 pipeline cmd-a3)
[ "$(jq -r .truncated <<<"$OUT")" = true ] \
  && [ "$(jq -r .content <<<"$OUT" | wc -c)" -le 48001 ] \
  && ok || bad "over-cap artifact tailed with truncated=true"
head -c 48000 /dev/zero | tr '\0' 'z' > "$B/pipeline.log"
[ "$(jq -r .truncated <<<"$(aj alpha-os TK-88 pipeline cmd-a4)")" = false ] \
  && ok || bad "exactly-at-cap artifact should be truncated=false"

# ---------- 12. encoding + beat envelope ----------
printf 'VERDICT: BLOCK\nsaid "no" \\ here\t} end\n' > "$B/review.md"
OUT=$(aj alpha-os TK-88 review cmd-a5)
jq -e . >/dev/null 2>&1 <<<"$OUT" && ok || bad "artifact output must be parseable JSON"
[ "$(jq -r .content <<<"$OUT")" = "$(cat "$B/review.md")" ] \
  && ok || bad "artifact content must round-trip byte-for-byte"
[ "$(jq -r .kind <<<"$OUT")" = artifact_tail ]       && ok || bad "kind should be artifact_tail"
[ "$(jq -r .rkey <<<"$OUT")" = "artifact:cmd-a5" ]   && ok || bad "rkey should be artifact:<command_id>"
[ "$(jq -r .key <<<"$OUT")" = TK-88 ]                && ok || bad "key echoed"
[ "$(jq -r .which <<<"$OUT")" = review ]             && ok || bad "which echoed"
[ "$(jq -r .project <<<"$OUT")" = alpha-os ]         && ok || bad "project echoed"
jq -e '.ts | test("^[0-9]{4}-")' >/dev/null <<<"$OUT" && ok || bad "artifact ts should be an ISO stamp"

# ---------- 13. artifact --error terminal beat + dotted near-match ----------
OUT=$("$DIR/bin/fetch-artifact.sh" --error alpha-os TK-88 review cmd-e3 fetch_failed 2>/dev/null); RC=$?
[ "$RC" -eq 0 ] && [ "$(jq -r .kind <<<"$OUT")" = artifact_tail ] \
  && [ "$(jq -r .rkey <<<"$OUT")" = "artifact:cmd-e3" ] \
  && [ "$(jq -r .error <<<"$OUT")" = fetch_failed ] \
  && [ "$(jq -r .missing <<<"$OUT")" = true ] && [ "$(jq -r .content <<<"$OUT")" = "" ] \
  && ok || bad "artifact --error terminal beat (rc=$RC out=$OUT)"
OUT=$(ap alpha.os TK-88 plan); RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] || bad "'alpha.os' must not match the alpha-os row (rc=$RC)"
ok

echo "fetch-log-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
