#!/bin/bash
# tests/launch-fastpath-hotfix-spec.bh-7117-test.sh — BH-7117: condition 11 of
# bin/launch-fastpath.sh ("the body is a spec") does not apply to an issue that
# carries the hotfix label. A hotfix body is an incident note (#7066 had no
# `## Scope` / `## Acceptance tests` headings), and the label is put on by a
# person on purpose. Every other condition still decides.
#
# Driven whole: the real script against a scratch $HARNESS (closure-installed),
# a gh REST fixture server, a curl stub for the ledger reads and run-build.sh as
# a recorder. The scaffold is tests/dispatch-hotfix-only.bh-6350-test.sh's.
#
#   F1  ai-build + hotfix, body with no headings -> launched
#   F2  label ` Hotfix ` (trim + case) -> launched
#   F3  `hotfix-candidate` -> declined, condition 11
#   F4  `not-hotfix`, `hotfixes`, the word in title and body -> declined, 11
#   F5  `hotfix` with HOTFIX_LANE=0 -> declined, 11
#   F6  `hotfix` + a HOLD comment -> declined for the HOLD (12 unchanged)
#   F7  the intake end to end: triage_hot_intake -> real fastpath -> launched
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/launch-fastpath-hotfix-spec.bh-7117-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v flock   >/dev/null || { echo "flock missing — skipping"; exit 0; }

H="$T/h"; P=cromford
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/locks" "$H/flags" "$H/env" "$H/prompts" "$H/fixture" "$T/fakebin"
scratch_install_closure bin/launch-fastpath.sh "$H" >/dev/null || { echo "closure install of bin/launch-fastpath.sh failed"; exit 1; }
[ -e "$H/bin/jobs-client.sh" ] || scratch_install_closure bin/jobs-client.sh "$H" >/dev/null
scratch_install_closure bin/lib/triage-hotfix-lib.sh "$H" >/dev/null || { echo "closure install of bin/lib/triage-hotfix-lib.sh failed"; exit 1; }
scratch_install_closure bin/lib/triage-shards-lib.sh "$H" >/dev/null || { echo "closure install of bin/lib/triage-shards-lib.sh failed"; exit 1; }
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
printf 'cromford example-org/cromford https://bh.example - 9 box-bh 192.0.2.9\n' > "$H/fleet.conf"
printf '%s\n' '  `setsid /root/harness/bin/run-build.sh cromford <issue-number> BH-<issue-number> > /root/harness/logs/cromford.bh-<issue-number>-build.out 2>&1 &`' > "$H/prompts/$P.md"
printf 'HARNESS_SECRET=s3cret-fixture\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
cat > "$H/bin/run-build.sh" <<'SH'
#!/bin/bash
printf 'argv=%s\n' "$*" >> "$HARNESS/launches.log"
SH
chmod +x "$H/bin/run-build.sh"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/gh-calls.log"
SEND() { printf 'HTTP/2 %s\r\nserver: x\r\n\r\n%s' "$1" "$2"; exit 0; }
A="$*"
PAGE=$(printf '%s' "$A" | sed -nE 's/.*[?&]page=([0-9]+).*/\1/p'); PAGE="${PAGE:-1}"
case "$A" in
  *"api rate_limit"*) exit 1 ;;
  *"/issues?labels="*)
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(cat "$HARNESS"/fixture/issue-*.json 2>/dev/null | jq -sc '[ .[]
      | select([.labels[].name] | index("ai-build") and index("hotfix"))
      | {number, pull_request:null} ]')" ;;
  *"/issues/"*"/comments"*)
    n=$(printf '%s' "$A" | sed -nE 's#.*/issues/([0-9]+)/comments.*#\1#p')
    [ "$PAGE" = 1 ] || SEND 200 '[]'
    SEND 200 "$(cat "$HARNESS/fixture/comments-$n.json" 2>/dev/null || echo '[]')" ;;
  *"/issues/"*)
    n=$(printf '%s' "$A" | sed -nE 's#.*/issues/([0-9]+).*#\1#p')
    [ -f "$HARNESS/fixture/issue-$n.json" ] || SEND 404 '{"message":"Not Found"}'
    SEND 200 "$(cat "$HARNESS/fixture/issue-$n.json")" ;;
  *"/issues"*) SEND 200 '[]' ;;
  *"/pulls"*)  SEND 200 '[]' ;;
  *"api repos/"*) echo 12345 ;;
  *) exit 1 ;;
