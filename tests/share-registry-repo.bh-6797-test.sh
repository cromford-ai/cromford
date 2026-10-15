#!/bin/bash
# tests/share-registry-repo.bh-6797-test.sh — the registry guard maps a repo
# slug only when it is an exact row of mapping.REPOS (BH-6797).
#
# The fleet registry's column 2 is the GitHub slug of each project. The guard
# checks it like the project, box, prefix and domain items: an exact REPOS key
# (or a "repo:<slug>" PUBLIC_REGISTRY row) is mapped, anything else is refused.
# The sanitizer uses the same rows (rule 4b), and each right side is the text
# the old rules already gave, so the mirror text does not change.
#
#   Q1  verdicts: exact keys are mapped; glued, partial, other-owner and
#       other-case slugs are not
#   Q2  every committed registry slug is mapped
#   Q3  a new fleet.conf row with no REPOS row: rc 1, the unmapped line and the
#       row hint; a glued or other-owner slug is refused alone; a REPOS row
#       added to a copy of mapping.py clears it
#   Q4  a failed repo read is rc 2, not a dropped item
#   Q5  the rewrite agrees with the rows, and the committed count is 58
#   Q6  rule 4b changes no text the old rules gave, every row's slug included
#   Q7  read_registry still returns 4-tuples (the BH-6760 X5 contract)
#
# The file is upstream-only: it runs bin/share/.
#
# Sources under test: "$DIR/bin/share/registry_guard.py" "$DIR/bin/share/mapping.py" "$DIR/bin/share/sanitize.py"
# Run from anywhere: tests/share-registry-repo.bh-6797-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
GUARD="$DIR/bin/share/registry_guard.py"

if [ ! -f "$GUARD" ]; then
  if [ ! -d "$DIR/bin/share" ]; then echo "SKIP share-registry-repo: no bin/share in this copy"; exit 0; fi
  bad "missing bin/share/registry_guard.py"
  echo "share-registry-repo.bh-6797-test: $PASS pass, $FAIL fail"; exit 1
fi
unset HARNESS_DEPLOYMENT_FILE
export REGISTRY_SOURCE=file

verdicts() { # verdicts <kind:name>... -> one "<kind:name> <verdict>" line each
  python3 -B - "$DIR/bin/share" "$@" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import registry_guard as g
for kn in sys.argv[2:]:
    kind, name = kn.split(":", 1)
    print("%s %s" % (kn, "mapped" if g.mapped(kind, name) else "unmapped"))
PY
}

