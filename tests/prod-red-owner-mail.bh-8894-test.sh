#!/bin/bash
# tests/prod-red-owner-mail.bh-8894-test.sh — THE TRANSITION TO A RED
# PRODUCTION DEPLOY EMAILS THE PROJECT OWNER ONCE (BH-8894, slice C0).
#
# bin/vercel-deploy-snapshot.sh pages one person on the transition to red
# (BH-8781). After that page it now calls owner_mail (bin/lib/owner-mail.sh)
# once per project, in a subshell that applies the project's lib.owner-mail
# rows, and writes `<stamp> owner-mail <p> <status>` to the lane log before the
# summary line.
#
# Driven: the REAL lane script in a scratch tree (scratch_install_closure).
# Stubs first on PATH: `curl` (the Vercel API from fixture files, every URL
# logged; any other URL fails), `npx` and `ssh`. bin/lib/page-critical.sh is a
# fake that logs. The mail goes through the real seam in vendor FAKE mode
# (HARNESS_VENDOR_FAKE=1, the repo fixture): 0 real network.
#
#   E0  the closure installs owner-mail.sh, vendor/resend.sh and seam.sh
#   E1  newest ERROR -> one page AND `owner-mail <p> sent`; the state row is
#       {sent, fake-email-0001, to = HARNESS_GIT_EMAIL}
#   E2  still red -> no new owner-mail line; READY then ERROR inside the TTL ->
#       a new page call, but owner-mail prints suppressed
#   E3  the seam fails (rc 70) -> owner-mail failed, prod_red kept, page made,
#       an [owner-mail] ALERTS line, lane rc 0
#   E4  two projects red in one run, OWNER_MAIL_TO only for one -> each mail to
#       its own owner (a row for one project never reaches the next)
#   E5  tail -1 of the log is still the summary line
#   E6  OWNER_MAIL_FROM unset -> not-configured; curl saw only api.vercel.com
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prod-red-owner-mail.bh-8894-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: prod-red-owner-mail: %s\n' "$*"; }

FB="$T/fakebin"; FX="$T/fx"
mkdir -p "$FB" "$FX"
jq -nc '{token:"tok-fixture-1", expiresAt:4102444800000}' > "$T/auth.json"
cat > "$FB/curl" <<'STUB'
#!/bin/bash
URL="${!#}"
printf '%s\n' "$URL" >> "$CURL_LOG"
pid=$(sed -n 's/.*projectId=\([^&]*\).*/\1/p' <<<"$URL")
case "$URL" in
  https://api.vercel.com/v4/aliases/*) echo '{"deploymentId":"dpl_fixture_s"}' ;;
  https://api.vercel.com/v13/deployments/*) echo '{"createdAt":1700000000000,"gitSource":{"sha":"a1b2c3d4e5f6"}}' ;;
  https://api.vercel.com/v6/deployments*target=preview*) echo '{"deployments":[]}' ;;
  https://api.vercel.com/v6/deployments*target=production\&state=READY*) echo '{"deployments":[]}' ;;
  https://api.vercel.com/v6/deployments*target=production*)
    if [ -f "$FX/$pid.newest" ]; then printf '{"deployments":[%s]}\n' "$(cat "$FX/$pid.newest")"; else echo '{"deployments":[]}'; fi ;;
  *) exit 7 ;;
esac
STUB
printf '#!/bin/bash\necho "npx $*" >> "$CURL_LOG"\nexit 0\n' > "$FB/npx"
printf '#!/bin/bash\ncat >/dev/null\nexit 0\n' > "$FB/ssh"
chmod +x "$FB/curl" "$FB/npx" "$FB/ssh"
: > "$T/curl.log"

