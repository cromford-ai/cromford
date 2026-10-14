#!/bin/bash
# tests/lead-fence-lanes.bh-1606-test.sh — BH-1606: the lead-PR merge fence
# (#1603, bin/lib/ticket-ownership.sh to_lane_lead_hold) on the lanes #1603 left
# open. merge-conductor, merge-sweep and merge-queue listed lead-authored PRs but
# asked only to_lane_hold, which EXEMPTS a lead PR, so a lead PR could land on
# any of them with no lead or human MERGE verdict on its exact head. The tier-2
# APPROVE enqueue in bin/run-build.sh put lead PRs on the box queue the same way.
#
# On EACH lane, driven (whole script, or a block extracted verbatim by its
# markers) against a stub gh (GitHub) and a stub curl (the jobs worker):
#   1. a lead PR with no lead row                    -> no merge
#   2. a lead MERGE row on the exact live head       -> merges, PINNED to that head
#   3. a lead MERGE row only on an OLDER head        -> no merge
#   4. an unreadable lead_pr_authors row             -> no merge, and ONE
#      lane-wide alert (the verdicts outage stamp), not one per PR
# plus: the conductor's provenance clearance never bypasses the fence; a
# review-prs merge refused with "Head branch was modified" never reaches the box
# queue; the MERGE_HELD dedupe files of closed PRs are pruned.
# Run from anywhere: tests/lead-fence-lanes.bh-1606-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
# BH-1585/1586: the conductor's open-PR list is REST now; the stubs below still
# describe it as `gh pr list --json`, and the bridge answers the REST reads from
# that description (the way tests/merge-conductor-test.sh does).
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# BH-1625: every lane reads verdicts through bin/lib/verdict-parse.sh, which the
# scratch harnesses / extracted blocks below do not carry by themselves.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
unset GH_TOKEN GH_ADMIN_TOKEN _GHAA_DEFAULT_TOK HARNESS_ENV_DIR JOB_ID JOB_PHASE_ID
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LEAD=operator
BOT='cromford[bot]'
H1=aaaaaaaa11111111111111111111111111111111   # the live head
H0=0000000011111111111111111111111111111111   # an earlier head of the same PR
H2=bbbbbbbb22222222222222222222222222222222   # a head pushed after the verdict read

# ---------------------------------------------------------------------------
# THE JOBS WORKER, one stub for every section. State lives in $VD:
#   $VD/lead         the lead_pr_authors value     $VD/lead-down  transport failure
#   $VD/<sha>        the standing verdict on <sha> $VD/down       verdicts unreachable
#   $VD/mq-posts     every merge_queue row POSTed (the tier-2 enqueue)
# ---------------------------------------------------------------------------
VD="$T/vd"; mkdir -p "$VD"
cat > "$T/worker-curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET; BODY=""
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; --data-binary|-d) BODY="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "GET "*/api/verdicts\?*)
    printf '%s\n' "$URL" >> "$VD/calls"
    [ -f "$VD/down" ] && exit 7
    h="${URL##*head=}"; h="${h%%&*}"
    if [ -f "$VD/$h" ]; then printf '%s\n200\n' "$(cat "$VD/$h")"
    else printf '{"standing":null,"rows":[]}\n200\n'; fi ;;
  "GET "*/api/settings/lead_pr_authors)
    [ -f "$VD/lead-down" ] && exit 7
    printf '{"setting":{"key":"lead_pr_authors","value":"%s"}}\n200\n' "$(cat "$VD/lead" 2>/dev/null)" ;;
  # BH-5781: the list carries lead_pr_authors too, as the real list route does
  # (every row): setting_get answers from the fresh list the gate cached.
  "GET "*/api/settings)
    [ -f "$VD/lead-down" ] && exit 7
    jq -nc --arg v "$(cat "$VD/lead" 2>/dev/null)" '{settings: (if $v == "" then [] else [{key:"lead_pr_authors",value:$v}] end)}'
    printf '200\n' ;;
  "GET "*/api/settings*) printf '{"settings":[]}\n200\n' ;;
  "POST "*/api/merge-queue*)
    printf '%s\n' "$BODY" >> "$VD/mq-posts"
    printf '{"merge":{"status":"queued"},"duplicate":false}\n201\n' ;;
  "PUT "*/api/ledger*) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/worker-curl"
