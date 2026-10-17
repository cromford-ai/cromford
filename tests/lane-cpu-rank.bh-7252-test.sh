#!/bin/bash
# tests/lane-cpu-rank.bh-7252-test.sh — BH-7252 C0: bin/lane-cpu-rank.sh, the
# hub lane that ranks lanes by CPU seconds per hour and posts the table once
# to an issue. Runs the script as shipped in a scratch harness.
#   GitHub:   a stub lib at LANE_CPU_RANK_GH_LIB (sandbox seam) that records
#             each call and returns a set rc.
#   Sampler:  LANE_CPU_RANK_SAMPLER (sandbox seam), a stub that records its
#             args and prints $T/sample.out with rc $T/sample.rc. R1 fills
#             sample.out with the REAL bin/lane-cpu-sample.sh --cpu-s output
#             on a fake /proc tree.
#   Settings: a stub jobs client (setting_get, _setting_key_ok, _jobs_req).
#   Load:     LANE_CPU_RANK_LOADAVG (sandbox seam), a /proc/loadavg copy.
#
#   R1  report: header, rows by CPU s/h, other last, load5 line, marker;
#       placement fly from a lane_placement row, the hub_only text, `not
#       classified`; the sampler got --cpu-s --seconds 3600 --interval 5
#   R2  the exact marker in a comment: rank=found, state posted ... found, the
#       sampler is never started, no post
#   R3  near-miss markers (72520, no brackets, hub-load-baseline) do not count
#   R4  post, then a second run: one post in all, state posted
#   R5  issue row 7300 -> #7300 issue=7300(row); row abc -> 7252(default)
#   R6  post fails -> attempts 1, no posted; the next run retries and posts
#   R7  sampler rc 2 -> rank=sample-failed, attempts 1, no post
#   R8  LANE_CPU_RANK_TOP=2 -> 2 lane rows plus other
#   R9  no gh lib (sandbox) -> not-configured, no sampling, state unchanged
#   R10 6 failed runs -> gave-up and exactly 1 lane-alert --log-only call; a
#       7th run calls nothing
#   R11 lock held -> skipped (running), exit 0
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT_REL=bin/lane-cpu-rank.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags"
[ -x "$REPO/$SCRIPT_REL" ] && ok "source is executable: $SCRIPT_REL" || bad "missing or not executable: $SCRIPT_REL"
for L in "$SCRIPT_REL" bin/lane-cpu-sample.sh bin/lib/lane-placement.sh bin/lib/lane-gate.sh; do
  [ -f "$REPO/$L" ] || continue
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null

STATE_DIR="$H/state/lane-cpu-rank"
LOG="$H/logs/lane-cpu-rank.log"
REPORT="$STATE_DIR/report.md"
MARK='<!-- lane-cpu-rank:7252 -->'

# ── stubs ────────────────────────────────────────────────────────────────────
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
SAMPLER="$T/sampler.sh"
cat > "$SAMPLER" <<EOF
#!/bin/bash
echo "sample \$*" >> "$T/calls"
cat "$T/sample.out"
exit \$(cat "$T/sample.rc")
EOF
chmod +x "$SAMPLER"
# The lane-alert stub: one line per call.
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
echo "alert \$*" >> "$T/alerts"
EOF
chmod +x "$H/bin/lane-alert.sh"
# Settings: the rows in $T/settings.tsv (key TAB value); no row -> rc 2.
cat > "$H/bin/jobs-client.sh" <<EOF
_setting_key_ok() { [[ "\$1" =~ ^[A-Za-z0-9._-]+\$ ]]; }
_jobs_req() { return 1; }
setting_get() {
  local v
  v=\$(awk -F '\t' -v k="\$1" '\$1 == k { print \$2; f = 1 } END { exit f ? 0 : 1 }' "$T/settings.tsv") || return 2
  printf '%s' "\$v"
}
EOF
printf '30.10 28.40 27.00 3/900 12345\n' > "$T/loadavg"

