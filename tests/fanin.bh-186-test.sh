#!/bin/bash
# tests/fanin.bh-186-test.sh — the fan-in assertion (BH-186): every PR the merge
# conductor or reconcile-prs enumerates leaves through exactly one accounted
# outcome, and a run where enumerated != accounted alerts, naming the missing.
#
# Scope (the operator, 2026-09-24): the merge conductor and reconcile-prs. merge-sweep
# no longer runs on cron and is not wired.
#
#   F1-F7  bin/lib/fanin.sh against a scratch $HARNESS
#   C1-C3  the REAL bin/merge-conductor.sh, gh/curl stubbed (the fixture of
#          tests/mc-unverifiable-alert.bh-1634-test.sh): the summary line and
#          its outcomes, no alert on a healthy or empty tick, and a tick killed
#          mid-worker reported by the next one
#   R1-R4  the REAL bin/reconcile-prs.sh (the fixture of
#          tests/reconcile-prs-project-test.sh): every row accounted with its
#          outcome, no alert on a healthy or empty tick, a planted `exit` in the
#          per-PR body reported by the next tick, and the two former `continue`
#          sites accounted
#
# Run from anywhere: tests/fanin.bh-186-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }
[ -f "$DIR/bin/lib/fanin.sh" ] || { bad "bin/lib/fanin.sh does not exist"; }

# =============================================================================
# F. the lib
# =============================================================================
F="$T/f"; mkdir -p "$F/bin" "$F/logs" || exit 1
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$F" > "$F/bin/lane-alert.sh"
chmod +x "$F/bin/lane-alert.sh"
FLOG="$F/logs/lane.log"
# Each case runs in its own subshell so FANIN_* never leaks between cases.
lib() { ( export HARNESS="$F"; . "$DIR/bin/lib/fanin.sh" 2>/dev/null || exit 9; "$@" ); }
reset_f() { scratch_rm "$F/state"; : > "$F/alerts.txt"; : > "$FLOG"; rm -f "$F/logs/ALERTS.log"; }
ledgers() { find "$F/state/fanin" -type f 2>/dev/null | grep -c . || true; }

# F1
reset_f
f1() { fanin_begin lane s1 "$FLOG"; fanin_enumerate a; fanin_enumerate b
       fanin_account a x; fanin_account b y; fanin_end; }
lib f1
[ "$(grep -c 'FANIN' "$FLOG")" = 1 ] && grep -q 'FANIN lane s1: enumerated 2 accounted 2 (x 1, y 1)$' "$FLOG" \
  && ok || bad "F1: one summary 'FANIN lane s1: enumerated 2 accounted 2 (x 1, y 1)' (log: $(cat "$FLOG"))"
[ ! -s "$F/alerts.txt" ] && ok || bad "F1: a healthy run sends no alert: $(cat "$F/alerts.txt")"
[ "$(ledgers)" = 0 ] && ok || bad "F1: the ledger is removed at end ($(ledgers) left)"

# F2
reset_f
f2() { fanin_begin lane "" "$FLOG"; fanin_enumerate 'r#1'; fanin_enumerate 'r#2'
       fanin_account 'r#2' done; fanin_end; }
lib f2
grep -qx -- '--severity warn lane ALERT FANIN lane: enumerated 2 accounted 1 missing: r#1' "$F/alerts.txt" \
  && ok || bad "F2: the alert names the missing PR (got: $(cat "$F/alerts.txt"))"
grep -q 'FANIN lane: enumerated 2 accounted 1 (done 1)' "$FLOG" && ok || bad "F2: the summary still counts (log: $(cat "$FLOG"))"
# ...and with no lane-alert.sh the line lands in ALERTS.log directly
mv "$F/bin/lane-alert.sh" "$F/bin/la.off"; : > "$F/alerts.txt"
lib f2
grep -q 'ALERT FANIN lane: enumerated 2 accounted 1 missing: r#1' "$F/logs/ALERTS.log" 2>/dev/null \
  && ok || bad "F2: no lane-alert.sh -> ALERTS.log carries the alert"
mv "$F/bin/la.off" "$F/bin/lane-alert.sh"

