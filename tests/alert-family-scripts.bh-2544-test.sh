#!/bin/bash
# tests/alert-family-scripts.bh-2544-test.sh — the family-registry RUNNER of
# BH-2544 (BH-2572): bin/triage-family-scripts.sh and the client function it
# reads rows through, alert_family_scripts in bin/lib/jobs/alerts.sh.
#
# Every B4 case runs one tick of the REAL bin/alert-triage.sh in a scratch
# harness with the REAL runner and the REAL jobs client beside it. The worker is
# a fake curl that serves the registry rows from $T/rows.json and answers
# PATCH /api/alerts/state; the verify scripts are stubs in the scratch
# bin/alert-verify/. agent-call is a recording stub (one prompt file = one
# session), and the close lib is a recording fake (its real half is #2570).
#   HARNESS_TEST_SANDBOX=1 bash tests/alert-family-scripts.bh-2544-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/triage-tick.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/h"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1; model_routes_fixture "$H" || exit 1
mkdir -p "$H/bin/lib" "$H/bin/alert-verify" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" "$T/stub" "$T/tmp"
: > "$H/env/global.env"
LOGF="$H/logs/alert-triage.log"
FAMF="$H/state/alert-families.json"
SPOOL="$H/state/alert-triage-deferred.tsv"
# BH-5942: project "fleet" is not in fleet.conf, so the cromford run owns
# the lines. reset seeds the shared files above (the dispatch routes the legacy
# spool; the run seeds its brake file by copy); the run writes this one.
PFAMF="$H/state/alert-triage/cromford/alert-families.json"
CALLDIR="$T/calls"

for s in alert-triage.sh triage-spool-retire.sh; do
  sed "s|/root/harness|$H|g" "$DIR/bin/$s" > "$H/bin/$s"; chmod +x "$H/bin/$s"
done
cp "$DIR/bin/triage-family-scripts.sh" "$H/bin/triage-family-scripts.sh"; chmod +x "$H/bin/triage-family-scripts.sh"
for s in triage-map.sh fleet-conf.sh box-for.sh alert_family.py jobs-client.sh; do ln -sf "$DIR/bin/$s" "$H/bin/$s"; done
ln -sf "$DIR/bin/lib/jobs" "$H/bin/lib/jobs"
ln -sf "$DIR/bin/lib/env-path.sh" "$H/bin/lib/env-path.sh"
export FLEET_CONF="$DIR/fleet.conf"
triage_tick_setup "$H" || exit 1

# --- stubs --------------------------------------------------------------------
cat > "$H/bin/agent-call.sh" <<'STUB'
#!/bin/bash
N=$(ls "$CALLDIR"/prompt-* 2>/dev/null | wc -l | tr -d ' ')
printf '%s' "$6" > "$CALLDIR/prompt-$N.txt"
echo "handled=1 escalated=0 noise=0" > "$5"
STUB
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/sh\nexit 75\n' > "$H/bin/gh-pr-state.sh"; chmod +x "$H/bin/gh-pr-state.sh"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/ssh";   chmod +x "$T/stub/ssh"
printf '#!/bin/sh\nexit 0\n' > "$T/stub/flock"; chmod +x "$T/stub/flock"
# timeout is the REAL binary, so the per-verify timeout and the deadline are real.

# The close lib is a recording fake: triage_settled_ids keeps a copy of the
# settled file it was handed (the runner's lines are in it).
cat > "$H/bin/lib/triage-close.sh" <<'STUB'
triage_settled_ids() { cp "$1" "$CALLDIR/settled-copy"; return 0; }
triage_close_ids() { echo "close $1" >> "$CALLDIR/close"; return 0; }
STUB

# The fake worker. Records `METHOD URL BODY parked=<PARKED lines in the lane log
# at that moment>` so "log first, then write" is read off the record.
cat > "$T/stub/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; BODY=""; METHOD=GET
while [ $# -gt 0 ]; do
  case "$1" in
    -X) METHOD="$2"; shift 2 ;;
    --data-binary) BODY="$2"; shift 2 ;;
    -H) shift 2 ;;
    *) shift ;;
  esac
