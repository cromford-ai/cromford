#!/bin/bash
# tests/br-reads-test.sh — what the lane READS before it decides anything: the
# ticket key it derives from a park, and the rows it picks up from the
# conductor. Sections 6b and 6c of the old tests/blocked-resolver-test.sh, moved
# here verbatim by BH-1196 and named for the discovery-reads slice of the
# bin/lib/br/ split.
#
# WHY IT IS ITS OWN SUITE. Everything downstream is keyed on the answer. A park
# whose ticket key the lane cannot derive is a park the lane drops on the floor
# quietly, and a conductor row in a state the lane does not recognise is a PR
# nobody owns — both are silent, and both were live incidents (project-5 #1124
# and #1136 on 2026-09-15 for the key, the RED_TWICE handover the same week).
#
# Sections carried (original numbering, from tests/blocked-resolver-test.sh):
#   6b. the ticket key is DERIVED, not given up on
#   6c. RED_TWICE rows are this lane's too
# Run from anywhere: tests/br-reads-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# The whole fixture — scratch tree, br modules, sibling libs, the stubbed PATH
# and the RUN/ROW/ROWST/STATEJSON/SPENT helpers — is tests/lib/fixture-harness.sh
# (BH-1196). What is installed and why is documented there.
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
H="$T/h"
mkdir -p "$H/bin"
# The scripts this suite drives. The copy stays HERE, in the suite's own text,
# so bin/test-impact.sh still selects this suite when one of them changes.
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fly-pool.sh" "$DIR/bin/merge-sweep.sh" \
   "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$H/bin/"
fx_br_harness "$DIR" "$T" || exit 1
[ -d "$DIR/bin/lib/br" ] || exit 1   # impact: this suite runs when bin/lib/br/ changes
# BH-6461: the key family moved to bin/lib/br/keys.sh; the corpus is the driver
# plus bin/lib/br/*.sh (tests/lib/br-corpus.sh), so the extraction finds it there.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$H" "$T/br-corpus.sh" || exit 1

# ============================================================================
# 6b. THE TICKET KEY IS DERIVED, NOT GIVEN UP ON.
#
# 2026-09-15: project-5 #1124 (TK-775, 06:14Z) and #1136 (TK-1109, 07:34Z) were
# closed by the rebuild rung and then never re-enqueued — "no ticket key —
# cannot enqueue a fresh build" — so both tickets sat with NO owner. The key was
# on the branch (ticket/TK-775) all along; discovery asks gh for that branch
# BEFORE br_one installs the repo token, and gh with the wrong token answers
# nothing at all. So the key is asked for again where the token works, and the
# parsers that read it are driven here one source at a time.
# ============================================================================
# THE DERIVATION READS THE PR OVER REST NOW (#783), so the two helpers that read
# it come out with the parsers, and the extract carries the contract library and
# a no-op `say` the way the running script carries them.
{ printf '. "%s/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1\n' "$H"
  printf '. "%s/bin/lib/gh-rest.sh"\n' "$H"
  printf 'say() { :; }\n'
} > "$T/keys.sh"
for fn in br_key_shape br_key_from_branch br_key_from_title br_key_from_dir \
          br_ticket_key br_slug_of_url br_pr_field br_derive_ticket_key; do
  awk -v F="^$fn\\(\\)" '$0~F{f=1} f{print} f&&/^}$/{exit}' "$T/br-corpus.sh"
done >> "$T/keys.sh"
[ "$(grep -c '^br_.*() {' "$T/keys.sh")" = 8 ] && ok || bad "could not extract the eight key-derivation functions"
K() { HARNESS="$H" bash -c '. "$0"; "$@" || echo NONE' "$T/keys.sh" "$@"; }

# --- the branch, including the real project-5 one this incident was about -----
for pair in "ticket/TK-775:TK-775" "ticket/TK-1109:TK-1109" "ticket/TK-716-r2:TK-716" \
            "ticket/TK-775-r12:TK-775" "TK-1109-report-nav:TK-1109" "TK-775:TK-775" \
            "ticket/TK-1617:TK-1617" "feat/TK-1617-fee-toggle:TK-1617" "fix/TK-88:TK-88"; do
  got=$(K br_key_from_branch "${pair%%:*}")
  [ "$got" = "${pair##*:}" ] && ok || bad "branch '${pair%%:*}' must derive ${pair##*:}, got '$got'"
