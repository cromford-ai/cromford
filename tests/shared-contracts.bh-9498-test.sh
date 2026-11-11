#!/bin/bash
# tests/shared-contracts.bh-9498-test.sh — BH-9498: a repo declares its shared
# contracts in catalog/shared-contracts.d/, the primer carries them to the plan,
# and the plan gate refuses a plan that triggers one and does not list it under
# `## Shared contracts`.
#
# Driven: bin/lib/shared-contracts.sh, and the real CLIs bin/verification-map.sh
# and bin/plan-gate.sh as installed by scratch_install_closure.
#   R1-R6  sc_read: rows, citations, BAD lines, duplicates, comments
#   M1-M12 sc_triggered: what triggers a contract, and the near misses
#   P1-P5  bin/verification-map.sh render: the section, Sources:, --contracts-out
#   G1-G8  bin/plan-gate.sh: listed / unlisted, byte-equal without the file, unread
#   K1-K4  the SHARED_CONTRACTS_ENFORCE knob and its registry default
#   S1-S2  this repo's own catalog/shared-contracts.d/
#   N1     no model call
# No network, no model call. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/shared-contracts.bh-9498-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
unset PROJECT KEY BUILD SHARED_CONTRACTS_ENFORCE PLAN_GATE_CONTRACTS PLAN_GATE_TICKET PLAN_GATE_HOTSPOTS
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
FX="$DIR/tests/fixtures/shared-contracts.bh-9498"
ID=migration-tenancy-header

# N1: any model CLI on PATH records the call; the suite asserts none happened.
mkdir -p "$T/stubbin" "$T/h/state" "$T/h/logs"
for m in claude agent-call; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/model-calls.log"\nexit 99\n' "$m" "$T" > "$T/stubbin/$m"
  chmod +x "$T/stubbin/$m"
done
export PATH="$T/stubbin:$PATH"

scratch_install_closure bin/plan-gate.sh "$T/h" >/dev/null || { echo "FAIL: plan-gate closure install"; exit 1; }
scratch_install_closure bin/verification-map.sh "$T/h" >/dev/null || { echo "FAIL: verification-map closure install"; exit 1; }
LIB="$T/h/bin/lib/shared-contracts.sh"
[ -r "$LIB" ] && ok || { bad "the lib is not in the plan-gate / verification-map closure"; LIB="$DIR/bin/lib/shared-contracts.sh"; }
[ -r "$DIR/bin/lib/shared-contracts.sh" ] || bad "the repo carries no bin/lib/shared-contracts.sh"
# shellcheck source=/dev/null
. "$LIB" || { echo "FAIL: cannot source $LIB"; exit 1; }
PG="$T/h/bin/plan-gate.sh"; VM="$T/h/bin/verification-map.sh"

# The fixture repo, copied: the gate checks `new` against it.
cp -R "$FX/repo" "$T/repo"
sc_write "$T/repo" "$T/sc.tsv" && ok || bad "sc_write on the fixture repo"

# ── R: sc_read ──────────────────────────────────────────────────────────────
OUT=$(sc_read "$T/repo")
[ "$OUT" = "$ID"$'\tnew\tprisma/sql/*.sql\tevery new prisma/sql migration starts with a -- tenancy: <class> header line\tthe tenancy-class check (DT-1)\tcatalog/shared-contracts.d/fx-project-6.tsv:2' ] && ok \
  || bad "R1 the fixture row reads with its file:line citation: $OUT"
