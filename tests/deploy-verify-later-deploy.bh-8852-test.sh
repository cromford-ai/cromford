#!/bin/bash
# tests/deploy-verify-later-deploy.bh-8852-test.sh — bin/deploy-verify.sh
# accepts a later successful production deployment that contains the merge sha.
#
# THE INCIDENT (project-6-os, 2026-10-31). Vercel skips the build of a merge sha
# that a newer main commit supersedes. f0c814df never got a deployment of its
# own, 4 later commits each deployed with success, and compare f0c814df...4c9e090a
# read ahead_by=4. deploy-verify polled deployments?sha=f0c814df for 20 min and
# paged "no successful production deployment within 20 min" twice (alerts 51400
# and 51427). Both pages were false.
#
# Driven end to end with gh/curl/beat/sleep stubbed. The gh stub applies the
# script's own `-q` jq filters to fixture JSON, so the environment filter and
# the terminal-state filter are the script's, not the stub's. A case that must
# NOT pass runs under `timeout` and must still be polling (rc 124) with no
# "contains" line, no OK line and no ALERTS line.
# Run from anywhere: tests/deploy-verify-later-deploy.bh-8852-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v timeout >/dev/null || { echo "timeout missing — skipping"; exit 0; }

# DV_SCRIPT lets the red proof run this suite against main's script.
DV_SCRIPT="${DV_SCRIPT:-$DIR/bin/deploy-verify.sh}"
H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/env" "$T/fakebin"
cp "$DV_SCRIPT" "$H/bin/deploy-verify.sh"
cp "$DIR/bin/prod-url.sh" "$DIR/bin/fleet-conf.sh" "$H/bin/"
# The copy above wins (no-clobber); the helper adds the bin/lib closure.
scratch_install_closure bin/deploy-verify.sh "$H" >/dev/null || { echo "FAIL: scratch_install_closure"; exit 1; }
chmod +x "$H/bin/"*.sh
printf 'tproj o/tproj https://tproj.example - 2 box-t 100.0.0.9\n' > "$H/fleet.conf"
: > "$H/env/global.env"
: > "$H/env/tproj.env"   # no DEPLOY_HOOK_URL: the hook path is out of scope
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$DV_CASE/beat.txt"\nexit 0\n' > "$H/bin/beat.sh"; chmod +x "$H/bin/beat.sh"

# gh: every answer comes from the case dir $DV_CASE.
#   deployments?sha=<A>         $DV_CASE/exact (default [])
#   deployments?per_page=1      the readability probe: []
#   deployments?per_page=<n>    $DV_CASE/list
#   deployments/<id>/statuses   $DV_CASE/state.<id>
#   compare/<A>...<B>           $DV_CASE/cmp.<B>; "ERR" answers like a 404
# A `-q <filter>` argument is applied with jq, as gh does.
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$DV_CASE/gh.log"
Q=""; URL=""; prev=""
for a in "$@"; do
  [ "$prev" = "-q" ] && Q="$a"
  case "$a" in repos/*) URL="$a" ;; esac
  prev="$a"
done
case "$URL" in
  *"/deployments?sha="*) BODY=$(cat "$DV_CASE/exact" 2>/dev/null || echo '[]') ;;
  *"/deployments?per_page=1") BODY='[]' ;;
  *"/deployments?per_page="*) BODY=$(cat "$DV_CASE/list") ;;
  *"/statuses"*) ID=${URL#*/deployments/}; ID=${ID%%/*}; BODY=$(cat "$DV_CASE/state.$ID" 2>/dev/null || echo '[]') ;;
  *"/compare/"*)
    B=${URL##*...}
    BODY=$(cat "$DV_CASE/cmp.$B" 2>/dev/null || echo ERR)
    [ "$BODY" = ERR ] && { echo "gh: Not Found (HTTP 404)" >&2; exit 1; } ;;
  *"/deployments/"*) ID=${URL##*/}; BODY=$(jq -c --arg id "$ID" '.[] | select((.id|tostring) == $id)' "$DV_CASE/list" 2>/dev/null) ;;
  *) BODY="" ;;
