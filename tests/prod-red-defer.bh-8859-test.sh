#!/bin/bash
# tests/prod-red-defer.bh-8859-test.sh — A CLIENT COMPLETION COMMENT WAITS
# WHILE PRODUCTION IS RED (BH-8859, item 3 of BH-8781).
#
# bin/lib/prod-red-defer.sh reads .projects[<p>].prod_red from
# state/vercel-deploy-status.json through the BH-8781 reader. While it is red:
#   - bin/board-closeout.sh exits 4 on a PR_MERGED RESULT, before any POST;
#   - rt_unswept_dirs (bin/lib/rt/scope.sh) leaves PR_MERGED dirs off the list;
#   - bin/triage-gate.sh step 3 buys no results-sweep for them alone;
#   - bin/run-triage.sh hands the session and every shard the directive.
# Green, stale, missing or junk = today's behaviour.
#
#   L1-L12  prod_red_defers_dir per RESULT line and snapshot state
#   K1-K3   the TRIAGE_PROD_RED_DEFER knob: unset 1, 0 off, junk 1
#   RT1     the real bin/vercel-deploy-snapshot.sh writes red, then green
#   C1-C3   the real bin/board-closeout.sh: red PR_MERGED rc 4 no POST; red
#           PR_CREATED posts; the same C1 dir posts after green
#   S1-S3   rt_unswept_dirs: red, green, no snapshot
#   G1-G3   the real bin/triage-gate.sh step 3
#   N1-N3   the directive text and the real bin/run-triage.sh shard prompt
#   B1      the stubs saw only fixture hosts
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prod-red-defer.bh-8859-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null || { echo "prod-red-defer: SKIPPED — jq is not installed"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); printf 'FAIL: prod-red-defer: %s\n' "$*"; }
unset TRIAGE_PROD_RED_DEFER MC_PROD_RED_SNAPSHOT MC_PROD_RED_MAX_AGE_S

NOW=1793440000                                     # pinned clock (MC_PROD_RED_NOW)
ga() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%SZ'; }
RED='{"since":"2026-10-31T08:00:00Z","sha":"c0ffee12","id":"dpl_fixture_red"}'
# snap <file> <project> <prod_red json|null> [generated_at epoch]
snap() {
  mkdir -p "$(dirname "$1")"
  jq -nc --arg g "$(ga "${4:-$((NOW - 60))}")" --arg p "$2" --argjson r "$3" \
    '{generated_at:$g, projects:{($p):{domain:"x.example.test", prod_red:$r}}}' > "$1"
}

# The closure scan copies bin/lib files only, so the BH-8781 reader the lib
# sources from bin/merge-conductor.d/ is installed as its own closure.
reader() { scratch_install_closure bin/merge-conductor.d/bh-8781-prod-red-hold.sh "$1" >/dev/null || bad "setup: cannot install the BH-8781 reader in $1"; }

