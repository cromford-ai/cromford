#!/bin/bash
# tests/no-hardcoded-deployment.bh-4080-test.sh — BH-4080 (the ticket's
# tests/no-hardcoded-deployment-test.sh, named per ticket): no production code
# carries a literal of OUR deployment (GitHub org, box hostname, operator login
# or email, billing account, tailnet address, workers.dev subdomain) outside its
# one documented-default home, and that home is a registered knob.
#
# Drives the real entry points against mktemp trees and asserts on exit codes
# and output, never on source text:
#   L1-L8  bin/deployment-lint.sh (bin/config-inventory.py --deployment-lint)
#          on fixture trees: red on a hardcoded org/box, every family fires,
#          comments and neighbours stay quiet, the allowlist rules, the scope,
#          and the lint writes nothing.
#   G1     the same lint on THIS checkout is green, with no `pending` entry.
#   D1-D3  bin/lib/deployment.sh against catalog/lanes.d/_lib.deployment.json:
#          defaults equal the registry, an override wins, nothing is settable.
#   C1-C6  converted consumers read the knob: git identity, the jobs URL, the PR
#          author set, the fleet.conf slug (no row = no guess, no gh call), the
#          box fallback, the gh-app owners.
#   J1-J2  the console and worker defaults modules hold today's values, core.js
#          re-exports the worker's, and their node suites pass.
#   R1     the deployment report renders with every family and zero un-allowlisted
#          literals, `bin/config-inventory.sh --check` is green (two renders
#          identical), and nothing under docs/config-inventory is tracked: the
#          report is generated and git-ignored (BH-5518), never committed.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/no-hardcoded-deployment.bh-4080-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LINT="$DIR/bin/deployment-lint.sh"
LIB="$DIR/bin/lib/deployment.sh"
REG="$DIR/catalog/lanes.d/_lib.deployment.json"
FAMS="$DIR/catalog/deployment-literals.tsv"
PASS=0; FAIL=0
# Tailnet-shaped fixture addresses are assembled here, never written dotted:
# the share mirror's leakcheck refuses any 100.x dotted quad in the tree.
TIP=$(printf '100.%s.1.2' 70)          # inside 100.64/10
NIP_HI=$(printf '100.%s.1.1' 200)      # outside it, above
NIP_LO=$(printf '100.%s.255.1' 63)     # outside it, below
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# fixture <name> — a fresh tree with the scanned dirs; prints its path.
fixture() {
  local f="$T/fx-$1"
  scratch_rm "$f" || exit 1; mkdir -p "$f/bin" "$f/fly" "$f/cron" "$f/worker/jobs/src" "$f/console-ui/src" "$f/locks-worker/src"
  printf '%s\n' "$f"
}
lint() { bash "$LINT" "$@"; }

# ── L1: a hardcoded org is red, named by file:line and family ────────────────
F=$(fixture l1)
printf '#!/bin/bash\n# header\nREPO=example-org/widget\n' > "$F/bin/x.sh"
out=$(lint --root "$F" --allowlist /dev/null); rc=$?
[ "$rc" = 1 ] && ok || bad "L1 hardcoded org: rc=$rc, want 1"
grep -q "^bin/x.sh:3	gh-org	" <<<"$out" && ok || bad "L1 output does not name bin/x.sh:3 gh-org: $out"

# ── L2: a hardcoded box is red ───────────────────────────────────────────────
F=$(fixture l2)
printf 'ssh root@box-foo true\n' > "$F/bin/y.sh"
out=$(lint --root "$F" --allowlist /dev/null); rc=$?
[ "$rc" = 1 ] && ok || bad "L2 hardcoded box: rc=$rc, want 1"
grep -q "^bin/y.sh:1	box-host	" <<<"$out" && ok || bad "L2 output does not name box-host: $out"

