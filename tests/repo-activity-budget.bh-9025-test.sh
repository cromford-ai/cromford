#!/bin/bash
# tests/repo-activity-budget.bh-9025-test.sh — BH-9025: the orchestrator's
# repo-activity block is bounded in time and names every repo it could not read.
#
# WHAT IS PINNED.
#   R: bin/repo-activity.sh. A 2xx body that does not parse prints its
#      UNREADABLE line as before AND one stderr line with the first 200 bytes
#      of the body. A gh_rest read that hit GH_REST_TIMEOUT_S prints
#      `UNREADABLE <ep> HTTP 000 (timeout)`; a network 000 does not say timeout.
#   P: archie_repo_activity_block (bin/lib/archie-repo-activity.sh). One reader
#      per repo, in parallel, each gh call under REPO_ACTIVITY_TIMEOUT_S, the
#      block under REPO_ACTIVITY_BUDGET_S. A repo past the budget is listed as
#      not finished. One summary line per call in logs/repo-activity.log, and
#      the first unparseable line of each bad repo.
#   K: the two knobs come from the lib registry catalog/lanes.d/_lib.orchestrate.json
#      (rows lib.orchestrate.repo_activity_timeout_s / _budget_s); the code
#      literals 5 and 10 are the fallback only.
#
# Nothing touches the network (BH-7563). `gh` is a PATH stub that answers per
# repo from $T/mode/<owner>__<repo>: ok | html | hang | slow | down. `curl` is a
# stub that records a call, and P10 fails if it ran.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/repo-activity-budget.bh-9025-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
command -v jq >/dev/null || { echo "jq missing, skipping"; exit 0; }
command -v timeout >/dev/null || { echo "timeout missing, skipping"; exit 0; }

KNOB_SRC="$SRC/catalog/lanes.d/_lib.orchestrate.json"

# ── the scratch harness ─────────────────────────────────────────────────────
export HARNESS="$T/h"
mkdir -p "$T/h/logs" "$T/h/state" "$T/h/catalog" "$T/tmp" "$T/fakebin" "$T/mode"
for s in bin/repo-activity.sh bin/fleet-conf.sh bin/lib/archie-repo-activity.sh; do
  scratch_install_closure "$s" "$T/h" >/dev/null || bad "F0 closure install $s"
done
cp -r "$SRC/catalog/lanes.d" "$T/h/catalog/"
export TMPDIR="$T/tmp" GH_STUB_DIR="$T" HARNESS_TEST_SANDBOX=1
unset GH_TOKEN GITHUB_TOKEN GH_ETAG GH_REST_TIMEOUT_S REPO_ACTIVITY_MAX_PAGES ARCHIE_REPO_ACTIVITY_LINES \
  ARCHIE_REPO_ACTIVITY_SINCE_H REPO_ACTIVITY_TIMEOUT_S REPO_ACTIVITY_BUDGET_S LANE_REGISTRY JOBS_URL HARNESS_SECRET
export JOBS_URL=""
NOW=$(date -u -d '2026-11-03T12:00:00Z' +%s)   # determinism: ok pinned clock
export REPO_ACTIVITY_NOW="$NOW"
export PATH="$T/fakebin:$PATH"
RA="$T/h/bin/repo-activity.sh"
LOG="$T/h/logs/repo-activity.log"

# ── the stubs ───────────────────────────────────────────────────────────────
# gh: `gh api -i -X GET repos/<o>/<r>/<sub> ...`. One line per call in
# calls.txt: `<mode> <endpoint> GH_REST_TIMEOUT_S=<v>` (the env the reader
# passed down, so K1/K2 can read the per-call timeout the block resolved).
cat > "$T/fakebin/gh" <<'STUB'
#!/bin/bash
S="$GH_STUB_DIR"
ep=""; prev=""
for a in "$@"; do
  case "$prev" in -H|-f|-F|-X) prev="$a"; continue ;; esac
  case "$a" in -*|api) ;; *) [ -z "$ep" ] && ep="$a" ;; esac
  prev="$a"
