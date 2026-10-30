#!/bin/bash
# tests/lane-move-dequeue-watch.bh-7424-test.sh — BH-7424: the dequeue-watch
# lane moves to Fly lane-run with bin/lane-move.sh. Runs the shipped module
# bin/lib/lane-move/dequeue-watch.sh alone (LANE_MOVE_MODULE_DIR holds only
# that file) under the shipped bin/lane-move.sh, in a scratch harness, with
# the same seams as tests/lane-move.bh-7252-test.sh (a stub jobs client, a
# stub GitHub lib, a stub lane-alert, LANE_MOVE_NOW, LANE_MOVE_LOADAVG).
#
#   D1  the module counts finished project ticks in [from, to) from
#       logs/dequeue-watch.log.1 and logs/dequeue-watch.log, in the line
#       bin/dequeue-watch.sh summary() writes; every negative of the plan's
#       decision table is out; pa-x is not pa
#   D2  no root -> rc 1, no output; no log -> rc 0, empty; the publisher lane
#       is dequeue-watch
#   D3a the gates pass: one PUT lane_placement.dequeue-watch=fly, state
#       flipped <now>, before.tsv pa 12, pb 12
#   D3b the after window has 10 pa ticks (11 needed): one PUT hub, state
#       rolled-back, one lane-alert warn --id lane-move-dequeue-watch
#   D3c 11 pa ticks and 12 pb ticks: verified, no hub PUT, no alert
#   D4  the manifests parse through the shipped lib, and the files a run
#       writes are allowed in rw
#   D5  the publisher cron line, gated by hub-lease.sh check
#   D6  the seed row fragment: key, hub, seed, INSERT OR IGNORE
#   (The plan's D7, "bin/lane-move.sh and the pipeline-health module are not
#   edited", is a check of the PR diff, so it is not in this suite: a suite
#   runs on every later PR and on main.)
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lane-move-dequeue-watch.bh-7424-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT_REL=bin/lane-move.sh
MOD_REL=bin/lib/lane-move/dequeue-watch.sh
MRO="$REPO/catalog/lane-run-inputs.d/dequeue-watch.ro"
MRW="$REPO/catalog/lane-run-inputs.d/dequeue-watch.rw"
SEED="$REPO/worker/jobs/schema.d/202610271650-bh-7424-dequeue-watch-placement.sql"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags"
for L in "$SCRIPT_REL" bin/lib/lane-placement.sh bin/lib/lane-gate.sh bin/lib/lane-run-inputs.sh; do
  [ -f "$REPO/$L" ] || { bad "setup: $L missing"; continue; }
  ( cd "$REPO" && scratch_install_closure "$L" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $L"
done
chmod +x "$H/bin/"*.sh 2>/dev/null
# Only the shipped module: lane-move must find this lane by its file alone.
MODS="$T/mods"; mkdir -p "$MODS"
if [ -f "$REPO/$MOD_REL" ]; then cp "$REPO/$MOD_REL" "$MODS/"; ok "module shipped: $MOD_REL"
else bad "module missing: $MOD_REL"; fi

DIR_M="$H/state/lane-move"
STATE="$DIR_M/dequeue-watch"
LOG="$H/logs/lane-move.log"
DQLOG="$H/logs/dequeue-watch.log"
PUBLOG="$H/logs/lane-snapshot-publish.log"
NOW=1792224000   # 2026-10-17T08:00:00Z
ROWKEY=lane_placement.dequeue-watch

# ── stubs ────────────────────────────────────────────────────────────────────
GHLIB="$T/ghlib.sh"
cat > "$GHLIB" <<EOF
gh_auth_for() { :; }
gh_auth_reset() { :; }
gh_rest_issue_comments() { echo "read \$1 \$2" >> "$T/calls"; echo '[]'; }
gh_rest_comment() { echo "post \$1 \$2" >> "$T/calls"; cp "\$3" "$T/body.md"; }
EOF
cat > "$H/bin/lane-alert.sh" <<EOF
#!/bin/bash
echo "alert \$*" >> "$T/alerts"
EOF
chmod +x "$H/bin/lane-alert.sh"
cat > "$H/bin/jobs-client.sh" <<EOF
JOBS_BOX=hub-fixture
_setting_key_ok() { [[ "\$1" =~ ^[a-z0-9_.-]{1,64}\$ ]]; }
_jobs_req() {
  echo "\$1 \$2" >> "$T/jobs.calls"
  case "\$1 \$2" in
    "GET /api/settings/"*)
      local k="\${2#/api/settings/}"
      if [ -f "$T/rows/\$k.json" ]; then jq -c --arg k "\$k" '{key:\$k, setting:(. + {key:\$k})}' "$T/rows/\$k.json"
      else printf '{"key":"%s","setting":null}' "\$k"; fi ;;
    "GET /api/lane-runs/stats") cat "$T/stats.json" ;;
    "GET /api/lane-runs/by-prefix?"*)
      local p; p=\$(sed -nE 's/.*project_prefix=([^&]*).*/\1/p' <<<"\$2")
      cat "$T/byprefix/\$p.json" 2>/dev/null || echo '{"rows":[],"truncated":false}' ;;
    "PUT /api/settings")
      echo "\$3" >> "$T/puts"
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
row() { jq -nc --arg v "$2" --arg a "$3" '{value:$v,actor:$a,updated_at:"2026-10-19T14:36:00Z"}' > "$T/rows/$1.json"; }
# tick <epoch> <project> [extra] — the line bin/dequeue-watch.sh:255 writes
# at the end of a `dequeue-watch.sh <p>` run (summary(), date -u +%FT%TZ).
tick() { printf '%s tick projects=1 dequeued=0 recorded=0 acted=0 would=0 owned=0 unread=0 stale=0 skipped=0%s project=%s\n' \
  "$(iso "$1")" "${3:-}" "$2"; }
