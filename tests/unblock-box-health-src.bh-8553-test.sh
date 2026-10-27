#!/bin/bash
# tests/unblock-box-health-src.bh-8553-test.sh — BH-8553: the Tackler infra
# collector's box_health source reads GET /api/box-health, the route the jobs
# worker serves (worker/jobs/src/routes/box-ssh.js, BH-7710), and maps each
# box to the record view U8 reads. Before the fix it read /api/boxes/health,
# a route the worker does not have, so every hub tick recorded
# `source-unreadable box_health` and U8 never saw a hung box.
#
# WHAT RUNS. The SHIPPED bin/lib/unblock/collectors/infra.sh, sourced in a
# subshell. Only the jobs transport under its seam (_jobs_req) is a stub that
# answers from a fixture's `routes` map and logs every call. A fake curl and
# gh log any call that would leave the box. The fixtures are in the real
# route's shape (tests/fixtures/unblock/bh-8553/).
#
# Cases S1-S21 (the plan's ## Acceptance tests).
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-box-health-src.bh-8553-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "unblock-box-health-src: jq is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { [ "$2" = "$3" ] && ok || bad "$1: want [$3] got [$2]"; }

LIB="$DIR/bin/lib/unblock/collectors/infra.sh"
U8="$DIR/catalog/unblock-rules.d/U8-box-restart.json"
FX="$DIR/tests/fixtures/unblock/bh-8553"
HUNG="$FX/box-health-hung40.json"
HEALTHY="$FX/box-health-healthy.json"
for f in "$LIB" "$U8" "$HUNG" "$HEALTHY"; do [ -f "$f" ] && ok || bad "missing $f"; done
[ -f "$LIB" ] || { echo "unblock-box-health-src: $PASS passed, $FAIL failed"; exit 1; }

H="$T/h"
mkdir -p "$H/bin" "$H/state/merge-conductor" "$T/fakebin"
ln -s "$DIR/catalog" "$H/catalog"
NOW=1792508400   # 2026-10-20T15:00:00Z
for w in curl gh; do
  printf '#!/bin/bash\nprintf "%%s %%s\\n" "%s" "$*" >> "%s/writes.log"\nexit 1\n' "$w" "$T" > "$T/fakebin/$w"
  chmod +x "$T/fakebin/$w"
done

# collect <fixture> <collector fn and args...> — one run of the shipped
# collector. _jobs_req answers GET <path> from .routes[path] (null = HTTP 404
# = rc 2, the string "rc1" = a 503 = rc 1). Every call lands in $T/jobs.log.
collect() {
  local fx="$1"; shift
  ( export HARNESS="$H" HARNESS_TEST_SANDBOX=1 UNBLOCK_NOW="$NOW" FXF="$fx" FXT="$T" PATH="$T/fakebin:$PATH"
    . "$LIB" || exit 9
    _jobs_req() {
      printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$FXT/jobs.log"
      [ "$1" = GET ] || return 1
      local b
      b=$(jq -c --arg p "$2" '.routes[$p]' "$FXF")
      case "$b" in
        null) JOBS_HTTP=404; return 2 ;;
        '"rc1"') JOBS_HTTP=503; return 1 ;;
      esac
      JOBS_HTTP=200; printf '%s' "$b"
    }
    "$@" )
}
box() { collect "$1" unblock_collect_infra --family box; }
# with <fixture> <jq filter> — a variant of a fixture, written to the scratch dir.
with() { local out; out="$T/fx.$(printf '%s' "$2" | md5sum | cut -c1-8).json"; jq "$2" "$1" > "$out"; printf '%s' "$out"; }
R='.routes["/api/box-health"]'
BRAVO="$R.boxes[1]"
hung() { jq -s 'map(select(.kind == "box-hung")) | length' <<<"$1"; }
unread() { jq -s 'map(select(.kind == "source-unreadable" and .unknown == ["box_health"])) | length' <<<"$1"; }

