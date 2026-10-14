#!/bin/bash
# tests/blocked-resolver.bh-488-test.sh — BH-488: one key derivation, and a
# rebuild enqueue that FAILS is really retried.
#
# THE BUG THIS PINS. bin/blocked-resolver.sh's rung 3 closes the stale PR, marks
# the build record superseded, releases the conductor's hand-off — and THEN
# enqueues. When that enqueue answers rc 1 (no ticket id, a jobs queue that took
# nothing, a box that would not answer) the lane wrote `rebuild-fresh-failed` and
# said "retried next tick". Nothing retried it: the PR was closed, the record was
# marked, the row was released, and every discovery source skips exactly that
# state. project-5 #1315/#1383 sat seven hours with no owner and nothing said so.
#
# So the retry is a real rung here, driven end to end through the script: a tick
# whose enqueue fails, then the next tick, which must enqueue WITHOUT closing
# anything a second time. The second half is the key derivation: one order
# (record -> branch -> title) with the winning source named in the log, because
# "derived TK-9 from the PR/record" does not tell an operator which of three
# sources was right.
#
# Per-ticket test file (docs/verification-map/test-home.md): the shared
# tests/blocked-resolver-test.sh is the fleet's biggest merge-conflict surface,
# and it is run UNCHANGED as this change's regression check.
# Run from anywhere: tests/blocked-resolver.bh-488-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the whole file (bin/test-determinism-lint.sh): every fixture
# age is derived from it, so this suite cannot pick its own red day.
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }
AT=$(date -u -d "@$((NOW-3600))" '+%Y-%m-%d %H:%M:%SZ')

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$H/state/build-queue/tproj" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy. One helper, one edit when the
# split moves again.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
# BH-6461: the key family moved to bin/lib/br/keys.sh; the corpus is the driver
# plus bin/lib/br/*.sh (tests/lib/br-corpus.sh), so the extraction finds it there.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$H" "$T/br-corpus.sh" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" \
   "$DIR/bin/lib/rebuild-ledger.sh" "$H/bin/lib/"
# bin/blocked-resolver.sh now REQUIRES the REST contract (#783): without it the
# lane refuses to start rather than deciding on undefined reads.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
# BH-680 (#929): merge-conductor-lib.sh is a shim that sources bin/lib/mc/*.sh and
# exits on a missing module — the fixture must carry the modules too.
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
chmod +x "$H/bin/"*.sh
# One project, a GitHub-Issues lane (board prefix "-"), owned by a remote box.
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh agent-call.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
# lane-alert is RECORDED, never stubbed silent: "it failed six times and the lane
# went quiet" is the failure section D is about.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

# Every gh call is recorded, so "did anything close a PR a second time" is a fact
# about the run rather than a reading of the source.
#   hrn-blank-first  — headRefName answers blank on the FIRST call only, which is
#                      discovery's (the wrong-token read the incident turned on).
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  # bin/blocked-resolver.sh reads, comments and closes over REST (#783): the
  # gh-api-dash-i envelope is answered once, in tests/lib/gh-rest-stub.sh.
  # hrn-blank-first now blanks the head branch of the FIRST PR read — the one
  # discovery makes before br_one installs the repo's own token — because the
  # branch and the title arrive in one object rather than in two reads.
  *"-i -X GET"*"/pulls/"*)
    if [ -f "$T/hrn-blank-first" ]; then
      C=\$(cat "$T/hrn-count" 2>/dev/null || echo 0); echo \$((C+1)) > "$T/hrn-count"
      if [ "\$C" = 0 ]; then
        printf 'HTTP/2 200\r\n\r\n'
        jq -nc '{state:"open",merged_at:null,head:{sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",ref:""},base:{ref:"main"},title:""}'
        exit 0
      fi
    fi
    GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"issues/"*"/comments"*) cat "$T/comments-\$N.json" 2>/dev/null || echo '[]' ;;
  *"repos/"*"/issues/"*)   cat "$T/issue-\$N.json" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *"pr close"*)   printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) printf '%s\n' "\$*" >> "$T/comments.txt"; exit 0 ;;
  *"--json state"*) cat "$T/prstate" 2>/dev/null || echo OPEN ;;
  *"/pulls/"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \$(cat "$T/prbranch")" ;;
  *"--json headRefOid,headRefName"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \$(cat "$T/prbranch")" ;;
  *"--json headRefName"*)
    if [ -f "$T/hrn-blank-first" ]; then
      C=\$(cat "$T/hrn-count" 2>/dev/null || echo 0); echo \$((C+1)) > "$T/hrn-count"
      [ "\$C" = 0 ] && exit 0
    fi
    cat "$T/prbranch" ;;
  *"--json title"*) cat "$T/prtitle" 2>/dev/null ;;
  *"pr list"*) cat "$T/mergedprs" 2>/dev/null ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf 'ticket/TK-9' > "$T/prbranch"; : > "$T/prtitle"; : > "$T/mergedprs"
