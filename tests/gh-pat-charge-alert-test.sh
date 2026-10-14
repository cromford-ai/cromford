#!/bin/bash
# tests/gh-pat-charge-alert-test.sh — bin/gh-pat-charge-alert.sh: ONE
# logs/ALERTS.log line per (box, PAT bucket, UTC day) whenever a fleet lane was
# charged to a personal access token in the last complete UTC hour.
#
# WHY. The fleet is migrating to "App tokens everywhere, keyring logged out".
# On 2026-09-24 the hub alone charged ~330 calls/hour to `pat-default` (gh's
# keyring login, operator): blocked-resolver.sh 213, tickets-snapshot-push.sh 101,
# wake-loop.sh 11, pipeline-health.sh 4 — and five more boxes had PAT callers.
# bin/gh-quota-report.sh only REPORTS; nothing said so unless someone asked.
# This lane is the tracker that counts that migration down to zero.
#
# What is pinned, with the harness-jobs worker stubbed as a `curl` on PATH that
# answers GET /api/metrics/gh-ledger from $T/read.json (the same read
# bin/gh-quota-report.sh --fleet makes):
#   A. an App-only hour writes no alert, one lane-log line, rc 0;
#   B. pat-default rows => ONE alert for that box naming the bucket in words,
#      the counted total, and the top 3 callers with counts (a caller's rows
#      across path classes are summed; the 4th caller is not named), plus the
#      remedy pointer (bin/lib/gh-app-auth.sh); a pat-<sha> bucket on another
#      box is its own line and reads "a PAT exported as GH_TOKEN";
#   C. a second run for the same UTC day writes no second line;
#   D. a graphql-pat-* row counts as a PAT charge;
#   E. counted=0 rows (304 / 000) do not count;
#   F. the threshold (GH_PAT_CHARGE_ALERT_MIN) is honoured;
#   G. the kill switch (flags/lane-off-gh-pat-charge-alert, GH_PAT_CHARGE_ALERT=0)
#      writes nothing;
#   H. an unreachable worker falls back to this box's own ledger file and SAYS
#      so, in the lane log and in the alert;
#   I. no token-shaped string ever reaches stdout, the lane log or ALERTS.log;
#   J. zero GitHub API calls: no `gh` invoked, no github.com URL requested;
#   K. the default hour is the last COMPLETE UTC hour, since == until.
#
# Run from anywhere: bash tests/gh-pat-charge-alert-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 33 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LANE="$DIR/bin/gh-pat-charge-alert.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

HOUR=2026-09-24T10   # determinism: ok pinned — every run names its hour
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state/gh-rest-ledger" "$T/h/flags" "$T/h/env" "$T/fake" "$T/req" "$T/tmp"
ln -s "$DIR/bin" "$T/h/bin"
export TMPDIR="$T/tmp" HARNESS_ENV_DIR="$T/h/env"
export HARNESS_SECRET=test-secret JOBS_URL=http://jobs.test JOBS_RETRIES=0 BOX_ID=hub
# Token-shaped values in the environment the lane inherits: none of them may
# ever be printed (section I). Each carries "FIXTURE" so the share-mirror
# leakcheck (bin/share/mapping.py FIXTURE_MARKERS) knows it for a fake.
export GH_TOKEN=ghp_FIXTUREFAKEFAKEFAKEFAKEFAKEFAKE0001
export GITHUB_TOKEN=github_pat_FIXTUREFAKEFAKEFAKE_0002
export GH_ADMIN_TOKEN=ghs_FIXTUREFAKEFAKEFAKEFAKEFAKE0003
export PATH="$T/fake:$PATH"
ALERTS="$T/h/logs/ALERTS.log"
LOG="$T/h/logs/gh-pat-charge-alert.log"
export STUB_DIR="$T"

