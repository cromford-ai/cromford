#!/bin/bash
# tests/overage-per-box-test.sh — every box's account meter is tracked, and no
# box can be added to the fleet without being tracked.
#
# WHY PER-BOX AT ALL. Extra usage is being turned ON for project-2/project-3/project-4, which
# reverses the 07-24 doctrine. With it off, a cap hit FAILED — that error is
# what drove the codex/grok failover cascade. With it on, the same cap hit
# BILLS: nothing errors, nothing fails over, and the only remaining signal that
# an account is burning cash is its own meter. So an untracked account is not
# "monitored a bit less"; it is an account whose overage nobody can see, which
# is exactly how $18.8K accumulated on the hub unnoticed.
#
# THE SET-EQUALITY HALF is the same shape as watchdog-boxes-test: the failure
# is not a crash, it is a box quietly outside the system. This fleet already
# carries FOUR divergent hand-maintained box lists (claude-auth-check,
# cost-rollup x2, alert-triage), so "someone will remember" is demonstrably
# false here.
# Run from anywhere: tests/overage-per-box-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1247: catalog/lanes.json and cron/<box>.cron are GENERATED and not
# committed. rendered_registry / rendered_cron render this repo's own into $T.
. "$(dirname "$0")/lib/rendered.sh" || exit 1
# TEST-CHANGE (BH-5651): the fleet is this repo's registry, as a cache read in
# db mode through bin/lib/registry.sh, not $DIR/fleet.conf. The crontabs render
# from it once, in a subshell, and rendered.sh reuses those files below.
. "$DIR/tests/lib/registry-cache.bh-5651.sh" || exit 1
RH="$T/rh"
( rcache_install "$RH" "$DIR" && export HARNESS="$RH" && rendered_cron_dir >/dev/null ) \
  || { echo "FAIL: could not build this repo's registry cache or render the fleet from it"; exit 1; }
