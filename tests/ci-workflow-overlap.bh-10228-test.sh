#!/bin/bash
# tests/ci-workflow-overlap.bh-10228-test.sh — two plans that each add one new
# fragment to config/harness-ci/ (and so both list the render
# .github/workflows/harness-ci.yml) are not deferred, because the render is a
# declared Generated files row (BH-10228, slice C4 of BH-9704). The REAL
# overlap scripts run in scratch harnesses against a scratch target repo whose
# docs/verification-map/index/tail.md is a COPY of this checkout's file, so the
# shipped row is what is proved, not a fixture row. No network, no gh, no LLM.
#   O0  the shipped tail.md holds the committed row: gen_table_paths lists the
#       render and gen_nocommit_paths does not
#   O1  two new fragments + the render: plan-overlap rc 0, plan-sibling check
#       rc 0, conflict-check rc 0, overlap-guard LAUNCH
#   O2  near miss: both plans list the SAME existing fragment: each defers
#   O3  near miss: tail.md without the new row (main before this PR): the
#       render alone defers, so the row is the cause
#   O4  near miss: paths that only look like the render or its dir: defer
#   U1  the CLAUDE.md union command runs bin/render-ci-workflow.sh --check
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

FDIR=config/harness-ci
RENDER=.github/workflows/harness-ci.yml
FA="$FDIR/120-lint/995-bh-1-a.yml"
FB="$FDIR/130-determinism/995-bh-2-b.yml"
OLD="$FDIR/120-lint/010-checkout.yml"
[ -f "$DIR/$OLD" ] && ok || bad "O0: $OLD must exist (O2 shares it)"
[ ! -e "$DIR/$FA" ] && [ ! -e "$DIR/$FB" ] && ok || bad "O0: $FA and $FB must be new fragments"
LOOK1="${RENDER}x"
LOOK2="$FDIR.bak/120-lint/010-checkout.yml"

# ============================== O0 the row ==============================
grep -qxF "| \`$RENDER\` | \`bin/render-ci-workflow.sh --write\` | committed |" "$DIR/docs/verification-map/index/tail.md" \
  && ok || bad "O0: tail.md must hold the committed row for $RENDER"

# ============================== U1 the union command ==============================
UNION=$(sed -n '/^```bash/,/^```/p' "$DIR/CLAUDE.md" | sed -n 2p)
grep -qF 'HARNESS_TEST_SANDBOX=1 bin/render-ci-workflow.sh --check' <<<"$UNION" && ok \
  || bad "U1: the CLAUDE.md union command must run bin/render-ci-workflow.sh --check"

# --- the scratch target repos: with the shipped tail.md, and without the row ---
mkrepo() { # mkrepo <dir> <with-row 1|0>
  local R="$1"
  mkdir -p "$R/docs/verification-map/index"
  git -C "$R" init -q -b main
  if [ "$2" = 1 ]; then
    cp "$DIR/docs/verification-map/index/tail.md" "$R/docs/verification-map/index/tail.md"
  else
    grep -vF "| \`$RENDER\` |" "$DIR/docs/verification-map/index/tail.md" > "$R/docs/verification-map/index/tail.md"
  fi
  git -C "$R" add -A && git -C "$R" -c user.email=t@fixture.test -c user.name=t -c commit.gpgsign=false commit -qm fixture || bad "fixture repo $R"
}
NEW="$T/repo-new"; mkrepo "$NEW" 1
OLDR="$T/repo-old"; mkrepo "$OLDR" 0
grep -qF "| \`$RENDER\` |" "$NEW/docs/verification-map/index/tail.md" && ok || bad "O0: the shipped tail.md must hold the $RENDER row"
grep -qF "| \`$RENDER\` |" "$OLDR/docs/verification-map/index/tail.md" && bad "O3 fixture: the old tail.md must not hold the row" || ok
# The readers take the table at a ref, so they read the committed copy in $NEW.
# shellcheck source=/dev/null
. "$DIR/bin/lib/generated-table.sh" || { echo "FAIL: cannot source bin/lib/generated-table.sh"; exit 1; }
GT=$(gen_table_paths "$NEW" HEAD); NC=$(gen_nocommit_paths "$NEW" HEAD)
grep -qxF "$RENDER" <<<"$GT" && ok || bad "O0: gen_table_paths must list $RENDER, got [$GT]"
grep -qxF "$RENDER" <<<"$NC" && bad "O0: gen_nocommit_paths must not list the committed $RENDER" || ok

