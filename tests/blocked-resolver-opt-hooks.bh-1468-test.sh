#!/bin/bash
# tests/blocked-resolver-opt-hooks.bh-1468-test.sh — BH-1468: the OPTIONAL
# module seam of bin/blocked-resolver.sh.
#
# WHAT THIS SLICE IS. Two siblings need somewhere to plug in: #1470 (carry an
# unchanged verdict / rebase a derived-only conflict) and #1471 (family-batched
# iron-law adjudication). Neither can land while the lane has no seam, and a
# seam nobody can verify is the same as no seam. So this file drives the REAL
# bin/blocked-resolver.sh against a scratch $HARNESS with CANARY modules
# dropped into $HARNESS/bin/lib/br/opt/, and asserts on what the run did:
# recorded hook argv, recorded bin/agent-call.sh calls, the `-> <action>`
# dispatch lines, the counters on the `tick:` line, and the lane's exit code.
# Nothing here greps the source of the lane.
#
# THE FAIL-OPEN RULE this pins is the difference between the two loaders. The
# REQUIRED loop (bin/lib/br/ladder.sh, record.sh) writes RESOLVER MODULE MISSING
# to logs/ALERTS.log and exits 1 — a half-synced classifier must never drain a
# park. The OPTIONAL loop cannot do that: a box that never got bin/lib/br/opt/
# at all is the NORMAL box, so absent is silent, unparseable is one log line,
# and a module that fails on source is one log line. In all three the tick runs
# today's path to completion.
#
# Run from anywhere: tests/blocked-resolver-opt-hooks.bh-1468-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
# BH-1176: the REQUIRED modules travel with the copy or the lane refuses the
# tick. bin/lib/br/opt/ deliberately does NOT — its absence is case 1.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$DIR/bin/lib/hold.sh" "$DIR/bin/lib/gh-rest.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
# The ACCEPT arm writes the ironlaw-head-accept row through ila_put (BH-7804).
( cd "$DIR" && scratch_install_closure bin/lib/ironlaw-carry.sh "$H" >/dev/null ) || exit 1
chmod +x "$H/bin/"*.sh
{ for I in 1 2; do printf 'p%s o/p%s - - 2 box-p%s 192.0.2.%s\n' "$I" "$I" "$I" "$I"; done; } > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
# BH-1510.1: the resolver's models are model_routes rows; this worker-less box carries the resolver's cache of #1507's table.
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p1 p2
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
: > "$T/agent.txt"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
: > "$T/alerts.txt"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
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
  *"--json state"*) cat "$T/prstate" 2>/dev/null || echo OPEN ;;
  *"/pulls/"*)             echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/comments.txt"
: > "$T/ssh.txt"; : > "$T/run.log"; : > "$T/hooks.txt"
echo OPEN > "$T/prstate"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
# NO REAL CREDENTIAL REACHES THIS RUN (the rule tests/blocked-resolver-test.sh holds).
export GH_TOKEN=""

JOBS_OK() { cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
# The ironlaw-head-accept write (ila_put): one "<kind> <key>" line per claim.
job_ledger_claim() { printf '%s %s\n' "\$1" "\$2" >> "$T/claims.txt"; return 0; }
EOF
}
for I in 1 2; do touch "$H/flags/fly-pool-p$I"; done
JOBS_OK

ROWS="$H/state/merge-conductor/pr-state.tsv"
ST="$H/state/blocked-resolver"
OPTD="$H/bin/lib/br/opt"
BRENV=()
RC=0
RUN() { RC=0
        ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || RC=$?; }
