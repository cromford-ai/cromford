#!/bin/bash
# tests/blocked-resolver-overdue.bh-7555-test.sh — BH-7555: a park that has
# waited BR_UNTOUCHED_ALERT_MIN/2 is offered first in its project's run.
#
# THE CENSUS (project-4, 2026-10-19). An iron-law park (an adjudication, cost 1)
# sorted behind every cost-0 row of its project on every tick. The cheap rows
# came back every tick and spent BR_PER_TICK or BR_TICK_MAX_SECS first, so the
# iron-law row went to br_note_untouched, the br-untouched alert fired, and the
# next tick built the same order again. One park waited 2,277 minutes.
#
#   O1  three fresh mechanical parks and one iron-law park 70 min old (a refused
#       carry: the record holds an ACCEPT for an older head only), BR_PER_TICK=2:
#       the iron-law row is dispatched FIRST, one OVERDUE line, visited=[p1]
#   O2  the same row 20 min old (under the bar): today's cost order
#   O3  a hotfix row stays ahead of an overdue row (driven through the function)
#   O4  two overdue rows (200 and 90 min) and one fresh row: oldest first, then
#       the next, then the fresh row; rows in = rows out (driver and function)
#   O5  parked `-`, `abc` and a future epoch are never promoted, never lost
#   O6  BR_UNTOUCHED_ALERT_MIN=0 and BR_OPT_OFF=bh-7555-overdue-first: today's
#       order, no OVERDUE line
#   O7  the tick-budget path: the one row a budget-bound tick looks at is the
#       overdue iron-law row
#   O8  fail-open: a rank lookup that fails mid-stream leaves every row in the
#       input order
#   O9  a carried ACCEPT (the conductor row is not BLOCKED_HUMAN) gives the
#       resolver no candidate: no adjudication is bought for it
#   O10 the head-of-line limit: five overdue rows and one fresh cheap row,
#       BR_PER_TICK=4: the four oldest overdue rows are dispatched, and the
#       fifth (the youngest) is the untouched row the tick line ages
#       (oldest_untouched=)
#
# WHAT IS DRIVEN. O1, O2, O4, O6, O7, O9 and O10 run the real bin/blocked-resolver.sh
# end to end against a scratch $HARNESS (the rig of
# tests/blocked-resolver-prepass.bh-1457-test.sh): real conductor rows, a
# recorded jobs client, a recorded bin/agent-call.sh, a recorded
# bin/lane-alert.sh, a gh stub. The rung ORDER is read off the `-> <action>`
# dispatch lines the run wrote. O3, O4, O5 and O8 also call br_overdue_first
# directly, sourced from the fragment, for the edge rows the conductor fixture
# cannot produce. No vendor is called (BH-7563): gh, the jobs client and the
# agent are local fakes, and GH_TOKEN is empty.
# Run from anywhere: tests/blocked-resolver-overdue.bh-7555-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh): every park
# age below is derived from it.
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
# The fragment under test travels with the lane, as harness-sync installs it.
mkdir -p "$H/bin/blocked-resolver.d"
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" 2>/dev/null || true
FRAG="$DIR/bin/blocked-resolver.d/bh-7555-overdue-first.sh"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
# The libs the lane reads through, each with whatever it sources itself.
for L in bin/lib/gh-pr-list.sh bin/lib/merge-conductor-lib.sh bin/lib/rebuild-ledger.sh \
         bin/lib/hold.sh bin/lib/gh-rest.sh $(cd "$DIR" && printf "%s " bin/lib/mc/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
chmod +x "$H/bin/"*.sh
{ printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n'; } > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
# BH-1510.1: the resolver's models are model_routes rows.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p1
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf 'call %s %s %s\n' "\$1" "\$2" "\$5" >> "$T/agent.txt"
printf 'the reasoning, such as it was\n%s\n' "\${ADJ_VERDICT:-REJECT}" > "\$5"
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

# The gh stub (the prepass rig's). $T/slowgh makes every gh call cost a second,
# so O7's tick is over its wall budget after the first row it looks at.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
[ -e "$T/slowgh" ] && sleep 1
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) cat "$T/comments-\$N.json" 2>/dev/null || echo '[]' ;;
  *"repos/"*"/issues/"*)
    cat "$T/issue-\$N.json" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *"pr close"*)   printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) printf '%s\n' "\$*" >> "$T/comments.txt"; exit 0 ;;
  *"--json state"*) echo OPEN ;;
  *"/pulls/"*)             echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
