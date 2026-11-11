#!/bin/bash
# tests/br-retire-closed.bh-9369-test.sh — BH-9369 fix 1: a park whose PR is
# closed or merged on GitHub is retired in the pre-pass, from ONE batched read
# of the repo's closed pull list per project per tick, and is skipped in
# discovery from the next tick on.
#
# THE BUG (hub, 2026-11-09). project-6#289 was merged and its park stayed in
# the candidate list, OVERDUE and offered first on every tick, for 38,960 min.
# br_prepass retired a row only from its record (br_finished) and had no PR
# state input.
#
#   R1  merged park (iron-law, parked 38,960 min): tick 1 retired=1, one
#       resolver_retired ... merged line, no OVERDUE line, not dispatched;
#       tick 2 retired_skipped=1, no new event line
#   R2  closed-unmerged park (conflict): the same, word `closed`
#   R3  negatives, never retired: open PR; #2890 with #289 closed; another
#       repo's url; a reopened PR (in the open list); a closed-unmerged PR while
#       the open list is unreadable (a merged one still retires); a rebuild-*
#       reason and a url `-` (function cases)
#   R4  page 1 answers HTTP 500: the store and watermark are unchanged, one
#       line, and a stored retire still applies
#   R5  round trip: tick 2 reads exactly 1 page (the watermark stop), and the
#       retired flag of tick 1 survives the merge
#   R6  prune: a row closed 100 days ago is gone after a rewrite at KEEP_DAYS=90
#   R7  knobs: BR_CLOSED_PR_MAX_PAGES=0 retires nothing and reads nothing; a
#       non-number falls back to the default with one line
#   R8  paging: a first read (no watermark) pages until a short page; a full
#       page whose oldest item is older than the watermark - 600 s stops the
#       read; a page-2 error keeps page 1's rows and leaves the watermark; an
#       answer that is not a list is one line and reads nothing more
#   R9  observe mode says WOULD, writes no event and no retired mark
#
# WHAT IS DRIVEN. R1-R7 run the real bin/blocked-resolver.sh end to end against
# a scratch $HARNESS (the rig of tests/blocked-resolver-overdue.bh-7555-test.sh).
# No vendor is called (BH-7563): gh is a local stub that answers the closed
# list from fixture JSON and records every call, GH_TOKEN is empty.
# Run from anywhere: tests/br-retire-closed.bh-9369-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
ISO() { date -u -d "@$1" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
mkdir -p "$H/bin/blocked-resolver.d"
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" 2>/dev/null || true
# The fragment under test, named by its rooted path so the orphan check sees it.
FRAG="$DIR/bin/blocked-resolver.d/bh-9369-closed-pr-retire.sh"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
for L in bin/lib/gh-pr-list.sh bin/lib/merge-conductor-lib.sh bin/lib/rebuild-ledger.sh \
         bin/lib/hold.sh bin/lib/gh-rest.sh bin/lib/br/opt/profile.sh $(cd "$DIR" && printf "%s " bin/lib/mc/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
chmod +x "$H/bin/"*.sh
{ printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n'; } > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p1
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf 'call %s %s %s\n' "\$1" "\$2" "\$5" >> "$T/agent.txt"
printf 'the reasoning\n%s\n' "\${ADJ_VERDICT:-REJECT}" > "\$5"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

# THE gh STUB. The closed pull list is answered here, first arm: page k is
# $T/closed-<k>.json (default []), $T/st-closed sets the status, and every
# read is one line in $T/closedreads.txt. $T/st-closed-<k> sets one page's status. Everything else is the shared stub.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X GET"*"pulls?state=closed"*)
    printf '%s\n' "\$*" >> "$T/closedreads.txt"
    K=\$(printf '%s' "\$*" | sed -nE 's#.*[?&]page=([0-9]+).*#\1#p')
    GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"
    S=\$(cat "$T/st-closed-\$K" 2>/dev/null || _ghs_st closed 200)
    _ghs_send "\$S" "\$(cat "$T/closed-\$K.json" 2>/dev/null || echo '[]')"
    exit 0 ;;
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) echo '[]' ;;
  *"repos/"*"/issues/"*) echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
  *"pr close"*)   printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) exit 0 ;;
  *"--json state"*) echo OPEN ;;
  *"/pulls/"*)             echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/br-ssh"; chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-p1"

