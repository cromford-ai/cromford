#!/bin/bash
# tests/qa-wiring-check.bh-6254-test.sh — bin/qa-wiring-check.sh and the daily
# hub lane bin/qa-wiring-sweep.sh, driven through their real entry points.
#
# THE INCIDENT (project-6-os, 2026-10-09 -> 2026-10-12). The project enrolled
# with no vercel.conf row, prod `-`, no env file on the hub and deploy kind
# `none`, and merged 47+ PRs with no browser QA. Its prod host was also one the
# Clerk prod instance refuses (origin_invalid). Nothing checked and no alert
# fired.
#
#   A1  all five wired -> five `ok:` lines, rc 0
#   A2  prod `-` -> OWED: prod URL, rc 1
#   A3  no vercel.conf row -> OWED: vercel.conf
#   A4  no QA_CLERK_SECRET_KEY -> OWED: QA account ... UNSET, and no env value
#       (nor an env value that spells OWED) reaches the output
#   A5  FAPI answers 400 origin_invalid -> OWED: Clerk prod rejects origin, rc 1
#   C1  the FAPI call carries Origin: <prod> on the host decoded from the key
#   C2  a commented row and a p-other row do not count for p
#   C3  env dir unreadable -> UNKNOWN: QA account, rc 3
#   C4  FAPI unreachable -> UNKNOWN, rc 3; page with no pk_ -> OWED no key
#   C5  kind none -> OWED; no row -> ok default; outage -> UNKNOWN
#   C6  qa_wiring.<p>.exempt row -> exactly `exempt: <reason>`, rc 0
#   C7  a *.vercel.app prod URL is ok on line 2 (line 5 decides it)
#   C8  a Clerk development instance (401 dev_browser_unauthenticated) is ok;
#       any other 401 is OWED
#   C9  a settings client that does not source -> UNKNOWN: deploy kind
#   S1  the real sweep: one ALERTS line + one fleet_alert beat + one latch for
#       the OWED project, none for the ok one, no env value anywhere
#   S2  a second sweep the same day sends nothing new
#   S3  an UNKNOWN-only project: log line, no alert, no latch
#   S4  the sweep prunes its own 9-day-old latch and keeps a doorbell one
#
# Network is a curl stub; settings are a bin/jobs-client.sh stub; the day is
# pinned through QA_WIRING_DAY.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/qa-wiring-check.bh-6254-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

for s in bin/qa-wiring-check.sh bin/qa-wiring-sweep.sh; do
  [ -x "$DIR/$s" ] || { echo "FAIL: $s missing or not executable"; echo "qa-wiring-check (BH-6254): 0 passed, 1 failed"; exit 1; }
done

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/flags" "$H/env" "$H/state" "$T/settings" "$T/web"
for s in bin/qa-wiring-check.sh bin/qa-wiring-sweep.sh bin/alert-line.sh bin/fleet-conf.sh bin/prod-url.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: cannot install $s closure"; exit 1; }
done

# Settings: one file per key in $T/settings. No file = no row (rc 2); a file
# holding OUTAGE = rc 1.
# jc_stub — (re)write the stub settings client. A function, so C9 can break it
# and restore it with no copy of a file named bin/jobs-client.sh (the
# jobs-client-modules lint reads any such cp as the real client).
jc_stub() {
cat > "$H/bin/jobs-client.sh" <<EOF
setting_get() {
  local f="$T/settings/\$1"
  [ -f "\$f" ] || return 2
  [ "\$(cat "\$f")" = OUTAGE ] && return 1
  cat "\$f"
}
EOF
}
jc_stub
printf '#!/bin/bash\nprintf "%%s\\n" "$1" >> "%s/beats.txt"\nexit 0\n' "$T" > "$H/bin/beat.sh"
chmod +x "$H/bin/beat.sh"

