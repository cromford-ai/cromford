#!/bin/bash
# tests/main-red-skip-by-repo.bh-8706-test.sh — BH-8706: a per-repo override of
# the main-red detector's skip regex, MAIN_RED_SKIP_RE_OVERRIDES.
#
#   THE GAP. The skip regex (e2e|nightly|smoke|publish|deploy) is global, so a
#   repo whose E2E workflow runs on a push to main can never count it as a
#   required check: a red E2E on main froze nothing. The override is a JSON
#   object {"<owner>/<repo>": "<regex>"} (settings row
#   lane.main-red-breaker.main_red_skip_re_overrides, then env, then {}).
#
#   THE PROPERTY UNDER TEST, through the real bin/main-red-detector.sh on a
#   fake runs page where an `E2E` workflow is red twice on main and CI is green:
#     S1  an override without e2e for this repo: the flag goes up, one by-repo line;
#     S2  an override for ANOTHER repo: the global regex, no flag, no by-repo line;
#     S3  {} (and unset): no flag, today's `skip regex` line, no new line;
#     S4  bad JSON: global, no flag, one `override ... is invalid` line;
#     S5  a regex that does not compile: global, no flag, one invalid line;
#     S6  a key in another case: global, no flag (the match is exact);
#     S7  the settings row is read (the knob is registered on main-red-breaker);
#     S8  two repos in one pass: only the overridden one is flagged, so the
#         global regex is restored for the next repo.
# Every timestamp is a literal. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/main-red-skip-by-repo.bh-8706-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || {
  echo "main-red-skip-by-repo.bh-8706-test: SKIPPED — jq/python3/flock is not installed"; exit 0; }
[ -f "$DIR/bin/main-red-detector.sh" ] || {
  echo "FAIL: bin/main-red-detector.sh is missing"; echo "main-red-skip-by-repo.bh-8706: 0 passed, 1 failed"; exit 1; }

mkdir -p "$T/bin/lib" "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin" "$T/pages" "$T/ledger" "$T/catalog"
: > "$T/env/global.env"

cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"

# The coordination-DB client: flag_set records, the ledger verbs keep the
# bin/lib/jobs/jobs.sh contract over files, /api/settings answers $ROWS
# (key=value lines) and every other path is refused.
cat > "$T/bin/jobs-client.sh" <<'SHIM'
flag_set() { printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$PUBLISH_SINK"; return 0; }
_lrow() { printf '%s/%s__%s' "$LEDGER_DIR" "$1" "$(printf '%s' "$2" | tr '/#' '-_')"; }
job_ledger_get() {
  local f; f=$(_lrow "$1" "$2"); [ -f "$f" ] || return 2
  cat "$f"; return 0
}
job_ledger_put() { printf '%s' "$3" > "$(_lrow "$1" "$2")"; return 0; }
_jobs_req() {
  case "$2" in
    /api/settings)
      local out="[]" kv IFS=$'\n'
      for kv in ${ROWS:-}; do
        out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"t"}]')
      done
      printf '{"settings":%s}' "$out" ;;
    *) return 1 ;;
  esac
}
SHIM