done
o=$(printf '%s' "$ep" | cut -d/ -f2); r=$(printf '%s' "$ep" | cut -d/ -f3)
mode=$(cat "$S/mode/${o}__${r}" 2>/dev/null || echo missing)
printf '%s %s GH_REST_TIMEOUT_S=%s\n' "$mode" "$ep" "${GH_REST_TIMEOUT_S:-}" >> "$S/calls.txt"
ok_body() {
  printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n'
  case "$ep" in
    */pulls) printf '[{"number":7,"state":"closed","title":"fixture merge","created_at":"2026-11-03T08:00:00Z","updated_at":"2026-11-03T11:00:00Z","closed_at":"2026-11-03T10:30:00Z","merged_at":"2026-11-03T10:30:00Z","merge_commit_sha":"aaaaaaaabbbbbbbbccccccccddddddddeeeeeeee","head":{"sha":"1111111122222222333333334444444455555555"}}]' ;;
    *) printf '{"total_count":0,"workflow_runs":[]}' ;;
  esac
}
case "$mode" in
  ok) ok_body; exit 0 ;;
  slow) case "$ep" in */pulls) sleep 1.5 ;; esac; ok_body; exit 0 ;;
  html)
    printf 'HTTP/2.0 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n\r\n'
    printf '<!DOCTYPE html>\n<html><head><title>Rate limit</title></head>\n<body>'
    for _ in 1 2 3 4 5 6 7 8 9 10; do printf 'fixture page text that runs past two hundred bytes. '; done
    printf '</body></html>\n'
    exit 0 ;;
  hang) sleep 10; exit 0 ;;   # determinism: ok the hang IS the fixture; the GH_REST_TIMEOUT_S / budget kill under test ends it, not a wait for a condition
  down) exit 1 ;;
  *) printf 'HTTP/2.0 404 Not Found\r\nContent-Type: application/json\r\n\r\n{"message":"fixture not found"}'; exit 1 ;;
esac
STUB
chmod +x "$T/fakebin/gh"
# curl: never the network. Any call is recorded and P10 fails on it.
printf '#!/bin/bash\necho "curl $*" >> "%s/net-calls.txt"\nexit 7\n' "$T" > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl"
: > "$T/net-calls.txt"

mode() { printf '%s\n' "$2" > "$T/mode/${1/\//__}"; }
mode fx/ok ok; mode fx/html html; mode fx/hang hang; mode fx/down down
mode fx/slow1 slow; mode fx/slow2 slow; mode fx/slow3 slow

el() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'; }   # elapsed seconds
lt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a < b) }'; }

# ═════ R: bin/repo-activity.sh ═══════════════════════════════════════════════
rc=0; "$RA" fx/html --since 6h > "$T/r1.out" 2> "$T/r1.err" || rc=$?
check "R1 html: rc 75 (got $rc)" '[ "$rc" = 75 ]'
check "R1 html: the UNREADABLE line is kept" 'grep -qx "UNREADABLE repos/fx/html/pulls HTTP 200 (unparseable)" "$T/r1.out"'
check "R1 html: one stderr line with the first bytes" '[ "$(grep -c "unparseable; first 200 bytes: <!DOCTYPE html>" "$T/r1.err")" = 1 ]'
check "R1 html: the stderr line names the repo and endpoint" 'grep -q "^repo-activity: fx/html repos/fx/html/pulls HTTP 200 unparseable; first 200 bytes: " "$T/r1.err"'
BYTES=$(sed -n 's/^.*unparseable; first 200 bytes: //p' "$T/r1.err" | head -n 1)
check "R2 at most 200 bytes logged (got ${#BYTES})" '[ -n "$BYTES" ] && [ "${#BYTES}" -le 200 ] && [ "${#BYTES}" -ge 150 ]'
check "R2 no newline or CR inside the logged bytes" '[ "$(grep -c "unparseable; first 200 bytes" "$T/r1.err")" = 1 ] && ! grep -q $'"'"'\r'"'"' "$T/r1.err"'
check "R2 the body text after the first newline is in the bytes" 'grep -q "<!DOCTYPE html> <html><head><title>Rate limit" <<<"$BYTES"'

t0=$(date +%s.%N)
rc=0; GH_REST_TIMEOUT_S=2 "$RA" fx/hang --since 6h > "$T/r3.out" 2>/dev/null || rc=$?
t1=$(date +%s.%N)
check "R3 hang: rc 75 (got $rc)" '[ "$rc" = 75 ]'
check "R3 hang: ends within 9s (took $(el "$t0" "$t1")s)" 'lt "$(el "$t0" "$t1")" 9'
check "R3 hang: UNREADABLE ... HTTP 000 (timeout)" 'grep -qx "UNREADABLE repos/fx/hang/pulls HTTP 000 (timeout)" "$T/r3.out"'

rc=0; GH_REST_TIMEOUT_S=2 "$RA" fx/down --since 6h > "$T/r4.out" 2>/dev/null || rc=$?
check "R4 network 000: rc 75 and HTTP 000 with no timeout mark" '[ "$rc" = 75 ] && grep -qx "UNREADABLE repos/fx/down/pulls HTTP 000" "$T/r4.out"'

