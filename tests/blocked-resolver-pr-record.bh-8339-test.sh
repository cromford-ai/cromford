#!/bin/bash
# tests/blocked-resolver-pr-record.bh-8339-test.sh — BH-8339: the resolver's
# ABANDONED terminal and ladder bind to one PR, a fix round never runs on
# another (closed) PR's branch, the branch's own lint is in the round's prompt,
# and the PR body is written only after a push.
#
# WHAT HAPPENED (BH-8062, 2026-10-25). The resolver abandoned PR #8294 and
# retired the ticket's record as ABANDONED. The rebuilt PR #8301 then got a lead
# BLOCK and no fix round came, because br_one answered rc 3 for every row of the
# ticket. One stale round also pushed to the closed PR's branch ticket/bh-8062
# instead of ticket/bh-8062-r3.
#
# THE CASES (plan ## Acceptance tests):
#   F1  (AT1, the production entry) one tick abandons A through br_abandon, the
#       next tick parks B with a lead BLOCK: B gets a fresh ladder (P1), its
#       fix round's pre-round lint scan is red and in the prompt (L1), and the
#       round pushes once to B's branch while A's branch stays (L2)
#   F2-F4  bin/blocked-resolver.sh --fix-here handed a closed / merged PR, or a
#       PR whose state will not read: no worktree, no agent, nothing pushed
#   P1-P9  bpr_scope's decision table and br_finished / br_record_index /
#       br_save / br_load, on the real bin/lib/br modules
#   F5  br_fix_adopt (the real function) given another PR's done row
#   L1-L4  bpr_lint_brief on the real bin/lib/ci-local-verify.sh
#   B1-B2  br_fix_round (the real function, git stubbed): no body PATCH when
#       nothing is pushed, one PATCH after a push that landed
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-pr-record.bh-8339-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq  >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }

FRAG="$DIR/bin/blocked-resolver.d/bh-8339-pr-record.sh"
DRV="$DIR/bin/blocked-resolver.sh"
[ -r "$FRAG" ] && ok || bad "0: bin/blocked-resolver.d/bh-8339-pr-record.sh is missing"

# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
# The scripts this suite drives. The copy stays HERE so bin/test-impact.sh
# selects this suite when one of them changes.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/" || exit 1
fx_br_harness "$DIR" "$T" || exit 1
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
fx_br_ladder_git "$DIR" "$T" || exit 1
# The round's own lint seam and its knob defaults, as bin/harness-sync.sh puts
# them on a box.
scratch_install_closure bin/lib/ci-local-verify.sh "$H" >/dev/null || exit 1
mkdir -p "$H/catalog/lanes.d" || exit 1
cp "$DIR/catalog/lanes.d/_lib.ci-local.json" "$H/catalog/lanes.d/" || exit 1
# Every fragment rides with the driver copy, as bin/harness-sync.sh puts them.
mkdir -p "$H/bin/blocked-resolver.d" || exit 1
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" || exit 1

# ---------------------------------------------------------------------------
# TWO PRs OF ONE TICKET. A (#80, ticket/TK-9001) and B (#81, ticket/TK-9001-r3).
# B's branch carries a bin/ci-local.sh that is red until a.txt holds the
# agent's resolution, so the round's pre-scan is red and its verify is clean
# after the agent's commit.
# ---------------------------------------------------------------------------
SEED="$T/seed"; ORIGIN="$T/origin.git"
mkbranch ticket/TK-9001 clean
mkbranch ticket/TK-9001-r3 clean
mkdir -p "$SEED/bin"
cat > "$SEED/bin/ci-local.sh" <<'EOF'
#!/bin/bash
# FIXTURE ci-local: red with one finding until a.txt holds the resolution.
tree=""; out=""
while [ $# -gt 0 ]; do case "$1" in --tree) tree="$2"; shift ;; --out) out="$2"; shift ;; esac; shift; done
grep -q 'both sides, resolved' "$tree/a.txt" 2>/dev/null && exit 0
mkdir -p "$out"; printf 'CI-LOCAL shellcheck: bin/x.sh:3 SC2086\n' > "$out/findings.txt"; exit 1
EOF
chmod +x "$SEED/bin/ci-local.sh"
git -C "$SEED" add -A; git -C "$SEED" commit -qm "fixture ci-local"; git -C "$SEED" push -q origin ticket/TK-9001-r3
git -C "$SEED" checkout -q main
PRA="https://github.com/o/tproj/pull/80"; PRB="https://github.com/o/tproj/pull/81"
CK=tproj-TK-9001
RECF="$H/state/blocked-resolver/tproj/$CK.json"
HA=$(osha ticket/TK-9001); HB=$(osha ticket/TK-9001-r3)
LOGF="$H/logs/blocked-resolver.log"

# The per-PR GitHub: $T/pr/<n>/{state,head,branch,title,st}. Every other call
# goes to the ladder fixture's own stub.
mv "$T/fakebin/gh" "$T/fakebin/gh-ladder" || exit 1
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
all="\$*"; n=""
case "\$all" in *"/pulls/"*) n="\${all##*/pulls/}"; n="\${n%%[!0-9]*}" ;; esac
d="$T/pr/\$n"
if [ -n "\$n" ] && [ -d "\$d" ]; then
  case "\$all" in
    *"/files"*|*"/reviews"*|*"/comments"*) ;;
    *"-X PATCH"*"body=@"*)
      printf 'PATCH %s\n' "\$n" >> "$T/patches.log"; echo '{}'; exit 0 ;;
    *"-X PATCH"*)
      printf '%s\n' "\$all" >> "$T/closed.txt"; echo CLOSED > "\$d/state"
      printf 'HTTP/2 200\r\nserver: x\r\n\r\n{"state":"closed"}'; exit 0 ;;
    *"-i -X GET"*)
      printf '%s\n' "\$all" >> "$T/prreads.txt"
      st=\$(cat "\$d/st" 2>/dev/null || echo 200)
      case "\$st" in 2*) ;; *) printf 'HTTP/2 %s\r\nserver: x\r\n\r\n{"message":"stub"}' "\$st"; exit 0 ;; esac
      printf 'HTTP/2 200\r\nserver: x\r\n\r\n%s' "\$(jq -nc --arg s "\$(cat "\$d/state")" --arg h "\$(cat "\$d/head")" \
        --arg b "\$(cat "\$d/branch")" --arg t "\$(cat "\$d/title")" \
        '{state:(if \$s=="OPEN" then "open" else "closed" end), merged_at:(if \$s=="MERGED" then "2026-10-25T00:00:00Z" else null end),
          head:{sha:\$h,ref:\$b}, base:{ref:"main"}, title:\$t, body:""}')"
      exit 0 ;;
    *"-i "*) ;;
    *) printf '%s\n' "\$all" >> "$T/gh.txt"; echo "\$(cat "\$d/head") \$(cat "\$d/branch")"; exit 0 ;;
  esac
