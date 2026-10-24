#!/bin/bash
# tests/pipeline-health-pr-record.bh-8268-test.sh — bin/pipeline-health.sh reads
# the fleet's own PR record (bin/lib/ph-pr-record.sh over bin/lib/pr-record.sh)
# before GitHub for its per-PR reads (BH-8268).
#
#   U1-U12  ph_prr_read / ph_prr_writeback, the real lib, a stub _jobs_req.
#   B0-B6   the "sweep should have landed" block, extracted VERBATIM.
#   D0-D3   the "stale dequeue (BH-3480)" block, extracted VERBATIM.
#
# _jobs_req serves $CT/rec/<repo-lower>/<n>.json only for the exact
# `GET /api/pr-records?repo=<r>&number=<n>`; every call goes to jobs-calls.txt,
# every PUT body to jobs-puts.txt. gh is a PATH stub that logs each call to
# gh-calls.txt; GH_MODE=fail fails every call, GH_PULLS=fail fails pulls/ only.
# Each case has its own scratch dir and its own PR numbers.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PH="$DIR/bin/pipeline-health.sh"
LIB="$DIR/bin/lib/ph-pr-record.sh"
[ -r "$LIB" ] && ok || bad "bin/lib/ph-pr-record.sh is missing"
grep -q 'lib/ph-pr-record.sh' "$PH" && ok || bad "bin/pipeline-health.sh does not load bin/lib/ph-pr-record.sh"
awk '/^# >>> sweep should have landed/{f=1;next} /^# <<< sweep should have landed/{exit} f' "$PH" > "$T/sweep.sh"
awk '/^# >>> stale dequeue \(BH-3480\)/{f=1;next} /^# <<< stale dequeue/{exit} f' "$PH" > "$T/dequeue.sh"
[ -s "$T/sweep.sh" ] && [ -s "$T/dequeue.sh" ] && ok || bad "a block was not extracted"

