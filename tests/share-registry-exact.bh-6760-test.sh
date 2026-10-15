#!/bin/bash
# tests/share-registry-exact.bh-6760-test.sh — the registry guard maps a name
# only when it is an exact row of a mapping table (BH-6760).
#
# the operator, 2026-10-14: "change things to project 1-2-3-4 instead of trying to make
# up new words." A fleet name is mapped only when it is a row of the table the
# sanitizer rewrites it with (PROJECTS / BOUNDED_PROJECTS, BOXES, DOMAINS,
# TICKET_PREFIXES) or a PUBLIC_REGISTRY row. No word analysis of a rewritten form.
#
#   X1  leak shapes are refused: a substring, prefix, suffix or glued form of a
#       mapped name, a partial rewrite, a domain built on a mapped name
#   X2  derived names the word analysis used to accept are refused when no row
#       names them (project-4-2 -> project-4-2, box-project-4-1-2, project-4.com)
#   X3  every exact row is mapped, and the catch-all box rows are not rows
#   X4  a new fleet.conf project with no row: rc 1, and stderr names the table
#       and the row to add for each item
#   X5  the rewrite agrees with the guard: every committed registry item that
#       a table row maps is rewritten to exactly that row's public form
#   X6  the word analysis is gone: no PUBLIC_WORDS, GENERIC_WORDS,
#       fully_rewritten or rewrite() in registry_guard.py
#   X7  the committed registry is fully mapped by exact rows (rc 0)
#
# The file is upstream-only (sanitize.DROP_FILES): it runs bin/share/.
#
# Sources under test: "$DIR/bin/share/registry_guard.py" "$DIR/bin/share/mapping.py"
# Run from anywhere: tests/share-registry-exact.bh-6760-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
GUARD="$DIR/bin/share/registry_guard.py"

if [ ! -f "$GUARD" ]; then
  if [ ! -d "$DIR/bin/share" ]; then echo "SKIP share-registry-exact: no bin/share in this copy"; exit 0; fi
  bad "missing bin/share/registry_guard.py"
  echo "share-registry-exact.bh-6760-test: $PASS pass, $FAIL fail"; exit 1
fi
unset HARNESS_DEPLOYMENT_FILE
export REGISTRY_SOURCE=file

# verdict <kind> <name> -> "mapped" or "unmapped", from the guard's own lookup.
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

# ── X1 leak shapes ──────────────────────────────────────────────────────────
X1=(project:acme-project-2 project:acme-project-3-labs project:acmeproject-1 project:project-1acme
    project:project-2acme project:project-4acme project:project-1-o project:entis-os project:omentis-os
    domain:project-1.acme.io domain:acme-project-2.com domain:acme.os.project-4.example domain:os.project-4.example.acme.io
    box:box-acme box:box-project-1-1x box:box-acme-project-2
    box:box- box:box prefix:TSX prefix:T)
verdicts "${X1[@]}" > "$T/x1.out" 2> "$T/x1.err" || bad "X1 the guard has no mapped(kind, name): $(head -3 "$T/x1.err" | tr '\n' ' ')"
for kn in "${X1[@]}"; do
  grep -qx "$kn unmapped" "$T/x1.out" && ok || bad "X1 a leak shape is mapped: $kn ($(grep "^$kn " "$T/x1.out"))"
done

# ── X2 derived names need a row ─────────────────────────────────────────────
X2=(project:project-4-2 project:project-5-labs domain:project-4.com domain:os.project-5.example box:box-project-4-1-2 box:box-project-5-1-2)
verdicts "${X2[@]}" > "$T/x2.out" 2>&1
for kn in "${X2[@]}"; do
  grep -qx "$kn unmapped" "$T/x2.out" && ok || bad "X2 a derived name with no row is mapped: $kn ($(grep "^$kn " "$T/x2.out"))"
done

