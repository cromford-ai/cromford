#!/bin/bash
# tests/plan-spec-trace.bh-6485-test.sh — BH-6485: a ticket body that names
# `Spec:` sections or `Reference:` screens gets a plan with a `## Spec trace`
# line per section and each Reference under `## QA screens`, or the plan gate
# refuses it (rc 2) and the build ends PLAN_MALFORMED after one repair pass.
#
# Driven: bin/lib/spec-trace.sh (the parser), bin/plan-gate.sh as installed by
# scratch_install_closure, and the shipped `# >>> spec trace note` and
# `# >>> plan gate` regions of bin/lib/rb/plan.sh (flattened by rb_all), with
# the model call, the beat and the ledger stubbed.
#   P1-P9  the ticket-line grammar, including this ticket's own body (P3)
#   G1-G8  bin/plan-gate.sh with PLAN_GATE_TICKET
#   E1     the plan gate region: rc 2 twice ends PLAN_MALFORMED, and the
#          repair prompt names the spec trace
#   N1-N2  the spec trace note region and UI_PLAN_NOTE
#   K1     the registry defaults equal the lib's fallbacks
# No network, no model call. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/plan-spec-trace.bh-6485-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
unset PROJECT KEY BUILD
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq missing"; exit 1; }

mkdir -p "$T/h/state" "$T/h/logs"
scratch_install_closure bin/plan-gate.sh "$T/h" >/dev/null || { echo "FAIL: closure install"; exit 1; }
LIB="$T/h/bin/lib/spec-trace.sh"
[ -r "$LIB" ] || { echo "FAIL: bin/lib/spec-trace.sh is not in the plan-gate closure"; exit 1; }
# shellcheck source=/dev/null
. "$LIB" || { echo "FAIL: cannot source $LIB"; exit 1; }
PG="$T/h/bin/plan-gate.sh"

# ── P: the parser ────────────────────────────────────────────────────────────
pv() { printf '%b' "$2" | st_parse "$1" | paste -sd'|' -; }
[ "$(pv spec 'Spec: docs/prd.md#J01\n')" = 'docs/prd.md#J01' ] && ok || bad "P1 column-0 Spec: line: '$(pv spec 'Spec: docs/prd.md#J01\n')'"
[ "$(pv spec '- `Spec:` a.md#X, `b/c.md#Y`\n')" = 'a.md#X|b/c.md#Y' ] && ok || bad "P2 bullet, backtick key, comma list: '$(pv spec '- `Spec:` a.md#X, `b/c.md#Y`\n')'"
OWN=$(cat <<'EOF'
## Scope

1. **Plan contract (`prompts/plan-contract.md`):** a ticket body may carry `Spec: <path>#<section>` and `Reference: <screenshot path>` lines. When it does, the plan must include a `## Spec trace` section.
3. **UI evidence:** when the ticket carries `Reference:` lines and the diff touches UI, the PR body must hold side-by-side screenshots.
4. **Readiness:** a repo with a `design/` or `spec/` folder and open ai-build tickets with no `Spec:` line gets a warning.

## Acceptance tests

- `tests/plan-spec-trace-test.sh`: a ticket with `Spec:` lines → a plan without `## Spec trace` is PLAN_MALFORMED; with it → passes.
EOF
)
[ -z "$(st_parse spec <<<"$OWN")$(st_parse reference <<<"$OWN")$(st_parse cut <<<"$OWN")" ] && ok \
  || bad "P3 this ticket's own body must parse to nothing: $(st_parse spec <<<"$OWN") $(st_parse reference <<<"$OWN")"
[ -z "$(pv spec 'Spec-repo: example-org/project-6\nSpec-repos: a/b.c\n')" ] && ok || bad "P4 Spec-repo: is not Spec:"
[ -z "$(pv spec '```\nSpec: f.md#Z\n```\n~~~\nSpec: g.md#Z\n~~~\n')" ] && ok || bad "P5 a fenced Spec: line must not parse"
[ -z "$(pv spec 'Spec: the plan this build executed is in this PR at `.harness/specs/BH-1/plan.md`\n')" ] && ok \
  || bad "P6 the spec-artifact sentence (bin/lib/rb/spec.sh) is not a spec line"
