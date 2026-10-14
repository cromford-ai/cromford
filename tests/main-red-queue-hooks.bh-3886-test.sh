#!/bin/bash
# tests/main-red-queue-hooks.bh-3886-test.sh — BH-3888 (1 of 5 of BH-3886): the
# wiring bin/main-red-detector.sh's merge-queue arm gives the three optional
# libs (bin/lib/main-red-queue-{thaw,attr,dispatch}.sh), its new flag lines and
# its two knobs. The libs themselves are the sibling tickets'; here each one is
# a STUB that records how it was called, so what is pinned is the contract.
#
# THE PAGES ARE REAL. tests/fixtures/bh-3886/ holds the cromford runs of
# 2026-10-02 as `gh api` returned them (a jq field projection, nothing typed):
# reds 36969794399 (#3882 + #3855 + #3881), 36967597297 (#3847), 36966459398
# (#3873), then greens at 05:54Z. Every timestamp is rebased onto NOW with its
# gaps kept, and a page is CUT at an instant (only runs whose updated_at is at
# or before it) to give the detector the state it saw then.
#
#   H1  the queue read projects updated_at, and qred_done= carries it
#   H2  R/W lines exist only with a verdict: mrqa_attr is called with the
#       counted batches and their PRs; on a 2-red page it is never called
#   H3  a reason=queue flag carries qred_t=/qred_done=/raised=; raised= survives
#       a new-sha rewrite (and a legacy flag's detected= becomes raised=)
#   H4a mrqt_stand_down rc 0 drops the verdict
#   H4b mrqa_attr `own` excludes that batch on pass 2; the cap; the lib absent;
#       the knob at 0
#   H4c mrqt_clear_ok decides the queue clear (rc 0 clears, rc 1 holds) and
#       mrqd_self_dispatch is called on the hold
#   H4d mrqd_self_dispatch on the same-sha still-red path, queue flags only
#   H5  no libs: flag, alerts, verdict and log equal the pre-BH-3888 detector's
#   H6  the knobs resolve settings row > env > default; non-numeric = default
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/main-red-queue-hooks.bh-3886-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  [ -n "${CI:-}" ] && { echo "FAIL: jq/python3 missing on a CI runner"; exit 1; }
  echo "main-red-queue-hooks.bh-3886-test: SKIPPED — jq/python3 is not installed"; exit 0; }
FX="$DIR/tests/fixtures/bh-3886"
[ -s "$FX/queue-2026-10-02.json" ] && [ -s "$FX/main-2026-10-02.json" ] || {
  echo "FAIL: the bh-3886 fixtures are missing"; exit 1; }
REG=$(rendered_registry)

NOW=$(date +%s)                     # the ONLY clock read in this file
SLUG=example-org/cromford
# The pre-BH-3888 detector H5 compares against: the base this wiring was built
# on. A later ticket that changes the no-lib decision on these pages on purpose
# re-pins it.
BASE_SHA=1226c3b

# tree <dir> <detector-file> — a scratch harness root around one detector copy.
tree() {
  mkdir -p "$1/bin/lib" "$1/logs" "$1/state" "$1/flags" "$1/locks" "$1/env" "$1/fakebin" "$1/ledger" "$1/stub"
  cp "$2" "$1/bin/main-red-detector.sh"
  cp "$DIR/bin/lib/gh-repo-token.sh" "$DIR/bin/lib/env-path.sh" "$DIR/bin/lib/lane-gate.sh" "$1/bin/lib/"
  : > "$1/env/global.env"
  cat > "$1/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
  chmod +x "$1/bin/lane-alert.sh"
  # The coordination-DB client, as tests/main-red-schedule-skip.bh-3769-test.sh
  # keeps it: ledger verbs over files, /api/settings from $ROWS.
  cat > "$1/bin/jobs-client.sh" <<'SHIM'
flag_set() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$PUBLISH_SINK"; return 0; }
_lrow() { printf '%s/%s__%s' "$LEDGER_DIR" "$1" "$(printf '%s' "$2" | tr '/#' '-_')"; }
job_ledger_get() { local f; f=$(_lrow "$1" "$2"); [ -f "$f" ] || return 2; cat "$f"; return 0; }
job_ledger_put() { printf '%s' "$3" > "$(_lrow "$1" "$2")"; return 0; }
_jobs_req() {
  case "$2" in
    /api/settings)
      local out="[]" kv IFS=$'\n'
      for kv in ${ROWS:-}; do
        out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"t"}]')
      done
      printf '{"settings":%s}' "$out" ;;
    *) return 1 ;;
  esac
}
SHIM
  # The gh fake APPLIES THE -q FILTER THE DETECTOR PASSED to the page on disk,
  # so a field the detector stops projecting is a field the detector stops
  # getting (H1 is behaviour, not a grep of the source).
  cat > "$1/fakebin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
