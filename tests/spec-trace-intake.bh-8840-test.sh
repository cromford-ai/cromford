#!/bin/bash
# tests/spec-trace-intake.bh-8840-test.sh — BH-8840: a `Spec:` line that mixes
# prose, quotes, commas or globs with its path is read by a path rule at the
# plan stage, before any paid call. The tokens that name a file on the base
# branch go into ticket-meta.json as .spec_trace, and the plan gate, the plan
# note and the review lens read that list. A line that names no readable file
# holds the ticket with ONE comment and starts no plan. A clean line runs
# today's path byte for byte.
#
# Driven: bin/lib/spec-trace.sh as installed by scratch_install_closure, a
# scratch git repo with the fixture spec files committed on main, bin/plan-gate.sh,
# and the shipped `# >>> spec intake (BH-8840)` region of bin/lib/rb/plan.sh
# (flattened by rb_all) with CC, RESULT, BB and thc_run stubbed.
#   A1-A3  the ticket's acceptance cases (A1 is red before BH-8840)
#   D1-D13 the decision table of the plan's failure modes
#   I1-I10 st_intake: status lines, atomic write, resume, path rules
#   R1-R4  the readers prefer .spec_trace.spec
#   E1-E5  the plan-stage region
# No network, no model call, no gh. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/spec-trace-intake.bh-8840-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
unset PROJECT KEY BUILD
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq missing"; exit 1; }
command -v git >/dev/null 2>&1 || { echo "FAIL: git missing"; exit 1; }

mkdir -p "$T/h/state" "$T/h/logs"
scratch_install_closure bin/plan-gate.sh "$T/h" >/dev/null || { echo "FAIL: closure install"; exit 1; }
LIB="$T/h/bin/lib/spec-trace.sh"
# shellcheck source=/dev/null
. "$LIB" || { echo "FAIL: cannot source $LIB"; exit 1; }
PG="$T/h/bin/plan-gate.sh"

# A scratch origin with the spec files on main, and a clone with origin/main.
PRD=design/acme-prototype-2026-10-05/handoff/PRD.md
G() { git -c user.email=t@example.invalid -c user.name=t -c init.defaultBranch=main "$@"; }
mkdir -p "$T/src"
( cd "$T/src" && G init -q && mkdir -p "$(dirname "$PRD")" design/x docs \
  && printf '# PRD\n\n## 4.20\nWaiting on you\n' > "$PRD" && printf 'x\n' > design/x/a.jpg \
  && printf '# PRD\n\n## D16\nthe rule\n' > docs/PRD.md && printf '# prd\n\n## 4.20\nx\n' > docs/prd.md \
  && G add -A && G commit -qm fixture ) || { echo "FAIL: scratch repo"; exit 1; }
G clone -q "$T/src" "$T/wk" || { echo "FAIL: scratch clone"; exit 1; }
REPO="$T/wk"

MK1796='Spec: Acme PRD §4.20 DASH-24 ("Waiting on you", "Agents on shift"), empty copy "Nothing needs you" (`design/acme-prototype-2026-10-05/handoff/PRD.md:4101,3207`)'
meta() { jq -n --arg b "$1" '{body: $b}' > "$T/$2"; }
sum() { cksum < "$1"; }
intake() { # intake <body> <file> -> SI (status line), SIRC
  meta "$1" "$2"
  SI=$(st_intake "$REPO" origin/main "$T/$2"); SIRC=$?
}

# ── A: the acceptance cases ─────────────────────────────────────────────────
TOK=$(st_spec_tokens <<<"$MK1796" 2>/dev/null)
[ "$TOK" = "$PRD"$'\t\t4101,3207' ] && ok || bad "A1 the TK-1796 line tokenizes to the PRD path with lines 4101,3207: '$TOK'"
intake "$MK1796" a1.json
case "$SI" in "SPEC_INTAKE: ok kept=1 "*) ok ;; *) bad "A1 st_intake prints ok kept=1, rc $SIRC: '$SI'" ;; esac
[ "$(st_parse spec "$T/a1.json")" = "$PRD" ] && ok || bad "A1 st_parse spec gives the PRD path: '$(st_parse spec "$T/a1.json")'"
[ "$(jq -c '.spec_trace.lines' "$T/a1.json" 2>/dev/null)" = "[\"$PRD:4101,3207\"]" ] && ok \
  || bad "A1 .spec_trace.lines names lines 4101,3207: $(jq -c '.spec_trace' "$T/a1.json" 2>/dev/null)"