fi
exec "$T/fakebin/gh-ladder" "\$@"
EOF
chmod +x "$T/fakebin/gh"
PRDIR() { # PRDIR <n> <OPEN|CLOSED|MERGED> <head> <branch>
  mkdir -p "$T/pr/$1"; echo "$2" > "$T/pr/$1/state"; printf '%s' "$3" > "$T/pr/$1/head"
  printf '%s' "$4" > "$T/pr/$1/branch"; printf 'TK-9001: a thing' > "$T/pr/$1/title"; rm -f "$T/pr/$1/st"
}
RESET() {
  scratch_rm "$H/state/blocked-resolver"; scratch_rm "$H/tmp/brfix"; scratch_rm "$T/pr"
  mkdir -p "$H/state/blocked-resolver/tproj"
  rm -f "$H/flags/blocked-resolver-observe" "$H/locks/blocked-resolver-cron.lock" "$T/agent-resolves"
  : > "$LOGF"; : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$T/lane-alert.txt"; : > "$T/patches.log"
  : > "$T/agent.txt"; : > "$T/comment-bodies.txt"; : > "$T/prreads.txt"; rm -f "$T/prompt.txt"
  git -C "$T/repos/tproj" worktree prune >/dev/null 2>&1
  git -C "$T/repos/tproj" branch -D "brfix/$CK" >/dev/null 2>&1
  PRDIR 80 OPEN "$HA" ticket/TK-9001; PRDIR 81 OPEN "$HB" ticket/TK-9001-r3
  # The lead's BLOCK on each PR's head (a person with write access, no footer).
  LEADREV 80 "$HA"; LEADREV 81 "$HB"
  BRENV=()
}
LEADREV() { # LEADREV <n> <head>
  jq -nc --arg h "$2" '[{id:1,user:{login:"lead-fixture",type:"User"},author_association:"OWNER",commit_id:$h,
    state:"CHANGES_REQUESTED",body:"1. HIGH a.txt: resolve the line main changed."}]' > "$T/reviews-$1.json"
}
REC() { jq -r "$1" "$RECF" 2>/dev/null; }
CLOSES() { grep -c -- '-X PATCH' "$T/closed.txt" 2>/dev/null; }
FIXHERE() { # FIXHERE <reason> <url> — the owning box's half, record on stdin
  ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BOX_NAME=box-tproj \
    bash "$H/bin/blocked-resolver.sh" --fix-here tproj o-tproj-80 "$1" "$2" - TK-9001 < "$T/rec-in.json" ) 2>>"$T/run.log"
}
# Two real fix rounds on A's head at cap 2: the review terminal closes A.
A_AT_CAP() {
  jq -nc --arg u "$PRA" --arg h "$HA" '
    {project:"tproj",rkey:"tproj-TK-9001",first_seen:"2026-10-25 05:00:00Z",rebuilds:1,mechanicals:0,regens:0,fixrounds:2,adjudications:0,rereviews:0,outcome:"",
     attempts:[{at:"2026-10-25 05:10:00Z",action:"fix-round",reason:"review-changes-requested",detail:"agent rc=1, verify rc=1",url:$u,head:$h},
               {at:"2026-10-25 05:40:00Z",action:"fix-round",reason:"review-changes-requested",detail:"agent rc=1, verify rc=1",url:$u,head:$h}],
     rung_head:$h,rung_pr:$u,review_fix_heads:[$h]}'
}