q=""; a=("$@"); for i in "${!a[@]}"; do [ "${a[$i]}" = -q ] && q="${a[$((i+1))]}"; done
case "$*" in
  "api repos/"*" -q .id") exit 0 ;;
  *"/actions/runs/"*"/jobs"*) exit 1 ;;
  *"event=pull_request"*) [ -s "$PAGES/queue.json" ] || exit 1; jq -c "$q" "$PAGES/queue.json" ;;
  *"actions/runs"*)       [ -s "$PAGES/main.json" ]  || exit 1; jq -c "$q" "$PAGES/main.json" ;;
  *) echo "" ;;
esac
SHIM
  chmod +x "$1/fakebin/gh"
}
T_OLD="$T/old"; T_NEW="$T/new"
tree "$T_NEW" "$DIR/bin/main-red-detector.sh"
PAGES="$T/pages"; mkdir -p "$PAGES"

# page <queue|main> <cut-iso> — the fixture runs whose updated_at <= cut, every
# timestamp shifted by ONE offset (05:53:34Z, the newest red's finish, lands one
# minute before NOW) so two pages cut at different instants stay one timeline.
page() {
  python3 - "$FX/$1-2026-10-02.json" "$2" "$NOW" "$PAGES/$1.json" <<'PY'
import calendar, json, sys, time
src, cut, now, out = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
P = lambda s: calendar.timegm(time.strptime(s, "%Y-%m-%dT%H:%M:%SZ"))
F = lambda e: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(e))
off = now - 60 - P("2026-10-02T05:53:34Z")
runs = [r for r in json.load(open(src))["workflow_runs"] if P(r["updated_at"]) <= P(cut)]
for r in runs:
    r["created_at"] = F(P(r["created_at"]) + off); r["updated_at"] = F(P(r["updated_at"]) + off)
json.dump({"workflow_runs": runs}, open(out, "w"))
PY
}
# rebased <run-id> <field> — a field of a run as the rebased page serves it.
rebased() { jq -r --argjson id "$1" ".workflow_runs[] | select(.id == \$id) | .$2" "$PAGES/queue.json"; }
CUT3=2026-10-02T05:53:34Z   # 3 independent reds: 36969794399, 36967597297, 36966459398
CUT2=2026-10-02T05:23:13Z   # 2 independent reds: 36967597297, 36966459398
CUTG=2026-10-02T06:09:28Z   # the two greens of 05:54Z have finished

# stubs <names...> — install stub libs into the NEW tree. Each records
# "<fn> <args>" in $STUB_SINK and answers from the environment.
stubs() {
  rm -f "$T_NEW"/bin/lib/main-red-queue-*.sh
  local s
  for s in "$@"; do case "$s" in
    thaw) cat > "$T_NEW/bin/lib/main-red-queue-thaw.sh" <<'SHIM'
# what a lib reads of mr_queue_verdict's globals, at the moment it is called
_g() { echo "$1 QRED_T=${QRED_T:-} QRED_DONE=${QRED_DONE:-} QWALK=$(printf '%s' "${QWALK:-}" | grep -c .)" >> "$STUB_SINK.g"; }
mrqt_stand_down() { echo "mrqt_stand_down $*" >> "$STUB_SINK"; _g stand; MRQT_WHY="${STUB_WHY:-}"; return "${STUB_STAND_RC:-1}"; }
mrqt_clear_ok()   { echo "mrqt_clear_ok $*"   >> "$STUB_SINK"; _g clear; MRQT_WHY="${STUB_WHY:-}"; return "${STUB_CLEAR_RC:-1}"; }
SHIM
    ;;
    attr) cat > "$T_NEW/bin/lib/main-red-queue-attr.sh" <<'SHIM'