echo OPEN > "$T/prstate"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
# ssh is RECORDED and never real: a test that reaches a box has already failed.
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
# NO REAL CREDENTIAL REACHES THIS RUN (the rule tests/blocked-resolver-test.sh holds).
export GH_TOKEN=""

BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
ROW() {   printf '%s\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$NOW" abc123 abc123 "$2" "$3" \
            > "$H/state/merge-conductor/pr-state.tsv"; }
ROWST() { printf '%s\t%s\t%s\t%s\t%s\t-\t%s\t%s\n' "$1" "$2" "$NOW" abc123 abc123 "$3" "$4" \
            > "$H/state/merge-conductor/pr-state.tsv"; }
STATEJSON() { cat "$H/state/blocked-resolver/tproj/$1.json" 2>/dev/null; }
LOG() { cat "$H/logs/blocked-resolver.log" 2>/dev/null; }
# SPENT <cap-key> — the two cheaper rungs already ran and did not land it, so the
# ladder's next rung is the rebuild. Same helper the shared suite uses.
SPENT() {
  mkdir -p "$H/state/blocked-resolver/tproj"
  jq -nc --arg k "$1" '{project:"tproj",rkey:$k,mechanicals:1,fixrounds:1,rebuilds:0,outcome:"",attempts:[]}' \
    > "$H/state/blocked-resolver/tproj/$1.json"
}
# The two jobs clients: one that takes the row, one that refuses it — the rc-1
# "enqueue that could not be made THIS time" this ticket is about.
JOBS_OK() { cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
}
JOBS_FAIL() { cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf 'REFUSED %s\n' "\$*" >> "$T/queue-attempts.txt"; return 1; }
queue_done() { return 0; }
queue_list() { return 1; }
EOF
}
CLEAN() { scratch_rm "$H/state/blocked-resolver" 2>/dev/null
          mkdir -p "$H/state/blocked-resolver/tproj"
          : > "$H/state/merge-conductor/pr-state.tsv"
          : > "$T/queue.txt"; : > "$T/queue-attempts.txt"; : > "$T/closed.txt"
          : > "$T/lane-alert.txt"; : > "$T/comments.txt"; : > "$T/gh.txt"
          : > "$H/logs/blocked-resolver.log"; : > "$H/logs/ALERTS.log"
          rm -f "$T/hrn-count" "$T/hrn-blank-first"
          echo OPEN > "$T/prstate"; printf 'ticket/TK-9' > "$T/prbranch"; }
touch "$H/flags/fly-pool-tproj"   # a pool project: the enqueue is a queue row
JOBS_OK

# ============================================================================
# A. br_ticket_key — THE one key resolver, and it names the source that won.
#    Driven as the pure function it is, extracted from the script the way the
#    shared suite extracts the same family: a table in the test that agrees with
#    a table in the test proves nothing.
# ============================================================================
for fn in br_key_shape br_key_from_branch br_key_from_title br_key_from_dir \
          br_ticket_key br_key_source_phrase; do
  awk -v F="^$fn\\(\\)" '$0~F{f=1} f{print} f&&/^}$/{exit}' "$T/br-corpus.sh"
done > "$T/keys.sh"
[ "$(grep -c '^br_.*() {' "$T/keys.sh")" = 6 ] && ok \
  || bad "could not extract the key-resolution family (got $(grep -c '^br_.*() {' "$T/keys.sh") of 6)"
# R <record> <branch> <title> -> "KEY source", or NONE. The resolver prints
# KEY<TAB>source; the tab is flattened so a row reads as one string.
R() { bash -c '. "$0"; br_ticket_key tproj "$1" "$2" "$3" || echo NONE' \
        "$T/keys.sh" "${1:--}" "${2:-}" "${3:-}" | tr '\t' ' '; }