mkdir -p "$T/rb/catalog/shared-contracts.d"; cp "$FX/bad-rows.tsv" "$T/rb/catalog/shared-contracts.d/a.tsv"
OUT=$(sc_read "$T/rb")
grep -q $'^tool-registry\tnew\tsrc/runtime/tools/\\*.ts\t.*\tcatalog/shared-contracts.d/a.tsv:6$' <<<"$OUT" && ok || bad "R1 a tool-registry-shaped row parses: $OUT"
grep -qx 'BAD: catalog/shared-contracts.d/a.tsv:2 has 4 field(s), needs 5 TAB-separated fields' <<<"$OUT" && ! grep -q '^short-row' <<<"$OUT" && ok || bad "R2 a 4-field row is BAD and unused: $OUT"
grep -q '^BAD: catalog/shared-contracts.d/a.tsv:3 when "sometimes"' <<<"$OUT" && ! grep -q '^bad-when' <<<"$OUT" && ok || bad "R3 when=sometimes is BAD: $OUT"
grep -q '^BAD: catalog/shared-contracts.d/a.tsv:4 id "Bad_Id"' <<<"$OUT" && ! grep -q '^Bad_Id' <<<"$OUT" && ok || bad "R4 id Bad_Id is BAD: $OUT"
printf 'tool-registry\tany\tsrc/*.ts\tsecond\tcheck\n' > "$T/rb/catalog/shared-contracts.d/b.tsv"
OUT=$(sc_read "$T/rb")
[ "$(grep -c '^tool-registry' <<<"$OUT")" = 1 ] && grep -q $'^tool-registry\tnew\t' <<<"$OUT" \
  && grep -q '^BAD: catalog/shared-contracts.d/b.tsv:1 id "tool-registry" is already declared at catalog/shared-contracts.d/a.tsv:6' <<<"$OUT" && ok \
  || bad "R5 a duplicate id: the C-order first file wins, the second is BAD: $OUT"
mkdir -p "$T/rc/catalog/shared-contracts.d"; printf '# only a comment\n\n   \n  # indented comment\n' > "$T/rc/catalog/shared-contracts.d/c.tsv"
[ -z "$(sc_read "$T/rc")" ] && ok || bad "R6 comments and blank lines give no row and no BAD: $(sc_read "$T/rc")"

# ── M: sc_triggered ─────────────────────────────────────────────────────────
trig() { printf '%b' "$1" > "$T/m.md"; sc_triggered "$T/m.md" "$T/sc.tsv"; }
OUT=$(sc_triggered "$FX/plan-unlisted.md" "$T/sc.tsv")
[ "$OUT" = "$ID"$'\tprisma/sql/20261111_widgets.sql' ] && ok || bad "M1 a new migration in Files to touch triggers: $OUT"
[ "$(trig '## Tasks\n\nWe add prisma/sql/20261111_widgets.sql.\n')" = "$ID"$'\tprisma/sql/20261111_widgets.sql' ] && ok \
  || bad "M2 a path that ends a sentence triggers without its dot: $(trig '## Tasks\n\nWe add prisma/sql/20261111_widgets.sql.\n')"
[ "$(trig '## Tasks\n\n### Task 1\nWrite `prisma/sql/20261111_widgets.sql`, then wire it.\n')" = "$ID"$'\tprisma/sql/20261111_widgets.sql' ] && ok \
  || bad "M4 a path only in a task body triggers"
[ -z "$(trig '## Files to touch\n\n1. `prisma/sql/0001_base.sql`\n')" ] && ok || bad "M5 an existing migration with a new row does not trigger: $(trig '## Files\n\n1. `prisma/sql/0001_base.sql`\n')"
# Each near miss next to its positive control: the same path outside the skip triggers.
[ "$(trig '## Files\n\n- `prisma/sql/sibling_only.sql`\n')" != "" ] && [ -z "$(trig '## Files\n\n- x\n\n## Sibling claims (not touched)\n\n- `prisma/sql/sibling_only.sql`\n')" ] && ok \
  || bad "M6 a path only under ## Sibling claims does not trigger"
[ "$(trig '## Files\n\n- `prisma/sql/verify_only.sql`\n')" != "" ] && [ -z "$(trig '## Files\n\n- x\n\n## Verify (run, not edited)\n\n- `prisma/sql/verify_only.sql`\n')" ] && ok \
  || bad "M7 a path only under ## Verify does not trigger"
[ "$(trig '### Task 1\nUse prisma/sql/validate_only.sql\n')" != "" ] && [ -z "$(trig '### Task 1\nVALIDATE: check prisma/sql/validate_only.sql\n- VALIDATE: check prisma/sql/validate_only.sql\n')" ] && ok \
  || bad "M8 a path only on a VALIDATE line does not trigger"
[ -z "$(trig '## Files\n\n`prisma/sqlite/x.sql` `prisma/sql/x.sql.bak` `src/prisma/sql/x.sql`\n')" ] && ok \
  || bad "M9 partial matches do not trigger: $(trig '`prisma/sqlite/x.sql` `prisma/sql/x.sql.bak` `src/prisma/sql/x.sql`\n')"
