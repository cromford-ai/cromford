#!/bin/bash
# tests/lane-move-stuck-work.bh-7423-test.sh — BH-7423: the stuck-work lane
# moves to Fly lane-run through bin/lane-move.sh. Runs the shipped module
# bin/lib/lane-move/stuck-work.sh, the shipped bin/lane-move.sh (with
# LANE_MOVE_MODULE_DIR at a dir that holds only the stuck-work module), the
# shipped manifests through bin/lib/lane-run-inputs.sh, and the shipped
# bin/stuck-work.sh, each in a scratch harness.
#   Jobs:   lane-move: a stub jobs client (the tests/lane-move.bh-7252-test.sh
#           pattern, copied); stuck-work.sh: a fake curl as the jobs worker.
#   GitHub: a stub lib at LANE_MOVE_GH_LIB (sandbox seam).
#
#   S1  the module's counting rule over seeded logs: what counts (items= lines
#       in stuck-work.log for the home project, project=<p> lines there for
#       <p>, stuck-work-<p>.log, the .log.1 copies, items=0, a stamp = from)
#       and what does not (busy/off/disabled/no-token/no-classifier/no-tmp, a
#       stamp = to or 1 s before from, the profile and cron logs, project=../x,
#       no space, a space-format stamp); the home rule; sort; rc 1 with no
#       root or a bad epoch; rc 0 and no output with no logs
#   S2  lane-move with only the stuck-work module: (a) flip, then verified on
#       the after window (a hub-run project whose after runs are machine lines)
#       with one report post; (b) fewer after-window runs -> one PUT hub,
#       rolled-back, one lane-alert; (c) no stuck-work publisher line ->
#       waiting no-publisher, no PUT
#   S3  the manifests parse and the lri_member_ok accept/refuse table
#   S4  bin/stuck-work.sh's summary line: tagged only on a non-home run with
#       LANE_RUN_ID set, and then in logs/stuck-work.log
#   S5  the seed fragment: hub by seed, INSERT OR IGNORE, no hub_only key
#   S6  the S4 log through the real module (writer/reader round trip)
#   S7  the diff does not touch bin/lane-move.sh or another lane's module
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/lane-move-stuck-work.bh-7423-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
MOD_REL=bin/lib/lane-move/stuck-work.sh
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }

for f in "$MOD_REL" bin/lane-move.sh bin/stuck-work.sh bin/lib/lane-run-inputs.sh \
         catalog/lane-run-inputs.d/stuck-work.rw catalog/lane-run-inputs.d/stuck-work.ro \
         tests/fixtures/stuck-work/scenario-ready-8m.txt; do
  [ -f "$REPO/$f" ] || bad "setup: $f is missing"
done
[ "$FAIL" = 0 ] || { echo "lane-move-stuck-work: $PASS passed, $FAIL failed"; exit 1; }

# A scratch harness: a symlink tree of bin/ and catalog/. A stub replaces a
# symlink only after rm, never a write through it.
H="$T/h"
mkdir -p "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags"
cp -rs "$REPO/bin" "$H/bin"
cp -rs "$REPO/catalog" "$H/catalog"
: > "$H/env/global.env"
MODS="$H/bin/lib/lmv-only"
mkdir -p "$MODS"; ln -s "$REPO/$MOD_REL" "$MODS/stuck-work.sh"

ts()  { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }
iso() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }
NOW=1792224000   # 2026-10-17T08:00:00Z
SWLOG="$H/logs/stuck-work.log"
SUM='states=ready:1 past_sla=0 paged=0 repaged=0 incomplete=0'
printf 'project-3 o/project-3 - -\ncromford Example/fixture-repo - -\n' > "$T/fleet.conf"

# M <from> <to> [env...] — the module as bin/lane-move.sh sources it.
M() {
  local f="$1" t="$2"; shift 2
  env HARNESS="$H" HARNESS_REPO=Example/fixture-repo FLEET_CONF="$T/fleet.conf" "$@" \
    bash -c '. "$1" || exit 99; lm_runs_done_stuck_work "$2" "$3"' _ "$REPO/$MOD_REL" "$f" "$t"
}
clearlogs() { rm -f "$H"/logs/stuck-work*.log "$H"/logs/stuck-work*.log.1; }

