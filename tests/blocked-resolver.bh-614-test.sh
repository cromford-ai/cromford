#!/bin/bash
# tests/blocked-resolver.bh-614-test.sh — an approved, pushed branch whose PR
# never opened is a park this lane OWNS, and it is taken from the build record
# only, never from the queue row.
#
# THE DEFECT (BH-614). `bin/run-build.sh`'s ratchet writes `PR_CREATE_FAILED:`
# when a create returns no url, `bin/fly-pool.sh`'s url-shape gate (BH-765)
# rewrites an older pool image's url-less claim to `RESULT_MALFORMED PR_CREATED
# …`, and the reap now closes both rows FAILED. Nothing then re-entered them:
# `br_from_builds` had no arm for either word and `br_action pr-create-failed`
# answered `none`, so a reviewed branch with no PR sat until a person noticed.
# the operator's 2026-09-13 rule is that nothing in this harness waits on a human; a
# ladder that runs out records ABANDONED.
#
# THE OTHER HALF, which is why the intake is deliberately narrow: the record is
# taken only once it is 90 MINUTES OLD, and the FAILED queue row is never an
# intake at all. `bin/pr-url-reconcile.sh` runs every ten minutes and re-links a
# record whose PR did open on a later rung of the create ladder (the BH-848
# shape). Rebuilding inside that window is two PRs for one ticket — the thing
# this whole ticket exists to stop. Section B2 is that negative, and section C
# drives the reconciler's own side of the handshake: a record the resolver has
# superseded is never re-linked, and BH-765's spelling is walked like the
# ratchet's.
#
# HOW IT DRIVES: the classifier functions are extracted and called, and the REAL
# bin/blocked-resolver.sh is then run end to end against a scratch $HARNESS with
# a stubbed jobs-client, a recorded gh and a recorded lane-alert — the same
# harness shape as tests/blocked-resolver-test.sh. Assertions are on artifacts:
# the tuple br_from_builds prints, the enqueue line, the markers on the record,
# the state file and the alert file.
# Run from anywhere: tests/blocked-resolver.bh-614-test.sh  (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NOW=$(date -u +%s)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq is required to drive this lane"; exit 1; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$H/state/build-queue/tproj" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/pr-url-reconcile.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
cp "$DIR/bin/lib/lane-switch.sh" "$DIR/bin/lib/lane-gate.sh" "$H/bin/lib/"
cp "$DIR/bin/alert-line.sh" "$H/bin/"
# BH-1176: the lane sources bin/lib/br/ and REFUSES the tick when a module is
# missing, so the modules travel with the copy. One helper, one edit when the
# split moves again.
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$H/bin/lib/"
# bin/blocked-resolver.sh now REQUIRES the REST contract (#783): without it the
# lane refuses to start rather than deciding on undefined reads.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
for l in env-path.sh gh-pr-create.sh result-pr-url.sh rebuild-ledger.sh; do
  [ -r "$DIR/bin/lib/$l" ] && cp "$DIR/bin/lib/$l" "$H/bin/lib/"
done
chmod +x "$H/bin/"*.sh
# One project, a GitHub-Issues lane (board prefix "-"), Fly-routed.
printf 'tproj o/tproj - - 2 box-tproj 100.0.0.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"
touch "$H/flags/fly-pool-tproj"
for f in beat.sh agent-call.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
# Every gh call is recorded, so "did anything close a PR" and "did anything reach
# GitHub for this record" are facts about the run, not hopes.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  # bin/blocked-resolver.sh reads, comments and closes over REST (#783): the
  # gh-api-dash-i envelope is answered once, in tests/lib/gh-rest-stub.sh.
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr close"*) printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr list"*"--state merged"*) cat "$T/mergedprs" 2>/dev/null ;;
  "api -i"*) cat "$T/api-response" 2>/dev/null ;;
  *"--json state"*) echo OPEN ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/mergedprs"; : > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/lane-alert.txt"; : > "$T/api-response"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""
# A jobs client whose queue_put is recorded rather than sent.
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { cat "$T/queue-list.txt" 2>/dev/null; }
EOF
: > "$T/queue.txt"; : > "$T/queue-list.txt"

RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
RECONCILE() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
                bash "$H/bin/pr-url-reconcile.sh" >>"$T/run.log" 2>&1 ) || true; }
STATEJSON() { cat "$H/state/blocked-resolver/tproj/$1.json" 2>/dev/null; }