# ============================================================================
# F1 (AT1, the production entry). Tick 1: A at its cap is abandoned through
# br_abandon. Tick 2: B, open, parked with a lead BLOCK, gets a fix round, and
# the push goes to B's branch.
# ============================================================================
RESET
A_AT_CAP > "$RECF"
ROW "o/tproj#80" review-changes-requested "$PRA"; BRENV=(BR_REVIEW_FIX_ROUNDS=2)
RUN
[ "$(CLOSES)" = 1 ] && grep -q 'pulls/80' "$T/closed.txt" && ok || bad "F1: tick 1 must close A once (closed: $(cat "$T/closed.txt"); log: $(tail -4 "$LOGF"))"
[ "$(REC .outcome)" = ABANDONED ] && ok || bad "F1: tick 1 records ABANDONED (got $(REC .outcome))"
[ "$(REC .abandoned_url)" = "$PRA" ] && ok || bad "P7: br_abandon stamps the abandoned PR's url (got $(REC .abandoned_url))"
# Tick 2: B with the lead's BLOCK.
: > "$LOGF"; touch "$T/agent-resolves"
ROW "o/tproj#81" review-changes-requested "$PRB"; BRENV=(BR_REVIEW_FIX_ROUNDS=2)
RUN
grep -q "PR RESET" "$LOGF" && ok || bad "P1: B's park must reset the record for B (log: $(tail -6 "$LOGF"))"
[ "$(grep -c 'EVENT resolver_pr_reset' "$LOGF")" = 1 ] && ok || bad "P1: one resolver_pr_reset event (log: $(grep EVENT "$LOGF"))"
[ "$(REC .outcome)" != ABANDONED ] && ok || bad "P1: B's record is not ABANDONED after the reset"
[ "$(REC .rebuilds)" = 1 ] && ok || bad "P1: the rebuild counter stays per ticket (got $(REC .rebuilds))"
[ "$(REC '[.attempts[]|select(.action=="pr-reset")]|length')" = 1 ] && [ "$(REC '[.attempts[]|select(.action=="pr-reset")][0].url')" = "$PRB" ] && ok \
  || bad "P1: one pr-reset attempt with B's url (got $(REC -c '[.attempts[]|select(.action=="pr-reset")]'))"
[ -s "$T/agent.txt" ] && ok || bad "F1: B must get a fix round (log: $(tail -8 "$LOGF"))"
grep -q 'Branch ticket/TK-9001-r3 of o/tproj' "$T/prompt.txt" 2>/dev/null && ok || bad "F1: the round's prompt names B's branch (prompt: $(head -c 300 "$T/prompt.txt" 2>/dev/null))"
grep -q 'RED ON THIS BRANCH BEFORE YOUR CHANGE' "$T/prompt.txt" 2>/dev/null && grep -q 'CI-LOCAL shellcheck: bin/x.sh:3 SC2086' "$T/prompt.txt" 2>/dev/null && ok \
  || bad "L1: the first round's prompt carries the branch's own lint lines (prompt tail: $(tail -c 600 "$T/prompt.txt" 2>/dev/null))"
[ "$(osha ticket/TK-9001-r3)" != "$HB" ] && ok || bad "F1: B's branch on the remote moved to the round's commit (log: $(tail -6 "$LOGF"))"
[ "$(git -C "$ORIGIN" log -1 --format=%s ticket/TK-9001-r3 2>/dev/null)" = "fix round: resolved the merge and answered the findings" ] && ok \
  || bad "F1: B's tip is the agent's commit (got $(git -C "$ORIGIN" log -1 --format=%s ticket/TK-9001-r3 2>/dev/null))"
[ "$(osha ticket/TK-9001)" = "$HA" ] && ok || bad "F1: A's branch must not move"
[ "$(REC .fixrounds)" = 1 ] && ok || bad "L2: one round, one push: fixrounds 1 (got $(REC .fixrounds))"
grep -q 'FIX ROUND pushed' "$LOGF" && ok || bad "L2: the pushed line (log: $(tail -4 "$LOGF"))"

# P3. A itself again after its abandon: rc 3, no reset, nothing read for A.
RESET
A_AT_CAP | jq -c --arg u "$PRA" '.outcome = "ABANDONED" | .abandoned_url = $u' > "$RECF"
PRDIR 80 CLOSED "$HA" ticket/TK-9001
cp "$RECF" "$T/before.json"
ROW "o/tproj#80" review-changes-requested "$PRA"
RUN
cmp -s <(jq -S 'del(.updated,.retired)' "$RECF") <(jq -S 'del(.updated,.retired)' "$T/before.json") && ok || bad "P3: A's own row leaves the record as it is"
grep -q 'PR RESET' "$LOGF" && bad "P3: A's own row must not reset" || ok
[ ! -s "$T/agent.txt" ] && ok || bad "P3: no round for A"

