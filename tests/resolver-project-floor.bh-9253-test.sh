#!/bin/bash
# tests/resolver-project-floor.bh-9253-test.sh — BH-9253: in one resolver tick
# every project with parked work keeps a floor of rungs (BR_PROJECT_FLOOR), and
# a tick that ran 0 rungs while its own hand-offs got no ack writes exactly one
# alert line (BR_ZERO_DISPATCH_ALERT).
#
# THE INCIDENT (hub-2, 2026-11-08 11:58Z): `rungs=0/50 reason=drained
# visited=[project-5]`, and six parked cromford PRs got no rung tick after
# tick while nothing alerted.
#
#   F1-F12  brpf_skip / brpf_take / brpf_init, pure, globals set here
#   T1-T3   a driven fleet tick: two projects, BR_PER_TICK=50, 50 overdue
#           tproj parks offered ahead of one fresh uproj park (the
#           bh-7555 overdue-first order). With the floor uproj gets a rung.
#           With BR_PROJECT_FLOOR=0 it gets none (today's order).
#   Z1-Z2   driven: a tick with 0 rungs (both shares 0) writes one
#           br-zero-dispatch line; a tick that ran rungs writes none
#   Z3-Z8   brpf_zero_alert, pure, over hand-written ack files
#
# The driven tick is the tests/resolver-per-project-budget.bh-870-test.sh
# scaffold: a scratch harness, the real bin/blocked-resolver.sh, its modules
# and every bin/blocked-resolver.d fragment, a two-project fleet.conf, a gh on
# PATH answered from fixture files, and a jobs client that records each rung.
# 0 network calls: GH_TOKEN is empty and every vendor binary is a stub.
# Run from anywhere: tests/resolver-project-floor.bh-9253-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq missing"; exit 1; }
FRAG="$DIR/bin/blocked-resolver.d/bh-9253-project-floor.sh"
# ONE clock read for the whole file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }

