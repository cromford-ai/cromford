#!/bin/bash
# tests/blocked-resolver.bh-1770-test.sh — a run the lane reaper killed is
# relaunched by bin/blocked-resolver.sh, on its capped rebuild ladder, and by
# nothing else (BH-1770 part B2; the operator's decision 2026-09-24).
#
# THE GAP. bin/lane-reaper.sh writes `ABANDONED_TIMEOUT <why>`, kills the lane,
# releases its claim and touches REAPED. The sweep then posted an honest board
# comment and touched COMMENTED — and that was the end of the ticket: nobody
# relaunched it, and nothing said who should (#1142 item 7). The decision: the
# blocked-resolver owns it, because it already owns the capped rebuild ladder
# and its audit trail; when that ladder is spent it ends ABANDONED with one
# alert and leaves the run for a human. Never the sweep.
#
# What is pinned (the fixture is tests/blocked-resolver.bh-614-test.sh's):
#   A   the classifier: abandoned-timeout -> rebuild-fresh, no ladder class
#   B1  a REAPED ABANDONED_TIMEOUT record is offered once the sweep has
#       COMMENTED it, without waiting out the 90-minute floor
#   B2  no REAPED (the kill has not landed) -> never offered; not yet COMMENTED
#       and young -> left to the sweep's close-out first
#   B3  end to end: one enqueue, the record superseded, rebuilds=1
#   B4  a second tick buys nothing
#   B5  past the cap: ABANDONED, one alert, no enqueue
#   C1  a rebuild that is ITSELF reaped spends the next rebuild — and only once
#       its record carries REAPED
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver.bh-1770-test.sh
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
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
cp "$DIR/bin/alert-line.sh" "$H/bin/"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$H/bin/lib/"
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$H/bin/lib/"
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/"
for l in env-path.sh gh-pr-create.sh result-pr-url.sh rebuild-ledger.sh; do
  [ -r "$DIR/bin/lib/$l" ] && cp "$DIR/bin/lib/$l" "$H/bin/lib/"
done
chmod +x "$H/bin/"*.sh
# One project, a GitHub-Issues lane (board prefix "-"), Fly-routed.
printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
: > "$H/env/global.env"
touch "$H/flags/fly-pool-tproj"
for f in beat.sh agent-call.sh run-build.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
case "\$*" in
  *"-i -X "*) GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"pr close"*) printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"--json state"*) echo OPEN ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
: > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/lane-alert.txt"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"
chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
: > "$T/queue.txt"

RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
STATEJSON() { cat "$H/state/blocked-resolver/tproj/$1.json" 2>/dev/null; }

VERDICT="ABANDONED_TIMEOUT past its 270m deadline (LANE_REAP_DEADLINE_SECS=16200, default) by 4m"
# reaped <key> <stamp> <age-seconds> [REAPED 0|1] [COMMENTED 0|1] — a box build record.
REC=""
reaped() {
  REC="$H/builds/tproj-$1-$2"
  scratch_rm "$REC"; mkdir -p "$REC"
  printf '%s\n' "$VERDICT" > "$REC/RESULT"
  jq -nc --arg k "$1" '{project:"tproj",ticket_id:"t",key:$k}' > "$REC/job.json"
  [ "${4:-1}" = 1 ] && : > "$REC/REAPED"
  [ "${5:-1}" = 1 ] && : > "$REC/COMMENTED"
  touch -d "@$(( NOW - $3 ))" "$REC/RESULT"
}

# ═══════════════════════════════════════════════════════════════════════════
# A. The classifier, extracted and CALLED.
# ═══════════════════════════════════════════════════════════════════════════
# BH-5241: the corpus is the driver plus bin/lib/br/*.sh (tests/lib/br-corpus.sh),
# because the ladder functions moved out of the driver into bin/lib/br/ladder.sh.
# shellcheck source=tests/lib/br-corpus.sh
. "$DIR/tests/lib/br-corpus.sh" || exit 1
br_corpus "$H" "$T/br-corpus.sh" || exit 1
: > "$T/cls.sh"
for fn in br_action br_reason_of br_ladder_class br_ladder_rung br_skips_mechanical br_rebuild_outcome; do
  awk -v f="^${fn}[(][)]" '$0 ~ f {p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$T/cls.sh"
