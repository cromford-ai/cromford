#!/bin/bash
# tests/run-rollout.bh-1335-test.sh — BH-1335: resume a partially filed rollout,
# close two parser holes, harden `after:`.
#
# Drives a byte copy of the repo's bin/run-rollout.sh and bin/lib/file-children.sh
# out of a scratch checkout ($T/co), against a scratch $HARNESS ($T/h), with a
# lane-module stub BESIDE the copied library (never in $HARNESS/bin/lib — that is
# the resolution rule BH-1347 pinned). The stub's failure point is injectable
# (STUB_FAIL_ON=<n>, STUB_SILENT=1) so the partial-filing runs are REAL runs of
# the script, not simulations of one. $T/co-real carries the REAL
# bin/lib/fc-issues.sh for the dry-run-over-a-partial-record case.
#
# Assertions are on the artifacts the script writes — children.json,
# children.txt, rollout-run.txt, parse.err, pipeline.log, filer-call.txt — never
# on source text, except E2 (which is a note the ticket asked for) and L1 (which
# lints the repo's own files).
#
# Run with no arguments for the whole suite, or --filter <name>:
#   lints, hidden-pre, midline-h3, after-edges, resume, never-green,
#   regression, pins.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

FILTER=""
if [ "${1:-}" = "--filter" ]; then FILTER="${2:-}"; fi
run_section() { [ -z "$FILTER" ] || [ "$FILTER" = "$1" ]; }

ROLLOUT_SRC="$DIR/bin/run-rollout.sh"
LIB_SRC="$DIR/bin/lib/file-children.sh"
ROLLOUT="$T/co/bin/run-rollout.sh"
ROLLOUT_REAL="$T/co-real/bin/run-rollout.sh"
FIX="$DIR/tests/fixtures/run-rollout"

# --------------------------------------------------------------------------
# scratch harness + two scratch checkouts
# --------------------------------------------------------------------------
mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/env"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
scoutish      example-org/scoutish   https://scoutish.example  -  9 box-1 10.0.0.9
CONF
export FLEET_CONF="$T/h/fleet.conf"

cat > "$T/h/bin/gh" <<'SH'
#!/bin/bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then cat "$GH_BODY"; exit 0; fi
echo "gh stub: $*" >&2; exit 1
SH
chmod +x "$T/h/bin/gh"

mkdir -p "$T/co/bin/lib" "$T/co-real/bin/lib"
for co in "$T/co" "$T/co-real"; do
  cp "$ROLLOUT_SRC" "$co/bin/"; chmod +x "$co/bin/run-rollout.sh"
  cp "$LIB_SRC" "$co/bin/lib/"
  cp "$DIR/bin/fleet-conf.sh" "$co/bin/"
done
cp "$DIR/bin/lib/fc-issues.sh" "$T/co-real/bin/lib/"

# The injectable stub. resume_from is the number of keys already on the record
# when the filer was entered, which is what §R2 asserts the resume hands it.
cat > "$T/co/bin/lib/fc-issues.sh" <<'SH'
#!/bin/bash
# shellcheck shell=bash
fc_file_issues() {
  local n k done_n
  done_n=$(grep -c '[^[:space:]]' "$FC_BUILD/children.txt" 2>/dev/null || true)
  case "${done_n:-}" in ''|*[!0-9]*) done_n=0 ;; esac
  printf 'lane=issues project=%s parent=%s key=%s kind=%s resume_from=%s\n' \
    "$FC_PROJECT" "$FC_PARENT" "$FC_KEY" "$FC_KIND" "$done_n" >> "$FC_BUILD/filer-call.txt"
  if [ "${STUB_SILENT:-0}" = 1 ]; then return 0; fi
  n=$(jq 'length' "$FC_SPEC" 2>/dev/null); case "${n:-}" in ''|*[!0-9]*) n=0 ;; esac
  k=$((done_n + 1))
  while [ "$k" -le "$n" ]; do
    if [ "$k" = "${STUB_FAIL_ON:-}" ]; then
      FC_ERROR="stub filer failed on child $k"
      fc_log "$FC_BUILD" "$FC_ERROR"
      return 1
    fi
    printf 'FAKE-90%s\n' "$k" >> "$FC_BUILD/children.txt"
    k=$((k + 1))
  done
  return 0
}
SH
chmod +x "$T/co/bin/lib/fc-issues.sh"

# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------
# drive <script> <build-dir> <fixture> [VAR=VAL ...] — rc is the script's rc.
drive() {
  local script="$1" b="$2" fx="$3"; shift 3
  mkdir -p "$b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY="$FIX/$fx" DECOMPOSE_DRY_RUN=1 "$@" \
      "$script" scoutish 552 TK-552 "$b" >"$b/stdout.txt" 2>&1 )
}
# fresh <build-dir> — a build dir with nothing in it. scratch_rm, never a bare
# rm -rf: it refuses any path that is not inside $T.
fresh() { scratch_rm "$1" || exit 1; mkdir -p "$1"; }
keys()  { grep -c '[^[:space:]]' "$1/children.txt" 2>/dev/null || true; }
calls() { grep -c . "$1/filer-call.txt" 2>/dev/null || true; }
last_result() { grep '^RESULT ' "$1/rollout-run.txt" 2>/dev/null | tail -1; }

# --------------------------------------------------------------------------
# L1 — lints, on the REPO's files (a lint is about what ships)
# --------------------------------------------------------------------------
l1_lints() {
  bash -n "$ROLLOUT_SRC" 2>/dev/null && ok || bad "bash -n bin/run-rollout.sh: $(bash -n "$ROLLOUT_SRC" 2>&1)"
  bash -n "$LIB_SRC" 2>/dev/null && ok || bad "bash -n bin/lib/file-children.sh: $(bash -n "$LIB_SRC" 2>&1)"
  if command -v shellcheck >/dev/null 2>&1; then
    SC=$(shellcheck -S error "$ROLLOUT_SRC" "$LIB_SRC" 2>&1) && ok || bad "shellcheck -S error: $SC"
  else
    echo "note: shellcheck absent — L1 shellcheck assertion did not run"
  fi
}

# --------------------------------------------------------------------------
# P — the unclosed backtick span stops eating HTML block markers
# --------------------------------------------------------------------------
p1_hidden_pre_detector() {
  "$ROLLOUT" --is-rollout "$FIX/bh-1335-hidden-pre.md" >"$T/iso.out" 2>&1; RC=$?
  [ "$RC" -eq 1 ] && ok || bad "P1: --is-rollout on a <pre> hidden behind a stray backtick must be rc 1 (rc=$RC)"
  [ ! -s "$T/iso.out" ] && ok || bad "P1: --is-rollout printed output: $(cat "$T/iso.out")"
  fresh "$T/p1"; drive "$ROLLOUT" "$T/p1" bh-1335-hidden-pre.md; RC=$?
  [ "$RC" -eq 0 ] && ok || bad "P1: the lane must fall through as not-a-rollout (rc=$RC)"
  grep -q 'ROLLOUT_NO_SECTION' "$T/p1/pipeline.log" 2>/dev/null \
    && ok || bad "P1: pipeline.log must carry ROLLOUT_NO_SECTION: $(cat "$T/p1/pipeline.log" 2>/dev/null)"
  [ ! -e "$T/p1/children.json" ] && ok || bad "P1: must write no children.json"
  [ ! -e "$T/p1/filer-call.txt" ] && ok || bad "P1: must make no filer call"
}

p2_hidden_pre_parser() {
  fresh "$T/p2"; drive "$ROLLOUT" "$T/p2" bh-1335-hidden-pre-midbody.md; RC=$?
  [ "$RC" -eq 1 ] && ok || bad "P2: a <pre> hidden mid-section must refuse (rc=$RC)"
  [ "$(head -1 "$T/p2/parse.err" 2>/dev/null)" = "unterminated code block" ] \
    && ok || bad "P2: parse.err reason: $(cat "$T/p2/parse.err" 2>/dev/null)"
  [ ! -e "$T/p2/children.json" ] && ok || bad "P2: must write no children.json"
  [ ! -e "$T/p2/filer-call.txt" ] && ok || bad "P2: must make no filer call"
}