# ============================== conflict-check.sh ==============================
CC="$T/cc"
mkdir -p "$CC/bin/lib" "$CC/builds" "$CC/flags"
scratch_install_closure bin/conflict-check.sh "$CC" >/dev/null || bad "closure install: bin/conflict-check.sh"
ccb() { local d="$CC/builds/acme-$1"; shift; scratch_rm "$d"; mkdir -p "$d"; printf '%s\n' "$@" > "$d/planned-files.txt"; }
ccr() { CC_OUT=$(env LANE_GATE_DISABLE=1 HARNESS="$CC" PLAN_OVERLAP_REPO="$1" bash "$CC/bin/conflict-check.sh" acme "$CC/builds/acme-a"); CC_RC=$?; }
ccb a "$FA" "$RENDER"; ccb b "$FB" "$RENDER"; ccr "$NEW"
[ "$CC_RC" = 0 ] && [ -z "$CC_OUT" ] && ok || bad "O1 conflict-check: two new fragments + the render must not conflict, rc=$CC_RC out=[$CC_OUT]"
ccb a "$OLD" "$RENDER"; ccb b "$OLD" "$RENDER"; ccr "$NEW"
[ "$CC_RC" = 1 ] && grep -qF "$OLD" <<<"$CC_OUT" && ok || bad "O2 conflict-check: one shared fragment must conflict on it, rc=$CC_RC out=[$CC_OUT]"
ccb a "$FA" "$RENDER"; ccb b "$FB" "$RENDER"; ccr "$OLDR"
[ "$CC_RC" = 1 ] && grep -qF "$RENDER" <<<"$CC_OUT" && ok || bad "O3 conflict-check: without the row the render must conflict, rc=$CC_RC out=[$CC_OUT]"
for p in "$LOOK1" "$LOOK2"; do
  ccb a "$p"; ccb b "$p"; ccr "$NEW"
  [ "$CC_RC" = 1 ] && ok || bad "O4 conflict-check: the look-alike $p must conflict, rc=$CC_RC"
done

# ============================== plan-overlap.sh ==============================
W="$T/W"
cat > "$T/jobs-client.stub.sh" <<SH
JOBS_BOX=box-test
[ -r "\$HARNESS/bin/lib/jobs/jobs.sh" ] && . "\$HARNESS/bin/lib/jobs/jobs.sh"
_jobs_req() {
  case "\$1 \$2" in
    "GET /api/file-claims?project=acme") echo '{"claims":[],"truncated":false}' ;;
    "GET /api/conflict-hotspots?project=acme&limit="*) echo '{"project":"acme","run":null,"hotspots":[],"total":0,"truncated":false}' ;;
    "PUT /api/jobs/"*"/artifacts") echo '{"ok":true}' ;;
    *) return 1 ;;
  esac
}
SH
mkdir -p "$W/bin/lib" "$W/env" "$W/flags" "$W/logs" "$W/builds" "$W/state/claims/acme"
cp "$T/jobs-client.stub.sh" "$W/bin/jobs-client.sh"
for s in bin/plan-overlap.sh bin/touch-files.sh bin/planned-files.sh bin/lib/jobs/jobs.sh; do
  scratch_install_closure "$s" "$W" >/dev/null || bad "closure install: $s"
