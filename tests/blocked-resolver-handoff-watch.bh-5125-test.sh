#!/bin/bash
# tests/blocked-resolver-handoff-watch.bh-5125-test.sh — A HAND-OFF TO THE
# RESOLVER ACTS, SAYS WHY NOT, OR PAGES (BH-5125 item 3).
#
# WHAT HAPPENED (2026-10-07). bin/review-rescue.sh logged that PR #5067 "goes to
# bin/blocked-resolver.sh for an agent fix round" at 04:34:50Z and no round ran.
# br_from_builds offers a rescued REVIEW_BLOCKED record only once its RESULT is
# 90 minutes old, and as rescue-giving-up (a rebuild), and nothing measured
# whether the resolver ever got to a row it had been handed. The key lock's
# `flock -n 9 || exit 0` was silent, a row the rung budget never reached got no
# line, and nothing paged.
#
# Cases:
#   W1-W12 bin/lib/handoff-watch.sh, driven directly with a pinned clock
#          (BHW_NOW) and a recording bin/lane-alert.sh.
#   T1-T4  the REAL bin/blocked-resolver.sh tick over conductor rows
#          (tests/lib/fixture-harness.sh), asserting on the log, the claim and
#          ack files and lane-alert's argv.
#   T5     BHW_BUILD_FLOOR_S is br_from_builds' own `-mmin +90` floor.
# R1-R3 (the REAL bin/review-rescue.sh BLOCK arm: its wording and its claim)
# are section 16 of tests/review-rescue-test.sh, which already carries the real
# git origin and worktree that arm cannot run without.
# Run from anywhere: tests/blocked-resolver-handoff-watch.bh-5125-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export HARNESS_TEST_SANDBOX=1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
LIB="$DIR/bin/lib/handoff-watch.sh"
[ -r "$LIB" ] || { bad "setup: $LIB is missing — nothing below can pass"; echo "blocked-resolver-handoff-watch.bh-5125: $PASS passed, $FAIL failed"; exit 1; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

# ============================================================================
# W. the lib, on its own. W <now> <cmd...> runs one call in a subshell with the
#    clock pinned, the way the lane runs it.
# ============================================================================
W_H="$T/w"
mkdir -p "$W_H/bin" "$W_H/logs"
cat > "$W_H/bin/lane-alert.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/w-alerts.txt"
exit "\$(cat "$T/w-alert-rc" 2>/dev/null || echo 0)"
EOF
chmod +x "$W_H/bin/lane-alert.sh"
WLOG="$W_H/logs/blocked-resolver.log"
W() { local at="$1"; shift
      ( HARNESS="$W_H" BHW_NOW="$at" BHW_TICK_AT="$at"
        . "$LIB" || exit 99
        "$@" ) ; }
WRESET() { scratch_rm "$W_H/state"; : > "$WLOG"; : > "$T/w-alerts.txt"; rm -f "$T/w-alert-rc"; }
CL="$W_H/state/blocked-resolver/handoffs/claims"
AK="$W_H/state/blocked-resolver/handoffs/acks"
PRU="https://github.com/o/tproj/pull/77"
PAGES() { grep -c -- '--severity critical --id br-handoff-silent' "$T/w-alerts.txt" 2>/dev/null; }

# --- W1: the first claim's first_at stands -----------------------------------
WRESET
W "$NOW" bhw_claim tproj TP-7 "$PRU" review-rescue 0 "first"
W "$((NOW + 600))" bhw_claim tproj TP-7 "$PRU" resolver:conductor 0 "second"
[ "$(cut -f1 "$CL/tproj-TP-7" 2>/dev/null)" = "$NOW" ] && [ "$(cut -f6 "$CL/tproj-TP-7")" = review-rescue ] \
  && ok "W1: a second claim keeps the first first_at and who" \
  || bad "W1: claim is '$(cat "$CL/tproj-TP-7" 2>/dev/null)'"

# --- W2: an acted ack closes the claim ---------------------------------------
W "$((NOW + 60))" bhw_ack tproj TP-7 "$PRU" acted
W "$((NOW + 120))" bhw_sweep drained
[ ! -e "$CL/tproj-TP-7" ] && ok "W2: an acted ack closes the claim" || bad "W2: the claim survived an acted ack"
[ "$(PAGES)" = 0 ] && ok "W2: nothing paged" || bad "W2: paged: $(cat "$T/w-alerts.txt")"

# --- W3: no ack, younger than the knob: one line, no page --------------------
WRESET
W "$NOW" bhw_claim tproj TP-7 "$PRU" review-rescue 0 "x"
W "$((NOW + 600))" bhw_sweep drained
[ "$(grep -c 'HANDOFF-WAIT tproj-TP-7: claimed by review-rescue 10m ago — not dispatched this tick: not a candidate' "$WLOG")" = 1 ] \
  && ok "W3: one HANDOFF-WAIT line naming the reason" || bad "W3: log is: $(cat "$WLOG")"
[ "$(PAGES)" = 0 ] && ok "W3: no page inside the window" || bad "W3: paged early: $(cat "$T/w-alerts.txt")"

# --- W4: no ack at 1800 s: exactly one page naming the id and url ------------
W "$((NOW + 1800))" bhw_sweep drained
[ "$(PAGES)" = 1 ] && ok "W4: exactly one critical br-handoff-silent page" || bad "W4: pages: $(cat "$T/w-alerts.txt")"
grep -q "tproj-TP-7 (review-rescue, $PRU)" "$T/w-alerts.txt" && ok "W4: the page names the id, who and url" \
  || bad "W4: the page does not name the claim: $(cat "$T/w-alerts.txt")"
[ "$(cut -f7 "$CL/tproj-TP-7" 2>/dev/null)" = "$((NOW + 1800))" ] && ok "W4: paged_at is stamped" \
  || bad "W4: paged_at is '$(cut -f7 "$CL/tproj-TP-7" 2>/dev/null)'"

# --- W5: the next sweep does not page it again --------------------------------
W "$((NOW + 2400))" bhw_sweep drained
[ "$(PAGES)" = 1 ] && ok "W5: a paged claim is not paged again" || bad "W5: pages: $(cat "$T/w-alerts.txt")"

# --- W6: dispatched / lock-held every tick: never paged -----------------------
for kind in dispatched lock-held; do
  WRESET
  W "$NOW" bhw_claim tproj TP-8 - review-rescue 0 "x"
  for s in 600 1200 1800 2400 3000 3600; do
    W "$((NOW + s))" bhw_ack tproj TP-8 - "$kind"
    W "$((NOW + s))" bhw_sweep drained
  done
  [ "$(PAGES)" = 0 ] && ok "W6: a claim acked $kind every tick is never paged" || bad "W6 $kind: paged: $(cat "$T/w-alerts.txt")"
  grep -q 'HANDOFF-WAIT tproj-TP-8' "$WLOG" && bad "W6 $kind: an acked tick wrote a HANDOFF-WAIT line: $(cat "$WLOG")" \
    || ok "W6: an acked ($kind) tick writes no HANDOFF-WAIT line"
done

# --- W7: not_before in the future: nothing until it has passed + the knob -----
WRESET
NB=$((NOW + 5400))
W "$NOW" bhw_claim tproj TP-9 - review-rescue "$NB" "x"
W "$((NOW + 3600))" bhw_sweep drained
[ ! -s "$WLOG" ] && [ "$(PAGES)" = 0 ] && ok "W7: before not_before: no line and no page" \
  || bad "W7: before not_before: log '$(cat "$WLOG")' alerts '$(cat "$T/w-alerts.txt")'"
W "$((NB + 1799))" bhw_sweep drained
[ "$(PAGES)" = 0 ] && ok "W7: not_before + 1799 s: not yet" || bad "W7: paged one second early"
W "$((NB + 1800))" bhw_sweep drained
[ "$(PAGES)" = 1 ] && ok "W7: not_before + 1800 s: paged" || bad "W7: not paged at not_before + 1800: $(cat "$T/w-alerts.txt")"

# --- W8: knob 0 never pages; a failed page is not stamped and is retried ------
WRESET
W "$NOW" bhw_claim tproj TP-10 - review-rescue 0 "x"
( export BR_HANDOFF_SILENT_PAGE_S=0; W "$((NOW + 7200))" bhw_sweep drained )
[ "$(PAGES)" = 0 ] && grep -q 'HANDOFF-WAIT tproj-TP-10' "$WLOG" && ok "W8: knob 0 writes the line and never pages" \
  || bad "W8: knob 0: log '$(cat "$WLOG")' alerts '$(cat "$T/w-alerts.txt")'"
echo 1 > "$T/w-alert-rc"
W "$((NOW + 1800))" bhw_sweep drained
[ "$(cut -f7 "$CL/tproj-TP-10")" = - ] && ok "W8: a failed page leaves paged_at unstamped" \
  || bad "W8: a failed page was stamped: $(cat "$CL/tproj-TP-10")"
rm -f "$T/w-alert-rc"
W "$((NOW + 2400))" bhw_sweep drained
[ "$(PAGES)" = 2 ] && [ "$(cut -f7 "$CL/tproj-TP-10")" = "$((NOW + 2400))" ] && ok "W8: the next sweep retries the page and stamps it" \
  || bad "W8: retry: pages=$(PAGES) claim=$(cat "$CL/tproj-TP-10")"

# --- W9: a resolver candidate's own claim goes once the source drops the row --
WRESET
W "$NOW" bhw_tick_begin
W "$NOW" bhw_claim tproj TP-11 - resolver:conductor 0 "x"
W "$NOW" bhw_seen tproj TP-11 -
W "$NOW" bhw_sweep drained
[ -e "$CL/tproj-TP-11" ] && ok "W9: a candidate claim on this tick's list stays" || bad "W9: the claim was dropped while still a candidate"
W "$((NOW + 600))" bhw_tick_begin
W "$((NOW + 600))" bhw_sweep drained
[ ! -e "$CL/tproj-TP-11" ] && ok "W9: a candidate claim the list no longer holds is retired, not paged" \
  || bad "W9: the claim outlived its candidate row"

# --- W10: one paged claim never mutes another's page (lead review lr-5160) --
# bin/lane-alert.sh counts a repeat of an OPEN id and does not send it. This
# stub models that: a call whose id is open goes to w10-counted, any other call
# opens the id and goes to w10-sent; --resolve closes it. A review-rescue claim
# whose record was fixed another way is never offered, so it is never acked and
# stays paged until BR_HANDOFF_MAX_AGE_SECS; a LATER silent hand-off must still
# page. TEST-CHANGE (review of 9251f18c3): the page is now ONE aggregated
# br-handoff-silent page per sweep, not one per claim, so W10 asserts the open
# page is resolved and sent again with the later claim, and is resolved for
# good only when no paged claim is left (it asserted per-claim ids before).
WRESET; : > "$T/w10-open"; : > "$T/w10-sent"; : > "$T/w10-counted"
cp "$W_H/bin/lane-alert.sh" "$T/w-lane-alert.keep"
cat > "$W_H/bin/lane-alert.sh" <<EOF
#!/bin/bash
id=""; res=0; prev=""
for a in "\$@"; do [ "\$prev" = --id ] && id="\$a"; [ "\$a" = --resolve ] && res=1; prev="\$a"; done
if [ "\$res" = 1 ]; then grep -vxF -- "\$id" "$T/w10-open" > "$T/w10-open.t"; mv "$T/w10-open.t" "$T/w10-open"; printf 'RESOLVE %s\n' "\$id" >> "$T/w10-sent"; exit 0; fi
if grep -qxF -- "\$id" "$T/w10-open"; then printf '%s\n' "\$*" >> "$T/w10-counted"; exit 0; fi
printf '%s\n' "\$id" >> "$T/w10-open"; printf '%s\n' "\$*" >> "$T/w10-sent"; exit 0
EOF
chmod +x "$W_H/bin/lane-alert.sh"
W "$NOW" bhw_claim tproj TP-20 "$PRU" review-rescue 0 "stale rescue"
W "$((NOW + 1800))" bhw_sweep drained
grep -q 'br-handoff-silent.*tproj-TP-20' "$T/w10-sent" && ok "W10: the first silent claim pages" || bad "W10: the first claim did not page: $(cat "$T/w10-sent")"
W "$((NOW + 3600))" bhw_claim tproj TP-21 - resolver:conductor 0 "later"
W "$((NOW + 3600))" bhw_tick_begin
W "$((NOW + 3600))" bhw_seen tproj TP-21 -
W "$((NOW + 5400))" bhw_tick_begin
W "$((NOW + 5400))" bhw_seen tproj TP-21 -
W "$((NOW + 5400))" bhw_sweep drained
[ "$(grep -c '^RESOLVE br-handoff-silent$' "$T/w10-sent")" = 1 ] && grep -q 'br-handoff-silent.*2 resolver hand-off.*tproj-TP-21' "$T/w10-sent" \
  && [ ! -s "$T/w10-counted" ] && ok "W10: a later silent hand-off re-sends the open page with the new count" \
  || bad "W10: the later page was muted (sent: $(cat "$T/w10-sent"); counted: $(cat "$T/w10-counted"))"
# The stale claim reaches BR_HANDOFF_MAX_AGE_SECS: the page stays open while
# TP-21 is still silent, and is resolved once TP-21 is acted on.
W "$((NOW + 172801))" bhw_tick_begin
W "$((NOW + 172801))" bhw_seen tproj TP-21 -
W "$((NOW + 172801))" bhw_sweep drained
[ ! -e "$CL/tproj-TP-20" ] && [ "$(grep -c '^RESOLVE' "$T/w10-sent")" = 1 ] && grep -qx 'br-handoff-silent' "$T/w10-open" \
  && ok "W10: an aged-out claim leaves the page open for the other" || bad "W10: sent: $(cat "$T/w10-sent"); open: $(cat "$T/w10-open")"
W "$((NOW + 172900))" bhw_ack tproj TP-21 - acted
W "$((NOW + 172900))" bhw_sweep drained
[ "$(grep -c '^RESOLVE br-handoff-silent$' "$T/w10-sent")" = 2 ] && ! grep -qx 'br-handoff-silent' "$T/w10-open" \
  && ok "W10: the page is resolved once no paged claim is left" || bad "W10: sent: $(cat "$T/w10-sent"); open: $(cat "$T/w10-open")"
cp "$T/w-lane-alert.keep" "$W_H/bin/lane-alert.sh"

# --- W11: a saturated hub — 665 silent claims make ONE page (review of 9251f18c3)
# The live hub: about 665 claims each tick, and a tick of about 3000 s. One
# page per sweep, naming the count and at most 10 claims, and at most 10 named
# HANDOFF-WAIT lines plus one summary line.
WT() { local tk="$1" at="$2"; shift 2
       ( HARNESS="$W_H" BHW_NOW="$at" BHW_TICK_AT="$tk"
         . "$LIB" || exit 99
         "$@" ) ; }
mk_claims() { local i; for i in $(seq "$1" "$2"); do bhw_claim tproj "SAT-$i" - review-rescue 0 "starved"; done; }
WRESET
W "$((NOW - 7200))" mk_claims 1 665
WT "$((NOW - 3000))" "$NOW" bhw_sweep tick-budget
[ "$(PAGES)" = 1 ] && ok "W11: 665 silent claims make one page" || bad "W11: $(PAGES) pages for 665 silent claims"
grep -q '665 resolver hand-off(s) silent' "$T/w-alerts.txt" && ok "W11: the page carries the count" || bad "W11: no count in the page: $(head -c 300 "$T/w-alerts.txt")"
nm=$(grep -o 'tproj-SAT-[0-9]*' "$T/w-alerts.txt" | sort -u | wc -l | tr -d ' ')
[ "$nm" -le 10 ] && [ "$nm" -ge 1 ] && ok "W11: the page names at most 10 claims" || bad "W11: the page names $nm claims"
nw=$(grep -c 'HANDOFF-WAIT' "$WLOG")
[ "$nw" -le 11 ] && grep -q 'HANDOFF-WAIT summary: 665 hand-off(s) not dispatched this tick' "$WLOG" \
  && ok "W11: the log is rate-limited ($nw HANDOFF-WAIT lines)" || bad "W11: $nw HANDOFF-WAIT lines: $(grep HANDOFF-WAIT "$WLOG" | tail -2)"
WT "$NOW" "$((NOW + 3000))" bhw_sweep tick-budget
[ "$(PAGES)" = 1 ] && ok "W11: no new silent claim, no new page" || bad "W11: re-paged with nothing new: $(PAGES)"

# --- W12: a claim made in the same tick is not silent at that tick's end -----
WRESET
T0=$NOW
W "$T0" bhw_claim tproj TP-30 - review-rescue 0 "same tick"
WT "$T0" "$((T0 + 3000))" bhw_sweep tick-budget
[ "$(PAGES)" = 0 ] && ok "W12: a claim made in this tick does not page at its end" || bad "W12: paged at once: $(cat "$T/w-alerts.txt")"
grep -q 'HANDOFF-WAIT tproj-TP-30' "$WLOG" && ok "W12: it still gets its HANDOFF-WAIT line" || bad "W12: no line: $(cat "$WLOG")"
WT "$((T0 + 3000))" "$((T0 + 6000))" bhw_sweep tick-budget
[ "$(PAGES)" = 1 ] && ok "W12: still undispatched one tick later: paged" || bad "W12: not paged a tick later: $(cat "$T/w-alerts.txt")"

# ============================================================================
# T. the REAL lane. tests/lib/fixture-harness.sh's whole-tick scratch harness,
#    with the hand-off lib installed the way the lane sources it.
# ============================================================================
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin" "$H/catalog"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
( cd "$DIR" && scratch_install_closure bin/lib/handoff-watch.sh "$H" ) >/dev/null || exit 1
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: br_event's twin lives in bin/lib/br/record.sh
# THE KEY LOCK IS REAL HERE. fx_br_harness puts a flock that always succeeds on
# PATH; T1 is about the one that does not.
rm -f "$T/fakebin/flock"
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
flag_sync() { [ -f "\${HARNESS:-/root/harness}/flags/\$1" ] && return 0; return 2; }
flag_active() { [ -f "\${HARNESS:-/root/harness}/flags/\$1" ]; }
_jobs_req() { JOBS_HTTP=""; printf '{}'; }
EOF
touch "$H/flags/fly-pool-tproj"
LOGF="$H/logs/blocked-resolver.log"
HCL="$H/state/blocked-resolver/handoffs/claims"
HAK="$H/state/blocked-resolver/handoffs/acks"
WHY="merge-failed-twice: gh pr merge refused"
ROWS() { : > "$H/state/merge-conductor/pr-state.tsv"
         for n in "$@"; do
           printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "o/tproj#$n" "$NOW" abc123 abc123 "$WHY" \
             "https://github.com/o/tproj/pull/$n" >> "$H/state/merge-conductor/pr-state.tsv"
         done; }
FRESH() { scratch_rm "$H/state/blocked-resolver"
          scratch_rm "$H/state/lane-gate"
          rm -f "$H/locks/"blocked-resolver-* "$H/flags/lane-off-"*
          : > "$LOGF"; : > "$T/lane-alert.txt"; : > "$T/queue.txt"; : > "$T/closed.txt"; : > "$T/run.log"; }
TPAGES() { grep -c -- '--severity critical --id br-handoff-silent' "$T/lane-alert.txt" 2>/dev/null; }

# --- T1: the key lock is held: the exit says so and acks lock-held -----------
FRESH
ROWS 9
mkdir -p "$H/locks"
LK="$H/locks/blocked-resolver-tproj-o-tproj-9.lock"
flock "$LK" sleep 60 & LPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do flock -n "$LK" true 2>/dev/null || break; sleep 0.2; done
BRENV=(BHW_NOW="$NOW")
RUN
kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
grep -q 'tproj/o-tproj-9: key lock held — a round for it is already running (locks/blocked-resolver-tproj-o-tproj-9.lock); not dispatched this tick' "$LOGF" \
  && ok "T1: the held key lock writes its line" || bad "T1: no key-lock line (log: $(tail -5 "$LOGF"))"
ls "$HAK"/*.lock-held >/dev/null 2>&1 && ok "T1: the claim has a lock-held ack" \
  || bad "T1: no lock-held ack (acks: $(ls "$HAK" 2>/dev/null | tr '\n' ' '))"

# --- T3: a rung ran: the claim is closed and never paged ---------------------
FRESH
ROWS 9
BRENV=(BHW_NOW="$NOW")
RUN
grep -q 'EVENT resolver_' "$LOGF" && ok "T3: the tick emitted a resolver event" \
  || bad "T3: no EVENT line, the case is vacuous (log: $(tail -5 "$LOGF"))"
[ -z "$(ls "$HCL" 2>/dev/null)" ] && ok "T3: the acted claim is closed" \
  || bad "T3: claims left: $(cat "$HCL"/* 2>/dev/null)"
BRENV=(BHW_NOW="$((NOW + 3600))")
RUN
[ "$(TPAGES)" = 0 ] && ok "T3: an acted hand-off never pages" || bad "T3: paged: $(cat "$T/lane-alert.txt")"

# --- T2: budget starvation: a line every tick, then one page ------------------
# BR_PER_TICK=0 spends the budget before the first row, which is the starved
# row's whole life on a saturated lane: offered every tick, reached by none.
FRESH
ROWS 9
BRENV=(BHW_NOW="$NOW" BR_PER_TICK=0)
RUN
grep -q 'HANDOFF-WAIT tproj-TK-9: claimed by resolver:conductor 0m ago — not dispatched this tick: tick stopped at budget before reaching it' "$LOGF" \
  && ok "T2: the unreached row gets a HANDOFF-WAIT line naming the budget" \
  || bad "T2: no budget HANDOFF-WAIT line (log: $(grep -v 'github auth' "$LOGF" | tail -6))"
[ "$(TPAGES)" = 0 ] && ok "T2: no page on the first starved tick" || bad "T2: paged at once: $(cat "$T/lane-alert.txt")"
BRENV=(BHW_NOW="$((NOW + 1200))" BR_PER_TICK=0)
RUN
[ "$(grep -c 'HANDOFF-WAIT tproj-TK-9: claimed by resolver:conductor 20m ago .*tick stopped at budget' "$LOGF")" = 1 ] \
  && ok "T2: the next starved tick says so again" || bad "T2: no second HANDOFF-WAIT line (log: $(grep HANDOFF "$LOGF"))"
[ "$(TPAGES)" = 0 ] && ok "T2: no page at 20 min" || bad "T2: paged at 20 min: $(cat "$T/lane-alert.txt")"
BRENV=(BHW_NOW="$((NOW + 1800))" BR_PER_TICK=0)
RUN
[ "$(TPAGES)" = 1 ] && ok "T2: one page once the row sat 1800 s unreached" \
  || bad "T2: pages=$(TPAGES) (alerts: $(cat "$T/lane-alert.txt"); log: $(grep HANDOFF "$LOGF" | tail -3))"
grep -q 'tproj-TK-9 (resolver:conductor, https://github.com/o/tproj/pull/9)' "$T/lane-alert.txt" \
  && ok "T2: the page names the starved hand-off" || bad "T2: the page does not name TK-9: $(cat "$T/lane-alert.txt")"
BRENV=(BHW_NOW="$((NOW + 2400))" BR_PER_TICK=0)
RUN
[ "$(TPAGES)" = 1 ] && ok "T2: the next tick does not page again" || bad "T2: re-paged: $(cat "$T/lane-alert.txt")"
# The row is reached at last: a rung runs, the claim closes, the open page resolves.
BRENV=(BHW_NOW="$((NOW + 3000))")
RUN
[ -z "$(ls "$HCL" 2>/dev/null)" ] && ok "T2: the reached row's claim is closed" || bad "T2: claims left: $(cat "$HCL"/* 2>/dev/null)"
grep -q -- '--resolve --id br-handoff-silent' "$T/lane-alert.txt" && ok "T2: the page is resolved once nothing paged is open" \
  || bad "T2: no resolve sent (alerts: $(cat "$T/lane-alert.txt"))"

# --- T4: a held project: the reason is said, and nothing pages ---------------
FRESH
ROWS 9
( cd "$DIR" && scratch_install_closure bin/lib/lane-gate.sh "$H" ) >/dev/null || exit 1
# shellcheck source=tests/lib/rendered.sh
. "$DIR/tests/lib/rendered.sh" || exit 1
cp "$(rendered_registry)" "$H/catalog/lanes.json" || exit 1
touch "$H/flags/lane-off-blocked-resolver-tproj"
BRENV=(BHW_NOW="$NOW" LANE_GATE_NOW="$NOW")
RUN
grep -q 'tproj: held — flags/lane-off-blocked-resolver-tproj' "$LOGF" && ok "T4: the project is held (the gate is live)" \
  || bad "T4: the project hold never fired, the case is vacuous (log: $(tail -4 "$LOGF"))"
grep -q 'HANDOFF-WAIT tproj-TK-9: .*not dispatched this tick: project held' "$LOGF" \
  && ok "T4: the HANDOFF-WAIT line says project held" || bad "T4: no project-held line (log: $(grep HANDOFF "$LOGF"))"
BRENV=(BHW_NOW="$((NOW + 3600))" LANE_GATE_NOW="$((NOW + 3600))")
RUN
[ "$(TPAGES)" = 0 ] && ok "T4: a held project's hand-off never pages" || bad "T4: paged: $(cat "$T/lane-alert.txt")"
rm -f "$H/flags/lane-off-blocked-resolver-tproj"

# ============================================================================
# T5. the floor the lib mirrors is the floor br_from_builds applies.
# ============================================================================
# BH-6517: br_from_builds moved to bin/lib/br/discovery.sh; read the corpus.
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$DIR" "$T/br-corpus.sh" || exit 1
BFB=$(awk '/^br_from_builds\(\) \{/{f=1} f{print} f&&/^}$/{exit}' "$T/br-corpus.sh")
[ -n "$BFB" ] || bad "T5: br_from_builds is not defined in the resolver corpus"
if [ -n "$BFB" ]; then
  grep -qF -- '-mmin +90' <<<"$BFB" && grep -qF -- '-gt 5400' <<<"$BFB" \
    && ok "T5: br_from_builds still floors a record at 90 min / 5400 s" \
    || bad "T5: br_from_builds' floor moved — BHW_BUILD_FLOOR_S must move with it"
fi
got=$( . "$LIB"; printf '%s' "$BHW_BUILD_FLOOR_S" )
[ "$got" = 5400 ] && ok "T5: BHW_BUILD_FLOOR_S is 5400" || bad "T5: BHW_BUILD_FLOOR_S is '$got'"


echo "blocked-resolver-handoff-watch.bh-5125: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