# mkh <dir> — a scratch harness root with the lane's real libs.
mkh() {
  mkdir -p "$1/logs" "$1/state" "$1/builds" "$1/bin" "$1/rec" "$1/gh" "$1/c" "$1/fakebin"
  ( cd "$DIR" && scratch_install_closure bin/pipeline-health.sh "$1" ) >/dev/null || { echo "setup: closure into $1"; exit 1; }
  ( cd "$DIR" && scratch_install_closure bin/lib/ph-pr-record.sh "$1" ) >/dev/null 2>&1
  : > "$1/jobs-calls.txt"; : > "$1/jobs-puts.txt"; : > "$1/gh-calls.txt"
  cat > "$1/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CT/gh-calls.txt"
[ "${GH_MODE:-ok}" = fail ] && exit 1
case "$*" in
  *"repos/example-org/proj-os/issues?labels=merge-queue"*) cat "$CT/list.json" ;;
  *"api --paginate repos/example-org/proj-os/issues/"*"/comments"*)
    N=$(sed -n 's|.*/issues/\([0-9]*\)/comments.*|\1|p' <<<"$*"); cat "$CT/c/$N.json" 2>/dev/null || echo '[]' ;;
  *"api repos/example-org/proj-os/commits/"*)
    N=$(sed -n 's|.*/commits/sha\([0-9]*\).*|\1|p' <<<"$*"); cat "$CT/c/$N.head" ;;
  *"api repos/example-org/proj-os/pulls/"*" --jq .head.sha"*)
    [ "${GH_PULLS:-ok}" = fail ] && exit 1
    N=$(sed -n 's|.*/pulls/\([0-9]*\).*|\1|p' <<<"$*"); echo "sha$N" ;;
  *"repos/example-org/proj-os/pulls/"[0-9]*)
    [ "${GH_PULLS:-ok}" = fail ] && exit 1
    N=$(sed -n 's|.*/pulls/\([0-9]*\).*|\1|p' <<<"$*")
    [ -f "$CT/gh/$N.json" ] || exit 1
    printf 'HTTP/2.0 200\r\n\r\n'; cat "$CT/gh/$N.json" ;;
  *"api rate_limit"*)
    now=$(date +%s)
    printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":%s},"graphql":{"remaining":5000,"limit":5000,"reset":%s}}}' "$((now + 3600))" "$((now + 3600))" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$1/fakebin/gh"
}
# The jobs client, stubbed. Defined in each driver subshell.
JOBS_STUB='_jobs_req() {
  printf "%s %s\n" "$1" "$2" >> "$CT/jobs-calls.txt"
  case "${JOBS_MODE:-ok}" in fail) return 1 ;; other) echo "{\"jobs\":[]}"; return 0 ;; esac
  case "$1" in
    GET)
      if [[ "$2" =~ ^/api/pr-records\?repo=([a-z0-9_.-]+/[a-z0-9_.-]+)\&number=([0-9]+)$ ]] \
         && [ -f "$CT/rec/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}.json" ]; then
        cat "$CT/rec/${BASH_REMATCH[1]}/${BASH_REMATCH[2]}.json"
      else echo "{\"row\":null,\"age_s\":null}"; fi ;;
    PUT) printf "%s\n" "$3" >> "$CT/jobs-puts.txt"; echo "{\"row\":{},\"applied\":[],\"stale\":[]}" ;;
    *) return 1 ;;
  esac
}'
# rec <h> <repo-lower> <n> <state> <mergeable|null> <head_sha|null> [age_s|absent]
rec() {
  local h="$1" r="$2" n="$3" st="$4" m="$5" sha="$6" age="${7:-0}"
  mkdir -p "$h/rec/$r"
  jq -nc --arg r "$r" --argjson n "$n" --arg st "$st" --argjson m "$( [ "$m" = null ] && echo null || jq -nc --arg v "$m" '$v')" \
    --argjson sha "$( [ "$sha" = null ] && echo null || jq -nc --arg v "$sha" '$v')" --arg age "$age" \
    '{row: {repo:$r, number:$n, state:$st, mergeable_state:$m, head_sha:$sha, head_ref:"b\($n)", checks:null},
      } + (if $age == "absent" then {} else {age_s: ($age | tonumber)} end)' > "$h/rec/$r/$n.json"
}
# ghpr <h> <n> <open|closed|merged> <mergeable> — the REST pulls object gh serves.
ghpr() {
  jq -nc --argjson n "$2" --arg s "$3" --arg m "$4" '{number:$n,
    state: (if $s == "open" then "open" else "closed" end), merged: ($s == "merged"),
    merged_at: (if $s == "merged" then "2026-10-24T00:00:00Z" else null end),
    mergeable_state: $m, draft: false, user: {login: "operator"},
    head: {ref: "b\($n)", sha: "sha\($n)"}, base: {ref: "main", sha: "base1"}, labels: []}' > "$1/gh/$2.json"
}
misses() { [ -f "$1/logs/pipeline-health.log" ] || { echo 0; return; }; grep -c " PRR_MISS " "$1/logs/pipeline-health.log"; }

# ============================================================================
# Unit: ph_prr_read / ph_prr_writeback
# ============================================================================
# u <h> <cmd...> — run a command in a subshell with the real lib and the stub.
u() {
  local h="$1"; shift
  ( export CT="$h" HARNESS="$h"; unset H
    eval "$JOBS_STUB"
    [ "${NO_JOBS:-0}" = 1 ] && unset -f _jobs_req
    # shellcheck disable=SC1091
    . "$h/bin/lib/ph-pr-record.sh" || exit 9
    "$@" ) > "$h/out.txt" 2> "$h/err.txt"
}
U="$T/u"; mkh "$U"
# U1 hit
rec "$U" example-org/proj-os 801 open clean sha801 0
u "$U" ph_prr_read example-org/proj-os 801 state mergeable_state head_sha; RC=$?
[ "$RC" = 0 ] && [ "$(jq -r .head_sha "$U/out.txt" 2>/dev/null)" = sha801 ] && ok || bad "U1: hit must print the row rc 0 (rc=$RC out=$(cat "$U/out.txt") err=$(cat "$U/err.txt"))"
[ "$(misses "$U")" = 0 ] && ok || bad "U1: a hit wrote a PRR_MISS line"
grep -qx 'GET /api/pr-records?repo=example-org/proj-os&number=801' "$U/jobs-calls.txt" && [ "$(wc -l < "$U/jobs-calls.txt")" = 1 ] \
  && ok || bad "U1: expected one lowercased GET: $(cat "$U/jobs-calls.txt")"
