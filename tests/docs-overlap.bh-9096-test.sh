#!/bin/bash
# tests/docs-overlap.bh-9096-test.sh — a docs file (`*.md` at any depth) never
# causes an overlap defer, in any overlap path; code files keep their rule
# (BH-9096).
#
# The REAL scripts run in scratch harnesses. No network, no gh, no LLM.
#   U1-U7 bin/lib/docs-overlap.sh: path, pair, drop, and the exemption read
#         from the OVERLAP_IGNORE knob (on when the list holds a `*.md` token)
#   P1-P6 bin/plan-overlap.sh: two local builds sharing docs/UI.md -> rc 0 and
#         `docs-only`; docs/a/b/c.md -> rc 0; src/lib/backstage-nav.ts -> defer;
#         both -> defer on the .ts only; lib absent -> docs/UI.md defers (old
#         box); OVERLAP_IGNORE=package.json -> docs/UI.md defers again
#   M0/M1 main's plan-overlap.sh, and a copy without the docs_overlap_pair line,
#         turn P1 red (the cause the ticket asks for)
#   S1-S4 bin/plan-sibling.sh check (sibling PR files) and inflight (hotset)
#   C1-C5 bin/conflict-check.sh; M2 a copy without skipmd turns C1 red
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 missing — skipping"; exit 0; }

NAV=src/lib/backstage-nav.ts
LIB="$DIR/bin/lib/docs-overlap.sh"

# ============================== U. the lib ==============================
# lib <cmd> — run <cmd> in a clean shell with the lib sourced and a scratch
# harness (no settings row, no flags/scheduler.conf), so the live box never
# answers. OVERLAP_IGNORE is unset unless the caller sets it.
unset OVERLAP_IGNORE
mkdir -p "$T/uh/flags"
lib() { env HARNESS="$T/uh" LANE_GATE_DISABLE=1 bash -c '. "$1" || exit 90; shift; eval "$*"' _ "$LIB" "$@"; }

# U1 docs paths, at any depth
for p in docs/UI.md docs/a/b/c.md CLAUDE.md docs/x.md/; do
  lib "docs_overlap_path '$p'" && ok || bad "U1: '$p' must be a docs path"
done
# U2 near misses stay code
for p in docs/UI.mdx docs/UI.MD README.md.ts src/md docs .md; do
  lib "docs_overlap_path '$p'" && bad "U2: '$p' must NOT be a docs path" || ok
done
# U3 the either-side pair rule
lib "docs_overlap_pair 'docs/UI.md ~ docs/UI.md'" && ok || bad "U3: docs/UI.md ~ docs/UI.md must be docs-safe"
lib "docs_overlap_pair 'docs ~ docs/UI.md'" && ok || bad "U3: docs ~ docs/UI.md must be docs-safe"
lib "docs_overlap_pair 'docs ~ docs/nav.ts'" && bad "U3: docs ~ docs/nav.ts must NOT be docs-safe" || ok
lib "docs_overlap_pair '$NAV ~ $NAV'" && bad "U3: $NAV must NOT be docs-safe" || ok
# U4 drop
out=$(printf 'src/a.ts\ndocs/UI.md\ndocs/a/b/c.md\ndocs/UI.mdx\n' | lib docs_overlap_drop)
[ "$out" = "$(printf 'src/a.ts\ndocs/UI.mdx')" ] && ok || bad "U4: drop must keep only code paths, got [$out]"
# U5 no env, no conf row, no flags/scheduler.conf -> the default list -> on
lib "docs_overlap_on" && ok || bad "U5: the default OVERLAP_IGNORE list holds *.md, so the exemption must be on"
# U6 an override without *.md turns it off: env, and flags/scheduler.conf
OVERLAP_IGNORE=package.json lib "docs_overlap_on" && bad "U6: OVERLAP_IGNORE=package.json must turn the exemption off" || ok
out=$(printf 'docs/UI.md\n' | OVERLAP_IGNORE=package.json lib docs_overlap_drop)
[ "$out" = docs/UI.md ] && ok || bad "U6: drop must pass everything when off, got [$out]"
OVERLAP_IGNORE=package.json lib "docs_overlap_pair 'docs/UI.md ~ docs/UI.md'" && bad "U6: pair must be a collision when off" || ok
printf 'OVERLAP_IGNORE=package.json package-lock.json\n' > "$T/uh/flags/scheduler.conf"
lib "docs_overlap_on" && bad "U6: flags/scheduler.conf without *.md must turn the exemption off" || ok
printf 'OVERLAP_IGNORE="package.json *.md"\n' > "$T/uh/flags/scheduler.conf"
lib "docs_overlap_on" && ok || bad "U6: flags/scheduler.conf with *.md must keep the exemption on"
rm -f "$T/uh/flags/scheduler.conf"
# U7 the token is matched as text: a narrower glob is not the bare token; a
# CWD full of .md files must not glob it
OVERLAP_IGNORE='docs/*.md' lib "docs_overlap_on" && bad "U7: 'docs/*.md' is not the *.md token, must be off" || ok
OVERLAP_IGNORE='*.md' lib "docs_overlap_on" && ok || bad "U7: '*.md' alone must be on"
mkdir -p "$T/mdcwd"; : > "$T/mdcwd/a.md"
(cd "$T/mdcwd" && OVERLAP_IGNORE='x.json *.md' lib "docs_overlap_on") && ok || bad "U7: *.md must not glob the CWD"
[ ! -e "$DIR/catalog/switches.d/docs-overlap-off.json" ] && ok || bad "U7: the knob is the off switch; docs-overlap-off must not be registered"

