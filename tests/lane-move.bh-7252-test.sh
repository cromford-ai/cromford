#!/bin/bash
# tests/lane-move.bh-7252-test.sh — BH-7252 C1: bin/lane-move.sh, the hub
# lane that flips a lane's placement row to fly after proof gates, checks the
# hour after the flip against the hour before, and moves the lane back to the
# hub (the kill row) when the counts do not hold. Runs the script as shipped,
# with the shipped module bin/lib/lane-move/pipeline-health.sh, in a scratch
# harness.
#   Jobs:   a stub jobs client. Settings rows are JSON files under $T/rows
#           ({value, actor, updated_at}); GET /api/settings/<key>, PUT
#           /api/settings, GET /api/lane-runs/stats and GET
#           /api/lane-runs/by-prefix answer from fixture files.
#   GitHub: a stub lib at LANE_MOVE_GH_LIB (sandbox seam).
#   Clock:  LANE_MOVE_NOW (epoch); load: LANE_MOVE_LOADAVG.
#   Logs:   logs/pipeline-health.log and logs/lane-snapshot-publish.log in
#           the line formats the real writers print.
#
#   M1  all gates pass: one PUT lane_placement.pipeline-health=fly, state
#       flipped <now>, before.tsv holds both projects
#   M2  a verify run at flip+5400 with good counts: verified, one post with
#       the marker; the report has the table, both load5 values, the kill
#       command
#   M3  g1 negatives: actor operator -> held; flyy -> held; no row -> waiting;
#       hub_only -> held; fly -> flipped found, flip epoch = updated_at; no PUT
#   M4  PASS/FAIL: (6,5) pass; (6,4) fail; (0,0) pass; before 1 / ok 0 fail;
#       failed 1 with fail_max default 0 and row abc fails, row 1 passes
#   M5  FAIL -> one PUT hub, rolled-back, one lane-alert warn
#       --id lane-move-pipeline-health, one post; a failed hub PUT leaves
#       flipped and logs rollback-failed
#   M6  no fleet -> waiting no-fleet 1; the 36th wait gives up with one
#       log-only alert; the 37th run calls nothing
#   M7  the fly PUT fails -> waiting put-failed, not flipped
#   M8  post once: the exact marker -> posted, no post; another epoch or
#       another lane's marker -> posts; 6 failed posts -> posted gave-up and
#       one log-only alert
#   M9  g4: a publisher line 1799 s old passes, 1801 s waits; a
#       blocked-resolver line alone waits
#   M10 verify sees hub, actor operator -> killed, no PUT, one post
#   M11 lock held -> skipped (running), exit 0, state unchanged
#   M12 counting: by-prefix pa-x is not pa; a row 1 s before the window is
#       out; a review-rescue run-done line is out; a publisher `1 failed`
#       fails the check
#   M13 no GitHub lib (sandbox) -> not-configured, no jobs call
#   M14 issue row 7300 -> the post goes to #7300
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lane-move.bh-7252-test.sh
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

# ── M1 flip ──────────────────────────────────────────────────────────────────
reset; good_pre; run
[ "$RC" = 0 ] && ok "M1 exit 0" || bad "M1 exit $RC: $(head -5 "$T/run.out")"
[ "$(nputs)" = 1 ] && jq -e '.key == "lane_placement.pipeline-health" and .value == "fly"' "$T/puts" >/dev/null 2>&1 \
  && ok "M1 one PUT lane_placement.pipeline-health=fly" || bad "M1 puts: $(cat "$T/puts" 2>/dev/null)"
[ "$(st)" = "flipped $NOW load5=28.40" ] && ok "M1 state flipped <now> load5" || bad "M1 state: $(st)"
[ "$(cat "$DIR_M/pipeline-health.before.tsv" 2>/dev/null)" = "$(printf 'pa\t6\npb\t6')" ] \
  && ok "M1 before.tsv pa 6, pb 6" || bad "M1 before.tsv: $(cat "$DIR_M/pipeline-health.before.tsv" 2>/dev/null)"