# A record of one ticket, its RESULT aged by hand off the single NOW read.
REC=""
record() { # record <key> <age-seconds> <line1>
  REC="$H/builds/pool-tproj-$1-202609180000"
  scratch_rm "$REC"; mkdir -p "$REC"
  printf '%s\n' "$3" > "$REC/RESULT"
  touch -d "@$(( NOW - $2 ))" "$REC/RESULT"
}
L1="PR_CREATE_FAILED: GraphQL: API rate limit already exceeded for installation ID 161623167. — refused a url-less create claim carrying ''"
L1M="RESULT_MALFORMED PR_CREATED  | STACKED on ticket/TK-1883 (https://github.com/example-org/project-5/pull/1925) - parent PR not resolved"

# ═══════════════════════════════════════════════════════════════════════════
# A. The classifier. Extracted and CALLED — a table in the test that agrees
#    with a table in the test proves nothing.
# ═══════════════════════════════════════════════════════════════════════════
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the ladder functions moved out of the driver into bin/lib/br/ladder.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$H" "$T/br-corpus.sh" || exit 1
: > "$T/cls.sh"
for fn in br_action br_reason_of br_ladder_class br_ladder_rung br_skips_mechanical; do
  awk -v f="^$fn\\(\\)" '$0 ~ f {p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$T/cls.sh"
done
[ -s "$T/cls.sh" ] && ok || bad "A: could not extract the classifier functions"
cls()   { bash -c '. "$0"; br_reason_of "$1"' "$T/cls.sh" "$1"; }
act()   { bash -c '. "$0"; br_action "$1"' "$T/cls.sh" "$1"; }
klass() { bash -c '. "$0"; br_ladder_class "$1"' "$T/cls.sh" "$1"; }

[ "$(cls 'pr-create-failed: gh said no')" = pr-create-failed ] && ok \
  || bad "A1: the reason word must normalize on its prefix, got '$(cls 'pr-create-failed: gh said no')'"
[ "$(act pr-create-failed)" = rebuild-fresh ] && ok \
  || bad "A2: pr-create-failed must answer rebuild-fresh, got '$(act pr-create-failed)'"
# There is no branch to fix and no finding to read, so no rung of the ladder
# applies: a fix round with nothing to fix would spend a model on nothing.
[ -z "$(klass pr-create-failed)" ] && ok \
  || bad "A3: pr-create-failed must have no ladder class, got '$(klass pr-create-failed)'"
# The RAW RESULT text is not a reason word. If it classified, every log line
# quoting a RESULT would become a park.
[ -z "$(cls "$L1")" ] && ok \
  || bad "A4: raw RESULT text must not classify as a reason, got '$(cls "$L1")'"
[ "$(act "$(cls "$L1")")" = none ] && ok || bad "A4: an unclassified reason must answer none"

# ═══════════════════════════════════════════════════════════════════════════
# B1. br_from_builds offers the record — and its negatives.
# ═══════════════════════════════════════════════════════════════════════════
: > "$T/src.sh"
awk '/^br_from_builds\(\) \{/{p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" > "$T/src.sh"
awk '/^br_rkey\(\) \{/{p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$T/src.sh"
awk '/^br_from_queue\(\) \{/{p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$T/src.sh"
[ -s "$T/src.sh" ] && ok || bad "B1: could not extract br_from_builds/br_from_queue"
builds() { H="$H" ST="$H/state/blocked-resolver" ONLY=tproj \
           bash -c '. "$0"; br_from_builds' "$T/src.sh" 2>/dev/null; }
queue()  { H="$H" ONLY=tproj bash -c '. "$0"; br_from_queue' "$T/src.sh" 2>/dev/null; }

record TK-1885 7200 "$L1"
# `builds/pool-*-*/` and `builds/*-*/` both match a pool record, so main emits
# the tuple twice and br_one dedupes downstream. The tuple's CONTENT is what is
# pinned here — including the EIGHTH field (BH-1457), the park age, which this
# source has no clock for and emits as `-`. It used to be omitted entirely, and
# a ninth column appended downstream then landed in it and was read as an epoch.
GOT=$(builds | sort -u)
[ "$GOT" = "$(printf 'build\ttproj\ttproj-TK-1885\tpr-create-failed\t-\t%s\tTS-1885\t-' "$REC")" ] && ok \
  || bad "B1: the record must be offered as a pr-create-failed park, got '$GOT'"

# B1b — BH-765's spelling of the same park. The reap wrote it for a record an
# older pool image produced; it is the SAME reason here, never a PR_CREATED.
record TK-1885 7200 "$L1M"
GOT=$(builds | sort -u)
[ "$GOT" = "$(printf 'build\ttproj\ttproj-TK-1885\tpr-create-failed\t-\t%s\tTS-1885\t-' "$REC")" ] && ok \
  || bad "B1b: a reaped RESULT_MALFORMED PR_CREATED record must be the same park, got '$GOT'"

