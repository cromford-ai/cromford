#!/bin/bash
# tests/merge-conductor-prod-red-hold.bh-8781-test.sh — BH-8781: a red
# production deploy holds every READY PR of that project in the merge
# conductor, and the first tick after a READY deploy merges it.
#
# The red record is .projects[<p>].prod_red in state/vercel-deploy-status.json,
# written by bin/vercel-deploy-snapshot.sh (tests/prod-red-snapshot.bh-8781-test.sh).
# The hold is bin/merge-conductor.d/bh-8781-prod-red-hold.sh, called once in
# pr_worker's READY arm after the main-red freeze.
#
# Part A (unit) sources the fragment with its seams stubbed:
#   U1  red, fresh snapshot, plain PR          -> held, reason + log + mark
#   U2  red, no knob row and no env            -> held (default on)
#   U3  no prod_red key (old format)           -> not held, silent
#   U4  prod_red null                          -> not held, silent
#   U5  snapshot older than MC_PROD_RED_MAX_AGE_S -> not held, one line per hour
#   U6  snapshot missing / junk JSON           -> not held, one line per hour
#   U7  MC_PROD_RED_HOLD 0 (per-project row)   -> not held, the file never read
#   U8  exempt (main_red_exempt / hotfix_pr_is) -> not held, one pass mark
#   U9  a project absent from the snapshot     -> not held
# Part B (whole tick) drives the WHOLE bin/merge-conductor.sh in a scratch tree
# (the fixture of tests/merge-conductor-migration-hold.bh-7785-test.sh part B):
#   M1  red: no merge, no enqueue; the ready-why reason; one HELD line
#   M2  the same tick twice: one HELD line, still no merge or enqueue
#   M3  prod_red null on the next tick: the same PR is enqueued
#   M4  labelled fix-main-red: enqueued while red; U8b fix-main-red-later is held
#   M5  snapshot 2 h old: enqueued, one "not held" line
#   RED the M1 tick with the fragment absent: enqueued (the fragment holds)
#   N2  the snapshot written by the REAL bin/vercel-deploy-snapshot.sh: ERROR
#       holds, then READY enqueues
#   B2  every conductor curl went to a .test host; the hold made none
# Run: HARNESS_TEST_SANDBOX=1 bash tests/merge-conductor-prod-red-hold.bh-8781-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: merge-conductor-prod-red-hold: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
FRAG="$DIR/bin/merge-conductor.d/bh-8781-prod-red-hold.sh"
for SRC in "$FRAG" "$DIR/bin/merge-conductor.sh" "$DIR/bin/vercel-deploy-snapshot.sh"; do
  [ -r "$SRC" ] && ok || bad "missing $SRC"
done
grep -q 'command -v mc_prod_red_hold >/dev/null 2>&1 && mc_prod_red_hold; then return 0; fi' "$DIR/bin/merge-conductor.sh" \
  && ok || bad "the driver has no mc_prod_red_hold call site"

H1=$(printf 'a%.0s' $(seq 40))
SLUG=example-org/mgfy-os
NOWP=2000000000                       # 2033-05-18 03:33:20Z, the pinned clock
GA_FRESH='2033-05-18 03:30:00Z'
GA_OLD='2033-05-18 01:33:20Z'
RED_REC='{"since":"2033-05-18T02:00:00Z","sha":"c0ffee12","id":"dpl_fixture_red"}'
# snap <file> <generated_at> <project> <prod_red json|-> — write a snapshot;
# "-" leaves the prod_red key out (the format before BH-8781).
snap() {
  if [ "$4" = - ]; then jq -nc --arg g "$2" --arg p "$3" '{generated_at:$g, projects:{($p):{domain:"x"}}}' > "$1"
  else jq -nc --arg g "$2" --arg p "$3" --argjson r "$4" '{generated_at:$g, projects:{($p):{domain:"x", prod_red:$r}}}' > "$1"; fi
}