[ "$(trig '## Files\n\nprisma/sql/fenced_only.sql\n')" != "" ] && [ -z "$(trig '## Files\n\n```\nprisma/sql/fenced_only.sql\n```\n')" ] && ok \
  || bad "M10 a path only inside a fence does not trigger"
[ -z "$(trig '## Files\n\nThe dir `prisma/sql/` holds them.\n')" ] && ok || bad "M11 the bare dir does not trigger"
[ -z "$(sc_triggered "$FX/plan-near-misses.md" "$T/sc.tsv")" ] && ok \
  || bad "M12 the near-miss fixture plan triggers nothing: $(sc_triggered "$FX/plan-near-misses.md" "$T/sc.tsv")"

# ── P: bin/verification-map.sh render (the production entry point) ──────────
render() { # render <repo> [extra args] -> primer in $T/h/state/fx-context.md
  local r="$1"; shift
  HARNESS="$T/h" "$VM" render fx --repo "$r" "$@" > "$T/vm.out" 2>&1
}
PRIMER="$T/h/state/fx-context.md"
mkdir -p "$T/b"
render "$T/repo" --contracts-out "$T/b/shared-contracts.tsv"; RRC=$?
[ "$RRC" = 0 ] && grep -qE '^Sources:.* shared-contracts=yes conflict-hotspots=[a-z]+$' "$PRIMER" && ok \
  || bad "P1 Sources: carries shared-contracts=yes and still ends conflict-hotspots=: rc $RRC $(grep '^Sources:' "$PRIMER")"
grep -qF -- "- $ID | new | prisma/sql/*.sql | " "$PRIMER" && grep -qF 'catalog/shared-contracts.d/fx-project-6.tsv:2' "$PRIMER" && ok \
  || bad "P1 the primer lists the contract with its citation: $(sed -n '/SHARED CONTRACTS/,/^$/p' "$PRIMER")"
# Section order: after AGENT ARCHITECTURE, before CONFLICT HOTSPOTS.
ORD=$(grep -nE '^--- (AGENT ARCHITECTURE|SHARED CONTRACTS|CONFLICT HOTSPOTS)' "$PRIMER" | sed 's/ (.*//; s/^[0-9]*:--- //' | paste -sd,)
[ "$ORD" = 'AGENT ARCHITECTURE ---,SHARED CONTRACTS,CONFLICT HOTSPOTS ---' ] || [ "$ORD" = 'AGENT ARCHITECTURE ---,SHARED CONTRACTS,CONFLICT HOTSPOTS' ] && ok \
  || bad "P1 section order: $ORD"
mkdir -p "$T/nodir"
render "$T/nodir"
grep -q '^Sources:.* shared-contracts=no ' "$PRIMER" && grep -q '^ABSENT: no catalog/shared-contracts.d/ in ' "$PRIMER" && ok \
  || bad "P1 no dir: shared-contracts=no and an ABSENT line: $(grep '^Sources:' "$PRIMER")"
mkdir -p "$T/onlybad/catalog/shared-contracts.d"; printf 'Bad_Id\tnew\tx\ty\tz\n' > "$T/onlybad/catalog/shared-contracts.d/x.tsv"
render "$T/onlybad"
grep -q '^Sources:.* shared-contracts=bad ' "$PRIMER" && grep -q '^BAD: catalog/shared-contracts.d/x.tsv:1 ' "$PRIMER" && ok \
  || bad "P1 only bad rows: shared-contracts=bad and the BAD line: $(grep '^Sources:' "$PRIMER")"

# P2 — THE acceptance case: a fixture migration with no tenancy header; the
# plan gate, reading the file the real render wrote, refuses the plan that does
# not list the contract and passes the one that does.
render "$T/repo" --contracts-out "$T/b/shared-contracts.tsv"
cp "$FX/plan-unlisted.md" "$T/b/plan.md"
OUT=$("$PG" "$T/b/plan.md" 2>&1); GRC=$?
[ "$GRC" = 2 ] && grep -q "^  UNTRACED: shared contract — $ID: every new prisma/sql migration starts with a -- tenancy: <class> header line (triggered by prisma/sql/20261111_widgets.sql)" <<<"$OUT" \
  && grep -qx 'PLAN_CONTRACTS: unlisted' <<<"$OUT" && grep -qx 'PLAN_TRACE: untraced' <<<"$OUT" && ok \
  || bad "P2 the unlisted plan is refused naming $ID, rc $GRC: $OUT"
