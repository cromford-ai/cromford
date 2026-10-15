#!/bin/bash
# tests/cli-version-check-tools.bh-6742-test.sh — bin/cli-version-check.sh
# reports node and tailscale per box against the vendor's release feed, and
# alerts once a day when one is too far behind (BH-6742). Stub feeds only.
#
#   T1  node 22.20.0 with 22.21.0 (45 days old) and 22.22.0 out: "2 releases,
#       45 days behind", one ALERTS line; 24.x is another major and not counted
#   T2  tailscale at the latest: "(current)", no alert for it
#   T3  a box inside both limits (1 release, 5 days): reported, no alert
#   T4  a second run the same day: no second ALERTS line, and the feeds come
#       from the cache (each fetched once over both runs)
#   T5  a tailscale feed that cannot be read: "latest unknown", no alert, and
#       the failure is not cached (the next run fetches again and reads it)
#   T6  CLI_CHECK_TOOL_BEHIND_RELEASES=5 and _DAYS=100: the T1 gap no longer
#       alerts
#   T7  a box with no node: "node missing"
#   T8  a feed that cannot be read is fetched ONCE per run for every box, and
#       logged once (lead review of #6787: the memo was lost in a subshell)
# Run from anywhere: tests/cli-version-check-tools.bh-6742-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
export JOBS_URL=https://jobs.invalid
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

FLEET="$T/fleet"; mkdir -p "$T/fakebin" "$T/feeds"
printf '#!/bin/bash\nprintf "{\\"accepted\\":1}\\n200\\n"\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
day() { date -u -d "@$(( $(date +%s) - $1 * 86400 ))" +%Y-%m-%d; }
iso() { date -u -d "@$(( $(date +%s) - $1 * 86400 ))" +%Y-%m-%dT%H:%M:%SZ; }
# The vendor feeds, dated relative to now.
jq -n --arg a "$(day 2)" --arg b "$(day 10)" --arg c "$(day 45)" --arg d "$(day 90)" '[
  {version:"v24.10.0", date:$a, lts:false}, {version:"v22.22.0", date:$b, lts:"Jod"},
  {version:"v22.21.0", date:$c, lts:"Jod"}, {version:"v22.20.0", date:$d, lts:"Jod"},
  {version:"v22.19.0-rc.1", date:$d, lts:false}]' > "$T/feeds/node.json"
jq -n --arg a "$(iso 3)" --arg b "$(iso 5)" --arg c "$(iso 40)" '[
  {tag_name:"v1.101.0-pre", published_at:$a, draft:false, prerelease:true},
  {tag_name:"v1.100.0", published_at:$b, draft:false, prerelease:false},
  {tag_name:"v1.98.9", published_at:$c, draft:false, prerelease:false}]' > "$T/feeds/tailscale.json"
# The fetcher: logs each URL; fails for a URL listed in $T/feeds/fail.
cat > "$T/feedcurl" <<EOF
#!/bin/bash
u="\${!#}"; echo "\$u" >> "$T/feed-calls"
grep -qxF "\$u" "$T/feeds/fail" 2>/dev/null && exit 22
case "\$u" in *node*) cat "$T/feeds/node.json" ;; *tailscale*) cat "$T/feeds/tailscale.json" ;; *) exit 22 ;; esac
EOF
chmod +x "$T/feedcurl"; : > "$T/feed-calls"

