#!/bin/bash
# tests/lead-enqueue-unwired.bh-7235-test.sh — BH-7235 (BH-5878.1, slice C1):
# nothing starts bin/lead-review-enqueue.sh. The lead review worklist
# (bin/lead-review.sh tick on each box) is the one input of the lead review.
#   U1  no cron/lanes/*.cron non-comment line runs lead-review-enqueue.sh.
#   U2  a scratch bin/lanes-build.sh --write, then bin/render-cron.sh --root
#       <scratch> <box> for every cron/boxes/<box>.d (not _*), file mode:
#       each exits 0 and renders no crontab line that runs the enqueue.
#   U3  the hub render in db mode (REGISTRY_SOURCE=db) over a registry cache
#       (tests/lib/registry-cache.bh-5651.sh) that still holds the D1 row
#       lane_boxes {lead-review-enqueue, hub}: rc 0, no enqueue line.
#   bin/wake-loop.sh on tests/lib/wake-claim-stub.sh, every lane script an
#   argv recorder, bin/lib/lead-reenqueue.sh installed beside it:
#   W1  the hub, one pr row pull_request.synchronize: no lead-enqueue launch,
#       no lead-review-enqueue.sh argv, no `lead-enqueue:` log line.
#   W2  the box that owns the repo (not the hub), one lead-review doorbell
#       row: one bin/lead-review.sh tick launch (unchanged).
#   M1  (D1) the BH-5581 source line and its two calls put back in the loop:
#       W1 goes red.
# The 713 stub and the lane JSON are deleted together (BH-8363): the db-mode
# overlay maps the D1 rows over file lanes only, so the row has no lane to
# land on. The old stub and .boxes pins live on as R1-R4 and M1 of
# tests/lead-enqueue-lane-retired.bh-8363-test.sh.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-enqueue-unwired.bh-7235-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
. "$(dirname "$0")/lib/registry-cache.bh-5651.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { local out; if out=$("$1" 2>&1); then ok; else bad "$1 — $out"; fi; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "FAIL: flock missing"; exit 1; }
command -v perl >/dev/null || { echo "FAIL: perl missing"; exit 1; }

# ── U1: no lane fragment runs the enqueue ──
U1=$(grep -l 'lead-review-enqueue\.sh' "$DIR"/cron/lanes/*.cron 2>/dev/null \
  | while IFS= read -r f; do grep -v '^[[:space:]]*#' "$f" | grep -q 'lead-review-enqueue\.sh' && echo "${f#"$DIR"/}"; done)
[ -z "$U1" ] && ok || bad "U1 a cron/lanes fragment runs the enqueue: $U1"

# ── U2: every box's render runs no enqueue ──
RR="$T/render"; mkdir -p "$RR"
# Three copies, each checked: a suite run beside this one may rewrite the
# git-ignored catalog/lanes.json while cp reads it, and lanes-build renders it
# again below anyway.
cp -r "$DIR/cron" "$RR/" || bad "U2 setup: cp cron"
cp -r "$DIR/catalog" "$RR/" 2>/dev/null; [ -d "$RR/catalog/lanes.d" ] || bad "U2 setup: cp catalog"
cp "$DIR/fleet.conf" "$RR/" || bad "U2 setup: cp fleet.conf"
if bash "$DIR/bin/lanes-build.sh" --root "$RR" --write > "$T/lb.out" 2>&1; then ok; else bad "U2 lanes-build --write: $(cat "$T/lb.out")"; fi
NB=0
for d in "$DIR"/cron/boxes/*.d; do
  b=${d##*/}; b=${b%.d}
  case "$b" in _*) continue ;; esac
  NB=$((NB + 1))
  if ! bash "$DIR/bin/render-cron.sh" --root "$RR" "$b" > "$T/r.$b" 2> "$T/r.$b.err"; then
    bad "U2 render-cron $b: $(head -3 "$T/r.$b.err")"; continue
  fi
  [ -s "$T/r.$b" ] || { bad "U2 render-cron $b printed nothing"; continue; }
  hit=$(grep -v '^[[:space:]]*#' "$T/r.$b" | grep 'lead-review-enqueue') && bad "U2 $b runs the enqueue: $hit" || ok
done
[ "$NB" -ge 10 ] && ok || bad "U2 rendered $NB boxes, want 10 or more"