p3_balanced_and_close_tags() {
  # A BALANCED mention is untouched: all three waves still file.
  fresh "$T/p3"; drive "$ROLLOUT" "$T/p3" backticked-pre-mention.md; RC=$?
  [ "$RC" -eq 0 ] && ok || bad "P3: a balanced \`<pre><code>\` mention must still file (rc=$RC)"
  [ "$(jq 'length' "$T/p3/children.json" 2>/dev/null)" = 3 ] \
    && ok || bad "P3: balanced mention wave count"
  # An unclosed span whose remainder holds no tag still drops to end of line.
  OUT=$( . "$LIB_SRC"; printf 'a `b` c `d\n' | fc_strip_fences )
  [ "$OUT" = "a  c " ] && ok || bad "P3: unclosed span with no tag must be unchanged, got '$OUT'"
  # A CLOSE tag in the dropped remainder is deliberately NOT re-emitted: that is
  # the one direction that could OPEN the lane.
  OUT=$( . "$LIB_SRC"; printf 'a `x </pre> y\n' | fc_strip_fences )
  case "$OUT" in *'</pre>'*) bad "P3: a dropped </pre> must not be re-emitted, got '$OUT'" ;; *) ok ;; esac
}

# --------------------------------------------------------------------------
# H — a mid-line <h2>/<h3> inside the section refuses
# --------------------------------------------------------------------------
h1_midline() {
  fresh "$T/h1"; drive "$ROLLOUT" "$T/h1" bh-1335-midline-h3.md; RC=$?
  [ "$RC" -eq 1 ] && ok || bad "H1: a mid-line <h3> in the section must refuse (rc=$RC)"
  [ "$(head -1 "$T/h1/parse.err" 2>/dev/null)" = "mid-line heading tag" ] \
    && ok || bad "H1: parse.err reason: $(cat "$T/h1/parse.err" 2>/dev/null)"
  [ ! -e "$T/h1/children.json" ] && ok || bad "H1: must write no children.json"
  [ ! -e "$T/h1/filer-call.txt" ] && ok || bad "H1: must make no filer call"
}

h2_whole_line_tags() {
  fresh "$T/h2"; drive "$ROLLOUT" "$T/h2" html.md; RC=$?
  [ "$RC" -eq 0 ] && ok || bad "H2: whole-line <h3> tags are the board's normal shape (rc=$RC)"
  [ "$(last_result "$T/h2")" = 'RESULT "ROLLOUT_FILED 3"' ] \
    && ok || bad "H2: html.md result: $(last_result "$T/h2")"
}

h3_preamble_tag() {
  fresh "$T/h3"; drive "$ROLLOUT" "$T/h3" bh-1335-preamble-h3.md; RC=$?
  [ "$RC" -eq 0 ] && ok || bad "H3: an inline <h3> in the PREAMBLE must not refuse (rc=$RC)"
  [ "$(last_result "$T/h3")" = 'RESULT "ROLLOUT_FILED 2"' ] \
    && ok || bad "H3: preamble result: $(last_result "$T/h3")"
}

# --------------------------------------------------------------------------
# A — the three `after:` edge cases
# --------------------------------------------------------------------------
a1_indented_after() {
  fresh "$T/a1"; drive "$ROLLOUT" "$T/a1" bh-1335-after-indented.md; RC=$?
  [ "$RC" -eq 1 ] && ok || bad "A1: an indented after: line must refuse (rc=$RC)"
  [ "$(head -1 "$T/a1/parse.err" 2>/dev/null)" = "indented after: line" ] \
    && ok || bad "A1: parse.err reason: $(cat "$T/a1/parse.err" 2>/dev/null)"
  ! grep -qE 'unknown dependency|too few waves' "$T/a1/parse.err" 2>/dev/null \
    && ok || bad "A1: the refusal must not use a misleading reason: $(cat "$T/a1/parse.err" 2>/dev/null)"
  [ ! -e "$T/a1/children.json" ] && ok || bad "A1: must write no children.json"
}

