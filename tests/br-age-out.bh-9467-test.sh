#!/bin/bash
# tests/br-age-out.bh-9467-test.sh — BH-9467 (#9369 fix 2): a build or rebuild
# row whose ticket has no open PR, and whose RESULT and record are both older
# than BR_RECORD_MAX_AGE_DAYS (default 14), is aged out in the pre-pass and is
# not discovered again.
#
# THE BUG (hub, 2026-11-09). cromford found 783 candidates a tick and ran
# 2 rungs: every build and rebuild row with no open PR stayed a candidate for
# ever, because br_prepass dropped a row only on a closed PR or a finished
# record.
#
#   A1  REVIEW_BLOCKED build, RESULT 20 d, no record, no open PR: aged
#   A2  BUILD_DEAD build, RESULT 15 d, record 15 d: aged
#   A3  rebuild-enqueue-failed, no dir, record 20 d: aged (aged-out attempt)
#   A4  rebuild-decompose-failed, result dir 30 d, record 30 d: aged
#   A5  RESULT 13 d: kept        A6  RESULT 20 d, record 3 d: kept
#   A7  an open PR on ticket/ts-<k>-r2: kept
#   A8  the row url is an open PR: kept
#   A9  the open list does not read: nothing aged, one line
#   A10 HELD record: kept        A11 DATA_LANE record: kept
#   A12 a ledger-only build row (no dir): kept (function case)
#   A13 a record whose .updated does not read: kept
#   A14 a conductor row: kept
#   A15 BR_RECORD_MAX_AGE_DAYS=0: nothing aged; a non-number: one line, 14
#   A16 a child-key head ticket/ts-<k>.1: kept
#   A17 the key TK-46 with an open ticket/TK-467: aged (near miss)
#   A-RT tick 2: retired_skipped counts the aged build dirs, no rebuild row
#        comes back, no new event line
#   A-rev a new rebuild-fresh-failed attempt brings the record back
#   OBS observe mode says WOULD and writes nothing
#   MUT the driver with the call-site line removed ages nothing (D1)
#
# WHAT IS DRIVEN. The real bin/blocked-resolver.sh, end to end, against a
# scratch $HARNESS (the rig of tests/br-retire-closed.bh-9369-test.sh). No
# vendor is called (BH-7563): gh is a local stub that answers the open list
# from fixture JSON, GH_TOKEN is empty.
# Run from anywhere: tests/br-age-out.bh-9467-test.sh (exit 0 = pass)
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
STAMPAT() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }
DAY=86400

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
mkdir -p "$H/bin/blocked-resolver.d"
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" 2>/dev/null || true
# The fragment under test, named by its rooted path so the orphan check sees it.
FRAG="$DIR/bin/blocked-resolver.d/bh-9467-record-age-out.sh"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
for L in bin/lib/gh-pr-list.sh bin/lib/merge-conductor-lib.sh bin/lib/rebuild-ledger.sh \
         bin/lib/hold.sh bin/lib/gh-rest.sh bin/lib/br/opt/profile.sh $(cd "$DIR" && printf "%s " bin/lib/mc/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
chmod +x "$H/bin/"*.sh
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$H/fleet.conf"
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

# THE gh STUB. The closed pull list answers [] (no PR here is closed), the open
# list is $T/openprs (tests/lib/gh-rest-stub.sh), and every call is logged.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X GET"*"pulls?state=closed"*)
    GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; _ghs_send 200 '[]'; exit 0 ;;
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
LOGF="$H/logs/blocked-resolver.log"
U="https://github.com/o/p1/pull"
BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
LOG() { cat "$LOGF" 2>/dev/null; }
LASTTICK() { grep 'tick: candidates=' "$LOGF" | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
LFIELD() { LASTTICK | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
LASTPROF() { grep ' prof: ' "$LOGF" | tail -1 | sed -E 's/^[0-9-]+ [0-9:]+Z //'; }
PFIELD() { LASTPROF | sed -nE "s/.*(^| )$1=([^ ]*).*/\2/p"; }
NLINES() { grep -c -- "$1" "$LOGF" 2>/dev/null; }
AGED() { grep -c -- "EVENT resolver_retired p1/p1-TK-$1 .*aged out" "$LOGF" 2>/dev/null; }
# BUILD <n> <RESULT line> <RESULT age secs> — a build dir p1-TK-<n>-<stamp>.
BUILD() { local d="$H/builds/p1-TK-$1-202610010000"; mkdir -p "$d"; printf '%s\n' "$2" > "$d/RESULT"
          touch -d "@$((NOW - $3))" "$d/RESULT"; }
BDIR() { printf '%s' "$H/builds/p1-TK-$1-202610010000"; }
# REC <n> <json fields> — the ticket record p1-TK-<n>.json, one line.
REC() { mkdir -p "$ST/p1"; jq -c -n --arg k "p1-TK-$1" "{project:\"p1\",rkey:\$k,outcome:\"\",attempts:[]} + ($2)" > "$ST/p1/p1-TK-$1.json"; }
# OPR <num> <head ref> — one open-list item (an author harness_pr_list keeps).
OPR() {
  jq -nc --argjson n "$1" --arg r "$2" --arg u "$(ISO $((NOW - 600)))" \
    '{number:$n, html_url:("https://github.com/o/p1/pull/"+($n|tostring)), title:"t", body:"",
      head:{sha:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", ref:$r}, base:{ref:"main"},
      draft:false, user:{login:"operator", type:"User"}, created_at:$u, updated_at:$u,
      merged_at:null, closed_at:null, labels:[], state:"open"}'
}
CLEAN() { scratch_rm "$ST" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff" 2>/dev/null
          scratch_rm "$H/state/merge-conductor/handoff-released" 2>/dev/null
          scratch_rm "$H/builds" 2>/dev/null; mkdir -p "$H/builds"
          rm -f "$H/flags/blocked-resolver-observe" "$T/openprs" "$T/st-prlist" "$H/logs/ALERTS.log"
          : > "$T/gh.txt"; : > "$T/alerts.txt"; : > "$T/agent.txt"
          : > "$T/closed.txt"; : > "$T/queue.txt"; : > "$LOGF"; : > "$ROWS"
          BRENV=(BR_PER_TICK=10 BR_PER_TICK_P1=1); }
[ -f "$FRAG" ] || bad "0: bin/blocked-resolver.d/bh-9467-record-age-out.sh must exist"

# THE FIXTURE of A1-A17 (A9, A12, A15 are their own sections).
SEED() {
  BUILD 101 "REVIEW_BLOCKED gate refused" $((20 * DAY))                       # A1
  BUILD 102 "BUILD_DEAD no heartbeat" $((15 * DAY))                           # A2
  REC 102 "{updated:\"$(STAMPAT $((NOW - 15 * DAY)))\"}"
  REC 103 "{updated:\"$(STAMPAT $((NOW - 20 * DAY)))\", parked_url:\"-\", parked_rec:\"-\",
            attempts:[{at:\"$(STAMPAT $((NOW - 20 * DAY)))\",action:\"rebuild-fresh-failed\",reason:\"x\",detail:\"rc 1\"}]}"   # A3
  mkdir -p "$H/builds/p1-TK-104-202610100000"                                 # A4
  printf 'DECOMPOSE_FAILED no children\n' > "$H/builds/p1-TK-104-202610100000/RESULT"
  touch -d "@$((NOW - 30 * DAY))" "$H/builds/p1-TK-104-202610100000/RESULT"
  REC 104 "{updated:\"$(STAMPAT $((NOW - 30 * DAY)))\", parked_url:\"-\", rebuild_result:\"DECOMPOSE_FAILED no children\", wait:\"-\", wait_job:\"-\",
            attempts:[{at:\"$(STAMPAT $((NOW - 31 * DAY)))\",action:\"rebuild-fresh\",reason:\"x\",detail:\"enqueued\"}]}"
  BUILD 105 "BUILD_DEAD no heartbeat" $((13 * DAY))                           # A5
  BUILD 106 "BUILD_DEAD no heartbeat" $((20 * DAY))                           # A6
  REC 106 "{updated:\"$(STAMPAT $((NOW - 3 * DAY)))\"}"
  BUILD 107 "BUILD_DEAD no heartbeat" $((20 * DAY))                           # A7
  REC 108 "{updated:\"$(STAMPAT $((NOW - 20 * DAY)))\", parked_url:\"$U/808\", parked_rec:\"-\",
            attempts:[{at:\"$(STAMPAT $((NOW - 20 * DAY)))\",action:\"rebuild-fresh-failed\",reason:\"x\",detail:\"rc 1\"}]}"   # A8
  BUILD 110 "BUILD_DEAD no heartbeat" $((20 * DAY))                           # A10
  REC 110 "{outcome:\"HELD\", updated:\"$(STAMPAT $((NOW - 20 * DAY)))\"}"
  BUILD 111 "BUILD_DEAD no heartbeat" $((20 * DAY))                           # A11
  REC 111 "{outcome:\"DATA_LANE\", updated:\"$(STAMPAT $((NOW - 20 * DAY)))\"}"
  BUILD 113 "BUILD_DEAD no heartbeat" $((20 * DAY))                           # A13
  REC 113 "{updated:\"not a stamp\"}"
  printf 'o/p1#901\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\tconflict-unresolvable: x\t%s\n' "$((NOW - 20 * DAY))" "$U/901" >> "$ROWS"   # A14
  BUILD 116 "BUILD_DEAD no heartbeat" $((20 * DAY))                           # A16
  BUILD 46 "BUILD_DEAD no heartbeat" $((20 * DAY))                            # A17
  { OPR 807 ticket/TK-107-r2; OPR 808 feature-x; OPR 816 ticket/TK-116.1; OPR 846 ticket/TK-467; } | jq -s . > "$T/openprs"
}

# ============================================================================
# A1-A17 (driver), tick 1.
# ============================================================================
CLEAN; SEED
RUN p1
for N in 101 102 103 104 46; do
  [ "$(AGED "$N")" = 1 ] && ok || bad "A: TK-$N must be aged out once on tick 1 (log: $(LOG | grep -E "TK-$N[ /-]" | head -3))"
done
for N in 105 106 107 108 110 111 113 116; do
  [ "$(AGED "$N")" = 0 ] && ok || bad "A: TK-$N must be kept (log: $(LOG | grep -E "TK-$N[ /]" | head -3))"
done
[ "$(NLINES 'EVENT resolver_retired p1/o-p1-901')" = 0 ] && ok || bad "A14: a conductor row is never aged"
[ "$(LFIELD retired)" = 5 ] && ok || bad "A: THE BUG: tick 1 must retire exactly the 5 aged rows (tick: $(LASTTICK))"
C1=$(LFIELD candidates)
grep -q '^aged-out	' "$(BDIR 101)/.blocked-resolver-retired" 2>/dev/null && ok \
  || bad "A1: the build dir carries the aged-out marker ($(cat "$(BDIR 101)/.blocked-resolver-retired" 2>/dev/null))"
[ -e "$(BDIR 105)/.blocked-resolver-retired" ] && bad "A5: a kept dir has no marker" || ok
[ "$(jq -r '.attempts[-1].action' "$ST/p1/p1-TK-103.json")" = aged-out ] && ok \
  || bad "A3: the rebuild record ends with an aged-out attempt ($(cat "$ST/p1/p1-TK-103.json"))"
[ "$(jq -r '.attempts[-1].action' "$ST/p1/p1-TK-104.json")" = aged-out ] && ok || bad "A4: the rebuild record ends with an aged-out attempt"
[ "$(jq -r '.outcome' "$ST/p1/p1-TK-103.json")" = "" ] && [ "$(jq -r '.rebuilds // 0' "$ST/p1/p1-TK-103.json")" = 0 ] && ok \
  || bad "A3: the age-out sets no outcome and bumps no counter"
[ "$(jq -r '.attempts[-1].action' "$ST/p1/p1-TK-108.json")" = rebuild-fresh-failed ] && ok || bad "A8: an open url's record is not written"
grep -q 'BR_RECORD_MAX_AGE_DAYS=14' <<<"$(LOG | grep 'EVENT resolver_retired p1/p1-TK-101')" && ok \
  || bad "A1: the event line names the knob and its value"
[ "$(cat "$H/logs/ALERTS.log" "$T/alerts.txt" 2>/dev/null | grep -ci 'aged')" = 0 ] && ok || bad "A: the age-out writes no alert line"

# A-RT: tick 2. The aged build dirs are skipped in discovery (retired_skipped),
# the aged rebuild records emit no row, no new event line.
: > "$LOGF"
RUN p1
[ "$(NLINES 'EVENT resolver_retired.*aged out')" = 0 ] && ok || bad "A-RT: tick 2 says no new aged-out line (log: $(LOG | grep 'aged out'))"
[ "$(PFIELD retired_skipped)" = 3 ] && ok || bad "A-RT: tick 2 retired_skipped=3, the 3 aged build dirs (prof: $(LASTPROF))"
C2=$(LFIELD candidates)
[ "$C2" = $((C1 - 5)) ] && ok || bad "A-RT: tick 2 discovers 5 fewer candidates ($C1 -> $C2)"
[ "$(LFIELD retired)" = 0 ] && ok || bad "A-RT: tick 2 retires nothing (tick: $(LASTTICK))"

# A-rev: a new rebuild-fresh-failed attempt on TK-103 brings its row back, and
# it is not aged (its record is young now).
jq -c --arg t "$(STAMPAT "$NOW")" '.attempts += [{at:$t,action:"rebuild-fresh-failed",reason:"x",detail:"rc 1"}] | .updated = $t' \
  "$ST/p1/p1-TK-103.json" > "$T/r.json" && mv "$T/r.json" "$ST/p1/p1-TK-103.json"
: > "$LOGF"
RUN p1
[ "$(LFIELD candidates)" = $((C2 + 1)) ] && ok || bad "A-rev: the record comes back as a candidate ($C2 -> $(LFIELD candidates))"
[ "$(AGED 103)" = 0 ] && ok || bad "A-rev: the young record is not aged again"

# ============================================================================
# A9. The open list does not read: nothing is aged, one line says so.
# ============================================================================
CLEAN; SEED
echo 500 > "$T/st-prlist"
RUN p1
[ "$(NLINES 'EVENT resolver_retired.*aged out')" = 0 ] && ok || bad "A9: nothing is aged while the open list does not read (log: $(LOG | grep 'aged out' | head -2))"
[ "$(NLINES 'open-PR list for o/p1 unreadable — no build or rebuild row is aged out this tick')" = 1 ] && ok \
  || bad "A9: one line names the unreadable list (log: $(LOG | grep -i 'open-PR'))"
[ -e "$(BDIR 101)/.blocked-resolver-retired" ] && bad "A9: no marker is written" || ok

# ============================================================================
# A15. The knob. 0 ages nothing; a non-number is one line and the fallback 14.
# ============================================================================
CLEAN; SEED
BRENV+=(BR_RECORD_MAX_AGE_DAYS=0)
RUN p1
[ "$(NLINES 'EVENT resolver_retired.*aged out')" = 0 ] && [ "$(LFIELD retired)" = 0 ] && ok || bad "A15: BR_RECORD_MAX_AGE_DAYS=0 ages nothing (tick: $(LASTTICK))"
CLEAN; SEED
BRENV+=(BR_RECORD_MAX_AGE_DAYS=abc)
RUN p1
[ "$(NLINES "BR_RECORD_MAX_AGE_DAYS is 'abc', not a number — the fallback 14 is used")" = 1 ] && ok \
  || bad "A15: a non-number is said once (log: $(LOG | grep -i MAX_AGE))"
[ "$(AGED 101)" = 1 ] && ok || bad "A15: with the fallback, TK-101 is aged"
CLEAN; SEED
BRENV+=(BR_RECORD_MAX_AGE_DAYS=25)
RUN p1
[ "$(AGED 104)" = 1 ] && [ "$(AGED 101)" = 0 ] && ok || bad "A15: at 25 days only the 30-day TK-104 is aged"

# ============================================================================
# OBS. Observe mode says WOULD and writes no marker, attempt or event.
# ============================================================================
CLEAN; SEED
touch "$H/flags/blocked-resolver-observe"
RUN p1
[ "$(NLINES 'p1/p1-TK-101 \[rescue-giving-up\]: WOULD age out — no open PR')" = 1 ] && ok \
  || bad "OBS: observe mode says WOULD (log: $(LOG | grep -E 'WOULD|TK-101' | head -3))"
[ "$(NLINES 'EVENT resolver_retired')" = 0 ] && ok || bad "OBS: no event line"
[ -e "$(BDIR 101)/.blocked-resolver-retired" ] && bad "OBS: no marker" || ok
[ "$(jq -r '.attempts[-1].action' "$ST/p1/p1-TK-103.json")" = rebuild-fresh-failed ] && ok || bad "OBS: no attempt"
rm -f "$H/flags/blocked-resolver-observe"

# ============================================================================
# MUT (D1). With the br_prepass call-site line removed, A1 is not aged.
# ============================================================================
CLEAN; SEED
cp "$H/bin/blocked-resolver.sh" "$T/driver.keep"
grep -v 'bra_prepass_row && continue' "$T/driver.keep" > "$H/bin/blocked-resolver.sh"
RUN p1
[ "$(AGED 101)" = 0 ] && [ "$(LFIELD retired)" = 0 ] && ok || bad "MUT: without the call site nothing is aged (the test pins the call site)"
cp "$T/driver.keep" "$H/bin/blocked-resolver.sh"

# ============================================================================
# Function cases: bra_aged (A12 and the edges) and bra_has_open (A16, A17).
# ============================================================================
(
  say() { printf '%s\n' "$*" >> "$T/fsay.txt"; }
  # shellcheck source=bin/blocked-resolver.d/bh-9467-record-age-out.sh
  . "$FRAG" || exit 1
  declare -A _BRA_OLD=(["/b/old"]=1)
  r=""
  bra_aged build - - /b/old 0 14 && r="${r}a"          # a build with no record, old RESULT
  bra_aged build - - - 0 14 || r="${r}b"               # A12: a ledger-only build row
  bra_aged rebuild - 20 - 1 14 && r="${r}c"            # a rebuild with no dir, old record
  bra_aged rebuild - - - 1 14 || r="${r}d"             # A13: the record age does not read
  bra_aged build - 13 /b/old 1 14 || r="${r}e"         # a young record
  bra_aged build - 15 /b/young 1 14 || r="${r}f"       # a young RESULT
  bra_aged build HELD 30 /b/old 1 14 || r="${r}g"
  bra_aged rebuild DATA_LANE 30 - 1 14 || r="${r}h"
  bra_aged conductor - 30 /b/old 1 14 || r="${r}i"     # A14
  bra_aged build - 30 /b/old 1 0 || r="${r}j"          # A15: knob 0
  bra_aged rebuild - - - 0 14 || r="${r}k"             # a rebuild row always has a record
  bra_aged build - 14 /b/old 1 14 && r="${r}l"         # exactly the knob is old
  [ "$r" = abcdefghijkl ] || { echo "bra_aged: $r"; exit 1; }
  declare -A _BRA_OPEN_OK=([p]=1) _BRA_OURL=(["$U/9"]=1) _BRA_OHEAD=([p]=$'ticket/bh-9467\nticket/bh-9369.1\nticket/bh-12-r2\nfix/TK-7\n')
  _BRA_OPEN_INIT=1
  r=""
  bra_has_open p BH-946 - || r="${r}a"                 # A17: a prefix of a longer key
  bra_has_open p BH-9467 - && r="${r}b"
  bra_has_open p BH-9369 - && r="${r}c"                # A16: a child key keeps
  bra_has_open p BH-12 - && r="${r}d"                  # ticket/bh-12-r2
  bra_has_open p BH-1 - || r="${r}e"
  bra_has_open p TK-7 - && r="${r}f"
  bra_has_open p TK-99 "$U/9" && r="${r}g"             # A8: the url is open
  bra_has_open p - - && r="${r}h"                      # no key: kept
  _BRA_OPEN_OK[p]=0
  bra_has_open p BH-946 - && r="${r}i"                 # A9: unreadable keeps
  [ "$r" = abcdefghi ] || { echo "bra_has_open: $r"; exit 1; }
) && ok || bad "F: the bra_aged and bra_has_open decision tables"

echo "br-age-out.bh-9467: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
