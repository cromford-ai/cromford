#!/bin/bash
# tests/slice-closeout.bh-4662-test.sh — BH-4662: a sliced plan never closes its
# parent, and "children own the rest" is only written when a child exists.
#
# WHY. A plan whose line was `SLICE: C0 of #4477` still opened its PR with
# `Closes #4477` (only `Part of #N` lines were rewritten), so GitHub's keyword
# close shut the master at merge (#4500 / #4477). And the slice close-out said
# "children own the rest" and took `ai-build` off on `slice:plan` and
# `slice:no-keyword` without ever reading whether a child issue existed: with
# none, the master was left open, unlabelled, and invisible to every watcher.
#
# WHAT THIS PINS, on the PR body rendered by the real evidence block, the REST
# argv that reached the stub `gh`, the comment bodies it was sent, the word each
# close-out prints, and the lane-alert stub's log, never on source text:
#   C1  PR_BODY_FOR of a SLICE plan says `Part of #4477`, never `Closes #4477`
#   C2  lines that only TALK about a slice leave `Closes #4477` alone
#   C3  slice:plan with an open child: today's comment and strip
#   C4  slice:plan / Refs with no child: honest comment, label kept, one alert:
#       a SLICE plan that names no remainder pages critical SLICE_REMAINDER_UNKNOWN
#       (BH-5961, which files the remainder when there is one), a Refs body warns
#   C5  an unreadable children read: nothing written, close-deferred, rc 1
#   C6  the same three through mc_close_shipped (the conductor's own arm)
#   C7  no case ever PATCHes (closes) the master
#   C8  bin/hotfix-after-deploy.sh alerts on the children-read deferral
#
#   HARNESS_TEST_SANDBOX=1 bash tests/slice-closeout.bh-4662-test.sh   exit 0 = pass
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/gh-rest-fx.sh
. "$DIR/tests/lib/gh-rest-fx.sh" || exit 1
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/prepr-gate.sh"
[ -r "$LIB" ] && [ -r "$DIR/bin/lib/issue-state-lib.sh" ] || { echo "FAIL: a lib under test is missing"; exit 1; }

# ════════════════════════════════════════════════════════════════════════════
# C1. the PR body, rendered by the real evidence block with the real gate lib
# ════════════════════════════════════════════════════════════════════════════
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> evidence block/{f=1;next} /^# <<< evidence block/{exit} f' "$RB_ALL" > "$T/block.sh"
grep -q CLOSES_LINE "$T/block.sh" && ok || bad "C1: could not extract the evidence block with CLOSES_LINE — markers moved?"
mkdir -p "$T/fh/bin" "$T/repo"
printf '#!/bin/bash\n[ "${2:-}" = board_prefix ] && echo "-"\n' > "$T/fh/bin/fleet-conf.sh"; chmod +x "$T/fh/bin/fleet-conf.sh"
( cd "$T/repo" && git init -q -b main && git config user.email t@example.com && git config user.name t \
  && echo one > a.txt && git add -A && git -c commit.gpgsign=false commit -qm "BH-4500: C0" ) >/dev/null 2>&1