# ── the worker, as a curl stub (same shape as tests/gh-ledger-fleet.bh-1574) ──
cat > "$T/fake/curl" <<'SH'
#!/bin/bash
D="$STUB_DIR"; M=GET; URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) M="$2"; shift 2 ;;
    -H|-m|--connect-timeout|-w|-o|-D|--data-binary|-d|--data) shift 2 ;;
    http*) URL="$1"; shift ;;
    *) shift ;;
  esac
done
printf '%s %s\n' "$M" "$URL" >> "$D/req/all.lines"
code="${STUB_CODE:-200}"
case "$URL" in
  */api/metrics/gh-ledger\?*) [ -f "$D/read.json" ] && cat "$D/read.json" || printf '{"rows":[],"truncated":false}' ;;
  *) code=404; printf '{"error":"unknown endpoint"}' ;;
esac
printf '\n%s' "$code"
SH
# `gh` must never run: any invocation is recorded and fails the J section.
cat > "$T/fake/gh" <<'SH'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$STUB_DIR/req/gh.calls"
exit 1
SH
chmod +x "$T/fake/curl" "$T/fake/gh"

# row <box> <lane> <meter> <resource> <path_class> <calls> <counted> — one D1 row
row() { jq -nc --arg b "$1" --arg l "$2" --arg m "$3" --arg r "$4" --arg p "$5" \
  --argjson c "$6" --argjson k "$7" \
  '{box:$b,lane:$l,meter:$m,resource:$r,path_class:$p,calls:$c,counted:$k,remaining_min:4000,used_max:900,limit_max:5000}'; }
read_json() { jq -sc '{rows: ., truncated: false, since: "'"$HOUR"'", until: "'"$HOUR"'"}'; }
reset() { rm -rf "$T/h/state/gh-pat-charge-alert" "$T/req/"* "$T/read.json"; : > "$ALERTS"; : > "$LOG"; rm -f "$T/h/flags/"*; }
run() { bash "$LANE" > "$T/out" 2>&1; echo $? > "$T/rc"; }
nalerts() { grep -c '\[gh-pat-charge-alert\]' "$ALERTS" 2>/dev/null | tr -dc 0-9; }
alert_for() { grep '\[gh-pat-charge-alert\]' "$ALERTS" | grep -F " $1:" ; }
export GH_PAT_CHARGE_ALERT_HOUR="$HOUR"

[ -x "$LANE" ] && ok || bad "0: bin/gh-pat-charge-alert.sh must exist and be executable"

# ══ A. App-only hour ═════════════════════════════════════════════════════════
reset
{ row hub merge-conductor app-161623167 core 'repos/o/r/pulls/N' 400 380
  row small review-prs.sh app-163842147 core 'repos/o/r/pulls/N' 50 50
  row hub merge-conductor graphql-app-161623167 graphql graphql 10 10
} | read_json > "$T/read.json"
run
[ "$(cat "$T/rc")" = 0 ] && ok || bad "A1: rc 0, got $(cat "$T/rc"): $(cat "$T/out")"
[ "$(nalerts)" = 0 ] && ok || bad "A2: an App-only hour writes no alert, got: $(cat "$ALERTS")"
[ "$(grep -c . "$LOG")" = 1 ] && ok || bad "A3: one lane-log line per run, got: $(cat "$LOG")"
grep -q "hour=$HOUR" "$LOG" && ok || bad "A4: the lane log names the hour, got: $(cat "$LOG")"
grep -q 'source=fleet' "$LOG" && ok || bad "A5: the lane log names the fleet source, got: $(cat "$LOG")"
grep -q "since=$HOUR&until=$HOUR" "$T/req/all.lines" 2>/dev/null && ok \
  || bad "A6: the read is the gh-quota-report fleet read bounded to ONE hour, got: $(cat "$T/req/all.lines" 2>/dev/null)"