[ "$(pv reference 'Reference: design/home.png\n')" = 'design/home.png' ] && ok || bad "P7 Reference: value"
[ "$(pv cut 'Cut: SET-4, J03\n')" = 'SET-4|J03' ] && ok || bad "P8 two cut tokens: '$(pv cut 'Cut: SET-4, J03\n')'"
MANY="Spec: $(seq 1 21 | sed 's#^#d/p.md\##' | paste -sd, -)"
[ "$(st_parse spec <<<"$MANY" | grep -c .)" = 20 ] && ok || bad "P9 the cap keeps 20 values, got $(st_parse spec <<<"$MANY" | grep -c .)"
[ "$(st_dropped spec <<<"$MANY")" = 1 ] && ok || bad "P9 the dropped count is 1, got $(st_dropped spec <<<"$MANY")"
printf '{"body":"Spec: docs/prd.md#J01\\n"}' > "$T/meta-json.json"
[ "$(st_parse spec "$T/meta-json.json")" = 'docs/prd.md#J01' ] && ok || bad "P10 the body comes from .body of ticket-meta.json"
printf '{"body":"plain","comments":[{"body":"Spec: docs/prd.md#J09"}]}' > "$T/meta-comment.json"
st_has "$T/meta-comment.json" && bad "P11 a Spec: line in a comment must never count" || ok

# ── G: bin/plan-gate.sh ─────────────────────────────────────────────────────
meta() { jq -n --arg b "$1" '{body: $b}' > "$T/$2"; }
meta 'Spec: docs/prd.md#J01' spec1.json
meta 'Spec: docs/prd.md#J01, docs/prd.md#J02' spec2.json
meta 'Reference: design/home.png' ref.json
meta 'Spec: docs/prd.md' nosec.json
meta 'A plain ticket with no spec lines.' plain.json
meta 'Spec: docs/prd.md#T1' t1.json
plan() { # plan <file> <spec-trace-body|-> [qa-body]
  { printf '# Plan\n\n## Tasks\n\n### Task 1 — first run\nVALIDATE: bash tests/x.sh\nSATISFIES: the first run\n\n'
    [ "$2" = - ] || printf '## Spec trace\n\n%s\n\n' "$2"
    printf '## QA screens\n\n%s\n\nKIND: feature\nSIZE: S\n' "${3:-- / (home)}"
  } > "$T/$1"
}
gate() { # gate <plan> [ticket] -> $T/g.out, rc in GRC
  if [ -n "${2:-}" ]; then PLAN_GATE_TICKET="$T/$2" "$PG" "$T/$1" > "$T/g.out" 2>&1; GRC=$?
  else env -u PLAN_GATE_TICKET "$PG" "$T/$1" > "$T/g.out" 2>&1; GRC=$?; fi
}
plan none.md -
gate none.md spec1.json
[ "$GRC" = 2 ] && ok || bad "G1 rc must be 2, got $GRC: $(cat "$T/g.out")"
grep -qx 'PLAN_SPEC_TRACE: missing' "$T/g.out" && ok || bad "G1 PLAN_SPEC_TRACE: missing: $(cat "$T/g.out")"
grep -q '^  UNTRACED: spec trace — J01: ' "$T/g.out" && ok || bad "G1 the UNTRACED line names J01: $(cat "$T/g.out")"
grep -qx 'PLAN_TRACE: untraced' "$T/g.out" && ok || bad "G1 the final verdict is untraced: $(tail -1 "$T/g.out")"

plan traced.md 'SJ01: first run → Task 1 / src/a.ts'
gate traced.md spec1.json
[ "$GRC" = 0 ] && grep -qx 'PLAN_SPEC_TRACE: ok' "$T/g.out" && ok || bad "G2 a traced plan passes, rc $GRC: $(cat "$T/g.out")"

plan half.md 'SJ01: first run → Task 1 / src/a.ts'
gate half.md spec2.json
[ "$GRC" = 2 ] && grep -q '^  UNTRACED: spec trace — J02: ' "$T/g.out" && ! grep -q 'spec trace — J01' "$T/g.out" && ok \
  || bad "G3 two sections, one line: rc 2 naming J02 only, rc $GRC: $(cat "$T/g.out")"

plan refmiss.md - '- / (home)'
gate refmiss.md ref.json
[ "$GRC" = 2 ] && grep -q '^  UNTRACED: spec trace — design/home.png: Reference not listed' "$T/g.out" && ok \
  || bad "G4 a Reference absent from QA screens refuses, rc $GRC: $(cat "$T/g.out")"
plan refok.md - '- / (home), matches design/home.png'
gate refok.md ref.json
[ "$GRC" = 0 ] && ok || bad "G4 the Reference listed under QA screens passes, rc $GRC: $(cat "$T/g.out")"

plan ascii.md '- J01: first run -> Task 1'
gate ascii.md spec1.json
[ "$GRC" = 0 ] && ok || bad "G5 no S prefix and an ASCII arrow count, rc $GRC: $(cat "$T/g.out")"
plan noarrow.md 'SJ01: first run, see Task 1'
gate noarrow.md spec1.json
[ "$GRC" = 2 ] && ok || bad "G5 a line with no arrow is not a trace line, rc $GRC"
plan bypath.md 'Sdocs/prd.md: the whole PRD → Task 1'
gate bypath.md nosec.json
[ "$GRC" = 0 ] && ok || bad "G5 a Spec with no #section is keyed by its path, rc $GRC: $(cat "$T/g.out")"

