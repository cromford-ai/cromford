#!/bin/bash
# tests/blocked-resolver-pm-release.bh-7836-test.sh — BH-7836: the rebuild-fresh
# rung releases the malformed-plan hold before it buys a rebuild.
#
# WHAT HAPPENED. TK-1163 was held after two malformed plans (state/plan-malformed.txt
# and the plan_malformed ledger row said `held`). The resolver drained the
# PLAN_MALFORMED park with a rebuild-fresh rung. The rebuild reached the hold
# gate in bin/lib/rb/plan.sh, wrote `PLAN skipped … no plan session spent` and
# exited 4. The resolver saw PLAN_MALFORMED again and spent the next rung. Three
# rungs went that way, then ABANDONED.
#
# THE CASES (plan ## Acceptance tests):
#   U1-U9  br_pm_release on its own: which rows release, which do not, the rc
#   R1     a held ticket + a PLAN_MALFORMED record, one tick: the release is
#          written before the enqueue, and the SHIPPED plan-launch region then
#          calls the planner. Second arm, BR_OPT_OFF: today's bug (skipped).
#   R2     the ledger put fails: nothing closed, nothing enqueued, no counter
#   R3     no hold: the rung runs as before, no release line, no file
#   R4     after a release, a third malformed plan re-holds the ticket
#
# No vendor: gh, the jobs client and the ledger are local fakes (BH-7563).
# Every case has its own ticket key.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-pm-release.bh-7836-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

FRAG="$DIR/bin/blocked-resolver.d/bh-7836-pm-release.sh"

# ============================================================================
# U. The fragment on its own. A stub `say`, a scratch $H, and a file-backed
#    ledger fake: LEDGER_GET_RC forces the get rc (1 outage), PUT_RC the put rc.
# ============================================================================
U="$T/u"
UH="$U/h"
ulog="$U/say.log"; uled="$U/ledger.log"
ufresh() { # ufresh <file rows (printf %b)> <ledger status or ""> [get rc]
  scratch_rm "$U"; mkdir -p "$UH/state"
  : > "$ulog"; : > "$uled"
  [ -n "$1" ] && printf '%b' "$1" > "$UH/state/plan-malformed.txt"
  ULED_ST="$2"; ULED_RC="${3:-}"
}
urun() { # urun <p> <rkey> <reason> <tkey> ; prints rc
  ( H="$UH"; PUT_RC="${PUT_RC:-0}"
    say() { printf '%s\n' "$*" >> "$ulog"; }
    job_ledger_get() {
      printf 'GET|%s|%s\n' "$1" "$2" >> "$uled"
      [ -n "$ULED_RC" ] && return "$ULED_RC"
      [ -n "$ULED_ST" ] || return 2
      printf '%s\n' "$ULED_ST"; return 0
    }
    job_ledger_put() { printf 'PUT|%s|%s|%s\n' "$1" "$2" "$3" >> "$uled"; return "$PUT_RC"; }
    # shellcheck source=/dev/null
    . "$FRAG" || exit 9
    br_pm_release "$@" )
  echo $?
}
lastrow() { awk -v p="$1" -v k="$2" '$1==p && $2==k {s=$3} END{print s}' "$UH/state/plan-malformed.txt" 2>/dev/null; }
nrows()   { grep -c . "$UH/state/plan-malformed.txt" 2>/dev/null || true; }
puts()    { grep -c '^PUT|' "$uled" 2>/dev/null || true; }

[ -r "$FRAG" ] && ok || bad "0: bin/blocked-resolver.d/bh-7836-pm-release.sh is missing"