# ══ B. pat-default + pat-<sha> ═══════════════════════════════════════════════
reset
{ row hub blocked-resolver.sh pat-default core 'repos/o/r/issues/N' 150 150
  row hub blocked-resolver.sh pat-default core 'repos/o/r/pulls/N' 63 63
  row hub tickets-snapshot-push.sh pat-default core 'repos/o/r/issues' 101 101
  row hub wake-loop.sh pat-default core 'repos/o/r/pulls' 11 11
  row hub pipeline-health.sh pat-default core 'repos/o/r/actions/runs' 4 4
  row hub merge-conductor app-161623167 core 'repos/o/r/pulls/N' 900 900
  row small run-preplan.sh pat-3f2a9c1d0b4e core 'repos/o/r/issues/N' 7 7
} | read_json > "$T/read.json"
run
[ "$(cat "$T/rc")" = 0 ] && ok || bad "B0: rc 0, got $(cat "$T/rc")"
[ "$(nalerts)" = 2 ] && ok || bad "B1: one alert per (box, bucket), expected 2, got: $(cat "$ALERTS")"
L=$(alert_for hub)
case "$L" in *"pat-default = the gh keyring login (operator)"*) ok ;; *) bad "B2: the bucket in words, got: $L" ;; esac
case "$L" in *" 329 counted "*) ok ;; *) bad "B3: the counted total (329) for the hour, got: $L" ;; esac
case "$L" in *"blocked-resolver.sh 213, tickets-snapshot-push.sh 101, wake-loop.sh 11"*) ok ;;
  *) bad "B4: the top 3 callers with summed counts, in order, got: $L" ;; esac
case "$L" in *pipeline-health.sh*) bad "B5: only the top 3 callers are named, got: $L" ;; *) ok ;; esac
case "$L" in *gh_default_auth_for_slug*gh_auth_for*bin/lib/gh-app-auth.sh*) ok ;; *) bad "B6: the remedy pointer, got: $L" ;; esac
case "$L" in *"$HOUR"*) ok ;; *) bad "B7: the alert names the hour, got: $L" ;; esac
case "$L" in *merge-conductor*) bad "B8: an App row is not a PAT caller, got: $L" ;; *) ok ;; esac
S=$(alert_for small)
case "$S" in *"pat-3f2a9c1d0b4e = a PAT exported as GH_TOKEN"*) ok ;; *) bad "B9: a pat-<sha> bucket in words, got: $S" ;; esac
case "$S" in *"run-preplan.sh 7"*) ok ;; *) bad "B10: the small box's caller, got: $S" ;; esac

# ══ C. same UTC day: no second line ══════════════════════════════════════════
run
[ "$(nalerts)" = 2 ] && ok || bad "C1: a second run the same UTC day writes nothing new, got $(nalerts): $(cat "$ALERTS")"
[ "$(grep -c . "$LOG")" = 2 ] && ok || bad "C2: still one lane-log line per run, got: $(cat "$LOG")"
grep -q 'deduped=2' "$LOG" && ok || bad "C3: the lane log counts the deduped pairs, got: $(tail -1 "$LOG")"
GH_PAT_CHARGE_ALERT_HOUR=2026-09-24T11 run
[ "$(nalerts)" = 2 ] && ok || bad "C4: a later hour of the SAME day is still deduped, got $(nalerts)"
GH_PAT_CHARGE_ALERT_HOUR=2026-09-25T00 run
[ "$(nalerts)" = 4 ] && ok || bad "C5: the next UTC day alerts again, got $(nalerts): $(cat "$ALERTS")"

# ══ D. graphql-pat-* counts ═════════════════════════════════════════════════
reset
{ row project-5 triage graphql-pat-default graphql graphql 2 2
} | read_json > "$T/read.json"
run
[ "$(nalerts)" = 1 ] && ok || bad "D1: a graphql-pat row alerts, got: $(cat "$ALERTS")"
L=$(alert_for project-5)
case "$L" in *"graphql-pat-default = GraphQL charged to the gh keyring login (operator)"*) ok ;;
  *) bad "D2: the graphql bucket in words, got: $L" ;; esac