# mkroot <dir> — the registry readers, the prompts and the committed fleet.conf.
mkroot() {
  local r="$1"
  mkdir -p "$r/prompts"
  scratch_install_closure bin/fleet-conf.sh "$r" >/dev/null || bad "closure install (fleet-conf) in $r"
  scratch_install_closure bin/box-for.sh "$r" >/dev/null || bad "closure install (box-for) in $r"
  cp "$DIR"/prompts/*.md "$r/prompts/"
  cp "$DIR/fleet.conf" "$r/fleet.conf"
}

# ── Q1 verdicts ─────────────────────────────────────────────────────────────
MAPPED=(repo:example-org/project-1 repo:example-org/project-9 repo:example-org/cromford-console
        repo:example-org/project-6-runtime)
UNMAPPED=(repo:example-org/project-1-x repo:acme/project-1 repo:example-org/project-1
          repo:example-org/project-1-o repo:example-org/newclient)
verdicts "${MAPPED[@]}" "${UNMAPPED[@]}" > "$T/q1.out" 2> "$T/q1.err" \
  || bad "Q1 the guard cannot judge a repo item: $(tail -2 "$T/q1.err" | tr '\n' ' ')"
for kn in "${MAPPED[@]}"; do
  grep -qx "$kn mapped" "$T/q1.out" && ok || bad "Q1 an exact REPOS row is not mapped: $kn"
done
for kn in "${UNMAPPED[@]}"; do
  grep -qx "$kn unmapped" "$T/q1.out" && ok || bad "Q1 a non-exact slug is mapped: $kn ($(grep "^$kn " "$T/q1.out"))"
done

# ── Q2 every committed slug is mapped ───────────────────────────────────────
mapfile -t SLUGS < <(FLEET_CONF="$DIR/fleet.conf" "$DIR/bin/fleet-conf.sh" --projects | while read -r p; do
  FLEET_CONF="$DIR/fleet.conf" "$DIR/bin/fleet-conf.sh" "$p" repo; done)
[ "${#SLUGS[@]}" = 13 ] && ok || bad "Q2 want 13 committed slugs, got ${#SLUGS[@]}"
Q2=(); for s in "${SLUGS[@]}"; do Q2+=("repo:$s"); done
verdicts "${Q2[@]}" > "$T/q2.out" 2>&1
[ "$(grep -c ' mapped$' "$T/q2.out")" = 13 ] && ok || bad "Q2 not 13 of 13 slugs mapped: $(tr '\n' '|' < "$T/q2.out")"

# ── Q3 a new row: rc 1, the unmapped line and the hint ──────────────────────
R="$T/q3"; mkroot "$R"
printf 'newclient example-org/newclient https://newclient.example - 5 box-newclient\n' >> "$R/fleet.conf"
printf 'Launch: run-build.sh newclient <ticket-id> NC-<issue-number>\n' > "$R/prompts/newclient.md"
python3 -B "$GUARD" --root "$R" --fleet-conf "$R/fleet.conf" > "$T/q3.out" 2> "$T/q3.err"; rc=$?
[ "$rc" = 1 ] && ok || bad "Q3 rc=$rc, want 1"
grep -qx 'registry-guard: unmapped repo example-org/newclient' "$T/q3.out" && ok \
  || bad "Q3 no unmapped repo line: $(tr '\n' '|' < "$T/q3.out")"
grep -qE '^registry-guard: add to REPOS in bin/share/mapping.py: \("example-org/newclient"' "$T/q3.err" && ok \
  || bad "Q3 stderr does not name the REPOS row: $(tr '\n' '|' < "$T/q3.err")"

# Q3b a glued or other-owner slug on a mapped project is refused alone. The
# project name gets its own PROJECTS row in a copy of mapping.py; the box, the
# prefix (TS) and the absent domain are already mapped.
S3="$T/share3"; cp -r "$DIR/bin/share" "$S3"
python3 -B - "$S3/mapping.py" <<'PY' || bad "Q3b could not add the PROJECTS rows"
import sys
p = sys.argv[1]; s = open(p).read()
a = "\nPROJECTS = [\n"
assert s.count(a) == 1
s = s.replace(a, a + '    ("gluedrepo", "project-97"),\n    ("ownerrepo", "project-98"),\n')
open(p, "w").write(s)
PY
for pair in "gluedrepo example-org/project-1-x" "ownerrepo acme/project-1"; do
  set -- $pair
  R3="$T/q3b-$1"; mkroot "$R3"
  printf '%s %s - - 5 box-small\n' "$1" "$2" >> "$R3/fleet.conf"
  printf 'Launch: run-build.sh %s <ticket-id> TK-<issue-number>\n' "$1" > "$R3/prompts/$1.md"
  python3 -B "$S3/registry_guard.py" --root "$R3" --fleet-conf "$R3/fleet.conf" > "$T/q3b.out" 2>/dev/null; rc=$?
  [ "$rc" = 1 ] && grep -qx "registry-guard: unmapped repo $2" "$T/q3b.out" \
    && [ "$(grep -c '^registry-guard: unmapped ' "$T/q3b.out")" = 1 ] && ok \
    || bad "Q3b $2 must be refused alone (rc=$rc): $(tr '\n' '|' < "$T/q3b.out")"
done

# Q3c the REPOS row added clears the repo item.
python3 -B - "$S3/mapping.py" <<'PY' || bad "Q3c could not add the REPOS row"
import sys
p = sys.argv[1]; s = open(p).read()
a = "\nREPOS = [\n"
assert s.count(a) == 1
s = s.replace(a, a + '    ("example-org/newclient", "example-org/project-99"),\n')
open(p, "w").write(s)
PY
python3 -B "$S3/registry_guard.py" --root "$R" --fleet-conf "$R/fleet.conf" > "$T/q3c.out" 2>/dev/null
grep -q '^registry-guard: unmapped project newclient$' "$T/q3c.out" && ! grep -q 'unmapped repo' "$T/q3c.out" && ok \
  || bad "Q3c the REPOS row did not clear the repo item: $(tr '\n' '|' < "$T/q3c.out")"

# ── Q4 a failed repo read is rc 2 ───────────────────────────────────────────
R4="$T/q4"; mkroot "$R4"
mv "$R4/bin/fleet-conf.sh" "$R4/bin/fleet-conf.real.sh"
cat > "$R4/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "${2:-}" = repo ] && exit 3
exec "$(dirname "$0")/fleet-conf.real.sh" "$@"
SH
chmod +x "$R4/bin/fleet-conf.sh"
python3 -B "$GUARD" --root "$R4" --fleet-conf "$R4/fleet.conf" > "$T/q4.out" 2>&1; rc=$?
[ "$rc" = 2 ] && grep -q 'could not read the fleet registry.*repo rc 3' "$T/q4.out" && ok \
  || bad "Q4 a failed repo read: rc=$rc, want 2 and 'could not read ... repo rc 3': $(tr '\n' ' ' < "$T/q4.out")"

# ── Q5 the rewrite agrees with the rows ─────────────────────────────────────
FLEET_CONF="$DIR/fleet.conf" python3 -B - "$DIR" > "$T/q5.out" 2>&1 <<'PY'
import os, sys
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "bin", "share"))
import registry_guard as g
from sanitize import rewrite
n = bad = 0
for p, slug in g.read_repos(root, dict(os.environ), "committed"):
    n += 1
    pub = g.row_value("repo", slug)
    if pub is None or rewrite(slug) != pub:
        bad += 1
        print("MISMATCH %s: row says %s, rewrite gives %s" % (slug, pub, rewrite(slug)))
print("checked %d" % n)
sys.exit(1 if bad or n != 13 else 0)
PY
[ $? = 0 ] && ok || bad "Q5 the rewrite and the REPOS rows disagree: $(tr '\n' '|' < "$T/q5.out")"
python3 -B "$GUARD" --root "$DIR" --fleet-conf "$DIR/fleet.conf" > "$T/q5b.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -qx 'registry-guard: 58 item(s), all mapped' "$T/q5b.out" && ok \
  || bad "Q5 the committed registry: rc=$rc, want 0 and 58 items: $(tr '\n' ' ' < "$T/q5b.out")"

# ── Q6 rule 4b changes no text ──────────────────────────────────────────────
python3 -B - "$DIR/bin/share" > "$T/q6.out" 2>&1 <<'PY'
import re, sys
sys.path.insert(0, sys.argv[1])
import mapping, sanitize
# The REPOS-sourced rules: the ones that put a REPOS right side in for its key.
rules = sanitize.build_rules()
old = [(rx, rep) for rx, rep in rules
       if not any(rep == b and re.escape(a) in rx.pattern for a, b in mapping.REPOS)]
assert len(rules) - len(old) == len(mapping.REPOS), "rule 4b is not one rule per REPOS row"
bad = 0
# Every row's own slug, then slugs inside text and slugs no row names whole.
for text in [a for a, _ in mapping.REPOS] + ["example-org/project-1.git", "see example-org/project-6-runtime and example-org/project-6.",
             "example-org/Cromford", "example-org/project-1-x", "(example-org/cromford-console)",
             "github.com/example-org/project-9/pull/3", "example-org/cromford-web#12"]:
    a = sanitize.rewrite(text)
    b = text
    for rx, rep in old:
        b = rx.sub(rep, b)
    if a != b:
        bad += 1
        print("CHANGED %r: with 4b %r, without %r" % (text, a, b))
sys.exit(1 if bad else 0)
PY
[ $? = 0 ] && ok || bad "Q6 rule 4b changed the text: $(tr '\n' '|' < "$T/q6.out")"

# ── Q7 read_registry keeps its 4-tuple ──────────────────────────────────────
FLEET_CONF="$DIR/fleet.conf" python3 -B - "$DIR" > "$T/q7.out" 2>&1 <<'PY'
import os, sys
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "bin", "share"))
import registry_guard as g
rows = g.read_registry(root, dict(os.environ), "committed")
sys.exit(0 if rows and all(len(r) == 4 for r in rows) else 1)
PY
[ $? = 0 ] && ok || bad "Q7 read_registry no longer returns 4-tuples: $(tr '\n' '|' < "$T/q7.out")"

echo "share-registry-repo.bh-6797-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