# ── S1 the counting rule ─────────────────────────────────────────────────────
clearlogs
F=$((NOW - 3600))
{
  echo "$(iso $((NOW - 3000))) items=12 $SUM"                 # 1  home
  echo "$(iso $((NOW - 2900))) project=project-3 items=3 $SUM"     # 3  project-3
  echo "$(iso $((NOW - 2800))) items=0 states=- past_sla=0 paged=0 repaged=0 incomplete=0"  # 4 home
  echo "$(iso "$F") items=2 $SUM"                             # 5  home (= from)
  echo "$(iso $((NOW - 2700))) busy"                          # 7
  for w in off disabled no-token no-classifier no-tmp; do echo "$(iso $((NOW - 2600))) $w"; done  # 8
  echo "$(iso $((NOW - 2500))) project=project-3 busy"
  echo "$(iso "$NOW") items=1 $SUM"                           # 9  (= to)
  echo "$(iso $((F - 1))) items=1 $SUM"                       # 10
  echo "$(iso $((NOW - 2400))) project=../x items=1 $SUM"     # 13
  echo "$(iso $((NOW - 2300)))items=1 $SUM"                   # 14
  echo "$(ts $((NOW - 2200))) items=1 $SUM"                   # 15
  echo "$(iso $((NOW - 2100)))x items=1 $SUM"                 # a stamp with a tail, inside the window as a string
} > "$SWLOG"
echo "$(iso $((NOW - 3300))) items=5 $SUM" > "$SWLOG.1"        # 2  home
{ echo "$(iso $((NOW - 2000))) items=4 $SUM"; echo "$(iso $((NOW - 1000))) items=1 $SUM"
  echo "$(iso $((NOW - 900))) busy"; } > "$H/logs/stuck-work-project-3.log"   # 6  project-3 x2
echo "$(iso $((NOW - 1500))) items=1 $SUM" > "$H/logs/stuck-work-Zed.log.1"
echo "$(iso $((NOW - 1500))) project=cromford secs=4 facts_s=1 loop_s=1 items=12 seen_hit=1 seen_miss=0 led_hit=0 led_miss=0 ci_hit=0 ci_miss=0 thread_skip=0" \
  > "$H/logs/stuck-work-profile.log"                            # 11
echo "$(iso $((NOW - 1500))) items=1 $SUM" >> "$H/logs/stuck-work-profile.log"
echo "$(iso $((NOW - 1500))) items=1 $SUM" > "$H/logs/stuck-work-cron.log"   # 12
OUT=$(M "$F" "$NOW"); rc=$?
WANT=$(printf 'Zed\t1\ncromford\t4\nproject-3\t3')
[ "$rc" = 0 ] && [ "$OUT" = "$WANT" ] && ok "S1a the counting table: Zed 1, cromford 4, project-3 3 (C sort)" \
  || bad "S1a rc=$rc got: $(printf '%s' "$OUT" | tr '\t\n' ':,')"
# The home is the first fleet.conf project whose repo is sw_repo, not the first project.
printf 'project-3 o/project-3 - -\nbh Example/fixture-repo - -\n' > "$T/fleet-bh.conf"
OUT=$(M "$F" "$NOW" FLEET_CONF="$T/fleet-bh.conf")
[ "$(grep -c '^bh	4$' <<<"$OUT")" = 1 ] && ! grep -q '^cromford' <<<"$OUT" \
  && ok "S1b home = the project whose repo is sw_repo (bh)" || bad "S1b got: $(printf '%s' "$OUT" | tr '\t\n' ':,')"
OUT=$(M "$F" "$NOW" FLEET_CONF="$T/fleet-bh.conf" HARNESS_REPO=Other/none STUCK_WORK_REPO=)
grep -q '^cromford	4$' <<<"$OUT" && ok "S1c no repo match -> home cromford" \
  || bad "S1c got: $(printf '%s' "$OUT" | tr '\t\n' ':,')"