done
printf '%s %s %s parked=%s\n' "$METHOD" "$URL" "$BODY" "$(grep -c 'PARKED by registry row' "$FK_LOG" 2>/dev/null)" >> "$FK/req.log"
[ -f "$FK/curl-down" ] && exit 7
# BH-6650: a one-shot delay on the registry fetch, inside the runner's deadline,
# stands in for a loaded runner that is slow to reach its first verify.
case "$METHOD $URL" in "GET "*/api/alert-family-scripts)
  [ -f "$FK/curl-delay" ] && { rm -f "$FK/curl-delay"; sleep 2; } ;; esac   # determinism: ok the delay IS the fixture (BH-6650 start lag)
case "$METHOD $URL" in
  "GET "*/api/alert-family-scripts)
    if [ -f "$FK/rows-404" ]; then printf '{"error":"not found"}\n404\n'
    elif [ -f "$FK/rows-html" ]; then printf '<html>bad gateway</html>\n200\n'
    else printf '%s\n200\n' "$(cat "$FK/rows.json")"; fi ;;
  "PATCH "*/api/alerts/state)
    if [ -f "$FK/patch-409" ]; then printf '{"error":"illegal transition"}\n409\n'
    else printf '{"alert":%s}\n200\n' "$(printf '%s' "$BODY" | jq -c '{id, state}')"; fi ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/stub/curl"

# --- fixture helpers ------------------------------------------------------------
NOW=1790467200   # 2026-09-26T22:40:00Z
mkline() { # mkline <akey> <text> [extra-json-object] — one quarantine line
  printf 'hub\t%s\t%s' "$((NOW - 3600))" \
    "$(jq -nc --arg a "$1" --arg l "$2" --argjson x "${3:-{\}}" '{kind:"fleet_alert",project:"fleet",akey:$a,line:$l} + $x')"
}
# The family key the lane itself computes, never a typed one (D4).
fam() { (cd "$DIR/bin" && python3 -c 'import sys; from alert_family import family; print(family(sys.argv[1]))' "$1"); }
rows() { printf '{"rows":%s,"as_of":"2026-09-28T09:00:00Z"}' "$1" > "$T/rows.json"; }
row() { # row <id> <kind> <match> <verify> [on_clear] [on_repro] [priority] [enabled]
  jq -nc --arg id "$1" --arg k "$2" --arg m "$3" --arg v "$4" --arg c "${5:-settle}" --arg r "${6:-model}" \
    --argjson p "${7:-100}" --argjson e "${8:-1}" \
    '{id:$id, match_kind:$k, match:$m, verify:(if $v == "" then null else $v end), on_clear:$c, on_repro:$r, priority:$p, enabled:$e}'
}
mkverify() { # mkverify <name> <body> — a stub verify script that records its call and stdin
  { echo '#!/bin/bash'
    echo "cat > \"\$CALLDIR/stdin-$1\""
    echo "echo $1 >> \"\$CALLDIR/verify-calls\""
    printf '%s\n' "$2"; } > "$H/bin/alert-verify/$1.sh"
  chmod +x "$H/bin/alert-verify/$1.sh"
}

