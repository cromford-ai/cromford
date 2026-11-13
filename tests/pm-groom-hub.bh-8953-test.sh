#!/bin/bash
# tests/pm-groom-hub.bh-8953-test.sh — BH-8953: the Telegram bot token lives on
# the hub only, so the weekly pm-groom brief runs on the hub, no project box
# renders a pm-groom line, and bin/archie-tg-send.sh on a box with no token
# prints one line that names the cause and the fix.
#
# WHAT RUNS REAL. bin/render-cron.sh over this checkout (REGISTRY_SOURCE=file)
# and the SHIPPED bin/archie-tg-send.sh from a scratch harness ($H: the script's
# closure, scratch_install_closure). ARCHIE_FIXTURE=$T/fx.sh is the jobs ledger (no row) and the
# chat target. $T/fakebin/curl is first on PATH: every call is logged to
# $T/net.log, and a `-K -` call answers a fake Telegram ok. Nothing here reaches
# Telegram or the jobs worker.
#
# H1 hub renders 8 gated lines; B1-B3 no box renders one; A1 the caller audit;
# T1-T4 the no-token line; V1 the vendor-call budget.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pm-groom-hub.bh-8953-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "pm-groom-hub: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

LANE_FRAG="$DIR/cron/lanes/737-pm-groom.cron"
HUB_FRAG="$DIR/cron/boxes/hub.d/737-pm-groom.cron"
REG="$DIR/catalog/lanes.d/pm-groom.json"
# A hub render takes about 90 s on a 2-CPU box, so this suite does 3 (hub,
# project-6-os, small) and proves the other boxes with static checks (B2, B3).
RENDERS=0
render() { RENDERS=$((RENDERS+1)); env HARNESS_TEST_SANDBOX=1 REGISTRY_SOURCE=file "$DIR/bin/render-cron.sh" --root "$DIR" "$1" 2>"$T/render.err"; }
# An active pm-groom line: a schedule field first, then the script and a space.
# A comment, pm-groom.log in another lane's line and pm-flesh.sh do not match.
SCHED_RE='^[0-9*].*pm-groom\.sh '
sched() { grep -qE "$SCHED_RE" <<<"$1"; }
# S1/S2 call sched directly, not through check's eval: a cron sample string
# handed to eval reads to the CI tracer as a redirect to /root/harness/logs.
if sched "8 11 * * 1 /root/harness/bin/hub-lease.sh check && /root/harness/bin/pm-groom.sh project-4 >> /root/harness/logs/pm-groom.log 2>&1"; then ok; else bad "S1 a hub-lease line matches"; fi
if sched "* * * * * /x/pm-groom.sh x"; then ok; else bad "S1 a star line matches"; fi
if ! sched "# Monday 11:0x UTC: bin/pm-groom.sh <project> writes the brief"; then ok; else bad "S2 a comment line does not match"; fi
if ! sched "0 3 * * * /root/harness/bin/pm-flesh.sh x >> /root/harness/logs/pm-flesh.log 2>&1"; then ok; else bad "S2 pm-flesh.sh does not match"; fi
if ! sched "5 * * * * /root/harness/bin/other.sh >> /root/harness/logs/pm-groom.log 2>&1"; then ok; else bad "S2 another lane logging to pm-groom.log does not match"; fi
check "S2 a blank line does not match" '! sched ""'

# ═════ H1: the hub renders one gated line per project ═════════════════════════
render hub > "$T/hub.cron"; eq "H1 render hub rc" "$?" 0
eq "H1 hub has 8 pm-groom lines" "$(grep -cE "$SCHED_RE" "$T/hub.cron")" 8
for pair in "8 project-4" "2 project-1" "4 project-2" "6 project-3" "5 project-9" \
  "9 project-5" "1 project-8" "1 project-6-os"; do
  read -r cmin cproj <<<"$pair"
  want="$cmin 11 * * 1 /root/harness/bin/hub-lease.sh check && /root/harness/bin/pm-groom.sh $cproj >> /root/harness/logs/pm-groom.log 2>&1"
  # In a hub-lanes block: the lease decides which box fires it.
  got=$(awk -v w="$want" '/^# BEGIN hub-lanes$/{b=1; next} /^# END hub-lanes$/{b=0; next} $0==w{print (b ? "in" : "out")}' "$T/hub.cron")
  eq "H1 hub line for $cproj at minute $cmin, inside hub-lanes" "$got" in
done

# ═════ B1-B3: no project box renders one ══════════════════════════════════════
# B1: the 2 boxes the ticket names, through the real renderer.
for b in project-6-os small; do
  render "$b" > "$T/box.cron"; rrc=$?
  eq "B1 render $b rc" "$rrc" 0
  eq "B1 $b has no active pm-groom line" "$(grep -cE "$SCHED_RE" "$T/box.cron")" 0