done
# A branch that carries no key must answer NOTHING. An invented key is worse
# than none: bin/fly-pool.sh quarantines the row, or the wrong ticket is built.
for b in fix/report-nav-anchors main ticket/ hotfix "-" ""; do
  got=$(K br_key_from_branch "$b")
  [ "$got" = NONE ] && ok || bad "branch '$b' carries no ticket key but derived '$got'"
done

# --- the PR title -------------------------------------------------------------
for pair in "TK-775: report nav anchors:TK-775" "[TK-1617] discount toggle:TK-1617" \
            "(TK-88) the thing:TK-88" "TK-472 something:TK-472"; do
  got=$(K br_key_from_title "${pair%:*}")
  [ "$got" = "${pair##*:}" ] && ok || bad "title '${pair%:*}' must derive ${pair##*:}, got '$got'"
done
# A key mentioned mid-sentence is a REFERENCE to another ticket, never this one.
for t in "fix(nav): supersedes TK-700" "rebuild the report nav" "-"; do
  got=$(K br_key_from_title "$t")
  [ "$got" = NONE ] && ok || bad "title '$t' must not yield a key, got '$got'"
done

# --- the build dir the pipeline itself named ----------------------------------
[ "$(K br_key_from_dir project-5 /root/harness/builds/pool-project-5-TK-775-202609150614)" = TK-775 ] \
  && ok || bad "a pool build dir must yield its key"
[ "$(K br_key_from_dir tproj "$H/builds/tproj-TK-9-202609150614")" = TK-9 ] \
  && ok || bad "a box build dir must yield its key"
[ "$(K br_key_from_dir tproj /root/harness/builds/pool-project-5-TK-775-202609150614)" = NONE ] \
  && ok || bad "a build dir belonging to another project must yield nothing"

# --- br_derive_ticket_key: branch, then title, then the record ---------------
mkdir -p "$T/ghd"
cat > "$T/ghd/gh" <<EOF
#!/bin/bash
# The branch and the title are one REST PR object now (#783), so this harness
# answers the \`gh api -i\` envelope with both fields taken from its two env vars.
case "\$*" in
  *"-i -X GET"*"/pulls/"*)
      printf 'HTTP/2 200\r\n\r\n'
      jq -nc --arg br "\${GHBRANCH:-}" --arg ti "\${GHTITLE:-}" \
        '{state:"open",merged_at:null,head:{sha:"",ref:\$br},base:{ref:"main"},title:\$ti}' ;;
  *) printf '' ;;
