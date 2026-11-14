#!/bin/bash
# tests/overlap-automerge-paths.bh-9426-test.sh — a path the merge resolves by
# itself never defers a build: every path the target repo's `## Generated
# files` table declares, and every `merge=union` path in its .gitattributes
# (BH-9426 scope 3). Code paths, fragment files edited on both sides and near
# misses still defer.
#
# The REAL scripts run in scratch harnesses against a scratch target repo. No
# network, no gh, no LLM.
#   U1-U5  bin/lib/automerge-paths.sh: amp_is_automerge and amp_filter
#   C1-C4  bin/conflict-check.sh (the in-build wait that ends BUILD_DEFERRED
#          file overlap): generated -> rc 0, union -> rc 0, code -> rc 1,
#          negatives -> rc 1, no repo -> the old defer
#   P1-P3  bin/plan-overlap.sh: union path -> rc 0, generated -> rc 0, code -> defer
#   S1-S2  bin/plan-sibling.sh check: union path -> rc 0, code -> defer
#   G1-G3  bin/overlap-guard.sh: union / generated -> LAUNCH, code -> DEFER
#   M1-M3  mutants without the new filter turn C1, P1 and G1 red
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

GEN=catalog/state-paths.json
UNI=env-templates/project.env.example
GLOB=cron/rendered/hub.cron
CODE=bin/pay.sh
# Paths that must STILL defer when both sides plan them.
NEG="catalog/state-paths.jsonx catalog/lanes.d/x.json worker/jobs/schema.d/0001-x.sql catalog/state-paths.d/0001-x.json assets/logo.bin .gitattributes"

# --- the scratch target repo -------------------------------------------------
R="$T/repo"
mkdir -p "$R/docs/verification-map/index"
git -C "$R" init -q -b main
git -C "$R" config user.email t@fixture.test; git -C "$R" config user.name t; git -C "$R" config commit.gpgsign false
cat > "$R/docs/verification-map/index/tail.md" <<'MD'
## Generated files

| Path | Regenerate with |
|---|---|
| `catalog/state-paths.json` | `bin/state-paths-build.sh --write` |
| `cron/rendered/*.cron` | `bin/render-cron.sh --write` |
MD
printf '%s merge=union\nassets/logo.bin merge=binary\n' "$UNI" > "$R/.gitattributes"
git -C "$R" add -A && git -C "$R" commit -qm fixture || bad "fixture repo"

# ============================== U. the lib ==============================
LIB="$DIR/bin/lib/automerge-paths.sh"
lib() { env HARNESS="$DIR" bash -c '. "$1" || exit 90; shift; eval "$*"' _ "$LIB" "$@"; }
for p in "$GEN" "$UNI" "$GLOB"; do
  lib "amp_is_automerge '$R' '$p'" && ok || bad "U1: '$p' must be an auto-merge path"
done
for p in $CODE $NEG; do
  lib "amp_is_automerge '$R' '$p'" && bad "U2: '$p' must NOT be an auto-merge path" || ok
done
lib "amp_is_automerge '$T/no-such-repo' '$GEN'" && bad "U3: no repo dir must fail open to 'not auto-merge'" || ok
out=$(printf '%s\n' "$CODE" "$GEN" "$UNI" "$GLOB" catalog/state-paths.jsonx | lib "amp_filter '$R'")
[ "$out" = "$(printf '%s\n' "$CODE" catalog/state-paths.jsonx)" ] && ok || bad "U4: amp_filter must keep only the non-auto-merge paths, got [$out]"
out=$(printf '%s\n' "$CODE" "$GEN" | lib "amp_filter '$T/no-such-repo'")
[ "$out" = "$(printf '%s\n' "$CODE" "$GEN")" ] && ok || bad "U5: amp_filter with no repo must pass every path, got [$out]"
# the lib has no /root/harness default (D43)
grep -q '/root/harness' "$LIB" && bad "U5: bin/lib/automerge-paths.sh must not name /root/harness" || ok