export VD
# vd_put <head> <verdict> <source> [pr] — one standing row on that head
vd_put() {
  jq -nc --arg v "$2" --arg s "$3" --arg h "$1" --argjson p "${4:-9}" \
    '{standing:{id:7,pr:$p,head_sha:$h,verdict:$v,source:$s,
      created_at:"2026-09-23T10:00:00Z",report_url:null,reviewer:"mac-lead"},head:$h,rows:[]}' > "$VD/$1"
}
vd_reset() { rm -f "$VD"/*; : > "$VD/calls"; printf '%s' "$LEAD" > "$VD/lead"; }
lead_alerts() { [ -f "$1" ] || { echo 0; return 0; }; grep -c 'lead-row' "$1" || true; }

# ════════════════════════════════════════════════════════════════════════════
# L. THE LIBRARY: the lane call site, the lane-wide outage alert, the prune.
# ════════════════════════════════════════════════════════════════════════════
LH="$T/lib/h"; mkdir -p "$LH/bin/lib/jobs" "$LH/logs" "$LH/state" "$T/lib/fakebin" "$T/lib/fx"
cp "$DIR/bin/jobs-client.sh" "$LH/bin/"; cp "$DIR"/bin/lib/jobs/*.sh "$LH/bin/lib/jobs/"
cp "$DIR/bin/lib/block-gate.sh" "$DIR/bin/lib/verdicts.sh" "$DIR/bin/lib/ticket-ownership.sh" \
   "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$LH/bin/lib/"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$T/lib/fx" > "$LH/bin/lane-alert.sh"; chmod +x "$LH/bin/lane-alert.sh"
cp "$T/worker-curl" "$T/lib/fakebin/curl"
cp "$DIR/tests/lib/rest-emit.sh" "$T/lib/fakebin/restpr"; chmod +x "$T/lib/fakebin/restpr"
# gh: pulls/<n> answers $T/lib/fx/pr-<n>.state (OPEN|MERGED|CLOSED); none = 404
cat > "$T/lib/fakebin/gh" <<'EOF'
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "$*" >> "$LFX/gh-calls"
n=$(printf '%s' "$*" | sed -nE 's#.*repos/[^/]+/[^/]+/pulls/([0-9]+).*#\1#p')
if [ -n "$n" ]; then
  [ -f "$LFX/pr-$n.json" ] && { restpr --raw 200 "$(cat "$LFX/pr-$n.json")"; exit 0; }
  [ -f "$LFX/pr-$n.state" ] || { restpr --raw 404 '{"message":"Not Found"}'; exit 0; }
  restpr "$(cat "$LFX/pr-$n.state")" aaaaaaaa11111111111111111111111111111111 ticket/x main "" MERGEABLE CLEAN operator; exit 0
fi
echo ""
EOF
chmod +x "$T/lib/fakebin/gh"
export LFX="$T/lib/fx"
# libcall <lane-name> <shell text> — the library in a lane named <lane-name> ($0)
libcall() {
  ( cd "$T/lib" && PATH="$T/lib/fakebin:$PATH" HARNESS="$LH" HARNESS_SECRET=s JOBS_URL=https://jobs.test \
      JOBS_RETRIES=0 JOBS_BOX=box-l BLOCK_GATE_STREAK_K="${K:-1}" \
      bash -c '. "$HARNESS/bin/lib/block-gate.sh"; . "$HARNESS/bin/lib/ticket-ownership.sh"; eval "$1"' "$1" "$2" )
}
lreset() { vd_reset; rm -f "$LFX"/*; : > "$LFX/gh-calls"; scratch_rm "$LH/state" 2>/dev/null; mkdir -p "$LH/state"; : > "$LH/logs/lane.log"; }

# L1. the lane call site exists and holds a lead PR with no row (rc 0, no alert)
lreset; echo OPEN > "$LFX/pr-41.state"   # a plain (non-train) lead PR, readable
got=$(libcall merge-demo 'to_lane_lead_fence demo o/r 41 '"$H1"' '"$LEAD"' "$HARNESS/logs/lane.log"; echo "rc=$?"')
[ "$got" = "rc=0" ] && ok || bad "L1: to_lane_lead_fence must hold a lead PR with no row with rc 0 (got '$got')"
[ ! -s "$LFX/alerts" ] && ok || bad "L1: a lead PR WAITING on its lead is not an outage — no alert ($(cat "$LFX/alerts" 2>/dev/null))"

# L2. the lead row is unreadable: rc 2 for every PR, and ONE alert for the lane
#     (the verdicts outage stamp), not one per PR.
lreset; touch "$VD/lead-down"
got=$(libcall merge-demo 'for n in 41 42 43; do to_lane_lead_fence demo o/r $n '"$H1"' '"$LEAD"' "$HARNESS/logs/lane.log"; printf "%s " "$?"; done')
[ "$got" = "2 2 2 " ] && ok || bad "L2: an unreadable lead row answers rc 2 for every PR (got '$got')"
[ "$(lead_alerts "$LFX/alerts")" = 1 ] && ok \
  || bad "L2: THE DEFECT — three PRs in one lead-row outage must raise ONE lane-wide alert, got $(lead_alerts "$LFX/alerts"): $(cat "$LFX/alerts" 2>/dev/null)"
grep -q 'lead-row-unreadable:box-l:merge-demo' "$LFX/alerts" 2>/dev/null && ok \
  || bad "L2: the alert id is lane-wide (lead-row-unreadable:<box>:<lane>): $(cat "$LFX/alerts" 2>/dev/null)"
got=$(libcall merge-demo 'to_lane_lead_fence demo o/r 44 '"$H1"' '"$LEAD"' "$HARNESS/logs/lane.log"; echo $?')
[ "$(lead_alerts "$LFX/alerts")" = 1 ] && ok || bad "L2: a fourth PR in the same outage is still the same alert"
got=$(libcall other-lane 'to_lane_lead_fence demo o/r 41 '"$H1"' '"$LEAD"' "$HARNESS/logs/lane.log"; echo $?')
[ "$(lead_alerts "$LFX/alerts")" = 2 ] && ok || bad "L2: another lane is its own alert ($(cat "$LFX/alerts"))"
# the outage ends: one clean block-gate scan clears the stamp, the next outage alerts again
rm -f "$VD/lead-down"
libcall merge-demo 'bg_streak_note o/r 41 '"$H1"' 0 ""' >/dev/null
touch "$VD/lead-down"
libcall merge-demo 'to_lane_lead_fence demo o/r 45 '"$H1"' '"$LEAD"' "$HARNESS/logs/lane.log"' >/dev/null
[ "$(lead_alerts "$LFX/alerts")" = 3 ] && ok || bad "L2: a NEW outage window after a clean scan alerts again ($(lead_alerts "$LFX/alerts"))"

# L3. the verdicts outage keeps its one-alert-per-lane behaviour through the fence
lreset; touch "$VD/down"; echo OPEN > "$LFX/pr-41.state"; echo OPEN > "$LFX/pr-42.state"
libcall merge-demo 'for n in 41 42; do to_lane_lead_fence demo o/r $n '"$H1"' '"$LEAD"' "$HARNESS/logs/lane.log"; done' >/dev/null
[ "$(grep -c 'verdicts-unreadable' "$LFX/alerts" 2>/dev/null)" = 1 ] && ok \
  || bad "L3: two PRs in one verdicts outage raise one alert ($(cat "$LFX/alerts" 2>/dev/null))"

# L5 (#1624 round-2 review B1, rule A). A lead-authored PR is fenced WHATEVER
#     its title or ref look like. round 2 exempted "trains" by shape, and the
#     shape is a title prefix OR a branch prefix anyone can type: a lead hand
#     PR titled "Merge train…" or pushed to train/… auto-merged on a box
#     APPROVE with no lead row — the #1547 hole again. Every row below, the
#     reviewer's five spoofs plus the two genuine train shapes, is HELD (rc 0).
#     And because a real train opened under the lead's login would otherwise
#     sit held in silence, a train-SHAPED held lead PR raises ONE alert per
#     (PR, head): reopen it as the App, or post a lead MERGE row.
cp "$DIR/bin/lib/train-shape.sh" "$LH/bin/lib/" 2>/dev/null
lpr() { # lpr <n> <title> <ref> [head] — a lead-authored open PR
  jq -nc --arg t "$2" --arg r "$3" --arg h "${4:-$H1}" \
    '{state:"open",merged_at:null,title:$t,head:{sha:$h,ref:$r},base:{ref:"main"},user:{login:"operator",type:"User"},body:""}' > "$LFX/pr-$1.json"; }
train_alerts() { [ -f "$LFX/alerts" ] || { echo 0; return 0; }; grep -c 'lead-authored-train' "$LFX/alerts" || true; }
L5N=70
while IFS='|' read -r L5T L5R L5W; do
  [ -n "$L5T" ] || continue
  L5N=$((L5N + 1)); lreset; lpr "$L5N" "$L5T" "$L5R"
  got=$(libcall merge-demo 'to_lane_lead_fence demo o/r '"$L5N"' '"$H1"' '"$LEAD"' "$HARNESS/logs/lane.log"; echo "rc=$?"')
  [ "$got" = "rc=0" ] && ok || bad "L5: THE DEFECT ($L5W) — a lead PR titled '$L5T' on '$L5R' must be HELD (got '$got')"
  [ "$(train_alerts)" = 1 ] && ok || bad "L5 ($L5W): a train-shaped held lead PR raises exactly one alert (got $(train_alerts): $(cat "$LFX/alerts" 2>/dev/null))"
done <<'ROWS'
BH-99: lead WIP, not ready|train/wip-thing|spoof 1: ref train/
BH-99: lead WIP|batch/anything|spoof 2: ref batch/
Merge train: lead refactor|lead/1700-refactor|spoof 3: title Merge train
batch(docs) lead cleanup|lead/1701|spoof 4: title batch(
  merge TRAIN of my own|ticket/bh-75-local|spoof 5: indented mixed-case title
merge train: 3 approved PRs|train/demo/20260922-1|a genuine union train shape
batch(demo): land 2 approved siblings as one train|batch/demo/20260922-1-2|a genuine batch train shape
ROWS
# the control: a plain lead PR is held and raises NO train alert (it is simply waiting on its lead)
lreset; lpr 79 "BH-76: plain lead PR" "lead/1702"
got=$(libcall merge-demo 'to_lane_lead_fence demo o/r 79 '"$H1"' '"$LEAD"' "$HARNESS/logs/lane.log"; echo "rc=$?"')
[ "$got" = "rc=0" ] && [ "$(train_alerts)" = 0 ] && ok || bad "L5: a plain lead PR is held and raises no train alert (got '$got', $(train_alerts) alert(s))"
# ALERT ONCE per (PR, head): the same head on later ticks and on another lane
# is the same alert; a NEW head of the same PR is a new one.
lreset; lpr 80 "Merge train: lead refactor" "lead/1700-refactor"
for i in 1 2 3; do libcall merge-demo 'to_lane_lead_fence demo o/r 80 '"$H1"' '"$LEAD"' "$HARNESS/logs/lane.log"' >/dev/null; done
libcall other-lane 'to_lane_lead_fence demo o/r 80 '"$H1"' '"$LEAD"' "$HARNESS/logs/lane.log"' >/dev/null
[ "$(train_alerts)" = 1 ] && ok || bad "L5: THE DEFECT — one alert per (PR, head), not per tick or per lane (got $(train_alerts))"
lpr 80 "Merge train: lead refactor" "lead/1700-refactor" "$H2"
libcall merge-demo 'to_lane_lead_fence demo o/r 80 '"$H2"' '"$LEAD"' "$HARNESS/logs/lane.log"' >/dev/null
[ "$(train_alerts)" = 2 ] && ok || bad "L5: a new head of the same PR is a new alert (got $(train_alerts))"
grep -q 'App\|lead MERGE' "$LFX/alerts" 2>/dev/null && ok || bad "L5: the alert says how to clear it (reopen as the App, or a lead MERGE row): $(cat "$LFX/alerts" 2>/dev/null)"
# …and a train-shaped lead PR WITH a lead MERGE row on its head merges (the
# verdict is the clearance, never the shape) and alerts nothing.
lreset; lpr 81 "merge train: 3 approved PRs" "train/demo/20260922-2"; vd_put "$H1" MERGE lead 81
got=$(libcall merge-demo 'to_lane_lead_fence demo o/r 81 '"$H1"' '"$LEAD"' "$HARNESS/logs/lane.log"; echo "rc=$?"')
[ "$got" = "rc=1" ] && [ "$(train_alerts)" = 0 ] && ok || bad "L5: a lead MERGE row clears a lead-authored train, silently (got '$got', $(train_alerts) alert(s))"

# L4. PRUNE: the MERGE_HELD dedupe files of closed PRs go; open ones stay.
lreset
libcall merge-demo 'for n in 41 42 43; do to_lane_lead_hold demo o/r $n '"$H1"' '"$LEAD"' "$HARNESS/logs/lane.log"; done' >/dev/null
HELD="$LH/state/ticket-ownership/held"
[ "$(ls "$HELD" 2>/dev/null | wc -l | tr -d ' ')" = 3 ] && ok || bad "L4: three held PRs write three dedupe files ($(ls "$HELD" 2>/dev/null))"
printf 'x' > "$HELD/1234567890"      # a pre-BH-1606 file: nothing can say whose it is
echo CLOSED > "$LFX/pr-42.state"; echo OPEN > "$LFX/pr-43.state"
: > "$LFX/gh-calls"   # only the PRUNE's reads count below (the holds above read the PRs themselves)
libcall merge-demo 'to_held_prune o/r 41' >/dev/null
left=$(ls "$HELD" 2>/dev/null | tr '\n' ' ')
case "$left" in *"#41."*) ok ;; *) bad "L4: PR 41 is in the open list — its file stays (left: $left)" ;; esac
case "$left" in *"#42."*) bad "L4: THE DEFECT — PR 42 is CLOSED and its dedupe file must be pruned (left: $left)" ;; *) ok ;; esac
case "$left" in *"#43."*) ok ;; *) bad "L4: PR 43 is not in the list but GitHub says OPEN — its file stays (left: $left)" ;; esac
[ -e "$HELD/1234567890" ] && bad "L4: a legacy unkeyed dedupe file is pruned (left: $left)" || ok
grep -q 'pulls/41' "$LFX/gh-calls" && bad "L4: a PR in the open list costs no read ($(cat "$LFX/gh-calls"))" || ok
# an unreadable state keeps the file (not this pass)
lreset
libcall merge-demo 'to_lane_lead_hold demo o/r 46 '"$H1"' '"$LEAD"' "$HARNESS/logs/lane.log"' >/dev/null
libcall merge-demo 'to_held_prune o/r 41' >/dev/null
ls "$HELD" 2>/dev/null | grep -q '#46\.' && ok || bad "L4: a PR whose state cannot be read keeps its file ($(ls "$HELD" 2>/dev/null))"

# ════════════════════════════════════════════════════════════════════════════
# Q. bin/merge-queue.sh, WHOLE.
# ════════════════════════════════════════════════════════════════════════════
QT="$T/q"; QH="$QT/h"; QFX="$QT/fx"
mkdir -p "$QH/bin/lib/jobs" "$QH/bin/lib/mc" "$QH/logs" "$QH/state" "$QH/env" "$QH/flags" "$QH/locks" "$QH/builds" "$QT/fakebin" "$QFX"
cp "$DIR/bin/merge-queue.sh" "$DIR/bin/jobs-client.sh" "$QH/bin/"
cp "$DIR"/bin/lib/jobs/*.sh "$QH/bin/lib/jobs/"; cp "$DIR"/bin/lib/mc/*.sh "$QH/bin/lib/mc/"
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" \
   "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/gh-repo-token.sh" \
   "$DIR/bin/lib/block-gate.sh" "$DIR/bin/lib/verdicts.sh" "$DIR/bin/lib/ticket-ownership.sh" "$DIR/bin/lib/hold.sh" "$QH/bin/lib/"
cp "$DIR/bin/lib/train-shape.sh" "$QH/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$QT/fakebin/restpr"; chmod +x "$QT/fakebin/restpr"
for s in beat.sh deploy-request.sh lander.sh review-tighten.sh; do printf '#!/bin/bash\nexit 0\n' > "$QH/bin/$s"; chmod +x "$QH/bin/$s"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$QFX" > "$QH/bin/lane-alert.sh"; chmod +x "$QH/bin/lane-alert.sh"
for s in flock git sleep; do printf '#!/bin/bash\nexit 0\n' > "$QT/fakebin/$s"; chmod +x "$QT/fakebin/$s"; done
cp "$T/worker-curl" "$QT/fakebin/curl"
cat > "$QH/bin/fleet-conf.sh" <<'SHIM'
#!/bin/bash
case "$1 ${2:-}" in
  "--projects ")      echo iss ;;
  "iss repo")         echo "o/r" ;;
  "iss board_prefix") echo "-" ;;
esac
exit 0
SHIM
chmod +x "$QH/bin/fleet-conf.sh"
printf 'iss o/r https://iss.example - 9 box-q 10.0.0.9\n' > "$QH/fleet.conf"
printf 'HARNESS_SECRET=test-secret\nJOBS_URL=https://jobs.invalid\nJOBS_RETRIES=0\nJOBS_BOX=box-q\nBLOCK_GATE_ENFORCE=0\nBLOCK_GATE_STREAK_K=1\n' > "$QH/env/global.env"
: > "$QH/env/iss.env"
# gh: PR <n> is $QFX/pr-<n>.json; its LIVE head is $QFX/live-<n> when set. A
# merge pinned (REST sha= or --match-head-commit) to another head is refused as
# GitHub refuses it; a landed PR reads back merged.
cat > "$QT/fakebin/gh" <<'SHIM'
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "$*" >> "$QFX/argv.log"
I=0; case " $* " in *" -i "*) I=1 ;; esac
hdr() { [ "$I" = 1 ] && printf 'HTTP/1.1 %s Stub\r\n\r\n' "$1"; return 0; }
N=$(printf '%s' "$*" | sed -nE 's#.*repos/[^/]+/[^/]+/(issues|pulls)/([0-9]+).*#\2#p')
[ -n "$N" ] || N=$(printf '%s' "$*" | grep -oE '[0-9]+' | head -1)
case "$*" in
  *"pr merge"*|*"-X PUT"*"/merge"*)
    pin=$(printf '%s' "$*" | sed -nE 's/.*(--match-head-commit |sha=)([0-9a-f]{40}).*/\2/p')
    live=$(jq -r '.head.sha' "$QFX/pr-$N.json" 2>/dev/null); [ -f "$QFX/live-$N" ] && live=$(cat "$QFX/live-$N")
    if [ -n "$pin" ] && [ "$pin" != "$live" ]; then
      printf '%s\n' "$*" >> "$QFX/refused"; hdr 409; echo '{"message":"Head branch was modified. Review and try the merge again."}'
      [ "$I" = 1 ] && exit 0; echo "Head branch was modified. Review and try the merge again." >&2; exit 1
    fi
    printf '%s\n' "$N" >> "$QFX/merged.log"; printf '%s\n' "$*" >> "$QFX/merges"; hdr 200; echo '{"merged":true,"sha":"dddddddd4444"}'; exit 0 ;;
  *"/issues/"*"/comments"*) hdr 200; echo '[]'; exit 0 ;;
  *"/pulls/"*"/reviews"*) hdr 200; echo '[]'; exit 0 ;;
  *"/issues/"*) hdr 200; jq -nc --argjson n "$N" '{number:$n,state:"open",labels:[{name:"ai-build"}],title:"BH-\($n): x",body:"## Build"}'; exit 0 ;;
  *"/pulls/"*)
    [ -s "$QFX/pr-$N.json" ] || { hdr 404; echo '{"message":"Not Found"}'; exit 0; }
    hdr 200
    if grep -qx "$N" "$QFX/merged.log" 2>/dev/null; then jq -c '.state="closed" | .merged_at="2026-09-23T12:00:00Z" | .merge_commit_sha="dddddddd4444"' "$QFX/pr-$N.json"
    else cat "$QFX/pr-$N.json"; fi
    exit 0 ;;