lastlog | grep -q 'lane=pipeline-health step=flipped' && ok "M1 log step=flipped" || bad "M1 log: $(lastlog)"
# A run before the verify time changes nothing.
AT=$((NOW + 600)) run
[ "$(st)" = "flipped $NOW load5=28.40" ] && [ "$(nputs)" = 1 ] && [ "$(nposts)" = 0 ] \
  && ok "M1 a run at flip+600 waits for the verify time" || bad "M1 early run: $(st) / $(lastlog)"

# ── M2 verify (same scratch tree as M1: the flip's own before.tsv) ──────────
good_after "$NOW"
printf '20.00 21.50 22.00 3/900 12345\n' > "$T/loadavg"
verdict_after
[ "$RC" = 0 ] && ok "M2 exit 0" || bad "M2 exit $RC"
st | grep -q '^verified ' && ok "M2 state verified" || bad "M2 state: $(st) / $(lastlog)"
st2 | grep -q '^posted ' && ok "M2 posted line" || bad "M2 line 2: $(st2)"
[ "$(nputs)" = 1 ] && ok "M2 no PUT on a pass" || bad "M2 puts: $(nputs)"
[ "$(nposts)" = 1 ] && grep -q '^post Example/fixture-repo 7252$' "$T/calls" && ok "M2 one post on #7252" || bad "M2 calls: $(cat "$T/calls" 2>/dev/null)"
R="$DIR_M/pipeline-health.report.md"
tail -1 "$R" 2>/dev/null | grep -qxF "$MARK" && ok "M2 marker is the last line" || bad "M2 last line: $(tail -1 "$R" 2>/dev/null)"
cmp -s "$R" "$T/body.md" && ok "M2 posted body = report" || bad "M2 body differs from the report"
grep -qxF '| pa | 6 | 6 | 6 | 0 | 0 |' "$R" && grep -qxF '| pb | 6 | 6 | 6 | 0 | 0 |' "$R" \
  && ok "M2 per-project rows" || bad "M2 table: $(grep '^|' "$R" 2>/dev/null)"
grep -q 'load5 at the flip: 28.40' "$R" && grep -q 'load5 at the check: 21.50' "$R" && ok "M2 both load5 values" \
  || bad "M2 load lines: $(grep -i load5 "$R" 2>/dev/null)"
grep -qF 'bin/jobs-client.sh setting-set lane_placement.pipeline-health hub' "$R" && ok "M2 the kill command" || bad "M2 no kill command"
grep -q '^Verdict: PASS' "$R" && ok "M2 verdict PASS" || bad "M2 verdict: $(grep -i verdict "$R" 2>/dev/null)"
# Terminal: a later run is one file read.
rm -f "$T/calls" "$T/jobs.calls"; AT=$((NOW + 9000)) run
[ ! -e "$T/calls" ] && [ ! -e "$T/jobs.calls" ] && lastlog | grep -q 'step=verified' && ok "M2 a later run calls nothing" \
  || bad "M2 later run: $(cat "$T/jobs.calls" 2>/dev/null) / $(lastlog)"