# A window that holds only one line of each kind.
OUT=$(M $((NOW - 3001)) $((NOW - 2999)))
[ "$OUT" = "$(printf 'cromford\t1')" ] && ok "S1d a 2 s window holds one run" || bad "S1d got: $OUT"
OUT=$(M $((NOW - 2901)) $((NOW - 2899)))
[ "$OUT" = "$(printf 'project-3\t1')" ] && ok "S1e a tagged line counts for its project" || bad "S1e got: $OUT"
OUT=$(M $((NOW - 60)) "$NOW")
[ -z "$OUT" ] && ok "S1f a stamp = to is out of [from, to)" || bad "S1f got: $OUT"
OUT=$(M "$F" $((F + 1)))
[ "$OUT" = "$(printf 'cromford\t1')" ] && ok "S1g a stamp = from is in" || bad "S1g got: $OUT"
OUT=$(M $((F - 1)) "$F")
[ "$OUT" = "$(printf 'cromford\t1')" ] && ok "S1g2 a line 1 s before from counts only in a window that holds it" || bad "S1g2 got: $OUT"
OUT=$(M $((NOW - 1600)) $((NOW - 1400)))
[ "$OUT" = "$(printf 'Zed\t1')" ] && ok "S1h the profile and cron logs do not count, .log.1 of a project does" \
  || bad "S1h got: $(printf '%s' "$OUT" | tr '\t\n' ':,')"
OUT=$(M "$F" "$NOW" HARNESS= H=); rc=$?
[ "$rc" = 1 ] && [ -z "$OUT" ] && ok "S1i no root -> rc 1" || bad "S1i rc=$rc out=$OUT"
OUT=$(M notanepoch "$NOW"); rc=$?
[ "$rc" = 1 ] && [ -z "$OUT" ] && ok "S1j a bad epoch -> rc 1" || bad "S1j rc=$rc out=$OUT"
clearlogs; rm -f "$H/logs/stuck-work-profile.log" "$H/logs/stuck-work-cron.log"
OUT=$(M "$F" "$NOW"); rc=$?
[ "$rc" = 0 ] && [ -z "$OUT" ] && ok "S1k no logs -> rc 0, no output" || bad "S1k rc=$rc out=$OUT"
( . "$REPO/$MOD_REL" && [ "$LM_LANE" = stuck-work ] && [ "$(lm_publisher_lane_stuck_work)" = stuck-work ] ) \
  && ok "S1l LM_LANE and the publisher lane are stuck-work" || bad "S1l the module contract"

# ── S2 lane-move with the stuck-work module only ────────────────────────────
DIR_M="$H/state/lane-move"
STATE="$DIR_M/stuck-work"
LOG="$H/logs/lane-move.log"
PUBLOG="$H/logs/lane-snapshot-publish.log"
ROWKEY=lane_placement.stuck-work
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
  return 0
}
EOF
rm -f "$H/bin/lane-alert.sh" "$H/bin/jobs-client.sh"
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
row() { jq -nc --arg v "$2" --arg a "$3" '{value:$v,actor:$a,updated_at:"2026-10-19T14:36:00Z"}' > "$T/rows/$1.json"; }
# swlog <file> <n> <from> [tag] — n stuck-work summary lines, 290 s apart, in
# the line bin/stuck-work.sh's summary() writes (tag: `project=<p> `).
swlog() { local i; for i in $(seq 0 $(($2 - 1))); do
  printf '%s %sitems=4 %s\n' "$(iso $(($3 + i * 290)))" "${4:-}" "$SUM" >> "$1"; done; }