# F3
reset_f
okfn()    { return 0; }
exitfn()  { exit 3; }
retfn()   { return 1; }
killwrap() { local me=$BASHPID; kill -9 "$(awk '{print $4}' "/proc/$me/stat")"; }
outfn()   { echo "st$1"; }
f3() { fanin_begin lane s3 "$FLOG"
       for i in ok exit ret kill; do fanin_enumerate "p#$i"; done
       fanin_run_sub p#ok outfn okfn
       fanin_run_sub p#exit outfn exitfn
       fanin_run_sub p#ret outfn retfn
       fanin_run_sub p#kill outfn killwrap &
       wait $! 2>/dev/null
       fanin_end; }
lib f3
grep -q 'enumerated 4 accounted 3 (st0 1, st3 rc=3 1, st1 rc=1 1)' "$FLOG" \
  && ok || bad "F3: exit and return are accounted with their rc (log: $(cat "$FLOG"))"
grep -q 'missing: p#kill$' "$F/alerts.txt" && ok || bad "F3: a SIGKILLed wrapper is missing (alerts: $(cat "$F/alerts.txt"))"
# fanin_run (same shell): the outcome var, unlabelled, and rc
setv() { OUT=merged; return 0; }
nolab() { return 2; }
f3b() { fanin_begin lane s3b "$FLOG"; fanin_enumerate a; fanin_enumerate b
        fanin_run a OUT setv; fanin_run b OUT nolab; fanin_end; }
: > "$FLOG"; lib f3b
grep -q 'enumerated 2 accounted 2 (merged 1, unlabelled rc=2 1)' "$FLOG" \
  && ok || bad "F3: fanin_run accounts the outcome var, or unlabelled with rc (log: $(cat "$FLOG"))"

# F4
reset_f
f4() { fanin_begin lane s4 "$FLOG"; fanin_enumerate a; fanin_account a x; fanin_account a x; fanin_end; }
lib f4
grep -q 'enumerated 1 accounted 2 double: a$' "$F/alerts.txt" && ok || bad "F4: a double account is named (alerts: $(cat "$F/alerts.txt"))"

# F5
reset_f
f5() { fanin_begin lane s5 "$FLOG"; fanin_end; }
lib f5
[ ! -s "$FLOG" ] && [ ! -s "$F/alerts.txt" ] && [ "$(ledgers)" = 0 ] \
  && ok || bad "F5: an empty run writes nothing (log: $(cat "$FLOG"); alerts: $(cat "$F/alerts.txt"); ledgers $(ledgers))"

# F6
reset_f
mkdir -p "$F/state/fanin/lane"
DEAD=$(bash -c 'echo $$')   # a pid that has exited
printf 'E a\nE b\nA a x\n' > "$F/state/fanin/lane/s6.$DEAD"
printf 'E c\n' > "$F/state/fanin/lane/s6.$$"                 # a live run: not ours to reap
printf 'E d\nA d x\n' > "$F/state/fanin/lane/s6.999999999"    # dead and fully accounted
f6() { fanin_begin lane s6 "$FLOG"; fanin_end; }
lib f6
[ "$(grep -c . "$F/alerts.txt")" = 1 ] && grep -q 'ALERT FANIN lane s6: enumerated 2 accounted 1 missing: b (run died before fan-in)$' "$F/alerts.txt" \
  && ok || bad "F6: exactly one alert, for the dead ledger with a missing id (alerts: $(cat "$F/alerts.txt"))"
[ ! -e "$F/state/fanin/lane/s6.$DEAD" ] && ok || bad "F6: the dead ledger is deleted once reported"
[ -e "$F/state/fanin/lane/s6.$$" ] && ok || bad "F6: a live run's ledger is left alone"
[ ! -e "$F/state/fanin/lane/s6.999999999" ] && ok || bad "F6: a fully accounted dead ledger is deleted"
: > "$F/alerts.txt"; lib f6
[ ! -s "$F/alerts.txt" ] && ok || bad "F6: a dead ledger is reported ONCE (alerts: $(cat "$F/alerts.txt"))"