# ============================================================================
# F. THE FLOOR, PURE.
# ============================================================================
# sk <want rc> <label> <bucket> <floor> <N> <EFF> <NP spec> <LEFT spec>
#   spec: "a=1 b=0"
sk_fail=""
sk() {
  local want="$1" lab="$2" b="$3" fl="$4" n="$5" eff="$6" np="$7" left="$8" got
  got=$(FRAG="$FRAG" B="$b" FL="$fl" NN="$n" EFF="$eff" NPS="$np" LEFTS="$left" bash -c '
    say() { printf "%s\n" "$*" >&2; }
    . "$FRAG"
    declare -A NP=(); declare -A BRPF_LEFT=(); BRPF_SAID=" "
    for kv in $NPS; do NP[${kv%%=*}]=${kv#*=}; done
    for kv in $LEFTS; do BRPF_LEFT[${kv%%=*}]=${kv#*=}; done
    BR_PROJECT_FLOOR="$FL"; N="$NN"; EFF_PER_TICK="$EFF"
    brpf_skip "$B"; echo $?' 2>/dev/null)
  [ "$got" = "$want" ] || sk_fail="$sk_fail [$lab: rc $got, want $want]"
}
sk 0 F1-floor1-last-rung      a 1 49 50 "a=49 b=0" "a=10 b=1"
sk 0 F2-floor2                a 2 48 50 "a=48 b=0" "a=5 b=3"
sk 1 F3-a-under-its-floor     a 1 49 50 "a=0 b=0"  "a=10 b=1"
sk 1 F4-budget-far-away       a 1 10 50 "a=10 b=0" "a=40 b=1"
sk 1 F5-b-has-no-rows-left    a 1 49 50 "a=49 b=0" "a=10 b=0"
sk 1 F6-b-holds-its-floor     a 1 49 50 "a=48 b=1" "a=10 b=3"
sk 1 F7-floor-off             a 0 49 50 "a=49 b=0" "a=10 b=1"
sk 1 F8-one-project           a 1 49 50 "a=49"     "a=10"
sk 0 F9-empty-project-bucket  a 1 49 50 "a=49"     "a=10 -=1"
sk 0 F10-two-starved          a 1 48 50 "a=48"     "a=3 b=1 c=1"
sk 1 F11-two-starved-room     a 1 47 50 "a=47"     "a=3 b=1 c=1"
sk 1 F12-b-not-in-LEFT-held   a 1 49 50 "a=49 b=0" "a=10"
sk 0 F13-bad-floor-reads-1    a x 49 50 "a=49 b=0" "a=10 b=1"
[ -z "$sk_fail" ] && ok || bad "F brpf_skip:$sk_fail"
# F14: brpf_init counts rows per bucket and leaves out held projects and rows
# with no key; brpf_take counts down and never below 0. (A row with an empty
# project field is not built here: the tab IFS read folds the empty field, in
# brpf_init exactly as in the driver's loop. F9 covers the "-" bucket.)
F14=$(FRAG="$FRAG" bash -c '
  say() { :; }; . "$FRAG"
  lane_project_held() { [ "$2" = hproj ]; }
  T=$(printf "\t")
  CANDS=("c${T}a${T}k1" "c${T}a${T}k2" "c${T}b${T}k3" "c${T}hproj${T}k4" "c${T}a")
  brpf_init
  printf "%s %s %s|" "${BRPF_LEFT[a]:-}" "${BRPF_LEFT[b]:-}" "${BRPF_LEFT[hproj]:-none}"
  brpf_take a; brpf_take b; brpf_take b; brpf_take zz
  printf "%s %s %s" "${BRPF_LEFT[a]}" "${BRPF_LEFT[b]}" "${BRPF_LEFT[zz]:-none}"')
[ "$F14" = "2 1 none|1 0 none" ] && ok || bad "F14 brpf_init/brpf_take: [$F14]"
# F15: the knobs are read once, at brpf_init.
F15=$(FRAG="$FRAG" bash -c 'say() { :; }; . "$FRAG"; CANDS=()
  BR_PROJECT_FLOOR=2 BR_ZERO_DISPATCH_ALERT=0; brpf_init; BR_PROJECT_FLOOR=5 BR_ZERO_DISPATCH_ALERT=1
  printf "%s %s" "$BRPF_FL" "$BRPF_ZA"')
[ "$F15" = "2 0" ] && ok || bad "F15 the knobs are read once per tick: [$F15]"
# F16: one PROJECT_FLOOR line per project per tick.
F16=$(FRAG="$FRAG" bash -c 'say() { printf "%s\n" "$*"; }; . "$FRAG"
  declare -A NP=([a]=49 [b]=0); declare -A BRPF_LEFT=([a]=5 [b]=1); BRPF_SAID=" "; BRPF_FL=1; N=49; EFF_PER_TICK=50
  brpf_skip a; brpf_skip a; brpf_skip a' | grep -c '^PROJECT_FLOOR a skipped: 1 rung(s) kept for \[b\] (BR_PROJECT_FLOOR=1')
[ "$F16" = 1 ] && ok || bad "F16 the PROJECT_FLOOR line is said once per project per tick: $F16"

# ============================================================================
# Z (pure). brpf_zero_alert over hand-written ack files.
# ============================================================================
ZH="$T/zh"; mkdir -p "$ZH/bin" "$ZH/state/blocked-resolver/handoffs/acks"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\n' "$ZH" > "$ZH/bin/alert-line.sh"; chmod +x "$ZH/bin/alert-line.sh"
# za <label> [VAR=val...] — CANDS: two tproj rows (tkeys TK-1 TK-2), N=0.
za() {
  shift   # the label names the case in this file only
  : > "$ZH/alerts"; : > "$ZH/say"
  env BHW_TICK_AT=1000 NN=0 OBS=0 HELD="" "$@" H="$ZH" HARNESS="$ZH" FRAG="$FRAG" DIR="$DIR" bash -c '
    say() { printf "%s\n" "$*" >> "$H/say"; }
    . "$DIR/bin/lib/handoff-watch.sh"; . "$FRAG"
    lane_project_held() { [ -n "$HELD" ] && [ "$2" = "$HELD" ]; }
    T=$(printf "\t")
    CANDS=("conductor${T}tproj${T}k1${T}r${T}https://github.com/o/tproj/pull/1${T}-${T}TK-1${T}900"
           "conductor${T}tproj${T}k2${T}r${T}https://github.com/o/tproj/pull/2${T}-${T}TK-2${T}800"
           "conductor${T}tproj${T}k2${T}r${T}https://github.com/o/tproj/pull/2${T}-${T}TK-2${T}800")
    BHW_ON=1; N="$NN"; EFF_PER_TICK=50; STOPREASON=drained; VISITLIST=""; ONLY=""; OBSERVE="$OBS"
    brpf_init; brpf_zero_alert'
}
ACKS="$ZH/state/blocked-resolver/handoffs/acks"
ack() { printf '%s\n' "$3" > "$ACKS/$1.$2"; }
clearacks() { rm -f "$ACKS"/*; }
clearacks; za z3
[ "$(grep -c . "$ZH/alerts")" = 1 ] && grep -q -- '--id br-zero-dispatch:fleet' "$ZH/alerts" \
  && grep -q '2 undispatched hand-off(s) (0 dispatched with rc 3)' "$ZH/alerts" && grep -q 'oldest: tproj-TK-2' "$ZH/alerts" && ok \
  || bad "Z3 two unacked rows (one twice): one alert, k=2, the oldest named: [$(cat "$ZH/alerts")]"
grep -q '^ZERO_DISPATCH fleet:' "$ZH/say" && ok || bad "Z3 one ZERO_DISPATCH say line: [$(cat "$ZH/say")]"
clearacks; ack tproj-TK-1 dispatched 1000; ack o-tproj-2 held 1001; za z4
[ ! -s "$ZH/alerts" ] && ok || bad "Z4 every row acked (by tkey id or by url id): no alert: [$(cat "$ZH/alerts")]"
clearacks; ack tproj-TK-1 lock-held 1000; ack tproj-TK-2 dispatched 999; za z5
grep -q '1 undispatched hand-off(s) (1 dispatched with rc 3)' "$ZH/alerts" && ok || bad "Z5 an ack from before this tick does not count: [$(cat "$ZH/alerts")]"
clearacks; za z6 NN=3
[ ! -s "$ZH/alerts" ] && ok || bad "Z6 a tick that ran rungs: no alert"
clearacks; za z7 BR_ZERO_DISPATCH_ALERT=0
[ ! -s "$ZH/alerts" ] && ok || bad "Z7 BR_ZERO_DISPATCH_ALERT=0: no alert"
clearacks; za z8 HELD=tproj
[ ! -s "$ZH/alerts" ] && ok || bad "Z8 a held project's rows do not count: [$(cat "$ZH/alerts")]"
clearacks; za z9 OBS=1
[ ! -s "$ZH/alerts" ] && grep -q 'observe mode' "$ZH/say" && ok || bad "Z9 observe mode says, writes no alert"
# Z10: a sibling run's claim in the shared tick-cands (not in this run's CANDS)
# does not count. This run's own rows are acked.
clearacks; ack tproj-TK-1 dispatched 1000; ack tproj-TK-2 dispatched 1000
printf 'uproj-TK-9\n' > "$ZH/state/blocked-resolver/handoffs/tick-cands"
za z10
[ ! -s "$ZH/alerts" ] && ok || bad "Z10 a sibling's claim alone makes no alert: [$(cat "$ZH/alerts")]"
# Z11: BHW_ON=0 (no hand-off watch this tick): no alert.
clearacks; : > "$ZH/alerts"
Z11=$(H="$ZH" HARNESS="$ZH" FRAG="$FRAG" DIR="$DIR" bash -c '. "$DIR/bin/lib/handoff-watch.sh"; . "$FRAG"; say() { :; }
  T=$(printf "\t"); CANDS=("c${T}tproj${T}k1${T}r${T}-${T}-${T}TK-1${T}900"); BHW_ON=0; N=0; brpf_zero_alert; echo rc=$?')
[ "$Z11" = rc=0 ] && [ ! -s "$ZH/alerts" ] && ok || bad "Z11 BHW_ON=0 writes nothing: [$Z11] [$(cat "$ZH/alerts")]"

# ============================================================================
# T / Z (driven). The real lane in a scratch harness.
# ============================================================================
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$H/state/build-queue/tproj" "$H/state/build-queue/uproj" \
         "$T/fakebin" "$T/repos"
# The lane's closure (BH-4552): the script, its modules and libs, as the
# scratch-closure lint asks. The fragments are copied whole so the overdue-first
# order (bh-7555) and this ticket's floor run as they do in production.
scratch_install_closure bin/blocked-resolver.sh "$H" >/dev/null || { echo "FAIL: closure install"; exit 1; }
# The bin/ helpers the lane execs are not in the lib closure.
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
mkdir -p "$H/bin/blocked-resolver.d" && cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/"
chmod +x "$H/bin/"*.sh
{ printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\n'
  printf 'uproj o/uproj - - 2 box-uproj 192.0.2.7\n'; } > "$H/fleet.conf"
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh agent-call.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts"\nexit 0\n' "$T" > "$H/bin/alert-line.sh"; chmod +x "$H/bin/alert-line.sh"
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
  *"issues/"*"/comments"*) echo '[]' ;;
  *"repos/"*"/issues/"*)
    cat "$T/issues/\$N.json" 2>/dev/null || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *"pr close"*)   exit 0 ;;
  *"pr comment"*|*"issue comment"*) exit 0 ;;
  *"--json state"*)        echo OPEN ;;
  *"/pulls/"*)             echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *"--json headRefOid,headRefName"*) echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ticket/ts-\$N" ;;
  *"--json headRefName"*)  echo "ticket/ts-\$N" ;;
  *"--json headRefOid"*)   echo "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" ;;
  *"pr list"*"--state merged"*) : ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/br-ssh"; chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN=""
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
EOF
touch "$H/flags/fly-pool-tproj" "$H/flags/fly-pool-uproj"
mkdir -p "$T/issues"
# Each ticket has a local build-queue record, so br_park_time dates the park
# from the file and never asks the builds-of-record ledger (a jobs API read).
for n in $(seq 1 50); do printf '{}\n' > "$H/state/build-queue/tproj/TK-$n.json"; done
printf '{}\n' > "$H/state/build-queue/uproj/TK-51.json"
for n in $(seq 1 51); do
  jq -nc --argjson n "$n" --arg c "$(ISO 604800)" \
    '{number:$n,state:"open",labels:[{name:"ai-build"}],title:("TK-\($n): a parked ticket"),body:"## Scope",created_at:$c}' > "$T/issues/$n.json"
done
WHY="merge-failed-twice: gh pr merge refused"
# 50 tproj parks two hours old (overdue: offered first), then one uproj park
# from now. In this order a fleet budget of 50 never reaches uproj.
SEED() {
  : > "$H/state/merge-conductor/pr-state.tsv"
  local n
  for n in $(seq 1 50); do
    printf 'o/tproj#%s\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\t%s\thttps://github.com/o/tproj/pull/%s\n' "$n" "$((NOW - 7200))" "$WHY" "$n"
  done >> "$H/state/merge-conductor/pr-state.tsv"
  printf 'o/uproj#51\tBLOCKED_HUMAN\t%s\tabc123\tabc123\t-\t%s\thttps://github.com/o/uproj/pull/51\n' "$NOW" "$WHY" \
    >> "$H/state/merge-conductor/pr-state.tsv"
}
CLEAN() { scratch_rm "$H/state/blocked-resolver"
          scratch_rm "$H/state/merge-conductor/handoff-released"
          : > "$T/queue.txt"; : > "$T/gh.txt"; : > "$T/alerts"
          : > "$H/logs/blocked-resolver.log"; rm -f "$H/logs/ALERTS.log"; : > "$T/run.log"; }
BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" \
           BR_SSH="$T/fakebin/br-ssh" env ${BRENV[*]:+"${BRENV[@]}"} \
           bash "$H/bin/blocked-resolver.sh" "$@" >>"$T/run.log" 2>&1 ) || true; }
NT() { grep -c '^tproj TK-[0-9]* [0-9]* fly ' "$T/queue.txt" || true; }
NU() { grep -c '^uproj TK-51 51 fly ' "$T/queue.txt" || true; }
LOG="$H/logs/blocked-resolver.log"

CLEAN; SEED; BRENV=(BR_REBUILDS_PER_TICK=60 BR_PER_TICK=50); RUN; BRENV=()
[ "$(NU)" = 1 ] && ok || bad "T1 uproj's park takes a rung in the same tick (uproj=$(NU) tproj=$(NT)); tick: $(grep 'tick:' "$LOG" | tail -1); run.log: $(tail -5 "$T/run.log")"
[ "$(NT)" = 49 ] && ok || bad "T1 tproj takes the other 49 rungs, took $(NT)"
grep -q 'overdue-first: 50 of 51 candidate(s)' "$LOG" && ok \
  || bad "T1 the order is the overdue-first shape (tproj ahead): $(grep 'overdue-first' "$LOG" | tail -1)"
grep -q 'PROJECT_FLOOR tproj skipped: 1 rung(s) kept for \[uproj\] (BR_PROJECT_FLOOR=1' "$LOG" && ok \
  || bad "T1 one PROJECT_FLOOR line names the kept rung: $(grep PROJECT_FLOOR "$LOG")"
[ "$(grep -c PROJECT_FLOOR "$LOG")" = 1 ] && ok || bad "T1 exactly one PROJECT_FLOOR line, got $(grep -c PROJECT_FLOOR "$LOG")"
[ ! -s "$T/alerts" ] && ok || bad "T1/Z2 a tick that ran rungs writes no zero-dispatch alert: [$(cat "$T/alerts")]"

CLEAN; SEED; BRENV=(BR_REBUILDS_PER_TICK=60 BR_PER_TICK=50 BR_PROJECT_FLOOR=0); RUN; BRENV=()
[ "$(NU)" = 0 ] && [ "$(NT)" = 50 ] && ok \
  || bad "T2 with the floor off the order alone decides (uproj 0, tproj 50): uproj=$(NU) tproj=$(NT)"
grep -q PROJECT_FLOOR "$LOG" && bad "T2 no PROJECT_FLOOR line with the floor off" || ok

# T3: a single-project run (ONLY=tproj) is unchanged by the floor.
CLEAN; SEED; BRENV=(BR_REBUILDS_PER_TICK=60 BR_PER_TICK=50); RUN tproj; BRENV=()
[ "$(NT)" = 50 ] && [ "$(NU)" = 0 ] && ! grep -q PROJECT_FLOOR "$LOG" && ok \
  || bad "T3 a project run spends its budget as before: tproj=$(NT) uproj=$(NU)"

# Z1: both shares 0 — the tick runs 0 rungs and dispatches none of its rows.
CLEAN; SEED; BRENV=(BR_REBUILDS_PER_TICK=60 BR_PER_TICK=50 BR_PER_TICK_TPROJ=0 BR_PER_TICK_UPROJ=0); RUN; BRENV=()
[ ! -s "$T/queue.txt" ] && ok || bad "Z1 no rung ran: $(head -3 "$T/queue.txt")"
[ "$(grep -c 'br-zero-dispatch' "$T/alerts")" = 1 ] && ok \
  || bad "Z1 exactly one br-zero-dispatch alert line, got $(grep -c 'br-zero-dispatch' "$T/alerts"): [$(cat "$T/alerts")] tick: $(grep 'tick:' "$LOG" | tail -1)"
grep -q -- '--id br-zero-dispatch:fleet \[blocked-resolver\] fleet: this tick ran 0 rungs and 51 undispatched hand-off(s) (0 dispatched with rc 3)' "$T/alerts" && ok \
  || bad "Z1 the line names the scope and the count: [$(cat "$T/alerts")]"
grep -q '^.*ZERO_DISPATCH fleet:' "$LOG" && ok || bad "Z1 one ZERO_DISPATCH log line: $(grep ZERO "$LOG")"

echo "resolver-project-floor.bh-9253: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