done
printf 'acme  example-org/acme   -  -  0 local -\n' > "$W/fleet.conf"
bdir() { echo "$W/builds/acme-$1-20261114040000"; }
build() { # build <KEY> <file>...
  local K="$1" D f; shift; D=$(bdir "$K")
  scratch_rm "$D"; mkdir -p "$D"
  { printf '# Plan %s\n## Files to touch\n' "$K"; for f in "$@"; do printf -- '- `%s` (Modified)\n' "$f"; done
    printf '\n## Tasks\nEdit them.\n'; } > "$D/plan.md"
  printf '{"key":"%s"}\n' "$K" > "$D/ticket-meta.json"
  bash "$W/bin/planned-files.sh" "$D"
  env HARNESS="$W" bash "$W/bin/touch-files.sh" "$D" acme
}
preset() { scratch_rm "$W/builds"; scratch_rm "$W/state"; scratch_rm "$W/logs"; mkdir -p "$W/builds" "$W/state/claims/acme" "$W/logs"; }
po() { OUT=$(env LANE_GATE_DISABLE=1 HARNESS="$W" PLAN_OVERLAP_REPO="$2" bash "$W/bin/plan-overlap.sh" acme "$(bdir "$1")" 2>"$T/err.txt"); RC=$?; }
preset; build TK-1 "$FA" "$RENDER"; build TK-2 "$FB" "$RENDER"
grep -qxF "$RENDER" "$(bdir TK-1)/touch-files.txt" && ok || bad "O1 fixture: touch-files.txt must list $RENDER"
po TK-1 "$NEW"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "O1 plan-overlap: two new fragments + the render must not defer, rc=$RC out=[$OUT]"
po TK-1 "$OLDR"
[ "$RC" = 1 ] && grep -q '^OVERLAP_DEFER TK-1 vs TK-2' <<<"$OUT" && ok || bad "O3 plan-overlap: without the row the render must defer, rc=$RC out=[$OUT]"
preset; build TK-1 "$OLD" "$RENDER"; build TK-2 "$OLD" "$RENDER"; po TK-1 "$NEW"
[ "$RC" = 1 ] && grep -qF "$OLD" <<<"$OUT" && ok || bad "O2 plan-overlap: a shared fragment must defer, rc=$RC out=[$OUT]"
for p in "$LOOK1" "$LOOK2"; do
  preset; build TK-1 "$p"; build TK-2 "$p"; po TK-1 "$NEW"
  [ "$RC" = 1 ] && ok || bad "O4 plan-overlap: the look-alike $p must defer, rc=$RC out=[$OUT]"
done