# ── M3 g1 negatives ──────────────────────────────────────────────────────────
reset; good_pre; row "$ROWKEY" hub operator; run
st | grep -q '^held .*operator' && [ "$(nputs)" = 0 ] && ok "M3 hub by operator -> held, 0 PUT" || bad "M3 operator: $(st) puts=$(nputs)"
lastlog | grep -q 'step=held' && ok "M3 log step=held" || bad "M3 log: $(lastlog)"
reset; good_pre; row "$ROWKEY" flyy seed; run
st | grep -q '^held ' && [ "$(nputs)" = 0 ] && ok "M3 flyy -> held" || bad "M3 flyy: $(st)"
reset; good_pre; row "$ROWKEY" ' Hub ' seed; run
st | grep -q '^flipped ' && ok "M3 ' Hub ' by seed -> flipped (trimmed, lowercased)" || bad "M3 ' Hub ': $(st) / $(lastlog)"
reset; good_pre; rm -f "$T/rows/$ROWKEY.json"; run
[ "$(st)" = "waiting 1 no-row" ] && [ "$(nputs)" = 0 ] && ok "M3 no row -> waiting 1 no-row" || bad "M3 no row: $(st)"
reset; good_pre; touch "$T/settings.fail"; run
st | grep -q '^waiting 1 ' && [ "$(nputs)" = 0 ] && ok "M3 settings read fails -> waiting" || bad "M3 read fail: $(st)"
reset; good_pre; row "$ROWKEY.hub_only" "reads hub files" operator; run
st | grep -q '^held .*hub_only' && [ "$(nputs)" = 0 ] && ok "M3 hub_only row -> held" || bad "M3 hub_only: $(st)"
reset; good_pre; row "$ROWKEY" fly operator "$(iso $((NOW - 900)))"; run
[ "$(st)" = "flipped $((NOW - 900)) load5=28.40 found" ] && [ "$(nputs)" = 0 ] \
  && ok "M3 fly by an operator -> flipped found at updated_at, 0 PUT" || bad "M3 found: $(st) puts=$(nputs)"
lastlog | grep -q 'step=found' && ok "M3 log step=found" || bad "M3 found log: $(lastlog)"
[ "$(cut -f2 "$DIR_M/pipeline-health.before.tsv" 2>/dev/null | paste -sd, -)" = "5,5" ] \
  && ok "M3 found: before counts over the hour before updated_at" || bad "M3 found before.tsv: $(cat "$DIR_M/pipeline-health.before.tsv" 2>/dev/null)"
# A fly row with no updated_at: the flip time is now, never today's 00:00Z.
reset; good_pre; jq -nc '{value:"fly",actor:"operator"}' > "$T/rows/$ROWKEY.json"; run
[ "$(st)" = "flipped $NOW load5=28.40 found" ] && ok "M3 found, no updated_at -> flip time is now" || bad "M3 found no updated_at: $(st)"

# ── M4 PASS/FAIL table ───────────────────────────────────────────────────────
# vcase <name> <want verified|rolled-back> — a verify run over the fixtures set up by the caller.
vcase() { verdict_after
  if st | grep -q "^$2 "; then ok "M4 $1 -> $2"; else bad "M4 $1: want $2, got $(st) / $(lastlog)"; fi; }
reset; flipped_at "$NOW"; good_after "$NOW"; : > "$PHLOG"; phlog pa 5 $((NOW + 1300)); phlog pb 6 $((NOW + 1400)); vcase "(6,5)" verified
reset; flipped_at "$NOW"; good_after "$NOW"; : > "$PHLOG"; phlog pa 4 $((NOW + 1300)); phlog pb 6 $((NOW + 1400)); vcase "(6,4)" rolled-back
reset; flipped_at "$NOW"; printf 'pb\t6\n' > "$DIR_M/pipeline-health.before.tsv"
phlog pb 6 $((NOW + 1400)); okrows pb 6 $((NOW + 1400)); publine $((NOW + 1500)) pipeline-health fly; vcase "pa (0,0)" verified
reset; flipped_at "$NOW"; printf 'pa\t1\n' > "$DIR_M/pipeline-health.before.tsv"
phlog pa 1 $((NOW + 1300)); publine $((NOW + 1500)) pipeline-health fly; vcase "before 1 / ok 0" rolled-back
onefail() { lrows pa done 0 $((NOW + 1300)) pa done 0 $((NOW + 1900)) pa done 0 $((NOW + 2500)) pa done 0 $((NOW + 3100)) pa done 0 $((NOW + 3700)) pa failed 1 $((NOW + 4300)) pa; }
reset; flipped_at "$NOW"; good_after "$NOW"; onefail; vcase "failed 1, fail_max default 0" rolled-back
reset; flipped_at "$NOW"; good_after "$NOW"; onefail; row lane_move.pipeline-health.fail_max abc operator; vcase "failed 1, fail_max abc" rolled-back
reset; flipped_at "$NOW"; good_after "$NOW"; onefail; row lane_move.pipeline-health.fail_max 1 operator; vcase "failed 1, fail_max 1" verified
reset; flipped_at "$NOW"; good_after "$NOW"; lrows pa done 0 $((NOW + 1300)) pa died - $((NOW + 1900)) pa; vcase "died 1" rolled-back
reset; flipped_at "$NOW"; good_after "$NOW"; : > "$PUBLOG"; publine $((NOW + 4900)) pipeline-health fly; vcase "no publisher line in the window" rolled-back

