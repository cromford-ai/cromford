#!/bin/bash
# tests/mc-batch-victim.bh-9253-test.sh — BH-9253: a PR that Mergify dequeued
# with BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS while its own-head CI is green is a
# batch victim. The conductor adds `queue-solo` and requeues it alone, once per
# head. It does not park it BLOCKED_HUMAN `queue-ejected-twice`.
#
# THE INCIDENT (2026-11-08). #9141 #9132 #9130 #9103 had green CI on their own
# heads. Their batch drafts failed on one shard and Mergify dequeued every
# member with BATCH_MAX. The conductor parked all four at 12:01Z.
#
# THE FIXTURE. tests/fixtures/bh-9229/pr9189-mergify-comments.json (BH-9229):
# comment 6711807239 is a real BATCH_MAX dequeue payload, 6715131096 a real
# CHECKS_FAILED one. The victim cases drop 6715131096, so the newest
# mergify[bot] comment is the BATCH_MAX one.
#
# Driven, not grepped. The fragment is sourced as it is. The conductor's two
# call sites (the settle pass ejection arm and the `parked merged settle`
# block) and mc_mergify_payload_dequeue are extracted VERBATIM from the
# sources. Every gh read and write is a stub that records its call: 0 network
# calls, and a gh binary on PATH that fails the test if anything reaches it.
# Each case has its own scratch dir, ledger and key.
#   D1-D16  mc_bv_decide decision table
#   C1-C4   mc_bv_code over the fixture
#   A1-A5   the settle pass ejection arm
#   B1-B3   the parked-row pass
#   S1-S7   mc_bv_solo exit paths and marks
#   K1-K3   knobs and fallbacks
#   Q1-Q2   bin/lib/queue-risk.sh keeps queue-solo on a solo requeue
#   R1-R4   the tick after a solo requeue: the open pass reads it QUEUED, the
#           re-entry arm does not park it, and only the solo run's own
#           ejection (`bvreejected`) parks it
# Run from anywhere: tests/mc-batch-victim.bh-9253-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }

FX="$DIR/tests/fixtures/bh-9229/pr9189-mergify-comments.json"
FRAG="$DIR/bin/merge-conductor.d/bh-9253-batch-victim.sh"
MC="$DIR/bin/merge-conductor.sh"
SLUG=example-org/cromford
TAB=$'\t'
BM=BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS

fnx() { # fnx <file> <name> — one function, verbatim
  awk -v n="$2" '!f && $0 ~ "^"n"\\(\\)[[:space:]]*\\{" {f=1; print; if ($0 ~ /\}[[:space:]]*$/) exit; next} f {print} f && /^}/ {exit}' "$1"
}
blk() { awk -v b="$2" 'index($0, "# >>> " b) {f=1; next} index($0, "# <<< " b) {exit} f' "$1"; }

fnx "$DIR/bin/lib/mc/queue.sh" mc_mergify_payload_dequeue > "$T/fns.sh"
fnx "$DIR/bin/lib/mc/classify.sh" mc_label_add >> "$T/fns.sh"
grep -q '^mc_mergify_payload_dequeue()' "$T/fns.sh" && ok || bad "could not extract mc_mergify_payload_dequeue"
grep -q '^mc_label_add()' "$T/fns.sh" && ok || bad "could not extract mc_label_add"
# The settle pass ejection arm: from the batch-victim marker (or, on a tree
# without it, the `EJN >= 2` test) to the arm's closing `fi ;;`.
awk 'index($0, "# >>> batch victim (BH-9253)") || index($0, "if [ \"${EJN:-1}\" -ge 2 ]; then") {f=1}
     f {print} f && /^[[:space:]]*fi ;;[[:space:]]*$/ {exit}' "$MC" | sed '$ s/fi ;;[[:space:]]*$/fi/' > "$T/settle.sh"
blk "$MC" "parked merged settle" > "$T/parked.sh"
for b in settle parked; do
  [ -s "$T/$b.sh" ] && bash -n "$T/$b.sh" && ok || bad "could not extract the conductor's $b block"
done

# Comment fixtures. c-bm: the newest mergify comment is the BATCH_MAX dequeue.
jq '[.[] | select(.id != 6715131096)]' "$FX" > "$T/c-bm.json"
cp "$FX" "$T/c-checks.json"
jq '. + [{id: 6715131097, user: {login: "mergify[bot]"}, created_at: "2026-11-08T02:00:00Z",
         body: "Queue requested — the merge queue status continues below."}]' "$T/c-bm.json" > "$T/c-newer.json"