mrqa_attr() {
  echo "mrqa_attr $*" >> "$STUB_SINK"
  if [ "$2" = "${STUB_OWN_ID:-}" ]; then MRQA_VERDICT=own; MRQA_PR=${STUB_OWN_PR:-}; MRQA_WHY="stub says its own diff broke it"
  else MRQA_VERDICT=untouched; MRQA_PR=""; MRQA_WHY=""; fi
}
SHIM
    ;;
    dispatch) cat > "$T_NEW/bin/lib/main-red-queue-dispatch.sh" <<'SHIM'
mrqd_self_dispatch() { echo "mrqd_self_dispatch $*" >> "$STUB_SINK"; return 0; }
SHIM
    ;;
  esac; done
}
# drive <root> [args] — one tick of that root's detector.
drive() {
  local r="$1"; shift
  ( export PATH="$r/fakebin:$PATH" HARNESS="$r" PAGES="$PAGES" GH_SINK="$r/gh.txt" LANE_REGISTRY="$REG" \
           ALERT_SINK="$r/alerts.txt" PUBLISH_SINK="$r/publish.txt" LEDGER_DIR="$r/ledger" ROWS="${ROWS:-}" \
           STUB_SINK="$r/stub.txt" MAIN_RED_QUEUE_REPOS="$SLUG"; unset GH_TOKEN
    bash "$r/bin/main-red-detector.sh" "$@" "$SLUG" >/dev/null 2>>"$r/err.txt" )
}
reset_tree() {
  local r="$1"
  local p; for p in ledger state/main-red state/lane-gate state/settings-cache.json; do scratch_rm "$r/$p" || exit 1; done
  mkdir -p "$r/ledger"
  rm -f "$r"/flags/main-red-*
  : > "$r/alerts.txt"; : > "$r/gh.txt"; : > "$r/logs/main-red.log"; : > "$r/publish.txt"; : > "$r/stub.txt"; : > "$r/stub.txt.g"; : > "$r/err.txt"
}
reset() { reset_tree "$T_NEW"; ROWS=""; }
FLAG="$T_NEW/flags/main-red-example-org-cromford"
LOG="$T_NEW/logs/main-red.log"
calls() { grep -c "^$1 " "$T_NEW/stub.txt" 2>/dev/null; }
crit()  { grep -c '^--critical' "$T_NEW/alerts.txt" 2>/dev/null; }
fl()    { sed -n "s/^$1=//p" "$FLAG" 2>/dev/null | head -1; }
STAMPNOW=$(date -u -d "@$NOW" '+%Y-%m-%d %H:%M:%SZ')
# preflag <sha> <reason> — a flag this detector already raised.
preflag() {
  printf 'sha=%s\nworkflow=Harness CI\npath=.github/workflows/harness-ci.yml\njob=(job list unavailable)\nsince=2026-10-02T04:52:39Z\nstreak=3\nrun=u\ndetected=%s\nreason=%s\n' \
    "$1" "$STAMPNOW" "$2" > "$FLAG"
}

# ── H1. the projection carries updated_at, and it reaches the flag.
reset; stubs; page main "$CUT3"; page queue "$CUT3"
drive "$T_NEW"
grep 'event=pull_request' "$T_NEW/gh.txt" | head -1 | grep -q 'ut:.updated_at' && ok \
  || bad "H1: the queue read must project updated_at: $(grep 'event=pull_request' "$T_NEW/gh.txt" | head -1)"
[ -f "$FLAG" ] && ok || bad "H1: three independent red batches must still freeze (log=$(tail -3 "$LOG"))"
[ -n "$(fl qred_done)" ] && [ "$(fl qred_done)" = "$(rebased 36969794399 updated_at)" ] && ok \
  || bad "H1: qred_done= must be the newest counted red's updated_at ($(rebased 36969794399 updated_at)), got '$(fl qred_done)'"