esac
exit 0
EOF
chmod +x "$T/ghd/gh"
D() { ( export PATH="$T/ghd:$PATH" GHBRANCH="$1" GHTITLE="$2" HARNESS="$H"
        bash -c '. "$0"; br_derive_ticket_key "$1" "$2" "$3" || echo NONE' \
             "$T/keys.sh" tproj https://github.com/o/tproj/pull/9 "${3:--}" ) ; }
[ "$(D ticket/TK-775 'TK-999: wrong')" = TK-775 ] && ok || bad "the head branch must be the first source"
[ "$(D '' '[TK-1109] report nav')" = TK-1109 ] && ok || bad "with no branch, the PR title must be read"
[ "$(D '' '' "$H/builds/tproj-TK-9-202609150614")" = TK-9 ] && ok \
  || bad "with no branch and no title, the build record must be read"
[ "$(D '' '')" = NONE ] && ok || bad "with nothing to read, the derivation must FAIL rather than guess"

# --- driven: the incident itself ---------------------------------------------
# A PR with NO build record (the shape mc_record_for cannot answer for: both
# real records read `RESULT_UNVERIFIED PR_CREATED ...`, which it skips), whose
# gh answers the FIRST headRefName call with nothing — discovery, wrong token —
# and the real branch afterwards, under the repo token. Before this change the
# run closed the PR and enqueued nothing.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  # THE DERIVATION READ IS REST NOW (#783), and it is the read hrn-blank-always
  # and hrn-blank-first are about: the branch and the title arrive in one PR
  # object, so the blanking that used to sit on \`--json headRefName\` sits here.
  *"-i -X GET"*"/pulls/"*)
    _BR=ticket/TK-9
    [ -f "$T/hrn-blank-always" ] && _BR=""
    if [ -f "$T/hrn-blank-first" ]; then
      N=\$(cat "$T/hrn-count" 2>/dev/null || echo 0); echo \$((N+1)) > "$T/hrn-count"
      [ "\$N" = 0 ] && _BR=""
    fi
    # Only the BRANCH is this section's business: the state (including "has this
    # run already closed it", which the close has to verify) stays the shared
    # stub's, so a close here is as real as anywhere else.
    printf '%s' "\$_BR" > "$T/prbranch"
    GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr close"*)  printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) exit 0 ;;
  *"--json state"*) echo OPEN ;;
  # br_pr_ref's REST read: this section's PR has NO BRANCH — head.ref comes back
  # null, which is the rc 1 "genuinely branchless" answer rather than the rc 2
  # "could not read" one. The rungs cascade to the rebuild, which is where the
  # ticket-key derivation under test lives.
  *"/pulls/"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa null" ;;
  *"--json headRefName"*)
    # hrn-blank-always: gh never answers (the no-key case below).
    # hrn-blank-first: blank on the FIRST call only, which is discovery's.
    [ -f "$T/hrn-blank-always" ] && exit 0
    if [ -f "$T/hrn-blank-first" ]; then
      N=\$(cat "$T/hrn-count" 2>/dev/null || echo 0); echo \$((N+1)) > "$T/hrn-count"
      [ "\$N" = 0 ] && exit 0
    fi
    echo "ticket/TK-9" ;;
  *"--json title"*) cat "$T/prtitle" 2>/dev/null ;;
  *"pr list"*) cat "$T/mergedprs" 2>/dev/null ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/prtitle"
