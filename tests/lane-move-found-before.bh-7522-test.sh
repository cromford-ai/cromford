#!/bin/bash
# tests/lane-move-found-before.bh-7522-test.sh — BH-7522: an operator flip
# (`found`, `found-late`) writes before.tsv from the module's own counter, and
# a zero count gives one clear reason instead of an empty file. The automatic
# flip path is unchanged. Runs bin/lane-move.sh as shipped in a scratch harness
# (the stubs are those of tests/lane-move-late-flip.bh-7252-test.sh).
#   F1  operator flip, runs in the hour before updated_at: before.tsv holds the
#       counts; the after window matches -> verified
#   F2  operator flip, no runs before: before.tsv is not empty (one comment
#       line), no project row; the check rolls back with ONE reason, the words
#       "the lane had no runs in the hour before the operator flip", and not
#       the generic "no runs in the before window"; the report holds it once
#   F3  found-late, no runs in the hour before the row time: the same reason;
#       runs only in the hour before now do not count
#   F4  found-late with runs before the row time: counts, verified
#   F5  the automatic path: no runs -> waiting lane-idle, no before.tsv; runs ->
#       before.tsv = the C1 bytes; a flip with an empty before.tsv still gives
#       the generic reason
#   F6  a project row `pa 0` after an operator flip: no zero-count reason
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lane-move-found-before.bh-7522-test.sh
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

BEFORE="$DIR_M/pipeline-health.before.tsv"
R="$DIR_M/pipeline-health.report.md"
GENERIC='no runs in the before window'
CLEAR='the lane had no runs in the hour before the operator flip'
# has_data <file> — a line `<project>\t<digits>`.
has_data() { awk -F '\t' '$1 ~ /^[A-Za-z0-9._-]+$/ && $2 ~ /^[0-9]+$/ { f = 1 } END { exit !f }' "$1" 2>/dev/null; }

# ── F1 operator flip with runs before ────────────────────────────────────────
reset; good_pre; row "$ROWKEY" fly operator "$(iso $((NOW - 900)))"; run
[ "$(st)" = "flipped $((NOW - 900)) load5=28.40 found" ] && ok "F1 found state" || bad "F1 state: $(st)"
[ "$(cut -f2 "$BEFORE" 2>/dev/null | paste -sd, -)" = "5,5" ] && ok "F1 before.tsv holds the counts" || bad "F1 before.tsv: $(cat "$BEFORE" 2>/dev/null)"
good_after "$((NOW - 900))"; AT=$((NOW - 900 + 5400)) run
st | grep -q '^verified ' && ok "F1 verified when the after window matches" || bad "F1 verify: $(st) / $(lastlog)"

# ── F2 operator flip, no runs before ─────────────────────────────────────────
reset; row "$ROWKEY" fly operator "$(iso $((NOW - 900)))"; run
[ -s "$BEFORE" ] && ok "F2 before.tsv is not an empty file" || bad "F2 before.tsv is empty or missing"
has_data "$BEFORE" && bad "F2 before.tsv has a project row: $(cat "$BEFORE")" || ok "F2 no project row"
lastlog | grep -q 'step=found' && ok "F2 log step=found" || bad "F2 log: $(lastlog)"
good_after "$((NOW - 900))"; AT=$((NOW - 900 + 5400)) run
st | grep -q '^rolled-back ' && ok "F2 rolled back" || bad "F2 state: $(st)"
grep -qF "$CLEAR" <<<"$(st)" && ok "F2 the reason says it in words" || bad "F2 reason: $(st)"
grep -qF "$GENERIC" <<<"$(st)" && bad "F2 generic reason present: $(st)" || ok "F2 no generic reason"
[ "$(grep -o "$CLEAR" "$R" 2>/dev/null | wc -l)" = 1 ] && ok "F2 report holds the reason once" || bad "F2 report: $(grep '^Reasons' "$R" 2>/dev/null)"
[ "$(grep -c '^Reasons: ' "$R" 2>/dev/null)" = 1 ] && [ "$(grep '^Reasons: ' "$R" | tr -cd ';' | wc -c)" = 0 ] \
  && ok "F2 one reason, not a list" || bad "F2 reasons: $(grep '^Reasons' "$R" 2>/dev/null)"