fake() { printf '#!/bin/bash\necho "%s"\n' "$2" > "$1"; chmod +x "$1"; }
# tbox <name> <node-version|-> <tailscale-version|->
tbox() {
  local b="$FLEET/$1"; mkdir -p "$b/cronbin" "$b/shim" "$b/home/.grok/bin" "$b/etc"
  fake "$b/cronbin/claude" "2.1.299 (Claude Code)"; fake "$b/cronbin/codex" "codex-cli 0.162.1"; fake "$b/home/.grok/bin/grok" "grok 1.0.40"
  printf '#!/bin/bash\necho "PATH=%s"\n' "$b/cronbin" > "$b/shim/crontab"; chmod +x "$b/shim/crontab"
  [ "$2" != - ] && fake "$b/shim/node" "v$2"
  [ "$3" != - ] && fake "$b/shim/tailscale" "$3"
  echo "HARNESS_SECRET=x" > "$b/global.env"
}
cat > "$T/fake-ssh.sh" <<'EOF'
#!/bin/bash
BOX="${1#root@}"; ROOT="$FLEET/$BOX"
[ -d "$ROOT" ] || exit 255
PATH="$ROOT/shim:$SYS_PATH" CLI_CHECK_ENV_FILE="$ROOT/global.env" CLI_CHECK_LOGIN_PATH="$ROOT/cronbin" \
  CLI_CHECK_HOME="$ROOT/home" CLI_CHECK_ETC="$ROOT/etc" CLI_CHECK_UU_LOGS=/nonexistent bash -s
