#!/bin/bash
# tests/mc-sat-fresh-handoff.bh-9467-test.sh — BH-9467 T7: while
# bin/blocked-resolver.sh is SATURATED, the conductor's stuck re-kick still
# hands off a park that is YOUNGER than MC_SAT_FRESH_PARK_MIN (default 1440 min),
# so a new red is not muted by 200 old ones.
#
# THE ASK (comment 6776463505 on #9369): "Let it hand off a park that is less
# than 24 h old, so a new red is not muted by old ones." stuck_rekick reads the
# park's since (optional arg 16, from bin/merge-conductor.sh's SINCE).
#
#   S1  saturated: 1 RED_TWICE park 30 min old + 200 parks 3 d old, each through
#       stuck_rekick with arg 16. Only the fresh park's hand-off record is
#       rewritten and its line says `handed to bin/blocked-resolver.sh again`;
#       the 200 keep their record and the `not re-handed off` line.
#   F1  since 23 h ago: handed off.
#   F2  since 25 h ago: not.            F3  no arg 16 (the 12-arg call): not.
#   F4  since non-numeric: not.         F5  since in the future: not.
#   F6  MC_SAT_FRESH_PARK_MIN=0: not.
#   F7  MC_SAT_FRESH_PARK_MIN non-number: one line, the 1440 fallback applies.
#   F8  a BLOCKED_HUMAN park (merge-failed-twice), fresh: handed off.
#   N1  not saturated: today's hand-off line, with and without arg 16.
#   C1  one real bin/merge-conductor.sh tick (D2): two RED_TWICE parks past
#       their TTL while saturated, one with a fresh since and one 3 d old. Arg 16
#       reaches stuck_rekick: the fresh one is handed again, the old one is not.
#
# S/F/N source the conductor's lib from a scratch closure and pin mc_now (the
# conductor's clock) to NOW. C1 is the tests/stuck-pr-timers.bh-7241-test.sh
# rig: the real conductor closure, a stub gh, GH_TOKEN empty, no network.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/mc-sat-fresh-handoff.bh-9467-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq    >/dev/null || { echo "jq missing — skipping";    exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
export GH_TOKEN=""
hx() { printf '%-40s' "$1" | tr ' ' 0; }   # a 40-hex head from a short hex prefix

