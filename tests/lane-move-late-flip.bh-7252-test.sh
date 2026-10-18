#!/bin/bash
# tests/lane-move-late-flip.bh-7252-test.sh — BH-7252 C2: bin/lane-move.sh
# judges a late-found operator flip on a window it can see. A `fly` row that
# lane-move first sees 1200 s (AFTER_FROM) or more after its updated_at is
# adopted with the seen time as the flip epoch (`flipped <seen> load5=<x>
# found-late <row epoch>`); its before window stays the hour before the row
# time. An empty before window is a FAIL reason. The report names both times.
# Runs the script as shipped, with the shipped module, in a scratch harness
# (the same stubs as tests/lane-move.bh-7252-test.sh).
#
#   L1  row age 1200: found-late, flip epoch = now, log `late by 1200s`,
#       0 PUT, 0 post
#   L2  row age 0, 1199, empty updated_at, future updated_at: `found` at the
#       row epoch (now for empty and future), no found-late
#   L3  row age 1201: found-late
#   L4  row age 105600 (the 2026-10-18 live case): found-late; before.tsv
#       counts the hour before the row time, not the hour before now
#   L5  found-late state, empty before.tsv, good after window: rolled-back
#       with `no runs in the before window`, one PUT hub; a before.tsv with
#       only a bad line gives the same reason
#   L6  the same with before.tsv `pa 0`: no such reason
#   L7  round trip: first sight at T0 of a row at T0-105600, verify at
#       T0+5400 -> verified; the report names both times and both windows,
#       the marker carries T0
#   L8  terminal rolled-back + posted: no jobs call, no GitHub call, state
#       unchanged
#   L9  a normal (not late) flip: the report's Flip line is the C1 line
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lane-move-late-flip.bh-7252-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT_REL=bin/lane-move.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags"
[ -x "$REPO/$SCRIPT_REL" ] && ok "source is executable: $SCRIPT_REL" || bad "missing or not executable: $SCRIPT_REL"
for L in "$SCRIPT_REL" bin/lib/lane-move/pipeline-health.sh bin/lib/lane-placement.sh bin/lib/lane-gate.sh; do
  [ -f "$REPO/$L" ] || { bad "setup: $L missing"; continue; }
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null

DIR_M="$H/state/lane-move"
STATE="$DIR_M/pipeline-health"
LOG="$H/logs/lane-move.log"
PHLOG="$H/logs/pipeline-health.log"
PUBLOG="$H/logs/lane-snapshot-publish.log"
NOW=1792224000   # 2026-10-17T08:00:00Z
ROWKEY=lane_placement.pipeline-health

# ── stubs ────────────────────────────────────────────────────────────────────
GHLIB="$T/ghlib.sh"
cat > "$GHLIB" <<EOF
gh_auth_for() { :; }
gh_auth_reset() { :; }
gh_rest_issue_comments() {
  echo "read \$1 \$2" >> "$T/calls"
  cat "$T/comments.json"
}
gh_rest_comment() {
  echo "post \$1 \$2" >> "$T/calls"
  cp "\$3" "$T/body.md"
  return \$(cat "$T/post.rc")
}
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
echo "alert \$*" >> "$T/alerts"
EOF
chmod +x "$H/bin/lane-alert.sh"
mkdir -p "$T/rows" "$T/byprefix"
cat > "$H/bin/jobs-client.sh" <<EOF
JOBS_BOX=hub-fixture
_setting_key_ok() { [[ "\$1" =~ ^[a-z0-9_.-]{1,64}\$ ]]; }
_jobs_req() {
  echo "\$1 \$2" >> "$T/jobs.calls"
  case "\$1 \$2" in
    "GET /api/settings/"*)
      [ -e "$T/settings.fail" ] && return 1
      local k="\${2#/api/settings/}"
      if [ -f "$T/rows/\$k.json" ]; then jq -c --arg k "\$k" '{key:\$k, setting:(. + {key:\$k})}' "$T/rows/\$k.json"
      else printf '{"key":"%s","setting":null}' "\$k"; fi ;;
    "GET /api/lane-runs/stats")
      [ -e "$T/stats.fail" ] && return 1
      cat "$T/stats.json" ;;
    "GET /api/lane-runs/by-prefix?"*)
      [ -e "$T/byprefix.fail" ] && return 1
      local p; p=\$(sed -nE 's/.*project_prefix=([^&]*).*/\1/p' <<<"\$2")
      cat "$T/byprefix/\$p.json" 2>/dev/null || echo '{"rows":[],"truncated":false}' ;;
    "PUT /api/settings")
      echo "\$3" >> "$T/puts"
      local prc; prc=\$(cat "$T/put.rc" 2>/dev/null || echo 0)
      [ "\$prc" = 0 ] || return "\$prc"
      local k; k=\$(jq -r .key <<<"\$3")
      jq -c '{value, actor, updated_at:"2026-10-17T09:00:00Z"}' <<<"\$3" > "$T/rows/\$k.json" ;;
    *) return 1 ;;
  esac
}
setting_get() {
  _setting_key_ok "\$1" || return 1
  [ -f "$T/rows/\$1.json" ] || return 2
  jq -r .value "$T/rows/\$1.json"
}
setting_set() {
  local body
  _setting_key_ok "\$1" || return 1
  body=\$(jq -nc --arg k "\$1" --arg v "\$2" --arg n "\${3:-}" --arg a "\$JOBS_BOX" '{key:\$k,value:\$v,actor:\$a,note:\$n}')
  _jobs_req PUT /api/settings "\$body" >/dev/null
}
EOF

