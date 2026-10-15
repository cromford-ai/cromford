#!/bin/bash
# tests/pr-snapshot-wakes.bh-6799-test.sh — BH-6799: "$DIR/bin/lib/pr-snapshot-wakes.sh"
# asks the wakes summary FIRST and skips its page read of /api/wakes?since=
# when the summary row for the repo carries a last_id that is not above its own
# wakes.wm. The summary JSON goes through the real wakes_summary verb
# ("$DIR/bin/lib/jobs/queue.sh", its 5th TSV column) into the real skip rule.
#
# Loaded the way production loads it: the real bin/jobs-client.sh, then
# bin/lib/pr-snapshot.sh, whose hook sources the wakes lib. Stubbed: _jobs_req
# only (the bh-4661 stub): /api/wakes/summary answers $T/summary.json (rc 2
# when absent), /api/wakes?since=N answers $T/wakes/N.json or {"wakes":[]}.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/pr-snapshot-wakes.bh-6799-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v flock >/dev/null || { echo "flock missing — skipping"; exit 0; }

H="$T/h"; mkdir -p "$H/bin/lib/jobs" "$H/state" "$H/logs" "$T/log" "$T/tmp" "$T/wakes"
for s in bin/jobs-client.sh bin/lib/pr-snapshot.sh; do
  scratch_install_closure "$s" "$H" >/dev/null \
    || { echo "FAIL: scratch_install_closure $s"; exit 1; }
done
[ -r "$H/bin/lib/pr-snapshot-wakes.sh" ] \
  || { echo "FAIL: the closure of bin/lib/pr-snapshot.sh did not install bin/lib/pr-snapshot-wakes.sh"; exit 1; }
HARNESS_TEST_SANDBOX=1 "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 \
  || { echo "FAIL: bin/lanes-build.sh could not compose the registry"; exit 1; }

SLUG=example-org/demo-os
unset PR_SNAPSHOT_LIB PR_SNAPSHOT_WAKES_LIB PRS_COUNT_FILE
export HARNESS="$H" HARNESS_SECRET=test-secret JOBS_URL=https://jobs.test \
  JOBS_RETRIES=0 TMPDIR="$T/tmp" LANE_GATE_DISABLE=1 GH_ETAG=0 LANE_REGISTRY="$T/lanes.json" T \
  PR_SNAPSHOT=1 PR_SNAPSHOT_TTL_S=60 PR_SNAPSHOT_QUIET_TTL_S=300 PR_SNAPSHOT_FEED_STALE_S=900
SNAPDIR="$H/state/pr-snapshot/example-org_demo-os"
NOW=$(date +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }

# summary <repo> <last_id JSON value, or `absent`> — the worker's answer, one row.
summary() {
  if [ "$2" = absent ]; then
    jq -nc --arg r "$1" --arg a "$(iso "$((NOW - 30))")" '{repos:[{repo:$r, last_at:$a, kinds:"pr"}]}' > "$T/summary.json"
  else
    jq -nc --arg r "$1" --arg a "$(iso "$((NOW - 30))")" --argjson l "$2" \
      '{repos:[{repo:$r, last_id:$l, last_at:$a, kinds:"pr"}]}' > "$T/summary.json"
  fi
}
# seed [wm] — a box with wm 100 (or the given content; `none` for no file,
# `empty` for an empty one) and no read inside the TTL.
seed() {
  scratch_rm "$H/state/pr-snapshot"; scratch_rm "$T/wakes"
  mkdir -p "$T/wakes" "$SNAPDIR"
  rm -f "$T/summary.json"; : > "$T/log/worker"
  case "${1:-100}" in
    none) ;;
    empty) : > "$SNAPDIR/wakes.wm" ;;
    *) printf '%s\n' "${1:-100}" > "$SNAPDIR/wakes.wm" ;;
  esac
  printf 'pr\t5\t90\t%s\n' "$((NOW - 3600))" > "$SNAPDIR/changed.tsv"
  printf '%s\t1\t1\t%s\n' "$((NOW - 600))" "$((NOW - 7200))" > "$SNAPDIR/wakes.state"
}