# ROWADD <key> <since> <why> <url> [state] [head] — one conductor hand-off row.
ROWADD() { printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' \
             "$1" "${5:-BLOCKED_HUMAN}" "$2" "${6:-abc123}" "${6:-abc123}" "$3" "$4" >> "$ROWS"; }
STATEJSON() { cat "$ST/$1/$2.json" 2>/dev/null; }
LOG() { cat "$H/logs/blocked-resolver.log" 2>/dev/null; }
LASTTICK() { grep 'tick: candidates=' "$H/logs/blocked-resolver.log" \
             | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
LFIELD() { LASTTICK | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
ORDER() { grep -oE '\-> (mechanical|regen|fix-round|rebuild-fresh|rebuild-retry|adjudicate|re-review|abandon-rebuild)' \
            "$H/logs/blocked-resolver.log" 2>/dev/null | sed 's/-> //' | tr '\n' ' '; }
NAGENT() { grep -c . "$T/agent.txt" 2>/dev/null; }
NLINES() { grep -c "$1" "$H/logs/blocked-resolver.log" 2>/dev/null; }
# HOOKS <tag> — the recorded calls of one hook, in the order they were made.
HOOKS() { grep "^$1|" "$T/hooks.txt" 2>/dev/null; }
# HFIELD <tag> <n> — field n of the FIRST recorded call of that hook.
HFIELD() { HOOKS "$1" | head -1 | cut -d'|' -f"$2"; }

# RECMK <name> <url> — a build record the conductor's mc_record_for can find,
# so the iron-law ACCEPT arm has somewhere real to write its per-PR marker.
RECMK() { mkdir -p "$H/builds/$1"; printf 'PR_CREATED %s (harness build)\n' "$2" > "$H/builds/$1/RESULT"; }

CLEAN() { scratch_rm "$ST" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff-released" 2>/dev/null
          scratch_rm "$OPTD" 2>/dev/null
          scratch_rm "$H/builds" 2>/dev/null; mkdir -p "$H/builds"
          : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/gh.txt"; : > "$T/ssh.txt"
          : > "$T/alerts.txt"; : > "$T/agent.txt"; : > "$T/comments.txt"
          : > "$T/hooks.txt"; : > "$T/claims.txt"; rm -f "$T/knobs.txt"
          : > "$H/logs/blocked-resolver.log"; rm -f "$H/logs/ALERTS.log"
          echo OPEN > "$T/prstate"; JOBS_OK
          : > "$ROWS"; }

ISSUE() {  # ISSUE <number> <labels-csv>
  local labels="[]"
  [ -n "${2:-}" ] && labels=$(printf '%s' "$2" | jq -Rc 'split(",")|map({name:.})')
  jq -nc --argjson n "$1" --argjson l "$labels" --arg t "TK-$1: a parked ticket" \
         --arg c "$(date -u -d "@$((NOW - 604800))" '+%Y-%m-%dT%H:%M:%SZ')" \
         '{number:$n,state:"open",labels:$l,title:$t,body:"## Scope",created_at:$c}'
}
for N in $(seq 1 40); do
  ISSUE "$N" ai-build > "$T/issue-$N.json"
  echo '[]' > "$T/comments-$N.json"
done

CONFLICT="conflict-unresolvable: CONFLICT (content): Merge conflict in src/a.ts"
IRONLAW="iron-law: hardcoded claude-opus-5 in src/agent.ts"

# ---------------------------------------------------------------------------
# The canary modules. Each defines ONLY the hook under test plus an argv
# recorder, which is what the README tells a real module to look like: define
# functions, do nothing on source.
# ---------------------------------------------------------------------------
MODW() { mkdir -p "$OPTD"; cat > "$OPTD/$1.sh"; }

# CARRY <rc> — br_opt_carry_rung recording six-field argv, counting `carried`
#              on a handled row, answering <rc>.
CARRY() { MODW mechanical <<EOF
br_opt_carry_rung() {
  printf 'carry|%s|%s|%s|%s|%s|%s|%s\n' "\$#" "\$1" "\$2" "\$3" "\$4" "\$5" "\$6" >> "$T/hooks.txt"
  [ "$1" = 0 ] && br_count carried
  return $1
}
EOF
}
# BOTH <carry-rc> <conflict-rc> — both br_one hooks in one module.
BOTH() { MODW mechanical <<EOF
br_opt_carry_rung() {
  printf 'carry|%s|%s|%s|%s|%s|%s|%s\n' "\$#" "\$1" "\$2" "\$3" "\$4" "\$5" "\$6" >> "$T/hooks.txt"
  [ "$1" = 0 ] && br_count carried
  return $1
}
br_opt_conflict_rung() {
  printf 'conflict|%s|%s|%s|%s|%s|%s|%s\n' "\$#" "\$1" "\$2" "\$3" "\$4" "\$5" "\$6" >> "$T/hooks.txt"
  [ "$2" = 0 ] && br_count mechanical
  return $2
}
EOF
}
# FAMILY <pre-rc> — br_opt_family_pre + br_opt_family_record. The record hook
#                   probes for the per-PR ACCEPT row (the ironlaw-head-accept
#                   claim, BH-7804) at the moment it runs,
#                   which is the ordering #1471 depends on.
FAMILY() { MODW family <<EOF
br_opt_family_pre() {
  printf 'pre|%s|%s|%s|%s|%s|%s\n' "\$#" "\$1" "\$2" "\$3" "\$4" "\$5" >> "$T/hooks.txt"
  [ "$1" = 0 ] && br_count family
  return $1
}
br_opt_family_record() {
  local m=no
  grep -q '^ironlaw-head-accept ' "$T/claims.txt" 2>/dev/null && m=yes
  printf 'record|%s|%s|%s|%s|%s|%s|%s|marker=%s\n' "\$#" "\$1" "\$2" "\$3" "\$4" "\$5" "\$6" "\$m" >> "$T/hooks.txt"
  return 0
}
EOF
}
# KNOBS — a module that writes the two declared knobs, as the LANE resolved
#         them, from inside a hook. A knob a module cannot read is not a knob.
KNOBS() { MODW family <<EOF
br_opt_family_pre() {
  printf 'ttl=%s off=%s\n' "\${BR_FAMILY_TTL_SECS:-unset}" "\${BR_OPT_OFF:-empty}" >> "$T/knobs.txt"
  return 1
}
EOF
}

# ============================================================================
# 1. NO opt/ DIRECTORY AT ALL — the normal box. The loader is silent, the tick
#    runs today's path, and the four new counters read 0 / the one model call.
# ============================================================================
CLEAN
ROWADD "o/p1#23" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/23"
RUN
[ "$RC" = 0 ] && ok || bad "1: a tick with no optional module must exit 0 (rc $RC)"
[ ! -d "$OPTD" ] && ok || bad "1: the fixture must not have created bin/lib/br/opt/"
[ "$(NLINES 'optional module')" = 0 ] && ok \
  || bad "1: an absent optional module is SILENT (log: $(LOG | tail -5))"
[ "$(LFIELD carried)" = 0 ] && ok || bad "1: carried must read 0 (tick: $(LASTTICK))"
[ "$(LFIELD mechanical)" = 0 ] && ok || bad "1: mechanical must read 0 (tick: $(LASTTICK))"
[ "$(LFIELD families)" = 0 ] && ok || bad "1: families must read 0 (tick: $(LASTTICK))"
[ "$(LFIELD llm_rungs)" = 1 ] && ok \
  || bad "1: the adjudication that ran is one llm rung (tick: $(LASTTICK))"
[ "$(NAGENT)" = 1 ] && ok || bad "1: and it really called the model (agent calls: $(NAGENT))"

# ============================================================================
# 2. A CARRY HOOK THAT HANDLES THE ROW. rc 0 means the module did the work:
#    br_one returns 0, nothing is dispatched, no model is called — and the row
#    still SPENDS its PER_TICK slot, because it ran under the per-key lock and
#    did work. That is the contract #1470 builds against.
# ============================================================================
CLEAN
CARRY 0
# The OLDER park goes first (BH-1122), so #23 is the row the hook sees and #24
# is the one left waiting on the budget.
ROWADD "o/p1#23" "$((NOW - 100))" "$IRONLAW" "https://github.com/o/p1/pull/23"
ROWADD "o/p1#24" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/24"
BRENV=(BR_PER_TICK=1 BR_PER_TICK_P1=1)
RUN
BRENV=()
[ "$(HFIELD carry 2)" = 6 ] && ok \
  || bad "2: the carry hook gets six arguments (got: $(HOOKS carry | head -1))"
[ "$(HFIELD carry 3)" = p1 ] && ok || bad "2: arg1 is the project (got: $(HFIELD carry 3))"
[ "$(HFIELD carry 4)" = "o-p1-23" ] && ok || bad "2: arg2 is the row key (got: $(HFIELD carry 4))"
[ "$(HFIELD carry 5)" = "iron-law" ] && ok \
  || bad "2: arg3 is the classified reason word (got: $(HFIELD carry 5))"
[ "$(HFIELD carry 6)" = "https://github.com/o/p1/pull/23" ] && ok \
  || bad "2: arg4 is the PR url (got: $(HFIELD carry 6))"
[ "$(HFIELD carry 8)" = "TK-23" ] && ok || bad "2: arg6 is the ticket key (got: $(HFIELD carry 8))"
[ "$(NAGENT)" = 0 ] && ok || bad "2: a handled row calls no model (agent: $(cat "$T/agent.txt"))"
case "$(ORDER)" in *adjudicate*) bad "2: a handled row dispatches nothing (order: $(ORDER))" ;; *) ok ;; esac
[ "$(LFIELD rungs)" = "1/1" ] && ok || bad "2: and it spends its slot (tick: $(LASTTICK))"
[ "$(LFIELD reason)" = budget ] && ok || bad "2: so the second row waits (tick: $(LASTTICK))"
[ "$(LFIELD carried)" = 1 ] && ok || bad "2: carried=1 (tick: $(LASTTICK))"
[ "$(LFIELD llm_rungs)" = 0 ] && ok || bad "2: a carried row is not an llm rung (tick: $(LASTTICK))"

# ============================================================================
# 3. A CARRY HOOK THAT DECLINES. Any rc but 0 is today's path, byte for byte —
#    the hook was consulted and the lane adjudicated anyway.
# ============================================================================
CLEAN
CARRY 1
ROWADD "o/p1#23" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/23"
RUN
[ -n "$(HOOKS carry)" ] && ok || bad "3: the hook must still be consulted (hooks: $(cat "$T/hooks.txt"))"
[ "$(ORDER)" = "adjudicate " ] && ok || bad "3: a declined row takes its normal rung (order: $(ORDER))"
[ "$(NAGENT)" = 1 ] && ok || bad "3: and the model is called (agent calls: $(NAGENT))"
[ "$(LFIELD carried)" = 0 ] && ok || bad "3: nothing was carried (tick: $(LASTTICK))"
[ "$(LFIELD llm_rungs)" = 1 ] && ok || bad "3: the adjudication is the llm rung (tick: $(LASTTICK))"

# ============================================================================
# 4. CARRY FIRST, THEN CONFLICT. Two hooks, one order: a module that cannot
#    carry a verdict may still resolve the conflict. The second is only asked
#    when the first declined.
# ============================================================================
CLEAN
BOTH 1 0
ROWADD "o/p1#25" "$NOW" "$CONFLICT" "https://github.com/o/p1/pull/25"
RUN
[ "$(cut -d'|' -f1 "$T/hooks.txt" | tr '\n' ' ')" = "carry conflict " ] && ok \
  || bad "4: carry is asked first, conflict second (hooks: $(cut -d'|' -f1 "$T/hooks.txt" | tr '\n' ' '))"
[ "$(HFIELD conflict 2)" = 6 ] && ok \
  || bad "4: the conflict hook gets the same six arguments (got: $(HOOKS conflict | head -1))"
case "$(ORDER)" in *mechanical*) bad "4: a handled conflict dispatches nothing (order: $(ORDER))" ;; *) ok ;; esac
[ "$(LFIELD mechanical)" = 1 ] && ok || bad "4: mechanical=1 (tick: $(LASTTICK))"
[ "$(LFIELD carried)" = 0 ] && ok || bad "4: and carried stays 0 (tick: $(LASTTICK))"