grep -q 'unbound variable' "$T_NEW/err.txt" && bad "H1: set -u tripped: $(cat "$T_NEW/err.txt")" || ok

# ── H2. R/W only with a verdict.
reset; stubs attr; page main "$CUT3"; page queue "$CUT3"
drive "$T_NEW"
for w in "36969794399 3855 3881 3882" "36967597297 3847" "36966459398 3873"; do
  grep -qx "mrqa_attr $SLUG $w" "$T_NEW/stub.txt" && ok || bad "H2: mrqa_attr must be called as '$SLUG $w': $(cat "$T_NEW/stub.txt")"
done
[ "$(fl qred_t)" = "$(rebased 36969794399 created_at)" ] && ok \
  || bad "H2: qred_t= must be 36969794399's created_at ($(rebased 36969794399 created_at)), got '$(fl qred_t)'"
reset; stubs attr; page main "$CUT3"; page queue "$CUT2"
drive "$T_NEW"
{ [ ! -f "$FLAG" ] && [ "$(calls mrqa_attr)" = 0 ]; } && ok \
  || bad "H2-neg: two reds are no verdict — no flag and no attribution call (stub=$(cat "$T_NEW/stub.txt"))"

# ── H3. the flag lines, and raised= across a new-sha rewrite.
reset; stubs; page main "$CUT3"; page queue "$CUT2"
( export MAIN_RED_QUEUE_STREAK=2; drive "$T_NEW" )
[ "$(fl reason)" = queue ] && ok || bad "H3: tick 1 must raise reason=queue: $(cat "$FLAG" 2>/dev/null)"
R1=$(fl raised); S1=$(fl since); SHA1=$(fl sha)
[ -n "$R1" ] && [ "$(fl qred_t)" = "$(rebased 36967597297 created_at)" ] && [ "$(fl qred_done)" = "$(rebased 36967597297 updated_at)" ] && ok \
  || bad "H3: tick 1 must carry qred_t/qred_done of 36967597297 and a raised= stamp: $(cat "$FLAG" 2>/dev/null)"
sed -n '1,9p' "$FLAG" | cut -d= -f1 | tr '\n' ' ' | grep -qx 'sha workflow path job since streak run detected reason ' && ok \
  || bad "H3: the existing keys keep their order above the new lines: $(cut -d= -f1 "$FLAG" | tr '\n' ' ')"
[ "$(sed -n '10,12p' "$FLAG" | cut -d= -f1 | tr '\n' ' ')" = "qred_t qred_done raised " ] && ok \
  || bad "H3: the three new lines come last: $(cut -d= -f1 "$FLAG" | tr '\n' ' ')"
# raised= is the episode's first raise: back-date it, and the rewrite must keep it.
sed -i 's/^raised=.*/raised=2026-10-02 05:00:00Z/' "$FLAG"
page queue "$CUT3"
( export MAIN_RED_QUEUE_STREAK=2; drive "$T_NEW" )
{ [ "$(fl sha)" != "$SHA1" ] && [ "$(fl raised)" = "2026-10-02 05:00:00Z" ] && [ "$(fl since)" = "$S1" ] \
  && [ "$(fl qred_t)" = "$(rebased 36969794399 created_at)" ]; } && ok \
  || bad "H3: a new-sha rewrite keeps raised= and since=, and takes the new qred_t=: $(cat "$FLAG" 2>/dev/null)"
# a legacy queue flag (no raised=) rewritten on a new sha: raised= is its detected=.
preflag deadbeef queue; sed -i 's/^detected=.*/detected=2026-10-02 04:00:00Z/' "$FLAG"
drive "$T_NEW"
[ "$(fl raised)" = "2026-10-02 04:00:00Z" ] && ok || bad "H3: a legacy flag's detected= becomes raised=: $(cat "$FLAG" 2>/dev/null)"