intake 'Spec: see the PRD for this' a2.json; B=$(sum "$T/a2.json"); meta 'Spec: see the PRD for this' a2b.json
[ "$SIRC" = 3 ] && case "$SI" in "SPEC_INTAKE: refuse"*) true ;; *) false ;; esac && ok || bad "A2 a prose line refuses, rc 3: rc $SIRC '$SI'"
[ "$B" = "$(sum "$T/a2b.json")" ] && ok || bad "A2 a refusal leaves the meta bytes unchanged"

meta 'Spec: docs/prd.md#4.20' a3b.json
intake 'Spec: docs/prd.md#4.20' a3.json
[ "$SI" = 'SPEC_INTAKE: clean' ] && [ "$SIRC" = 0 ] && ok || bad "A3 a clean line is clean: rc $SIRC '$SI'"
[ "$(sum "$T/a3.json")" = "$(sum "$T/a3b.json")" ] && ok || bad "A3 a clean line leaves the meta bytes unchanged"
[ "$(st_parse spec "$T/a3.json")" = 'docs/prd.md#4.20' ] && ok || bad "A3 st_parse spec is today's value: '$(st_parse spec "$T/a3.json")'"

# ── D: the decision table ───────────────────────────────────────────────────
d() { # d <n> <body> <expected status prefix> [expected kept values, | joined]
  intake "$2" "d$1.json"
  case "$SI" in "$3"*) ok ;; *) bad "D$1 '$2': want '$3…', got rc $SIRC '$SI'" ;; esac
  if [ -n "${4:-}" ]; then
    local got; got=$(jq -r '.spec_trace.spec[]?' "$T/d$1.json" | paste -sd'|' -)
    [ "$got" = "$4" ] && ok || bad "D$1 '$2': kept '$got', want '$4'"
  fi
}
d 1 'Spec: docs/prd.md#J01' 'SPEC_INTAKE: clean'
d 2 '- `Spec:` a.md#X, `b/c.md#Y`' 'SPEC_INTAKE: clean'
d 3 'Spec: docs/missing.md#J01' 'SPEC_INTAKE: clean'
d 4 "$MK1796" 'SPEC_INTAKE: ok kept=1' "$PRD"
d 5 'Spec: see the PRD for this' 'SPEC_INTAKE: refuse'
d 6 'Spec:' 'SPEC_INTAKE: refuse'
d 7 'Spec: design/x/{light,dark}.jpg' 'SPEC_INTAKE: refuse'
d 8 'Spec: PRD §4 (docs/PRD.md#D16)' 'SPEC_INTAKE: ok kept=1' 'docs/PRD.md#D16'
d 9 'Spec: ../etc/passwd and /etc/hosts' 'SPEC_INTAKE: refuse'
d 10 $'Intro\n```\nSpec: see the PRD\n```\n' 'SPEC_INTAKE: n/a'
d 11 'Spec-repo: example-org/project-6' 'SPEC_INTAKE: n/a'
jq -n '{body: "plain", comments: [{body: "Spec: see the PRD for this"}]}' > "$T/d12.json"
SI=$(st_intake "$REPO" origin/main "$T/d12.json"); [ "$SI" = 'SPEC_INTAKE: n/a' ] && ok || bad "D12 a Spec: line only in a comment is n/a: '$SI'"
OWN=$(cat <<'EOF'
## Fix

Check the `Spec:` line at intake (triage or the first plan stage), before any paid plan call:
1. Extract path tokens with a path rule, not a comma split.
3. A clean `Spec: path#4.20` line behaves as today.
EOF
)
d 13 "$OWN" 'SPEC_INTAKE: n/a'
[ ! -e "$T/d7.json.tmp" ] && [ "$(jq 'has("spec_trace")' "$T/d7.json")" = false ] && ok || bad "D7 a refusal writes no .spec_trace"