# U2 no row
u "$U" ph_prr_read example-org/proj-os 802 state head_sha; RC=$?
[ "$RC" = 1 ] && [ ! -s "$U/out.txt" ] && ok || bad "U2: no row must be rc 1, nothing printed (rc=$RC)"
grep -qE '^[0-9T:-]+Z PRR_MISS example-org/proj-os#802 why=no-row$' "$U/logs/pipeline-health.log" && ok || bad "U2: no PRR_MISS no-row line: $(cat "$U/logs/pipeline-health.log" 2>/dev/null)"
# U3 age edge
rec "$U" example-org/proj-os 803 open clean sha803 900
( export PR_RECORD_MAX_AGE_S=900; u "$U" ph_prr_read example-org/proj-os 803 head_sha ); RC=$?
[ "$RC" = 0 ] && ok || bad "U3: age_s 900 at max 900 must be a hit (rc=$RC)"
rec "$U" example-org/proj-os 804 open clean sha804 901
( export PR_RECORD_MAX_AGE_S=900; u "$U" ph_prr_read example-org/proj-os 804 head_sha ); RC=$?
[ "$RC" = 1 ] && grep -q 'PRR_MISS example-org/proj-os#804 why=stale$' "$U/logs/pipeline-health.log" && ok || bad "U3: age_s 901 must miss why=stale (rc=$RC)"
# U4 knob 0: no GET at all
: > "$U/jobs-calls.txt"
( export PR_RECORD_MAX_AGE_S=0; u "$U" ph_prr_read example-org/proj-os 801 head_sha ); RC=$?
[ "$RC" = 1 ] && [ ! -s "$U/jobs-calls.txt" ] && grep -q 'PRR_MISS example-org/proj-os#801 why=stale$' "$U/logs/pipeline-health.log" \
  && ok || bad "U4: knob 0 must miss why=stale with 0 jobs calls (rc=$RC calls=$(cat "$U/jobs-calls.txt"))"
# U5 age_s absent
rec "$U" example-org/proj-os 805 open clean sha805 absent
u "$U" ph_prr_read example-org/proj-os 805 head_sha; RC=$?
[ "$RC" = 1 ] && grep -q 'PRR_MISS example-org/proj-os#805 why=stale$' "$U/logs/pipeline-health.log" && ok || bad "U5: no age_s must miss why=stale (rc=$RC)"
# U6 a null asked field
rec "$U" example-org/proj-os 806 open null sha806 0
u "$U" ph_prr_read example-org/proj-os 806 state mergeable_state head_sha; RC=$?
[ "$RC" = 1 ] && grep -q 'PRR_MISS example-org/proj-os#806 why=no-field field=mergeable_state$' "$U/logs/pipeline-health.log" \
  && ok || bad "U6: a null mergeable_state asked must miss no-field (rc=$RC)"
u "$U" ph_prr_read example-org/proj-os 806 state head_sha; RC=$?
[ "$RC" = 0 ] && ok || bad "U6: a null field not asked is a hit (rc=$RC)"
# U7 checks null is not a GitHub-filled field
u "$U" ph_prr_read example-org/proj-os 801 head_sha checks; RC=$?
[ "$RC" = 0 ] && ok || bad "U7: checks null must not miss (rc=$RC)"
# U8 another route's answer, a failed GET
( export JOBS_MODE=other; u "$U" ph_prr_read example-org/proj-os 807 head_sha ); RC=$?
[ "$RC" = 1 ] && grep -q 'PRR_MISS example-org/proj-os#807 why=unreadable$' "$U/logs/pipeline-health.log" && ok || bad "U8: {jobs:[]} must miss unreadable (rc=$RC)"
( export JOBS_MODE=fail; u "$U" ph_prr_read example-org/proj-os 808 head_sha ); RC=$?
[ "$RC" = 1 ] && grep -q 'PRR_MISS example-org/proj-os#808 why=unreadable$' "$U/logs/pipeline-health.log" && ok || bad "U8: a failed GET must miss unreadable (rc=$RC)"
# U9 no jobs client: unreadable, and the lib does not load one
printf '#!/bin/bash\n_jobs_req() { echo loaded; }\n' > "$U/bin/jobs-client.sh"
( export NO_JOBS=1; u "$U" eval 'ph_prr_read example-org/proj-os 809 head_sha; echo "rc=$?"; command -v _jobs_req >/dev/null && echo client-loaded' )
grep -qx 'rc=1' "$U/out.txt" && ! grep -q client-loaded "$U/out.txt" && grep -q 'PRR_MISS example-org/proj-os#809 why=unreadable$' "$U/logs/pipeline-health.log" \
  && ok || bad "U9: no _jobs_req must miss unreadable and load no client: $(cat "$U/out.txt")"