# curl: the page from $T/web/page (page-down = rc 7), the FAPI answer from
# $T/web/fapi-code + $T/web/fapi-body (code 000 = rc 7). Every FAPI call is
# recorded as "<host> <Origin>".
cat > "$T/curl" <<EOF
#!/bin/bash
out=""; fmt=""; origin=""; url=""
while [ \$# -gt 0 ]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -w) fmt="\$2"; shift 2 ;;
    -H) case "\$2" in Origin:*) origin="\${2#Origin: }" ;; esac; shift 2 ;;
    --max-time) shift 2 ;;
    -*) shift ;;
    *) url="\$1"; shift ;;
  esac
done
case "\$url" in
  */v1/environment)
    h="\${url#https://}"; h="\${h%%/*}"
    echo "\$h \$origin" >> "$T/fapi-calls.txt"
    code=\$(cat "$T/web/fapi-code")
    [ "\$code" = 000 ] && { printf 000; exit 7; }
    cp "$T/web/fapi-body" "\$out"; printf '%s' "\$code" ;;
  *)
    [ -f "$T/web/page-down" ] && exit 7
    cp "$T/web/page" "\$out" ;;
esac
EOF
chmod +x "$T/curl"

PK="pk_live_$(printf 'clerk.example.test$' | base64 | tr -d '=\n')"
reset() { # every item wired for qa-good; qa-noprod has prod `-`
  cat > "$T/fleet.conf" <<EOF
# <project> <repo> <prod> <board-prefix> <offset> <box> <ip>
qa-good    Test/qa-good    https://app.example.test  -  1  box-test 192.0.2.1
qa-noprod  Test/qa-noprod  -                         -  2  box-test 192.0.2.1
EOF
  printf '# p team project domain\nqa-good team_fixture prj_fixture app.example.test\n' > "$T/vercel.conf"
  scratch_rm "$H/env"; mkdir -p "$H/env"
  printf 'QA_TEST_USER_ID=user_fixtureleak1\nexport QA_CLERK_SECRET_KEY=sk_test_fixtureleak2\n' > "$H/env/qa-good.env"
  printf 'QA_TEST_USER_ID=user_fixtureleak3\nOTHER=OWED_fixtureleak4\n' > "$H/env/qa-noprod.env"
  printf '{"qa-good":{"member":{"user_id":"user_fixtureleak1"}}}\n' > "$T/accounts.json"
  rm -f "$T/settings/"*; printf github-deployment > "$T/settings/deploy.qa-good.kind"
  printf '<html><script>window.__clerk_publishable_key="%s"</script></html>\n' "$PK" > "$T/web/page"
  rm -f "$T/web/page-down" "$T/fapi-calls.txt"
  printf 200 > "$T/web/fapi-code"; printf '{"auth_config":{}}' > "$T/web/fapi-body"
}
export HARNESS="$H" FLEET_CONF="$T/fleet.conf" VERCEL_CONF="$T/vercel.conf" \
  QA_ACCOUNTS="$T/accounts.json" QA_WIRING_CURL="$T/curl"
check() { OUT=$("$H/bin/qa-wiring-check.sh" "$1" 2>&1); RC=$?; }
has() { grep -qF -- "$1" <<< "$OUT"; }

# A1
reset; check qa-good
n=$(grep -c . <<< "$OUT"); nok=$(grep -c '^ok: ' <<< "$OUT")
if [ "$RC" = 0 ] && [ "$n" = 5 ] && [ "$nok" = 5 ]; then ok; else bad "A1 rc=$RC lines=$n ok=$nok: $OUT"; fi

# C1 — the probe went to the decoded host, with the prod origin.
if [ "$(cat "$T/fapi-calls.txt" 2>/dev/null)" = "clerk.example.test https://app.example.test" ]; then ok
else bad "C1 FAPI calls: $(cat "$T/fapi-calls.txt" 2>/dev/null)"; fi
if ! has "$PK"; then ok; else bad "C1 the publishable key was printed"; fi

# A2
reset; check qa-noprod
if [ "$RC" = 1 ] && has "OWED: prod URL"; then ok; else bad "A2 rc=$RC: $OUT"; fi

# A3
reset; printf '# nothing here\n' > "$T/vercel.conf"; check qa-good
if [ "$RC" = 1 ] && has "OWED: vercel.conf"; then ok; else bad "A3 rc=$RC: $OUT"; fi

