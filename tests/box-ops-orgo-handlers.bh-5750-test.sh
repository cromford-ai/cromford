#!/bin/bash
# tests/box-ops-orgo-handlers.bh-5750-test.sh — the Orgo handlers in run_op of
# bin/box-ops.sh (BH-5750 C2): a claimed box_commands_v2 row of type
# orgo_restart|orgo_stop|orgo_resize_quote|orgo_resize|orgo_retire runs
# `bin/box-ops.sh <verb> <id> ...` and posts ok/fail from its rc and its lines.
#
# Runs the REAL bin/box-ops.sh tick (no argument), bin/jobs-client.sh,
# bin/alert-line.sh and their libs in a scratch harness root. Stubbed:
# bin/lib/box-ops-orgo.sh (records its argv to $T/argv.log, prints the lines
# in $T/stub-out, returns $STUB_RC), curl (plays the jobs worker's claim and
# result routes), bin/box-name.sh and bin/hub-lease.sh (this box holds the hub
# lease, so it claims box='hub' rows). The stub's lines are copied from what
# bin/lib/box-ops-orgo.sh prints (resize dry run, COST refusal, stop, retire).
#   H0  BOX_OPS_ORGO_TIMEOUT_S not a positive int: ALERTS, exit 1, no claim
#   H1  resize quote: argv has no --apply; ok; detail starts with the price line
#   H1b quote with a string vcpus: refused bad args, stub not called
#   H2  resize with figure 12: argv has --apply --confirm-monthly-usd 12; NEXT before summary
#   H2b resize with figure 0: --apply, no --confirm-monthly-usd
#   H3  resize with no figure: stub not called, refused: no confirmed price
#   H4  apply rc 2 with a moved price (COST:): fail, detail has COST:
#   H4b quote rc 2 with a COST: line: ok
#   H4c rc 2 with no COST: line: fail refused: <summary>
#   H5  rc 0 + "already running": fail already running (lock held)
#   H5b rc 0 + a last line that is no summary: fail
#   H6  stop: detail has the NEXT: lift line; the handler makes no flag call
#   H7  rc 3: fail NEEDS PURCHASE
#   H8  rc 4: fail WAITING
#   H9  bad target (project-3;rm -rf /, hub): stub not called
#   H10 retire with BOX_OPS_REPO_ROOT unset / not a git checkout / the live harness: not configured
#   H11 restart/stop/retire argv carry --apply (and retire --root/--to/--ip/--delete)
#   H12 retire with delete "true" (a string): refused bad args
#   H13 rc 1 fail, rc 7 fail with the rc, timeout rc 124 "timed out after 1s"
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $*"; }

for f in "$DIR/bin/box-ops.sh" "$DIR/bin/lib/box-ops-orgo.sh"; do
  [ -f "$f" ] || { echo "FAIL: missing $f"; exit 1; }
done

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/locks" "$H/state" "$H/env" "$T/fakebin"
# The stub goes in FIRST: scratch_install_closure keeps a file already there.
cat > "$H/bin/lib/box-ops-orgo.sh" <<'EOF'
box_ops_orgo() {
  printf '%s\n' "$*" >> "$STUB_DIR/argv.log"
  [ -f "$STUB_DIR/stub-out" ] && cat "$STUB_DIR/stub-out"
  [ -n "${STUB_SLEEP:-}" ] && sleep "$STUB_SLEEP"
  return "${STUB_RC:-0}"
}
EOF
for s in bin/box-ops.sh bin/jobs-client.sh bin/alert-line.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: closure install $s"; exit 1; }
done
: > "$H/env/global.env"
: > "$H/logs/ALERTS.log"
cat > "$H/bin/hub-lease.sh" <<'EOF'
#!/bin/bash
[ "${1:-}" = check ] || exit 2
exit 0
EOF
cat > "$H/bin/box-name.sh" <<'EOF'
#!/bin/bash
echo b1
EOF
chmod +x "$H/bin/hub-lease.sh" "$H/bin/box-name.sh"

