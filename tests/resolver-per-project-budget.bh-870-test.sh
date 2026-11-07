#!/bin/bash
# tests/resolver-per-project-budget.bh-870-test.sh — BR_PER_TICK is a FLEET
# total, and before BH-870 it was spent in pr-state.tsv file order. Four rungs,
# and the project whose parked rows happen to sort first takes all four, every
# ten minutes, for as long as it stays parked. The other six repos are then
# invisible to this lane while nothing anywhere says so.
#
# So this file pins two things and nothing else:
#   - ORDER. br_candidates is interleaved by project (br_round_robin, the
#     sweep_order shape BH-778 shipped in bin/merge-sweep.sh), so the fleet
#     budget is spread across the projects that have candidates instead of
#     being drained by the first one.
#   - SHARE. BR_PER_TICK_<PROJECT> caps one project's rungs inside that tick.
#     Unset is the whole point of section 3: it must behave EXACTLY as today.
#
# Everything is asserted on what the run DID — the queue rows it wrote, the PRs
# it closed, the lines in logs/blocked-resolver.log — never on the source text
# of bin/blocked-resolver.sh. A grep for br_round_robin would pass on a version
# that defines it and never pipes anything through it.
# Run from anywhere: tests/resolver-per-project-budget.bh-870-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh): every
# created_at below is derived from it, so the fixture thread is internally
# ordered whatever the wall clock says.
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$H/state/build-queue/tproj" "$H/state/build-queue/uproj" \
         "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy. One helper, one edit when the
# split moves again.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
cp "$DIR/bin/lib/hold.sh" "$H/bin/lib/" 2>/dev/null || true
# bin/blocked-resolver.sh now REQUIRES the REST contract (#783): without it the
# lane refuses to start rather than deciding on undefined reads.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
chmod +x "$H/bin/"*.sh
# TWO projects, both GitHub-Issues lanes (board prefix "-"), because the whole
# question here is what happens to the SECOND one when the first has more
# candidates than the tick has rungs.
{ printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\n'
  printf 'uproj o/uproj - - 2 box-uproj 192.0.2.7\n'; } > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh agent-call.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done

# Every gh call is recorded, so "which PRs did this tick actually act on" is a
# fact about the run rather than a reading of the log.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  # bin/blocked-resolver.sh decides over REST now (#783). This fixture names its
  # PR fields off the NUMBER in the path, so they are written where the shared
  # REST stub reads them and the envelope is answered there.
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
  *"pr comment"*|*"issue comment"*) exit 0 ;;
  *"--json state"*)        echo OPEN ;;
  *"/pulls/"*)             echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *"--json headRefOid,headRefName"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *"--json headRefName"*)  echo "ticket/ts-\$N" ;;
  *"--json headRefOid"*)   echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;
  *"pr list"*"--state merged"*) : ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/ssh.txt"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
# NO REAL CREDENTIAL REACHES THIS RUN (same rule as tests/blocked-resolver-test.sh).
export GH_TOKEN=""
# A jobs client whose queue_put is recorded rather than sent. Both projects are
# pool projects, so every rung this file counts lands as one queue row.
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-tproj" "$H/flags/fly-pool-uproj"

BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
# The conductor hand-off row this lane drains: key, state, since, head, rev,
# alerted, why, url.
ROW() { printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$NOW" abc123 abc123 "$2" "$3" \
          > "$H/state/merge-conductor/pr-state.tsv"; }
ROWADD() { printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$NOW" abc123 abc123 "$2" "$3" \
          >> "$H/state/merge-conductor/pr-state.tsv"; }
CLEAN() { scratch_rm "$H/state/blocked-resolver"
          scratch_rm "$H/state/merge-conductor/handoff-released"
          : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/gh.txt"; : > "$T/ssh.txt"
          : > "$H/logs/blocked-resolver.log"; rm -f "$H/logs/ALERTS.log"
          : > "$H/state/merge-conductor/pr-state.tsv"; }

WHY="merge-failed-twice: gh pr merge refused"
# --- the fixture issues -------------------------------------------------------
# Every candidate must be CLEAR (unheld), or the hold gate would refuse the rung
# and the budget this file measures would never be spent at all.
ISSUE() {  # ISSUE <number> <labels-csv>
  local labels="[]"
  [ -n "${2:-}" ] && labels=$(printf '%s' "$2" | jq -Rc 'split(",")|map({name:.})')
  jq -nc --argjson n "$1" --argjson l "$labels" --arg t "TK-$1: a parked ticket" \
         --arg c "$(ISO 604800)" \
         '{number:$n,state:"open",labels:$l,title:$t,body:"## Scope",created_at:$c}'
}
CMT() { jq -nc --arg b "$1" --arg c "$(ISO "${2:-0}")" '[{body:$b,created_at:$c,user:{type:"User"}}]'; }
for N in 1 2 3 4; do
  ISSUE "$N" ai-build > "$T/issue-$N.json"
  echo '[]' > "$T/comments-$N.json"
done
# THREE tproj rows ABOVE one uproj row. This is the starvation shape: in file
# order the uproj candidate is last, so a fleet budget of 2 never reaches it.
SEED() { ROW    "o/tproj#1" "$WHY" "https://github.com/o/tproj/pull/1"
         ROWADD "o/tproj#2" "$WHY" "https://github.com/o/tproj/pull/2"
         ROWADD "o/tproj#3" "$WHY" "https://github.com/o/tproj/pull/3"
         ROWADD "o/uproj#4" "$WHY" "https://github.com/o/uproj/pull/4"; }
# ACTED <project> <ticket-number> — did this tick spend a rung on that ticket?
ACTED() { grep -q "^$1 TK-$2 $2 fly " "$T/queue.txt"; }
NACTED() { grep -c '^[a-z]* TK-[0-9]* [0-9]* fly ' "$T/queue.txt"; }
TCOUNT() { grep -c '^tproj TK-[0-9]* [0-9]* fly ' "$T/queue.txt"; }

# ============================================================================
# 0. THE TWO HELPERS, extracted verbatim and driven as the pure functions they
#    are. They are lifted out of the script rather than re-typed here so a body
#    that drifts is a red test, not a test that quietly checks a copy.
# ============================================================================
PER_TICK=4
say() { printf '%s\n' "$*" >> "$T/say.txt"; }
: > "$T/say.txt"
RRSRC=$(sed -n '/^br_round_robin() {/,/^}/p' "$H/bin/blocked-resolver.sh")
PTSRC=$(sed -n '/^br_per_tick_for() {/,/^}/p' "$H/bin/blocked-resolver.sh")
[ -n "$RRSRC" ] && ok || bad "br_round_robin is not defined in bin/blocked-resolver.sh"
[ -n "$PTSRC" ] && ok || bad "br_per_tick_for is not defined in bin/blocked-resolver.sh"
eval "$RRSRC" 2>/dev/null || bad "br_round_robin does not eval"
eval "$PTSRC" 2>/dev/null || bad "br_per_tick_for does not eval"
if ! command -v br_round_robin >/dev/null 2>&1; then br_round_robin() { cat; }; fi
if ! command -v br_per_tick_for >/dev/null 2>&1; then br_per_tick_for() { printf '4\n'; }; fi

# a a a b c -> a b c a a, and the order WITHIN a project is preserved.
RRIN=$(printf 'conductor\ta\ta1\tr\t-\t-\t-\nconductor\ta\ta2\tr\t-\t-\t-\nconductor\ta\ta3\tr\t-\t-\t-\nconductor\tb\tb1\tr\t-\t-\t-\nconductor\tc\tc1\tr\t-\t-\t-\n')
RROUT=$(printf '%s' "$RRIN" | br_round_robin | cut -f3 | tr '\n' ' ')
[ "$RROUT" = "a1 b1 c1 a2 a3 " ] && ok \
  || bad "round-robin of a a a b c must be a b c a a, got '$RROUT'"
# NOTHING IS EVER DROPPED. An ordering that loses a candidate is worse than the
# ordering it replaced, so the line count is asserted on its own.
[ "$(printf '%s' "$RRIN" | br_round_robin | wc -l)" = 5 ] && ok \
  || bad "round-robin must print every line it read"
# A line with an EMPTY project field keeps its own bucket rather than being
# dropped or folded into another project's.
RRIN2=$(printf 'conductor\ta\ta1\tr\t-\t-\t-\nconductor\t\tz1\tr\t-\t-\t-\nconductor\ta\ta2\tr\t-\t-\t-\n')
RROUT2=$(printf '%s' "$RRIN2" | br_round_robin | cut -f3 | tr '\n' ' ')
[ "$RROUT2" = "a1 z1 a2 " ] && ok \
  || bad "an empty project field keeps its own bucket, got '$RROUT2'"
# Empty stdin is empty stdout, not an error.
[ -z "$(printf '' | br_round_robin)" ] && ok || bad "empty input must produce empty output"

# br_per_tick_for: the env-var mangle, the fallback, and the bad value.
[ "$(BR_PER_TICK_PROJECT_1=2 br_per_tick_for project-1)" = 2 ] && ok \
  || bad "project-1 must read BR_PER_TICK_PROJECT_1 (got '$(BR_PER_TICK_PROJECT_1=2 br_per_tick_for project-1)')"
# …and NOT a name with a stray trailing underscore, which is what a mangle that
# folds the trailing newline produces.
[ "$(BR_PER_TICK_PROJECT_1_=2 br_per_tick_for project-1)" = 4 ] && ok \
  || bad "BR_PER_TICK_PROJECT_1_ (trailing underscore) must not be read"
[ "$(br_per_tick_for project-1)" = 4 ] && ok \
  || bad "an unset override falls back to BR_PER_TICK (got '$(br_per_tick_for project-1)')"
[ "$(BR_PER_TICK_TPROJ=1 br_per_tick_for tproj)" = 1 ] && ok || bad "BR_PER_TICK_TPROJ=1 must read 1"
: > "$T/say.txt"
BADV=$(BR_PER_TICK_PROJECT_1=x br_per_tick_for project-1)
[ "$BADV" = 4 ] && ok || bad "a non-numeric override falls back to BR_PER_TICK (got '$BADV')"
grep -q 'is not a number' "$T/say.txt" && ok \
  || bad "a non-numeric override must say so (say.txt: $(cat "$T/say.txt"))"
grep -q 'BR_PER_TICK_PROJECT_1' "$T/say.txt" && ok \
  || bad "…and name the variable it could not read: $(cat "$T/say.txt")"

# ============================================================================
# 1. THE STARVATION. Three tproj candidates above one uproj candidate, two
#    rungs in the tick. In file order tproj takes both and uproj is invisible;
#    interleaved, each project gets one.
# ============================================================================
CLEAN
SEED
BRENV=(BR_PER_TICK=2)
RUN
BRENV=()
ACTED uproj 4 && ok \
  || bad "with 2 rungs and tproj first, uproj must still be reached (queue: $(cat "$T/queue.txt"))"
[ "$(TCOUNT)" = 1 ] && ok \
  || bad "tproj must spend exactly one of the two rungs, spent $(TCOUNT) (queue: $(cat "$T/queue.txt"))"
[ "$(NACTED)" = 2 ] && ok \
  || bad "the fleet total BR_PER_TICK=2 is unchanged, got $(NACTED) rungs (queue: $(cat "$T/queue.txt"))"
ACTED tproj 1 && ok \
  || bad "the first candidate of the busy project is still the one that runs (queue: $(cat "$T/queue.txt"))"

# ============================================================================
# 2. THE OVERRIDE. Four rungs in the tick, but tproj is capped at one, so the
#    other three are available to everybody else and tproj's remaining
#    candidates wait — with ONE line saying so, not one per candidate.
# ============================================================================
CLEAN
SEED
BRENV=(BR_PER_TICK=4 BR_PER_TICK_TPROJ=1)
RUN
BRENV=()
[ "$(TCOUNT)" = 1 ] && ok \
  || bad "BR_PER_TICK_TPROJ=1 must cap tproj at one rung, spent $(TCOUNT) (queue: $(cat "$T/queue.txt"))"
ACTED uproj 4 && ok || bad "uproj must still be acted on (queue: $(cat "$T/queue.txt"))"
[ "$(grep -c 'share of this tick is spent' "$H/logs/blocked-resolver.log")" = 1 ] && ok \
  || bad "the cap must be said exactly once per project per tick, said $(grep -c 'share of this tick is spent' "$H/logs/blocked-resolver.log") times"
grep 'share of this tick is spent' "$H/logs/blocked-resolver.log" | grep -q 'tproj' && ok \
  || bad "the cap line must name the project: $(grep 'share of this tick' "$H/logs/blocked-resolver.log")"
grep -q 'BR_PER_TICK=4' "$H/logs/blocked-resolver.log" && ok \
  || bad "the cap line must name the fleet total it sits under: $(grep 'share of this tick' "$H/logs/blocked-resolver.log")"

# ============================================================================
# 3. UNSET BEHAVES EXACTLY AS TODAY. No override anywhere: the fleet budget is
#    the only ceiling and every candidate inside it is acted on.
# ============================================================================
CLEAN
SEED
BRENV=(BR_PER_TICK=4)
RUN
BRENV=()
[ "$(NACTED)" = 4 ] && ok \
  || bad "with no override all four candidates run, got $(NACTED) (queue: $(cat "$T/queue.txt"))"
for N in 1 2 3; do ACTED tproj "$N" && ok || bad "tproj#$N must run when nothing caps tproj"; done
ACTED uproj 4 && ok || bad "uproj#4 must run when nothing caps anything"
grep -q 'share of this tick is spent' "$H/logs/blocked-resolver.log" \
  && bad "no override means no cap line: $(grep 'share of this tick' "$H/logs/blocked-resolver.log")" || ok

# ============================================================================
# 4. A BAD VALUE IS NOT A CAP OF ZERO. An operator typo in env/global.env must
#    fall back to the fleet default and say so, never silently stop a project.
# ============================================================================
CLEAN
SEED
BRENV=(BR_PER_TICK=4 BR_PER_TICK_TPROJ=abc)
RUN
BRENV=()
grep -q "is not a number" "$H/logs/blocked-resolver.log" && ok \
  || bad "a non-numeric override must be logged: $(tail -3 "$H/logs/blocked-resolver.log")"
[ "$(NACTED)" = 4 ] && ok \
  || bad "a non-numeric override falls back to BR_PER_TICK, got $(NACTED) rungs (queue: $(cat "$T/queue.txt"))"

# ============================================================================
# 5. A HELD CANDIDATE SPENDS NEITHER BUDGET. The fleet total already works this
#    way (tests/resolver-hold-test.sh section 7) and the per-project share has
#    to match: a held ticket at the top of a capped project would otherwise be
#    that project's whole tick, at zero cost and in silence.
# ============================================================================
CLEAN
# Tick one parks tproj#1 HELD (the gate parks on discovery and answers rc 3
# only from the tick after, so the park has to exist before the budget is read).
printf '%s\n' "$(CMT 'HOLD — the operator: do not rebuild this.' 3600)" > "$T/comments-1.json"
ROW "o/tproj#1" "$WHY" "https://github.com/o/tproj/pull/1"
RUN
grep -q 'HOLD respected' "$H/logs/blocked-resolver.log" && ok \
  || bad "tproj#1 must be parked HELD before the budget test: $(tail -3 "$H/logs/blocked-resolver.log")"
[ -s "$T/queue.txt" ] && bad "a held ticket must not be rebuilt (queue: $(cat "$T/queue.txt"))" || ok
: > "$T/queue.txt"; : > "$T/closed.txt"; : > "$H/logs/blocked-resolver.log"
ROWADD "o/tproj#2" "$WHY" "https://github.com/o/tproj/pull/2"
ROWADD "o/tproj#3" "$WHY" "https://github.com/o/tproj/pull/3"
ROWADD "o/uproj#4" "$WHY" "https://github.com/o/uproj/pull/4"
BRENV=(BR_PER_TICK=4 BR_PER_TICK_TPROJ=1)
RUN
BRENV=()
ACTED tproj 1 && bad "the held candidate must still not be rebuilt (queue: $(cat "$T/queue.txt"))" || ok
ACTED tproj 2 && ok \
  || bad "a HELD candidate spends no share, so tproj#2 must still run (queue: $(cat "$T/queue.txt"))"
ACTED tproj 3 && bad "…and the share is spent after it (queue: $(cat "$T/queue.txt"))" || ok
ACTED uproj 4 && ok || bad "uproj must be reached in the same tick (queue: $(cat "$T/queue.txt"))"
echo '[]' > "$T/comments-1.json"

echo "resolver-per-project-budget: PASS $PASS FAIL $FAIL"
[ "$FAIL" -eq 0 ]