# 4b. BOTH DECLINE — both are asked, and the lane runs its own mechanical rung.
CLEAN
BOTH 1 1
ROWADD "o/p1#25" "$NOW" "$CONFLICT" "https://github.com/o/p1/pull/25"
RUN
[ "$(cut -d'|' -f1 "$T/hooks.txt" | tr '\n' ' ')" = "carry conflict " ] && ok \
  || bad "4b: both hooks are asked (hooks: $(cut -d'|' -f1 "$T/hooks.txt" | tr '\n' ' '))"
case "$(ORDER)" in *mechanical*) ok ;; *) bad "4b: the lane's own rung must run (order: $(ORDER))" ;; esac
[ "$(LFIELD mechanical)" = 0 ] && ok || bad "4b: and nothing is counted (tick: $(LASTTICK))"

# ============================================================================
# 5. THE FAMILY PRE-HOOK CARRIES A STORED RULING. rc 0 = br_adjudicate returns
#    without buying a model call, without posting an adjudication comment and
#    without spending the once-per-ticket adjudication counter.
# ============================================================================
CLEAN
FAMILY 0
ROWADD "o/p1#23" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/23"
RUN
[ "$(HFIELD pre 2)" = 5 ] && ok || bad "5: the pre hook gets five arguments (got: $(HOOKS pre | head -1))"
[ "$(HFIELD pre 3)" = p1 ] && ok || bad "5: arg1 is the project (got: $(HFIELD pre 3))"
[ "$(HFIELD pre 5)" = "iron-law" ] && ok \
  || bad "5: arg3 is the classified reason word (got: $(HFIELD pre 5))"