# NO REAL CREDENTIAL REACHES THIS RUN.
export GH_TOKEN=""

cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-p1"

ROWS="$H/state/merge-conductor/pr-state.tsv"
ST="$H/state/blocked-resolver"
BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
# ROWADD <key> <since> <why> <url> [state] [head] — one conductor hand-off row.
ROWADD() { printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' \
             "$1" "${5:-BLOCKED_HUMAN}" "$2" "${6:-abc123}" "${6:-abc123}" "$3" "$4" >> "$ROWS"; }
LOG() { cat "$H/logs/blocked-resolver.log" 2>/dev/null; }
LASTTICK() { grep 'tick: candidates=' "$H/logs/blocked-resolver.log" \
             | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
LFIELD() { LASTTICK | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
# ORDER — the rungs this run DISPATCHED, in the order it dispatched them.
ORDER() { grep -oE '\-> (mechanical|regen|fix-round|rebuild-fresh|rebuild-retry|adjudicate|re-review|abandon-rebuild)' \
            "$H/logs/blocked-resolver.log" 2>/dev/null | sed 's/-> //' | tr '\n' ' '; }
NLINES() { grep -c -- "$1" "$H/logs/blocked-resolver.log" 2>/dev/null; }
NAGENT() { grep -c . "$T/agent.txt" 2>/dev/null; }
CLEAN() { scratch_rm "$ST" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff-released" 2>/dev/null
          scratch_rm "$H/builds" 2>/dev/null; mkdir -p "$H/builds"
          : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/gh.txt"; : > "$T/ssh.txt"
          : > "$T/alerts.txt"; : > "$T/agent.txt"; : > "$T/comments.txt"
          : > "$H/logs/blocked-resolver.log"; rm -f "$H/logs/ALERTS.log" "$T/slowgh"
          : > "$ROWS"; }
ISSUE() {
  jq -nc --argjson n "$1" --arg t "TK-$1: a parked ticket" \
         --arg c "$(date -u -d "@$((NOW - 604800))" '+%Y-%m-%dT%H:%M:%SZ')" \
         '{number:$n,state:"open",labels:[{name:"ai-build"}],title:$t,body:"## Scope",created_at:$c}'
}
for N in $(seq 1 99); do
  ISSUE "$N" > "$T/issue-$N.json"
  echo '[]' > "$T/comments-$N.json"
done

CONFLICT="conflict-unresolvable: CONFLICT (content): Merge conflict in src/a.ts"
IRONLAW="iron-law (8 hit(s))"
MFT="merge-failed-twice: gh pr merge refused"
HEAD_A=1111111111111111111111111111111111111111
HEAD_B=2222222222222222222222222222222222222222

# ============================================================================
# O1. THE BUG. A refused carry on head B: the build record holds an ACCEPT for
#     head A only, the conductor parked head B as BLOCKED_HUMAN iron-law 70 min
#     ago. Three fresh mechanical parks (cost 0) sort ahead of it on cost, and
#     BR_PER_TICK=2 is spent on two of them. Fixed: the iron-law row goes first.
# ============================================================================
CLEAN
mkdir -p "$H/builds/p1-TK-14-r1"
printf 'PR_CREATED https://github.com/o/p1/pull/14\n' > "$H/builds/p1-TK-14-r1/RESULT"
: > "$H/builds/p1-TK-14-r1/iron-law-accepted-$HEAD_A"
ROWADD "o/p1#11" "$((NOW - 600))"  "$CONFLICT" "https://github.com/o/p1/pull/11"
ROWADD "o/p1#12" "$((NOW - 600))"  "$CONFLICT" "https://github.com/o/p1/pull/12"
ROWADD "o/p1#13" "$((NOW - 600))"  "$CONFLICT" "https://github.com/o/p1/pull/13"
ROWADD "o/p1#14" "$((NOW - 4200))" "$IRONLAW"  "https://github.com/o/p1/pull/14" BLOCKED_HUMAN "$HEAD_B"
BRENV=(BR_PER_TICK=2 BR_PER_TICK_P1=2)
RUN
BRENV=()
[ "$(ORDER)" = "adjudicate mechanical " ] && ok \
  || bad "O1: THE BUG: the iron-law park 70 min old must be dispatched first (order: '$(ORDER)'; tick: $(LASTTICK))"
[ "$(NLINES 'OVERDUE — parked 70 min')" = 1 ] && ok \
  || bad "O1: one OVERDUE line for the promoted row (log: $(LOG | grep -i overdue))"
[ "$(LOG | grep -c 'OVERDUE — parked')" = 1 ] && ok \
  || bad "O1: only the overdue row is promoted (log: $(LOG | grep -i overdue))"
case "$(LFIELD visited)" in *p1*) ok ;; *) bad "O1: the tick line must say p1 was visited (tick: $(LASTTICK))" ;; esac
[ "$(NAGENT)" = 1 ] && ok || bad "O1: the adjudication is the one agent call (agent: $(cat "$T/agent.txt"))"

# O1b. THE NEXT TICK DOES NOT STARVE THE CHEAP ROWS. The adjudication answered
#      REJECT, so the park is still live and still 70 min old: its ladder goes
#      on (the fix round) and it is offered first again. The second slot of
#      BR_PER_TICK=2 still goes to a mechanical row.
: > "$H/logs/blocked-resolver.log"
BRENV=(BR_PER_TICK=2 BR_PER_TICK_P1=2)
RUN
BRENV=()
[ "$(ORDER)" = "adjudicate mechanical " ] && ok \
  || bad "O1b: the live overdue park first, then a cheap row (order: '$(ORDER)')"

# ============================================================================
# O2. THE NEAR MISS. The same iron-law row 20 min old is under the bar (60 min
#     at the default BR_UNTOUCHED_ALERT_MIN=120): today's cost order, no line.
# ============================================================================
CLEAN
ROWADD "o/p1#21" "$((NOW - 600))"  "$CONFLICT" "https://github.com/o/p1/pull/21"
ROWADD "o/p1#22" "$((NOW - 600))"  "$CONFLICT" "https://github.com/o/p1/pull/22"
ROWADD "o/p1#24" "$((NOW - 1200))" "$IRONLAW"  "https://github.com/o/p1/pull/24" BLOCKED_HUMAN "$HEAD_B"
BRENV=(BR_PER_TICK=2 BR_PER_TICK_P1=2)
RUN
BRENV=()
[ "$(ORDER)" = "mechanical mechanical " ] && ok \
  || bad "O2: a park under the bar keeps the cost order (order: '$(ORDER)')"
[ "$(LOG | grep -c 'OVERDUE')" = 0 ] && ok || bad "O2: no OVERDUE line (log: $(LOG | grep OVERDUE))"

# ============================================================================
# O4 (driver). Two overdue rows and a fresh one, offered cheapest first by the
#     cost order: the 200-min rebuild, then the 90-min adjudication, then the
#     fresh mechanical row.
# ============================================================================
CLEAN
ROWADD "o/p1#41" "$((NOW - 12000))" "$MFT"      "https://github.com/o/p1/pull/41"
ROWADD "o/p1#42" "$((NOW - 5400))"  "$IRONLAW"  "https://github.com/o/p1/pull/42" BLOCKED_HUMAN "$HEAD_B"
ROWADD "o/p1#43" "$((NOW - 600))"   "$CONFLICT" "https://github.com/o/p1/pull/43"
BRENV=(BR_PER_TICK=3 BR_PER_TICK_P1=3)
RUN
BRENV=()
[ "$(ORDER)" = "rebuild-fresh adjudicate mechanical " ] && ok \
  || bad "O4: overdue rows go oldest first, then the fresh row (order: '$(ORDER)')"
[ "$(LOG | grep -c 'OVERDUE — parked')" = 2 ] && ok \
  || bad "O4: one OVERDUE line per promoted row (log: $(LOG | grep OVERDUE))"

# ============================================================================
# O6. THE OFF SWITCHES. BR_UNTOUCHED_ALERT_MIN=0 turns the alert off and the
#     overdue bar with it; BR_OPT_OFF=bh-7555-overdue-first does not source the
#     fragment. Both give today's cost order and no OVERDUE line.
# ============================================================================
for SW in BR_UNTOUCHED_ALERT_MIN=0 BR_OPT_OFF=bh-7555-overdue-first; do
  CLEAN
  ROWADD "o/p1#61" "$((NOW - 600))"  "$CONFLICT" "https://github.com/o/p1/pull/61"
  ROWADD "o/p1#62" "$((NOW - 600))"  "$CONFLICT" "https://github.com/o/p1/pull/62"
  ROWADD "o/p1#64" "$((NOW - 4200))" "$IRONLAW"  "https://github.com/o/p1/pull/64" BLOCKED_HUMAN "$HEAD_B"
  BRENV=(BR_PER_TICK=2 BR_PER_TICK_P1=2 "$SW")
  RUN
  BRENV=()
  [ "$(ORDER)" = "mechanical mechanical " ] && ok \
    || bad "O6 ($SW): the switch restores the cost order (order: '$(ORDER)')"
  [ "$(LOG | grep -c 'OVERDUE')" = 0 ] && ok || bad "O6 ($SW): no OVERDUE line (log: $(LOG | grep OVERDUE))"
done

# ============================================================================
# O7. THE TICK-BUDGET PATH. Every gh call costs a second, so the tick is over
#     BR_TICK_MAX_SECS=1 after the first row it looks at. That one row must be
#     the overdue iron-law row.
# ============================================================================
CLEAN
touch "$T/slowgh"
ROWADD "o/p1#71" "$((NOW - 600))"  "$CONFLICT" "https://github.com/o/p1/pull/71"
ROWADD "o/p1#72" "$((NOW - 600))"  "$CONFLICT" "https://github.com/o/p1/pull/72"
ROWADD "o/p1#74" "$((NOW - 4200))" "$IRONLAW"  "https://github.com/o/p1/pull/74" BLOCKED_HUMAN "$HEAD_B"
BRENV=(BR_PER_TICK=3 BR_PER_TICK_P1=3 BR_TICK_MAX_SECS=1)
RUN
BRENV=(); rm -f "$T/slowgh"
[ "$(LFIELD reason)" = tick-budget ] && ok \
  || bad "O7: the fixture must end on the wall budget (tick: $(LASTTICK))"
[ "$(ORDER)" = "adjudicate " ] && ok \
  || bad "O7: the one row a budget-bound tick looks at is the overdue one (order: '$(ORDER)')"

# ============================================================================
# O9. A CARRIED ACCEPT IS NOT A PARK. When ilc_covered carries the ACCEPT to the
#     new head the conductor row is not BLOCKED_HUMAN, so the resolver has no
#     candidate for it and buys no adjudication, however old the row is.
# ============================================================================
CLEAN
ROWADD "o/p1#91" "$((NOW - 4200))" "-" "https://github.com/o/p1/pull/91" READY "$HEAD_B"
RUN
[ "$(ORDER)" = "" ] && ok || bad "O9: a carried head gives no rung (order: '$(ORDER)')"
[ "$(NAGENT)" = 0 ] && ok || bad "O9: and no agent call (agent: $(cat "$T/agent.txt"))"

# ============================================================================
# O10. THE HEAD-OF-LINE LIMIT (plan ASSUMPTIONS). Five overdue iron-law rows
#      (cost 1) and one fresh mechanical row (cost 0), BR_PER_TICK=4: the four
#      OLDEST overdue rows are dispatched, ahead of the cheaper fresh row. The
#      youngest overdue row (100 min) waits with the fresh row and goes to
#      br_note_untouched, so the tick line's oldest_untouched= is its age. The
#      untouched alert stays the backstop for a project with more overdue rows
#      than its share.
# ============================================================================
CLEAN
ROWADD "o/p1#100" "$((NOW - 600))"   "$CONFLICT" "https://github.com/o/p1/pull/100"
ROWADD "o/p1#101" "$((NOW - 6000))"  "$IRONLAW"  "https://github.com/o/p1/pull/101" BLOCKED_HUMAN "$HEAD_B"
ROWADD "o/p1#102" "$((NOW - 9000))"  "$IRONLAW"  "https://github.com/o/p1/pull/102" BLOCKED_HUMAN "$HEAD_B"
ROWADD "o/p1#103" "$((NOW - 12000))" "$IRONLAW"  "https://github.com/o/p1/pull/103" BLOCKED_HUMAN "$HEAD_B"
ROWADD "o/p1#104" "$((NOW - 15000))" "$IRONLAW"  "https://github.com/o/p1/pull/104" BLOCKED_HUMAN "$HEAD_B"
ROWADD "o/p1#105" "$((NOW - 18000))" "$IRONLAW"  "https://github.com/o/p1/pull/105" BLOCKED_HUMAN "$HEAD_B"
BRENV=(BR_PER_TICK=4 BR_PER_TICK_P1=4)
RUN
BRENV=()
# DISPATCHED — the PR numbers this run dispatched, in dispatch order.
DISPATCHED() { grep -E ' -> (mechanical|regen|fix-round|rebuild-fresh|rebuild-retry|adjudicate|re-review|abandon-rebuild) ' \
                 "$H/logs/blocked-resolver.log" 2>/dev/null | grep -oE 'p1/o-p1-[0-9]+ ' \
                 | sed -E 's#.*-([0-9]+) #\1#' | tr '\n' ' '; }
[ "$(DISPATCHED)" = "105 104 103 102 " ] && ok \
  || bad "O10: the four oldest overdue rows go first, oldest first (dispatched: '$(DISPATCHED)'; tick: $(LASTTICK))"
[ "$(LFIELD oldest_untouched)" = 100m ] && ok \
  || bad "O10: the fifth row (100 min) is the untouched one the tick line ages (tick: $(LASTTICK))"
[ "$(LOG | grep -c 'OVERDUE — parked')" = 5 ] && ok \
  || bad "O10: all five rows are overdue and said once each (log: $(LOG | grep OVERDUE))"

# ============================================================================
# THE FUNCTION, directly: the rows the conductor fixture cannot produce.
# ============================================================================
if [ ! -r "$FRAG" ]; then
  bad "the fragment bin/blocked-resolver.d/bh-7555-overdue-first.sh is missing"
else
  # OF [env...] — br_overdue_first over stdin in a clean shell, `say` to $T/say.txt.
  OF() { ( env "$@" bash -c '
      set -uo pipefail
      say() { printf "%s\n" "$*" >> "'"$T"'/say.txt"; }
      [ -n "${OF_RANK:-}" ] && eval "$OF_RANK"
      . "'"$FRAG"'" || exit 9
      br_overdue_first "'"$NOW"'"' ); }
  # R <rkey> <parked> [rec] — one 8-column candidate row.
  R() { printf 'conductor\tp1\t%s\tiron-law\thttps://x/%s\t%s\t-\t%s\n' "$1" "$1" "${3:--}" "$2"; }
  KEYS() { cut -f3 | tr '\n' ' '; }

  # O3. A hotfix row stays ahead of an overdue row; the overdue row then goes
  #     ahead of the fresh row. The input is in rank order, as br_rank_rows
  #     leaves it: the hotfix row first.
  : > "$T/say.txt"
  IN=$( R hot "$((NOW - 600))" hotrec; R fresh "$((NOW - 600))"; R old "$((NOW - 4200))" )
  RANKFN='priority_rank_meta() { case "$1" in hotrec/*) echo 0 ;; *) echo 2 ;; esac; }'
  OUT=$(printf '%s\n' "$IN" | OF OF_RANK="$RANKFN")
  [ "$(printf '%s\n' "$OUT" | KEYS)" = "hot old fresh " ] && ok \
    || bad "O3: hotfix first, then the overdue row, then the fresh row (got '$(printf '%s\n' "$OUT" | KEYS)')"
  # A hotfix row that is ALSO overdue stays in the hotfix group, printed once.
  IN=$( R hot "$((NOW - 9000))" hotrec; R fresh "$((NOW - 600))"; R old "$((NOW - 4200))" )
  OUT=$(printf '%s\n' "$IN" | OF OF_RANK="$RANKFN")
  [ "$(printf '%s\n' "$OUT" | KEYS)" = "hot old fresh " ] && ok \
    || bad "O3: an overdue hotfix row is printed once, in the hotfix group (got '$(printf '%s\n' "$OUT" | KEYS)')"

  # O4. Oldest overdue first, stable on a tie; rows in = rows out, as a multiset.
  IN=$( R fresh "$((NOW - 600))"; R ninety "$((NOW - 5400))"; R twohundred "$((NOW - 12000))"
        R tie "$((NOW - 5400))"; R fresh "$((NOW - 600))" )
  OUT=$(printf '%s\n' "$IN" | OF)
  [ "$(printf '%s\n' "$OUT" | KEYS)" = "twohundred ninety tie fresh fresh " ] && ok \
    || bad "O4: oldest first, stable, duplicates kept (got '$(printf '%s\n' "$OUT" | KEYS)')"
  [ "$(printf '%s\n' "$OUT" | sort | md5sum)" = "$(printf '%s\n' "$IN" | sort | md5sum)" ] && ok \
    || bad "O4: the rows out are the rows in, byte for byte"

  # O5. Unknown and future ages are never promoted and never lost. Exactly at
  #     the bar (60 min) IS overdue; one second under is not.
  : > "$T/say.txt"
  IN=$( R dash "-"; R abc "abc"; R future "$((NOW + 7200))"; R empty "";
        R under "$((NOW - 3599))"; R edge "$((NOW - 3600))" )
  OUT=$(printf '%s\n' "$IN" | OF)
  [ "$(printf '%s\n' "$OUT" | KEYS)" = "edge dash abc future empty under " ] && ok \
    || bad "O5: only the row at the bar is promoted, nothing is lost (got '$(printf '%s\n' "$OUT" | KEYS)')"
  [ "$(grep -c 'OVERDUE — parked 60 min' "$T/say.txt")" = 1 ] && ok \
    || bad "O5: one OVERDUE line, for the edge row (say: $(cat "$T/say.txt"))"
  # A knob that is not a number is the 120 default, as untouched.sh reads it.
  OUT=$(printf '%s\n' "$IN" | OF BR_UNTOUCHED_ALERT_MIN=soon)
  [ "$(printf '%s\n' "$OUT" | KEYS)" = "edge dash abc future empty under " ] && ok \
    || bad "O5: a non-numeric knob is 120 (got '$(printf '%s\n' "$OUT" | KEYS)')"
  # A smaller knob moves the bar: 20 min -> 10 min, so `under` (59 min) is overdue.
  OUT=$(printf '%s\n' "$IN" | OF BR_UNTOUCHED_ALERT_MIN=20)
  [ "$(printf '%s\n' "$OUT" | KEYS)" = "edge under dash abc future empty " ] && ok \
    || bad "O5: BR_UNTOUCHED_ALERT_MIN=20 puts the bar at 10 min (got '$(printf '%s\n' "$OUT" | KEYS)')"

  # O8. FAIL-OPEN. The rank lookup fails mid-stream (rc 2): every row comes out
  #     in the input order, nothing promoted, and the function returns 0.
  IN=$( R hot "$((NOW - 600))" hotrec; R hot2 "$((NOW - 600))" hotrec2; R fresh "$((NOW - 600))"; R old "$((NOW - 4200))" )
  : > "$T/say.txt"
  FAILFN='priority_rank_meta() { case "$1" in hotrec2/*) return 2 ;; hotrec/*) echo 0 ;; *) echo 2 ;; esac; }'
  OUT=$(printf '%s\n' "$IN" | OF OF_RANK="$FAILFN"); RC=$?
  [ "$RC" = 0 ] && ok || bad "O8: the function returns 0 on a failed lookup (rc $RC)"
  [ "$OUT" = "$IN" ] && ok \
    || bad "O8: a failed lookup leaves the input order (got '$(printf '%s\n' "$OUT" | KEYS)')"
  [ "$(grep -c '^overdue-first: the rank lookup for p1/hot2 failed' "$T/say.txt")" = 1 ] && ok \
    || bad "O8: one overdue-first: failure line (say: $(cat "$T/say.txt"))"
  [ "$(grep -c 'OVERDUE' "$T/say.txt")" = 0 ] && ok \
    || bad "O8: no OVERDUE line on the fail-open path (say: $(cat "$T/say.txt"))"
  # And the clock: an argument that is not an epoch passes the input through.
  OUT=$(printf '%s\n' "$IN" | ( say() { :; }; . "$FRAG"; br_overdue_first "") )
  [ "$OUT" = "$IN" ] && ok || bad "O8: no clock, no reorder (got '$(printf '%s\n' "$OUT" | KEYS)')"
fi

echo "blocked-resolver-overdue.bh-7555: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