# ══ L / K — the decision ═══════════════════════════════════════════════════
LH="$T/l"; mkdir -p "$LH/state" "$LH/b"
scratch_install_closure bin/lib/prod-red-defer.sh "$LH" >/dev/null || bad "L setup: cannot install the lib closure"
reader "$LH"
# lrc <result line> [env...] — rc of prod_red_defers_dir on a fresh process.
lrc() {
  local l="$1"; shift
  printf '%s\n' "$l" > "$LH/b/RESULT"
  env MC_PROD_RED_NOW="$NOW" "$@" bash -c '. "$1/bin/lib/prod-red-defer.sh"; prod_red_defers_dir "$1" pfx "$1/b"' _ "$LH"
}
SF="$LH/state/vercel-deploy-status.json"
snap "$SF" pfx "$RED"
lrc "PR_MERGED https://github.com/o/r/pull/1"; [ $? = 0 ] && ok || bad "L1 red + PR_MERGED url must defer"
lrc "PR_MERGED https://github.com/o/r/pull/2 [builder-direct 2026-10-31T09:00:00Z]"; [ $? = 0 ] && ok || bad "L2 red + PR_MERGED with a marker suffix must defer"
lrc "PR_CREATED https://github.com/o/r/pull/3"; [ $? = 1 ] && ok || bad "L3 PR_CREATED must not defer"
lrc "RESULT_MALFORMED PR_MERGED https://github.com/o/r/pull/4"; [ $? = 1 ] && ok || bad "L4 RESULT_MALFORMED must not defer"
lrc "PR_MERGE_FAILED https://github.com/o/r/pull/5"; [ $? = 1 ] && ok || bad "L5 PR_MERGE_FAILED must not defer"
lrc " PR_MERGED https://github.com/o/r/pull/6"; [ $? = 1 ] && ok || bad "L6 a leading space must not defer"
lrc "PR_MERGED"; [ $? = 1 ] && ok || bad "L7 PR_MERGED with no url must not defer"
snap "$SF" pfx null
lrc "PR_MERGED https://github.com/o/r/pull/8"; [ $? = 1 ] && ok || bad "L8 a green (null) record must not defer"
snap "$SF" pfx "$RED" $((NOW - 4000))
lrc "PR_MERGED https://github.com/o/r/pull/9"; [ $? = 1 ] && ok || bad "L9 a stale snapshot (> 1800 s) must not defer"
scratch_rm "$SF"
lrc "PR_MERGED https://github.com/o/r/pull/10"; [ $? = 1 ] && ok || bad "L10 no snapshot file must not defer"
echo 'not json {' > "$SF"
lrc "PR_MERGED https://github.com/o/r/pull/11"; [ $? = 1 ] && ok || bad "L11 a junk snapshot must not defer"
snap "$SF" other "$RED"
lrc "PR_MERGED https://github.com/o/r/pull/12"; [ $? = 1 ] && ok || bad "L12 a red record on another project must not defer"
snap "$SF" pfx "$RED"
lrc "PR_MERGED https://github.com/o/r/pull/13"; [ $? = 0 ] && ok || bad "K1 the knob unset defers (default 1)"
lrc "PR_MERGED https://github.com/o/r/pull/14" TRIAGE_PROD_RED_DEFER=0; [ $? = 1 ] && ok || bad "K2 TRIAGE_PROD_RED_DEFER=0 must not defer"
lrc "PR_MERGED https://github.com/o/r/pull/15" TRIAGE_PROD_RED_DEFER=abc; [ $? = 0 ] && ok || bad "K3 a junk knob value reads as 1"
jq -e '.env == "TRIAGE_PROD_RED_DEFER" and .default == 1 and .min == 0 and .max == 1' \
  "$DIR/catalog/lanes.d/run-triage.knobs.d/TRIAGE_PROD_RED_DEFER.json" >/dev/null 2>&1 \
  && ok || bad "K1 the knob fragment must register TRIAGE_PROD_RED_DEFER default 1 (0..1)"

# N1 / N2 — the directive text
N=$(MC_PROD_RED_NOW="$NOW" bash -c '. "$1/bin/lib/prod-red-defer.sh"; prod_red_triage_note "$1" pfx' _ "$LH")
case "$N" in *"PRODUCTION RED (BH-8859)"*pfx*c0ffee12*"red since 2026-10-31T08:00:00Z"*) ok ;;
  *) bad "N1 the red directive names the project, the sha8 and since (got '$N')" ;; esac
case "$N" in *"un-COMMENTED"*) ok ;; *) bad "N1 the directive must tell the session to leave the dir un-COMMENTED" ;; esac
snap "$SF" pfx null
N=$(MC_PROD_RED_NOW="$NOW" bash -c '. "$1/bin/lib/prod-red-defer.sh"; prod_red_triage_note "$1" pfx' _ "$LH")
[ -z "$N" ] && ok || bad "N2 green must print no directive (got '$N')"

