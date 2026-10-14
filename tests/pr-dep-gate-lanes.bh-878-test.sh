#!/bin/bash
# tests/pr-dep-gate-lanes.bh-878-test.sh — BH-878 (BH-629.2): the four automatic
# merge writers ask the PR-dependency gate BEFORE they write.
#
# THE INCIDENT. #615 merged at 03:33Z on 2026-09-17 while its own body said
# "Depends on #459 (PR #609) for tests/lib/scratch.sh" and #609 was still open.
# Main then carried a suite sourcing a file main did not have, every open PR went
# red for about 7.5 hours, and the sweep will not touch a red PR — so the repo
# froze. A gate on ONE lane is not a gate: whichever lane picks the PR up first
# is the one that lands it, so this suite drives all four.
#
# Driven, not grepped. The conductor, the sweep, the merge train and the tier-1
# gate each extract their production block VERBATIM by its `# >>> dep gate`
# markers and run THAT; the serial queue case runs bin/merge-queue.sh WHOLE.
# Every assertion is on an artifact — state/merge-conductor/attempts.txt, the
# lane logs, the alert sink, the `gh pr merge` sink, RESULT — and never on source
# text. Delete any one of the four call sites and its named case goes red.
#
# pdg_hold IS STUBBED HERE (rc 0 hold / rc 1 pass / rc 2 could-not-read, per
# case). That is deliberate: this slice proves the wiring against the contract
# signature, not against BH-629.1's parser, which is what lets it build in the
# same wave as the library.
#
# Every fixture value is a literal. Nothing here reads the wall clock.
# Run from anywhere: tests/pr-dep-gate-lanes.bh-878-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SLUG=example-org/demo-os
NUM=41
PRURL="https://github.com/$SLUG/pull/41"
KEY="$SLUG#$NUM"
H1=aaaaaaaa1111
H2=bbbbbbbb2222
DEP='#609 (PR #612)'      # what BH-629.1's parser will print on stdout

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state/merge-conductor" "$T/h/flags" "$T/h/locks" \
         "$T/h/env" "$T/h/builds" "$T/fakebin"
cp "$DIR/bin/merge-queue.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
# gh-rest.sh rides along: the conductor lib sources it (BH-784) and the queue's
# reads go through it, so a fixture without the file exercises a lib whose REST
# helpers silently do not exist.
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/block-gate.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
printf 'demo-os %s - - 2 box-demo\n' "$SLUG" > "$T/h/fleet.conf"
export FLEET_CONF="$T/h/fleet.conf"
: > "$T/h/env/global.env"; : > "$T/h/env/demo-os.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
for s in beat.sh deploy-request.sh lander.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/$s"; chmod +x "$T/h/bin/$s"
done
printf '#!/bin/bash\nprintf "{}\\n404\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"

# One gh shim for every section. `pr merge` argv lands in its own sink, which is
# what "a hold writes nothing to GitHub" is asserted on.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none". An unanswered probe is "unknown" now, and unknown holds.
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"pr merge"*)   printf '%s\n' "\$*" >> "$T/gh-merges.txt"; exit 0 ;;
  *"pr comment"*) printf '%s\n' "\$*" >> "$T/gh-comments.txt"; exit 0 ;;
  # The queue's reads are REST since BH-784 (gh api -i, judged on the HTTP
  # status line). Same facts as the --json arms below, which stay for whichever
  # lane in this suite still asks the old way: OPEN and mergeable on head $H1,
  # MERGED once the merge verb has run.
  *"api -i -X GET repos/"*"/pulls/"*)
    printf 'HTTP/1.1 200 OK\r\nServer: x\r\n\r\n'
    if [ -s "$T/gh-merges.txt" ]; then ST=closed; MA='"2026-09-18T00:00:00Z"'; else ST=open; MA=null; fi
    BR=ticket/TK-41
    case "\$*" in *"/pulls/7"*) BR=ticket/TK-7 ;; *"/pulls/8"*) BR=ticket/TK-8 ;; esac
    printf '{"state":"%s","merged_at":%s,"head":{"sha":"$H1","ref":"%s"},"base":{"ref":"main"},"labels":[],"mergeable":true,"mergeable_state":"clean","user":{"login":"app/cromford","type":"Bot"},"merge_commit_sha":"cccccccc3333","body":"harness PR body"}\n' "\$ST" "\$MA" "\$BR"
    exit 0 ;;
  *"--json headRefOid"*) echo "$H1" ;;
  *"--json state,mergeable,headRefName"*) echo "OPEN MERGEABLE ticket/TK-41" ;;
  *"--json state,headRefName"*) echo "OPEN ticket/TK-41" ;;
  *"--json state"*) [ -s "$T/gh-merges.txt" ] && echo MERGED || echo OPEN ;;
  *"--json mergeCommit"*) echo cccccccc3333 ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