render_body() { # render_body <build> <out> — KEY BH-4477 on a "-" project: the block writes Closes #4477
  ( cd "$T/repo" || exit 1
    env HARNESS="$T/fh" BUILD="$1" KEY=BH-4477 LIBF="$LIB" \
    bash -c '
      set -uo pipefail
      STAMP() { echo TS; }
      PROJECT=cromford; SLUG=o/r; BASE=main; TIER=2; QA_NOTE=""; MIG_NOTE=""; ADDED_SQL=""; E2E_VERDICT=pass
      CHANGED="a.txt"; TAMPER_RC=0; REPRO_RC=0; INTENT_RC=0
      WHAT_LIST="- did a thing"; WHY_EXCERPT="Ship C0"; VERIFY_LINE="v"; SPEC_LINE="s"
      PLAN_MODEL=pm; EXECUTE_MODEL=em; REVIEW_MODEL=rm; MIG_SECTION=""; COST_LINE="c"; MERGE_NOTE=""
      CTX_SIG=sig; CTX_COMMIT=abc; CTX_SYNC=yes; CTX_FRESH=yes
      job_evidence_put() { return 0; }
      . "$LIBF"
      . "$0"
      printf "%s" "$(PR_BODY_FOR "EVIDENCE")" > "$1"
    ' "$T/block.sh" "$2" 2>"$2.err" )
}
for pl in 'SLICE: C0 of #4477' '**SLICE:** C0 of #4477'; do
  B1="$T/c1"; scratch_rm "$B1"; mkdir -p "$B1"
  jq -n '{title:"BH-4477: master", body:"Ship C0"}' > "$B1/ticket-meta.json"
  printf '# BH-4477\n\n%s\n\n## Tasks\n' "$pl" > "$B1/plan.md"
  render_body "$B1" "$T/body-c1.txt"
  [ -s "$T/body-c1.txt" ] && ok || bad "C1 [$pl]: no body rendered ($(cat "$T/body-c1.txt.err" 2>/dev/null))"
  grep -qx 'Part of #4477' "$T/body-c1.txt" && ok || bad "C1 [$pl]: no 'Part of #4477' line ($(head -3 "$T/body-c1.txt"))"
  grep -qiE 'close[sd]? #4477' "$T/body-c1.txt" && bad "C1 [$pl]: the body still closes #4477 ($(head -3 "$T/body-c1.txt"))" || ok
done
# The control: the same master with no plan line keeps its Closes.
rm -f "$B1/plan.md"; render_body "$B1" "$T/body-c1n.txt"
grep -qx 'Closes #4477' "$T/body-c1n.txt" && ok || bad "C1: a whole-ticket build must keep 'Closes #4477' ($(head -3 "$T/body-c1n.txt"))"

# ════════════════════════════════════════════════════════════════════════════
# C2. negatives, through prepr_body_keywords as the PR body passes through it
# ════════════════════════════════════════════════════════════════════════════
kw() { # kw <build-dir> <input>
  env BUILD="$1" LIBF="$LIB" bash -c 'set -uo pipefail; . "$LIBF" || exit 9; printf "%s" "$0" | prepr_body_keywords' "$2"
}
IN=$'Ticket BH-4477 — x\nCloses #4477\n## What\n- a'
B2="$T/c2"; mkdir -p "$B2"
jq -n '{title:"BH-4656: other", body:"Ship it"}' > "$B2/ticket-meta.json"
for line in '| C0 | SLICE: C0 of #4477 |' 'A plan quoting `SLICE: C0 of #4477` mid-line' \
            'We note the SLICE: C0 of #4477 here.' 'SLICE: C0 of #44770' 'This is C0 of #4477 mid-line'; do
  printf '# BH-4656\n\n%s\n' "$line" > "$B2/plan.md"
  OUT=$(kw "$B2" "$IN")
  [ "$OUT" = "$IN" ] && ok || bad "C2: '$line' must leave 'Closes #4477' byte-identical (got: $OUT)"
done
printf '# BH-4477\n\n> SLICE: C0 of #4477\n' > "$B2/plan.md"
OUT=$(kw "$B2" "$IN")
grep -qx 'Part of #4477' <<<"$OUT" && ! grep -q 'Closes #4477' <<<"$OUT" && ok \
  || bad "C2: the positive control '> SLICE: C0 of #4477' must rewrite (got: $OUT)"

# ════════════════════════════════════════════════════════════════════════════
# C3-C7. the close-out libs against a routed REST stub
# ════════════════════════════════════════════════════════════════════════════
mkdir -p "$T/h/bin/lib/mc" "$T/h/logs" "$T/h/state" "$T/h/env" "$T/h/flags" "$T/h/builds" "$T/tmp"
scratch_install_closure bin/lib/merge-conductor-lib.sh "$T/h" >/dev/null || { echo "FAIL: closure install failed"; exit 1; }
# The lane-alert stub: its argv, one line per call.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/h/logs/ALERTS.log"\n' "$T" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"
: > "$T/h/env/global.env"
ghfx_init
export HARNESS="$T/h" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH"
ghfx_extra <<'SH'
case "$A" in *"-X POST"*"/comments"*)
  for a in "$@"; do case "$a" in body=@*) { cat "${a#body=@}"; printf '\n----\n'; } >> "$GHFX/posted.txt" ;; esac; done ;;