# U1 requeued then held: released row last, ledger put, rc 0.
ufresh 'tproj TK-11 requeued 2026-10-20T01:00:00Z\ntproj TK-11 held 2026-10-20T02:00:00Z /b/size-gate.txt\n' ""
RC=$(urun tproj tproj-TK-11 plan-malformed TK-11)
[ "$RC" = 0 ] && ok || bad "U1: rc must be 0 (got $RC)"
[ "$(lastrow tproj TK-11)" = released ] && ok || bad "U1: the last TK-11 row must be released: $(cat "$UH/state/plan-malformed.txt")"
grep -q '^tproj TK-11 released [0-9T:-]*Z blocked-resolver:tproj-TK-11$' "$UH/state/plan-malformed.txt" \
  && ok || bad "U1: the row must be '<p> <k> released <stamp> blocked-resolver:<rkey>': $(tail -1 "$UH/state/plan-malformed.txt")"
grep -q '^PUT|plan_malformed|tproj TK-11|released$' "$uled" && ok || bad "U1: ledger put plan_malformed|tproj TK-11|released: $(cat "$uled")"
[ "$(grep -c 'released the malformed-plan hold on TK-11 (was held)' "$ulog")" = 1 ] && ok \
  || bad "U1: exactly one released say line: $(cat "$ulog")"

# U2 held then skipped.
ufresh 'tproj TK-12 held 2026-10-20T01:00:00Z\ntproj TK-12 skipped 2026-10-20T02:00:00Z\n' ""
RC=$(urun tproj tproj-TK-12 build-dead TK-12)
[ "$RC" = 0 ] && [ "$(lastrow tproj TK-12)" = released ] && [ "$(puts)" = 1 ] && ok \
  || bad "U2: held,skipped must release (rc=$RC last=$(lastrow tproj TK-12) puts=$(puts))"
grep -q '(was skipped)' "$ulog" && ok || bad "U2: the line must name the status it released: $(cat "$ulog")"

# U3 no file row, ledger held (a Fly machine with an empty state dir).
ufresh '' held
RC=$(urun tproj tproj-TK-13 plan-malformed TK-13)
[ "$RC" = 0 ] && [ "$(lastrow tproj TK-13)" = released ] && [ "$(puts)" = 1 ] && ok \
  || bad "U3: a ledger-only hold must release both halves (rc=$RC last=$(lastrow tproj TK-13) puts=$(puts))"

# U4 file last row released, ledger still skipped: the ledger half is released.
ufresh 'tproj TK-14 held 2026-10-20T01:00:00Z\ntproj TK-14 released 2026-10-20T02:00:00Z\n' skipped
RC=$(urun tproj tproj-TK-14 plan-malformed TK-14)
[ "$RC" = 0 ] && [ "$(lastrow tproj TK-14)" = released ] && [ "$(puts)" = 1 ] && [ "$(nrows)" = 3 ] && ok \
  || bad "U4: a ledger hold behind a released file row must release again (rc=$RC rows=$(nrows) puts=$(puts))"

# U5 no hold in four shapes: no write, no put, no line, rc 0.
u5() { # u5 <label> <rows> <ledger> [get rc]
  local before
  ufresh "$2" "$3" "${4:-}"
  before=$(cat "$UH/state/plan-malformed.txt" 2>/dev/null)
  RC=$(urun tproj tproj-TK-15 plan-malformed TK-15)
  [ "$RC" = 0 ] && [ "$(puts)" = 0 ] && [ ! -s "$ulog" ] \
    && [ "$(cat "$UH/state/plan-malformed.txt" 2>/dev/null)" = "$before" ] && ok \
    || bad "U5 $1: must not release (rc=$RC puts=$(puts) say=$(cat "$ulog") file=$(cat "$UH/state/plan-malformed.txt" 2>/dev/null))"
}
u5 requeued-only 'tproj TK-15 requeued 2026-10-20T01:00:00Z\n' ""
u5 held-released 'tproj TK-15 held 2026-10-20T01:00:00Z\ntproj TK-15 released 2026-10-20T02:00:00Z\n' ""
u5 no-rows '' ""
u5 outage '' "" 1
[ ! -e "$UH/state/plan-malformed.txt" ] && ok || bad "U5: a ledger outage with no file row must create no file"

