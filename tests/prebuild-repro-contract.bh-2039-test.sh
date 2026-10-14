#!/bin/bash
# tests/prebuild-repro-contract.bh-2039-test.sh — the pre-build repro gate's
# contract (BH-2039, order 1 of #2004): the record, the ledger key, the five
# stub stages, the runner's fixed flow and the run-build hook.
#
# WHAT THIS SUITE PINS:
#   L  — bin/lib/prebuild-repro.sh: pr_record (three-line record, one log line
#        in each of two logs, unknown gate refused), pr_ledger_key (stable over
#        comment order, moves on a new comment or an edited body, refuses bad
#        JSON), the stub outputs, and a source that has no side effects.
#   A/S/N/F — bin/prebuild-repro.sh run for real in a scratch HARNESS with the
#        real lane-gate, the real kind-gate and a registry composed from this
#        tree. Stage files are overridden per case to drive each branch.
#   R  — the composed registry carries the lane and its two knobs.
#   A13 — the `# >>> prebuild repro (BH-2004)` and `# >>> repro section` blocks
#        lifted verbatim from the flattened pipeline and executed.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/prebuild-repro-contract.bh-2039-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq is required"; exit 1; }

# The registry this tree composes, so lane_knob reads the shipped defaults.
REG="$T/lanes.json"
bash "$DIR/bin/lanes-build.sh" --root "$DIR" --to "$REG" >/dev/null 2>&1 \
  || bad "setup: bin/lanes-build.sh --to could not compose the registry"
export LANE_REGISTRY="$REG"
export LANE_GATE_NOW=""

# mkh <name> — a fresh scratch HARNESS with the shipped runner, lib, stages,
# lane gate and kind gate, and an agent-call.sh that only leaves a marker.
mkh() {
  local h="$T/$1"
  mkdir -p "$h/bin/lib" "$h/logs" "$h/state" "$h/flags"
  cp -p "$DIR/bin/prebuild-repro.sh" "$DIR/bin/kind-gate.sh" "$h/bin/" 2>/dev/null
  cp -p "$DIR/bin/lib/prebuild-repro.sh" "$DIR/bin/lib/lane-gate.sh" "$h/bin/lib/" 2>/dev/null
  cp -rp "$DIR/bin/lib/prebuild-repro" "$h/bin/lib/" 2>/dev/null
  printf '#!/bin/bash\ntouch "%s/agent-called"\n' "$h" > "$h/bin/agent-call.sh"
  chmod +x "$h/bin/agent-call.sh"
  printf '%s' "$h"
}
# stage <harness> <file> <body> — replace one stage file in that harness.
stage() { printf '%s\n' "$3" > "$1/bin/lib/prebuild-repro/$2.sh"; }
# meta <build> <json> — the ticket meta kind-gate reads.
BUGMETA='{"title":"Totals are wrong","labels":[{"name":"bug"}],"body":""}'
meta() { mkdir -p "$1"; printf '%s\n' "$2" > "$1/ticket-meta.json"; }
# run <harness> <build> — the runner as run-build calls it; sets RC.
run() { HARNESS="$1" bash "$1/bin/prebuild-repro.sh" p 42 BH-7 "$2" > "$2/runner.out" 2>&1; RC=$?; }
rline() { sed -n "s/^$2: //p" "$1/prebuild-repro.txt" 2>/dev/null; }
FETCH_MARK='pr_fetch_thread() { touch "$HARNESS/fetched"; printf "{\"body\":\"b\",\"comments\":[]}"; }'

# ═══════════════════════════════════════════════════════════════════════════
# L — the library
# ═══════════════════════════════════════════════════════════════════════════
H=$(mkh lib)
L() { ( export HARNESS="$H"; . "$H/bin/lib/prebuild-repro.sh" && "$@" ); }

