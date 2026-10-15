#!/bin/bash
# tests/hub-load-baseline.bh-6939-test.sh — BH-6939 (rest of #6882): the 24 h
# hub load baseline, bin/hub-load-baseline.sh, run as shipped in a scratch
# harness. The clock is HUB_LOAD_NOW. GitHub is a stub lib at
# HUB_LOAD_BASELINE_GH_LIB that records each call and returns a set rc.
#
#   B1  not ready: NOW = T0+86399 waits, no baseline.txt, no GitHub call;
#       no tsv is no-data
#   B2  numbers: the 150-line fixture over 25 h, the last 6 lines out of the
#       window; p50/p90/mean match values computed by hand
#   B3  NA: every steal NA reports NA, never 0; na= counts are right
#   B4  --print writes no state file and calls no stub
#   B5  post: empty comment list, post rc 0 -> posted; body and target
#   B6  post fails: rc 75 -> attempts 1, baseline.txt present, no posted
#   B7  marker: the exact marker -> no post, posted ... found; a marker for
#       another T0 or the name in prose -> the post happens
#   B8  terminal: posted -> the next run calls no stub
#   B9  give up: 6 failed runs -> gave-up and exactly 1 ALERTS line; a 7th
#       run adds none and calls no stub
#   B10 knob: row 42 posts on #42 issue=42(row); abc -> 6881 issue=6881(default)
#   B11 sandbox with no stub lib: not-configured, no network; the real sampler
#       run writes a baseline= line after its summary line
#
# Run from anywhere: tests/hub-load-baseline.bh-6939-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT_REL=bin/hub-load-baseline.sh
FIX="$REPO/tests/fixtures/hub-load-baseline"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags"
[ -s "$REPO/$SCRIPT_REL" ] && ok "source exists: $SCRIPT_REL" || bad "missing source $SCRIPT_REL"
# The sampler runs it only when it is executable ([ -x ]), and setup chmods the
# scratch copy, so the mode is checked on the source.
[ -x "$REPO/$SCRIPT_REL" ] && ok "source is executable: $SCRIPT_REL" || bad "not executable: $SCRIPT_REL (the sampler would skip it)"
for L in "$SCRIPT_REL" bin/hub-load-sample.sh bin/jobs-client.sh bin/lane-alert.sh; do
  [ -f "$REPO/$L" ] || continue
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null
# The real client needs its modules beside it (B10 swaps a stub in and back).
[ -r "$H/bin/lib/jobs/settings.sh" ] && [ -r "$H/bin/lib/jobs/jobs.sh" ] \
  && ok "closure installs bin/lib/jobs modules" || bad "closure lacks bin/lib/jobs modules"
cp -p "$H/bin/jobs-client.sh" "$T/jobs-client.real" 2>/dev/null

DIR_HL="$H/state/hub-load"
LOG="$H/logs/hub-load-baseline.log"
STATE="$DIR_HL/baseline.state"
REPORT="$DIR_HL/baseline.txt"
T0=2026-10-03T18:00:00Z
T0E=$(date -u -d "$T0" +%s)
MARK="<!-- hub-load-baseline:$T0 -->"

# The GitHub stub lib: every call appends one line to $T/calls; the comment
# read prints $T/comments.json; the post copies its body to $T/body.md.
GHLIB="$T/ghlib.sh"
cat > "$GHLIB" <<EOF
gh_auth_for() { echo "auth \$1" >> "$T/calls"; return 0; }
gh_auth_reset() { :; }
gh_rest_issue_comments() {
  echo "read \$1 \$2" >> "$T/calls"
  [ -e "$T/read.fail" ] && return 75
  cat "$T/comments.json"
}
gh_rest_comment() {
  echo "post \$1 \$2" >> "$T/calls"
  cp "\$3" "$T/body.md"
  return \$(cat "$T/post.rc")
}
EOF
# A gh on PATH that records it ran: no path in this script may reach it.
STUB="$T/stub"; mkdir -p "$STUB"
printf '#!/bin/bash\ntouch "%s/gh.ran"\nexit 1\n' "$T" > "$STUB/gh"
chmod +x "$STUB/gh"