publine() {
  printf '%s lane-snapshot-publish: 0 published, 0 unchanged, 3 write-backs applied, %s conflicts, 0 rejected, %s failed; %s placed %s (lane_placement.%s=%s); alert lines: 0 replayed, 0 already applied, ack none\n' \
    "$(ts "$1")" "${4:-0}" "${5:-0}" "$2" "$3" "$2" "$3" >> "$PUBLOG"
}
okrows() {
  local p="$1" n="$2" f="$3" i out='[]'
  for i in $(seq 0 $((n - 1))); do
    out=$(jq -c --arg f "$(iso $((f + i * 600)))" --arg p "$p" --argjson i "$i" \
      '. + [{id:(100+$i), lane:"stuck-work", project:$p, status:"done", rc:0, finished_at:$f}]' <<<"$out")
  done
  jq -c '{rows:., truncated:false}' <<<"$out" > "$T/byprefix/$p.json"
}
reset() {
  scratch_rm "$DIR_M" 2>/dev/null; mkdir -p "$DIR_M"
  scratch_rm "$T/rows" 2>/dev/null; scratch_rm "$T/byprefix" 2>/dev/null; mkdir -p "$T/rows" "$T/byprefix"
  clearlogs; : > "$LOG"; : > "$PUBLOG"
  rm -f "$T/calls" "$T/alerts" "$T/body.md" "$T/puts" "$T/jobs.calls"
  echo '[]' > "$T/comments.json"
  echo '{"lanes":[{"lane":"blocked-resolver","queued":0,"claimed":0,"done":12,"died":0}]}' > "$T/stats.json"
  printf '30.10 28.40 27.00 3/900 12345\n' > "$T/loadavg"
  return 0
}
run() {
  env HARNESS="$H" HARNESS_REPO=Example/fixture-repo FLEET_CONF="$T/fleet.conf" HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 \
    JOBS_URL=http://jobs.invalid HARNESS_SECRET=fixture-secret \
    LANE_MOVE_GH_LIB="$GHLIB" LANE_MOVE_NOW="${AT:-$NOW}" LANE_MOVE_MODULE_DIR="$MODS" \
    LANE_MOVE_LOADAVG="$T/loadavg" "$H/bin/lane-move.sh" > "$T/run.out" 2>&1
  RC=$?
}
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }
nputs() { cnt . "$T/puts"; }
nposts() { cnt '^post ' "$T/calls"; }
st() { head -1 "$STATE" 2>/dev/null; }
REPORT="$DIR_M/stuck-work.report.md"

# S2a: the flip, then the check passes. project-3 ran on the hub before (its own
# log) and on a machine after (tagged lines in stuck-work.log).
reset; row "$ROWKEY" hub seed; publine $((NOW - 600)) stuck-work hub
swlog "$SWLOG" 12 $((NOW - 3500)); swlog "$H/logs/stuck-work-project-3.log" 12 $((NOW - 3450))
run
[ "$RC" = 0 ] && [ "$(nputs)" = 1 ] && jq -e '.key == "lane_placement.stuck-work" and .value == "fly"' "$T/puts" >/dev/null 2>&1 \
  && ok "S2a one PUT lane_placement.stuck-work=fly" || bad "S2a rc=$RC puts: $(cat "$T/puts" 2>/dev/null) / $(tail -2 "$LOG")"
[ "$(st)" = "flipped $NOW load5=28.40" ] && ok "S2a state flipped <now>" || bad "S2a state: $(st)"
[ "$(cat "$DIR_M/stuck-work.before.tsv" 2>/dev/null)" = "$(printf 'cromford\t12\nproject-3\t12')" ] \
  && ok "S2a before.tsv cromford 12, project-3 12" || bad "S2a before.tsv: $(cat "$DIR_M/stuck-work.before.tsv" 2>/dev/null)"
grep -q 'lane=stuck-work step=flipped' "$LOG" && ! grep -q 'lane=pipeline-health' "$LOG" \
  && ok "S2a the module is found by its file name, alone" || bad "S2a log: $(cat "$LOG")"
swlog "$SWLOG" 12 $((NOW + 1300)); swlog "$SWLOG" 12 $((NOW + 1310)) 'project=project-3 '
okrows cromford 6 $((NOW + 1300)); okrows project-3 6 $((NOW + 1310))
publine $((NOW + 1500)) stuck-work fly; publine $((NOW + 2100)) stuck-work fly
AT=$((NOW + 5400)) run
grep -q '^verified ' <<<"$(st)" && ok "S2a the check at flip+5400 -> verified" || bad "S2a verify: $(st) / $(tail -3 "$LOG")"
grep -qxF '| cromford | 12 | 12 | 6 | 0 | 0 |' "$REPORT" && grep -qxF '| project-3 | 12 | 12 | 6 | 0 | 0 |' "$REPORT" \
  && ok "S2a the report rows: machine runs count for project-3" || bad "S2a table: $(grep '^|' "$REPORT" 2>/dev/null)"
[ "$(nposts)" = 1 ] && grep -qxF "<!-- lane-move:stuck-work:$NOW -->" <<<"$(tail -1 "$T/body.md" 2>/dev/null)" \
  && ok "S2a one report post with the lane-move:stuck-work marker" || bad "S2a posts=$(nposts) $(tail -1 "$T/body.md" 2>/dev/null)"