# newtree <name> <projects...> — a fresh scratch harness for one case.
newtree() {
  local c="$1" p; shift
  H="$T/$c/h"; mkdir -p "$H/state" "$H/logs" "$H/flags"
  scratch_install_closure bin/vercel-deploy-snapshot.sh "$H" >/dev/null || bad "$c setup: cannot install the lane script"
  cat > "$H/bin/lib/page-critical.sh" <<'FAKE'
page_critical() { printf '%s\t%s\t%s\n' "$1" "$2" "${4:-}" >> "$PAGE_LOG"; return 0; }
FAKE
  : > "$H/vercel.conf"; : > "$T/$c/fleet.conf"; : > "$T/$c/pages"
  for p in "$@"; do printf '%s team_fixture prj_%s %s.example.test\n' "$p" "$p" "$p" >> "$H/vercel.conf"; done
}
# run_snap <case> [env...] — one run of the real lane script.
run_snap() {
  local c="$1"; shift
  env -u PROD_RED_REPAGE_S -u OWNER_MAIL_TO -u RESEND_API_TIMEOUT_S PATH="$FB:$PATH" HARNESS="$H" \
      FLEET_CONF="$T/$c/fleet.conf" REGISTRY_SOURCE=file LANE_GATE_DISABLE=1 LANE_REGISTRY="$T/no-registry.json" \
      JOBS_URL='' FX="$FX" VERCEL_CLI_AUTH="$T/auth.json" CURL_LOG="$T/curl.log" PAGE_LOG="$T/$c/pages" \
      HARNESS_VENDOR_FAKE=1 HARNESS_VENDOR_FAKE_DIR="$DIR/tests/fixtures/vendor-fake" \
      OWNER_MAIL_FROM=alerts@example.test RESEND_API_KEY=re_fixture_key HARNESS_GIT_EMAIL=owner@example.test \
      HARNESS_ENV_DIR="$T/$c/no-env" "$@" bash "$H/bin/vercel-deploy-snapshot.sh" 2>>"$T/stderr"
}
dep() { jq -nc --arg s "$1" --arg u "$2" '{uid:$u, state:$s, createdAt:1793400000000, meta:{githubCommitSha:"c0ffee12deadbeef"}}'; }
pages() { grep -c . "$T/$1/pages" 2>/dev/null; }
mails() { grep -c " owner-mail $1 " "$H/logs/vercel-snapshot.log" 2>/dev/null; }
mailrow() { jq -c --arg k "prodred:$1" '.[$k]' "$H/state/owner-mail.json" 2>/dev/null; }

# ---------- E0: the closure ---------------------------------------------------
newtree e0 pe0
for f in bin/lib/owner-mail.sh bin/lib/vendor/resend.sh bin/lib/vendor/seam.sh; do
  [ -f "$H/$f" ] && ok || bad "E0 the lane closure installs $f"
done

# ---------- E1: the transition mails the owner -------------------------------
newtree e1 pe1
dep ERROR dpl_e1 > "$FX/prj_pe1.newest"
run_snap e1; RC=$?
[ "$RC" = 0 ] && ok || bad "E1 rc 0 (got $RC; stderr $(tail -3 "$T/stderr"))"
[ "$(pages e1)" = 1 ] && ok || bad "E1 one page (got $(pages e1))"
grep -qE '^[0-9-]+ [0-9:]+Z owner-mail pe1 sent$' "$H/logs/vercel-snapshot.log" && ok \
  || bad "E1 the log has 'owner-mail pe1 sent' (log: $(cat "$H/logs/vercel-snapshot.log"))"
jq -e '.status == "sent" and .id == "fake-email-0001" and .to == "owner@example.test"' <<<"$(mailrow pe1)" >/dev/null 2>&1 \
  && ok || bad "E1 the state row is {sent, fake-email-0001, owner@example.test} (got $(mailrow pe1))"
# E5: the summary line stays last.
[[ "$(tail -1 "$H/logs/vercel-snapshot.log")" == *"prodred:[pe1]"* ]] && ok || bad "E5 tail -1 is the summary line (got '$(tail -1 "$H/logs/vercel-snapshot.log")')"