case "$L" in *"triage 2"*) ok ;; *) bad "D3: the caller, got: $L" ;; esac

# ══ E. counted=0 rows do not count ══════════════════════════════════════════
reset
{ row project-4 review-prs.sh pat-default core 'repos/o/r/pulls/N' 50 0
} | read_json > "$T/read.json"
run
[ "$(nalerts)" = 0 ] && ok || bad "E1: 304/000 rows (counted=0) are not a charge, got: $(cat "$ALERTS")"
grep -q 'alerted=0' "$LOG" && ok || bad "E2: the lane log says nothing was alerted, got: $(cat "$LOG")"

# ══ F. threshold ════════════════════════════════════════════════════════════
reset
{ row project-4 review-prs.sh pat-default core 'repos/o/r/pulls/N' 5 5
  row project-3-2 review-prs.sh pat-default core 'repos/o/r/pulls/N' 40 40
} | read_json > "$T/read.json"
GH_PAT_CHARGE_ALERT_MIN=10 run
[ "$(nalerts)" = 1 ] && ok || bad "F1: only the pair at/above the threshold alerts, got: $(cat "$ALERTS")"
[ -n "$(alert_for project-3-2)" ] && ok || bad "F2: project-3-2 (40 >= 10) alerts"
[ -z "$(alert_for project-4)" ] && ok || bad "F3: project-4 (5 < 10) does not"
GH_PAT_CHARGE_ALERT_MIN=garbage run
[ "$(nalerts)" = 2 ] && ok || bad "F4: a non-numeric threshold falls back to 1, got: $(cat "$ALERTS")"

# ══ G. kill switch ══════════════════════════════════════════════════════════
reset
{ row hub wake-loop.sh pat-default core 'repos/o/r/pulls' 11 11
} | read_json > "$T/read.json"
: > "$T/h/flags/lane-off-gh-pat-charge-alert"
run
[ "$(nalerts)" = 0 ] && ok || bad "G1: flags/lane-off-gh-pat-charge-alert writes no alert, got: $(cat "$ALERTS")"
[ ! -s "$LOG" ] && ok || bad "G2: ... and no lane-log line, got: $(cat "$LOG")"
grep -q 'gh-ledger' "$T/req/all.lines" 2>/dev/null && bad "G3: ... and no ledger read" || ok
rm -f "$T/h/flags/lane-off-gh-pat-charge-alert"
GH_PAT_CHARGE_ALERT=0 run
[ "$(nalerts)" = 0 ] && ok || bad "G4: GH_PAT_CHARGE_ALERT=0 writes no alert, got: $(cat "$ALERTS")"
[ ! -s "$LOG" ] && ok || bad "G5: ... and no lane-log line, got: $(cat "$LOG")"