reset() { # reset <line>... — the spool this tick starts from
  triage_tick_reset "$H"; : > "$LOGF"; : > "$H/logs/ALERTS.log"; : > "$H/logs/cost.csv"
  echo '{}' > "$FAMF"; printf '%s\n' "$@" > "$SPOOL"
  : > "$H/state/alert-quarantine.jsonl"
  rm -f "$H"/flags/* "$H"/state/alert-triage-expired-*.tsv "$H/state/triage-prstate.json"
  rm -f "$T/req.log" "$T/curl-down" "$T/rows-404" "$T/rows-html" "$T/patch-409" "$T/curl-delay" "$H/bin/rm.sh" "$T/canary"
  scratch_rm "$CALLDIR"; mkdir -p "$CALLDIR"
  scratch_rm "$H/bin/alert-verify"; mkdir -p "$H/bin/alert-verify"
  mkverify ok-clear 'echo "gone: probe 200"; exit 0'
  mkverify still-there 'echo "still failing"; exit 1'
  rows '[]'
}
RC=0
run() { # run [VAR=value...] — one real lane tick
  ( [ "$#" -gt 0 ] && export "$@"
    export TMPDIR="$T/tmp" TRIAGE_NOW="$NOW" TRIAGE_MAX_FAMILIES=20 CALLDIR="$CALLDIR" PATH="$T/stub:$PATH" \
      HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid JOBS_RETRY_SLEEP=0 FK="$T" FK_LOG="$LOGF"
    triage_tick "$H/bin/alert-triage.sh" >/dev/null 2>&1 )
  RC=$?
}
ncalls() { ls "$CALLDIR"/prompt-* 2>/dev/null | wc -l | tr -d ' '; }
nverify() { [ -f "$CALLDIR/verify-calls" ] && wc -l < "$CALLDIR/verify-calls" | tr -d ' ' || echo 0; }
summary() { grep -o 'triage pass: REGISTRY rows=.*' "$LOGF" | tail -1; }
stamp_of() { jq -r --arg k "$1" 'if .[$k] == null then "absent" else (.[$k] | floor | tostring) end' "$PFAMF"; }

# ---------- B3. the client ------------------------------------------------------
client() { # client [pre-command] — alert_family_scripts through the real jobs client
  ( export PATH="$T/stub:$PATH" HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.invalid \
      JOBS_RETRY_SLEEP=0 FK="$T" FK_LOG="$LOGF" CALLDIR="$CALLDIR"
    . "$DIR/bin/jobs-client.sh" || exit 99
    eval "${1:-:}"
    alert_family_scripts > "$T/client.out"; echo $? > "$T/client.rc" )
}
reset
rows "[$(row b akey_prefix bb: ok-clear settle model 5),$(row a akey_prefix aa: '' settle park 5),$(row c line_regex cc ok-clear settle model 1 0),$(row d line_regex 'SLO .*' ok-clear model model 9)]"
client
EXP=$(printf 'a\takey_prefix\taa:\t\tsettle\tpark\t5\nb\takey_prefix\tbb:\tok-clear\tsettle\tmodel\t5\nd\tline_regex\tSLO .*\tok-clear\tmodel\tmodel\t9')
[ "$(cat "$T/client.rc")" = 0 ] && [ "$(cat "$T/client.out")" = "$EXP" ] && ok \
  || bad "B3: enabled rows a,b,d as TSV in priority,id order (rc $(cat "$T/client.rc"), got: $(cat "$T/client.out"))"
rows '[]'; client
[ "$(cat "$T/client.rc")" = 0 ] && [ ! -s "$T/client.out" ] && ok || bad "B3: zero rows is rc 0 and no output (rc $(cat "$T/client.rc"))"
touch "$T/rows-404"; client
[ "$(cat "$T/client.rc")" = 2 ] && [ ! -s "$T/client.out" ] && ok \
  || bad "B3: a 404 (route not deployed) is rc 2 with empty stdout (rc $(cat "$T/client.rc"), out: $(cat "$T/client.out"))"
rm -f "$T/rows-404"; touch "$T/rows-html"; client
[ "$(cat "$T/client.rc")" = 1 ] && [ ! -s "$T/client.out" ] && ok \
  || bad "B3: a 200 that is not {rows:[...]} is rc 1 (rc $(cat "$T/client.rc"))"
rm -f "$T/rows-html"; printf '{"as_of":"x"}' > "$T/rows.json"; client
[ "$(cat "$T/client.rc")" = 1 ] && ok || bad "B3: a 200 with no rows array is rc 1, never an empty list (rc $(cat "$T/client.rc"))"
client '_jobs_req() { return 75; }'
[ "$(cat "$T/client.rc")" = 75 ] && [ ! -s "$T/client.out" ] && ok \
  || bad "B3: rc 75 from _jobs_req passes through verbatim (rc $(cat "$T/client.rc"))"

# ---------- B4a. cleared + settle -----------------------------------------------
L_A=$(mkline "orclane:a-1" "the widget subsystem is unhappy" '{"dbrow":true,"alertid":"a-1"}')
F_A=$(fam "$L_A")
reset "$L_A"
rows "[$(row r-clear akey_prefix orclane: ok-clear)]"
jq -n --arg k "$F_A" --argjson v "$((NOW - 7*3600))" '{($k): $v}' > "$FAMF"
run
[ "$RC" = 0 ] && ok || bad "B4a: the tick exits 0 (got $RC)"
grep -qF 'NOISE-STALE (deterministic, no model call) verify:r-clear: gone: probe 200 :: ' "$LOGF" && ok \
  || bad "B4a: NOISE-STALE verify:r-clear line in the lane log (log: $(grep -c . "$LOGF") lines; $(grep -E 'REGISTRY|NOISE' "$LOGF" | head -3))"
grep -q '^verify:r-clear: gone: probe 200	.*"alertid":"a-1"' "$CALLDIR/settled-copy" 2>/dev/null && ok \
  || bad "B4a: the close lib got the settled line with its reason and alertid (got: $(cat "$CALLDIR/settled-copy" 2>/dev/null))"
[ "$(ncalls)" = 0 ] && ok || bad "B4a: a settled family costs no session (got $(ncalls))"
[ "$(summary)" = "triage pass: REGISTRY rows=1 matched=1 cleared=1 parked=0 repro=0 unknown=0 unchecked=0" ] && ok \
  || bad "B4a: summary line (got: $(summary))"
[ "$(cat "$CALLDIR/stdin-ok-clear" 2>/dev/null)" = "$L_A" ] && ok \
  || bad "B4a: the verify script gets the family's raw quarantine lines on stdin (got: $(cat "$CALLDIR/stdin-ok-clear" 2>/dev/null))"
[ "$(stamp_of "$F_A")" = "$((NOW - 7*3600))" ] && ok \
  || bad "NEG-stamp: a settled family is back at its pre-tick stamp (got $(stamp_of "$F_A"))"
# NEG-stamp: never seen before -> stays absent.
reset "$L_A"; rows "[$(row r-clear akey_prefix orclane: ok-clear)]"; run
[ "$(stamp_of "$F_A")" = absent ] && ok || bad "NEG-stamp: a settled never-seen family stays absent (got $(stamp_of "$F_A"))"

# ---------- B4b. repro + model: one session, as today ---------------------------
reset "$L_A"; rows "[$(row r-clear akey_prefix orclane: still-there settle model)]"; run
[ "$(ncalls)" = 1 ] && ok || bad "B4b: repro + model keeps the session (got $(ncalls))"
! grep -q NOISE-STALE "$LOGF" && ok || bad "B4b: nothing settled"
[ "$(summary)" = "triage pass: REGISTRY rows=1 matched=1 cleared=0 parked=0 repro=1 unknown=0 unchecked=0" ] && ok \
  || bad "B4b: summary (got: $(summary))"

# ---------- B4c. repro + park ---------------------------------------------------
reset "$L_A"; rows "[$(row r-clear akey_prefix orclane: still-there settle park)]"
jq -n --arg k "$F_A" --argjson v "$((NOW - 7*3600))" '{($k): $v}' > "$FAMF"
run
PATCHL=$(grep '^PATCH .*/api/alerts/state ' "$T/req.log" 2>/dev/null)
grep -qF '{"id":"a-1","state":"parked","actor":"alert-triage"}' <<<"$PATCHL" && ok \
  || bad "B4c: PATCH /api/alerts/state parks a-1 as alert-triage (got: $PATCHL)"
grep -q 'parked=[1-9]' <<<"$PATCHL" && ok || bad "B4c: PARKED is logged BEFORE the write (got: $PATCHL)"
grep -q 'PARKED by registry row r-clear family=.* ids=a-1' "$LOGF" && ok || bad "B4c: PARKED by registry row r-clear line"
[ "$(ncalls)" = 0 ] && ok || bad "B4c: a parked family costs no session (got $(ncalls))"
[ "$(summary)" = "triage pass: REGISTRY rows=1 matched=1 cleared=0 parked=1 repro=1 unknown=0 unchecked=0" ] && ok \
  || bad "B4c: summary (got: $(summary))"
[ "$(stamp_of "$F_A")" = "$((NOW - 7*3600))" ] && ok || bad "NEG-stamp: a parked family is back at its pre-tick stamp (got $(stamp_of "$F_A"))"
# B4c-409: the worker refuses the park -> the family keeps its session.
reset "$L_A"; rows "[$(row r-clear akey_prefix orclane: still-there settle park)]"; touch "$T/patch-409"; run
[ "$(ncalls)" = 1 ] && ok || bad "B4c-409: a refused park keeps the session (got $(ncalls))"
grep -q 'REGISTRY park failed rc=9 id=a-1' "$LOGF" && ok || bad "B4c-409: park failed line (log: $(grep REGISTRY "$LOGF"))"
# A park candidate with no alerts row is kept, never silently suppressed.
L_NR=$(mkline "orclane:beat" "a beat with no table row")
reset "$L_NR"; rows "[$(row r-clear akey_prefix orclane: still-there settle park)]"; run
[ "$(ncalls)" = 1 ] && grep -q 'REGISTRY park skipped: no alerts row to park' "$LOGF" && ! grep -q '^PATCH' "$T/req.log" && ok \
  || bad "B4c: a beat-only family is not parked (sessions $(ncalls))"

# ---------- B4d. 1 of 3 lines matches: untouched -------------------------------
L_D1=$(mkline "p1-disk" "disk nearly full on the build box")
L_D2=$(mkline "p2-disk" "disk nearly full on the build box")
L_D3=$(mkline "p3-disk" "disk nearly full on the build box")
[ "$(fam "$L_D1")" = "$(fam "$L_D2")" ] && [ "$(fam "$L_D1")" = "$(fam "$L_D3")" ] && ok \
  || bad "B4d precondition: the three lines are one family"
reset "$L_D1" "$L_D2" "$L_D3"; rows "[$(row r-p1 akey_prefix p1- ok-clear)]"; run
[ "$(nverify)" = 0 ] && ok || bad "B4d: a partly matched family is never verified (got $(nverify))"
[ "$(ncalls)" = 1 ] && ok || bad "B4d: one session (got $(ncalls))"
P=$(cat "$CALLDIR"/prompt-*.txt 2>/dev/null)
case "$P" in *p1-disk*p2-disk*p3-disk*) ok ;; *) bad "B4d: the session prompt holds all three lines unchanged" ;; esac
case "$(summary)" in *" matched=0 "*) ok ;; *) bad "B4d: matched=0 (got: $(summary))" ;; esac

