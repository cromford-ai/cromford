#!/bin/bash
# tests/fanin-solo.bh-4842-test.sh — BH-4842: a conductor worker killed before
# fan-in says WHY (signal, elapsed, the last mc_log line it wrote), and a PR
# missing from fan-in on MC_FANIN_SOLO_AFTER runs in a row is worked alone in
# its own keyed run, so one slow PR cannot starve itself or its siblings.
#
#   S1-S7  bin/lib/fanin.sh (+ mc_log from bin/lib/mc/log.sh) on a scratch $HARNESS
#   K1-K4  the REAL bin/merge-conductor.sh, gh/curl stubbed (the fixture of
#          tests/fanin.bh-186-test.sh section C): a tick TERMed inside #13's
#          worker the way `timeout 240` kills it, the next tick's alert, the
#          solo launch after two such ticks and the PR classified by it
#   K3     the recursion guard: a solo run (MC_FANIN_SOLO_RUN=1) never solos; a
#          one-key run that is not one does
#   K7     a solo run killed at its worker deadline keeps the streak
#   K5     bin/merge-conductor-backstop.sh's timeout comes from MC_BACKSTOP_TIMEOUT_S
#   K6     no write verb in observe mode
#   K8     the backstop takes the keys the last capped fire deferred first,
#          then the harness's own repo, then the oldest; no project starves
#   K9     a worker that finds the PR's lock held is skipped:locked and keeps
#          the streak
#   K10    a keyed run starts no worker with under 15 s to MC_WORKERS_DONE_BY
#   K11    the backstop's default cap is 6, and the keys a run had no window
#          for head the next fire's carry
#   S8     a `&` wrapper does not install its parent's traps
#   S9     mc_window_cap
#
# Run from anywhere: tests/fanin-solo.bh-4842-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
command -v setsid >/dev/null || { echo "setsid missing — skipping"; exit 0; }

# =============================================================================
# S. the lib
# =============================================================================
F="$T/f"; mkdir -p "$F/bin" "$F/logs" || exit 1
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$F" > "$F/bin/lane-alert.sh"
chmod +x "$F/bin/lane-alert.sh"
FLOG="$F/logs/lane.log"
lib() { ( export HARNESS="$F"; . "$DIR/bin/lib/fanin.sh" 2>/dev/null || exit 9; "$@" ); }
reset_f() { scratch_rm "$F/state"; : > "$F/alerts.txt"; : > "$FLOG"; rm -f "$F/stop" "$F"/up.*; }
outfn() { echo "st$1"; }
# A body that runs until the case is over (or 30s), in short sleeps so a killed
# body leaves no long-lived orphan behind.
slow() { local i=0; while [ ! -e "$F/stop" ] && [ "$i" -lt 150 ]; do sleep 0.2; i=$((i+1)); done; }
# up <name> — the body's first act: a marker that it is running. fanin_run_sub
# installs its TERM/INT/HUP traps BEFORE it forks the body, so once the marker
# exists a signal to the wrapper is trapped. (A child of the wrapper alone is
# not proof: its command substitutions are children too, and fork before the
# traps are set.)
up() { : > "$F/up.$1"; }
slowup() { up "$1"; slow; }
staged() { up "$1"; mc_log "$2"; slow; }
# body_up <name> — bounded wait (10s) for that marker.
body_up() { local i=0; while [ "$i" -lt 100 ]; do [ -e "$F/up.$1" ] && return 0; sleep 0.1; i=$((i+1)); done; return 1; }

# S1 — a TERMed wrapper is still missing, and the alert says signal + elapsed.
reset_f
s1() { fanin_begin lane s1 "$FLOG"; fanin_enumerate 'p#t'
       fanin_run_sub 'p#t' outfn slowup t & local w=$!
       body_up t || echo "S1 setup: the body never started" >> "$F/setup.txt"
       kill -TERM "$w"; wait "$w" 2>/dev/null
       fanin_end; }
lib s1; touch "$F/stop"
A=$(cat "$F/alerts.txt")
grep -q 'ALERT FANIN lane s1: enumerated 1 accounted 0 missing: p#t' <<<"$A" \
  && ok || bad "S1: the TERMed worker is missing (got: ${A:-none})"
grep -Eq ' why: p#t signal=TERM after=[0-9]+s' <<<"$A" \
  && ok || bad "S1: the alert says why: p#t signal=TERM after=Ns (got: ${A:-none})"
grep -q 'enumerated 1 accounted 0' "$FLOG" && ok || bad "S1: no A line for a killed worker (log: $(cat "$FLOG"))"

# S2 — SIGKILL cannot be trapped: today's alert text, byte for byte.
reset_f
s2() { fanin_begin lane s2 "$FLOG"; fanin_enumerate 'p#k'
       fanin_run_sub 'p#k' outfn slowup k & local w=$!
       body_up k || echo "S2 setup: the body never started" >> "$F/setup.txt"
       kill -KILL "$w"; wait "$w" 2>/dev/null
       fanin_end; }
