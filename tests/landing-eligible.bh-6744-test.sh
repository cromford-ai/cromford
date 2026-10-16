#!/bin/bash
# tests/landing-eligible.bh-6744-test.sh — BH-6744 (wave 1 of #6541): the
# landing contract (bin/lib/mc/landing.sh) and its shadow decisions.
#
# WHAT IS DRIVEN.
#   Unit cases source the REAL bin/lib/mc/landing.sh, bin/lib/lead-authority.sh
#   (_la_files, _la_match), bin/lib/main-red-gate.sh (flags under $T),
#   bin/lib/mc-prequeue.sh (pq_key, pq_cache_put, pq_cache_get) and
#   bin/lib/queue-status-contexts.sh. Only the transports are stubbed: la_globs,
#   gh_rest, _jobs_req, ae_mergify_admit_checks, mc_attempt_has/put, mc_log.
#   L6 runs the REAL bin/merge-conductor.sh over tests/lib/nhv-conductor-fixture.sh.
#   L1 every condition true -> ok; a verdict exactly at the max age -> ok
#   L2 a protected path (filename, or a rename's previous_filename) -> protected-path
#   L3 queue-solo -> solo; fix-main-red -> fix-main-red
#   L4 61 min old (knob 60) -> prequeue-stale; knob 120 -> ok; only could-not-run -> prequeue-missing
#   L5 a main-red flag -> main-red, and no GitHub or jobs read was made
#   L6 the conductor tick: queue -> 0 POST, 0 LANDING line; shadow -> 1 POST and
#      1 line that agree, the same label POST, row QUEUED, no `pr merge`
#   L7 landing_shadow dedupes per (key, head, mode) and marks step landing-shadow;
#      queue mode reads nothing and marks no step
#   L8 landing_mode values; one bad-value line per project per day
#   L9 tier-high, tier-unknown, lead-verdict, fast-checks, unreadable-status,
#      unreadable-checks, and a failed POST -> one LANDING_ROW_FAILED line, rc 0
#   K1 the two knob fragments, and the per-project settings key fits 64 chars
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/landing-eligible.bh-6744-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

REPO=example-org/landing-os
PROJ=landing
PR=6744
HEAD=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa6744
OLDHEAD=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb6744
MAIN=cccccccccccccccccccccccccccccccccccc6744
NOW=2000000000
FX="$T/fx"
mkdir -p "$T/u/flags" "$T/u/state" "$FX" || exit 1

# ── the unit shell: real libs, stubbed transports ────────────────────────────
export HARNESS="$T/u" MC_STATE_DIR="$T/u/state" LANDING_NOW="$NOW"
unset MC_LANDING_MODE MC_LANDING_PQ_AGE_MIN
# shellcheck source=bin/lib/main-red-gate.sh
. "$DIR/bin/lib/main-red-gate.sh" || exit 1
# shellcheck source=bin/lib/lead-authority.sh
. "$DIR/bin/lib/lead-authority.sh" || exit 1
# shellcheck source=bin/lib/mc-prequeue.sh
. "$DIR/bin/lib/mc-prequeue.sh" || exit 1
# shellcheck source=bin/lib/queue-status-contexts.sh
. "$DIR/bin/lib/queue-status-contexts.sh" || exit 1
LANDING_LIB="$DIR/bin/lib/mc/landing.sh"
if [ -r "$LANDING_LIB" ]; then
  # shellcheck source=bin/lib/mc/landing.sh
  . "$LANDING_LIB" || exit 1
fi
unset -f lane_knob 2>/dev/null
MC_MAIN_RED_LABEL=fix-main-red