ts()  { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
row() { jq -nc --arg v "$2" --arg a "$3" --arg u "${4:-2026-10-16T12:38:00Z}" '{value:$v,actor:$a,updated_at:$u}' > "$T/rows/$1.json"; }
# phlog <project> <n> <from-epoch> — n `run done` lines, 600 s apart, in the
# exact line bin/pipeline-health.sh writes (its STAMP and line 3131).
phlog() { local i; for i in $(seq 0 $(($2 - 1))); do
  printf '%s pipeline-health project %s: run done in 12s\n' "$(ts $(($3 + i * 600)))" "$1" >> "$PHLOG"; done; }
# publine <epoch> <lane> <place> [conflicts] [failed] — one line in the format
# bin/lane-snapshot-publish.sh writes to its log.
publine() {
  printf '%s lane-snapshot-publish: 0 published, 0 unchanged, 3 write-backs applied, %s conflicts, 0 rejected, %s failed; %s placed %s (lane_placement.%s=%s); alert lines: 0 replayed, 0 already applied, ack none\n' \
    "$(ts "$1")" "${4:-0}" "${5:-0}" "$2" "$3" "$2" "$3" >> "$PUBLOG"
}
# lrows <project> <file> ... — by-prefix rows: <status> <rc> <finished-epoch> [project]
lrows() {
  local p="$1"; shift
  local s r f q out='[]' i=1
  while [ "$#" -ge 3 ]; do
    s="$1"; r="$2"; f="$3"; q="${4:-$p}"; shift 4 2>/dev/null || shift "$#"
    out=$(jq -c --arg s "$s" --arg r "$r" --arg f "$(iso "$f")" --arg q "$q" --argjson i "$i" \
      '. + [{id:$i, lane:"pipeline-health", project:$q, status:$s, rc:(if $r == "-" then null else ($r|tonumber) end), finished_at:$f}]' <<<"$out")
    i=$((i + 1))
  done
  jq -c '{rows:., truncated:false}' <<<"$out" > "$T/byprefix/$p.json"
}
# okrows <project> <n> <from> — n done rc 0 rows, 600 s apart
okrows() {
  local p="$1" n="$2" f="$3" i out='[]'
  for i in $(seq 0 $((n - 1))); do
    out=$(jq -c --arg f "$(iso $((f + i * 600)))" --arg p "$p" --argjson i "$i" \
      '. + [{id:(100+$i), lane:"pipeline-health", project:$p, status:"done", rc:0, finished_at:$f}]' <<<"$out")
  done
  jq -c '{rows:., truncated:false}' <<<"$out" > "$T/byprefix/$p.json"
}

reset() {
  scratch_rm "$DIR_M" 2>/dev/null; mkdir -p "$DIR_M"
  scratch_rm "$T/rows" 2>/dev/null; scratch_rm "$T/byprefix" 2>/dev/null; mkdir -p "$T/rows" "$T/byprefix"
  : > "$LOG"; : > "$PHLOG"; : > "$PUBLOG"
  rm -f "$T/calls" "$T/alerts" "$T/body.md" "$T/puts" "$T/jobs.calls" "$T/settings.fail" "$T/stats.fail" "$T/byprefix.fail"
  echo '[]' > "$T/comments.json"; echo 0 > "$T/post.rc"; echo 0 > "$T/put.rc"
  echo '{"lanes":[{"lane":"blocked-resolver","queued":0,"claimed":0,"done":12,"died":0}]}' > "$T/stats.json"
  printf '30.10 28.40 27.00 3/900 12345\n' > "$T/loadavg"
  return 0
}
# good_pre — every pre-flip gate passes at NOW.
good_pre() {
  row "$ROWKEY" hub seed
  publine $((NOW - 600)) pipeline-health hub
  phlog pa 6 $((NOW - 3500)); phlog pb 6 $((NOW - 3400))
}
# flipped_at <epoch> — the state a flip at <epoch> leaves, with good before
# counts (pa 6, pb 6) and the row at fly.
flipped_at() {
  printf 'flipped %s load5=28.40\n' "$1" > "$STATE"
  printf 'pa\t6\npb\t6\n' > "$DIR_M/pipeline-health.before.tsv"
  row "$ROWKEY" fly hub-fixture
}
# good_after <flip> — after counts pa 6, pb 6 in [flip+1200, flip+4800), the
# lane-run rows done, the publisher clean.
good_after() {
  local f="$1"
  phlog pa 6 $((f + 1300)); phlog pb 6 $((f + 1400))
  okrows pa 6 $((f + 1300)); okrows pb 6 $((f + 1400))
  publine $((f + 1500)) pipeline-health fly
  publine $((f + 2100)) pipeline-health fly
}
# run [env...] — the script as cron runs it, with the stubs.
run() {
  env HARNESS="$H" HARNESS_REPO=Example/fixture-repo HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 \
    JOBS_URL=http://jobs.invalid HARNESS_SECRET=fixture-secret \
    LANE_MOVE_GH_LIB="${GHLIB_OVERRIDE-$GHLIB}" LANE_MOVE_NOW="${AT:-$NOW}" \
    LANE_MOVE_LOADAVG="$T/loadavg" "$@" "$H/$SCRIPT_REL" > "$T/run.out" 2>&1
  RC=$?
}
lastlog() { tail -1 "$LOG" 2>/dev/null; }
# cnt <pattern> <file> — matching lines; 0 when the file does not exist.
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }
nputs() { cnt . "$T/puts"; }
nposts() { cnt '^post ' "$T/calls"; }
st() { head -1 "$STATE" 2>/dev/null; }
st2() { sed -n 2p "$STATE" 2>/dev/null; }
verdict_after() { AT=$((NOW + 5400)) run; }
MARK="<!-- lane-move:pipeline-health:$NOW -->"
BEFORE="$DIR_M/pipeline-health.before.tsv"
R="$DIR_M/pipeline-health.report.md"
NOREASON='no runs in the before window'

