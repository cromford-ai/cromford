#!/bin/bash
# tests/gh-repo-token-test.sh — bin/lib/gh-repo-token.sh against a gh shim.
#
# The rule under test (2026-09-12, the 10-hour project-5 loss): a repo the
# default gh token cannot see is routed to the admin token when that one can,
# and a repo NO token can see is an ALERT — one per (lane, repo, day) — never
# a silent empty loop. Token VALUES never reach ALERTS.log.
# Run from anywhere: tests/gh-repo-token-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
mkdir -p "$T/bin/lib" "$T/env" "$T/flags" "$T/logs" "$T/fakebin"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cp "$DIR/bin/lib/gh-repo-token.sh" "$T/bin/lib/"
cp "$DIR/bin/alert-line.sh" "$T/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
echo 'GH_ADMIN_TOKEN=admintok' > "$T/env/github-admin.env"
cp "$DIR/bin/lib/gh-budget.sh" "$T/bin/lib/"
# gh_repo_invisible_alert keeps its day flag through bin/lib/flags.sh (BH-7252):
# install that lib and the jobs client it loads.
( cd "$DIR" && scratch_install_closure bin/lib/flags.sh "$T" && scratch_install_closure bin/jobs-client.sh "$T" ) >/dev/null \
  || bad "setup: could not install bin/lib/flags.sh + bin/jobs-client.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "$BEAT_SINK"\n' > "$T/bin/beat.sh"; chmod +x "$T/bin/beat.sh"
# gh shim: o/seen is visible to any token, o/adminonly only to the admin token, o/blind to none.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
RESET=1757725102
case "$*" in
  "api repos/o/seen -q .id")      exit 0 ;;
  "api repos/o/adminonly -q .id") [ "${GH_TOKEN:-}" = admintok ] && exit 0; exit 1 ;;
  "api rate_limit")
    if [ "${RATE_LIMIT:-full}" = exhausted ]; then
      jq -nc --argjson r "$RESET" '{
        resources: {
          core: {limit:5000, remaining:0, reset:$r, used:5000},
          graphql: {limit:5000, remaining:4999, reset:$r, used:1},
          search: {limit:30, remaining:30, reset:$r, used:0},
          code_scanning_upload: {limit:1000, remaining:1000, reset:$r, used:0}
        }
      }'
    else
      jq -nc --argjson r "$RESET" '{
        resources: {
          core: {limit:5000, remaining:4996, reset:$r, used:4},
          graphql: {limit:5000, remaining:4999, reset:$r, used:1},
          search: {limit:30, remaining:30, reset:$r, used:0},
          code_scanning_upload: {limit:1000, remaining:1000, reset:$r, used:0}
        }
      }'
    fi
    ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"

drive() { # drive <bash snippet>; the lib is sourced fresh with HARNESS=$T
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" BEAT_SINK="$T/beats.txt"; unset GH_TOKEN
    # shellcheck source=/dev/null
    . "$T/bin/lib/gh-repo-token.sh"; eval "$1" )
}

# 1. routing
[ "$(drive 'gh_repo_token_for o/seen')" = default ] && ok || bad "a visible repo should route to the default token"
[ "$(drive 'gh_repo_token_for o/adminonly')" = admin ] && ok || bad "an admin-only repo should route to the admin token"
[ "$(drive 'gh_repo_token_for o/blind')" = none ] && ok || bad "a repo nobody sees should read none"
[ "$(drive 'gh_repo_use_token o/adminonly; printf %s "${GH_TOKEN:-}"')" = admintok ] && ok || bad "use_token did not export the admin token"
[ "$(drive 'gh_repo_use_token o/blind; echo rc=$? tok=${GH_TOKEN:-unset}')" = "rc=1 tok=unset" ] && ok || bad "use_token on a blind repo must rc 1 and leave the default token"
# A SECOND ask after the admin token was exported still answers admin: the probe
# pins the default token, it never trusts whatever GH_TOKEN holds right now
# (2026-09-13: mc_git_auth's re-ask reset review-rescue to the blind PAT).
[ "$(drive 'gh_repo_use_token o/adminonly; gh_repo_use_token o/adminonly; printf %s "${GH_TOKEN:-unset}"')" = admintok ] && ok || bad "second use_token reset the admin token"
[ "$(drive 'gh_repo_use_token o/adminonly; gh_repo_token_for o/adminonly')" = admin ] && ok || bad "token_for after use_token must still say admin"
# The answer is cached per process: a second ask costs no gh call (shim counts would show, but cheaper to assert the cache var).
OUT=$(drive 'gh_repo_token_for o/seen >/dev/null; gh_repo_token_for o/seen; echo "${_GHRT_REPO_TOK[o/seen]}"')
[ "$OUT" = $'default\ndefault' ] && ok || bad "per-process cache missing: $OUT"