# F7
reset_f
t7() { ran=1; }
f7() { local rc=0 ran=0
       fanin_enumerate a || rc=1; fanin_account a x || rc=1; fanin_end || rc=1
       fanin_run a OUT t7 || rc=1; [ "$ran" = 1 ] || rc=2
       ran=0; fanin_run_sub a outfn okfn || rc=1
       echo "rc=$rc ran=$ran"; }
R7=$(lib f7 2>&1)
[ "$R7" = "rc=0 ran=0" ] && [ ! -s "$FLOG" ] && [ ! -s "$F/alerts.txt" ] && [ ! -d "$F/state" ] \
  && ok || bad "F7: with no fanin_begin every function is rc 0 and silent, and fanin_run still runs the body (got '$R7')"

# =============================================================================
# C. the merge conductor, driven
# =============================================================================
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
# shellcheck source=tests/lib/fixture-harness.sh
. "$DIR/tests/lib/fixture-harness.sh" || exit 1
( export HARNESS="$T/h"; fx_mc_harness "$DIR" "$T" && fx_conductor_tick "$DIR" "$T" ) || exit 1
[ -f "$DIR/bin/merge-conductor.sh" ] || exit 1   # impact: this suite drives the whole tick
cp "$DIR/bin/lib/fanin.sh" "$T/h/bin/lib/" || exit 1
H1=aaaaaaaa1111; H2=bbbbbbbb2222; H3=cccccccc3333
printf 'demo-os example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/c-alerts.txt"\nexit 0\n' "$T" > "$T/h/bin/lane-alert.sh"
chmod +x "$T/h/bin/lane-alert.sh"

cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"issue comment"*|*"pr review"*|*"pr edit"*|*"-X PATCH"*|*"-X POST"*|*"-X PUT"*|*"-X DELETE"*)
    echo "WRITE VERB IN OBSERVE MODE: \$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*)
    [ -e "$T/empty" ] && { echo '[]'; exit 0; }
    cat <<'J'
[{"number":11,"url":"https://github.com/example-org/demo-os/pull/11","headRefOid":"$H1","headRefName":"ticket/TK-11","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"},
 {"number":12,"url":"https://github.com/example-org/demo-os/pull/12","headRefOid":"$H2","headRefName":"ticket/TK-12","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"},
 {"number":13,"url":"https://github.com/example-org/demo-os/pull/13","headRefOid":"$H3","headRefName":"ticket/TK-13","isDraft":false,"mergeStateStatus":"DIRTY","mergeable":"CONFLICTING","state":"OPEN"},
 {"number":16,"url":"https://github.com/example-org/demo-os/pull/16","headRefOid":"$H1","headRefName":"ticket/TK-16","isDraft":true,"mergeStateStatus":"DRAFT","mergeable":"UNKNOWN","state":"OPEN"}]
J
    ;;
  *"repos/example-org/demo-os/pulls?state=closed"*) printf 'HTTP/2.0 200\r\n\r\n[]\n' ;;
  *"actions/runs?head_sha=$H1"*) printf 'completed|success\ncompleted|success\n' ;;
  *"actions/runs?head_sha=$H2"*) printf 'in_progress|\n' ;;
  *"actions/runs?head_sha=$H3"*)
    # C3: #13's worker reads its CI (only a worker does) and the whole tick is
    # killed there, the way a reaper's SIGKILL would.
    if [ -e "$T/kill13" ]; then
      echo killed >> "$T/killed.txt"; kill -9 -- -"\$(ps -o pgid= \$\$ | tr -d ' ')"
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
printf '11\n16\n' > "$T/lazy-fail"
CLOG="$T/h/logs/merge-conductor.log"
# ctick [fail] — one real tick in its own session (C3 kills its process group).
ctick() {
  local extra=()
  [ "${1:-}" = fail ] && extra=(GH_LIST_BRIDGE_FAIL_LAZY="$T/lazy-fail")
  ( cd "$T" && setsid -w env PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x MC_PR_PARALLEL=1 \
      "${extra[@]}" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) 2>/dev/null || true
}
fanin_lines() { grep -F 'FANIN merge-conductor' "$CLOG" 2>/dev/null; }
fanin_alerts() { grep -F 'FANIN' "$T/c-alerts.txt"; }

