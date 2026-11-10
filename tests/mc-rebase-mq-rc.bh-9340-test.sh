#!/bin/bash
# tests/mc-rebase-mq-rc.bh-9340-test.sh — BH-9340: mc_rebase's BH-8021 Mergify
# push refusal has its own rc for a caller that asks for it.
#
# WHAT IT PINS:
#   R1  Mergify's "In merge queue" check on the head and arg 7 `distinct`:
#       rc 9, one SKIP_PUSH line, nothing pushed.
#   R2  the same with no arg 7: rc 3, as every default caller reads today.
#       Nothing pushed.
#   R3  a dequeued check with `distinct`: the guard does not hold, it pushes
#       (rc 0 and the new head).
#
# HOW. The fixture is the BH-8021 suite's (tests/mc-land-rebase-skip.bh-8021-test.sh
# case 3): the real mc_rebase in a scratch harness, gh_rest answers check runs
# from fixture files, git is a fake on PATH, hold_push writes a trace. 0 network
# calls.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/mc-rebase-mq-rc.bh-9340-test.sh   (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: mc-rebase-mq-rc: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H1=$(printf '1%.0s' $(seq 40)); H2=$(printf '2%.0s' $(seq 40))
H3=$(printf '3%.0s' $(seq 40)); H4=$(printf '4%.0s' $(seq 40))
NEW=$(printf '9%.0s' $(seq 40)); MAIN2=$(printf 'b%.0s' $(seq 40))
SLUG=example-org/mgfy-os
FX="$T/fx"

export HARNESS="$T/h"
mkdir -p "$T/h/bin/lib/mc" "$T/h/logs" "$T/h/state" "$T/h/env" "$T/h/tmp" "$T/fakebin" "$T/repos" "$FX/set" "$FX/checks"
scratch_install_closure bin/lib/merge-conductor-lib.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/lib/migration-hold.sh "$T/h" >/dev/null || { echo "closure install failed"; exit 1; }

# The fake git: clone makes the dir, rev-parse answers the PR head first and the
# merged head after the merge, every other verb succeeds. No push verb is
# reached: the push is the stubbed hold_push below.
cat > "$T/fakebin/git" <<EOF
#!/bin/bash
A="\$*"
printf '%s\n' "\$A" >> "$T/git-argv.txt"
case "\$A" in
  *" clone "*|clone*) for d; do :; done; mkdir -p "\$d/.git"; exit 0 ;;
  *rev-parse*) if [ -f "$T/merged" ]; then printf '%s\n' "$NEW"; else cat "$T/ctl-head"; fi; exit 0 ;;
  *" merge -q "*) touch "$T/merged"; exit 0 ;;
  *" log "*) exit 0 ;;
  *" diff "*) exit 0 ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/git"
export PATH="$T/fakebin:$PATH"

# shellcheck source=/dev/null
. "$T/h/bin/lib/merge-conductor-lib.sh"; mc_init
# shellcheck source=bin/lib/gh-rest-list.sh
. "$T/h/bin/lib/gh-rest-list.sh" || { echo "gh-rest-list did not load"; exit 1; }
H="$T/h"
# shellcheck source=bin/lib/migration-hold.sh
. "$T/h/bin/lib/migration-hold.sh" || { echo "migration-hold did not load"; exit 1; }

# ---- the seams --------------------------------------------------------------
# gh_rest: check runs from FX/checks/<sha8>.json (absent = no check runs; a
# file `fail` = rc 75), the files list from FX/files-<num>.json.
gh_rest() {
  local path="$2" page=1 a
  for a in "$@"; do case "$a" in page=*) page="${a#page=}" ;; esac; done
  echo "$path" >> "$FX/rest.log"
  case "$path" in
    */check-runs)
      local sha="${path%/check-runs}"; sha="${sha##*/}"
      [ -e "$FX/checks/fail" ] && { GH_REST_STATUS=502; return 75; }
      GH_REST_STATUS=200
      if [ -f "$FX/checks/${sha:0:8}.json" ]; then cat "$FX/checks/${sha:0:8}.json"; else echo '{"check_runs":[]}'; fi ;;
    */pulls/*/files)
      local n="${path%/files}"; n="${n##*/}"
      GH_REST_STATUS=200
      if [ -f "$FX/files-$n.json" ]; then jq -c --argjson p "$page" '.[(($p-1)*100):($p*100)]' "$FX/files-$n.json"; else echo '[]'; fi ;;
    *) GH_REST_STATUS=404; return 1 ;;
  esac
}
setting_get() { [ -f "$FX/set/$1" ] || return 2; cat "$FX/set/$1"; }
mc_land_needed() { return 0; }
mc_pool_rebase_enabled() { return 1; }
mc_rr_state() { echo none; }
mc_transition() { printf '%s\t%s\n' "$1" "$2" >> "$FX/transitions"; }
mc_rebase_spawn() { printf '%s\n' "$*" >> "$FX/spawns"; return 0; }
mc_rebase_job_ref() { printf 'job'; }
mc_queue_provider() { printf 'mergify'; }
# mc_rebase's own seams (case 3).
mc_tmp_room() { return 0; }
mc_git_auth() { MC_REMOTE="https://example.test/$1.git"; return 0; }
mc_git_auth_clear() { :; }
mc_hold_push_load() { return 0; }
hold_push_verdict() { return 0; }
hold_push() { printf '%s\n' "$*" >> "$FX/pushes"; return 0; }
mc_resolve_vmap_clean_merge() { return 0; }
mc_regen_generated() { :; }
mc_rebase_cleanup() { :; }
mc_record_for() { return 1; }
job_verdict_rebind() { return 0; }