# ============================== C. conflict-check.sh ==============================
CC="$T/cc"
mkdir -p "$CC/bin/lib" "$CC/builds" "$CC/flags"
scratch_install_closure bin/conflict-check.sh "$CC" >/dev/null || bad "closure install: bin/conflict-check.sh"
[ -f "$CC/bin/lib/automerge-paths.sh" ] && ok || bad "C0: bin/conflict-check.sh must source bin/lib/automerge-paths.sh (closure)"
ccb() { local d="$CC/builds/acme-$1"; shift; scratch_rm "$d"; mkdir -p "$d"; printf '%s\n' "$@" > "$d/planned-files.txt"; }
ccr() { # ccr <script> [repo] -> CC_RC CC_OUT for candidate a vs other b
  CC_OUT=$(env LANE_GATE_DISABLE=1 HARNESS="$CC" PLAN_OVERLAP_REPO="${2:-$R}" bash "$1" acme "$CC/builds/acme-a"); CC_RC=$?
}
for p in "$GEN" "$UNI" "$GLOB"; do
  ccb a "$p" src/a.ts; ccb b "$p" src/b.ts
  ccr "$CC/bin/conflict-check.sh"
  [ "$CC_RC" = 0 ] && [ -z "$CC_OUT" ] && ok || bad "C1: two builds sharing only $p must be disjoint, rc=$CC_RC out=[$CC_OUT]"
done
ccb a "$CODE" "$UNI"; ccb b "$UNI" "$CODE"
ccr "$CC/bin/conflict-check.sh"
[ "$CC_RC" = 1 ] && [ "$CC_OUT" = "CONFLICT with acme-b: $CODE ~ $CODE" ] && ok \
  || bad "C2: a shared code file must still conflict on it, rc=$CC_RC out=[$CC_OUT]"
for p in $NEG; do
  ccb a "$p"; ccb b "$p"
  ccr "$CC/bin/conflict-check.sh"
  [ "$CC_RC" = 1 ] && ok || bad "C3: '$p' on both sides must still conflict, rc=$CC_RC out=[$CC_OUT]"
done
ccb a "$GEN"; ccb b "$GEN"
ccr "$CC/bin/conflict-check.sh" "$T/no-such-repo"
[ "$CC_RC" = 1 ] && ok || bad "C4: with no target repo the old rule stands (fail-open = defer as before), rc=$CC_RC"

# ============================== P. plan-overlap.sh ==============================
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
mkbox() { # mkbox [plan-overlap.sh to install]
  scratch_rm "$W"
  mkdir -p "$W/bin/lib" "$W/env" "$W/flags" "$W/logs" "$W/builds" "$W/state/claims/acme"
  cp "$T/jobs-client.stub.sh" "$W/bin/jobs-client.sh"
  [ -n "${1:-}" ] && cp "$1" "$W/bin/plan-overlap.sh"
  scratch_install_closure bin/plan-overlap.sh "$W" >/dev/null || bad "mkbox: closure of bin/plan-overlap.sh"
  scratch_install_closure bin/touch-files.sh "$W" >/dev/null || bad "mkbox: closure of bin/touch-files.sh"
  scratch_install_closure bin/planned-files.sh "$W" >/dev/null || bad "mkbox: closure of bin/planned-files.sh"
  scratch_install_closure bin/lib/jobs/jobs.sh "$W" >/dev/null || bad "mkbox: closure of bin/lib/jobs/jobs.sh"
  printf 'acme  example-org/acme   -  -  0 local -\n' > "$W/fleet.conf"
}
bdir() { echo "$W/builds/acme-$1-20261112040000"; }
build() { # build <KEY> <file>... -> a live build dir that declares exactly those files
  local K="$1" D f; shift; D=$(bdir "$K")
  scratch_rm "$D"; mkdir -p "$D"
  { printf '# Plan %s\n## Files to touch\n' "$K"; for f in "$@"; do printf -- '- `%s` (Modified)\n' "$f"; done
    printf '\n## Tasks\nEdit them.\n'; } > "$D/plan.md"
  printf '{"key":"%s"}\n' "$K" > "$D/ticket-meta.json"
  bash "$W/bin/planned-files.sh" "$D"
  env HARNESS="$W" bash "$W/bin/touch-files.sh" "$D" acme
}
preset() { scratch_rm "$W/builds"; scratch_rm "$W/state"; scratch_rm "$W/logs"; mkdir -p "$W/builds" "$W/state/claims/acme" "$W/logs"; }
po() { # po <KEY> -> RC OUT
  OUT=$(env LANE_GATE_DISABLE=1 HARNESS="$W" PLAN_OVERLAP_REPO="$R" bash "$W/bin/plan-overlap.sh" acme "$(bdir "$1")" 2>"$T/err.txt")
  RC=$?
}
mkbox
[ -f "$W/bin/lib/automerge-paths.sh" ] && ok || bad "P0: bin/plan-overlap.sh must source bin/lib/automerge-paths.sh (closure)"
p1() { preset; build TK-1 "$UNI" src/a.ts; build TK-2 "$UNI" src/b.ts; }
p1
grep -qxF "$UNI" "$(bdir TK-1)/touch-files.txt" && ok || bad "P1 fixture: touch-files.txt must list $UNI"
po TK-1
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "P1: two plans sharing only the union path $UNI must not defer, rc=$RC out=[$OUT]"
preset; build TK-1 "$GEN" src/a.ts; build TK-2 "$GEN" src/b.ts; po TK-1
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "P2: two plans sharing only the generated path $GEN must not defer, rc=$RC out=[$OUT]"
preset; build TK-1 "$CODE" "$UNI"; build TK-2 "$CODE" "$UNI"; po TK-1
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER TK-1 vs TK-2 files=[$CODE,$CODE]" ] && ok \
  || bad "P3: a shared code file must defer on it alone, rc=$RC out=[$OUT]"