# S2b: fewer runs in the after window -> rolled back.
reset; printf 'flipped %s load5=28.40\n' "$NOW" > "$STATE"; printf 'cromford\t12\n' > "$DIR_M/stuck-work.before.tsv"
row "$ROWKEY" fly hub-fixture
swlog "$SWLOG" 5 $((NOW + 1300)); okrows cromford 5 $((NOW + 1300)); publine $((NOW + 1500)) stuck-work fly
AT=$((NOW + 5400)) run
grep -q '^rolled-back .*cromford: after 5 < before 12 - 1' <<<"$(st)" && ok "S2b after 5 < before 12 - 1 -> rolled-back" \
  || bad "S2b state: $(st)"
[ "$(nputs)" = 1 ] && jq -e '.key == "lane_placement.stuck-work" and .value == "hub"' "$T/puts" >/dev/null 2>&1 \
  && ok "S2b one PUT lane_placement.stuck-work=hub" || bad "S2b puts: $(cat "$T/puts" 2>/dev/null)"
[ "$(cnt '--severity warn --id lane-move-stuck-work lane-move ' "$T/alerts")" = 1 ] && [ "$(cnt . "$T/alerts")" = 1 ] \
  && ok "S2b exactly one lane-alert --id lane-move-stuck-work" || bad "S2b alerts: $(cat "$T/alerts" 2>/dev/null)"
grep -q '^Verdict: FAIL' "$T/body.md" 2>/dev/null && ok "S2b the posted report says FAIL" || bad "S2b body: $(head -3 "$T/body.md" 2>/dev/null)"

# S2c: only another lane's publisher line -> waiting no-publisher.
reset; row "$ROWKEY" hub seed; publine $((NOW - 600)) pipeline-health hub; swlog "$SWLOG" 12 $((NOW - 3500))
run
[ "$(st)" = "waiting 1 no-publisher" ] && [ "$(nputs)" = 0 ] && [ ! -e "$T/alerts" ] \
  && ok "S2c no stuck-work publisher line -> waiting no-publisher, no PUT, no alert" || bad "S2c: $(st) puts=$(nputs)"

# ── S3 the manifests ────────────────────────────────────────────────────────
LIB="$REPO/bin/lib/lane-run-inputs.sh"
printf 'demo o/demo - - 2 box-a 192.0.2.1\n' > "$T/demo-fleet.conf"
mkdir -p "$T/none"
_jobs_req() { return 1; }
setting_get() { return 1; }
L() { ( export HARNESS="$T/none" FLEET_CONF="$T/demo-fleet.conf" LRI_MANIFEST_DIR="$REPO/catalog/lane-run-inputs.d"
        . "$LIB" || exit 99; "$@" ); }
for mode in ro rw; do
  OUT=$(L lri_paths stuck-work demo "$mode" 2>&1); rc=$?
  [ "$rc" = 0 ] && [ -n "$OUT" ] && ok "S3 lri_paths stuck-work demo $mode parses" || bad "S3 $mode rc=$rc: $OUT"
done
SHA=0123456789abcdef0123456789abcdef01234567
n=0
while read -r rel mode want; do
  [ -n "$rel" ] || continue
  n=$((n + 1)); L lri_member_ok demo "$rel" - "$mode" stuck-work; rc=$?
  if { [ "$want" = accept ] && [ "$rc" = 0 ]; } || { [ "$want" = refuse ] && [ "$rc" != 0 ]; }; then
    ok "S3.$n $mode $rel -> $want"
  else bad "S3.$n $mode $rel: want $want, rc=$rc"; fi