# ── L3: every family in the catalog fires, exactly once per line ─────────────
F=$(fixture l3)
cat > "$F/bin/all.sh" <<'EOF'
a=example-org/cromford
b=example-org
c=operator
d=https://harness-jobs.operator.workers.dev
e=ops@example.com
f=operator@example.com
g=box-project-4-1
h=@TIP@
i=box.tail1234.ts.net
j=https://www.orgo.ai/api
EOF
sed -i "s/@TIP@/$TIP/" "$F/bin/all.sh"
out=$(lint --root "$F" --allowlist /dev/null); rc=$?
[ "$rc" = 1 ] && ok || bad "L3 rc=$rc, want 1"
i=0
for fam in harness-repo gh-org operator-login workers-subdomain operator-email billing-account box-host tailnet-ip tailnet-host orgo-host; do
  i=$((i+1))
  n=$(printf '%s\n' "$out" | grep -c "^bin/all.sh:$i	")
  [ "$n" = 1 ] || bad "L3 line $i: $n hits, want exactly 1 ($fam): $(printf '%s\n' "$out" | grep "^bin/all.sh:$i	")"
  grep -q "^bin/all.sh:$i	$fam	" <<<"$out" && ok || bad "L3 family $fam did not fire on line $i"
done
# every family the catalog declares is covered above (a new row needs a line here)
CATFAMS=$(grep -v '^#' "$FAMS" | grep -v '^$' | cut -f1 | sort | tr '\n' ' ')
[ "$CATFAMS" = "billing-account box-host gh-org harness-repo operator-email operator-login orgo-host tailnet-host tailnet-ip workers-subdomain " ] \
  && ok || bad "L3 catalog families changed without a fixture line: $CATFAMS"
# non-vacuity: an empty or missing families catalog cannot read as clean
: > "$T/empty.tsv"
lint --root "$F" --allowlist /dev/null --families "$T/empty.tsv" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "L3 empty families file: rc=$rc, want 2"
lint --root "$F" --allowlist /dev/null --families "$T/nope.tsv" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "L3 missing families file: rc=$rc, want 2"
lint --root "$F" --allowlist "$T/nope-allow.txt" >/dev/null 2>&1; rc=$?
[ "$rc" = 2 ] && ok || bad "L3 named allowlist that does not exist: rc=$rc, want 2"

# ── L4: comment lines are prose ──────────────────────────────────────────────
F=$(fixture l4)
printf '# example-org/cromford on box-hub, operator\n  # operator@example.com\n' > "$F/bin/c.sh"
printf '// example-org operator.workers.dev\n/* box-project-4-1\n * %s orgo.ai\n */\n' "$TIP" > "$F/console-ui/src/c.js"
out=$(lint --root "$F" --allowlist /dev/null); rc=$?
[ "$rc" = 0 ] && ok || bad "L4 comment-only literals: rc=$rc, want 0: $out"

# a shell case arm starts with `*` and is CODE, not a JS block-comment line
F=$(fixture l4b)
printf 'case "$p" in\n  *) SLUG=example-org/widget ;;\nesac\n' > "$F/bin/arm.sh"
out=$(lint --root "$F" --allowlist /dev/null); rc=$?
[ "$rc" = 1 ] && grep -q '^bin/arm.sh:2	gh-org	' <<<"$out" && ok || bad "L4 a shell *) case arm was read as a comment: rc=$rc $out"

# ── L5: neighbours that are not a family stay quiet ──────────────────────────
F=$(fixture l5)
cat > "$F/bin/n.sh" <<'EOF'
git -c user.name=box commit
ip=10.0.0.1
ip2=@NIP_HI@
ip3=@NIP_LO@
REPO=example-org/widget
x=operatorx
y=myoperator
z=notorgo.aix
EOF
sed -i "s/@NIP_HI@/$NIP_HI/; s/@NIP_LO@/$NIP_LO/" "$F/bin/n.sh"
out=$(lint --root "$F" --allowlist /dev/null); rc=$?
[ "$rc" = 0 ] && ok || bad "L5 neighbours: rc=$rc, want 0: $out"