# ============================================================================
# Part A — the fragment, sourced, seams stubbed. Own subshell; exits its fail count.
# ============================================================================
(
  A="$T/a"; FXD="$A/fx"; mkdir -p "$A/h/state"
  H="$A/h"; SF="$H/state/vercel-deploy-status.json"
  export MC_PROD_RED_NOW="$NOWP"
  unset MC_PROD_RED_HOLD MC_PROD_RED_MAX_AGE_S MC_PROD_RED_SNAPSHOT
  lane_knob() { [ -f "$FXD/knob.$2.${3:-}" ] && { cat "$FXD/knob.$2.${3:-}"; return 0; }; [ -f "$FXD/knob.$2" ] && cat "$FXD/knob.$2"; return 0; }
  mc_log() { printf '%s\n' "$*" >> "$FXD/log"; }
  mc_attempt_has() { grep -qxF "$1" "$FXD/attempts" 2>/dev/null; }
  mc_attempt_put() { echo "$1" >> "$FXD/attempts"; }
  mc_ready_why() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-}" >> "$FXD/why"; }
  main_red_exempt() { echo "$*" >> "$FXD/exempt-calls"; [ -e "$FXD/exempt" ]; }
  hotfix_pr_is() { [ -e "$FXD/hotfix" ]; }
  # shellcheck source=bin/merge-conductor.d/bh-8781-prod-red-hold.sh
  . "$FRAG" || exit 90
  F=0; no() { F=$((F+1)); echo "FAIL: merge-conductor-prod-red-hold: $1"; }
  n() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
  reset() { scratch_rm "$FXD"; mkdir -p "$FXD"; rm -f "$SF"; }
  run() { P="${1:-mgfy}"; KEY="$SLUG#31"; HEAD="$H1"; NUM=31; URL="https://github.com/$SLUG/pull/31"; RAWLBL="${2:-}"; mc_prod_red_hold; }

  # U1 — red, fresh: held.
  reset; snap "$SF" "$GA_FRESH" mgfy "$RED_REC"
  OUT=$(mc_prod_red_state mgfy); RC=$?
  [ "$RC" = 0 ] && [ "$OUT" = $'2033-05-18T02:00:00Z\tc0ffee12\tdpl_fixture_red' ] || no "U1 mc_prod_red_state prints since/sha/id, rc 0 (rc $RC, '$OUT')"
  run; RC=$?
  [ "$RC" = 0 ] || no "U1 a red project holds (rc $RC)"
  [ "$(cat "$FXD/why" 2>/dev/null)" = "$SLUG#31	$H1	prod-red	production red since 2033-05-18T02:00:00Z, commit c0ffee12	logged" ] \
    || no "U1 the ready-why reason (got '$(cat "$FXD/why" 2>/dev/null)')"
  grep -q "^$SLUG#31 READY and HELD: production red since 2033-05-18T02:00:00Z, commit c0ffee12 (Vercel dpl_fixture_red)" "$FXD/log" 2>/dev/null \
    || no "U1 the HELD log line (log: $(cat "$FXD/log" 2>/dev/null))"
  grep -qxF "prodredhold $SLUG#31 $H1" "$FXD/attempts" 2>/dev/null || no "U1 the prodredhold mark"
  run; [ "$(n "$FXD/log")" = 1 ] && [ "$(n "$FXD/why")" = 2 ] || no "U1 a second call: one log line (dedupe), the reason still recorded ($(n "$FXD/log") / $(n "$FXD/why"))"

  # U2 — the knob is on with no row and no env; a row of 1 for another project changes nothing.
  reset; snap "$SF" "$GA_FRESH" mgfy "$RED_REC"; echo 0 > "$FXD/knob.MC_PROD_RED_HOLD.other"
  run; [ "$?" = 0 ] || no "U2 default on: held"

  # U3 / U4 / U9 — not red: silent.
  for spec in "-:U3" "null:U4"; do
    reset; snap "$SF" "$GA_FRESH" mgfy "${spec%%:*}"
    mc_prod_red_state mgfy >/dev/null; RC=$?
    run; R2=$?
    [ "$RC" = 1 ] && [ "$R2" = 1 ] && [ "$(n "$FXD/log")" = 0 ] && [ "$(n "$FXD/why")" = 0 ] || no "${spec#*:} not red: state rc 1, not held, silent (rc $RC/$R2, log $(n "$FXD/log"))"
  done
  reset; snap "$SF" "$GA_FRESH" mgfy "$RED_REC"
  run other; [ "$?" = 1 ] && [ "$(n "$FXD/log")" = 0 ] || no "U9 a project absent from the snapshot is not held"
  # An empty since is not a record.
  reset; snap "$SF" "$GA_FRESH" mgfy '{"since":"","sha":"x","id":"y"}'
  run; [ "$?" = 1 ] || no "U4b an empty since is not red"

  # U5 — old snapshot: not held; one line per project-hour.
  reset; snap "$SF" "$GA_OLD" mgfy "$RED_REC"
  mc_prod_red_state mgfy >/dev/null; RC=$?
  run; R2=$?; run
  [ "$RC" = 2 ] && [ "$R2" = 1 ] && [ "$(n "$FXD/log")" = 1 ] && [ "$(n "$FXD/why")" = 0 ] || no "U5 an old snapshot: rc 2, not held, one line for two calls (rc $RC/$R2, log $(n "$FXD/log"))"
  grep -q "^prod-red: snapshot unreadable or older than 1800s for mgfy (generated_at $GA_OLD); not held" "$FXD/log" 2>/dev/null || no "U5 the not-held line (log: $(cat "$FXD/log" 2>/dev/null))"
  grep -qxF "prodredunk mgfy 2033051803" "$FXD/attempts" 2>/dev/null || no "U5 the hour mark (attempts: $(cat "$FXD/attempts" 2>/dev/null))"
  MC_PROD_RED_NOW=$((NOWP + 3600)) run; [ "$(n "$FXD/log")" = 2 ] || no "U5 the next hour writes one more line"
  # The knob moves the window: 3 h reads the same file as fresh.
  echo 10800 > "$FXD/knob.MC_PROD_RED_MAX_AGE_S"; run; [ "$?" = 0 ] || no "U5 MC_PROD_RED_MAX_AGE_S=10800: the 2 h snapshot holds"
  echo abc > "$FXD/knob.MC_PROD_RED_MAX_AGE_S"; mc_prod_red_state mgfy >/dev/null; [ "$?" = 2 ] || no "U5 a bogus max age reads as 1800"

  # U6 — missing, junk, wrong shape: not held, one line.
  for k in missing junk array; do
    reset
    case "$k" in junk) echo '{not json' > "$SF" ;; array) echo '[1,2]' > "$SF" ;; esac
    mc_prod_red_state mgfy >/dev/null; RC=$?
    run; R2=$?
    [ "$RC" = 2 ] && [ "$R2" = 1 ] && [ "$(n "$FXD/log")" = 1 ] && [ "$(n "$FXD/why")" = 0 ] || no "U6 $k: rc 2, not held, one line (rc $RC/$R2, log $(n "$FXD/log"))"
  done

  # U7 — knob 0 for this project: not held, no line.
  reset; snap "$SF" "$GA_FRESH" mgfy "$RED_REC"; echo 0 > "$FXD/knob.MC_PROD_RED_HOLD.mgfy"
  run; [ "$?" = 1 ] && [ "$(n "$FXD/log")" = 0 ] && [ "$(n "$FXD/exempt-calls")" = 0 ] || no "U7 MC_PROD_RED_HOLD=0: not held, silent"
  reset; snap "$SF" "$GA_FRESH" mgfy "$RED_REC"; ( MC_PROD_RED_HOLD=0; run ); [ "$?" = 1 ] || no "U7 env MC_PROD_RED_HOLD=0 with no row: not held"

  # U8 — exempt: not held, one pass mark; the exempt check gets the PR's labels.
  reset; snap "$SF" "$GA_FRESH" mgfy "$RED_REC"; : > "$FXD/exempt"
  run mgfy fix-main-red; RC=$?; run mgfy fix-main-red
  [ "$RC" = 1 ] && [ "$(n "$FXD/why")" = 0 ] && [ "$(n "$FXD/log")" = 1 ] && grep -qxF "prodredpass $SLUG#31 $H1" "$FXD/attempts" || no "U8 exempt: not held, one pass line (rc $RC, log $(n "$FXD/log"))"
  grep -q "^$SLUG 31 https://github.com/$SLUG/pull/31 $H1 fix-main-red$" "$FXD/exempt-calls" || no "U8 main_red_exempt gets slug num url head labels ($(head -1 "$FXD/exempt-calls"))"
  reset; snap "$SF" "$GA_FRESH" mgfy "$RED_REC"; : > "$FXD/hotfix"
  run mgfy hotfix; [ "$?" = 1 ] || no "U8 a hotfix PR is not held"
  # No exempt function in the tree at all: held (fail closed).
  reset; snap "$SF" "$GA_FRESH" mgfy "$RED_REC"
  ( unset -f main_red_exempt hotfix_pr_is; run ); [ "$?" = 0 ] || no "U8 no exempt functions: held"

  # B2a — the hold path calls no curl and no gh.
  reset; snap "$SF" "$GA_FRESH" mgfy "$RED_REC"
  ( curl() { echo curl >> "$FXD/net"; }; gh() { echo gh >> "$FXD/net"; }; run )
  [ "$(n "$FXD/net")" = 0 ] || no "B2a the hold made a network call"

  echo "part A: $F failed"
  exit "$F"
)
PA=$?; FAIL=$((FAIL + PA))

