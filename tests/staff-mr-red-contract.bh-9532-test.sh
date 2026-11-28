#!/bin/bash
# tests/staff-mr-red-contract.bh-9532-test.sh — BH-9532 (C0, #9539): the Mr Red
# tracer. bin/staff/mr-red.sh tick is driven over real curl against one local
# server (tests/lib/mr-red-world.bh-9532.mjs) that hosts the REAL jobs worker
# on the composed schema: the roster row, the settings rows, the claim route
# and the mr-red routes this PR ships. GitHub is a fake `gh` on PATH that
# answers from per-case fixture files (tests/fixtures/mr-red/drafts/) and
# records each call. A curl wrapper records every URL; no case reaches a
# non-local host.
#
#   lib-fingerprint  mrr_fingerprint: sorted and deduped checks, rc 1 on a bad head
#   lib-killed       mrr_killed: the first set kill switch, else rc 1
#   seams            each seam exists, names its owner, gives its placeholder answer
#   soul             bin/staff-core.mjs soul accepts prompts/staff/mr-red-soul.md
#   registry         the cron line, the lane row, the switches, the manifests, state path
#   collect-guard    no MRR_TICK: the collector prints nothing and calls no gh
#   observable-outcome  one draft: one observe row, GET ?repo= returns it; a
#                    second tick adds no row and seen_count is 2
#   AT7              3 ticks: 1 finding, seen_count 3, 1 action row, 0 alerts
#   AT8              staff-kill-mr-red: killed by, 0 gh calls, no own request
#   exit-killed x5   the four flags and STAFF_ENABLED=0
#   exit-lane-off, exit-not-configured, exit-lock, exit-roster
#   exit-no-lane-gate  bin/lib/lane-gate.sh missing: not-configured, 0 gh calls
#   exit-gh-budget   budget low: incomplete=10-drafts, no read, no row
#   exit-source-unreadable  pulls 500: incomplete=10-drafts, no row, no sample
#   collect-incomplete  a failed source's lines are dropped; the others count
#   collect-drafts   the decision table (items and near misses)
#   collect-cache    a completed check-runs answer is read once
#   lever-pick       level observe / no row / file order / the loop check
#   exit-claim-fails, exit-post-fails, exit-act-fails (and no _act)
#   work-dispatched  a lever dispatches: one lane-run row of lane mr-red, the
#                    row is dispatched, `mr-red.sh work <payload>` calls
#                    mrr_<lever>_work with the same action_key; the tick runs
#                    no test process
#   judge-called     mrr_judge_tick runs with MRR_INCOMPLETE
#   exit-timeout     tick_timeout_s 1 and a source that sleeps 30 s: the tick
#                    ends in under 10 s (setup overhead is not in the tick budget)
#   cap-200          200 failed drafts: 50 rows, deferred=150
#   no-cap           5 ticks with a new head each: 5 acts
#   net-budget       0 non-local URLs over the whole suite
#
# Run from anywhere: tests/staff-mr-red-contract.bh-9532-test.sh (exit 0 = pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# The jobs worker imports the git-ignored catalogs (BH-6452, BH-6540).
. "$DIR/tests/lib/worker-catalogs.sh" || exit 1
worker_catalogs "$DIR" || exit 1
SRV="$DIR/tests/lib/mr-red-world.bh-9532.mjs"
FX0="$DIR/tests/fixtures/mr-red/drafts"
FRAG="$DIR/worker/jobs/schema.d/202611111407-bh-9532-mr-red.sql"
LIB="$DIR/bin/lib/mr-red.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok   $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL $1"; }
eq()  { [ "$2" = "$3" ] && ok "$1" || bad "$1: got '$2' want '$3'"; }
has() { grep -qF -- "$2" <<<"$3" && ok "$1" || bad "$1: no '$2' in: $3"; }
command -v node >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && command -v curl >/dev/null 2>&1 \
  && command -v sha256sum >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 \
  || { echo "SKIP: node, jq, curl, sha256sum or flock missing"; exit 0; }
SLUG=example-org/cromford
sha() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }
HEAD40=9001ffffffffffffffffffffffffffffffffffff

# --- lib-fingerprint ------------------------------------------------------------
(
  . "$LIB" || { echo "  FAIL lib-fingerprint source"; exit 1; }
  f=0
  W=$(sha "failed-batch|$SLUG|#9001|a,b|$HEAD40")
  for c in $'b\na' 'a,b' 'a,a,b' $'a\nb\nb'; do
    got=$(mrr_fingerprint failed-batch "$SLUG" '#9001' "$c" "$HEAD40")
    [ "$got" = "$W" ] && echo "  ok   lib-fingerprint same fp for checks '${c//$'\n'/\\n}'" || { echo "  FAIL lib-fingerprint '$c': $got"; f=1; }
  done
  for alt in "failed-batch $SLUG #9001 a 9002ffffffffffffffffffffffffffffffffffff" \
             "failed-batch $SLUG #9001 a,c $HEAD40" "failed-batch $SLUG #9002 a,b $HEAD40"; do
    # shellcheck disable=SC2086
    got=$(mrr_fingerprint $alt)
    [ -n "$got" ] && [ "$got" != "$W" ] && echo "  ok   lib-fingerprint another fp: $alt" || { echo "  FAIL lib-fingerprint same fp for $alt"; f=1; }
  done
  for h in 9001ffffffff 9001FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF ''; do
    if mrr_fingerprint failed-batch "$SLUG" '#9001' a "$h" >/dev/null; then echo "  FAIL lib-fingerprint head '$h' accepted"; f=1
    else echo "  ok   lib-fingerprint rc 1 on head '$h'"; fi
  done
  exit "$f"
) && ok "lib-fingerprint" || bad "lib-fingerprint"