# ── U3: the hub in db mode, the D1 row lead-review-enqueue/hub still there ──
# render_db <tree> <out-prefix>: the hub render in db mode over a cache built
# from <tree>'s own registry emit plus the D1 row the seed put there.
render_db() {
  local tree="$1" o="$2" hr="$1/hroot"
  scratch_rm "$hr"; mkdir -p "$hr"
  bash "$DIR/bin/registry-seed.sh" --emit --root "$tree" > "$o.emit" 2> "$o.emit.err" || { echo "registry-seed --emit: $(head -3 "$o.emit.err")" > "$o.err"; return 2; }
  jq '.lane_boxes += [{lane: "lead-review-enqueue", box_id: "hub"}]' "$o.emit" > "$o.reg" || return 2
  ( RCACHE_REGISTRY_JSON="$o.reg" rcache_install "$hr" "$tree" > "$o.rc.err" 2>&1 || exit 2
    HARNESS="$hr" bash "$DIR/bin/render-cron.sh" --root "$tree" hub > "$o" 2> "$o.err" )
}
render_db "$RR" "$T/db.hub"; RC=$?
[ "$RC" = 0 ] && ok || bad "U3 db-mode hub render rc=$RC: $(head -3 "$T/db.hub.err" 2>/dev/null) $(cat "$T/db.hub.rc.err" 2>/dev/null)"
jq -e '.lane_boxes | any(.lane == "lead-review-enqueue" and .box_id == "hub")' "$RR/hroot/state/registry/registry.json" >/dev/null 2>&1 \
  && ok || bad "U3 setup: the cache does not hold the lead-review-enqueue/hub row"
[ -s "$T/db.hub" ] && ok || bad "U3 the db-mode render printed nothing"
hit=$(grep -v '^[[:space:]]*#' "$T/db.hub" | grep 'lead-review-enqueue\.sh') && bad "U3 db mode runs the enqueue: $hit" || ok

# ═══════════════════ bin/wake-loop.sh ═══════════════════
WH="$T/wh"
LOOP_SRC="$DIR/bin/wake-loop.sh"
LANES="merge-conductor deploy-train postmerge-qa run-triage review-prs rebase-train lead-review lead-review-land"
fresh() {
  scratch_rm "$WH"
  mkdir -p "$WH/bin/lib/jobs" "$WH/env" "$WH/logs" "$WH/locks" "$WH/state/wcs" "$WH/flags" "$WH/calls"
  printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\n' > "$WH/env/global.env"
  scratch_install_closure bin/wake-loop.sh "$WH" >/dev/null || { echo "FAIL: scratch_install_closure bin/wake-loop.sh"; exit 1; }
  scratch_install_closure bin/jobs-client.sh "$WH" >/dev/null || { echo "FAIL: scratch_install_closure bin/jobs-client.sh"; exit 1; }
  # The enqueue's closure carries bin/lib/lead-reenqueue.sh: the lib is on the
  # box, so W1 proves the loop no longer reads it, not that it is absent.
  scratch_install_closure bin/lead-review-enqueue.sh "$WH" >/dev/null || { echo "FAIL: scratch_install_closure bin/lead-review-enqueue.sh"; exit 1; }
  cp "$LOOP_SRC" "$WH/bin/wake-loop.sh"
  wcs_install "$WH/bin"
  HARNESS="$WH" wcs_identity "$WH/bin" || { echo "wcs_identity failed"; exit 1; }
  cat > "$WH/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'cromford\nproject-1\n'; exit 0; }
case "$1/$2" in
  cromford/repo) echo example-org/cromford ;;
  project-1/repo)   echo example-org/project-1 ;;
  cromford/box)  echo box-small ;;
  project-1/box)    echo local ;;
  */board_prefix)     echo /api/board ;;
  *) exit 1 ;;