# U10 wrong repo, mixed case
rec "$U" example-org/other 810 open clean sha810 0
u "$U" ph_prr_read example-org/proj-os 810 head_sha; RC=$?
[ "$RC" = 1 ] && grep -q 'PRR_MISS example-org/proj-os#810 why=no-row$' "$U/logs/pipeline-health.log" && ok || bad "U10: another repo's row was served (rc=$RC)"
: > "$U/jobs-calls.txt"
u "$U" ph_prr_read example-org/Proj-OS 801 head_sha; RC=$?
[ "$RC" = 0 ] && grep -qx 'GET /api/pr-records?repo=example-org/proj-os&number=801' "$U/jobs-calls.txt" && ok || bad "U10: a mixed-case slug must read the lowercased repo (rc=$RC $(cat "$U/jobs-calls.txt"))"
# U11 bad args
: > "$U/jobs-calls.txt"; B4L=$(misses "$U")
for a in "bad 801 head_sha" "example-org/proj-os 0 head_sha" "example-org/proj-os 801 nosuchfield" "example-org/proj-os 801"; do
  # shellcheck disable=SC2086
  u "$U" ph_prr_read $a; RC=$?
  [ "$RC" = 2 ] && ok || bad "U11: '$a' must be rc 2 (rc=$RC)"
done
[ ! -s "$U/jobs-calls.txt" ] && [ "$(misses "$U")" = "$B4L" ] && ok || bad "U11: bad args made a request or a line"
# U12 write-back
ghpr "$U" 812 open clean
u "$U" ph_prr_writeback example-org/proj-os 812 "$U/gh/812.json"; RC=$?
[ "$RC" = 0 ] && [ "$(wc -l < "$U/jobs-puts.txt")" = 1 ] \
  && jq -e '.repo == "example-org/proj-os" and .number == 812 and .source == "github" and .fields.head_sha == "sha812" and .fields.mergeable_state == "clean"' "$U/jobs-puts.txt" >/dev/null \
  && ok || bad "U12: one github PUT expected (rc=$RC): $(cat "$U/jobs-puts.txt")"
: > "$U/jobs-puts.txt"
( export NO_JOBS=1; u "$U" ph_prr_writeback example-org/proj-os 812 "$U/gh/812.json" ); RC=$?
[ "$RC" = 0 ] && [ ! -s "$U/jobs-puts.txt" ] && ok || bad "U12: no client must mean no PUT, rc 0 (rc=$RC)"

