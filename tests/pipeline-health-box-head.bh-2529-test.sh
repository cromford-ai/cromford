#!/bin/bash
# tests/pipeline-health-box-head.bh-2529-test.sh — BH-2529 (goal-gap B15, file
# state -> DB state): the cost autohalt writes the pause ROW or pages that it
# could not, and the fleet checkout freshness check reads each remote box's
# harness HEAD from box_status instead of ssh-ing into the box.
#
# WHAT IS DRIVEN. bin/pipeline-health.sh's `cost budget` and `fleet checkout
# freshness` blocks, extracted VERBATIM by their own markers (the way every
# other pipeline-health suite drives it), against a scratch tree: the real
# bin/fleet-conf.sh and bin/box-for.sh, a scratch git origin whose commits carry
# pinned dates, and the real bin/lib/jobs/boxes.sh for the box_heads reader.
# ssh is a PATH shim that records every call; alert() and page_critical() record
# to files. Every assertion is on one of those artifacts.
#
# CASES
#   (BH-5526: the breaker's flag is the hold spend-hold-<p>, not paused-<p>.)
#   A1 no jobs client, project at 3x its $/PR budget: no ssh touches the hold
#      flag, no flags/spend-hold-<p> is written anywhere
#   A2 same: pages costhaltfail naming the unwritten hold row; no costhalt page,
#      no state/costhalt re-arm stamp (the next check tries again)
#   A3 zero-merge breaker, no client: the page says the hold row was NOT written
#   A4 flag_set present and answering: costhalt page, stamp written, no ssh
#   B0 box_heads: TSV of reporting boxes only; rc 1 when the worker cannot answer
#   B1-B8 (BH-7304) the inputs that used to alert or log for a REMOTE box
#      (behind main, a stale report, no row, box_heads failing, an orchestrator
#      sync, a box-id row): no driftfail: line and no log line, because
#      bin/fleet-version-check.sh owns remote boxes now
#   B6 no case in section 8 ever calls ssh
#   H1 the hub's own checkout behind origin: harness-sync.sh deploy runs once;
#      a heal that does not move HEAD gives one driftfail:local alert
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pipeline-health-box-head.bh-2529-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export T
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
for c in jq git awk; do command -v "$c" >/dev/null || { echo "$c missing — skipping"; exit 0; }; done

NOW=$(date +%s)
iso() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }   # iso <seconds-ago>

mkdir -p "$T/fakebin"
cat > "$T/fakebin/ssh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$T/calls.ssh"
exit 0
SH
chmod +x "$T/fakebin/ssh"

# ════════════════════════════════════════════════════════════════════════════
# A. the cost autohalt
# ════════════════════════════════════════════════════════════════════════════
awk '/^# >>> cost budget/{f=1;next} /^# <<< cost budget/{exit} f' "$DIR/bin/pipeline-health.sh" > "$T/cost.sh"
[ -s "$T/cost.sh" ] && ok || bad "could not extract the cost budget block — markers missing?"

