#!/bin/bash
# reads-run-build: raw — the one-copy pin (P1) asserts the driver's own text carries no `split child check` block (it lives once, in bin/lib/rb/plan.sh, since the BH-572 cut); the flatten puts the module's copy back in the driver's place, so only a raw read can see a second copy pasted into the driver.
# tests/size-gate-split-child.bh-851-test.sh — BH-851: the depth-1 guard also
# reads the ticket BODY, and says which way it went.
#
# WHY (2026-09-18). The guard that stops a split child from being split again
# read only `.title` out of $BUILD/ticket-meta.json. A build whose meta file
# never arrived (or whose title had been edited) read as "top-level", so an
# oversized child went back to bin/run-decompose.sh. The filer writes a column-0
# `Split child (depth 1): ...` line into every decompose child's footer
# (fc_child_footer in bin/lib/file-children.sh), so the body on disk is a second
# local source. It is matched strictly: column 0, outside ``` / ~~~ fences, the
# filer's exact text — a ticket that merely QUOTES the line (BH-851 itself does)
# must still split, because a false "child" costs a big PR and a false
# "top-level" costs filed issues.
#
# Every drive runs the REAL size-gate block lifted from the flatten, with the
# decomposer stubbed and gh/curl stubs on PATH that record any call (a child
# must never depend on a network call to avoid being split again). Body
# fixtures come from the real fc_child_footer, not hand-typed.
#
# Run from anywhere. No network, no model call, no secrets.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$DIR/tests/lib/rb-all.sh" || exit 1
. "$DIR/bin/lib/file-children.sh" || exit 1
RB_ALL=$(rb_all "$DIR" "$T/run-build.all.sh")
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

mkdir -p "$T/h/bin" "$T/h/state" "$T/h/logs" "$T/h/flags" "$T/h/catalog" "$T/stub"
for S in size-gate.sh size-scope.sh size-threshold.sh planned-files.sh fleet-conf.sh; do
  [ -f "$DIR/bin/$S" ] && cp "$DIR/bin/$S" "$T/h/bin/"
done

awk '/^# >>> size gate/{f=1;next} /^# <<< size gate/{exit} f' "$RB_ALL" > "$T/sizeblock.sh"
[ -s "$T/sizeblock.sh" ] && ok || bad "could not extract the size-gate block — markers missing?"
awk '/^# >>> size enforce switch/{f=1;next} /^# <<< size enforce switch/{exit} f' \
  "$RB_ALL" > "$T/switch.sh"
[ -s "$T/switch.sh" ] && ok || bad "could not extract the size enforce switch"

cat > "$T/h/bin/run-decompose.sh" <<'EOS'
#!/bin/bash
echo "$*" >> "$DECOMPOSE_LOG"
printf 'WD-9.1\nWD-9.2\n' > "$4/children.txt"
exit 0
EOS
chmod +x "$T/h/bin/run-decompose.sh"
for S in gh curl; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 1\n' "$S" "$T" > "$T/stub/$S"
  chmod +x "$T/stub/$S"
done