# C1 — a healthy tick: 4 PRs, one a draft.
ctick
L=$(fanin_lines)
[ "$(grep -c . <<<"$L")" = 1 ] && grep -q 'FANIN merge-conductor example-org/demo-os: enumerated 4 accounted 4 (' <<<"$L" \
  && ok || bad "C1: one tick = exactly one 'FANIN merge-conductor example-org/demo-os: enumerated 4 accounted 4' line (got: ${L:-none}; stderr: $(tail -3 "$T/tick.err"))"
grep -q 'skipped:draft 1' <<<"$L" && ok || bad "C1: the draft #16 is accounted skipped:draft (got: $L)"
# ...and the UNVERIFIABLE early return is accounted with its reason
M=$(wc -l < "$CLOG"); ctick fail
L=$(tail -n +"$((M+1))" "$CLOG" | grep -F 'FANIN merge-conductor')
grep -q 'enumerated 4 accounted 4 (' <<<"$L" && grep -q 'skipped:unverifiable 1' <<<"$L" \
  && ok || bad "C1: an UNVERIFIABLE row is accounted skipped:unverifiable (got: ${L:-none})"

# C2 — no alert on a healthy tick; nothing at all on an empty one.
[ -z "$(fanin_alerts)" ] && ok || bad "C2: a healthy tick sends no FANIN alert: $(fanin_alerts)"
[ ! -e "$T/h/logs/ALERTS.log" ] || ! grep -q FANIN "$T/h/logs/ALERTS.log" && ok || bad "C2: ALERTS.log has no FANIN line"
N=$(fanin_lines | grep -c .); : > "$T/empty"; ctick; rm -f "$T/empty"
[ "$(fanin_lines | grep -c .)" = "$N" ] && ok || bad "C2: an empty open list writes no FANIN line"
[ -z "$(find "$T/h/state/fanin" -type f 2>/dev/null)" ] && ok || bad "C2: no ledger outlives a finished tick: $(find "$T/h/state/fanin" -type f)"

# C3 — the tick is killed inside #13's worker; the next tick names what never
# came back.
: > "$T/kill13"; ctick; rm -f "$T/kill13"
[ -s "$T/killed.txt" ] && ok || bad "C3: setup — the stub never killed the tick during #13's worker"
[ -z "$(fanin_alerts)" ] && ok || bad "C3: the killed tick itself sends nothing: $(fanin_alerts)"
# Wait (bounded) until the killed tick's ledger pid is dead or a zombie, the
# same definition fanin_begin uses (BH-2247), before the next tick looks at it.
c3_dead() { local s; kill -0 "$1" 2>/dev/null || return 0
  s=$(cat "/proc/$1/stat" 2>/dev/null) || return 0; s=${s##*) }
  case "${s%% *}" in Z|X) return 0 ;; esac; return 1; }
C3L=$(find "$T/h/state/fanin/merge-conductor" -name 'example-org_demo-os.*' -type f 2>/dev/null | head -1)
if [ -z "$C3L" ]; then
  bad "C3: setup — the killed tick left no ledger under state/fanin/merge-conductor"
else
  C3P="${C3L##*.}"; i=0
  while ! c3_dead "$C3P" && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i+1)); done
  c3_dead "$C3P" && ok || bad "C3: setup — the killed tick's ledger pid $C3P still running after 10s"
fi
ctick
A=$(fanin_alerts)
grep -q 'ALERT FANIN merge-conductor example-org/demo-os: enumerated 4 accounted 2 missing: example-org/demo-os#13 example-org/demo-os#16 (run died before fan-in)' <<<"$A" \
  && ok || bad "C3: the next tick alerts the dead tick's missing PRs (got: ${A:-none})"
[ "$(printf '%s\n' "$A" | grep -c .)" = 1 ] && ok || bad "C3: exactly one FANIN alert (got: $A)"
ctick
[ "$(fanin_alerts | grep -c .)" = 1 ] && ok || bad "C3: the dead tick is reported once, not every tick (got: $(fanin_alerts))"
[ ! -s "$T/gh-writes.txt" ] && ok || bad "C: an observe tick used a write verb: $(cat "$T/gh-writes.txt")"