# B1c — the floor IS the reconciler's window: ten minutes old is still its business.
record TK-1885 600 "$L1"
[ -z "$(builds | sort -u)" ] && ok || bad "B1c: a record younger than 90 minutes must not be offered (got '$(builds)')"

# B1d — the reconciler got there first: line 1 is a real PR now.
record TK-1885 7200 "PR_CREATED https://github.com/o/tproj/pull/44 | RECONCILED 2026-09-18T08:03:00Z by pr-url-reconcile"
[ -z "$(builds | sort -u)" ] && ok || bad "B1d: a re-linked record must never be offered (got '$(builds)')"

# B1e — already superseded by an earlier rebuild.
record TK-1885 7200 "$L1"; : > "$REC/.blocked-resolver-superseded"
[ -z "$(builds | sort -u)" ] && ok || bad "B1e: a superseded record must not be offered again"

# B1f — the negative that keeps the two reap words apart: RESULT_UNVERIFIED is a
# PR that could not be READ, not a create that failed. Rebuilding it would open a
# second PR for a ticket whose first one is probably fine.
record TK-1885 7200 "RESULT_UNVERIFIED PR_CREATED https://github.com/o/tproj/pull/44"
[ -z "$(builds | sort -u)" ] && ok || bad "B1f: RESULT_UNVERIFIED is not this park (got '$(builds)')"

# ═══════════════════════════════════════════════════════════════════════════
# B2. The FAILED queue row is NOT an intake. This is the negative that keeps
#     the reconciler's ten-minute window intact.
# ═══════════════════════════════════════════════════════════════════════════
printf 'tproj\tTS-1885\t1885\tfailed\t-\t1\t-\t-\t%s\t-\n' "$L1" > "$T/queue-list.txt"
QGOT=$(queue)
grep -q 'TK-1885' <<<"${QGOT:-}" \
  && bad "B2: a PR_CREATE_FAILED queue row must never be a park — it would race bin/pr-url-reconcile.sh (got '$QGOT')" \
  || ok
: > "$T/queue-list.txt"

# ═══════════════════════════════════════════════════════════════════════════
# B3. End to end, through the real script.
# ═══════════════════════════════════════════════════════════════════════════
record TK-1885 7200 "$L1"
# A BUILD_DEAD record of another ticket: its own park, its own reason, and this
# rung must not reach across and retire it.
DEAD="$H/builds/pool-tproj-TK-1886-202609180000"
scratch_rm "$DEAD"; mkdir -p "$DEAD"
printf 'BUILD_DEAD the machine went away\n' > "$DEAD/RESULT"
# Under its OWN floor on purpose: it is not a candidate this tick, so "untouched"
# can only mean the pr-create-failed park did not reach across into it.
touch -d "@$(( NOW - 600 ))" "$DEAD/RESULT"
: > "$T/queue.txt"; : > "$T/closed.txt"; : > "$T/lane-alert.txt"
RUN
grep -q '^tproj TK-1885 1885 fly 0 ' "$T/queue.txt" && ok \
  || bad "B3: the fresh build must be enqueued with its ticket id (got: $(cat "$T/queue.txt"))"
[ "$(grep -c '^tproj TK-1885 ' "$T/queue.txt")" = 1 ] && ok \
  || bad "B3: exactly one enqueue for TK-1885, got $(grep -c '^tproj TK-1885 ' "$T/queue.txt")"
[ -f "$REC/.blocked-resolver-superseded" ] && ok || bad "B3: the record must be marked superseded"
[ -f "$REC/COMMENTED" ] && ok || bad "B3: the record must be marked COMMENTED so no sweep re-reads it"
[ -s "$T/closed.txt" ] && bad "B3: there is no PR to close — the url is '-' (got: $(cat "$T/closed.txt"))" || ok
[ "$(STATEJSON tproj-TK-1885 | jq -r .rebuilds)" = 1 ] && ok \
  || bad "B3: the rebuild must be counted, got '$(STATEJSON tproj-TK-1885 | jq -r .rebuilds)'"
grep -q 'pr-create-failed' "$H/logs/blocked-resolver.log" && ok \
  || bad "B3: the lane log must name the reason it acted on"
[ -f "$DEAD/.blocked-resolver-superseded" ] \
  && bad "B3: a BUILD_DEAD record of another ticket is its own park and must not be retired here" || ok

