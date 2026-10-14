#!/bin/bash
# tests/watchdog-url-hub-lanes.bh-3321-test.sh — watchdog-ping, watchdog-poll
# and tickets-snapshot-push read WATCHDOG_URL through bin/lib/watchdog-url.sh
# (BH-3321, part 2 of BH-2091).
#
# WHY. The three lanes used to fall back to the fleet watchdog host when
# WATCHDOG_URL was empty (watchdog-poll had no override at all). Now an unset
# URL means no network call and one line per lane per day in
# logs/watchdog-url.log, and a missing lib means no call either.
#
# Every case runs the real script file against a scratch harness with a
# recording curl/wget on PATH:
# §4a/§4b ping/poll unset: 0 curl, exactly 1 [lane] line after two runs, rc 0
# §4c/§4d ping/poll set: the call goes to http://watchdog.invalid
# §4e/§4f lib absent: 0 curl, rc 0
# §5a/§5b tickets-snapshot-push unset: 0 curl of any kind (board reads too);
#         set: the POST goes to http://watchdog.invalid/api/tickets-snapshot
# §6 the fleet host appears in none of the 3 scripts or the 2 lane JSONs
#
# WUHL_SRC_DIR points at the directory the scripts under test are copied from
# (default: this checkout's bin/), so a mutated copy can be run through the
# same cases. Fixtures use http://watchdog.invalid; the fleet host is only
# ever assembled from pieces here. Run from anywhere (0 = pass).
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 30 || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

SRC="${WUHL_SRC_DIR:-$DIR/bin}"
FLEET_HOST='harness-watchdog.'"operator"'.workers'"."'dev'
DAY=$(date -u +%F)
PROJ="bh3321p$$"

# Recording curl/wget. curl answers `[]` so the poll sees an empty queue and a
# board read finds no board; the log is per case through $WUHL_NET.
mkdir -p "$T/fakebin"
for c in curl wget; do
  printf '#!/bin/bash\necho "%s $*" >> "${WUHL_NET:-/dev/null}"\n[ "%s" = curl ] && echo "[]"\nexit 0\n' "$c" "$c" > "$T/fakebin/$c"
  chmod +x "$T/fakebin/$c"
done

# mkh <case> <script> [nolib] -> prints the scratch harness root
mkh() {
  local h="$T/$1/h"
  mkdir -p "$h/bin/lib" "$h/env" "$h/logs" "$h/flags" "$h/state"
  cp "$SRC/$2" "$h/bin/$2"; chmod +x "$h/bin/$2"
  cp "$DIR/bin/lib/env-path.sh" "$h/bin/lib/"
  [ "${3:-}" = nolib ] || cp "$DIR/bin/lib/watchdog-url.sh" "$h/bin/lib/"
  echo "HARNESS_SECRET=x" > "$h/env/global.env"
  printf '%s\n' "$h"
}
# run <h> <net-log> <script> [args...] -> RC ; WATCHDOG_URL comes only from global.env
run() {
  local h="$1" net="$2" s="$3"; shift 3
  : >> "$net"
  env -u WATCHDOG_URL PATH="$T/fakebin:$PATH" HARNESS="$h" WUHL_NET="$net" \
    bash "$h/bin/$s" "$@" >/dev/null 2>&1
  RC=$?
}
# A failure message never echoes a secret: anything but the fixture's `x` after
# ?s= is masked (a regressed script that ignores $HARNESS reads the live env).
seen() { sed -E 's/([?&]s=)([^ &]{2,})/\1<redacted>/g' "$1" 2>/dev/null | tr '\n' ' '; }
lines() { # lines <h> <lane> -> count of today's not-set lines for that lane
  grep "^$DAY" "$1/logs/watchdog-url.log" 2>/dev/null | grep -cF "[$2] WATCHDOG_URL not set"
}