# --- lib-killed -------------------------------------------------------------------
(
  . "$LIB" || exit 1
  f=0
  ON=""; flag_active() { [ "$1" = "$ON" ]; }
  unset STAFF_ENABLED
  for k in staff-off-all staff-kill-all staff-off-mr-red staff-kill-mr-red; do
    ON=$k; got=$(mrr_killed); rc=$?
    [ "$rc" = 0 ] && [ "$got" = "$k" ] && echo "  ok   lib-killed $k" || { echo "  FAIL lib-killed $k: rc=$rc '$got'"; f=1; }
  done
  ON=""; got=$(mrr_killed); rc=$?
  [ "$rc" = 1 ] && [ -z "$got" ] && echo "  ok   lib-killed none" || { echo "  FAIL lib-killed none: rc=$rc '$got'"; f=1; }
  ON=staff-off-tackler; mrr_killed >/dev/null && { echo "  FAIL lib-killed another agent's flag"; f=1; }
  got=$(STAFF_ENABLED=0 mrr_killed) && [ "$got" = STAFF_ENABLED=0 ] && echo "  ok   lib-killed STAFF_ENABLED=0" || { echo "  FAIL lib-killed STAFF_ENABLED=0"; f=1; }
  exit "$f"
) && ok "lib-killed" || bad "lib-killed"

# --- seams ------------------------------------------------------------------------
for spec in bin/staff/mr-red.d/10-culprit.sh:1:match bin/staff/mr-red.d/20-mechanical.sh:2:match \
            bin/staff/mr-red.d/30-codefix.sh:2:match bin/staff/mr-red.d/40-freeze.sh:3:match \
            bin/staff/mr-red.d/50-unstick.sh:3:match bin/staff/mr-red.d/60-migration.sh:3:match \
            bin/lib/mr-red-loop.sh:2:loop bin/staff/mr-red-judge.sh:4:judge \
            bin/staff/mr-red-collect.d/20-pr-red.sh:2:source bin/staff/mr-red-collect.d/40-main-red.sh:3:source \
            bin/staff/mr-red-collect.d/50-parks.sh:3:source bin/staff/mr-red-collect.d/55-ttl-green.sh:3:source; do
  IFS=: read -r p n kind <<<"$spec"
  f="$DIR/$p"
  [ -s "$f" ] || { bad "seams $p missing"; continue; }
  grep -q "^# owner: BH-9532\.$n\$" "$f" && ok "seams $p names owner BH-9532.$n" || bad "seams $p: no '# owner: BH-9532.$n' line"
  case "$kind" in
    match)
      l=$(basename "$p" .sh); l=${l#*-}
      ( . "$f" && ! "mrr_${l}_match" '{"item":{}}' ) && ok "seams $p: mrr_${l}_match returns 1" || bad "seams $p: mrr_${l}_match" ;;
    loop) eq "seams $p prints ok" "$( . "$f" && mrr_loop_check fp '#1' culprit none)" ok ;;
    judge) ( . "$f" && mrr_judge_tick ) && ok "seams $p: mrr_judge_tick rc 0" || bad "seams $p: mrr_judge_tick" ;;
    source) out=$(MRR_TICK=1 bash "$f"); rc=$?; eq "seams $p prints nothing, rc 0" "$rc:$out" "0:" ;;
  esac
done

# --- soul -------------------------------------------------------------------------
eq "soul: staff-core.mjs accepts the soul" "$(node "$DIR/bin/staff-core.mjs" soul "$DIR/prompts/staff/mr-red-soul.md" | jq -r .ok)" true

# --- registry ---------------------------------------------------------------------
grep -q '^\*/5 \* \* \* \* /root/harness/bin/hub-lease.sh check && /root/harness/bin/staff/mr-red.sh tick ' \
  "$DIR/cron/lanes/781-staff-mr-red.cron" 2>/dev/null && ok "registry cron: */5 behind the hub lease" || bad "registry cron line"
eq "registry lane row" "$(jq -r '.script + " " + .switch.name + " " + .scope + " " + .cadence' "$DIR/catalog/lanes.d/staff-mr-red.json" 2>/dev/null)" \
  "bin/staff/mr-red.sh lane-off-staff-mr-red hub */5 * * * *"
for s in staff-off-mr-red staff-kill-mr-red; do
  eq "registry switch $s" "$(jq -r '.name + " " + (.readers | join(","))' "$DIR/catalog/switches.d/$s.json" 2>/dev/null)" "$s bin/lib/mr-red.sh"
done
for m in ro rw; do [ -s "$DIR/catalog/lane-run-inputs.d/mr-red.$m" ] && ok "registry manifest mr-red.$m" || bad "registry no mr-red.$m"; done
eq "registry state path" "$(jq -r '.[0].path + " " + .[0].class' "$DIR/catalog/state-paths.d/9532-mr-red.json" 2>/dev/null)" "mr-red box-local"