# dqlog <project> <n> <from-epoch> — n project ticks, 300 s apart (*/5).
dqlog() { local i; for i in $(seq 0 $(($2 - 1))); do tick $(($3 + i * 300)) "$1" >> "$DQLOG"; done; }
publine() {
  printf '%s lane-snapshot-publish: 0 published, 0 unchanged, 3 write-backs applied, 0 conflicts, 0 rejected, 0 failed; %s placed %s (lane_placement.%s=%s); alert lines: 0 replayed, 0 already applied, ack none\n' \
    "$(ts "$1")" "$2" "$3" "$2" "$3" >> "$PUBLOG"
}
# okrows <project> <n> <from> — n done rc 0 lane_runs rows, 300 s apart
okrows() {
  local p="$1" n="$2" f="$3" i out='[]'
  for i in $(seq 0 $((n - 1))); do
    out=$(jq -c --arg f "$(iso $((f + i * 300)))" --arg p "$p" --argjson i "$i" \
      '. + [{id:(100+$i), lane:"dequeue-watch", project:$p, status:"done", rc:0, finished_at:$f}]' <<<"$out")
  done
  jq -c '{rows:., truncated:false}' <<<"$out" > "$T/byprefix/$p.json"
}
reset() {
  scratch_rm "$DIR_M" 2>/dev/null; mkdir -p "$DIR_M"
  scratch_rm "$T/rows" 2>/dev/null; scratch_rm "$T/byprefix" 2>/dev/null; mkdir -p "$T/rows" "$T/byprefix"
  : > "$LOG"; : > "$DQLOG"; : > "$PUBLOG"; rm -f "$DQLOG.1"
  rm -f "$T/calls" "$T/alerts" "$T/body.md" "$T/puts" "$T/jobs.calls"
  echo '{"lanes":[{"lane":"pipeline-health","queued":0,"claimed":0,"done":12,"died":0}]}' > "$T/stats.json"
  printf '30.10 28.40 27.00 3/900 12345\n' > "$T/loadavg"
  return 0
}
run() {
  env HARNESS="$H" HARNESS_REPO=Example/fixture-repo HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 \
    JOBS_URL=http://jobs.invalid HARNESS_SECRET=fixture-secret LANE_MOVE_MODULE_DIR="$MODS" \
    LANE_MOVE_GH_LIB="$GHLIB" LANE_MOVE_NOW="${AT:-$NOW}" \
    LANE_MOVE_LOADAVG="$T/loadavg" "$H/$SCRIPT_REL" > "$T/run.out" 2>&1
  RC=$?
}
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }
nputs() { cnt . "$T/puts"; }
st() { head -1 "$STATE" 2>/dev/null; }
lastlog() { tail -1 "$LOG" 2>/dev/null; }
# M <fn> [args] — one module call with the scratch root.
M() { ( export HARNESS="$H"; unset H; . "$MODS/dequeue-watch.sh" || exit 99; "$@" ); }