# ═════ S1: a box unreachable 40 min is one box-hung record ═══════════════════
rm -f "$T/jobs.log" "$T/writes.log"
OUT=$(box "$HUNG")
eq "S1 exactly one record" "$(jq -s length <<<"$OUT")" 1
eq "S1 one box-hung record" "$(hung "$OUT")" 1
REC=$(jq -c 'select(.kind == "box-hung")' <<<"$OUT")
eq "S1 subject" "$(jq -r .subject <<<"$REC")" "box:watcher-bravo"
eq "S1 ssh_reachable false" "$(jq -r .ssh_reachable <<<"$REC")" false
eq "S1 unreachable 40 min" "$(jq -r .ssh_unreachable_min <<<"$REC")" 40
eq "S1 Orgo hosted and running" "$(jq -c '[.orgo_hosted, .orgo_state]' <<<"$REC")" '[true,"running"]'
eq "S1 env-bundle failures from the lane count" "$(jq -r .envbundle_fail_1h <<<"$REC")" 5
eq "S1 stall_at is the last ssh answer" "$(jq -r .stall_at <<<"$REC")" "2026-10-20T14:20:00Z"
eq "S1 stall hour" "$(jq -r .stall_at_hour <<<"$REC")" "2026-10-20T14"

# ═════ S4: one read, of the route the worker serves ═════════════════════════
eq "S4 one GET of /api/box-health" "$(cat "$T/jobs.log")" "GET /api/box-health "

# ═════ S2: a healthy fleet gives nothing ═════════════════════════════════════
OUT=$(box "$HEALTHY")
eq "S2 healthy fleet: 0 records of any kind" "$(printf '%s' "$OUT" | grep -c .)" 0

# ═════ S3: the S1 record against U8 ══════════════════════════════════════════
if [ -f "$U8" ] && [ -n "$REC" ]; then
  RES=""
  while IFS= read -r p; do
    v=$(jq -c "$p" <<<"$REC" 2>/dev/null) || v=error
    RES+="$v "
  done < <(jq -r '.match.all[]' "$U8")
  eq "S3 U8 predicates: orgo x2, minutes, env-bundle true; restart and build claim not true" "$RES" "true true true true false false "
  eq "S3 unknown names the two facts the route does not carry" "$(jq -c .unknown <<<"$REC")" '["last_restart_min_ago","build_claim_10m"]'
  eq "S3 the two facts are null, never invented" "$(jq -c '[.last_restart_min_ago, .build_claim_10m]' <<<"$REC")" '[null,null]'
else
  bad "S3 no S1 record to evaluate"
fi

# ═════ S5-S8: a real read failure is one source-unreadable record ═══════════
rm -f "$T/jobs.log"
OUT=$(box "$(with "$HUNG" "$R = \"rc1\"")")
eq "S5 503: one source-unreadable naming box_health" "$(unread "$OUT")" 1
eq "S5 ... and nothing else" "$(jq -s length <<<"$OUT")" 1
eq "S5 one GET" "$(cat "$T/jobs.log")" "GET /api/box-health "
OUT=$(box "$(with "$HUNG" "del($R)")")
eq "S6 404: one unreadable" "$(unread "$OUT")" 1
OUT=$(box "$(with "$HUNG" "$R = \"not json\"")")
eq "S7 a body that is not an object: one unreadable" "$(unread "$OUT")" 1
OUT=$(box "$(with "$HUNG" "$R = {}")")
eq "S8a {} with no boxes: one unreadable" "$(unread "$OUT")" 1
OUT=$(box "$(with "$HUNG" "$R.boxes = {}")")
eq "S8a boxes not an array: one unreadable" "$(unread "$OUT")" 1
OUT=$(box "$(with "$HUNG" "$R.partial = [\"ssh\"] | $R.boxes[].ssh = null")")
eq "S8b partial ssh: one unreadable, never all healthy" "$(unread "$OUT")" 1
eq "S8b ... and no box record" "$(hung "$OUT")" 0

# ═════ S9: a stale probe says nothing about now ══════════════════════════════
STALE2H=$(with "$HUNG" "$BRAVO.ssh.probed_at = \"2026-10-20T13:00:00Z\" | $BRAVO.ssh.last_ok_at = \"2026-10-20T12:00:00Z\"")
EDGE=$(with "$HUNG" "$BRAVO.ssh.probed_at = \"2026-10-20T14:50:00Z\"")
eq "S9 probed 2 h ago, default knob: 0 records" "$(hung "$(box "$STALE2H")")" 0
eq "S9 probed exactly 600 s ago: 1 record" "$(hung "$(box "$EDGE")")" 1
eq "S9 probed 601 s ago: 0 records" "$(hung "$(box "$(with "$HUNG" "$BRAVO.ssh.probed_at = \"2026-10-20T14:49:59Z\"")")")" 0
eq "S9 UNBLOCK_BOX_PROBE_STALE_S=86400, probed 2 h ago: 1 record" "$(hung "$(UNBLOCK_BOX_PROBE_STALE_S=86400 box "$STALE2H")")" 1
eq "S9 UNBLOCK_BOX_PROBE_STALE_S=abc: fallback 600, 0 records" "$(hung "$(UNBLOCK_BOX_PROBE_STALE_S=abc box "$STALE2H")")" 0
eq "S9 UNBLOCK_BOX_PROBE_STALE_S=5 (under min 120): fallback 600, edge still 1" "$(hung "$(UNBLOCK_BOX_PROBE_STALE_S=5 box "$EDGE")")" 1
eq "S9 a probed_at that does not parse: 0 records" "$(hung "$(box "$(with "$HUNG" "$BRAVO.ssh.probed_at = \"yesterday\"")")")" 0