# ============================================================================
# Block: sweep should have landed
# ============================================================================
# sweep_fixture <h> — #701 open/clean (stamped 31m ago: pages), #702 open/dirty
# (stamped: the stamp is dropped), #703 merged (the marker is written).
sweep_fixture() {
  local h="$1" n now; now=$(date +%s)
  : > "$h/state/sweep-clean-seen.txt"
  for n in 701 702 703; do
    mkdir -p "$h/builds/pool-proj-BH-$n-1"
    echo "PR_CREATED https://github.com/example-org/proj-os/pull/$n" > "$h/builds/pool-proj-BH-$n-1/RESULT"
  done
  echo "https://github.com/example-org/proj-os/pull/701 sha701 $((now - 1890))" >> "$h/state/sweep-clean-seen.txt"
  echo "https://github.com/example-org/proj-os/pull/702 sha702 $((now - 1890))" >> "$h/state/sweep-clean-seen.txt"
  ghpr "$h" 701 open clean; ghpr "$h" 702 open dirty; ghpr "$h" 703 merged unknown
  printf '#!/bin/bash\n[ "$1 $2" = "proj repo" ] && echo example-org/proj-os\nexit 0\n' > "$h/bin/fleet-conf.sh"; chmod +x "$h/bin/fleet-conf.sh"
}
sweep_record() { # all three, fresh
  rec "$1" example-org/proj-os 701 open clean sha701 0
  rec "$1" example-org/proj-os 702 open dirty sha702 0
  rec "$1" example-org/proj-os 703 merged null sha703 0
}
# sweep <h> [env...] — run the block; PHLIB=0 runs it without ph-pr-record.sh.
sweep() {
  local h="$1"; shift
  : > "$h/alerts.txt"; : > "$h/gh-calls.txt"; : > "$h/jobs-calls.txt"
  ( export PATH="$h/fakebin:$PATH" CT="$h" HARNESS="$h" GH_BUDGET_TTL_S=0 "$@"; unset GH_TOKEN
    H="$h"; NOW=$(date +%s); PROJECTS=proj
    alert() { printf '%s|%s\n' "$2" "$3" >> "$CT/alerts.txt"; }
    alert_digest() { printf '%s|%s\n' "$2" "$3" >> "$CT/alerts.txt"; }
    job_verdict() { printf 'APPROVE\t2\tclaude\t-\tj1\t-'; }
    gh_repo_use_token() { return 0; }   # the repo-visibility probe, not a per-PR read
    eval "$JOBS_STUB"
    # shellcheck disable=SC1091
    . "$h/bin/lib/pr-terminal.sh"
    # shellcheck disable=SC1091
    [ "${PHLIB:-1}" = 1 ] && . "$h/bin/lib/ph-pr-record.sh"
    # shellcheck disable=SC1090
    . "$T/sweep.sh"; echo reached ) > "$h/drive.out" 2>&1
}
keys() { cut -d'|' -f1 "$1/alerts.txt" | sort; }
seen() { awk '{print $1, $2}' "$1/state/sweep-clean-seen.txt" | sort; }
pulls() { grep -cE "pulls/$2( |$)" "$1/gh-calls.txt" || true; }

# B0 baseline: no record, gh serves the three PRs.
B0="$T/b0"; mkh "$B0"; sweep_fixture "$B0"
sweep "$B0"
grep -qx reached "$B0/drive.out" && ok || bad "B0: the block did not run to its end: $(cat "$B0/drive.out")"
[ "$(keys "$B0")" = "sweepstall:example-org/proj-os#701" ] && ok || bad "B0: baseline must page #701 only: $(cat "$B0/alerts.txt")"
[ "$(seen "$B0")" = "https://github.com/example-org/proj-os/pull/701 sha701" ] && ok || bad "B0: baseline CLEANSEEN: $(seen "$B0")"
grep -q '^merged ' "$B0/builds/pool-proj-BH-703-1/pr-terminal" 2>/dev/null && ok || bad "B0: baseline #703 marker missing"
[ "$(misses "$B0")" = 3 ] && ok || bad "B0: three record misses expected in the baseline, got $(misses "$B0")"

# B1 the record has all three, gh fails every call.
B1="$T/b1"; mkh "$B1"; sweep_fixture "$B1"; sweep_record "$B1"
sweep "$B1" GH_MODE=fail
grep -qx reached "$B1/drive.out" && ok || bad "B1: the block did not run to its end: $(cat "$B1/drive.out")"
[ ! -s "$B1/gh-calls.txt" ] && ok || bad "B1: the record answered every PR, yet gh was called: $(cat "$B1/gh-calls.txt")"
[ "$(keys "$B1")" = "$(keys "$B0")" ] && ok || bad "B1: decisions differ from the baseline: $(cat "$B1/alerts.txt")"
[ "$(seen "$B1")" = "$(seen "$B0")" ] && ok || bad "B1: CLEANSEEN differs from the baseline: $(seen "$B1")"
grep -qE '^merged [0-9]+ https://github.com/example-org/proj-os/pull/703$' "$B1/builds/pool-proj-BH-703-1/pr-terminal" 2>/dev/null \
  && ok || bad "B1: the record's merged #703 must write the merged marker: $(cat "$B1/builds/pool-proj-BH-703-1/pr-terminal" 2>/dev/null)"
[ "$(misses "$B1")" = 0 ] && ok || bad "B1: a hit wrote a PRR_MISS line"