# The conductor's one alert path is mc_alert, which execs bin/lane-alert.sh
# without --critical. The stub counts the lines; the failing variant is how
# "the dedupe line is written BEFORE the send" is proved.
cat > "$T/alert-ok.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/alerts.txt"
exit 0
EOF
printf '#!/bin/bash\nexit 1\n' > "$T/alert-dead.sh"

# The fixture stand-in for bin/lib/pr-dep-gate.sh, for the cases that run a whole
# script rather than an extracted block: same two names, rc from the environment.
cat > "$T/pdg-stub.sh" <<'EOF'
#!/bin/bash
pdg_hold() { [ -n "${PDG_OUT:-}" ] && printf '%s' "$PDG_OUT"; return "${PDG_RC:-1}"; }
pdg_queue_hold() { pdg_hold "${SLUG:-}" "${1:-}" "https://github.com/${SLUG:-}/pull/${1:-}" ""; }
EOF

lines_of() { [ -f "$1" ] && wc -l < "$1" | tr -d ' ' || echo 0; }

# ============================================================================
# C. bin/merge-conductor.sh, READY) arm — the block extracted by its markers.
# ============================================================================
awk '/^      # >>> dep gate/{f=1;next} /^      # <<< dep gate/{exit} f' \
  "$DIR/bin/merge-conductor.sh" > "$T/dep-conductor.sh"
[ -s "$T/dep-conductor.sh" ] && ok || bad "could not extract the conductor's dep gate — markers missing?"
# The block lives inside the tick's worker function and ends its arm with
# `return 0`, so it is wrapped — verbatim, nothing retyped — in a function here
# too: `return` inside a plain `.` would only end the source and run on.
{ printf 'arm() {\n'; cat "$T/dep-conductor.sh"; printf '  printf "FELL_THROUGH\\n"\n}\n'; } > "$T/conductor-arm.sh"

CLOG="$T/h/logs/merge-conductor.log"
ATT="$T/h/state/merge-conductor/attempts.txt"
conductor_reset() { # conductor_reset [dead-alert]
  rm -rf "$T/h/state/merge-conductor" "$T/h/logs"
  mkdir -p "$T/h/state/merge-conductor" "$T/h/logs"
  : > "$T/alerts.txt"; : > "$T/transitions.txt"; : > "$T/budget.txt"
  : > "$T/gh-merges.txt"; : > "$T/gh-calls.txt"; : > "$T/gh-comments.txt"
  cp "$T/alert-${1:-ok}.sh" "$T/h/bin/lane-alert.sh"; chmod +x "$T/h/bin/lane-alert.sh"
}
conductor_arm() { # conductor_arm <pdg-rc> <head> [define=1] ; prints FELL_THROUGH when the gate passed
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" \
      SLUG="$SLUG" NUM="$NUM" URL="$PRURL" KEY="$KEY" HEAD="$2" \
      PDG_RC="$1" PDG_OUT="$DEP" PDG_DEFINE="${3:-1}" \
      TSINK="$T/transitions.txt" BSINK="$T/budget.txt" \
      bash -c 'set -uo pipefail
        if [ "$PDG_DEFINE" = 1 ]; then
          pdg_hold() { [ -n "$PDG_OUT" ] && printf "%s" "$PDG_OUT"; return "$PDG_RC"; }
        fi
        . "$HARNESS/bin/lib/merge-conductor-lib.sh"
        [ "$PDG_DEFINE" = 1 ] || unset -f pdg_hold
        mc_transition()      { printf "%s\n" "$*" >> "$TSINK"; }
        mc_tick_budget_left() { printf "take\n" >> "$BSINK"; return 0; }
        . "$1"
        arm' bash "$T/conductor-arm.sh" 2>"$T/conductor.err" )
}