scratch_rm "$H/state/blocked-resolver"; : > "$T/mergedprs"
# THE REBUILD RUNG IS REACHED BY EVENTS, NOT BY A MISSING CLONE (2026-09-16).
# This section is about br_rebuild_fresh's KEY DERIVATION, so each park has to
# arrive at rung 3 — and since the fix above, a park only gets there because the
# cheaper rungs RAN and did not land. There is no clone at all at this point in
# the file (it is created further down, for section 6), so leaving the counters
# at zero would now park every case on br_setup_blocked and derive nothing.
# Seeding the two spent rungs is that history stated outright.
# SPENT lives in tests/lib/fixture-harness.sh since BH-1196: section 11 of the
# old suite (now tests/br-rebuild-outcome-test.sh) calls it too.
rm -f "$H"/state/build-queue/tproj/*.json   # section 5's park, not this one's
touch "$H/flags/fly-pool-tproj"
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
SPENT tproj-TK-9
ROW "o/tproj#55" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/55"
: > "$T/queue.txt"; : > "$T/closed.txt"; : > "$T/lane-alert.txt"; rm -f "$T/hrn-count"
touch "$T/hrn-blank-first"
RUN
rm -f "$T/hrn-blank-first"
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "a keyless candidate must derive its key and still enqueue (queue: $(cat "$T/queue.txt"))"
grep -q 'derived TK-9' "$H/logs/blocked-resolver.log" && ok \
  || bad "the run must SAY the key was derived rather than silently inventing one"
[ -s "$T/lane-alert.txt" ] && bad "a derivation that SUCCEEDED must not page: $(cat "$T/lane-alert.txt")" || ok

# The PR TITLE is the second source: no branch at all, key at the front of the
# title, and the rebuild still lands.
scratch_rm "$H/state/blocked-resolver"
SPENT tproj-TK-9
printf 'TK-9: the report nav anchors\n' > "$T/prtitle"
ROW "o/tproj#56" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/56"
: > "$T/queue.txt"; : > "$T/lane-alert.txt"
touch "$T/hrn-blank-always"
RUN
grep -q '^tproj TK-9 9 fly 0 ' "$T/queue.txt" && ok \
  || bad "with no branch, the PR title must carry the rebuild (queue: $(cat "$T/queue.txt"))"
: > "$T/prtitle"

# --- driven: nothing anywhere carries a key, so it ALERTS ---------------------
# The PR is closed by the time the enqueue is refused, so the ticket has no
# owner at all. That is the one outcome this lane may never keep to itself.
scratch_rm "$H/state/blocked-resolver"
SPENT o-tproj-77
ROW "o/tproj#77" "conflict-unresolvable: CONFLICT (content): src/a.ts" "https://github.com/o/tproj/pull/77"
: > "$T/queue.txt"; : > "$T/closed.txt"; : > "$T/lane-alert.txt"
RUN
grep -q '^tproj ' "$T/queue.txt" && bad "with no derivable key nothing may be enqueued: $(cat "$T/queue.txt")" || ok
grep -q 'no ticket key' "$H/logs/blocked-resolver.log" && ok || bad "the refusal must still be logged"
grep -q 'https://github.com/o/tproj/pull/77' "$T/lane-alert.txt" && ok \
  || bad "the give-up must lane-alert WITH the PR url (got: $(cat "$T/lane-alert.txt"))"
# ...once. This lane re-offers the same park every ten minutes.
: > "$T/lane-alert.txt"
RUN
[ -s "$T/lane-alert.txt" ] && bad "the no-key alert must page once per key, not every tick" || ok
rm -f "$T/hrn-blank-always"
rm -f "$H/flags/fly-pool-tproj"

# ============================================================================
# 6c. RED_TWICE rows are this lane's too (2026-09-15, project-5 #1045).
#     The conductor's red ladder ends in a state that is NOT the word
#     BLOCKED_HUMAN, and a row source that only ever matched that one word would
#     leave every red-twice park with no owner — which is the bug the ladder was
#     written to fix, one state further along.
# ============================================================================
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
# Section 4 left a sweep-shaped gh stub behind; this rung needs the branch name
# (the ticket key comes from it) and a close that is recorded.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  # bin/blocked-resolver.sh reads, comments and closes over REST (#783): the
  # gh-api-dash-i envelope is answered once, in tests/lib/gh-rest-stub.sh.
  *"-i -X "*)
    # This section's PR is #77 on ticket/TK-77, so the one REST object the lane
    # now reads is named here before the shared stub answers it.
    printf 'ticket/TK-77' > "$T/prbranch"
    printf 'TK-77: a thing' > "$T/prtitle"
    printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' > "$T/prhead"
    GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr close"*)   printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*|*"issue comment"*) exit 0 ;;
  *"--json state"*)       echo OPEN ;;
  # The mechanical rung reads the head and the branch in ONE call, so the stub
  # answers that shape before the single-field ones.
  *"/pulls/"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/TK-77" ;;
  *"--json headRefOid,headRefName"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/TK-77" ;;
  *"--json headRefName"*) echo "ticket/TK-77" ;;
  *"--json headRefOid"*)  echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;
  *"pr list"*"--state merged"*) : ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
touch "$H/flags/fly-pool-tproj"   # pool project: the enqueue is a queue row
ROWST "o/tproj#77" RED_TWICE "red-twice: still red on abc12345 after its failed jobs were re-run once" "https://github.com/o/tproj/pull/77"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"
RUN
grep -q 'tproj-77\|tproj/77\|TK-77' "$H/logs/blocked-resolver.log" \
  && ok || bad "a RED_TWICE row must be picked up as a candidate (log: $(tail -3 "$H/logs/blocked-resolver.log"))"
grep -q 'red-twice/ci-red.: ladder rung: mechanical' "$H/logs/blocked-resolver.log" \
  && ok || bad "a red-twice park must enter the LADDER as a ci-red class (log: $(tail -3 "$H/logs/blocked-resolver.log"))"
grep -q 'red-twice.* -> mechanical' "$H/logs/blocked-resolver.log" \
  && ok || bad "the line a reader greps must name the RUNG that runs, not the table it came from (log: $(tail -3 "$H/logs/blocked-resolver.log"))"
# With no credential the mechanical rung cannot run at all, and THAT MUST NOT
# CASCADE: the fix round needs the same clone, so a machine problem would walk
# a park down to a fresh rebuild in one tick. Since 2026-09-16 it spends nothing
# either (br_setup_blocked) — the rung is a fact about the box, and the park is
# re-offered the same rung next tick instead of walking toward the rebuild.
grep -q 'the mechanical rung could not START' "$H/logs/blocked-resolver.log" \
  && ok || bad "a mechanical rung that cannot even set up must say so and stop for the tick (log: $(tail -3 "$H/logs/blocked-resolver.log"))"
[ "$(STATEJSON tproj-TK-77 | jq -r .mechanicals)" = 0 ] && ok \
  || bad "a mechanical rung that could not run spends nothing — the ladder may only be walked by events (got $(STATEJSON tproj-TK-77 | jq -r .mechanicals))"
[ -s "$T/closed.txt" ] && bad "the FIRST rung of a red-twice park must not close the PR — that is the rebuild rung, two rungs later" || ok
grep -q '^tproj TK-77 ' "$T/queue.txt" && bad "the first rung must not enqueue a rebuild (got: $(cat "$T/queue.txt"))" || ok
# BR_LADDER=0 is the operator's way back to the pre-ladder behaviour, and it has
# to be exactly that: the same park, closed and rebuilt in one tick.
scratch_rm "$H/state/blocked-resolver"
: > "$T/closed.txt"; : > "$T/queue.txt"; : > "$H/logs/blocked-resolver.log"
BRENV=(BR_LADDER=0); RUN; BRENV=()
grep -q 'red-twice.* -> rebuild-fresh' "$H/logs/blocked-resolver.log" \
  && ok || bad "BR_LADDER=0 must take a red-twice park straight to REBUILD FRESH (log: $(tail -3 "$H/logs/blocked-resolver.log"))"
[ -s "$T/closed.txt" ] && ok || bad "the rebuild must close the stale PR behind a red-twice park"
grep -q '^tproj TK-77 77 fly 0 ' "$T/queue.txt" \
  && ok || bad "the rebuild must enqueue the ticket fresh at attempt 0 (got: $(cat "$T/queue.txt"))"
# The hand-off LOG recovery reads the conductor's RED_TWICE line shape too — a
# park whose row has since moved on must still be recoverable.
HOFF=$(awk '/^br_handoff_lines\(\)/{f=1} f{print} f&&/^}$/{exit}' "$H/bin/blocked-resolver.sh")
printf '%s\n' "2026-09-15 09:00:00Z o/tproj#78 RED_TWICE red-twice: still red on abc12345 after its failed jobs were re-run once — handed to bin/blocked-resolver.sh (fix round on the branch, or a fresh rebuild against current main): https://github.com/o/tproj/pull/78" \
  > "$H/logs/merge-conductor.log"
OUT=$(BR_HANDOFF_MAX_AGE_SECS=999999999 H="$H" bash -c "$HOFF"'
br_handoff_lines' 2>/dev/null)
[ "$(cut -f1 <<<"$OUT")" = "o/tproj#78" ] && ok || bad "br_handoff_lines must recover a RED_TWICE hand-off line (got '$OUT')"
[ "$(cut -f2 <<<"$OUT")" = "red-twice" ] && ok || bad "the recovered reason must be the mapped word (got '$OUT')"
[ "$(cut -f3 <<<"$OUT")" = "https://github.com/o/tproj/pull/78" ] && ok || bad "the recovered url must be the PR (got '$OUT')"
: > "$H/logs/merge-conductor.log"
rm -f "$H/flags/fly-pool-tproj"

echo "br-reads-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