# ── H4a. mrqt_stand_down rc 0 drops the verdict.
reset; stubs thaw; page main "$CUT3"; page queue "$CUT3"
( export STUB_STAND_RC=0 STUB_WHY=test-why; drive "$T_NEW" )
{ [ ! -f "$FLAG" ] && [ "$(crit)" = 0 ] && grep -q 'test-why — the queue arm stands down' "$LOG" \
  && grep -qx "mrqt_stand_down $SLUG" "$T_NEW/stub.txt"; } && ok \
  || bad "H4a: a stand-down must drop the verdict and say why (flag=$( [ -f "$FLAG" ] && echo yes); log=$(tail -3 "$LOG"))"
reset; stubs thaw; page main "$CUT3"; page queue "$CUT3"
( export STUB_STAND_RC=1; drive "$T_NEW" )
[ -f "$FLAG" ] && ok || bad "H4a-neg: a stand-down that answers rc 1 changes nothing — the freeze goes up"
# H2, as a lib sees it: with a verdict the globals are set when the hook runs.
grep -qx "stand QRED_T=$(rebased 36969794399 created_at) QRED_DONE=$(rebased 36969794399 updated_at) QWALK=3" "$T_NEW/stub.txt.g" && ok \
  || bad "H2: mrqt_stand_down must see QRED_T/QRED_DONE and three W lines: $(cat "$T_NEW/stub.txt.g")"

# ── H4b. attribution: `own` is excluded on pass 2.
reset; stubs attr; page main "$CUT3"; page queue "$CUT3"
( export STUB_OWN_ID=36969794399 STUB_OWN_PR=3882; drive "$T_NEW" )
[ ! -f "$FLAG" ] && ok || bad "H4b: with 36969794399 attributed, two reds are left — no freeze: $(cat "$FLAG" 2>/dev/null)"
grep -q "$SLUG: queue batch 36969794399 (#3855 + #3881 + #3882) red on $(rebased 36969794399 head_sha | cut -c1-8) attributed to #3882, not counted toward main-red — stub says its own diff broke it" "$LOG" && ok \
  || bad "H4b: the exclusion is logged: $(grep 'queue batch' "$LOG")"
# the cap: QUEUE_STREAK=1 reads at most 2 of the 3 counted batches.
reset; stubs attr; page main "$CUT3"; page queue "$CUT3"
( export MAIN_RED_QUEUE_STREAK=1; drive "$T_NEW" )
{ [ "$(awk '{print $3}' "$T_NEW/stub.txt" | sort -u | wc -l)" = 2 ] \
  && ! grep -q ' 36966459398' "$T_NEW/stub.txt" && grep -q 'attribution read 2 of 3 red batches' "$LOG"; } && ok \
  || bad "H4b-cap: QUEUE_STREAK*2=2 batches read, the third not, and the cap logged (stub=$(sort -u "$T_NEW/stub.txt" | tr '\n' ';'); log=$(grep attribution "$LOG"))"
# the lib absent, the knob on: said once per run, verdict unchanged.
reset; stubs; page main "$CUT3"; page queue "$CUT3"
drive "$T_NEW"
{ [ "$(grep -c 'attribution is off: bin/lib/main-red-queue-attr.sh is not installed' "$LOG")" = 1 ] && [ -f "$FLAG" ]; } && ok \
  || bad "H4b-off: one 'attribution is off' line and the freeze stands (n=$(grep -c 'attribution is off' "$LOG"))"
# the knob at 0, the lib present: never called, and nothing says it is off.
reset; stubs attr; page main "$CUT3"; page queue "$CUT3"
( export MAIN_RED_QUEUE_ATTR=0 STUB_OWN_ID=36969794399; drive "$T_NEW" )
{ [ "$(calls mrqa_attr)" = 0 ] && [ -f "$FLAG" ] && ! grep -q 'attribution is off' "$LOG"; } && ok \
  || bad "H4b-zero: MAIN_RED_QUEUE_ATTR=0 must not call mrqa_attr (calls=$(calls mrqa_attr))"