# ── M5 rollback ──────────────────────────────────────────────────────────────
reset; flipped_at "$NOW"; good_after "$NOW"; : > "$PHLOG"; phlog pa 2 $((NOW + 1300)); phlog pb 6 $((NOW + 1400))
verdict_after
st | grep -q '^rolled-back ' && ok "M5 state rolled-back" || bad "M5 state: $(st)"
[ "$(nputs)" = 1 ] && jq -e '.key == "lane_placement.pipeline-health" and .value == "hub"' "$T/puts" >/dev/null 2>&1 \
  && ok "M5 one PUT lane_placement.pipeline-health=hub" || bad "M5 puts: $(cat "$T/puts" 2>/dev/null)"
[ "$(grep -c -- '--severity warn --id lane-move-pipeline-health lane-move ' "$T/alerts" 2>/dev/null)" = 1 ] \
  && [ "$(grep -c . "$T/alerts")" = 1 ] && ok "M5 exactly one lane-alert warn" || bad "M5 alerts: $(cat "$T/alerts" 2>/dev/null)"
[ "$(nposts)" = 1 ] && grep -q '^Verdict: FAIL' "$T/body.md" && grep -q 'pa: after 2 < before 6 - 1' "$T/body.md" \
  && ok "M5 one post, verdict FAIL with the reason" || bad "M5 post: $(nposts) $(grep -i verdict "$T/body.md" 2>/dev/null)"
lastlog | grep -q 'step=posted' && grep -q 'step=rolled-back' "$LOG" && ok "M5 log rolled-back then posted" || bad "M5 log: $(cat "$LOG")"
reset; flipped_at "$NOW"; good_after "$NOW"; : > "$PHLOG"; phlog pa 2 $((NOW + 1300)); phlog pb 6 $((NOW + 1400)); echo 1 > "$T/put.rc"
verdict_after
st | grep -q '^flipped ' && lastlog | grep -q 'step=rollback-failed' && [ ! -e "$T/alerts" ] && [ "$(nposts)" = 0 ] \
  && ok "M5 hub PUT fails -> still flipped, rollback-failed, no alert, no post" || bad "M5 rollback-failed: $(st) / $(lastlog)"
echo 0 > "$T/put.rc"; verdict_after
st | grep -q '^rolled-back ' && ok "M5 the next run retries the rollback" || bad "M5 retry: $(st)"

# ── M6 waiting and gave-up ──────────────────────────────────────────────────
reset; good_pre; echo '{"lanes":[{"lane":"blocked-resolver","done":0,"died":0}]}' > "$T/stats.json"; run
[ "$(st)" = "waiting 1 no-fleet" ] && lastlog | grep -q 'step=waiting why=no-fleet' && ok "M6 no fleet -> waiting 1 no-fleet" \
  || bad "M6: $(st) / $(lastlog)"
run
[ "$(st)" = "waiting 2 no-fleet" ] && ok "M6 the counter counts" || bad "M6 second: $(st)"
echo 'waiting 35 no-fleet' > "$STATE"; run
st | grep -q '^gave-up .* no-fleet$' && ok "M6 the 36th wait gives up" || bad "M6 36th: $(st)"
[ "$(grep -c -- '^alert --log-only lane-move ' "$T/alerts" 2>/dev/null)" = 1 ] && ok "M6 one log-only alert" || bad "M6 alerts: $(cat "$T/alerts" 2>/dev/null)"
rm -f "$T/jobs.calls"; run
[ ! -e "$T/jobs.calls" ] && [ "$(grep -c . "$T/alerts")" = 1 ] && [ "$(nputs)" = 0 ] && ok "M6 the 37th run calls nothing" \
  || bad "M6 37th: $(cat "$T/jobs.calls" 2>/dev/null)"