# ============================================================================
# S / F / N. stuck_rekick, called directly.
# ============================================================================
U="$T/u"
mkdir -p "$U/bin/lib" "$U/logs" "$U/state" "$U/flags" "$U/locks" "$U/builds" "$U/env"
scratch_install_closure bin/merge-conductor.sh "$U" >/dev/null || { echo "FAIL: closure install (unit)"; exit 1; }
: > "$U/env/global.env"
UOUT=$(
  export HARNESS="$U"
  PASS=0; FAIL=0
  # shellcheck source=/dev/null
  . "$U/bin/lib/merge-conductor-lib.sh" || { echo "FAIL: the conductor lib did not load"; exit 1; }
  mc_init
  mc_now() { printf '%s' "$NOW"; }
  ACTIONS=1; MERGES=0
  type stuck_rekick >/dev/null 2>&1 || { echo "FAIL: stuck_rekick is not defined by the conductor lib"; exit 1; }
  SAT="$U/state/blocked-resolver/.saturated"
  mkdir -p "$(dirname "$SAT")"
  SLUG=o/p1; OLD=$(hx 1a)
  RWHY="red-twice: still red on ${OLD:0:8} after its failed jobs were re-run once"
  seed()  { local hf; hf=$(mc_handoff_file "$SLUG#$1"); mkdir -p "$(dirname "$hf")"
            printf '12345\t%s\t%s\t%s\n' "$OLD" "$RWHY" "https://github.com/$SLUG/pull/$1" > "$hf"; }
  first() { cut -f1 "$(mc_handoff_file "$SLUG#$1")" 2>/dev/null; }
  lines() { grep -F "$SLUG#$1 " "$MC_LOG" 2>/dev/null; }
  # rk <num> <state> <why> [since] — the 16-arg call of bin/merge-conductor.sh;
  # with no since it is the 12-arg call of tests/blocked-resolver.bh-1122-test.sh.
  rk() {
    local n="$1" st="$2" why="$3"
    if [ $# -ge 4 ]; then
      stuck_rekick "$SLUG#$n" "$st" "$why" "$SLUG" "$n" "https://github.com/$SLUG/pull/$n" "$OLD" CLEAN MERGEABLE main main red APPROVE "$OLD" "" "$4"
    else
      stuck_rekick "$SLUG#$n" "$st" "$why" "$SLUG" "$n" "https://github.com/$SLUG/pull/$n" "$OLD" CLEAN MERGEABLE main main red
    fi
  }
  AGAIN='handed to bin/blocked-resolver.sh again: '
  STOOD='not re-handed off, its hand-off record stands'
  FRESH() { # FRESH <num> <state-display> <why> <min> <knob>
    printf '%s RED_TWICE %s: still parked past its TTL on %s — bin/blocked-resolver.sh is SATURATED, but this park is %sm old (< MC_SAT_FRESH_PARK_MIN=%s) — handed to bin/blocked-resolver.sh again: %s' \
      "$SLUG#$1" "$3" "${OLD:0:8}" "$4" "$5" "https://github.com/$SLUG/pull/$1"; }

  # S1 — saturated, 1 fresh + 200 old.
  : > "$SAT"
  seed 1; rk 1 RED_TWICE "$RWHY" "$((NOW - 1800))"
  for n in $(seq 100 299); do seed "$n"; rk "$n" RED_TWICE "$RWHY" "$((NOW - 259200))"; done
  [ "$(first 1)" = "$NOW" ] && ok || bad "S1 the fresh park's hand-off record is rewritten (first field '$(first 1)', want $NOW)"
  L1=$(lines 1)
  grep -qF -- "$(FRESH 1 RED_TWICE "$RWHY" 30 1440)" <<<"$L1" && ok \
    || bad "S1 the fresh park's line says handed again with its age and the knob: [$L1]"
  grep -qF "$STOOD" <<<"$L1" && bad "S1 the fresh park has no 'not re-handed off' line: [$L1]" || ok
  KEPT=0; STOODN=0; AGAINN=0
  for n in $(seq 100 299); do
    [ "$(first "$n")" = 12345 ] && KEPT=$((KEPT + 1))
    LN=$(lines "$n")
    grep -qF "$STOOD" <<<"$LN" && STOODN=$((STOODN + 1))
    grep -qF "$AGAIN" <<<"$LN" && AGAINN=$((AGAINN + 1))
  done
  [ "$KEPT" = 200 ] && ok || bad "S1 all 200 old parks keep their hand-off record (kept $KEPT)"
  [ "$STOODN" = 200 ] && ok || bad "S1 all 200 old parks log the 'not re-handed off' line ($STOODN)"
  [ "$AGAINN" = 0 ] && ok || bad "S1 no old park is handed again ($AGAINN)"
  # The old line, byte for byte.
  grep -qxF -- "$(printf '%s RED_TWICE %s: still parked past its TTL on %s — bin/blocked-resolver.sh is SATURATED (see the [blocked-resolver] SATURATED line in logs/ALERTS.log); not re-handed off, its hand-off record stands: %s' "$SLUG#100" "$RWHY" "${OLD:0:8}" "https://github.com/$SLUG/pull/100")" \
    <<<"$(lines 100 | cut -d' ' -f3-)" && ok || bad "S1 the old park's line is today's line byte for byte: [$(lines 100)]"

  # F1-F6 — the decision table.
  fcase() { # fcase <label> <num> <want: again|stood> <since or NOARG> [env...]
    local lab="$1" n="$2" want="$3" s="$4" L; shift 4
    seed "$n"
    if [ "$s" = NOARG ]; then ( [ $# -gt 0 ] && export "$@"; rk "$n" RED_TWICE "$RWHY" )
    else ( [ $# -gt 0 ] && export "$@"; rk "$n" RED_TWICE "$RWHY" "$s" ); fi
    L=$(lines "$n")
    case "$want" in
      again) [ "$(first "$n")" = "$NOW" ] && grep -qF "$AGAIN" <<<"$L" && ! grep -qF "$STOOD" <<<"$L" && ok \
               || bad "$lab: want handed again (first '$(first "$n")'): [$L]" ;;
      stood) [ "$(first "$n")" = 12345 ] && grep -qF "$STOOD" <<<"$L" && ! grep -qF "$AGAIN" <<<"$L" && ok \
               || bad "$lab: want not re-handed off (first '$(first "$n")'): [$L]" ;;
    esac
  }
  fcase "F1 since 23 h ago"   11 again "$((NOW - 82800))"
  grep -qF "this park is 1380m old (< MC_SAT_FRESH_PARK_MIN=1440)" <<<"$(lines 11)" && ok || bad "F1 the age is in minutes: [$(lines 11)]"
  fcase "F2 since 25 h ago"   12 stood "$((NOW - 90000))"
  fcase "F3 no arg 16"        13 stood NOARG
  fcase "F4 since not a number" 14 stood "abc"
  fcase "F4b since empty"     15 stood ""
  fcase "F5 since in the future" 16 stood "$((NOW + 600))"
  fcase "F6 knob 0"           17 stood "$((NOW - 1800))" MC_SAT_FRESH_PARK_MIN=0
  fcase "F6b knob 60, park 90 min" 18 stood "$((NOW - 5400))" MC_SAT_FRESH_PARK_MIN=60
  fcase "F6c knob 120, park 90 min" 19 again "$((NOW - 5400))" MC_SAT_FRESH_PARK_MIN=120
  grep -qF "(< MC_SAT_FRESH_PARK_MIN=120)" <<<"$(lines 19)" && ok || bad "F6c the line names the knob value read: [$(lines 19)]"
  fcase "F6d since exactly now" 20 again "$NOW"
  # F7 — a non-number knob: one line in one process, and the 1440 fallback.
  (
    export MC_SAT_FRESH_PARK_MIN=abc
    seed 21; rk 21 RED_TWICE "$RWHY" "$((NOW - 1800))"
    seed 22; rk 22 RED_TWICE "$RWHY" "$((NOW - 90000))"
  )
  [ "$(grep -c "MC_SAT_FRESH_PARK_MIN='abc'" "$MC_LOG")" = 1 ] && ok \
    || bad "F7 a non-number knob says so once: $(grep -c "MC_SAT_FRESH_PARK_MIN='abc'" "$MC_LOG") line(s): $(grep "MC_SAT_FRESH_PARK_MIN='abc'" "$MC_LOG")"
  [ "$(first 21)" = "$NOW" ] && grep -qF "(< MC_SAT_FRESH_PARK_MIN=1440)" <<<"$(lines 21)" && ok \
    || bad "F7 the fallback 1440 hands off a 30 min park: [$(lines 21)]"
  [ "$(first 22)" = 12345 ] && grep -qF "$STOOD" <<<"$(lines 22)" && ok \
    || bad "F7 the fallback 1440 keeps a 25 h park: [$(lines 22)]"
  # F8 — a BLOCKED_HUMAN park the resolver owns, fresh: handed off.
  seed 23; rk 23 BLOCKED_HUMAN "merge-failed-twice: gh pr merge refused" "$((NOW - 1800))"
  [ "$(first 23)" = "$NOW" ] && grep -qF "#23 BLOCKED_AGENT merge-failed-twice: gh pr merge refused: still parked past its TTL on ${OLD:0:8} — bin/blocked-resolver.sh is SATURATED, but this park is 30m old" <<<"$(lines 23)" && ok \
    || bad "F8 a fresh BLOCKED_HUMAN park is handed again: [$(lines 23)]"

  # N1 — not saturated: today's hand-off, arg 16 or not.
  rm -f "$SAT"
  OFFERED='handed to bin/blocked-resolver.sh again (the release marker is cleared, so the park is offered fresh): '
  seed 31; rk 31 RED_TWICE "$RWHY" "$((NOW - 259200))"
  seed 32; rk 32 RED_TWICE "$RWHY"
  seed 33; rk 33 RED_TWICE "$RWHY" "$((NOW - 1800))"
  for n in 31 32 33; do
    [ "$(first "$n")" = "$NOW" ] && grep -qF "$OFFERED" <<<"$(lines "$n")" && ! grep -qF SATURATED <<<"$(lines "$n")" && ok \
      || bad "N1 #$n not saturated: today's hand-off line: [$(lines "$n")]"
  done
  echo "UNIT $PASS $FAIL"
)
printf '%s\n' "$UOUT" | grep -v '^UNIT '
UP=$(sed -n 's/^UNIT \([0-9]*\) \([0-9]*\)$/\1/p' <<<"$UOUT"); UF=$(sed -n 's/^UNIT \([0-9]*\) \([0-9]*\)$/\2/p' <<<"$UOUT")
if [ -z "$UP" ]; then bad "the unit section did not finish: [$(tail -3 <<<"$UOUT")]"; else PASS=$((PASS + UP)); FAIL=$((FAIL + UF)); fi

# ============================================================================
# C1. One real bin/merge-conductor.sh tick (D2): arg 16 reaches stuck_rekick.
# ============================================================================
C="$T/c"
SLUG=example-org/demo-os
P=demo-os
mkdir -p "$C/bin/lib" "$C/logs" "$C/state" "$C/flags" "$C/locks" "$C/builds" "$C/env" "$C/tmp" "$T/fakebin"
# The flake ledger, stubbed: the failed runs of a head are $T/failed.<head>.
cat > "$C/bin/lib/flaky.sh" <<EOF
flaky_failed_runs() { cat "$T/failed.\$2" 2>/dev/null; }
flaky_run_tests() { echo "test_\$2"; }
flaky_all_known() { cat >/dev/null; return 1; }
EOF
: > "$C/bin/lib/pr-snapshot.sh"
scratch_install_closure bin/merge-conductor.sh "$C" >/dev/null || { echo "FAIL: closure install (conductor)"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$C" >/dev/null || { echo "FAIL: closure install (jobs-client)"; exit 1; }
scratch_rm "$C/bin/lib/gh-limit-logger.sh"
cp "$REPO/bin/fleet-conf.sh" "$C/bin/" || exit 1
cp "$REPO/tests/lib/rest-emit.sh" "$T/fakebin/restpr" && chmod +x "$T/fakebin/restpr" || exit 1
# shellcheck source=tests/lib/gh-list-bridge.sh
. "$REPO/tests/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/verdict-fixture.sh
. "$REPO/tests/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
for s in agent-call beat codegraph-ensure deploy-request pre-arm-guards; do printf '#!/bin/bash\nexit 0\n' > "$C/bin/$s.sh"; chmod +x "$C/bin/$s.sh"; done
printf '#!/bin/bash\necho "[lane-alert] $*" >> "%s/logs/ALERTS.log"\n' "$C" > "$C/bin/lane-alert.sh"; chmod +x "$C/bin/lane-alert.sh"
printf '#!/bin/bash\necho "launch p=$1 only=${BR_ONLY_PR:-}" >> "%s/launch.txt"\n' "$T" > "$C/bin/blocked-resolver.sh"; chmod +x "$C/bin/blocked-resolver.sh"
printf '%s %s - - 2 box-demo\n' "$P" "$SLUG" > "$C/fleet.conf"
: > "$C/env/global.env"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
T="$T"; SLUG="$SLUG"
printf '%s\n' "\$*" >> "\$T/gh-calls.txt"
case "\$*" in
  *"auth token"*) echo tok-fixture ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *"pr list -R \$SLUG --state open"*) cat "\$T/list.json" ;;
  *"pr list"*) echo "[]" ;;
  *"actions/runs?head_sha="*)
    h=\$(printf '%s' "\$*" | sed -n 's/.*head_sha=\([0-9a-f]*\).*/\1/p')
    if [ -s "\$T/runs.\$h" ]; then restpr --runs - < "\$T/runs.\$h"; else restpr --runs; fi ;;
  *"-X GET repos/\$SLUG/commits/"*"/check-runs"*) restpr --raw 500 '{"message":"fixture"}' ;;
  *"-X GET repos/\$SLUG/pulls/"*)
    [ "\${HPL_READ_ROLE:-}" = list-lazy ] && exit 0
    n=\$(printf '%s' "\$*" | sed -n 's|.*/pulls/\([0-9]*\).*|\1|p')
    hd=\$(jq -r --argjson n "\$n" '.[]|select(.number==\$n)|.headRefOid' "\$T/list.json")
    restpr OPEN "\$hd" "ticket/pb-\$n" main "" MERGEABLE CLEAN operator ;;
  *"run rerun"*) printf '%s\n' "\$*" >> "\$T/writes.txt"; exit 0 ;;
  *"api -X PATCH repos/"*) printf '%s\n' "\$*" >> "\$T/writes.txt"; exit 0 ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nprintf '"'"'{"error":"not found"}\\n404\\n'"'"'\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