lib s2; touch "$F/stop"
grep -qx -- '--severity warn lane ALERT FANIN lane s2: enumerated 1 accounted 0 missing: p#k' "$F/alerts.txt" \
  && ok || bad "S2: a SIGKILLed worker keeps today's exact alert (got: $(cat "$F/alerts.txt"))"

# S3 — the stage: the last mc_log line the worker wrote, from the REAL mc_log.
reset_f
s3() { export MC_LOG="$F/logs/mc.log"; : > "$MC_LOG"
       # shellcheck source=bin/lib/mc/log.sh
       . "$DIR/bin/lib/mc/log.sh" 2>/dev/null; MC_LOG="$F/logs/mc.log"
       fanin_begin lane s3 "$FLOG"; fanin_enumerate 'p#s'; fanin_enumerate 'p#q'
       fanin_run_sub 'p#s' outfn staged s 'p#s reached merge-tree' & local w=$!
       fanin_run_sub 'p#q' outfn slowup q & local q=$!
       body_up s && body_up q || echo "S3 setup: a body never started" >> "$F/setup.txt"
       sleep 0.3
       find "$F/state/fanin/lane/.stage" -type f > "$F/s3-stage-during.txt" 2>/dev/null
       kill -TERM "$w" "$q"; wait "$w" "$q" 2>/dev/null
       fanin_end; }
lib s3; touch "$F/stop"
A=$(cat "$F/alerts.txt")
grep -qF 'why: p#s signal=TERM after=' <<<"$A" && grep -qF 'stage: "p#s reached merge-tree"' <<<"$A" \
  && ok || bad "S3: the alert names the stage p#s reached (got: ${A:-none})"
grep -Eq '; p#q signal=TERM after=[0-9]+s$' <<<"$A" \
  && ok || bad "S3: a worker that never logged gets no stage: (got: ${A:-none})"
grep -q ' p#s reached merge-tree$' "$F/logs/mc.log" && ok || bad "S3: mc_log still writes its log (got: $(cat "$F/logs/mc.log"))"
[ -s "$F/s3-stage-during.txt" ] && ok || bad "S3: setup — no stage file while the worker ran"
[ -z "$(find "$F/state/fanin/lane/.stage" -type f 2>/dev/null)" ] \
  && ok || bad "S3: fanin_end clears the run's stage files: $(find "$F/state/fanin/lane/.stage" -type f)"

# S4 — the run itself TERMed: the next begin's alert names the signal.
reset_f
s4run() { fanin_begin lane s4 "$FLOG"; fanin_trap_run; fanin_enumerate a; fanin_enumerate b
          fanin_account a x; kill -TERM "$BASHPID"; slow; fanin_end; }
s4() { ( s4run ) & local r=$!; wait "$r" 2>/dev/null
       fanin_begin lane s4 "$FLOG"; fanin_end; }
lib s4; touch "$F/stop"
A=$(cat "$F/alerts.txt")
grep -Eq 'ALERT FANIN lane s4: enumerated 2 accounted 1 missing: b \(run died before fan-in\) run: signal=TERM after=[0-9]+s' <<<"$A" \
  && ok || bad "S4: the dead run's alert says run: signal=TERM after=Ns (got: ${A:-none})"

# S5 — the streak: +1 per missing run, kept by deferred:, cleared by a real outcome.
reset_f
s5miss() { fanin_begin lane s5 "$FLOG"; fanin_enumerate 'p#x'; fanin_enumerate "$1"; fanin_end; }
s5acc()  { fanin_begin lane s5 "$FLOG"; fanin_enumerate 'p#x'; fanin_account 'p#x' "$1"; fanin_end; }
s5get()  { fanin_begin lane s5 "$FLOG"; echo "$(fanin_streak 'p#x') $(fanin_streak 'p#y') $(fanin_streak 'p#none')"; fanin_end; }
lib s5miss 'p#y'; lib s5miss 'p#z'
[ "$(lib s5get)" = "2 1 0" ] && ok || bad "S5: two missing runs = streak 2, one = 1, never = 0 (got: $(lib s5get))"
lib s5acc deferred:solo
[ "$(lib s5get)" = "2 1 0" ] && ok || bad "S5: deferred:solo keeps the streak (got: $(lib s5get))"
lib s5acc killed:deadline
[ "$(lib s5get)" = "2 1 0" ] && ok || bad "S5: killed:deadline keeps the streak, the worker never finished (got: $(lib s5get))"
lib s5acc 'READY rc=143 signal=TERM'
[ "$(lib s5get)" = "2 1 0" ] && ok || bad "S5: a signal death keeps the streak (got: $(lib s5get))"
lib s5acc skipped:locked
[ "$(lib s5get)" = "2 1 0" ] && ok || bad "S5: skipped:locked keeps the streak, another worker holds the PR (got: $(lib s5get))"
lib s5acc 'READY held:worker-locked'
[ "$(lib s5get)" = "2 1 0" ] && ok || bad "S5: READY held:worker-locked keeps the streak (got: $(lib s5get))"
lib s5acc deferred:window
[ "$(lib s5get)" = "2 1 0" ] && ok || bad "S5: deferred:window keeps the streak (got: $(lib s5get))"
lib s5acc READY
[ "$(lib s5get)" = "0 1 0" ] && ok || bad "S5: a real outcome clears it; an id the run never enumerated is untouched (got: $(lib s5get))"