# P4. A legacy ABANDONED record (no abandoned_url), open B: the ticket rule.
RESET
A_AT_CAP | jq -c '.outcome = "ABANDONED"' > "$RECF"
ROW "o/tproj#81" review-changes-requested "$PRB"
RUN
[ "$(REC .outcome)" = ABANDONED ] && ok || bad "P4: a legacy record stays ABANDONED (got $(REC .outcome))"
grep -q 'resolver_pr_reset' "$LOGF" && bad "P4: no reset event on a legacy record" || ok
[ ! -s "$T/agent.txt" ] && ok || bad "P4: no round under a legacy record"

# ============================================================================
# F2-F4. The owning box handed a closed / merged / unreadable PR: no worktree,
# no agent, nothing pushed, no rung.
# ============================================================================
for c in CLOSED MERGED 500; do
  RESET
  A_AT_CAP | jq -c '.fixrounds = 0 | .review_fix_heads = []' > "$T/rec-in.json"
  if [ "$c" = 500 ]; then echo 500 > "$T/pr/80/st"; else PRDIR 80 "$c" "$HA" ticket/TK-9001; fi
  touch "$T/agent-resolves"
  OUT=$(FIXHERE review-changes-requested "$PRA")
  [ ! -s "$T/agent.txt" ] && ok || bad "F-$c: no agent call for a $c PR ($(cat "$T/agent.txt"))"
  [ "$(osha ticket/TK-9001)" = "$HA" ] && ok || bad "F-$c: A's branch must not move"
  REC_OUT=$(grep '^FIX_RECORD ' <<<"$OUT" | head -1 | cut -d' ' -f2 | base64 -d 2>/dev/null)
  [ "$(jq -r .fixrounds <<<"$REC_OUT" 2>/dev/null)" = 0 ] && ok || bad "F-$c: no rung spent (got $(jq -r .fixrounds <<<"$REC_OUT" 2>/dev/null))"
  [ -z "$(ls -A "$H/tmp/brfix" 2>/dev/null)" ] && ok || bad "F-$c: no worktree made"
  if [ "$c" = 500 ]; then
    grep -q 'fix round not run' "$LOGF" && grep -q 'retried next tick' "$LOGF" && ok || bad "F4: an unreadable state says 'retried next tick' (log: $(tail -3 "$LOGF"))"
  else
    lw=$(tr 'A-Z' 'a-z' <<<"$c")
    grep -q "fix round not run: $PRA is $lw" "$LOGF" && ok || bad "F-$c: the refusal line names the state (log: $(tail -3 "$LOGF"))"
  fi
done

# ============================================================================
# U. The fragment's rules, driven directly on the real bin/lib/br modules, with
#    br_finished, br_record_index and br_fix_adopt lifted from the driver.
# ============================================================================
U="$T/u"; mkdir -p "$U/state/tproj"
awk '/^br_finished\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$DRV" > "$U/finished.sh"
awk '/^br_record_index\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$DRV" > "$U/index.sh"
awk '/^br_fix_adopt\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$DRV" > "$U/adopt.sh"
[ -s "$U/finished.sh" ] && [ -s "$U/index.sh" ] && [ -s "$U/adopt.sh" ] && ok || bad "U0: the driver functions could not be lifted"
cat > "$T/u-pre.sh" <<EOF
set -u
H="$U"; ST="$U/state"; LOG="$U/log"; OBSERVE="\${OBSERVE:-0}"
STAMP() { printf '2026-10-26 01:00:00Z'; }
say() { printf '%s\n' "\$*" >> "\$LOG"; }
# br_pr_state's contract (open|closed|merged; rc 44 absent, rc 75 unreadable),
# one file per PR number.
br_pr_state() {
  local n="\${1##*/}"; printf '%s\n' "\$1" >> "$U/stateread"
  local rc; rc=\$(cat "$U/rc-\$n" 2>/dev/null || echo 0)
  [ "\$rc" = 0 ] || return "\$rc"
  cat "$U/state-\$n"
}
# The ledger, one file per key (job_ledger_put / job_ledger_row's contract).
job_ledger_put() { jq -nc --arg s "\$3" --arg d "\$4" '{status:\$s,detail:\$d}' > "$U/ledger-\${2//\//_}"; }
job_ledger_row() { cat "$U/ledger-\${2//\//_}" 2>/dev/null || return 1; }
fix_round_adopt() { printf '%s\n' "\$1" >> "$U/adopted"; return "\$(cat "$U/adopt-rc" 2>/dev/null || echo 0)"; }
br_fix_terminal() { printf 'terminal\n' >> "$U/terminal"; }
br_fix_terminal_word() { printf 'terminal'; }
. "$DIR/bin/lib/br/record.sh" || exit 9
. "$DIR/bin/lib/br/ladder.sh" || exit 9
. "$DIR/bin/lib/ci-local-verify.sh" || exit 9
. "$U/finished.sh" || exit 9
. "$U/index.sh" || exit 9
. "$U/adopt.sh" || exit 9
. "$FRAG" || exit 9
# After record.sh, whose br_event this replaces: the event rows land in a file.
br_event() { printf '%s\n' "\$*" >> "$U/events"; }
EOF
URF="$U/state/tproj/$CK.json"
UNIT() { ( . "$T/u-pre.sh"; eval "$1" ) 2>>"$U/err"; }
USEED() { # USEED <jq-filter> — A's abandoned record, edited by the filter
  A_AT_CAP | jq -c --arg a "$PRA" --arg b "$PRB" '.outcome = "ABANDONED" | .abandoned_url = $a' | jq -c --arg a "$PRA" --arg b "$PRB" "$1" > "$URF"
  : > "$U/log"; : > "$U/events"; : > "$U/stateread"; rm -f "$U"/rc-* "$U"/state-* "$U"/ledger-*
  echo open > "$U/state-81"; echo closed > "$U/state-80"
}
SCOPE() { UNIT "bpr_scope tproj o-tproj-81 $CK ${2:-review-changes-requested} ${1:-$PRB}; echo rc=\$?"; }