# ══ RT1 — the real snapshot writer, read back ═════════════════════════════
FB="$T/fakebin"; FX="$T/fx"; mkdir -p "$FB" "$FX"
jq -nc '{token:"tok-fixture-1", expiresAt:4102444800000}' > "$T/auth.json"
cat > "$FB/curl" <<'STUB'
#!/bin/bash
URL="${!#}"; BODY=""
for a in "$@"; do [ "${prev:-}" = -d ] && BODY="$a"; prev="$a"; done
printf '%s\n' "$URL" >> "$CURL_LOG"
pid=$(sed -n 's/.*projectId=\([^&]*\).*/\1/p' <<<"$URL")
case "$URL" in
  https://api.vercel.com/v4/aliases/*) echo '{"deploymentId":"dpl_fixture_s"}' ;;
  https://api.vercel.com/v13/deployments/*) echo '{"createdAt":1700000000000,"gitSource":{"sha":"a1b2c3d4e5f6"}}' ;;
  https://api.vercel.com/v6/deployments*target=preview*) echo '{"deployments":[]}' ;;
  https://api.vercel.com/v6/deployments*target=production\&state=READY*) echo '{"deployments":[]}' ;;
  https://api.vercel.com/v6/deployments*target=production*)
    if [ -f "$FX/$pid.newest" ]; then printf '{"deployments":[%s]}\n' "$(cat "$FX/$pid.newest")"; else echo '{"deployments":[]}'; fi ;;
  https://app.example.test/*/comments) printf '%s\n' "$BODY" >> "$CURL_LOG.bodies"; echo '{"comment":{"id":"c1"}}' ;;
  https://app.example.test/*/move) echo '{"ticket":{"status":"done"}}' ;;
  *) exit 7 ;;
esac
STUB
printf '#!/bin/bash\necho "npx $*" >> "$CURL_LOG"\nexit 0\n' > "$FB/npx"
printf '#!/bin/bash\ncat >/dev/null\nexit 0\n' > "$FB/ssh"
chmod +x "$FB/curl" "$FB/npx" "$FB/ssh"
RH="$T/rt/h"; mkdir -p "$RH/state" "$RH/logs" "$RH/flags"
scratch_install_closure bin/vercel-deploy-snapshot.sh "$RH" >/dev/null || bad "RT1 setup: cannot install the snapshot lane"
printf 'page_critical() { return 0; }\n' > "$RH/bin/lib/page-critical.sh"
printf 'pfx team_fixture prj_pfx pfx.example.test\n' > "$RH/vercel.conf"; : > "$T/rt/fleet.conf"
: > "$T/rt.curl"
run_snap() {
  env -u PROD_RED_REPAGE_S PATH="$FB:$PATH" HARNESS="$RH" FLEET_CONF="$T/rt/fleet.conf" REGISTRY_SOURCE=file \
      LANE_GATE_DISABLE=1 LANE_REGISTRY="$T/no-registry.json" JOBS_URL='' FX="$FX" \
      VERCEL_CLI_AUTH="$T/auth.json" CURL_LOG="$T/rt.curl" bash "$RH/bin/vercel-deploy-snapshot.sh" 2>>"$T/rt.err"
}
SHA=c0ffee12deadbeef00000000000000000000aaaa
jq -nc --arg h "$SHA" '{uid:"dpl_fixture_rt", state:"ERROR", createdAt:1793400000000, meta:{githubCommitSha:$h}}' > "$FX/prj_pfx.newest"
run_snap || bad "RT1 the snapshot lane failed: $(tail -3 "$T/rt.err")"
cp "$RH/state/vercel-deploy-status.json" "$T/rt-red.json" 2>/dev/null
jq -nc --arg h "$SHA" '{uid:"dpl_fixture_rt2", state:"READY", createdAt:1793400600000, meta:{githubCommitSha:$h}}' > "$FX/prj_pfx.newest"
run_snap || bad "RT1 the second snapshot run failed: $(tail -3 "$T/rt.err")"
cp "$RH/state/vercel-deploy-status.json" "$T/rt-green.json" 2>/dev/null
RT_NOW=$(jq -r '.generated_at | sub(" "; "T") | fromdateiso8601 + 30' "$T/rt-green.json" 2>/dev/null)
case "$RT_NOW" in ''|*[!0-9]*) bad "RT1 the written snapshot has no readable generated_at"; RT_NOW=$NOW ;; esac
rtstate() { MC_PROD_RED_NOW="$RT_NOW" MC_PROD_RED_SNAPSHOT="$1" bash -c '. "$1/bin/lib/prod-red-defer.sh"; prod_red_defer_state "$1" pfx' _ "$LH"; }
OUT=$(rtstate "$T/rt-red.json"); RC=$?
[ "$RC" = 0 ] && [ "$(cut -f2 <<<"$OUT")" = "${SHA:0:8}" ] && ok \
  || bad "RT1 the real writer's red record must read red with sha ${SHA:0:8} (rc $RC, got '$OUT')"
rtstate "$T/rt-green.json" >/dev/null; [ $? = 1 ] && ok || bad "RT1 the real writer's READY record must read not red"