# ---------- B4-prio. the lowest priority number wins ----------------------------
mk_hi_lo() { mkverify v-hi 'echo "hi cleared"; exit 0'; mkverify v-lo 'echo "lo cleared"; exit 0'; }
reset "$L_A"; mk_hi_lo
rows "[$(row r-lo akey_prefix orc v-lo settle model 5),$(row r-hi akey_prefix orclane: v-hi settle model 1)]"; run
grep -q '^v-hi$' "$CALLDIR/verify-calls" 2>/dev/null && ! grep -q '^v-lo$' "$CALLDIR/verify-calls" && ok \
  || bad "B4-prio: only the priority-1 row's verify runs (got: $(cat "$CALLDIR/verify-calls" 2>/dev/null))"
grep -qF 'verify:r-hi: hi cleared' "$LOGF" && ok || bad "B4-prio: settled by r-hi"

# ---------- B4e. unknown outcomes keep the family ------------------------------
for c in e124:'exit 124' e75:'exit 75' empty:'exit 0' absent:''; do
  name=${c%%:*}; body=${c#*:}
  reset "$L_A"
  [ "$name" != absent ] && mkverify "$name" "$body"
  rows "[$(row r-clear akey_prefix orclane: "$name")]"; run
  [ "$(ncalls)" = 1 ] && ok || bad "B4e ($name): the family keeps its session (got $(ncalls))"
  ! grep -q NOISE-STALE "$LOGF" && ok || bad "B4e ($name): nothing settled"
  case "$(summary)" in *" unknown=1 "*) ok ;; *) bad "B4e ($name): unknown=1 (got: $(summary))" ;; esac