# ── L6: the allowlist ────────────────────────────────────────────────────────
F=$(fixture l6)
printf 'REPO=example-org/widget\n' > "$F/bin/home.sh"
printf 'bin/home.sh  gh-org  the documented-default home\n' > "$T/allow-ok.txt"
out=$(lint --root "$F" --allowlist "$T/allow-ok.txt"); rc=$?
[ "$rc" = 0 ] && ok || bad "L6 allowlisted hit: rc=$rc, want 0: $out"
printf 'bin/home.sh  gh-org\n' > "$T/allow-noreason.txt"
out=$(lint --root "$F" --allowlist "$T/allow-noreason.txt"); rc=$?
[ "$rc" = 1 ] && ok || bad "L6 entry with no reason: rc=$rc, want 1"
grep -q '^allowlist:1: bin/home.sh: no reason' <<<"$out" && ok || bad "L6 no-reason problem line missing: $out"
printf 'bin/home.sh  gh-org,box-host  home of both\n' > "$T/allow-stale.txt"
out=$(lint --root "$F" --allowlist "$T/allow-stale.txt"); rc=$?
[ "$rc" = 1 ] && ok || bad "L6 stale family: rc=$rc, want 1"
grep -q 'bin/home.sh: stale, no box-host' <<<"$out" && ok || bad "L6 stale line missing: $out"
grep -q 'stale, no gh-org' <<<"$out" && bad "L6 the live family was reported stale: $out" || ok
printf 'bin/home.sh  gh-org  home\nbin/gone.sh  gh-org  removed\n' > "$T/allow-missing.txt"
out=$(lint --root "$F" --allowlist "$T/allow-missing.txt"); rc=$?
[ "$rc" = 1 ] && ok || bad "L6 missing path: rc=$rc, want 1"
grep -q 'bin/gone.sh: no such file' <<<"$out" && ok || bad "L6 missing-path line: $out"
printf 'bin/home.sh  gh-orgg  typo\n' > "$T/allow-unknown.txt"
lint --root "$F" --allowlist "$T/allow-unknown.txt" >/dev/null; rc=$?
[ "$rc" = 1 ] && ok || bad "L6 unknown family: rc=$rc, want 1"

# ── L7: scan scope — config and prose are out, every code dir is in ──────────
F=$(fixture l7)
mkdir -p "$F/docs" "$F/catalog" "$F/tests" "$F/locks-worker/.wrangler" "$F/console-ui/src/node_modules/p"
for p in docs/a.md catalog/b.json tests/c.sh fleet.conf locks-worker/.wrangler/x.js console-ui/src/node_modules/p/i.js bin/readme.txt; do
  printf 'x = "example-org/widget"\n' > "$F/$p"
done
out=$(lint --root "$F" --allowlist /dev/null); rc=$?
[ "$rc" = 0 ] && ok || bad "L7 out-of-scope files flagged: rc=$rc: $out"
for p in worker/jobs/src/a.js console-ui/src/b.js fly/c.sh cron/d.cron locks-worker/src/e.js bin/f.py bin/g.mjs; do
  G=$(fixture l7in); mkdir -p "$G/$(dirname "$p")"
  printf 'x = "example-org/widget"\n' > "$G/$p"
  lint --root "$G" --allowlist /dev/null >/dev/null; rc=$?
  [ "$rc" = 1 ] && ok || bad "L7 $p not scanned: rc=$rc, want 1"
done

# ── L8: the lint writes nothing ──────────────────────────────────────────────
F=$(fixture l8)
printf 'REPO=example-org/widget\n' > "$F/bin/x.py"
before=$(cd "$F" && find . -print0 | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum; find "$F" | sort | sha256sum)
lint --root "$F" --allowlist /dev/null >/dev/null
after=$(cd "$F" && find . -print0 | sort -z | xargs -0 sha256sum 2>/dev/null | sha256sum; find "$F" | sort | sha256sum)
[ "$before" = "$after" ] && ok || bad "L8 the lint changed the fixture tree"