# The REAL sampler's --cpu-s output on a fake /proc tree: four lanes and other.
mkproc() {
  local root="$1" pid="$2" ppid="$3" ut="$4" comm="$5"; shift 5
  mkdir -p "$root/$pid"
  printf '%s (%s) S %s %s %s 0 -1 4194304 0 0 0 0 %s 0 0 0 20 0 1 0 100\n' \
    "$pid" "$comm" "$ppid" "$pid" "$pid" "$ut" > "$root/$pid/stat"
  printf '%s\0' "$@" > "$root/$pid/cmdline"
}
tree() {
  local r="$1" s="$2"
  mkproc "$r" 1 0 0 systemd /sbin/init
  mkproc "$r" 20 1 $((s * 400)) bash bash /root/harness/bin/merge-conductor.sh
  mkproc "$r" 21 1 $((s * 300)) bash bash /root/harness/bin/blocked-resolver.sh
  mkproc "$r" 22 1 $((s * 200)) bash bash /root/harness/bin/pipeline-health.sh
  mkproc "$r" 23 1 $((s * 50)) bash bash /root/harness/bin/state-backup.sh
  mkproc "$r" 30 1 $((s * 500)) cron /usr/sbin/cron
}
mkdir -p "$T/tmpd"
tree "$T/proc" 0
( for _ in $(seq 1 200); do
    for f in "$T"/tmpd/lcs.*; do
      if [ -f "$f" ] && [ "$(wc -l < "$f" | tr -d ' ')" = 6 ]; then tree "$T/proc" 1; exit 0; fi
    done
    sleep 0.05
  done; exit 1 ) &
helper=$!
TMPDIR="$T/tmpd" LCS_CLK_TCK=100 "$H/bin/lane-cpu-sample.sh" --seconds 2 --proc-root "$T/proc" \
  --cpu-s --lane lane-cpu-sample --max-pct 100 > "$T/real-sample.out" 2>&1
echo "$?" > "$T/real-sample.rc"
wait "$helper" || bad "setup: the helper never saw the first snapshot"
grep -q $'^34.5\tother\t9000.0$' "$T/real-sample.out" && ok "setup: real --cpu-s sample has other 9000.0" \
  || bad "setup: real sample: $(cat "$T/real-sample.out")"

reset() {
  scratch_rm "$STATE_DIR" 2>/dev/null; mkdir -p "$STATE_DIR"
  : > "$LOG"; : > "$T/settings.tsv"
  rm -f "$T/calls" "$T/alerts" "$T/body.md" "$T/read.fail"
  echo '[]' > "$T/comments.json"; echo 0 > "$T/post.rc"
  cp "$T/real-sample.out" "$T/sample.out"; cp "$T/real-sample.rc" "$T/sample.rc"
  return 0
}
# run [env...] — the script as cron runs it, with the stubs.
run() {
  env HARNESS="$H" HARNESS_REPO=Example/fixture-repo HARNESS_TEST_SANDBOX=1 \
    LANE_CPU_RANK_GH_LIB="${GHLIB_OVERRIDE-$GHLIB}" LANE_CPU_RANK_SAMPLER="$SAMPLER" \
    LANE_CPU_RANK_LOADAVG="$T/loadavg" "$@" "$H/$SCRIPT_REL" > "$T/run.out" 2>&1
  RC=$?
}
lastlog() { tail -1 "$LOG" 2>/dev/null; }
ncalls() { grep -c "^${1}" "$T/calls" 2>/dev/null || true; }
state() { cat "$STATE_DIR/state-${1:-7252}" 2>/dev/null; }

# ── R1 report ────────────────────────────────────────────────────────────────
reset
printf 'lane_placement.blocked-resolver\tfly\n' >> "$T/settings.tsv"
printf 'lane_placement.state-backup.hub_only\treads the hub state | dir\n' >> "$T/settings.tsv"
run
[ "$RC" = 0 ] && ok "R1 exit 0" || bad "R1 exit $RC: $(head -5 "$T/run.out")"
lastlog | grep -q 'rank=posted issue=7252(default) rows=4 load5=28.40->28.40' && ok "R1 log line" || bad "R1 log: $(lastlog)"
[ -f "$REPORT" ] && ok "R1 report.md written" || bad "R1 no report.md"
grep -q -- "--cpu-s" "$T/calls" && grep -q -- "--seconds 3600" "$T/calls" && grep -q -- "--interval 5" "$T/calls" \
  && ok "R1 sampler args: --cpu-s --seconds 3600 --interval 5" || bad "R1 sampler args: $(grep '^sample' "$T/calls")"