# ============================== plan-sibling.sh ==============================
H="$T/h"
mkdir -p "$H/bin/lib" "$H/env" "$H/flags" "$H/logs" "$H/fx" "$T/stub"
printf 'cromford  example-org/cromford  -  -     0 local -\n' > "$H/fleet.conf"
cat > "$H/bin/lib/gh-rest-list.sh" <<'SH'
gh_rest_issue_list() { [ "$1" = example-org/cromford ] || return 75; cat "$HARNESS/fx/issues.json"; }
gh_rest_pr_list_all() { cat "$HARNESS/fx/pulls.json"; }
gh_rest() {
  local n
  case "$2" in repos/example-org/cromford/pulls/*/files) ;; *) return 75 ;; esac
  n=${2#repos/example-org/cromford/pulls/}; n=${n%/files}
  cat "$HARNESS/fx/files.$n.json"
}
gh_rest_comment() { return 0; }
SH
printf '#!/bin/bash\nexit 99\n' > "$T/stub/gh"; chmod +x "$T/stub/gh"
scratch_install_closure bin/plan-sibling.sh "$H" >/dev/null || bad "closure install: bin/plan-sibling.sh"
[ -e "$H/bin/fleet-conf.sh" ] || cp "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
B="$T/b"
sbody() { printf 'Scope for this slice.\n\n---\nPart of #%s\nOrder: 2 of 3\n' "$1"; }
smkb() { scratch_rm "$B"; mkdir -p "$B"; printf '# plan\n' > "$B/plan.md"; printf '%s\n' "$@" > "$B/planned-files.txt"
  jq -n --arg b "$(sbody 9704)" '{key:"BH-9802",body:$b}' > "$B/ticket-meta.json"; }
sreset() {
  scratch_rm "$H/fx"; scratch_rm "$H/logs"; scratch_rm "$H/state"; mkdir -p "$H/fx" "$H/logs"
  printf '[]\n' > "$H/fx/pulls.json"
  jq -nc --arg b "$(sbody 9704)" '[{number:9801,title:"s",body:$b,state:"open"},{number:9802,title:"s",body:$b,state:"open"}]' > "$H/fx/issues.json"
}
spull() { local n="$1" ref="$2" sha="$3"; shift 3
  jq -c --argjson n "$n" --arg r "$ref" --arg s "$sha" '. + [{number:$n,state:"open",head:{ref:$r,sha:$s}}]' "$H/fx/pulls.json" > "$H/fx/p.tmp" \
    && mv "$H/fx/p.tmp" "$H/fx/pulls.json"
  printf '%s\n' "$@" | jq -R . | jq -sc 'map({filename:.,status:"modified"})' > "$H/fx/files.$n.json"; }
ps() { OUT=$(env LANE_GATE_DISABLE=1 PATH="$T/stub:$PATH" FLEET_CONF="$H/fleet.conf" HARNESS="$H" PLAN_OVERLAP_REPO="$1" \
        bash "$H/bin/plan-sibling.sh" check cromford "$B" 2>"$T/err"); RC=$?; }
SHA1=1111111111111111111111111111111111111111
sreset; smkb "$FB" "$RENDER"; spull 900 ticket/bh-9801 "$SHA1" "$FA" "$RENDER"
ps "$NEW"
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "O1 plan-sibling: a sibling PR with its own new fragment + the render must not defer, rc=$RC out=[$OUT] err=[$(cat "$T/err")]"
ps "$OLDR"
[ "$RC" = 1 ] && grep -qF "$RENDER" <<<"$OUT" && ok || bad "O3 plan-sibling: without the row the render must defer, rc=$RC out=[$OUT]"
sreset; smkb "$OLD" "$RENDER"; spull 900 ticket/bh-9801 "$SHA1" "$OLD" "$RENDER"
ps "$NEW"
[ "$RC" = 1 ] && grep -qF "$OLD" <<<"$OUT" && ok || bad "O2 plan-sibling: a shared fragment must defer, rc=$RC out=[$OUT]"
sreset; smkb "$LOOK1"; spull 900 ticket/bh-9801 "$SHA1" "$LOOK1"
ps "$NEW"
[ "$RC" = 1 ] && ok || bad "O4 plan-sibling: the look-alike $LOOK1 must defer, rc=$RC out=[$OUT]"

# ============================== overlap-guard.sh ==============================
GH="$T/g"
mkdir -p "$GH/bin/lib" "$GH/logs" "$GH/flags" "$GH/state" "$GH/plans" "$GH/builds" "$GH/env" "$GH/locks" "$T/fakebin"
scratch_install_closure bin/overlap-guard.sh "$GH" >/dev/null || bad "closure install: bin/overlap-guard.sh"
for s in bin/fleet-conf.sh bin/planned-files.sh; do [ -e "$GH/$s" ] || cp "$DIR/$s" "$GH/$s"; done
scratch_install_closure bin/lib/gh-pr-list.sh "$GH" >/dev/null || bad "closure install: bin/lib/gh-pr-list.sh"
printf 'proj example-org/proj https://proj.example /api/board 0 local -\n' > "$GH/fleet.conf"
printf '_jobs_req() { cat "%s"; }\n' "$T/ledger.json" > "$GH/bin/jobs-client.sh"
echo '{"jobs":[{"kind":"build","ticket_id":"AB-2"}]}' > "$T/ledger.json"
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
case "$*" in
  *"/pulls?"*|*"/files"*) printf 'HTTP/2.0 200\r\n\r\n[]\n' ;;
  *"pr list"*) echo '[]' ;;
  *) echo '' ;;
esac
exit 0
SH
chmod +x "$T/fakebin/gh"
setplan() { local k="$1"; shift; mkdir -p "$GH/plans/proj-$k"; printf '%s\n' "$@" > "$GH/plans/proj-$k/planned-files.txt"; }
gr() { scratch_rm "$GH/state/overlap-guard"
  OUT=$(env LANE_GATE_DISABLE=1 HARNESS="$GH" FLEET_CONF="$GH/fleet.conf" PATH="$T/fakebin:$PATH" PLAN_OVERLAP_REPO="$1" \
        bash "$GH/bin/overlap-guard.sh" proj AB-1 2>/dev/null); RC=$?; }
setplan AB-1 "$FA" "$RENDER"; setplan AB-2 "$FB" "$RENDER"
gr "$NEW"
[ "$RC" = 0 ] && grep -q '^LAUNCH AB-1' <<<"$OUT" && ok || bad "O1 overlap-guard: two new fragments + the render must LAUNCH, rc=$RC out=[$OUT]"
gr "$OLDR"
[ "$RC" = 1 ] && grep -q '^DEFER AB-1 vs AB-2' <<<"$OUT" && ok || bad "O3 overlap-guard: without the row the render must DEFER, rc=$RC out=[$OUT]"
setplan AB-1 "$OLD" "$RENDER"; setplan AB-2 "$OLD" "$RENDER"
gr "$NEW"
[ "$RC" = 1 ] && ok || bad "O2 overlap-guard: a shared fragment must DEFER, rc=$RC out=[$OUT]"
setplan AB-1 "$LOOK2"; setplan AB-2 "$LOOK2"
gr "$NEW"
[ "$RC" = 1 ] && ok || bad "O4 overlap-guard: the look-alike $LOOK2 must DEFER, rc=$RC out=[$OUT]"

echo "ci-workflow-overlap.bh-10228: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