# ── G1: green on this checkout after conversion ──────────────────────────────
out=$(lint --root "$DIR"); rc=$?
[ "$rc" = 0 ] && ok || bad "G1 deployment-lint on the repo: rc=$rc
$out"
ALLOW_CODE=$(grep -v '^\s*#' "$DIR/tests/no-hardcoded-deployment-allowlist.txt")
grep -qi 'pending' <<<"$ALLOW_CODE" && bad "G1 the allowlist still carries a pending entry" || ok

# ── D1-D3: the defaults home against its registry ────────────────────────────
[ -f "$LIB" ] && ok || bad "D1 no bin/lib/deployment.sh"
[ -f "$REG" ] && ok || bad "D1 no catalog/lanes.d/_lib.deployment.json"
if [ -f "$LIB" ] && [ -f "$REG" ]; then
  [ "$(jq -r '.libs[0].file' "$REG")" = "bin/lib/deployment.sh" ] && ok || bad "D1 registry file is not bin/lib/deployment.sh"
  REGKNOBS=$(jq -r '.libs[].knobs[].env' "$REG" | sort)
  [ "$(printf '%s\n' "$REGKNOBS" | wc -l)" -ge 10 ] && ok || bad "D1 registry has fewer knobs than the plan's ten"
  # every knob resolves to its documented default in an empty environment
  while IFS=$'\t' read -r env def; do
    got=$(env -i PATH="$PATH" bash -c '. "$1" || exit 9; printf "%s" "${!2-<unset>}"' _ "$LIB" "$env"); rc=$?
    [ "$rc" = 0 ] && [ "$got" = "$def" ] && ok || bad "D1 $env: sourced '$got' (rc $rc), registry default '$def'"
  done < <(jq -r '.libs[].knobs[]|[.env,(.default|tostring)]|@tsv' "$REG")
  # parity the other way: every knob the lib sets is registered
  LIBKNOBS=$(grep -oE '^: "\$\{[A-Z_]+:=' "$LIB" | sed -E 's/^: "\$\{//; s/:=$//' | sort)
  [ -n "$LIBKNOBS" ] && [ "$LIBKNOBS" = "$REGKNOBS" ] && ok || bad "D1 lib knobs and registry knobs differ:
lib: $(echo $LIBKNOBS)
reg: $(echo $REGKNOBS)"
  # D2: an operator's value wins, and the owner derives from the repo
  got=$(env -i PATH="$PATH" HARNESS_REPO=acme/h HARNESS_GIT_EMAIL=ops@acme.test bash -c \
    '. "$1"; printf "%s|%s|%s" "$HARNESS_REPO" "$HARNESS_GIT_EMAIL" "$HARNESS_GH_OWNER"' _ "$LIB")
  [ "$got" = "acme/h|ops@acme.test|acme" ] && ok || bad "D2 override: got '$got'"
  got=$(env -i PATH="$PATH" HARNESS_REPO=acme/h HARNESS_GH_OWNER=other bash -c '. "$1"; printf "%s" "$HARNESS_GH_OWNER"' _ "$LIB")
  [ "$got" = other ] && ok || bad "D2 an explicit HARNESS_GH_OWNER must beat the derivation: '$got'"
  # D3: an identity or a host is never writable from a page
  ns=$(jq -r '[.libs[].knobs[]|select(.settable != false)|.env]|join(" ")' "$REG")
  [ -z "$ns" ] && ok || bad "D3 settable deployment knobs: $ns"
fi

# ── C1: git identity ─────────────────────────────────────────────────────────
mkdir -p "$T/home-empty"
got=$(env -i PATH="$PATH" HOME="$T/home-empty" GIT_CONFIG_NOSYSTEM=1 HARNESS_GIT_EMAIL=ops@acme.test HARNESS_GIT_NAME=acme-ops \
  bash -c '. "$1" || exit 9; gi_resolve; printf "%s|%s" "$GI_NAME" "$GI_EMAIL"' _ "$DIR/bin/lib/git-identity.sh")