: > "$T/gh-calls.txt"; : > "$T/writes.txt"; : > "$T/launch.txt"
CK() { printf '%s#%s' "$SLUG" "$1"; }
CU() { printf 'https://github.com/%s/pull/%s' "$SLUG" "$1"; }
COUT=$(
  export HARNESS="$C" FLEET_CONF="$C/fleet.conf" PATH="$T/fakebin:$PATH"
  # shellcheck source=/dev/null
  . "$C/bin/lib/merge-conductor-lib.sh" || { echo "FAIL: C1 the conductor lib did not load"; exit 1; }
  mc_init
  A="$C/state/merge-conductor/attempts.txt"; touch "$A"
  # Two red heads, each re-run once an hour ago (red ladder rung 2 = RED_TWICE),
  # each parked RED_TWICE past the 2 h TTL: #40 since 150 min (fresh), #41 since 3 d.
  for n in 40 41; do
    h=$(hx "c$n")
    d="$C/builds/pool-demo-os-TK-$n-2026111100$n"; mkdir -p "$d"
    echo "PR_CREATED $(CU "$n")" > "$d/RESULT"
    printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$d/review.md"
    echo "$h" > "$d/reviewed-sha"
    echo "completed|failure|7$n|ci" > "$T/runs.$h"
    echo "7$n|.github/workflows/ci.yml|ci|$h" > "$T/failed.$h"
    echo "cirerun $(CK "$n") $h $((NOW - 3600))" >> "$A"
    case "$n" in 40) s=$((NOW - 9000)) ;; *) s=$((NOW - 259200)) ;; esac
    mc_row_put "$(CK "$n")" RED_TWICE "$s" "$h" "$h" - "red-twice: still red on ${h:0:8} after its failed jobs were re-run once" "$(CU "$n")"
    hf=$(mc_handoff_file "$(CK "$n")"); mkdir -p "$(dirname "$hf")"
    printf '12345\t%s\t%s\t%s\n' "$h" "red-twice: still red on ${h:0:8} after its failed jobs were re-run once" "$(CU "$n")" > "$hf"
  done
  printf '[%s,%s]' \
    "$(printf '{"number":40,"url":"%s","headRefOid":"%s","headRefName":"ticket/TK-40","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"}' "$(CU 40)" "$(hx c40)")" \
    "$(printf '{"number":41,"url":"%s","headRefOid":"%s","headRefName":"ticket/TK-41","isDraft":false,"mergeStateStatus":"BLOCKED","mergeable":"MERGEABLE","state":"OPEN","labels":[],"baseRefName":"main"}' "$(CU 41)" "$(hx c41)")" \
    > "$T/list.json"
  touch "$C/flags/merge-conductor-actions"
  mkdir -p "$C/state/blocked-resolver"; : > "$C/state/blocked-resolver/.saturated"
  ( cd "$T" && HARNESS_SECRET=fixture-secret MC_MERGE_SETTLE=0 MC_MERGE_TREE=0 MC_KICK_REOPEN_SLEEP=0 MC_DETACHED_REBASE=0 \
      bash "$C/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) || echo "NOTE: tick rc=$? stderr: $(tail -3 "$T/tick.err")"
  for n in 40 41; do
    printf 'ROW %s %s\n' "$n" "$(awk -F'\t' -v k="$(CK "$n")" '$1==k {print $2" "$3}' "$C/state/merge-conductor/pr-state.tsv")"
    printf 'FIRST %s %s\n' "$n" "$(cut -f1 "$(mc_handoff_file "$(CK "$n")")" 2>/dev/null)"
  done
)
CLOG="$C/logs/merge-conductor.log"
L40=$(grep -F "$(CK 40) " "$CLOG" 2>/dev/null); L41=$(grep -F "$(CK 41) " "$CLOG" 2>/dev/null)
grep -q '^NOTE\|^FAIL' <<<"$COUT" && echo "$COUT" | grep '^NOTE\|^FAIL'
grep -q '^FAIL' <<<"$COUT" && bad "C1 the conductor rig failed to start"
grep -qxF "ROW 40 RED_TWICE $((NOW - 9000))" <<<"$COUT" && ok || bad "C1 #40 stays RED_TWICE with its since (rig check): [$(grep '^ROW 40' <<<"$COUT")] log: [$(tail -3 <<<"$L40")]"
grep -qF "$(CK 40) RED_TWICE red-twice: still red on $(hx c40 | cut -c1-8) after its failed jobs were re-run once: still parked past its TTL on $(hx c40 | cut -c1-8) — bin/blocked-resolver.sh is SATURATED, but this park is 150m old (< MC_SAT_FRESH_PARK_MIN=1440) — handed to bin/blocked-resolver.sh again: $(CU 40)" <<<"$L40" \
  && ok || bad "C1 the tick hands the fresh park again (arg 16 reached stuck_rekick): [$(grep -F 'TTL' <<<"$L40")] all: [$(tail -4 <<<"$L40")]"
grep -qxF "FIRST 40 12345" <<<"$COUT" && bad "C1 the fresh park's hand-off record is rewritten: [$(grep '^FIRST 40' <<<"$COUT")]" || ok
grep -qF 'not re-handed off, its hand-off record stands' <<<"$L41" && ok \
  || bad "C1 the 3 d old park is not re-handed off: [$(grep -F 'TTL' <<<"$L41")] all: [$(tail -4 <<<"$L41")]"
grep -qxF "FIRST 41 12345" <<<"$COUT" && ok || bad "C1 the old park keeps its hand-off record: [$(grep '^FIRST 41' <<<"$COUT")]"
grep -qF 'handed to bin/blocked-resolver.sh again' <<<"$L41" && bad "C1 the old park is not handed again: [$L41]" || ok

echo "mc-sat-fresh-handoff.bh-9467: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