cp "$FX/plan-listed.md" "$T/b/plan.md"
OUT=$("$PG" "$T/b/plan.md" 2>&1); GRC=$?
[ "$GRC" = 0 ] && grep -qx 'PLAN_CONTRACTS: ok (1 triggered, 1 declared)' <<<"$OUT" && ok || bad "P2 the listed plan passes, rc $GRC: $OUT"
# P3: the two instructions.
render "$T/repo"
grep -q '^PLAN: list each contract your planned paths trigger under `## Shared contracts`' "$PRIMER" \
  && grep -q '^EXECUTE: add each contract the plan'"'"'s `## Shared contracts` lists, in the same diff.$' "$PRIMER" && ok \
  || bad "P3 the PLAN and EXECUTE instruction lines are in the section"
# P4: the lib missing beside the script: rc 0, COULD NOT READ, no out file.
mkdir -p "$T/h2/state"
scratch_install_closure bin/verification-map.sh "$T/h2" >/dev/null || bad "P4 closure install"
rm -f "$T/h2/bin/lib/shared-contracts.sh"
mkdir -p "$T/b4"; echo stale > "$T/b4/shared-contracts.tsv"
HARNESS="$T/h2" "$T/h2/bin/verification-map.sh" render fx --repo "$T/repo" --contracts-out "$T/b4/shared-contracts.tsv" >/dev/null 2>&1; RRC=$?
[ "$RRC" = 0 ] && grep -q '^COULD NOT READ: bin/lib/shared-contracts.sh is not beside this script' "$T/h2/state/fx-context.md" \
  && grep -q '^Sources:.* shared-contracts=unknown ' "$T/h2/state/fx-context.md" && [ ! -e "$T/b4/shared-contracts.tsv" ] && ok \
  || bad "P4 lib missing: rc $RRC, COULD NOT READ, shared-contracts=unknown, out file removed"
# P5: no dir writes a header-only file; the gate reads it as 0 contracts.
mkdir -p "$T/b5"
render "$T/nodir" --contracts-out "$T/b5/shared-contracts.tsv"
[ "$(cat "$T/b5/shared-contracts.tsv")" = "# repo: $T/nodir" ] && ok || bad "P5 header-only file: $(cat "$T/b5/shared-contracts.tsv")"
cp "$FX/plan-unlisted.md" "$T/b5/plan.md"
OUT=$("$PG" "$T/b5/plan.md" 2>&1); GRC=$?
[ "$GRC" = 0 ] && grep -qx 'PLAN_CONTRACTS: ok (0 triggered, 0 declared)' <<<"$OUT" && ok || bad "P5 the gate reads 0 contracts, rc $GRC: $OUT"

# ── G: bin/plan-gate.sh listing ─────────────────────────────────────────────
gate() { # gate <plan text> -> $T/g.out, GRC
  printf '%b' "$1" > "$T/g.md"
  PLAN_GATE_CONTRACTS="$T/sc.tsv" "$PG" "$T/g.md" > "$T/g.out" 2>&1; GRC=$?
}
BASE='# Plan\n\n## Files to touch\n\n1. `prisma/sql/20261111_widgets.sql`\n\n## Tasks\n\n### Task 1\nVALIDATE: npm test\nSATISFIES: "x"\n'
gate "$BASE"
[ "$GRC" = 2 ] && grep -qx 'PLAN_CONTRACTS: unlisted' "$T/g.out" && ok || bad "G1 no section: refused, rc $GRC: $(cat "$T/g.out")"
gate "$BASE"'\n## Shared contracts\n\n- migration-tenancy-header: `prisma/sql/20261111_widgets.sql` starts with -- tenancy: tenant\n'
[ "$GRC" = 0 ] && grep -qx 'PLAN_CONTRACTS: ok (1 triggered, 1 declared)' "$T/g.out" && grep -qx 'PLAN_TASKS: 1' "$T/g.out" && ok \
  || bad "G2 listed: ok, and the section is not read as a task, rc $GRC: $(cat "$T/g.out")"