# U6 near misses: a neighbour key in both directions, another project.
ufresh 'tproj TK-160 held 2026-10-20T01:00:00Z\nxproj TK-16 held 2026-10-20T01:00:00Z\n' ""
RC=$(urun tproj tproj-TK-16 plan-malformed TK-16)
[ "$RC" = 0 ] && [ "$(nrows)" = 2 ] && [ "$(puts)" = 0 ] && ok \
  || bad "U6: TK-160 and xproj TK-16 must not release tproj TK-16 (rows=$(nrows) puts=$(puts))"
ufresh 'tproj TK-16 held 2026-10-20T01:00:00Z\n' ""
RC=$(urun tproj tproj-TK-160 plan-malformed TK-160)
[ "$RC" = 0 ] && [ "$(nrows)" = 1 ] && [ "$(puts)" = 0 ] && ok \
  || bad "U6: TK-16 held must not release TK-160 (rows=$(nrows) puts=$(puts))"

# U7 a requeued row whose artifact path says `held`.
ufresh 'tproj TK-17 requeued 2026-10-20T01:00:00Z /b/held/size-gate.txt\n' ""
RC=$(urun tproj tproj-TK-17 plan-malformed TK-17)
[ "$RC" = 0 ] && [ "$(nrows)" = 1 ] && [ "$(puts)" = 0 ] && ok \
  || bad "U7: field 3 is the status, not a word anywhere in the row (rows=$(nrows) puts=$(puts))"

# U8 held, the ledger put fails: rc 1 and one deferral line, no released line.
ufresh 'tproj TK-18 held 2026-10-20T01:00:00Z\n' ""
RC=$(PUT_RC=1 urun tproj tproj-TK-18 plan-malformed TK-18)
[ "$RC" = 1 ] && ok || bad "U8: a failed ledger put must return 1 (got $RC)"
[ "$(grep -c 'rebuild deferred' "$ulog")" = 1 ] && ok || bad "U8: exactly one deferral line: $(cat "$ulog")"
grep -q 'released the malformed-plan hold' "$ulog" && bad "U8: no released line when the put failed: $(cat "$ulog")" || ok

# U8b the file write fails (state is a file, not a dir): rc 1.
ufresh '' held
scratch_rm "$UH/state"; : > "$UH/state"
RC=$(urun tproj tproj-TK-19 plan-malformed TK-19)
[ "$RC" = 1 ] && [ "$(puts)" = 0 ] && ok || bad "U8b: a failed file write must return 1 before the ledger put (rc=$RC puts=$(puts))"

# U9 no ticket key: nothing read, nothing written.
ufresh 'tproj - held 2026-10-20T01:00:00Z\n' held
RC=$(urun tproj tproj-x plan-malformed -)
[ "$RC" = 0 ] && [ ! -s "$uled" ] && [ "$(nrows)" = 1 ] && ok \
  || bad "U9: tkey '-' must read and write nothing (rc=$RC ledger=$(cat "$uled"))"
RC=$(urun tproj tproj-x plan-malformed "")
[ "$RC" = 0 ] && [ ! -s "$uled" ] && ok || bad "U9: an empty tkey must read and write nothing (rc=$RC)"