# ── X3 exact rows are mapped ────────────────────────────────────────────────
X3=(project:project-1 project:project-2 project:project-5 project:project-6-os project:project-15
    domain:os.project-4.example domain:project-5.example domain:os.example.com
    box:box-project-4-1 box:box-project-6-os-1 box:local
    prefix:TS prefix:AIO project:cromford domain:cromford.ai prefix:BH)
verdicts "${X3[@]}" > "$T/x3.out" 2>&1
for kn in "${X3[@]}"; do
  grep -qx "$kn mapped" "$T/x3.out" && ok || bad "X3 an exact row is not mapped: $kn ($(grep "^$kn " "$T/x3.out"))"
done

# ── X4 a new project: rc 1 and the row to add ───────────────────────────────
R="$T/x4"; mkdir -p "$R/prompts"
scratch_install_closure bin/fleet-conf.sh "$R" >/dev/null || bad "closure install (fleet-conf)"
scratch_install_closure bin/box-for.sh "$R" >/dev/null || bad "closure install (box-for)"
cp "$DIR"/prompts/*.md "$R/prompts/"
cp "$DIR/fleet.conf" "$R/fleet.conf"
printf 'newclient example-org/newclient https://newclient.example - 5 box-newclient\n' >> "$R/fleet.conf"
printf 'Launch: run-build.sh newclient <ticket-id> NC-<issue-number>\n' > "$R/prompts/newclient.md"
python3 -B "$GUARD" --root "$R" --fleet-conf "$R/fleet.conf" > "$T/x4.out" 2> "$T/x4.err"; rc=$?
[ "$rc" = 1 ] && ok || bad "X4 rc=$rc, want 1"
for want in 'PROJECTS.*"newclient"' 'BOXES.*"box-newclient"' 'DOMAINS.*"newclient.example"' 'TICKET_PREFIXES.*"NC"'; do
  grep -qE "^registry-guard: add .*$want" "$T/x4.err" && ok || bad "X4 stderr does not name the row to add ($want): $(tr '\n' '|' < "$T/x4.err")"
done

# ── X5 the rewrite agrees with the guard ────────────────────────────────────
REGISTRY_SOURCE=file FLEET_CONF="$DIR/fleet.conf" python3 -B - "$DIR" > "$T/x5.out" 2>&1 <<'PY'
import os, sys
root = sys.argv[1]
sys.path.insert(0, os.path.join(root, "bin", "share"))
import registry_guard as g
from sanitize import rewrite
n = bad = 0
for p, box, prefix, host in g.read_registry(root, dict(os.environ), "committed"):
    for kind, item in (("project", p), ("box", box), ("domain", host)):
        pub = g.row_value(kind, item) if item else None
        if pub is None:
            continue
        n += 1
        if rewrite(item) != pub:
            bad += 1
            print("MISMATCH %s %s: row says %s, rewrite gives %s" % (kind, item, pub, rewrite(item)))
print("checked %d" % n)
sys.exit(1 if bad or n == 0 else 0)
PY
[ $? = 0 ] && ok || bad "X5 the rewrite and the rows disagree: $(tr '\n' '|' < "$T/x5.out")"

# ── X6 the word analysis is gone ────────────────────────────────────────────
CODE=$(grep -v '^[[:space:]]*#' "$GUARD")
for w in PUBLIC_WORDS GENERIC_WORDS fully_rewritten 'import rewrite' 'rewrite('; do
  case "$CODE" in *"$w"*) bad "X6 registry_guard.py still has '$w'" ;; *) ok ;; esac
done

# ── X7 the committed registry ───────────────────────────────────────────────
python3 -B "$GUARD" --root "$DIR" --fleet-conf "$DIR/fleet.conf" > "$T/x7.out" 2>&1; rc=$?
[ "$rc" = 0 ] && grep -qE '^registry-guard: [0-9]+ item\(s\), all mapped$' "$T/x7.out" && ok \
  || bad "X7 the committed registry is not mapped by exact rows (rc=$rc): $(tr '\n' ' ' < "$T/x7.out")"

echo "share-registry-exact.bh-6760-test: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