gate "$BASE"'\n## Notes\n\n### Shared contracts\n\n- migration-tenancy-header: the header.\n'
[ "$GRC" = 0 ] && grep -qx 'PLAN_CONTRACTS: ok (1 triggered, 1 declared)' "$T/g.out" && ok || bad "G3 a nested ### Shared contracts counts, rc $GRC: $(cat "$T/g.out")"
gate "$BASE"'\n## Shared contracts\n\n- MIGRATION-TENANCY-HEADER: the header.\n'
[ "$GRC" = 0 ] && ok || bad "G4 the id in any case counts, rc $GRC: $(cat "$T/g.out")"
gate '# Plan\n\n## Files to touch\n\n1. `prisma/sql/20261111_widgets.sql`\n\n## Tasks\n\n### Task 1 — migration-tenancy-header\nVALIDATE: npm test\nSATISFIES: "x"\n\n## Shared contracts\n\nnone\n'
[ "$GRC" = 2 ] && grep -q "^  UNTRACED: shared contract — $ID" "$T/g.out" && ok || bad "G5 the id only in ## Tasks is unlisted, rc $GRC: $(cat "$T/g.out")"
gate "$BASE"'\n## Shared contracts\n\n- migration-tenancy-header-v2: another contract.\n'
[ "$GRC" = 2 ] && ok || bad "G6 only migration-tenancy-header-v2 is not the id, rc $GRC: $(cat "$T/g.out")"
gate "$BASE"'\n## Shared files\n\n- migration-tenancy-header: wrong section.\n'
[ "$GRC" = 2 ] && ok || bad "G6b the id under ## Shared files is unlisted, rc $GRC: $(cat "$T/g.out")"
# G7: no file beside the plan and PLAN_GATE_CONTRACTS unset: no line, and the
# output is byte-equal to the gate with the lib removed.
mkdir -p "$T/b7"; cp "$FX/plan-unlisted.md" "$T/b7/plan.md"
A=$("$PG" "$T/b7/plan.md" 2>&1); ARC=$?
mkdir -p "$T/h7"; scratch_install_closure bin/plan-gate.sh "$T/h7" >/dev/null; rm -f "$T/h7/bin/lib/shared-contracts.sh"
B=$("$T/h7/bin/plan-gate.sh" "$T/b7/plan.md" 2>&1); BRC=$?
[ "$A" = "$B" ] && [ "$ARC" = "$BRC" ] && ! grep -q 'PLAN_CONTRACTS' <<<"$A" && ok || bad "G7 no file: byte-equal output, no PLAN_CONTRACTS line: $A"
# G8: the repo path is gone: unread, never a refusal.
printf '# repo: %s/gone\n' "$T" > "$T/b7/gone.tsv"; tail -n +2 "$T/sc.tsv" >> "$T/b7/gone.tsv"
OUT=$(PLAN_GATE_CONTRACTS="$T/b7/gone.tsv" "$PG" "$T/b7/plan.md" 2>&1); GRC=$?
[ "$GRC" = 0 ] && grep -qx 'PLAN_CONTRACTS: unread' <<<"$OUT" && ok || bad "G8 a missing repo is unread, rc $GRC: $OUT"
printf 'not a contracts file\n' > "$T/b7/junk.tsv"
OUT=$(PLAN_GATE_CONTRACTS="$T/b7/junk.tsv" "$PG" "$T/b7/plan.md" 2>&1); GRC=$?
[ "$GRC" = 0 ] && grep -qx 'PLAN_CONTRACTS: unread' <<<"$OUT" && ok || bad "G8 a file with no # repo: line is unread, rc $GRC: $OUT"