# P1u / P2. Reset for an open other PR, under a review park and a conductor park.
for r in review-changes-requested conductor-blocked; do
  USEED '.'
  OUT=$(SCOPE "$PRB" "$r")
  [ "$OUT" = rc=0 ] && ok || bad "P1u[$r]: an open other PR resets (got '$OUT'; log: $(cat "$U/log"); err: $(tail -2 "$U/err"))"
  [ "$(jq -r '[.outcome,.fixrounds,.mechanicals,.regens,.rebuilds,(.retired|tostring)]|map(tostring)|join(" ")' "$URF")" = " 0 0 0 1 false" ] && ok \
    || bad "P1u[$r]: outcome '', per-PR counters 0, rebuilds kept (got $(jq -c '[.outcome,.fixrounds,.mechanicals,.regens,.rebuilds,.retired]' "$URF"))"
  [ "$(jq -r '.pr_reset.from + " " + .pr_reset.to' "$URF")" = "$PRA $PRB" ] && ok || bad "P1u[$r]: pr_reset names from and to (got $(jq -c .pr_reset "$URF"))"
  [ "$(grep -c resolver_pr_reset "$U/events")" = 1 ] && ok || bad "P1u[$r]: one event (got $(cat "$U/events"))"
done
# P3u. The candidate is A itself: rc 1, no state read.
USEED '.'
[ "$(SCOPE "$PRA")" = rc=1 ] && [ ! -s "$U/stateread" ] && ok || bad "P3u: A itself keeps the terminal and reads nothing (read: $(cat "$U/stateread"))"
# P4u. Legacy record; P8 operator ABANDON (an outcome and no url); url-less row.
USEED 'del(.abandoned_url)'
[ "$(SCOPE)" = rc=1 ] && [ ! -s "$U/stateread" ] && ok || bad "P4u: a legacy record keeps the ticket rule"
USEED 'del(.abandoned_url) | .attempts += [{action:"operator-abandon"}]'
[ "$(SCOPE)" = rc=1 ] && [ ! -s "$U/events" ] && ok || bad "P8: an operator ABANDON (no abandoned_url) is never reset"
USEED '.'
[ "$(SCOPE -)" = rc=1 ] && ok || bad "P4u: a url-less row keeps the terminal"
# A rebuild-* row with another PR url keeps the terminal.
[ "$(SCOPE "$PRB" rebuild-review-blocked)" = rc=1 ] && ok || bad "P4u: a rebuild-* row keeps the terminal"
# P5. Other PR closed / merged / 404 / unreadable.
for s in closed merged; do
  USEED '.'; echo "$s" > "$U/state-81"
  [ "$(SCOPE)" = rc=1 ] && [ "$(jq -r .outcome "$URF")" = ABANDONED ] && ok || bad "P5: a $s other PR keeps the terminal"
done
USEED '.'; echo 44 > "$U/rc-81"
[ "$(SCOPE)" = rc=1 ] && ok || bad "P5: an absent other PR keeps the terminal"
USEED '.'; echo 75 > "$U/rc-81"
[ "$(SCOPE)" = rc=1 ] && grep -q 'retried next tick' "$U/log" && ok || bad "P5: an unreadable state keeps it this tick and says so (log: $(cat "$U/log"))"
# Not ABANDONED: no read at all.
USEED '.outcome = ""'
[ "$(SCOPE)" = rc=1 ] && [ ! -s "$U/stateread" ] && ok || bad "P1u: a record that is not ABANDONED is not touched"
# P9. Observe mode: WOULD, nothing written.
USEED '.'; cp "$URF" "$T/before.json"
OUT=$(OBSERVE=1 SCOPE)
[ "$OUT" = rc=1 ] && cmp -s "$URF" "$T/before.json" && grep -q 'WOULD reset' "$U/log" && ok || bad "P9: observe mode says WOULD and writes nothing (got '$OUT'; log: $(cat "$U/log"))"
# Near miss: the same number in another repo is another PR.
USEED '.'; echo open > "$U/state-80"
[ "$(SCOPE https://github.com/o/other/pull/80)" = rc=0 ] && ok || bad "P1u: a url in another repo with the same number is another PR"