esac
SH
  for s in $LANES lead-review-enqueue; do
    printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/%s"\n' "$s" > "$WH/bin/$s.sh"
  done
  printf '#!/bin/bash\nexit 1\n' > "$WH/bin/unblocked-children.sh"
  printf '#!/bin/bash\necho "[]"\n' > "$WH/bin/gh"
  printf '#!/bin/bash\nexec "$@"\n' > "$WH/bin/setsid"
  chmod +x "$WH/bin/"*.sh "$WH/bin/gh" "$WH/bin/setsid"
  : > "$T/wakes.json"
}
wakes() { printf '{"wakes":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/wakes.json"; }
W() { # W <id> <repo> <kind> <key> <event>
  printf '{"id":%s,"repo":"%s","kind":"%s","key":"%s","event":"%s","at":"2026-10-17T03:00:00Z"}' "$1" "$2" "$3" "$4" "$5"
}
settle() {
  local prev="" cur i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
    sleep 0.25
    cur=$(cat "$WH/calls/"* 2>/dev/null | wc -c | tr -d ' ')
    [ "$cur" = "$prev" ] && [ "$i" -ge 3 ] && return 0
    prev="$cur"
  done
}
run_as() {
  ( export HARNESS="$WH" WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0 WCS_WAKES="$T/wakes.json" PATH="$WH/bin:$PATH"
    unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE LEAD_REENQUEUE_ON_PUSH
    BOX_NAME="$1" "$WH/bin/wake-loop.sh" ); settle
}
calls() { if [ -f "$WH/calls/$1" ]; then wc -l < "$WH/calls/$1" | tr -d " "; else echo 0; fi; }
WLOG() { cat "$WH/logs/wake-loop.log" 2>/dev/null; }
BH=example-org/cromford

case_W1() {
  fresh; wakes "$(W 1 $BH pr 42 pull_request.synchronize)"
  [ -r "$WH/bin/lib/lead-reenqueue.sh" ] || { echo "W1 setup: bin/lib/lead-reenqueue.sh not installed"; return 1; }
  run_as box-hub
  [ "$(calls lead-review-enqueue)" = 0 ] || { echo "W1 launched the enqueue: $(cat "$WH/calls/lead-review-enqueue")"; return 1; }
  ! grep -q 'lead-enqueue' <<<"$(WLOG)" || { echo "W1 log: $(grep 'lead-enqueue' <<<"$(WLOG)")"; return 1; }
  # The row still reached the loop: the hub's conductor ran for it.
  [ "$(calls merge-conductor)" -ge 1 ] || { echo "W1 the pr row was not drained (no conductor launch): $(WLOG)"; return 1; }
}
case_W2() {
  fresh; wakes "$(W 1 $BH lead-review 42 lead-review)"
  run_as box-small
  [ "$(calls lead-review)" = 1 ] || { echo "W2 lead-review launched $(calls lead-review) time(s): $(WLOG)"; return 1; }
  [ "$(cat "$WH/calls/lead-review")" = tick ] || { echo "W2 argv: $(cat "$WH/calls/lead-review")"; return 1; }
  [ "$(calls lead-review-enqueue)" = 0 ] || { echo "W2 launched the enqueue"; return 1; }
}
check case_W1
check case_W2

# ── M1: the BH-5581 hook put back -> W1 goes red ──
perl -0pe '
  s{(\ncommand -v lane_switch >/dev/null 2>&1 \|\| lane_switch\(\)[^\n]*\n)}{$1. "\${HARNESS:-/root/harness}/bin/lib/lead-reenqueue.sh" 2>/dev/null || true\n};
  s{(\n    case "\$kind" in\n      # Only the hub runs the conductor)}{\n    [ "\$IS_HUB" = 1 ] && command -v lre_wake_row >/dev/null 2>&1 && lre_wake_row "\$kind" "\$event" "\$repo" "\$key"$1};
  s{(\n  # ── THE TRIAGE LAUNCH)}{\n  [ "\$IS_HUB" = 1 ] && command -v lre_wake_launch >/dev/null 2>&1 && lre_wake_launch\n$1};
' "$DIR/bin/wake-loop.sh" > "$T/wl-mutant.sh"
if [ "$(grep -c 'lead-reenqueue.sh\|lre_wake_row "\$kind"\|&& lre_wake_launch$' "$T/wl-mutant.sh")" != 3 ]; then
  bad "M1: the mutant does not carry the three BH-5581 lines (the anchors moved): $(grep -n 'lre_\|lead-reenqueue' "$T/wl-mutant.sh")"
else
  LOOP_SRC="$T/wl-mutant.sh"
  if case_W1 >/dev/null 2>&1; then bad "M1: case_W1 stayed GREEN with the enqueue launch put back"; else ok; fi
  LOOP_SRC="$DIR/bin/wake-loop.sh"
fi

echo "lead-enqueue-unwired.bh-7235: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