# C2 — a commented row and a longer name never count for qa-good.
reset; printf '# qa-good team prj dom\nqa-good-other team prj dom\n' > "$T/vercel.conf"; check qa-good
if [ "$RC" = 1 ] && has "OWED: vercel.conf"; then ok; else bad "C2 rc=$RC: $OUT"; fi

# A4 — the QA account line, and no env value anywhere in the output.
reset; printf 'QA_TEST_USER_ID=user_fixtureleak5\nOTHER=sk_fixtureleak6\nODD=OWED_fixtureleak7\n#QA_CLERK_SECRET_KEY=sk_fixtureleak8\nQA_CLERK_SECRET_KEY=\n' > "$H/env/qa-good.env"
check qa-good
if [ "$RC" = 1 ] && grep -q '^OWED: QA account .*QA_TEST_USER_ID=set QA_CLERK_SECRET_KEY=UNSET qa-accounts.json role=yes' <<< "$OUT"; then ok
else bad "A4 rc=$RC: $OUT"; fi
if [ "$(grep -c fixtureleak <<< "$OUT")" = 0 ] && [ "$(grep -c OWED <<< "$OUT")" = 1 ]; then ok
else bad "A4 an env value reached the output: $OUT"; fi
# No env file at all (the project-6-os case) is OWED, not UNKNOWN.
reset; rm -f "$H/env/qa-good.env"; rm -f "$T/accounts.json"; check qa-good
if [ "$RC" = 1 ] && has "OWED: QA account — QA_TEST_USER_ID=UNSET QA_CLERK_SECRET_KEY=UNSET qa-accounts.json role=none"; then ok
else bad "A4 no env file rc=$RC: $OUT"; fi

# A5
reset; printf 400 > "$T/web/fapi-code"; printf '{"errors":[{"code":"origin_invalid"}]}' > "$T/web/fapi-body"; check qa-good
if [ "$RC" = 1 ] && has "OWED: Clerk prod rejects origin https://app.example.test (origin_invalid at clerk.example.test)"; then ok
else bad "A5 rc=$RC: $OUT"; fi
reset; printf 403 > "$T/web/fapi-code"; check qa-good
if [ "$RC" = 1 ] && has "OWED: Clerk origin probe — clerk.example.test answered 403"; then ok; else bad "A5 403 rc=$RC: $OUT"; fi

# C3 — an env dir this shell cannot read is unknown, never owed.
reset; HARNESS_ENV_DIR="$T/no-such-env" check qa-good
if [ "$RC" = 3 ] && has "UNKNOWN: QA account" && ! has "OWED"; then ok; else bad "C3 rc=$RC: $OUT"; fi

# C4
reset; printf 000 > "$T/web/fapi-code"; check qa-good
if [ "$RC" = 3 ] && has "UNKNOWN: Clerk origin probe — clerk.example.test unreachable"; then ok; else bad "C4 fapi down rc=$RC: $OUT"; fi
reset; : > "$T/web/page-down"; check qa-good
if [ "$RC" = 3 ] && has "UNKNOWN: Clerk origin probe — https://app.example.test unreachable"; then ok; else bad "C4 page down rc=$RC: $OUT"; fi
reset; printf '<html>no key</html>\n' > "$T/web/page"; check qa-good
if [ "$RC" = 1 ] && has "OWED: Clerk origin probe — no Clerk publishable key on https://app.example.test/sign-in"; then ok
else bad "C4 no key rc=$RC: $OUT"; fi
reset; printf '<html>pk_live_ISEhPz8/</html>\n' > "$T/web/page"; check qa-good
if [ "$RC" = 1 ] && has "OWED: Clerk origin probe — publishable key does not decode to a host"; then ok
else bad "C4 bad key rc=$RC: $OUT"; fi