# ── H4c. mrqt_clear_ok decides the queue clear.
reset; stubs thaw dispatch; page main "$CUT3"; page queue "$CUT2"; preflag deadbeef queue
( export STUB_CLEAR_RC=0 STUB_WHY=thaw-why; drive "$T_NEW" )
{ [ ! -f "$FLAG" ] && [ "$(grep -c -- '^--resolve' "$T_NEW/alerts.txt")" = 1 ] && [ "$(wc -l < "$T_NEW/alerts.txt")" = 1 ] \
  && grep -q "$SLUG: queue freeze thawed — thaw-why" "$LOG" \
  && grep -qx "mrqt_clear_ok $SLUG $FLAG" "$T_NEW/stub.txt"; } && ok \
  || bad "H4c: rc 0 clears with one resolve (alerts=$(cat "$T_NEW/alerts.txt"); log=$(tail -3 "$LOG"))"
reset; stubs thaw dispatch; page main "$CUT3"; page queue "$CUT2"; preflag deadbeef queue
( export STUB_CLEAR_RC=1; drive "$T_NEW" )
{ [ -f "$FLAG" ] && [ ! -s "$T_NEW/alerts.txt" ] && grep -q 'flag left as it is' "$LOG" \
  && [ "$(grep -cx "mrqd_self_dispatch $SLUG $FLAG" "$T_NEW/stub.txt")" = 1 ]; } && ok \
  || bad "H4c-neg: rc 1 holds, sends nothing, and self-dispatch is asked once (stub=$(cat "$T_NEW/stub.txt"); alerts=$(cat "$T_NEW/alerts.txt"))"
# H2-neg, as a lib sees it: two reds are no verdict, so no R and no W lines.
grep -qx "clear QRED_T= QRED_DONE= QWALK=0" "$T_NEW/stub.txt.g" && ok \
  || bad "H2-neg: with no verdict mrqt_clear_ok must see QRED_T/QRED_DONE/QWALK empty: $(cat "$T_NEW/stub.txt.g")"

# ── H4d. the same-sha still-red path asks self-dispatch, for a queue flag only.
reset; stubs dispatch; page main "$CUT3"; page queue "$CUT3"; preflag "$(rebased 36969794399 head_sha)" queue
drive "$T_NEW"
{ [ "$(grep -cx "mrqd_self_dispatch $SLUG $FLAG" "$T_NEW/stub.txt")" = 1 ] && grep -q 'still red' "$LOG"; } && ok \
  || bad "H4d: still red on the same sha calls mrqd_self_dispatch once (stub=$(cat "$T_NEW/stub.txt"); log=$(tail -2 "$LOG"))"
reset; stubs dispatch; page main "$CUT3"; page queue "$CUT3"; preflag "$(rebased 36969794399 head_sha)" streak
drive "$T_NEW"
{ [ "$(calls mrqd_self_dispatch)" = 0 ] && grep -q 'still red' "$LOG"; } && ok \
  || bad "H4d-neg: a reason=streak flag still red is not a queue flag — no self-dispatch (stub=$(cat "$T_NEW/stub.txt"))"