mkdir -p "$H/builds/tproj-TK-9-202609150614"
mkdir -p "$H/builds/tproj-TK-42-202609150700"
printf '{"key":"TK-42"}\n' > "$H/builds/tproj-TK-42-202609150700/ticket-meta.json"
mkdir -p "$H/builds/tproj-TK-43-202609150700"
printf '{"ticket_key":"TK-43"}\n' > "$H/builds/tproj-TK-43-202609150700/ticket-meta.json"
# THE LEDGER FIRST. The build record is what the pipeline itself wrote down; a
# branch is what somebody named. They disagree only when a rebuild took a new
# branch name, and the record is the one that says which ticket this is.
[ "$(R "$H/builds/tproj-TK-9-202609150614" ticket/TK-775 'TK-999: wrong')" = "TK-9 record" ] && ok \
  || bad "the build record must win over branch and title (got '$(R "$H/builds/tproj-TK-9-202609150614" ticket/TK-775 'TK-999: wrong')')"
# ticket-meta.json is the record's own word, ahead of the name of its directory.
[ "$(R "$H/builds/tproj-TK-42-202609150700" '' '')" = "TK-42 record" ] && ok \
  || bad "ticket-meta.json .key must be read before the dir name (got '$(R "$H/builds/tproj-TK-42-202609150700" '' '')')"
[ "$(R "$H/builds/tproj-TK-43-202609150700" '' '')" = "TK-43 record" ] && ok \
  || bad "ticket-meta.json .ticket_key is the same ledger field under its other name (got '$(R "$H/builds/tproj-TK-43-202609150700" '' '')')"
# ...then the branch, then the title.
[ "$(R - ticket/TK-1200-r2 'TK-77: wrong')" = "TK-1200 branch" ] && ok \
  || bad "with no record the head branch wins, -rN stripped (got '$(R - ticket/TK-1200-r2 'TK-77: wrong')')"
[ "$(R - hotfix/x 'TK-77: the discount toggle')" = "TK-77 title" ] && ok \
  || bad "a branch with no key falls to the title (got '$(R - hotfix/x 'TK-77: the discount toggle')')"
[ "$(R - '' '[TK-1617] discount toggle')" = "TK-1617 title" ] && ok \
  || bad "the bracketed title shape must still resolve (got '$(R - '' '[TK-1617] discount toggle')')"
# AND IT REFUSES rather than guesses: an invented key buys a quarantine.
[ "$(R - feature/x '')" = NONE ] && ok \
  || bad "nothing carrying a key must answer rc 1, never a guess (got '$(R - feature/x '')')"
[ "$(R - fix/report-nav-anchors 'rebuild the report nav')" = NONE ] && ok \
  || bad "a keyless branch and a keyless title must still answer NONE (got '$(R - fix/report-nav-anchors 'rebuild the report nav')')"
# A record belonging to ANOTHER project is not this ticket's ledger.
[ "$(R /root/harness/builds/pool-project-5-TK-775-202609150614 ticket/TK-9 '')" = "TK-9 branch" ] && ok \
  || bad "a record dir from another project must be skipped, not read (got '$(R /root/harness/builds/pool-project-5-TK-775-202609150614 ticket/TK-9 '')')"
# ...and it is skipped BEFORE its ticket-meta.json is read, not after: a foreign
# record that carries one would otherwise hand this project another project's
# key out of a file this project never wrote.
mkdir -p "$H/builds/pool-project-5-TK-775-202609150614"
printf '{"key":"TK-775"}\n' > "$H/builds/pool-project-5-TK-775-202609150614/ticket-meta.json"
[ "$(R "$H/builds/pool-project-5-TK-775-202609150614" ticket/TK-9 '')" = "TK-9 branch" ] && ok \
  || bad "a foreign record's ticket-meta.json must not supply this project's key (got '$(R "$H/builds/pool-project-5-TK-775-202609150614" ticket/TK-9 '')')"
# The source words an operator reads in the log.
for pair in "record:the build record" "branch:the PR branch" "title:the PR title"; do
  got=$(bash -c '. "$0"; br_key_source_phrase "$1"' "$T/keys.sh" "${pair%%:*}")
  [ "$got" = "${pair##*:}" ] && ok || bad "source '${pair%%:*}' must read as '${pair##*:}', got '$got'"
done

# ============================================================================
# B. DRIVEN: the run SAYS which source carried the key.
# ============================================================================
CLEAN; JOBS_OK
SPENT tproj-TK-9
ROW "o/tproj#9" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/9"
RUN
grep -q 'ticket key TK-9 from the PR branch' "$H/logs/blocked-resolver.log" && ok \
  || bad "discovery must name the source that carried the key (log: $(LOG | tail -5))"
