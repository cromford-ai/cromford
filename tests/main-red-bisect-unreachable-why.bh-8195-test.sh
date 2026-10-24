#!/bin/bash
# tests/main-red-bisect-unreachable-why.bh-8195-test.sh — BH-8195: the
# main-red-bisect `forge-unreachable` log line names its cause.
#
#   THE INCIDENT (2026-10-23). On bh-hub-2 logs/main-red-bisect.log held only
#   `example-org/cromford forge-unreachable rc=75`. mrb_detect_episodes
#   returns 75 for 8 causes and writes the reason to stderr, and the cron line
#   sends stderr to /dev/null. Nobody could read the cause.
#
#   B1  the line holds `forge-unreachable rc=75` and `why=<the detect's last
#       mrb-detect: line>`.
#   B2  GH_REST_STATUS / GH_REST_REASON from the detect show as http= reason=.
#   B3  an empty stderr gives `why=-` (and gh-rest's `http=000 reason=-`); a trailing line
#       that does not start with `mrb-detect: ` is not taken.
#   B4  rc 0 gives no forge-unreachable line; the episodes line is unchanged.
#
# The REAL bin/main-red-bisect.sh runs in a scratch harness (scratch_install_closure;
# the fixture shape of tests/main-red-bisect.bh-3685-test.sh). MAIN_RED_BISECT_FIXTURE redefines
# mrb_detect_episodes as a fake that prints $T/detect-err to stderr, sets the
# gh-rest vars from $T/http and $T/reason, and returns $T/detect-rc.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/main-red-bisect-unreachable-why.bh-8195-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }
has() { if grep -qF -- "$3" <<<"$2"; then ok; else bad "$1: no [$3] in: ${2:0:400}"; fi; }
hasnt() { if grep -qF -- "$3" <<<"$2"; then bad "$1: unexpected [$3]"; else ok; fi; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/state" "$H/flags" "$H/logs" "$H/catalog" "$T/repos/cromford"
scratch_install_closure bin/main-red-bisect.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
printf '#!/bin/bash\n[ "${BASH_SOURCE[0]}" = "$0" ] || return 0\nexit 0\n' > "$H/bin/jobs-client.sh"
printf '#!/bin/bash\necho "$*" >> "%s/alerts"\n' "$T" > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/jobs-client.sh" "$H/bin/lane-alert.sh"
echo local > "$H/state/box-name"

cat > "$T/fakes.sh" <<SH
F="$T"
mrb_detect_episodes() {
  [ -f "\$F/detect-err" ] && cat "\$F/detect-err" >&2
  [ -f "\$F/http" ] && GH_REST_STATUS=\$(cat "\$F/http")
  [ -f "\$F/reason" ] && GH_REST_REASON=\$(cat "\$F/reason")
  return "\$(cat "\$F/detect-rc" 2>/dev/null || echo 0)"
}
mrb_probe() { echo red; }
mrb_bisect() { echo "aborted - 0"; }
mrb_episode_still_red() { return 0; }
mrb_act_culprit() { return 0; }
mrb_act_notmerge() { return 0; }
SH

SLUG=example-org/cromford
LOG="$H/logs/main-red-bisect.log"
reset() { rm -f "$T/detect-err" "$T/http" "$T/reason" "$T/detect-rc" "$LOG"; }
run() {
  env -i PATH="$PATH" HOME="$T" HARNESS="$H" HARNESS_TEST_SANDBOX=1 \
    MAIN_RED_BISECT_FIXTURE="$T/fakes.sh" REPOS_ROOT="$T/repos" bash "$H/bin/main-red-bisect.sh" >"$T/out" 2>&1
}
cnt() { local n; n=$(grep -cF -- "$2" "$1" 2>/dev/null); printf '%s' "${n:-0}"; }

# ==== B1: the detect's reason is in the line ===================================
reset; echo 75 > "$T/detect-rc"
printf 'mrb-detect: %s: /x is not a git checkout\n' "$SLUG" > "$T/detect-err"
run; check B1-rc "$?" 0
l=$(cat "$LOG" 2>/dev/null)
check B1-one-line "$(cnt "$LOG" "$SLUG forge-unreachable")" 1
has B1-rc75 "$l" "$SLUG forge-unreachable rc=75 "
has B1-why "$l" "why=mrb-detect: $SLUG: /x is not a git checkout"
# bin/lib/gh-rest.sh (in the closure) sets GH_REST_STATUS=000, its "no HTTP status" value, at load.
has B1-no-http "$l" "http=000 reason=- "
check B1-no-stderr-leak "$(cat "$T/out")" ""

# ==== B2: the gh-rest status and reason ========================================
reset; echo 75 > "$T/detect-rc"; echo 401 > "$T/http"; echo auth-skipped > "$T/reason"
printf 'mrb-detect: %s: flag read answered rc 1\n' "$SLUG" > "$T/detect-err"
run
l=$(cat "$LOG" 2>/dev/null)
has B2-http-reason "$l" "forge-unreachable rc=75 http=401 reason=auth-skipped why=mrb-detect: $SLUG: flag read answered rc 1"

# ==== B3: empty stderr; a non-mrb-detect trailing line =========================
reset; echo 75 > "$T/detect-rc"
run
l=$(cat "$LOG" 2>/dev/null)
case "$l" in *" forge-unreachable rc=75 http=000 reason=- why=-") ok ;; *) bad "B3-empty: want why=- at the end, got [$l]" ;; esac
reset; echo 75 > "$T/detect-rc"
printf 'mrb-detect: first cause\nmrb-detect-foo: near miss\ngh-rest: GET x answered 502\n' > "$T/detect-err"
run
l=$(cat "$LOG" 2>/dev/null)
case "$l" in *" why=mrb-detect: first cause") ok ;; *) bad "B3-last-mrb-line: got [$l]" ;; esac
hasnt B3-no-near-miss "$l" "mrb-detect-foo"
reset; echo 75 > "$T/detect-rc"
printf 'mrb-detect: a\tb\r\n' > "$T/detect-err"
run
l=$(cat "$LOG" 2>/dev/null)
case "$l" in *" why=mrb-detect: a b") ok ;; *) bad "B3-tab-cr: got [$(printf '%q' "$l")]" ;; esac

# ==== B4: rc 0 =================================================================
reset; printf 'mrb-detect: noise on success\n' > "$T/detect-err"
run
l=$(cat "$LOG" 2>/dev/null)
hasnt B4-no-unreachable "$l" "forge-unreachable"
case "$l" in *" $SLUG episodes=0") ok ;; *) bad "B4-episodes-line: got [$l]" ;; esac

echo "main-red-bisect-unreachable-why.bh-8195: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