# ── D1 counting ──────────────────────────────────────────────────────────────
echo "D1: the module counts finished project ticks"
reset
F=$((NOW - 3600)); TO=$NOW
{
  tick "$F" pa                                   # at exactly from: in
  tick $((F - 1)) pa                             # 1 s before from: out
} > "$DQLOG.1"
{
  tick $((F + 600)) pa                           # in
  tick $((F + 900)) pa " page-cut err=skip-project"   # errors next to the finish: in
  tick "$TO" pa                                  # at exactly to: out
  tick $((F + 700)) pa-x                         # pa-x, never pa
  tick $((F + 800)) pb                           # in
  printf '%s tick projects=9 dequeued=0 recorded=0 acted=0 would=0 owned=0 unread=0 stale=0 skipped=0\n' "$(iso $((F + 100)))"
  printf '%s locked project=pa\n' "$(iso $((F + 110)))"
  printf '%s tick timed-out\n' "$(iso $((F + 120)))"
  printf '%s gather: tick projects=1 dequeued=0 skipped=0 project=pa\n' "$(ts $((F + 130)))"
  tick $((F + 140)) 'pa;rm'
  # A short stamp sorts inside the window as a string; it is not a stamp.
  printf '%s tick projects=1 dequeued=0 skipped=0 project=pa\n' "$(date -u -d "@$((F + 1800))" '+%Y-%m-%dT%H:%MZ')"
  printf '%s tick timed-out project=pa\n' "$(iso $((F + 145)))"
  printf '%s off\n%s disabled\n%s gh-budget\n' "$(iso $((F + 150)))" "$(iso $((F + 160)))" "$(iso $((F + 170)))"
} > "$DQLOG"
OUT=$(M lm_runs_done_dequeue_watch "$F" "$TO"); rc=$?
WANT=$(printf 'pa\t3\npa-x\t1\npb\t1')
[ "$rc" = 0 ] && [ "$OUT" = "$WANT" ] && ok "D1 pa 3, pa-x 1, pb 1 and nothing else" \
  || bad "D1 rc=$rc out: $(printf '%s' "$OUT" | tr '\t\n' ' |')"

# ── D2 exit paths ────────────────────────────────────────────────────────────
echo "D2: exit paths"
OUT=$( ( unset H HARNESS; . "$MODS/dequeue-watch.sh" || exit 99; lm_runs_done_dequeue_watch "$F" "$TO" ) ); rc=$?
[ "$rc" = 1 ] && [ -z "$OUT" ] && ok "D2 no root -> rc 1, no output" || bad "D2 no root: rc=$rc out=$OUT"
OUT=$(M lm_runs_done_dequeue_watch "$F" notanepoch); rc=$?
[ "$rc" = 1 ] && [ -z "$OUT" ] && ok "D2 a bad epoch -> rc 1" || bad "D2 bad epoch: rc=$rc out=$OUT"
rm -f "$DQLOG" "$DQLOG.1"
OUT=$(M lm_runs_done_dequeue_watch "$F" "$TO"); rc=$?
[ "$rc" = 0 ] && [ -z "$OUT" ] && ok "D2 no log -> rc 0, empty" || bad "D2 no log: rc=$rc out=$OUT"
[ "$(M lm_publisher_lane_dequeue_watch)" = dequeue-watch ] && ok "D2 publisher lane is dequeue-watch" \
  || bad "D2 publisher: $(M lm_publisher_lane_dequeue_watch)"