esac
printf '\n'
exit 0
SHIM
chmod +x "$QT/fakebin/gh"
export QFX
qpr() { # qpr <n> <login> [title] [ref] [conflicting] — an open PR at $H1 closing issue <n>
  jq -nc --argjson n "$1" --arg l "$2" --arg h "$H1" --arg t "${3:-BH-$1: x}" --arg r "${4:-ticket/bh-$1}" --arg c "${5:-}" \
    '{number:$n,state:"open",merged_at:null,title:$t,head:{ref:$r,sha:$h},base:{ref:"main"},labels:[],
      mergeable:($c == ""),mergeable_state:(if $c == "" then "clean" else "dirty" end),
      user:{login:$l,type:"User"},merge_commit_sha:null,body:"Closes #\($n)",draft:false}' > "$QFX/pr-$1.json"
}
# lander.sh RECORDS: it writes code into the branch (a rewrite the lead never saw)
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lander"\nexit 1\n' "$QFX" > "$QH/bin/lander.sh"; chmod +x "$QH/bin/lander.sh"
QQ="$QH/state/merge-queue/iss"
mq() { # mq <pr>… — one whole queue pass with exactly these entries
  scratch_rm "$QQ" 2>/dev/null; mkdir -p "$QQ"; local n; for n in "$@"; do : > "$QQ/$n"; done
  : > "$QFX/merged.log"; : > "$QFX/merges"; rm -f "$QFX/refused"; : > "$QH/logs/merge-queue.log"
  ( cd "$QT" && PATH="$QT/fakebin:$PATH" HARNESS="$QH" FLEET_CONF="$QH/fleet.conf" \
      bash "$QH/bin/merge-queue.sh" iss >/dev/null 2>>"$QT/mq.err" ) || true
}
qreset() { vd_reset; rm -f "$QFX"/pr-*.json "$QFX"/live-* "$QFX/alerts"; : > "$QFX/argv.log"
           scratch_rm "$QH/state/block-gate" 2>/dev/null; scratch_rm "$QH/state/ticket-ownership" 2>/dev/null; return 0; }