# C1. conductor-ready-hold (rc 0): the row is held, one dedupe line, one log
#     line naming the dependency, exactly one alert, and nothing else moves.
conductor_reset
OUT=$(conductor_arm 0 "$H1")
grep -q FELL_THROUGH <<<"$OUT" && bad "conductor-ready-hold: the READY arm fell through to the merge on an open dependency" || ok
[ "$(cat "$ATT" 2>/dev/null)" = "depwaithold $KEY $H1" ] && ok || bad "conductor-ready-hold: attempts.txt must be exactly one depwaithold line (got '$(cat "$ATT" 2>/dev/null)')"
grep -q "READY and HELD by the PR-dependency gate" "$CLOG" && ok || bad "conductor-ready-hold: the log must say the row is held (log: $(cat "$CLOG" 2>/dev/null))"
grep -qF "$DEP" "$CLOG" && ok || bad "conductor-ready-hold: the log must name the dependency $DEP (log: $(cat "$CLOG" 2>/dev/null))"
[ "$(lines_of "$T/alerts.txt")" = 1 ] && ok || bad "conductor-ready-hold: exactly one lane alert on the first hold (got $(cat "$T/alerts.txt"))"
grep -q "pull/41" "$T/alerts.txt" && ok || bad "conductor-ready-hold: the alert must name the PR (got $(cat "$T/alerts.txt"))"
[ -s "$T/transitions.txt" ] && bad "conductor-ready-hold: a hold writes no state transition ($(cat "$T/transitions.txt"))" || ok
[ -s "$T/budget.txt" ] && bad "conductor-ready-hold: a hold sits before the budget check and spends nothing ($(cat "$T/budget.txt"))" || ok
[ -s "$T/gh-merges.txt" ] && bad "conductor-ready-hold: THE DEFECT — the conductor merged over an open dependency ($(cat "$T/gh-merges.txt"))" || ok
[ -s "$T/gh-comments.txt" ] && bad "conductor-ready-hold: a hold posts nothing on the PR ($(cat "$T/gh-comments.txt"))" || ok

# C2. conductor-ready-hold-second-tick: same head, no second line, no second alert.
OUT=$(conductor_arm 0 "$H1")
grep -q FELL_THROUGH <<<"$OUT" && bad "conductor-ready-hold-second-tick: the second tick merged" || ok
[ "$(lines_of "$ATT")" = 1 ] && ok || bad "conductor-ready-hold-second-tick: one dedupe line per (PR, head), got $(cat "$ATT")"
[ "$(lines_of "$T/alerts.txt")" = 1 ] && ok || bad "conductor-ready-hold-second-tick: no second alert at the same head (got $(cat "$T/alerts.txt"))"

# C3. conductor-rebase-realerts-once: a rebase moves the head, so the gate is
#     asked, logged and alerted again — once.
OUT=$(conductor_arm 0 "$H2")
[ "$(lines_of "$ATT")" = 2 ] && ok || bad "conductor-rebase-realerts-once: a new head takes its own dedupe line (got $(cat "$ATT"))"
[ "$(lines_of "$T/alerts.txt")" = 2 ] && ok || bad "conductor-rebase-realerts-once: a new head alerts once (got $(cat "$T/alerts.txt"))"
OUT=$(conductor_arm 0 "$H2")
[ "$(lines_of "$ATT")" = 2 ] && ok || bad "conductor-rebase-realerts-once: the same head twice adds nothing (got $(cat "$ATT"))"
[ "$(lines_of "$T/alerts.txt")" = 2 ] && ok || bad "conductor-rebase-realerts-once: the same head twice alerts once (got $(cat "$T/alerts.txt"))"