# P6. br_finished's ABANDONED arm.
FIN() { UNIT "br_finished ABANDONED '$1' '$2' '${3:-review-changes-requested}'; echo rc=\$?"; }
[ "$(FIN - "$PRB")" = rc=0 ] && ok || bad "P6: a record with no abandoned url retires every row"
[ "$(FIN "$PRA" -)" = rc=0 ] && ok || bad "P6: a url-less candidate retires"
[ "$(FIN "$PRA" "$PRA")" = rc=0 ] && ok || bad "P6: the abandoned PR itself retires"
[ "$(FIN "$PRA" "$PRB")" = rc=1 ] && ok || bad "P6: another PR of the ticket is NOT retired"
[ "$(FIN "$PRA" https://github.com/o/tproj/issues/5)" = rc=0 ] && ok || bad "P6: a non-PR string retires"
# P7. The round trip: stamp, the ledger mirror, the file gone, br_load restores
# it, and br_record_index's column 2 carries it.
USEED '.outcome = ""'
UNIT "br_set_outcome tproj $CK ABANDONED; bpr_stamp tproj $CK $PRA"
[ "$(jq -r .abandoned_url "$URF")" = "$PRA" ] && ok || bad "P7: bpr_stamp writes the file"
[ "$(jq -r '.detail|fromjson|.abandoned_url' "$U/ledger-tproj_$CK" 2>/dev/null)" = "$PRA" ] && ok || bad "P7: br_save mirrors abandoned_url into the ledger row (got $(cat "$U/ledger-tproj_$CK" 2>/dev/null))"
rm -f "$URF"
[ "$(UNIT "br_load tproj $CK" | jq -r '.abandoned_url + " " + .outcome')" = "$PRA ABANDONED" ] && ok || bad "P7: br_load restores abandoned_url from the ledger (got $(UNIT "br_load tproj $CK"))"
UNIT "br_save tproj $CK \"\$(br_load tproj $CK)\""
[ "$(UNIT br_record_index | awk -F'\t' -v k="$CK" '$2==k {print $4}')" = "$PRA" ] && ok || bad "P7: br_record_index column 2 is the abandoned url (got $(UNIT br_record_index))"
USEED '.outcome = "RESOLVED_MERGED" | .resolved_url = $b'
[ "$(UNIT br_record_index | awk -F'\t' -v k="$CK" '$2==k {print $4}')" = "$PRB" ] && ok || bad "P7: a RESOLVED_MERGED record keeps its resolved url in column 2"
# bpr_stamp writes nothing for a url that is not a PR.
USEED 'del(.abandoned_url)'
UNIT "bpr_stamp tproj $CK -"
[ "$(jq -r '.abandoned_url // "none"' "$URF")" = none ] && ok || bad "P7: no stamp for a url-less abandon"

# F5. br_fix_adopt given a done row of PR A while the candidate is B.
FROW() { jq -nc --arg u "$1" '{id:7,project:"tproj",cap_key:"tproj-TK-9001",box:"box-tproj",
  args:["tproj","o-tproj-80","review-changes-requested",$u,"-","TK-9001"],status:"done",claimed_by:"box-tproj",result:"terminal",
  record_out:({project:"tproj",rkey:"tproj-TK-9001",fixrounds:2,outcome:"",attempts:[{},{},{},{},{},{},{},{}]}|tojson)}'; }
USEED '.outcome = "" | .fixrounds = 0'; : > "$U/adopted"; rm -f "$U/terminal"
N0=$(jq '.attempts|length' "$URF")
UNIT "br_fix_adopt tproj o-tproj-81 review-changes-requested $PRB - TK-9001 $CK '$(FROW "$PRA")'"
[ "$(cat "$U/adopted")" = 7 ] && ok || bad "F5: the other PR's row is adopted (CAS) once (got $(cat "$U/adopted"))"
[ "$(jq '.attempts|length' "$URF")" = "$N0" ] && [ "$(jq -r .fixrounds "$URF")" = 0 ] && ok || bad "F5: the record is not overwritten by A's row"
[ ! -e "$U/terminal" ] && ok || bad "F5: no terminal is taken for B"
grep -q "$PRA" "$U/log" && ok || bad "F5: the line names A (log: $(cat "$U/log"))"
# ...and a row of B itself is adopted as today (its record is saved).
USEED '.outcome = "" | .fixrounds = 0'; : > "$U/adopted"; rm -f "$U/terminal"
UNIT "br_fix_adopt tproj o-tproj-81 review-changes-requested $PRB - TK-9001 $CK '$(FROW "$PRB")'"
[ "$(jq '.attempts|length' "$URF")" = 8 ] && [ -e "$U/terminal" ] && ok || bad "F5: a row of the same PR is adopted as today"