[ "$(HFIELD pre 7)" = "https://github.com/o/p1/pull/23" ] && ok \
  || bad "5: arg5 is the PR url (got: $(HFIELD pre 7))"
[ "$(NAGENT)" = 0 ] && ok || bad "5: a carried ruling buys NO model call (agent: $(cat "$T/agent.txt"))"
[ "$(LFIELD families)" = 1 ] && ok || bad "5: families=1 (tick: $(LASTTICK))"
[ "$(LFIELD llm_rungs)" = 0 ] && ok || bad "5: and no llm rung (tick: $(LASTTICK))"
grep -q '_Adjudication by' "$T/comments.txt" && bad "5: no ruling is posted (comments: $(cat "$T/comments.txt"))" || ok
# No record at all is the same fact as a record at zero: nothing was spent.
ADJN=$(STATEJSON p1 p1-TK-23 | jq -r '.adjudications // 0' 2>/dev/null); [ -n "$ADJN" ] || ADJN=0
[ "$ADJN" = 0 ] && ok \
  || bad "5: and the once-per-ticket adjudication counter is untouched (record: $(STATEJSON p1 p1-TK-23))"
[ -z "$(HOOKS record)" ] && ok || bad "5: a carried ruling stores nothing new (hooks: $(HOOKS record))"