# C4. conductor-flag-before-send: the dedupe line is appended BEFORE the alert,
#     so a dead lane-alert.sh costs one line rather than one per tick.
conductor_reset dead
OUT=$(conductor_arm 0 "$H1")
grep -q FELL_THROUGH <<<"$OUT" && bad "conductor-flag-before-send: a failed alert must not turn a hold into a merge" || ok
[ "$(cat "$ATT" 2>/dev/null)" = "depwaithold $KEY $H1" ] && ok || bad "conductor-flag-before-send: the dedupe line must survive a dead alert (got '$(cat "$ATT" 2>/dev/null)')"
[ -s "$T/alerts.txt" ] && bad "conductor-flag-before-send: the dead stub records nothing by construction" || ok

# C5. conductor-unreadable-hold (rc 2): fail closed, own dedupe key, no alert.
conductor_reset
OUT=$(conductor_arm 2 "$H1")
grep -q FELL_THROUGH <<<"$OUT" && bad "conductor-unreadable-hold: rc 2 is a HOLD, never a pass" || ok
[ "$(cat "$ATT" 2>/dev/null)" = "depwaitunread $KEY $H1" ] && ok || bad "conductor-unreadable-hold: rc 2 takes its own depwaitunread key (got '$(cat "$ATT" 2>/dev/null)')"
grep -q "could not read" "$CLOG" && ok || bad "conductor-unreadable-hold: the log must say the gate could not read (log: $(cat "$CLOG" 2>/dev/null))"
[ -s "$T/alerts.txt" ] && bad "conductor-unreadable-hold: an unread dependency pages nobody ($(cat "$T/alerts.txt"))" || ok
[ -s "$T/gh-merges.txt" ] && bad "conductor-unreadable-hold: nothing merges on an unread dependency" || ok

# C6. conductor-pass-falls-through (rc 1): the arm continues to the merge path
#     exactly as it did before BH-629.
conductor_reset
OUT=$(conductor_arm 1 "$H1")
grep -q FELL_THROUGH <<<"$OUT" && ok || bad "conductor-pass-falls-through: rc 1 must fall through to the merge path (err: $(cat "$T/conductor.err"))"
[ "$(lines_of "$ATT")" = 0 ] && ok || bad "conductor-pass-falls-through: a pass records nothing ($(cat "$ATT"))"
[ -s "$T/alerts.txt" ] && bad "conductor-pass-falls-through: a pass alerts nobody ($(cat "$T/alerts.txt"))" || ok

# C7. gate-absent-conductor: no pr-dep-gate.sh in the tree and pdg_hold
#     undefined — the arm is byte-for-byte pre-BH-629.
conductor_reset
OUT=$(conductor_arm 0 "$H1" 0)
grep -q FELL_THROUGH <<<"$OUT" && ok || bad "gate-absent-conductor: an absent gate must merge as before (err: $(cat "$T/conductor.err"))"
[ "$(lines_of "$ATT")" = 0 ] && ok || bad "gate-absent-conductor: an absent gate records nothing ($(cat "$ATT"))"
[ -s "$T/alerts.txt" ] && bad "gate-absent-conductor: an absent gate alerts nobody" || ok

# ============================================================================
# S. bin/merge-sweep.sh — the lane that merged #615 ahead of #609.
# ============================================================================
awk '/^  # >>> dep gate/{f=1;next} /^  # <<< dep gate/{exit} f' \
  "$DIR/bin/merge-sweep.sh" > "$T/dep-sweep.sh"
[ -s "$T/dep-sweep.sh" ] && ok || bad "could not extract the sweep's dep gate — markers missing?"

SWLOG="$T/sweep.log"
sweep_arm() { # sweep_arm <pdg-rc> [define=1] ; prints FELL_THROUGH when the gate passed
  : > "$SWLOG"; : > "$T/claims.txt"; : > "$T/gh-merges.txt"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" \
      PA_SLUG="$SLUG" PA_NUM="$NUM" LOG="$SWLOG" \
      PDG_RC="$1" PDG_OUT="$DEP" PDG_DEFINE="${2:-1}" CSINK="$T/claims.txt" \
      bash -c 'set -uo pipefail
        if [ "$PDG_DEFINE" = 1 ]; then
          pdg_hold() { [ -n "$PDG_OUT" ] && printf "%s" "$PDG_OUT"; return "$PDG_RC"; }
        fi
        STAMP()       { printf TS; }
        sweep_claim() { printf "claim\n"  >> "$CSINK"; }
        sweep_record() { printf "record\n" >> "$CSINK"; }
        for PR in "$2"; do
          . "$1"
          sweep_claim
          printf "FELL_THROUGH\n"
        done' bash "$T/dep-sweep.sh" "$PRURL" 2>"$T/sweep.err" )
}