# ── D3a flip ─────────────────────────────────────────────────────────────────
echo "D3: lane-move with only the dequeue-watch module"
reset
row "$ROWKEY" hub seed
publine $((NOW - 60)) dequeue-watch hub
dqlog pa 12 $((NOW - 3550)); dqlog pb 12 $((NOW - 3500))
run
[ "$RC" = 0 ] && ok "D3a exit 0" || bad "D3a exit $RC: $(head -5 "$T/run.out")"
[ "$(nputs)" = 1 ] && jq -e '.key == "lane_placement.dequeue-watch" and .value == "fly"' "$T/puts" >/dev/null 2>&1 \
  && ok "D3a one PUT lane_placement.dequeue-watch=fly" || bad "D3a puts: $(cat "$T/puts" 2>/dev/null) / $(lastlog)"
[ "$(st)" = "flipped $NOW load5=28.40" ] && ok "D3a state flipped <now>" || bad "D3a state: $(st) / $(lastlog)"
[ "$(cat "$DIR_M/dequeue-watch.before.tsv" 2>/dev/null)" = "$(printf 'pa\t12\npb\t12')" ] \
  && ok "D3a before.tsv pa 12, pb 12" || bad "D3a before.tsv: $(cat "$DIR_M/dequeue-watch.before.tsv" 2>/dev/null)"
grep -q 'lane=dequeue-watch step=flipped' "$LOG" && ! grep -q 'lane=pipeline-health' "$LOG" \
  && ok "D3a log names dequeue-watch only" || bad "D3a log: $(cat "$LOG")"

# ── D3b rollback (the D3a tree, at flip+5400) ───────────────────────────────
dqlog pa 10 $((NOW + 1300)); dqlog pb 12 $((NOW + 1250))
okrows pa 10 $((NOW + 1300)); okrows pb 12 $((NOW + 1250))
publine $((NOW + 1500)) dequeue-watch fly
AT=$((NOW + 5400)) run
st | grep -q '^rolled-back .*pa: after 10 < before 12 - 1' && ok "D3b 10 of 12 pa ticks -> rolled-back" \
  || bad "D3b state: $(st) / $(lastlog)"
[ "$(nputs)" = 2 ] && tail -1 "$T/puts" | jq -e '.key == "lane_placement.dequeue-watch" and .value == "hub"' >/dev/null 2>&1 \
  && ok "D3b one PUT lane_placement.dequeue-watch=hub" || bad "D3b puts: $(cat "$T/puts" 2>/dev/null)"
[ "$(cnt '--severity warn --id lane-move-dequeue-watch lane-move ' "$T/alerts")" = 1 ] && [ "$(cnt . "$T/alerts")" = 1 ] \
  && ok "D3b exactly one lane-alert warn --id lane-move-dequeue-watch" || bad "D3b alerts: $(cat "$T/alerts" 2>/dev/null)"

# ── D3c pass ────────────────────────────────────────────────────────────────
reset
printf 'flipped %s load5=28.40\n' "$NOW" > "$STATE"
printf 'pa\t12\npb\t12\n' > "$DIR_M/dequeue-watch.before.tsv"
row "$ROWKEY" fly hub-fixture
dqlog pa 11 $((NOW + 1300)); dqlog pb 12 $((NOW + 1250))
okrows pa 11 $((NOW + 1300)); okrows pb 12 $((NOW + 1250))
publine $((NOW + 1500)) dequeue-watch fly
AT=$((NOW + 5400)) run
st | grep -q '^verified ' && ok "D3c 11 pa, 12 pb -> verified" || bad "D3c state: $(st) / $(lastlog)"
[ "$(nputs)" = 0 ] && [ ! -e "$T/alerts" ] && ok "D3c no PUT, no alert" || bad "D3c puts=$(nputs) alerts=$(cat "$T/alerts" 2>/dev/null)"
grep -qxF '| pa | 12 | 11 | 11 | 0 | 0 |' "$DIR_M/dequeue-watch.report.md" 2>/dev/null \
  && ok "D3c report row pa 12/11" || bad "D3c report: $(grep '^|' "$DIR_M/dequeue-watch.report.md" 2>/dev/null)"