# ── H5. no libs: the same decisions, alerts and log as the detector before it.
if git -C "$DIR" cat-file -e "$BASE_SHA:bin/main-red-detector.sh" 2>/dev/null; then
  git -C "$DIR" show "$BASE_SHA:bin/main-red-detector.sh" > "$T/old-detector.sh"
  tree "$T_OLD" "$T/old-detector.sh"
  norm_log()  { sed -E 's/^[0-9-]+ [0-9:]+Z //' "$1" | grep -v -e '^queue knobs ' -e '^attribution is off' -e '^pass start: ' -e '^pass end: ' -e ' decision=none reason='; }
  norm_flag() { grep -v -e '^qred_t=' -e '^qred_done=' -e '^raised=' -e '^detected=' "$1" 2>/dev/null; }
  h5() { # h5 <label> — one tick on the current pages in both trees, compared
    local r d
    for r in "$T_OLD" "$T_NEW"; do drive "$r"; done
    [ "$(norm_log "$T_OLD/logs/main-red.log")" = "$(norm_log "$T_NEW/logs/main-red.log")" ] && ok \
      || bad "H5 $1: logs differ: $(diff <(norm_log "$T_OLD/logs/main-red.log") <(norm_log "$T_NEW/logs/main-red.log"))"
    [ "$(norm_flag "$T_OLD/flags/main-red-example-org-cromford")" = "$(norm_flag "$FLAG")" ] && ok \
      || bad "H5 $1: flags differ: $(diff <(norm_flag "$T_OLD/flags/main-red-example-org-cromford") <(norm_flag "$FLAG"))"
    cmp -s "$T_OLD/alerts.txt" "$T_NEW/alerts.txt" && cmp -s "$T_OLD/publish.txt" "$T_NEW/publish.txt" && ok \
      || bad "H5 $1: alerts/publishes differ: $(diff "$T_OLD/alerts.txt" "$T_NEW/alerts.txt")"
    [ "$(grep -v '^at=' "$T_OLD/state/main-red/example-org-cromford.verdict")" = "$(grep -v '^at=' "$T_NEW/state/main-red/example-org-cromford.verdict")" ] && ok \
      || bad "H5 $1: verdicts differ"
    grep -q 'unbound variable' "$T_NEW/err.txt" && bad "H5 $1: set -u tripped: $(cat "$T_NEW/err.txt")" || ok
  }
  reset; reset_tree "$T_OLD"; stubs
  page main "$CUT3"; page queue "$CUT3"; h5 raise
  [ -f "$FLAG" ] && ok || bad "H5 raise: the scenario must actually raise"
  page queue "$CUTG"; h5 green-after
  page queue "$CUT2"; h5 two-reds
else
  [ -n "${CI:-}" ] && bad "H5: $BASE_SHA is not in this checkout — the baseline cannot be read" \
    || echo "H5: SKIPPED — $BASE_SHA is not in this checkout (shallow clone)"
fi

# ── H6. the knobs: settings row > env > default; non-numeric = default.
knobline() { sed -nE 's/^[0-9-]+ [0-9:]+Z (queue knobs .*)/\1/p' "$LOG" | tail -1; }
reset; stubs attr; page main "$CUT3"; page queue "$CUT3"
ROWS="lib.main-red-detector.main_red_queue_attr=0
lib.main-red-detector.main_red_queue_self_dispatch_min=7"
( export MAIN_RED_QUEUE_ATTR=1 MAIN_RED_QUEUE_SELF_DISPATCH_MIN=9; drive "$T_NEW" )
{ [ "$(calls mrqa_attr)" = 0 ] && [ "$(knobline)" = "queue knobs attr=0 (from settings) self-dispatch=7 (from settings)" ]; } && ok \
  || bad "H6 row: a settings row beats env for both knobs (calls=$(calls mrqa_attr); line=$(knobline))"
reset; stubs attr; page main "$CUT3"; page queue "$CUT3"
( export MAIN_RED_QUEUE_ATTR=0 MAIN_RED_QUEUE_SELF_DISPATCH_MIN=0; drive "$T_NEW" )
{ [ "$(calls mrqa_attr)" = 0 ] && [ "$(knobline)" = "queue knobs attr=0 (from env) self-dispatch=0 (from env)" ]; } && ok \
  || bad "H6 env: no row, env 0 is off (calls=$(calls mrqa_attr); line=$(knobline))"
reset; stubs attr; page main "$CUT3"; page queue "$CUT3"
( export MAIN_RED_QUEUE_ATTR=abc MAIN_RED_QUEUE_SELF_DISPATCH_MIN=abc; drive "$T_NEW" )
{ [ "$(calls mrqa_attr)" -gt 0 ] && [ "$(knobline)" = "queue knobs attr=1 (from default) self-dispatch=60 (from default)" ]; } && ok \
  || bad "H6 abc: a non-numeric env is the default, never off (calls=$(calls mrqa_attr); line=$(knobline))"
reset; stubs attr; page main "$CUT3"; page queue "$CUT3"
drive "$T_NEW"
[ "$(knobline)" = "queue knobs attr=1 (from default) self-dispatch=60 (from default)" ] && ok \
  || bad "H6 unset: both defaults (line=$(knobline))"

echo "main-red-queue-hooks.bh-3886: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