cat > "$T/drv.sh" <<'EOF'
#!/bin/bash
set -uo pipefail
. "$HARNESS/bin/jobs-client.sh" || exit 97
. "$HARNESS/bin/lib/pr-snapshot.sh" || exit 99
_jobs_req() {
  local s
  printf '%s %s\n' "$1" "$2" >> "$T/log/worker"
  case "$2" in
    /api/wakes/summary*) [ -f "$T/summary.json" ] || return 2; cat "$T/summary.json" ;;
    "/api/wakes?"*)
      s="${2#*since=}"; s="${s%%&*}"
      if [ -f "$T/wakes/$s.json" ]; then cat "$T/wakes/$s.json"; else echo '{"wakes":[]}'; fi ;;
    *) return 2 ;;
  esac
}
eval "$1"
EOF
drv() { bash "$T/drv.sh" "$1" > "$T/drv.out" 2>&1; DRC=$?; }
wreads() { grep -c '^GET /api/wakes?' "$T/log/worker"; }
sreads() { grep -c '^GET /api/wakes/summary' "$T/log/worker"; }
complete() { cut -f2 "$SNAPDIR/wakes.state"; }

# ── P1: last_id 101 above wm 100 -> one page read from since=100 ──
seed; summary "$SLUG" 101
jq -nc --arg r "$SLUG" --arg at "$(iso "$((NOW - 20))")" \
  '{wakes:[{id:101, repo:$r, kind:"pr", key:"7", event:"x", at:$at, acked_at:null}]}' > "$T/wakes/100.json"
drv "prs_changed $SLUG; echo changed=\$?"
grep -qx changed=0 "$T/drv.out" && ok || bad "P1 prs_changed: $(cat "$T/drv.out")"
[ "$(wreads)" = 1 ] && grep -q 'since=100&' "$T/log/worker" && ok || bad "P1 want 1 page read from 100: $(cat "$T/log/worker")"
[ "$(cat "$SNAPDIR/wakes.wm")" = 101 ] && ok || bad "P1 wm want 101, got $(cat "$SNAPDIR/wakes.wm")"
[ "$(sreads)" = 1 ] && grep -q '^GET /api/wakes/summary?hours=168$' "$T/log/worker" && ok \
  || bad "P1 want one summary read for 168 h: $(cat "$T/log/worker")"

# ── P2: last_id 100 (== wm) and 99 -> zero page reads, complete, wm and changed.tsv kept ──
for L in 100 99; do
  seed; summary "$SLUG" "$L"; cp "$SNAPDIR/changed.tsv" "$T/changed.before"
  drv "prs_changed $SLUG; echo changed=\$?; prs_feed_fresh $SLUG; echo fresh=\$?"
  grep -qx changed=0 "$T/drv.out" && ok || bad "P2 $L prs_changed: $(cat "$T/drv.out")"
  [ "$(wreads)" = 0 ] && ok || bad "P2 $L want 0 page reads, got $(wreads): $(cat "$T/log/worker")"
  [ "$(sreads)" = 1 ] && ok || bad "P2 $L want 1 summary read, got $(sreads)"
  [ "$(complete)" = 1 ] && ok || bad "P2 $L state not complete: $(cat "$SNAPDIR/wakes.state")"
  [ "$(cat "$SNAPDIR/wakes.wm")" = 100 ] && ok || bad "P2 $L wm moved: $(cat "$SNAPDIR/wakes.wm")"
  cmp -s "$SNAPDIR/changed.tsv" "$T/changed.before" && ok || bad "P2 $L changed.tsv changed"
  grep -qx fresh=0 "$T/drv.out" && ok || bad "P2 $L the skip lost freshness: $(cat "$T/drv.out")"
done

# ── P3: every adversarial negative pages once (never a wrong quiet) ──
neg() {  # neg <label> — expects exactly one page read and a complete state
  drv "prs_changed $SLUG; echo changed=\$?"
  [ "$(wreads)" = 1 ] && ok || bad "P3 $1: want 1 page read, got $(wreads): $(cat "$T/log/worker")"
}
seed; summary example-org/demo-os2 50; neg "a lookalike repo row"
seed; summary example-org/demo 50; neg "a prefix repo row"
seed; summary example-org/demo-os 50; neg "a case-different repo row"
seed; summary "$SLUG" absent; neg "last_id absent (an old worker)"
seed; summary "$SLUG" '"-"'; neg "last_id -"
seed; summary "$SLUG" '""'; neg "last_id empty"
seed; summary "$SLUG" '"12a"'; neg "last_id 12a"
seed; summary "$SLUG" -5; neg "last_id negative"
seed; summary "$SLUG" 50.5; neg "last_id fractional"
seed; summary "$SLUG" null; neg "last_id null"
seed none; summary "$SLUG" 0; neg "no wm file"
seed empty; summary "$SLUG" 0; neg "an empty wm"
seed; neg "summary rc 2 (no route)"
seed; printf 'not json' > "$T/summary.json"; neg "summary not JSON"

echo "pr-snapshot-wakes.bh-6799: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