# ── M7 the fly PUT fails ────────────────────────────────────────────────────
reset; good_pre; echo 1 > "$T/put.rc"; run
[ "$(st)" = "waiting 1 put-failed" ] && ok "M7 PUT fails -> waiting 1 put-failed" || bad "M7: $(st)"

# ── M8 post once ────────────────────────────────────────────────────────────
reset; flipped_at "$NOW"; good_after "$NOW"
jq -n --arg m "Report.
$MARK" '[{body:"hello"},{body:$m}]' > "$T/comments.json"
verdict_after
st | grep -q '^verified ' && st2 | grep -q '^posted .* found$' && [ "$(nposts)" = 0 ] \
  && ok "M8 the exact marker -> posted found, no post" || bad "M8 found: $(st) / $(st2) posts=$(nposts)"
reset; flipped_at "$NOW"; good_after "$NOW"
jq -n --arg n "$NOW" '[{body:("<!-- lane-move:pipeline-health:" + $n + "1 -->")},{body:("<!-- lane-move:blocked-resolver:" + $n + " -->")},{body:"<!-- lane-cpu-rank:7252 -->"},{body:null}]' > "$T/comments.json"
verdict_after
[ "$(nposts)" = 1 ] && st2 | grep -q '^posted ' && ok "M8 near-miss markers -> posts" || bad "M8 near miss: posts=$(nposts) $(st2)"
reset; flipped_at "$NOW"; good_after "$NOW"; echo 75 > "$T/post.rc"
verdict_after
st | grep -q '^verified ' && [ "$(st2)" = "post-attempts 1" ] && lastlog | grep -q 'step=post-failed' \
  && ok "M8 a failed post -> post-attempts 1" || bad "M8 post fail: $(st2) / $(lastlog)"
for _ in 2 3 4 5 6; do verdict_after; done
[ "$(st2)" = "posted gave-up" ] && [ "$(grep -c -- '^alert --log-only lane-move ' "$T/alerts" 2>/dev/null)" = 1 ] \
  && ok "M8 6 failed posts -> posted gave-up, one log-only alert" || bad "M8 gave-up: $(st2) / $(cat "$T/alerts" 2>/dev/null)"
[ "$(nposts)" = 6 ] && ok "M8 6 post tries in all" || bad "M8 posts: $(nposts)"

# ── M9 g4 the publisher ─────────────────────────────────────────────────────
reset; good_pre; : > "$PUBLOG"; publine $((NOW - 1799)) pipeline-health hub; run
st | grep -q '^flipped ' && ok "M9 publisher line 1799 s old -> flip" || bad "M9 1799: $(st) / $(lastlog)"
reset; good_pre; : > "$PUBLOG"; publine $((NOW - 1801)) pipeline-health hub; run
[ "$(st)" = "waiting 1 no-publisher" ] && ok "M9 1801 s old -> waiting no-publisher" || bad "M9 1801: $(st)"
reset; good_pre; : > "$PUBLOG"; publine $((NOW - 60)) blocked-resolver fly; run
[ "$(st)" = "waiting 1 no-publisher" ] && [ "$(nputs)" = 0 ] && ok "M9 a blocked-resolver line alone -> waiting" || bad "M9 other lane: $(st)"
reset; good_pre; : > "$PHLOG"; run
[ "$(st)" = "waiting 1 lane-idle" ] && ok "M9 g5 no run-done line -> waiting lane-idle" || bad "M9 idle: $(st)"

# ── M10 killed ──────────────────────────────────────────────────────────────
reset; flipped_at "$NOW"; good_after "$NOW"; row "$ROWKEY" hub operator
verdict_after
[ "$(st | cut -d' ' -f1,3)" = "killed operator" ] && [ "$(nputs)" = 0 ] && [ "$(nposts)" = 1 ] \
  && ok "M10 row hub by operator -> killed operator, no PUT, one post" || bad "M10: $(st) puts=$(nputs) posts=$(nposts)"