# S1. sweep-hold (rc 0): one log line naming the dependency, no claim, no ledger
#     row, no gh write, and the PR is simply re-offered next pass.
OUT=$(sweep_arm 0)
grep -q FELL_THROUGH <<<"$OUT" && bad "sweep-hold: the sweep merged over an open dependency" || ok
grep -q "not merged this pass: HELD by the PR-dependency gate" "$SWLOG" && ok || bad "sweep-hold: the sweep must log the hold (log: $(cat "$SWLOG"))"
grep -qF "$DEP" "$SWLOG" && ok || bad "sweep-hold: the log must name the dependency (log: $(cat "$SWLOG"))"
[ -s "$T/claims.txt" ] && bad "sweep-hold: a held PR is neither claimed nor ledgered ($(cat "$T/claims.txt"))" || ok
[ -s "$T/gh-merges.txt" ] && bad "sweep-hold: THE DEFECT — the sweep merged ahead of the dependency ($(cat "$T/gh-merges.txt"))" || ok

# S2. sweep-unreadable-hold (rc 2).
OUT=$(sweep_arm 2)
grep -q FELL_THROUGH <<<"$OUT" && bad "sweep-unreadable-hold: rc 2 is a HOLD, never a pass" || ok
grep -q "could not read" "$SWLOG" && ok || bad "sweep-unreadable-hold: the log must say the gate could not read (log: $(cat "$SWLOG"))"
[ -s "$T/claims.txt" ] && bad "sweep-unreadable-hold: nothing is claimed on an unread dependency" || ok

# S3. sweep-pass-falls-through (rc 1) and gate-absent-sweep.
OUT=$(sweep_arm 1)
grep -q FELL_THROUGH <<<"$OUT" && ok || bad "sweep-pass-falls-through: rc 1 must reach sweep_claim (err: $(cat "$T/sweep.err"))"
[ -s "$SWLOG" ] && bad "sweep-pass-falls-through: a pass says nothing ($(cat "$SWLOG"))" || ok
OUT=$(sweep_arm 0 0)
grep -q FELL_THROUGH <<<"$OUT" && ok || bad "gate-absent-sweep: an absent gate must merge as before (err: $(cat "$T/sweep.err"))"
[ -s "$SWLOG" ] && bad "gate-absent-sweep: an absent gate says nothing ($(cat "$SWLOG"))" || ok