# B4. A second tick immediately after must not buy a second rebuild.
: > "$T/queue.txt"
RUN
grep -q '^tproj TK-1885 ' "$T/queue.txt" \
  && bad "B4: one PR-open failure buys ONE rebuild (got: $(cat "$T/queue.txt"))" || ok

# B5. The cap: past BR_MAX_REBUILDS the ladder ends ABANDONED, it does not ask.
scratch_rm "$H/state/blocked-resolver"
record TK-1887 7200 "$L1"
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc --arg k tproj-TK-1887 '{key:$k,rebuilds:3,mechanicals:0,fixrounds:0,attempts:[]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-1887.json"
: > "$T/queue.txt"; : > "$T/lane-alert.txt"
RUN
grep -q '^tproj TK-1887 ' "$T/queue.txt" \
  && bad "B5: past the cap there is no fourth enqueue (got: $(cat "$T/queue.txt"))" || ok
grep -q 'ABANDONED tproj/tproj-TK-1887 (pr-create-failed)' "$H/logs/ALERTS.log" && ok \
  || bad "B5: an exhausted ladder must page ABANDONED, never wait for a human (got: $(cat "$H/logs/ALERTS.log" 2>/dev/null))"

# ═══════════════════════════════════════════════════════════════════════════
# C. The other side of the handshake: bin/pr-url-reconcile.sh skips a record
#    this lane superseded. Without it the reconciler could re-link the retired
#    record and the merge sweep would have two PRs for one ticket.
# ═══════════════════════════════════════════════════════════════════════════
scratch_rm "$H/builds"; mkdir -p "$H/builds"
X="$H/builds/pool-tproj-TK-1888-202609180000"; mkdir -p "$X"
printf '%s\n' "$L1" > "$X/RESULT"; : > "$X/.blocked-resolver-superseded"
Y="$H/builds/pool-tproj-TK-1889-202609180000"; mkdir -p "$Y"
printf '%s\n' "$L1" > "$Y/RESULT"
: > "$T/gh.txt"; : > "$T/api-response"
cp "$X/RESULT" "$T/x-before"
RECONCILE
cmp -s "$X/RESULT" "$T/x-before" && ok || bad "C1: a superseded record must never be rewritten"
[ -f "$X/.pr-url-reconciled" ] && bad "C1: a superseded record must not be marked reconciled" || ok
grep -q 'TK-1888' "$T/gh.txt" && bad "C1: a superseded record must cost zero gh calls (got: $(cat "$T/gh.txt"))" || ok
# The negative: the UNMARKED record of the same shape IS walked, so C1 is not
# passing because the lane did nothing at all.
grep -q 'TK-1889' "$H/logs/pr-url-reconcile.log" && ok \
  || bad "C1: an unmarked PR_CREATE_FAILED record must still be walked (log: $(cat "$H/logs/pr-url-reconcile.log" 2>/dev/null))"
grep -qE 'skipped=[1-9]' "$H/logs/pr-url-reconcile.log" && ok \
  || bad "C1: the skipped record must be counted in the tick summary"

# C2 — the second shape the lane must read. A record BH-765's reap rewrote, whose
# PR an operator opened by hand, is re-linked on exactly the ratchet's terms.
scratch_rm "$H/builds"; mkdir -p "$H/builds"
Z="$H/builds/pool-tproj-TK-1890-202609180000"; mkdir -p "$Z"
printf '%s\n' "$L1M" > "$Z/RESULT"; printf 'TIER: 2\n' >> "$Z/RESULT"
PRURL="https://github.com/o/tproj/pull/77"
printf 'HTTP/2.0 200\r\n\r\n[{"html_url":"%s","state":"open"}]\n' "$PRURL" > "$T/api-response"
RECONCILE
case "$(head -1 "$Z/RESULT")" in
  "PR_CREATED $PRURL | RECONCILED "*"by pr-url-reconcile"*) ok ;;
  *) bad "C2: line 1 must be re-linked to the open PR, got '$(head -1 "$Z/RESULT")'" ;;
esac
grep -qx "RECONCILED_FROM: $L1M" "$Z/RESULT" && ok \
  || bad "C2: the original RESULT_MALFORMED line must be kept verbatim, got: $(cat "$Z/RESULT")"
grep -qx "PR: $PRURL" "$Z/RESULT" && ok \
  || bad "C2: the PR: line must be appended, got: $(cat "$Z/RESULT")"
grep -qx 'TIER: 2' "$Z/RESULT" && ok || bad "C2: the TIER line must survive the re-link"
[ -f "$Z/.pr-url-reconciled" ] && ok || bad "C2: a re-linked record must be marked terminal"

echo "blocked-resolver.bh-614: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