reset() {
  scratch_rm "$DIR_HL"; mkdir -p "$DIR_HL"
  : > "$LOG"; : > "$H/logs/ALERTS.log"
  rm -f "$T/calls" "$T/body.md" "$T/read.fail" "$T/gh.ran"
  echo '[]' > "$T/comments.json"; echo 0 > "$T/post.rc"
  cp -p "$T/jobs-client.real" "$H/bin/jobs-client.sh"
  [ -n "${1:-}" ] && cp "$FIX/$1"/*.tsv "$DIR_HL/"
  return 0
}
# run <now> [args...] — the script as the sampler calls it, with the stub lib.
run() {
  local now="$1"; shift
  env PATH="$STUB:$PATH" HARNESS="$H" HARNESS_REPO=Example/fixture-repo HUB_LOAD_NOW="$now" \
    HUB_LOAD_BASELINE_GH_LIB="${GHLIB_OVERRIDE-$GHLIB}" HARNESS_TEST_SANDBOX=1 \
    "$H/$SCRIPT_REL" "$@" > "$T/run.out" 2>&1
  RC=$?
}
lastlog() { tail -1 "$LOG" 2>/dev/null; }
ncalls() { grep -c "^${1}" "$T/calls" 2>/dev/null || true; }
nalerts() { grep -c 'hub-load' "$H/logs/ALERTS.log" 2>/dev/null || true; }
# stub_client <row> — a jobs client whose setting_get answers the issue knob
stub_client() {
  printf 'setting_get() { [ "$1" = hub_load.baseline_issue ] && { printf %%s %q; return 0; }; return 2; }\n' "$1" > "$H/bin/jobs-client.sh"
}

# ── B1 not ready ─────────────────────────────────────────────────────────────
reset full; run $((T0E + 86399))
[ "$RC" = 0 ] && ok "B1 exit 0" || bad "B1 exit $RC: $(head -5 "$T/run.out")"
lastlog | grep -q 'baseline=waiting(1h left)' && ok "B1 T0+86399: baseline=waiting(1h left)" || bad "B1 log: $(lastlog)"
[ ! -e "$REPORT" ] && ok "B1 no baseline.txt" || bad "B1 baseline.txt written"
[ ! -e "$T/calls" ] && ok "B1 no GitHub call" || bad "B1 calls: $(cat "$T/calls")"
[ ! -e "$STATE" ] && ok "B1 no state" || bad "B1 state: $(cat "$STATE")"
reset; run $((T0E + 86400))
lastlog | grep -q 'baseline=no-data' && ok "B1 no tsv: baseline=no-data" || bad "B1 no-data: $(lastlog)"
reset; printf 'garbage\trunnable=1\n' > "$DIR_HL/2026-10-03.tsv"; run $((T0E + 86400))
lastlog | grep -q 'baseline=no-data' && ok "B1 only unparsable lines: no-data" || bad "B1 unparsable: $(lastlog)"

# ── B2 numbers ───────────────────────────────────────────────────────────────
reset full; run $((T0E + 86400)) --print
P="$T/run.out"
[ "$RC" = 0 ] && ok "B2 --print exit 0" || bad "B2 exit $RC"
grep -qx "window $T0 to 2026-10-04T18:00:00Z" "$P" && ok "B2 window T0 to T0+24 h" || bad "B2 window: $(cat "$P")"
grep -qx 'lines 144/144' "$P" && ok "B2 lines 144/144 (6 past T0+24 h out, garbage out)" || bad "B2 lines: $(grep lines "$P")"
grep -qx 'runnable p50=17.75 p90=31.95 mean=17.75 n=143 na=1' "$P" && ok "B2 runnable p50/p90, abc counted NA" || bad "B2 runnable: $(grep runnable "$P")"
grep -qx 'steal p50=3 p90=6 mean=2.97 n=108 na=36' "$P" && ok "B2 steal p50" || bad "B2 steal: $(grep steal "$P")"
grep -qx 'forks_s p50=20.5 p90=40.5 mean=20.5 n=143 na=1' "$P" && ok "B2 forks/s p50 and mean" || bad "B2 forks: $(grep forks_s "$P")"

# ── B3 NA ────────────────────────────────────────────────────────────────────
reset short; run $((T0E + 86400)) --print
grep -qx 'steal p50=NA p90=NA mean=NA n=0 na=20' "$T/run.out" && ok "B3 every steal NA: NA, never 0" || bad "B3 steal: $(grep steal "$T/run.out")"
grep -qx 'runnable p50=10.5 p90=18.1 mean=10.5 n=20 na=0' "$T/run.out" && ok "B3 runnable on the short file" || bad "B3 runnable: $(grep runnable "$T/run.out")"
grep -qx 'lines 20/144' "$T/run.out" && ok "B3 coverage 20/144" || bad "B3 lines: $(grep lines "$T/run.out")"

# ── B4 --print is read-only ──────────────────────────────────────────────────
reset full; run $((T0E + 86400)) --print
[ ! -e "$REPORT" ] && [ ! -e "$STATE" ] && ok "B4 --print writes no state" || bad "B4 state: $(ls "$DIR_HL")"
[ ! -e "$T/calls" ] && ok "B4 --print calls no stub" || bad "B4 calls: $(cat "$T/calls")"
reset full; run $((T0E + 86399)) --print
grep -q 'baseline=waiting(1h left)' "$T/run.out" && ok "B4 --print before T0+24 h says waiting" || bad "B4 waiting: $(cat "$T/run.out")"

# ── B5 post ──────────────────────────────────────────────────────────────────
reset full; run $((T0E + 86400))
[ "$RC" = 0 ] && ok "B5 exit 0" || bad "B5 exit $RC: $(head -5 "$T/run.out")"
grep -q "^posted [^ ]* [0-9a-z]*" "$STATE" 2>/dev/null && ok "B5 state posted" || bad "B5 state: $(cat "$STATE" 2>/dev/null)"
grep -qx 'post Example/fixture-repo 6881' "$T/calls" && ok "B5 posted on HARNESS_REPO #6881" || bad "B5 calls: $(cat "$T/calls" 2>/dev/null)"
grep -qx 'auth Example/fixture-repo' "$T/calls" && ok "B5 App token armed for HARNESS_REPO" || bad "B5 auth: $(cat "$T/calls" 2>/dev/null)"
grep -qF "$MARK" "$T/body.md" 2>/dev/null && ok "B5 body ends with the marker" || bad "B5 marker: $(tail -2 "$T/body.md" 2>/dev/null)"
[ "$(tail -1 "$T/body.md" 2>/dev/null)" = "$MARK" ] && ok "B5 the marker is the last line" || bad "B5 last line: $(tail -1 "$T/body.md" 2>/dev/null)"
grep -q '| Runnable processes | 17.75 | 31.95 |' "$T/body.md" 2>/dev/null && ok "B5 body: runnable p50/p90" || bad "B5 runnable row: $(grep -i runnable "$T/body.md" 2>/dev/null)"
grep -q '| Steal (%) | 3 |' "$T/body.md" 2>/dev/null && ok "B5 body: steal p50" || bad "B5 steal row"
grep -q '| Forks per second | 20.5 | 40.5 | 20.5 |' "$T/body.md" 2>/dev/null && ok "B5 body: forks/s p50 and mean" || bad "B5 forks row"
grep -q "$T0 to 2026-10-04T18:00:00Z" "$T/body.md" 2>/dev/null && ok "B5 body: the window" || bad "B5 window"
grep -q 'Coverage: 144/144' "$T/body.md" 2>/dev/null && ok "B5 body: coverage" || bad "B5 coverage"
grep -qx 'Source: state/hub-load/\*.tsv on the hub, bin/hub-load-baseline.sh' "$T/body.md" 2>/dev/null && ok "B5 body: source line" || bad "B5 source"
grep -qx 'runnable p50=17.75 p90=31.95 mean=17.75 n=143 na=1' "$REPORT" 2>/dev/null && ok "B5 baseline.txt holds the numbers" || bad "B5 report: $(cat "$REPORT" 2>/dev/null)"
lastlog | grep -q 'baseline=posted issue=6881(default)' && ok "B5 log baseline=posted" || bad "B5 log: $(lastlog)"
[ ! -e "$T/gh.ran" ] && ok "B5 no raw gh" || bad "B5 raw gh ran"

# ── B6 post fails ────────────────────────────────────────────────────────────
reset full; echo 75 > "$T/post.rc"; run $((T0E + 86400))
[ "$RC" = 0 ] && ok "B6 exit 0" || bad "B6 exit $RC"
[ "$(cat "$STATE" 2>/dev/null)" = "attempts 1" ] && ok "B6 attempts 1, not posted" || bad "B6 state: $(cat "$STATE" 2>/dev/null)"
[ -s "$REPORT" ] && ok "B6 baseline.txt present after a failed send" || bad "B6 no baseline.txt"
lastlog | grep -q 'baseline=post-failed' && ok "B6 log post-failed" || bad "B6 log: $(lastlog)"
reset full; touch "$T/read.fail"; run $((T0E + 86400))
[ "$(cat "$STATE" 2>/dev/null)" = "attempts 1" ] && [ "$(ncalls post)" = 0 ] && ok "B6 read fails: attempts 1, no post" || bad "B6 read: $(cat "$STATE" 2>/dev/null) $(cat "$T/calls")"
lastlog | grep -q 'baseline=read-failed' && ok "B6 log read-failed" || bad "B6 read log: $(lastlog)"
reset full; echo 'not json' > "$T/comments.json"; run $((T0E + 86400))
[ "$(ncalls post)" = 0 ] && lastlog | grep -q 'baseline=read-failed' && ok "B6 unparsable comment list: read-failed, no post" || bad "B6 bad json: $(lastlog)"

# ── B7 marker ────────────────────────────────────────────────────────────────
reset full; jq -n --arg b "numbers below
$MARK" '[{id: 1, body: "unrelated"}, {id: 2, body: $b}]' > "$T/comments.json"
run $((T0E + 86400))
[ "$(ncalls post)" = 0 ] && ok "B7 exact marker: no post" || bad "B7 calls: $(cat "$T/calls")"
grep -q '^posted .* found$' "$STATE" 2>/dev/null && ok "B7 state posted ... found" || bad "B7 state: $(cat "$STATE" 2>/dev/null)"
reset full; jq -n '[{id: 1, body: "```\n<!-- hub-load-baseline:2026-09-01T00:00:00Z -->\n```"}, {id: 2, body: "the hub-load-baseline script posts here"}]' > "$T/comments.json"
run $((T0E + 86400))
[ "$(ncalls post)" = 1 ] && grep -q '^posted ' "$STATE" && ! grep -q 'found' "$STATE" \
  && ok "B7 other T0 in a code block and name in prose: post happens" || bad "B7 negatives: $(cat "$T/calls") $(cat "$STATE" 2>/dev/null)"

# ── B8 terminal ──────────────────────────────────────────────────────────────
rm -f "$T/calls"; run $((T0E + 87000))
[ ! -e "$T/calls" ] && ok "B8 posted: the next run calls no stub" || bad "B8 calls: $(cat "$T/calls")"
lastlog | grep -q 'baseline=posted' && ok "B8 log baseline=posted" || bad "B8 log: $(lastlog)"

# ── B9 give up ───────────────────────────────────────────────────────────────
reset full; echo 75 > "$T/post.rc"
for i in 1 2 3 4 5; do run $((T0E + 86400 + i * 600)); done
[ "$(cat "$STATE" 2>/dev/null)" = "attempts 5" ] && [ "$(nalerts)" = 0 ] && ok "B9 5 failures: attempts 5, no ALERTS line" || bad "B9 after 5: $(cat "$STATE" 2>/dev/null) alerts=$(nalerts)"
run $((T0E + 86400 + 6 * 600))
grep -q '^gave-up ' "$STATE" 2>/dev/null && ok "B9 6th failure: gave-up" || bad "B9 state: $(cat "$STATE" 2>/dev/null)"
[ "$(nalerts)" = 1 ] && ok "B9 exactly 1 ALERTS line" || bad "B9 alerts=$(nalerts): $(cat "$H/logs/ALERTS.log")"
grep 'hub-load' "$H/logs/ALERTS.log" | grep -q '#6881' && grep 'hub-load' "$H/logs/ALERTS.log" | grep -q 'state/hub-load/baseline.txt' \
  && ok "B9 the line names the issue and baseline.txt" || bad "B9 line: $(cat "$H/logs/ALERTS.log")"
rm -f "$T/calls"; run $((T0E + 86400 + 7 * 600))
[ "$(nalerts)" = 1 ] && [ ! -e "$T/calls" ] && ok "B9 7th run: no new line, no stub call" || bad "B9 7th: alerts=$(nalerts) calls=$(cat "$T/calls" 2>/dev/null)"
lastlog | grep -q 'baseline=gave-up' && ok "B9 log baseline=gave-up" || bad "B9 log: $(lastlog)"

# ── B10 knob ─────────────────────────────────────────────────────────────────
reset full; stub_client 42; run $((T0E + 86400))
grep -qx 'post Example/fixture-repo 42' "$T/calls" 2>/dev/null && lastlog | grep -q 'issue=42(row)' \
  && ok "B10 row 42: posts on #42, issue=42(row)" || bad "B10 row: $(cat "$T/calls" 2>/dev/null) $(lastlog)"
reset full; stub_client abc; run $((T0E + 86400))
grep -qx 'post Example/fixture-repo 6881' "$T/calls" 2>/dev/null && lastlog | grep -q 'issue=6881(default)' \
  && ok "B10 abc: 6881, issue=6881(default)" || bad "B10 abc: $(cat "$T/calls" 2>/dev/null) $(lastlog)"

# ── B11 sandbox and sampler ──────────────────────────────────────────────────
reset full; GHLIB_OVERRIDE='' run $((T0E + 86400))
lastlog | grep -q 'baseline=not-configured' && ok "B11 sandbox, no stub lib: not-configured" || bad "B11 log: $(lastlog)"
[ ! -e "$T/gh.ran" ] && [ ! -e "$T/calls" ] && ok "B11 no network call" || bad "B11 network"
[ -s "$REPORT" ] && [ ! -e "$STATE" ] && ok "B11 baseline.txt written, no attempt counted" || bad "B11 state: $(cat "$STATE" 2>/dev/null)"

# The real sampler, with the BH-6882 suite's stubs, appends its own tsv line;
# the baseline reads that line (it is T0 here) and logs after the summary.
cat > "$STUB/ps" <<'EOF'
#!/bin/bash
printf '%5d %5d R    bash            /bin/bash /root/harness/bin/fly-pool.sh\n' 100 1
EOF
printf '#!/bin/bash\nexit 0\n' > "$STUB/sleep"; printf '#!/bin/bash\nexit 1\n' > "$STUB/vmstat"
chmod +x "$STUB/ps" "$STUB/sleep" "$STUB/vmstat"
reset
SNOW=$T0E
env PATH="$STUB:$PATH" HARNESS="$H" HUB_LOAD_NOW="$SNOW" HUB_LOAD_SAMPLES=2 HUB_LOAD_INTERVAL_S=0 \
  HUB_LOAD_FORK_WINDOW_S=0 BOX_NAME=hub HARNESS_TEST_SANDBOX=1 HARNESS_REPO=Example/fixture-repo \
  HUB_LOAD_BASELINE_GH_LIB="$GHLIB" "$H/bin/hub-load-sample.sh" > "$T/run.out" 2>&1
SL=$(tail -1 "$H/logs/hub-load-sample.log" 2>/dev/null)
[[ "$SL" == *"runnable=1.00"* ]] && ok "B11 sampler summary is still its log's last line" || bad "B11 sampler log: $SL"
[ "$(cut -f1 "$DIR_HL/2026-10-03.tsv" 2>/dev/null)" = "$T0" ] && ok "B11 sampler wrote its tsv line" || bad "B11 tsv: $(cat "$DIR_HL"/*.tsv 2>/dev/null)"
lastlog | grep -q 'baseline=waiting(24h left)' && ok "B11 the sampler ran the baseline: waiting(24h left) on its own line" || bad "B11 baseline log: $(lastlog)"
# 24 h later the baseline, run by the sampler, reads the sampler's own line.
env PATH="$STUB:$PATH" HARNESS="$H" HUB_LOAD_NOW=$((SNOW + 86400)) HUB_LOAD_SAMPLES=2 HUB_LOAD_INTERVAL_S=0 \
  HUB_LOAD_FORK_WINDOW_S=0 BOX_NAME=hub HARNESS_TEST_SANDBOX=1 HARNESS_REPO=Example/fixture-repo \
  HUB_LOAD_BASELINE_GH_LIB="$GHLIB" "$H/bin/hub-load-sample.sh" > "$T/run.out" 2>&1
grep -qx 'runnable p50=1 p90=1 mean=1 n=1 na=0' "$REPORT" 2>/dev/null && ok "B11 the baseline read the sampler's tsv" || bad "B11 report: $(cat "$REPORT" 2>/dev/null)"
grep -q '^posted ' "$STATE" 2>/dev/null && lastlog | grep -q 'baseline=posted' && ok "B11 posted through the sampler" || bad "B11 posted: $(cat "$STATE" 2>/dev/null) $(lastlog)"

# ── lock held ────────────────────────────────────────────────────────────────
reset full; exec 9> "$H/locks/hub-load-baseline.lock"; flock -n 9
run $((T0E + 86400))
exec 9>&-
lastlog | grep -q 'baseline=skipped (running)' && [ ! -e "$T/calls" ] && [ ! -e "$STATE" ] \
  && ok "lock held: skipped (running), no change" || bad "lock: $(lastlog)"

echo
echo "hub-load-baseline: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