# ============================================================================
# Part B — the WHOLE bin/merge-conductor.sh in a scratch tree.
# ============================================================================
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$DIR/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
C="$T/w"; CH="$C/h"; FX="$C/fx"
fx_mc_harness "$DIR" "$C" || exit 1
fx_conductor_tick "$DIR" "$C" || exit 1
( cd "$DIR" && for s in bin/lib/autoenqueue.sh bin/lib/mc-hold-comment.sh bin/lib/gh-repo-token.sh; do scratch_install_closure "$s" "$CH" >/dev/null || exit 1; done ) || exit 1
mkdir -p "$C/fakebin" "$FX"
# The conductor's curl: every call logged; the worker and settings reads 404.
cat > "$C/fakebin/curl" <<EOF
#!/bin/bash
URL=""; out=""; w=""; M=GET
while [ \$# -gt 0 ]; do case "\$1" in
  -o) out="\$2"; shift 2 ;; -w) w="\$2"; shift 2 ;; -X) M="\$2"; shift 2 ;;
  -m|-H|--connect-timeout|--data-binary|-d|--max-time) shift 2 ;;
  -*) shift ;; *) URL="\$1"; shift ;;
esac; done
printf '%s %s\n' "\$M" "\$URL" >> "$C/curl-all.log"
body='{"error":"not found"}'; code=404
case "\$M \$URL" in "PUT "*|"POST "*) body='{"ok":true}'; code=200 ;; esac
if [ -n "\$out" ]; then printf '%s' "\$body" > "\$out"; else printf '%s' "\$body"; fi
case "\$w" in '') ;; \$'\n'*) printf '\n%s' "\$code" ;; *) printf '%s' "\$code" ;; esac
exit 0
EOF
chmod +x "$C/fakebin/curl"
cat > "$CH/bin/lib/ticket-ownership.sh" <<'EOF2'
to_lane_hold() { return 1; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
EOF2
printf 'pdg_hold() { return 1; }\n' > "$CH/bin/lib/pr-dep-gate.sh"
install_frag() { ( cd "$DIR" && scratch_install_closure bin/merge-conductor.d/bh-8781-prod-red-hold.sh "$CH" >/dev/null ); }
install_frag || exit 1
printf 'mgfy %s - - 2 box-m\n' "$SLUG" > "$CH/fleet.conf"
: > "$CH/env/global.env"
for s in agent-call beat deploy-request pre-arm-guards codegraph-ensure; do printf '#!/bin/bash\nexit 0\n' > "$CH/bin/$s.sh"; chmod +x "$CH/bin/$s.sh"; done
REC="$CH/builds/pool-mgfy-MG-31-202609120001"; mkdir -p "$REC"
U="https://github.com/$SLUG/pull"
MGFY_YML=$(printf 'queue_rules:\n  - name: default\n    merge_method: squash\n' | base64 | tr -d '\n')
cat > "$C/fakebin/gh" <<EOF
#!/bin/bash
HD="$H1"
case "\$*" in
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"api -i -X GET repos/$SLUG/rulesets"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/$SLUG/contents/.mergify.yml"*) restpr --raw 200 '{"content":"$MGFY_YML"}' ;;
  *"actions/runs?head_sha="*) restpr --raw 200 '{"workflow_runs":[{"id":1,"name":"CI","status":"completed","conclusion":"success","run_started_at":"2026-09-29T10:00:00Z"}]}' ;;
  *"check-runs?check_name="*) restpr --raw 200 '{"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"api -i -X GET repos/"*"/commits/"*"/check-runs"*) restpr --raw 200 '{"total_count":1,"check_runs":[{"name":"Build + Unit tests","status":"completed","conclusion":"success","started_at":"2026-09-23T10:00:00Z"}]}' ;;
  *"api -i -X POST repos/$SLUG/issues/31/comments -f body=@mergifyio queue"*) printf '%s\n' "\$*" >> "$FX/queue-posts.txt"; restpr --raw 201 '{"id":901}' ;;
  *"issues/31/labels"*) printf '%s\n' "\$*" >> "$FX/label-posts.txt"; restpr --raw 200 '[]' ;;
  *"pr merge"*) printf '%s\n' "\$*" >> "$FX/merges.txt"; exit 0 ;;
  *"/pulls/"*"/merge"|*"/pulls/"*"/merge "*) printf '%s\n' "\$*" >> "$FX/merges.txt"; restpr --raw 200 '{"merged":true}' ;;
  *"api -i -X POST repos/"*"/issues/"*"/comments"*) printf '%s\n' "\$*" >> "$FX/comment-posts.txt"; restpr --raw 201 '{"id":1}' ;;
  *"api -i -X GET repos/$SLUG/issues/31/comments"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/issues/"*) restpr --raw 200 '{"state":"open"}' ;;
  *"api -i -X GET repos/$SLUG/pulls/31"*"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/"*"/pulls/"*"/files"*) restpr --raw 200 '[{"filename":"src/a.ts","status":"modified"}]' ;;
  *"api -i -X GET repos/$SLUG/pulls/31"*) restpr OPEN "\$HD" ticket/mg-31 main "" MERGEABLE CLEAN operator "" "" ;;
  *"api -i -X GET repos/"*"/pulls -f state="*) restpr --raw 200 '[]' ;;
  *"api repos/$SLUG -q .id"*) echo 1 ;;
  *"pr list -R $SLUG --state open"*) cat "$C/list.json" ;;
  *"pr list"*"--state closed"*) : ;;