# ── I: st_intake ────────────────────────────────────────────────────────────
printf 'Spec: see the PRD\n' > "$T/i1.md"
SI=$(st_intake "$REPO" origin/main "$T/i1.md"); [ "$SI" = 'SPEC_INTAKE: n/a' ] && ok || bad "I1 a non-JSON ticket file is n/a: '$SI'"
meta "$MK1796" i2.json; B=$(sum "$T/i2.json")
SI=$(st_intake "$REPO" origin/nope "$T/i2.json"); SIRC=$?
case "$SI" in "SPEC_INTAKE: unknown"*) [ "$SIRC" = 0 ] && [ "$B" = "$(sum "$T/i2.json")" ] && ok || bad "I2 unknown writes nothing, rc 0: rc $SIRC" ;;
  *) bad "I2 a base ref that does not resolve is unknown (fail open): '$SI'" ;; esac
intake "$MK1796" i3.json
[ -z "$(find "$T" -maxdepth 1 -name '.spec-intake.*')" ] && ok || bad "I3 the atomic write leaves no temp file: $(find "$T" -maxdepth 1 -name '.spec-intake.*')"
intake "Spec: $PRD#4.20 and docs/PRD.md#D16, plus nothing/here.md" i4.json
K=$(sed -n 's/^SPEC_INTAKE: ok kept=\([0-9]*\) .*/\1/p' <<<"$SI")
[ -n "$K" ] && [ "$K" = "$(jq '.spec_trace.spec | length' "$T/i4.json")" ] && [ "$K" = 2 ] && ok \
  || bad "I4 kept= equals the array length (2): '$SI' $(jq -c '.spec_trace' "$T/i4.json")"
intake 'Spec: see docs/prd.md (4.20, see nothing/here.md)' i5.json
[ "$(jq -c '.spec_trace.dropped' "$T/i5.json")" = '["nothing/here.md"]' ] && ok \
  || bad "I5 dropped holds the candidates that did not read, never 4.20: $(jq -c '.spec_trace.dropped' "$T/i5.json")"
grep -q 'dropped=1: nothing/here.md' <<<"$SI" && ok || bad "I5 the status line names the dropped part: '$SI'"
B=$(sum "$T/i5.json"); SI=$(st_intake "$REPO" origin/main "$T/i5.json")
[ "$SI" = 'SPEC_INTAKE: reused' ] && [ "$B" = "$(sum "$T/i5.json")" ] && ok || bad "I6 a second run is reused with the bytes unchanged: '$SI'"
intake 'Spec: see design/x and design/x/ for it' i7.json
[ "$SIRC" = 3 ] && ok || bad "I7 a directory does not read: rc $SIRC '$SI'"
intake 'Spec: see ../wk/docs/prd.md and /etc/passwd' i8.json
[ "$SIRC" = 3 ] && grep -q '\.\./wk/docs/prd.md' <<<"$SI" && ok || bad "I8 .. and absolute paths do not read: rc $SIRC '$SI'"
intake 'Spec: see docs/../docs/prd.md for it' i8b.json
[ "$SIRC" = 3 ] && ok || bad "I8 a .. inside the path does not read, even when git resolves it: rc $SIRC '$SI'"
meta 'Spec: see ../up.md and /etc/hosts' i8c.json
SI=$(git() { case "$*" in *cat-file*) echo blob ;; *) command git "$@" ;; esac; }; st_intake "$REPO" origin/main "$T/i8c.json"); SIRC=$?
[ "$SIRC" = 3 ] && ok || bad "I8 the path rules refuse .. and / even when git would answer blob: rc $SIRC '$SI'"
intake 'Spec: read docs/prd.md.' i9.json
[ "$(jq -r '.spec_trace.spec | join("|")' "$T/i9.json")" = 'docs/prd.md' ] && ok || bad "I9 a sentence-end dot is cut from the path: '$SI'"
( cd "$T/src" && for i in $(seq 1 21); do printf '# %s\n' "$i" > "docs/c$i.md"; done && G add -A && G commit -qm many ) \
  && ( cd "$REPO" && G pull -q ) || bad "I10 fixture"
