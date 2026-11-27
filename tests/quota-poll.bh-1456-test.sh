#!/bin/bash
# tests/quota-poll.bh-1456-test.sh — WHAT THE DERIVED QUOTA JSON CARRIES, AND
# WHOSE METER IT IS.
#
# Two defects, one masking the other (BH-1456):
#
#   1  bin/quota-poll.sh's normalize() emitted five_hour/seven_day/per_model and
#      nothing else, so the endpoint's `extra_usage` object — the one that says
#      "overage billing is ON for this account" — was dropped on the floor. No
#      quota json could say it, so bin/account-pick.sh classed an account at
#      weekly 100% as `capped` while it was serving perfectly well in overage.
#
#   2  the implicit `default` account's json is DERIVED from
#      state/extra-usage-last.json, which is the BOX LOGIN's meter. On the hub
#      that login is operator_home@example.com, but the `default` credential
#      (CLAUDE_CODE_OAUTH_TOKEN in env/global.env) bills operator@second.example,
#      whose snapshot is state/extra-usage-last-project-6-account.json. So the
#      `default` row showed a 4% week while the token it describes was at 100%.
#
# The cases:
#   1  a snapshot carrying `extra_usage` -> default.json.extra_usage is the full
#      object; a POLLED account whose response has none -> `null`, not `false`
#      (absent is not a reading — D11)
#   2  ACCOUNT_DEFAULT_LABEL set + the labelled snapshot present -> the numbers
#      come from the LABELLED file and `source` names the label
#   3  the label set and its file MISSING -> today's plain derivation plus
#      exactly ONE `default fallback label_snapshot_missing:<label>` log row
#   4  the label UNSET -> plain derivation, and NO fallback row at all (every
#      box that never sets the knob must be byte-identical to before)
#
# Run from anywhere: tests/quota-poll.bh-1456-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

mkdir -p "$T/bin/lib" "$T/env/accounts.d" "$T/state/quota" "$T/logs" "$T/flags"
for f in account-pick.sh quota-poll.sh; do
  cp "$DIR/bin/$f" "$T/bin/$f"; chmod +x "$T/bin/$f"
done
cp "$DIR/bin/lib/oauth-usage-fetch.py" "$T/bin/lib/" 2>/dev/null || true

TOKB=sk-ant-oat01-FIXTURE-B

# A real registry account so the POLLED half of case 1 has something to poll.
# Same shape as tests/account-routing-test.sh case 13's fetch stub.
reg() { # <name> ; body on stdin
  cat > "$T/env/accounts.d/$1.env"; chmod 600 "$T/env/accounts.d/$1.env"
}
mkdir -p "$T/.claude-b"
echo '{"claudeAiOauth":{"accessToken":"'"$TOKB"'"}}' > "$T/.claude-b/.credentials.json"
reg b <<EOF
ACCOUNT_NAME=b
ACCOUNT_VENDOR=claude
CLAUDE_CONFIG_DIR=$T/.claude-b
EOF

# The polled response deliberately carries NO extra_usage: case 1's negative.
cat > "$T/fetch-stub.sh" <<'EOF'
#!/bin/bash
[ -n "${OAUTH_USAGE_TOKEN:-}" ] || { echo NO_TOKEN >&2; exit 1; }
cat <<'J'
{"five_hour":{"utilization":42},"seven_day":{"utilization":61}}
J
EOF
chmod +x "$T/fetch-stub.sh"

poll() { env HARNESS="$T" HOME="$T" ACCOUNTS_DIR="$T/env/accounts.d" \
  OAUTH_USAGE_FETCH="$T/fetch-stub.sh" ACCOUNT_POLL_STAGGER_SECS=0 "$@" \
  bash "$T/bin/quota-poll.sh" >/dev/null 2>&1; }

# =============================================================================
# 1. the snapshot's extra_usage reaches default.json; absent stays null
# =============================================================================
printf '%s' '{"five_hour":{"utilization":0},"seven_day":{"utilization":100},
  "extra_usage":{"is_enabled":true,"spend_limit_reached":false,"disabled_reason":null,
                 "user_disabled":false,"monthly_limit":50000,"used_credits":42000,
                 "utilization":84}}' > "$T/state/extra-usage-last.json"
: > "$T/logs/quota-poll.log"
poll
D="$T/state/quota/default.json"
[ "$(jq -r '.extra_usage.is_enabled' "$D" 2>/dev/null)" = true ] \
  && ok || bad "1: default.json.extra_usage.is_enabled is not true: $(jq -c '.extra_usage' "$D" 2>/dev/null)"
[ "$(jq -r '.extra_usage.spend_limit_reached' "$D" 2>/dev/null)" = false ] \
  && ok || bad "1: extra_usage.spend_limit_reached did not survive normalize"
[ "$(jq -r '.extra_usage.pct' "$D" 2>/dev/null)" = 84 ] \
  && ok || bad "1: extra_usage.pct (from .utilization) is not 84: $(jq -r '.extra_usage.pct' "$D" 2>/dev/null)"
[ "$(jq -r '.extra_usage.monthly_limit' "$D" 2>/dev/null)" = 50000 ] \
  && ok || bad "1: extra_usage.monthly_limit did not survive normalize"