# ---------- E2: no repeat inside the TTL -------------------------------------
run_snap e1
[ "$(mails pe1)" = 1 ] && [ "$(pages e1)" = 1 ] && ok || bad "E2 a second red run mails and pages nothing new (mails $(mails pe1), pages $(pages e1))"
dep READY dpl_e2g > "$FX/prj_pe1.newest"; run_snap e1
dep ERROR dpl_e2r > "$FX/prj_pe1.newest"; run_snap e1
[ "$(pages e1)" = 2 ] && ok || bad "E2 red -> green -> red calls page_critical again (got $(pages e1))"
grep -q ' owner-mail pe1 suppressed$' "$H/logs/vercel-snapshot.log" && [ "$(jq -r '.id' <<<"$(mailrow pe1)")" = fake-email-0001 ] \
  && ok || bad "E2 the second transition inside the TTL is suppressed (log: $(grep owner-mail "$H/logs/vercel-snapshot.log"))"

# ---------- E3: the seam fails ------------------------------------------------
newtree e3 pe3
# The lane calls bin/alert-line.sh by path; install its real closure too.
scratch_install_closure bin/alert-line.sh "$H" >/dev/null || bad "E3 setup: cannot install bin/alert-line.sh"
dep ERROR dpl_e3 > "$FX/prj_pe3.newest"; mkdir -p "$T/e3/empty-fake"
run_snap e3 HARNESS_VENDOR_FAKE_DIR="$T/e3/empty-fake"; RC=$?
[ "$RC" = 0 ] && ok || bad "E3 a failing mail leaves the lane rc 0 (got $RC)"
grep -q ' owner-mail pe3 failed$' "$H/logs/vercel-snapshot.log" && ok || bad "E3 the log has 'owner-mail pe3 failed'"
[ "$(jq -r '.projects.pe3.prod_red.id' "$H/state/vercel-deploy-status.json" 2>/dev/null)" = dpl_e3 ] && [ "$(pages e3)" = 1 ] \
  && ok || bad "E3 the red record and the page are kept"
[ "$(jq -r '.status' <<<"$(mailrow pe3)")" = failed ] && ok || bad "E3 the state row is failed (got $(mailrow pe3))"
grep -q '\[owner-mail\] pe3: the owner email to owner@example.test failed' "$H/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "E3 one [owner-mail] ALERTS line (got $(cat "$H/logs/ALERTS.log" 2>/dev/null))"

# ---------- E4: per-project owners, no leak between projects ------------------
newtree e4 pa4 pb4
cat > "$H/bin/lib/lane-gate.sh" <<'GATE'
lane_gate_or_exit() { return 0; }
lane_env_apply() { return 0; }
lib_env_apply() { [ "$1" = owner-mail ] && [ "${2:-}" = pa4 ] && export OWNER_MAIL_TO=owner-a@example.test; return 0; }
GATE
dep ERROR dpl_a4 > "$FX/prj_pa4.newest"; dep ERROR dpl_b4 > "$FX/prj_pb4.newest"
run_snap e4
[ "$(jq -r '.to' <<<"$(mailrow pa4)")" = owner-a@example.test ] && ok || bad "E4 pa4 mails its own row's owner (got $(mailrow pa4))"
[ "$(jq -r '.to' <<<"$(mailrow pb4)")" = owner@example.test ] && ok || bad "E4 pb4 gets HARNESS_GIT_EMAIL, not pa4's row (got $(mailrow pb4))"
[ "$(mails pa4)" = 1 ] && [ "$(mails pb4)" = 1 ] && ok || bad "E4 one owner-mail line per project"

# ---------- E6: not configured ------------------------------------------------
newtree e6 pe6
dep ERROR dpl_e6 > "$FX/prj_pe6.newest"
run_snap e6 OWNER_MAIL_FROM=
grep -q ' owner-mail pe6 not-configured$' "$H/logs/vercel-snapshot.log" && ok || bad "E6 the log has 'owner-mail pe6 not-configured'"
[ ! -e "$H/state/owner-mail.json" ] && [ "$(pages e6)" = 1 ] && ok || bad "E6 no state write, the page still goes out"
! grep -qv '^https://api\.vercel\.com/' "$T/curl.log" && ok || bad "E6 curl saw only api.vercel.com ($(grep -v '^https://api\.vercel\.com/' "$T/curl.log" | head -3))"

echo "prod-red-owner-mail.bh-8894: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