B="$T/l1"; mkdir -p "$B"
L pr_record "$B" p BH-1 skip not-bug -
if [ "$(cat "$B/prebuild-repro.txt" 2>/dev/null)" = "$(printf 'REPRO_GATE: skip\nREPRO_REASON: not-bug\nREPRO_EVIDENCE: -')" ]; then ok
else bad "L1: record is not exactly the three lines: $(cat "$B/prebuild-repro.txt" 2>/dev/null | tr '\n' '|')"; fi

B="$T/l2"; mkdir -p "$B"
L pr_record "$B" p BH-1 cannot-drive x "$(printf 'line one\nline\ttwo')"
grep -qx 'repro=cannot_drive reason=x key=BH-1' "$B/pipeline.log" 2>/dev/null && ok || bad "L2: cannot-drive log line missing from pipeline.log"
grep -qx 'repro=cannot_drive reason=x key=BH-1' "$H/logs/p.log" 2>/dev/null && ok || bad "L2: cannot-drive log line missing from logs/p.log"
[ "$(wc -l < "$B/prebuild-repro.txt" 2>/dev/null)" = 3 ] && ok || bad "L2: a newline in evidence broke the three-line record"
[ "$(rline "$B" REPRO_EVIDENCE)" = "line one line two" ] && ok || bad "L2: evidence not flattened: '$(rline "$B" REPRO_EVIDENCE)'"
L pr_record "$B" p BH-1 cannot-drive x "$(head -c 900 /dev/zero | tr '\0' a)"
[ "$(rline "$B" REPRO_EVIDENCE | tr -d '\n' | wc -c)" = 500 ] && ok || bad "L2: evidence not capped at 500 chars"
B="$T/l2b"; mkdir -p "$B"
L pr_record "$B" p BH-1 approved x -; rc=$?
[ "$rc" = 2 ] && ok || bad "L2: unknown gate returned rc $rc, not 2"
[ ! -e "$B/prebuild-repro.txt" ] && [ ! -e "$B/pipeline.log" ] && ok || bad "L2: unknown gate still wrote something"

TH='{"body":"steps","comments":[{"id":"c1","createdAt":"2026-09-01T00:00:00Z","body":"a"},{"id":"c2","createdAt":"2026-09-02T00:00:00Z","body":"b"}]}'
TH_REV='{"body":"steps","comments":[{"id":"c2","createdAt":"2026-09-02T00:00:00Z","body":"b"},{"id":"c1","createdAt":"2026-09-01T00:00:00Z","body":"a"}]}'
TH_ADD='{"body":"steps","comments":[{"id":"c1","createdAt":"2026-09-01T00:00:00Z","body":"a"},{"id":"c2","createdAt":"2026-09-02T00:00:00Z","body":"b"},{"id":"c3","createdAt":"2026-09-03T00:00:00Z","body":"c"}]}'
TH_EDIT='{"body":"steps, edited","comments":[{"id":"c1","createdAt":"2026-09-01T00:00:00Z","body":"a"},{"id":"c2","createdAt":"2026-09-02T00:00:00Z","body":"b"}]}'
K1=$(L pr_ledger_key p BH-1 "$TH")
grep -qE '^p/BH-1/[0-9a-f]{64}$' <<<"$K1" && ok || bad "L3: key shape is '$K1'"
[ "$(L pr_ledger_key p BH-1 "$TH_REV")" = "$K1" ] && ok || bad "L4: reordering the comments changed the key"
[ "$(L pr_ledger_key p BH-1 "$TH_ADD")" != "$K1" ] && ok || bad "L5: a new comment did not change the key"
[ "$(L pr_ledger_key p BH-1 "$TH_EDIT")" != "$K1" ] && ok || bad "L5: an edited body did not change the key"
out=$(L pr_ledger_key p BH-1 'not json {'); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "L6: invalid JSON gave rc $rc and '$out'"
out=$(L pr_ledger_key p BH-1 ''); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "L6: empty thread gave rc $rc and '$out'"
out=$(L pr_ledger_key '' BH-1 "$TH"); rc=$?
[ "$rc" = 1 ] && [ -z "$out" ] && ok || bad "L6: empty project gave rc $rc and '$out'"
L pr_ledger_key p BH-1 '{"body":"x","comments":[]}' | grep -qE '^p/BH-1/[0-9a-f]{64}$' && ok || bad "L6: zero comments gave no key"