QLOG="$QH/logs/merge-queue.log"

# Q1. a lead PR, no lead row: not landed, held with one line, entry kept.
qreset; qpr 51 "$LEAD"
mq 51
grep -qx 51 "$QFX/merged.log" && bad "Q1: THE DEFECT — the box queue landed a LEAD PR with no lead verdict row ($(cat "$QFX/merges"))" || ok
grep -q '#51 MERGE_HELD lead-pr' "$QLOG" && ok || bad "Q1: the hold is logged as a lead-PR hold ($(cat "$QLOG"); err $(tail -c 300 "$QT/mq.err"))"
[ -f "$QQ/51" ] && ok || bad "Q1: the entry stays queued for the lead's verdict"
# Q2. a lead MERGE row on the exact live head: lands, pinned to that head.
qreset; qpr 51 "$LEAD"; vd_put "$H1" MERGE lead 51
mq 51
grep -qx 51 "$QFX/merged.log" && ok || bad "Q2: a lead MERGE on the live head lands the lead PR ($(cat "$QLOG"))"
grep -Eq -- "(--match-head-commit |sha=)$H1" "$QFX/merges" && ok || bad "Q2: the landing is pinned to the head the verdict was read on ($(cat "$QFX/merges"))"
# Q2b. the head moves between the verdict read and the merge: the pin refuses it.
qreset; qpr 51 "$LEAD"; vd_put "$H1" MERGE lead 51; printf '%s' "$H2" > "$QFX/live-51"
mq 51
grep -qx 51 "$QFX/merged.log" && bad "Q2b: a verdict on $H1 must not land live head $H2 ($(cat "$QFX/merges"))" || ok
# Q3. a lead MERGE row only on an older head: not landed.
qreset; qpr 51 "$LEAD"; vd_put "$H0" MERGE lead 51
mq 51
grep -qx 51 "$QFX/merged.log" && bad "Q3: a MERGE on an earlier head must not land the live one ($(cat "$QFX/merges"))" || ok
# Q4. the lead row is unreadable, two entries: neither lands, ONE alert.
qreset; qpr 51 "$LEAD"; qpr 52 "$BOT"; touch "$VD/lead-down"
mq 51 52
[ -s "$QFX/merged.log" ] && bad "Q4: an unreadable lead row must hold every entry ($(cat "$QFX/merged.log"))" || ok
[ "$(lead_alerts "$QFX/alerts")" = 1 ] && ok || bad "Q4: ONE lane-wide alert for the outage, got $(lead_alerts "$QFX/alerts"): $(cat "$QFX/alerts" 2>/dev/null)"
[ -f "$QQ/51" ] && [ -f "$QQ/52" ] && ok || bad "Q4: both entries stay queued"
# Q5. control: a pool PR lands as today, and pinned.
qreset; qpr 52 "$BOT"
mq 52
grep -qx 52 "$QFX/merged.log" && ok || bad "Q5: a pool PR still lands ($(cat "$QLOG"); err $(tail -c 300 "$QT/mq.err"))"
grep -Eq -- "(--match-head-commit |sha=)$H1" "$QFX/merges" && ok || bad "Q5: every landing is pinned ($(cat "$QFX/merges"))"
# Q7 (#1624 review I2). A HELD lead PR that conflicts with main: the queue must
#     ask the fence BEFORE its rebase / force-push / lander round, or it
#     rewrites a branch the lead is still judging and the verdict dies with it.
qreset; rm -f "$QFX/lander"; qpr 53 "$LEAD" "" "" conflicting
mq 53
[ -s "$QFX/lander" ] && bad "Q7: THE DEFECT — the queue ran the lander (a branch rewrite) on a HELD lead PR ($(cat "$QFX/lander"); log $(cat "$QLOG"))" || ok
grep -q '#53 MERGE_HELD lead-pr' "$QLOG" && ok || bad "Q7: the hold is logged before any rewrite ($(cat "$QLOG"))"
[ -f "$QQ/53" ] && [ ! -f "$QQ/53.blocked" ] && ok || bad "Q7: the entry stays queued, not parked"
#     …and a CLEARED lead PR that conflicts is not rewritten either: its verdict
#     stands on this head only, so it is left for the lead.
qreset; rm -f "$QFX/lander"; qpr 53 "$LEAD" "" "" conflicting; vd_put "$H1" MERGE lead 53
mq 53
[ -s "$QFX/lander" ] && bad "Q7: a cleared lead PR must not be rewritten by the queue ($(cat "$QFX/lander"))" || ok
grep -q '#53 .*left for the lead' "$QLOG" && ok || bad "Q7: the log says a cleared lead PR that needs a rebase is left for the lead ($(cat "$QLOG"))"
#     control: a conflicting POOL PR still gets the rebase/lander round.
qreset; rm -f "$QFX/lander"; qpr 54 "$BOT" "" "" conflicting
mq 54
[ -s "$QFX/lander" ] && ok || bad "Q7: a conflicting pool PR still goes to the lander as today ($(cat "$QLOG"))"
# Q8 (#1624 round-2 B1, rule A). A lead-authored MERGE TRAIN is held like any
#     lead PR — the shape is never a clearance — and it is held LOUDLY: one
#     alert per (PR, head), however many passes see it.
# (A train/* HEAD never reaches the fence here: BH-1285 drops it from the box
# queue first. The title is the shape that does — spoof row 3.)
qreset; qpr 55 "$LEAD" "Merge train: lead refactor" "lead/1700-refactor"
mq 55; mq 55
grep -qx 55 "$QFX/merged.log" && bad "Q8: THE DEFECT — the queue landed a lead-authored train with no lead row ($(cat "$QFX/merges"))" || ok
[ "$(grep -c 'lead-authored-train' "$QFX/alerts" 2>/dev/null || true)" = 1 ] && ok \
  || bad "Q8: two passes over a held lead-authored train raise exactly one alert ($(cat "$QFX/alerts" 2>/dev/null))"