EOF
chmod +x "$T/fake-ssh.sh"
# sysbin: the machine's tools minus node and tailscale, so "missing" means it.
mkdir -p "$T/sysbin"
for f in /usr/bin/* /bin/*; do n=$(basename "$f"); case "$n" in node|tailscale|claude|codex|grok) continue ;; esac
  [ -e "$T/sysbin/$n" ] || ln -s "$f" "$T/sysbin/$n" 2>/dev/null; done

# hroot <name> — a fresh harness root (state, alerts) for one scenario.
hroot() {
  H="$T/$1"; mkdir -p "$H/logs" "$H/state" "$H/env"
  ( cd "$DIR" && scratch_install_closure bin/jobs-client.sh "$H" ) >/dev/null || { echo "closure install failed"; exit 1; }
  echo "HARNESS_SECRET=x" > "$H/env/global.env"
}
# check <boxes> [VAR=value...] -> OUT, NEW (ALERTS lines this run added)
check() {
  local boxes="$1" b0=0; shift
  [ -f "$H/logs/ALERTS.log" ] && b0=$(wc -l < "$H/logs/ALERTS.log")
  OUT=$(env PATH="$FLEET/hub/shim:$T/fakebin:$T/sysbin" SYS_PATH="$T/fakebin:$T/sysbin" FLEET="$FLEET" HARNESS="$H" \
        HARNESS_CHECKOUT="$DIR" CLI_CHECK_BOXES="$boxes" CLI_CHECK_SSH="$T/fake-ssh.sh" CLI_CHECK_SELF_REPORT_FRESH_S=0 \
        CLI_CHECK_ENV_FILE="$FLEET/hub/global.env" CLI_CHECK_LOGIN_PATH="$FLEET/hub/cronbin" CLI_CHECK_HOME="$FLEET/hub/home" \
        CLI_CHECK_ETC="$FLEET/hub/etc" CLI_CHECK_UU_LOGS=/nonexistent CLI_CHECK_FEED_CURL="$T/feedcurl" \
        CLI_CHECK_FEED_NODE_URL=https://feeds.invalid/node.json CLI_CHECK_FEED_TAILSCALE_URL=https://feeds.invalid/tailscale.json \
        "$@" bash "$DIR/bin/cli-version-check.sh" 2>&1)
  NEW=$(tail -n +$((b0 + 1)) "$H/logs/ALERTS.log" 2>/dev/null)
}

tbox hub 22.20.0 1.100.0
tbox box-eta 22.21.0 1.100.0
tbox box-theta - 1.100.0

echo "T1-T3, T7: one run"
hroot h1; check "local box-eta box-theta"
grep -q '^  hub tools: node 22.20.0 (latest 22.22.0: 2 releases, 45 days behind), tailscale 1.100.0 (current)$' <<<"$OUT" \
  && ok "T1/T2 hub: node 2 releases 45 days behind (24.x not counted), tailscale current" || bad "T1 report: $(grep tools: <<<"$OUT")"
[ "$(grep -c 'TOOL VERSIONS' <<<"$NEW")" = 1 ] && grep -q '\[hub\] TOOL VERSIONS: node 22.20.0 is 2 releases and 45 days behind 22.22.0' <<<"$NEW" \
  && ok "T1 exactly one ALERTS line, for the hub's node" || bad "T1 alerts: $NEW"
grep -q '^  eta tools: node 22.21.0 (latest 22.22.0: 1 releases, 10 days behind), tailscale 1.100.0 (current)$' <<<"$OUT" \
  && ok "T3 eta: reported inside the limits" || bad "T3 report: $(grep 'eta tools' <<<"$OUT")"
! grep -q '\[eta\] TOOL' <<<"$NEW" && ok "T3 no alert for eta" || bad "T3 alerts: $NEW"
grep -q '^  theta tools: node missing, tailscale 1.100.0 (current)$' <<<"$OUT" && ok "T7 theta: node missing" || bad "T7 report: $(grep 'theta tools' <<<"$OUT")"

echo "T4: a second run the same day"
check "local box-eta box-theta"
! grep -q 'TOOL VERSIONS' <<<"$NEW" && ok "T4 no second ALERTS line" || bad "T4 alerts: $NEW"
[ "$(grep -c node "$T/feed-calls")" = 1 ] && [ "$(grep -c tailscale "$T/feed-calls")" = 1 ] \
  && ok "T4 each feed fetched once over two runs (cached)" || bad "T4 feed calls: $(cat "$T/feed-calls")"

echo "T5: an unreadable feed"
hroot h5; : > "$T/feed-calls"; echo https://feeds.invalid/tailscale.json > "$T/feeds/fail"
check "local"
grep -q '^  hub tools: node 22.20.0 (latest 22.22.0: 2 releases, 45 days behind), tailscale 1.100.0 (latest unknown: the feed could not be read)$' <<<"$OUT" \
  && ok "T5 tailscale: latest unknown" || bad "T5 report: $(grep tools: <<<"$OUT")"
! grep -q 'tailscale' <<<"$NEW" && ok "T5 no alert for an unknown latest" || bad "T5 alerts: $NEW"
[ ! -e "$H/state/tool-feeds/tailscale.tsv" ] && ok "T5 the failure is not cached" || bad "T5 cache: $(ls "$H/state/tool-feeds")"
: > "$T/feeds/fail"; check "local"
grep -q 'tailscale 1.100.0 (current)' <<<"$OUT" && [ "$(grep -c tailscale "$T/feed-calls")" = 2 ] \
  && ok "T5 the next run fetches again and reads it" || bad "T5 next: $(grep tools: <<<"$OUT") / $(cat "$T/feed-calls")"

echo "T6: the limits are knobs"
hroot h6; check "local" CLI_CHECK_TOOL_BEHIND_RELEASES=5 CLI_CHECK_TOOL_BEHIND_DAYS=100
grep -q 'hub tools: node 22.20.0 (latest 22.22.0: 2 releases, 45 days behind)' <<<"$OUT" && ! grep -q 'TOOL VERSIONS' <<<"$NEW" \
  && ok "T6 the same gap, no alert under 5 releases / 100 days" || bad "T6 alerts: $NEW / $(grep tools: <<<"$OUT")"

echo "T8: a failing feed is fetched once for N boxes"
hroot h8; : > "$T/feed-calls"; echo https://feeds.invalid/tailscale.json > "$T/feeds/fail"
check "local box-eta box-theta"
[ "$(grep -c tailscale "$T/feed-calls")" = 1 ] && ok "T8 the tailscale feed is fetched once for 3 boxes" \
  || bad "T8 tailscale fetches: $(grep -c tailscale "$T/feed-calls")"
[ "$(grep -c 'tool feed for tailscale unreadable' "$H/logs/cli-version-check.log")" = 1 ] && ok "T8 one 'unreadable' log line" \
  || bad "T8 log lines: $(grep -c 'tool feed for tailscale unreadable' "$H/logs/cli-version-check.log")"
[ "$(grep -c 'tailscale 1.100.0 (latest unknown' <<<"$OUT")" = 3 ] && ok "T8 every box still says latest unknown" \
  || bad "T8 report: $(grep tools: <<<"$OUT")"
: > "$T/feeds/fail"

echo "cli-version-check-tools.bh-6742: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