esac
exit 0
EOF
chmod +x "$C/fakebin/gh"
# list <labels-json> — the open PR list: one PR, #31.
list() { jq -nc --arg u "$U/31" --arg h "$H1" --argjson l "${1:-[]}" '[{number:31,url:$u,headRefOid:$h,headRefName:"ticket/mg-31",baseRefName:"main",isDraft:false,mergeStateStatus:"CLEAN",mergeable:"MERGEABLE",state:"OPEN",isInMergeQueue:false,labels:$l}]' > "$C/list.json"; }
printf '#!/bin/bash\nexit 0\n' > "$C/fakebin/flock"; chmod +x "$C/fakebin/flock"
touch "$CH/flags/merge-conductor-actions" "$CH/flags/merge-conductor-merge"
SNAP="$CH/state/vercel-deploy-status.json"
# fresh — a clean slate: state, logs, fixture answers and the build record.
fresh() {
  scratch_rm "$CH/state"; scratch_rm "$FX"; mkdir -p "$CH/state" "$FX"
  : > "$CH/logs/merge-conductor.log"; : > "$CH/logs/ALERTS.log"; list '[]'
  echo "PR_CREATED $U/31" > "$REC/RESULT"; printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$REC/review.md"
  echo "$H1" > "$REC/reviewed-sha"; : > "$REC/pipeline.log"
}
# tick [env...] — one conductor tick on the pinned clock; state carries over until fresh.
tick() {
  ( cd "$C" && env PATH="$C/fakebin:$PATH" HARNESS="$CH" HARNESS_ENV_DIR= HARNESS_SECRET=fixture-secret JOBS_URL=http://worker.test JOBS_RETRIES=0 GH_TOKEN=pat-fixture \
    MC_MERGE_BUDGET=0 MC_ENQUEUE_SETTLE=0 MC_MERGE_SETTLE=0 MC_MERGIFY_SETTLE=0 MC_MERGIFY_WAIT_S=0 MC_QUEUE_TTL=0 MC_MAIN_RED_DETECT=0 \
    MC_PROD_RED_NOW="$NOWP" "$@" bash "$CH/bin/merge-conductor.sh" >/dev/null 2>"$C/tick.err" ) || { echo "tick rc=$? stderr:"; tail -5 "$C/tick.err"; }
}
n() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
landed() { echo $(( $(n "$FX/queue-posts.txt") + $(n "$FX/merges.txt") )); }
clog() { grep -E '#31' "$CH/logs/merge-conductor.log" | tail -"${1:-6}"; }
held() { grep -c 'READY and HELD: production red' "$CH/logs/merge-conductor.log"; }
why() { cat "$CH/state/merge-conductor/ready-why/"*31 2>/dev/null; }