# ── §4 watchdog-ping / watchdog-poll ─────────────────────────────────────────
for pair in "ping:watchdog-ping.sh:watchdog-ping" "poll:watchdog-poll.sh:watchdog-poll"; do
  tag=${pair%%:*}; rest=${pair#*:}; script=${rest%%:*}; lane=${rest#*:}
  args=(); [ "$tag" = ping ] && args=(box1)

  # §4a/§4b unset
  h=$(mkh "$tag-unset" "$script"); net="$T/$tag-unset/net.log"
  run "$h" "$net" "$script" "${args[@]}"; rc1=$RC
  run "$h" "$net" "$script" "${args[@]}"; rc2=$RC
  [ "$rc1" = 0 ] && [ "$rc2" = 0 ] && ok || bad "§4 $lane unset: want rc 0 twice, got $rc1/$rc2"
  [ ! -s "$net" ] && ok || bad "§4 $lane unset: want 0 network calls, saw: $(seen "$net")"
  n=$(lines "$h" "$lane")
  [ "${n:-0}" = 1 ] && ok || bad "§4 $lane unset: want exactly 1 [$lane] line after two runs, got ${n:-0}: $(cat "$h/logs/watchdog-url.log" 2>/dev/null)"

  # §4c/§4d set (in global.env, with a trailing slash the lib strips)
  h=$(mkh "$tag-set" "$script"); net="$T/$tag-set/net.log"
  echo "WATCHDOG_URL=http://watchdog.invalid/" >> "$h/env/global.env"
  run "$h" "$net" "$script" "${args[@]}"
  if [ "$tag" = ping ]; then want='http://watchdog.invalid/api/ping/box1?s=x'
  else want='http://watchdog.invalid/api/commands?s=x'; fi
  [ "$RC" = 0 ] && grep -qF "$want" "$net" && ok || bad "§4 $lane set: want rc 0 + a call to $want, rc=$RC saw: $(seen "$net")"
  grep -qF "$FLEET_HOST" "$net" && bad "§4 $lane set: called the fleet host: $(seen "$net")" || ok
  [ "$(lines "$h" "$lane")" = 0 ] && ok || bad "§4 $lane set: must log no not-set line"

  # §4e/§4f the lib is not there
  h=$(mkh "$tag-nolib" "$script" nolib); net="$T/$tag-nolib/net.log"
  run "$h" "$net" "$script" "${args[@]}"
  [ "$RC" = 0 ] && [ ! -s "$net" ] && ok || bad "§4 $lane lib absent: want rc 0 + 0 network calls, rc=$RC saw: $(seen "$net")"
  echo "WATCHDOG_URL=http://watchdog.invalid" >> "$h/env/global.env"
  run "$h" "$net" "$script" "${args[@]}"
  [ "$RC" = 0 ] && [ ! -s "$net" ] && ok || bad "§4 $lane lib absent (URL set): no lib means no call, rc=$RC saw: $(seen "$net")"
done

# ── §5 tickets-snapshot-push ─────────────────────────────────────────────────
# Board stubs that WOULD answer: one project with a prod URL, prefix and token.
mksnap() {
  local h; h=$(mkh "$1" tickets-snapshot-push.sh "${2:-}")
  printf '#!/bin/bash\necho %s\n' "$PROJ" > "$h/bin/fleet-projects-or-alert.sh"
  cat > "$h/bin/fleet-conf.sh" <<'EOF'
#!/bin/bash
case "$2" in prod) echo http://board.invalid ;; board_prefix) echo /api ;; repo) echo o/r ;; esac
EOF
  printf '#!/bin/bash\necho tok\n' > "$h/bin/internal-token-for.sh"
  printf '#!/bin/bash\necho "$*" >> "%s/alerts.log"\n' "$h" > "$h/bin/alert-line.sh"
  chmod +x "$h/bin/"*.sh
  printf '%s\n' "$h"
}
h=$(mksnap snap-unset); net="$T/snap-unset/net.log"
run "$h" "$net" tickets-snapshot-push.sh
[ "$RC" = 0 ] && ok || bad "§5a snapshot unset: want rc 0, got $RC"
[ ! -s "$net" ] && ok || bad "§5a snapshot unset: want 0 curl calls of any kind (board reads included), saw: $(seen "$net")"
[ "$(lines "$h" tickets-snapshot-push)" = 1 ] && ok || bad "§5a snapshot unset: want 1 [tickets-snapshot-push] line"

h=$(mksnap snap-set); net="$T/snap-set/net.log"
echo "WATCHDOG_URL=http://watchdog.invalid" >> "$h/env/global.env"
run "$h" "$net" tickets-snapshot-push.sh
[ "$RC" = 0 ] && ok || bad "§5b snapshot set: want rc 0, got $RC"
grep -q 'board.invalid/api/boards' "$net" && ok || bad "§5b snapshot set: the board read should run, saw: $(seen "$net")"
grep -F -- '-X POST' "$net" | grep -qF 'http://watchdog.invalid/api/tickets-snapshot?s=x' && ok \
  || bad "§5b snapshot set: want a POST to http://watchdog.invalid/api/tickets-snapshot?s=x, saw: $(seen "$net")"
grep -qF "$FLEET_HOST" "$net" && bad "§5b snapshot set: called the fleet host" || ok

h=$(mksnap snap-nolib nolib); net="$T/snap-nolib/net.log"
echo "WATCHDOG_URL=http://watchdog.invalid" >> "$h/env/global.env"
run "$h" "$net" tickets-snapshot-push.sh
[ "$RC" = 0 ] && [ ! -s "$net" ] && ok || bad "§5c snapshot lib absent: want rc 0 + 0 curl, rc=$RC saw: $(seen "$net")"
rm -f "/tmp/snap-$PROJ.json" "/tmp/snap-$PROJ.enriched"

# ── §6 no fleet host literal in the three scripts or the two lane JSONs ─────
for f in "$SRC/watchdog-ping.sh" "$SRC/watchdog-poll.sh" "$SRC/tickets-snapshot-push.sh" \
         "$DIR/catalog/lanes.d/watchdog-ping.json" "$DIR/catalog/lanes.d/tickets-snapshot-push.json"; do
  [ -f "$f" ] || { bad "§6 $f missing"; continue; }
  grep -qF "$FLEET_HOST" "$f" && bad "§6 $f still names the fleet watchdog host" || ok
done

echo "watchdog-url-hub-lanes: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