# ============================== P. plan-overlap.sh ==============================
W="$T/W"
STUB="$T/jobs-client.stub.sh"
cat > "$STUB" <<SH
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
  cp "$STUB" "$W/bin/jobs-client.sh"
  [ -n "${1:-}" ] && cp "$1" "$W/bin/plan-overlap.sh"
  scratch_install_closure bin/plan-overlap.sh "$W" >/dev/null || bad "mkbox: closure of bin/plan-overlap.sh"
  scratch_install_closure bin/touch-files.sh "$W" >/dev/null || bad "mkbox: closure of bin/touch-files.sh"
  scratch_install_closure bin/planned-files.sh "$W" >/dev/null || bad "mkbox: closure of bin/planned-files.sh"
  scratch_install_closure bin/lib/jobs/jobs.sh "$W" >/dev/null || bad "mkbox: closure of bin/lib/jobs/jobs.sh"
  printf 'acme  example-org/acme   -  -  0 local -\n' > "$W/fleet.conf"
}
bdir() { echo "$W/builds/acme-$1-20261105040000"; }
build() { # build <KEY> <file>... -> a live build dir that declares exactly those files
  local K="$1" D f; shift; D=$(bdir "$K")
  scratch_rm "$D"; mkdir -p "$D"
  { printf '# Plan %s\n## Files to touch\n' "$K"; for f in "$@"; do printf -- '- `%s` (Modified)\n' "$f"; done
    printf '\n## Tasks\nEdit them.\n'; } > "$D/plan.md"
  printf '{"key":"%s"}\n' "$K" > "$D/ticket-meta.json"
  bash "$W/bin/planned-files.sh" "$D"
  env HARNESS="$W" bash "$W/bin/touch-files.sh" "$D" acme
}
reset() { scratch_rm "$W/builds"; scratch_rm "$W/state"; scratch_rm "$W/logs"; mkdir -p "$W/builds" "$W/state/claims/acme" "$W/logs"; }
po() { # po <KEY> [env...] -> sets RC OUT ERR
  local K="$1"; shift
  OUT=$(env LANE_GATE_DISABLE=1 HARNESS="$W" "$@" bash "$W/bin/plan-overlap.sh" acme "$(bdir "$K")" 2>"$T/err.txt")
  RC=$?; ERR=$(cat "$T/err.txt")
}
p1() { reset; build TK-1 docs/UI.md src/a.ts; build TK-2 docs/UI.md src/b.ts; }

mkbox
[ -f "$W/bin/lib/docs-overlap.sh" ] && ok || bad "P0: bin/plan-overlap.sh must source bin/lib/docs-overlap.sh (closure)"
p1
grep -qxF docs/UI.md "$(bdir TK-1)/touch-files.txt" && grep -qxF docs/UI.md "$(bdir TK-2)/touch-files.txt" && ok \
  || bad "P1 fixture: both touch-files.txt must list docs/UI.md"
po TK-1
[ "$RC" = 0 ] && ok || bad "P1: two plans sharing only docs/UI.md must not defer, rc=$RC out=[$OUT]"
case "$OUT" in *OVERLAP_DEFER*) bad "P1: stdout must carry no OVERLAP_DEFER: [$OUT]" ;; *) ok ;; esac
case "$ERR" in *"PLAN_HOTSPOT TK-1 choice=build vs TK-2 docs-only files=[docs/UI.md,docs/UI.md]"*) ok ;;
  *) bad "P1: stderr must log the docs-only build line, got [$ERR]" ;; esac