# ══ C — the real bin/board-closeout.sh ════════════════════════════════════
CH="$T/c/h"; mkdir -p "$CH/state" "$CH/flags" "$CH/env" "$CH/builds/pfx-TK-9-1"
scratch_install_closure bin/board-closeout.sh "$CH" >/dev/null || bad "C setup: cannot install the close-out closure"
[ -f "$CH/bin/lib/prod-red-defer.sh" ] || bad "C setup: bin/board-closeout.sh must source bin/lib/prod-red-defer.sh"
reader "$CH"
cat > "$CH/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$2" in prod) echo "https://app.example.test" ;; board_prefix) echo "/api/board" ;; *) exit 1 ;; esac
SH
printf '#!/bin/bash\necho tok-fixture-board\n' > "$CH/bin/internal-token-for.sh"
printf '#!/bin/bash\necho OK\n' > "$CH/bin/triage-gate.sh"
chmod +x "$CH/bin/fleet-conf.sh" "$CH/bin/internal-token-for.sh" "$CH/bin/triage-gate.sh"
BB="$CH/builds/pfx-TK-9-1"
printf '## QA screens\n- /clients — the list\n\n## Size\n' > "$BB/plan.md"
closeout() { env PATH="$FB:$PATH" HARNESS="$CH" MC_PROD_RED_NOW="$RT_NOW" CURL_LOG="$T/c.curl" BUILDER_DIRECT=1 \
               "$CH/bin/board-closeout.sh" pfx T1 TK-9 "$BB" 2>"$T/c.err"; }
cp "$T/rt-red.json" "$CH/state/vercel-deploy-status.json"
: > "$T/c.curl"; echo "PR_MERGED https://github.com/o/r/pull/7" > "$BB/RESULT"
closeout >/dev/null; RC=$?
[ "$RC" = 4 ] && ok || bad "C1 red + PR_MERGED must exit 4 (got $RC; $(tail -2 "$T/c.err"))"
[ "$(grep -c . "$T/c.curl")" = 0 ] && ok || bad "C1 no request may be made while red (got $(cat "$T/c.curl"))"
grep -q 'waits for a green deploy' "$T/c.err" && ok || bad "C1 stderr must say the close-out waits for a green deploy"
[ "$(head -1 "$BB/RESULT")" = "PR_MERGED https://github.com/o/r/pull/7" ] && ok || bad "C1 the RESULT must stay unmarked"
: > "$T/c.curl"; echo "PR_CREATED https://github.com/o/r/pull/8" > "$BB/RESULT"
closeout >/dev/null; RC=$?
[ "$RC" = 0 ] && grep -q 'tickets/T1/comments' "$T/c.curl" && ok || bad "C2 red + PR_CREATED must still post (rc $RC; $(cat "$T/c.curl"))"
cp "$T/rt-green.json" "$CH/state/vercel-deploy-status.json"
: > "$T/c.curl"; : > "$T/c.curl.bodies"; echo "PR_MERGED https://github.com/o/r/pull/7" > "$BB/RESULT"
OUT=$(closeout); RC=$?
[ "$RC" = 0 ] && grep -q 'tickets/T1/comments' "$T/c.curl" && ok || bad "C3 the deferred dir must post once green (rc $RC; $(tail -2 "$T/c.err"))"
grep -q 'app.example.test/clients' "$T/c.curl.bodies" && ok || bad "C3 the comment must carry the production link"
[ "$OUT" = "POSTED pfx/TK-9 -> done" ] && ok || bad "C3 the merged close-out moves the ticket to done (got '$OUT')"