# C8 — a Clerk DEVELOPMENT instance answers a browserless GET with Origin set
# 401 dev_browser_unauthenticated (live, 2026-10-13, four fleet FAPI hosts). It
# accepts any origin with a dev-browser token, so that 401 is not an origin
# refusal: ok, never OWED. Any other 401 stays OWED.
reset; printf 401 > "$T/web/fapi-code"
printf '{"errors":[{"message":"Browser unauthenticated","code":"dev_browser_unauthenticated"}]}' > "$T/web/fapi-body"; check qa-good
if [ "$RC" = 0 ] && has "ok: Clerk development instance clerk.example.test (dev-browser auth, no origin allow-list)" && ! has "OWED"; then ok
else bad "C8 dev instance rc=$RC: $OUT"; fi
reset; printf 401 > "$T/web/fapi-code"; printf '{"errors":[{"code":"authentication_invalid"}]}' > "$T/web/fapi-body"; check qa-good
if [ "$RC" = 1 ] && has "OWED: Clerk origin probe — clerk.example.test answered 401"; then ok; else bad "C8 other 401 rc=$RC: $OUT"; fi

# C9 — a settings client that is readable but does not source is UNKNOWN, not
# the "no row" default (lr-6271 NOTE: deploy_kind gives rc 2 for both).
reset
printf 'return 1\n' > "$H/bin/jobs-client.sh"; check qa-good
if [ "$RC" = 3 ] && has "UNKNOWN: deploy kind — $H/bin/jobs-client.sh does not load" && ! has "ok: deploy kind"; then ok
else bad "C9 broken client rc=$RC: $OUT"; fi
jc_stub

# C5
reset; printf none > "$T/settings/deploy.qa-good.kind"; check qa-good
if [ "$RC" = 1 ] && has "OWED: deploy kind none — set settings row deploy.qa-good.kind"; then ok; else bad "C5 none rc=$RC: $OUT"; fi
reset; rm -f "$T/settings/deploy.qa-good.kind"; check qa-good
if [ "$RC" = 0 ] && has "ok: deploy kind github-deployment (no row, default)"; then ok; else bad "C5 no row rc=$RC: $OUT"; fi
reset; printf OUTAGE > "$T/settings/deploy.qa-good.kind"; check qa-good
if [ "$RC" = 3 ] && has "UNKNOWN: deploy kind — settings unreadable"; then ok; else bad "C5 outage rc=$RC: $OUT"; fi

# C6
reset; printf 'no web UI' > "$T/settings/qa_wiring.qa-noprod.exempt"; check qa-noprod
if [ "$RC" = 0 ] && [ "$OUT" = "exempt: no web UI" ]; then ok; else bad "C6 rc=$RC: $OUT"; fi
# An outage on the exemption read is "check it", never "exempt".
reset; printf OUTAGE > "$T/settings/qa_wiring.qa-noprod.exempt"; check qa-noprod
if [ "$RC" = 1 ] && has "OWED: prod URL"; then ok; else bad "C6 outage rc=$RC: $OUT"; fi

# C7
reset; sed -i 's#https://app.example.test#https://qa-good.vercel.app#' "$T/fleet.conf"; check qa-good
if has "ok: prod URL https://qa-good.vercel.app"; then ok; else bad "C7 vercel.app prod: $OUT"; fi

# Usage: no project, unknown project.
reset; check ""; r1=$RC; check qa-nowhere
if [ "$r1" = 2 ] && [ "$RC" = 2 ]; then ok; else bad "usage rc=$r1/$RC"; fi

# ── the sweep ────────────────────────────────────────────────────────────────
ALERTS="$H/logs/ALERTS.log"
sweep() { QA_WIRING_DAY="$1" "$H/bin/qa-wiring-sweep.sh"; SRC=$?; }
nfleet() { grep -c '"kind":"fleet_alert"' "$T/beats.txt" 2>/dev/null; }

