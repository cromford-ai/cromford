#!/bin/bash
# tests/gh-budget-memo.bh-8334-test.sh — BH-8334 (C0): bin/lib/gh-budget.sh
# makes at most one `gh api rate_limit` call per
# GH_BUDGET_RATE_LIMIT_MIN_INTERVAL_S per process (_ghb_rl_read).
#
#   M1  3x gh_budget_exhausted + 1x gh_budget_ratelimit_alert in one process,
#       no knob: 1 rate_limit call; the answers are what a fresh read says
#   M2  knob 0: 4 calls (every call reads, the old behavior)
#   M3  the clock moves past the interval: 2 calls; inside it: 1
#   M4  a failed read is not kept: the next call reads again, and a good read
#       after it is kept
#   M5  two processes: 2 calls (the memo is per process, the box cache file is
#       not reused by gh_budget_exhausted — gh-budget-test.sh section 12)
#   M6  gh_budget_refresh's fresh read shares the memo: refresh then exhausted
#       = 1 call; a non-integer knob reads as 60
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/gh-budget-memo.bh-8334-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1: expected '$3', got '$2'"; fi; }
command -v jq >/dev/null || { echo "SKIP: jq missing"; exit 0; }

mkdir -p "$T/bin/lib" "$T/fakebin" "$T/logs" "$T/state/gh-budget" "$T/flags"
scratch_install_closure bin/lib/gh-budget.sh "$T" >/dev/null || { echo "FAIL: closure install of bin/lib/gh-budget.sh"; exit 1; }
# The stub gh: every `api rate_limit` call is one line in $T/rl-calls. The
# answer is $T/rate_limit.json; $T/rl-down makes the call fail.
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
case "\$*" in
  "api rate_limit"*)
    echo x >> "$T/rl-calls"
    [ -f "$T/rl-down" ] && exit 1
    cat "$T/rate_limit.json"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$T/fakebin/gh"
jq -nc '{resources:{core:{limit:5000,remaining:0,reset:1757727802},graphql:{limit:5000,remaining:4000,reset:1757727802}}}' > "$T/rate_limit.json"

calls() { [ -f "$T/rl-calls" ] && grep -c . "$T/rl-calls" || echo 0; }
# drive <snippet> — one process with the lib sourced. CLOCK is the epoch
# _ghb_now answers; the snippet may change it.
drive() {
  rm -f "$T/rl-calls"
  ( export T PATH="$T/fakebin:$PATH" HARNESS="$T" GH_BUDGET_DB=0
    bash -c '
      set -uo pipefail
      . "$T/bin/lib/gh-budget.sh"
      CLOCK=1757725102
      _ghb_now() { echo "$CLOCK"; }
      eval "$0"' "$1" )
}
unset GH_BUDGET_RATE_LIMIT_MIN_INTERVAL_S

# ---- M1 -------------------------------------------------------------------
OUT=$(drive 'r=""; for i in 1 2 3; do gh_budget_exhausted; r="$r$?"; done; gh_budget_ratelimit_alert mlane "memo test"; echo "$r"')
eq "M1 3 exhausted answers are rc 0 (core 0)" "$OUT" 000
eq "M1 3 exhausted + 1 alert, no knob: 1 rate_limit call" "$(calls)" 1
grep -q '\[mlane\] GitHub API rate-limited: core 0/5000' "$T/logs/ALERTS.log" 2>/dev/null \
  && ok "M1 the alert used the memoized reading" || bad "M1 no alert line: $(cat "$T/logs/ALERTS.log" 2>/dev/null)"

# ---- M2 -------------------------------------------------------------------
rm -f "$T/flags"/*
GH_BUDGET_RATE_LIMIT_MIN_INTERVAL_S=0 drive 'for i in 1 2 3; do gh_budget_exhausted; done; gh_budget_ratelimit_alert mlane2 x' >/dev/null
eq "M2 knob 0: 4 calls" "$(calls)" 4

# ---- M3 -------------------------------------------------------------------
drive 'gh_budget_exhausted; CLOCK=$((CLOCK + 59)); gh_budget_exhausted' >/dev/null
eq "M3 59 s later: still 1 call" "$(calls)" 1
drive 'gh_budget_exhausted; CLOCK=$((CLOCK + 60)); gh_budget_exhausted' >/dev/null
eq "M3 60 s later: 2 calls" "$(calls)" 2
GH_BUDGET_RATE_LIMIT_MIN_INTERVAL_S=10 drive 'gh_budget_exhausted; CLOCK=$((CLOCK + 11)); gh_budget_exhausted' >/dev/null
eq "M3 knob 10, 11 s later: 2 calls" "$(calls)" 2

# ---- M4 -------------------------------------------------------------------
: > "$T/rl-down"
OUT=$(drive 'gh_budget_exhausted; a=$?; rm -f "$T/rl-down"; gh_budget_exhausted; b=$?; gh_budget_exhausted; echo "$a$b$?"')
eq "M4 a failed read answers rc 1 (not exhausted), then the good reads rc 0" "$OUT" 100
eq "M4 failed, read again, then memo: 2 calls" "$(calls)" 2

# ---- M5 -------------------------------------------------------------------
rm -f "$T/rl-calls"
for i in 1 2; do
  ( export T PATH="$T/fakebin:$PATH" HARNESS="$T" GH_BUDGET_DB=0
    bash -c '. "$T/bin/lib/gh-budget.sh"; gh_budget_exhausted' )
done
eq "M5 two processes: 2 calls" "$(calls)" 2

# ---- M6 -------------------------------------------------------------------
rm -f "$T/state/gh-budget"/*
OUT=$(drive 'gh_budget_refresh; a=$?; gh_budget_exhausted; echo "$a$?"')
eq "M6 refresh rc 0, then exhausted rc 0" "$OUT" 00
eq "M6 refresh + exhausted share the memo: 1 call" "$(calls)" 1
GH_BUDGET_RATE_LIMIT_MIN_INTERVAL_S=abc drive 'gh_budget_exhausted; CLOCK=$((CLOCK + 59)); gh_budget_exhausted; CLOCK=$((CLOCK + 1)); gh_budget_exhausted' >/dev/null
eq "M6 knob abc reads as 60: 2 calls over 60 s" "$(calls)" 2

echo "gh-budget-memo.bh-8334: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