# ── L1 age 1200 is late ──────────────────────────────────────────────────────
reset; good_pre; row "$ROWKEY" fly operator "$(iso $((NOW - 1200)))"; run
[ "$RC" = 0 ] && ok "L1 exit 0" || bad "L1 exit $RC: $(head -5 "$T/run.out")"
[ "$(st)" = "flipped $NOW load5=28.40 found-late $((NOW - 1200))" ] \
  && ok "L1 age 1200 -> flipped <now> found-late <row epoch>" || bad "L1 state: $(st)"
lastlog | grep -q 'step=found why=row fly by operator at .*; late by 1200s, after window from '"$(iso "$NOW")" \
  && ok "L1 log step=found, late by 1200s" || bad "L1 log: $(lastlog)"
[ "$(nputs)" = 0 ] && [ "$(nposts)" = 0 ] && ok "L1 0 PUT, 0 post" || bad "L1 puts=$(nputs) posts=$(nposts)"

# ── L2 young, empty and future rows keep the C1 form ─────────────────────────
for age in 0 1199; do
  reset; good_pre; row "$ROWKEY" fly operator "$(iso $((NOW - age)))"; run
  [ "$(st)" = "flipped $((NOW - age)) load5=28.40 found" ] \
    && ok "L2 age $age -> found at the row epoch" || bad "L2 age $age: $(st)"
  grep -q 'late by' <<<"$(lastlog)" && bad "L2 age $age log says late: $(lastlog)" || ok "L2 age $age log not late"