[ "$(jq -r '.extra_usage.used_credits' "$D" 2>/dev/null)" = 42000 ] \
  && ok || bad "1: extra_usage.used_credits did not survive normalize"
[ "$(jq -r '.extra_usage.disabled_reason' "$D" 2>/dev/null)" = null ] \
  && ok || bad "1: extra_usage.disabled_reason should be null"
# D11: a polled account whose response carries no extra_usage says NULL, which
# means "no reading", not `false`, which would mean "overage is off".
[ "$(jq -r '.extra_usage' "$T/state/quota/b.json" 2>/dev/null)" = null ] \
  && ok || bad "1: a response with no extra_usage produced $(jq -c '.extra_usage' "$T/state/quota/b.json" 2>/dev/null), expected null"
# the rest of the shape is untouched
[ "$(jq -r '.five_hour.pct' "$T/state/quota/b.json" 2>/dev/null)" = 42 ] \
  && ok || bad "1: b.json five_hour.pct regressed"
# THE FAILURE PATH CARRIES THE KEY TOO, so every reader sees one shape. `f` has
# a registry file but no readable credential, which is what quota-poll writes
# status_json for — driven through the real script, not by sourcing it.
printf 'ACCOUNT_NAME=f\nACCOUNT_VENDOR=claude\nCLAUDE_CONFIG_DIR=%s/.claude-missing\n' "$T" \
  > "$T/env/accounts.d/f.env"; chmod 600 "$T/env/accounts.d/f.env"
poll
[ -f "$T/state/quota/f.json" ] \
  && ok || bad "1: quota-poll wrote no json at all for an account it could not read"
[ "$(jq -r '.extra_usage' "$T/state/quota/f.json" 2>/dev/null)" = null ] \
  && ok || bad "1: a status_json row does not carry extra_usage: null (got $(jq -c '.extra_usage' "$T/state/quota/f.json" 2>/dev/null))"
rm -f "$T/env/accounts.d/f.env"

# =============================================================================
# 2. ACCOUNT_DEFAULT_LABEL + a labelled snapshot -> the labelled numbers
# =============================================================================
# The plain snapshot still says weekly 100. The LABELLED one says 7. If the
# label is honoured, default.json says 7.
printf '%s' '{"five_hour":{"utilization":3},"seven_day":{"utilization":7},
  "extra_usage":{"is_enabled":false,"spend_limit_reached":false,"utilization":0}}' \
  > "$T/state/extra-usage-last-mk.json"
: > "$T/logs/quota-poll.log"
rm -f "$T/state/quota/default.json"
poll ACCOUNT_DEFAULT_LABEL=mk
[ "$(jq -r '.seven_day.pct' "$D" 2>/dev/null)" = 7 ] \
  && ok || bad "2: default.json seven_day.pct is $(jq -r '.seven_day.pct' "$D" 2>/dev/null), expected 7 from the labelled snapshot"
[ "$(jq -r '.five_hour.pct' "$D" 2>/dev/null)" = 3 ] \
  && ok || bad "2: default.json five_hour.pct did not come from the labelled snapshot"
[ "$(jq -r '.source' "$D" 2>/dev/null)" = "extra-usage-track:mk" ] \
  && ok || bad "2: source does not name the label: $(jq -r '.source' "$D" 2>/dev/null)"
grep -q 'fallback' "$T/logs/quota-poll.log" \
  && bad "2: logged a fallback row while the labelled snapshot was present" || ok

# =============================================================================
# 3. the label set, its file missing -> plain derivation + ONE fallback row
# =============================================================================
: > "$T/logs/quota-poll.log"
rm -f "$T/state/quota/default.json"
poll ACCOUNT_DEFAULT_LABEL=gone
[ "$(jq -r '.seven_day.pct' "$D" 2>/dev/null)" = 100 ] \
  && ok || bad "3: did not fall back to the plain snapshot (seven_day.pct=$(jq -r '.seven_day.pct' "$D" 2>/dev/null), expected 100)"
[ "$(jq -r '.source' "$D" 2>/dev/null)" = "extra-usage-track" ] \
  && ok || bad "3: the fallback derivation should carry the plain source, got $(jq -r '.source' "$D" 2>/dev/null)"
N=$(grep -c 'default fallback label_snapshot_missing:gone' "$T/logs/quota-poll.log" 2>/dev/null || true)
[ "${N:-0}" = 1 ] \
  && ok || bad "3: expected exactly 1 'default fallback label_snapshot_missing:gone' row, got ${N:-0}"

# =============================================================================
# 4. the label unset -> plain derivation, and no fallback row anywhere
# =============================================================================
: > "$T/logs/quota-poll.log"
rm -f "$T/state/quota/default.json"
poll
[ "$(jq -r '.seven_day.pct' "$D" 2>/dev/null)" = 100 ] \
  && ok || bad "4: unset label changed the derivation"
[ "$(jq -r '.source' "$D" 2>/dev/null)" = "extra-usage-track" ] \
  && ok || bad "4: unset label changed the source"
grep -q 'fallback' "$T/logs/quota-poll.log" \
  && bad "4: an unset label logged a fallback row — every box that never sets the knob would log one per tick" || ok

echo "quota-poll.bh-1456-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