# ── K: the knob ─────────────────────────────────────────────────────────────
OUT=$(SHARED_CONTRACTS_ENFORCE=0 PLAN_GATE_CONTRACTS="$T/sc.tsv" "$PG" "$FX/plan-unlisted.md" 2>&1); GRC=$?
[ "$GRC" = 0 ] && grep -q "^  NOTE: shared contract (SHARED_CONTRACTS_ENFORCE=0) — $ID" <<<"$OUT" && ! grep -q '^  UNTRACED' <<<"$OUT" \
  && grep -qx 'PLAN_CONTRACTS: unlisted (not enforced, SHARED_CONTRACTS_ENFORCE=0)' <<<"$OUT" && ok \
  || bad "K1 SHARED_CONTRACTS_ENFORCE=0 logs and never refuses, rc $GRC: $OUT"
OUT=$(env -u SHARED_CONTRACTS_ENFORCE PLAN_GATE_CONTRACTS="$T/sc.tsv" "$PG" "$FX/plan-unlisted.md" 2>&1); GRC=$?
[ "$GRC" = 2 ] && ok || bad "K2 unset enforces, rc $GRC"
OUT=$(SHARED_CONTRACTS_ENFORCE=maybe PLAN_GATE_CONTRACTS="$T/sc.tsv" "$PG" "$FX/plan-unlisted.md" 2>&1); GRC=$?
[ "$GRC" = 2 ] && grep -q "SHARED_CONTRACTS_ENFORCE='maybe' is not on/off, so it enforces" <<<"$OUT" && ok || bad "K3 an unknown value enforces with a warning, rc $GRC: $OUT"
REG="$DIR/catalog/lanes.d/_lib.shared-contracts.json"
[ "$(jq -r '.libs[] | select(.id == "shared-contracts") | .file' "$REG" 2>/dev/null)" = bin/lib/shared-contracts.sh ] && ok \
  || bad "K4 the registry names bin/lib/shared-contracts.sh"
KD=$(jq -r '.libs[] | select(.id == "shared-contracts") | .knobs[] | select(.env == "SHARED_CONTRACTS_ENFORCE") | .default' "$REG" 2>/dev/null)
[ "$KD" = "$SC_DEFAULT_ENFORCE" ] && ok || bad "K4 registry default '$KD' != lib SC_DEFAULT_ENFORCE '$SC_DEFAULT_ENFORCE'"

# ── S: this repo's own contracts ────────────────────────────────────────────
OWN="$DIR/catalog/shared-contracts.d/bh-9498-cromford.tsv"
[ -r "$OWN" ] || bad "S1 $OWN is missing"
OUT=$(sc_read "$DIR")
[ "$(grep -vc '^BAD: ' <<<"$OUT")" -ge 2 ] && ! grep -q '^BAD: ' <<<"$OUT" \
  && grep -q $'^lane-registry\tany\tcron/\\*.cron\t' <<<"$OUT" && grep -q $'^schema-fragment\tnew\tworker/\\*/schema.d/\\*.sql\t' <<<"$OUT" && ok \
  || bad "S1 this repo's dir reads lane-registry and schema-fragment, 0 BAD: $OUT"
sc_write "$DIR" "$T/own.tsv" || bad "S2 sc_write on this repo"
printf '## Files to touch\n\n1. `cron/lanes/020-wake-loop.cron`\n' > "$T/s2.md"
grep -q $'^lane-registry\tcron/lanes/020-wake-loop.cron$' <<<"$(sc_triggered "$T/s2.md" "$T/own.tsv")" && ok \
  || bad "S2 an existing cron fragment triggers lane-registry (when=any): $(sc_triggered "$T/s2.md" "$T/own.tsv")"
printf '## Files to touch\n\n1. `worker/jobs/schema.d/202611111000-bh-0000-x.sql` (NEW)\n2. `worker/jobs/schema.d/0000-base.sql`\n' > "$T/s2b.md"
[ "$(sc_triggered "$T/s2b.md" "$T/own.tsv")" = $'schema-fragment\tworker/jobs/schema.d/202611111000-bh-0000-x.sql' ] && ok \
  || bad "S2 a new schema fragment triggers schema-fragment, an existing one does not: $(sc_triggered "$T/s2b.md" "$T/own.tsv")"

# ── N1: no model call ───────────────────────────────────────────────────────
[ ! -s "$T/model-calls.log" ] && ok || bad "N1 a model CLI was called: $(cat "$T/model-calls.log")"

echo "shared-contracts.bh-9498: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