# gh shim: a runs read serves $T/pages/<owner>-<repo>.json through the
# detector's own -q expression. A jobs read answers nothing.
cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_SINK"
case "$*" in
  "api repos/"*" -q .id") exit 0 ;;
  *"/actions/runs/"*) echo "" ;;
  *"actions/runs"*)
    slug=""; q=""; prev=""
    for a in "$@"; do
      case "$a" in repos/*/actions/runs) slug=${a#repos/}; slug=${slug%/actions/runs} ;; esac
      [ "$prev" = -q ] && q="$a"; prev="$a"
    done
    f="$T/pages/$(printf '%s' "$slug" | tr '/' '-').json"
    [ -s "$f" ] || exit 0
    if [ -n "$q" ]; then jq -c "$q" "$f"; else cat "$f"; fi ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

# The real lib closure; the stubs above were written first, so they stay.
scratch_install_closure bin/main-red-detector.sh "$T" >/dev/null || bad "setup: detector closure install failed"
cp "$(rendered_registry)" "$T/catalog/lanes.json" || bad "setup: no rendered registry"

A=example-owner/example-repo; B=example-owner/other-repo
E2E=".github/workflows/e2e.yml"; CI=".github/workflows/ci.yml"
page() { # page <slug> — E2E red on the two newest pushes, CI green under them
  local slug="$1" out='[' first=1 spec n p c t sha id
  for spec in "E2E|$E2E|failure|2026-10-28T09:20:00Z|aaaa0002|9002" \
              "E2E|$E2E|failure|2026-10-28T09:10:00Z|aaaa0001|9001" \
              "CI|$CI|success|2026-10-28T09:05:00Z|aaaa0002|9000"; do
    IFS='|' read -r n p c t sha id <<<"$spec"
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --arg slug "$slug" --arg n "$n" --arg p "$p" --arg c "$c" --arg t "$t" --arg sha "$sha" --arg id "$id" '
      {id:($id|tonumber), name:$n, path:$p, status:"completed", conclusion:$c, head_sha:$sha, event:"push",
       created_at:$t, updated_at:$t, run_attempt:1,
       html_url:("https://github.com/" + $slug + "/actions/runs/" + $id)}')
  done
  jq -nc --argjson r "$out]" '{total_count:($r|length), workflow_runs:$r}' \
    > "$T/pages/$(printf '%s' "$slug" | tr '/' '-').json"
}
page "$A"; page "$B"
FA="$T/flags/main-red-example-owner-example-repo"; FB="$T/flags/main-red-example-owner-other-repo"
LOG="$T/logs/main-red.log"

reset_all() {
  : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$T/publish.txt"; : > "$LOG"
  rm -rf "$T"/flags/main-red-* "$T/state/main-red" "$T/state/settings-cache.json" "$T/state/lane-gate" "$T/ledger"
  mkdir -p "$T/ledger"; : > "$T/env/global.env"; ROWS=""
}
drive() { # drive <slug>... — one detector pass over the slugs
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" \
           ALERT_SINK="$T/alerts.txt" PUBLISH_SINK="$T/publish.txt" LEDGER_DIR="$T/ledger" ROWS="${ROWS:-}" \
           MAIN_RED_QUEUE=0 MAIN_RED_TIP_RED=0 MAIN_RED_STALE_GUARD=0 MAIN_RED_INFRA_RERUN=0 HARNESS_REPO=example-owner/harness
    unset GH_TOKEN MAIN_RED_SKIP_RE MAIN_RED_SKIP_RE_OVERRIDES REGISTRY_SOURCE LANE_START_SPREAD_S
    bash "$T/bin/main-red-detector.sh" "$@" >"$T/out.txt" 2>"$T/err.txt" )
}
by_env() { printf "MAIN_RED_SKIP_RE_OVERRIDES='%s'\n" "$1" > "$T/env/global.env"; }
nlines() { grep -cF -- "$1" "$LOG"; }
NOE2E='(nightly|smoke|publish|deploy)'

# ── S1 the override drops e2e for this repo: the red E2E freezes ─────────────
reset_all; by_env "{\"$A\": \"$NOE2E\"}"
drive "$A"
{ [ -f "$FA" ] && grep -q '^workflow=E2E$' "$FA"; } && ok \
  || bad "S1 an override without e2e must let the red E2E freeze: flag=$(cat "$FA" 2>/dev/null) log=$(cat "$LOG") err=$(cat "$T/err.txt")"
[ "$(nlines "$A: skip regex $NOE2E (by-repo)")" = 1 ] && ok || bad "S1 one by-repo line expected: $(grep 'skip regex' "$LOG")"
[ "$(grep -c -- '--critical' "$T/alerts.txt")" = 1 ] && ok || bad "S1 the raise pages once: $(cat "$T/alerts.txt")"

# ── S2 an override for another repo leaves this one on the global regex ──────
reset_all; by_env "{\"$B\": \"$NOE2E\"}"
drive "$A"
[ ! -e "$FA" ] && ok || bad "S2 an override keyed for $B froze $A: $(cat "$FA")"
[ "$(nlines 'by-repo')" = 0 ] && [ "$(nlines 'override')" = 0 ] && ok || bad "S2 no by-repo or override line for $A: $(grep 'skip regex' "$LOG")"

# ── S3 {} and unset: today's behavior and today's log lines ──────────────────
reset_all
drive "$A"
sed -e 's/^[0-9-]* [0-9:]*Z //' -e 's/ in [0-9]*s,/ in Ns,/' "$LOG" > "$T/s3-unset.log"
[ ! -e "$FA" ] && ok || bad "S3 unset froze on a skipped E2E: $(cat "$FA")"
reset_all; by_env '{}'
drive "$A"
sed -e 's/^[0-9-]* [0-9:]*Z //' -e 's/ in [0-9]*s,/ in Ns,/' "$LOG" > "$T/s3-empty.log"
[ ! -e "$FA" ] && ok || bad "S3 {} froze on a skipped E2E: $(cat "$FA")"
[ "$(nlines 'skip regex (e2e|nightly|smoke|publish|deploy) from default')" = 1 ] && ok || bad "S3 today's skip regex line expected once: $(cat "$LOG")"
{ [ "$(nlines 'by-repo')" = 0 ] && [ "$(nlines 'override')" = 0 ]; } && ok || bad "S3 {} must add no line: $(cat "$LOG")"
cmp -s "$T/s3-unset.log" "$T/s3-empty.log" && ok || bad "S3 {} and unset must log the same lines: $(diff "$T/s3-unset.log" "$T/s3-empty.log")"

# ── S4 bad JSON: global, one invalid line ────────────────────────────────────
reset_all; by_env '{not json'
drive "$A"
[ ! -e "$FA" ] && ok || bad "S4 bad JSON must fall back to the global regex: $(cat "$FA")"
[ "$(nlines "skip regex override for $A is invalid — global used")" = 1 ] && ok || bad "S4 one invalid line expected: $(cat "$LOG")"

# ── S5 a regex that does not compile: global, one invalid line ───────────────
reset_all; by_env "{\"$A\": \"(nightly\"}"
drive "$A"
[ ! -e "$FA" ] && ok || bad "S5 a bad regex must fall back to the global regex: $(cat "$FA")"
[ "$(nlines "skip regex override for $A is invalid — global used")" = 1 ] && ok || bad "S5 one invalid line expected: $(cat "$LOG")"
[ "$(nlines 'by-repo')" = 0 ] && ok || bad "S5 a bad regex must not log as applied"

# ── S6 a key in another case does not match ──────────────────────────────────
reset_all; by_env "{\"Example-Owner/Example-Repo\": \"$NOE2E\"}"
drive "$A"
[ ! -e "$FA" ] && ok || bad "S6 a case-different key must not apply: $(cat "$FA")"
[ "$(nlines 'by-repo')" = 0 ] && ok || bad "S6 no by-repo line on a case-different key"

# ── S7 the settings row is read ──────────────────────────────────────────────
reset_all; ROWS="lane.main-red-breaker.main_red_skip_re_overrides={\"$A\": \"$NOE2E\"}"
drive "$A"
[ -f "$FA" ] && ok || bad "S7 the settings row lane.main-red-breaker.main_red_skip_re_overrides was not read: log=$(grep 'skip regex' "$LOG")"

# ── S8 two repos in one pass: the global regex comes back for the next repo ──
reset_all; by_env "{\"$A\": \"$NOE2E\"}"
drive "$A" "$B"
{ [ -f "$FA" ] && [ ! -e "$FB" ]; } && ok \
  || bad "S8 only $A may freeze: A=$([ -f "$FA" ] && echo up) B=$([ -f "$FB" ] && echo up) log=$(cat "$LOG")"
[ "$(nlines "$B: skip regex")" = 0 ] && ok || bad "S8 $B must not log a by-repo regex"

echo "main-red-skip-by-repo.bh-8706: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