ROWS="$H/state/merge-conductor/pr-state.tsv"
ST="$H/state/blocked-resolver"
STORE="$ST/.closed-prs-p1.tsv"
LOGF="$H/logs/blocked-resolver.log"
BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
ROWADD() { printf '%s\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$ROWS"; }
LOG() { cat "$LOGF" 2>/dev/null; }
LASTTICK() { grep 'tick: candidates=' "$LOGF" | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
LFIELD() { LASTTICK | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
LASTPROF() { grep ' prof: ' "$LOGF" | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
PFIELD() { LASTPROF | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
NLINES() { grep -c -- "$1" "$LOGF" 2>/dev/null; }
# A row was DISPATCHED when the rung loop logged a line for its key.
# The candidate key of conductor row o/p1#<n> is o-p1-<n>; a dispatch is its `-> <rung>` line.
DISPATCHED() { grep -qE "p1/o-p1-$1 \[[^]]*\] -> " "$LOGF"; }
OVERDUE_OF() { grep 'OVERDUE' "$LOGF" | grep -c -- "p1/o-p1-$1 "; }
NCLOSEDREADS() { grep -c . "$T/closedreads.txt" 2>/dev/null; }
# CPR <num> <merged|closed> <closed-age-secs> [updated-age-secs] — one closed-list item.
CPR() {
  local m=null; [ "$2" = merged ] && m="\"$(ISO $((NOW - $3)))\""
  jq -nc --argjson n "$1" --arg c "$(ISO $((NOW - $3)))" --arg u "$(ISO $((NOW - ${4:-$3})))" --argjson m "$m" \
    '{number:$n, html_url:("https://github.com/o/p1/pull/"+($n|tostring)), state:"closed",
      merged_at:$m, closed_at:$c, updated_at:$u}'
}
OPR() { # OPR <num> — one open-list item (an author harness_pr_list keeps)
  jq -nc --argjson n "$1" --arg u "$(ISO $((NOW - 600)))" \
    '{number:$n, html_url:("https://github.com/o/p1/pull/"+($n|tostring)), title:"t", body:"",
      head:{sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", ref:("ticket/ts-"+($n|tostring))}, base:{ref:"main"},
      draft:false, user:{login:"operator", type:"User"}, created_at:$u, updated_at:$u,
      merged_at:null, closed_at:null, labels:[], state:"open"}'
}
CLEAN() { scratch_rm "$ST" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff-released" 2>/dev/null
          scratch_rm "$H/builds" 2>/dev/null; mkdir -p "$H/builds"
          rm -f "$T"/closed-*.json "$T/st-closed" "$T"/st-closed-* "$H/flags/blocked-resolver-observe" "$T/openprs" "$T/st-prlist" "$H/logs/ALERTS.log"
          : > "$T/gh.txt"; : > "$T/closedreads.txt"; : > "$T/alerts.txt"; : > "$T/agent.txt"
          : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$LOGF"; : > "$ROWS"; BRENV=(); }

IRONLAW="iron-law (8 hit(s))"
CONFLICT="conflict-unresolvable: CONFLICT (content): Merge conflict in src/a.ts"
U="https://github.com/o/p1/pull"
[ -f "$FRAG" ] || bad "0: bin/blocked-resolver.d/bh-9369-closed-pr-retire.sh must exist"

# ============================================================================
# R1 + R2 + R3 (driver). THE BUG. #289 merged, parked 38,960 min; #290 closed
#     unmerged; #291 open; #2890 open while #289 is closed (the near miss);
#     #292 closed but reopened (in the open list); another repo's #289.
# ============================================================================
CLEAN
ROWADD "o/p1#289"  "$((NOW - 38960 * 60))" "$IRONLAW"  "$U/289"
ROWADD "o/p1#290"  "$((NOW - 7200))"       "$CONFLICT" "$U/290"
ROWADD "o/p1#291"  "$((NOW - 7200))"       "$CONFLICT" "$U/291"
ROWADD "o/p1#2890" "$((NOW - 7200))"       "$CONFLICT" "$U/2890"
ROWADD "o/p1#292"  "$((NOW - 7200))"       "$CONFLICT" "$U/292"
ROWADD "o/p1#293"  "$((NOW - 7200))"       "$CONFLICT" "https://github.com/other/repo/pull/289"
{ CPR 289 merged 3600; CPR 290 closed 3600; CPR 292 closed 7200; } | jq -s . > "$T/closed-1.json"
{ OPR 291; OPR 2890; OPR 292; } | jq -s . > "$T/openprs"
BRENV=(BR_PER_TICK=10 BR_PER_TICK_P1=10)
RUN p1
[ "$(LFIELD retired)" = 2 ] && ok || bad "R1: THE BUG: tick 1 must retire the merged #289 and the closed #290 (tick: $(LASTTICK))"
[ "$(NLINES 'EVENT resolver_retired .*PR is merged')" = 1 ] && ok \
  || bad "R1: one resolver_retired line that names the word merged (log: $(LOG | grep -E 'EVENT|retire'))"
[ "$(NLINES 'EVENT resolver_retired .*PR is closed')" = 1 ] && ok \
  || bad "R2: one resolver_retired line that names the word closed (log: $(LOG | grep -E 'EVENT|retire'))"
[ "$(OVERDUE_OF 289)" = 0 ] && ok \
  || bad "R1: no OVERDUE line for #289 (log: $(LOG | grep OVERDUE))"
DISPATCHED 289 && bad "R1: the retired #289 must not be dispatched (log: $(LOG | grep -- '-289'))" || ok
DISPATCHED 290 && bad "R2: the retired #290 must not be dispatched" || ok
for N in 291 2890 292 293; do
  DISPATCHED "$N" && ok || bad "R3: #$N must still be dispatched (log: $(LOG | grep -- "-$N" | head -3))"
done
[ "$(NLINES 'EVENT resolver_retired')" = 2 ] && ok \
  || bad "R3: only the two closed rows are retired (log: $(LOG | grep 'EVENT resolver_retired'))"
[ "$(NCLOSEDREADS)" = 1 ] && ok || bad "R1: one closed-list read on tick 1 (reads: $(cat "$T/closedreads.txt"))"
[ -s "$STORE" ] && head -1 "$STORE" | grep -qE '^#wm	[0-9]{4}-' && ok || bad "R5: the store has a watermark line ($(head -2 "$STORE" 2>/dev/null))"
grep -qE '^289	merged	[^	]+	1$' "$STORE" && ok || bad "R5: #289 is stored retired ($(cat "$STORE" 2>/dev/null))"
grep -qE '^292	closed	[^	]+	0$' "$STORE" && ok || bad "R3: the reopened #292 is stored, not retired ($(cat "$STORE" 2>/dev/null))"
# The rungs of the open rows page about the fixture's missing token; this
# change adds no alert line of its own.
[ "$(cat "$H/logs/ALERTS.log" "$T/alerts.txt" 2>/dev/null | grep -ciE 'closed-PR|retire')" = 0 ] && ok \
  || bad "R1: no alert line about the closed-PR read or a retire ($(cat "$H/logs/ALERTS.log" "$T/alerts.txt" 2>/dev/null))"

# R1 tick 2 + R5: the watermark stops the read after 1 page, the retired rows
# are skipped in discovery (retired_skipped=2), and no new event line is said.
: > "$LOGF"; : > "$T/closedreads.txt"
CPR 300 closed 60 60 | jq -s . > "$T/closed-1.json"
RUN p1
[ "$(NCLOSEDREADS)" = 1 ] && ok || bad "R5: tick 2 reads exactly 1 page (reads: $(cat "$T/closedreads.txt"))"
[ "$(PFIELD retired_skipped)" = 2 ] && ok || bad "R1: tick 2 retired_skipped=2 (prof: $(LASTPROF); tick: $(LASTTICK))"
[ "$(NLINES 'EVENT resolver_retired')" = 0 ] && ok || bad "R1: tick 2 says no new event line (log: $(LOG | grep EVENT))"
[ "$(OVERDUE_OF 289)" = 0 ] && ok || bad "R1: tick 2 has no OVERDUE line for #289"
grep -qE '^289	merged	[^	]+	1$' "$STORE" && grep -qE '^300	closed	' "$STORE" && ok \
  || bad "R5: the tick-1 retired flag survives the tick-2 merge, and #300 is added ($(cat "$STORE"))"

# ============================================================================
# R3 (driver): the open list is unreadable. A closed-unmerged PR waits (it may
#     have been reopened); a merged PR still retires (a merge is final).
# ============================================================================
CLEAN
ROWADD "o/p1#401" "$((NOW - 7200))" "$CONFLICT" "$U/401"
ROWADD "o/p1#402" "$((NOW - 7200))" "$CONFLICT" "$U/402"
{ CPR 401 merged 3600; CPR 402 closed 3600; } | jq -s . > "$T/closed-1.json"
echo 500 > "$T/st-prlist"
BRENV=(BR_PER_TICK=10 BR_PER_TICK_P1=10)
RUN p1
[ "$(NLINES 'EVENT resolver_retired p1/p1-TK-401 ')" = 1 ] && ok \
  || bad "R3: a merged PR retires while the open list is unreadable (log: $(LOG | grep -E 'EVENT|401' | head -5))"
[ "$(NLINES 'EVENT resolver_retired p1/p1-TK-402 ')" = 0 ] && DISPATCHED 402 && ok \
  || bad "R3: a closed-unmerged PR is not retired while the open list is unreadable"

# ============================================================================
# R4. Page 1 answers HTTP 500. The store and the watermark are unchanged, one
#     line says so, and the stored retire still applies.
# ============================================================================
CLEAN
mkdir -p "$ST"
printf '#wm\t%s\n501\tmerged\t%s\t0\n' "$(ISO $((NOW - 300)))" "$(ISO $((NOW - 3600)))" > "$STORE"
cp "$STORE" "$T/store-before"
ROWADD "o/p1#501" "$((NOW - 7200))" "$CONFLICT" "$U/501"
echo 500 > "$T/st-closed"
echo '[]' > "$T/openprs"
BRENV=(BR_PER_TICK=10 BR_PER_TICK_P1=10)
RUN p1
[ "$(NLINES 'closed-PR read for o/p1 stopped at page 1 (HTTP 500')" = 1 ] && ok \
  || bad "R4: one line names the failed page (log: $(LOG | grep -i closed-PR))"
[ "$(NLINES 'EVENT resolver_retired p1/p1-TK-501 ')" = 1 ] && ok \
  || bad "R4: the stored merged row still retires #501 (log: $(LOG | grep -E 'EVENT|501' | head -4))"
[ "$(head -1 "$STORE")" = "$(head -1 "$T/store-before")" ] && ok \
  || bad "R4: the watermark is unchanged ($(head -1 "$STORE") vs $(head -1 "$T/store-before"))"
[ "$(grep -ci 'closed-PR' "$H/logs/ALERTS.log" "$T/alerts.txt" 2>/dev/null | awk -F: '{s+=$NF} END {print s+0}')" = 0 ] && ok \
  || bad "R4: a failed read writes no ALERTS line"

# ============================================================================
# R6. THE PRUNE. A row closed 100 days ago is gone after a rewrite at the
#     default KEEP_DAYS=90; a row closed 10 days ago stays. With KEEP_DAYS=0
#     both stay.
# ============================================================================
CLEAN
mkdir -p "$ST"
printf '#wm\t%s\n601\tmerged\t%s\t1\n602\tclosed\t%s\t1\n' "$(ISO $((NOW - 300)))" \
  "$(ISO $((NOW - 100 * 86400)))" "$(ISO $((NOW - 10 * 86400)))" > "$STORE"
CPR 603 closed 60 60 | jq -s . > "$T/closed-1.json"
echo '[]' > "$T/openprs"
ROWADD "o/p1#699" "$((NOW - 7200))" "$CONFLICT" "$U/699"
RUN p1
grep -q '^601	' "$STORE" && bad "R6: the 100-day row must be pruned ($(cat "$STORE"))" || ok
grep -q '^602	' "$STORE" && grep -q '^603	' "$STORE" && ok || bad "R6: the 10-day row and the new row stay ($(cat "$STORE"))"
printf '#wm\t%s\n601\tmerged\t%s\t1\n' "$(ISO $((NOW - 300)))" "$(ISO $((NOW - 100 * 86400)))" > "$STORE"
BRENV=(BR_CLOSED_PR_KEEP_DAYS=0)
RUN p1
grep -q '^601	' "$STORE" && ok || bad "R6: KEEP_DAYS=0 keeps every row ($(cat "$STORE"))"

# ============================================================================
# R7. THE KNOBS. MAX_PAGES=0: no read, nothing retired. A non-number: the
#     default, with one line.
# ============================================================================
CLEAN
ROWADD "o/p1#701" "$((NOW - 7200))" "$CONFLICT" "$U/701"
CPR 701 merged 3600 | jq -s . > "$T/closed-1.json"
echo '[]' > "$T/openprs"
BRENV=(BR_CLOSED_PR_MAX_PAGES=0)
RUN p1
[ "$(NCLOSEDREADS)" = 0 ] && ok || bad "R7: MAX_PAGES=0 reads nothing (reads: $(cat "$T/closedreads.txt"))"
[ "$(NLINES 'EVENT resolver_retired')" = 0 ] && ok || bad "R7: MAX_PAGES=0 retires nothing"
: > "$LOGF"
BRENV=(BR_CLOSED_PR_MAX_PAGES=abc)
RUN p1
[ "$(NLINES "BR_CLOSED_PR_MAX_PAGES is 'abc', not a number — the fallback 30 is used")" = 1 ] && ok \
  || bad "R7: a non-number knob says so once (log: $(LOG | grep -i MAX_PAGES))"
[ "$(NLINES 'EVENT resolver_retired p1/p1-TK-701 ')" = 1 ] && ok \
  || bad "R7: with the fallback, #701 is retired"

# ============================================================================
# R8. PAGING. FULL <first-n> — a full page of 100 closed items, #<n>..#<n+99>,
#     updated from 100 s ago (the newest) down to 100 + 99*60 s ago.
# ============================================================================
FULL() { jq -nc --argjson b "$1" --argjson now "$NOW" \
  '[range(0;100) | {number:($b+.), html_url:("https://github.com/o/p1/pull/"+(($b+.)|tostring)), state:"closed",
     merged_at:null, closed_at:(($now - 100 - .*60) | todate), updated_at:(($now - 100 - .*60) | todate)}]'; }
CLEAN
FULL 800 > "$T/closed-1.json"
CPR 950 merged 9000 | jq -s . > "$T/closed-2.json"
echo '[]' > "$T/openprs"
ROWADD "o/p1#950" "$((NOW - 7200))" "$CONFLICT" "$U/950"
RUN p1
[ "$(NCLOSEDREADS)" = 2 ] && ok || bad "R8: a first read pages until the short page (reads: $(NCLOSEDREADS))"
[ "$(grep -c '^[0-9]' "$STORE")" = 101 ] && ok || bad "R8: both pages are stored ($(grep -c '^[0-9]' "$STORE") rows)"
[ "$(NLINES 'EVENT resolver_retired p1/p1-TK-950 ')" = 1 ] && ok || bad "R8: the page-2 PR is retired"
[ "$(head -1 "$STORE")" = "#wm	$(ISO $((NOW - 100)))" ] && ok || bad "R8: the watermark is the newest updated_at ($(head -1 "$STORE"))"
# The watermark stop on a FULL page: tick 2's page 1 is full and its oldest
# item is older than the watermark - 600 s, so page 2 is never read.
: > "$T/closedreads.txt"; : > "$LOGF"
RUN p1
[ "$(NCLOSEDREADS)" = 1 ] && ok || bad "R8: a full page past the watermark stops the read (reads: $(NCLOSEDREADS))"
# A page-2 error with no watermark: page 1's rows are kept, no watermark is
# written, one line names page 2.
CLEAN
FULL 800 > "$T/closed-1.json"
echo 502 > "$T/st-closed-2"
echo '[]' > "$T/openprs"
ROWADD "o/p1#850" "$((NOW - 7200))" "$CONFLICT" "$U/850"
RUN p1
[ "$(NLINES 'closed-PR read for o/p1 stopped at page 2 (HTTP 502')" = 1 ] && ok \
  || bad "R8: one line names page 2 (log: $(LOG | grep -i closed-PR))"
[ "$(grep -c '^[0-9]' "$STORE" 2>/dev/null)" = 100 ] && [ "$(head -1 "$STORE")" = "#wm	" ] && ok \
  || bad "R8: page 1's rows are kept and no watermark is set ($(head -1 "$STORE" 2>/dev/null); $(grep -c '^[0-9]' "$STORE" 2>/dev/null) rows)"
[ "$(NLINES 'EVENT resolver_retired p1/p1-TK-850 ')" = 1 ] && ok || bad "R8: a page-1 PR still retires"
# An answer that is not a list.
CLEAN
echo '{"message":"Moved Permanently"}' > "$T/closed-1.json"
echo '[]' > "$T/openprs"
ROWADD "o/p1#860" "$((NOW - 7200))" "$CONFLICT" "$U/860"
RUN p1
[ "$(NLINES 'closed-PR read for o/p1 stopped at page 1 (the answer is not a PR list)')" = 1 ] && ok \
  || bad "R8: a non-list answer is one line (log: $(LOG | grep -i closed-PR))"
[ "$(NCLOSEDREADS)" = 1 ] && [ ! -e "$STORE" ] && ok || bad "R8: no more pages are read and no store is written"

# ============================================================================
# R9. OBSERVE MODE. WOULD, no event line, no retired mark.
# ============================================================================
CLEAN
touch "$H/flags/blocked-resolver-observe"
CPR 901 merged 3600 | jq -s . > "$T/closed-1.json"
echo '[]' > "$T/openprs"
ROWADD "o/p1#901" "$((NOW - 7200))" "$CONFLICT" "$U/901"
RUN p1
[ "$(NLINES 'p1/o-p1-901 \[conflict-unresolvable\]: WOULD retire — PR is merged — observe mode')" = 1 ] && ok \
  || bad "R9: observe mode says WOULD (log: $(LOG | grep -E 'WOULD|901' | head -3))"
[ "$(NLINES 'EVENT resolver_retired')" = 0 ] && ok || bad "R9: observe mode writes no event line"
grep -qE '^901	merged	[^	]+	0$' "$STORE" && ok || bad "R9: observe mode writes no retired mark ($(cat "$STORE" 2>/dev/null))"
rm -f "$H/flags/blocked-resolver-observe"

# ============================================================================
# R3 (function). bcr_is_closed, sourced from the fragment, for the rows the
#     conductor fixture cannot produce: a rebuild-* reason and a url `-`.
# ============================================================================
(
  say() { :; }
  # shellcheck source=bin/blocked-resolver.d/bh-9369-closed-pr-retire.sh
  . "$FRAG" || exit 1
  declare -A _BCR_CLOSED=(["$U/289"]=closed ["$U/290"]=merged) _BCR_OPEN=() _BCR_OPENBAD=()
  r=""
  bcr_is_closed "$U/289" conflict-unresolvable && r="${r}a"
  bcr_is_closed "$U/289" rebuild-conflict || r="${r}b"
  bcr_is_closed "-" conflict-unresolvable || r="${r}c"
  bcr_is_closed "$U/289/files" conflict-unresolvable || r="${r}d"
  bcr_is_closed "$U/2890" conflict-unresolvable || r="${r}e"
  _BCR_OPENBAD["o/p1"]=1
  bcr_is_closed "$U/289" conflict-unresolvable || r="${r}f"
  bcr_is_closed "$U/290" conflict-unresolvable && [ "$_BCR_WORD" = merged ] && r="${r}g"
  [ "$r" = abcdefg ]
) && ok || bad "R3: bcr_is_closed decision table (rebuild-*, url -, /files, #2890, open list unreadable)"

echo "br-retire-closed.bh-9369: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