esac
SH
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"
case "$URL" in
  */api/jobs*)  printf '{"jobs":[]}\n200\n' ;;
  */api/queue*) printf '{"queue":[]}\n200\n' ;;
  */api/flags/*) printf '{"error":"not found"}\n404\n' ;;
  *) printf '{"ok":true}\n200\n' ;;
esac
SH
printf '#!/bin/bash\nexec "$@"\n' > "$T/fakebin/setsid"
chmod +x "$T/fakebin"/*

# The #7066 shape: an incident note, no spec headings.
INCIDENT=$'main is red on sql-ident-sites since 05:17Z.\nFix the failing suite and get main green.\n'
mkissue() { # mkissue <n> <labels-json> [title] [body] [comments-json]
  jq -n --argjson n "$1" --argjson lb "$2" --arg t "${3:-BH-$1 fixture}" --arg b "${4:-$INCIDENT}" \
        --argjson c "$(printf '%s' "${5:-[]}" | jq 'length')" \
    '{number:$n,state:"open",title:$t,body:$b,labels:$lb,comments:$c}' > "$H/fixture/issue-$1.json"
  printf '%s' "${5:-[]}" > "$H/fixture/comments-$1.json"
}
lab() { # lab <name>... -> labels json with ai-build first
  local a='[{"name":"ai-build"}' x
  for x in "$@"; do a="$a,$(jq -nc --arg n "$x" '{name:$n}')"; done
  printf '%s]' "$a"
}
fpreset() {
  scratch_rm "$H/state"; scratch_rm "$H/locks"; scratch_rm "$H/logs"
  mkdir -p "$H/state" "$H/locks" "$H/logs"
  rm -f "$H/launches.log" "$H/gh-calls.log" "$H/fixture"/issue-*.json "$H/fixture"/comments-*.json "$H/flags"/*
}
fp() { OUT=$(env PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" LANE_GATE_DISABLE=1 \
          bash "$H/bin/launch-fastpath.sh" "$P" "$@" 2>/dev/null); RC=$?; }
launched() { grep -qxF "argv=$P $1 BH-$1" "$H/launches.log" 2>/dev/null; }
reason() { grep -F "FASTPATH-DECLINED $1 ::" "$H/logs/$P.log" 2>/dev/null | tail -1 | sed 's/.*:: //'; }
C11="body lacks ## Scope / ## Acceptance tests"

# F1 — the #7066 shape launches
fpreset; mkissue 7066 "$(lab hotfix)"
fp 7066
launched 7066 && ok || bad "F1 a hotfix incident body launches (reason: $(reason 7066))"
grep -q "FASTPATH BH-7066 (issue #7066) — launched" "$H/logs/$P.log" 2>/dev/null && ok || bad "F1 the launched log line"
[ "$RC" = 0 ] && ok || bad "F1 rc 0 (got $RC, stdout '$OUT')"

# F2 — trim + case
fpreset; mkissue 7067 "$(lab ' Hotfix ')"
fp 7067
launched 7067 && ok || bad "F2 label ' Hotfix ' counts as the hotfix label (reason: $(reason 7067))"

# F3 / F4 — near-miss labels and the bare word are not the label
fpreset
mkissue 7068 "$(lab hotfix-candidate)"
mkissue 7069 "$(lab not-hotfix)"
mkissue 7070 "$(lab hotfixes)"
mkissue 7071 "$(lab)" "hotfix: main is red" $'hotfix please\n'
fp 7068 7069 7070 7071
for n in 7068 7069 7070 7071; do
  launched "$n" && bad "F3/F4 #$n must not launch" || ok
  [ "$(reason "$n")" = "$C11" ] && ok || bad "F3/F4 #$n declines on condition 11 (got '$(reason "$n")')"
done
[ "$RC" = 1 ] && ok || bad "F3/F4 rc 1 (got $RC)"

# F5 — the lane off: the label is not a hotfix
fpreset; mkissue 7066 "$(lab hotfix)"
OUT=$(env PATH="$T/fakebin:$PATH" HARNESS="$H" FLEET_CONF="$H/fleet.conf" LANE_GATE_DISABLE=1 HOTFIX_LANE=0 \
        bash "$H/bin/launch-fastpath.sh" "$P" 7066 2>/dev/null)
launched 7066 && bad "F5 HOTFIX_LANE=0: no waiver" || ok
[ "$(reason 7066)" = "$C11" ] && ok || bad "F5 declines on condition 11 (got '$(reason 7066)')"

# F6 — a HOLD still wins over a hotfix
fpreset; mkissue 7066 "$(lab hotfix)" "" "" '[{"body":"HOLD: not yet, waiting on the migration","user":{"login":"operator","type":"User"},"author_association":"OWNER"}]'
fp 7066
launched 7066 && bad "F6 a held hotfix must not launch" || ok
case "$(reason 7066)" in *HOLD*) ok ;; *) bad "F6 the reason is the HOLD (got '$(reason 7066)')" ;; esac

# F7 — the intake end to end, real lib -> real fastpath
fpreset; mkissue 7066 "$(lab hotfix)"; mkissue 7001 "$(lab)" "" $'## Scope\nx\n\n## Acceptance tests\n- y\n'
env PATH="$T/fakebin:$PATH" HARNESS="$H" PROJECT="$P" FLEET_CONF="$H/fleet.conf" LANE_GATE_DISABLE=1 \
    LOG="$H/logs/$P.log" ALERTS="$H/logs/ALERTS.log" STAMP="2026-10-16 07:00:00Z" \
    TRIAGE_GH_SLUG=example-org/cromford bash -c '
      . "$HARNESS/bin/lib/triage-shards-lib.sh"
      . "$HARNESS/bin/lib/triage-hotfix-lib.sh"
      triage_hot_intake' >/dev/null 2>&1
launched 7066 && ok || bad "F7 the intake launched the hotfix through the real fastpath (reason: $(reason 7066); log: $(tail -3 "$H/logs/$P.log" 2>/dev/null))"
launched 7001 && bad "F7 the intake must not launch a normal ticket" || ok
grep -qF "HOTFIX-INTAKE offered #7066; declined none" "$H/logs/$P.log" 2>/dev/null && ok || bad "F7 the intake summary line"

echo "launch-fastpath-hotfix-spec.bh-7117: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