# B3 a second run with the record emptied and gh failing: #703 is skipped by its marker.
scratch_rm "$B1/rec/example-org" || { echo "setup: scratch_rm"; exit 1; }
sweep "$B1" GH_MODE=fail
[ "$(pulls "$B1" 703)" = 0 ] && ok || bad "B3: #703's marker must skip it: $(cat "$B1/gh-calls.txt")"

# B2 #702 missing from the record, gh serving it.
B2="$T/b2"; mkh "$B2"; sweep_fixture "$B2"; sweep_record "$B2"; rm -f "$B2/rec/example-org/proj-os/702.json"
sweep "$B2"
[ "$(pulls "$B2" 702)" = 1 ] && [ "$(grep -c 'pulls/' "$B2/gh-calls.txt")" = 1 ] && ok || bad "B2: exactly one pulls/702 read expected: $(cat "$B2/gh-calls.txt")"
[ "$(misses "$B2")" = 1 ] && grep -q 'PRR_MISS example-org/proj-os#702 why=no-row$' "$B2/logs/pipeline-health.log" && ok || bad "B2: one no-row line expected: $(cat "$B2/logs/pipeline-health.log" 2>/dev/null)"
[ "$(keys "$B2")" = "$(keys "$B0")" ] && [ "$(seen "$B2")" = "$(seen "$B0")" ] && ok || bad "B2: decisions differ from the baseline: $(cat "$B2/alerts.txt")"
# B4 the fallback answer is written back to the record.
[ "$(wc -l < "$B2/jobs-puts.txt")" = 1 ] && jq -e '.number == 702 and .source == "github" and .fields.mergeable_state == "dirty"' "$B2/jobs-puts.txt" >/dev/null \
  && ok || bad "B4: one github PUT for #702 expected: $(cat "$B2/jobs-puts.txt")"

# B5 #701 stale.
B5="$T/b5"; mkh "$B5"; sweep_fixture "$B5"; sweep_record "$B5"; rec "$B5" example-org/proj-os 701 open clean sha701 1000
sweep "$B5"
[ "$(pulls "$B5" 701)" = 1 ] && [ "$(grep -c 'pulls/' "$B5/gh-calls.txt")" = 1 ] && ok || bad "B5: one pulls/701 read expected: $(cat "$B5/gh-calls.txt")"
grep -q 'PRR_MISS example-org/proj-os#701 why=stale$' "$B5/logs/pipeline-health.log" && ok || bad "B5: no why=stale line"
[ "$(keys "$B5")" = "$(keys "$B0")" ] && ok || bad "B5: decisions differ from the baseline: $(cat "$B5/alerts.txt")"

# B5b an open row with mergeable_state null is never read as CLEAN: GitHub decides.
B7="$T/b7"; mkh "$B7"; sweep_fixture "$B7"; sweep_record "$B7"; rec "$B7" example-org/proj-os 701 open null sha701 0
sweep "$B7"
[ "$(pulls "$B7" 701)" = 1 ] && grep -q 'PRR_MISS example-org/proj-os#701 why=no-field field=mergeable_state$' "$B7/logs/pipeline-health.log" \
  && ok || bad "B5b: an open row with no mergeable_state must read GitHub: $(cat "$B7/gh-calls.txt")"
[ "$(keys "$B7")" = "$(keys "$B0")" ] && ok || bad "B5b: decisions differ from the baseline: $(cat "$B7/alerts.txt")"

# B6 the lib not loaded: today's path, one pulls/ read per PR.
B6="$T/b6"; mkh "$B6"; sweep_fixture "$B6"; sweep_record "$B6"
sweep "$B6" PHLIB=0
[ "$(pulls "$B6" 701)" = 1 ] && [ "$(pulls "$B6" 702)" = 1 ] && [ "$(pulls "$B6" 703)" = 1 ] && ! grep -q pr-records "$B6/jobs-calls.txt" \
  && ok || bad "B6: without the lib each PR must read GitHub once: $(cat "$B6/gh-calls.txt")"
[ "$(keys "$B6")" = "$(keys "$B0")" ] && ok || bad "B6: decisions differ from the baseline"