esac
SH
# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh" || { echo "FAIL: cannot source the lib"; exit 1; }
mc_init

S=example-org/proj
PRURL=https://github.com/example-org/proj/pull/4500
REC="$T/h/builds/pool-proj-BH-4477-202610051500"
mkdir -p "$REC"
REFS_BODY=$'## Summary\nRefs #4477\n\nThis builds C0.'
CLOSES_BODY=$'## Summary\nCloses #4477\n\nharness build'
LBL='[{"name":"ai-build"},{"name":"enhancement"}]'
xref() {
  jq -nc --argjson n "$1" --arg st "$2" --arg b "$3" \
    '{event:"cross-referenced",source:{type:"issue",issue:{number:$n,state:$st,body:$b}}}'
}
KID="[$(xref 4478 open $'Scope.\nPart of #4477')]"
: > "$T/all-argv.log"
reset() {
  cat "$T/gh-argv.log" >> "$T/all-argv.log" 2>/dev/null
  ghfx_routes_reset; ghfx_log_reset
  : > "$T/posted.txt"; : > "$T/h/logs/ALERTS.log"
  rm -f "$REC/plan.md" "$REC/issue-commented"
  # BH-5961's per-record markers (unknown-paged pages once per record), so each
  # case starts from a record no lane has settled.
  scratch_rm "$REC/slice-remainder"
}
pr_body()  { ghfx_route GET "repos/$S/pulls/4500" 200 "$(jq -nc --arg b "$1" '{number:4500,state:"closed",body:$b}')"; }
timeline() { ghfx_route GET "repos/$S/issues/4477/timeline*" 200 "$1"; }
writes() {
  ghfx_route POST   "repos/$S/issues/4477/comments" 201 '{"id":1}'
  ghfx_route PATCH  "repos/$S/issues/4477" 200 '{"state":"closed"}'
  ghfx_route DELETE "repos/$S/issues/4477/labels/ai-build" 200 '[]'
  ghfx_route GET    "repos/$S/issues/4477" 200 "$(jq -nc --argjson l "$LBL" '{state:"open",body:"master ticket",labels:$l}')"
}
slice_plan() { printf '# BH-4477\n\nSLICE: C0 of #4477\n\n## Tasks\n' > "$REC/plan.md"; }
n_patch()  { grep -c -- "-X PATCH repos/$S/issues/4477" "$T/gh-argv.log"; }
n_post()   { grep -c -- "-X POST repos/$S/issues/4477/comments" "$T/gh-argv.log"; }
n_delete() { grep -c -- "-X DELETE repos/$S/issues/4477/labels/ai-build" "$T/gh-argv.log"; }
n_alert()  { grep -c . "$T/h/logs/ALERTS.log"; }
ics() { issue_close_shipped "$S" 4477 "Merged in $PRURL. Closing this issue." "$T/h" "$PRURL" "$REC" 2>/dev/null; }
mcs() { mc_close_shipped "$S" 4477 "Merged in $PRURL (merge conductor). Closing this issue." "$REC" "$PRURL" 2>/dev/null; }
NOKID_LINE='Slice delivered: #4500. No child issue carries the rest yet, so this issue stays open and keeps ai-build.'