jq '[.[] | select(.id == 6711807239) | .user.login = "operator"]' "$FX" > "$T/c-human.json"
# The BATCH_MAX body with its payload code swapped (the near misses).
swap() { jq --arg c "$1" '[.[] | select(.id == 6711807239) | .body |= sub("BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS"; $c)]' "$FX"; }
swap CONFLICT_WITH_BASE_BRANCH > "$T/c-conflict.json"
swap PR_MANUALLY_DEQUEUED > "$T/c-manual.json"
jq -e '.[0].body | test("CONFLICT_WITH_BASE_BRANCH")' "$T/c-conflict.json" >/dev/null && ok || bad "the code swap fixture did not take"

mkdir -p "$T/fakebin"
printf '#!/bin/bash\nprintf "gh %%s\\n" "$*" >> "%s/unstubbed"\nexit 1\n' "$T" > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
: > "$T/unstubbed"

# drive <case> <mode> [VAR=val...] — one conductor path in a fresh shell.
#   mode: settle | parked | solo. Case files under $T/<case>/: log att writes
#   trans rel fbh fixnow reads views settled.
# Knobs: CI (green), CF (comments file), VERD (APPROVE), VREV (the head), LIVE
# (the head), MERGES (1), BUDGET (1), LABELRC (0), RQRC (0), EJN (2), ROWST
# (BLOCKED_HUMAN), ROWWHY, FRAG_ON (1). DRIVE_KEEP=1 keeps the case ledger.
drive() {
  local c="$1" mode="$2"; shift 2
  mkdir -p "$T/$c"; [ "${DRIVE_KEEP:-0}" = 1 ] || : > "$T/$c/att"
  local hd; hd=$(printf '%s' "$c" | sha1sum | cut -c1-40)
  env CI=green CF="$T/c-bm.json" VERD=APPROVE VREV="$hd" LIVE="$hd" MERGES=1 BUDGET=1 \
      LABELRC=0 RQRC=0 EJN=2 ROWST=BLOCKED_HUMAN FRAG_ON=1 \
      ROWWHY="queue-ejected-twice: 1 checks (Tests, traced (shard 7/12)) on ${hd:0:8}" \
      "$@" PATH="$T/fakebin:$PATH" T="$T" C="$T/$c" FRAG="$FRAG" HD="$hd" MODE="$mode" \
      SLUG="$SLUG" NUM="$((9000 + ${#c}))" bash -c '
    set -uo pipefail
    . "$T/fns.sh"
    [ "$FRAG_ON" = 1 ] && . "$FRAG"
    mc_log() { printf "%s\n" "$*" >> "$C/log"; }
    mc_attempt_has() { grep -qxF "$1" "$C/att" 2>/dev/null; }
    mc_attempt_put() { printf "%s\n" "$1" >> "$C/att"; }
    mc_record_for() { printf "%s" "$C/rec"; }
    mc_verdict() { printf "%s\t-\t%s\t-\t-" "$VERD" "$VREV"; }
    mc_pr_view() { printf "%s\n" "$2" >> "$C/views"
      case "$2" in *STATE*) printf "OPEN ticket/bh-1" ;; *) printf "%s" "$LIVE" ;; esac; }
    mc_ci_state() { printf "ci %s\n" "$*" >> "$C/reads"; printf "%s" "$CI"; }
    gh_rest_issue_comments() { printf "comments %s\n" "$*" >> "$C/reads"; cat "$CF"; }
    mc_rest_var() { local __v="$1"; shift; local __o; __o=$("$@") || return 1; printf -v "$__v" "%s" "$__o"; }
    mc_tick_budget_take() { printf "budget %s\n" "$*" >> "$C/reads"; [ "$BUDGET" = 1 ]; }
    prr_write() { shift 4; printf "%s\n" "$*" >> "$C/writes"; return "$LABELRC"; }
    mc_requeued_record() { mc_attempt_put "requeued $1 $2 1762560000"; }
    mc_requeue_mergify() { printf "requeue %s keep=%s\n" "$*" "${QR_KEEP_SOLO:-}" >> "$C/writes"; return "$RQRC"; }
    mc_transition() { printf "%s\t%s\t%s\n" "$1" "$2" "$3" >> "$C/trans"; }
    mc_handoff_release() { printf "%s\n" "$*" >> "$C/rel"; }
    mc_fbh_clear() { printf "%s\n" "$*" >> "$C/fbh"; }
    mc_eject_fix_now() { printf "%s\n" "$*" >> "$C/fixnow"; }
    mc_only_has() { return 0; }
    mc_pr_lock() { printf "%s" "$C/lock"; }
    conductor_settle() { printf "%s\n" "$*" >> "$C/settled"; }
    ec_summary() { printf ""; }
    P=cromford; PROVIDER=mergify
    QKEY="$SLUG#$NUM"; QHEAD="$HD"; QURL="https://github.com/$SLUG/pull/$NUM"
    QREV="$HD"; QVERDICT=APPROVE; QREC="$C/rec"; QEWHY=""
    case "$MODE" in
      settle) . "$T/settle.sh" ;;
      parked)
        MC_ROWS="$C/rows"
        printf "%s\t%s\t1762560000\t%s\t%s\t-\t%s\t%s\n" "$QKEY" "$ROWST" "$HD" "$HD" "$ROWWHY" "$QURL" > "$MC_ROWS"
        . "$T/parked.sh" ;;
      solo) rc=0; mc_bv_solo "$P" "$SLUG" "$QKEY" "$QHEAD" "$QURL" || rc=$?; printf "%s" "$rc" > "$C/rc" ;;
    esac'
}
f() { cat "$T/$1/$2" 2>/dev/null; }
has() { grep -qF -- "$3" "$T/$1/$2" 2>/dev/null; }
n_of() { grep -c . "$T/$1/$2" 2>/dev/null || true; }