# 2. the alert: one line per (lane, repo, day); names the repo, the default
#    token, and the admin token's verdict; never the token value
: > "$T/logs/ALERTS.log"; : > "$T/beats.txt"
drive 'gh_repo_invisible_alert merge-sweep o/blind "3 approved PRs skipped"; gh_repo_invisible_alert merge-sweep o/blind "again"'
[ "$(grep -c "INVISIBLE" "$T/logs/ALERTS.log")" = 1 ] && ok || bad "expected exactly one ALERT line per day, got: $(cat "$T/logs/ALERTS.log")"
grep -q "\[merge-sweep\] repo o/blind is INVISIBLE to the default gh token (the admin token cannot see it either) — 3 approved PRs skipped" "$T/logs/ALERTS.log" \
  && ok || bad "alert wording: $(cat "$T/logs/ALERTS.log")"
# BH-765: and it says which of the three rungs it tried. This tree has no App
# credentials at all, which is the case an operator most needs spelled out —
# "not armed on this box" is a different instruction from "could not see it".
grep -q 'Tried: tried the App installation token: not armed on this box; the default PAT: blind; the admin PAT: blind\.' "$T/logs/ALERTS.log" \
  && ok || bad "the alert must say what each rung answered: $(cat "$T/logs/ALERTS.log")"
grep -q '"akey":"repoinvisible:merge-sweep:o/blind"' "$T/beats.txt" && grep -q '"kind":"fleet_alert"' "$T/beats.txt" \
  && ok || bad "no fleet_alert beat with the repoinvisible akey: $(cat "$T/beats.txt")"
grep -q admintok "$T/logs/ALERTS.log" "$T/beats.txt" && bad "the admin token VALUE leaked into an alert" || ok
# admin CAN see it -> the alert says so (the fix is to route this consumer through it)
drive 'gh_repo_invisible_alert stalepr o/adminonly "check skipped"'
grep -q "repo o/adminonly is INVISIBLE to the default gh token (the admin token CAN see it — route this consumer through it)" "$T/logs/ALERTS.log" \
  && ok || bad "admin-can-see wording missing: $(tail -1 "$T/logs/ALERTS.log")"
# no admin token file at all
rm -f "$T/env/github-admin.env"
drive 'gh_repo_invisible_alert other o/blind "x"'
grep -q "no admin token on this box" "$T/logs/ALERTS.log" && ok || bad "absent admin env should be named: $(tail -1 "$T/logs/ALERTS.log")"
echo 'GH_ADMIN_TOKEN=admintok' > "$T/env/github-admin.env"

# 3. a failed list on a VISIBLE repo is a log line in the lane's own log, not a page
: > "$T/logs/ALERTS.log"
drive 'gh_repo_list_failed pipeline-health o/seen "stalepr skipped this tick"'
[ ! -s "$T/logs/ALERTS.log" ] && grep -q "gh pr list failed for o/seen (repo is visible; transient?)" "$T/logs/pipeline-health.log" \
  && ok || bad "transient list failure must log, not page: ALERTS=$(cat "$T/logs/ALERTS.log") log=$(cat "$T/logs/pipeline-health.log" 2>/dev/null)"
# ...and on an INVISIBLE repo it is the page
rm -f "$T"/flags/alerted-repo-invisible-*
drive 'gh_repo_list_failed pipeline-health o/blind "stalepr skipped"'
grep -q "\[pipeline-health\] repo o/blind is INVISIBLE" "$T/logs/ALERTS.log" && ok || bad "list failure on a blind repo must page: $(cat "$T/logs/ALERTS.log")"
# 4. an exhausted API bucket pages instead of the transient line
rm -f "$T"/flags/alerted-gh-ratelimit-*; : > "$T/logs/ALERTS.log"; : > "$T/logs/pipeline-health.log"
drive 'RATE_LIMIT=exhausted gh_repo_list_failed pipeline-health o/seen "stalepr skipped"'
grep -q "GitHub API rate-limited: core 0/5000 resets at" "$T/logs/ALERTS.log" && ok || bad "exhausted core should page: $(cat "$T/logs/ALERTS.log")"
! grep -q "transient?" "$T/logs/pipeline-health.log" && ok || bad "exhausted must not write the transient line: $(cat "$T/logs/pipeline-health.log")"
grep -q '"akey":"ghratelimit:pipeline-health:core:1757725102"' "$T/beats.txt" && ok || bad "exhausted should produce a fleet_alert beat: $(cat "$T/beats.txt")"
# with budget available the existing transient assertion still holds
rm -f "$T"/flags/alerted-gh-ratelimit-*; : > "$T/logs/ALERTS.log"; : > "$T/logs/pipeline-health.log"
drive 'gh_repo_list_failed pipeline-health o/seen "stalepr skipped"'
[ ! -s "$T/logs/ALERTS.log" ] && grep -q "transient?" "$T/logs/pipeline-health.log" \
  && ok || bad "non-exhausted list failure must still log transient: ALERTS=$(cat "$T/logs/ALERTS.log") log=$(cat "$T/logs/pipeline-health.log")"

echo "gh-repo-token: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