# L7 — the shipped stubs, exactly.
L pr_fetch_thread p 42 BH-1 >/dev/null; rc=$?
[ "$rc" = 3 ] && ok || bad "L7: pr_fetch_thread rc $rc, not 3"
[ "$(L pr_skip_classify '{}')" = "$(printf 'run\t-\t-')" ] && ok || bad "L7: pr_skip_classify output"
# pr_drive is real since BH-2041: in this harness (no prod-url.sh) it fails
# closed — CANNOT_DRIVE with a reason, rc 0, and no agent call.
out=$(L pr_drive p BH-1 "$T" '{}'); rc=$?
case "$out" in "CANNOT_DRIVE"$'\t'?*) [ "$rc" = 0 ] && [ ! -e "$H/agent-called" ] && ok || bad "L7: pr_drive gave rc $rc '$out'" ;;
  *) bad "L7: pr_drive gave rc $rc '$out'" ;; esac
L pr_stop p 42 BH-1 "$T" '{}' NOT_REPRODUCED; rc=$?
[ "$rc" = 0 ] && ok || bad "L7: pr_stop rc $rc, not 0"
[ -z "$(L pr_brief_line "$T")" ] && ok || bad "L7: pr_brief_line printed something"
[ -z "$(L pr_pr_section "$T")" ] && ok || bad "L7: pr_pr_section printed something"

# L8 — sourcing is side-effect free (run-build.sh sources it).
mkdir -p "$T/l8"
out=$(cd "$T/l8" && env -i PATH="$PATH" HARNESS="$H" bash -c ". '$H/bin/lib/prebuild-repro.sh'; command -v pr_record >/dev/null && echo DEFINED")
[ "$out" = DEFINED ] && ok || bad "L8: sourcing printed '$out' or defined nothing"
[ -z "$(ls -A "$T/l8")" ] && ok || bad "L8: sourcing created files"

# ═══════════════════════════════════════════════════════════════════════════
# Runner cases
# ═══════════════════════════════════════════════════════════════════════════
# A6 — no bug signal: skip not-bug, no fetch.
H=$(mkh a6); stage "$H" thread "$FETCH_MARK"; B="$T/a6b"; meta "$B" '{"title":"Add export","labels":[],"body":""}'
run "$H" "$B"
[ "$RC" = 0 ] && [ "$(rline "$B" REPRO_GATE)" = skip ] && [ "$(rline "$B" REPRO_REASON)" = not-bug ] && ok || bad "A6: rc $RC record $(tr '\n' '|' < "$B/prebuild-repro.txt" 2>/dev/null)"
[ ! -e "$H/fetched" ] && ok || bad "A6: the thread was fetched for a non-bug"
# A10 — the exact line, once, in both logs.
[ "$(grep -cx 'repro=skip reason=not-bug key=BH-7' "$H/logs/p.log" 2>/dev/null)" = 1 ] && ok || bad "A10: logs/p.log does not carry the line exactly once"
[ "$(grep -cx 'repro=skip reason=not-bug key=BH-7' "$B/pipeline.log" 2>/dev/null)" = 1 ] && ok || bad "A10: pipeline.log does not carry the line exactly once"

# N1 — a title that only looks like a key prefix is not a bug.
H=$(mkh n1); stage "$H" thread "$FETCH_MARK"; B="$T/n1b"; meta "$B" '{"title":"BH-12: fix typo","body":""}'
run "$H" "$B"
[ "$(rline "$B" REPRO_REASON)" = not-bug ] && [ ! -e "$H/fetched" ] && ok || bad "N1: '$(rline "$B" REPRO_REASON)'"

# A7 — env knob off.
H=$(mkh a7); stage "$H" thread "$FETCH_MARK"; B="$T/a7b"; meta "$B" "$BUGMETA"
REPRO_GATE=0 run "$H" "$B"
[ "$RC" = 0 ] && [ "$(rline "$B" REPRO_REASON)" = knob-off ] && [ ! -e "$H/fetched" ] && ok || bad "A7: rc $RC reason '$(rline "$B" REPRO_REASON)'"