esac
if [ -n "$Q" ]; then printf '%s' "$BODY" | jq -r "$Q"; else printf '%s\n' "$BODY"; fi
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\ncat "$DV_CASE/code" 2>/dev/null || echo 200\nexit 0\n' > "$T/fakebin/curl"; chmod +x "$T/fakebin/curl"
REAL_SLEEP=$(command -v sleep)
printf '#!/bin/bash\n%s 0.2\nexit 0\n' "$REAL_SLEEP" > "$T/fakebin/sleep"; chmod +x "$T/fakebin/sleep"

N=0
NEWCASE() { # NEWCASE -> sets C (case dir) and A (a unique merge sha)
  N=$((N+1)); C="$T/case$N"; mkdir -p "$C/build"
  A=$(printf 'a%07d' "$N"; printf '%032d' "$N"); A=${A:0:40}
}
DEP()   { printf '{"id":%s,"sha":"%s","environment":"%s","created_at":"2026-10-31T0%s:00:00Z"}' "$1" "$2" "$3" "$4"; }
STATE() { printf '[{"state":"%s"}]\n' "$2" > "$C/state.$1"; }
CMP()   { printf '{"status":"%s"}\n' "$2" > "$C/cmp.$1"; }
RUN() { # RUN <timeout-s> -> rc
  : > "$H/logs/ALERTS.log"
  ( export DV_CASE="$C"; PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" \
      timeout "$1" bash "$H/bin/deploy-verify.sh" tproj o/tproj "$A" "$C/build" >/dev/null 2>&1 )
}
PIPE() { cat "$C/build/pipeline.log" 2>/dev/null; }
NOPASS() { # NOPASS <label> <rc>
  [ "$2" = 124 ] && ok || bad "$1: the verify must still be polling inside the window (rc=$2, want 124)"
  grep -q 'which contains' <<<"$(PIPE)" && bad "$1: no 'contains' line may be written (got: $(PIPE))" || ok
  grep -q 'deploy-verify OK' <<<"$(PIPE)" && bad "$1: no OK line may be written (got: $(PIPE))" || ok
  [ -s "$H/logs/ALERTS.log" ] && bad "$1: no ALERTS line inside the window (got: $(cat "$H/logs/ALERTS.log"))" || ok
}
B1=bbbbbbbb11111111111111111111111111111111
B2=cccccccc22222222222222222222222222222222

# ============================================================================
# 1. No deployment for A; B succeeded and compare A...B is ahead -> PASS.
# ============================================================================
NEWCASE
echo "[$(DEP 901 "$B1" Production 8)]" > "$C/list"; STATE 901 success; CMP "$B1" ahead
RUN 10; RC=$?
[ "$RC" = 0 ] && ok || bad "case 1: a later success that contains A must pass (rc=$RC, log: $(PIPE))"
grep -qF "deploy-verify: verified through ${B1:0:8}, which contains ${A:0:8}" <<<"$(PIPE)" && ok \
  || bad "case 1: want 'verified through ${B1:0:8}, which contains ${A:0:8}' (got: $(PIPE))"
grep -q 'deploy-verify OK' <<<"$(PIPE)" && ok || bad "case 1: the smoke check and OK line must still run (got: $(PIPE))"
[ -s "$H/logs/ALERTS.log" ] && bad "case 1: a pass must write no ALERTS line" || ok

# 1b. identical is a pass too.
NEWCASE
echo "[$(DEP 902 "$B1" production 8)]" > "$C/list"; STATE 902 success; CMP "$B1" identical
RUN 10; RC=$?
[ "$RC" = 0 ] && ok || bad "case 1b: compare identical must pass (rc=$RC)"
grep -qF "verified through ${B1:0:8}, which contains ${A:0:8}" <<<"$(PIPE)" && ok || bad "case 1b: want the contains line (got: $(PIPE))"

# 1c. a pass through B still smokes: a dead prod is still a FAIL.
NEWCASE
echo "[$(DEP 903 "$B1" Production 8)]" > "$C/list"; STATE 903 success; CMP "$B1" ahead; echo 503 > "$C/code"
RUN 10; RC=$?
[ "$RC" = 1 ] && ok || bad "case 1c: a pass through B must still FAIL on a dead prod (rc=$RC)"
grep -q 'prod smoke check' "$H/logs/ALERTS.log" && ok || bad "case 1c: the smoke FAIL must alert"

# ============================================================================
# 2. B failed (compare ahead) -> no pass; the verify keeps to today's FAIL.
# ============================================================================
NEWCASE
echo "[$(DEP 911 "$B1" Production 8)]" > "$C/list"; STATE 911 failure; CMP "$B1" ahead
RUN 3; NOPASS "case 2 (B failure)" $?
NEWCASE
echo "[$(DEP 912 "$B1" Production 8)]" > "$C/list"; STATE 912 error; CMP "$B1" ahead
RUN 3; NOPASS "case 2 (B error)" $?

# 2b. B failed and is newest; an older C succeeded but is behind A -> no pass.
NEWCASE
echo "[$(DEP 913 "$B1" Production 8),$(DEP 914 "$B2" Production 6)]" > "$C/list"
STATE 913 failure; CMP "$B1" ahead; STATE 914 success; CMP "$B2" behind
RUN 3; NOPASS "case 2b (newest failed, older success behind)" $?

# ============================================================================
# 3. B succeeded, but compare is diverged / behind / unreadable -> no pass.
# ============================================================================
NEWCASE
echo "[$(DEP 921 "$B1" Production 8)]" > "$C/list"; STATE 921 success; CMP "$B1" diverged
RUN 3; NOPASS "case 3 (diverged)" $?
# 4. memo: the compare answer for one (A, B) pair is read once per run.
POLLS=$(grep -c "deployments?sha=$A" "$C/gh.log")
CMPS=$(grep -c "compare/$A...$B1" "$C/gh.log")
[ "$POLLS" -ge 2 ] && ok || bad "case 4: the loop must poll more than once in 3 s (polls=$POLLS)"
[ "$CMPS" = 1 ] && ok || bad "case 4: the compare for B must be read once per run (got $CMPS over $POLLS polls)"
NEWCASE
echo "[$(DEP 922 "$B1" Production 8)]" > "$C/list"; STATE 922 success; CMP "$B1" behind
RUN 3; NOPASS "case 3 (behind)" $?
NEWCASE
echo "[$(DEP 923 "$B1" Production 8)]" > "$C/list"; STATE 923 success   # no cmp file: gh 404s
RUN 3; NOPASS "case 3 (compare unreadable)" $?
NEWCASE
echo "[$(DEP 924 "$B1" Production 8)]" > "$C/list"; STATE 924 success; printf '{}\n' > "$C/cmp.$B1"
RUN 3; NOPASS "case 3 (compare empty)" $?

# 3b. only a Preview deployment succeeded -> no pass.
NEWCASE
echo "[$(DEP 931 "$B1" Preview 8)]" > "$C/list"; STATE 931 success; CMP "$B1" ahead
RUN 3; NOPASS "case 3b (Preview)" $?

# ============================================================================
# 5. Newest B is pending; older C succeeded and is ahead -> pass through C.
# ============================================================================
NEWCASE
echo "[$(DEP 941 "$B1" Production 8),$(DEP 942 "$B2" Production 6)]" > "$C/list"
printf '[{"state":"pending"}]\n' > "$C/state.941"; STATE 942 success; CMP "$B2" ahead
RUN 10; RC=$?
[ "$RC" = 0 ] && ok || bad "case 5: the newest successful deployment C must pass (rc=$RC, log: $(PIPE))"
grep -qF "verified through ${B2:0:8}, which contains ${A:0:8}" <<<"$(PIPE)" && ok \
  || bad "case 5: want 'verified through ${B2:0:8}' (got: $(PIPE))"

# ============================================================================
# 6. An exact-sha deployment exists -> today's path; the later scan never runs.
# ============================================================================
NEWCASE
echo "[$(DEP 951 "$A" Production 8)]" > "$C/exact"; STATE 951 success
echo "[$(DEP 952 "$B1" Production 9)]" > "$C/list"; STATE 952 success; CMP "$B1" ahead
RUN 10; RC=$?
[ "$RC" = 0 ] && ok || bad "case 6: the exact deployment must verify (rc=$RC)"
grep -q 'which contains' <<<"$(PIPE)" && bad "case 6: the exact path must not write the contains line" || ok
grep -q 'compare/' "$C/gh.log" && bad "case 6: the exact path must not read a compare" || ok

echo "deploy-verify-later-deploy.bh-8852-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