preset; build TK-1 assets/logo.bin; build TK-2 assets/logo.bin; po TK-1
[ "$RC" = 1 ] && ok || bad "P3: a merge=binary path must still defer, rc=$RC out=[$OUT]"

# ============================== S. plan-sibling.sh ==============================
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
  jq -n --arg b "$(sbody 4975)" '{key:"BH-5001",body:$b}' > "$B/ticket-meta.json"; }
sreset() {
  scratch_rm "$H/fx"; scratch_rm "$H/logs"; scratch_rm "$H/state"; mkdir -p "$H/fx" "$H/logs"
  printf '[]\n' > "$H/fx/pulls.json"
  jq -nc --arg b "$(sbody 4975)" '[{number:5000,title:"s",body:$b,state:"open"},{number:5001,title:"s",body:$b,state:"open"}]' > "$H/fx/issues.json"
}
spull() { local n="$1" ref="$2" sha="$3"; shift 3
  jq -c --argjson n "$n" --arg r "$ref" --arg s "$sha" '. + [{number:$n,state:"open",head:{ref:$r,sha:$s}}]' "$H/fx/pulls.json" > "$H/fx/p.tmp" \
    && mv "$H/fx/p.tmp" "$H/fx/pulls.json"
  printf '%s\n' "$@" | jq -R . | jq -sc 'map({filename:.,status:"modified"})' > "$H/fx/files.$n.json"; }
ps() { local m="$1"; shift
  OUT=$(env LANE_GATE_DISABLE=1 PATH="$T/stub:$PATH" FLEET_CONF="$H/fleet.conf" HARNESS="$H" PLAN_OVERLAP_REPO="$R" "$@" \
        bash "$H/bin/plan-sibling.sh" "$m" cromford "$B" 2>"$T/err"); RC=$?; }
SHA1=1111111111111111111111111111111111111111
sreset; smkb "$UNI" bin/mine.sh; spull 900 ticket/bh-5000 "$SHA1" "$UNI" bin/theirs.sh
ps check
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S1: a sibling PR sharing only the union path must not defer, rc=$RC out=[$OUT] err=[$(cat "$T/err")]"
sreset; smkb "$CODE" "$UNI"; spull 900 ticket/bh-5000 "$SHA1" "$CODE" "$UNI"
ps check
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER BH-5001 vs BH-5000 files=[$CODE,$CODE]" ] && ok \
  || bad "S2: a shared code file must defer on it alone, rc=$RC out=[$OUT]"

# ============================== G. overlap-guard.sh ==============================
GH="$T/g"
mkdir -p "$GH/bin/lib" "$GH/logs" "$GH/flags" "$GH/state" "$GH/plans" "$GH/builds" "$GH/env" "$GH/locks" "$T/fakebin"
scratch_install_closure bin/overlap-guard.sh "$GH" >/dev/null || bad "closure install: bin/overlap-guard.sh"
for s in bin/fleet-conf.sh bin/planned-files.sh; do [ -e "$GH/$s" ] || cp "$DIR/$s" "$GH/$s"; done
scratch_install_closure bin/lib/gh-pr-list.sh "$GH" >/dev/null || bad "closure install: bin/lib/gh-pr-list.sh"
[ -f "$GH/bin/lib/automerge-paths.sh" ] && ok || bad "G0: bin/overlap-guard.sh must source bin/lib/automerge-paths.sh (closure)"
printf 'proj example-org/proj https://proj.example /api/board 0 local -\n' > "$GH/fleet.conf"
printf '_jobs_req() { cat "%s"; }\n' "$T/ledger.json" > "$GH/bin/jobs-client.sh"
echo '{"jobs":[{"kind":"build","ticket_id":"AB-2"}]}' > "$T/ledger.json"
cat > "$T/fakebin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  *"/pulls?"*|*"/files"*) printf 'HTTP/2.0 200\r\n\r\n[]\n' ;;
  *"pr list"*) echo '[]' ;;
  *) echo '' ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