# A14 — the settings-cache row turns it off.
H=$(mkh a14); stage "$H" thread "$FETCH_MARK"; B="$T/a14b"; meta "$B" "$BUGMETA"
printf '{"fetched_at":%s,"values":{"lane.prebuild-repro.p.repro_gate":"0"},"seeded":{}}\n' "$(date -u +%s)" > "$H/state/settings-cache.json"
run "$H" "$B"
[ "$(rline "$B" REPRO_REASON)" = knob-off ] && [ ! -e "$H/fetched" ] && ok || bad "A14: reason '$(rline "$B" REPRO_REASON)'"

# A11 — a bug with the real stubs: cannot-drive fetch-not-wired, rc 0, no agent call.
H=$(mkh a11); B="$T/a11b"; meta "$B" "$BUGMETA"
run "$H" "$B"
[ "$RC" = 0 ] && [ "$(rline "$B" REPRO_GATE)" = cannot-drive ] && [ "$(rline "$B" REPRO_REASON)" = fetch-not-wired ] && ok \
  || bad "A11: rc $RC record $(tr '\n' '|' < "$B/prebuild-repro.txt" 2>/dev/null) out $(tr '\n' '|' < "$B/runner.out")"
[ ! -e "$H/agent-called" ] && ok || bad "A11: agent-call.sh was invoked"
grep -qx 'repro=cannot_drive reason=fetch-not-wired key=BH-7' "$H/logs/p.log" 2>/dev/null && ok || bad "A11: log line missing"

THREAD_OK='pr_fetch_thread() { printf "{\"body\":\"b\",\"comments\":[]}"; }'
# S3 — fetch rc 1.
H=$(mkh s3); stage "$H" thread 'pr_fetch_thread() { return 1; }'; B="$T/s3b"; meta "$B" "$BUGMETA"
run "$H" "$B"
[ "$RC" = 0 ] && [ "$(rline "$B" REPRO_REASON)" = thread-unreadable ] && ok || bad "S3: rc $RC reason '$(rline "$B" REPRO_REASON)'"

# S4 — classify says skip: recorded with its reason and evidence, no drive.
H=$(mkh s4); stage "$H" thread "$THREAD_OK"
stage "$H" classify 'pr_skip_classify() { printf "skip\t[no-repro]\tbody line 3\n"; }'
stage "$H" drive 'pr_drive() { touch "$HARNESS/drove"; printf "REPRODUCED\tx\n"; }'
B="$T/s4b"; meta "$B" "$BUGMETA"; run "$H" "$B"
[ "$RC" = 0 ] && [ "$(rline "$B" REPRO_GATE)" = skip ] && [ "$(rline "$B" REPRO_REASON)" = '[no-repro]' ] \
  && [ "$(rline "$B" REPRO_EVIDENCE)" = 'body line 3' ] && ok || bad "S4: record $(tr '\n' '|' < "$B/prebuild-repro.txt" 2>/dev/null)"
[ ! -e "$H/drove" ] && ok || bad "S4: drove after a skip"

# N4 — `skipper` is not `skip`.
H=$(mkh n4); stage "$H" thread "$THREAD_OK"
stage "$H" classify 'pr_skip_classify() { printf "skipper\ta\tb\n"; }'
stage "$H" drive 'pr_drive() { touch "$HARNESS/drove"; printf "REPRODUCED\tseen it\n"; }'
B="$T/n4b"; meta "$B" "$BUGMETA"; run "$H" "$B"
[ -e "$H/drove" ] && [ "$(rline "$B" REPRO_GATE)" = reproduced ] && [ "$(rline "$B" REPRO_REASON)" = 'seen it' ] && ok || bad "N4: record $(tr '\n' '|' < "$B/prebuild-repro.txt" 2>/dev/null)"