# ── D4 manifests ────────────────────────────────────────────────────────────
echo "D4: the manifests through bin/lib/lane-run-inputs.sh"
[ -f "$MRO" ] && [ -f "$MRW" ] && ok "D4 both manifests exist" || bad "D4 manifest missing: $MRO $MRW"
R4="$T/r4"; mkdir -p "$R4"
printf '%s\n' "pa Org/pa - - 2 box-m" > "$R4/fleet.conf"
LIB="$REPO/bin/lib/lane-run-inputs.sh"
L() { ( unset H; export HARNESS="$R4" FLEET_CONF="$R4/fleet.conf" LRI_MANIFEST_DIR="$REPO/catalog/lane-run-inputs.d"; . "$LIB" || exit 99; "$@" ); }
OUT=$(L lri_paths dequeue-watch pa rw 2>"$T/d4.err"); rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/d4.err" ] && grep -qx 'state/merge-conductor/attempts.txt' <<<"$OUT" \
  && ok "D4 lri_paths rw rc 0, prints attempts.txt" || bad "D4 rw rc=$rc: $(cat "$T/d4.err") / $OUT"
grep -qx 'state/merge-conductor/mergify-asked/Org_pa_\*' <<<"$OUT" && ok "D4 rw folds \$repokey" || bad "D4 rw repokey: $OUT"
OUT=$(L lri_paths dequeue-watch pa ro 2>"$T/d4.err"); rc=$?
[ "$rc" = 0 ] && [ ! -s "$T/d4.err" ] && grep -qx 'fleet.conf' <<<"$OUT" && grep -qx 'flags/\*' <<<"$OUT" \
  && ok "D4 lri_paths ro rc 0, prints fleet.conf and flags/*" || bad "D4 ro rc=$rc: $(cat "$T/d4.err") / $OUT"
L lri_member_ok pa state/merge-conductor/attempts.txt - rw dequeue-watch && ok "D4 rw allows attempts.txt" || bad "D4 rw refuses attempts.txt"
L lri_member_ok pa state/merge-conductor/mergify-asked/Org_pa_7 - rw dequeue-watch && ok "D4 rw allows this repo's ask ledger" \
  || bad "D4 rw refuses mergify-asked/Org_pa_7"
L lri_member_ok pa state/merge-conductor/mergify-asked/Org_pb_7 - rw dequeue-watch && bad "D4 rw allows another repo's ask ledger" \
  || ok "D4 rw refuses mergify-asked/Org_pb_7"
L lri_member_ok pa state/pipeline-health/pa/x - rw dequeue-watch && bad "D4 rw allows state/pipeline-health/pa/x" \
  || ok "D4 rw refuses state/pipeline-health/pa/x"
L lri_member_ok pa env/global.env - ro dequeue-watch && bad "D4 ro allows env/global.env" || ok "D4 ro refuses env/global.env"
L lri_member_ok pa fleet.conf - ro dequeue-watch && ok "D4 ro allows fleet.conf" || bad "D4 ro refuses fleet.conf"

# ── D5 cron line ────────────────────────────────────────────────────────────
echo "D5: the publisher cron line"
CL=$(grep -v '^#' "$REPO/cron/lanes/579-lane-snapshot-publish.cron" | grep -- '--lane dequeue-watch')
[ "$(grep -c . <<<"$CL")" = 1 ] && ok "D5 one --lane dequeue-watch line" || bad "D5 lines: $CL"
[[ "$CL" == '3,13,23,33,43,53 * * * * /root/harness/bin/hub-lease.sh check && /root/harness/bin/lane-snapshot-publish.sh --lane dequeue-watch '* ]] \
  && ok "D5 minutes 3,13,..., gated by hub-lease.sh check &&" || bad "D5 line: $CL"

# ── D6 seed row ─────────────────────────────────────────────────────────────
echo "D6: the seed row fragment"
FR=$(grep -l "lane_placement.dequeue-watch" "$REPO"/worker/jobs/schema.d/*.sql 2>/dev/null)
[ "$FR" = "$SEED" ] && ok "D6 one fragment seeds the row" || bad "D6 fragments: $FR"
grep -q "^INSERT OR IGNORE INTO settings" "$FR" 2>/dev/null && grep -qF "('lane_placement.dequeue-watch','hub','" "$FR" \
  && grep -qE "','seed','[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z'\);" "$FR" \
  && ok "D6 INSERT OR IGNORE, hub, actor seed" || bad "D6 fragment: $(cat "$FR" 2>/dev/null)"

echo "lane-move-dequeue-watch: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