# S1
reset; rm -f "$T/beats.txt" "$ALERTS"; sweep 20261012
na=$(grep -c . "$ALERTS" 2>/dev/null); nf=$(nfleet)
if [ "$SRC" = 0 ] && [ "$na" = 1 ] && grep -q '\[qa-wiring\] \[qa-noprod\] browser QA not wired: .*OWED: prod URL' "$ALERTS"; then ok
else bad "S1 rc=$SRC alerts=$na: $(cat "$ALERTS" 2>/dev/null)"; fi
fb=$(grep '"kind":"fleet_alert"' "$T/beats.txt" 2>/dev/null)
if [ "$nf" = 1 ] && [ "$(jq -r '.akey' <<< "$fb")" = qa-wiring:qa-noprod ] && [ "$(jq -r '.project' <<< "$fb")" = qa-noprod ]; then ok
else bad "S1 fleet_alert beats=$nf: $fb"; fi
if [ -f "$H/flags/alerted-qa-wiring-qa-noprod-20261012" ] && [ ! -e "$H/flags/alerted-qa-wiring-qa-good-20261012" ]; then ok
else bad "S1 latches: $(ls "$H/flags")"; fi
if ! grep -q fixtureleak "$ALERTS" "$T/beats.txt" "$H/logs/qa-wiring.log"; then ok; else bad "S1 an env value reached an alert or the log"; fi
if grep -q 'qa-good ok' "$H/logs/qa-wiring.log" && grep -q 'checked=2 owed=1 unknown=0 alerted=1' "$H/logs/qa-wiring.log"; then ok
else bad "S1 log: $(cat "$H/logs/qa-wiring.log")"; fi

# S2 — same day: nothing new.
nb=$(grep -c . "$T/beats.txt"); sweep 20261012
if [ "$(grep -c . "$ALERTS")" = 1 ] && [ "$(grep -c . "$T/beats.txt")" = "$nb" ] && tail -1 "$H/logs/qa-wiring.log" | grep -q 'alerted=0'; then ok
else bad "S2 second run sent again: alerts=$(grep -c . "$ALERTS") beats=$(grep -c . "$T/beats.txt")/$nb"; fi
# The next day alerts again.
sweep 20261013
if [ "$(grep -c . "$ALERTS")" = 2 ]; then ok; else bad "S2 next day did not alert: $(grep -c . "$ALERTS")"; fi

# S3 — UNKNOWN only: no alert, no latch.
reset; printf 'qa-good Test/qa-good https://app.example.test - 1 box-test 192.0.2.1\n' > "$T/fleet.conf"
printf 000 > "$T/web/fapi-code"; nb=$(grep -c . "$ALERTS"); sweep 20261014
if [ "$(grep -c . "$ALERTS")" = "$nb" ] && [ ! -e "$H/flags/alerted-qa-wiring-qa-good-20261014" ] \
   && grep -q 'qa-good unknown: UNKNOWN: Clerk origin probe' "$H/logs/qa-wiring.log"; then ok
else bad "S3 an UNKNOWN alerted or was not logged: $(tail -2 "$H/logs/qa-wiring.log")"; fi

# S4 — prune: only this lane's old latches.
reset; touch -d '9 days ago' "$H/flags/alerted-qa-wiring-old-20200101" "$H/flags/alerted-doorbell-Test_x-20200101"
touch -d '2 days ago' "$H/flags/alerted-qa-wiring-recent-20200101"
sweep 20261015
if [ ! -e "$H/flags/alerted-qa-wiring-old-20200101" ] && [ -e "$H/flags/alerted-doorbell-Test_x-20200101" ] \
   && [ -e "$H/flags/alerted-qa-wiring-recent-20200101" ]; then ok
else bad "S4 prune: $(ls "$H/flags")"; fi

# The lane switch: lane-off stops the sweep before its body.
reset; : > "$H/flags/lane-off-qa-wiring-sweep"; nb=$(grep -c . "$ALERTS"); rm -f "$H/flags/alerted-qa-wiring-qa-noprod-"*
sweep 20261016
if [ "$SRC" = 0 ] && [ "$(grep -c . "$ALERTS")" = "$nb" ] && [ ! -e "$H/flags/alerted-qa-wiring-qa-noprod-20261016" ]; then ok
else bad "lane-off did not stop the sweep"; fi
rm -f "$H/flags/lane-off-qa-wiring-sweep"

echo "qa-wiring-check (BH-6254): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