# ═════ P: the block ══════════════════════════════════════════════════════════
fleet() { # fleet <repo...> — the fixture fleet.conf, one project per repo
  local i=0 r
  : > "$T/fleet.conf"
  for r in "$@"; do i=$((i+1)); printf 'fixture-p%s  %s  -  -  %s fixture-box 192.0.2.10\n' "$i" "$r" "$i" >> "$T/fleet.conf"; done
}
fleet fx/ok fx/html fx/hang
export FLEET_CONF="$T/fleet.conf" HARNESS_REPO=fx/ok ARCHIE_REPO_ACTIVITY_SANDBOX=1
# shellcheck source=/dev/null
. "$T/h/bin/lib/archie-repo-activity.sh" 2>/dev/null || bad "P0 cannot source bin/lib/archie-repo-activity.sh"
command -v archie_repo_activity_block >/dev/null 2>&1 || { bad "P0 archie_repo_activity_block is not defined"; echo "repo-activity-budget.bh-9025: $PASS passed, $FAIL failed"; exit 1; }

# P1-P5, P8: timeout 2, budget 4. Run inside $( ), as compose_v2_prompt does:
# a reader that kept the caller's pipe open would hold the substitution open.
: > "$LOG"; : > "$T/calls.txt"
t0=$(date +%s.%N)
B=$(REPO_ACTIVITY_TIMEOUT_S=2 REPO_ACTIVITY_BUDGET_S=4 archie_repo_activity_block 2>/dev/null)
t1=$(date +%s.%N)
printf '%s\n' "$B" > "$T/p.out"
check "P1 the block returns under the budget + 1s (took $(el "$t0" "$t1")s)" 'lt "$(el "$t0" "$t1")" 5'
check "P1 header unchanged" '[ "$(head -n 1 "$T/p.out")" = "## Repo activity (last 6h)" ]'
check "P2 the fx/ok merge line is in the block" 'grep -q "^fx/ok 2026-11-03T10:30:00Z merged #7 aaaaaaaa fixture merge$" "$T/p.out"'
check "P3 fx/html is UNREADABLE (unparseable) in the block" 'grep -qx "fx/html UNREADABLE repos/fx/html/pulls HTTP 200 (unparseable)" "$T/p.out"'
check "P3 the log has the first bytes of fx/html" 'grep -qE "^[0-9TZ:-]+ repo-activity: fx/html repos/fx/html/pulls HTTP 200 unparseable; first 200 bytes: <!DOCTYPE html>" "$LOG"'
check "P4 exactly one unparseable line for fx/html per call" '[ "$(grep -c "fx/html .*unparseable; first 200 bytes" "$LOG")" = 1 ]'
check "P5 fx/hang is timed out after 2s" 'grep -qx "fx/hang UNREADABLE timed out after 2s" "$T/p.out"'
check "P5 no not-finished line when every repo finished" '! grep -q "^(not finished" "$T/p.out"'
check "P8 one summary line: 3 repos, 1 ok, 1 unreadable, 1 timed out" '[ "$(grep -cE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z repo-activity: 3 repos, 1 ok, 1 unreadable, 1 timed out, took [0-9]+\.[0-9] s \(caller [^)]+\)$" "$LOG")" = 1 ]'
check "P8 only the summary and the unparseable line were written" '[ "$(wc -l < "$LOG")" = 2 ]'

# P6: the budget cuts a repo that is still reading.
: > "$LOG"
t0=$(date +%s.%N)
B=$(REPO_ACTIVITY_TIMEOUT_S=30 REPO_ACTIVITY_BUDGET_S=2 archie_repo_activity_block 2>/dev/null)
t1=$(date +%s.%N)
printf '%s\n' "$B" > "$T/p6.out"
check "P6 budget 2: returns under 3s (took $(el "$t0" "$t1")s)" 'lt "$(el "$t0" "$t1")" 3'
check "P6 budget 2: fx/ok events are in" 'grep -q "^fx/ok .* merged #7 " "$T/p6.out"'
check "P6 budget 2: the not-finished list names fx/hang" 'grep -qx "(not finished in 2s: fx/hang)" "$T/p6.out"'
check "P6 budget 2: fx/hang has its own UNREADABLE line" 'grep -qx "fx/hang UNREADABLE not finished in 2s" "$T/p6.out"'
check "P6 budget 2: the summary counts it timed out" 'grep -qE "repo-activity: 3 repos, 1 ok, 1 unreadable, 1 timed out, took" "$LOG"'