done
# Db mode: the D1 lane_boxes rows still list the 8 boxes, so they get the lane
# fragment's DEFAULT section. It must hold no schedule line and no box variant.
eq "B2 the lane fragment has no '# @box' section" "$(grep -c '^# @box ' "$LANE_FRAG")" 0
eq "B2 the lane fragment has no schedule line" "$(grep -cE '^[0-9*@]' "$LANE_FRAG")" 0
check "B2 the lane fragment points at the hub fragment" 'grep -qF "cron/boxes/hub.d/737-pm-groom.cron" "$LANE_FRAG"'
eq "B3 pm-groom .boxes" "$(jq -c .boxes "$REG")" '["hub"]'
# B3: a box gets lane lines only from cron/lanes/*.cron and its own
# cron/boxes/<box>.d/ fragments. Only the hub fragment may schedule pm-groom.
stray=$(grep -lE "$SCHED_RE" "$DIR"/cron/lanes/*.cron "$DIR"/cron/boxes/*.d/*.cron 2>/dev/null \
  | grep -vF "$DIR/cron/boxes/hub.d/" || true)
eq "B3 no fragment outside hub.d schedules pm-groom" "$stray" ""
check "B3 the hub fragment schedules pm-groom" 'grep -qE "$SCHED_RE" "$HUB_FRAG"'

# ═════ A1: every archie-tg-send caller lane runs on the hub only ══════════════
hub_only() { [ "$(jq -c .boxes "$1" 2>/dev/null)" = '["hub"]' ]; }
for l in archie archie-fm-report archie-fm-watch archie-learn archie-research daily-digest \
  lesson-measure archie-overlook unblock-metrics pm-groom; do
  check "A1 lane $l runs on the hub only" 'hub_only "$DIR/catalog/lanes.d/$l.json"'
done
jq '.boxes = ["hub","project-6-os"]' "$DIR/catalog/lanes.d/archie.json" > "$T/archie-near.json"
check "A1 near miss: a lane with a box beside the hub fails the check" '! hub_only "$T/archie-near.json"'

# ═════ T1-T4: archie-tg-send with no token ════════════════════════════════════
H="$T/h"
mkdir -p "$H/env" "$H/logs" "$T/fakebin"
scratch_install_closure bin/archie-tg-send.sh "$H" >/dev/null || { echo "pm-groom-hub: closure install failed"; exit 1; }
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$FXT/net.log"
for a in "$@"; do [ "$a" = -K ] && { cat >/dev/null; printf '{"ok":true,"result":{"message_id":7}}'; exit 0; }; done
exit 7
SH
chmod +x "$T/fakebin/curl"
cat > "$T/fx.sh" <<'SH'
job_ledger_get() { return 2; }
job_ledger_put() { printf '%s\n' "$*" >> "$FXT/ledger.log"; return 0; }
lane_knob() { [ "$2" = ARCHIE_TELEGRAM_TARGET ] && printf '100000000'; }
SH
send() { # send <akey> [env...]: the shipped transport, stderr to $T/err
  local k="$1"; shift
  env HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" HARNESS_TEST_SANDBOX=1 ARCHIE_FIXTURE="$T/fx.sh" \
    LANE_GATE_DISABLE=1 "$@" bash "$H/bin/archie-tg-send.sh" "$k" hello > "$T/out" 2> "$T/err"
}
unset TELEGRAM_BOT_TOKEN ARCHIE_TELEGRAM_TARGET LANE_ALERT_DM_CHAT 2>/dev/null || true
: > "$H/env/global.env"          # a project box: no TELEGRAM_BOT_TOKEN line
K1="bh8953-$$-1"; K2="bh8953-$$-2"
send "$K1"; eq "T1 no token: rc 2" "$?" 2
eq "T1 one stderr line" "$(wc -l < "$T/err")" 1
check "T1 stderr names the variable and the hub" 'grep -q "TELEGRAM_BOT_TOKEN" "$T/err" && grep -q "hub" "$T/err"'
check "T1 archie.log has the same cause line" '[ -s "$T/err" ] && grep -qF "$(cat "$T/err")" "$H/logs/archie.log"'
check "T1 archie.log has the chunks=0 rc=2 line" 'grep -q "tg $K1 chat=100000000 chunks=0 rc=2" "$H/logs/archie.log"'
check "T1 nothing written to the ledger" '[ ! -s "$T/ledger.log" ]'
eq "T2 one ALERTS line names the token" "$(grep -c TELEGRAM_BOT_TOKEN "$H/logs/ALERTS.log" 2>/dev/null)" 1
send "$K2"; eq "T2 second send: rc 2" "$?" 2
check "T2 second send still prints the line" 'grep -q "TELEGRAM_BOT_TOKEN" "$T/err"'
eq "T2 second send adds no ALERTS line" "$(grep -c TELEGRAM_BOT_TOKEN "$H/logs/ALERTS.log" 2>/dev/null)" 1
check "T3 the text never reaches stderr or a log" '! grep -q hello "$T/err" "$H/logs/archie.log" "$H/logs/ALERTS.log"'
eq "V1 no-token sends made 0 network calls" "$(cat "$T/net.log" 2>/dev/null | wc -l)" 0
send "bh8953-$$-3" TELEGRAM_BOT_TOKEN=fixture-token; eq "T4 token set: rc 0" "$?" 0
check "T4 token set: nothing on stderr" '[ ! -s "$T/err" ]'
# V1: the only network call in this suite is T4's, and it went to the fake.
eq "V1 one curl call, the T4 fake" "$(cat "$T/net.log" 2>/dev/null | wc -l)" 1
check "V1 the T4 call read the url from stdin (-K -)" 'grep -q -- "-K -" "$T/net.log"'

echo "renders: $RENDERS"
echo "pm-groom-hub: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