# ...and when discovery could not read the branch (the wrong-token read), the
# second ask inside the repo token says the same thing in br_one's own line.
CLEAN; JOBS_OK
SPENT tproj-TK-9
touch "$T/hrn-blank-first"
ROW "o/tproj#9" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/9"
RUN
rm -f "$T/hrn-blank-first"
grep -q 'discovery carried no ticket key — derived TK-9 from the PR branch' "$H/logs/blocked-resolver.log" && ok \
  || bad "the second derivation must name its source too (log: $(grep derived "$H/logs/blocked-resolver.log" | tail -3))"
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "the keyless-at-discovery park must still enqueue TK-9 (queue: $(cat "$T/queue.txt"))"

# ============================================================================
# C. THE BUG: a FAILED enqueue is re-offered, and the next tick really retries.
# ============================================================================
CLEAN; JOBS_FAIL
SPENT tproj-TK-9
ROW "o/tproj#9" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/9"
RUN
# Tick 1: the rung ran, the PR is closed, and the enqueue did NOT land.
# One REST PATCH is one close (#783), where it used to be one `gh pr close`.
[ "$(grep -c -- '-X PATCH' "$T/closed.txt")" = 1 ] && ok \
  || bad "tick 1 must close the stale PR exactly once (closed: $(cat "$T/closed.txt"))"
[ "$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action')" = rebuild-fresh-failed ] && ok \
  || bad "a failed enqueue is recorded as rebuild-fresh-failed (got '$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action')')"
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 0 ] && ok \
  || bad "a failed enqueue must NOT spend a rebuild counter (rebuilds=$(STATEJSON tproj-TK-9 | jq -r .rebuilds))"
[ "$(STATEJSON tproj-TK-9 | jq -r .parked_url)" = "https://github.com/o/tproj/pull/9" ] && ok \
  || bad "THE BUG: the PR it closed must be on the record BEFORE the enqueue, or nothing can retry it (got '$(STATEJSON tproj-TK-9 | jq -r .parked_url)')"
[ "$(STATEJSON tproj-TK-9 | jq -r '.parked_rec // "MISSING"')" != MISSING ] && ok \
  || bad "the superseded record must be written before the enqueue too (state: $(STATEJSON tproj-TK-9))"
[ "$(STATEJSON tproj-TK-9 | jq -r '.enqueue_failures // "MISSING"')" = 1 ] && ok \
  || bad "the first failure must be counted (got '$(STATEJSON tproj-TK-9 | jq -r '.enqueue_failures // "MISSING"')')"
grep -q '^tproj ' "$T/queue.txt" && bad "nothing may be queued on a failed enqueue: $(cat "$T/queue.txt")" || ok
# Tick 2: the conductor has re-classified the closed PR, so NO conductor row can
# re-offer this park. The state file is the only thing that can, and it must.
ROWST "o/tproj#9" CLOSED "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/9"
echo CLOSED > "$T/prstate"
JOBS_OK
CLOSED_BEFORE=$(wc -l < "$T/closed.txt")
RUN
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "THE BUG: the tick after a failed enqueue must actually enqueue (queue: $(cat "$T/queue.txt"); log: $(LOG | tail -5))"
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 1 ] && ok \
  || bad "the retry that LANDED spends the rebuild counter (rebuilds=$(STATEJSON tproj-TK-9 | jq -r .rebuilds))"
[ "$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action')" = rebuild-fresh ] && ok \
  || bad "a landed retry is recorded as rebuild-fresh (got '$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action')')"
[ "$(wc -l < "$T/closed.txt")" = "$CLOSED_BEFORE" ] && ok \
  || bad "the retry must NOT close anything again (closed: $(cat "$T/closed.txt"))"
[ "$(STATEJSON tproj-TK-9 | jq -r .enqueue_failures)" = 0 ] && ok \
  || bad "a landed enqueue resets the failure counter (got '$(STATEJSON tproj-TK-9 | jq -r .enqueue_failures)')"
# ...and the tick after THAT leaves the in-flight build alone.
QLINES=$(wc -l < "$T/queue.txt")
RUN
[ "$(wc -l < "$T/queue.txt")" = "$QLINES" ] && ok \
  || bad "a rebuild in flight must not be enqueued again (queue: $(cat "$T/queue.txt"))"

