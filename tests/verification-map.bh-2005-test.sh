#!/bin/bash
# tests/verification-map.bh-2005-test.sh — BH-2005.1 (built as BH-2035): the
# `--- WHAT USUALLY LIES` section bin/verification-map.sh render writes into the
# project primer, between DRIVING CONVENTIONS and VERIFICATION CONTRACT.
#
# Drives the real CLI (`verification-map.sh render`) against fixture repos built
# here, and reads the primer it writes. Nothing is a copy of the function.
#
#   A1  a flat entry's two bullets are printed under `<map>/<entry>:<line>`
#   A2  an entries/ layout entry is cited as `<map>/entries/<entry>:<line>`
#   A3  an entry without the field is named once, on one `ABSENT: n of m` line
#   A4  headers: MAP, CONVENTIONS, LIES, CONTRACT, ARCHITECTURE, SHARED CONTRACTS, HOTSPOTS, in that order,
#       and every one of them is cited or opens with ABSENT / COULD NOT READ
#   A5  a repo with no map: the block holds exactly one ABSENT line
#   A6  VMAP_LIES_CAP_BYTES bites with the [TRUNCATED ...] tail; the default does
#       not bite on a small map; a non-number falls back to the default
#   A7  mutation: the script with the block deleted fails A1; the lib missing
#       renders COULD NOT READ, not an absence claim
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/verification-map.bh-2005-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
VM="$DIR/bin/verification-map.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

H="$T/harness"; mkdir -p "$H/state"
# render <script> <repo> [env...] -> prints the primer it wrote (empty if none)
render() {
  local vm="$1" repo="$2"; shift 2
  rm -f "$H/state/fx-context.md"
  env "$@" HARNESS="$H" "$vm" render fx --repo "$repo" >/dev/null 2>&1
  cat "$H/state/fx-context.md" 2>/dev/null
}
# The WHAT USUALLY LIES block: its header through the line before the next header.
block() { awk '/^--- WHAT USUALLY LIES/{on=1; print; next} on && /^--- /{exit} on' ; }

# ---------- fixture: a repo with a map in both layouts ----------------------
R="$T/present"; M="$R/docs/verification-map"
mkdir -p "$M/entries"
cat > "$R/CLAUDE.md" <<'MD'
# fx

## Verification Contract

```bash
npm test
```
MD
cat > "$M/README.md" <<'MD'
# Map

## Driving conventions

- poll an observable end-state
MD
cat > "$M/TEMPLATE.md" <<'MD'
**What usually lies:**
- template bullet that must never be rendered
MD
# The field is on line 7 of lies.md.
cat > "$M/lies.md" <<'MD'
# Lies

**What it is:** a screen.

**Verify it works:** open it.

**What usually lies:** inline text is not printed
- the green toast fires before the write lands
- the count badge caches for 60 s
  and resets on reload

**Manual-only:** nothing.
MD
cat > "$M/plain.md" <<'MD'
# Plain

**What it is:** a screen with no lies field.
MD
# The field is on line 3 of entries/row.md.
cat > "$M/entries/row.md" <<'MD'
| row | [TEMPLATE.md](TEMPLATE.md) | code |

**What usually lies:**
* the row count is per page, not total
MD

P=$(render "$VM" "$R")
B=$(block <<<"$P")

# A1
grep -q '^--- WHAT USUALLY LIES' <<<"$P" && ok || bad "A1 no WHAT USUALLY LIES header in the primer"
grep -qx -- '- the green toast fires before the write lands' <<<"$B" && ok || bad "A1 first bullet missing from the block"
grep -qx -- '- the count badge caches for 60 s' <<<"$B" && ok || bad "A1 second bullet missing from the block"
grep -qx -- '  and resets on reload' <<<"$B" && ok || bad "A1 continuation line missing from the block"
grep -qx 'docs/verification-map/lies.md:7' <<<"$B" && ok || bad "A1 no docs/verification-map/lies.md:7 citation (got: $(grep -m1 'lies.md' <<<"$B"))"
grep -q 'inline text is not printed' <<<"$B" && bad "A1 the heading line's inline text must not be printed" || ok
grep -q 'template bullet' <<<"$B" && bad "A1 TEMPLATE.md must not be read as an entry" || ok

# A2
grep -qx 'docs/verification-map/entries/row.md:3' <<<"$B" && ok || bad "A2 no docs/verification-map/entries/row.md:3 citation"
grep -qx -- '\* the row count is per page, not total' <<<"$B" && ok || bad "A2 entries/ bullet missing"

# A3
grep -qE '^ABSENT: 1 of 3 entries carry no "What usually lies" field: .*plain\.md' <<<"$B" \
  && ok || bad "A3 no 'ABSENT: 1 of 3 ... plain.md' line (got: $(grep -m1 '^ABSENT' <<<"$B"))"
[ "$(grep -c 'plain\.md' <<<"$B")" = 1 ] && ok || bad "A3 plain.md must appear exactly once in the block"
[ "$(grep -c '^ABSENT' <<<"$B")" = 1 ] && ok || bad "A3 exactly one ABSENT line expected in the block"
grep -q 'TRUNCATED' <<<"$B" && bad "A6 the default cap must not bite on a small map" || ok

