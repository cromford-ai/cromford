#!/bin/bash
# tests/br-replay-drained.bh-9467-test.sh — BH-9467 (#9369 acceptance): on a
# replay of the 2026-11-09 cromford tick, the candidates drop to the
# open-PR set plus the young rows, and the tick ends `reason=drained`.
#
# THE HUB TICK. `candidates=783 ... rungs=2/100 reason=tick-budget secs=1959`,
# `discovery_src=rebuilds:416,conductor:34,builds:403,reviews:52` (seconds).
# The hub's builds/ cannot be read from a build box, so the fixture is
# synthetic and uses those numbers as row counts (plan ASSUMPTIONS):
#   403 build dirs: 380 with a 20-day RESULT and no open PR, 13 young (2 d),
#                   10 old ones whose ticket has an open PR (ticket/ts-<k>-r2)
#   416 rebuild records (rebuild-enqueue-failed): 400 of 20 days, 16 of 1 day
#   34 conductor rows: 20 open PRs, 14 closed or merged on GitHub
# The review-verdict source has no rows here (no review comment is seeded).
#
#   P1  tick 1 (rung cap 0, so only the pre-pass acts): candidates=853,
#       retired=794 (780 aged out + 14 closed), one event line each
#   P2  tick 2: candidates=59 (the 20 open PRs, 10 old rows with an open PR,
#       13 young dirs, 16 young records), retired=0, reason=drained, no
#       aged-out line, no ALERTS line about a retire or a saturation
#   P3  tick 3: the discovery cache skips the retired dirs and still counts
#       them in retired_skipped
#
# WHAT IS DRIVEN. The real bin/blocked-resolver.sh, end to end, against a
# scratch $HARNESS (the rig of tests/br-age-out.bh-9467-test.sh). No vendor is
# called (BH-7563): gh is a local stub, GH_TOKEN is empty.
# Run from anywhere: tests/br-replay-drained.bh-9467-test.sh (exit 0 = pass)
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

# THE gh STUB. The closed pull list is $T/closed-1.json (one page), the open
# list is $T/openprs (tests/lib/gh-rest-stub.sh), and every call is logged.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X GET"*"pulls?state=closed"*)
    GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; _ghs_send 200 "\$(cat "$T/closed-1.json" 2>/dev/null || echo '[]')"; exit 0 ;;
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
# CPR <num> <merged|closed> — one closed-list item, closed an hour ago.
CPR() {
  local m=null; [ "$2" = merged ] && m="\"$(ISO $((NOW - 3600)))\""
  jq -nc --argjson n "$1" --arg c "$(ISO $((NOW - 3600)))" --argjson m "$m" \
    '{number:$n, html_url:("https://github.com/o/p1/pull/"+($n|tostring)), state:"closed",
      merged_at:$m, closed_at:$c, updated_at:$c}'
}
DIRS() { # DIRS <from> <to> <age secs> — only the RESULTs this call writes are aged
  local n d
  touch "$T/mark"
  for n in $(seq "$1" "$2"); do
    d="$H/builds/p1-TK-$n-202610010000"; mkdir -p "$d"; printf 'BUILD_DEAD no heartbeat\n' > "$d/RESULT"
  done
  find "$H/builds" -mindepth 2 -maxdepth 2 -name RESULT -newer "$T/mark" -exec touch -d "@$((NOW - $3))" {} +
}
RRECS() { # RRECS <from> <to> <age secs> — rebuild-enqueue-failed records
  local n s; mkdir -p "$ST/p1"; s=$(STAMPAT $((NOW - $3)))
  for n in $(seq "$1" "$2"); do
    printf '{"project":"p1","rkey":"p1-TK-%s","outcome":"","attempts":[{"at":"%s","action":"rebuild-fresh-failed","reason":"x","detail":"rc 1"}],"updated":"%s","parked_url":"-","parked_rec":"-"}\n' \
      "$n" "$s" "$s" > "$ST/p1/p1-TK-$n.json"
  done; }