# ══ S — rt_unswept_dirs ═══════════════════════════════════════════════════
SH_="$T/s/h"; mkdir -p "$SH_/state" "$SH_/builds/pfx-TK-1-1" "$SH_/builds/pfx-TK-2-1"
scratch_install_closure bin/lib/prod-red-defer.sh "$SH_" >/dev/null || bad "S setup: cannot install the lib"
reader "$SH_"
echo "PR_CREATED https://github.com/o/r/pull/1" > "$SH_/builds/pfx-TK-1-1/RESULT"
echo "PR_MERGED https://github.com/o/r/pull/2" > "$SH_/builds/pfx-TK-2-1/RESULT"
unswept() ( export HARNESS="$SH_" PROJECT=pfx MC_PROD_RED_NOW="$NOW"; . "$DIR/bin/lib/rt/scope.sh" >/dev/null 2>&1; rt_unswept_dirs )
snap "$SH_/state/vercel-deploy-status.json" pfx "$RED"
L=$(unswept)
grep -q 'pfx-TK-1-1 :: PR_CREATED' <<<"$L" && ok || bad "S1 red: the PR_CREATED dir stays on the list (got '$L')"
grep -q 'pfx-TK-2-1' <<<"$L" && bad "S1 red: the PR_MERGED dir must be left off the list (got '$L')" || ok
snap "$SH_/state/vercel-deploy-status.json" pfx null
L=$(unswept)
grep -q 'pfx-TK-1-1' <<<"$L" && grep -q 'pfx-TK-2-1 :: PR_MERGED' <<<"$L" && ok || bad "S2 green: both dirs are listed (got '$L')"
scratch_rm "$SH_/state/vercel-deploy-status.json"
L=$(unswept)
[ "$(grep -c . <<<"$L")" = 2 ] && ok || bad "S3 no snapshot: both dirs are listed (got '$L')"

# ══ G — the real bin/triage-gate.sh step 3 ════════════════════════════════
mkdir -p "$T/gfake"
cat > "$T/gfake/gh" <<'SH'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$GH_LOG"
[ "${1:-}" = api ] || exit 1
shift; P=""
while [ $# -gt 0 ]; do case "$1" in -i) shift ;; -X|-f|-F|-H) shift 2 ;; -*) shift ;; *) P="$1"; shift; break ;; esac; done
case "$P" in
  repos/o/r/issues*) BODY='[{"number":7,"state":"open","title":"t","comments":1,"updated_at":"x"}]' ;;
  repos/o/r/pulls*)  BODY='[]' ;;
  *) exit 1 ;;
esac
printf 'HTTP/2.0 200\r\n\r\n%s\n' "$BODY"
SH
chmod +x "$T/gfake/gh"; : > "$T/gh.log"
# gtree <name> <prod_red json> <RESULT line>... — a fresh gate harness.
gtree() {
  local n="$1" r="$2" i=0 l; shift 2
  G="$T/g/$n"; mkdir -p "$G/bin" "$G/state" "$G/flags" "$G/logs" "$G/env"
  printf '#!/bin/bash\ncase "$1 ${2:-}" in "p board_prefix") echo "-" ;; "p repo") echo "o/r" ;; *) exit 1 ;; esac\n' > "$G/bin/fleet-conf.sh"
  chmod +x "$G/bin/fleet-conf.sh"
  snap "$G/state/vercel-deploy-status.json" p "$r"
  for l in "$@"; do i=$((i+1)); mkdir -p "$G/builds/p-K$i-1"; echo "$l" > "$G/builds/p-K$i-1/RESULT"; done
}
gate() { ( export PATH="$T/gfake:$PATH" HARNESS="$G" GH_LOG="$T/gh.log" MC_PROD_RED_NOW="$NOW"; "$DIR/bin/triage-gate.sh" p 2>/dev/null ); }
gtree g1 "$RED" "PR_MERGED https://github.com/o/r/pull/1"
# Red, one PR_MERGED dir: step 3 buys nothing and the gate falls through to
# step 4, the overdue daily net (no daily-sweep stamp in a fresh tree).
OUT=$(gate); [ "$OUT" = "RUN daily-sweep" ] && ok || bad "G1 red, one PR_MERGED dir: no results-sweep, the gate falls through to the daily net (got '$OUT')"
[ ! -f "$G/state/p.sweepfp" ] && ok || bad "G1 a deferred dir must not stamp the sweep fingerprint"
gtree g2 null "PR_MERGED https://github.com/o/r/pull/1"
OUT=$(gate); [ "$OUT" = "RUN results-sweep" ] && ok || bad "G2 green: the PR_MERGED dir buys the sweep (got '$OUT')"
gtree g3 "$RED" "PR_MERGED https://github.com/o/r/pull/1" "PR_CREATED https://github.com/o/r/pull/2"
OUT=$(gate); [ "$OUT" = "RUN results-sweep" ] && ok || bad "G3 red with a PR_CREATED dir beside it: the sweep still runs (got '$OUT')"