a1b_spaced_after() {
  # 1-3 spaces is a legal markdown indent, not a code block: it parses.
  fresh "$T/a1b"; drive "$ROLLOUT" "$T/a1b" bh-1335-after-spaced.md; RC=$?
  [ "$RC" -eq 0 ] && ok || bad "A1b: a 2-space after: line must parse (rc=$RC): $(cat "$T/a1b/parse.err" 2>/dev/null)"
  [ "$(jq -c '[.[].after]' "$T/a1b/children.json" 2>/dev/null)" = "[[],[1]]" ] \
    && ok || bad "A1b: after list: $(jq -c '[.[].after]' "$T/a1b/children.json" 2>/dev/null)"
  grep -q 'after:' <<<"$(jq -r '.[1].body' "$T/a1b/children.json" 2>/dev/null)" \
    && bad "A1b: the consumed after: line must not stay in the body" || ok
}

a2_duplicate_after() {
  fresh "$T/a2"; drive "$ROLLOUT" "$T/a2" bh-1335-after-duplicate.md; RC=$?
  [ "$RC" -eq 0 ] && ok || bad "A2: 'after: a, a' must parse (rc=$RC): $(cat "$T/a2/parse.err" 2>/dev/null)"
  [ "$(jq -c '[.[].after]' "$T/a2/children.json" 2>/dev/null)" = "[[],[1]]" ] \
    && ok || bad "A2: duplicates must dedupe, got $(jq -c '[.[].after]' "$T/a2/children.json" 2>/dev/null)"
}

a3_empty_after() {
  for fx in bh-1335-after-empty.md bh-1335-after-empty-ws.md; do
    fresh "$T/a3"; drive "$ROLLOUT" "$T/a3" "$fx"; RC=$?
    [ "$RC" -eq 1 ] && ok || bad "A3: $fx — an empty after: must refuse (rc=$RC)"
    [ "$(head -1 "$T/a3/parse.err" 2>/dev/null)" = "empty after: list" ] \
      && ok || bad "A3: $fx parse.err reason: $(cat "$T/a3/parse.err" 2>/dev/null)"
    [ ! -e "$T/a3/children.json" ] && ok || bad "A3: $fx must write no children.json"
  done
}

a4_existing_after_reasons() {
  check() { # check <fixture> <expected parse.err first line>
    fresh "$T/a4"; drive "$ROLLOUT" "$T/a4" "$1" >/dev/null 2>&1
    [ "$(head -1 "$T/a4/parse.err" 2>/dev/null)" = "$2" ] \
      && ok || bad "A4: $1 reason changed: got '$(head -1 "$T/a4/parse.err" 2>/dev/null)', want '$2'"
  }
  check after-self.md "self dependency"
  check after-later.md "forward dependency"
  check after-unknown.md 'unknown dependency "missing" (known: "first", "second")'
  # deeper-after: the after: line is not the first body line, so it is prose.
  fresh "$T/a4d"; drive "$ROLLOUT" "$T/a4d" deeper-after.md; RC=$?
  [ "$RC" -eq 0 ] && ok || bad "A4: deeper-after must still file (rc=$RC)"
  [ "$(jq -c '.[1].after' "$T/a4d/children.json" 2>/dev/null)" = "[]" ] \
    && ok || bad "A4: deeper-after wave 2 after must stay empty"
  jq -r '.[1].body' "$T/a4d/children.json" 2>/dev/null | grep -q 'after: first' \
    && ok || bad "A4: deeper-after after: line must stay in the body"
  # canonical: two real dependencies, in order.
  fresh "$T/a4c"; drive "$ROLLOUT" "$T/a4c" canonical.md >/dev/null 2>&1
  [ "$(jq -c '[.[].after]' "$T/a4c/children.json" 2>/dev/null)" = "[[],[],[1,2]]" ] \
    && ok || bad "A4: canonical after lists: $(jq -c '[.[].after]' "$T/a4c/children.json" 2>/dev/null)"
}