# ══ H. worker unreachable → this box's ledger file ═════════════════════════
reset
tsv() { printf '%s\t' "$@" | sed 's/\t$//'; printf '\n'; }
{
  tsv 2026-09-24T10:00:01Z blocked-resolver.sh fleet GET 'repos/o/r/issues/N' 200 1 4000 1790143346 pat-default core rest 1000 5000
  tsv 2026-09-24T10:00:02Z blocked-resolver.sh fleet GET 'repos/o/r/issues/N' 200 1 3999 1790143346 pat-default core rest 1001 5000
  tsv 2026-09-24T10:00:03Z wake-loop.sh fleet GET 'repos/o/r/pulls' 200 1 3998 1790143346 pat-default core rest 1002 5000
  tsv 2026-09-24T10:00:04Z wake-loop.sh fleet GET 'repos/o/r/pulls' 304 0 3998 1790143346 pat-default core rest 1002 5000
  tsv 2026-09-24T10:00:05Z merge-conductor fleet GET 'repos/o/r/pulls/N' 200 1 6000 1790143346 app-161623167 core rest 600 6600
} > "$T/h/state/gh-rest-ledger/$HOUR.tsv"
STUB_CODE=500 run
[ "$(cat "$T/rc")" = 0 ] && ok || bad "H0: rc 0 on an unreachable worker, got $(cat "$T/rc")"
grep -q 'source=local' "$LOG" && ok || bad "H1: the lane log says it fell back to the local ledger, got: $(cat "$LOG")"
grep -qi 'worker unreachable\|http=' "$LOG" && ok || bad "H2: ... and why, got: $(cat "$LOG")"
[ "$(nalerts)" = 1 ] && ok || bad "H3: the local ledger still alerts, got: $(cat "$ALERTS")"
L=$(alert_for hub)
case "$L" in *" 3 counted "*) ok ;; *) bad "H4: counted from the file (the 304 excluded) = 3, got: $L" ;; esac
case "$L" in *"blocked-resolver.sh 2, wake-loop.sh 1"*) ok ;; *) bad "H5: callers from the file, got: $L" ;; esac
case "$L" in *"this box's ledger only"*) ok ;; *) bad "H6: the alert says the fleet was not read, got: $L" ;; esac
rm -f "$T/h/state/gh-rest-ledger/$HOUR.tsv"
reset
env -u HARNESS_SECRET bash "$LANE" > "$T/out" 2>&1
grep -q 'source=local' "$LOG" && ok || bad "H7: no HARNESS_SECRET is the local fallback too, got: $(cat "$LOG")"
grep -q 'no ledger' "$LOG" && ok || bad "H8: ... and an absent hour file is said, not an error, got: $(cat "$LOG")"

# ══ I. no token-shaped string anywhere ══════════════════════════════════════
if grep -rEq 'gh[pousr]_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,}|FAKEFAKE' "$T/out" "$LOG" "$ALERTS" "$T/h/state/gh-pat-charge-alert" 2>/dev/null; then
  bad "I1: a token-shaped string was written: $(grep -rhoE 'gh[pousr]_[A-Za-z0-9]{8,}|github_pat_[A-Za-z0-9_]{8,}|FAKEFAKE' "$T/out" "$LOG" "$ALERTS" 2>/dev/null | head -3)"
else ok; fi

# ══ J. zero GitHub API calls ════════════════════════════════════════════════
[ ! -s "$T/req/gh.calls" ] && ok || bad "J1: gh was invoked: $(cat "$T/req/gh.calls")"
grep -qi 'github.com' "$T/req/all.lines" 2>/dev/null && bad "J2: a github.com URL was requested: $(grep -i github.com "$T/req/all.lines")" || ok
grep -qE '(^|[^_])(gh api|gh_rest|curl[^|]*api\.github)' "$LANE" && bad "J3: the lane script must not call GitHub" || ok

