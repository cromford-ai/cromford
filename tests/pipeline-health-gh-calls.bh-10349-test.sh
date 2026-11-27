#!/bin/bash
# tests/pipeline-health-gh-calls.bh-10349-test.sh — BH-10349: pipeline-health's
# GitHub calls are counted, and its lead-merge-unqueued block (section 13d)
# makes fewer of them without losing an alert.
#
# WHY. On 2026-11-27 the hub's App installation used its 7,100 calls before
# each hourly reset. A sample of the hub's connections put pipeline-health.sh
# behind 54 of 189 `gh` processes, and logs/gh-calls/ had no line for it: the
# lane never sourced bin/lib/gh-limit-logger.sh, so only that wrapper's own
# callers were counted. The hub ledger counted about 150 reviews and 60 status
# reads an hour from section 13d, for the same PRs every 10 minutes.
#
# Cases:
#   C1 a lane that calls `gh` by name through the PATH shim (bin/gh-ledger/gh)
#      gets one logs/gh-calls line, named after the lane
#   C2 a lane that sourced gh-limit-logger.sh gets ONE line per call, not two
#   C3 `timeout N gh api -i -X GET <path>` (gh_rest's bounded shape) is counted,
#      with its METHOD:template field
#   C4 `gh auth token` (a local command) is not counted
#   M1 two runs over N fake PRs: GitHub calls with the cache off, then on
#   M2 the warm run raises the same alerts as the cold run
#   M3 a `checks` wake for a head re-reads its status: the new verdict pages
#   M4 a `pr` wake re-reads the reviews: a dismissed stale review turns the
#      stale-review page into the generic page in the next run
#   M5 a moved head re-reads both
#   M6 a wake feed that cannot tell reads everything
#   M7 a --sections run reads live
#   M8 past PH_LU_MEMO_BACKSTOP_S every read runs
#   M9 with the snapshot off (PR_SNAPSHOT=0) every read runs
# Nothing touches the network: the real `gh` is a stub.
#
# Run from anywhere: bash tests/pipeline-health-gh-calls.bh-10349-test.sh (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SHIM="$DIR/bin/gh-ledger/gh"
PH="$DIR/bin/pipeline-health.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
[ "${BASH_VERSINFO[0]:-0}" -ge 4 ] || { echo "bash 4 needed — skipping"; exit 0; }

# ══ C: the call counter ══════════════════════════════════════════════════════
mkdir -p "$T/h/logs" "$T/h/flags" "$T/tmp" "$T/real" "$T/lane"
unset GH_TOKEN GITHUB_TOKEN GH_DEBUG HARNESS_LANE GH_LEDGER_OFF GH_LEDGER_DEPTH \
  GH_LEDGER_BY_CALLER GH_REST_SHIM_DEPTH GH_CALL_CALLER GH_CALLS_COUNTED
cat > "$T/real/gh" <<'STUB'
#!/bin/bash
case "${1:-}" in auth) echo tok; exit 0 ;; esac
printf '[]'
exit 0
STUB
chmod +x "$T/real/gh"
cat > "$T/lane/pipeline-health.sh" <<'SH'
#!/bin/bash
gh api repos/o/r/pulls/7/reviews >/dev/null
SH
cat > "$T/lane/wrapped-lane.sh" <<'SH'
#!/bin/bash
. "$LOGGER"
gh api repos/o/r/pulls/7 >/dev/null
SH
cat > "$T/lane/bounded-lane.sh" <<'SH'
#!/bin/bash
GH_LEDGER_BY_CALLER=1 timeout 30 gh api -i -X GET repos/o/r/commits/0123456789abcdef0123456789abcdef01234567/status >/dev/null
SH
cat > "$T/lane/local-lane.sh" <<'SH'
#!/bin/bash
gh auth token >/dev/null
SH
chmod +x "$T/lane/"*.sh
calls() { cat "$T/h/logs/gh-calls/"*.log 2>/dev/null; }
run_lane() { # run_lane <script> — the shim first on PATH, then the stub
  [ -d "$T/h/logs/gh-calls" ] && scratch_rm "$T/h/logs/gh-calls"
  env PATH="$(dirname "$SHIM"):$T/real:/usr/bin:/bin" HARNESS="$T/h" TMPDIR="$T/tmp" \
    GH_LEDGER_OFF=1 LOGGER="$DIR/bin/lib/gh-limit-logger.sh" bash "$1" > "$T/out" 2> "$T/err"
}
run_lane "$T/lane/pipeline-health.sh"
[ "$(calls | grep -c .)" = 1 ] && ok || bad "C1: one call must write one logs/gh-calls line, got: [$(calls)] err: $(head -c 300 "$T/err")"
calls | grep -q '^[0-9][0-9]* pipeline-health.sh api repos/o/r/pulls/7/reviews$' \
  && ok || bad "C1: the line must name pipeline-health.sh and the call, got: [$(calls)]"