# ============================================================================
# D. NOTHING WAITS SILENTLY — AND NOTHING RETRIES FOR EVER (BH-1122 revised the
#    contract this section used to pin). The original BH-488 answer was "retry
#    free, page once at six, never a ticket terminal". It held until project-4
#    TK-1674 produced 79 `rebuild enqueue FAILED` lines, 25 of them in a row,
#    each one of the four rungs a ten-minute tick has: the page was true and
#    nothing acted on it, so the lane kept paying. So three IDENTICAL failures
#    now STALL the park — one alert, no rung until its row changes — and the
#    retry itself is unchanged, only its end is new. The record is still not
#    ABANDONED, nothing is closed twice, and no counter is spent.
# ============================================================================
CLEAN; JOBS_FAIL
SPENT tproj-TK-9
ROW "o/tproj#9" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/9"
RUN                                   # tick 1: the fresh rung, failure 1
ROWST "o/tproj#9" CLOSED "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/9"
echo CLOSED > "$T/prstate"
[ -s "$T/lane-alert.txt" ] && bad "one failed enqueue is not a page: $(cat "$T/lane-alert.txt")" || ok
RUN                                   # failure 2
[ -s "$T/lane-alert.txt" ] && bad "two failures must not page yet (BR_ENQUEUE_FAIL_MAX=3): $(cat "$T/lane-alert.txt")" || ok
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = "" ] && ok \
  || bad "two failures are not a terminal (outcome '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
RUN                                   # failure 3 — the stall
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = STALLED ] && ok \
  || bad "three identical failures must stall the park (outcome '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
[ "$(grep -c 'pull/9' "$T/lane-alert.txt")" = 1 ] && ok \
  || bad "the stall pages exactly once, naming the closed PR (got: $(cat "$T/lane-alert.txt"))"
grep -q 'TK-9' "$T/lane-alert.txt" && ok \
  || bad "the page must name the ticket (got: $(cat "$T/lane-alert.txt"))"
grep -q 'took no row' "$T/lane-alert.txt" && ok \
  || bad "the page must name why it could not be resolved (got: $(cat "$T/lane-alert.txt"))"
ATTD=$(STATEJSON tproj-TK-9 | jq -r '[.attempts[]] | length')
for _ in 4 5; do RUN; done            # the park is out of the candidate list
[ "$(grep -c 'pull/9' "$T/lane-alert.txt")" = 1 ] && ok \
  || bad "the page is once per episode, not once per tick (got: $(cat "$T/lane-alert.txt"))"
[ "$(STATEJSON tproj-TK-9 | jq -r '[.attempts[]] | length')" = "$ATTD" ] && ok \
  || bad "a stalled park adds no attempts (attempts: $(STATEJSON tproj-TK-9 | jq -c '[.attempts[].action]'))"
[ "$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action')" = stalled ] && ok \
  || bad "the stall is the last thing on the record (attempts: $(STATEJSON tproj-TK-9 | jq -c '[.attempts[].action]'))"