done <<EOF
state/stuck-work/seen/$SHA rw accept
state/stuck-work/led/$SHA rw accept
state/stuck-work/ci/o_demo-12 rw accept
state/stuck-work/thread/o_demo-12.json rw accept
state/stuck-work/thread/o_demo-12.meta rw accept
state/stuck-work/demo/no-token-20261019 rw accept
state/stuck-work/outage-2026101910 rw accept
state/stuck-work/no-token-20261019 rw accept
state/stuck-work/seen/$SHA ro accept
state/merge-conductor/resolver-claim/o_demo_12 ro accept
fleet.conf ro accept
prompts/demo.md ro accept
flags/lane-off-stuck-work ro accept
state/merge-conductor/resolver-claim/o_demo_12 rw refuse
state/merge-conductor/resolver-claim/o_other_12 ro refuse
prompts/demo.md rw refuse
flags/x rw refuse
state/stuck-work/other/x rw refuse
state/stuck-work/ci/o_other-12 rw refuse
state/stuck-work/ci/o_other-12 ro refuse
logs/stuck-work.log rw refuse
logs/stuck-work.log ro refuse
env/global.env ro refuse
env/global.env rw refuse
locks/stuck-work-demo.lock rw refuse
state/pr-snapshot/x ro refuse
state/stuck-work/../x rw refuse
state/settings-cache.json ro refuse
EOF
unset -f _jobs_req setting_get

# ── S4 bin/stuck-work.sh's summary line ─────────────────────────────────────
H2="$T/h2"
mkdir -p "$H2/env" "$T/fakebin" "$T/fx"
cp -rs "$REPO/bin" "$H2/bin"
cp -rs "$REPO/catalog" "$H2/catalog"
rm -f "$H2/catalog/lanes.json"
HARNESS_TEST_SANDBOX=1 "$REPO/bin/lanes-build.sh" > "$H2/catalog/lanes.json" 2>/dev/null || bad "S4 setup: lanes-build"
: > "$H2/env/global.env"
rm -f "$H2/bin/lane-alert.sh" "$H2/bin/alert-line.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/s4-alerts"\nexit 0\n' > "$H2/bin/alert-line.sh"
cp "$H2/bin/alert-line.sh" "$H2/bin/lane-alert.sh"
chmod +x "$H2/bin/alert-line.sh" "$H2/bin/lane-alert.sh"
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
m=GET; body=""; prev=""; wfmt=0
for a in "$@"; do
  case "$prev" in -X) m="$a" ;; --data-binary|-d) body="$a" ;; -w) wfmt=1 ;; esac
  prev="$a"
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
url="${!#}"
case "$url" in "$JOBS_URL"*) ;; *) exit 7 ;; esac
path="${url#"$JOBS_URL"}"
dec() { local s=${1//+/ }; printf '%b' "${s//%/\\x}"; }
code=200; out='{"ok":true}'
exec 7>"$FXT/ledger.lock"; flock 7
case "$m $path" in
  "GET /api/settings"*) out='{"settings":[]}' ;;
  "GET /api/ledger"*)
    k=$(dec "$(printf '%s' "$path" | sed -n 's/.*[?&]kind=\([^&]*\).*/\1/p')")
    v=$(dec "$(printf '%s' "$path" | sed -n 's/.*[?&]key=\([^&]*\).*/\1/p')")
    row=$(jq -c --arg i "$k/$v" '.[$i] // empty' "$FXT/ledger.json")
    if [ -n "$row" ]; then out=$(jq -nc --argjson r "$row" '{ledger: $r}'); else code=404; out='{"error":"not found"}'; fi ;;
  "PUT /api/ledger"*)
    jq --argjson b "$body" '.[$b.kind + "/" + $b.key] = {status: $b.status, detail: ($b.detail // "")}' \
      "$FXT/ledger.json" > "$FXT/ledger.tmp.$$" && mv "$FXT/ledger.tmp.$$" "$FXT/ledger.json" ;;
  "GET "*) code=404; out='{"error":"not found"}' ;;