# ══ N3 — the real bin/run-triage.sh shard prompt ══════════════════════════
H="$T/n/h"; P=cromford
mkdir -p "$H/logs" "$H/state" "$H/locks" "$H/env" "$H/flags" "$H/prompts" "$H/builds" "$H/catalog" "$T/repos"
scratch_install_closure bin/run-triage.sh "$H" >/dev/null || bad "N3 setup: cannot install the run-triage closure"
[ -f "$H/bin/lib/prod-red-defer.sh" ] || bad "N3 setup: bin/run-triage.sh must source bin/lib/prod-red-defer.sh"
reader "$H"
sed -i "s|/root/repos|$T/repos|g" "$H/bin/run-triage.sh" "$H"/bin/lib/rt/*.sh
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
: > "$H/env/global.env"; echo "SOP for $P." > "$H/prompts/$P.md"
for s in fleet-conf.sh project-of.sh decision-log.sh queue-line-drop.sh; do cp "$DIR/bin/$s" "$H/bin/$s"; done
printf '#!/bin/sh\necho box-fixture\n' > "$H/bin/box-name.sh"
printf '#!/bin/bash\n[ "${2:-}" = "--pending" ] && exit 0\necho "RUN results-sweep"\n' > "$H/bin/triage-gate.sh"
printf '#!/bin/bash\nexit 2\n' > "$H/bin/gate-diff.sh"
for s in unblocked-children triage-shard overlap-guard beat; do printf '#!/bin/sh\nexit 0\n' > "$H/bin/$s.sh"; done
printf '#!/bin/sh\necho "CONTRACT: end with DECISION lines."\n' > "$H/bin/triage-contract.sh"
printf '#!/bin/bash\necho "tickets=0" > "$5"\nexit 0\n' > "$H/bin/agent-call.sh"
chmod +x "$H/bin/"*.sh
SD="$H/state/triage-shards/$P"
ntick() { # ntick <prod_red json>
  scratch_rm "$H/state"; scratch_rm "$H/logs"; scratch_rm "$H/locks"; scratch_rm "$H/builds"
  mkdir -p "$H/state" "$H/logs" "$H/locks" "$H/builds/$P-BH-91-1" "$H/builds/$P-BH-92-1"
  model_routes_fixture "$H" "$P" || exit 1
  : > "$H/logs/READY-QUEUE.log"
  echo "PR_CREATED https://github.com/o/r/pull/91" > "$H/builds/$P-BH-91-1/RESULT"
  echo "PR_MERGED https://github.com/o/r/pull/92" > "$H/builds/$P-BH-92-1/RESULT"
  snap "$H/state/vercel-deploy-status.json" "$P" "$1"
  env HARNESS="$H" FLEET_CONF="$DIR/fleet.conf" TRIAGE_SHARDS=1 MC_PROD_RED_NOW="$NOW" "$H/bin/run-triage.sh" "$P" >/dev/null 2>&1
}
ntick "$RED"
grep -q 'PRODUCTION RED (BH-8859)' "$SD/91.prompt" 2>/dev/null && ok \
  || bad "N3 red: the shard prompt must carry the directive (prompts: $(ls "$SD" 2>/dev/null | tr '\n' ' '))"
[ ! -f "$SD/92.prompt" ] && ok || bad "N3 red: the PR_MERGED dir must get no shard"
grep -q 'PROD-RED defer' "$H/logs/$P.log" 2>/dev/null && ok || bad "N3 red: the tick logs one PROD-RED defer line"
ntick null
[ -f "$SD/91.prompt" ] && ! grep -q 'PRODUCTION RED' "$SD/91.prompt" && ok || bad "N3 green: the shard prompt carries no directive"
[ -f "$SD/92.prompt" ] && ok || bad "N3 green: the PR_MERGED dir gets its shard"

# ══ B1 — only fixture hosts ═══════════════════════════════════════════════
grep -qv '^https://api.vercel.com/' "$T/rt.curl" && bad "B1 the snapshot lane reached a host other than the Vercel stub: $(grep -v '^https://api.vercel.com/' "$T/rt.curl")" || ok
grep -qv '^https://app.example.test/' "$T/c.curl" && bad "B1 the close-out reached a host other than the board stub" || ok
grep -qv '^gh api repos/o/r/' "$T/gh.log" && bad "B1 the gate called gh outside the stubbed board: $(grep -v '^gh api repos/o/r/' "$T/gh.log")" || ok

echo "prod-red-defer.bh-8859: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