setplan() { local k="$1"; shift; mkdir -p "$GH/plans/proj-$k"; printf '%s\n' "$@" > "$GH/plans/proj-$k/planned-files.txt"; }
gr() { # gr <script> -> RC OUT
  scratch_rm "$GH/state/overlap-guard"
  OUT=$(env LANE_GATE_DISABLE=1 HARNESS="$GH" FLEET_CONF="$GH/fleet.conf" PATH="$T/fakebin:$PATH" PLAN_OVERLAP_REPO="$R" \
        bash "$1" proj AB-1 2>/dev/null); RC=$?
}
for p in "$UNI" "$GEN"; do
  setplan AB-1 "$p" src/a.ts; setplan AB-2 "$p" src/b.ts
  gr "$GH/bin/overlap-guard.sh"
  [ "$RC" = 0 ] && grep -q '^LAUNCH AB-1' <<<"$OUT" && ok || bad "G1: a running sibling sharing only $p must LAUNCH, rc=$RC out=[$OUT]"
done
setplan AB-1 "$CODE" "$UNI"; setplan AB-2 "$CODE" "$UNI"
gr "$GH/bin/overlap-guard.sh"
[ "$RC" = 1 ] && grep -q "^DEFER AB-1 vs AB-2" <<<"$OUT" && ok || bad "G2: a shared code file must DEFER, rc=$RC out=[$OUT]"
setplan AB-1 catalog/state-paths.jsonx; setplan AB-2 catalog/state-paths.jsonx
gr "$GH/bin/overlap-guard.sh"
[ "$RC" = 1 ] && ok || bad "G3: a near-miss of a generated path must DEFER, rc=$RC out=[$OUT]"

# ============================== M. mutations ==============================
# M1 conflict-check without the auto-merge filter -> C1 (union) red
sed 's/amp_filter "\$AMP_REPO"/cat/g' "$DIR/bin/conflict-check.sh" > "$CC/bin/cc-m1.sh"
cmp -s "$CC/bin/cc-m1.sh" "$DIR/bin/conflict-check.sh" && bad "M1: the mutant changed nothing"
ccb a "$UNI"; ccb b "$UNI"; ccr "$CC/bin/cc-m1.sh"
[ "$CC_RC" = 1 ] && ok || bad "M1: conflict-check.sh without the filter must conflict on $UNI (else C1 proves nothing), rc=$CC_RC"
# M2 plan-overlap's fragment_safe without the amp test -> P1 red
sed '/amp_is_automerge "\$REPO_DIR"/d' "$DIR/bin/plan-overlap.sh" > "$T/po-m2.sh"
cmp -s "$T/po-m2.sh" "$DIR/bin/plan-overlap.sh" && bad "M2: the mutant changed nothing"
mkbox "$T/po-m2.sh"; p1; po TK-1
[ "$RC" = 1 ] && ok || bad "M2: plan-overlap.sh without the amp test must defer on $UNI, rc=$RC"
# M3 overlap-guard's prune without the amp filter -> G1 red
sed 's/amp_filter "\$AMP_REPO"/cat/g' "$DIR/bin/overlap-guard.sh" > "$GH/bin/og-m3.sh"
cmp -s "$GH/bin/og-m3.sh" "$DIR/bin/overlap-guard.sh" && bad "M3: the mutant changed nothing"
setplan AB-1 "$UNI" src/a.ts; setplan AB-2 "$UNI" src/b.ts
gr "$GH/bin/og-m3.sh"
[ "$RC" = 1 ] && ok || bad "M3: overlap-guard.sh without the filter must DEFER on $UNI, rc=$RC out=[$OUT]"

echo "overlap-automerge-paths.bh-9426: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