# ══ K. the default hour is the last complete UTC hour ═══════════════════════
reset
unset GH_PAT_CHARGE_ALERT_HOUR
run
H1=$(grep -oE 'since=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}&until=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}' "$T/req/all.lines" 2>/dev/null | head -1)
S1=${H1#since=}; S1=${S1%%&*}; U1=${H1##*until=}
[ -n "$S1" ] && [ "$S1" = "$U1" ] && ok || bad "K1: since == until, one hour, got: '$H1'"
NOWH=$(date -u +%Y-%m-%dT%H)   # determinism: ok — compared as 'not the current hour', never equality with a clock
[ -n "$S1" ] && [ "$S1" != "$NOWH" ] && [[ "$S1" < "$NOWH" ]] && ok \
  || bad "K2: the default hour is a COMPLETE hour before now ($NOWH), got: '$S1'"

# ══ L. severity: a PAT charge is a digest item, never a critical page ════════
# poll-commands.sh re-beats every ALERTS.log line with no severity, so without a
# built-in rule ALERT_DEFAULT_SEVERITY (critical) turns each one into an
# immediate Telegram page — ~6-12 a day with the known backlog, since the day's
# counts in the text make the row key new each day. warn = the digest.
reset
{ row hub blocked-resolver.sh pat-default core 'repos/o/r/issues/N' 5 5
} | read_json > "$T/read.json"
export GH_PAT_CHARGE_ALERT_HOUR="$HOUR"
run
L=$(grep '\[gh-pat-charge-alert\]' "$ALERTS" | head -1)
SEV=$(ALERTS_CONF="$T/none.conf" HARNESS="$T/h" bash -c '. "$1/bin/lib/alert-state.sh" >/dev/null 2>&1; alert_state_route "$2" ""' _ "$DIR" "$L")
[ "$SEV" = warn ] && ok || bad "L1: a [gh-pat-charge-alert] line routes to warn (digest), got '$SEV'"
SEV=$(ALERTS_CONF="$T/none.conf" HARNESS="$T/h" bash -c '. "$1/bin/lib/alert-state.sh" >/dev/null 2>&1; alert_state_route "$2" ""' _ "$DIR" "2026-09-24 10:00:00Z [somelane] something broke")
[ "$SEV" = critical ] && ok || bad "L2: the rule is scoped — an unrelated line keeps the default, got '$SEV'"
grep -q "lane-alert.sh" "$LANE" && bad "L3: the lane must not route through lane-alert.sh (LLM triage)" || ok

# ══ M. a truncated fleet answer is said IN THE ALERT, not only in the log ═════
reset
{ row hub wake-loop.sh pat-default core 'repos/o/r/pulls' 11 11
} | jq -sc '{rows: ., truncated: true}' > "$T/read.json"
run
L=$(alert_for hub)
case "$L" in *TRUNCATED*) ok ;; *) bad "M1: a truncated fleet answer is named in the alert text, got: $L" ;; esac

# ══ N. the local-fallback box label is gh-ledger-push's own id ════════════════
# gh-ledger-push.sh takes the box id from argv (the hub cron passes `hub`); the
# lane must label its local rows the same way, or one box gets two alerts a day
# (one from the fleet read, one from the fallback) under two names.
reset
{ tsv 2026-09-24T10:00:01Z wake-loop.sh fleet GET 'repos/o/r/pulls' 200 1 3998 1790143346 pat-default core rest 1002 5000
} > "$T/h/state/gh-rest-ledger/$HOUR.tsv"
STUB_CODE=500 BOX_ID= bash "$LANE" hub > "$T/out" 2>&1
[ -n "$(alert_for hub)" ] && ok || bad "N1: argv box id labels the local fallback (as gh-ledger-push.sh hub), got: $(cat "$ALERTS")"
grep -qE '/bin/gh-pat-charge-alert\.sh hub( |$)' "$DIR/cron/lanes/712-gh-pat-charge-alert.cron" && ok \
  || bad "N2: the hub cron line passes the same box id gh-ledger-push.sh gets (hub)"
rm -f "$T/h/state/gh-rest-ledger/$HOUR.tsv"

# ══ O. an overridden FUTURE hour never prunes today's dedupe markers ══════════
reset
TODAY=$(date -u +%Y-%m-%d)   # determinism: ok — the marker dir is named by the real day, compared for existence only
mkdir -p "$T/h/state/gh-pat-charge-alert/$TODAY"; : > "$T/h/state/gh-pat-charge-alert/$TODAY/hub__pat-default"
GH_PAT_CHARGE_ALERT_HOUR=2099-01-01T00 run
[ -e "$T/h/state/gh-pat-charge-alert/$TODAY/hub__pat-default" ] && ok \
  || bad "O1: a future GH_PAT_CHARGE_ALERT_HOUR deleted today's marker ($TODAY) — today would re-alert"
mkdir -p "$T/h/state/gh-pat-charge-alert/2020-01-01"
GH_PAT_CHARGE_ALERT_HOUR=2099-01-01T00 run
[ ! -e "$T/h/state/gh-pat-charge-alert/2020-01-01" ] && ok || bad "O2: a genuinely past day's markers are still pruned"

echo "gh-pat-charge-alert: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