# --- D. mc_bv_decide --------------------------------------------------------------
dec() { FRAG="$FRAG" bash -c '. "$FRAG"; mc_bv_decide "$@"' _ "$@"; }
d_fail=""
dchk() { local want="$1"; shift; local got; got=$(dec "$@"); [ "$got" = "$want" ] || d_fail="$d_fail [$* -> $got, want $want]"; }
dchk victim          "$BM" green 1 0 "$BM"                       # D1 the #9141 shape
dchk victim          "$BM" green 1 0 "X,$BM"                     # D2 a custom csv
dchk victim          "$BM" green 1 0 " X , $BM "                 # D3 spaces in the csv
dchk park:ci-red     "$BM" red 1 0 "$BM"                         # D4 #9166 / #9107
dchk park:ci-pending "$BM" pending 1 0 "$BM"                     # D5
dchk park:ci-unavailable "$BM" unavailable 1 0 "$BM"             # D6
dchk park:ci-none    "$BM" none 1 0 "$BM"                        # D7
dchk park:ci-none    "$BM" "" 1 0 "$BM"                          # D8 an empty CI word
dchk park:code       CHECKS_FAILED green 1 0 "$BM"               # D9 #9189 (BH-9229 path)
dchk park:code       PR_MANUALLY_DEQUEUED green 1 0 "$BM"        # D10
dchk park:code       CONFLICT_WITH_BASE_BRANCH green 1 0 "$BM"   # D11
dchk park:code       "" green 1 0 "$BM"                          # D12 unreadable comments
dchk park:unbound    "$BM" green 0 0 "$BM"                       # D13 verdict on an older head
dchk park:solo-tried "$BM" green 1 1 "$BM"                       # D14 a second BATCH_MAX
dchk park:code       "${BM}_X" green 1 0 "$BM"                   # D15 near miss: longer code
dchk park:code       "$(tr 'A-Z' 'a-z' <<<"$BM")" green 1 0 "$BM"  # D16 near miss: lower case
dchk park:code       "$BM" green 1 0 ""                          # D17 an empty csv
[ -z "$d_fail" ] && ok || bad "D mc_bv_decide:$d_fail"