CLEAN
DIRS 1 380 $((20 * DAY))
DIRS 381 393 $((2 * DAY))
DIRS 394 403 $((20 * DAY))
RRECS 1001 1400 $((20 * DAY))
RRECS 1401 1416 "$DAY"
OPEN=""
for n in $(seq 500 509); do OPEN="$OPEN$(OPR "$n" "ticket/ts-$n")"$'\n'; done
for n in $(seq 394 403); do OPEN="$OPEN$(OPR "$((n + 1000))" "ticket/ts-$n-r2")"$'\n'; done
printf '%s' "$OPEN" | jq -s . > "$T/openprs"
for n in $(seq 500 509) $(seq 1394 1403); do
  printf 'o/p1#%s\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\tconflict-unresolvable: x\t%s/%s\n' "$n" "$((NOW - 7200))" "$U" "$n" >> "$ROWS"
done
CL=""
for n in $(seq 520 533); do
  printf 'o/p1#%s\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\tconflict-unresolvable: x\t%s/%s\n' "$n" "$((NOW - 7200))" "$U" "$n" >> "$ROWS"
  w=closed; [ $((n % 2)) = 0 ] && w=merged
  CL="$CL$(CPR "$n" "$w")"$'\n'
done
printf '%s' "$CL" | jq -s . > "$T/closed-1.json"
[ "$(find "$H/builds" -mindepth 2 -maxdepth 2 -name RESULT -mmin +$((14 * 1440)) | wc -l)" = 390 ] && ok || bad "setup: 390 RESULTs older than 14 days"

# P1. Tick 1, rung cap 0: only the pre-pass acts.
BRENV=(BR_PER_TICK=500 BR_PER_TICK_P1=0 BR_REBUILDS_PER_TICK=100)
RUN p1
[ "$(LFIELD candidates)" = 853 ] && ok || bad "P1: tick 1 discovers 853 rows (tick: $(LASTTICK))"
[ "$(LFIELD retired)" = 794 ] && ok || bad "P1: tick 1 retires 794 = 780 aged + 14 closed (tick: $(LASTTICK))"
[ "$(NLINES 'EVENT resolver_retired .*aged out')" = 780 ] && ok || bad "P1: one aged-out line per aged row ($(NLINES 'EVENT resolver_retired .*aged out'))"
[ "$(NLINES 'EVENT resolver_retired .*PR is \(merged\|closed\)')" = 14 ] && ok || bad "P1: one closed line per closed PR ($(NLINES 'EVENT resolver_retired .*PR is'))"

# P2. Tick 2, the hub's budget: the open-PR set plus the young rows, drained.
: > "$LOGF"; rm -f "$H/logs/ALERTS.log"; : > "$T/alerts.txt"
BRENV=(BR_PER_TICK=100 BR_REBUILDS_PER_TICK=100)
RUN p1
[ "$(LFIELD candidates)" = 59 ] && ok || bad "P2: tick 2 candidates are the 59 live rows (tick: $(LASTTICK))"
[ "$(LFIELD retired)" = 0 ] && ok || bad "P2: tick 2 retires nothing (tick: $(LASTTICK))"
[ "$(LFIELD reason)" = drained ] && ok || bad "P2: THE BUG: tick 2 ends reason=drained (tick: $(LASTTICK))"
[ "$(NLINES 'EVENT resolver_retired')" = 0 ] && ok || bad "P2: no event line on tick 2"
[ "$(PFIELD retired_skipped)" = 394 ] && ok || bad "P2: retired_skipped=394, 380 dirs + 14 closed PRs (prof: $(LASTPROF))"
AL=$(cat "$H/logs/ALERTS.log" "$T/alerts.txt" 2>/dev/null)
grep -qiE 'aged|retire|SATURATED|ZERO_DISPATCH' <<<"$AL" && bad "P2: no ALERTS line about a retire or a saturation ($AL)" || ok

# P3. Tick 3: the retired dirs are cached skips and still counted.
: > "$LOGF"
BRENV=(BR_PER_TICK=100 BR_PER_TICK_P1=0)
RUN p1
grep -qE 'discovery cache builds: 403 path\(s\), (3[89][0-9]|40[0-3]) unchanged and skipped' "$LOGF" && ok \
  || bad "P3: tick 3 skips the unchanged dirs ($(grep 'discovery cache builds' "$LOGF"))"
[ "$(PFIELD retired_skipped)" = 394 ] && ok || bad "P3: a cached retired dir still counts in retired_skipped (prof: $(LASTPROF))"

echo "br-replay-drained.bh-9467: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