# ============================================================================
# 6. THE RECORD HOOK SEES THE VERDICT — AND THE ACCEPT. The code writes the
#    per-PR ironlaw-head-accept row FIRST (BH-7804: it replaced the
#    iron-law-accepted-<head> file); the family row is second, so a module may
#    key its store on an ACCEPT that is already recorded.
# ============================================================================
CLEAN
FAMILY 1
RECMK "p1-TK-23-1" "https://github.com/o/p1/pull/23"
ROWADD "o/p1#23" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/23"
BRENV=(ADJ_VERDICT=ACCEPT)
RUN
BRENV=()
[ "$(NAGENT)" = 1 ] && ok || bad "6: a declined pre-hook buys the model call (agent calls: $(NAGENT))"
[ "$(LFIELD llm_rungs)" = 1 ] && ok || bad "6: which is the llm rung (tick: $(LASTTICK))"
[ "$(HFIELD record 2)" = 6 ] && ok || bad "6: the record hook gets six arguments (got: $(HOOKS record))"
[ "$(HFIELD record 8)" = ACCEPT ] && ok || bad "6: arg6 is the verdict (got: $(HOOKS record))"
[ "$(HOOKS record | head -1 | sed -n 's/.*|marker=//p')" = yes ] && ok \
  || bad "6: the ironlaw-head-accept row must already be written when the hook runs (got: $(HOOKS record))"
[ "$(LFIELD families)" = 0 ] && ok || bad "6: recording is not carrying (tick: $(LASTTICK))"

# 6b. A REJECT IS RECORDED TOO — the store is of RULINGS, not of accepts.
CLEAN
FAMILY 1
ROWADD "o/p1#23" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/23"
BRENV=(ADJ_VERDICT=REJECT)
RUN
BRENV=()
[ "$(HFIELD record 8)" = REJECT ] && ok || bad "6b: a REJECT reaches the hook (got: $(HOOKS record))"