run_lane "$T/lane/wrapped-lane.sh"
[ "$(calls | grep -c .)" = 1 ] && ok || bad "C2: a call the logger wrapper counted must not be counted again by the shim, got: [$(calls)]"
calls | grep -q ' wrapped-lane.sh api repos/o/r/pulls/7$' && ok || bad "C2: the wrapper's line must stay, got: [$(calls)]"
if command -v timeout >/dev/null 2>&1; then
  run_lane "$T/lane/bounded-lane.sh"
  [ "$(calls | grep -c .)" = 1 ] && ok || bad "C3: a call under timeout must be counted once, got: [$(calls)] err: $(head -c 300 "$T/err")"
  calls | grep -q ' bounded-lane.sh api -i GET:repos/{o}/{r}/commits/{sha}/status$' \
    && ok || bad "C3: the gh_rest shape must carry its METHOD:template, got: [$(calls)]"
fi
run_lane "$T/lane/local-lane.sh"
[ -z "$(calls)" ] && ok || bad "C4: a local command is not a GitHub call, got: [$(calls)]"

# ══ M: the section 13d cache ═════════════════════════════════════════════════
awk '/^# >>> lead merge unqueued \(BH-3778\)/{f=1;next} /^# <<< lead merge unqueued/{exit} f' "$PH" > "$T/block.sh"
[ -s "$T/block.sh" ] || { bad "no lead merge unqueued block in bin/pipeline-health.sh"; echo "pipeline-health-gh-calls.bh-10349: $PASS passed, $FAIL failed"; exit 1; }
mkdir -p "$T/m/fakebin" "$T/m/s" "$T/m/r" "$T/m/h"
NOW=$(date -u +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
SLUG=example-org/proj-os
N=12
sha() { printf '%040d' "$1"; }
# list — N open PRs on main, no queue label; HEADBUMP=<n> gives PR <n> a new head.
list() {
  local i out="" h
  for i in $(seq 1 "$N"); do
    h=$(sha "$i"); [ "${HEADBUMP:-}" = "$i" ] && h=$(sha $((i + 900)))
    out="$out${out:+,}{\"number\":$i,\"draft\":false,\"head\":{\"sha\":\"$h\"},\"base\":{\"ref\":\"main\",\"repo\":{\"default_branch\":\"main\"}},\"labels\":[]}"
  done
  printf '[%s]' "$out" > "$T/m/list.json"
}
st() { # st <sha> <success|none> — the head's combined status
  if [ "$2" = none ]; then
    jq -nc '{statuses:[{context:"ci/x", state:"success", updated_at:"2026-10-01T00:00:00Z"}]}' > "$T/m/s/$1"
  else
    jq -nc --arg u "$(iso $((NOW - 2700)))" '{statuses:[{context:"lead-verdict", state:"success", updated_at:$u}]}' > "$T/m/s/$1"
  fi
}
rv() { # rv <n> <none|stale> — the PR's reviews
  if [ "$2" = stale ]; then
    jq -nc '[{id:91, state:"CHANGES_REQUESTED", commit_id:"ffffffffffffffffffffffffffffffffffffffff",
      body:"<!-- lead-review: x -->", user:{login:"cromford[bot]", type:"Bot"}}]' > "$T/m/r/$1"
  else echo '[]' > "$T/m/r/$1"; fi
}
cat > "$T/m/fakebin/gh" <<'EOF'
#!/bin/bash
A="$*"
printf '%s\n' "$A" >> "$CT/gh-calls.txt"
case "$A" in
  "api repos/example-org/proj-os/pulls?state=open&per_page=100") cat "$CT/list.json" ;;
  "api repos/example-org/proj-os/commits/"*"/status")
    s=${A#api repos/example-org/proj-os/commits/}; s=${s%/status}; cat "$CT/s/$s" 2>/dev/null || exit 1 ;;
  "api repos/example-org/proj-os/pulls/"*"/reviews?per_page=100")
    n=${A#api repos/example-org/proj-os/pulls/}; n=${n%%/*}; cat "$CT/r/$n" 2>/dev/null || exit 1 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$T/m/fakebin/gh"
: > "$T/m/wakes.tsv"
wake() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$T/m/wakes.tsv"; }   # wake <kind> <key> <epoch>
drive() { # drive [VAR=value...] — one run of the block at clock $CLOCK; fresh dedupe every run
  : > "$T/m/alerts.txt"; : > "$T/m/gh-calls.txt"; : > "$T/m/fired.txt"; echo '{}' > "$T/m/dedup.json"
  list
  ( export PATH="$T/m/fakebin:$PATH" CT="$T/m" LEAD_REVIEW_AUTO_REPOS="$SLUG" HARNESS="$T/m/h" \
      HARNESS_TEST_SANDBOX=1 WAKE_BACKSTOP_NOW="$CLOCK" TMPDIR="$T/tmp" HPL_SNAPSHOT=1 "$@"
    H="$T/m/h"; NOW="$CLOCK"; DEDUP="$T/m/dedup.json"; FIRED="$T/m/fired.txt"
    # shellcheck source=bin/lib/lead-stale-review.sh
    . "$DIR/bin/lib/lead-stale-review.sh"
    # shellcheck source=bin/lib/ph-lu-memo.sh
    . "$DIR/bin/lib/ph-lu-memo.sh"
    # shellcheck source=bin/lib/wake-backstop.sh
    . "$DIR/bin/lib/wake-backstop.sh"
    # The wake mirror: a row <kind> <key> <epoch> at or after <since> is a wake.
    prs_wake_seen() {
      [ "${FEED_DOWN:-0}" = 1 ] && return 2
      awk -F'\t' -v k="$2" -v y="$3" -v s="$4" '$1 == k && $2 == y && $3 >= s { f = 1 } END { exit f ? 0 : 1 }' "$T/m/wakes.tsv"
    }
    gh_budget_low() { return 1; }
    alert() { echo "$2" >> "$FIRED"; printf '%s|%s\n' "$2" "$3" >> "$T/m/alerts.txt"; }
    # shellcheck disable=SC1090
    . "$T/block.sh"; echo reached ) > "$T/m/drive.out" 2>&1
}
ghn() { grep -c . "$T/m/gh-calls.txt"; }
keys() { cut -d'|' -f1 "$T/m/alerts.txt" | sort; }
reset_world() {
  [ -d "$T/m/h/state" ] && scratch_rm "$T/m/h/state"
  : > "$T/m/wakes.tsv"; unset HEADBUMP
  local i; for i in $(seq 1 "$N"); do st "$(sha "$i")" success; rv "$i" none; done
  rv 5 stale
}

# M1 — calls over two runs, cache off then on.
reset_world
CLOCK=$NOW;        drive PH_LU_MEMO_BACKSTOP_S=0; OFF1=$(ghn)
grep -qx reached "$T/m/drive.out" && ok || bad "M1: the block did not run to its end: $(cat "$T/m/drive.out")"
CLOCK=$((NOW+600)); drive PH_LU_MEMO_BACKSTOP_S=0; OFF2=$(ghn)
reset_world
CLOCK=$NOW;        drive; ON1=$(ghn); keys > "$T/m/keys.cold"
CLOCK=$((NOW+600)); drive; ON2=$(ghn); keys > "$T/m/keys.warm"
echo "M1: $N PRs, two runs: GitHub calls before (cache off) $OFF1 + $OFF2 = $((OFF1+OFF2)); after (cache on) $ON1 + $ON2 = $((ON1+ON2))"
[ "$OFF1" = $((1 + 2 * N)) ] && ok || bad "M1: a cold run reads the list, one status and one reviews per PR ($((1 + 2 * N))), got $OFF1"
[ "$ON2" = 1 ] && ok || bad "M1: a warm run with no wake must read only the open list, got $ON2: $(cat "$T/m/gh-calls.txt")"
[ $((ON1 + ON2)) -lt $((OFF1 + OFF2)) ] && ok || bad "M1: the cache must cut calls ($((ON1+ON2)) vs $((OFF1+OFF2)))"

# M2 — the warm run raises the same alerts as the cold run.
[ "$(grep -c . "$T/m/keys.cold")" = "$N" ] && ok || bad "M2: the cold run must page all $N PRs, got: $(cat "$T/m/keys.cold")"
cmp -s "$T/m/keys.cold" "$T/m/keys.warm" && ok || bad "M2: the warm run must page the same keys: cold=$(tr '\n' ' ' < "$T/m/keys.cold") warm=$(tr '\n' ' ' < "$T/m/keys.warm")"
grep -q "^leadunqueued:$SLUG#5:$(sha 5 | cut -c1-12):stale-review$" "$T/m/keys.warm" \
  && ok || bad "M2: the stale-review reason must survive the cache: $(cat "$T/m/keys.warm")"

# M3 — a new verdict on a head: its `checks` wake makes the next run read it.
reset_world
st "$(sha 3)" none
CLOCK=$NOW; drive
grep -q "#3:" "$T/m/alerts.txt" && bad "M3: no verdict must not page: $(grep '#3:' "$T/m/alerts.txt")" || ok
st "$(sha 3)" success; wake checks "$(sha 3)" $((NOW + 60))
CLOCK=$((NOW+600)); drive
grep -q "commits/$(sha 3)/status" "$T/m/gh-calls.txt" && ok || bad "M3: a checks wake must re-read the status: $(cat "$T/m/gh-calls.txt")"
grep -q "^leadunqueued:$SLUG#3:$(sha 3 | cut -c1-12)|" "$T/m/alerts.txt" \
  && ok || bad "M3: the new verdict must page in the first run after its wake: $(cat "$T/m/alerts.txt")"
[ "$(grep -c '/status$' "$T/m/gh-calls.txt")" = 1 ] && ok || bad "M3: only the woken head is re-read, got $(grep -c '/status$' "$T/m/gh-calls.txt")"

# M4 — the stale review is dismissed: its `pr` wake re-reads the reviews.
reset_world
CLOCK=$NOW; drive
grep -q "#5:.*:stale-review|" "$T/m/alerts.txt" && ok || bad "M4: #5 must page stale-review first: $(grep '#5:' "$T/m/alerts.txt")"
rv 5 none; wake pr 5 $((NOW + 60))
CLOCK=$((NOW+600)); drive
grep -q "pulls/5/reviews" "$T/m/gh-calls.txt" && ok || bad "M4: a pr wake must re-read the reviews"
grep -q "^leadunqueued:$SLUG#5:$(sha 5 | cut -c1-12)|" "$T/m/alerts.txt" \
  && ok || bad "M4: the dismissed review must give the generic page in the next run: $(grep '#5:' "$T/m/alerts.txt")"
grep -q "#5:.*stale-review" "$T/m/alerts.txt" && bad "M4: the stale-review page must stop: $(grep '#5:' "$T/m/alerts.txt")" || ok

# M5 — a moved head is a different answer: both reads run again.
reset_world
CLOCK=$NOW; drive
HEADBUMP=7; st "$(sha 907)" success
CLOCK=$((NOW+600)); drive HEADBUMP=7
grep -q "commits/$(sha 907)/status" "$T/m/gh-calls.txt" && ok || bad "M5: a new head must read its status"
grep -q "pulls/7/reviews" "$T/m/gh-calls.txt" && ok || bad "M5: a new head must read its reviews"
grep -q "^leadunqueued:$SLUG#7:$(sha 907 | cut -c1-12)|" "$T/m/alerts.txt" && ok || bad "M5: the new head must page: $(grep '#7:' "$T/m/alerts.txt")"

# M6 — a wake feed that cannot tell: every read runs.
reset_world
CLOCK=$NOW; drive
CLOCK=$((NOW+600)); drive FEED_DOWN=1
[ "$(ghn)" = $((1 + 2 * N)) ] && ok || bad "M6: with no feed every read must run ($((1 + 2 * N))), got $(ghn)"

# M7 — a --sections run reads live.
reset_world
CLOCK=$NOW; drive
CLOCK=$((NOW+600)); drive PH_MODE=sections
[ "$(ghn)" = $((1 + 2 * N)) ] && ok || bad "M7: a sections run must read live ($((1 + 2 * N))), got $(ghn)"

# M9 — with the snapshot off (PR_SNAPSHOT=0 leaves HPL_SNAPSHOT unset) it reads live.
reset_world
CLOCK=$NOW; drive
CLOCK=$((NOW+600)); drive HPL_SNAPSHOT=
[ "$(ghn)" = $((1 + 2 * N)) ] && ok || bad "M9: with the snapshot off every read must run ($((1 + 2 * N))), got $(ghn)"

# M8 — past the backstop the answer is read again.
reset_world
CLOCK=$NOW; drive
CLOCK=$((NOW+1900)); drive
[ "$(ghn)" = $((1 + 2 * N)) ] && ok || bad "M8: past PH_LU_MEMO_BACKSTOP_S every read must run, got $(ghn)"

echo "pipeline-health-gh-calls.bh-10349: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