# Q6. all three landing paths ask (the union train is not drivable without a clone).
[ "$(grep -c 'mq_lead_hold "\$' "$DIR/bin/merge-queue.sh")" -ge 3 ] && ok \
  || bad "Q6: the box queue asks the lead fence on all three landing paths (assembly, train landing, serial)"

# ════════════════════════════════════════════════════════════════════════════
# C. bin/merge-conductor.sh, WHOLE TICK.
# ════════════════════════════════════════════════════════════════════════════
CT="$T/ct"; mkdir -p "$CT"
fx_mc_harness "$DIR" "$CT" && fx_conductor_tick "$DIR" "$CT" || bad "C0: the conductor fixture did not build"
CH="$CT/h"
cp "$DIR/bin/lib/lane-gate.sh" "$DIR/bin/lib/lanes-registry.sh" "$DIR/bin/lib/block-gate.sh" "$DIR/bin/lib/verdicts.sh" "$CH/bin/lib/"
mkdir -p "$CH/catalog"; cp -R "$DIR/catalog/lanes.d" "$CH/catalog/"
"$DIR/bin/lanes-build.sh" --root "$CH" --write >/dev/null 2>&1 || bad "C0: could not render the lane registry"
printf 'issuer example-org/issuer - - 3 box-issuer\n' > "$CH/fleet.conf"
: > "$CH/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$CH/bin/agent-call.sh"; chmod +x "$CH/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$CT" > "$CH/bin/lane-alert.sh"; chmod +x "$CH/bin/lane-alert.sh"
CREC="$CH/builds/pool-issuer-IS-9-202609230001"; mkdir -p "$CREC"
echo "PR_CREATED https://github.com/example-org/issuer/pull/9" > "$CREC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$CREC/review.md"
echo "$H1" > "$CREC/reviewed-sha"
cat > "$CT/fakebin/gh" <<GHSTUB
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$CT/gh-calls.txt"
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"-X POST"*"/comments"*) printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1}\n' ;;
  *"pr merge"*|*"-X PUT"*"/merge"*) printf '%s\n' "\$*" >> "$CT/merged.txt"; touch "$CT/merged9"; printf 'HTTP/1.1 200 OK\r\n\r\n{"merged":true,"sha":"cccccccc3333"}\n' ;;
  *"api -i -X GET repos/example-org/issuer/pulls -f state=open"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
  *"pr list -R example-org/issuer --state open"*) cat "$CT/openlist.json" ;;
  *"pr list"*) echo "[]" ;;
  *"repos/example-org/issuer/pulls?state=closed"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
  *"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/example-org/issuer/pulls/9")
    if [ -f "$CT/merged9" ]; then restpr MERGED "$H1" ticket/is-9 main "" MERGEABLE CLEAN "\$(cat "$CT/author")" cccccccc3333 "Closes #9"
    else restpr OPEN "$H1" ticket/is-9 main "" MERGEABLE CLEAN "\$(cat "$CT/author")" "" "Closes #9"; fi ;;
  *"api -i -X GET repos/example-org/issuer/issues/9") restpr --raw 200 '{"state":"open"}' ;;
  *"repos/example-org/issuer/issues/9/comments?per_page"*) echo '[]' ;;
  "api repos/example-org/issuer/issues/9") echo '{"number":9,"state":"open","labels":[{"name":"ai-build"}],"title":"IS-9","body":"scope"}' ;;
  *"actions/runs?head_sha=$H1"*) printf 'completed|success\n' ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
GHSTUB
chmod +x "$CT/fakebin/gh"
cp "$T/worker-curl" "$CT/fakebin/curl"
jq -nc --arg h "$H1" '[{number:9,url:"https://github.com/example-org/issuer/pull/9",headRefOid:$h,headRefName:"ticket/is-9",baseRefName:"main",isDraft:false,mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",state:"OPEN",updatedAt:"2026-09-23T10:00:00Z"}]' > "$CT/openlist.json"
ctick() { # ctick <author> [provcleared] — one whole merge-mode tick on READY PR 9
  local d; for d in "$CH/state" "$CH/logs" "$CH/locks" "$CH/flags"; do scratch_rm "$d"; done
  mkdir -p "$CH/state/merge-conductor" "$CH/logs" "$CH/locks" "$CH/flags"
  : > "$CT/gh-calls.txt"; : > "$CT/merged.txt"; rm -f "$CT/merged9"; printf '%s' "$1" > "$CT/author"
  : > "$CH/flags/merge-conductor-actions"; : > "$CH/flags/merge-conductor-merge"
  [ "${2:-}" = provcleared ] && echo "provcleared example-org/issuer#9 $H1" > "$CH/state/merge-conductor/attempts.txt"
  ( cd "$CT" && PATH="$CT/fakebin:$PATH" HARNESS="$CH" HARNESS_SECRET=x JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 \
      JOBS_BOX=box-c FLEET_CONF="$CH/fleet.conf" BLOCK_GATE_ENFORCE=0 BLOCK_GATE_STREAK_K=1 \
      MC_MAIN_RED_DETECT=0 MC_MERGE_SETTLE=0 bash "$CH/bin/merge-conductor.sh" >/dev/null 2>>"$CT/tick.err" ) || true
}
CLOG="$CH/logs/merge-conductor.log"
creset() { vd_reset; rm -f "$CT/alerts"; }

# C0. control: a pool PR, READY, merges (the fixture really reaches the merge).
creset; ctick "app/cromford"
[ -s "$CT/merged.txt" ] && ok || bad "C0: a READY pool PR merges ($(grep 'issuer#9' "$CLOG" 2>/dev/null | tail -4); err $(tail -c 300 "$CT/tick.err"))"
# C1. a READY lead PR with no lead row: no merge, one MERGE_HELD line.
creset; ctick "$LEAD"
[ -s "$CT/merged.txt" ] && bad "C1: THE DEFECT — the conductor merged a LEAD PR with no lead verdict row ($(cat "$CT/merged.txt"))" || ok
[ "$(grep -c 'issuer#9 MERGE_HELD lead-pr' "$CLOG" 2>/dev/null)" = 1 ] && ok \
  || bad "C1: exactly one MERGE_HELD lead-pr line ($(grep 'issuer#9' "$CLOG" 2>/dev/null | tail -4))"
# C1b. a provenance clearance (the #1536 provcleared marker) never bypasses it.
creset; ctick "$LEAD" provcleared
[ -s "$CT/merged.txt" ] && bad "C1b: a provcleared marker must not merge a lead PR with no lead row ($(cat "$CT/merged.txt"))" || ok
# C2. a lead MERGE row on the exact head: merges, pinned to it.
creset; vd_put "$H1" MERGE lead; ctick "$LEAD"
[ -s "$CT/merged.txt" ] && ok || bad "C2: a lead MERGE on the live head merges ($(grep 'issuer#9' "$CLOG" 2>/dev/null | tail -4))"
grep -Eq -- "(--match-head-commit |sha=)$H1" "$CT/merged.txt" && ok || bad "C2: the merge is pinned to the head the verdict was read on ($(cat "$CT/merged.txt"))"
# C3. a lead MERGE row only on an older head: no merge.
creset; vd_put "$H0" MERGE lead; ctick "$LEAD"
[ -s "$CT/merged.txt" ] && bad "C3: a MERGE on an earlier head must not merge the live one ($(cat "$CT/merged.txt"))" || ok
# C4. an unreadable lead row: no merge (even for a pool PR), and the lane alert.
creset; touch "$VD/lead-down"; ctick "app/cromford"
[ -s "$CT/merged.txt" ] && bad "C4: an unreadable lead row must not let a PR merge ($(cat "$CT/merged.txt"))" || ok
[ "$(lead_alerts "$CT/alerts")" = 1 ] && ok || bad "C4: the lead-row outage raises the lane-wide alert ($(cat "$CT/alerts" 2>/dev/null); log $(grep 'issuer#9' "$CLOG" 2>/dev/null | tail -3))"
grep -q 'lead-row-unreadable:box-c:merge-conductor' "$CT/alerts" 2>/dev/null && ok || bad "C4: keyed to the lane ($(cat "$CT/alerts" 2>/dev/null))"