# M1 — red: held.
fresh; snap "$SNAP" "$GA_FRESH" mgfy "$RED_REC"; tick
[ "$(landed)" = 0 ] && [ "$(n "$FX/label-posts.txt")" = 0 ] && ok || bad "M1 a red project: no merge, no enqueue, no label (landed $(landed); log: $(clog))"
[ "$(held)" = 1 ] && grep -q "#31 READY and HELD: production red since 2033-05-18T02:00:00Z, commit c0ffee12" "$CH/logs/merge-conductor.log" \
  && ok || bad "M1 one HELD line naming since and sha8 (log: $(clog))"
[ "$(cut -f3,4 <<<"$(why)")" = $'prod-red\tproduction red since 2033-05-18T02:00:00Z, commit c0ffee12' ] && ok \
  || bad "M1 the ready-why note carries the hold reason (got '$(why)')"
[ "$(cut -f2 <<<"$(awk -F'\t' -v k="$SLUG#31" '$1==k' "$CH/state/merge-conductor/pr-state.tsv" 2>/dev/null)")" = READY ] && ok \
  || bad "M1 the row stays READY"

# M2 — the same tick again: still one line, still nothing landed.
tick
[ "$(held)" = 1 ] && [ "$(landed)" = 0 ] && ok || bad "M2 a second tick: one HELD line ($(held)), nothing landed ($(landed))"