la_globs() { [ -e "$FX/globs.rc" ] && return "$(cat "$FX/globs.rc")"; cat "$FX/globs" 2>/dev/null; return 0; }
gh_rest() {
  local p="$2"
  printf '%s\n' "$p" >> "$T/gh.log"
  GH_REST_STATUS=200
  case "$p" in
    */commits/*/status)
      if [ "$(cat "$FX/status.code" 2>/dev/null)" = 500 ]; then GH_REST_STATUS=500; return 1; fi
      cat "$FX/status.json" ;;
    */check-runs*) cat "$FX/checks.json" ;;
    */files*page=1) cat "$FX/files.json" ;;
    */files*) echo '[]' ;;
    *) export GH_REST_STATUS=404; return 1 ;;
  esac
}
_jobs_req() {
  printf '%s %s\n' "$1" "$2" >> "$T/jobs.log"
  case "$1 $2" in
    "GET /api/risk-tiers"*) JOBS_HTTP=200; cat "$FX/tiers.json"; return 0 ;;
    "POST /api/landing-decisions")
      printf '%s\n' "$3" >> "$T/posts.txt"
      if [ -e "$FX/post500" ]; then JOBS_HTTP=500; return 1; fi
      JOBS_HTTP=201; echo '{"ok":true,"id":1}'; return 0 ;;
  esac
  JOBS_HTTP=404; return 2
}
ae_mergify_admit_checks() { printf '%s\n' lint 'unit tests' lead-verdict prequeue-verdict; }
MC_ATTEMPTS="$T/attempts.txt"; : > "$MC_ATTEMPTS"
mc_attempt_has() { grep -qxF "$1" "$MC_ATTEMPTS"; }
mc_attempt_put() { echo "$1" >> "$MC_ATTEMPTS"; }
mc_log() { echo "$*" >> "$T/mc.log"; }
mc_step() { echo "$1" >> "$T/steps.txt"; }

no_pq() { scratch_rm "$T/u/state/prequeue"; }
pq_put() { # pq_put <state> <age_s> [head]
  pq_cache_put "$(pq_key "$REPO" "$PR" "${3:-$HEAD}" "$MAIN")" "$1" "$((NOW - $2))" run-fixture "s1"
}
green_fixture() {
  no_pq; scratch_rm "$T/u/flags"; scratch_rm "$FX"; mkdir -p "$FX" "$T/u/flags"
  : > "$T/gh.log"; : > "$T/jobs.log"; : > "$T/posts.txt"; : > "$T/mc.log"; : > "$MC_ATTEMPTS"; : > "$T/steps.txt"
  command -v main_red_forget >/dev/null && main_red_forget
  unset MC_LANDING_PQ_AGE_MIN MC_LANDING_MODE
  printf 'bin/merge-conductor.sh\nworker/**\n' > "$FX/globs"
  echo '{"state":"success","statuses":[{"context":"ci","state":"success"},{"context":"lead-verdict","state":"success"}]}' > "$FX/status.json"
  echo '{"total_count":3,"check_runs":[
    {"name":"lint","status":"completed","conclusion":"success","started_at":"2026-10-15T10:00:00Z"},
    {"name":"unit tests","status":"completed","conclusion":"failure","started_at":"2026-10-15T09:00:00Z"},
    {"name":"unit tests","status":"completed","conclusion":"success","started_at":"2026-10-15T10:00:00Z"}]}' > "$FX/checks.json"
  echo '[{"filename":"docs/landing.md"},{"filename":"tests/x-test.sh"}]' > "$FX/files.json"
  printf '{"rows":[{"head_sha":"%s","tier":"low"},{"head_sha":"%s","tier":"high"}]}\n' "$HEAD" "$OLDHEAD" > "$FX/tiers.json"
  pq_put red 60
  pq_put green 600
}
# elig [labels] — runs landing_eligible in THIS shell; sets RC, OUT, REASON.
elig() {
  RC=0; landing_eligible "$REPO" "$PR" "$HEAD" "$PROJ" "${1:-}" > "$T/out" 2>"$T/err" || RC=$?
  OUT=$(cat "$T/out"); REASON="${LANDING_REASON:-}"
}
expect() { # expect <case> <token> [labels]
  elig "${3:-}"
  if [ "$2" = ok ]; then
    [ "$RC" = 0 ] && [ "$OUT" = ok ] && [ "$REASON" = ok ] && ok || bad "$1: want rc 0 ok (rc $RC, out '$OUT', reason '$REASON', err $(head -c 300 "$T/err"))"
  else
    [ "$RC" = 1 ] && [ "$OUT" = "$2" ] && [ "$REASON" = "$2" ] && ok || bad "$1: want rc 1 $2 (rc $RC, out '$OUT', reason '$REASON', err $(head -c 300 "$T/err"))"
  fi
}