# The worker, by path. A claim pops the next line of $T/queue.
cat > "$T/fakebin/curl" <<'EOF'
#!/bin/bash
method=GET; body=""; url=""; prev=""
for a in "$@"; do
  case "$prev" in -X) method=$a ;; --data-binary|-d) body=$a ;; esac
  case "$a" in http*://*) url=$a ;; esac
  prev=$a
done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
path="/${url#*://*/}"; path="${path%%\?*}"
case "$path" in
  /api/box-commands/claim)
    printf '%s %s %s\n' "$method" "$path" "$body" >> "$STUB_DIR/requests.log"
    ans='{"command":null}'
    if [ -s "$STUB_DIR/queue" ]; then ans=$(head -1 "$STUB_DIR/queue"); sed -i 1d "$STUB_DIR/queue"; fi
    printf '%s\n%s' "$ans" 200 ;;
  /api/box-commands/*/result)
    printf '%s %s %s\n' "$method" "$path" "$body" >> "$STUB_DIR/requests.log"
    printf '%s\n%s' '{"ok":true}' 200 ;;
  *)
    printf '%s %s %s\n' "$method" "$path" "$body" >> "$STUB_DIR/other.log"
    printf '%s\n%s' '{}' 404 ;;
esac
EOF
chmod +x "$T/fakebin/curl"
export STUB_DIR="$T" PATH="$T/fakebin:$PATH" HARNESS="$H" HARNESS_SECRET=tok-fixture-secret
export JOBS_URL=https://jobs.fixture JOBS_RETRIES=0

# A git checkout for retire --root, and a plain directory that is not one.
RR="$T/retire-root"; mkdir -p "$RR" "$T/plain-dir"
git -C "$RR" init -q -b main && printf 'pa acme/pa - - 1 node-oldbox 192.0.2.5\n' > "$RR/fleet.conf" \
  || { echo "FAIL: git fixture"; exit 1; }

row() { # row <type> <target> <args-json>
  jq -nc --arg t "$1" --arg tg "$2" --argjson a "$3" \
    '{command:{id:1, box:"hub", type:$t, target:$tg, args:$a, reason:"fixture", status:"claimed", claimed_by:"b1"}}'
}
reset() {
  rm -f "$T/requests.log" "$T/other.log" "$T/queue" "$T/argv.log" "$T/stub-out" "$H/logs/box-ops.log"
  unset STUB_RC STUB_SLEEP BOX_OPS_ORGO_TIMEOUT_S BOX_OPS_REPO_ROOT
}
out() { printf '%s\n' "$@" > "$T/stub-out"; }
run() { bash "$H/bin/box-ops.sh" > "$T/out" 2>&1; RC=$?; }
result() { grep ' /api/box-commands/1/result ' "$T/requests.log" 2>/dev/null | tail -1 | cut -d' ' -f3-; }
okv()    { result | jq -r '.ok'; }
detail() { result | jq -r '.detail'; }
argv()   { cat "$T/argv.log" 2>/dev/null; }
calls()  { if [ -f "$T/argv.log" ]; then wc -l < "$T/argv.log"; else echo 0; fi; }
expect() { # expect <case> <true|false> <detail substring>
  [ "$RC" = 0 ] && ok || bad "$1 rc=$RC ($(cat "$T/out"))"
  [ "$(okv)" = "$2" ] && ok || bad "$1 ok is not $2: $(result)"
  detail | grep -qF -- "$3" && ok || bad "$1 detail lacks '$3': $(detail)"
}
nocall() { [ "$(calls)" = 0 ] && ok || bad "$1: the box-ops-orgo stub ran: $(argv)"; }
starts() { case "$(detail)" in "$2"*) ok ;; *) bad "$1 detail does not start '$2': $(detail)" ;; esac; }

SUM_PLAN='box-ops: verb=resize box=project-3 orgo=o-fixture-1 result=PLAN dry run'
QUOTE_OUT=(
  'resize: project-3 4c/16gb/-gb -> 8c/16gb/-gb, delta $12/mo'
  'capacity: the pool fits 8c/16gb/-gb'
  'PLAN cost +$12/mo (now $69/mo, after $81/mo); --apply needs --confirm-monthly-usd 12'
  'PLAN drain ssh root@<tailnet-ip of node-project-3> /root/harness/bin/quiesce-for-resize.sh (expects SAFE_TO_RESIZE)'
  'PLAN PATCH /computers/o-fixture-1/resize {"cpu":8}'
  'PLAN verify the results array names cpu, then GET /computers/o-fixture-1 shows 8c/16gb/-gb'
  "$SUM_PLAN"
)

# ── H0 a bad timeout knob refuses before claiming ────────────────────────
for v in abc 0 -5; do
  reset; row orgo_restart project-3 '{}' > "$T/queue"; export BOX_OPS_ORGO_TIMEOUT_S="$v"
  A0=$(wc -l < "$H/logs/ALERTS.log"); run
  [ "$RC" = 1 ] && ok || bad "H0 $v rc=$RC"
  [ "$(wc -l < "$H/logs/ALERTS.log")" -gt "$A0" ] && tail -1 "$H/logs/ALERTS.log" | grep -qF BOX_OPS_ORGO_TIMEOUT_S && ok \
    || bad "H0 $v ALERTS: $(tail -1 "$H/logs/ALERTS.log")"
  grep -q ' /api/box-commands/claim ' "$T/requests.log" 2>/dev/null && bad "H0 $v claimed" || ok
  scratch_rm "$H/state/alert-line-sent"
done

# ── H1 resize quote: no --apply, ok, the price line first ────────────────
reset; row orgo_resize_quote project-3 '{"account":"fixture-acct","vcpus":8}' > "$T/queue"
out "${QUOTE_OUT[@]}"; run
expect H1 true "$SUM_PLAN"
[ "$(argv)" = "resize project-3 --account fixture-acct --vcpus 8" ] && ok || bad "H1 argv: $(argv)"
grep -q -- '--apply' <<<"$(argv)" && bad "H1 the quote ran with --apply" || ok
starts H1 'PLAN cost +$12/mo'
detail | grep -qF 'capacity: the pool fits 8c/16gb/-gb' && ok || bad "H1 detail lacks capacity: $(detail)"
grep -qF 'PLAN drain' <<<"$(detail)" && bad "H1 detail carries PLAN step lines: $(detail)" || ok
case "$(detail)" in *" | $SUM_PLAN") ok ;; *) bad "H1 summary is not last: $(detail)" ;; esac

# ── H1b a string spec is bad args, nothing runs ──────────────────────────
for a in '{"account":"fixture-acct","vcpus":"8"}' '{"account":"fixture-acct"}' '{"vcpus":8}' \
         '{"account":"bad acct","vcpus":8}' '{"account":"fixture-acct","mem_gb":0}'; do
  reset; row orgo_resize_quote project-3 "$a" > "$T/queue"; out "${QUOTE_OUT[@]}"; run
  expect "H1b $a" false "refused: bad args"; nocall "H1b $a"
done

# ── H2 resize with figure 12 ─────────────────────────────────────────────
SUM_OK='box-ops: verb=resize box=project-3 orgo=o-fixture-1 result=OK 8c/16gb/-gb'
NEXT_W='NEXT: watchers on project-3 are paused by quiesce (flags/paused-* on the box); lift them when the box is back'
reset; row orgo_resize project-3 '{"account":"fixture-acct","vcpus":8,"quote_id":41,"confirm_monthly_usd":"12"}' > "$T/queue"
out 'resize: project-3 4c/16gb/-gb -> 8c/16gb/-gb, delta $12/mo' 'capacity: the pool fits 8c/16gb/-gb' \
    'drain: SAFE_TO_RESIZE' "$NEXT_W" "$SUM_OK"
run
expect H2 true "$SUM_OK"
[ "$(argv)" = "resize project-3 --account fixture-acct --vcpus 8 --apply --confirm-monthly-usd 12" ] && ok || bad "H2 argv: $(argv)"
[ "$(detail)" = "capacity: the pool fits 8c/16gb/-gb | $NEXT_W | $SUM_OK" ] && ok || bad "H2 detail order: $(detail)"

# ── H2b figure 0 (a shrink): --apply, no figure flag ─────────────────────
reset; row orgo_resize project-3 '{"account":"fixture-acct","mem_gb":8,"quote_id":42,"confirm_monthly_usd":"0"}' > "$T/queue"
out "$NEXT_W" 'box-ops: verb=resize box=project-3 orgo=o-fixture-1 result=OK 4c/8gb/-gb'; run
expect H2b true 'result=OK'
[ "$(argv)" = "resize project-3 --account fixture-acct --mem-gb 8 --apply" ] && ok || bad "H2b argv: $(argv)"

# ── H3 no figure: nothing runs ───────────────────────────────────────────
for a in '{"account":"fixture-acct","vcpus":8,"quote_id":41}' \
         '{"account":"fixture-acct","vcpus":8,"quote_id":41,"confirm_monthly_usd":""}'; do
  reset; row orgo_resize project-3 "$a" > "$T/queue"; out "$SUM_OK"; run
  expect "H3 $a" false "refused: no confirmed price"; nocall "H3 $a"
done
for a in '{"account":"fixture-acct","vcpus":8,"quote_id":41,"confirm_monthly_usd":12}' \
         '{"account":"fixture-acct","vcpus":8,"quote_id":41,"confirm_monthly_usd":"12 "}'; do
  reset; row orgo_resize project-3 "$a" > "$T/queue"; out "$SUM_OK"; run
  expect "H3 $a" false "refused: bad args"; nocall "H3 $a"
done

# ── H4 a moved price on apply: rc 2 with COST: is a fail ─────────────────
COST='COST: resize project-3 +$15/mo (now $69/mo, after $84/mo) — re-run with --confirm-monthly-usd 15'
SUM_REF='box-ops: verb=resize box=project-3 orgo=o-fixture-1 result=REFUSED cost not confirmed'
reset; row orgo_resize project-3 '{"account":"fixture-acct","vcpus":8,"quote_id":41,"confirm_monthly_usd":"12"}' > "$T/queue"
out 'resize: project-3 4c/16gb/-gb -> 8c/16gb/-gb, delta $15/mo' 'capacity: the pool fits 8c/16gb/-gb' "$COST" "$SUM_REF"
STUB_RC=2 run
expect H4 false 'COST: resize project-3 +$15/mo'
starts H4 'refused: COST: resize project-3 +$15/mo'
[ "$(calls)" = 1 ] && ok || bad "H4 calls=$(calls)"

# ── H4b a quote that answers rc 2 with a COST: line is ok ────────────────
reset; row orgo_resize_quote project-3 '{"account":"fixture-acct","vcpus":8}' > "$T/queue"
out "$COST" "$SUM_REF"; STUB_RC=2 run
expect H4b true 'COST: resize project-3 +$15/mo'
starts H4b 'COST: resize project-3 +$15/mo'

# ── H4c rc 2 with no COST: line is refused with the summary ──────────────
reset; row orgo_resize_quote project-3 '{"account":"fixture-acct","vcpus":8}' > "$T/queue"
out 'box-ops: price vcpu not recorded in catalog/orgo-plans.json' \
    'box-ops: verb=resize box=project-3 orgo=o-fixture-1 result=REFUSED price vcpu not recorded in catalog/orgo-plans.json'
STUB_RC=2 run
expect H4c false 'result=REFUSED price vcpu not recorded'
starts H4c 'refused: '

# ── H5 rc 0 + already running is NOT ok (D9) ─────────────────────────────
reset; row orgo_resize project-3 '{"account":"fixture-acct","vcpus":8,"quote_id":41,"confirm_monthly_usd":"12"}' > "$T/queue"
out 'box-ops: project-3 already running'; run
expect H5 false 'already running (lock held)'

# ── H5b rc 0 with no summary line is not ok ──────────────────────────────
reset; row orgo_restart project-3 '{}' > "$T/queue"
out 'PLAN restart POST /computers/o-fixture-1/restart'; run
expect H5b false 'PLAN restart'

# ── H6 stop: NEXT: lift line, and the handler lifts nothing ──────────────
NEXT_L='NEXT: lift with bin/jobs-client.sh flag-set paused-project-3 off'
reset; row orgo_stop project-3 '{}' > "$T/queue"
out 'stop: paused-project-3 on' "$NEXT_L" 'box-ops: verb=stop box=project-3 orgo=o-fixture-1 result=OK stopped'; run
expect H6 true "$NEXT_L"
[ "$(argv)" = "stop project-3 --apply" ] && ok || bad "H6 argv: $(argv)"
{ grep -i 'flag' "$T/other.log" "$T/requests.log" 2>/dev/null | grep -v '/api/box-commands/' | grep -q .; } \
  && bad "H6 the handler made a flag call: $(cat "$T/other.log")" || ok
grep -q 'paused-project-3' "$T/other.log" 2>/dev/null && bad "H6 a paused-project-3 request was made" || ok

# ── H7 rc 3 NEEDS PURCHASE ───────────────────────────────────────────────
reset; row orgo_resize_quote project-3 '{"account":"fixture-acct","mem_gb":32}' > "$T/queue"
out 'resize: project-3 4c/16gb/-gb -> 4c/32gb/-gb, delta $64/mo' 'NEEDS PURCHASE: ram-gb 5 $20/mo' \
    'box-ops: verb=resize box=project-3 orgo=o-fixture-1 result=REFUSED needs purchase'
STUB_RC=3 run
expect H7 false 'result=REFUSED needs purchase'
starts H7 'NEEDS PURCHASE: ram-gb 5 $20/mo'

# ── H8 rc 4 WAITING ──────────────────────────────────────────────────────
reset; export BOX_OPS_REPO_ROOT="$RR"; row orgo_retire oldbox '{"delete":true}' > "$T/queue"
out 'WAITING: origin/main still has the box (fleet.conf names node-oldbox); merge the retire PR, then re-run' \
    'box-ops: verb=retire box=oldbox orgo=- result=WAITING fleet.conf names node-oldbox'
STUB_RC=4 run
expect H8 false 'result=WAITING'
starts H8 'WAITING: origin/main still has the box'

# ── H9 a bad target never reaches the stub ───────────────────────────────
for tg in 'project-3;rm -rf /' hub 'project-3' '' 'a23456789012345678901234567890123'; do
  for ty in orgo_restart orgo_stop orgo_resize_quote; do
    reset; row "$ty" "$tg" '{"account":"fixture-acct","vcpus":8}' > "$T/queue"; out "$SUM_PLAN"; run
    expect "H9 $ty '$tg'" false "refused: bad target"; nocall "H9 $ty '$tg'"
  done
done

# ── H10 retire without a configured checkout runs nothing ────────────────
for r in unset "$T/plain-dir" "$T/missing-dir" "$H"; do
  reset; [ "$r" = unset ] || export BOX_OPS_REPO_ROOT="$r"
  row orgo_retire oldbox '{"to":"newbox","delete":false}' > "$T/queue"
  out 'box-ops: verb=retire box=oldbox orgo=- result=OK retired in the working tree'; run
  expect "H10 $r" false "not configured: BOX_OPS_REPO_ROOT"; nocall "H10 $r"
done
# the live harness root is refused even when it is a git checkout
git -C "$H" init -q -b main 2>/dev/null
reset; export BOX_OPS_REPO_ROOT="$H"; row orgo_retire oldbox '{"delete":false}' > "$T/queue"
out 'box-ops: verb=retire box=oldbox orgo=- result=OK retired in the working tree'; run
expect "H10 harness-git" false "not configured: BOX_OPS_REPO_ROOT"; nocall "H10 harness-git"
scratch_rm "$H/.git"

# ── H11 restart/stop/retire run with --apply ─────────────────────────────
reset; row orgo_restart project-3 '{"account":"fixture-acct"}' > "$T/queue"
out 'box-ops: verb=restart box=project-3 orgo=o-fixture-1 result=OK running'; run
expect "H11 restart" true 'result=OK running'
[ "$(argv)" = "restart project-3 --account fixture-acct --apply" ] && ok || bad "H11 restart argv: $(argv)"

reset; row orgo_stop project-3 '{"account":"fixture-acct"}' > "$T/queue"
out 'box-ops: verb=stop box=project-3 orgo=o-fixture-1 result=OK stopped'; run
expect "H11 stop" true 'result=OK stopped'
[ "$(argv)" = "stop project-3 --account fixture-acct --apply" ] && ok || bad "H11 stop argv: $(argv)"

SUM_RET='box-ops: verb=retire box=oldbox orgo=- result=OK retired in the working tree'
reset; export BOX_OPS_REPO_ROOT="$RR"
row orgo_retire oldbox '{"to":"newbox","ip":"192.0.2.5","delete":false}' > "$T/queue"
out 'NEXT: commit, open the PR, merge, then re-run with --delete --apply' "$SUM_RET"; run
expect "H11 retire" true "$SUM_RET"
[ "$(argv)" = "retire oldbox --root $RR --to newbox --ip 192.0.2.5 --apply" ] && ok || bad "H11 retire argv: $(argv)"
[ "$(detail)" = "NEXT: commit, open the PR, merge, then re-run with --delete --apply | $SUM_RET" ] && ok \
  || bad "H11 retire detail: $(detail)"

reset; export BOX_OPS_REPO_ROOT="$RR"; row orgo_retire oldbox '{"delete":true}' > "$T/queue"
out 'box-ops: verb=retire box=oldbox orgo=o-fixture-9 result=OK deleted'; run
expect "H11 retire delete" true 'result=OK deleted'
[ "$(argv)" = "retire oldbox --root $RR --apply --delete" ] && ok || bad "H11 retire delete argv: $(argv)"

# ── H12 bad retire args ──────────────────────────────────────────────────
for a in '{"delete":"true"}' '{"to":"oldbox","delete":false}' '{"to":"hub","delete":false}' \
         '{"ip":"192.0.2.999","delete":false}' '{"ip":"192.0.2.5;id","delete":false}'; do
  reset; export BOX_OPS_REPO_ROOT="$RR"; row orgo_retire oldbox "$a" > "$T/queue"; out "$SUM_RET"; run
  expect "H12 $a" false "refused: bad args"; nocall "H12 $a"
done

# ── H13 rc 1, an unknown rc, a timeout ───────────────────────────────────
reset; row orgo_restart project-3 '{}' > "$T/queue"
out 'box-ops: restart HTTP 500' 'box-ops: verb=restart box=project-3 orgo=o-fixture-1 result=FAIL restart HTTP 500'
STUB_RC=1 run
expect "H13 rc1" false 'result=FAIL restart HTTP 500'

reset; row orgo_restart project-3 '{}' > "$T/queue"; out 'something odd'; STUB_RC=7 run
expect "H13 rc7" false 'rc=7'

reset; row orgo_restart project-3 '{}' > "$T/queue"; out 'box-ops: verb=restart box=project-3 orgo=o-fixture-1 result=OK running'
export BOX_OPS_ORGO_TIMEOUT_S=1; STUB_SLEEP=5 run
expect "H13 timeout" false 'timed out after 1s'

echo "box-ops-orgo-handlers.bh-5750: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
