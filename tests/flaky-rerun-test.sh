#!/bin/bash
# tests/flaky-rerun-test.sh — the merge conductor's one concession to flaky CI.
#
# THE CLAIM. A red head whose failing test names are ALL known flakes (the
# ci_flakes ledger, >= FLAKY_MIN distinct heads inside the window) buys exactly
# ONE `gh run rerun --failed` per (PR, head) INSTEAD of a red strike. Every
# other red counts exactly as it did before — and that "exactly as before" half
# is the one worth a test, because the cheap way to make flaky CI stop blocking
# merges is to stop counting reds, which is how a genuinely broken build gets
# auto-merged.
#
# So this pins five things, and the last three are the guardrails:
#   1. known-flake red   -> one rerun, no strike recorded
#   2. the SAME head red twice -> the second one is a real red (one rerun only)
#   3. unknown red       -> strike recorded (the forgiveness is what is refused)
#   4. unreadable red    -> fail CLOSED: strike recorded, nothing forgiven
#   5. observe mode      -> no rerun ever (rerun is a WRITE verb)
#
# WHAT MOVED ON 2026-09-15 (the red ladder, docs/MERGE-CONDUCTOR.md section 3).
# The RERUN is no longer flake-only: `mc_red_rerun` re-runs the failed jobs of
# ANY red once per (PR, head), because `WAIT_CI checks red once` had no next
# transition and project-5 #1045 sat in it for ten hours. What this file exists
# to protect is the FORGIVENESS, and that is untouched — only an all-known-flake,
# readable red skips its strike, and cases 3, 3b and 3c assert exactly that
# below. The two paths share one mark, so a head still gets ONE rerun whichever
# of them bought it.
#
# gh and the metrics client are stubbed. The gh stub records any write verb
# other than the rerun under test, so a conductor that started merging or
# commenting to get here would fail rather than pass quietly.
# Run from anywhere: tests/flaky-rerun-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day stamp below is read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 45 || exit 1
# TEST-CHANGE (BH-1585): the open-PR list is REST now (a page plus per-PR reads);
# this bridge answers those reads from the GraphQL list this stub describes.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/gh-list-bridge.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# BH-1625: the lane under test reads every verdict through bin/lib/verdict-parse.sh,
# which this suite's scratch harness / extracted block does not carry by itself.
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null && command -v python3 >/dev/null || { echo "jq/python3 missing — skipping"; exit 0; }

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/state" "$T/h/flags" "$T/h/locks" "$T/h/builds" "$T/h/env" "$T/fakebin"
cp "$DIR/bin/merge-conductor.sh" "$DIR/bin/jobs-client.sh" "$T/h/bin/"
mkdir -p "$T/h/bin/lib/jobs" && cp "$DIR"/bin/lib/jobs/*.sh "$T/h/bin/lib/jobs/"
cp "$DIR/bin/lib/gh-pr-list.sh" "$DIR/bin/lib/merge-conductor-lib.sh" "$T/h/bin/lib/"
# TEST-CHANGE (BH-1585): the open list is REST now; the contract lib rides beside gh-pr-list.sh.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
mkdir -p "$T/h/bin/lib/mc" && cp "$DIR"/bin/lib/mc/*.sh "$T/h/bin/lib/mc/"
cp "$DIR/bin/lib/flaky.sh" "$T/h/bin/lib/" 2>/dev/null
# BH-1586: mc_ci_state reads the run list through gh_rest, so the fixture carries
# the library and the stub answers that read as a whole HTTP response.
cp "$DIR/bin/lib/gh-rest.sh" "$DIR/bin/lib/gh-rest-var.sh" "$T/h/bin/lib/"
cp "$DIR/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
[ -s "$T/h/bin/lib/flaky.sh" ] && ok || bad "bin/lib/flaky.sh missing"
printf 'demo example-org/demo-os https://demo.example /api/board 2 box-demo\n' > "$T/h/fleet.conf"
: > "$T/h/env/global.env"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nexit 0\n' > "$T/h/bin/beat.sh"; chmod +x "$T/h/bin/beat.sh"
printf '#!/bin/bash\necho "" > "$4"; exit 0\n' > "$T/h/bin/agent-call.sh"; chmod +x "$T/h/bin/agent-call.sh"
cat > "$T/h/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1 $2" in
  "--projects ") echo "demo" ;;
  "demo repo") echo "example-org/demo-os" ;;
  "demo board_prefix") echo "PB" ;;
esac
SH
chmod +x "$T/h/bin/fleet-conf.sh"
# The ledger read, shimmed onto the real client: metric_flakes_list answers from
# $FLAKE_LEDGER in the TSV shape bin/jobs-client.sh's reader prints
# (day, repo, workflow, test, head, kind).
cat >> "$T/h/bin/jobs-client.sh" <<'SH'
metric_flakes_list() { cat "${FLAKE_LEDGER:-/dev/null}" 2>/dev/null; }
SH

H1=aaaaaaaa1111
# An approved build record for PR 11 bound to H1, so the only thing between it
# and READY is the red CI this test is about.
mkdir -p "$T/h/builds/demo-os-TK-11-202609120001"
echo "PR_CREATED https://github.com/example-org/demo-os/pull/11" > "$T/h/builds/demo-os-TK-11-202609120001/RESULT"
printf 'findings\nTIER: 2\nVERDICT: APPROVE\n' > "$T/h/builds/demo-os-TK-11-202609120001/review.md"
echo "$H1" > "$T/h/builds/demo-os-TK-11-202609120001/reviewed-sha"

# gh stub. The two reads of actions/runs?head_sha are told apart by their -q
# expression: mc_ci_state asks for status|conclusion, the flake path asks for
# the failed runs' ids (select(.conclusion).
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
# BH-2275: no .mergify.yml in this fixture repo — GitHub's own 404, so the queue
# provider reads "none" from a real read (not a fallback on an unreadable probe).
case "\$*" in *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;; esac
printf '%s\n' "\$*" >> "$T/gh-calls.txt"
case "\$*" in
  *"run rerun"*) printf '%s\n' "\$*" >> "$T/reruns.txt"; exit 0 ;;
  *"pr merge"*|*"push"*|*"pr comment"*|*"issue close"*|*"pr review"*|*"pr edit"*)
    printf '%s\n' "\$*" >> "$T/gh-writes.txt"; exit 1 ;;
  *"pr list -R example-org/demo-os --state open"*)
    cat <<'J'
[{"number":11,"url":"https://github.com/example-org/demo-os/pull/11","headRefOid":"$H1","headRefName":"ticket/TK-11","isDraft":false,"mergeStateStatus":"CLEAN","mergeable":"MERGEABLE","state":"OPEN"}]
J
    ;;
  *"pr list"*) echo "[]" ;;
  *"select(.conclusion"*) printf '900|.github/workflows/ci.yml|CI\n' ;;
  *"actions/runs?head_sha=$H1"*) restpr --runs 'completed|failure|900|CI' ;;
  *"actions/runs/900/jobs"*) echo "unit" ;;
  "run view 900 "*"--log-failed"*) cat "$T/failed-log.txt" 2>/dev/null || exit 1 ;;
  *"pr view"*"--json body"*) echo "plain body" ;;
  *"pr diff"*) printf '+++ b/src/x.ts\n+const a = 1;\n' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"

D=$(date -u +%Y-%m-%d)
FLAKY_NAME="queue > drains under load"
ledger() { # ledger known|empty
  : > "$T/ledger.tsv"
  [ "$1" = known ] || return 0
  local hd
  for hd in h1 h2 h3; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$D" example-org/demo-os .github/workflows/ci.yml \
      "$FLAKY_NAME" "$hd" flake >> "$T/ledger.tsv"
  done
}
failing_log() { printf '2026-09-12T00:00:00Z    \xc3\x97 %s 12ms\n' "$1" > "$T/failed-log.txt"; }
tick() {
  : > "$T/gh-calls.txt"; : > "$T/reruns.txt"; : > "$T/gh-writes.txt"
  ( cd "$T" && PATH="$T/fakebin:$PATH" HARNESS="$T/h" HARNESS_SECRET=x \
      FLAKE_LEDGER="$T/ledger.tsv" bash "$T/h/bin/merge-conductor.sh" >/dev/null 2>"$T/tick.err" ) \
    || { echo "tick rc=$? stderr:"; head -5 "$T/tick.err"; }
}
strikes() { grep -c "^red example-org/demo-os#11 " "$T/h/state/merge-conductor/attempts.txt" 2>/dev/null || true; }
state_of() { awk -F'\t' -v k="$1" '$1==k {print $2}' "$T/h/state/merge-conductor/pr-state.tsv" 2>/dev/null; }
fresh() { rm -rf "$T/h/state/merge-conductor" "$T/h/logs"; mkdir -p "$T/h/logs"; }

# ===========================================================================
# 1. Known-flake red: ONE rerun, and NO red strike
# ===========================================================================
fresh; ledger known; failing_log "$FLAKY_NAME"
touch "$T/h/flags/merge-conductor-actions"
tick
[ "$(grep -c . "$T/reruns.txt")" = 1 ] \
  && ok || bad "a known-flake red must dispatch exactly one rerun (got '$(cat "$T/reruns.txt")')"
grep -q 'run rerun 900 --failed' "$T/reruns.txt" \
  && ok || bad "the rerun must be 'gh run rerun <id> --failed' on the failed run (got '$(cat "$T/reruns.txt")')"
[ "$(strikes)" = 0 ] \
  && ok || bad "a known-flake red must NOT record a red strike (got $(strikes))"
[ "$(state_of 'example-org/demo-os#11')" = WAIT_CI ] \
  && ok || bad "the PR stays WAIT_CI while the rerun runs (got '$(state_of 'example-org/demo-os#11')')"
grep -qi 'known flake' "$T/h/logs/merge-conductor.log" \
  && ok || bad "the rerun must be logged as a known flake, not left silent"
[ -s "$T/gh-writes.txt" ] && bad "no other write verb may be used: $(cat "$T/gh-writes.txt")" || ok

# ===========================================================================
# 2. Same head, red AGAIN: one rerun only, and now it is a real red
# ===========================================================================
tick
[ -s "$T/reruns.txt" ] && bad "a second red on the SAME head must not buy a second rerun" || ok
[ "$(strikes)" = 1 ] \
  && ok || bad "the second red on the same head must record the strike (got $(strikes))"

# ===========================================================================
# 3. A red whose failing tests are NOT known flakes strikes as it always did.
#    Since the red ladder it is still RE-RUN once — that is the ladder's rung 1,
#    not this file's forgiveness — but the strike is recorded on sight, which is
#    the whole difference between a flaky red and a broken one.
# ===========================================================================
fresh; ledger empty; failing_log "auth > rejects an expired token"
tick
[ "$(strikes)" = 1 ] \
  && ok || bad "an unknown red must record a strike on the first tick (got $(strikes))"
[ "$(grep -c . "$T/reruns.txt")" = 1 ] \
  && ok || bad "the red ladder re-runs an unknown red once too (got '$(cat "$T/reruns.txt")')"
grep -q 'red ladder rung 1' "$T/h/logs/merge-conductor.log" \
  && ok || bad "an unknown red's rerun must be logged as the ladder's, not as a known flake"
grep -qi 'known flake' "$T/h/logs/merge-conductor.log" \
  && bad "an unknown red must never be logged as a known flake" || ok

# 3b. a known flake PLUS an unknown failure is an unknown red — ALL or nothing
fresh; ledger known
{ printf '2026-09-12T00:00:00Z    \xc3\x97 %s 12ms\n' "$FLAKY_NAME"
  printf '2026-09-12T00:00:00Z    \xc3\x97 auth > rejects an expired token 3ms\n'; } > "$T/failed-log.txt"
tick
[ "$(strikes)" = 1 ] \
  && ok || bad "a mixed red must strike (got $(strikes))"
grep -qi 'known flake' "$T/h/logs/merge-conductor.log" \
  && bad "one unknown failure alongside a known flake must not be forgiven as a flake" || ok

# 3c. a red whose failing tests cannot be NAMED at all fails CLOSED
fresh; ledger known; rm -f "$T/failed-log.txt"
tick
[ "$(strikes)" = 1 ] \
  && ok || bad "an unreadable red must strike (got $(strikes))"
grep -qi 'known flake' "$T/h/logs/merge-conductor.log" \
  && bad "a red we cannot name must fail CLOSED — never forgiven as a flake" || ok

# 3d. ONE rerun per head, whoever bought it: a head the ladder re-ran must not
#     then buy a second rerun from the flake path (and vice versa).
fresh; ledger empty; failing_log "auth > rejects an expired token"
tick
ledger known; failing_log "$FLAKY_NAME"
tick
[ -s "$T/reruns.txt" ] \
  && bad "a head that already had its ladder rerun must not buy a flake rerun too: $(cat "$T/reruns.txt")" || ok
[ "$(grep -c "^cirerun example-org/demo-os#11 " "$T/h/state/merge-conductor/attempts.txt")" = 1 ] \
  && ok || bad "the rerun mark is one per (PR, head) (got $(grep -c "^cirerun example-org/demo-os#11 " "$T/h/state/merge-conductor/attempts.txt"))"

# ===========================================================================
# 3e. RED IS COUNTED PER HEAD, NEVER ACROSS HEADS (BH-1671). Two earlier heads
#     of this PR went red (their strikes are in the ledger) and the current head
#     goes red ONCE. That used to park BLOCKED_HUMAN red-ci-twice on sight,
#     before this head's rerun, and the resolver's rebuild rung closed the PR as
#     superseded on a count spanning code no longer on the branch. Now this head
#     climbs its own ladder: WAIT_CI + one rerun, and only red AGAIN on this same
#     head parks it (RED_TWICE).
# ===========================================================================
fresh; ledger empty; failing_log "auth > rejects an expired token"
mkdir -p "$T/h/state/merge-conductor"
{ echo "red example-org/demo-os#11 1111111111aa"; echo "red example-org/demo-os#11 3333333333cc"; } \
  >> "$T/h/state/merge-conductor/attempts.txt"
tick
[ "$(strikes)" = 3 ] \
  && ok || bad "the strike ledger still records this head's red (got $(strikes))"
[ "$(state_of 'example-org/demo-os#11')" = WAIT_CI ] \
  && ok || bad "red on two EARLIER heads plus red once on this one must be WAIT_CI, not a park (got '$(state_of 'example-org/demo-os#11')')"
grep -q 'red-ci-twice' "$T/h/logs/merge-conductor.log" \
  && bad "a cross-head red count must never park red-ci-twice: $(grep 'red-ci-twice' "$T/h/logs/merge-conductor.log" | head -2)" || ok
[ "$(grep -c . "$T/reruns.txt")" = 1 ] \
  && ok || bad "this head must get its own one rerun first (got '$(cat "$T/reruns.txt")')"
[ -s "$T/gh-writes.txt" ] && bad "no close/comment/merge on a head that went red once: $(cat "$T/gh-writes.txt")" || ok
# The rerun settles and the SAME head is red again: now, and only now, it parks.
A="$T/h/state/merge-conductor/attempts.txt"
grep -v "^cirerun example-org/demo-os#11 $H1 " "$A" > "$T/a.tmp"; mv "$T/a.tmp" "$A"
echo "cirerun example-org/demo-os#11 $H1 $(( $(date -u +%s) - 600 ))" >> "$A"
tick
[ "$(state_of 'example-org/demo-os#11')" = RED_TWICE ] \
  && ok || bad "red again on the SAME head after its rerun must be RED_TWICE (got '$(state_of 'example-org/demo-os#11')')"

# ===========================================================================
# 4. Observe mode: rerun is a write verb and must not happen
# ===========================================================================
fresh; ledger known; failing_log "$FLAKY_NAME"
rm -f "$T/h/flags/merge-conductor-actions"
tick
[ -s "$T/reruns.txt" ] && bad "observe-only must not re-run anything: $(cat "$T/reruns.txt")" || ok
[ "$(strikes)" = 1 ] \
  && ok || bad "with no actions flag the red counts exactly as it does today (got $(strikes))"

echo "flaky-rerun-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