ROLL="$DIR/bin/cost-rollup.sh"
TRACK="$DIR/bin/extra-usage-track.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ---------- gather ----------
CRON_BOXES=$(grep -ho 'extra-usage-track\.sh [A-Za-z0-9._-]*' "$(rendered_cron_dir)"/*.cron 2>/dev/null \
  | awk '{print $2}' | sort -u)
# The collection list in the rollup: the overage block's ids plus the local hub.
# TEST-CHANGE (BH-5747): the loop reads fleet.conf (fleet-conf.sh --box-ids)
# instead of a literal list, so this RUNS the real block against this repo's
# fleet.conf rather than parsing a list out of the source. The FACT under test
# is unchanged: every box that polls a meter must be collected from.
# TEST-CHANGE (BH-5651): the block runs in db mode against the registry cache
# under $RH, not with FLEET_CONF="$DIR/fleet.conf".
OVB=$(sed -n '/^# >>> overage boxes (BH-5747)$/,/^# <<< overage boxes$/p' "$ROLL")
COLLECT_BOXES=""
[ -n "$OVB" ] && COLLECT_BOXES=$( { echo hub
  rcache_run "$RH" bash -c "$OVB"$'\nprintf "%s\\n" $OVERAGE_BOXES' "$ROLL"; } | grep . | sort -u)

[ -n "$CRON_BOXES" ]    && ok || bad "no extra-usage-track lines found in cron/*.cron"
[ -n "$COLLECT_BOXES" ] && ok || bad "could not parse the collection list out of cost-rollup.sh"

# ---------- 1. exactly one tracker line per cron file ----------
# Two lines double the poll rate against a per-account rate limit, and the
# symptom is a MISSING sample rather than an error — the tracker fail-softs, so
# over-polling looks like a quiet hour.
# Exactly one, OR zero WITH A DECLARED REASON. A stopped box legitimately has
# no tracker (project-10, 2026-08-25) — but silence and "deliberately
# absent" must not look alike, or the next reader cannot tell a decision from
# an oversight. Same declared-gap rule the trim and the meter both follow.
for F in "$(rendered_cron_dir)"/*.cron; do
  N=$(grep -c 'extra-usage-track\.sh' "$F" 2>/dev/null || true)
  case "${N:-0}" in
    1) ;;
    0) grep -qi 'NO extra-usage tracker line, deliberately' "$F" \
         || bad "$(basename "$F") has no tracker line and no stated reason — absence must be declared" ;;
    *) bad "$(basename "$F") has $N tracker lines, expected exactly 1" ;;
  esac
done
ok

# ---------- 2. the box id must match the cron file it lives in ----------
# A copy-pasted line carrying the wrong id attributes one box's overage to
# another — worse than missing, because it looks present and points at the
# wrong account.
for F in "$(rendered_cron_dir)"/*.cron; do
  EXPECT=$(basename "$F" .cron)
  GOT=$(grep -o 'extra-usage-track\.sh [A-Za-z0-9._-]*' "$F" | awk '{print $2}')
  [ -z "$GOT" ] && continue          # deliberately untracked, checked above
  [ "$GOT" = "$EXPECT" ] || bad "$(basename "$F") tracks box id '$GOT', expected '$EXPECT'"
done
ok

# ---------- 3. one schedule everywhere ----------
# Drift in cadence changes what a "day delta" means per box, and the alert
# threshold is a per-day figure.
# 15 minutes since 2026-09-14 (was hourly). The reconciler compares a METER
# DELTA over a 1h window against summed rows, and a delta needs two samples
# inside the window: at one sample an hour, every hourly window has exactly one
# and the comparison can never be made. :58 is kept in the set so the existing
# hourly series continues on the same minute it always landed on.
ODD=$(grep -h 'extra-usage-track\.sh' "$(rendered_cron_dir)"/*.cron \
  | grep -vE '^13,28,43,58 \* \* \* \* /root/harness/bin/extra-usage-track\.sh [A-Za-z0-9._-]+ >/dev/null 2>&1 #' || true)
[ -z "$ODD" ] && ok || bad "tracker cron line does not match the fleet-standard shape:
$ODD"

# ---------- 4. THE TWO SETS ARE EQUAL ----------
MISSING_FROM_COLLECT=$(comm -23 <(echo "$CRON_BOXES") <(echo "$COLLECT_BOXES"))
[ -z "$MISSING_FROM_COLLECT" ] && ok || bad "these boxes poll their meter but the rollup never collects it (the account burns invisibly):
$MISSING_FROM_COLLECT"

MISSING_FROM_CRON=$(comm -13 <(echo "$CRON_BOXES") <(echo "$COLLECT_BOXES"))
[ -z "$MISSING_FROM_CRON" ] && ok || bad "the rollup collects these boxes but no committed cron polls them (it waits forever for a file nobody writes):
$MISSING_FROM_CRON"

# ---------- 5. the tracker takes a box id and uses it ----------
grep -q 'BOX="\${1:-' "$TRACK" \
  && ok || bad "extra-usage-track.sh does not take a box id argument"
# ATTRIBUTED TO THE ACCOUNT LABEL, not the box (2026-09-14). A box may hold more
# than one login — the hub polls operator_home@example.com AND operator@second.example — so
# "[hub] EXTRA-USAGE" would name the machine and hide which of the two accounts
# is the one burning cash. The label IS the account.
grep -q 'EXTRA-USAGE \[\$LABEL\]' "$TRACK" \
  && ok || bad "the ALERTS lines are not attributed to an account label — a fleet-wide alert names no account"
grep -q '\[\$BOX\] EXTRA-USAGE' "$TRACK" \
  && bad "the alert still names the BOX, which is ambiguous on a box holding two logins" || ok
grep -q 'logs/hub.log' "$TRACK" \
  && bad "the tracker still logs to hub.log, which is the wrong file on 8 of 9 boxes" || ok

# ---------- 6. the aggregation: contract, and NOTHING MISSING SUMS AS ZERO ----
python3 - "$ROLL" "$T/core.py" <<'EXTRACT'
import sys
src = open(sys.argv[1]).read()
body = src[src.index("import csv, json, glob, os, re, sys, datetime, subprocess"):]
def grab(name, upto):
    i = body.index(name)
    return body[i:body.index(upto, i)]
out = ["import csv, json, datetime, sys, glob, os\nprices = {}\nH = CD = sys.argv[1]\n"
       "now = datetime.datetime.utcnow()\n"]
# read_overage_meter ends where the summary assembly begins; overage_accounts
# lives further down, next to overage_fields. Grabbing the span BETWEEN them
# would drag module-level code (s7/s30) into the extraction, which fails with a
# NameError that says nothing about the code under test.
out.append(grab("def read_overage_meter(", "summary = {"))
out.append(grab("def overage_accounts(", "def overage_fields("))
open(sys.argv[2], "w").write("\n".join(out))
EXTRACT
[ -s "$T/core.py" ] && grep -q 'def overage_accounts' "$T/core.py" \
  && ok || bad "could not extract overage_accounts from cost-rollup.sh"

mkdir -p "$T/overage"
HDR='ts,session_pct,weekly_pct,weekly_resets_at,extra_enabled,extra_used_usd,spend_limit_reached,in_overage'
FUT=$(python3 -c "
import datetime
print((datetime.datetime.utcnow()+datetime.timedelta(days=2)).strftime('%Y-%m-%dT%H:%M:%S.%f+00:00'))")
NOW=$(python3 -c "
import datetime
print((datetime.datetime.utcnow()-datetime.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%SZ'))")
PAST=$(python3 -c "
import datetime
print((datetime.datetime.utcnow()-datetime.timedelta(hours=1)).strftime('%Y-%m-%dT%H:%M:%S.%f+00:00'))")

# hub + project-4 report live meters; project-3's window has already reset (no observation
# yet); project-2 is expected but never reported at all.
printf '%s\n%s,100,100,%s,1,18863.13,0,1\n' "$HDR" "$NOW" "$FUT" > "$T/overage/hub.csv"
printf '%s\n%s,90,95,%s,1,250.00,0,0\n'     "$HDR" "$NOW" "$FUT" > "$T/overage/project-4.csv"
printf '%s\n%s,100,100,%s,1,9999.00,0,1\n'  "$HDR" "$NOW" "$PAST" > "$T/overage/project-3.csv"
# badstamp REPORTS a meter but its reset stamp is unparseable, so freshness
# cannot be verified. This is the case window_verified exists for, and without
# it in the fixture the verified-only filter can be deleted with the suite
# still green — the first mutation pass proved exactly that.
printf '%s\n2026-08-24T10:00:00Z,50,50,not-a-timestamp,1,4242.00,0,0\n' "$HDR" > "$T/overage/badstamp.csv"
printf 'hub\nproject-4\nproject-3\nbadstamp\nproject-2\n' > "$T/overage/EXPECTED"

python3 - "$T" <<'PY' && ok || bad "overage_accounts must sum only verified meters and NAME the rest"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
accounts, total, note = core.overage_accounts()

# contract keys, exactly as the consumer will read them
# project-2 is EXPECTED but never reported, and it now appears WITH a named
# reason rather than being silently absent. That is the fix: 8 boxes whose
# tokens are refused by the usage endpoint (403, user:profile) used to render
# identically to the one box that genuinely has no meter.
assert set(accounts) == {"hub", "project-4", "project-3", "badstamp", "project-2"}, accounts
assert "meter_unavailable" in accounts["project-2"], accounts["project-2"]
assert "meter_usd" not in accounts["project-2"], "an unavailable box must NOT carry a meter figure"
# ...and a box that DID report must not be labelled unavailable.
assert "meter_unavailable" not in accounts["hub"], accounts["hub"]
assert set(accounts["hub"]) == {"meter_usd", "enabled", "in_overage", "resets_at",
                                "window_verified", "observed_at", "tracking_since"}, accounts["hub"]
assert accounts["hub"]["meter_usd"] == 18863.13, accounts["hub"]
assert accounts["project-4"]["meter_usd"] == 250.00, accounts["project-4"]
# project-3's window has rolled: reported, but its live meter is unknown, not 0.
assert accounts["project-3"]["meter_usd"] is None, accounts["project-3"]

# THE MONEY ASSERTION: 18863.13 + 250.00, and nothing else silently added.
assert total == 19113.13, total
assert total != 19113.13 + 9999.00, "a stale-window meter was summed as if current"
# badstamp reported $4,242 but its freshness is unverifiable. Summing it would
# put an unverified number inside a figure captioned as verified.
assert accounts["badstamp"]["meter_usd"] == 4242.00, accounts["badstamp"]
assert accounts["badstamp"]["window_verified"] is False, accounts["badstamp"]
assert total != 19113.13 + 4242.00, "an unverified-window meter was summed"
assert "badstamp" in note, note

# Everything not summed is NAMED. A total that quietly excludes accounts is
# the same lie as one that counts them as zero.
assert "project-2" in note, note      # expected, never reported
assert "project-3" in note, note            # reported, not summable
assert "NOT zero" in note, note
assert "Mac" in note, note             # the set's known boundary, stated
PY

# A fleet where NOTHING reported must total 0 with every box named — not a
# confident zero standing alone.
rm -f "$T/overage"/*.csv
printf 'hub\nproject-4\n' > "$T/overage/EXPECTED"
python3 - "$T" <<'PY' && ok || bad "an all-missing fleet must name every box rather than report a bare 0"
import sys, importlib.util
T = sys.argv[1]
spec = importlib.util.spec_from_file_location("core", f"{T}/core.py")
core = importlib.util.module_from_spec(spec); sys.argv = ["core", T]
spec.loader.exec_module(core)
accounts, total, note = core.overage_accounts()
# Every expected box appears with a REASON. An empty dict would say "no
# accounts", which is a different and wronger claim than "these accounts could
# not be read".
assert set(accounts) == {"hub", "project-4"}, accounts
assert all("meter_unavailable" in v for v in accounts.values()), accounts
assert total == 0, total
assert "hub" in note and "project-4" in note, note
assert "NOT zero" in note, note
PY

# --- 7. THE TWO NOTHINGS MUST BE NAMED BY THE FAILURE ITSELF ----------------
# The shipped classifier could never fire. It read $ROW (STDOUT — but a 403
# raises and writes STDERR, so ROW is empty) plus a tail of agent-rules.log,
# whose only writer of those strings is THIS BRANCH — so it required its own
# prior output to trigger and took the else forever. All 8 boxes reported a
# permanent capability gap as "poll failed (transient?)": exactly the
# conflation the code was added to end.
#
# A shared, mutable, sticky log is the wrong evidence twice: another lane's 403
# misclassifies this one, and once fired, this branch's own message makes a
# later genuine timeout read as a 403. The failure must name ITSELF, from the
# output it produced on this run.
grep -q '2>"\$ERRF"' "$TRACK" \
  && ok || bad "the poll's STDERR is not captured — a 403 raises to stderr, so there is nothing to classify from"
grep -q 'grep -qiE .*"\$ERRF"' "$TRACK" \
  && ok || bad "the classifier does not read this run's stderr file"
# Targeted at the CLASSIFIER line, not at any line mentioning both: the branch
# legitimately WRITES its alert into agent-rules.log, and an earlier version of
# this assertion matched that write and cried wolf. What must not happen is the
# classifier READING that log.
grep -nE 'grep -qiE.*agent-rules\.log|tail .*agent-rules\.log.*\|.*grep -qiE' "$TRACK" \
  && bad "the classifier still reads the shared agent-rules.log — sticky, mutable, and written by itself" || ok

# Behaviour: three inputs, three distinct verdicts.
CLS=$(grep -oE "grep -qiE '[^']+'" "$TRACK" | head -1 | sed "s/grep -qiE '//;s/'\$//")
[ -n "$CLS" ] && ok || bad "could not extract the classifier pattern"
verdict() { printf '%s' "$1" > "$T/err"; if grep -qiE "$CLS" "$T/err" 2>/dev/null; then echo NAMED; else echo TRANSIENT; fi; }
[ "$(verdict 'urllib.error.HTTPError: HTTP Error 403: Forbidden')" = NAMED ] \
  && ok || bad "a 403 must be NAMED as a capability gap"
[ "$(verdict 'OAuth token does not meet scope requirement user:profile')" = NAMED ] \
  && ok || bad "the scope error must be NAMED"
[ "$(verdict 'socket.timeout: timed out')" = TRANSIENT ] \
  && ok || bad "a timeout must NOT be named as a permanent capability gap"
[ "$(verdict '')" = TRANSIENT ] \
  && ok || bad "empty stderr must not be read as a 403 — that is inventing a diagnosis"

echo "overage-per-box-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