gate none.md spec1.json; cp "$T/g.out" "$T/g6.txt"
RN=$(st_repair_note "$T/g6.txt")
grep -q "## Spec trace" <<<"$RN" && grep -q 'J01' <<<"$RN" && ok || bad "G6 the repair note names ## Spec trace and J01: $RN"
gate traced.md spec1.json
[ -z "$(st_repair_note "$T/g.out")" ] && ok || bad "G6 a traced plan gets no repair note"

gate none.md; cp "$T/g.out" "$T/g7-unset.txt"; R1=$GRC
gate none.md plain.json; R2=$GRC
grep -q 'PLAN_SPEC_TRACE' "$T/g7-unset.txt" && bad "G7 no PLAN_GATE_TICKET prints no spec-trace line" || ok
grep -vx 'PLAN_SPEC_TRACE: n/a' "$T/g.out" | cmp -s - "$T/g7-unset.txt" && [ "$R1" = "$R2" ] && [ "$R1" = 0 ] && ok \
  || bad "G7 a plain ticket adds only 'PLAN_SPEC_TRACE: n/a' (rc $R1/$R2): $(diff "$T/g7-unset.txt" "$T/g.out")"
PLAN_GATE_TICKET="$T/does-not-exist.json" "$PG" "$T/none.md" > "$T/g.out" 2>&1; GRC=$?
[ "$GRC" = 0 ] && grep -qx 'PLAN_SPEC_TRACE: unread' "$T/g.out" && ok || bad "G7 an unreadable ticket never refuses, rc $GRC: $(cat "$T/g.out")"

plan t1.md '- T1: first run → Task 1 / src/a.ts'
gate t1.md t1.json
[ "$GRC" = 0 ] && grep -qx 'PLAN_TASKS: 1' "$T/g.out" && ok || bad "G8 a '- T1:' trace line is not a task, rc $GRC: $(cat "$T/g.out")"

SPEC_TRACE_ENFORCE=0 PLAN_GATE_TICKET="$T/spec1.json" "$PG" "$T/none.md" > "$T/g.out" 2>&1; GRC=$?
[ "$GRC" = 0 ] && grep -q '^PLAN_SPEC_TRACE: missing (not enforced' "$T/g.out" && ! grep -q '^  UNTRACED: spec trace' "$T/g.out" && ok \
  || bad "G9 SPEC_TRACE_ENFORCE=0 logs and never refuses, rc $GRC: $(cat "$T/g.out")"

# ── E, N: the shipped regions of bin/lib/rb/plan.sh ──────────────────────────
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> spec trace note \(BH-6485\)/{f=1;next} /^# <<< spec trace note \(BH-6485\)/{exit} f' "$RB_ALL" > "$T/note.sh"
awk '/^# >>> plan gate$/{f=1;next} /^# <<< plan gate$/{exit} f' "$RB_ALL" > "$T/pgblock.sh"
[ -s "$T/note.sh" ] && ok || bad "could not extract the spec trace note region"
[ -s "$T/pgblock.sh" ] && grep -q 'PLAN_GATE_TICKET=' "$T/pgblock.sh" && ok || bad "the plan gate region must pass PLAN_GATE_TICKET to bin/plan-gate.sh"
cat > "$T/drive.sh" <<'EOS'
set -uo pipefail
STAMP() { echo TS; }
RESULT() { echo "RESULT=$*"; }
BB() { :; }
CC() { printf '%s\n' "$5" >> "$CCLOG"; printf 'stub repair\n' > "$4"; }
UI_PLAN_NOTE="${UI_PLAN_NOTE_IN:-}"
. "$NOTE"
printf '%s' "$UI_PLAN_NOTE" > "$NOTEOUT"
[ "${GATE:-0}" = 1 ] || exit 0
. "$PGBLOCK"
echo CONTINUED
EOS
drive() { # drive <ticket-json> <plan> [env...]
  local tk="$1" pl="$2"; shift 2
  rm -rf "$T/b"; mkdir -p "$T/b"; cp "$T/$tk" "$T/b/ticket-meta.json"; cp "$T/$pl" "$T/b/plan.md"
  : > "$T/cc.log"; : > "$T/h/logs/ALERTS.log"; rm -f "$T/h/state/plan-malformed.txt"
  ( env HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 TICKET=1 PLAN_MODEL=stub-model \
        ALERTS="$T/h/logs/ALERTS.log" CCLOG="$T/cc.log" NOTE="$T/note.sh" PGBLOCK="$T/pgblock.sh" \
        NOTEOUT="$T/noteout" "$@" bash "$T/drive.sh" 2>&1 )
}
OUT=$(drive spec1.json none.md GATE=1)
grep -q '^RESULT=PLAN_MALFORMED ' <<<"$OUT" && ok || bad "E1 rc 2 twice must end PLAN_MALFORMED: $OUT"
grep -q CONTINUED <<<"$OUT" && bad "E1 the build must not continue past a refused spec trace" || ok
[ "$(grep -c . "$T/cc.log")" -ge 1 ] && grep -q 'SPEC TRACE' "$T/cc.log" && grep -q '## Spec trace' "$T/cc.log" && ok \
  || bad "E1 the one repair prompt must carry the spec-trace note: $(cat "$T/cc.log")"