done
cls()   { bash -c '. "$0"; br_reason_of "$1"' "$T/cls.sh" "$1"; }
act()   { bash -c '. "$0"; br_action "$1"' "$T/cls.sh" "$1"; }
klass() { bash -c '. "$0"; br_ladder_class "$1"' "$T/cls.sh" "$1"; }
outc()  { bash -c '. "$0"; br_rebuild_outcome "$1"' "$T/cls.sh" "$1"; }
[ "$(cls 'abandoned-timeout: past its deadline')" = abandoned-timeout ] && ok \
  || bad "A1 abandoned-timeout must normalize on its prefix, got '$(cls 'abandoned-timeout: past its deadline')'"
[ "$(act abandoned-timeout)" = rebuild-fresh ] && ok \
  || bad "A2 abandoned-timeout must answer rebuild-fresh (the capped ladder), got '$(act abandoned-timeout)'"
[ -z "$(klass abandoned-timeout)" ] && ok \
  || bad "A3 a reaped run has no branch to fix: no ladder class, got '$(klass abandoned-timeout)'"
[ "$(outc "$VERDICT")" = rebuild-build-dead ] && ok \
  || bad "A4 a rebuild that is itself reaped must spend the next rebuild (rebuild-build-dead), got '$(outc "$VERDICT")'"
# the same word in the ladder module (the lane's split, bin/lib/br/ladder.sh)
[ "$(bash -c '. "$0"; br_action abandoned-timeout' "$DIR/bin/lib/br/ladder.sh")" = rebuild-fresh ] && ok \
  || bad "A5 bin/lib/br/ladder.sh must carry the same br_action answer"

# ═══════════════════════════════════════════════════════════════════════════
# B1/B2. br_from_builds offers the record — and its negatives.
# ═══════════════════════════════════════════════════════════════════════════
awk '/^br_from_builds\(\) \{/{p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" > "$T/src.sh"
awk '/^br_rkey\(\) \{/{p=1} p{print} p&&/^}$/{exit}' "$T/br-corpus.sh" >> "$T/src.sh"
builds() { H="$H" ST="$H/state/blocked-resolver" ONLY=tproj \
           bash -c '. "$0"; br_from_builds' "$T/src.sh" 2>/dev/null; }

reaped TK-1885 202609240000 600 1 1
GOT=$(builds | sort -u)
[ "$GOT" = "$(printf 'build\ttproj\ttproj-TK-1885\tabandoned-timeout\t-\t%s\tTS-1885\t-' "$REC")" ] && ok \
  || bad "B1 a REAPED, COMMENTED record ten minutes old must be offered at once as abandoned-timeout, got '$GOT'"
reaped TK-1885 202609240000 7200 1 0
[ -n "$(builds | sort -u)" ] && ok \
  || bad "B1 a REAPED record the sweep never closed out must still be offered after the 90-minute floor"
reaped TK-1885 202609240000 600 1 0
[ -z "$(builds | sort -u)" ] && ok \
  || bad "B2 a REAPED record the sweep has not closed out yet is the sweep's first (got '$(builds)')"
reaped TK-1885 202609240000 7200 0 1
[ -z "$(builds | sort -u)" ] && ok \
  || bad "B2 a verdict with NO REAPED is a kill that has not landed and must never be offered (got '$(builds)')"
reaped TK-1885 202609240000 7200 1 1; : > "$REC/.blocked-resolver-superseded"
[ -z "$(builds | sort -u)" ] && ok || bad "B2 a superseded record must not be offered again"