[ "$got" = "acme-ops|ops@acme.test" ] && ok || bad "C1 git identity override: '$got'"
got=$(env -i PATH="$PATH" HOME="$T/home-empty" GIT_CONFIG_NOSYSTEM=1 \
  bash -c '. "$1" || exit 9; gi_resolve; printf "%s|%s" "$GI_NAME" "$GI_EMAIL"' _ "$DIR/bin/lib/git-identity.sh")
[ "$got" = "operator|operator@example.com" ] && ok || bad "C1 git identity default changed: '$got'"

# ── C2: the jobs URL ─────────────────────────────────────────────────────────
got=$(env -i PATH="$PATH" HARNESS_WORKERS_SUBDOMAIN=acme bash -c '. "$1" || exit 9; printf "%s" "$JOBS_URL"' _ "$DIR/bin/lib/jobs/req.sh")
[ "$got" = "https://harness-jobs.acme.workers.dev" ] && ok || bad "C2 jobs URL from the subdomain knob: '$got'"
got=$(env -i PATH="$PATH" bash -c '. "$1" || exit 9; printf "%s" "$JOBS_URL"' _ "$DIR/bin/lib/jobs/req.sh")
[ "$got" = "https://harness-jobs.operator.workers.dev" ] && ok || bad "C2 jobs URL default changed: '$got'"
got=$(env -i PATH="$PATH" JOBS_URL= HARNESS_WORKERS_SUBDOMAIN=acme bash -c '. "$1" || exit 9; printf "[%s]" "$JOBS_URL"' _ "$DIR/bin/lib/jobs/req.sh")
[ "$got" = "[]" ] && ok || bad "C2 an explicitly empty JOBS_URL must stay empty: '$got'"

# ── C3: the PR author set ────────────────────────────────────────────────────
mkdir -p "$T/c3/env"
got=$(env -i PATH="$PATH" HARNESS="$T/c3" HARNESS_OPERATOR_LOGIN=acme-bot bash -c '. "$1" || exit 9; harness_pr_authors; harness_verdict_authors' _ "$DIR/bin/lib/gh-pr-list.sh")
case "$got" in "acme-bot "*app/cromford*$'\n'"acme-bot app/cromford"*) ok ;; *) bad "C3 authors with HARNESS_OPERATOR_LOGIN=acme-bot: '$got'" ;; esac
case "$got" in *operator*) bad "C3 the default login leaked past the override: '$got'" ;; *) ok ;; esac
got=$(env -i PATH="$PATH" HARNESS="$T/c3" bash -c '. "$1" || exit 9; harness_pr_authors' _ "$DIR/bin/lib/gh-pr-list.sh")
case "$got" in "operator app/cromford app/cromford-builders"*) ok ;; *) bad "C3 default authors changed: '$got'" ;; esac