done

# ---------- B4f. registry unreachable: fail open ------------------------------
L_F2=$(mkline "orclane:f2" "the gizmo daemon restarted")
reset "$L_A" "$L_F2"; rows "[$(row r-clear akey_prefix orclane: ok-clear)]"; touch "$T/curl-down"; run
[ "$RC" = 0 ] && ok || bad "B4f: the tick exits 0 (got $RC)"
[ "$(grep -c 'triage pass: REGISTRY unavailable rc=1' "$LOGF")" = 1 ] && [ "$(grep -c 'REGISTRY' "$LOGF")" = 1 ] && ok \
  || bad "B4f: exactly one REGISTRY unavailable line (got: $(grep REGISTRY "$LOGF"))"
[ "$(ncalls)" = 2 ] && ok || bad "B4f: one session per family (got $(ncalls))"
! grep -q NOISE-STALE "$LOGF" && [ "$(nverify)" = 0 ] && ok || bad "B4f: nothing verified or settled"

# ---------- B4g. TRIAGE_VERIFY_MAX=1 with three matched families ----------------
L_G2=$(mkline "orclane:g2" "the sprocket queue is backed up")
L_G3=$(mkline "orclane:g3" "the flange cache went cold")
[ "$(printf '%s\n' "$(fam "$L_A")" "$(fam "$L_G2")" "$(fam "$L_G3")" | sort -u | wc -l)" = 3 ] && ok \
  || bad "B4g precondition: three distinct families"