# drive_case <name> <verdict line> <stop rc> — runner with a canned drive and stop.
drive_case() {
  H=$(mkh "$1"); stage "$H" thread "$THREAD_OK"
  stage "$H" drive "pr_drive() { printf '$2\n'; }"
  stage "$H" stop "pr_stop() { touch \"\$HARNESS/stopped\"; return $3; }"
  B="$T/$1b"; meta "$B" "$BUGMETA"; run "$H" "$B"
}
# S5 — the verdict map.
drive_case s5a 'REPRODUCED\tsaw it' 0
[ "$RC" = 0 ] && [ "$(rline "$B" REPRO_GATE)" = reproduced ] && [ ! -e "$H/stopped" ] && ok || bad "S5: REPRODUCED rc $RC gate '$(rline "$B" REPRO_GATE)'"
drive_case s5b 'ALREADY_FIXED\tworks on prod' 0
[ "$RC" = 0 ] && [ "$(rline "$B" REPRO_GATE)" = already-fixed ] && [ -e "$H/stopped" ] && ok || bad "S5: ALREADY_FIXED rc $RC gate '$(rline "$B" REPRO_GATE)'"
drive_case s5c 'CANNOT_DRIVE\tno login' 0
[ "$RC" = 0 ] && [ "$(rline "$B" REPRO_GATE)" = cannot-drive ] && [ "$(rline "$B" REPRO_REASON)" = 'no login' ] && [ ! -e "$H/stopped" ] && ok || bad "S5: CANNOT_DRIVE gate '$(rline "$B" REPRO_GATE)'"
# S10 — stop rc 10: exit 10, record says stop.
drive_case s10 'NOT_REPRODUCED\tlooks fine' 10
[ "$RC" = 10 ] && [ "$(rline "$B" REPRO_GATE)" = stop ] && ok || bad "S10: rc $RC gate '$(rline "$B" REPRO_GATE)'"
grep -qx 'repro=stop reason=not-reproduced key=BH-7' "$B/pipeline.log" 2>/dev/null && ok || bad "S10: stop log line missing"
# S11 — stop rc 11: exit 11.
drive_case s11 'NOT_REPRODUCED\tlooks fine' 11
[ "$RC" = 11 ] && ok || bad "S11: rc $RC, not 11"
# N3 — stop rc 1 is not a stop.
drive_case n3 'ALREADY_FIXED\tx' 1
[ "$RC" = 0 ] && [ "$(rline "$B" REPRO_GATE)" = already-fixed ] && ok || bad "N3: rc $RC gate '$(rline "$B" REPRO_GATE)'"
# N2 — an unknown verdict is cannot-drive, never a stop.
drive_case n2 'MAYBE\tx' 10
[ "$RC" = 0 ] && [ "$(rline "$B" REPRO_REASON)" = drive-bad-verdict ] && [ ! -e "$H/stopped" ] && ok || bad "N2: rc $RC reason '$(rline "$B" REPRO_REASON)'"
drive_case n2e '' 10
[ "$RC" = 0 ] && [ "$(rline "$B" REPRO_REASON)" = drive-bad-verdict ] && ok || bad "N2: empty verdict rc $RC reason '$(rline "$B" REPRO_REASON)'"

# F1 — a missing stage file fails open.
H=$(mkh f1); stage "$H" thread "$THREAD_OK"; rm -f "$H/bin/lib/prebuild-repro/drive.sh"
B="$T/f1b"; meta "$B" "$BUGMETA"; run "$H" "$B"
[ "$RC" = 0 ] && [ "$(rline "$B" REPRO_REASON)" = stage-missing ] && ok || bad "F1: rc $RC reason '$(rline "$B" REPRO_REASON)'"
# Bad args: exit 0, nothing written.
H=$(mkh args); HARNESS="$H" bash "$H/bin/prebuild-repro.sh" p 42 BH-7 "$T/nope" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ ! -e "$T/nope" ] && [ -z "$(ls -A "$H/logs")" ] && ok || bad "args: rc $rc on a missing build dir"