if ! command -v landing_eligible >/dev/null 2>&1; then
  bad "bin/lib/mc/landing.sh is missing or defines no landing_eligible — every L case below is red"
fi

# ── L1 ──────────────────────────────────────────────────────────────────────
green_fixture
expect L1 ok
grep -q "repos/$REPO/commits/$HEAD/status" "$T/gh.log" && grep -q "check-runs" "$T/gh.log" && grep -q "pulls/$PR/files" "$T/gh.log" \
  && ok || bad "L1: the decision read status, check-runs and files ($(tr '\n' ' ' < "$T/gh.log"))"
grep -q "^GET /api/risk-tiers?repo=example-org%2Flanding-os&pr=$PR&limit=50$" "$T/jobs.log" && ok || bad "L1: the tier read names repo and pr ($(cat "$T/jobs.log"))"
green_fixture; no_pq; pq_put green 3600
expect "L1 inclusive edge (exactly 60 min)" ok
green_fixture; printf '' > "$FX/globs"
expect "L1 a repo with no globs" ok

# ── L2 ──────────────────────────────────────────────────────────────────────
green_fixture; echo '[{"filename":"docs/a.md"},{"filename":"worker/jobs/src/index.js"}]' > "$FX/files.json"
expect "L2 protected filename" protected-path
green_fixture; echo '[{"filename":"docs/b.md","previous_filename":"bin/merge-conductor.sh"}]' > "$FX/files.json"
expect "L2 protected previous_filename" protected-path
green_fixture; echo 2 > "$FX/globs.rc"
expect "L2 globs unreadable" unreadable-paths

# ── L3 ──────────────────────────────────────────────────────────────────────
green_fixture; expect "L3 queue-solo" solo "hotfix,queue-solo"
[ ! -s "$T/gh.log" ] && ok || bad "L3: a solo refusal reads nothing from GitHub ($(cat "$T/gh.log"))"
green_fixture; expect "L3 fix-main-red" fix-main-red "fix-main-red"
green_fixture; expect "L3 a label that only contains the word" ok "fix-main-red-later,queue-solo-x"

# ── L4 ──────────────────────────────────────────────────────────────────────
green_fixture; no_pq; pq_put green 3660
expect "L4 61 min old" prequeue-stale
MC_LANDING_PQ_AGE_MIN=120 expect "L4 knob 120" ok
green_fixture; no_pq; pq_put could-not-run 60; pq_put pending 30 "$HEAD"
expect "L4 only could-not-run/pending" prequeue-missing
green_fixture; no_pq; pq_put green 60 "$OLDHEAD"
expect "L4 green only for another head" prequeue-missing
green_fixture; no_pq; pq_cache_put "$(pq_key "$REPO" "$PR" "$HEAD" "$MAIN")" no-selection "$((NOW - 60))" run-fixture ""
printf 'stale why\n' > "$(pq_key "$REPO" "$PR" "$HEAD" "$MAIN").why"
expect "L4 no-selection counts; a sidecar file is not a verdict" ok
green_fixture; MC_LANDING_PQ_AGE_MIN=banana expect "L4 a bad knob reads 60 (10 min old)" ok
green_fixture; no_pq; pq_put green 3660
MC_LANDING_PQ_AGE_MIN=0 expect "L4 a knob under 1 reads 60" prequeue-stale

# ── L5 ──────────────────────────────────────────────────────────────────────
green_fixture; touch "$T/u/flags/main-red-$PROJ"
expect "L5 main-red flag" main-red
[ ! -s "$T/gh.log" ] && [ ! -s "$T/jobs.log" ] && ok || bad "L5: the freeze is checked first: no read ($(cat "$T/gh.log" "$T/jobs.log"))"
green_fixture; touch "$T/u/flags/main-red-example-org-landing-os"
expect "L5 main-red flag by slug" main-red

