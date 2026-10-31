#!/bin/bash
# tests/prod-red-snapshot.bh-8781-test.sh — THE HUB SNAPSHOT RECORDS A RED
# PRODUCTION DEPLOY AND PAGES ONE PERSON ON THE TRANSITION (BH-8781).
#
# bin/vercel-deploy-snapshot.sh reads the NEWEST production deployment of each
# Vercel project (any state) and writes .projects[<p>].prod_red into
# state/vercel-deploy-status.json: {since, sha, id} while production is red,
# null once the newest finished production deploy is READY. On the transition
# to red it calls page_critical once (key prodred:<p>, ttl PROD_RED_REPAGE_S).
#
# Driven: the REAL lane script in a scratch tree (scratch_install_closure).
# Stubs first on PATH: `curl` (the Vercel API, answered from fixture files,
# every URL logged), `npx` (must not run) and `ssh` (always succeeds, never
# connects). bin/lib/page-critical.sh in the scratch tree is a fake that logs
# "ttl<TAB>key<TAB>project<TAB>line" and returns PAGE_RC. 0 real network.
#
#   S1  newest ERROR, no previous record          -> red, since = ISO(createdAt)
#   S1b readyState ERROR, no state field          -> red
#   S2  newest ERROR after a red record           -> red, the old since kept
#   S3  BUILDING after a red record               -> the red record kept
#   S4  CANCELED after a red record               -> the red record kept
#   S5  the newest read fails after a red record  -> carried, FAILED p:newest, no page
#   S6  READY after a red record                  -> null
#   S7  READY, no previous record                 -> null
#   S8  no production deploy at all               -> null, newest_prod null
#   S9  BUILDING, no previous record (old format) -> null
#   S10 the log token prodred:[..] equals jq over the written file
#   P1  transition -> one page: key, ttl 86400, project, since, sha8, Owner:
#   P2  the next run still red -> no new page
#   P3  the page lib fails -> the record is written, rc 0
#   P4  PROD_RED_REPAGE_S=7200 -> ttl 7200; abc -> 86400
#   N1  the written file, read by the conductor's mc_prod_red_state
#   B1  curl saw only api.vercel.com, npx never ran
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prod-red-snapshot.bh-8781-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: prod-red-snapshot: %s\n' "$*"; }

FRAG="$DIR/bin/merge-conductor.d/bh-8781-prod-red-hold.sh"
FB="$T/fakebin"; FX="$T/fx"
mkdir -p "$FB" "$FX"
jq -nc '{token:"tok-fixture-1", expiresAt:4102444800000}' > "$T/auth.json"

# The Vercel stub. FX/<pid>.newest answers the newest-production read (absent:
# no deployment); FX/<pid>.newest-fail makes that read fail (rc 22, as -f).
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
    [ -e "$FX/$pid.newest-fail" ] && exit 22
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
  [ -f "$H/bin/lib/page-critical.sh" ] || bad "$c setup: the lane closure has no bin/lib/page-critical.sh"
  cat > "$H/bin/lib/page-critical.sh" <<'FAKE'
page_critical() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "${4:-}" "$3" >> "$PAGE_LOG"; return "${PAGE_RC:-0}"; }
FAKE
  : > "$H/vercel.conf"; : > "$T/$c/fleet.conf"; : > "$T/$c/pages"
  for p in "$@"; do printf '%s team_fixture prj_%s %s.example.test\n' "$p" "$p" "$p" >> "$H/vercel.conf"; done
}
# run_snap <case> [env...] — one run of the real lane script.
run_snap() {
  local c="$1"; shift
  env -u PROD_RED_REPAGE_S PATH="$FB:$PATH" HARNESS="$H" FLEET_CONF="$T/$c/fleet.conf" REGISTRY_SOURCE=file \
      LANE_GATE_DISABLE=1 LANE_REGISTRY="$T/no-registry.json" JOBS_URL='' FX="$FX" \
      VERCEL_CLI_AUTH="$T/auth.json" CURL_LOG="$T/curl.log" PAGE_LOG="$T/$c/pages" \
      "$@" bash "$H/bin/vercel-deploy-snapshot.sh" 2>>"$T/stderr"
}
# dep <state-field> <state> <uid> <sha> <createdAt> — one Vercel deployment row.
dep() { jq -nc --arg f "$1" --arg s "$2" --arg u "$3" --arg h "$4" --argjson c "$5" '{uid:$u, ($f):$s, createdAt:$c, meta:{githubCommitSha:$h}}'; }
# prev <project> <prod_red json> — seed the previous snapshot.
prev() { jq -nc --arg p "$1" --argjson r "$2" '{generated_at:"2026-10-30 00:00:00Z", projects:{($p):{domain:"x", prod_red:$r, newest_prod:{id:"dpl_prev",state:"ERROR",sha:"0ld0ld00",created_ms:1}}}}' > "$H/state/vercel-deploy-status.json"; }
red_of() { jq -c --arg p "$1" '.projects[$p].prod_red' "$H/state/vercel-deploy-status.json" 2>/dev/null; }
pages() { grep -c . "$T/$1/pages" 2>/dev/null; }