# P2 a deep docs path
reset; build TK-1 docs/a/b/c.md src/a.ts; build TK-2 docs/a/b/c.md src/b.ts
po TK-1
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "P2: docs/a/b/c.md must not defer, rc=$RC out=[$OUT]"

# P3 a code file still defers, line unchanged
reset; build TK-1 "$NAV" src/a.ts; build TK-2 "$NAV" src/b.ts
po TK-1
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER TK-1 vs TK-2 files=[$NAV,$NAV]" ] && ok \
  || bad "P3: a shared code file must defer exactly as before, rc=$RC out=[$OUT]"

# P4 a mixed set defers on the code file only, and never says docs-only
reset; build TK-1 docs/UI.md "$NAV"; build TK-2 docs/UI.md "$NAV"
po TK-1
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER TK-1 vs TK-2 files=[$NAV,$NAV]" ] && ok \
  || bad "P4: a mixed set must defer on $NAV only, rc=$RC out=[$OUT]"
case "$ERR" in *docs-only*) bad "P4: a mixed set must not log docs-only: [$ERR]" ;; *) ok ;; esac
# P4b docs + a fragment dir: both safe, still builds
reset; build TK-1 docs/UI.md docs/verification-map/entries; build TK-2 docs/UI.md docs/verification-map/entries
po TK-1
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "P4b: docs + fragment pairs must build, rc=$RC out=[$OUT]"
# P4c near misses stay collisions
for f in docs/UI.mdx docs/UI.MD README.md.ts; do
  reset; build TK-1 "$f"; build TK-2 "$f"
  po TK-1
  [ "$RC" = 1 ] && ok || bad "P4c: '$f' is not a docs path and must defer, rc=$RC out=[$OUT]"
done

# P5 the lib absent from the box (an old box) -> the old defer, no error
mkbox; rm -f "$W/bin/lib/docs-overlap.sh"; p1; po TK-1
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER TK-1 vs TK-2 files=[docs/UI.md,docs/UI.md]" ] && ok \
  || bad "P5: with no bin/lib/docs-overlap.sh, docs/UI.md must defer as before, rc=$RC out=[$OUT]"
mkbox
# P6 OVERLAP_IGNORE without *.md restores the old defer (env and flags/scheduler.conf)
p1; po TK-1 OVERLAP_IGNORE=package.json
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER TK-1 vs TK-2 files=[docs/UI.md,docs/UI.md]" ] && ok \
  || bad "P6: OVERLAP_IGNORE=package.json must restore the docs/UI.md defer, rc=$RC out=[$OUT]"
p1; printf 'OVERLAP_IGNORE=package.json\n' > "$W/flags/scheduler.conf"; po TK-1
[ "$RC" = 1 ] && ok || bad "P6: flags/scheduler.conf without *.md must restore the docs/UI.md defer, rc=$RC out=[$OUT]"
rm -f "$W/flags/scheduler.conf"

# M0 the base of this ticket (b504945d5, pinned so main moving on does not
# change the test) is the cause: it defers on docs/UI.md. Skipped when the
# clone does not hold that commit.
if git -C "$DIR" show b504945d5:bin/plan-overlap.sh > "$T/po-main.sh" 2>/dev/null \
   && ! grep -q docs_overlap "$T/po-main.sh"; then
  mkbox "$T/po-main.sh"; p1; po TK-1
  [ "$RC" = 1 ] && ok || bad "M0: main's plan-overlap.sh was expected to defer on docs/UI.md, rc=$RC out=[$OUT]"