grep -q 'spec trace is still missing' <<<"$OUT" && ok || bad "E1 the PLAN_MALFORMED reason names the spec trace: $OUT"
OUT=$(drive spec1.json traced.md GATE=1)
grep -q CONTINUED <<<"$OUT" && [ ! -s "$T/cc.log" ] && ok || bad "E1 a traced plan continues with no repair session: $OUT"

drive spec1.json traced.md UI_PLAN_NOTE_IN='pre ' >/dev/null
N1=$(cat "$T/noteout")
case "$N1" in "pre SPEC TRACE"*) ok ;; *) bad "N1 the note is appended to UI_PLAN_NOTE: $N1" ;; esac
grep -q 'docs/prd.md#J01' <<<"$N1" && grep -q '## Spec trace' <<<"$N1" && ok || bad "N1 the note names the section and ## Spec trace: $N1"
drive plain.json traced.md UI_PLAN_NOTE_IN='pre ' >/dev/null
[ "$(cat "$T/noteout")" = 'pre ' ] && ok || bad "N2 a plain ticket leaves UI_PLAN_NOTE byte-identical: '$(cat "$T/noteout")'"

# ── K1: the registry defaults are the lib's fallbacks ───────────────────────
REG="$DIR/catalog/lanes.d/_lib.spec-trace.json"
kd() { jq -r --arg e "$1" '.libs[] | select(.id == "spec-trace") | .knobs[] | select(.env == $e) | .default' "$REG" 2>/dev/null; }
[ "$(jq -r '.libs[0].file' "$REG")" = bin/lib/spec-trace.sh ] && ok || bad "K1 the registry names bin/lib/spec-trace.sh"
for pair in SPEC_TRACE_ENFORCE:ENFORCE SPEC_TRACE_SECTION_MAX_BYTES:SECTION_MAX_BYTES SPEC_TRACE_TOTAL_MAX_BYTES:TOTAL_MAX_BYTES \
            REFERENCE_SHOTS_KEEP_DAYS:KEEP_DAYS REFERENCE_SHOTS_PRUNE:PRUNE REFERENCE_SHOTS_PRUNE_MAX:PRUNE_MAX; do
  e="${pair%%:*}"; v="ST_DEFAULT_${pair#*:}"
  [ "$(kd "$e")" = "${!v}" ] && ok || bad "K1 $e: registry '$(kd "$e")' != lib $v '${!v}'"
done

# K2-K4: st_conf reads one knob with the others unset, refuses out-of-range
# values to the default with a warning, and an unknown prune mode is dry.
K=$(env -u SPEC_TRACE_ENFORCE REFERENCE_SHOTS_PRUNE_MAX=7 bash -c '. "$1"; st_conf; echo "$ST_ENFORCE $ST_PRUNE_MAX $ST_PRUNE $ST_SECTION_MAX"' _ "$LIB")
[ "$K" = "1 7 dry 12000" ] && ok || bad "K2 one knob set, the rest default: '$K'"
K=$(SPEC_TRACE_SECTION_MAX_BYTES=5 REFERENCE_SHOTS_KEEP_DAYS=x bash -c '. "$1"; st_conf; echo "$ST_SECTION_MAX $ST_KEEP_DAYS|$ST_CONF_WARN"' _ "$LIB")
case "$K" in "12000 30|"*"ST_SECTION_MAX='5' is outside 1000-200000"*"ST_KEEP_DAYS='x' is not a whole number"*) ok ;; *) bad "K3 out-of-range and non-numeric knobs fall back with a warning: '$K'" ;; esac
K=$(REFERENCE_SHOTS_PRUNE=sometimes bash -c '. "$1"; st_conf; echo "$ST_PRUNE|$ST_CONF_WARN"' _ "$LIB")
case "$K" in "dry|"*"is not dry|on|off"*) ok ;; *) bad "K4 an unknown prune mode is dry: '$K'" ;; esac

echo "plan-spec-trace.bh-6485: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