[ "$(STATEJSON tproj-TK-9 | jq -r .enqueue_failures)" = 3 ] && ok \
  || bad "the counter stops where the stall did (got '$(STATEJSON tproj-TK-9 | jq -r .enqueue_failures)')"
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 0 ] && ok \
  || bad "no failure may spend a rebuild counter (rebuilds=$(STATEJSON tproj-TK-9 | jq -r .rebuilds))"
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" != ABANDONED ] && ok \
  || bad "an enqueue that cannot be made is a machine problem, never a TICKET terminal (outcome '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
grep -q '^tproj ' "$T/queue.txt" \
  && bad "a stalled park enqueues nothing: $(cat "$T/queue.txt")" || ok
# NOTHING IN THIS LANE ASKS FOR A PERSON (the operator, 2026-09-13).
grep -iE 'BLOCKED_HUMAN|by hand|for the operator|needs a human' "$T/lane-alert.txt" >/dev/null 2>&1 \
  && bad "the page must not park the ticket on a human: $(cat "$T/lane-alert.txt")" || ok
grep -iE 'BLOCKED_HUMAN|by hand|for the operator|needs a human' "$H/logs/ALERTS.log" >/dev/null 2>&1 \
  && bad "no ALERTS line may ask for a human either: $(cat "$H/logs/ALERTS.log")" || ok
# ...and the alert's own instruction has to WORK. It says to clear .outcome, not
# to delete the file, so clearing it must put the park back in the stream.
JOBS_OK
jq '.outcome=""' "$H/state/blocked-resolver/tproj/tproj-TK-9.json" > "$T/cleared.json" \
  && mv -f "$T/cleared.json" "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
RUN
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "clearing .outcome must put the park back and the retry must land (queue: $(cat "$T/queue.txt"))"
[ "$(STATEJSON tproj-TK-9 | jq -r .enqueue_failures)" = 0 ] && ok \
  || bad "a landed enqueue resets the streak so the next episode can page (got '$(STATEJSON tproj-TK-9 | jq -r .enqueue_failures)')"

# ============================================================================
# E. ONE ENQUEUE PER TICKET PER TICK. The retry row's key is the CAP key
#    (tproj-TK-9) and a conductor row for the same PR keys on the NUMBER
#    (o-tproj-9): two rows, one ticket, and without a dedupe the ticket is built
#    twice and its PR closed twice.
# ============================================================================
CLEAN; JOBS_FAIL
SPENT tproj-TK-9
ROW "o/tproj#9" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/9"
RUN                                   # tick 1: closes the PR, enqueue fails
JOBS_OK
RUN                                   # tick 2: the conductor row is STILL BLOCKED_HUMAN
[ "$(grep -c '^tproj TK-9 9 fly 0 ' "$T/queue.txt")" = 1 ] && ok \
  || bad "one ticket may be enqueued once per tick (queue: $(cat "$T/queue.txt"))"
[ "$(grep -c -- '-X PATCH' "$T/closed.txt")" = 1 ] && ok \
  || bad "and its PR closed once, ever (closed: $(cat "$T/closed.txt"))"
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 1 ] && ok \
  || bad "the duplicate row must spend no counter of its own (rebuilds=$(STATEJSON tproj-TK-9 | jq -r .rebuilds))"

# ============================================================================
# E2. THE MUTE IS ONLY EVER CLAIMED FOR A RUNG THAT REALLY RAN. The dedupe used
#     to record the ticket the moment its cap key was known — before the
#     terminal reads, before the merged guard, before the one line that says
#     what is about to run, and in observe mode too. So an observe tick, which
#     takes no rung at all, logged sibling rows as "already took a rung this
#     tick" and printed no candidate for them: tests/conductor-sticky-handoff-
#     test.sh reads exactly those lines. The key is recorded AFTER the dispatch
#     and only when a rung ran; the candidate line is ahead of any dedupe.
# ============================================================================
# E2a. Observe mode: nothing takes a rung, so nothing may be muted, and every
#      row for the ticket must still say what it would have done.
CLEAN; JOBS_FAIL
SPENT tproj-TK-9
ROW "o/tproj#9" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/9"
RUN                                   # tick 1: real, so there is a retry row too
JOBS_OK
touch "$H/flags/blocked-resolver-observe"
: > "$H/logs/blocked-resolver.log"
RUN
rm -f "$H/flags/blocked-resolver-observe"
grep -q 'already took a rung this tick' "$H/logs/blocked-resolver.log" \
  && bad "observe mode takes no rung, so no row may be muted as if one had (log: $(LOG | tail -6))" || ok
[ "$(grep -c ' -> ' "$H/logs/blocked-resolver.log")" = 2 ] && ok \
  || bad "both rows for the ticket must name their candidate rung in observe mode (got $(grep -c ' -> ' "$H/logs/blocked-resolver.log"); log: $(LOG | tail -6))"
# E2b. A real tick still dedupes — but the muted row has already said what it
#      was a candidate for, so the log never hides a row behind the mute.
CLEAN; JOBS_FAIL
SPENT tproj-TK-9
ROW "o/tproj#9" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/9"
RUN                                   # tick 1: closes the PR, enqueue fails
JOBS_OK
: > "$H/logs/blocked-resolver.log"
RUN                                   # tick 2: two rows, one ticket
DEDUPE_LN=$(grep -n 'already took a rung this tick' "$H/logs/blocked-resolver.log" | head -1 | cut -d: -f1)
[ -n "$DEDUPE_LN" ] && ok \
  || bad "the second row for one ticket must still be muted on a real tick (log: $(LOG | tail -6))"
MUTED_RKEY=$(grep 'already took a rung this tick' "$H/logs/blocked-resolver.log" \
             | head -1 | sed -nE 's#^.* (tproj/[^ :]+): .*#\1#p')