# C5 (#1624 review S1). The fence costs the conductor NO extra PR read: the
#     pre-merge state guard already fetched the pull, and its author rides in.
#     With the ownership library a pool PR's tick may make exactly ONE more
#     pulls/9 read than with none at all — the ticket hold's own (to_merge_hold,
#     BH-1526, reads the PR body for its issue). A second one is the fence.
pulls9() { grep -c 'repos/example-org/issuer/pulls/9$' "$CT/gh-calls.txt" 2>/dev/null || true; }
creset; ctick "app/cromford"; WITH=$(pulls9)
mv "$CH/bin/lib/ticket-ownership.sh" "$CT/to.off"
creset; ctick "app/cromford"; WITHOUT=$(pulls9)
mv "$CT/to.off" "$CH/bin/lib/ticket-ownership.sh"
[ "${WITH:-0}" = "$(( ${WITHOUT:-0} + 1 ))" ] && [ "${WITHOUT:-0}" -gt 0 ] && ok \
  || bad "C5: THE DEFECT — the lead fence re-reads the pull the state guard already read (pulls/9 reads: $WITH with the fence, $WITHOUT without)"

# ════════════════════════════════════════════════════════════════════════════
# S. bin/merge-sweep.sh, WHOLE.
# ════════════════════════════════════════════════════════════════════════════
ST="$T/sw"; mkdir -p "$ST"
fx_mc_harness "$DIR" "$ST" || bad "S0: the sweep fixture did not build"
cp "$DIR/bin/merge-sweep.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$ST/h/bin/"
mkdir -p "$ST/h/bin/lib" && cp -rL "$DIR/bin/lib/ms" "$ST/h/bin/lib/" || exit 1   # BH-5242: the sweep loads bin/lib/ms/
mkdir -p "$ST/h/bin/lib/jobs"; cp "$DIR"/bin/lib/jobs/*.sh "$ST/h/bin/lib/jobs/"
cp "$DIR/bin/lib/ticket-ownership.sh" "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/block-gate.sh" "$DIR/bin/lib/verdicts.sh" "$ST/h/bin/lib/"
for s in beat.sh deploy-request.sh codegraph-ensure.sh; do printf '#!/bin/bash\nexit 0\n' > "$ST/h/bin/$s"; chmod +x "$ST/h/bin/$s"; done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$ST" > "$ST/h/bin/lane-alert.sh"; chmod +x "$ST/h/bin/lane-alert.sh"
printf 'issuer example-org/issuer - - - box-issuer\n' > "$ST/h/fleet.conf"
printf 'HARNESS_SECRET=x\nJOBS_URL=https://jobs.invalid\n' > "$ST/h/env/global.env"
SREC="$ST/h/builds/pool-issuer-IS-9-202609230003"; mkdir -p "$SREC" "$ST/h/state" "$ST/tmp"
echo "PR_CREATED https://github.com/example-org/issuer/pull/9" > "$SREC/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$SREC/review.md"
cp "$T/worker-curl" "$ST/fakebin/curl"
cat > "$ST/fakebin/gh" <<GHSTUB
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$ST/gh-argv.log"
case "\$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"pr merge"*|*"-X PUT"*"/merge"*) touch "$ST/merged9"; echo "\$*" >> "$ST/merged.txt"; printf 'HTTP/1.1 200 OK\r\n\r\n{"merged":true,"sha":"cccc3333"}\n'; exit 0 ;;
  *"-X PATCH"*|*"issue close"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"closed"}\n'; exit 0 ;;
  *"-X POST"*"/comments"*) printf 'HTTP/1.1 201 Created\r\n\r\n{"id":1}\n'; exit 0 ;;
  *"api -i -X GET repos/example-org/issuer/issues/9"*) printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"open"}\n'; exit 0 ;;
  *v3.diff*) printf 'HTTP/1.1 200 OK\r\n\r\n+++ b/src/x.ts\n+const a = 1;\n'; exit 0 ;;
  *"api -i -X GET repos/example-org/issuer/pulls/9"*)
    printf 'HTTP/1.1 200 OK\r\n\r\n'
    if [ -e "$ST/merged9" ]; then S=closed; M='"2026-09-22T00:00:00Z"'; else S=open; M=null; fi
    printf '{"state":"%s","merged_at":%s,"head":{"sha":"$H1","ref":"ticket/is-9"},"base":{"ref":"main"},"labels":[],"mergeable":true,"mergeable_state":"clean","user":{"login":"%s","type":"User"},"merge_commit_sha":"cccc3333","body":"Closes #9"}\n' "\$S" "\$M" "\$(cat "$ST/author")"
    exit 0 ;;
  *"repos/example-org/issuer/issues/9/comments?per_page"*) echo '[]'; exit 0 ;;
  "api repos/example-org/issuer/issues/9") echo '{"state":"open","labels":[{"name":"ai-build"}],"title":"IS-9","body":"scope"}'; exit 0 ;;
  *"pr view"*"--json state"*) if [ -e "$ST/merged9" ]; then echo MERGED; else echo OPEN; fi; exit 0 ;;
  *"pr view"*) echo ""; exit 0 ;;
  *"api repos/example-org/issuer -q .id"*) echo 1; exit 0 ;;
  *"actions/runs?head_sha="*) printf 'completed|success\n'; exit 0 ;;
  *"api -i"*) printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"no route"}\n'; exit 0 ;;
  *"rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"auth token"*) echo faketoken ;;
  *) echo "" ;;
esac
exit 0
GHSTUB
chmod +x "$ST/fakebin/gh"
sweep() { # sweep <author>
  : > "$ST/gh-argv.log"; : > "$ST/merged.txt"; rm -f "$ST/merged9" "$ST/alerts"; printf '%s' "$1" > "$ST/author"
  : > "$ST/h/state/merge-sweep-done.txt"; scratch_rm "$ST/h/logs"; mkdir -p "$ST/h/logs"
  scratch_rm "$ST/h/state/block-gate" 2>/dev/null; scratch_rm "$ST/h/state/ticket-ownership" 2>/dev/null
  ( export PATH="$ST/fakebin:$PATH" HARNESS="$ST/h" HARNESS_TEST_SANDBOX=1 TMPDIR="$ST/tmp" \
           FLEET_CONF="$ST/h/fleet.conf" SWEEP_MERGE_SETTLE=0 JOBS_RETRIES=0 JOBS_BOX=box-s \
           BLOCK_GATE_ENFORCE=0 BLOCK_GATE_STREAK_K=1
    bash "$ST/h/bin/merge-sweep.sh" >/dev/null 2>"$ST/sweep.err" )
}
SLOG="$ST/h/logs/merge-sweep.log"
# S0. control: a pool PR merges, pinned to the head every gate read.
vd_reset; sweep "app/cromford"
[ -s "$ST/merged.txt" ] && ok || bad "S0: a pool PR merges ($(tail -4 "$SLOG" 2>/dev/null); err $(head -c 300 "$ST/sweep.err"))"
grep -Eq -- "(--match-head-commit |sha=)$H1" "$ST/merged.txt" && ok || bad "S0: THE DEFECT — the sweep's merge must be pinned to the head it read ($(cat "$ST/merged.txt"))"
# S1. a lead PR, no lead row: no merge, one line.
vd_reset; sweep "$LEAD"
[ -s "$ST/merged.txt" ] && bad "S1: THE DEFECT — merge-sweep merged a LEAD PR with no lead verdict row ($(cat "$ST/merged.txt"))" || ok
[ "$(grep -c 'issuer#9 MERGE_HELD lead-pr' "$SLOG" 2>/dev/null)" = 1 ] && ok || bad "S1: one MERGE_HELD lead-pr line ($(tail -4 "$SLOG" 2>/dev/null))"
# S2. a lead MERGE row on the exact head: merges, pinned.
vd_reset; vd_put "$H1" MERGE lead; sweep "$LEAD"
[ -s "$ST/merged.txt" ] && ok || bad "S2: a lead MERGE on the live head merges ($(tail -4 "$SLOG" 2>/dev/null))"
grep -Eq -- "(--match-head-commit |sha=)$H1" "$ST/merged.txt" && ok || bad "S2: pinned to $H1 ($(cat "$ST/merged.txt"))"
# S3. a lead MERGE row only on an older head: no merge.
vd_reset; vd_put "$H0" MERGE lead; sweep "$LEAD"
[ -s "$ST/merged.txt" ] && bad "S3: a MERGE on an earlier head must not merge the live one ($(cat "$ST/merged.txt"))" || ok
# S4. an unreadable lead row: no merge, the lane alert.
vd_reset; touch "$VD/lead-down"; sweep "$LEAD"
[ -s "$ST/merged.txt" ] && bad "S4: an unreadable lead row must not merge ($(cat "$ST/merged.txt"))" || ok
[ "$(lead_alerts "$ST/alerts")" = 1 ] && ok || bad "S4: the lead-row outage raises the lane-wide alert ($(cat "$ST/alerts" 2>/dev/null); log $(tail -3 "$SLOG" 2>/dev/null))"

# ════════════════════════════════════════════════════════════════════════════
# E. bin/run-build.sh's tier-2 APPROVE enqueue — BOTH spellings of it.
# ════════════════════════════════════════════════════════════════════════════
EH="$T/e/h"; mkdir -p "$EH/bin/lib/jobs" "$EH/logs" "$EH/state" "$EH/env" "$EH/builds/b" "$T/e/fakebin" "$T/e/fx"
cp "$DIR/bin/jobs-client.sh" "$EH/bin/"; cp "$DIR"/bin/lib/jobs/*.sh "$EH/bin/lib/jobs/"
cp "$DIR/bin/lib/block-gate.sh" "$DIR/bin/lib/verdicts.sh" "$DIR/bin/lib/ticket-ownership.sh" \
   "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$EH/bin/lib/"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$T/e/fx" > "$EH/bin/lane-alert.sh"; chmod +x "$EH/bin/lane-alert.sh"
cp "$T/worker-curl" "$T/e/fakebin/curl"
cp "$DIR/tests/lib/rest-emit.sh" "$T/e/fakebin/restpr"; chmod +x "$T/e/fakebin/restpr"
cat > "$T/e/fakebin/gh" <<'EOF'
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
case "$*" in
  *"repos/example-org/demo-os/pulls/41"*) restpr OPEN aaaaaaaa11111111111111111111111111111111 ticket/bh-41 main "" MERGEABLE CLEAN "$(cat "$EFX/author")"; exit 0 ;;
esac
echo ""
EOF
chmod +x "$T/e/fakebin/gh"
export EFX="$T/e/fx"
awk '/^# >>> verdict at review/{f=1;next} /^# <<< verdict at review/{exit} f' "$RB_ALL" > "$T/e/at-review.sh"
awk '/^# >>> verdict artifact/{f=1;next} /^# <<< verdict artifact/{exit} f' "$RB_ALL" > "$T/e/artifact.sh"
[ -s "$T/e/at-review.sh" ] && [ -s "$T/e/artifact.sh" ] && ok || bad "E0: could not extract the two verdict blocks"
printf 'x\nVERDICT: APPROVE\n' > "$EH/builds/b/review.md"
enq() { # enq <block-file> <author> — prints the pipeline log; the POSTs land in $VD/mq-posts
  : > "$EH/builds/b/pipeline.log"; rm -f "$VD/mq-posts"; printf '%s' "$2" > "$EFX/author"
  ( cd "$T/e" && PATH="$T/e/fakebin:$PATH" HARNESS="$EH" HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
      JOBS_BOX=box-e BLOCK_GATE_STREAK_K=1 BUILD="$EH/builds/b" PROJECT=demo-os KEY=BH-41 TIER=2 \
      SLUG=example-org/demo-os PR_URL=https://github.com/example-org/demo-os/pull/41 JOB_ID=j1 \
      bash -c 'STAMP() { echo TS; }
        job_artifact_put() { return 0; }
        rp_out_is_claude() { return 0; }
        rp_out_prov() { echo claude; }
        . "$HARNESS/bin/jobs-client.sh"
        . "$HARNESS/bin/lib/block-gate.sh"
        . "$HARNESS/bin/lib/ticket-ownership.sh"
        . "$0"' "$1" 2>>"$T/e/err" ) || true
}
posted() { [ -f "$VD/mq-posts" ] || { echo 0; return 0; }; grep -c '"pr":41' "$VD/mq-posts" || true; }
for B in at-review artifact; do
  vd_reset; enq "$T/e/$B.sh" "$BOT"
  [ "$(posted)" = 1 ] && ok || bad "E1 ($B): control — a pool PR's APPROVE enqueues ($(cat "$EH/builds/b/pipeline.log"); err $(tail -c 300 "$T/e/err"))"
  vd_reset; enq "$T/e/$B.sh" "$LEAD"
  [ "$(posted)" = 0 ] && ok || bad "E2 ($B): THE DEFECT — a LEAD PR with no lead row must not be put on the box queue ($(cat "$EH/builds/b/pipeline.log"))"
  grep -q 'MERGE_HELD lead-pr' "$EH/builds/b/pipeline.log" && ok || bad "E2 ($B): the hold is logged ($(cat "$EH/builds/b/pipeline.log"))"
  vd_reset; vd_put "$H1" MERGE lead 41; enq "$T/e/$B.sh" "$LEAD"
  [ "$(posted)" = 1 ] && ok || bad "E3 ($B): a lead MERGE on the live head enqueues ($(cat "$EH/builds/b/pipeline.log"))"
  vd_reset; vd_put "$H0" MERGE lead 41; enq "$T/e/$B.sh" "$LEAD"
  [ "$(posted)" = 0 ] && ok || bad "E4 ($B): a MERGE on an earlier head must not enqueue the lead PR ($(cat "$EH/builds/b/pipeline.log"))"
  # unreadable: the entry still goes to the queue (whose own fence holds it —
  # Q4), because a worker outage must not cost a pool PR its only enqueue.
  vd_reset; touch "$VD/lead-down"; enq "$T/e/$B.sh" "$BOT"
  grep -q 'lead_pr_authors.*could not be read\|lead fence could not' "$EH/builds/b/pipeline.log" && ok \
    || bad "E5 ($B): an unreadable lead row at the enqueue is logged ($(cat "$EH/builds/b/pipeline.log"))"
done

# ════════════════════════════════════════════════════════════════════════════
# R. bin/review-prs.sh: a pinned merge refused with "Head branch was modified"
#    never reaches the box queue (it would land the new head unpinned).
# ════════════════════════════════════════════════════════════════════════════
RT="$T/r"; RH="$RT/h"; RFX="$RT/fx"
mkdir -p "$RH/bin/lib/jobs" "$RH/logs" "$RH/state" "$RH/flags" "$RH/env" "$RT/fakebin" "$RFX"
cp "$DIR/bin/jobs-client.sh" "$RH/bin/"; cp "$DIR"/bin/lib/jobs/*.sh "$RH/bin/lib/jobs/"
cp "$DIR/bin/lib/block-gate.sh" "$DIR/bin/lib/verdicts.sh" "$DIR/bin/lib/ticket-ownership.sh" \
   "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$RH/bin/lib/"
cat > "$RH/bin/fleet-conf.sh" <<'SHIM'
#!/bin/bash
case "$1 ${2:-}" in
  "--projects ")          echo demo-os ;;
  "demo-os repo")         echo "example-org/demo-os" ;;
  "demo-os board_prefix") echo "-" ;;
esac
exit 0
SHIM
chmod +x "$RH/bin/fleet-conf.sh"
printf 'demo-os example-org/demo-os - - 2 box-demo\n' > "$RH/fleet.conf"
: > "$RH/env/global.env"
for s in beat.sh deploy-request.sh merge-queue.sh lane-alert.sh; do printf '#!/bin/bash\nexit 0\n' > "$RH/bin/$s"; chmod +x "$RH/bin/$s"; done
cp "$T/worker-curl" "$RT/fakebin/curl"
cp "$DIR/tests/lib/rest-emit.sh" "$RT/fakebin/restpr"; chmod +x "$RT/fakebin/restpr"
cat > "$RT/fakebin/gh" <<'EOF'
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
case "$*" in
  *"api -i -X GET repos/"*"/issues/"*"/comments"*) printf 'HTTP/1.1 200 OK\r\n\r\n[]\n'; exit 0 ;;  # BH-1668: the PR's own thread (no HOLD), read over REST by to_merge_hold
  *"pr merge"*)
    pin=$(printf '%s' "$*" | sed -nE 's/.*--match-head-commit ([0-9a-f]+).*/\1/p')
    if [ -n "$pin" ] && [ "$pin" != "$(cat "$RFX/live-head")" ]; then
      echo "GraphQL: Head branch was modified. Review and try the merge again. (mergePullRequest)" >&2; exit 1
    fi
    printf '%s\n' "$*" >> "$RFX/merges"; exit 0 ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/41"*)
    [ -f "$RFX/pr41.json" ] && { restpr --raw 200 "$(cat "$RFX/pr41.json")"; exit 0; }
    restpr OPEN "$(cat "$RFX/live-head")" ticket/bh-41 main "" MERGEABLE CLEAN external-dev "" "Closes #41"; exit 0 ;;
  *"--json state"*) [ -s "$RFX/merges" ] && echo MERGED || echo OPEN; exit 0 ;;
  *" -q "*|*"--jq"*) exit 0 ;;
  *"api repos/example-org/demo-os/issues/41/comments"*) echo '[]'; exit 0 ;;
  *"api repos/example-org/demo-os/issues/41"*) echo '{"number":41,"state":"open","labels":[{"name":"ai-build"}],"title":"BH-41: x","body":"## Build"}'; exit 0 ;;