# M3 — a READY deploy: the next tick lands the same PR.
snap "$SNAP" "$GA_FRESH" mgfy null; tick
[ "$(landed)" = 1 ] && ok || bad "M3 prod_red null: the next tick lands the PR (landed $(landed); log: $(clog))"

# M4 — fix-main-red passes the hold; U8b fix-main-red-later does not.
fresh; snap "$SNAP" "$GA_FRESH" mgfy "$RED_REC"; list '[{"name":"fix-main-red"}]'; tick
[ "$(landed)" = 1 ] && [ "$(held)" = 0 ] && ok || bad "M4 fix-main-red lands while red (landed $(landed), held $(held); log: $(clog))"
fresh; snap "$SNAP" "$GA_FRESH" mgfy "$RED_REC"; list '[{"name":"fix-main-red-later"}]'; tick
[ "$(landed)" = 0 ] && [ "$(held)" = 1 ] && ok || bad "U8b fix-main-red-later is held (landed $(landed), held $(held))"

# M5 — a 2 h old snapshot fails open.
fresh; snap "$SNAP" "$GA_OLD" mgfy "$RED_REC"; tick
[ "$(landed)" = 1 ] && [ "$(grep -c 'prod-red: snapshot unreadable or older than 1800s for mgfy' "$CH/logs/merge-conductor.log")" = 1 ] && ok \
  || bad "M5 an old snapshot: landed, one not-held line (landed $(landed); log: $(tail -5 "$CH/logs/merge-conductor.log"))"