TABLE=$(grep '^|' "$REPORT" 2>/dev/null)
WANT=$(cat <<'W'
| rank | lane | CPU s/h | share % | placement | hub-only reason |
|---|---|---|---|---|---|
| 1 | merge-conductor | 7200.0 | 27.6 | hub | not classified |
| 2 | blocked-resolver | 5400.0 | 20.7 | fly | not classified |
| 3 | pipeline-health | 3600.0 | 13.8 | hub | not classified |
| 4 | state-backup | 900.0 | 3.4 | hub | reads the hub state / dir |
| - | other | 9000.0 | 34.5 | - | not a lane |
W
)
# lane-cpu-sample itself also shows when the real run counts its own CPU;
# here the fixture tree has no such process, so the table is exact.
[ "$TABLE" = "$WANT" ] && ok "R1 table rows, order, placement and reasons" || bad "R1 table:
$TABLE"
grep -q '^Load (load1/load5): start 30.10/28.40, end 30.10/28.40\.$' "$REPORT" && ok "R1 load line" || bad "R1 load line: $(grep -i load "$REPORT")"
tail -1 "$REPORT" | grep -qxF "$MARK" && ok "R1 marker is the last line" || bad "R1 last line: $(tail -1 "$REPORT")"
cmp -s "$REPORT" "$T/body.md" && ok "R1 posted body = report.md" || bad "R1 body differs from report.md"
grep -q '^post Example/fixture-repo 7252$' "$T/calls" && ok "R1 posted on #7252" || bad "R1 calls: $(cat "$T/calls")"
state | grep -q '^posted .* 7252$' && ok "R1 state posted" || bad "R1 state: $(state)"

# ── R2 marker found ──────────────────────────────────────────────────────────
reset
jq -n --arg m "Table.
$MARK" '[{body:"hello"},{body:$m}]' > "$T/comments.json"
run
lastlog | grep -q 'rank=found issue=7252' && ok "R2 rank=found" || bad "R2 log: $(lastlog)"
state | grep -q '^posted .* found$' && ok "R2 state posted ... found" || bad "R2 state: $(state)"
[ "$(ncalls sample)" = 0 ] && ok "R2 sampler never started" || bad "R2 sampler ran"
[ "$(ncalls post)" = 0 ] && ok "R2 no post" || bad "R2 posted"

# ── R3 near-miss markers ─────────────────────────────────────────────────────
reset
jq -n '[{body:"<!-- lane-cpu-rank:72520 -->"},{body:"see lane-cpu-rank:7252 in the log"},
        {body:"<!-- hub-load-baseline:2026-10-03T18:00:00Z -->"},{body:null}]' > "$T/comments.json"
run
[ "$(ncalls post)" = 1 ] && lastlog | grep -q 'rank=posted' && ok "R3 near-miss markers do not count" || bad "R3 log: $(lastlog)"

# ── R4 post once ─────────────────────────────────────────────────────────────
reset; run; run
[ "$(ncalls post)" = 1 ] && ok "R4 one post over two runs" || bad "R4 posts: $(ncalls post)"
[ "$(ncalls sample)" = 1 ] && ok "R4 one sample over two runs" || bad "R4 samples: $(ncalls sample)"
lastlog | grep -q 'rank=posted' && ok "R4 second run logs posted" || bad "R4 log: $(lastlog)"

# ── R5 issue knob ────────────────────────────────────────────────────────────
reset; printf 'lane_cpu_rank.issue\t 7300 \n' >> "$T/settings.tsv"; run
grep -q '^post Example/fixture-repo 7300$' "$T/calls" && lastlog | grep -q 'issue=7300(row)' \
  && grep -qF '<!-- lane-cpu-rank:7300 -->' "$T/body.md" && [ -n "$(state 7300)" ] \
  && ok "R5 row 7300 posts on #7300" || bad "R5 7300: $(lastlog) / $(cat "$T/calls")"