intake "Spec: see $(seq 1 21 | sed 's#^#docs/c#; s#$#.md#' | paste -sd' ' -) for it" i10.json
[ "$(jq '.spec_trace.spec | length' "$T/i10.json")" = 20 ] && [ "$(st_dropped spec "$T/i10.json")" = 1 ] && ok \
  || bad "I10 the cap keeps 20 values and st_dropped counts 1 over it: '$SI' $(jq -c '.spec_trace | {n: (.spec|length), capped}' "$T/i10.json")"

# ── R: the readers ──────────────────────────────────────────────────────────
st_has "$T/a1.json" && ok || bad "R1 st_has counts the intake list"
[ "$(st_dropped spec "$T/a1.json")" = 0 ] && ok || bad "R2 st_dropped spec on the intake list: '$(st_dropped spec "$T/a1.json")'"
N=$(st_plan_note "$T/a1.json")
grep -qF "lines 4101, 3207 of $PRD" <<<"$N" && grep -qF "spec sections $PRD" <<<"$N" && ok || bad "R3 the plan note names the path and lines 4101, 3207: $N"
plan() { printf '# Plan\n\n## Tasks\n\n### Task 1 — first run\nVALIDATE: bash tests/x.sh\nSATISFIES: the first run\n\n%s## QA screens\n\n- none\n\nKIND: bug\nSIZE: S\n' "$2" > "$T/$1"; }
plan r4ok.md "## Spec trace"$'\n\n'"S$PRD: waiting on you → T1"$'\n\n'
plan r4no.md ''
PLAN_GATE_TICKET="$T/a1.json" "$PG" "$T/r4ok.md" > "$T/g.out" 2>&1; R=$?
[ "$R" = 0 ] && grep -qx 'PLAN_SPEC_TRACE: ok' "$T/g.out" && ok || bad "R4 the plan gate passes a plan that traces the intake path, rc $R: $(cat "$T/g.out")"
PLAN_GATE_TICKET="$T/a1.json" "$PG" "$T/r4no.md" > "$T/g.out" 2>&1; R=$?
[ "$R" = 2 ] && grep -qF "UNTRACED: spec trace — $PRD" "$T/g.out" && ok || bad "R4 the plan gate refuses a plan without it, rc $R: $(cat "$T/g.out")"
meta 'Spec: docs/prd.md#J01' r5.json
[ "$(st_parse spec "$T/r5.json")" = 'docs/prd.md#J01' ] && ok || bad "R4 a meta with no .spec_trace gives today's output"

# ── E: the shipped plan-stage region ────────────────────────────────────────
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
awk '/^# >>> spec intake \(BH-8840\)/{f=1;next} /^# <<< spec intake \(BH-8840\)/{exit} f' "$RB_ALL" > "$T/si.sh"
[ -s "$T/si.sh" ] && ok || bad "could not extract the spec intake region"
L1=$(grep -n '^# >>> spec intake (BH-8840)' "$RB_ALL" | cut -d: -f1); L2=$(grep -n '^# >>> spec trace note (BH-6485)' "$RB_ALL" | cut -d: -f1)
LC=$(grep -n '^CC plan ' "$RB_ALL" | head -1 | cut -d: -f1)
[ -n "$L1" ] && [ -n "$L2" ] && [ -n "$LC" ] && [ "$L1" -lt "$L2" ] && [ "$L1" -lt "$LC" ] && ok \
  || bad "the intake region runs before the spec trace note and the first plan CC call ($L1 / $L2 / $LC)"