# ── L9 ──────────────────────────────────────────────────────────────────────
green_fixture; printf '{"rows":[{"head_sha":"%s","tier":"high"}]}\n' "$HEAD" > "$FX/tiers.json"
expect "L9 tier high" tier-high
green_fixture; printf '{"rows":[{"head_sha":"%s","tier":"medium"}]}\n' "$HEAD" > "$FX/tiers.json"
expect "L9 tier medium" ok
green_fixture; printf '{"rows":[{"head_sha":"%s","tier":"low"}]}\n' "$OLDHEAD" > "$FX/tiers.json"
expect "L9 a tier row for an older head only" tier-unknown
green_fixture; echo 'not json' > "$FX/tiers.json"
expect "L9 tier payload unreadable" unreadable-tier
green_fixture; echo '{"state":"failure","statuses":[{"context":"lead-verdict","state":"failure"}]}' > "$FX/status.json"
expect "L9 lead-verdict failure" lead-verdict
green_fixture; echo '{"state":"success","statuses":[{"context":"ci","state":"success"}]}' > "$FX/status.json"
expect "L9 lead-verdict absent" lead-verdict
green_fixture; echo 500 > "$FX/status.code"
expect "L9 status read 500" unreadable-status
green_fixture; echo '{"total_count":2,"check_runs":[
    {"name":"lint","status":"completed","conclusion":"success","started_at":"2026-10-15T10:00:00Z"},
    {"name":"unit tests","status":"in_progress","conclusion":null,"started_at":"2026-10-15T10:00:00Z"}]}' > "$FX/checks.json"
expect "L9 one fast check in progress" fast-checks
green_fixture; echo '{"total_count":1,"check_runs":[
    {"name":"lint","status":"completed","conclusion":"success","started_at":"2026-10-15T10:00:00Z"}]}' > "$FX/checks.json"
expect "L9 a fast check absent" fast-checks
green_fixture; echo '{"total_count":9,"check_runs":[
    {"name":"lint","status":"completed","conclusion":"success","started_at":"2026-10-15T10:00:00Z"},
    {"name":"unit tests","status":"completed","conclusion":"success","started_at":"2026-10-15T10:00:00Z"}]}' > "$FX/checks.json"
expect "L9 check-runs page short of total_count" unreadable-checks
green_fixture; ae_mergify_admit_checks() { return 1; }
expect "L9 admission checks unreadable" unreadable-checks
ae_mergify_admit_checks() { printf '%s\n' lead-verdict prequeue-verdict; }
expect "L9 only status contexts, no fast check left" unreadable-checks
ae_mergify_admit_checks() { printf '%s\n' lint 'unit tests' lead-verdict prequeue-verdict; }