reset; printf 'lane_cpu_rank.issue\tabc\n' >> "$T/settings.tsv"; run
grep -q '^post Example/fixture-repo 7252$' "$T/calls" && lastlog | grep -q 'issue=7252(default)' \
  && ok "R5 row abc -> 7252(default)" || bad "R5 abc: $(lastlog)"

# ── R6 post fails ────────────────────────────────────────────────────────────
reset; echo 75 > "$T/post.rc"; run
lastlog | grep -q 'rank=post-failed' && [ "$(state)" = "attempts 1" ] && ok "R6 post-failed, attempts 1" \
  || bad "R6: $(lastlog) / $(state)"
echo 0 > "$T/post.rc"; run
[ "$(ncalls post)" = 2 ] && state | grep -q '^posted ' && ok "R6 next run retries and posts" || bad "R6 retry: $(state)"

# ── R7 sample fails ──────────────────────────────────────────────────────────
reset; echo 'LCS total 0 ticks' > "$T/sample.out"; echo 2 > "$T/sample.rc"; run
lastlog | grep -q 'rank=sample-failed' && [ "$(state)" = "attempts 1" ] && [ "$(ncalls post)" = 0 ] \
  && ok "R7 sample rc 2: sample-failed, attempts 1, no post" || bad "R7: $(lastlog) / $(state)"

# ── R8 top ───────────────────────────────────────────────────────────────────
reset; run LANE_CPU_RANK_TOP=2
[ "$(grep -c '^| [0-9]' "$REPORT")" = 2 ] && grep -q '^| - | other |' "$REPORT" \
  && ok "R8 TOP=2: 2 lane rows plus other" || bad "R8: $(grep '^|' "$REPORT")"
grep -q '^Lanes not shown: 2 (4500.0 CPU s/h)\.$' "$REPORT" && ok "R8 the cut lanes are summed" \
  || bad "R8 not-shown line: $(grep -i 'not shown' "$REPORT")"
lastlog | grep -q 'rows=2' && ok "R8 log rows=2" || bad "R8 log: $(lastlog)"

# ── R9 not configured ────────────────────────────────────────────────────────
reset; echo 'attempts 2' > "$STATE_DIR/state-7252"; GHLIB_OVERRIDE="" run
lastlog | grep -q 'rank=not-configured' && ok "R9 not-configured" || bad "R9 log: $(lastlog)"
[ ! -e "$T/calls" ] && ok "R9 no sampling, no GitHub call" || bad "R9 calls: $(cat "$T/calls")"
[ "$(state)" = "attempts 2" ] && ok "R9 state unchanged" || bad "R9 state: $(state)"

# ── R10 give up ──────────────────────────────────────────────────────────────
reset; echo 75 > "$T/post.rc"
for _ in 1 2 3 4 5 6; do run; done
state | grep -q '^gave-up .* post-failed$' && ok "R10 gave-up after 6" || bad "R10 state: $(state)"
[ "$(grep -c -- '^alert --log-only lane-cpu-rank ' "$T/alerts" 2>/dev/null)" = 1 ] && ok "R10 one log-only alert" \
  || bad "R10 alerts: $(cat "$T/alerts" 2>/dev/null)"
rm -f "$T/calls"; run
[ ! -e "$T/calls" ] && lastlog | grep -q 'rank=gave-up' && [ "$(wc -l < "$T/alerts")" = 1 ] \
  && ok "R10 7th run does nothing" || bad "R10 7th: $(lastlog)"

# ── R11 lock held ────────────────────────────────────────────────────────────
reset
( exec 9> "$H/locks/lane-cpu-rank.lock"; flock -n 9; touch "$T/held"; sleep 5 ) &
holder=$!
for _ in $(seq 1 100); do [ -e "$T/held" ] && break; sleep 0.05; done
run
[ "$RC" = 0 ] && lastlog | grep -q 'rank=skipped (running)' && [ ! -e "$T/calls" ] \
  && ok "R11 lock held: skipped (running)" || bad "R11: rc $RC $(lastlog)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null

echo "lane-cpu-rank: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