# --------------------------------------------------------------------------
# R — the top gate resumes instead of returning green
# --------------------------------------------------------------------------
r_resume() {
  fresh "$T/r"
  # R1 — run 1 dies on child 2.
  drive "$ROLLOUT" "$T/r" issue-552.md STUB_FAIL_ON=2; RC=$?
  [ "$RC" -eq 1 ] && ok || bad "R1: a filer that dies must fail the run (rc=$RC)"
  [ "$(keys "$T/r")" = 1 ] && ok || bad "R1: children.txt must hold exactly 1 key, got $(keys "$T/r")"
  [ "$(last_result "$T/r")" = 'RESULT "ROLLOUT_FAILED filed 1 of 3 waves"' ] \
    && ok || bad "R1: result must carry the count: $(last_result "$T/r")"
  grep -q 'ROLLOUT_FILER_ERROR' "$T/r/pipeline.log" 2>/dev/null \
    && ok || bad "R1: the filer's own error must still reach pipeline.log"

  # R2 — the same dir, healthy filer: it resumes.
  drive "$ROLLOUT" "$T/r" issue-552.md; RC=$?
  [ "$RC" -eq 0 ] && ok || bad "R2: the resumed run must succeed (rc=$RC): $(cat "$T/r/stdout.txt")"
  [ "$(calls "$T/r")" = 2 ] && ok || bad "R2: the filer must be called a second time, calls=$(calls "$T/r")"
  grep -q 'resume_from=1' "$T/r/filer-call.txt" 2>/dev/null \
    && ok || bad "R2: the filer must see the record: $(cat "$T/r/filer-call.txt" 2>/dev/null)"
  [ "$(keys "$T/r")" = 3 ] && ok || bad "R2: children.txt must hold 3 keys, got $(keys "$T/r")"
  [ "$(last_result "$T/r")" = 'RESULT "ROLLOUT_FILED 3"' ] \
    && ok || bad "R2: result: $(last_result "$T/r")"
  grep -q 'ROLLOUT_RESUME TK-552 (1 of 3 waves already filed)' "$T/r/pipeline.log" 2>/dev/null \
    && ok || bad "R2: pipeline.log must name the resume: $(grep ROLLOUT_ "$T/r/pipeline.log" 2>/dev/null)"

  # R3 — a complete record is still idempotent, and now says so truthfully.
  BEFORE=$(calls "$T/r")
  drive "$ROLLOUT" "$T/r" issue-552.md; RC=$?
  [ "$RC" -eq 0 ] && ok || bad "R3: a complete record must exit 0 (rc=$RC)"
  [ "$(calls "$T/r")" = "$BEFORE" ] && ok || bad "R3: the filer must not be called again"
  [ "$(last_result "$T/r")" = 'RESULT "ROLLOUT_FILED 3"' ] \
    && ok || bad "R3: an already-filed run must still state its result: $(last_result "$T/r")"
  grep -q 'ROLLOUT_ALREADY_FILED TK-552 (3 of 3 waves on the record)' "$T/r/pipeline.log" 2>/dev/null \
    && ok || bad "R3: pipeline.log must carry the count: $(grep ROLLOUT_ALREADY "$T/r/pipeline.log" 2>/dev/null)"

  # R4 — a record with no readable spec refuses; absent is not zero.
  fresh "$T/r4"; printf 'TK-701\n' > "$T/r4/children.txt"
  drive "$ROLLOUT" "$T/r4" issue-552.md; RC=$?
  [ "$RC" -eq 1 ] && ok || bad "R4: a record with no children.json must refuse (rc=$RC)"
  case "$(last_result "$T/r4")" in
    *'no readable children.json'*) ok ;;
    *) bad "R4: result: $(last_result "$T/r4")" ;;
  esac
  [ "$(cat "$T/r4/children.txt")" = "TK-701" ] && ok || bad "R4: children.txt must be untouched"
  [ ! -e "$T/r4/filer-call.txt" ] && ok || bad "R4: the filer must not be called"
}