# =============================================================================
# R. reconcile-prs, driven
# =============================================================================
unset -f gh   # the list bridge is the conductor fixture's; reconcile's stub answers REST itself
H="$T/r"
mkdir -p "$H/bin/lib" "$H/logs" "$H/locks" "$H/env" "$H/builds" "$T/rbin" "$T/pr" || exit 1
cp "$DIR/bin/reconcile-prs.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" "$H/bin/" || exit 1
cp "$DIR/bin/lib/merge-conductor-lib.sh" "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/fanin.sh" \
   "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$DIR/bin/lib/gh-rest-etag.sh" "$H/bin/lib/" || exit 1
mkdir -p "$H/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$H/bin/lib/mc/" || exit 1
. "$(dirname "$0")/lib/reconcile-fixture.sh" || exit 1
rcfx_arm "$H" "$DIR" || exit 1
cat > "$H/fleet.conf" <<'EOF'
project-1   Example/project-1       https://project-1.example  /api/board 2 box-a
noslug-fixture     -                         https://noslug.example    /api/board 2 box-b
EOF
printf 'CONSOLE_URL=https://console.example\nHARNESS_SECRET=shh\n' > "$H/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/rbin/flock"; chmod +x "$T/rbin/flock"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/r-alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
# The console's unmerged list is $T/console.json.
cat > "$T/rbin/curl" <<EOF
#!/bin/bash
case "\${!#}" in
  *"/api/builds/unmerged") cat "$T/console.json" ;;
  *) printf '{"ok":true}\n' ;;