done
reset; good_pre; jq -nc '{value:"fly",actor:"operator",updated_at:""}' > "$T/rows/$ROWKEY.json"; run
[ "$(st)" = "flipped $NOW load5=28.40 found" ] && ok "L2 empty updated_at -> found at now" || bad "L2 empty: $(st)"
reset; good_pre; row "$ROWKEY" fly operator "$(iso $((NOW + 7200)))"; run
[ "$(st)" = "flipped $NOW load5=28.40 found" ] && ok "L2 future updated_at -> found at now" || bad "L2 future: $(st)"
reset; good_pre; row "$ROWKEY" ' Fly ' operator "$(iso $((NOW - 1199)))"; run
[ "$(st)" = "flipped $((NOW - 1199)) load5=28.40 found" ] && ok "L2 ' Fly ' age 1199 -> found" || bad "L2 ' Fly ': $(st)"

# ── L3 age 1201 ──────────────────────────────────────────────────────────────
reset; good_pre; row "$ROWKEY" fly operator "$(iso $((NOW - 1201)))"; run
[ "$(st)" = "flipped $NOW load5=28.40 found-late $((NOW - 1201))" ] && ok "L3 age 1201 -> found-late" || bad "L3: $(st)"

# ── L4 the live case: a row 105600 s old ─────────────────────────────────────
RE=$((NOW - 105600))
reset; row "$ROWKEY" fly operator "$(iso "$RE")"
phlog pa 3 $((RE - 3500))          # in the hour before the row time
phlog pb 2 $((NOW - 3500))         # in the hour before now: not counted
run
[ "$(st)" = "flipped $NOW load5=28.40 found-late $RE" ] && ok "L4 age 105600 -> found-late" || bad "L4 state: $(st)"
[ "$(cat "$BEFORE" 2>/dev/null)" = "$(printf 'pa\t3')" ] \
  && ok "L4 before.tsv = the hour before the row time" || bad "L4 before.tsv: $(cat "$BEFORE" 2>/dev/null)"
[ "$(nputs)" = 0 ] && ok "L4 0 PUT" || bad "L4 puts=$(nputs)"

# ── L5 empty before window is a FAIL reason ──────────────────────────────────
for kind in empty bad-line; do
  reset
  printf 'flipped %s load5=1 found-late %s\n' "$NOW" "$((NOW - 105600))" > "$STATE"
  if [ "$kind" = empty ]; then : > "$BEFORE"; else printf 'p q\n' > "$BEFORE"; fi
  row "$ROWKEY" fly operator
  good_after "$NOW"
  verdict_after
  st | grep -q "^rolled-back .*$NOREASON" && ok "L5 $kind before.tsv -> rolled-back, $NOREASON" || bad "L5 $kind: $(st)"
  [ "$(nputs)" = 1 ] && jq -e '.value == "hub"' "$T/puts" >/dev/null 2>&1 \
    && ok "L5 $kind one PUT hub" || bad "L5 $kind puts: $(cat "$T/puts" 2>/dev/null)"
done

# ── L6 one valid project row: no such reason ─────────────────────────────────
reset
printf 'flipped %s load5=1 found-late %s\n' "$NOW" "$((NOW - 105600))" > "$STATE"
printf 'pa\t0\n' > "$BEFORE"
row "$ROWKEY" fly operator
good_after "$NOW"
verdict_after
grep -q "$NOREASON" <<<"$(st)" && bad "L6 pa 0 has the reason: $(st)" || ok "L6 pa 0 -> no '$NOREASON'"
st | grep -q '^verified ' && ok "L6 verified" || bad "L6 state: $(st)"