# L1-L4. bpr_lint_brief on the real ci-local seam.
W="$T/lwt"; mkdir -p "$W/bin"
cat > "$W/bin/ci-local.sh" <<'EOF'
#!/bin/bash
out=""; while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift ;; esac; shift; done
[ -f "$(dirname "$0")/../clean" ] && exit 0
mkdir -p "$out"; printf 'CI-LOCAL shellcheck: bin/x.sh:3 SC2086\n' > "$out/findings.txt"; exit 1
EOF
chmod +x "$W/bin/ci-local.sh"
OLDF="$U/old-findings.txt"; printf 'CI-LOCAL fixture-hygiene: tests/old.sh:9\n' > "$OLDF"
LB() { UNIT "bpr_lint_brief '$W' origin/main '$U/pre' '$OLDF' '${1:-}'"; }
OUT=$(LB)
grep -q 'RED ON THIS BRANCH BEFORE YOUR CHANGE' <<<"$OUT" && grep -q 'CI-LOCAL shellcheck: bin/x.sh:3 SC2086' <<<"$OUT" && ok || bad "L1u: red prints the pre-round lines (got: $OUT)"
grep -q 'tests/old.sh' <<<"$OUT" && bad "L1u: a red pre-scan replaces the last round's lines" || ok
touch "$W/clean"; OUT=$(LB)
[ -z "$OUT" ] && ok || bad "L4: clean prints no lint paragraph even with an old findings file (got: $OUT)"
rm -f "$W/clean"; mv "$W/bin/ci-local.sh" "$W/bin/ci-local.off"
OUT=$(LB)
grep -q 'WERE RED ON THE LAST ROUND' <<<"$OUT" && grep -q 'tests/old.sh' <<<"$OUT" && ok || bad "L3: no bin/ci-local.sh -> today's last-round paragraph (got: $OUT)"
mv "$W/bin/ci-local.off" "$W/bin/ci-local.sh"
OUT=$(LB "a.txt")
grep -q 'WERE RED ON THE LAST ROUND' <<<"$OUT" && ! grep -q 'BEFORE YOUR CHANGE' <<<"$OUT" && ok || bad "L3: a conflicted merge runs no scan, today's paragraph (got: $OUT)"

# ============================================================================
# B1-B2. br_fix_round, the real function (git and the lane's bookkeeping
# stubbed, as tests/fixround-preflight.bh-1794-test.sh drives it), with the
# real fixround-preflight lib and the preflight block: the body is PATCHed only
# after a push that landed.
# ============================================================================
BW="$T/b"; mkdir -p "$BW/st" "$BW/repos/tproj/.git" "$BW/h/bin" "$BW/gh"
awk '/^# >>> br fixround preflight/{f=1} f{print} /^# <<< br fixround preflight/{f=0}' "$DRV" > "$BW/pre.sh"
awk '/^br_fix_round\(\) \{/{f=1} f{print} f&&/^}/{exit}' "$DRV" > "$BW/fixround.sh"
NEWH=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; PUSHED=cccccccccccccccccccccccccccccccccccccccc
printf '#!/bin/bash\n[ "$2" = repo ] && echo o/tproj\nexit 0\n' > "$BW/h/bin/fleet-conf.sh"
printf '#!/bin/bash\nprintf "%%s" "$6" > "%s/prompt.txt"\nprintf "agent\\n" >> "%s/agent.log"\nexit 0\n' "$BW" "$BW" > "$BW/h/bin/agent-call.sh"
chmod +x "$BW/h/bin/fleet-conf.sh" "$BW/h/bin/agent-call.sh"
mkdir -p "$BW/fakebin"
cat > "$BW/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$BW/gh.log"
case "\$*" in
  *"-X PATCH"*"/pulls/"*) printf 'PATCH\n' >> "$BW/order.log"; printf 'PATCH\n' >> "$BW/patches.log"; echo '{}' ;;
  *"/actions/runs?head_sha="*) echo '{"total_count":1,"workflow_runs":[{"id":11,"name":"CI","status":"completed","conclusion":"failure","html_url":"https://github.com/o/tproj/actions/runs/11"}]}' ;;
  *"/check-runs"*) echo '{"total_count":0,"check_runs":[]}' ;;
  *"/pulls/"*) echo '"the body"' | jq -r . ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$BW/fakebin/gh"