for FN in ics mcs; do
  # C3 / C6 a SLICE plan, a Closes body, one open child: today's path
  reset; pr_body "$CLOSES_BODY"; timeline "$KID"; writes; slice_plan
  W=$($FN); RC=$?
  [ "$RC" = 0 ] && [ "$W" = kept-slice:plan+stripped ] && ok || bad "C3[$FN]: an open child must answer kept-slice:plan+stripped rc 0 (rc=$RC w=$W)"
  [ "$(head -1 "$T/posted.txt")" = 'Slice delivered: #4500; children own the rest.' ] && ok \
    || bad "C3[$FN]: first line must be today's 'children own the rest' ($(head -1 "$T/posted.txt"))"
  [ "$(n_delete)" = 1 ] && [ "$(n_post)" = 1 ] && [ "$(n_alert)" = 0 ] && ok \
    || bad "C3[$FN]: one comment, one DELETE, no alert (post=$(n_post) delete=$(n_delete) alerts=$(n_alert))"
  grep -q -- "GET repos/$S/issues/4477/timeline" "$T/gh-argv.log" && ok || bad "C3[$FN]: the children must have been read"

  # C4 / C6 the same with no child: honest comment, label kept, and one critical
  # SLICE_REMAINDER_UNKNOWN page in place of the warn (the plan names no remainder)
  reset; pr_body "$CLOSES_BODY"; timeline '[]'; writes; slice_plan
  # BH-6308: the legacy path, behind its switch; the default is pinned in tests/slice-closeout-closes.bh-6308-test.sh
  W=$(SLICE_CLOSEOUT_SETTLE=0 $FN); RC=$?
  [ "$RC" = 0 ] && [ "$W" = kept-slice:no-children+label-kept ] && ok \
    || bad "C4[$FN]: no child must answer kept-slice:no-children+label-kept rc 0 (rc=$RC w=$W)"
  [ "$(head -1 "$T/posted.txt")" = "$NOKID_LINE" ] && ok || bad "C4[$FN]: first line ($(head -1 "$T/posted.txt"))"
  sed -n 2p "$T/posted.txt" | grep -qxF "$PRURL" && ok || bad "C4[$FN]: the PR url must be on line 2"
  grep -q 'children own the rest' "$T/posted.txt" && bad "C4[$FN]: no child, so no 'children own the rest'" || ok
  [ "$(grep -c '—' "$T/posted.txt")" = 0 ] && ok || bad "C4[$FN]: no em dashes in a client-visible comment"
  [ "$(n_delete)" = 0 ] && [ "$(n_post)" = 1 ] && ok || bad "C4[$FN]: one comment, no DELETE (post=$(n_post) delete=$(n_delete))"
  [ "$(n_alert)" = 1 ] && grep -q -- '--severity critical' "$T/h/logs/ALERTS.log" && grep -q 'SLICE_REMAINDER_UNKNOWN' "$T/h/logs/ALERTS.log" \
    && grep -q '#4477' "$T/h/logs/ALERTS.log" && grep -qF "$PRURL" "$T/h/logs/ALERTS.log" && ok \
    || bad "C4[$FN]: exactly one critical SLICE_REMAINDER_UNKNOWN page naming #4477 and the PR ($(cat "$T/h/logs/ALERTS.log"))"
  grep -q -- '--severity warn' "$T/h/logs/ALERTS.log" && bad "C4[$FN]: the page replaces the warn alert" || ok
  [ -f "$REC/issue-commented" ] && ok || bad "C4[$FN]: the comment must write <record>/issue-commented"
  # the second lane on the same record: no comment, no alert, same word
  cat "$T/gh-argv.log" >> "$T/all-argv.log"; ghfx_log_reset; : > "$T/posted.txt"
  # BH-6308: the legacy path, behind its switch; the default is pinned in tests/slice-closeout-closes.bh-6308-test.sh
  W=$(SLICE_CLOSEOUT_SETTLE=0 $FN); RC=$?
  [ "$RC" = 0 ] && [ "$W" = kept-slice:no-children+label-kept ] && ok || bad "C4[$FN]: second lane word (rc=$RC w=$W)"
  [ "$(n_post)" = 0 ] && [ "$(n_delete)" = 0 ] && [ "$(n_alert)" = 1 ] && ok \
    || bad "C4[$FN]: the second lane posts and alerts nothing (post=$(n_post) delete=$(n_delete) alerts=$(n_alert))"
  # C4b a Refs body, no plan, no child
  reset; pr_body "$REFS_BODY"; timeline '[]'; writes
  # BH-6308: the legacy path, behind its switch; the default is pinned in tests/slice-closeout-closes.bh-6308-test.sh
  W=$(SLICE_CLOSEOUT_SETTLE=0 $FN); RC=$?
  [ "$RC" = 0 ] && [ "$W" = kept-slice:no-children+label-kept ] && [ "$(n_delete)" = 0 ] && [ "$(n_post)" = 1 ] && [ "$(n_alert)" = 1 ] \
    && grep -q -- '--severity warn' "$T/h/logs/ALERTS.log" && ok \
    || bad "C4b[$FN]: a Refs body with no child keeps the warn alert (rc=$RC w=$W post=$(n_post) delete=$(n_delete) alerts=$(n_alert))"
  [ "$(head -1 "$T/posted.txt")" = "$NOKID_LINE" ] && ok || bad "C4b[$FN]: first line ($(head -1 "$T/posted.txt"))"

  # C5 / C6 the children read is refused: nothing written, deferred
  reset; pr_body "$CLOSES_BODY"; ghfx_route GET "repos/$S/issues/4477/timeline*" 403 '{"message":"no"}'; writes; slice_plan
  W=$($FN); RC=$?
  [ "$RC" = 1 ] && [ "$W" = close-deferred:children-read ] && ok || bad "C5[$FN]: a refused read must be close-deferred:children-read rc 1 (rc=$RC w=$W)"
  [ "$(n_post)" = 0 ] && [ "$(n_delete)" = 0 ] && [ "$(n_alert)" = 0 ] && [ ! -f "$REC/issue-commented" ] && ok \
    || bad "C5[$FN]: nothing written (post=$(n_post) delete=$(n_delete) alerts=$(n_alert))"
  # C5 variant: a full page at the cap is an unfinished read, not "no children"
  reset; pr_body "$REFS_BODY"; writes
  timeline "$(jq -nc '[range(100) | {event:"commented"}]')"
  W=$(ISSUE_CLOSE_GUARD_PAGES=1 $FN); RC=$?
  [ "$RC" = 1 ] && [ "$W" = close-deferred:children-read ] && [ "$(n_post)" = 0 ] && [ "$(n_delete)" = 0 ] && [ "$(n_alert)" = 0 ] && ok \
    || bad "C5[$FN]: a capped read must defer and write nothing (rc=$RC w=$W post=$(n_post) delete=$(n_delete) alerts=$(n_alert))"