# ── L7 round trip ────────────────────────────────────────────────────────────
reset; RE=$((NOW - 105600))
row "$ROWKEY" fly operator "$(iso "$RE")"
phlog pa 6 $((RE - 3500)); phlog pb 6 $((RE - 3400))
run
[ "$(st)" = "flipped $NOW load5=28.40 found-late $RE" ] && ok "L7 first sight -> found-late" || bad "L7 first sight: $(st)"
AT=$((NOW + 600)) run
[ "$(st)" = "flipped $NOW load5=28.40 found-late $RE" ] && [ "$(nposts)" = 0 ] \
  && ok "L7 a run at seen+600 waits" || bad "L7 early: $(st) / $(lastlog)"
good_after "$NOW"
verdict_after
st | grep -q '^verified ' && ok "L7 verified on the window after the seen time" || bad "L7 state: $(st) / $(lastlog)"
grep -qF 'lane-move first saw it at '"$(iso "$NOW")" "$R" && ok "L7 report: lane-move first saw it at <seen>" \
  || bad "L7 flip line: $(grep '^Flip' "$R" 2>/dev/null)"
grep -qF "Flip: $(iso "$RE")" "$R" && ok "L7 report: Flip is the row time" || bad "L7 flip: $(grep '^Flip' "$R" 2>/dev/null)"
grep -qF "Before window: $(iso $((RE - 3600))) to $(iso "$RE")." "$R" \
  && ok "L7 report: before window ends at the row time" || bad "L7 before: $(grep '^Flip' "$R" 2>/dev/null)"
grep -qF "After window: $(iso $((NOW + 1200))) to $(iso $((NOW + 4800)))" "$R" \
  && ok "L7 report: after window from seen+1200" || bad "L7 after: $(grep '^Flip' "$R" 2>/dev/null)"
tail -1 "$R" 2>/dev/null | grep -qxF "$MARK" && ok "L7 marker carries the seen epoch" || bad "L7 marker: $(tail -1 "$R" 2>/dev/null)"
grep -qF "lane-move:pipeline-health:$RE " "$R" && bad "L7 marker carries the row epoch" || ok "L7 no row-epoch marker"
[ "$(nposts)" = 1 ] && ok "L7 one post" || bad "L7 posts=$(nposts)"

# ── L8 terminal state ────────────────────────────────────────────────────────
reset
printf 'rolled-back 2026-10-18T16:06:00Z no pipeline-health publisher line in the window\nposted 2026-10-18T16:06:01Z\n' > "$STATE"
cp "$STATE" "$T/state.before"
row "$ROWKEY" hub hub-fixture
run
[ ! -s "$T/jobs.calls" ] && [ ! -s "$T/calls" ] && ok "L8 terminal -> no jobs call, no GitHub call" \
  || bad "L8 calls: $(cat "$T/jobs.calls" "$T/calls" 2>/dev/null)"
cmp -s "$STATE" "$T/state.before" && ok "L8 state unchanged" || bad "L8 state: $(cat "$STATE")"
lastlog | grep -q 'step=rolled-back why=terminal' && ok "L8 log terminal" || bad "L8 log: $(lastlog)"

# ── L9 a normal flip's report keeps the C1 windows ───────────────────────────
reset; flipped_at "$NOW"; good_after "$NOW"; verdict_after
grep -qxF "Flip: $(iso "$NOW"). Before window: $(iso $((NOW - 3600))) to $(iso "$NOW"). After window: $(iso $((NOW + 1200))) to $(iso $((NOW + 4800))) (UTC)." "$R" \
  && ok "L9 normal flip: Flip line unchanged" || bad "L9 flip line: $(grep '^Flip' "$R" 2>/dev/null)"
grep -q 'first saw it' "$R" && bad "L9 normal flip names a seen time" || ok "L9 no seen time"

echo "lane-move-late-flip: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