# --- the scratch harness ------------------------------------------------------------
H="$T/h"
mkdir -p "$H/logs" "$H/locks" "$H/state" "$H/env" "$H/flags" "$T/bin" "$T/tmp" "$T/fx"
# bin/jobs-client.sh is named on its own: the closure scan does not follow
# the `$LIBD/jobs-client.sh` fallback form (bin/staff/clerk-lever.sh's suite
# names it the same way).
for f in "$DIR/bin/jobs-client.sh" "$DIR"/bin/staff/mr-red*.sh "$DIR"/bin/staff/mr-red-collect.d/*.sh "$DIR"/bin/staff/mr-red.d/*.sh; do
  rel=${f#"$DIR"/}
  ( cd "$DIR" && scratch_install_closure "$rel" "$H" ) >/dev/null 2>&1 || bad "setup: could not install $rel"
done
chmod +x "$H"/bin/staff/*.sh "$H"/bin/staff/mr-red-collect.d/*.sh 2>/dev/null
[ -x "$H/bin/staff/mr-red.sh" ] || { echo "setup: bin/staff/mr-red.sh not installed"; echo "staff-mr-red-contract.bh-9532: $PASS passed, $((FAIL+1)) failed"; exit 1; }
cp "$H/bin/staff/mr-red-judge.sh" "$T/judge.seam"
printf 'cromford %s https://board.example /api/board 2 hub\n' "$SLUG" > "$H/fleet.conf"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/alerts.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"; chmod +x "$H/bin/lane-alert.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"

# The fake gh. rate_limit answers $GH_FX/rate_limit.json (else a healthy
# bucket); a REST path answers $GH_FX/<key>.status (one status line, a
# failure body) or $GH_FX/<key>.json (200), else 404. <key> is the path with
# every non-alphanumeric byte as `_`.
cat > "$T/bin/gh" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_CALLS"
case "$1" in auth) echo tok-fixture-gh; exit 0 ;; esac
if [ "$1 ${2:-}" = "api rate_limit" ]; then
  if [ -f "$GH_FX/rate_limit.json" ]; then cat "$GH_FX/rate_limit.json"
  else echo '{"resources":{"core":{"limit":5000,"remaining":4900,"reset":1893456000},"graphql":{"limit":5000,"remaining":4900,"reset":1893456000}}}'; fi
  exit 0
fi
p=""; for a in "$@"; do case "$a" in repos/*) p="$a" ;; esac; done
k=$(printf '%s' "$p" | tr -c 'A-Za-z0-9' '_')
if [ -f "$GH_FX/$k.status" ]; then printf 'HTTP/1.1 %s Fixture\r\n\r\n{"message":"fixture failure"}' "$(cat "$GH_FX/$k.status")"
elif [ -f "$GH_FX/$k.json" ]; then printf 'HTTP/1.1 200 OK\r\n\r\n'; cat "$GH_FX/$k.json"
else printf 'HTTP/1.1 404 Not Found\r\n\r\n{"message":"Not Found"}'; fi
exit 0
STUB
# The curl wrapper: every URL to $CURL_LOG, every non-local one to $NET_LOG.
REAL_CURL=$(command -v curl)
cat > "$T/bin/curl" <<STUB
#!/bin/bash
for a in "\$@"; do case "\$a" in
  http://127.0.0.1:*) printf '%s\n' "\$a" >> "\$CURL_LOG" ;;
  http://*|https://*) printf '%s\n' "\$a" >> "\$CURL_LOG"; printf '%s\n' "\$a" >> "\$NET_LOG" ;;
esac; done
exec "$REAL_CURL" "\$@"
STUB
chmod +x "$T/bin/gh" "$T/bin/curl"
: > "$T/net.log"

export HARNESS="$H" FLEET_CONF="$H/fleet.conf" HARNESS_TEST_SANDBOX=1 HARNESS_SECRET=fixture-harness-secret
export JOBS_SETTINGS_CACHE_S=0 JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 JOBS_ALERT=0 BOX_NAME=hub JOBS_BOX=hub
export LANE_GATE_DISABLE=1 GH_ETAG=0 TMPDIR="$T/tmp" PATH="$T/bin:$PATH"
export GH_CALLS="$T/gh-calls.txt" CURL_LOG="$T/curl.log" NET_LOG="$T/net.log" FXLOG="$T/fx-lever.log"
unset STAFF_ENABLED MRR_TICK MRR_NOW GH_TOKEN

PIDS=()
stop_all() { local p; for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done; }
trap 'stop_all; __scratch_exit_trap' EXIT
: > "$T/w.log"; : > "$T/w.port"
node "$SRV" "$T/w.log" > "$T/w.port" 2> "$T/w.err" &
SPID=$!; PIDS+=("$SPID")
for _ in $(seq 1 200); do [ -s "$T/w.port" ] && break; kill -0 "$SPID" 2>/dev/null || break; sleep 0.05; done
PORT=$(head -1 "$T/w.port")
if [ -z "$PORT" ]; then
  wait "$SPID"; [ "$?" = 3 ] && { echo "SKIP: node:sqlite unavailable in this runtime"; exit 0; }
  echo "setup: server did not start: $(cat "$T/w.err")"; exit 1
fi
export JOBS_URL="http://127.0.0.1:$PORT"

jsql() { "$REAL_CURL" -sS -X POST "$JOBS_URL/__sql" --data-binary "$1" >/dev/null; }
jget() { "$REAL_CURL" -sS -X POST "$JOBS_URL/__get" --data-binary "$1"; }
jmode() { "$REAL_CURL" -sS -X POST "$JOBS_URL/__mode" --data-binary "$1" >/dev/null; }
setk() { jsql "INSERT OR REPLACE INTO settings (key,value,note,actor,updated_at) VALUES ('$1','$2','t','test','2026-11-11T00:00:00Z')"; }
delk() { jsql "DELETE FROM settings WHERE key='$1'"; }
NOW0=$(date -u -d 2026-11-11T12:00:00Z +%s)
iso() { date -u -d "@$1" +%FT%TZ; }
fxkey() { printf '%s' "$1" | tr -c 'A-Za-z0-9' '_'; }
PULLS="repos/$SLUG/pulls?state=closed&sort=updated&direction=desc&per_page=100&page="
runs_path() { printf 'repos/%s/commits/%s/check-runs?filter=latest&per_page=100&page=%s' "$SLUG" "$1" "${2:-1}"; }
HEAD_PAD=$(printf 'f%.0s' $(seq 32))
head_of() { printf '%08d%s' "$1" "$HEAD_PAD"; }
# draft <n> [jq edit] — the fixture draft as PR <n>, closed 1 h before NOW0.
draft() {
  jq -c --argjson n "$1" --arg h "$(head_of "$1")" --arg c "$(iso $((NOW0 - 3600)))" --arg u "$(iso $((NOW0 - 3590)))" \
    ".number = \$n | .head.sha = \$h | .head.ref = \"mergify/merge-queue/\(\$n)fx\" | .closed_at = \$c | .updated_at = \$u
     | .html_url = \"https://github.com/$SLUG/pull/\(\$n)\" | ${2:-.}" "$FX0/draft.json"
}
pulls_page() { printf '%s' "$2" > "$GH_FX/$(fxkey "$PULLS$1").json"; }
runs_page() { printf '%s' "$3" > "$GH_FX/$(fxkey "$(runs_path "$1" "$2")").json"; }
fail_runs() { runs_page "$(head_of "$1")" 1 "$(cat "$FX0/check-runs.json")"; }
# runs_of <n> <conclusion...> — one completed run per conclusion.
runs_of() {
  local n=$1; shift
  runs_page "$(head_of "$n")" 1 "$(printf '%s\n' "$@" | jq -Rsc '[split("\n")[] | select(. != "")] | to_entries
    | {total_count: length, check_runs: map({name: "check-\(.key)", status: "completed", conclusion: .value})}')"
}
# RESET <case> — a fresh fixture dir, token, log and rows; the seam set as shipped.
RESET() {
  export GH_FX="$T/fx/$1" GH_TOKEN="tok-fixture-$1"
  mkdir -p "$GH_FX"
  jmode ""
  jsql "DELETE FROM mr_red_actions; DELETE FROM staff_findings WHERE agent='mr-red'; DELETE FROM staff_finding_seen WHERE agent='mr-red';
        DELETE FROM lane_runs; UPDATE staff_agents SET status='active' WHERE name='mr-red'"
  setk staff.mr-red.level act; setk staff.mr-red.max_items_tick 50; setk staff.mr-red.lookback_h 24; setk staff.mr-red.tick_timeout_s 240
  rm -f "$H"/flags/* "$H"/bin/staff/mr-red.d/1[5-9]-*.sh "$H"/bin/staff/mr-red-collect.d/1[1-9]-*.sh 2>/dev/null
  scratch_rm "$H/state/mr-red"
  cp "$T/judge.seam" "$H/bin/staff/mr-red-judge.sh"
  # The loop seam as shipped: a case may overwrite it, so reinstall it.
  rm -f "$H/bin/lib/mr-red-loop.sh"; ( cd "$DIR" && scratch_install_closure bin/lib/mr-red-loop.sh "$H" ) >/dev/null
  : > "$H/logs/staff-mr-red.log"; : > "$H/logs/ALERTS.log"; : > "$T/alerts.txt"; : > "$GH_CALLS"; : > "$CURL_LOG"
  : > "$FXLOG"; : > "$T/w.log"
  unset FXA_RC FXB_MATCH
}
tick() { MRR_NOW="${TNOW:-$NOW0}" "$H/bin/staff/mr-red.sh" tick > "$T/run.out" 2>&1; RC=$?; }
last() { tail -1 "$H/logs/staff-mr-red.log"; }
rows() { jget "SELECT action_key, fingerprint, repo, project, target, lever, approach, state, evidence_json, red_check FROM mr_red_actions ORDER BY id"; }
nrows() { jget "SELECT count(*) AS n FROM mr_red_actions" | jq -r '.[0].n'; }
nreq() { grep -c -- "$1" "$T/w.log"; }
ngh() { grep -c . "$GH_CALLS"; }
# Requests a stopped tick may still make: the kill check reads flag rows
# (flag_active) and the lane gate reports flag-seen and liveness.
own_requests() { grep -cvE '^(GET /api/flags/|POST /api/lanes/(flag-seen|liveness) )' "$T/w.log"; }
lever() { # lever <file> <name> — a fixture lever: match unless <NAME>_MATCH=0, act rc <NAME>_RC
  local up; up=$(printf '%s' "$2" | tr '[:lower:]' '[:upper:]')
  cat > "$H/bin/staff/mr-red.d/$1" <<EOF
mrr_$2_match() { [ "\${${up}_MATCH:-1}" = 1 ]; }
mrr_$2_act() { printf '%s %s\n' "$2" "\$2" >> "\$FXLOG"; return "\${${up}_RC:-0}"; }
mrr_$2_work() { printf 'work %s\n' "\$1" >> "\$FXLOG"; return 0; }
EOF
}
fp_of() { sha "failed-batch|$SLUG|#$1|$2|$(head_of "$1")"; }
CHK='harness-ci / tests (shard 3)'

# --- collect-guard ----------------------------------------------------------------
RESET guard; pulls_page 1 "[$(draft 9050)]"; fail_runs 9050
# A source with no guard of its own: only the runner's guard keeps it quiet.
printf '#!/bin/bash\necho %q\n' '{"item":{"x":1},"target":"#guard"}' > "$H/bin/staff/mr-red-collect.d/11-fxguard.sh"
out=$(MRR_NOW=$NOW0 "$H/bin/staff/mr-red-collect.sh"); rc=$?
eq "collect-guard: no MRR_TICK prints nothing, rc 0" "$rc:$out" "0:"
eq "collect-guard: 0 gh calls" "$(ngh)" 0
out=$(MRR_TICK=1 MRR_NOW=$NOW0 "$H/bin/staff/mr-red-collect.sh"); rc=$?
eq "collect-guard: MRR_TICK=1 prints the items" "$rc:$(jq -r 'select(.item) | .target' <<<"$out" 2>/dev/null | tr '\n' ' ')" "0:#9050 #guard "

# --- observable-outcome -----------------------------------------------------------
RESET outcome; pulls_page 1 "[$(draft 9101)]"; fail_runs 9101
tick
eq "outcome rc" "$RC" 0
R=$(rows)
eq "outcome: one row" "$(jq length <<<"$R")" 1
eq "outcome: lever/target/state/repo/project" "$(jq -r '.[0] | "\(.lever) \(.target) \(.state) \(.repo) \(.project)"' <<<"$R")" \
  "observe #9101 observed $SLUG cromford"
eq "outcome: the draft's fingerprint" "$(jq -r '.[0].fingerprint' <<<"$R")" "$(fp_of 9101 "$CHK")"
eq "outcome: evidence head and checks" "$(jq -r '.[0].evidence_json | fromjson | "\(.head) \(.checks | join(","))"' <<<"$R")" "$(head_of 9101) $CHK"
G=$("$REAL_CURL" -sS -H "Authorization: Bearer $HARNESS_SECRET" "$JOBS_URL/api/mr-red/actions?repo=$SLUG")
eq "outcome: GET ?repo= returns the row" "$(jq -r '.actions | map(.action_key) | join(",")' <<<"$G")" "$(jq -r '.[0].action_key' <<<"$R")"
has "outcome: summary" "items=1 new=1 repeat=0 deferred=0 rows=1 observed=1 acted=0" "$(last)"
has "outcome: summary incomplete=- timed_out=0" "incomplete=- timed_out=0" "$(last)"
tick
eq "outcome: a second tick adds no row" "$(nrows)" 1
eq "outcome: seen_count 2" "$(jget "SELECT seen_count FROM staff_finding_seen WHERE agent='mr-red'" | jq -r '.[0].seen_count')" 2
has "outcome: second summary" "items=1 new=0 repeat=1 deferred=0 rows=0 observed=0" "$(last)"
has "outcome: second summary replay=1" "replay=1" "$(last)"
eq "outcome: 0 metric samples" "$(nreq '^POST /api/staff/levers/metric')" 0

# --- AT7 --------------------------------------------------------------------------
RESET at7; pulls_page 1 "[$(draft 9111)]"; fail_runs 9111
tick; tick; tick
eq "AT7: 1 finding row" "$(jget "SELECT count(*) AS n FROM staff_findings WHERE agent='mr-red'" | jq -r '.[0].n')" 1
eq "AT7: seen_count 3" "$(jget "SELECT seen_count FROM staff_finding_seen WHERE agent='mr-red'" | jq -r '.[0].seen_count')" 3
eq "AT7: 1 action row" "$(nrows)" 1
eq "AT7: 0 alerts (lane-alert)" "$(grep -c . "$T/alerts.txt")" 0
eq "AT7: 0 ALERTS.log lines" "$(grep -c . "$H/logs/ALERTS.log")" 0

# --- AT8 and exit-killed ------------------------------------------------------------
for k in flag:staff-kill-mr-red flag:staff-off-mr-red flag:staff-off-all flag:staff-kill-all env:STAFF_ENABLED=0; do
  RESET "kill-${k#*:}"; pulls_page 1 "[$(draft 9121)]"; fail_runs 9121
  case "$k" in
    flag:*) : > "$H/flags/${k#flag:}"; tick ;;
    env:*) STAFF_ENABLED=0 tick ;;
  esac
  n="exit-killed [${k#*:}]"; [ "$k" = flag:staff-kill-mr-red ] && n="AT8"
  eq "$n rc" "$RC" 0
  has "$n: log" "killed by ${k#*:}" "$(cat "$H/logs/staff-mr-red.log")"
  eq "$n: 0 gh calls" "$(ngh)" 0
  eq "$n: 0 own requests" "$(own_requests)" 0
  eq "$n: curl only read flags" "$(grep -cv '/api/flags/' "$CURL_LOG")" 0
  eq "$n: 0 rows" "$(nrows)" 0
done

# --- exit-lane-off ----------------------------------------------------------------
RESET laneoff; pulls_page 1 "[$(draft 9131)]"; fail_runs 9131
: > "$H/flags/lane-off-staff-mr-red"
LANE_GATE_DISABLE=0 tick
eq "exit-lane-off: 0 gh calls" "$(ngh)" 0
eq "exit-lane-off: 0 own requests" "$(own_requests)" 0
eq "exit-lane-off: 0 rows" "$(nrows)" 0

# --- exit-not-configured -----------------------------------------------------------
RESET notconf; pulls_page 1 "[$(draft 9132)]"; fail_runs 9132
HARNESS_SECRET="" tick
has "exit-not-configured: log" "not-configured (no HARNESS_SECRET)" "$(last)"
eq "exit-not-configured: 0 requests" "$(grep -c . "$T/w.log")" 0
eq "exit-not-configured: 0 gh calls" "$(ngh)" 0

# --- exit-no-lane-gate ------------------------------------------------------------
# A missing bin/lib/lane-gate.sh must not let the tick run with the lane-off flag unread.
RESET nolanegate; pulls_page 1 "[$(draft 9135)]"; fail_runs 9135
rm -f "$H/bin/lib/lane-gate.sh"
tick
has "exit-no-lane-gate: log" "not-configured (no bin/lib/lane-gate.sh)" "$(last)"
eq "exit-no-lane-gate: 0 gh calls" "$(ngh)" 0
eq "exit-no-lane-gate: 0 rows" "$(nrows)" 0
( cd "$DIR" && scratch_install_closure bin/lib/lane-gate.sh "$H" ) >/dev/null 2>&1 || bad "setup: could not reinstall bin/lib/lane-gate.sh"

# --- exit-lock --------------------------------------------------------------------
RESET lock; pulls_page 1 "[$(draft 9133)]"; fail_runs 9133
exec 8>"$H/locks/staff-mr-red.lock"; flock -n 8
tick
exec 8>&-
has "exit-lock: log" "another mr-red tick is running" "$(last)"
eq "exit-lock: 0 gh calls" "$(ngh)" 0
eq "exit-lock: no roster read" "$(nreq 'GET /api/staff/agent?name=mr-red')" 0
eq "exit-lock: 0 rows" "$(nrows)" 0

# --- exit-roster -------------------------------------------------------------------
RESET roster; pulls_page 1 "[$(draft 9134)]"; fail_runs 9134
jsql "UPDATE staff_agents SET status='paused' WHERE name='mr-red'"
tick
has "exit-roster: log" "mr-red is not active on the roster" "$(last)"
eq "exit-roster: 1 roster read" "$(nreq 'GET /api/staff/agent?name=mr-red')" 1
eq "exit-roster: 0 gh calls" "$(ngh)" 0
eq "exit-roster: 0 rows" "$(nrows)" 0

# --- exit-gh-budget ----------------------------------------------------------------
RESET budget; pulls_page 1 "[$(draft 9141)]"; fail_runs 9141
echo '{"resources":{"core":{"limit":5000,"remaining":10,"reset":1893456000},"graphql":{"limit":5000,"remaining":4900,"reset":1893456000}}}' > "$GH_FX/rate_limit.json"
tick
has "exit-gh-budget: incomplete=10-drafts" "incomplete=10-drafts" "$(last)"
eq "exit-gh-budget: 0 rows" "$(nrows)" 0
eq "exit-gh-budget: 0 claims" "$(nreq '^POST /api/staff/findings/claim')" 0
eq "exit-gh-budget: 1 rate_limit read, 0 REST reads" "$(grep -c '^api rate_limit' "$GH_CALLS") $(grep -c '^api -i' "$GH_CALLS")" "1 0"
eq "exit-gh-budget: 0 metric samples" "$(nreq '^POST /api/staff/levers/metric')" 0

# --- exit-source-unreadable -----------------------------------------------------------
RESET unread; echo 500 > "$GH_FX/$(fxkey "${PULLS}1").status"
tick
has "exit-source-unreadable: incomplete=10-drafts" "incomplete=10-drafts" "$(last)"
eq "exit-source-unreadable: 0 rows" "$(nrows)" 0
eq "exit-source-unreadable: 0 claims" "$(nreq '^POST /api/staff/findings/claim')" 0
eq "exit-source-unreadable: 0 metric samples" "$(nreq '^POST /api/staff/levers/metric')" 0

# --- collect-incomplete ------------------------------------------------------------------
RESET incomplete; echo 502 > "$GH_FX/$(fxkey "${PULLS}1").status"
item_line() { # item_line <n> — one valid collector line for PR <n>
  local h; h=$(head_of "$1")
  jq -nc --argjson n "$1" --arg h "$h" --arg r "$SLUG" --arg fp "$(fp_of "$1" x)" \
    '{item:{class:"failed-batch",repo:$r,target:"#\($n)",head:$h,checks:["x"]}, title:"fixture \($n)",
      source:{kind:"mr-red-failed-batch",url:"https://github.com/\($r)/pull/\($n)",labels:[]}, observedAt:"2026-11-11T11:00:00Z",
      class:"failed-batch", project:"cromford", repo:$r, target:"#\($n)", target_kind:"pr", head:$h, checks:["x"], fingerprint:$fp}'
}
printf '#!/bin/bash\necho %q\nexit 0\n' "$(item_line 9151)" > "$H/bin/staff/mr-red-collect.d/12-fxok.sh"
printf '#!/bin/bash\necho %q\nexit 3\n' "$(item_line 9152)" > "$H/bin/staff/mr-red-collect.d/13-fxbad.sh"
chmod +x "$H"/bin/staff/mr-red-collect.d/1[23]-*.sh
tick
eq "collect-incomplete: only the good source's row" "$(rows | jq -r 'map(.target) | join(",")')" "#9151"
has "collect-incomplete: incomplete names both failed sources" "incomplete=10-drafts,13-fxbad" "$(last)"

# --- collect-drafts ------------------------------------------------------------------------
RESET drafts
P1=$(jq -sc . <<EOF
$(draft 9201)
$(draft 9202)
$(draft 9203)
$(draft 9205 '.merged_at = "2026-11-11T10:59:00Z"')
$(draft 9206 '.state = "open" | .closed_at = null')
$(draft 9207 '.head.ref = "mergify/merge-queue-x/9207fx"')
$(draft 9208 '.user.login = "fixture-dev"')
$(draft 9209 ".closed_at = \"$(iso $((NOW0 - 25 * 3600)))\"")
$(draft 9210)
$(draft 9211)
$(draft 9212)
$(draft 9213)
EOF
)
# Fill page 1 to 100 with merged human PRs, so the suite must read page 2.
P1=$(jq -c '. + [range(0; 100 - length) as $i | .[3] | .number = (8000 + $i) | .user.login = "fixture-dev"
  | .head.ref = "ticket/bh-\(8000 + $i)"]' <<<"$P1")
eq "collect-drafts: page 1 is full" "$(jq length <<<"$P1")" 100
pulls_page 1 "$P1"
pulls_page 2 "[$(draft 9204)]"
fail_runs 9201; fail_runs 9204
runs_of 9202 timed_out success
runs_page "$(head_of 9203)" 1 "$(jq -nc '{total_count: 101, check_runs: [range(0;100) | {name: "ok-\(.)", status: "completed", conclusion: "success"}]}')"
runs_page "$(head_of 9203)" 2 '{"total_count":101,"check_runs":[{"name":"page-two-check","status":"completed","conclusion":"failure"}]}'
for n in 9205 9206 9207 9208 9209; do fail_runs "$n"; done
runs_of 9210 success success; runs_of 9211 cancelled; runs_of 9212 skipped neutral
# filter=latest: the rerun's success; the unfiltered list still holds the old failure.
runs_of 9213 success
printf '%s' "$(cat "$FX0/check-runs.json")" > "$GH_FX/$(fxkey "repos/$SLUG/commits/$(head_of 9213)/check-runs?per_page=100&page=1").json"
tick
eq "collect-drafts: the items are exactly 9201-9204" "$(rows | jq -r 'map(.target) | sort | join(",")')" "#9201,#9202,#9203,#9204"
eq "collect-drafts: 9202 lists its timed_out check" "$(rows | jq -r '.[] | select(.target=="#9202") | .evidence_json | fromjson | .checks | join(",")')" check-0
eq "collect-drafts: 9203 fp from the page-2 failure" "$(rows | jq -r '.[] | select(.target=="#9203") | .fingerprint')" "$(fp_of 9203 page-two-check)"
eq "collect-drafts: no check-runs read for a non-item draft" "$(grep -cE "commits/($(head_of 9205)|$(head_of 9206)|$(head_of 9207)|$(head_of 9208)|$(head_of 9209))/" "$GH_CALLS")" 0
has "collect-drafts: summary items=4" "items=4 new=4" "$(last)"

# --- collect-cache -----------------------------------------------------------------------------
RESET cache
pulls_page 1 "[$(draft 9301),$(draft 9302)]"
fail_runs 9301
runs_page "$(head_of 9302)" 1 '{"total_count":2,"check_runs":[{"name":"a","status":"completed","conclusion":"failure"},{"name":"b","status":"in_progress","conclusion":null}]}'
tick; : > "$GH_CALLS"; tick
eq "collect-cache: a completed draft is not read again" "$(grep -c "commits/$(head_of 9301)/" "$GH_CALLS")" 0
eq "collect-cache: a draft with a run in progress is read again" "$(grep -c "commits/$(head_of 9302)/" "$GH_CALLS")" 1
[ -s "$H/state/mr-red/checks/example-org_cromford__$(head_of 9301).json" ] && ok "collect-cache: the cache file" || bad "collect-cache: no cache file: $(ls -R "$H/state/mr-red" 2>&1)"
eq "collect-cache: both still items" "$(nrows)" 2

# --- lever-pick ------------------------------------------------------------------------------
RESET pick-observe; pulls_page 1 "[$(draft 9401)]"; fail_runs 9401; lever 15-fxa.sh fxa
setk staff.mr-red.level observe; tick
eq "lever-pick: level observe -> observe" "$(rows | jq -r '.[0].lever')" observe
eq "lever-pick: level observe -> no act" "$(grep -c . "$FXLOG")" 0
RESET pick-norow; pulls_page 1 "[$(draft 9402)]"; fail_runs 9402; lever 15-fxa.sh fxa
delk staff.mr-red.level; tick
eq "lever-pick: no level row -> observe" "$(rows | jq -r '.[0].lever')" observe
RESET pick-order; pulls_page 1 "[$(draft 9403)]"; fail_runs 9403; lever 15-fxa.sh fxa; lever 16-fxb.sh fxb
tick
eq "lever-pick: two match -> the first by file order, done" "$(rows | jq -r '.[0] | "\(.lever) \(.state)"')" "fxa done"
eq "lever-pick: one act call, fxa" "$(cut -d' ' -f1 "$FXLOG" | tr '\n' ' ')" "fxa "
has "lever-pick: summary acted=1" "acted=1" "$(last)"
RESET pick-loop; pulls_page 1 "[$(draft 9404)]"; fail_runs 9404; lever 15-fxa.sh fxa; lever 16-fxb.sh fxb
printf 'mrr_loop_check() { if [ "$3" = fxa ]; then echo change-approach; else echo ok; fi; }\n' > "$H/bin/lib/mr-red-loop.sh"
tick
eq "lever-pick: loop on fxa -> fxb" "$(rows | jq -r '.[0].lever')" fxb
eq "lever-pick: evidence why=loop:fxa" "$(rows | jq -r '.[0].evidence_json | fromjson | .why')" loop:fxa

# --- exit-claim-fails ---------------------------------------------------------------------------
RESET claimfail; pulls_page 1 "[$(draft 9501)]"; fail_runs 9501
jmode claim500; tick
eq "exit-claim-fails: 0 rows" "$(nrows)" 0
has "exit-claim-fails: claim_failed=1" "claim_failed=1" "$(last)"
jmode ""; tick
eq "exit-claim-fails: the item comes back next tick" "$(nrows)" 1

# --- exit-post-fails ------------------------------------------------------------------------------
RESET postfail; pulls_page 1 "[$(draft 9502)]"; fail_runs 9502; lever 15-fxa.sh fxa
jsql "DROP TABLE mr_red_actions"
tick
jsql "$(cat "$FRAG")"
eq "exit-post-fails: 0 act calls" "$(grep -c . "$FXLOG")" 0
has "exit-post-fails: post_failed=1" "post_failed=1" "$(last)"
grep -q '^POST /api/mr-red/actions 503' "$T/w.log" && ok "exit-post-fails: the route answered 503" || bad "exit-post-fails: $(grep mr-red "$T/w.log")"

# --- exit-act-fails ----------------------------------------------------------------------------------
RESET actfail; pulls_page 1 "[$(draft 9503)]"; fail_runs 9503; lever 15-fxa.sh fxa
FXA_RC=1 tick
eq "exit-act-fails: row failed" "$(rows | jq -r '.[0] | "\(.lever) \(.state)"')" "fxa failed"
has "exit-act-fails: failed=1" "failed=1" "$(last)"
RESET noact; pulls_page 1 "[$(draft 9504)]"; fail_runs 9504
printf 'mrr_fxc_match() { return 0; }\n' > "$H/bin/staff/mr-red.d/17-fxc.sh"
tick
eq "exit-act-fails: no _act -> failed, why=no-act" "$(rows | jq -r '.[0] | "\(.lever) \(.state) \(.evidence_json | fromjson | .why)"')" "fxc failed no-act"

# --- work-dispatched --------------------------------------------------------------------------------
RESET dispatch; pulls_page 1 "[$(draft 9601)]"; fail_runs 9601
cat > "$H/bin/staff/mr-red.d/15-fxd.sh" <<'EOF'
mrr_fxd_match() { return 0; }
mrr_fxd_act() {
  local p rc
  p=$(jq -c '{lever:"fxd", action_key:.action_key, project:.project}' <<<"$2")
  mrr_dispatch fxd "$p"; rc=$?
  [ "$rc" = 0 ] && return 3
  return 1
}
mrr_fxd_work() { printf 'work %s\n' "$1" >> "$FXLOG"; return 0; }
EOF
mkdir -p "$T/shim"
for p in node npx vitest bats; do printf '#!/bin/bash\necho %s >> "%s/testproc.txt"\nexit 0\n' "$p" "$T" > "$T/shim/$p"; chmod +x "$T/shim/$p"; done
: > "$T/testproc.txt"
PATH="$T/shim:$PATH" tick
eq "work-dispatched: 0 test processes during the tick" "$(grep -c . "$T/testproc.txt")" 0
LR=$(jget "SELECT lane, project, args_json FROM lane_runs")
eq "work-dispatched: one lane-run row of lane mr-red" "$(jq -r 'map("\(.lane) \(.project)") | join(",")' <<<"$LR")" "mr-red cromford"
eq "work-dispatched: the row is dispatched" "$(rows | jq -r '.[0] | "\(.lever) \(.state)"')" "fxd dispatched"
has "work-dispatched: summary dispatched=1" "dispatched=1" "$(last)"
ARGS=$(jq -r '.[0].args_json' <<<"$LR")
eq "work-dispatched: args are the work verb" "$(jq -r '.[0:2] | join(" ")' <<<"$ARGS")" "bin/staff/mr-red.sh work"
PAY=$(jq -r '.[2]' <<<"$ARGS")
"$H/bin/staff/mr-red.sh" work "$PAY" > "$T/work.out" 2>&1; WRC=$?
eq "work-dispatched: work rc 0" "$WRC" 0
eq "work-dispatched: _work got the same action_key" "$(sed -n 's/^work //p' "$FXLOG" | jq -r .action_key)" "$(rows | jq -r '.[0].action_key')"
"$H/bin/staff/mr-red.sh" work '{"lever":"nosuch","action_key":"x"}' > /dev/null 2>&1; eq "work: an unknown lever exits 2" "$?" 2
"$H/bin/staff/mr-red.sh" work 'not json' > /dev/null 2>&1; eq "work: a bad payload exits 2" "$?" 2
: > "$H/flags/staff-kill-mr-red"; : > "$FXLOG"
"$H/bin/staff/mr-red.sh" work "$PAY" > /dev/null 2>&1
eq "work: killed -> no _work call" "$(grep -c . "$FXLOG")" 0
"$H/bin/staff/mr-red.sh" nosuch > /dev/null 2>&1; eq "usage: an unknown verb exits 2" "$?" 2

# --- judge-called -------------------------------------------------------------------------------------
RESET judge; echo 500 > "$GH_FX/$(fxkey "${PULLS}1").status"
printf 'mrr_judge_tick() { printf "judge incomplete=[%%s]\\n" "${MRR_INCOMPLETE:-}" >> "$FXLOG"; return 0; }\n' > "$H/bin/staff/mr-red-judge.sh"
tick
eq "judge-called: once, with the incomplete list" "$(cat "$FXLOG")" "judge incomplete=[10-drafts]"

# --- exit-timeout ----------------------------------------------------------------------------------------
RESET timeout; pulls_page 1 "[$(draft 9701)]"; fail_runs 9701
setk staff.mr-red.tick_timeout_s 1
printf '#!/bin/bash\nsleep 30\nexit 0\n' > "$H/bin/staff/mr-red-collect.d/15-fxsleep.sh"; chmod +x "$H/bin/staff/mr-red-collect.d/15-fxsleep.sh"
S0=$(date +%s); tick; S1=$(date +%s)
has "exit-timeout: timed_out=1" "timed_out=1" "$(last)"
has "exit-timeout: the sleeping source is incomplete" "15-fxsleep" "$(last)"
[ $((S1 - S0)) -lt 10 ] && ok "exit-timeout: the tick did not wait for the source" || bad "exit-timeout: tick took $((S1 - S0)) s"

# --- cap-200 -----------------------------------------------------------------------------------------------
RESET cap
A=""; B=""
for n in $(seq 10001 10100); do A+="$(draft "$n"),"; fail_runs "$n"; done
for n in $(seq 10101 10200); do B+="$(draft "$n"),"; fail_runs "$n"; done
pulls_page 1 "[${A%,}]"; pulls_page 2 "[${B%,}]"; pulls_page 3 "[]"
tick
eq "cap-200: 50 rows" "$(nrows)" 50
has "cap-200: deferred=150" "deferred=150" "$(last)"
eq "cap-200: at most 50 check-runs reads" "$(grep -c '/check-runs' "$GH_CALLS")" 50

# --- no-cap ---------------------------------------------------------------------------------------------------
RESET nocap; lever 15-fxa.sh fxa
for i in 1 2 3 4 5; do
  rm -f "$GH_FX"/*; pulls_page 1 "[$(draft $((9800 + i)))]"; fail_runs $((9800 + i)); tick
done
eq "no-cap: 5 ticks with a new head each give 5 acts" "$(grep -c '^fxa ' "$FXLOG")" 5
eq "no-cap: 5 done rows" "$(jget "SELECT count(*) AS n FROM mr_red_actions WHERE state='done'" | jq -r '.[0].n')" 5

# --- net-budget ----------------------------------------------------------------------------------------------------
eq "net-budget: 0 non-local URLs over the suite" "$(grep -c . "$NET_LOG")" 0

echo "staff-mr-red-contract.bh-9532: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