esac
exit 0
EOF
chmod +x "$T/rbin/curl"
# GitHub: a list page fails (so every row takes the lane's single per-PR read);
# pulls/<n> answers $T/pr/<n>, or a 500.
cat > "$T/rbin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/r-gh.txt"
case "\$*" in
  *"pulls?"*) printf 'HTTP/2.0 500 Error\r\n\r\n{"message":"boom"}' ;;
  *"/pulls/"*) a="\$*"; n=\${a##*/pulls/}; n=\${n%% *}
    if [ -f "$T/pr/\$n" ]; then printf 'HTTP/2.0 200 OK\r\n\r\n'; cat "$T/pr/\$n"
    else printf 'HTTP/2.0 500 Error\r\n\r\n{"message":"boom"}'; fi ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/rbin/gh"
OLD=2026-09-01T00:00:00Z; NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '{"state":"closed","closed_at":"%s","merged_at":"%s","merge_commit_sha":"deadbeef"}' "$OLD" "$OLD" > "$T/pr/1"
printf '{"state":"closed","closed_at":"%s","merged_at":null,"merge_commit_sha":null}' "$OLD" > "$T/pr/2"
printf '{"state":"open","closed_at":null,"merged_at":null,"merge_commit_sha":null}' > "$T/pr/3"
printf '{"state":"closed","closed_at":"%s","merged_at":null,"merge_commit_sha":null}' "$NOW" > "$T/pr/5"
cp "$T/pr/1" "$T/pr/6"; cp "$T/pr/1" "$T/pr/7"
RLOG="$H/logs/reconcile.log"
rtick() { # rtick [script]
  ( cd "$T" && printf '%s\n' "--- tick" >> "$T/r-gh.txt" && PATH="$T/rbin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
      bash "$H/bin/${1:-reconcile-prs.sh}" >/dev/null 2>"$T/r.err" ) || true
}
: > "$T/r-alerts.txt"
cat > "$T/console.json" <<'EOF'
{"builds":[{"bkey":"project-1-TK-1-202609240001","pr_url":"https://github.com/Example/project-1/pull/1"},
           {"bkey":"project-1-TK-2-202609240002","pr_url":"https://github.com/Example/project-1/pull/2"},
           {"bkey":"project-1-TK-3-202609240003","pr_url":"https://github.com/Example/project-1/pull/3"},
           {"bkey":"project-1-TK-9-202609240009","pr_url":""},
           {"bkey":"project-1-TK-4-202609240004","pr_url":"https://github.com/Example/project-1/pull/4"},
           {"bkey":"project-1-TK-5-202609240005","pr_url":"https://github.com/Example/project-1/pull/5"},
           {"bkey":"stranger-XX-6-202609240006","pr_url":"https://github.com/Example/stranger/pull/6"},
           {"bkey":"noslug-fixture-TK-7-202609240007","pr_url":"https://github.com/Example/noslug/pull/7"}]}
EOF
rfanin() { grep -F 'FANIN reconcile-prs' "$RLOG" 2>/dev/null; }

# R1 + R4 — one line; every row accounted with its outcome.
rtick
L=$(rfanin)
[ "$(grep -c . <<<"$L")" = 1 ] && grep -q 'FANIN reconcile-prs fleet: enumerated 8 accounted 8 (' <<<"$L" \
  && ok || bad "R1: exactly one 'FANIN reconcile-prs fleet: enumerated 8 accounted 8' line (got: ${L:-none}; stderr: $(tail -3 "$T/r.err"))"
for o in 'merged 1' 'closed 1' 'skipped:open 1' 'skipped:no-url 1' 'skipped:unread 1' 'skipped:closed-unsettled 1'; do
  grep -qF "$o" <<<"$L" && ok || bad "R1: outcome '$o' in the tally (got: $L)"
done
grep -qF 'merged:no-project 1' <<<"$L" && ok || bad "R4: a merged PR naming no fleet project is accounted merged:no-project (got: $L)"
grep -qF 'merged:no-slug 1' <<<"$L" && ok || bad "R4: a merged PR whose project has no repo is accounted merged:no-slug (got: $L)"
grep -q 'reconciled 3 externally-merged PR(s), 1 closed unmerged' "$RLOG" \
  && ok || bad "R1: the lane's own work is unchanged (log: $(cat "$RLOG"))"

# R2 — no alert on the healthy tick; an empty list writes nothing.
[ ! -s "$T/r-alerts.txt" ] && ok || bad "R2: a healthy tick sends no alert: $(cat "$T/r-alerts.txt")"
N=$(rfanin | grep -c .); echo '{"builds":[]}' > "$T/console.json"; rtick
[ "$(rfanin | grep -c .)" = "$N" ] && ok || bad "R2: an empty console list writes no FANIN line"
[ ! -s "$T/r-alerts.txt" ] && ok || bad "R2: ...and no alert: $(cat "$T/r-alerts.txt")"

# R3 — an `exit` planted in the per-PR body: the tick dies with a ledger open,
# and the next tick names the rows it never reached.
cat > "$T/console.json" <<'EOF'
{"builds":[{"bkey":"project-1-TK-3-202609240003","pr_url":"https://github.com/Example/project-1/pull/3"},
           {"bkey":"project-1-TK-4-202609240004","pr_url":"https://github.com/Example/project-1/pull/4"},
           {"bkey":"project-1-TK-9-202609240009","pr_url":""}]}
EOF
awk '{print} /^rcr_one_pr\(\) \{/ {getline; print; print "  [ \"$BKEY\" = project-1-TK-4-202609240004 ] && exit 0"}' \
  "$H/bin/reconcile-prs.sh" > "$H/bin/reconcile-prs-mut.sh"
grep -q 'project-1-TK-4-202609240004 \] && exit 0' "$H/bin/reconcile-prs-mut.sh" \
  && ok || bad "R3: setup — the exit was not planted in rcr_one_pr"
N=$(rfanin | grep -c .); rtick reconcile-prs-mut.sh
[ "$(rfanin | grep -c .)" = "$N" ] && ok || bad "R3: the dying tick writes no summary"
rtick
A=$(grep -F 'FANIN' "$T/r-alerts.txt")
grep -qF 'ALERT FANIN reconcile-prs fleet: enumerated 3 accounted 1 missing: project-1-TK-4-202609240004 project-1-TK-9-202609240009 (run died before fan-in)' <<<"$A" \
  && ok || bad "R3: the next tick alerts the rows the dead tick never accounted (got: ${A:-none})"
[ "$(printf '%s\n' "$A" | grep -c .)" = 1 ] && ok || bad "R3: exactly one alert (got: $A)"
rtick
[ "$(grep -c FANIN "$T/r-alerts.txt")" = 1 ] && ok || bad "R3: reported once (got: $(cat "$T/r-alerts.txt"))"

echo "fanin.bh-186-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