# ============================================================================
# R. The whole lane, then the shipped plan-launch region of run-build.
# ============================================================================
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$DIR/bin/alert-line.sh" "$H/bin/"
fx_br_harness "$DIR" "$T" || exit 1
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
mkdir -p "$H/bin/blocked-resolver.d"
cp "$DIR/bin/blocked-resolver.d/"*.sh "$H/bin/blocked-resolver.d/" || exit 1
touch "$H/flags/fly-pool-tproj"   # pool project: the rebuild is a queue row
# TEST-CHANGE (BH-7970): the plan launch region sources $HARNESS/bin/lib/stage-prompt.sh and renders prompts/stages/plan.md; the scratch harness carries both, as a synced box does.
scratch_install_closure bin/lib/stage-prompt.sh "$H" >/dev/null || bad "could not install bin/lib/stage-prompt.sh into the scratch harness"
mkdir -p "$H/prompts/stages"; cp "$DIR"/prompts/stages/*.md "$H/prompts/stages/"
# The jobs client: the queue and a file-backed ledger. Every queue_put and
# every ledger put lands in ONE ordered file, so "released before enqueued" is
# a line order. $T/pm-put-fail makes the plan_malformed put fail (R2).
LED="$T/ledger"; SEQ="$T/seq.txt"
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf 'queue_put %s\n' "\$*" >> "$SEQ"; printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
job_ledger_get() {
  local f="$LED/\$1/\$(printf '%s' "\$2" | tr ' /' '__')"
  [ -s "\$f" ] || return 2
  head -1 "\$f"
}
job_ledger_put() {
  [ "\$1" = plan_malformed ] && [ -e "$T/pm-put-fail" ] && return 1
  local f="$LED/\$1/\$(printf '%s' "\$2" | tr ' /' '__')"
  mkdir -p "$LED/\$1" && printf '%s\n' "\$3" > "\$f" || return 1
  printf 'ledger_put %s|%s|%s\n' "\$1" "\$2" "\$3" >> "$SEQ"
}
EOF
. "$H/bin/jobs-client.sh" || exit 1   # the plan region below reads the same ledger
PMF="$H/state/plan-malformed.txt"
LOGF="$H/logs/blocked-resolver.log"

# The shipped run-build regions, by their markers (tests/plan-malformed-cap-test.sh).
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> plan launch/{f=1;next} /^# <<< plan launch/{exit} f' "$RB_ALL" > "$T/launch.sh"
awk '/^# >>> plan malformed terminal/{f=1;next} /^# <<< plan malformed terminal/{exit} f' "$RB_ALL" > "$T/terminal.sh"
grep -q 'CC plan' "$T/launch.sh" && ok || bad "R: the plan launch region must call the planner"
grep -q '^PM_TERMINAL()' "$T/terminal.sh" && ok || bad "R: the terminal region must define PM_TERMINAL"
# drive <key> <region> [cmd] — the region against the lane's harness tree and
# ledger, with the model call, beat and RESULT stubbed. cc.log = planner calls.
drive() {
  rm -rf "$T/b"; mkdir -p "$T/b"; : > "$T/cc.log"
  ( env HARNESS="$H" BUILD="$T/b" PROJECT=tproj KEY="$1" TICKET=tkt-1 \
        PLAN_MODEL=stub-model ALERTS="$T/rb-alerts.log" CCLOG="$T/cc.log" FP_BEFORE="" REPO="$T" \
        PLAN_AMBIGUITY_RULE="" KIND_HINT_LINE="" CARRIED_NOTE_LINE="" JC="$H/bin/jobs-client.sh" CMD="${3:-}" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             RESULT() { echo "RESULT=$*"; }
             BB() { echo "BB=$1"; }
             CC() { echo "$1" >> "$CCLOG"; }
             . "$JC"
             . "$0"; [ -n "$CMD" ] && eval "$CMD"; echo LAUNCHED' "$2" 2>&1 )
}
planned() { grep -c . "$T/cc.log" 2>/dev/null || true; }
last()    { awk -v k="$1" '$1=="tproj" && $2==k {s=$3} END{print s}' "$PMF" 2>/dev/null; }
# park <key> — a held ticket (two malformed plans, both halves) and its
# PLAN_MALFORMED build record, three hours old.
park() {
  local n rec
  n="${1#TK-}"; rec="$H/builds/tproj-$1-2026102200$n"
  printf 'tproj %s requeued 2026-10-20T01:00:00Z\ntproj %s held 2026-10-20T02:00:00Z /b/size-gate.txt\n' "$1" "$1" >> "$PMF"
  job_ledger_put plan_malformed "tproj $1" held
  mkdir -p "$rec"
  echo "PLAN_MALFORMED held for a human: $1 already produced 2 malformed plans" > "$rec/RESULT"
  touch -d '3 hours ago' "$rec/RESULT"
}
clean() {
  scratch_rm "$H/state/blocked-resolver"; scratch_rm "$H/builds"; mkdir -p "$H/builds"
  : > "$T/queue.txt"; : > "$T/closed.txt"; : > "$SEQ"; : > "$LOGF"
  : > "$H/state/merge-conductor/pr-state.tsv"; rm -f "$T/pm-put-fail"
  BRENV=()
}

# R1 (the reproduction). Prod default: the release is written, then enqueued.
clean; park TK-71
RUN
grep -q '^tproj TK-71 ' "$T/queue.txt" && ok || bad "R1: the rebuild must be enqueued (queue: $(cat "$T/queue.txt"); log: $(tail -5 "$LOGF"))"
[ "$(last TK-71)" = released ] && ok || bad "R1: the last TK-71 row must be released before the rebuild: $(grep 'TK-71 ' "$PMF")"
REL=$(grep -n '^ledger_put plan_malformed|tproj TK-71|released$' "$SEQ" | head -1 | cut -d: -f1)
ENQ=$(grep -n '^queue_put tproj TK-71 ' "$SEQ" | head -1 | cut -d: -f1)
[ -n "$REL" ] && [ -n "$ENQ" ] && [ "$REL" -lt "$ENQ" ] && ok \
  || bad "R1: the released ledger put must come BEFORE the queue_put (seq: $(cat "$SEQ"))"
[ "$(grep -c 'released the malformed-plan hold on TK-71' "$LOGF")" = 1 ] && ok \
  || bad "R1: exactly one released line in the lane log: $(grep TK-71 "$LOGF")"
OUT=$(drive TK-71 "$T/launch.sh"); RC=$?
[ "$(planned)" = 1 ] && ok || bad "R1: the rebuild's plan region must call the planner once (rc=$RC out: $OUT)"
[ "$RC" != 4 ] && grep -q LAUNCHED <<<"$OUT" && ok || bad "R1: the plan region must not exit 4 (rc=$RC out: $OUT)"
grep -q 'PLAN skipped' "$T/b/pipeline.log" 2>/dev/null && bad "R1: no 'PLAN skipped' line after the release: $(cat "$T/b/pipeline.log")" || ok

# R1 second arm: the fragment off is today's behaviour — enqueued, still held,
# and the rebuild's plan region skips the planner (the bug).
clean; park TK-75
BRENV=(BR_OPT_OFF=bh-7836-pm-release)
RUN
grep -q '^tproj TK-75 ' "$T/queue.txt" && ok || bad "R1/off: the rung still enqueues with the fragment off (queue: $(cat "$T/queue.txt"))"
[ "$(last TK-75)" = held ] && ok || bad "R1/off: with the fragment off nothing releases: $(grep 'TK-75 ' "$PMF")"
OUT=$(drive TK-75 "$T/launch.sh"); RC=$?
[ "$(planned)" = 0 ] && [ "$RC" = 4 ] && ok || bad "R1/off: today's rebuild skips the planner and exits 4 (rc=$RC planned=$(planned))"

# R2. The ledger put fails: the rung is deferred, nothing irreversible done.
clean; park TK-72
touch "$T/pm-put-fail"
RUN
[ -s "$T/queue.txt" ] && bad "R2: a release that was not recorded must enqueue nothing: $(cat "$T/queue.txt")" || ok
[ -s "$T/closed.txt" ] && bad "R2: …and close nothing: $(cat "$T/closed.txt")" || ok
[ "$(STATEJSON tproj-TK-72 | jq -r '.rebuilds // 0' 2>/dev/null || echo 0)" = 0 ] && ok \
  || bad "R2: …and spend no rebuild counter: $(STATEJSON tproj-TK-72)"
[ "$(grep -c 'rebuild deferred, nothing closed, no counter spent' "$LOGF")" = 1 ] && ok \
  || bad "R2: exactly one deferral line: $(grep TK-72 "$LOGF")"
grep -q 'released the malformed-plan hold on TK-72' "$LOGF" && bad "R2: no released line when the put failed" || ok

# R2b. The same failure on a park that HAS an open PR (merge-failed-twice, no
#      ladder above it): the deferral comes before the close, so the PR stays
#      open. When the put works on the next tick, it is released, then closed.
clean
printf 'tproj TK-9 requeued 2026-10-20T01:00:00Z\ntproj TK-9 held 2026-10-20T02:00:00Z /b/size-gate.txt\n' >> "$PMF"
job_ledger_put plan_malformed "tproj TK-9" held; : > "$SEQ"
ROW "o/tproj#9" "merge-failed-twice: gh pr merge refused" "https://github.com/o/tproj/pull/9"
touch "$T/pm-put-fail"
RUN
[ -s "$T/closed.txt" ] && bad "R2b: a deferred release must leave the PR open: $(cat "$T/closed.txt")" || ok
[ -s "$T/queue.txt" ] && bad "R2b: …and enqueue nothing: $(cat "$T/queue.txt")" || ok
grep -q 'rebuild deferred, nothing closed' "$LOGF" && ok || bad "R2b: the deferral line: $(tail -5 "$LOGF")"
rm -f "$T/pm-put-fail"
RUN
[ -s "$T/closed.txt" ] && ok || bad "R2b: with the put working, the rung closes the PR (log: $(tail -5 "$LOGF"))"
grep -q '^tproj TK-9 ' "$T/queue.txt" && ok || bad "R2b: …and enqueues the rebuild: $(cat "$T/queue.txt")"
[ "$(last TK-9)" = released ] && ok || bad "R2b: …and TK-9 is released: $(grep 'TK-9 ' "$PMF")"

# R3. No hold: the rung runs as before, no release, no plan-malformed file.
clean; rm -f "$PMF"
REC3="$H/builds/tproj-TK-73-202610220073"; mkdir -p "$REC3"
echo "PLAN_MALFORMED the plan had no VALIDATE line" > "$REC3/RESULT"
touch -d '3 hours ago' "$REC3/RESULT"
RUN
grep -q '^tproj TK-73 ' "$T/queue.txt" && ok || bad "R3: an unheld park must still be rebuilt (queue: $(cat "$T/queue.txt"))"
grep -q 'malformed-plan hold' "$LOGF" && bad "R3: no release line without a hold: $(grep 'malformed-plan' "$LOGF")" || ok
[ ! -e "$PMF" ] && ok || bad "R3: no plan-malformed.txt without a hold: $(cat "$PMF")"
grep -q 'plan_malformed' "$SEQ" && bad "R3: no plan_malformed ledger put without a hold: $(cat "$SEQ")" || ok

# R4. The hold still bounds plan sessions: after the release, one more
# malformed plan (the shipped PM_TERMINAL) holds the ticket again.
clean; park TK-74
RUN
[ "$(last TK-74)" = released ] && ok || bad "R4: setup — the tick must release TK-74: $(grep 'TK-74 ' "$PMF")"
OUT=$(drive TK-74 "$T/terminal.sh" 'PM_TERMINAL "a third untraced plan" /b/plan-gate.txt "trace its tasks"'); RC=$?
[ "$RC" = 4 ] && [ "$(last TK-74)" = held ] && ok \
  || bad "R4: a malformed plan after the release must hold again (rc=$RC last=$(last TK-74) out: $OUT)"
OUT=$(drive TK-74 "$T/launch.sh"); RC=$?
[ "$(planned)" = 0 ] && [ "$RC" = 4 ] && ok || bad "R4: the re-held ticket must skip the planner (rc=$RC planned=$(planned))"

echo "blocked-resolver-pm-release (BH-7836): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