# P7: no repo readable: never "no events".
fleet fx/html fx/hang
B=$(HARNESS_REPO=fx/html REPO_ACTIVITY_TIMEOUT_S=1 REPO_ACTIVITY_BUDGET_S=3 archie_repo_activity_block 2>/dev/null)
printf '%s\n' "$B" > "$T/p7.out"
check "P7 all repos failed: no (no events line" '! grep -q "^(no events" "$T/p7.out"'
check "P7 all repos failed: both are UNREADABLE" '[ "$(grep -c "^fx/[a-z]* UNREADABLE " "$T/p7.out")" = 2 ]'

# P7b (negative): an event title with the word timeout is an event, not a timeout.
mkdir -p "$T/fakebin2"
sed 's/fixture merge/fixture timeout UNREADABLE fix/' "$T/fakebin/gh" > "$T/fakebin2/gh"; chmod +x "$T/fakebin2/gh"
fleet fx/ok
: > "$LOG"
B=$(PATH="$T/fakebin2:$PATH" REPO_ACTIVITY_TIMEOUT_S=2 REPO_ACTIVITY_BUDGET_S=4 archie_repo_activity_block 2>/dev/null)
check "P7b a title with timeout stays an event and the repo stays ok" 'grep -q "merged #7 aaaaaaaa fixture timeout UNREADABLE fix" <<<"$B" && grep -q "repo-activity: 1 repos, 1 ok, 0 unreadable, 0 timed out" "$LOG"'

# P7c (negative): a network 000 repo is unreadable, never timed out.
fleet fx/down
: > "$LOG"
B=$(HARNESS_REPO=fx/down REPO_ACTIVITY_TIMEOUT_S=2 REPO_ACTIVITY_BUDGET_S=4 archie_repo_activity_block 2>/dev/null)
check "P7c network 000 is unreadable, not timed out" 'grep -qx "fx/down UNREADABLE repos/fx/down/pulls HTTP 000" <<<"$B" && grep -q "repo-activity: 1 repos, 0 ok, 1 unreadable, 0 timed out" "$LOG"'

# P9: parallel. Three repos whose pulls read takes 1.5s: sequential is 4.5s.
fleet fx/slow1 fx/slow2 fx/slow3
: > "$LOG"
t0=$(date +%s.%N)
B=$(HARNESS_REPO=fx/slow1 REPO_ACTIVITY_TIMEOUT_S=5 REPO_ACTIVITY_BUDGET_S=10 archie_repo_activity_block 2>/dev/null)
t1=$(date +%s.%N)
check "P9 three 1.5s repos in under 3.5s (took $(el "$t0" "$t1")s)" 'lt "$(el "$t0" "$t1")" 3.5'
check "P9 all three repos ok, in repo-list order" '[ "$(grep -oE "^fx/slow[0-9] [^ ]+ merged" <<<"$B" | cut -d" " -f1 | tr "\n" " ")" = "fx/slow1 fx/slow2 fx/slow3 " ] && grep -q "3 repos, 3 ok, 0 unreadable, 0 timed out" "$LOG"'

# P11 (D2): the production caller. compose_v2_prompt (the real function text of
# bin/orchestrate.sh) carries the block, and it is bounded there too.
fleet fx/ok fx/hang
FN=$(sed -n '/^compose_v2_prompt() {/,/^}/p' "$SRC/bin/orchestrate.sh")
mkdir -p "$T/orc"
: > "$LOG"
t0=$(date +%s.%N)
V2=$(env HARNESS="$T/h" ARCHIE_ORC_DIR="$T/orc" ORC_TURN_STATE="$T/orc/STATE.md" TEXT=hi META_TRANSPORT=telegram ORIGIN="" \
  REPO_ACTIVITY_TIMEOUT_S=30 REPO_ACTIVITY_BUDGET_S=2 bash -c "$FN"$'\n''compose_v2_prompt' 2>/dev/null)
t1=$(date +%s.%N)
check "P11 compose_v2_prompt returns under 3s with a hanging repo (took $(el "$t0" "$t1")s)" 'lt "$(el "$t0" "$t1")" 3'
check "P11 the chat-turn prompt carries the fx/ok merge" 'grep -q "^fx/ok 2026-11-03T10:30:00Z merged #7" <<<"$V2"'
check "P11 the chat-turn prompt names the unfinished repo" 'grep -qx "(not finished in 2s: fx/hang)" <<<"$V2"'
check "P11 the summary line names the caller" 'grep -q "repo-activity: 2 repos, 1 ok, 0 unreadable, 1 timed out, took .* (caller " "$LOG"'