esac
printf '%s' "$out"
[ "$wfmt" = 1 ] && printf '\n%s' "$code"
exit 0
SH
chmod +x "$T/fakebin/curl"
FX="$REPO/tests/fixtures/stuck-work/scenario-ready-8m.txt"
sed 's#example-org/cromford#o/project-3#g' "$FX" > "$T/fx/project-3.txt"
cp "$FX" "$T/fx/cromford.txt"
printf 'cromford example-org/cromford - -\nproject-3 o/project-3 - -\n' > "$T/fleet-home.conf"
echo '{}' > "$T/ledger.json"
# sw [env...] [args] — one stuck-work.sh run in H2.
sw() {
  env -u PL_LANE -u PL_PROJECT -u PL_LOCK_FD -u PL_SLUG -u PL_STATE_DIR -u GH_TOKEN -u GITHUB_TOKEN \
    -u STUCK_WORK_REPO -u STUCK_WORK_ENABLED -u HARNESS_ENV_DIR -u LANE_RUN_ID \
    HARNESS="$H2" FXT="$T" JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 HARNESS_SECRET=test JOBS_BOX=hub \
    PATH="$T/fakebin:$PATH" HARNESS_TEST_SANDBOX=1 STUCK_WORK_NOW=$((1789999520 + 900)) STUCK_WORK_FIXTURE="$T/fx" \
    FLEET_CONF="$T/fleet-home.conf" HARNESS_REPO=example-org/cromford STUCK_WORK_PROJECTS=all LANE_GATE_DISABLE=1 \
    "$@" > "$T/sw.out" 2>&1
}
L2="$H2/logs/stuck-work.log"; LO="$H2/logs/stuck-work-project-3.log"
TSRE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'
sw LANE_RUN_ID=41 bash "$H2/bin/stuck-work.sh"; rc=$?
[ "$rc" = 0 ] && [ "$(grep -cE "$TSRE items=1 " "$L2" 2>/dev/null)" = 1 ] && ! grep -q 'project=' "$L2" \
  && ok "S4a home run with LANE_RUN_ID: an untagged line in stuck-work.log" || bad "S4a rc=$rc: $(cat "$L2" 2>/dev/null) / $(head -3 "$T/sw.out")"
sw LANE_RUN_ID=42 bash "$H2/bin/stuck-work.sh" project-3; rc=$?
[ "$rc" = 0 ] && [ "$(grep -cE "$TSRE project=project-3 items=1 states=" "$L2" 2>/dev/null)" = 1 ] && [ ! -e "$LO" ] \
  && ok "S4b non-home run with LANE_RUN_ID: <ts> project=project-3 items=... in stuck-work.log, no stuck-work-project-3.log" \
  || bad "S4b rc=$rc: $(cat "$L2" 2>/dev/null) / $(ls "$H2/logs")"
grep -q -- '--project project-3 ' "$T/s4-alerts" 2>/dev/null \
  && ok "S4b the project-3 run paged as project-3" || bad "S4b alerts: $(cat "$T/s4-alerts" 2>/dev/null)"

# ── S6 the S4 lines through the real module ─────────────────────────────────
# summary() stamps with the real clock, so the window is every stamp from 1970
# to 2100: no clock read here.
OUT=$(env HARNESS="$H2" HARNESS_REPO=example-org/cromford FLEET_CONF="$T/fleet-home.conf" \
  bash -c '. "$1" || exit 99; lm_runs_done_stuck_work "$2" "$3"' _ "$REPO/$MOD_REL" 0 4102444800)
[ "$OUT" = "$(printf 'cromford\t1\nproject-3\t1')" ] && ok "S6 the module reads the written lines: cromford 1, project-3 1" \
  || bad "S6 got: $(printf '%s' "$OUT" | tr '\t\n' ':,')"

L2SZ=$(wc -c < "$L2")
sw bash "$H2/bin/stuck-work.sh" project-3; rc=$?
[ "$rc" = 0 ] && [ "$(grep -cE "$TSRE items=1 " "$LO" 2>/dev/null)" = 1 ] && [ "$(wc -c < "$L2")" = "$L2SZ" ] \
  && ok "S4c non-home hub run: an untagged line in stuck-work-project-3.log, stuck-work.log unchanged" \
  || bad "S4c rc=$rc: $(cat "$LO" 2>/dev/null)"
sw LANE_RUN_ID= bash "$H2/bin/stuck-work.sh" project-3; rc=$?
[ "$rc" = 0 ] && [ "$(grep -cE "$TSRE items=1 " "$LO" 2>/dev/null)" = 2 ] && [ "$(wc -c < "$L2")" = "$L2SZ" ] \
  && ok "S4d LANE_RUN_ID empty: the hub file, untagged" || bad "S4d rc=$rc: $(cat "$LO" 2>/dev/null)"
mkdir -p "$H2/flags"; touch "$H2/flags/stuck-work-off"
sw LANE_RUN_ID=43 bash "$H2/bin/stuck-work.sh" project-3
[ "$(grep -cE "$TSRE project=project-3 off$" "$L2")" = 1 ] && ok "S4e every summary word is tagged on a machine (off)" \
  || bad "S4e: $(tail -2 "$L2")"