# 6c. NO VERDICT IS NOT A RULING. A dead session stores nothing.
CLEAN
FAMILY 1
ROWADD "o/p1#23" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/23"
BRENV=(ADJ_VERDICT=MAYBE)
RUN
BRENV=()
[ -z "$(HOOKS record)" ] && ok || bad "6c: no verdict, no stored ruling (hooks: $(HOOKS record))"
[ "$(LFIELD llm_rungs)" = 1 ] && ok || bad "6c: the call still happened and is counted (tick: $(LASTTICK))"

# ============================================================================
# 7. A HALF-SYNCED MODULE. bin/ travels to a box file by file, so a tick can see
#    a module that does not parse. ONE line, today's path, no ALERTS.log — the
#    opposite of the REQUIRED loop, which pages and exits 1.
# ============================================================================
CLEAN
MODW mechanical <<< 'if [ ; then'
ROWADD "o/p1#23" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/23"
RUN
[ "$RC" = 0 ] && ok || bad "7: an unparseable optional module must not fail the tick (rc $RC)"
[ "$(NLINES 'bin/lib/br/opt/mechanical.sh does not parse')" = 1 ] && ok \
  || bad "7: exactly one line says so (log: $(LOG | tail -5))"
[ ! -f "$H/logs/ALERTS.log" ] && ok || bad "7: and it is not an alert (alerts: $(cat "$H/logs/ALERTS.log"))"
[ "$(ORDER)" = "adjudicate " ] && ok || bad "7: the tick runs today's path (order: $(ORDER))"
[ "$(NAGENT)" = 1 ] && ok || bad "7: including its model call (agent calls: $(NAGENT))"

# ============================================================================
# 8. THE KILL SWITCH. One knob turns every optional rung off; nobody adds a
#    per-behaviour flag.
# ============================================================================
CLEAN
CARRY 0
ROWADD "o/p1#23" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/23"
BRENV=(BR_OPT_OFF=mechanical)
RUN
BRENV=()
[ -z "$(HOOKS carry)" ] && ok || bad "8: BR_OPT_OFF leaves the module unsourced (hooks: $(cat "$T/hooks.txt"))"
[ "$(NAGENT)" = 1 ] && ok || bad "8: and the lane does its own work (agent calls: $(NAGENT))"

# 8b. A COMMA LIST, no spaces, any order.
CLEAN
CARRY 0
ROWADD "o/p1#23" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/23"
BRENV=(BR_OPT_OFF=family,mechanical)
RUN
BRENV=()
[ -z "$(HOOKS carry)" ] && ok || bad "8b: every named module is skipped (hooks: $(cat "$T/hooks.txt"))"

# 8c. A NAME NOBODY SHIPS is ignored, silently, and the real module still loads.
CLEAN
CARRY 0
ROWADD "o/p1#23" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/23"
BRENV=(BR_OPT_OFF=nosuchmodule)
RUN
BRENV=()
[ -n "$(HOOKS carry)" ] && ok || bad "8c: an unknown name must not turn everything off (hooks: $(cat "$T/hooks.txt"))"

# ============================================================================
# 9. A MODULE THAT FAILS ON SOURCE. One line, and the tick finishes.
# ============================================================================
CLEAN
MODW mechanical <<'EOF'
br_opt_carry_rung() { return 1; }
false
EOF
ROWADD "o/p1#23" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/23"
RUN
[ "$RC" = 0 ] && ok || bad "9: a failed source must not fail the tick (rc $RC)"
[ "$(NLINES 'bin/lib/br/opt/mechanical.sh failed on source')" = 1 ] && ok \
  || bad "9: exactly one line says so (log: $(LOG | tail -5))"
[ -n "$(LASTTICK)" ] && ok || bad "9: and the tick completes (log: $(LOG | tail -5))"