SHA=c0ffee12deadbeef00000000000000000000aaaa
CR=1793400000000                                   # 2026-10-30T22:40:00Z
ISO=$(jq -rn --argjson c "$CR" '$c/1000 | floor | todate')
PREVRED='{"since":"2026-10-30T08:00:00Z","sha":"0ld0ld00","id":"dpl_prev"}'

# ---------- S1 / P1: newest ERROR, no previous record --------------------------
newtree s1 ps1
dep state ERROR dpl_s1 "$SHA" "$CR" > "$FX/prj_ps1.newest"
run_snap s1; RC=$?
[ "$RC" = 0 ] && ok || bad "S1 rc 0 (got $RC; stderr $(tail -3 "$T/stderr"))"
R=$(red_of ps1)
[ "$(jq -r '.since' <<<"$R")" = "$ISO" ] && [ "$(jq -r '.sha' <<<"$R")" = "${SHA:0:8}" ] && [ "$(jq -r '.id' <<<"$R")" = dpl_s1 ] \
  && ok || bad "S1 prod_red is {since:$ISO, sha:${SHA:0:8}, id:dpl_s1} (got $R)"
jq -e '.projects.ps1.newest_prod | .id == "dpl_s1" and .state == "ERROR" and .created_ms == 1793400000000' "$H/state/vercel-deploy-status.json" >/dev/null 2>&1 \
  && ok || bad "S1 newest_prod names the ERROR deploy (got $(jq -c '.projects.ps1.newest_prod' "$H/state/vercel-deploy-status.json"))"
jq -e '.projects.ps1.serving.id == "dpl_fixture_s"' "$H/state/vercel-deploy-status.json" >/dev/null 2>&1 \
  && ok || bad "S1 the existing serving key is still written"
PL=$(cat "$T/s1/pages")
[ "$(pages s1)" = 1 ] && ok || bad "P1 exactly one page on the transition (got: $PL)"
IFS=$'\t' read -r pttl pkey pproj pline <<<"$PL"
[ "$pttl" = 86400 ] && [ "$pkey" = prodred:ps1 ] && [ "$pproj" = ps1 ] && ok \
  || bad "P1 ttl 86400, key prodred:ps1, project ps1 (got ttl=$pttl key=$pkey proj=$pproj)"
[[ "$pline" == *"since $ISO"* ]] && [[ "$pline" == *"commit ${SHA:0:8}"* ]] && [[ "$pline" == *"Owner: "* ]] && [[ "$pline" == *dpl_s1* ]] \
  && ok || bad "P1 the line names since, sha8, the deploy id and the owner (got '$pline')"

# ---------- P2: the next run, still red -> no new page -------------------------
run_snap s1
[ "$(pages s1)" = 1 ] && ok || bad "P2 a second red run pages nothing new (got $(pages s1))"
[ "$(jq -r '.since' <<<"$(red_of ps1)")" = "$ISO" ] && ok || bad "P2 the red record is kept (got $(red_of ps1))"

# ---------- S1b: readyState only --------------------------------------------
newtree s1b ps1b
dep readyState ERROR dpl_s1b "$SHA" "$CR" > "$FX/prj_ps1b.newest"
run_snap s1b
[ "$(jq -r '.id' <<<"$(red_of ps1b)")" = dpl_s1b ] && ok || bad "S1b readyState ERROR reads as red (got $(red_of ps1b))"