LOG="$MC_LOG"
n() { if [ -f "$1" ]; then grep -c . "$1"; else echo 0; fi; }
logn() { grep -c -- "$1" "$LOG" 2>/dev/null || true; }
# check <sha> <status|conclusion|title>... — the Mergify check runs on a head.
check() {
  local sha="$1"; shift
  printf '%s\n' "$@" | jq -Rnc '[inputs | split("|") | {name: "Mergify Merge Queue", status: .[0],
    conclusion: (if .[1] == "" then null else .[1] end), output: {title: .[2]}}] | {check_runs: .}' \
    > "$FX/checks/${sha:0:8}.json"
}
files() { local num="$1" x; shift; for x in "$@"; do printf '%s\n' "$x"; done \
  | jq -Rnc '[inputs | split(":") | {filename: .[0], status: .[1]}]' > "$FX/files-$num.json"; }
reset() {
  : > "$LOG"; : > "$MC_ATTEMPTS"; rm -f "$FX/spawns" "$FX/pushes" "$FX/transitions" "$FX/rest.log" \
    "$FX"/files-*.json "$FX"/checks/* "$FX"/set/* "$T/merged"
  scratch_rm "$MC_STATE_DIR/migration-hold"
}
URL3="https://github.com/$SLUG/pull/3"

# ============================================================================
# R1. Mergify holds the head, the caller asked for `distinct` -> rc 9
# ============================================================================
reset
echo "$H3" > "$T/ctl-head"; : > "$T/git-argv.txt"
check "$H3" 'in_progress||In merge queue'
OUT=$(MC_REPOS="$T/repos" mc_rebase "$SLUG" mgfy ticket/mg-3 "$H3" "$URL3" main distinct); RC=$?
grep -q -- ' merge -q --no-edit ' "$T/git-argv.txt" && ok || bad "R1: fixture: the rebase must reach its merge"
[ "$RC" = 9 ] && ok || bad "R1: the Mergify refusal with 'distinct' must answer rc 9, got $RC"
[ "$(n "$FX/pushes")" = 0 ] && ok || bad "R1: nothing may be pushed while Mergify holds ($(cat "$FX/pushes" 2>/dev/null))"
[ -z "$OUT" ] && ok || bad "R1: a dropped result prints no new head (got '$OUT')"
[ "$(logn "pull/3 rebase: SKIP_PUSH mergify-queue:")" = 1 ] && ok || bad "R1: exactly one SKIP_PUSH line: $(tail -3 "$LOG")"

# ============================================================================
# R2. The same, no arg 7 -> rc 3 (every default caller's contract)
# ============================================================================
reset
echo "$H3" > "$T/ctl-head"
check "$H3" 'in_progress||In merge queue'
OUT=$(MC_REPOS="$T/repos" mc_rebase "$SLUG" mgfy ticket/mg-3 "$H3" "$URL3" main); RC=$?
[ "$RC" = 3 ] && ok || bad "R2: without 'distinct' the refusal must stay rc 3, got $RC"
[ "$(n "$FX/pushes")" = 0 ] && ok || bad "R2: nothing may be pushed while Mergify holds"
OUT=$(MC_REPOS="$T/repos" mc_rebase "$SLUG" mgfy ticket/mg-3 "$H3" "$URL3"); RC=$?
[ "$RC" = 3 ] && ok || bad "R2: with only five args the refusal must stay rc 3, got $RC"
# Any other 7th word is not the opt-in.
OUT=$(MC_REPOS="$T/repos" mc_rebase "$SLUG" mgfy ticket/mg-3 "$H3" "$URL3" main other); RC=$?
[ "$RC" = 3 ] && ok || bad "R2: a 7th arg other than 'distinct' must keep rc 3, got $RC"
[ "$(n "$FX/pushes")" = 0 ] && ok || bad "R2: still nothing pushed"

# ============================================================================
# R3. A dequeued check with `distinct` -> the guard does not hold, it pushes
# ============================================================================
reset
echo "$H3" > "$T/ctl-head"
check "$H3" 'completed|failure|Dequeued: checks failed'
OUT=$(MC_REPOS="$T/repos" mc_rebase "$SLUG" mgfy ticket/mg-3 "$H3" "$URL3" main distinct); RC=$?
{ [ "$RC" = 0 ] && [ "$OUT" = "$NEW" ]; } && ok || bad "R3: a dequeued PR must push (rc $RC out '$OUT')"
[ "$(n "$FX/pushes")" = 1 ] && ok || bad "R3: exactly one push (got $(n "$FX/pushes"))"

echo "mc-rebase-mq-rc.bh-9340: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