done

# C6 the conductor keeps its own rule: a refused POST with no child defers, no alert
reset; pr_body "$REFS_BODY"; timeline '[]'
ghfx_route POST   "repos/$S/issues/4477/comments" 403 '{"message":"no"}'
ghfx_route DELETE "repos/$S/issues/4477/labels/ai-build" 200 '[]'
# BH-6308: the legacy path, behind its switch; the default is pinned in tests/slice-closeout-closes.bh-6308-test.sh
W=$(SLICE_CLOSEOUT_SETTLE=0 mcs); RC=$?
[ "$RC" = 1 ] && [ "$W" = comment-deferred ] && [ "$(n_delete)" = 0 ] && [ "$(n_alert)" = 0 ] && ok \
  || bad "C6: a refused no-child comment in the conductor must be comment-deferred rc 1, no strip, no alert (rc=$RC w=$W delete=$(n_delete) alerts=$(n_alert))"
# ...and issue_slice_settle (nobody retries it) still alerts, saying the comment failed
reset; pr_body "$REFS_BODY"; timeline '[]'
ghfx_route POST   "repos/$S/issues/4477/comments" 403 '{"message":"no"}'
ghfx_route DELETE "repos/$S/issues/4477/labels/ai-build" 200 '[]'
# BH-6308: the legacy path, behind its switch; the default is pinned in tests/slice-closeout-closes.bh-6308-test.sh
W=$(SLICE_CLOSEOUT_SETTLE=0 ics); RC=$?
[ "$RC" = 0 ] && [ "$W" = kept-slice:no-children+label-kept,comment-failed ] && [ "$(n_delete)" = 0 ] && [ "$(n_alert)" = 1 ] \
  && grep -q 'comment failed' "$T/h/logs/ALERTS.log" && ok \
  || bad "C6: a refused no-child comment in issue_close_shipped (rc=$RC w=$W delete=$(n_delete) alerts=$(cat "$T/h/logs/ALERTS.log"))"