# --------------------------------------------------------------------------
# N — never a green partial
# --------------------------------------------------------------------------
n_never_green() {
  # N1 — a resumed run whose filer dies on child 3.
  fresh "$T/n1"
  drive "$ROLLOUT" "$T/n1" issue-552.md STUB_FAIL_ON=2 >/dev/null 2>&1
  drive "$ROLLOUT" "$T/n1" issue-552.md STUB_FAIL_ON=3; RC=$?
  [ "$RC" -eq 1 ] && ok || bad "N1: a partial resume must fail (rc=$RC)"
  [ "$(last_result "$T/n1")" = 'RESULT "ROLLOUT_FAILED filed 2 of 3 waves"' ] \
    && ok || bad "N1: result: $(last_result "$T/n1")"

  # N2 — the RECORD decides, not the filer's rc: a filer that returns 0 while
  # appending nothing is still a partial.
  fresh "$T/n2"
  drive "$ROLLOUT" "$T/n2" issue-552.md STUB_FAIL_ON=2 >/dev/null 2>&1
  drive "$ROLLOUT" "$T/n2" issue-552.md STUB_SILENT=1; RC=$?
  [ "$RC" -eq 1 ] && ok || bad "N2: a silent rc-0 filer must not make the run green (rc=$RC)"
  [ "$(last_result "$T/n2")" = 'RESULT "ROLLOUT_FAILED filed 1 of 3 waves"' ] \
    && ok || bad "N2: result: $(last_result "$T/n2")"

  # N3 — DRY over a partial record, with the REAL bin/lib/fc-issues.sh, whose
  # dry arm returns 0 without filing anything when children.txt is non-empty.
  fresh "$T/gen"; drive "$ROLLOUT" "$T/gen" issue-552.md >/dev/null 2>&1
  fresh "$T/n3"
  cp "$T/gen/children.json" "$T/n3/children.json" 2>/dev/null
  printf 'TK-553\n' > "$T/n3/children.txt"
  drive "$ROLLOUT_REAL" "$T/n3" issue-552.md; RC=$?
  [ "$RC" -eq 1 ] && ok || bad "N3: a dry resume over a partial record must not be green (rc=$RC)"
  ! grep -q 'ROLLOUT_FILED' "$T/n3/rollout-run.txt" 2>/dev/null \
    && ok || bad "N3: no ROLLOUT_FILED may be printed: $(cat "$T/n3/rollout-run.txt" 2>/dev/null)"
  case "$(last_result "$T/n3")" in
    *'filed 1 of 3 waves'*) ok ;;
    *) bad "N3: result: $(last_result "$T/n3")" ;;
  esac
}

# --------------------------------------------------------------------------
# G1 — regression sweep: every lane fixture keeps the answer it has today.
# NONE means the no-section path: no rollout-run.txt at all.
# --------------------------------------------------------------------------
g1_regression() {
  while IFS='|' read -r fx want; do
    [ -n "$fx" ] || continue
    fresh "$T/g"; drive "$ROLLOUT" "$T/g" "$fx" >/dev/null 2>&1
    got=$(last_result "$T/g"); [ -n "$got" ] || got="NONE"
    if [ "$want" = "NONE" ]; then
      [ "$got" = "NONE" ] && ok || bad "G1: $fx — want no result line, got $got"
    else
      [ "$got" = "RESULT \"$want\"" ] && ok || bad "G1: $fx — want RESULT \"$want\", got $got"
    fi
  done <<'TABLE'
canonical.md|ROLLOUT_FILED 3
issue-552.md|ROLLOUT_FILED 3
lower.md|ROLLOUT_FILED 3
html.md|ROLLOUT_FILED 3
pre-code-block.md|ROLLOUT_FILED 3
indented-code.md|ROLLOUT_FILED 3
backticked-pre-mention.md|ROLLOUT_FILED 3
code-preserved.md|ROLLOUT_FILED 2
deeper-after.md|ROLLOUT_FILED 2
rollout-titled-wave.md|ROLLOUT_FILED 2
trailing-sections.md|ROLLOUT_FILED 2
one-wave.md|ROLLOUT_FAILED too few waves
no-waves.md|ROLLOUT_FAILED no waves
thirteen-waves.md|ROLLOUT_FAILED too many waves
duplicate-titles.md|ROLLOUT_FAILED duplicate title
nested-rollout.md|ROLLOUT_FAILED nested rollout
duplicate-rollout-section.md|ROLLOUT_FAILED duplicate rollout section
after-self.md|ROLLOUT_FAILED self dependency
after-later.md|ROLLOUT_FAILED forward dependency
after-unknown.md|ROLLOUT_FAILED unknown dependency "missing" (known: "first", "second")
unclosed-fence.md|ROLLOUT_FAILED unterminated code block
unclosed-pre.md|ROLLOUT_FAILED unterminated code block
no-section.md|NONE
empty-body.md|NONE
TABLE
  # The detector corpus keeps its answers too.
  for neg in is-rollout-fenced.md is-rollout-tilde-fence.md is-rollout-html-block.md \
             is-rollout-blockquote.md is-rollout-risk.md is-rollout-prose.md; do
    "$ROLLOUT" --is-rollout "$FIX/$neg" >/dev/null 2>&1
    [ $? -eq 1 ] && ok || bad "G1: --is-rollout $neg must stay a negative"
  done
  "$ROLLOUT" --is-rollout "$FIX/is-rollout-positive.md" >/dev/null 2>&1
  [ $? -eq 0 ] && ok || bad "G1: --is-rollout positive must stay positive"
}