# drive <meta-json|-> <body-file-text|-> <plan-text> [env...]
#   "-" leaves that file off the disk entirely.
drive() {
  local meta="$1" body="$2" plan="$3"; shift 3
  rm -rf "$T/b"; mkdir -p "$T/b"
  printf '%s\n' "$plan" > "$T/b/plan.md"
  [ "$meta" = - ] || printf '%s' "$meta" > "$T/b/ticket-meta.json"
  [ "$body" = - ] || printf '%s\n' "$body" > "$T/b/ticket-body.md"
  : > "$T/decompose.log"; : > "$T/net.log"
  ( env PATH="$T/stub:$PATH" HARNESS="$T/h" BUILD="$T/b" PROJECT=widget-os KEY=WD-9 TICKET=tkt-1 \
        ALERTS="$T/h/logs/ALERTS.log" JOB_ID=job-1 SIZE_GATE_ENFORCE=1 \
        DECOMPOSE_LOG="$T/decompose.log" SWITCHBLOCK="$T/switch.sh" "$@" \
    bash -c 'set -uo pipefail
             STAMP() { echo TS; }
             RESULT() { echo "RESULT=$*"; }
             BB() { echo "BB=$1"; }
             job_artifact_put() { :; }
             . "$SWITCHBLOCK"
             . "$0"; echo "CONTINUED"' "$T/sizeblock.sh" 2>&1 )
}
meta() { # meta <title> [body]
  jq -cn --arg t "$1" --arg b "${2:-}" '{title:$t,body:$b,labels:[]}'
}
decomposed() { [ -s "$T/decompose.log" ]; }
childlines() { grep -c 'SIZE: child check:' "$T/b/pipeline.log" 2>/dev/null; }
PLAN=$(printf '# Plan\n\n### Task 1\n- VALIDATE: npm test\n- SATISFIES: c1\n\n## Size\nFILES: 6\nLINES: 1500\n\nKIND: feature\nSIZE: M\n')
PLAN_XL=$(printf '# Plan\n\n### Task 1\n- VALIDATE: npm test\n- SATISFIES: c1\n\n## Size\nFILES: 2\nLINES: 40\n\nKIND: feature\nSIZE: XL\n')
FOOTER=$(fc_child_footer decompose 850 2 3 '#851')
grep -q '^Split child (depth 1):' <<<"$FOOTER" \
  && ok || bad "fc_child_footer no longer writes the column-0 'Split child (depth 1):' line — the fixture is stale"
CHILD_BODY=$(printf 'Tighten the retry loop in the sync worker.\n\n%s\n' "$FOOTER")
SPLIT_LINE=$(grep '^Split child (depth 1):' <<<"$FOOTER")

# --- B1. no ticket-meta.json, ticket-body.md carries the real footer ---------
OUT=$(drive - "$CHILD_BODY" "$PLAN")
grep -q CONTINUED <<<"$OUT" && ok || bad "B1: a body-marked child with no meta must build whole (got: $OUT)"
decomposed && bad "B1: a body-marked child was handed to the decomposer" || ok
grep -qi 'already a split child' "$T/b/pipeline.log" 2>/dev/null \
  && ok || bad "B1: building the child whole must leave the note: $(cat "$T/b/pipeline.log" 2>/dev/null)"
[ -s "$T/net.log" ] && bad "B1: the child check made a network call: $(cat "$T/net.log")" || ok
# --- L1. ...and it says so, once ---------------------------------------------
[ "$(grep -c 'SIZE: child check: title=unread source=body$' "$T/b/pipeline.log" 2>/dev/null)" = 1 ] \
  && ok || bad "L1: want one 'SIZE: child check: title=unread source=body' line: $(cat "$T/b/pipeline.log" 2>/dev/null)"

# --- B2. meta present, non-child title, .body carries the footer -------------
OUT=$(drive "$(meta 'Tidy the size gate' "$CHILD_BODY")" - "$PLAN")
decomposed && bad "B2: a meta .body carrying the footer must mark a child" || ok
grep -q 'SIZE: child check: title=Tidy the size gate source=body$' "$T/b/pipeline.log" 2>/dev/null \
  && ok || bad "B2: want source=body with the real title: $(cat "$T/b/pipeline.log" 2>/dev/null)"

# --- N1. BH-851's own body QUOTES the line mid-sentence: not a child ---------
OUT=$(drive - 'Every one of those tickets says in its body "Split child (depth 1) ... It is never split again"' "$PLAN")
decomposed && ok || bad "N1: a mid-line quote of the footer must not read as a child (got: $OUT)"
grep -q 'RESULT=DECOMPOSED' <<<"$OUT" && ok || bad "N1: want RESULT=DECOMPOSED (got: $OUT)"
OUT=$(drive - "The footer reads \"$SPLIT_LINE\" on every child." "$PLAN")
decomposed && ok || bad "N1: a mid-line quote carrying the full footer text must not read as a child"

# --- N2. the footer inside a fence documents the convention: not a child -----
OUT=$(drive - "$(printf 'The filer writes:\n\n```\n%s\n```\n' "$SPLIT_LINE")" "$PLAN")
decomposed && ok || bad "N2: a footer inside a \`\`\` fence must not read as a child"
OUT=$(drive - "$(printf 'The filer writes:\n\n~~~text\n%s\n~~~\n' "$SPLIT_LINE")" "$PLAN")
decomposed && ok || bad "N2: a footer inside a ~~~ fence must not read as a child"
# a fence that closes: the footer AFTER it still counts
OUT=$(drive - "$(printf '```\nexample\n```\n\n%s\n' "$SPLIT_LINE")" "$PLAN")
decomposed && bad "N2: a footer after a CLOSED fence must still read as a child" || ok

# --- N3. a rollout wave (Part of #N, no Split child line): not a child -------
OUT=$(drive - "$(printf 'Wave body.\n\n%s\n' "$(fc_child_footer rollout 850 2 3 '#851')")" "$PLAN")
decomposed && ok || bad "N3: a rollout wave body must stay decomposable"

# --- N4. indented or quoted footer: not a child ------------------------------
OUT=$(drive - "  $SPLIT_LINE" "$PLAN")
decomposed && ok || bad "N4: an indented footer must not read as a child"
OUT=$(drive - "> $SPLIT_LINE" "$PLAN")
decomposed && ok || bad "N4: a > quoted footer must not read as a child"

# --- L2. no meta, no body: today's fail-open, and the log says so ------------
OUT=$(drive - - "$PLAN")
decomposed && ok || bad "L2: no meta and no body must still split (fail-open unchanged)"
[ "$(grep -c 'SIZE: child check: title=unread source=none$' "$T/b/pipeline.log" 2>/dev/null)" = 1 ] \
  && ok || bad "L2: want one 'title=unread source=none' line: $(cat "$T/b/pipeline.log" 2>/dev/null)"

# --- L3. a child title: source=meta ------------------------------------------
OUT=$(drive "$(meta 'WD-9.1: the first slice')" - "$PLAN")
decomposed && bad "L3: a child title must build whole" || ok
[ "$(grep -c 'SIZE: child check: title=WD-9.1: the first slice source=meta$' "$T/b/pipeline.log" 2>/dev/null)" = 1 ] \
  && ok || bad "L3: want one source=meta line: $(cat "$T/b/pipeline.log" 2>/dev/null)"

# --- L4. a hostile title: one line, at most 120 title chars ------------------
LONG="$(printf 'first line\nsecond line %0300d' 0)"
OUT=$(drive "$(meta "$LONG")" - "$PLAN")
[ "$(childlines)" = 1 ] && ok || bad "L4: a multi-line title must log exactly one child-check line: $(cat "$T/b/pipeline.log" 2>/dev/null)"
T4=$(sed -n 's/.*SIZE: child check: title=\(.*\) source=[a-z]*$/\1/p' "$T/b/pipeline.log" 2>/dev/null)
[ -n "$T4" ] && [ "${#T4}" -le 120 ] \
  && ok || bad "L4: the logged title must be non-empty and at most 120 chars (got ${#T4})"
grep -q 'title=first linesecond line' "$T/b/pipeline.log" 2>/dev/null \
  && ok || bad "L4: CR/LF must be stripped from the logged title: $(cat "$T/b/pipeline.log" 2>/dev/null)"

# --- R1. a version number in a title is still not a child --------------------
OUT=$(drive "$(meta 'Upgrade to Next 15.2 across the app')" - "$PLAN")
decomposed && ok || bad "R1: a version number in a title must not read as a split child"

# --- R2. the kill flag: armed-only, whatever the source ----------------------
: > "$T/h/flags/size-gate-enforce-off"
OUT=$(drive - "$CHILD_BODY" "$PLAN_XL")
decomposed && ok || bad "R2: with the kill flag set, SIZE: XL must split even for a body-marked child"
[ "$(childlines)" = 1 ] && ok || bad "R2: the child check is logged under the kill flag too"
rm -f "$T/h/flags/size-gate-enforce-off"

# --- P1. one copy: the block lives in the stage module, never in the driver --
# Until the BH-572 cut the block lived twice (inline in the driver and in
# bin/lib/rb/plan.sh) and P1 pinned the two byte-identical. After the cut there
# is one copy, so P1 pins that: absent from the raw driver, exactly once in
# plan.sh, and exactly once in the pipeline that runs (the flatten).
cut_block() { awk '/^# >>> split child check/{f=1;next} /^# <<< split child check/{exit} f' "$1" > "$2"; }
cut_block "$DIR/bin/run-build.sh"   "$T/scc.driver"
cut_block "$DIR/bin/lib/rb/plan.sh" "$T/scc.plan"
[ ! -s "$T/scc.driver" ] && ok \
  || bad "P1: bin/run-build.sh carries its own '# >>> split child check' block again — a second copy is the drift the cut removed"
[ -s "$T/scc.plan" ] && [ "$(grep -c '^# >>> split child check' "$DIR/bin/lib/rb/plan.sh")" = 1 ] && ok \
  || bad "P1: bin/lib/rb/plan.sh must hold the '# >>> split child check' block exactly once"
[ "$(grep -c '^# >>> split child check' "$RB_ALL")" = 1 ] && ok \
  || bad "P1: the pipeline (flatten) must run the '# >>> split child check' block exactly once"

echo "size-gate-split-child.bh-851-test: $PASS pass, $FAIL fail"
[ "$FAIL" = 0 ]