fi
# M1 the docs skip removed -> P1 red
sed '/docs_overlap_pair "\$pr"/d' "$DIR/bin/plan-overlap.sh" > "$T/po-m1.sh"
cmp -s "$T/po-m1.sh" "$DIR/bin/plan-overlap.sh" && bad "M1: the mutant removed nothing (no docs_overlap_pair \"\$pr\" line)"
mkbox "$T/po-m1.sh"; p1; po TK-1
[ "$RC" = 1 ] && ok || bad "M1: plan-overlap.sh without the docs skip must defer on docs/UI.md (the test would not catch it), rc=$RC"
mkbox

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
[ -f "$H/bin/lib/docs-overlap.sh" ] && ok || bad "S0: bin/plan-sibling.sh must source bin/lib/docs-overlap.sh (closure)"
R="$T/repo"; mkdir -p "$R"
git -C "$R" init -q && git -C "$R" -c user.email=t@t -c user.name=t commit -q --allow-empty -m fixture || bad "fixture repo"
B="$T/b"
sbody() { printf 'Scope for this slice.\n\n---\nPart of #%s\nOrder: 2 of 3\n' "$1"; }
smkb() { # smkb <planned file>... — child BH-5001 of #4975
  scratch_rm "$B"; mkdir -p "$B"
  printf '# plan\n' > "$B/plan.md"
  printf '%s\n' "$@" > "$B/planned-files.txt"
  jq -n --arg b "$(sbody 4975)" '{key:"BH-5001",body:$b}' > "$B/ticket-meta.json"
}
sreset() {
  scratch_rm "$H/fx"; scratch_rm "$H/logs"; scratch_rm "$H/state"; mkdir -p "$H/fx" "$H/logs"
  printf '[]\n' > "$H/fx/pulls.json"
  jq -nc --arg b "$(sbody 4975)" '[{number:5000,title:"s",body:$b,state:"open"},{number:5001,title:"s",body:$b,state:"open"}]' > "$H/fx/issues.json"
}
spull() { # spull <pr> <ref> <sha> <file>...
  local n="$1" ref="$2" sha="$3"; shift 3
  jq -c --argjson n "$n" --arg r "$ref" --arg s "$sha" '. + [{number:$n,state:"open",head:{ref:$r,sha:$s}}]' "$H/fx/pulls.json" > "$H/fx/p.tmp" \
    && mv "$H/fx/p.tmp" "$H/fx/pulls.json"
  printf '%s\n' "$@" | jq -R . | jq -sc 'map({filename:.,status:"modified"})' > "$H/fx/files.$n.json"
}
ps() { # ps <check|inflight> [env...]
  local m="$1"; shift
  OUT=$(env LANE_GATE_DISABLE=1 PATH="$T/stub:$PATH" FLEET_CONF="$H/fleet.conf" HARNESS="$H" PLAN_OVERLAP_REPO="$R" "$@" \
        bash "$H/bin/plan-sibling.sh" "$m" cromford "$B" 2>"$T/err")
  RC=$?; ERR=$(cat "$T/err")
}
SHA1=1111111111111111111111111111111111111111

# S1 sibling PR shares only docs/UI.md -> build, docs-only
sreset; smkb docs/UI.md bin/mine.sh; spull 900 ticket/bh-5000 "$SHA1" docs/UI.md bin/theirs.sh
ps check
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S1: a sibling PR sharing only docs/UI.md must not defer, rc=$RC out=[$OUT] err=[$ERR]"
case "$ERR" in *"PLAN_SIBLING BH-5001 choice=build vs BH-5000 pr=#900 docs-only"*) ok ;; *) bad "S1: stderr lacks the docs-only line: [$ERR]" ;; esac
# S1 with an override without *.md -> today's defer
ps check OVERLAP_IGNORE=package.json
[ "$RC" = 1 ] && ok || bad "S1: OVERLAP_IGNORE=package.json must restore the defer, rc=$RC out=[$OUT]"
# S2 a code file still defers, line unchanged
sreset; smkb "$NAV" docs/UI.md; spull 900 ticket/bh-5000 "$SHA1" "$NAV" docs/UI.md
ps check
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER BH-5001 vs BH-5000 files=[$NAV,$NAV]" ] && ok \
  || bad "S2: a shared code file must defer on it alone, rc=$RC out=[$OUT]"
# S3 deep docs path
sreset; smkb docs/a/b/c.md; spull 900 ticket/bh-5000 "$SHA1" docs/a/b/c.md
ps check
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S3: docs/a/b/c.md must not defer, rc=$RC out=[$OUT]"
# S4 inflight: a hotset of only docs/UI.md -> hot=0, build
sreset; smkb docs/UI.md bin/mine.sh
printf 'docs/UI.md\n' > "$B/.hotspots.txt"
printf '2026-11-05T00:00:00Z [cromford/BH-5001] HOTSPOT_CLAIM n=1 source=rows\n' > "$B/pipeline.log"
spull 7000 ticket/bh-6000 "$SHA1" docs/UI.md
ps inflight
[ "$RC" = 0 ] && [ -z "$OUT" ] && ok || bad "S4: inflight on a docs-only hotset must build, rc=$RC out=[$OUT]"
case "$ERR" in *"PLAN_INFLIGHT BH-5001 choice=build hot=0"*) ok ;; *) bad "S4: stderr must say hot=0: [$ERR]" ;; esac
# S4b control: the same fixture on a hot code file defers
sreset; smkb "$NAV"; printf '%s\n' "$NAV" > "$B/.hotspots.txt"
printf '2026-11-05T00:00:00Z [cromford/BH-5001] HOTSPOT_CLAIM n=1 source=rows\n' > "$B/pipeline.log"
spull 7000 ticket/bh-6000 "$SHA1" "$NAV"
ps inflight
[ "$RC" = 1 ] && [ "$OUT" = "OVERLAP_DEFER BH-5001 vs BH-6000 files=[$NAV,$NAV]" ] && ok \
  || bad "S4b: inflight on a hot code file must defer, rc=$RC out=[$OUT]"