CAND_LN=$(grep -n "$MUTED_RKEY \[" "$H/logs/blocked-resolver.log" | head -1 | cut -d: -f1)
[ -n "$CAND_LN" ] && [ -n "$DEDUPE_LN" ] && [ "$CAND_LN" -lt "$DEDUPE_LN" ] && ok \
  || bad "the muted row must name its candidate rung BEFORE the mute line (cand=$CAND_LN dedupe=$DEDUPE_LN rkey=$MUTED_RKEY; log: $(LOG | tail -6))"

# ============================================================================
# F. A HOLD ON THE TICKET STOPS THE RETRY TOO (bin/lib/hold.sh, the real one).
# ============================================================================
cp "$DIR/bin/lib/hold.sh" "$H/bin/lib/hold.sh" 2>/dev/null || true
ISSUE9=$(jq -nc --arg c "$(ISO 604800)" \
  '{number:9,state:"open",labels:[{name:"ai-build"}],title:"TK-9: the report nav",body:"## Scope",created_at:$c}')
printf '%s\n' "$ISSUE9" > "$T/issue-9.json"
printf '[]\n' > "$T/comments-9.json"
CLEAN; JOBS_FAIL
SPENT tproj-TK-9
ROW "o/tproj#9" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/9"
RUN                                   # tick 1: clear thread, the enqueue fails
[ "$(STATEJSON tproj-TK-9 | jq -r '.attempts[-1].action')" = rebuild-fresh-failed ] && ok \
  || bad "tick 1 of the hold case must reach the failed enqueue (attempts: $(STATEJSON tproj-TK-9 | jq -c '[.attempts[].action]'))"
# Now the ticket says HOLD, and the retry is the rung that must respect it.
jq -nc --arg c "$(ISO 1800)" \
  '[{body:"HOLD — the operator: do not rebuild this.",created_at:$c,user:{type:"User"}}]' > "$T/comments-9.json"
ROWST "o/tproj#9" CLOSED "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/9"
echo CLOSED > "$T/prstate"
JOBS_OK
RUN
grep -q '^tproj ' "$T/queue.txt" \
  && bad "a HELD ticket must not be enqueued by the retry: $(cat "$T/queue.txt")" || ok
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = HELD ] && ok \
  || bad "the retry must park the row at HELD (got '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 0 ] && ok \
  || bad "a held retry spends no counter (rebuilds=$(STATEJSON tproj-TK-9 | jq -r .rebuilds))"
[ -s "$T/lane-alert.txt" ] && bad "a respected hold is not an alert: $(cat "$T/lane-alert.txt")" || ok
RUN                                   # still held: still nothing, still no counter
grep -q '^tproj ' "$T/queue.txt" \
  && bad "a still-held ticket must stay un-enqueued: $(cat "$T/queue.txt")" || ok
# ...and the row is STILL OFFERED, which is what the lift proves: nothing here
# waits for a person to clear state by hand.
jq -nc --arg c1 "$(ISO 1800)" --arg c2 "$(ISO 600)" \
  '[{body:"HOLD — the operator: do not rebuild this.",created_at:$c1,user:{type:"User"}},
    {body:"RESUME",created_at:$c2,user:{type:"User"}}]' > "$T/comments-9.json"
RUN
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "once the hold lifts the retry row must still be there to run (queue: $(cat "$T/queue.txt"); log: $(LOG | tail -5))"
rm -f "$H/bin/lib/hold.sh"

# ============================================================================
# G. THE NEGATIVES. A retry row is offered for exactly one state and no other.
# ============================================================================
# G1. A PR-number cap key is a park with NO derivable ticket key: rung 3 refused
#     it (rc 2, counted), and there is nothing to retry an enqueue WITH.
CLEAN; JOBS_OK
jq -nc --arg at "$AT" '{project:"tproj",rkey:"o-tproj-77",mechanicals:1,fixrounds:1,rebuilds:1,
   outcome:"",parked_url:"https://github.com/o/tproj/pull/77",enqueue_failures:1,
   attempts:[{at:$at,action:"rebuild-fresh-failed",reason:"conflict-unresolvable",detail:"x"}]}' \
  > "$H/state/blocked-resolver/tproj/o-tproj-77.json"
RUN
grep -q '^tproj ' "$T/queue.txt" \
  && bad "a keyless park must never be retried into an enqueue: $(cat "$T/queue.txt"))" || ok
[ "$(STATEJSON o-tproj-77 | jq -r '[.attempts[]] | length')" = 1 ] && ok \
  || bad "and nothing may be recorded against it (attempts: $(STATEJSON o-tproj-77 | jq -c '[.attempts[].action]'))"