cat > "$T/drive.sh" <<'EOS'
set -uo pipefail
STAMP() { echo TS; }
RESULT() { echo "RESULT=$*"; }
BB() { :; }
CC() { echo cc >> "$CCLOG"; }
thc_run() { printf '%s %s %s\n' "$1" "$2" "$3" >> "$HOLDLOG"; echo "stub hold"; return "${HOLD_RC:-0}"; }
. "$SI"
echo CONTINUED
EOS
drive() { # drive <body> [env...]
  local body="$1"; shift
  rm -rf "$T/b"; mkdir -p "$T/b"; jq -n --arg b "$body" '{body: $b}' > "$T/b/ticket-meta.json"
  : > "$T/cc.log"; : > "$T/hold.log"; : > "$T/h/logs/ALERTS.log"
  ( cd "$REPO" && env HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 TICKET=9 BASE=main \
        ALERTS="$T/h/logs/ALERTS.log" CCLOG="$T/cc.log" HOLDLOG="$T/hold.log" SI="$T/si.sh" "$@" bash "$T/drive.sh" 2>&1 )
}
OUT=$(drive 'Spec: docs/prd.md#4.20')
grep -q CONTINUED <<<"$OUT" && [ ! -s "$T/hold.log" ] && [ "$(cat "$T/b/spec-intake.txt")" = 'SPEC_INTAKE: clean' ] && ok \
  || bad "E1 a clean line continues with no hold: $OUT"
OUT=$(drive "$MK1796")
grep -q CONTINUED <<<"$OUT" && [ ! -s "$T/hold.log" ] && grep -q '^SPEC_INTAKE: ok kept=1' "$T/b/spec-intake.txt" && ok \
  || bad "E2 the TK-1796 line continues, spec-intake.txt says ok: $OUT / $(cat "$T/b/spec-intake.txt")"
grep -q 'spec-intake: SPEC_INTAKE: ok kept=1' "$T/b/pipeline.log" && ok || bad "E2 one pipeline.log line carries the intake result"
OUT=$(drive 'Spec: see the PRD for this')
grep -qx 'RESULT=PLAN_BLOCKED .*/plan.md' <<<"$OUT" && ! grep -q CONTINUED <<<"$OUT" && ok || bad "E3 a prose line ends PLAN_BLOCKED and does not continue: $OUT"
case "$(head -1 "$T/b/plan.md")" in "BLOCKED: SPEC intake :: The Spec line names no readable file."*) ok ;; *) bad "E3 plan.md starts BLOCKED: SPEC intake: $(head -1 "$T/b/plan.md")" ;; esac
[ "$(grep -c . "$T/hold.log")" = 1 ] && grep -q '^hold widget-os ' "$T/hold.log" \
  && [ "$(sed 's/^hold widget-os //' "$T/hold.log" | jq -r '.ticket + "|" + .actor')" = 'WD-9|spec-intake' ] \
  && sed 's/^hold widget-os //' "$T/hold.log" | jq -r .reason | grep -q 'names no readable file' && ok \
  || bad "E3 one hold call whose reason holds the sentence: $(cat "$T/hold.log")"
[ -e "$T/b/COMMENTED" ] && [ ! -s "$T/cc.log" ] && [ ! -s "$T/h/logs/ALERTS.log" ] && ok || bad "E3 COMMENTED, 0 CC calls, 0 ALERTS lines"
OUT=$(drive 'Spec: see the PRD for this' HOLD_RC=1)
grep -q '^RESULT=PLAN_BLOCKED' <<<"$OUT" && [ "$(grep -c . "$T/h/logs/ALERTS.log")" = 1 ] && [ ! -e "$T/b/COMMENTED" ] && ok \
  || bad "E4 a failed hold: 1 ALERTS line and no COMMENTED: $OUT / $(cat "$T/h/logs/ALERTS.log")"
OUT=$(drive 'Spec: see the PRD for this' SPEC_TRACE_ENFORCE=0)
grep -q '^RESULT=PLAN_BLOCKED' <<<"$OUT" && [ "$(grep -c . "$T/hold.log")" = 1 ] && ok || bad "E5 SPEC_TRACE_ENFORCE=0 still refuses: $OUT"

echo "spec-trace-intake.bh-8840: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