# ── C4: a project slug comes from fleet.conf col 2; no row, no guess ─────────
mkdir -p "$T/c4/h/bin" "$T/c4/h/logs" "$T/c4/stub"
cp "$DIR/bin/fleet-conf.sh" "$T/c4/h/bin/"
printf 'project-2 acme/project-2-real - TA 0 node-project-2\n' > "$T/c4/h/fleet.conf"
printf '#!/bin/bash\necho "$*" >> "%s/gh.calls"\n' "$T/c4" > "$T/c4/stub/gh"; chmod +x "$T/c4/stub/gh"
for s in lander deploy-train; do
  blk="$T/c4/$s.blk"
  awk '/^# >>> deployment slug \(BH-4080\)/{on=1} on{print} /^# <<< deployment slug/{on=0}' "$DIR/bin/$s.sh" > "$blk"
  [ -s "$blk" ] && ok || { bad "C4 bin/$s.sh has no deployment-slug block"; continue; }
  rm -f "$T/c4/gh.calls" "$T/c4/h/logs/"*
  got=$(env -i PATH="$T/c4/stub:$PATH" HARNESS="$T/c4/h" FLEET_CONF="$T/c4/h/fleet.conf" PROJECT=project-2 \
        bash -c '. "$1"; gh pr view 1 -R "$SLUG"; printf "%s" "$SLUG"' _ "$blk")
  [ "$got" = "acme/project-2-real" ] && ok || bad "C4 $s: project-2 slug '$got', want the fleet.conf col-2 value"
  rm -f "$T/c4/gh.calls"
  got=$(env -i PATH="$T/c4/stub:$PATH" HARNESS="$T/c4/h" FLEET_CONF="$T/c4/h/fleet.conf" PROJECT=project-3 \
        bash -c '. "$1"; gh pr view 1 -R "$SLUG"; printf "%s" "$SLUG"' _ "$blk"); rc=$?
  [ "$rc" != 0 ] && [ -z "$got" ] && ok || bad "C4 $s: a project with no row resolved '$got' (rc $rc)"
  [ ! -s "$T/c4/gh.calls" ] && ok || bad "C4 $s: gh was called for a project with no row: $(cat "$T/c4/gh.calls")"
  [ "$(cat "$T/c4/h/logs/"* 2>/dev/null | grep -c 'project-3')" = 1 ] && ok || bad "C4 $s: want one log line naming project-3"
done

# ── C5: the box naming fallback ──────────────────────────────────────────────
mkdir -p "$T/c5/bin/lib"
cp "$DIR/bin/box-for.sh" "$DIR/bin/fleet-conf.sh" "$T/c5/bin/"
cp "$LIB" "$T/c5/bin/lib/" 2>/dev/null
printf 'widget-os acme/widget - WG 0\n' > "$T/c5/fleet.conf"
got=$(env -i PATH="$PATH" FLEET_CONF="$T/c5/fleet.conf" HARNESS_BOX_PREFIX=node- bash "$T/c5/bin/box-for.sh" widget-os)
[ "$got" = node-widget ] && ok || bad "C5 box fallback with HARNESS_BOX_PREFIX=node-: '$got'"
got=$(env -i PATH="$PATH" FLEET_CONF="$T/c5/fleet.conf" bash "$T/c5/bin/box-for.sh" widget-os)
[ "$got" = box-widget ] && ok || bad "C5 box fallback default changed: '$got'"

# ── C6: gh-app default owners ────────────────────────────────────────────────
mkdir -p "$T/c6/state"
got=$(env -i PATH="$PATH" HARNESS="$T/c6" HARNESS_REPO=acme/h bash -c '. "$1" || exit 9; _ghad_knobs; printf "%s" "$_GHAD_OWNERS"' _ "$DIR/bin/lib/gh-app-default.sh")
[ "$got" = acme ] && ok || bad "C6 gh-app owners from HARNESS_REPO=acme/h: '$got'"
rm -rf "$T/c6/state"; mkdir -p "$T/c6/state"
got=$(env -i PATH="$PATH" HARNESS="$T/c6" bash -c '. "$1" || exit 9; _ghad_knobs; printf "%s" "$_GHAD_OWNERS"' _ "$DIR/bin/lib/gh-app-default.sh")
[ "$got" = example-org ] && ok || bad "C6 gh-app owners default changed: '$got'"