# ═════ K: the knobs ══════════════════════════════════════════════════════════
fleet fx/ok
check "K3 the registry defaults are 5 and 10" '[ "$(jq -c "[.libs[]|select(.id==\"orchestrate\")|.knobs[]|.default]" "$KNOB_SRC" 2>/dev/null)" = "[5,10]" ]'
check "K3 the registry rows name the block file" '[ "$(jq -r ".libs[]|select(.id==\"orchestrate\")|.file" "$KNOB_SRC" 2>/dev/null)" = "bin/lib/archie-repo-activity.sh" ]'

# K1: no env, no settings row: the per-call timeout reaching gh is 5.
: > "$T/calls.txt"
B=$(archie_repo_activity_block 2>/dev/null)
check "K1 no env, no row: the gh calls run under GH_REST_TIMEOUT_S=5" '[ -s "$T/calls.txt" ] && [ "$(grep -vc "GH_REST_TIMEOUT_S=5$" "$T/calls.txt")" = 0 ]'

# K2: operator rows in the settings cache win; the block reads them.
REG="$T/lanes.json"
"$SRC/bin/lanes-build.sh" --root "$T/h" --to "$REG" >/dev/null 2>&1 || bad "K2 lanes-build --to failed"
jq -n --argjson fa "$NOW" '{fetched_at:$fa, values:{"lib.orchestrate.repo_activity_timeout_s":"3","lib.orchestrate.repo_activity_budget_s":"2"}, seeded:{}}' \
  > "$T/h/state/settings-cache.json"
fleet fx/ok fx/hang
: > "$T/calls.txt"
B=$(LANE_GATE_NOW="$NOW" LANE_REGISTRY="$REG" archie_repo_activity_block 2>/dev/null)
check "K2 the row 3 reaches gh as GH_REST_TIMEOUT_S=3" 'grep -q "^ok repos/fx/ok/pulls GH_REST_TIMEOUT_S=3$" "$T/calls.txt"'
check "K2 the row budget 2 names the unfinished repo" 'grep -qx "(not finished in 2s: fx/hang)" <<<"$B"'
check "K2 an env value does not beat an operator row" '[ "$(LANE_GATE_NOW="$NOW" LANE_REGISTRY="$REG" REPO_ACTIVITY_BUDGET_S=9 archie_repo_activity_block 2>/dev/null | grep -c "^(not finished in 2s: fx/hang)$")" = 1 ]'
rm -f "$T/h/state/settings-cache.json"

# K3: bad values are the default.
fleet fx/ok
: > "$T/calls.txt"; : > "$LOG"
B=$(REPO_ACTIVITY_TIMEOUT_S=abc REPO_ACTIVITY_BUDGET_S=0 archie_repo_activity_block 2>/dev/null)
check "K3 timeout abc is the default 5" '[ -s "$T/calls.txt" ] && [ "$(grep -vc "GH_REST_TIMEOUT_S=5$" "$T/calls.txt")" = 0 ]'
check "K3 budget 0 is not a 0s cut (the repo is read)" 'grep -q "^fx/ok .* merged #7" <<<"$B" && grep -q "1 repos, 1 ok" "$LOG"'
: > "$T/calls.txt"
B=$(REPO_ACTIVITY_TIMEOUT_S=61 archie_repo_activity_block 2>/dev/null)
check "K3 timeout 61 (over 60) is the default 5" '[ "$(grep -vc "GH_REST_TIMEOUT_S=5$" "$T/calls.txt")" = 0 ]'

# K4: the sandbox short-circuit is still first: no reader, no log line.
: > "$T/calls.txt"; : > "$LOG"
B=$(ARCHIE_REPO_ACTIVITY_SANDBOX=0 archie_repo_activity_block 2>/dev/null)
check "K4 sandbox without the opt-in: no read and no log line" '[ ! -s "$T/calls.txt" ] && [ ! -s "$LOG" ] && grep -qx "(not read: test sandbox)" <<<"$B"'

# ═════ P10: 0 network calls ══════════════════════════════════════════════════
check "P10 no curl ran" '[ ! -s "$T/net-calls.txt" ]'
check "P10 every gh call was the stub (a fixture repo)" '[ "$(grep -vc " repos/fx/" "$T/calls.txt")" = 0 ]'

echo "repo-activity-budget.bh-9025: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