# ============================== C. conflict-check.sh ==============================
CC="$T/cc"
mkdir -p "$CC/bin/lib" "$CC/builds" "$CC/flags"
scratch_install_closure bin/conflict-check.sh "$CC" >/dev/null || bad "closure install: bin/conflict-check.sh"
[ -f "$CC/bin/lib/docs-overlap.sh" ] && ok || bad "C0: bin/conflict-check.sh must source bin/lib/docs-overlap.sh (closure)"
ccb() { # ccb <name> <file>... -> a live build dir with planned-files.txt
  local d="$CC/builds/acme-$1"; shift
  scratch_rm "$d"; mkdir -p "$d"; printf '%s\n' "$@" > "$d/planned-files.txt"
}
ccr() { # ccr <script> [env...] -> CC_RC CC_OUT for candidate a vs other b
  local s="$1"; shift
  CC_OUT=$(env LANE_GATE_DISABLE=1 HARNESS="$CC" LANE_GATE_DISABLE=1 "$@" bash "$s" acme "$CC/builds/acme-a"); CC_RC=$?
}
ccb a docs/UI.md src/a.ts; ccb b docs/UI.md src/b.ts
ccr "$CC/bin/conflict-check.sh"
[ "$CC_RC" = 0 ] && [ -z "$CC_OUT" ] && ok || bad "C1: docs/UI.md only must be disjoint, rc=$CC_RC out=[$CC_OUT]"
ccb a docs/a/b/c.md; ccb b docs/a/b/c.md
ccr "$CC/bin/conflict-check.sh"
[ "$CC_RC" = 0 ] && ok || bad "C2: docs/a/b/c.md must be disjoint, rc=$CC_RC out=[$CC_OUT]"
ccb a "$NAV" docs/UI.md; ccb b docs/UI.md "$NAV"
ccr "$CC/bin/conflict-check.sh"
[ "$CC_RC" = 1 ] && [ "$CC_OUT" = "CONFLICT with acme-b: $NAV ~ $NAV" ] && ok \
  || bad "C3: a shared code file must conflict on it, rc=$CC_RC out=[$CC_OUT]"
ccb a docs; ccb b docs/nav.ts
ccr "$CC/bin/conflict-check.sh"
[ "$CC_RC" = 1 ] && ok || bad "C4: docs dir vs docs/nav.ts must still conflict, rc=$CC_RC out=[$CC_OUT]"
ccb a docs; ccb b docs/UI.md
ccr "$CC/bin/conflict-check.sh"
[ "$CC_RC" = 0 ] && ok || bad "C4: docs dir vs docs/UI.md must be disjoint, rc=$CC_RC out=[$CC_OUT]"
# C5 OVERLAP_IGNORE without *.md restores the conflict
ccb a docs/UI.md src/a.ts; ccb b docs/UI.md src/b.ts
ccr "$CC/bin/conflict-check.sh" OVERLAP_IGNORE=package.json
[ "$CC_RC" = 1 ] && [ "$CC_OUT" = "CONFLICT with acme-b: docs/UI.md ~ docs/UI.md" ] && ok \
  || bad "C5: OVERLAP_IGNORE=package.json must restore the conflict, rc=$CC_RC out=[$CC_OUT]"
# M2 the awk skip removed -> C1 red
sed 's/-v skipmd="\$SKIPMD"//' "$DIR/bin/conflict-check.sh" > "$CC/bin/cc-m2.sh"
cmp -s "$CC/bin/cc-m2.sh" "$DIR/bin/conflict-check.sh" && bad "M2: the mutant removed nothing"
ccb a docs/UI.md; ccb b docs/UI.md
ccr "$CC/bin/cc-m2.sh"
[ "$CC_RC" = 1 ] && ok || bad "M2: conflict-check.sh without the docs skip must conflict on docs/UI.md, rc=$CC_RC"

echo "docs-overlap.bh-9096: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