# ============================================================================
# Q. bin/merge-queue.sh — run WHOLE on the serial path, then the two train
#    loops extracted by their markers.
# ============================================================================
Q="$T/h/state/merge-queue/demo-os"; mkdir -p "$Q"
MQLOG="$T/h/logs/merge-queue.log"
mq() { # mq <pdg-rc> ; one queued entry, the whole script
  : > "$T/gh-merges.txt"; : > "$T/gh-calls.txt"; : > "$MQLOG"
  rm -f "$Q"/*; : > "$Q/41"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" \
      PDG_RC="$1" PDG_OUT="$DEP" \
      bash "$T/h/bin/merge-queue.sh" demo-os >/dev/null 2>"$T/mq.err" ) || true
}

# Q1. queue-serial-hold: the gate holds the landing at :454, the entry stays
#     queued and is never parked .blocked — the hold ends by itself.
cp "$T/pdg-stub.sh" "$T/h/bin/lib/pr-dep-gate.sh"
mq 0
[ -s "$T/gh-merges.txt" ] && bad "queue-serial-hold: THE DEFECT — the box queue landed #41 over an open dependency ($(cat "$T/gh-merges.txt"))" || ok
grep -q "#41 HELD by the PR-dependency gate" "$MQLOG" && ok || bad "queue-serial-hold: the queue must log the hold (log: $(cat "$MQLOG") err: $(cat "$T/mq.err"))"
grep -qF "$DEP" "$MQLOG" && ok || bad "queue-serial-hold: the log must name the dependency (log: $(cat "$MQLOG"))"
[ -f "$Q/41" ] && ok || bad "queue-serial-hold: the entry must stay queued — it lands when the dependency closes"
[ -f "$Q/41.blocked" ] && bad "queue-serial-hold: a dependency hold must not park the entry .blocked" || ok

# Q2. queue-unreadable-hold (rc 2) — fail closed on the serial path too.
mq 2
[ -s "$T/gh-merges.txt" ] && bad "queue-unreadable-hold: rc 2 is a HOLD, never a landing ($(cat "$T/gh-merges.txt"))" || ok
grep -q "could not read" "$MQLOG" && ok || bad "queue-unreadable-hold: the log must say the gate could not read (log: $(cat "$MQLOG"))"
[ -f "$Q/41" ] && ok || bad "queue-unreadable-hold: the entry must stay queued"

# Q3. queue-pass-lands (rc 1) — the queue lands exactly as it always has.
mq 1
grep -q "pr merge 41" "$T/gh-merges.txt" && ok || bad "queue-pass-lands: rc 1 must land the entry (log: $(cat "$MQLOG") err: $(cat "$T/mq.err"))"
[ -f "$Q/41" ] && bad "queue-pass-lands: a landed entry is removed from the queue" || ok

# Q4. gate-absent-queue: no pr-dep-gate.sh in the tree at all.
rm -f "$T/h/bin/lib/pr-dep-gate.sh"
mq 0
grep -q "pr merge 41" "$T/gh-merges.txt" && ok || bad "gate-absent-queue: an absent gate must land as before (log: $(cat "$MQLOG") err: $(cat "$T/mq.err"))"
rm -f "$Q"/*

# Q5. queue-train-members-hold: the union train's member loop, extracted
#     verbatim with the queue's own dep-gate wrapper — a held PR never enters
#     the batch, so it is not typechecked into the candidate either.
awk '/^    # >>> head-bound train members/{f=1;next} /^    # <<< head-bound train members/{exit} f' \
  "$DIR/bin/merge-queue.sh" > "$T/train.sh"
[ -s "$T/train.sh" ] && ok || bad "could not extract the train member loop — markers missing?"
awk '/^# >>> block gate/{f=1;next} /^# <<< block gate/{exit} f' \
  "$DIR/bin/merge-queue.sh" > "$T/qhold.sh"
[ -s "$T/qhold.sh" ] && ok || bad "could not extract bg_queue_hold from bin/merge-queue.sh"
awk '/^# >>> dep gate/{f=1;next} /^# <<< dep gate/{exit} f' \
  "$DIR/bin/merge-queue.sh" > "$T/qdep.sh"
[ -s "$T/qdep.sh" ] && ok || bad "could not extract the queue's dep-gate wrapper — markers missing?"
# mq_land is the queue's own landing call (BH-892), lifted by ITS markers for the
# same reason bg_queue_hold is: the landing loop under test calls it by name.
# With no bin/lib/gh-pr-merge.sh in this fixture it is today's `gh pr merge`
# line, which is what the fake gh records and this lane asserts on.
awk '/^# >>> mq_land/{f=1;next} /^# <<< mq_land/{exit} f' \
  "$DIR/bin/merge-queue.sh" > "$T/mqland.sh"
[ -s "$T/mqland.sh" ] && ok || bad "could not extract mq_land from bin/merge-queue.sh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/git"; chmod +x "$T/fakebin/git"
: > "$T/train.log"; : > "$T/gh-merges.txt"
BATCH_OUT=$( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" SLUG="$SLUG" PROJECT=demo-os \
  LOG="$T/train.log" WT="$T" QUEUED="7 8" PDG_OUT="$DEP" \
  bash -c 'set -uo pipefail
    STAMP() { printf TS; }
    bh_held()   { return 1; }
    hb_blocked() { return 1; }
    # The member loop reads through mq_pr since BH-784 and this snippet runs
    # outside the script that defines it, so it is stubbed here with the same
    # two facts the old --json state,headRefName arm handed it, plus the base
    # ref the BH-1285 stacked-PR hold reads (main, so the hold stays out of it).
    mq_pr() { printf "OPEN ticket/aio-%s main" "$1"; }
    mc_rest_status() { printf "?"; }
    pdg_queue_hold() { [ "$1" = 7 ] || return 1; printf "%s" "$PDG_OUT"; return 0; }
    . "'"$T"'/qhold.sh"
    . "'"$T"'/qdep.sh"
    BATCH=""
    . "$0"
    printf "BATCH=[%s]" "$BATCH"' "$T/train.sh" 2>"$T/train.err" )
grep -q 'BATCH=\[ 8\]' <<<"$BATCH_OUT" && ok || bad "queue-train-members-hold: a held PR must not enter the train's batch (got $BATCH_OUT, stderr: $(cat "$T/train.err"))"
grep -q "#7 HELD by the PR-dependency gate" "$T/train.log" && ok || bad "queue-train-members-hold: the log must name the held member (log: $(cat "$T/train.log"))"

# Q6. queue-train-landing-hold: assembly and landing are minutes apart, so the
#     question is asked again at the write — a member held in that window is not
#     one of the cheap gh merges.
awk '/^        # >>> train landing/{f=1;next} /^        # <<< train landing/{exit} f' \
  "$DIR/bin/merge-queue.sh" > "$T/land.sh"
[ -s "$T/land.sh" ] && ok || bad "could not extract the train landing loop — markers missing?"
: > "$T/gh-merges.txt"; : > "$T/land.log"
( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" SLUG="$SLUG" PROJECT=demo-os \
  LOG="$T/land.log" Q="$Q" BATCH="7 8" PDG_OUT="$DEP" \
  bash -c 'set -uo pipefail
    STAMP() { printf TS; }
    MQROW() { :; }
    bh_held()   { return 1; }
    hb_blocked() { return 1; }
    # The member loop reads through mq_pr since BH-784 and this snippet runs
    # outside the script that defines it, so it is stubbed here with the same
    # two facts the old --json state,headRefName arm handed it, plus the base
    # ref the BH-1285 stacked-PR hold reads (main, so the hold stays out of it).
    mq_pr() { printf "OPEN ticket/aio-%s main" "$1"; }
    mc_rest_status() { printf "?"; }
    pdg_queue_hold() { [ "$1" = 7 ] || return 1; printf "%s" "$PDG_OUT"; return 0; }
    LANDED=0; LAST_SHA=""
    . "'"$T"'/qhold.sh"
    . "'"$T"'/qdep.sh"
    . "'"$T"'/mqland.sh"
    . "$0"' "$T/land.sh" >/dev/null 2>"$T/land.err" ) || true
grep -q 'pr merge 7 ' "$T/gh-merges.txt" && bad "queue-train-landing-hold: a member held between assembly and landing must not be merged ($(cat "$T/gh-merges.txt"))" || ok
grep -q 'pr merge 8 ' "$T/gh-merges.txt" && ok || bad "queue-train-landing-hold: the rest of the train must still land ($(cat "$T/gh-merges.txt"), stderr: $(cat "$T/land.err"))"
grep -q "#7 HELD by the PR-dependency gate" "$T/land.log" && ok || bad "queue-train-landing-hold: the log must name the held member (log: $(cat "$T/land.log"))"

# ============================================================================
# B. bin/run-build.sh's tier-1 merge gate, extracted and driven exactly as
#    tests/block-gate-lanes-test.sh section B drives it.
# ============================================================================
awk '/^# >>> tier-1 merge gate/{f=1;next} /^# <<< tier-1 merge gate/{exit} f' \
  "$RB_ALL" > "$T/gate.sh"
[ -s "$T/gate.sh" ] && ok || bad "could not extract the tier-1 merge gate — markers missing?"
run_gate() { # run_gate <pdg-rc> [define=1] ; prints the RESULT line
  rm -f "$T/RESULT"; mkdir -p "$T/h/builds/gate"
  printf 'VERDICT: APPROVE\n' > "$T/h/builds/gate/review.md"; printf 'plan\n' > "$T/h/builds/gate/plan.md"
  : > "$T/h/builds/gate/pipeline.log"; : > "$T/gh-merges.txt"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" BUILD="$T/h/builds/gate" ALERTS="$T/h/logs/ALERTS.log" \
      PROJECT=demo-os KEY=TK-41 SLUG="$SLUG" TIER=1 PR_URL="$PRURL" \
      QA_NOTE="" MIG_NOTE="" REBASE_NOTE="" CLOSES_LINE="Closes #41" HEADBOUND_SHA="$H1" \
      BUILDER_NO_MERGE= PDG_RC="$1" PDG_OUT="$DEP" PDG_DEFINE="${2:-1}" \
      bash -c 'set -uo pipefail
        STAMP() { printf TS; }
        RESULT() { echo "$*" > '"$T"'/RESULT; }
        BB() { :; }
        CLOSE_ISSUE_AFTER_MERGE() { :; }
        mc_queue_conductor_only() { return 1; }
        mc_pr_queued() { return 1; }
        if [ "$PDG_DEFINE" = 1 ]; then
          pdg_hold() { [ -n "$PDG_OUT" ] && printf "%s" "$PDG_OUT"; return "$PDG_RC"; }
        fi
        . "$HARNESS/bin/lib/block-gate.sh"
        . "$0"' "$T/gate.sh" >/dev/null 2>"$T/gate.err" ) || true
  cat "$T/RESULT" 2>/dev/null
}

# B1. tier1-hold (rc 0): the build stands down to PR_CREATED, the PR stays open.
OUT=$(run_gate 0)
[ -s "$T/gh-merges.txt" ] && bad "tier1-hold: THE DEFECT — the build merged its own PR over an open dependency ($(cat "$T/gh-merges.txt"))" || ok
grep -q "^PR_CREATED $PRURL" <<<"$OUT" && ok || bad "tier1-hold: a held tier-1 build exits through PR_CREATED (got '$OUT', stderr: $(cat "$T/gate.err"))"
grep -q "tier-1 merge HELD by the PR-dependency gate" "$T/h/builds/gate/pipeline.log" && ok || bad "tier1-hold: the build log must say why (log: $(cat "$T/h/builds/gate/pipeline.log"))"
grep -qF "$DEP" "$T/h/builds/gate/pipeline.log" && ok || bad "tier1-hold: the build log must name the dependency (log: $(cat "$T/h/builds/gate/pipeline.log"))"

# B2. tier1-unreadable-hold (rc 2).
OUT=$(run_gate 2)
[ -s "$T/gh-merges.txt" ] && bad "tier1-unreadable-hold: rc 2 is a HOLD, never a merge" || ok
grep -q "^PR_CREATED $PRURL" <<<"$OUT" && ok || bad "tier1-unreadable-hold: rc 2 exits through PR_CREATED (got '$OUT')"
grep -q "could not read" "$T/h/builds/gate/pipeline.log" && ok || bad "tier1-unreadable-hold: the log must say the gate could not read (log: $(cat "$T/h/builds/gate/pipeline.log"))"

# B3. tier1-pass-merges (rc 1) and gate-absent-tier1: the tier-1 step merges
#     exactly as it always has.
OUT=$(run_gate 1)
grep -q "^PR_MERGED $PRURL" <<<"$OUT" && ok || bad "tier1-pass-merges: rc 1 must merge as before (got '$OUT', stderr: $(cat "$T/gate.err"))"
[ -s "$T/gh-merges.txt" ] && ok || bad "tier1-pass-merges: the merge must reach gh ($(cat "$T/gh-merges.txt"))"
OUT=$(run_gate 0 0)
grep -q "^PR_MERGED $PRURL" <<<"$OUT" && ok || bad "gate-absent-tier1: an absent gate merges as before (got '$OUT', stderr: $(cat "$T/gate.err"))"
[ -s "$T/gh-merges.txt" ] && ok || bad "gate-absent-tier1: the merge must reach gh with no gate installed"

echo "pr-dep-gate-lanes.bh-878: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