# ---------- S2: ERROR after red keeps the old since ---------------------------
newtree s2 ps2; prev ps2 "$PREVRED"
dep state ERROR dpl_s2 "$SHA" "$CR" > "$FX/prj_ps2.newest"
run_snap s2
R=$(red_of ps2)
[ "$(jq -r '.since' <<<"$R")" = 2026-10-30T08:00:00Z ] && [ "$(jq -r '.id' <<<"$R")" = dpl_s2 ] && [ "$(jq -r '.sha' <<<"$R")" = "${SHA:0:8}" ] \
  && ok || bad "S2 a second ERROR keeps since and names the new deploy (got $R)"
[ "$(pages s2)" = 0 ] && ok || bad "S2 red after red: no page (got $(pages s2))"

# ---------- S3 / S4: BUILDING or CANCELED after red keep the red record -------
for st in BUILDING CANCELED; do
  c=s-$st; newtree "$c" "p$st"; prev "p$st" "$PREVRED"
  dep state "$st" "dpl_$st" "$SHA" "$CR" > "$FX/prj_p$st.newest"
  run_snap "$c"
  [ "$(red_of "p$st")" = "$(jq -c . <<<"$PREVRED")" ] && ok || bad "S3/S4 $st after red keeps the red record (got $(red_of "p$st"))"
  [ "$(pages "$c")" = 0 ] && ok || bad "S3/S4 $st: no page"
done

# ---------- S5: the newest read fails after red -------------------------------
newtree s5 ps5; prev ps5 "$PREVRED"
: > "$FX/prj_ps5.newest-fail"
run_snap s5; RC=$?
[ "$RC" = 0 ] && [ "$(red_of ps5)" = "$(jq -c . <<<"$PREVRED")" ] && ok || bad "S5 a failed read carries the red record, rc 0 (rc $RC, got $(red_of ps5))"
jq -e '.projects.ps5.newest_prod.id == "dpl_prev"' "$H/state/vercel-deploy-status.json" >/dev/null 2>&1 && ok || bad "S5 newest_prod is carried too"
[[ "$(tail -1 "$H/logs/vercel-snapshot.log")" == *"FAILED:"*"ps5:newest"* ]] && ok || bad "S5 the log names ps5:newest under FAILED (got '$(tail -1 "$H/logs/vercel-snapshot.log")')"
[ "$(pages s5)" = 0 ] && ok || bad "S5 an API failure pages nothing"
# S5b: a failed read with no previous record -> null, no page.
newtree s5b ps5b; : > "$FX/prj_ps5b.newest-fail"; run_snap s5b
[ "$(red_of ps5b)" = null ] && [ "$(pages s5b)" = 0 ] && ok || bad "S5b a failed read and no previous record: null, no page (got $(red_of ps5b))"

# ---------- S6 / S7: READY clears ---------------------------------------------
newtree s6 ps6; prev ps6 "$PREVRED"
dep state READY dpl_s6 "$SHA" "$CR" > "$FX/prj_ps6.newest"
run_snap s6
[ "$(red_of ps6)" = null ] && ok || bad "S6 READY after red clears the record (got $(red_of ps6))"
newtree s7 ps7; dep state READY dpl_s7 "$SHA" "$CR" > "$FX/prj_ps7.newest"; run_snap s7
[ "$(red_of ps7)" = null ] && [ "$(pages s7)" = 0 ] && ok || bad "S7 READY, no previous: null, no page (got $(red_of ps7))"

# ---------- S8: no production deploy ------------------------------------------
newtree s8 ps8; run_snap s8
[ "$(red_of ps8)" = null ] && [ "$(jq -c '.projects.ps8.newest_prod' "$H/state/vercel-deploy-status.json")" = null ] \
  && ok || bad "S8 no production deploy: prod_red and newest_prod null (got $(red_of ps8))"