cat > "$BW/stubs.sh" <<EOF
OBSERVE=0; H="$BW/h"; ST="$BW/st"; LOG="$BW/br.log"; REPOS="$BW/repos"; FIX_AGENT_TIMEOUT=60
PATH="$BW/fakebin:\$PATH"
say()  { printf '%s\n' "\$*" >> "$BW/say.log"; }
STAMP() { printf '2026-10-26 01:00:00Z'; }
br_event() { :; }; br_rereview() { :; }; br_pr_comment() { :; }
mc_num_of_url() { printf '%s' "\${1##*/}"; }
br_file() { printf '%s' "$BW/rec.json"; }
br_load() { cat "$BW/rec.json" 2>/dev/null || echo '{}'; }
br_push_field() { :; }; br_has_field_value() { return 1; }; br_set_field() { :; }; br_set_num() { :; }; br_json_edit() { :; }
br_num() { printf 0; }
br_cap_key() { printf ck; }
br_cap_rows() { printf '%s' "\$4"; }
br_fix_cap() { printf 2; }
br_fix_terminal_word() { printf 'terminal'; }
br_fix_terminal() { printf 'terminal\n' >> "$BW/terminal.log"; }
br_slug_of_url() { printf 'o/tproj'; }
br_pr_state() { printf 'open'; }
br_pr_ref() { printf 'o/tproj ticket/TK-7 %s\n' "$NEWH"; }
br_pr_field() { printf 'main'; }
br_sup_seen() { :; }; br_use_token() { :; }; br_setup_blocked() { printf 'setup %s\n' "\$6" >> "$BW/terminal.log"; }
br_findings() { printf '1. HIGH src/rate.ts:12 the route is unauthenticated.\n'; }
br_ladder_class() { echo ""; }
br_conflict_note() { :; }; br_note_conflict_lines() { :; }; mc_conflict_lines() { :; }
br_model() { printf 'model-under-test'; }
br_round_begin() { :; }; br_yield_take() { return 1; }; br_count() { :; }
br_record() { printf 'record %s\n' "\$*" >> "$BW/record.log"; }
br_wt_drop() { :; }; mc_git_auth() { :; }; mc_git_auth_clear() { :; }
br_fix_push_note() { :; }; br_hold_issue() { return 1; }; br_xpr_wait_line() { :; }
gi_check() { return 0; }
cl_verify_lines() { echo "== ci-local =="; if [ -f "$BW/verify-red" ]; then echo "CI-LOCAL x"; echo "CI_LOCAL_EXIT: 1"; else echo "CI_LOCAL_EXIT: 0"; fi; }
hold_push() { printf 'PUSH\n' >> "$BW/order.log"; return 0; }
git() {
  local a=("\$@"); [ "\${a[0]}" = -C ] && a=("\${a[@]:2}")
  case "\${a[*]}" in
    "remote get-url origin") echo /srv/clone ;;
    "rev-parse --verify -q origin/"*) echo "$NEWH" ;;
    "rev-parse --verify -q brfix/"*) return 1 ;;
    "worktree add"*) mkdir -p "\${a[3]}" ;;
    "rev-parse HEAD"|"rev-parse --short HEAD") if [ -f "$BW/committed" ]; then echo "$PUSHED"; else echo "$NEWH"; fi ;;
    *) return 0 ;;
  esac
}
EOF
BFR() { # BFR — the real br_fix_round in a fresh shell
  rm -f "$BW/prompt.txt" "$BW/agent.log" "$BW/terminal.log" "$BW/record.log" "$BW/order.log" "$BW/patches.log" "$BW/say.log"
  bash -c '. "$1"; . "$2"; . "$3"; . "$4"; . "$5"
    br_fix_round tproj rk review-changes-requested https://github.com/o/tproj/pull/7 /rec TK-7' _ \
    "$DIR/bin/lib/fixround-preflight.sh" "$BW/stubs.sh" "$BW/pre.sh" "$FRAG" "$BW/fixround.sh" >/dev/null 2>&1
}
# B1 (AT2): the agent commits, the lint is still red at verify -> not pushed,
# and the PR body was never PATCHed.
touch "$BW/committed" "$BW/verify-red"
BFR
[ -s "$BW/agent.log" ] && ok || bad "B1: the round must reach the agent (terminal: $(cat "$BW/terminal.log" 2>/dev/null); say: $(tail -3 "$BW/say.log" 2>/dev/null))"
grep -q PUSH "$BW/order.log" 2>/dev/null && bad "B1: a red verify must not push" || ok
[ ! -s "$BW/patches.log" ] && ok || bad "B1: no body PATCH when nothing was pushed (patches: $(cat "$BW/patches.log"))"
# B2: verify clean, the push lands -> exactly one PATCH, after the push.
rm -f "$BW/verify-red"
BFR
[ "$(tr '\n' ' ' < "$BW/order.log" 2>/dev/null)" = "PUSH PATCH " ] && ok || bad "B2: one body PATCH, after the push (order: $(tr '\n' ' ' < "$BW/order.log" 2>/dev/null))"

echo "blocked-resolver-pr-record.bh-8339: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