# A4
HDRS=$(grep '^--- ' <<<"$P" | sed -E 's/^--- ([A-Z ]+[A-Z]).*/\1/')
# SHARED CONTRACTS (BH-9498) comes before it. CONFLICT HOTSPOTS (BH-5269) closes the primer; no JOBS_URL here, so it is COULD NOT READ.
WANT=$'VERIFICATION MAP\nDRIVING CONVENTIONS\nWHAT USUALLY LIES\nVERIFICATION CONTRACT\nAGENT ARCHITECTURE\nSHARED CONTRACTS\nCONFLICT HOTSPOTS'
[ "$HDRS" = "$WANT" ] && ok || bad "A4 header order: got [$(tr '\n' '|' <<<"$HDRS")]"
UNCITED=$(awk '
  /^--- / && !/^--- END/ { hdr=$0; cited=(index($0,"source:")>0); getline nxt;
    if (!cited && nxt !~ /^ABSENT:/ && nxt !~ /^COULD NOT READ/) print hdr; next }
' <<<"$P")
[ -z "$UNCITED" ] && ok || bad "A4 uncited section(s): $UNCITED"
grep -q '^Sources:.* what-usually-lies=yes' <<<"$P" && ok || bad "A4 Sources: line must say what-usually-lies=yes"

# ---------- A5: no map at all ------------------------------------------------
N="$T/nomap"; mkdir -p "$N"; printf '# x\n' > "$N/CLAUDE.md"
NP=$(render "$VM" "$N"); NB=$(block <<<"$NP")
[ -n "$NB" ] && ok || bad "A5 no WHAT USUALLY LIES block for a repo without a map"
[ "$(grep -c '^ABSENT:' <<<"$NB")" = 1 ] && ok || bad "A5 expected exactly one ABSENT line, got: $NB"
grep -q '^Sources:.* what-usually-lies=no' <<<"$NP" && ok || bad "A5 Sources: line must say what-usually-lies=no"
# a map directory with no entries is also one ABSENT line, with its own reason
mkdir -p "$T/emptymap/docs/verification-map"; printf '# x\n' > "$T/emptymap/CLAUDE.md"
EB=$(render "$VM" "$T/emptymap" | block)
[ "$(grep -c '^ABSENT:' <<<"$EB")" = 1 ] && grep -q 'holds no entries' <<<"$EB" \
  && ok || bad "A5 an empty map dir must give one ABSENT line saying it holds no entries, got: $EB"

# ---------- A6: the cap ------------------------------------------------------
C="$T/big"; mkdir -p "$C/docs/verification-map"; printf '# x\n' > "$C/CLAUDE.md"
for i in $(seq -w 1 60); do
  {
    echo "**What usually lies:**"
    for j in 1 2 3; do echo "- entry $i bullet $j: a long enough line that sixty of these easily clear any small cap"; done
  } > "$C/docs/verification-map/e$i.md"
done
CP=$(render "$VM" "$C" VMAP_LIES_CAP_BYTES=500); CB=$(block <<<"$CP")
grep -q '^\[TRUNCATED at 500 of [0-9]* bytes by bin/verification-map.sh' <<<"$CB" \
  && ok || bad "A6 no [TRUNCATED at 500 of ...] tail inside the block"
CT=$(grep -A3 'TRUNCATED at 500' <<<"$CP")
grep -q '^--- VERIFICATION CONTRACT' <<<"$CT" \
  && ok || bad "A6 VERIFICATION CONTRACT must still follow the truncated block"
DP=$(render "$VM" "$C" VMAP_LIES_CAP_BYTES=abc)
grep -q 'TRUNCATED at 4000 of' <<<"$DP" && ok || bad "A6 a non-number cap must fall back to 4000"

# ---------- A7: mutations ----------------------------------------------------
# control: an unmodified copy (script + lib side by side) passes A1
mkdir -p "$T/ctl/bin/lib" "$T/mut/bin/lib" "$T/nolib/bin"
cp "$VM" "$T/ctl/bin/"; cp "$DIR/bin/lib/vmap-entry.sh" "$T/ctl/bin/lib/"
CTL=$(render "$T/ctl/bin/verification-map.sh" "$R")
grep -qx 'docs/verification-map/lies.md:7' <<<"$CTL" \
  && ok || bad "A7 control copy does not render the citation — the mutation below would prove nothing"
# mutation: the block deleted
awk '/# ---- what usually lies/{skip=1} /# ---- the repo.s own verification contract/{skip=0} !skip' "$VM" > "$T/mut/bin/verification-map.sh"
chmod +x "$T/mut/bin/verification-map.sh"; cp "$DIR/bin/lib/vmap-entry.sh" "$T/mut/bin/lib/"
cmp -s "$VM" "$T/mut/bin/verification-map.sh" && bad "A7 the mutation removed nothing"
MB=$(render "$T/mut/bin/verification-map.sh" "$R" | block)
grep -qx 'docs/verification-map/lies.md:7' <<<"$MB" \
  && bad "A7 the script with the block deleted still passes A1 — A1 is vacuous" || ok
# the lib missing: a tool failure, never an absence claim
cp "$VM" "$T/nolib/bin/"
LB=$(render "$T/nolib/bin/verification-map.sh" "$R" | block)
grep -q '^COULD NOT READ bin/lib/vmap-entry.sh' <<<"$LB" && ok || bad "A7 a missing lib must render COULD NOT READ, got: $LB"
grep -q '^ABSENT' <<<"$LB" && bad "A7 a missing lib must not render an ABSENT claim" || ok

echo "verification-map.bh-2005: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