# G2. A rebuild IN FLIGHT (last attempt rebuild-fresh, no RESULT yet) is not a
#     failed enqueue and must not be re-enqueued on top of itself.
CLEAN; JOBS_OK
jq -nc --arg at "$AT" '{project:"tproj",rkey:"tproj-TK-9",mechanicals:1,fixrounds:1,rebuilds:1,
   outcome:"",parked_url:"https://github.com/o/tproj/pull/9",parked_rec:"-",
   attempts:[{at:$at,action:"rebuild-fresh",reason:"conflict-unresolvable",detail:"enqueued"}]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
RUN
grep -q '^tproj ' "$T/queue.txt" \
  && bad "a build in flight must not be enqueued again: $(cat "$T/queue.txt")" || ok
# G3. An ABANDONED ticket is terminal. A failure underneath it changes nothing.
CLEAN; JOBS_OK
jq -nc --arg at "$AT" '{project:"tproj",rkey:"tproj-TK-9",mechanicals:1,fixrounds:1,rebuilds:3,
   outcome:"ABANDONED",parked_url:"https://github.com/o/tproj/pull/9",parked_rec:"-",enqueue_failures:2,
   attempts:[{at:$at,action:"rebuild-fresh-failed",reason:"conflict-unresolvable",detail:"x"}]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
RUN
grep -q '^tproj ' "$T/queue.txt" \
  && bad "an ABANDONED ticket must never be retried: $(cat "$T/queue.txt")" || ok
[ "$(STATEJSON tproj-TK-9 | jq -r '[.attempts[]] | length')" = 1 ] && ok \
  || bad "and nothing may be appended to a terminal record (attempts: $(STATEJSON tproj-TK-9 | jq -c '[.attempts[].action]'))"
# G4. The rebuild cap still bounds the retry: a ticket at BR_MAX_REBUILDS is
#     ABANDONED by the retry rung, exactly as the fresh rung would have.
CLEAN; JOBS_OK
jq -nc --arg at "$AT" '{project:"tproj",rkey:"tproj-TK-9",mechanicals:1,fixrounds:1,rebuilds:3,
   outcome:"",parked_url:"https://github.com/o/tproj/pull/9",parked_rec:"-",enqueue_failures:1,
   attempts:[{at:$at,action:"rebuild-fresh-failed",reason:"conflict-unresolvable",detail:"x"}]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-9.json"
RUN
[ "$(STATEJSON tproj-TK-9 | jq -r .outcome)" = ABANDONED ] && ok \
  || bad "the retry must honour the rebuild cap and end the ladder (outcome '$(STATEJSON tproj-TK-9 | jq -r .outcome)')"
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" \
  && bad "a capped ticket must not be enqueued by the retry: $(cat "$T/queue.txt")" || ok

# ============================================================================
# H. OBSERVE MODE takes no rung and writes nothing — the retry included.
# ============================================================================
CLEAN; JOBS_FAIL
SPENT tproj-TK-9
ROW "o/tproj#9" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/9"
RUN                                   # tick 1: real, so there is a retry row to observe
ROWST "o/tproj#9" CLOSED "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/9"
echo CLOSED > "$T/prstate"
JOBS_OK
touch "$H/flags/blocked-resolver-observe"
FAILS_BEFORE=$(STATEJSON tproj-TK-9 | jq -r .enqueue_failures)
RUN
rm -f "$H/flags/blocked-resolver-observe"
grep -q 'WOULD retry the enqueue' "$H/logs/blocked-resolver.log" && ok \
  || bad "observe mode must SAY what it would have done (log: $(LOG | tail -3))"
grep -q '^tproj ' "$T/queue.txt" \
  && bad "observe mode must enqueue nothing: $(cat "$T/queue.txt")" || ok
[ "$(STATEJSON tproj-TK-9 | jq -r .enqueue_failures)" = "$FAILS_BEFORE" ] && ok \
  || bad "observe mode must not move a counter (was $FAILS_BEFORE, now $(STATEJSON tproj-TK-9 | jq -r .enqueue_failures))"
[ "$(STATEJSON tproj-TK-9 | jq -r .rebuilds)" = 0 ] && ok \
  || bad "observe mode must spend no rebuild (rebuilds=$(STATEJSON tproj-TK-9 | jq -r .rebuilds))"

echo "blocked-resolver.bh-488-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