C="$T/c"
cost_fixture() {
  scratch_rm "$C"; mkdir -p "$C/bin/lib" "$C/logs" "$C/flags" "$C/state/cost" "$C/env"
  # busy: $30/PR on 1 PR against a $10 budget (3x: the RATE autohalt).
  # zm:   $400/24h, nothing merged in 24h or 7d (the zero-merge breaker).
  cat > "$C/state/cost/summary.json" <<'JSON'
{"projects":{
  "busy":{"delivery_cost_24h":30,"merged_prs_24h":1,"cost_7d":30,"product_7d":0,"merged_prs_7d":1,"merged_prs_status":"ok"},
  "zm":{"delivery_cost_24h":400,"merged_prs_24h":0,"cost_7d":350,"product_7d":0,"merged_prs_7d":0,"merged_prs_status":"ok"}}}
JSON
  printf 'cost_budget_for() { echo "10 1"; }\ncost_budget_source() { echo fixture; }\n' > "$C/bin/lib/cost-budget.sh"
  echo 0 > "$C/state/costbreaker.stamp"
  # Both projects have a box AND a tailnet address: the old no-client branch
  # would ssh-touch the flag there, which is what A1 must not see.
  printf 'busy Acme/busy - - 1 box-a 10.0.0.1\nzm Acme/zm - - 2 box-b 10.0.0.2\n' > "$C/fleet.conf"
  cp "$DIR/bin/fleet-conf.sh" "$C/bin/"
  : > "$T/alerts.txt"; : > "$T/pages.txt"; rm -f "$T/calls.ssh"
}
drive_cost() { # drive_cost [flagset]   -> $T/alerts.txt, $T/pages.txt
  ( export H="$C" HARNESS="$C" NOW HENV="$C/env" FLEET_CONF="$C/fleet.conf" PATH="$T/fakebin:$PATH" \
           WITH_FLAGSET="${1:-}" JOBS_URL= HARNESS_JOBS_URL=
    bash -c 'STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
             alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
             page_critical() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/pages.txt"; }
             if [ -n "$WITH_FLAGSET" ]; then
               flag_set() { printf "%s %s\n" "$1" "$2" >> "$T/flagset.txt"; return 0; }
             fi
             . "$0"' "$T/cost.sh" ) >"$T/cost.out" 2>&1
}
line() { grep "^[0-9]*|$2|" "$T/$1.txt" 2>/dev/null | head -1; }

# A1 / A2 / A3 — no jobs client
cost_fixture; drive_cost
! grep -q 'spend-hold-\|paused-' "$T/calls.ssh" 2>/dev/null && ok \
  || bad "A1: with no client the halt must not ssh the hold flag anywhere (calls.ssh: $(cat "$T/calls.ssh" 2>/dev/null))"
[ ! -e "$C/flags/spend-hold-busy" ] && [ ! -e "$C/flags/spend-hold-zm" ] && ok \
  || bad "A1: with no client no flags/spend-hold-* file may be written (flags: $(ls "$C/flags"))"
L=$(line pages costhaltfail:busy)
[ -n "$L" ] && grep -q 'hold row could not be written' <<<"$L" && grep -q 'flag_set spend-hold-busy on' <<<"$L" && ok \
  || bad "A2: no client must page costhaltfail naming the unwritten hold row and how to hold it by hand (pages: $(cat "$T/pages.txt"))"
! grep -qi 'unreachable' <<<"$L" && ok || bad "A2: the fail page must not blame an unreachable box ($L)"
[ -z "$(line pages costhalt:busy)" ] && ok || bad "A2: a halt that wrote nothing must not page costhalt"
[ ! -e "$C/state/costhalt/busy" ] && ok || bad "A2: a failed halt must not stamp state/costhalt/busy (the next check retries)"
L=$(line pages costzeromerge:zm)
[ -n "$L" ] && grep -q 'hold row could NOT be written' <<<"$L" && ! grep -q 'NEW BUILDS HELD' <<<"$L" && ok \
  || bad "A3: the zero-merge page must say the hold row was NOT written (got: $L)"

# A4 — flag_set present
cost_fixture; rm -f "$T/flagset.txt"; drive_cost flagset
grep -qx 'spend-hold-busy on' "$T/flagset.txt" 2>/dev/null && ok || bad "A4: the halt must go through flag_set spend-hold-busy on"
[ -n "$(line pages costhalt:busy)" ] && [ -z "$(line pages costhaltfail:busy)" ] && ok \
  || bad "A4: a landed row pages costhalt, not costhaltfail ($(cat "$T/pages.txt"))"
[ -s "$C/state/costhalt/busy" ] && ok || bad "A4: a landed halt stamps state/costhalt/busy"
! grep -q 'spend-hold-\|paused-' "$T/calls.ssh" 2>/dev/null && ok || bad "A4: the client path must not ssh"

# ════════════════════════════════════════════════════════════════════════════
# B0. box_heads — the reader both consumers share
# ════════════════════════════════════════════════════════════════════════════
B0=$( bash -c '. "$1" || exit 9
  _jobs_req() { printf "%s" "{\"boxes\":[{\"box\":\"box-project-4-1\",\"harness_commit\":\"abc1234\",\"harness_reported_at\":\"2026-09-25T20:00:00Z\"},{\"box\":\"box-project-3-2\",\"harness_commit\":null,\"harness_reported_at\":null}]}"; }
  box_heads' _ "$DIR/bin/lib/jobs/boxes.sh" ); RC=$?
[ "$RC" = 0 ] && [ "$B0" = "$(printf 'box-project-4-1\tabc1234\t2026-09-25T20:00:00Z')" ] && ok \
  || bad "B0: box_heads must print one TSV line per box that reported a commit (rc $RC, got: $B0)"
B0=$( bash -c '. "$1" || exit 9; _jobs_req() { return 1; }; box_heads' _ "$DIR/bin/lib/jobs/boxes.sh" ); RC=$?
[ "$RC" = 1 ] && [ -z "$B0" ] && ok || bad "B0: an unanswered GET must be rc 1 with no output, not an empty list (rc $RC)"

# ════════════════════════════════════════════════════════════════════════════
# B. section 8 — fleet checkout freshness from box_status
# ════════════════════════════════════════════════════════════════════════════
awk '/^# >>> fleet checkout freshness/{f=1;next} /^# <<< fleet checkout freshness/{exit} f' \
  "$DIR/bin/pipeline-health.sh" > "$T/fresh.sh"
[ -s "$T/fresh.sh" ] && ok || bad "could not extract the fleet checkout freshness block — markers missing?"
# B6's static half: nothing in the block can reach a box over ssh.
[ -s "$T/fresh.sh" ] && ! grep -q 'ssh' "$T/fresh.sh" && ok || bad "B6: the freshness block must not mention ssh"

# Main's history, dated relative to NOW (grace 5400s):
#   C0 -6h -> C1 -5h (touches bin/c1.sh) -> M -10m, M merging a branch (off C1) dated -3h.
G="$T/g"; mkdir -p "$G"
git init -q --bare "$G/origin.git"
git init -q "$G/src"
gc() { # gc <seconds-ago> <msg> [git-commit args]
  local at="@$(( NOW - $1 ))"; local m="$2"; shift 2
  GIT_AUTHOR_DATE="$at" GIT_COMMITTER_DATE="$at" git -C "$G/src" -c user.name=t -c user.email=t@t \
    commit -q --allow-empty -m "$m" "$@"
}
git -C "$G/src" checkout -q -b main
gc 21600 C0; C0=$(git -C "$G/src" rev-parse --short HEAD)
# C1 changes a fleet path (BH-5247): a box behind it only on docs would be current.
mkdir -p "$G/src/bin"; echo c1 > "$G/src/bin/c1.sh"; git -C "$G/src" add bin/c1.sh
gc 18000 C1; C1=$(git -C "$G/src" rev-parse --short HEAD)
git -C "$G/src" checkout -q -b feat
gc 10800 F1
git -C "$G/src" checkout -q main
GIT_AUTHOR_DATE="@$(( NOW - 600 ))" GIT_COMMITTER_DATE="@$(( NOW - 600 ))" \
  git -C "$G/src" -c user.name=t -c user.email=t@t merge -q --no-ff -m M feat
M=$(git -C "$G/src" rev-parse --short HEAD)
git -C "$G/src" push -q "$G/origin.git" main
git clone -q -b main "$G/origin.git" "$G/co" 2>/dev/null
[ "$(git -C "$G/co" rev-parse --short HEAD)" = "$M" ] && ok || bad "fixture: the hub checkout must sit at origin tip"

F="$T/f"; mkdir -p "$F/bin" "$F/logs" "$F/flags" "$F/state"
cp "$DIR/bin/fleet-conf.sh" "$DIR/bin/box-for.sh" "$F/bin/"
mkdir -p "$F/bin/lib"; cp "$DIR/bin/lib/cron-lines.sh" "$F/bin/lib/"
scratch_install_closure bin/lib/fleet-paths.sh "$F" >/dev/null || exit 1
printf 'project-4 Acme/project-4 - - 1 box-project-4-1 10.0.0.4\nproject-3 Acme/project-3 - - 2 box-project-3-2 10.0.0.5\n' > "$F/fleet.conf"
# harness-sync must never run: the hub checkout is current in every case.
printf '#!/bin/bash\necho "$*" >> "%s/calls.sync"\n' "$T" > "$F/bin/harness-sync.sh"; chmod +x "$F/bin/harness-sync.sh"

heads() { # heads <project-4 sha> <project-4 seconds-ago> [<project-3 sha> <project-3 seconds-ago>]
  : > "$T/heads.tsv"
  [ -n "${1:-}" ] && printf 'box-project-4-1\t%s\t%s\n' "$1" "$(iso "$2")" >> "$T/heads.tsv"
  [ -n "${3:-}" ] && printf 'box-project-3-2\t%s\t%s\n' "$3" "$(iso "$4")" >> "$T/heads.tsv"
  return 0
}
: > "$T/calls.ssh"   # the cost block's own ceiling sweep above is not section 8
drive_fresh() { # drive_fresh [rows|fail|undef]
  : > "$T/alerts.txt"; : > "$F/logs/pipeline-health.log"
  ( export H="$F" HARNESS="$F" NOW FLEET_CONF="$F/fleet.conf" HARNESS_CHECKOUT="${FRESH_CO:-$G/co}" \
           PATH="$T/fakebin:$PATH" BH_MODE="${1:-rows}"
    bash -c 'STAMP() { date -u "+%Y-%m-%d %H:%M:%SZ"; }
             alert() { printf "%s|%s|%s\n" "$1" "$2" "$3" >> "$T/alerts.txt"; }
             case "$BH_MODE" in
               rows) box_heads() { cat "$T/heads.tsv"; } ;;
               fail) box_heads() { return 1; } ;;
             esac
             . "$0"' "$T/fresh.sh" ) >"$T/fresh.out" 2>&1
}
drift() { grep "|driftfail:$1:" "$T/alerts.txt" 2>/dev/null; }
logged() { grep -q "$1" "$F/logs/pipeline-health.log" 2>/dev/null; }

# BH-7304 (BH-7191.2): remote boxes are judged by bin/fleet-version-check.sh,
# so section 8 gives a remote box no driftfail: line and no log line, whatever
# its report says. Every B input below is the one that used to alert or log.
remote_silent() { # remote_silent <case>
  if grep -q '|driftfail:' "$T/alerts.txt" 2>/dev/null; then
    bad "$1: a remote box must give no driftfail: line (alerts: $(cat "$T/alerts.txt"))"
  else ok; fi
  if logged 'harness HEAD unknown' || logged 'non-fleet paths only'; then
    bad "$1: a remote box must give no log line ($(cat "$F/logs/pipeline-health.log"))"
  else ok; fi
}

# B1 both boxes at origin tip
heads "$M" 300 "$M" 300; drive_fresh; remote_silent B1

# B2 project-4 on C0, reported 5 min ago: lacks C1 (5h old). This used to alert once.
heads "$C0" 300 "$M" 300; drive_fresh; remote_silent B2

# B3 the same sha, reported 3h ago. This used to log 'harness HEAD unknown'.
heads "$C0" 10800 "$M" 300; drive_fresh; remote_silent B3

# B4 project-4 on C1 (the pre-merge sha) 5 min ago
heads "$C1" 300 "$M" 300; drive_fresh; remote_silent B4

# B4b the old grace knob changes nothing now
heads "$C0" 300 "$M" 300
( export HARNESS_HEAD_GRACE_S=36000; drive_fresh ); remote_silent B4b

# B5 no row for project-4; box_heads failing; box_heads not defined
heads "" 0 "$M" 300; drive_fresh; remote_silent "B5 no row"
drive_fresh fail; remote_silent "B5 box_heads fails"
drive_fresh undef; remote_silent "B5 no jobs client"

# B5b a row with a commit but no report time
printf 'box-project-4-1\t%s\t\n' "$C0" > "$T/heads.tsv"; drive_fresh; remote_silent B5b

# B7 orchestrator sync in progress and a box behind: no suppressed line either
heads "$C0" 300 "$M" 300; touch "$F/flags/orchestrator-sync-in-progress"; drive_fresh; remote_silent B7
logged 'driftfail:project-4 suppressed' && bad "B7: a remote box must give no suppressed line" || ok
rm -f "$F/flags/orchestrator-sync-in-progress"

# B8 box_status names the box its own way (box id "project-3", behind)
printf 'box-project-4-1\t%s\t%s\nproject-3\t%s\t%s\n' "$M" "$(iso 300)" "$C0" "$(iso 300)" > "$T/heads.tsv"; drive_fresh
remote_silent B8

# B6 — across every section-8 run above
[ ! -s "$T/calls.ssh" ] && ok || bad "B6: section 8 must never ssh (calls.ssh: $(cat "$T/calls.ssh"))"
[ ! -e "$T/calls.sync" ] && ok || bad "fixture: the hub is current, harness-sync must not run"

# H1 the hub's own checkout one commit behind origin: section 8 still runs
# the auto-heal (harness-sync.sh deploy, once). The stub does not move HEAD, so
# the heal fails and one driftfail:local alert names origin.
git clone -q -b main "$G/origin.git" "$G/co-behind" 2>/dev/null
git -C "$G/co-behind" reset -q --hard HEAD^
rm -f "$T/calls.sync"
FRESH_CO="$G/co-behind" drive_fresh
[ "$(cat "$T/calls.sync" 2>/dev/null)" = deploy ] && ok || bad "H1: a hub behind origin must run harness-sync.sh deploy once (calls: $(cat "$T/calls.sync" 2>/dev/null))"
[ "$(grep -c '|driftfail:' "$T/alerts.txt")" = 1 ] && grep -q "^5400|driftfail:local:$M|local checkout STILL at " "$T/alerts.txt" && ok \
  || bad "H1: a failed heal must give one driftfail:local alert (alerts: $(cat "$T/alerts.txt"))"
! grep -q 'auto-healed' "$F/logs/agent-rules.log" 2>/dev/null && ok || bad "H1: a heal that did not move HEAD must not log auto-healed"

echo "pipeline-health-box-head: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