reset "$L_A" "$L_G2" "$L_G3"; rows "[$(row r-clear akey_prefix orclane: ok-clear)]"; run TRIAGE_VERIFY_MAX=1
[ "$(nverify)" = 1 ] && ok || bad "B4g: exactly one verify runs (got $(nverify))"
case "$(summary)" in *" cleared=1 "*" unchecked=2") ok ;; *) bad "B4g: cleared=1 unchecked=2 (got: $(summary))" ;; esac
[ "$(ncalls)" = 2 ] && ok || bad "B4g: the two unchecked families keep their sessions (got $(ncalls))"
# B4-deadline: the pass starts 2s late (a loaded runner), the first verify never
# ends on its own, and its timeout, clamped to what is left of the 10s pass, kills
# it; the second family is unchecked. No wall-clock race on the first start (BH-6650).
reset "$L_A" "$L_G2"; mkverify slow 'exec sleep 60'   # determinism: ok the verify never ends; the deadline-clamped timeout is what stops it
rows "[$(row r-slow akey_prefix orclane: slow)]"; touch "$T/curl-delay"
run TRIAGE_VERIFY_DEADLINE_S=10 TRIAGE_VERIFY_TIMEOUT_S=30
[ "$(nverify)" = 1 ] && ok || bad "B4-deadline: one verify started (got $(nverify))"
grep -q 'row r-slow: verify slow rc=124 ' "$LOGF" && ok || bad "B4-deadline: the clamped timeout killed the first verify (log: $(grep -F 'r-slow' "$LOGF" | head -2))"
[ ! -e "$T/curl-delay" ] && ok || bad "B4-deadline: the start delay fired"
case "$(summary)" in *" cleared=0 "*" unknown=1 unchecked=1") ok ;; *) bad "B4-deadline: unknown=1 unchecked=1 (got: $(summary))" ;; esac
[ "$(ncalls)" = 2 ] && ok || bad "B4-deadline: both families keep their sessions (got $(ncalls))"

# ---------- B4h. a regex that does not compile ----------------------------------
reset "$L_A"; rows "[$(row r-bad line_regex '([' ok-clear settle model 1),$(row r-good akey_prefix orclane: ok-clear settle model 2)]"; run
[ "$RC" = 0 ] && ok || bad "B4h: the tick exits 0 (got $RC)"
[ "$(grep -c 'REGISTRY refused row r-bad: line_regex' "$LOGF")" = 1 ] && ok || bad "B4h: one refused line for r-bad (got: $(grep refused "$LOGF"))"
grep -qF 'verify:r-good: gone: probe 200' "$LOGF" && [ "$(ncalls)" = 0 ] && ok || bad "B4h: r-good still settles its family"