esac
echo ""
EOF
chmod +x "$RT/fakebin/gh"
export RFX
awk '/^# >>> review-prs merge/{f=1;next} /^# <<< review-prs merge/{exit} f' "$DIR/bin/review-prs.sh" > "$RT/rmerge.sh"
[ -s "$RT/rmerge.sh" ] && ok || bad "R0: could not extract the review-prs merge step"
rreview() {
  : > "$RT/log"; rm -f "$RFX/merges"; scratch_rm "$RH/state/merge-queue" 2>/dev/null
  ( cd "$RT" && PATH="$RT/fakebin:$PATH" HARNESS="$RH" FLEET_CONF="$RH/fleet.conf" HARNESS_SECRET=s \
      JOBS_URL=https://jobs.test JOBS_RETRIES=0 PROJECT=demo-os SLUG=example-org/demo-os LOG="$RT/log" bash -c 'set -uo pipefail
      STAMP() { echo TS; }
      rp_prov_is_claude() { [ "${1:-}" = claude ]; }
      mc_queue_conductor_only() { return 1; }
      mc_pr_queued() { return 1; }
      # BH-1585/BH-1285 (as tests/lead-pr-fence.bh-1558-test.sh does): merge_step
      # reads state and .base.ref over REST through mc_pr_view; the driver gives
      # it that reader over the stub arm for pulls/41.
      . "$HARNESS/bin/lib/gh-rest.sh"
      mc_pr_view() { local f; f=$(mktemp); gh_rest GET "repos/$SLUG/pulls/${1##*/}" > "$f" || { rm -f "$f"; return 75; }
        jq -r "{STATE: (if .merged_at != null then \"MERGED\" elif .state == \"open\" then \"OPEN\" else \"CLOSED\" end), base: {ref: .base.ref}} | ${2:-.}" "$f"; rm -f "$f"; }
      . "$HARNESS/bin/lib/block-gate.sh"
      . "$0"
      merge_step 41 '"$H1"' claude '"${RAUTHOR:-external-dev}"'
      printf "MERGED=%s MQ=%s" "$MERGED" "${RP_MQ_WANT:-0}"' "$RT/rmerge.sh" 2>>"$RT/err" )
}
# R1. the head moved after the review: the pinned merge is refused, nothing
#     goes to the box queue, the PR is left for the re-review of its new head.
vd_reset; printf '%s' "$H2" > "$RFX/live-head"
OUT=$(rreview)
[ -s "$RFX/merges" ] && bad "R1: nothing merged ($(cat "$RFX/merges"))" || ok
[ -f "$RH/state/merge-queue/demo-os/41" ] && bad "R1: THE DEFECT — a 'Head branch was modified' refusal must not reach the box queue (it lands the new head unpinned)" || ok
grep -q 'MQ=0' <<<"$OUT" && ok || bad "R1: no merge_queue row either (got '$OUT')"
grep -q 're-review' "$RT/log" && ok || bad "R1: the log says the new head goes to re-review ($(cat "$RT/log"); err $(tail -c 300 "$RT/err" 2>/dev/null))"
# R2. control: a refusal for another reason still reaches the box queue as today.
vd_reset; printf '%s' "$H1" > "$RFX/live-head"
sed -i.bak 's#printf .%s\\n. "\$\*" >> "\$RFX/merges"; exit 0 ;;#echo "Pull request is not mergeable" >\&2; exit 1 ;;#' "$RT/fakebin/gh"
OUT=$(rreview)
[ -f "$RH/state/merge-queue/demo-os/41" ] && ok || bad "R2: a non-head refusal still goes to the box queue as today (got '$OUT'; log $(cat "$RT/log"))"

# R3 (#1624 round-2 B1, driven end to end the way the reviewer drove it). A
#     lead HAND PR shaped like a train, a box APPROVE, no lead row: review-prs
#     must NOT merge it — whether the shape is the title or the ref.
cp "$DIR/bin/lib/train-shape.sh" "$RH/bin/lib/"
sed -i.bak 's#echo "Pull request is not mergeable" >\&2; exit 1 ;;#printf '"'"'%s\\n'"'"' "$*" >> "$RFX/merges"; exit 0 ;;#' "$RT/fakebin/gh"
for R3 in "Merge train: lead refactor|lead/1700-refactor" "BH-99: lead WIP|train/wip"; do
  vd_reset; printf '%s' "$H1" > "$RFX/live-head"
  jq -nc --arg t "${R3%%|*}" --arg r "${R3#*|}" --arg h "$H1" \
    '{state:"open",merged_at:null,title:$t,head:{sha:$h,ref:$r},base:{ref:"main"},mergeable:true,mergeable_state:"clean",labels:[],user:{login:"operator",type:"User"},body:"Closes #41"}' > "$RFX/pr41.json"
  OUT=$(RAUTHOR="$LEAD" rreview)
  [ -s "$RFX/merges" ] && bad "R3: THE DEFECT — review-prs merged a lead PR shaped like a train ('${R3%%|*}' on ${R3#*|}) on a box APPROVE ($(cat "$RFX/merges"))" || ok
  grep -q 'MERGED=no' <<<"$OUT" && ok || bad "R3: merged=no for '${R3%%|*}' (got '$OUT'; log $(cat "$RT/log"))"
done
rm -f "$RFX/pr41.json"

echo "lead-fence-lanes.bh-1606: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