# ============================================================================
# Block: stale dequeue (BH-3480)
# ============================================================================
NOW=$(date -u +%s)
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
DQBODY=$(jq -r '.[] | select(.id == 5882237379) | .body' "$DIR/tests/fixtures/bh-3480-pr3396-mergify-comments.json")
# dq_fixture <h> — #931 dequeued 45m, old head (pages); #932 dequeued 45m, new
# head (no page); #933 waiting (never reads pulls/).
dq_fixture() {
  local h="$1" n st
  printf 'proj example-org/proj-os - - 2 box\n' > "$h/fleet.conf"
  printf '[%s]' "$(for n in 931 932 933; do printf '{"number":%s,"pull_request":{"url":"x"},"labels":[{"name":"merge-queue"}]}\n' "$n"; done | paste -sd, -)" > "$h/list.json"
  for n in 931 932 933; do
    st=dequeued; [ "$n" = 933 ] && st=waiting
    jq -nc --arg b "${DQBODY/\"state\": \"dequeued\"/\"state\": \"$st\"}" --arg u "$(iso $((NOW - 2700)))" \
      '[{id:1, created_at:$u, updated_at:$u, user:{login:"mergify[bot]"}, body:$b}]' > "$h/c/$n.json"
  done
  iso $((NOW - 9000)) > "$h/c/931.head"; iso $((NOW - 60)) > "$h/c/932.head"; iso $((NOW - 9000)) > "$h/c/933.head"
}
dq_record() { local n; for n in 931 932 933; do rec "$1" example-org/proj-os "$n" open clean "sha$n" 0; done; }
dq() {
  local h="$1"; shift
  : > "$h/alerts.txt"; : > "$h/gh-calls.txt"
  ( export PATH="$h/fakebin:$PATH" CT="$h" HARNESS="$h" "$@"
    H="$h"; PROJECTS=proj
    gh_budget_low() { return 1; }
    alert() { printf '%s|%s\n' "$2" "$3" >> "$CT/alerts.txt"; }
    eval "$JOBS_STUB"
    # shellcheck disable=SC1091
    . "$h/bin/lib/ph-pr-record.sh"
    # shellcheck disable=SC1090
    . "$T/dequeue.sh"; echo reached ) > "$h/drive.out" 2>&1
}
D0="$T/d0"; mkh "$D0"; dq_fixture "$D0"
dq "$D0"
grep -qx reached "$D0/drive.out" && ok || bad "D0: the block did not run to its end: $(cat "$D0/drive.out")"
[ "$(keys "$D0")" = "staledequeue:proj:931" ] && ok || bad "D0: baseline must page #931 only: $(cat "$D0/alerts.txt")"
# D1 the record has all three, gh fails pulls/.
D1="$T/d1"; mkh "$D1"; dq_fixture "$D1"; dq_record "$D1"
dq "$D1" GH_PULLS=fail
[ "$(grep -c 'pulls/' "$D1/gh-calls.txt")" = 0 ] && ok || bad "D1: the record answered, yet pulls/ was read: $(grep 'pulls/' "$D1/gh-calls.txt")"
# D2 the same decisions.
[ "$(keys "$D1")" = "$(keys "$D0")" ] && ok || bad "D2: decisions differ from the baseline: $(cat "$D1/alerts.txt")"
[ "$(misses "$D1")" = 0 ] && ok || bad "D1: a hit wrote a PRR_MISS line"
# D3 #932 missing from the record.
D3="$T/d3"; mkh "$D3"; dq_fixture "$D3"; dq_record "$D3"; rm -f "$D3/rec/example-org/proj-os/932.json"
dq "$D3"
[ "$(grep -c 'pulls/' "$D3/gh-calls.txt")" = 1 ] && [ "$(pulls "$D3" 932)" = 1 ] && ok || bad "D3: exactly one pulls/932 read expected: $(grep 'pulls/' "$D3/gh-calls.txt")"
[ "$(misses "$D3")" = 1 ] && grep -q 'PRR_MISS example-org/proj-os#932 why=no-row$' "$D3/logs/pipeline-health.log" && ok || bad "D3: one no-row line expected"
[ "$(keys "$D3")" = "$(keys "$D0")" ] && ok || bad "D3: decisions differ from the baseline: $(cat "$D3/alerts.txt")"

echo "pipeline-health-pr-record.bh-8268: $PASS passed, $FAIL failed"
[ -n "${KEEP:-}" ] && cp -r "$T" "$KEEP"
[ "$FAIL" -eq 0 ]