# ═══════════════════════════════════════════════════════════════════════════
# B3/B4. End to end, through the real script.
# ═══════════════════════════════════════════════════════════════════════════
scratch_rm "$H/builds"; mkdir -p "$H/builds"
reaped TK-1885 202609240000 600 1 1
: > "$T/queue.txt"; : > "$T/closed.txt"; : > "$T/lane-alert.txt"
RUN
[ "$(grep -c '^tproj TK-1885 ' "$T/queue.txt")" = 1 ] && ok \
  || bad "B3 exactly one relaunch must be enqueued for TK-1885 (got: $(cat "$T/queue.txt"))"
[ -f "$REC/.blocked-resolver-superseded" ] && ok || bad "B3 the reaped record must be marked superseded"
[ "$(STATEJSON tproj-TK-1885 | jq -r .rebuilds)" = 1 ] && ok \
  || bad "B3 the relaunch must be counted on the ladder, got rebuilds='$(STATEJSON tproj-TK-1885 | jq -r .rebuilds)'"
grep -q 'abandoned-timeout' "$H/logs/blocked-resolver.log" && ok \
  || bad "B3 the lane log must name the reason it acted on"
[ -s "$T/closed.txt" ] && bad "B3 there is no PR to close (got: $(cat "$T/closed.txt"))" || ok
: > "$T/queue.txt"
RUN
grep -q '^tproj TK-1885 ' "$T/queue.txt" \
  && bad "B4 one reap buys ONE relaunch (got: $(cat "$T/queue.txt"))" || ok

# ═══════════════════════════════════════════════════════════════════════════
# C1. The relaunch is itself reaped: that spends the NEXT rebuild, once REAPED.
# ═══════════════════════════════════════════════════════════════════════════
reaped TK-1885 202609241000 0 0 0
touch "$REC/RESULT"   # it ended AFTER the relaunch was bought, not at suite start
: > "$T/queue.txt"
RUN
grep -q '^tproj TK-1885 ' "$T/queue.txt" \
  && bad "C1 a reaped relaunch whose kill has not landed (no REAPED) must not be relaunched (got: $(cat "$T/queue.txt"))" || ok
[ "$(STATEJSON tproj-TK-1885 | jq -r .rebuilds)" = 1 ] && ok \
  || bad "C1 no rung may be spent before REAPED, got rebuilds='$(STATEJSON tproj-TK-1885 | jq -r .rebuilds)'"
: > "$REC/REAPED"
RUN
[ "$(grep -c '^tproj TK-1885 ' "$T/queue.txt")" = 1 ] && ok \
  || bad "C1 a reaped relaunch must spend the next rebuild once REAPED (got: $(cat "$T/queue.txt"))"
[ "$(STATEJSON tproj-TK-1885 | jq -r .rebuilds)" = 2 ] && ok \
  || bad "C1 the second relaunch must be counted, got rebuilds='$(STATEJSON tproj-TK-1885 | jq -r .rebuilds)'"

# ═══════════════════════════════════════════════════════════════════════════
# B5. The cap: past BR_MAX_REBUILDS the ladder ends ABANDONED, it does not ask.
# ═══════════════════════════════════════════════════════════════════════════
scratch_rm "$H/state/blocked-resolver"; scratch_rm "$H/builds"; mkdir -p "$H/builds"
reaped TK-1887 202609240000 600 1 1
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc --arg k tproj-TK-1887 '{key:$k,rebuilds:3,mechanicals:0,fixrounds:0,attempts:[]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-1887.json"
: > "$T/queue.txt"; : > "$T/lane-alert.txt"
RUN
grep -q '^tproj TK-1887 ' "$T/queue.txt" \
  && bad "B5 past the cap there is no fourth relaunch (got: $(cat "$T/queue.txt"))" || ok
[ "$(grep -c 'ABANDONED tproj/tproj-TK-1887 (abandoned-timeout)' "$H/logs/ALERTS.log" 2>/dev/null)" = 1 ] && ok \
  || bad "B5 an exhausted ladder must page ABANDONED exactly once (got: $(cat "$H/logs/ALERTS.log" 2>/dev/null))"

echo "blocked-resolver.bh-1770: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