# RED — the M1 tick without the fragment lands the PR.
scratch_rm "$CH/bin/merge-conductor.d"
fresh; snap "$SNAP" "$GA_FRESH" mgfy "$RED_REC"; tick
[ "$(landed)" = 1 ] && [ "$(held)" = 0 ] && ok || bad "RED without the fragment the M1 PR lands (landed $(landed))"
install_frag || exit 1

# N2 — the real snapshot writer feeds the conductor.
S="$C/snap"; SB="$C/snapbin"; mkdir -p "$S/state" "$S/logs" "$S/flags" "$SB"
( cd "$DIR" && scratch_install_closure bin/vercel-deploy-snapshot.sh "$S" >/dev/null ) || bad "N2 setup: cannot install the lane script"
printf 'page_critical() { return 0; }\n' > "$S/bin/lib/page-critical.sh"
printf 'mgfy team_fixture prj_mgfy mgfy.example.test\n' > "$S/vercel.conf"; : > "$C/snap-fleet.conf"
jq -nc '{token:"tok-fixture-1", expiresAt:4102444800000}' > "$C/auth.json"
cat > "$SB/curl" <<EOF
#!/bin/bash
URL="\${!#}"
printf '%s\n' "\$URL" >> "$C/snap-curl.log"
case "\$URL" in
  https://api.vercel.com/v4/aliases/*) echo '{"deploymentId":"dpl_fixture_s"}' ;;
  https://api.vercel.com/v13/deployments/*) echo '{"createdAt":1700000000000,"gitSource":{"sha":"a1b2c3d4"}}' ;;
  https://api.vercel.com/v6/deployments*target=production\&limit=1*) printf '{"deployments":[{"uid":"dpl_fixture_n2","state":"%s","createdAt":1793400000000,"meta":{"githubCommitSha":"feedface99"}}]}\n' "\$(cat "$C/snap-state")" ;;
  https://api.vercel.com/v6/deployments*) echo '{"deployments":[]}' ;;
  *) exit 7 ;;
esac
EOF
chmod +x "$SB/curl"
run_real_snap() {
  echo "$1" > "$C/snap-state"
  env PATH="$SB:$PATH" HARNESS="$S" FLEET_CONF="$C/snap-fleet.conf" REGISTRY_SOURCE=file LANE_GATE_DISABLE=1 \
    LANE_REGISTRY="$C/no-registry.json" JOBS_URL='' VERCEL_CLI_AUTH="$C/auth.json" bash "$S/bin/vercel-deploy-snapshot.sh" 2>>"$C/snap.err"
  # The tick's clock is pinned; the writer's generated_at is the wall clock.
  jq -c --arg g "$GA_FRESH" '.generated_at = $g' "$S/state/vercel-deploy-status.json" > "$SNAP"
}
fresh; run_real_snap ERROR; tick
[ "$(landed)" = 0 ] && [ "$(held)" = 1 ] && grep -q 'commit feedface (Vercel dpl_fixture_n2)' "$CH/logs/merge-conductor.log" && ok \
  || bad "N2 the real writer's ERROR record holds (landed $(landed), held $(held); snap $(jq -c '.projects.mgfy.prod_red' "$SNAP"))"
run_real_snap READY; tick
[ "$(landed)" = 1 ] && ok || bad "N2 the real writer's READY run: the next tick lands the PR (landed $(landed); snap $(jq -c '.projects.mgfy.prod_red' "$SNAP"))"

# B2 — every conductor curl went to a .test host.
OUT=$(awk '{print $2}' "$C/curl-all.log" 2>/dev/null | grep -vE '^https?://[a-z0-9.-]+\.test(/|$)' || true)
[ -z "$OUT" ] && ok || bad "B2 a curl left the fixture hosts: $OUT"
OUT=$(grep -v '^https://api\.vercel\.com/' "$C/snap-curl.log" 2>/dev/null || true)
[ -s "$C/snap-curl.log" ] && [ -z "$OUT" ] && ok || bad "B2 the snapshot curl saw only api.vercel.com ($OUT)"

echo "merge-conductor-prod-red-hold.bh-8781: part B $PASS passed; $FAIL failed in all (part A counted above)"
[ "$FAIL" -eq 0 ]