# ═════ S10-S13: the per-box rules ════════════════════════════════════════════
OUT=$(box "$(with "$HUNG" "$BRAVO.ssh.last_ok_at = null")")
eq "S10 never answered: 1 record" "$(hung "$OUT")" 1
eq "S10 minutes null and named unknown" "$(jq -c '[.ssh_unreachable_min, (.unknown | index("ssh_unreachable_min") != null)]' <<<"$OUT")" '[null,true]'
OUT=$(box "$(with "$HUNG" "$BRAVO.ssh.rc = 124 | $BRAVO.vm.live[0].status = \"stopped\"")")
eq "S11 rc 124, VM stopped: 1 record, orgo_state stopped" "$(jq -c '[.kind, .orgo_state]' <<<"$OUT")" '["box-hung","stopped"]'
eq "S12 ssh null (no probe row): 0 records" "$(hung "$(box "$(with "$HUNG" "$BRAVO.ssh = null")")")" 0
OUT=$(box "$(with "$HUNG" "$R.boxes += [7, {\"box\": 7, \"ssh\": {\"rc\": 255, \"probed_at\": \"2026-10-20T14:59:00Z\", \"last_ok_at\": null}}]")")
eq "S13 a non-object entry and box 7 are dropped, bravo still counted" "$(jq -s -c 'map(.subject)' <<<"$OUT")" '["box:watcher-bravo"]'
OUT=$(box "$(with "$HUNG" "$R.boxes += [{\"box\": \"watcher-x\", \"ssh\": \"down\"}]")")
eq "S13 an ssh that is not an object is dropped, bravo still counted" "$(jq -s -c 'map(.subject)' <<<"$OUT")" '["box:watcher-bravo"]'

# ═════ S14: the 50-box cap ═══════════════════════════════════════════════════
OUT=$(box "$(with "$HUNG" "$R.boxes = [range(51) as \$i | $BRAVO | .box = \"watcher-\(\$i)\"]")")
eq "S14 51 failing boxes: 50 records, all truncated" "$(jq -s -c '[length, (map(.truncated) | unique)]' <<<"$OUT")" '[50,[true]]'

# ═════ S15-S16: a partial that is not ssh, and an empty fleet ════════════════
OUT=$(box "$(with "$HUNG" "$R.partial = [\"vm\"] | $R.boxes[].vm = null | $R.vm_complete = null")")
eq "S15 partial vm: 1 record with Orgo unknown" "$(jq -c '[.kind, .orgo_hosted, .orgo_state]' <<<"$OUT")" '["box-hung",null,null]'
OUT=$(box "$(with "$HUNG" "$R.partial = [\"heartbeat\"] | $R.boxes[].last_beat_at = null")")
eq "S15 partial heartbeat: the same record as S1" "$OUT" "$REC"
OUT=$(box "$(with "$HUNG" "$R.boxes = []")")
eq "S16 boxes []: 0 records" "$(printf '%s' "$OUT" | grep -c .)" 0

# ═════ S17: envbundle_fail_1h ════════════════════════════════════════════════
ebf() { jq -r .envbundle_fail_1h <<<"$(box "$(with "$HUNG" "$1")")"; }
eq "S17 window 3600: the count" "$(ebf "$BRAVO.lane_ssh_failures = {\"count\": 9, \"window_s\": 3600, \"last_at\": null}")" 9
eq "S17 window 7200: null (not inside the last hour)" "$(ebf "$BRAVO.lane_ssh_failures = {\"count\": 9, \"window_s\": 7200, \"last_at\": null}")" null
eq "S17 no failures object: null" "$(ebf "$BRAVO.lane_ssh_failures = null")" null

# ═════ S18: orgo_hosted and orgo_state ═══════════════════════════════════════
orgo() { jq -c '[.orgo_hosted, .orgo_state]' <<<"$(box "$(with "$HUNG" "$1")")"; }
eq "S18 2 live VMs: unknown" "$(orgo "$BRAVO.vm.live += [{\"id\": \"vm-b2\", \"status\": \"running\"}]")" '[null,null]'
eq "S18 0 live, vm_complete true: not Orgo-hosted" "$(orgo "$BRAVO.vm.live = []")" '[false,null]'
eq "S18 0 live, vm_complete false: unknown" "$(orgo "$BRAVO.vm.live = [] | $R.vm_complete = false")" '[null,null]'
eq "S18 vm null: unknown" "$(orgo "$BRAVO.vm = null")" '[null,null]'

# ═════ S19: the tick contract entry (BH-8498 hub routing) ═══════════════════
OUT=$(collect "$HUNG" ub_collect_infra cromford example-org/cromford)
eq "S19 the hub tick gets the box record with its project" "$(jq -s -c 'map(select(.kind == "box-hung") | [.subject, .project])' <<<"$OUT")" '[["box:watcher-bravo","cromford"]]'
check "S19 the hub tick has no box_health unreadable record" '! jq -e "select(.kind == \"source-unreadable\" and .source == \"box_health\")" <<<"$OUT" >/dev/null'
OUT=$(collect "$HUNG" ub_collect_infra alpha example-org/x)
eq "S19 a non-hub tick gets no box record" "$(hung "$OUT")" 0

# ═════ S20: 0 writes, 0 vendor calls ═════════════════════════════════════════
check "S20 fake curl and gh never called" '[ ! -s "$T/writes.log" ]'
check "S20 no non-GET request" '! grep -qv "^GET " "$T/jobs.log"'

# ═════ S21: the seam reads a path a worker route serves ═════════════════════
P=$(sed -n 's/^ *box_health) path=\([^ ;]*\).*/\1/p' "$LIB")
eq "S21 the seam path" "$P" "/api/box-health"
check "S21 a worker route serves it" 'grep -rqF "\"GET\", \"$P\"" "$DIR/worker/jobs/src/routes/"'

# ═════ S22: the knob file and the writer/reader round trip ══════════════════
KNOB="$DIR/catalog/lanes.d/unblock.knobs.d/UNBLOCK_BOX_PROBE_STALE_S.json"
eq "S22 the stale knob: default 600, range 120..86400, read in infra.sh" \
  "$(jq -c '[.env, .default, .min, .max, .read_in]' "$KNOB" 2>/dev/null)" \
  '["UNBLOCK_BOX_PROBE_STALE_S",600,120,86400,"bin/lib/unblock/collectors/infra.sh"]'
# worker/jobs/test/box-health-collector.bh-8553.test.js feeds the REAL worker's
# GET /api/box-health body to the shipped collector. The worker imports the
# git-ignored render catalog/lanes.json; with no render (or no node) this says
# so and skips, and the worker CI job runs it.
RT="$DIR/worker/jobs/test/box-health-collector.bh-8553.test.js"
if [ ! -f "$RT" ]; then
  bad "S22 missing $RT"
elif ! command -v node >/dev/null 2>&1 || [ ! -f "$DIR/catalog/lanes.json" ]; then
  echo "unblock-box-health-src: S22 round trip SKIPPED, no node or no catalog/lanes.json render (the worker CI job runs it)"
elif NOUT=$(cd "$DIR/worker/jobs" && node --test "$RT" 2>&1); then ok
else bad "S22 $RT failed:"; printf '%s\n' "$NOUT" | grep -E '^not ok|Error|expected|actual' | head -20
fi

echo "unblock-box-health-src: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