# ---------- negatives -----------------------------------------------------------
# NEG-akey: the prefix is tested on the akey, never the text.
L_N1=$(mkline "triage:x" "main-red-foo: main is red on cromford")
reset "$L_N1"; rows "[$(row r-mr akey_prefix main-red- ok-clear)]"; run
[ "$(nverify)" = 0 ] && [ "$(ncalls)" = 1 ] && ok || bad "NEG-akey: main-red- in the TEXT must not match (verifies $(nverify), sessions $(ncalls))"
# NEG-RESOLVED: re.match is anchored.
L_N2=$(mkline "slo:p95" "SLO BREACH p95 latency — clears itself with a RESOLVED line.")
reset "$L_N2"; rows "[$(row r-res line_regex RESOLVED ok-clear)]"; run
[ "$(nverify)" = 0 ] && [ "$(ncalls)" = 1 ] && ! grep -q NOISE-STALE "$LOGF" && ok \
  || bad "NEG-RESOLVED: RESOLVED mid-line must not match (verifies $(nverify), sessions $(ncalls))"
# Control: an anchored regex on the same line DOES match (the regex path is
# live). A line that starts with RESOLVED is not usable here: the lane's own
# retraction rule settles it before the registry pass.
reset "$L_N2"; rows "[$(row r-slo line_regex 'SLO BREACH p[0-9]+ ' ok-clear)]"; run
[ "$(nverify)" = 1 ] && grep -qF 'verify:r-slo: gone: probe 200' "$LOGF" && ok \
  || bad "NEG-RESOLVED control: an anchored match does verify (got $(nverify))"
# NEG-traversal: a verify name outside ^[a-z0-9-]{1,48}$ is refused.
reset "$L_A"
printf '#!/bin/bash\ntouch "%s"\necho pwned\nexit 0\n' "$T/canary" > "$H/bin/rm.sh"; chmod +x "$H/bin/rm.sh"
rows "[$(row r-trav akey_prefix orclane: ../../bin/rm)]"; run
[ ! -e "$T/canary" ] && ok || bad "NEG-traversal: ../../bin/rm must never run"
grep -q 'REGISTRY refused row r-trav: verify' "$LOGF" && [ "$(ncalls)" = 1 ] && ok \
  || bad "NEG-traversal: the row is refused and the family keeps its session (sessions $(ncalls))"
# NEG-empty-match: an empty akey_prefix would match everything.
reset "$L_A"; rows "[$(row r-all akey_prefix '' ok-clear)]"; run
grep -q 'REGISTRY refused row r-all: empty match' "$LOGF" && [ "$(nverify)" = 0 ] && [ "$(ncalls)" = 1 ] && ok \
  || bad "NEG-empty-match: refused, nothing matched (verifies $(nverify), sessions $(ncalls))"
# NEG-json: a payload that is not JSON matches nothing, whatever it says.
L_N4=$(printf 'hub\t%s\tplain text orclane: not a beat' "$((NOW - 3600))")
reset "$L_N4"; rows "[$(row r-clear akey_prefix orclane: ok-clear),$(row r-any line_regex '.*' ok-clear)]"; run
[ "$(nverify)" = 0 ] && [ "$(ncalls)" = 1 ] && ok || bad "NEG-json: a non-JSON payload matches nothing (verifies $(nverify))"

# ---------- MAX=0: the pass is off, no request ---------------------------------
reset "$L_A"; rows "[$(row r-clear akey_prefix orclane: ok-clear)]"; run TRIAGE_VERIFY_MAX=0
! grep -q 'alert-family-scripts' "$T/req.log" 2>/dev/null && ok || bad "MAX=0: no registry fetch"
[ "$(grep -c 'REGISTRY off (TRIAGE_VERIFY_MAX=0)' "$LOGF")" = 1 ] && [ "$(ncalls)" = 1 ] && ok \
  || bad "MAX=0: one REGISTRY off line and the session as today (sessions $(ncalls))"

# ---------- no temp file outlives a tick ----------------------------------------
reset "$L_A"; scratch_rm "$T/tmp"; mkdir -p "$T/tmp"
rows "[$(row r-clear akey_prefix orclane: still-there settle park)]"; run
[ -z "$(ls -A "$T/tmp")" ] && ok || bad "temp files left behind: $(ls "$T/tmp" | head -5 | tr '\n' ' ')"

echo "alert-family-scripts.bh-2544: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