# ── F3 found-late, no runs before the row time ───────────────────────────────
RE=$((NOW - 105600))
reset; row "$ROWKEY" fly operator "$(iso "$RE")"; phlog pb 2 $((NOW - 3500)); run
[ "$(st)" = "flipped $NOW load5=28.40 found-late $RE" ] && ok "F3 found-late state" || bad "F3 state: $(st)"
if [ -s "$BEFORE" ] && ! has_data "$BEFORE"; then ok "F3 before.tsv: one comment line, no row"; else bad "F3 before.tsv: $(cat "$BEFORE" 2>/dev/null)"; fi
good_after "$NOW"; verdict_after
if grep -qF "$CLEAR" <<<"$(st)" && ! grep -qF "$GENERIC" <<<"$(st)"; then ok "F3 the clear reason only"; else bad "F3 reason: $(st)"; fi

# ── F4 found-late with runs before the row time ──────────────────────────────
reset; row "$ROWKEY" fly operator "$(iso "$RE")"; phlog pa 6 $((RE - 3500)); phlog pb 6 $((RE - 3400)); run
[ "$(cut -f2 "$BEFORE" 2>/dev/null | paste -sd, -)" = "6,6" ] && ok "F4 before.tsv counts the hour before the row time" || bad "F4 before.tsv: $(cat "$BEFORE" 2>/dev/null)"
good_after "$NOW"; verdict_after
st | grep -q '^verified ' && ok "F4 verified" || bad "F4 state: $(st)"

# ── F5 the automatic path is unchanged ───────────────────────────────────────
reset; row "$ROWKEY" hub seed; publine $((NOW - 600)) pipeline-health hub; run
if [ "$(st)" = "waiting 1 lane-idle" ] && [ ! -e "$BEFORE" ] && [ "$(nputs)" = 0 ]; then ok "F5 auto, no runs -> waiting lane-idle, no before.tsv, 0 PUT"; else bad "F5 idle: $(st) puts=$(nputs)"; fi
reset; good_pre; run
[ "$(st)" = "flipped $NOW load5=28.40" ] && [ "$(nputs)" = 1 ] && ok "F5 auto flip state, 1 PUT" || bad "F5 auto: $(st) puts=$(nputs)"
if [ "$(od -An -c "$BEFORE" | tr -d ' \n')" = "$(printf 'pa\t6\npb\t6\n' | od -An -c | tr -d ' \n')" ]; then ok "F5 auto before.tsv bytes are the C1 bytes"; else bad "F5 auto before.tsv: $(od -c "$BEFORE" | head -3)"; fi
reset; printf 'flipped %s load5=28.40\n' "$NOW" > "$STATE"; : > "$BEFORE"; row "$ROWKEY" fly hub-fixture; good_after "$NOW"; verdict_after
if grep -qF "$GENERIC" <<<"$(st)" && ! grep -qF "$CLEAR" <<<"$(st)"; then ok "F5 auto flip, empty before.tsv -> the generic reason"; else bad "F5 generic: $(st)"; fi

# ── F6 a project row with 0 is not the zero-count case ───────────────────────
reset; printf 'flipped %s load5=1 found\n' "$NOW" > "$STATE"; printf 'pa\t0\n' > "$BEFORE"; row "$ROWKEY" fly operator; good_after "$NOW"; verdict_after
grep -qF "$CLEAR" <<<"$(st)" && bad "F6 pa 0 has the reason: $(st)" || ok "F6 pa 0 -> no zero-count reason"

echo "lane-move-found-before: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