# S6 — a body killed outright while its wrapper lives: accounted, with the signal name.
reset_f
selfkill() { kill -KILL "$BASHPID"; }
s6() { fanin_begin lane s6 "$FLOG"; fanin_enumerate 'p#9'; fanin_run_sub 'p#9' outfn selfkill; fanin_end; }
lib s6
grep -q 'enumerated 1 accounted 1 (st137 rc=137 signal=KILL 1)' "$FLOG" \
  && ok || bad "S6: accounted rc=137 signal=KILL (log: $(cat "$FLOG"))"
[ ! -s "$F/alerts.txt" ] && ok || bad "S6: not missing, so no alert (got: $(cat "$F/alerts.txt"))"

# S7 — mc_log keeps its own rc whatever the stage file does.
s7() { export MC_LOG="$F/logs/mc7.log"
       . "$DIR/bin/lib/mc/log.sh" 2>/dev/null; MC_LOG="$F/logs/mc7.log"
       unset FANIN_STAGE_FILE; mc_log x; echo "unset=$?"
       FANIN_STAGE_FILE="$F/no/such/dir/f"; mc_log y; echo "unwritable=$?"
       MC_LOG="$F/no/such/dir/log"; FANIN_STAGE_FILE="$F/logs/s7.stage"; mc_log z 2>/dev/null; echo "logfail=$?"; }
R7=$(lib s7 | tr '\n' ' ')
[ "$R7" = "unset=0 unwritable=0 logfail=1 " ] && ok || bad "S7: mc_log rc is the log write's (got: $R7)"
[ ! -e "$F/no" ] && ok || bad "S7: an unwritable stage path creates nothing"
s7err() { export MC_LOG="$F/logs/mc7.log"
          . "$DIR/bin/lib/mc/log.sh" 2>/dev/null; MC_LOG="$F/logs/mc7.log"
          FANIN_STAGE_FILE="$F/no/such/dir/f"; mc_log y; }
E7=$(lib s7err 2>&1 >/dev/null)
[ -z "$E7" ] && ok || bad "S7: an unwritable stage path writes nothing to stderr (got: $E7)"
# S8 — the conductor's shape: the run's traps (fanin_trap_run), then each worker
# wrapper in a `&` subshell. bash shows a subshell its parent's traps, but none
# is installed there, so the wrapper must not put _fanin_run_signal back after
# its body: a TERM to it before its A line would stamp the RUN, not the worker.
reset_f
s8() { fanin_begin lane s8 "$FLOG"; fanin_trap_run; fanin_enumerate 'p#8'
       { fanin_run_sub 'p#8' outfn true; trap -p TERM INT HUP > "$F/s8.traps"; } & wait "$!"
       trap -p TERM > "$F/s8.parent"
       fanin_run_sub 'p#8f' outfn true; trap -p TERM > "$F/s8.fg"
       fanin_end; }
lib s8
[ ! -s "$F/s8.traps" ] && ok || bad "S8: a & wrapper installs none of its parent's traps (got: $(cat "$F/s8.traps"))"
grep -q _fanin_run_signal "$F/s8.parent" && ok || bad "S8: the run keeps its own trap (got: $(cat "$F/s8.parent"))"
grep -q _fanin_run_signal "$F/s8.fg" && ok || bad "S8: a foreground call puts the caller's trap back (got: $(cat "$F/s8.fg"))"

# S9 — mc_window_cap: what is left until MC_WORKERS_DONE_BY, never above
# MC_WORKER_DEADLINE_CAP_S; rc 1 under 15 s; no deadline = no cap.
s9() { local n; n=$(date +%s)
       echo "unset=$(unset MC_WORKERS_DONE_BY; mc_window_cap; echo "rc$?")"
       echo "junk=$(MC_WORKERS_DONE_BY=abc mc_window_cap; echo "rc$?")"
       echo "far=$(MC_WORKERS_DONE_BY=$((n + 200)) MC_WORKER_DEADLINE_CAP_S= mc_window_cap)"
       echo "capped=$(MC_WORKERS_DONE_BY=$((n + 200)) MC_WORKER_DEADLINE_CAP_S=60 mc_window_cap)"
       echo "near=$(MC_WORKERS_DONE_BY=$((n + 10)) mc_window_cap; echo "rc$?")"; }
R9=$(lib s9 | tr '\n' ' ')
grep -Eq '^unset=rc0 junk=rc0 far=(19[89]|200) capped=60 near=rc1 $' <<<"$R9" \
  && ok || bad "S9: mc_window_cap (got: $R9)"

[ ! -s "$F/setup.txt" ] && ok || bad "S: setup — $(cat "$F/setup.txt")"