# ============================================================================
# 10. AN IDLE TICK IS STILL SILENT with a module loaded. The loader must not be
#     the thing that starts writing a line every ten minutes for ever, so the
#     idle log is compared BYTE FOR BYTE (timestamps stripped) against the same
#     idle tick with no optional module at all.
# ============================================================================
CLEAN
RUN
LOG | sed -E 's/^[0-9-]+ [0-9:]+Z //' > "$T/idle-bare.txt"
CLEAN
CARRY 0
RUN
[ "$RC" = 0 ] && ok || bad "10: an idle tick exits 0 (rc $RC)"
LOG | sed -E 's/^[0-9-]+ [0-9:]+Z //' > "$T/idle-mod.txt"
diff -q "$T/idle-bare.txt" "$T/idle-mod.txt" >/dev/null && ok \
  || bad "10: a loaded module must add nothing to an idle tick ($(diff "$T/idle-bare.txt" "$T/idle-mod.txt" | head -4))"
[ -z "$(LASTTICK)" ] && ok || bad "10: and an idle tick still writes no tick line (got: $(LASTTICK))"

# ============================================================================
# 11. THE KNOBS REACH THE MODULE. A knob the lane reads but a hook cannot see
#     is a knob the console can explain and nothing can obey.
# ============================================================================
CLEAN
KNOBS
ROWADD "o/p1#23" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/23"
BRENV=(BR_FAMILY_TTL_SECS=60)
RUN
BRENV=()
[ "$(sed -n '1s/ .*//p' "$T/knobs.txt" 2>/dev/null)" = "ttl=60" ] && ok \
  || bad "11: a set TTL reaches the hook (got: $(cat "$T/knobs.txt" 2>/dev/null))"

# 11b. A TYPO IS A FALLBACK, not a value the module has to defend against (D11).
CLEAN
KNOBS
ROWADD "o/p1#23" "$NOW" "$IRONLAW" "https://github.com/o/p1/pull/23"
BRENV=(BR_FAMILY_TTL_SECS=abc)
RUN
BRENV=()
[ "$(sed -n '1s/ .*//p' "$T/knobs.txt" 2>/dev/null)" = "ttl=0" ] && ok \
  || bad "11b: a non-numeric TTL falls back to 0 (got: $(cat "$T/knobs.txt" 2>/dev/null))"

# ============================================================================
# 12. THE REGISTRY CARRIES THE TWO KNOBS AND NOTHING ELSE NEW, and the seam is
#     the seam the siblings asked for — no prepass/cost/rebuild_ok hook that
#     #1480 already made redundant (the operator, 2026-09-22T20:15Z).
# ============================================================================
LANEJ="$DIR/catalog/lanes.d/blocked-resolver.json"
[ "$(jq -r '.knobs[].env' "$LANEJ" | grep -cxE 'BR_OPT_OFF|BR_FAMILY_TTL_SECS')" = 2 ] && ok \
  || bad "12: both knobs must be declared on the lane (got: $(jq -r '.knobs[].env' "$LANEJ" | grep -xE 'BR_OPT_OFF|BR_FAMILY_TTL_SECS' | tr '\n' ' '))"
( cd "$DIR" && HARNESS_TEST_SANDBOX=1 bin/lanes-build.sh --to "$T/lanes.json" >/dev/null 2>&1 )
[ "$(jq -r '.lanes[]|select(.id=="blocked-resolver")|.knobs[]|select(.env=="BR_FAMILY_TTL_SECS")|.zero_means' "$T/lanes.json" 2>/dev/null)" = unlimited ] && ok \
  || bad "12: 0 must render as unlimited in the composed registry"
[ "$(grep -c 'br_opt_prepass\|br_opt_cost_sort\|br_opt_rebuild_ok' "$DIR/bin/blocked-resolver.sh")" = 0 ] && ok \
  || bad "12: this slice adds no seam #1480 already made redundant"

# ============================================================================
# 13. THE CONTRACT SHIPS NEXT TO THE FILE A SIBLING WRITES.
# ============================================================================
RM="$DIR/bin/lib/br/opt/README.md"
[ -s "$RM" ] && ok || bad "13: bin/lib/br/opt/README.md must exist"
MISSING=""
for n in br_opt_carry_rung br_opt_conflict_rung br_opt_family_pre br_opt_family_record br_count BR_OPT_OFF; do
  grep -qF "$n" "$RM" 2>/dev/null || MISSING="$MISSING $n"
done
[ -z "$MISSING" ] && ok || bad "13: the contract must name every hook:$MISSING"

echo "blocked-resolver opt hooks (BH-1468): $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