# --------------------------------------------------------------------------
# E — the two pins the ticket asks for
# --------------------------------------------------------------------------
e1_env_path_pin() {
  # Ticket item 4: tests/env-path-test.sh must be in the gate set every diff
  # runs. It is derived, not listed — this is the pin that a change to the
  # detector cannot quietly drop it.
  if [ ! -x "$DIR/bin/test-impact.sh" ]; then
    bad "E1: bin/test-impact.sh is missing"; return
  fi
  ALWAYS=$(HARNESS_TEST_SANDBOX=1 "$DIR/bin/test-impact.sh" always --root "$DIR" 2>/dev/null)
  grep -qx 'tests/env-path-test.sh' <<<"$ALWAYS" \
    && ok || bad "E1: bin/test-impact.sh always must yield tests/env-path-test.sh"
}

e2_graphql_note() {
  # Ticket item 3, note only: the gh issue view read is GraphQL-backed and is
  # ticket-specified. Guarded against the absent-symbol case: if the call site
  # itself moves, this fails rather than silently passing.
  LN=$(grep -n 'gh issue view' "$ROLLOUT_SRC" | head -1 | cut -d: -f1)
  if [ -z "$LN" ]; then bad "E2: the gh issue view call site is gone"; return; fi
  START=$((LN > 8 ? LN - 8 : 1))
  sed -n "${START},${LN}p" "$ROLLOUT_SRC" | grep -qi 'graphql' \
    && ok || bad "E2: no GraphQL note above the gh issue view call at line $LN"
}

e3_test_home() {
  if [ -r "$DIR/bin/lib/test-home-lib.sh" ]; then
    # shellcheck source=bin/lib/test-home-lib.sh
    . "$DIR/bin/lib/test-home-lib.sh" 2>/dev/null
    if command -v th_is_own >/dev/null 2>&1; then
      th_is_own tests/run-rollout.bh-1335-test.sh BH-1335 \
        && ok || bad "E3: suite must be BH-1335's own test file"
    fi
  fi
}

# --------------------------------------------------------------------------
# dispatch
# --------------------------------------------------------------------------
run_section lints      && l1_lints
if run_section hidden-pre; then p1_hidden_pre_detector; p2_hidden_pre_parser; p3_balanced_and_close_tags; fi
if run_section midline-h3; then h1_midline; h2_whole_line_tags; h3_preamble_tag; fi
if run_section after-edges; then a1_indented_after; a1b_spaced_after; a2_duplicate_after; a3_empty_after; a4_existing_after_reasons; fi
run_section resume      && r_resume
run_section never-green && n_never_green
run_section regression  && g1_regression
if run_section pins; then e1_env_path_pin; e2_graphql_note; e3_test_home; fi

echo "run-rollout.bh-1335: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