# =============================================================================
# K. the merge conductor, driven
# =============================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
( export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" && fx_conductor_tick "$DIR" "$T" ) || exit 1
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
scratch_install_closure bin/merge-conductor.sh "$T/h" >/dev/null || exit 1
# gh-limit-logger.sh wraps gh in a function that calls `command gh`, which would
# step around tests/lib/gh-list-bridge.sh; the conductor sources it optionally
# (the same seam as tests/merge-path-stall.bh-4918-test.sh).
scratch_rm "$T/h/bin/lib/gh-limit-logger.sh"
[ -f "$T/h/bin/lib/fanin.sh" ] && [ -f "$T/h/bin/lib/keyed-wake.sh" ] || { echo "setup: the conductor closure lacks fanin.sh/keyed-wake.sh"; exit 1; }
H1=aaaaaaaa1111; H2=bbbbbbbb2222; H3=cccccccc3333
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/c-alerts.txt"\nexit 0\n' "$T" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"

# #13 is LAST in the list, so a tick killed inside its worker has accounted
# every other row (MC_PR_PARALLEL=1 runs them in order).
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*|*"-X PATCH"*|*"-X POST"*|*"-X PUT"*|*"-X DELETE"*)
    echo "WRITE VERB IN OBSERVE MODE: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<'J'
[{"number":11,"url":"https://github.com/example-org/demo-os/pull/11","headRefOid":"$H1","headRefName":"ticket/TK-11","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"},
 {"number":12,"url":"https://github.com/example-org/demo-os/pull/12","headRefOid":"$H2","headRefName":"ticket/TK-12","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"},
 {"number":16,"url":"https://github.com/example-org/demo-os/pull/16","headRefOid":"$H1","headRefName":"ticket/TK-16","isDraft":true,"mergeStateStatus":"DRAFT","mergeable":"UNKNOWN","state":"OPEN"},
 {"number":13,"url":"https://github.com/example-org/demo-os/pull/13","headRefOid":"$H3","headRefName":"ticket/TK-13","isDraft":false,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","state":"OPEN"}]
J
    ;;
  *"repos/example-org/demo-os/pulls?state=closed"*) printf 'HTTP/2.0 200\r\n\r\n[]\n' ;;
  *"actions/runs?head_sha=$H1"*) printf 'completed|success\ncompleted|success\n' ;;
  *"actions/runs?head_sha=$H2"*) printf 'in_progress|\n' ;;
  *"actions/runs?head_sha=$H3"*)
    # With slow13 set, #13's CI read hangs (bounded) until its worker deadline.
    if [ -e "$T/slow13" ]; then i=0; while [ -e "$T/slow13" ] && [ "\$i" -lt 150 ]; do sleep 0.1; i=\$((i+1)); done; fi
    # Only #13's worker reads this. With the marker set the whole tick is
    # TERMed here, the way GNU timeout signals its process group.
    if [ -e "$T/term13" ]; then
      echo killed >> "$T/killed.txt"; kill -TERM -- -"\$(ps -o pgid= \$\$ | tr -d ' ')"; exit 1
    fi
    printf 'completed|success\n' ;;
  *"v3.diff"*) restpr --diff ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/11") restpr OPEN "$H1" ticket/TK-11 main "" ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/12") restpr OPEN "$H2" ticket/TK-12 main "" ;;
  *"api -i -X GET repos/example-org/demo-os/pulls/13") restpr OPEN "$H3" ticket/TK-13 main "" CONFLICTING DIRTY ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":5000,"limit":5000,"reset":2000000000},"graphql":{"remaining":5000,"limit":5000,"reset":2000000000}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
URL="${!#}"; M=GET
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "PUT "*/api/ledger) printf '{"ok":true}\n200\n' ;;
  *) printf '{"error":"not found"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/curl"
: > "$T/gh-writes.txt"; : > "$T/c-alerts.txt"
CLOG="$T/h/logs/merge-conductor.log"; : > "$CLOG"
LDIR="$T/h/state/fanin/merge-conductor"
K13='example-org/demo-os#13'
# ctick [VAR=value...] — one real tick in its own session.
ctick() {
  ( cd "$T" && setsid -w env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x MC_PR_PARALLEL=1 \
      MC_KEYED_WAKE_MIN_S=0 "$@" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) 2>/dev/null || true
}
pid_dead() { local s; kill -0 "$1" 2>/dev/null || return 0
  s=$(cat "/proc/$1/stat" 2>/dev/null) || return 0; s=${s##*) }
  case "${s%% *}" in Z|X) return 0 ;; esac; return 1; }
# termtick — a tick TERMed inside #13's worker; returns once its ledger pid is
# dead and the worker's own stamp (if any) has landed, bounded at 10s each.
termtick() { local l p i=0
  : > "$T/killed.txt"; : > "$T/term13"; ctick "$@"; rm -f "$T/term13"
  l=$(find "$LDIR" -maxdepth 1 -name 'example-org_demo-os.*' -type f 2>/dev/null | head -1)
  [ -n "$l" ] || return 1
  p="${l##*.}"
  while ! pid_dead "$p" && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  i=0; while ! grep -q "^X $K13 " "$l" 2>/dev/null && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i+1)); done
  return 0; }