# ── L7 ──────────────────────────────────────────────────────────────────────
lines() { local c; c=$(grep -c ' LANDING ' "$T/mc.log" 2>/dev/null); echo "${c:-0}"; }
posts() { local c; c=$(grep -c . "$T/posts.txt" 2>/dev/null); echo "${c:-0}"; }
KEY="$REPO#$PR"
green_fixture
MC_LANDING_MODE=shadow landing_shadow "$PROJ" "$REPO" "$PR" "$HEAD" "$KEY" ""; RC1=$?
MC_LANDING_MODE=shadow landing_shadow "$PROJ" "$REPO" "$PR" "$HEAD" "$KEY" ""
[ "$RC1" = 0 ] && [ "$(lines)" = 1 ] && [ "$(posts)" = 1 ] && ok || bad "L7: twice on one head = 1 line, 1 POST (rc $RC1, lines $(lines), posts $(posts); $(cat "$T/mc.log"))"
[ "$(cat "$T/steps.txt")" = "landing-shadow
landing-shadow" ] && ok || bad "L7: each shadow call marks the conductor step landing-shadow ($(cat "$T/steps.txt"))"
grep -qxF "$KEY LANDING would=direct reason=ok mode=shadow head=${HEAD:0:12}" "$T/mc.log" && ok || bad "L7: the line format ($(cat "$T/mc.log"))"
jq -e --arg r "$REPO" --arg h "$HEAD" '.repo==$r and .number==6744 and .head==$h and .mode=="shadow" and .would=="direct" and .reason=="ok"' "$T/posts.txt" >/dev/null 2>&1 \
  && ok || bad "L7: the POST body ($(cat "$T/posts.txt"))"
grep -qxF "landing $KEY $HEAD shadow" "$MC_ATTEMPTS" && ok || bad "L7: the ledger line ($(cat "$MC_ATTEMPTS"))"
pq_put green 60 "$OLDHEAD"; printf '{"rows":[{"head_sha":"%s","tier":"low"}]}\n' "$OLDHEAD" > "$FX/tiers.json"
MC_LANDING_MODE=shadow landing_shadow "$PROJ" "$REPO" "$PR" "$OLDHEAD" "$KEY" "queue-solo"
[ "$(lines)" = 2 ] && [ "$(posts)" = 2 ] && ok || bad "L7: a new head is a second decision (lines $(lines), posts $(posts))"
grep -qxF "$KEY LANDING would=queue reason=solo mode=shadow head=${OLDHEAD:0:12}" "$T/mc.log" && ok || bad "L7: would=queue for a refusal ($(cat "$T/mc.log"))"
MC_LANDING_MODE=optimistic landing_shadow "$PROJ" "$REPO" "$PR" "$HEAD" "$KEY" ""
[ "$(lines)" = 3 ] && [ "$(posts)" = 3 ] && grep -q "mode=optimistic" "$T/mc.log" && ok || bad "L7: optimistic on the first head is a third (lines $(lines), posts $(posts))"
: > "$T/gh.log"; : > "$T/jobs.log"; : > "$MC_ATTEMPTS"; : > "$T/steps.txt"
MC_LANDING_MODE=queue landing_shadow "$PROJ" "$REPO" "$PR" "$HEAD" "$KEY" ""; RCQ=$?
[ "$RCQ" = 0 ] && [ ! -s "$T/gh.log" ] && [ ! -s "$T/jobs.log" ] && [ ! -s "$MC_ATTEMPTS" ] && [ ! -s "$T/steps.txt" ] && [ "$(lines)" = 3 ] && ok \
  || bad "L7: mode queue reads nothing and writes nothing (rc $RCQ; gh $(cat "$T/gh.log"); jobs $(cat "$T/jobs.log"))"
landing_shadow "$PROJ" "$REPO" "$PR" "$HEAD" "$KEY" ""
[ ! -s "$T/gh.log" ] && [ ! -s "$T/jobs.log" ] && [ "$(lines)" = 3 ] && ok || bad "L7: no knob at all is queue: nothing read"

# ── L9 (POST) ───────────────────────────────────────────────────────────────
green_fixture; touch "$FX/post500"
RC=0; MC_LANDING_MODE=shadow landing_shadow "$PROJ" "$REPO" "$PR" "$HEAD" "$KEY" "" || RC=$?
[ "$RC" = 0 ] && [ "$(grep -c "^$KEY LANDING_ROW_FAILED http=500" "$T/mc.log")" = 1 ] && [ "$(lines)" = 1 ] && ok \
  || bad "L9: a failed POST is one LANDING_ROW_FAILED line, rc 0 (rc $RC; $(cat "$T/mc.log"))"
MC_LANDING_MODE=shadow landing_shadow "$PROJ" "$REPO" "$PR" "$HEAD" "$KEY" ""
[ "$(posts)" = 1 ] && ok || bad "L9: a failed POST is not retried on the same head (posts $(posts))"

# ── L8 ──────────────────────────────────────────────────────────────────────
green_fixture
m() { MC_LANDING_MODE="$1" landing_mode "$PROJ"; }
[ "$(m shadow)" = shadow ] && [ "$(m optimistic)" = optimistic ] && [ "$(m ' Shadow ')" = shadow ] && [ "$(m QUEUE)" = queue ] \
  && ok || bad "L8: shadow/optimistic/' Shadow '/QUEUE -> '$(m shadow)' '$(m optimistic)' '$(m ' Shadow ')' '$(m QUEUE)'"
[ ! -s "$T/mc.log" ] && ok || bad "L8: a good value logs nothing ($(cat "$T/mc.log"))"
[ "$(m '')" = queue ] && [ "$(landing_mode "$PROJ")" = queue ] && [ ! -s "$T/mc.log" ] && ok || bad "L8: empty and unset are queue, with no line"
A=$(m fast); B=$(m fast)
[ "$A" = queue ] && [ "$B" = queue ] && ok || bad "L8: fast -> queue ('$A' '$B')"
[ "$(grep -c 'LANDING_MODE_BAD' "$T/mc.log")" = 1 ] && ok || bad "L8: one bad-value line for two calls on one day ($(cat "$T/mc.log"))"
LANDING_NOW=$((NOW + 86400)) m fast >/dev/null
[ "$(grep -c 'LANDING_MODE_BAD' "$T/mc.log")" = 2 ] && ok || bad "L8: the next UTC day logs again ($(cat "$T/mc.log"))"
[ "$(MC_LANDING_PQ_AGE_MIN=45 landing_pq_age_min "$PROJ")" = 45 ] && [ "$(MC_LANDING_PQ_AGE_MIN=x landing_pq_age_min "$PROJ")" = 60 ] \
  && [ "$(landing_pq_age_min "$PROJ")" = 60 ] && ok || bad "L8: landing_pq_age_min 45 / x / unset"
# lane_knob, when the conductor has it, is the reader (per-project row first).
lane_knob() { [ "$1/$2/$3" = "merge-conductor/MC_LANDING_MODE/$PROJ" ] && { echo Optimistic; return 0; }; echo queue; }
[ "$(MC_LANDING_MODE=shadow landing_mode "$PROJ")" = optimistic ] && [ "$(landing_mode other)" = queue ] && ok || bad "L8: lane_knob is read per project"
unset -f lane_knob

# ── K1 ──────────────────────────────────────────────────────────────────────
KD="$DIR/catalog/lanes.d/merge-conductor.knobs.d"
jq -e '.env=="MC_LANDING_MODE" and .type=="string" and .default=="queue" and .read_in=="bin/lib/mc/landing.sh" and (.settable // true)' "$KD/MC_LANDING_MODE.json" >/dev/null 2>&1 \
  && ok || bad "K1: MC_LANDING_MODE.json (string, default queue, read_in landing.sh, settable)"
jq -e '.env=="MC_LANDING_PQ_AGE_MIN" and .type=="int" and .default==60 and .min==1 and .read_in=="bin/lib/mc/landing.sh"' "$KD/MC_LANDING_PQ_AGE_MIN.json" >/dev/null 2>&1 \
  && ok || bad "K1: MC_LANDING_PQ_AGE_MIN.json (int, default 60, min 1, read_in landing.sh)"
K=$( . "$DIR/bin/lib/lane-gate.sh" >/dev/null 2>&1; _lg_setting_key merge-conductor MC_LANDING_PQ_AGE_MIN project-8 ); KRC=$?
[ "$KRC" = 0 ] && [ "$K" = lane.merge-conductor.project-8.mc_landing_pq_age_min ] && ok || bad "K1: the longest per-project key fits (rc $KRC, '$K')"
# The code fallbacks equal the registry defaults.
[ "$(landing_mode "$PROJ")" = "$(jq -r .default "$KD/MC_LANDING_MODE.json" 2>/dev/null)" ] \
  && [ "$(landing_pq_age_min "$PROJ")" = "$(jq -r .default "$KD/MC_LANDING_PQ_AGE_MIN.json" 2>/dev/null)" ] && ok || bad "K1: code fallbacks equal the registry defaults"

# ── L6: the real conductor tick ─────────────────────────────────────────────
unset HARNESS MC_STATE_DIR LANDING_NOW MC_MAIN_RED_LABEL
unset -f gh_rest _jobs_req mc_log mc_attempt_has mc_attempt_put la_globs ae_mergify_admit_checks
if command -v flock >/dev/null; then
  # shellcheck source=tests/lib/gh-list-bridge.sh
  . "$DIR/tests/lib/gh-list-bridge.sh" || exit 1
  # shellcheck source=tests/lib/verdict-fixture.sh
  . "$DIR/tests/lib/verdict-fixture.sh" || exit 1
  vpf_export || exit 1
  # shellcheck source=tests/lib/nhv-conductor-fixture.sh
  . "$DIR/tests/lib/nhv-conductor-fixture.sh" || exit 1
  nhvf_setup || { echo "FAIL: fixture setup"; exit 1; }
  # The jobs transport: record every landing POST body, answer the tier read,
  # and hand everything else to the fixture's own fake curl.
  mv "$T/fakebin/curl" "$T/fakebin/curl.nhv"
  cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET; B=""
for ((i=1; i<=\$#; i++)); do
  a="\${!i}"; j=\$((i+1))
  case "\$a" in -X) M="\${!j}" ;; --data-binary) B="\${!j}" ;; esac
done
case "\$M \$URL" in
  "POST "*/api/landing-decisions) printf '%s\n' "\$B" >> "$T/l6-posts.txt"; printf '{"ok":true,"id":1}\n201\n'; exit 0 ;;
  "GET "*/api/risk-tiers*) printf '{"rows":[]}\n200\n'; exit 0 ;;