# ── J1-J2: the console and worker homes, driven through their own node suites ─
CONSOLE_HOME="$DIR/console-ui/src/lib/deployment.js"
WORKER_HOME="$DIR/worker/jobs/src/lib/deployment-defaults.js"
if command -v node >/dev/null 2>&1; then
  got=$(node --input-type=module -e "import { FLEET_LOGIN, PRODUCT_COCKPIT_URL } from '$CONSOLE_HOME'; console.log(FLEET_LOGIN + ' ' + PRODUCT_COCKPIT_URL)" 2>&1)
  [ "$got" = "operator https://harness-console.operator.workers.dev/product" ] && ok || bad "J1 console defaults module: '$got'"
  got=$(node --input-type=module -e "import { ANCHOR_DEFAULT_ACCOUNT_MAP as a } from '$WORKER_HOME'; console.log(a.split(',').map(p => p.split(':').pop()).sort().join(' '))" 2>&1)
  [ "$got" = "operator@example.com operator@example.com" ] && ok || bad "J2 worker defaults module accounts: '$got'"
  # core.js imports the RENDERED catalog/lanes.json by a static path; it is
  # git-ignored, so a fresh checkout has none (the worker/jobs CI job renders it).
  if [ -f "$DIR/catalog/lanes.json" ]; then
    got=$(node --input-type=module -e "import { ANCHOR_DEFAULT_ACCOUNT_MAP as a } from '$WORKER_HOME'; import { ANCHOR_DEFAULT_ACCOUNT_MAP as b } from '$DIR/worker/jobs/src/lib/core.js'; console.log(a === b && a.length > 0)" 2>&1)
    [ "$got" = true ] && ok || bad "J2 core.js must re-export the worker defaults module's map: '$got'"
    (cd "$DIR/worker/jobs" && node --test test/deployment-defaults.bh-4080.test.js >"$T/j2.log" 2>&1) && ok || bad "J2 worker suite: $(tail -5 "$T/j2.log")"
  else
    echo "SKIP: J2 core.js re-export + worker node suite (catalog/lanes.json is not rendered: bin/lanes-build.sh --write; the worker/jobs CI job runs it)"
  fi
  if [ -d "$DIR/console-ui/node_modules/preact" ]; then
    (cd "$DIR/console-ui" && node --test tests/deployment-defaults.bh-4080.test.js >"$T/j1.log" 2>&1) && ok || bad "J1 console suite: $(tail -5 "$T/j1.log")"
  else
    echo "SKIP: J1 console node suite (console-ui/node_modules not installed; CI's console job runs it)"
  fi
else
  echo "SKIP: J1-J2 (no node on PATH)"
fi

# ── R1: the report renders clean, deterministically, and is never committed ──
# BH-5518: a committed deployment.md was a shared generated file. A batch of two
# PRs that each rendered alone committed neither side's render, and this case
# failed batches #5426 and #5427. The freshness proof is now --check: two
# renders of the sources are identical and no render is tracked.
bash "$DIR/bin/config-inventory.sh" --root "$DIR" --out "$T/r1" >"$T/r1.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "R1 config-inventory.sh rc=$rc: $(cat "$T/r1.log")"
bash "$DIR/bin/config-inventory.sh" --check --root "$DIR" >"$T/r1-check.log" 2>&1; rc=$?
[ "$rc" = 0 ] && ok || bad "R1 config-inventory.sh --check rc=$rc: $(tail -8 "$T/r1-check.log")"
if git -C "$DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  got=$(git -C "$DIR" ls-files docs/config-inventory 2>&1)
  [ -z "$got" ] && ok || bad "R1 docs/config-inventory is generated and must not be tracked: $(echo "$got" | tr '\n' ' ')"
else
  echo "SKIP: R1 tracked-path check ($DIR is not a git checkout)"
fi
if [ -s "$T/r1/deployment.md" ]; then
  jq -e . "$T/r1/deployment.json" >/dev/null 2>&1 && ok || bad "R1 the rendered deployment.json is not valid JSON"
  for fam in $CATFAMS; do
    grep -q "^## \`$fam\`" "$T/r1/deployment.md" && ok || bad "R1 report has no section for $fam"
  done
  for w in "Model routes" "Telegram / Slack" "Tailnet hosts" "Account ids" "Hub paths"; do
    grep -q "\*\*$w" "$T/r1/deployment.md" && ok || bad "R1 already-config section does not name '$w'"
  done
  grep -q 'Un-allowlisted literals: \*\*0\*\*' "$T/r1/deployment.md" && ok || bad "R1 the report does not record zero un-allowlisted literals"
else
  bad "R1 the generator wrote no deployment.md"
fi

echo "no-hardcoded-deployment: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