# ---------- S9: BUILDING with an old-format previous snapshot -----------------
newtree s9 ps9
jq -nc '{generated_at:"2026-10-30 00:00:00Z", projects:{ps9:{domain:"x"}}}' > "$H/state/vercel-deploy-status.json"
dep state BUILDING dpl_s9 "$SHA" "$CR" > "$FX/prj_ps9.newest"; run_snap s9
[ "$(red_of ps9)" = null ] && [ "$(pages s9)" = 0 ] && ok || bad "S9 BUILDING with no red before: null, no page (got $(red_of ps9))"

# ---------- S10: the log token lists exactly the red projects ----------------
newtree s10 pa10 pb10 pc10
dep state ERROR dpl_a "$SHA" "$CR" > "$FX/prj_pa10.newest"
dep state READY dpl_b "$SHA" "$CR" > "$FX/prj_pb10.newest"
dep state ERROR dpl_c "$SHA" "$CR" > "$FX/prj_pc10.newest"
run_snap s10
WANT=$(jq -r '[.projects | to_entries[] | select(.value.prod_red != null) | .key] | join(",")' "$H/state/vercel-deploy-status.json")
[ "$WANT" = pa10,pc10 ] && [[ "$(tail -1 "$H/logs/vercel-snapshot.log")" == *"prodred:[$WANT]"* ]] && ok \
  || bad "S10 log token prodred:[pa10,pc10] matches the file (file $WANT; log '$(tail -1 "$H/logs/vercel-snapshot.log")')"
[ "$(pages s10)" = 2 ] && ok || bad "S10 two projects turned red: two pages (got $(pages s10))"

# ---------- P3: the page lib fails -> the record is still written ------------
newtree p3 pp3; dep state ERROR dpl_p3 "$SHA" "$CR" > "$FX/prj_pp3.newest"
run_snap p3 PAGE_RC=1; RC=$?
[ "$RC" = 0 ] && [ "$(jq -r '.id' <<<"$(red_of pp3)")" = dpl_p3 ] && [ "$(pages p3)" = 1 ] && ok \
  || bad "P3 a failing page: rc 0 and the record written (rc $RC, got $(red_of pp3))"

# ---------- P4: the knob reaches the call ------------------------------------
for spec in 7200:7200 abc:86400 0:86400; do
  k=${spec%%:*}; w=${spec#*:}
  newtree "p4-$k" "pp4$k"; dep state ERROR "dpl_p4$k" "$SHA" "$CR" > "$FX/prj_pp4$k.newest"
  run_snap "p4-$k" PROD_RED_REPAGE_S="$k"
  [ "$(cut -f1 "$T/p4-$k/pages")" = "$w" ] && ok || bad "P4 PROD_RED_REPAGE_S=$k -> ttl $w (got $(cut -f1 "$T/p4-$k/pages"))"
done

# ---------- N1: writer -> the conductor's reader -----------------------------
newtree n1 pn1; dep state ERROR dpl_n1 "$SHA" "$CR" > "$FX/prj_pn1.newest"; run_snap n1
GA=$(jq -r '.generated_at' "$H/state/vercel-deploy-status.json" | sed 's/ /T/')
GNOW=$(jq -rn --arg g "$GA" '$g | fromdateiso8601')
if [ -r "$FRAG" ]; then
  # shellcheck source=bin/merge-conductor.d/bh-8781-prod-red-hold.sh
  NOUT=$( H="$H"; MC_PROD_RED_NOW="$GNOW"; . "$FRAG" && mc_prod_red_state pn1 ); NRC=$?
else NOUT=""; NRC=99; fi
[ "$NRC" = 0 ] && [ "$NOUT" = "$ISO"$'\t'"${SHA:0:8}"$'\t'dpl_n1 ] && ok \
  || bad "N1 mc_prod_red_state reads the written record (rc $NRC, got '$NOUT')"

# ---------- B1: no real network ----------------------------------------------
! grep -qv '^https://api\.vercel\.com/' "$T/curl.log" && ok || bad "B1 curl saw only api.vercel.com ($(grep -v '^https://api\.vercel\.com/' "$T/curl.log" | head -3))"
grep -q 'target=production&limit=1' "$T/curl.log" && ok || bad "B1 the newest-production read went through the stub"

echo "prod-red-snapshot.bh-8781: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