esac
exec "$T/fakebin/curl.nhv" "\$@"
EOF
  chmod +x "$T/fakebin/curl"
  export JOBS_URL=https://jobs.example.test
  H61=dddddddddddddddddddddddddddddddddddd0061
  nhvf_pr 61 "$H61"
  l6_run() { # l6_run <mode>
    nhvf_reset
    nhvf_la 0 "no protected path"; : > "$T/l6-posts.txt"; nhvf_clear
    MC_LANDING_MODE="$1" nhvf_tick
    cp "$T/label-adds.txt" "$T/l6-adds-$1.txt"
  }
  l6_run queue
  [ "$(nhvf_field 61 2)" = QUEUED ] && ok || bad "L6 queue: the row is QUEUED (got '$(nhvf_field 61 2)'; $(grep -F '#61' "$CLOG" | tail -4))"
  [ "$(grep -c . "$T/l6-adds-queue.txt")" = 1 ] && ok || bad "L6 queue: one label POST ($(cat "$T/l6-adds-queue.txt"))"
  [ ! -s "$T/l6-posts.txt" ] && [ "$(grep -c ' LANDING ' "$CLOG")" = 0 ] && ok || bad "L6 queue: no POST, no LANDING line ($(cat "$T/l6-posts.txt"); $(grep LANDING "$CLOG"))"
  l6_run shadow
  [ "$(nhvf_field 61 2)" = QUEUED ] && ok || bad "L6 shadow: the row is QUEUED (got '$(nhvf_field 61 2)')"
  cmp -s "$T/l6-adds-queue.txt" "$T/l6-adds-shadow.txt" && ok || bad "L6 shadow: the label POSTs are byte-equal to the queue run ($(cat "$T/l6-adds-shadow.txt"))"
  [ ! -s "$T/merge-calls.txt" ] && ok || bad "L6: no pr merge call ($(cat "$T/merge-calls.txt"))"
  NP=$(grep -c . "$T/l6-posts.txt"); NL=$(grep -c ' LANDING ' "$CLOG")
  [ "$NP" = 1 ] && [ "$NL" = 1 ] && ok || bad "L6 shadow: exactly 1 POST and 1 LANDING line (posts $NP, lines $NL; $(grep -F '#61' "$CLOG" | tail -6))"
  LINE=$(grep ' LANDING ' "$CLOG" | head -1)
  W=$(sed -n 's/.* LANDING would=\([a-z]*\) .*/\1/p' <<<"$LINE"); R=$(sed -n 's/.* reason=\([a-z0-9-]*\) .*/\1/p' <<<"$LINE")
  jq -e --arg w "$W" --arg r "$R" --arg h "$H61" '.would==$w and .reason==$r and .head==$h and .number==61 and .repo=="example-org/mgfy-os" and .mode=="shadow"' "$T/l6-posts.txt" >/dev/null 2>&1 \
    && [ -n "$W" ] && [ -n "$R" ] && ok || bad "L6 shadow: the POST body equals the line (line '$LINE'; body $(cat "$T/l6-posts.txt"))"
  grep -qF "example-org/mgfy-os#61 LANDING would=" "$CLOG" && grep -q "mode=shadow head=${H61:0:12}$" "$CLOG" && ok || bad "L6 shadow: the line names key, mode and head ($LINE)"
  # A second shadow tick on the same head: no second row, no second line.
  : > "$T/l6-posts.txt"; nhvf_clear; MC_LANDING_MODE=shadow nhvf_tick
  [ ! -s "$T/l6-posts.txt" ] && [ "$(grep -c ' LANDING ' "$CLOG")" = 0 ] && ok || bad "L6 shadow: the next tick on the same head adds nothing ($(cat "$T/l6-posts.txt"))"
else
  echo "flock missing — L6 skipped"
fi

echo "landing-eligible.bh-6744: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = 0 ]