grep -q '^Verdict: KILLED' "$T/body.md" 2>/dev/null && ok "M10 the report says KILLED" || bad "M10 verdict: $(grep -i verdict "$T/body.md" 2>/dev/null)"

# ── M11 lock held ───────────────────────────────────────────────────────────
reset; good_pre
( exec 9> "$H/locks/lane-move.lock"; flock -n 9; touch "$T/held"; sleep 5 ) &
holder=$!
for _ in $(seq 1 100); do [ -e "$T/held" ] && break; sleep 0.05; done
run
[ "$RC" = 0 ] && lastlog | grep -q 'step=skipped (running)' && [ ! -e "$STATE" ] && [ ! -e "$T/jobs.calls" ] \
  && ok "M11 lock held -> skipped (running), state unchanged" || bad "M11: rc $RC $(lastlog)"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null; rm -f "$T/held"

# ── M12 counting ────────────────────────────────────────────────────────────
reset; flipped_at "$NOW"; printf 'pa\t1\n' > "$DIR_M/pipeline-health.before.tsv"
phlog pa 1 $((NOW + 1300)); publine $((NOW + 1500)) pipeline-health fly
lrows pa done 0 $((NOW + 1300)) pa-x done 0 $((NOW + 1199)) pa
verdict_after
st | grep -q '^rolled-back ' && grep -q '| pa | 1 | 1 | 0 | 0 | 0 |' "$DIR_M/pipeline-health.report.md" \
  && ok "M12 a pa-x row and a row 1 s early are not counted for pa" || bad "M12 rows: $(st) $(grep '^| pa' "$DIR_M/pipeline-health.report.md" 2>/dev/null)"
reset; flipped_at "$NOW"; good_after "$NOW"; : > "$PHLOG"; phlog pa 6 $((NOW + 1300))
for i in 0 1 2 3 4 5; do printf '%s review-rescue project pb: run done in 3s\n' "$(ts $((NOW + 1400 + i * 600)))" >> "$PHLOG"; done
verdict_after
st | grep -q '^rolled-back ' && grep -q '| pb | 6 | 0 |' "$DIR_M/pipeline-health.report.md" \
  && ok "M12 review-rescue run-done lines do not count" || bad "M12 other lane lines: $(st)"
reset; flipped_at "$NOW"; good_after "$NOW"; publine $((NOW + 2700)) pipeline-health fly 0 1; verdict_after
st | grep -q '^rolled-back ' && grep -q 'publisher failed 1' "$DIR_M/pipeline-health.report.md" \
  && ok "M12 a publisher '1 failed' line fails the check" || bad "M12 publisher failed: $(st)"
reset; flipped_at "$NOW"; good_after "$NOW"; publine $((NOW + 2700)) pipeline-health fly 2 0; verdict_after
st | grep -q '^rolled-back ' && ok "M12 a publisher conflict fails the check" || bad "M12 conflicts: $(st)"
reset; flipped_at "$NOW"; good_after "$NOW"; publine $((NOW + 2700)) blocked-resolver fly 4 3; verdict_after
st | grep -q '^verified ' && ok "M12 another lane's publisher counts are not this lane's" || bad "M12 other publisher: $(st)"

# ── M13 not configured ──────────────────────────────────────────────────────
reset; good_pre; GHLIB_OVERRIDE="" run
lastlog | grep -q 'step=not-configured' && [ ! -e "$T/jobs.calls" ] && [ ! -e "$STATE" ] \
  && ok "M13 no GitHub lib -> not-configured, nothing called or written" || bad "M13: $(lastlog)"

# ── M14 issue row ───────────────────────────────────────────────────────────
reset; flipped_at "$NOW"; good_after "$NOW"; row lane_move.pipeline-health.issue ' 7300 ' operator; verdict_after
grep -q '^post Example/fixture-repo 7300$' "$T/calls" 2>/dev/null && ok "M14 issue row 7300 -> #7300" || bad "M14: $(cat "$T/calls" 2>/dev/null)"

echo "lane-move: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