streak13() { awk -F'\t' -v id="$K13" '$1 == id { print $2; f = 1 } END { if (!f) print 0 }' "$LDIR/.streak" 2>/dev/null || echo 0; }
since() { tail -n +"$(($1 + 1))" "$CLOG"; }
wait_for() { local i=0; while ! grep -qF -- "$2" <<<"$(since "$1")" && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done; grep -qF -- "$2" <<<"$(since "$1")"; }

# K1 — TERMed mid-worker: the next tick's alert names the signal; the stage
# comes from the real worker's mc_log. In this fixture #13's worker writes no
# log line before its CI read (where it is killed), so its why: carries the
# stamp and no stage; #11's worker logged its classification, and the dead
# run's .stage dir holds exactly that line until the next tick reaps it.
termtick || bad "K1: setup — the TERMed tick left no ledger"
[ -s "$T/killed.txt" ] && ok || bad "K1: setup — the stub never TERMed the tick during #13's worker"
SD=$(find "$LDIR/.stage" -mindepth 1 -maxdepth 1 -type d -name 'example-org_demo-os.*' 2>/dev/null | head -1)
S11=$(cat "$SD/example-org_demo-os_11" 2>/dev/null)
[ -n "$S11" ] && grep -q '^example-org/demo-os#11 ' <<<"$S11" && grep -qF -- " $S11" "$CLOG" \
  && ok || bad "K1: the real worker's mc_log wrote #11's stage file (got: '${S11:-}' in ${SD:-no .stage dir})"
[ ! -s "$SD/example-org_demo-os_13" ] && ! grep -q '^[^ ]* [^ ]* example-org/demo-os#13 ' "$CLOG" \
  && ok || bad "K1: setup — #13's worker logged before its CI read; the no-stage assertion below needs updating"
M=$(wc -l < "$CLOG"); : > "$T/c-alerts.txt"; ctick
A=$(grep -F 'FANIN' "$T/c-alerts.txt")
grep -qF "ALERT FANIN merge-conductor example-org/demo-os: enumerated 4 accounted 3 missing: $K13 (run died before fan-in) run: signal=TERM after=" <<<"$A" \
  && ok || bad "K1: the alert names #13 and the run's signal (got: ${A:-none}; stderr: $(tail -3 "$T/tick.err"))"
grep -Eq "why: $K13 signal=TERM after=[0-9]+s$" <<<"$A" \
  && ok || bad "K1: why: names #13's signal, and no stage it never logged (got: ${A:-none})"
[ ! -d "$SD" ] && ok || bad "K1: the next tick reaped the dead run's .stage dir ($SD)"
[ "$(streak13)" = 0 ] && ok || bad "K1: the healthy tick after it cleared #13's streak (got $(streak13))"

# K2 — missing on two runs in a row: worked alone, and still classified.
termtick || bad "K2: setup — first TERMed tick left no ledger"
termtick || bad "K2: setup — second TERMed tick left no ledger"
rm -f "$T/h/state/merge-conductor/pr-state.tsv"; touch "$T/h/state/merge-conductor/pr-state.tsv"
M=$(wc -l < "$CLOG"); ctick
L=$(since "$M" | grep -F 'FANIN merge-conductor example-org/demo-os:' | grep -v ALERT | head -1)
grep -q 'enumerated 4 accounted 4 (' <<<"$L" && grep -q 'deferred:solo 1' <<<"$L" \
  && ok || bad "K2a: the batch tick accounts #13 deferred:solo (got: ${L:-none}; stderr: $(tail -3 "$T/tick.err"))"
since "$M" | grep -qF "$K13 FANIN_SOLO: missing from fan-in on 2 runs in a row — launched alone" \
  && ok || bad "K2b: one FANIN_SOLO line (log: $(since "$M" | grep -F FANIN))"
wait_for "$M" "keyed tick: 1 key(s) — $K13" && ok || bad "K2c: the solo keyed run started (log: $(since "$M" | grep -F 'keyed tick'))"
wait_for "$M" 'FANIN merge-conductor example-org/demo-os: enumerated 1 accounted 1' \
  && ok || bad "K2c: the solo run reached fan-in with #13 accounted (log: $(since "$M" | grep -F FANIN))"