# C7 across every case above: the master was never closed
reset
[ "$(grep -c -- "-X PATCH repos/$S/issues/4477" "$T/all-argv.log")" = 0 ] && ok \
  || bad "C7: a slice close-out PATCHed the master ($(grep -c -- '-X PATCH' "$T/all-argv.log"))"
grep -q -- "-X POST repos/$S/issues/4477/comments" "$T/all-argv.log" && ok || bad "C7: the cumulative log is empty, so C7 proves nothing"

# ════════════════════════════════════════════════════════════════════════════
# C8. bin/hotfix-after-deploy.sh, driven: the one caller that drops the rc
# ════════════════════════════════════════════════════════════════════════════
H="$T/hf"
mkdir -p "$H/bin/lib" "$H/logs" "$H/env" "$H/state" "$H/flags" "$H/builds"
cp "$DIR/bin/hotfix-after-deploy.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/prod-url.sh" "$H/bin/"
scratch_install_closure bin/hotfix-after-deploy.sh "$H" >/dev/null || { echo "FAIL: closure install failed"; exit 1; }
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/"*.sh
printf 'project-1 o/p https://tproj.example - 2 box-t 100.0.0.9\n' > "$H/fleet.conf"
: > "$H/env/global.env"; : > "$H/env/project-1.env"
ghfx_extra <<'SH'
case "$A" in
  *"-X POST"*"/comments"*)
    for a in "$@"; do case "$a" in body=@*) { cat "${a#body=@}"; printf '\n----\n'; } >> "$GHFX/posted.txt" ;; esac; done ;;
  "api repos/"*"/comments"*) echo 4242; exit 0 ;;
  "api repos/"*"/issues/"*) echo open; exit 0 ;;
  "api repos/"*) echo 1; exit 0 ;;
esac
SH
HB="$H/builds/project-1-BH-378-202610051500"; mkdir -p "$HB"
jq -n '{fp:"deadfp",mode:"endpoint",decision:"applied",files:[{path:"scripts/migrations/a.sql",status:"applied"}],after_deploy:null}' \
  > "$HB/hotfix-migrate.json"
ghfx_routes_reset; ghfx_log_reset
ghfx_route GET    "repos/o/p/pulls/9" 200 "$(jq -nc --arg b $'Hotfix.\nRefs #378' '{number:9,state:"closed",body:$b}')"
ghfx_route GET    "repos/o/p/issues/378/timeline*" 403 '{"message":"no"}'
ghfx_route POST   "repos/o/p/issues/378/comments" 201 '{"id":1}'
ghfx_route PATCH  "repos/o/p/issues/378" 200 '{"state":"closed"}'
ghfx_route DELETE "repos/o/p/issues/378/labels/ai-build" 200 '[]'
ghfx_route GET    "repos/o/p/issues/378" 200 '{"state":"open","body":"m","labels":[{"name":"ai-build"}]}'
( cd "$T" && env HARNESS="$H" FLEET_CONF="$H/fleet.conf" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH" \
    SLUG=o/p PR_URL=https://github.com/o/p/pull/9 \
    bash "$H/bin/hotfix-after-deploy.sh" project-1 "$HB" abc1234def5678 > "$T/hf.out" 2> "$T/hf.err" ); RC=$?
[ "$RC" = 0 ] && ok || bad "C8: the hotfix lane must exit 0 (rc=$RC; $(head -c 300 "$T/hf.err"))"
NW=$(grep -cE -- '-X (POST|DELETE|PATCH) repos/o/p/issues/378' "$T/gh-argv.log")
[ "$NW" = 0 ] && ok || bad "C8: an unreadable children read writes nothing on issue 378 ($NW writes)"
[ "$(grep -c 'issue 378.*close-deferred:children-read' "$H/logs/ALERTS.log")" = 1 ] && ok \
  || bad "C8: one ALERTS line naming issue 378 and close-deferred:children-read ($(cat "$H/logs/ALERTS.log"))"

echo "slice-closeout (BH-4662): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