# ═══════════════════════════════════════════════════════════════════════════
# R1 — the registry
# ═══════════════════════════════════════════════════════════════════════════
kn() { jq -r --arg e "$1" '.lanes[]|select(.id=="prebuild-repro")|.knobs[]|select(.env==$e)|[.default,.min,.max,(.zero_means//"null")]|map(tostring)|join(" ")' "$REG" 2>/dev/null; }
[ "$(kn REPRO_GATE)" = "1 0 1 off" ] && ok || bad "R1: REPRO_GATE is '$(kn REPRO_GATE)'"
[ "$(kn REPRO_GATE_MAX_USD)" = "3 0.5 10 null" ] && ok || bad "R1: REPRO_GATE_MAX_USD is '$(kn REPRO_GATE_MAX_USD)'"
[ "$(jq -r '.lanes[]|select(.id=="prebuild-repro")|"\(.script) \(.wired) \(.scope)"' "$REG" 2>/dev/null)" = "bin/prebuild-repro.sh true project" ] && ok || bad "R1: lane entry"

# ═══════════════════════════════════════════════════════════════════════════
# A13 — the run-build blocks, verbatim
# ═══════════════════════════════════════════════════════════════════════════
RB=$(rb_all "$DIR" "$T/run-build.all.sh")
marked() { awk -v s="$1" -v e="$2" 'index($0,s){f=1;next} index($0,e){f=0} f' "$3"; }
marked '# >>> prebuild repro (BH-2004)' '# <<< prebuild repro' "$RB" > "$T/hook.sh"
marked '# >>> repro section' '# <<< repro section' "$RB" > "$T/section.sh"
[ -s "$T/hook.sh" ] && ok || bad "A13: the '# >>> prebuild repro (BH-2004)' block is missing from bin/run-build.sh"
[ -s "$T/section.sh" ] && ok || bad "A13: the '# >>> repro section' block is missing from bin/run-build.sh"
# a: between the rollout hook and the pre-plan adoption.
ln() { grep -nF -m1 "$1" "$RB" | cut -d: -f1; }
a=$(ln '# <<< rollout hook'); b=$(ln '# >>> prebuild repro (BH-2004)'); c=$(ln '# >>> preplan adopt')
[ -n "$b" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && ok || bad "A13a: block not between rollout hook ($a) and preplan adopt ($c): $b"

# hook_run <harness> <build> <runner-exit> — the block with a stub runner that
# counts its calls and writes a record; prints REACHED when it falls through.
hook_run() {
  local h="$1" b="$2"
  mkdir -p "$h/bin/lib" "$b"
  cp -p "$DIR/bin/lib/prebuild-repro.sh" "$h/bin/lib/" 2>/dev/null
  cp -rp "$DIR/bin/lib/prebuild-repro" "$h/bin/lib/" 2>/dev/null
  cat > "$h/bin/prebuild-repro.sh" <<SH
#!/bin/bash
echo x >> "$h/calls"
printf 'REPRO_GATE: skip\nREPRO_REASON: not-bug\nREPRO_EVIDENCE: -\n' > "\$4/prebuild-repro.txt"
exit $3
SH
  chmod +x "$h/bin/prebuild-repro.sh"
  { echo 'RESULT() { printf "%s\n" "$*" >> "$BUILD/result.txt"; }'
    cat "$T/hook.sh"
    echo 'echo REACHED; printf "%s" "$REPRO_BRIEF_LINE" > "$BUILD/brief.txt"'
  } > "$T/hookrun.sh"
  ( HARNESS="$h" BUILD="$b" PROJECT=p TICKET=42 KEY=BH-7 bash "$T/hookrun.sh" ) > "$b/hook.out" 2>&1
}
hook_run "$T/h13a" "$T/b13a" 0; r1=$?
hook_run "$T/h13a" "$T/b13a" 0; r2=$?
[ "$(wc -l < "$T/h13a/calls" 2>/dev/null)" = 1 ] && ok || bad "A13a: runner called $(wc -l < "$T/h13a/calls" 2>/dev/null) times over two passes"
# b: skip / cannot-drive fall through.
[ "$r1" = 0 ] && [ "$r2" = 0 ] && grep -qx REACHED "$T/b13a/hook.out" && ok || bad "A13b: block did not fall through ($r1/$r2)"
[ -e "$T/b13a/brief.txt" ] && [ ! -s "$T/b13a/brief.txt" ] && ok || bad "A13b: REPRO_BRIEF_LINE not empty with the stub render"
# c: rc 10.
hook_run "$T/h13c" "$T/b13c" 10; rc=$?
[ "$rc" = 3 ] && ok || bad "A13c: rc $rc, not 3"
grep -q '^BUILD_DEFERRED repro NOT_REPRODUCED' "$T/b13c/result.txt" 2>/dev/null && ok || bad "A13c: RESULT line missing"
[ -e "$T/b13c/COMMENTED" ] && ok || bad "A13c: COMMENTED not written"
! grep -qx REACHED "$T/b13c/hook.out" && ok || bad "A13c: fell through after rc 10"
# d: rc 11.
hook_run "$T/h13d" "$T/b13d" 11; rc=$?
[ "$rc" = 3 ] && ok || bad "A13d: rc $rc, not 3"
[ ! -e "$T/b13d/COMMENTED" ] && ok || bad "A13d: COMMENTED written though the comment failed"
[ ! -e "$T/b13d/prebuild-repro.txt" ] && ok || bad "A13d: record kept, so the next offer would never retry"
grep -q '^BUILD_DEFERRED repro NOT_REPRODUCED but the board comment failed' "$T/b13d/result.txt" 2>/dev/null && ok || bad "A13d: RESULT line missing"
# Missing runner: fail open.
mkdir -p "$T/h13e/bin" "$T/b13e"
{ echo 'RESULT() { :; }'; cat "$T/hook.sh"; echo 'echo REACHED'; } > "$T/hookrun.sh"
out=$( HARNESS="$T/h13e" BUILD="$T/b13e" PROJECT=p TICKET=42 KEY=BH-7 bash "$T/hookrun.sh" 2>&1 ); rc=$?
[ "$rc" = 0 ] && [ "$out" = REACHED ] && ok || bad "A13: a box without the runner did not fall through (rc $rc '$out')"
# e: the plan prompt carries the brief line right after the carried note.
grep -qF '$KIND_HINT_LINE$CARRIED_NOTE_LINE${REPRO_BRIEF_LINE:-} IF KIND IS BUG' "$RB" && ok || bad "A13e: plan prompt does not carry \$REPRO_BRIEF_LINE after \$CARRIED_NOTE_LINE"
# f: the PR body slot, and the section block with the stub render is empty.
grep -qF '"${ASSUMPTIONS_SECTION}${PREPR_SECTION:-}${REPRO_SECTION:-}' "$RB" && ok || bad "A13f: PR_BODY_FOR does not carry \${REPRO_SECTION:-}"
out=$( { cat "$T/section.sh"; echo 'printf "[%s]" "$REPRO_SECTION"'; } | HARNESS="$T/h13a" BUILD="$T/b13a" bash -c '. "$HARNESS/bin/lib/prebuild-repro.sh"; . /dev/stdin' 2>&1 )
[ "$out" = "[]" ] && ok || bad "A13f: REPRO_SECTION is '$out' with the stub render"

# F0 — every stub stage file ships and parses on its own, named by path so the
# test-impact map reaches each one (not only through bin/lib/prebuild-repro.sh).
for st in bin/lib/prebuild-repro/thread.sh bin/lib/prebuild-repro/classify.sh \
          bin/lib/prebuild-repro/drive.sh bin/lib/prebuild-repro/stop.sh \
          bin/lib/prebuild-repro/render.sh; do
  [ -f "$DIR/$st" ] && bash -n "$DIR/$st" 2>/dev/null && ok || bad "F0 stage $st is missing or does not parse"
done

echo "prebuild-repro-contract: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