rm -f "$H2/flags/stuck-work-off"

# ── S5 the seed fragment ────────────────────────────────────────────────────
mapfile -t FR < <(ls "$REPO"/worker/jobs/schema.d/*-bh-7423-stuck-work-placement.sql 2>/dev/null)
if [ "${#FR[@]}" = 1 ]; then
  S=$(cat "${FR[0]}")
  grep -q "INSERT OR IGNORE INTO settings" <<<"$S" && grep -q "('lane_placement.stuck-work','hub'," <<<"$S" \
    && grep -q "'seed','20[0-9-]*T[0-9:]*Z');" <<<"$S" && ! grep -q 'hub_only' <<<"$S" && ! grep -qi 'create table' <<<"$S" \
    && ok "S5 the fragment seeds lane_placement.stuck-work=hub by seed, INSERT OR IGNORE, no hub_only" \
    || bad "S5 fragment: $S"
  # sq <db> <sql> — one script through the sqlite3 CLI (on stdin: a script that
  # starts with a "-- " comment is an unknown option as an argument), else
  # python3's sqlite3.
  sq() {
    if command -v sqlite3 >/dev/null 2>&1; then printf '%s\n' "$2" | sqlite3 "$1"
    else python3 -I -c 'import sqlite3,sys
c=sqlite3.connect(sys.argv[1]); r=c.executescript(sys.argv[2]) if not sys.argv[2].lstrip().upper().startswith("SELECT") else c.execute(sys.argv[2])
[print("|".join(str(x) for x in row)) for row in (r.fetchall() if hasattr(r,"fetchall") else [])]; c.commit()' "$1" "$2"; fi
  }
  if command -v sqlite3 >/dev/null 2>&1 || python3 -I -c 'import sqlite3' 2>/dev/null; then
    DB="$T/s5.db"; SQL=$(cat "${FR[0]}")
    sq "$DB" 'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT, note TEXT, actor TEXT, updated_at TEXT);'
    sq "$DB" "$SQL"; sq "$DB" "$SQL"
    [ "$(sq "$DB" "SELECT count(*) || ' ' || value || ' ' || actor FROM settings WHERE key='lane_placement.stuck-work'")" = "1 hub seed" ] \
      && ok "S5 applied twice: one row, hub by seed" || bad "S5 apply: $(sq "$DB" 'SELECT * FROM settings')"
    sq "$DB" "UPDATE settings SET value='fly', actor='operator' WHERE key='lane_placement.stuck-work';"
    sq "$DB" "$SQL"
    [ "$(sq "$DB" "SELECT value FROM settings WHERE key='lane_placement.stuck-work'")" = fly ] \
      && ok "S5 an operator row is never overwritten" || bad "S5 overwrite"
  else
    echo "  skip S5 apply: no sqlite3 and no python3 sqlite3"
  fi
else
  bad "S5 want one bh-7423 placement fragment, found ${#FR[@]}"
fi

# ── S7 the ticket's negative scope ──────────────────────────────────────────
# Only this ticket's own commits are read (subject `BH-7423:`), so a later PR
# that edits bin/lane-move.sh does not make this suite red. With none of them
# in origin/main..HEAD (main after the merge, or no git) it skips and passes.
# pr-scoped: ok reads only BH-7423 commits; an empty range skips
CS=$(git -C "$REPO" log --format=%H --grep='^BH-7423:' origin/main..HEAD 2>/dev/null)
if [ -n "$CS" ]; then
  CH=$(for c in $CS; do git -C "$REPO" show --name-only --format= "$c"; done | sort -u)
  if grep -qx 'bin/lane-move.sh' <<<"$CH" || [ -n "$(grep '^bin/lib/lane-move/' <<<"$CH" | grep -vx "$MOD_REL")" ]; then
    bad "S7 a BH-7423 commit touches bin/lane-move.sh or another module: $(grep 'lane-move' <<<"$CH" | tr '\n' ' ')"
  else ok "S7 bin/lane-move.sh and the other modules are untouched"; fi
else
  echo "  skip S7: no BH-7423 commit in origin/main..HEAD"
fi

echo "lane-move-stuck-work: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