# --- C. mc_bv_code over the fixture -----------------------------------------------
code_of() { CF="$1" T="$T" FRAG="$FRAG" bash -c '. "$T/fns.sh"; . "$FRAG"
  gh_rest_issue_comments() { cat "$CF"; }
  mc_rest_var() { local __v="$1"; shift; local __o; __o=$("$@") || return 1; printf -v "$__v" "%s" "$__o"; }
  mc_bv_code '"$SLUG"' 9189; echo " rc=$?"'; }
[ "$(code_of "$T/c-bm.json")" = "$BM rc=0" ] && ok || bad "C1 the BATCH_MAX comment: [$(code_of "$T/c-bm.json")]"
[ "$(code_of "$T/c-checks.json")" = "CHECKS_FAILED rc=0" ] && ok || bad "C2 the newest comment wins: [$(code_of "$T/c-checks.json")]"
[ "$(code_of "$T/c-newer.json")" = " rc=1" ] && ok || bad "C3 a newer non-dequeue mergify comment: [$(code_of "$T/c-newer.json")]"
[ "$(code_of "$T/c-human.json")" = " rc=1" ] && ok || bad "C4 a human quoting the payload is not read: [$(code_of "$T/c-human.json")]"

# --- A. the settle pass ejection arm ----------------------------------------------
drive a1 settle
has a1 writes 'labels[]=queue-solo' && ok || bad "A1 a queue-solo label POST: [$(f a1 writes)]"
[ "$(grep -c '^requeue ' "$T/a1/writes")" = 1 ] && has a1 writes 'keep=1' && ok \
  || bad "A1 mc_requeue_mergify is called once, with QR_KEEP_SOLO=1: [$(f a1 writes)]"
S=$(grep -n 'labels\[\]=queue-solo' "$T/a1/writes" | cut -d: -f1); R=$(grep -n '^requeue ' "$T/a1/writes" | cut -d: -f1)
[ -n "$S" ] && [ -n "$R" ] && [ "$S" -lt "$R" ] && ok || bad "A1 the label goes on BEFORE the requeue: [$(f a1 writes)]"
grep -q "${TAB}QUEUED${TAB}batch-victim: requeued solo on " "$T/a1/trans" 2>/dev/null && ok \
  || bad "A1 the row becomes QUEUED batch-victim: [$(f a1 trans)]"
has a1 log 'BATCH_VICTIM_SOLO ' && has a1 log "code=$BM ci=green" && ok || bad "A1 BATCH_VICTIM_SOLO is logged: [$(f a1 log)]"
has a1 rel 'batch-victim' && ok || bad "A1 the hand-off is released: [$(f a1 rel)]"
has a1 fbh 'batch-victim' && ok || bad "A1 the failed-batch hold is cleared: [$(f a1 fbh)]"
# A2: no park, no fix round.
grep -q "BLOCKED_HUMAN" "$T/a1/trans" 2>/dev/null && bad "A2 a victim is not parked: [$(f a1 trans)]" || ok
[ ! -s "$T/a1/fixnow" ] && ok || bad "A2 a victim gets no fix round: [$(f a1 fixnow)]"
# A3: the first ejection (EJN=1) is not asked at all.
drive a3 settle EJN=1
[ ! -s "$T/a3/writes" ] && [ ! -s "$T/a3/reads" ] && grep -q "${TAB}WAIT_CI${TAB}queue-ejected" "$T/a3/trans" && ok \
  || bad "A3 a first ejection is today's WAIT_CI with no read: trans=[$(f a3 trans)] reads=[$(f a3 reads)]"
# A4: with the fragment absent the arm parks exactly as before.
drive a4 settle FRAG_ON=0
grep -q "${TAB}BLOCKED_HUMAN${TAB}queue-ejected-twice" "$T/a4/trans" && [ -s "$T/a4/fixnow" ] && ok \
  || bad "A4 no fragment = today's park: trans=[$(f a4 trans)]"
# A5: own CI red: today's park, the fix round, no label.
drive a5 settle CI=red
grep -q "${TAB}BLOCKED_HUMAN${TAB}queue-ejected-twice" "$T/a5/trans" && ok || bad "A5 CI red still parks: [$(f a5 trans)]"
[ -s "$T/a5/fixnow" ] && ok || bad "A5 CI red still gets the fix round"
[ ! -s "$T/a5/writes" ] && ok || bad "A5 CI red writes no label and no requeue: [$(f a5 writes)]"
has a5 log 'BATCH_VICTIM_PARK ' && has a5 log 'park:ci-red' && ok || bad "A5 the park line names ci-red: [$(f a5 log)]"
# A6: CHECKS_FAILED with green CI stays on the BH-9229 fix-round path.
drive a6 settle CF="$T/c-checks.json"
grep -q "${TAB}BLOCKED_HUMAN${TAB}" "$T/a6/trans" && [ -s "$T/a6/fixnow" ] && [ ! -s "$T/a6/writes" ] && ok \
  || bad "A6 CHECKS_FAILED parks and gets the fix round: trans=[$(f a6 trans)] writes=[$(f a6 writes)]"
grep -q '^ci ' "$T/a6/reads" 2>/dev/null && bad "A6 a code that is not a victim code reads no CI" || ok

# --- B. the parked-row pass -------------------------------------------------------
drive b1 parked
has b1 writes 'labels[]=queue-solo' && grep -q '^requeue ' "$T/b1/writes" && ok \
  || bad "B1 a parked victim is labelled and requeued: [$(f b1 writes)]"
grep -q "${TAB}QUEUED${TAB}batch-victim:" "$T/b1/trans" && has b1 rel batch-victim && ok \
  || bad "B1 the row becomes QUEUED and the hand-off is released: trans=[$(f b1 trans)] rel=[$(f b1 rel)]"
[ ! -s "$T/b1/fixnow" ] && ok || bad "B1 a parked victim gets no fix round: [$(f b1 fixnow)]"
drive b2 parked CI=red
[ -s "$T/b2/fixnow" ] && [ ! -s "$T/b2/writes" ] && [ ! -s "$T/b2/trans" ] && ok \
  || bad "B2 a parked red PR gets the fix round only: fixnow=[$(f b2 fixnow)] writes=[$(f b2 writes)]"
drive b3 parked ROWWHY="red-twice: CI failed"
[ ! -s "$T/b3/fixnow" ] && [ ! -s "$T/b3/writes" ] && [ ! -s "$T/b3/reads" ] && ok \
  || bad "B3 a park for another reason is not asked: reads=[$(f b3 reads)]"

# --- S. mc_bv_solo exit paths -----------------------------------------------------
drive s1 solo MERGES=0
[ "$(f s1 rc)" = 1 ] && [ ! -s "$T/s1/writes" ] && ! grep -q '^batchvictim ' "$T/s1/att" && has s1 log 'would add queue-solo' && ok \
  || bad "S1 observe mode writes nothing, rc 1: rc=$(f s1 rc) writes=[$(f s1 writes)]"
drive s2 solo BUDGET=0
[ "$(f s2 rc)" = 1 ] && [ ! -s "$T/s2/writes" ] && ! grep -q '^batchvictim ' "$T/s2/att" && ok \
  || bad "S2 a spent requeue budget: rc 1, no label: rc=$(f s2 rc) writes=[$(f s2 writes)]"
drive s3 solo LABELRC=1
[ "$(f s3 rc)" = 1 ] && ! grep -q '^batchvictim ' "$T/s3/att" && ! grep -q '^requeue ' "$T/s3/writes" && ok \
  || bad "S3 a failed label POST: rc 1, no mark, no requeue: rc=$(f s3 rc) att=[$(f s3 att)]"
# S4: the writer/reader round trip. First call requeues, second answers solo-tried.
drive s4 solo
[ "$(f s4 rc)" = 0 ] && grep -q '^batchvictim ' "$T/s4/att" && grep -q '^requeued ' "$T/s4/att" && ok \
  || bad "S4 the first call requeues and writes both marks: rc=$(f s4 rc) att=[$(f s4 att)]"
for x in writes reads views trans log; do : > "$T/s4/$x"; done
DRIVE_KEEP=1 drive s4 solo
[ "$(f s4 rc)" = 1 ] && has s4 log 'park:solo-tried' && ok \
  || bad "S4 a second call on the same head answers park:solo-tried: rc=$(f s4 rc) log=[$(f s4 log)]"
[ ! -s "$T/s4/writes" ] && [ ! -s "$T/s4/reads" ] && [ ! -s "$T/s4/views" ] && ok \
  || bad "S4 a spent head reads and writes nothing: reads=[$(f s4 reads)] writes=[$(f s4 writes)]"
# S5: the reason the row gets is never fed back to the parked-row pass.
WHY5=$(cut -f3 "$T/a1/trans" | head -1)
for st in QUEUED WAIT_CI BLOCKED_HUMAN; do
  drive "s5-$st" parked ROWST="$st" ROWWHY="$WHY5"
  [ ! -s "$T/s5-$st/views" ] && [ ! -s "$T/s5-$st/reads" ] && [ ! -s "$T/s5-$st/fixnow" ] && ok \
    || bad "S5 a $st '$WHY5' row is not selected by the parked-row pass: views=[$(f "s5-$st" views)]"
done
drive s6 solo RQRC=3
[ "$(f s6 rc)" = 0 ] && grep -q "${TAB}WAIT_CI${TAB}batch-victim: requeued solo on .*awaiting Mergify's witness" "$T/s6/trans" && ok \
  || bad "S6 requeue rc 3 = WAIT_CI awaiting the witness: rc=$(f s6 rc) trans=[$(f s6 trans)]"
grep -q QUEUED "$T/s6/trans" && bad "S6 rc 3 is never QUEUED" || ok
drive s7 solo RQRC=1
[ "$(f s7 rc)" = 1 ] && [ ! -s "$T/s7/trans" ] && grep -q '^batchvictim ' "$T/s7/att" && has s7 log REQUEUE_FAILED && ok \
  || bad "S7 requeue rc 1: park, marks kept, no transition: rc=$(f s7 rc) trans=[$(f s7 trans)] att=[$(f s7 att)]"
drive s8 solo VREV=0000000000000000000000000000000000000000
[ "$(f s8 rc)" = 1 ] && [ ! -s "$T/s8/writes" ] && has s8 log park:unbound && ok \
  || bad "S8 an approval on an older head parks: rc=$(f s8 rc) log=[$(f s8 log)]"
drive s9 solo LIVE=1111111111111111111111111111111111111111
[ "$(f s9 rc)" = 1 ] && [ ! -s "$T/s9/writes" ] && ok || bad "S9 a live head that moved parks: rc=$(f s9 rc)"
drive s10 solo VERD=BLOCK
[ "$(f s10 rc)" = 1 ] && [ ! -s "$T/s10/writes" ] && ok || bad "S10 a BLOCK verdict parks"
drive s11 solo CI=pending
[ "$(f s11 rc)" = 1 ] && has s11 log park:ci-pending && ok || bad "S11 pending CI parks: [$(f s11 log)]"
# A pending CI is asked again; a red CI is a final answer for the head.
grep -q 'park:ci-pending' "$T/s11/att" && ok || bad "S11 the park line is marked once"

# --- K. knobs ---------------------------------------------------------------------
drive k1 solo MC_BATCH_VICTIM=0
[ "$(f k1 rc)" = 1 ] && [ ! -s "$T/k1/reads" ] && [ ! -s "$T/k1/writes" ] && [ ! -s "$T/k1/views" ] && ok \
  || bad "K1 MC_BATCH_VICTIM=0: rc 1 with no read: reads=[$(f k1 reads)]"
drive k2 solo MC_BATCH_VICTIM_CODES=CHECKS_FAILED
[ "$(f k2 rc)" = 1 ] && has k2 log park:code && ok || bad "K2 the codes knob is read: [$(f k2 log)]"
# K3: the fallbacks, with lane_knob present and answering nothing (no row).
K3=$(env -u MC_BATCH_VICTIM -u MC_BATCH_VICTIM_CODES FRAG="$FRAG" bash -c '. "$FRAG"; lane_knob() { printf ""; }
  printf "%s|%s" "$(_mc_bv_knob MC_BATCH_VICTIM 1)" "$(_mc_bv_knob MC_BATCH_VICTIM_CODES BATCH_MAX_FAILURE_RESOLUTION_ATTEMPTS)"')
[ "$K3" = "1|$BM" ] && ok || bad "K3 the code fallbacks with no row: [$K3]"
K4=$(FRAG="$FRAG" bash -c '. "$FRAG"; lane_knob() { [ "$2" = MC_BATCH_VICTIM ] && printf 0; }; _mc_bv_knob MC_BATCH_VICTIM 1')
[ "$K4" = 0 ] && ok || bad "K4 a settings row wins over the fallback: [$K4]"

# --- Q. queue-risk keeps the solo label on a solo requeue -------------------------
QH="$T/qr"; mkdir -p "$QH/config/mergify/repos"
printf 'slug=%s\nsolo_label=queue-solo\n' "$SLUG" > "$QH/config/mergify/repos/cromford.conf"
qr() { # qr <keep 0|1> — a batch-route PR that carries queue-solo
  QH="$QH" DIR="$DIR" KEEP="$1" SLUG="$SLUG" bash -c '
    . "$DIR/bin/lib/queue-risk.sh"
    _qr_root() { printf "%s" "$QH"; }
    qr_mode() { printf enforce; }
    gh_rest_var() { printf -v "$1" "%s" "{\"title\":\"BH-1: x\",\"head\":{\"ref\":\"ticket/bh-1\"},\"additions\":1,\"deletions\":0,\"changed_files\":1,\"labels\":[{\"name\":\"queue-solo\"}]}"; }
    mc_pr_files() { printf "docs/a.md\n"; }
    train_is_train() { return 1; }
    qr_score() { printf "0\t50\tbatch\t-"; }
    _qr_log() { printf "%s\n" "$*" >> "$QH/log"; }
    _qr_record() { :; }
    gh() { printf "%s\n" "$*" >> "$QH/calls"; }
    if [ "$KEEP" = 1 ]; then QR_KEEP_SOLO=1 qr_enqueue_step "$SLUG" 41 aaaa; else qr_enqueue_step "$SLUG" 41 aaaa; fi'
}
: > "$QH/calls"; qr 1
grep -q -- '-X DELETE' "$QH/calls" && bad "Q1 a solo requeue keeps queue-solo: [$(cat "$QH/calls")]" || ok
grep -q 'keeps label queue-solo' "$QH/log" && ok || bad "Q1 the keep is logged: [$(cat "$QH/log" 2>/dev/null)]"
: > "$QH/calls"; qr 0
grep -q -- '-X DELETE repos/example-org/cromford/issues/41/labels/queue-solo' "$QH/calls" && ok \
  || bad "Q2 without the flag a batch route still removes a stale queue-solo: [$(cat "$QH/calls")]"

# --- R. the tick after a solo requeue ---------------------------------------------
# The open pass asks mc_mergify_inqueue, which asks mc_ejection_live. Both are
# extracted VERBATIM, with mc_bv_requeue_live and mc_requeued_mark. Before the
# fix the `reejected` line of the second ejection made the requeued head read
# as ejected, so the row fell to the re-entry arm and was parked one tick after
# the solo requeue (lead review of 64d7d315).
for fn in mc_mergify_inqueue; do fnx "$DIR/bin/lib/mc/queue.sh" "$fn"; done > "$T/open.sh"
for fn in mc_requeued_mark mc_ejection_live mc_bv_requeue_live; do fnx "$DIR/bin/lib/mc/classify.sh" "$fn"; done >> "$T/open.sh"
for fn in mc_mergify_inqueue mc_requeued_mark mc_ejection_live mc_bv_requeue_live; do
  grep -q "^$fn()" "$T/open.sh" && ok || bad "could not extract $fn"
done
# The re-entry arm's park decision: from the batch-victim comment to the
# provider test, closed with `fi`.
awk 'index($0, "# A batch victim requeued solo on this head (BH-9253)") {f=1}
     f && index($0, "elif [ \"$PROVIDER\" != mergify ]") {exit} f' "$MC" > "$T/reentry.sh"
printf 'fi\n' >> "$T/reentry.sh"
grep -q 'mc_bv_requeue_live' "$T/reentry.sh" && bash -n "$T/reentry.sh" && ok || bad "could not extract the re-entry arm's park decision"
# open <case> <labels> <prev> — "<inqueue rc> <ejection_live rc> <STATE>|<WHY>"
# over the case ledger, as the open pass of the next tick reads it.
open_tick() {
  C="$T/$1" LBL="$2" PREV="$3" T="$T" SLUG="$SLUG" NUM="$((9000 + ${#1}))" HD=$(printf '%s' "$1" | sha1sum | cut -c1-40) bash -c '
    . "$T/open.sh"
    mc_attempt_has() { grep -qxF "$1" "$C/att" 2>/dev/null; }
    mc_attempt_tail() { awk -v k="$1 $2 $3" "index(\$0, k\" \")==1 { sub(/^[^ ]+ [^ ]+ [^ ]+ ?/, \"\"); print; exit }" "$C/att"; }
    mc_mergify_witness() { printf "witness\n" >> "$C/reads"; return 1; }
    MC_MERGIFY_LABEL=merge-queue
    KEY="$SLUG#$NUM"; HEAD="$HD"; URL="https://github.com/$SLUG/pull/$NUM"
    i=0; mc_mergify_inqueue "$SLUG" "$KEY" "$URL" "$HEAD" "$LBL" "$PREV" || i=$?
    e=0; mc_ejection_live "$KEY" "$HEAD" || e=$?
    STATE=READY; WHY=""; EJN=2
    ec_summary() { return 1; }
    . "$T/reentry.sh"
    printf "%s %s %s|%s" "$i" "$e" "$STATE" "$WHY"'
}
# r1: the ledger of a head ejected, requeued, ejected again, then requeued solo.
mkdir -p "$T/r1"; HR1=$(printf r1 | sha1sum | cut -c1-40); KR1="$SLUG#$((9000 + 2))"
printf '%s\n' "ejected $KR1 $HR1" "requeued $KR1 $HR1 1762550000" "reejected $KR1 $HR1" > "$T/r1/att"
DRIVE_KEEP=1 drive r1 solo
[ "$(f r1 rc)" = 0 ] && grep -q "^batchvictim $KR1 $HR1\$" "$T/r1/att" && ok \
  || bad "R1 setup: the solo requeue ran on the reejected ledger: rc=$(f r1 rc) att=[$(f r1 att)]"
# R1: one tick later, the row QUEUED with our label on: the open pass reads it
# queued, mc_ejection_live is not live, and no witness read is spent.
R1=$(open_tick r1 merge-queue QUEUED)
[ "${R1%% *}" = 0 ] && ok || bad "R1 the open pass reads the solo-requeued head QUEUED: [$R1]"
[ "$(cut -d' ' -f2 <<<"$R1")" = 1 ] && ok || bad "R1 mc_ejection_live is not live after the solo requeue: [$R1]"
# R2: Mergify's own label alone (row not yet QUEUED) also reads queued.
R2=$(open_tick r1 queued WAIT_CI)
[ "${R2%% *}" = 0 ] && ok || bad "R2 Mergify's queued label reads QUEUED after the solo requeue: [$R2]"
# R3: no witness yet (rc-3 path): the re-entry arm waits, it does not park.
R3=$(open_tick r1 "" WAIT_CI)
case "$R3" in *"WAIT_CI|batch-victim: requeued solo on ${HR1:0:8}"*) ok ;; *) bad "R3 the re-entry arm waits on a solo requeue, never parks: [$R3]" ;; esac
grep -q BLOCKED_HUMAN <<<"$R3" && bad "R3 a solo-requeued head is never parked by the re-entry arm: [$R3]" || ok
[ ! -s "$T/r1/fixnow" ] && ok || bad "R1-R3 no fix round while the solo run is in the queue: [$(f r1 fixnow)]"
# R4: the solo run ejects the head. The settle pass writes `bvreejected`,
# mc_bv_solo answers park:solo-tried, the row parks and the fix round starts.
for x in writes reads views trans log; do : > "$T/r1/$x"; done
DRIVE_KEEP=1 drive r1 settle EJN=3
grep -q "^bvreejected $KR1 $HR1\$" "$T/r1/att" && ok || bad "R4 the solo run's ejection writes bvreejected: [$(f r1 att)]"
grep -q "${TAB}BLOCKED_HUMAN${TAB}queue-ejected-twice" "$T/r1/trans" && [ -s "$T/r1/fixnow" ] && has r1 log park:solo-tried && ok \
  || bad "R4 the ejected solo run parks with the fix round: trans=[$(f r1 trans)] log=[$(f r1 log)]"
[ ! -s "$T/r1/writes" ] && ok || bad "R4 no second solo requeue: [$(f r1 writes)]"
R4=$(open_tick r1 "" WAIT_CI)
[ "$(cut -d' ' -f1-2 <<<"$R4")" = "1 0" ] && case "$R4" in *"BLOCKED_HUMAN|queue-ejected-twice"*) true ;; *) false ;; esac && ok \
  || bad "R4 after the solo run's ejection the head is live and the arm parks it: [$R4]"

# --- 0 vendor calls ---------------------------------------------------------------
[ ! -s "$T/unstubbed" ] && ok || bad "a gh call reached the PATH binary: [$(cat "$T/unstubbed")]"

echo "mc-batch-victim.bh-9253: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