S13=$(awk -F'\t' -v id="$K13" '$1 == id { print $2 }' "$T/h/state/merge-conductor/pr-state.tsv" 2>/dev/null)
[ -n "$S13" ] && ok || bad "K2d: #13 has a classified pr-state.tsv row (got: '$S13')"
i=0; while [ "$(streak13)" != 0 ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
[ "$(streak13)" = 0 ] && ok || bad "K2e: the solo run's outcome cleared the streak (got $(streak13))"
for n in 11 12; do
  awk -F'\t' -v id="example-org/demo-os#$n" '$1 == id && $2 != "" { f = 1 } END { exit !f }' "$T/h/state/merge-conductor/pr-state.tsv" \
    && ok || bad "K2f: #$n was worked in the batch tick"
done
[ "$(since "$M" | grep -c FANIN_SOLO)" = 1 ] && ok || bad "K2g: the solo run launched no solo of its own (log: $(since "$M" | grep FANIN_SOLO))"

# K3 — the recursion guard is the solo marker, not the key count. A solo run
# (MC_FANIN_SOLO_RUN=1, which mc_fanin_solo sets on the run it launches) never
# solos again; a one-key run that is NOT a solo run (a backstop fire whose only
# candidate is the starving PR, still under `timeout 240`) does.
printf '%s\t5\t%s\n' "$K13" "$(date +%s)" > "$LDIR/.streak"
M=$(wc -l < "$CLOG"); ctick MC_ONLY_PR="$K13" MC_FANIN_SOLO_RUN=1
[ "$(since "$M" | grep -c 'keyed tick:')" = 1 ] && ok || bad "K3a: exactly one keyed run (log: $(since "$M" | grep 'keyed tick'))"
! grep -q FANIN_SOLO <<<"$(since "$M")" && ok || bad "K3a: a solo run launches no solo (log: $(since "$M" | grep FANIN_SOLO))"
printf '%s\t5\t%s\n' "$K13" "$(date +%s)" > "$LDIR/.streak"
M=$(wc -l < "$CLOG"); ctick MC_ONLY_PR="$K13"
since "$M" | grep -qF "$K13 FANIN_SOLO: missing from fan-in on 5 runs in a row — launched alone" \
  && ok || bad "K3b: a one-key backstop-style run solos the starving PR (log: $(since "$M" | grep -F FANIN_SOLO))"
i=0; while [ "$(since "$M" | grep -c 'FANIN merge-conductor example-org/demo-os: enumerated 1 accounted 1')" -lt 2 ] && [ "$i" -lt 150 ]; do sleep 0.1; i=$((i+1)); done
[ "$(since "$M" | grep -c 'FANIN merge-conductor example-org/demo-os: enumerated 1 accounted 1')" = 2 ] \
  && ok || bad "K3b: the one-key run and its solo run both reached fan-in (log: $(since "$M" | grep -F 'FANIN merge-conductor'))"
[ "$(since "$M" | grep -c FANIN_SOLO)" = 1 ] && ok || bad "K3b: the solo run did not solo again (log: $(since "$M" | grep FANIN_SOLO))"
# The streak rewrite follows the FANIN line, so wait for it before K7 sets its
# own streak: the solo run's finished outcome clears #13.
i=0; while [ "$(streak13)" != 0 ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
[ "$(streak13)" = 0 ] && ok || bad "K3b: the solo run's finished outcome cleared the streak (got $(streak13))"

# K7 — a solo run whose worker hits MC_WORKER_DEADLINE_S (BH-4918) keeps the
# streak: the worker never finished, so the PR must not go back to batches.
printf '%s\t2\t%s\n' "$K13" "$(date +%s)" > "$LDIR/.streak"
: > "$T/slow13"
M=$(wc -l < "$CLOG"); ctick MC_WORKER_DEADLINE_S=2
i=0; while ! grep -q 'FANIN merge-conductor example-org/demo-os: enumerated 1 accounted 1 (killed:deadline' <<<"$(since "$M")" && [ "$i" -lt 250 ]; do sleep 0.1; i=$((i+1)); done
rm -f "$T/slow13"
since "$M" | grep -q 'FANIN merge-conductor example-org/demo-os: enumerated 1 accounted 1 (killed:deadline' \
  && ok || bad "K7: setup — the solo run's worker was killed at its deadline (log: $(since "$M" | grep -F -e FANIN -e DEADLINE))"
sleep 0.5
[ "$(streak13)" = 2 ] && ok || bad "K7: a deadline kill keeps #13's streak (got $(streak13); log: $(since "$M" | grep -F -e FANIN -e DEADLINE -e "$K13"))"

# K4 — the knob at 0, and a refused launch, keep #13 in the batch.
printf '%s\t5\t%s\n' "$K13" "$(date +%s)" > "$LDIR/.streak"
M=$(wc -l < "$CLOG"); ctick MC_FANIN_SOLO_AFTER=0
L=$(since "$M" | grep -F 'FANIN merge-conductor example-org/demo-os:' | grep -v ALERT | head -1)
! grep -q FANIN_SOLO <<<"$(since "$M")" && grep -q 'enumerated 4 accounted 4 (' <<<"$L" && ! grep -q deferred:solo <<<"$L" \
  && ok || bad "K4: MC_FANIN_SOLO_AFTER=0 works #13 in the batch (got: ${L:-none})"
printf '%s\t2\t%s\n' "$K13" "$(date +%s)" > "$LDIR/.streak"
M=$(wc -l < "$CLOG"); ctick MC_KEYED_WAKE=0
L=$(since "$M" | grep -F 'FANIN merge-conductor example-org/demo-os:' | grep -v ALERT | head -1)
since "$M" | grep -qF "$K13 FANIN_SOLO: missing from fan-in on 2 runs in a row — solo launch refused" \
  && since "$M" | grep -F FANIN_SOLO | grep -q 'kept in this run$' \
  && ok || bad "K4: a refused launch says so (log: $(since "$M" | grep FANIN_SOLO))"
grep -q 'enumerated 4 accounted 4 (' <<<"$L" && ! grep -q deferred:solo <<<"$L" \
  && ok || bad "K4: ...and #13 is worked in this run (got: ${L:-none})"
! grep -q "keyed tick:" <<<"$(since "$M")" && ok || bad "K4: no keyed run was launched"

# K9 — #13's lock is held (a solo run still working it) when a batch tick comes:
# the worker is skipped, accounted skipped:locked, and the streak is kept, so
# the next fire solos #13 again instead of sending it back to batches.
LK=$(find "$T/h" -name 'merge-conductor-*13.lock' 2>/dev/null | head -1)
[ -n "$LK" ] || bad "K9: setup — no PR lock file for #13 after the ticks above"
printf '%s\t1\t%s\n' "$K13" "$(date +%s)" > "$LDIR/.streak"
: > "$T/hold"; rm -f "$T/held"
( exec 9>"$LK"; flock 9; : > "$T/held"; i=0; while [ -e "$T/hold" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i+1)); done ) &
HP=$!
i=0; while [ ! -e "$T/held" ] && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
M=$(wc -l < "$CLOG"); ctick
rm -f "$T/hold"; wait "$HP" 2>/dev/null
L=$(since "$M" | grep -F 'FANIN merge-conductor example-org/demo-os:' | grep -v ALERT | head -1)
since "$M" | grep -qF "$K13: an earlier conductor worker still holds this PR's lock" \
  && ok || bad "K9: setup — #13's worker found its lock held (log: $(since "$M" | grep -F "$K13"))"
grep -q 'enumerated 4 accounted 4 (' <<<"$L" && grep -q 'skipped:locked 1' <<<"$L" \
  && ok || bad "K9: #13 is accounted skipped:locked (got: ${L:-none})"
sleep 0.5
[ "$(streak13)" = 1 ] && ok || bad "K9: a lock-skip keeps #13's streak (got $(streak13))"

# K10 — THE WINDOW. A keyed run whose MC_WORKERS_DONE_BY leaves under 15 s of
# worker time starts no worker: every row is accounted deferred:window, logged,
# and handed back in the defer file.
: > "$LDIR/.streak"; : > "$T/defer.txt"
M=$(wc -l < "$CLOG"); ctick MC_WORKERS_DONE_BY=$(( $(date +%s) + 5 )) MC_WINDOW_DEFER_FILE="$T/defer.txt"
L=$(since "$M" | grep -F 'FANIN merge-conductor example-org/demo-os:' | grep -v ALERT | head -1)
grep -q 'enumerated 4 accounted 4 (deferred:window 4)' <<<"$L" \
  && ok || bad "K10: no window, no worker: all four deferred:window (got: ${L:-none}; stderr: $(tail -3 "$T/tick.err"))"
[ "$(sort "$T/defer.txt" | paste -sd' ' -)" = "example-org/demo-os#11 example-org/demo-os#12 example-org/demo-os#13 example-org/demo-os#16" ] \
  && ok || bad "K10: the defer file names every deferred key (got: $(paste -sd' ' "$T/defer.txt"))"
since "$M" | grep -qF "$K13 WINDOW_DEFERRED:" && ok || bad "K10: the deferral is logged (log: $(since "$M" | grep -F WINDOW))"
: > "$T/defer.txt"
M=$(wc -l < "$CLOG"); ctick MC_WORKERS_DONE_BY=$(( $(date +%s) + 245 )) MC_WINDOW_DEFER_FILE="$T/defer.txt"
L=$(since "$M" | grep -F 'FANIN merge-conductor example-org/demo-os:' | grep -v ALERT | head -1)
grep -q 'enumerated 4 accounted 4 (' <<<"$L" && ! grep -q 'deferred:window' <<<"$L" && [ ! -s "$T/defer.txt" ] \
  && ok || bad "K10: with the window open every worker runs (got: ${L:-none}; defer: $(cat "$T/defer.txt"))"

# =============================================================================
# K5. the backstop's timeout is a knob
# =============================================================================
R="$T/r"; mkdir -p "$R/bin/lib" "$R/logs" "$R/state/merge-conductor" "$R/flags" "$R/env" "$T/rbin" || exit 1
scratch_install_closure bin/merge-conductor-backstop.sh "$R" >/dev/null || exit 1
: > "$R/env/global.env"
printf '#!/bin/bash\nprintf "%%s\\n" "${MC_ONLY_PR:-}" >> "%s/rec.txt"\n' "$T" > "$R/bin/merge-conductor.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/to.txt"; shift; exec "$@"\n' "$T" > "$T/rbin/timeout"
printf '#!/bin/bash\nexit 1\n' > "$T/rbin/gh"
chmod +x "$R/bin/merge-conductor.sh" "$T/rbin/timeout" "$T/rbin/gh"
printf 'example-org/x-os#1\tREADY\t%s\taaa\taaa\t-\t-\thttps://github.com/example-org/x-os/pull/1\n' "$(date +%s)" \
  > "$R/state/merge-conductor/pr-state.tsv"
# TEST-CHANGE (BH-6000): the backstop starts one DETACHED run per candidate and
# returns at once, so bs waits (bounded) until every run it started has
# written its line. The assertions on the timeout knob are unchanged.
bs() { : > "$T/to.txt"; ( cd "$T" && env PATH="$T/rbin:$PATH" HARNESS="$R" "$@" bash "$R/bin/merge-conductor-backstop.sh" > "$T/bs.out" 2>&1 )
  local want n=0; want=$(sed -n 's/.*: \([0-9]*\) detached keyed conductor run(s) started.*/\1/p' "$T/bs.out" | tail -1)
  while [ "$(grep -c . "$T/to.txt" 2>/dev/null || echo 0)" -lt "${want:-0}" ] && [ "$n" -lt 40 ]; do sleep 0.25; n=$((n + 1)); done; sleep 0.3; }
bs;                             [ "$(cat "$T/to.txt")" = 240 ] && ok || bad "K5: default timeout 240 (got: $(cat "$T/to.txt"))"
bs MC_BACKSTOP_TIMEOUT_S=120;   [ "$(cat "$T/to.txt")" = 120 ] && ok || bad "K5: MC_BACKSTOP_TIMEOUT_S=120 (got: $(cat "$T/to.txt"))"
bs MC_BACKSTOP_TIMEOUT_S=abc;   [ "$(cat "$T/to.txt")" = 240 ] && ok || bad "K5: a non-number falls back to 240 (got: $(cat "$T/to.txt"))"
grep -qx 'example-org/x-os#1' "$T/rec.txt" && ok || bad "K5: the keyed run still got its key (got: $(cat "$T/rec.txt"))"

# K8/K8b/K11. TEST-CHANGE (BH-6000): these cases pinned ONE keyed run per
# fire that took the carry first, then the harness's own repo, then the oldest,
# up to MC_BACKSTOP_MAX_KEYS (default 6), carried the rest, and gave the run a
# shared worker window (MC_WORKERS_DONE_BY) whose deferred keys headed the next
# carry. That batching is what starved PRs (#4546, #5704, #5727, #5990, #5999
# logged WINDOW_DEFERRED on every fire). The contract now: every candidate gets
# its own run in the same fire, with no shared window and no carry, whatever
# the (deprecated) cap says. tests/backstop-per-pr.bh-6000-test.sh drives the
# concurrency; these keep the old cases' intent: no key ever starves.
now=$(date +%s)
{ for n in 1 2 3; do printf 'example-org/x-os#%s\tREADY\t%s\taaa\taaa\t-\t-\tu\n' "$n" "$((now - 100 + n))"; done
  for n in 7 8 9; do printf 'example-org/cromford#%s\tWAIT_CI\t%s\tbbb\tbbb\t-\t-\tu\n' "$n" "$((now - 50 + n))"; done; } > "$R/state/merge-conductor/pr-state.tsv"
: > "$T/rec.txt"
bs MC_BACKSTOP_MAX_KEYS=2 HARNESS_REPO=example-org/cromford
[ "$(sort "$T/rec.txt" | paste -sd' ' -)" = "example-org/cromford#7 example-org/cromford#8 example-org/cromford#9 example-org/x-os#1 example-org/x-os#2 example-org/x-os#3" ] \
  && ok || bad "K8: one fire takes every key, each in its own run, whatever the cap (got: $(sort "$T/rec.txt" | paste -sd' ' -))"
grep -qi 'deferred' "$T/bs.out" && bad "K8: nothing is deferred (got: $(cat "$T/bs.out"))" || ok
[ ! -s "$R/state/merge-conductor/backstop-carry" ] && ok || bad "K8b: no carry is written"

# K11 — no run gets a shared window.
printf '#!/bin/bash\nprintf "%%s\\t%%s\\n" "${MC_ONLY_PR:-}" "${MC_WORKERS_DONE_BY:-}" >> "%s/rec.txt"\nexit 0\n' "$T" > "$R/bin/merge-conductor.sh"
: > "$R/state/merge-conductor/pr-state.tsv"
for n in 1 2 3 4 5 6 7 8; do printf 'example-org/x-os#%s\tREADY\t%s\taaa\taaa\t-\t-\tu\n' "$n" "$((now - 100 + n))" >> "$R/state/merge-conductor/pr-state.tsv"; done
: > "$T/rec.txt"; bs
[ "$(grep -c . "$T/rec.txt")" = 8 ] && ok || bad "K11: all 8 candidates run (got: $(cut -f1 "$T/rec.txt" | paste -sd' ' -))"
[ -z "$(cut -f2 "$T/rec.txt" | tr -d '\n')" ] && ok || bad "K11: no run carries MC_WORKERS_DONE_BY (got: $(cut -f2 "$T/rec.txt" | paste -sd' ' -))"
grep -qF 'no window left' "$T/bs.out" && bad "K11: no window deferral (got: $(cat "$T/bs.out"))" || ok

# K6
[ ! -s "$T/gh-writes.txt" ] && ok || bad "K6: an observe tick used a write verb: $(cat "$T/gh-writes.txt")"

echo "fanin-solo.bh-4842-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
