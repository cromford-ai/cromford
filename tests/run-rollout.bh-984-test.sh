#!/bin/bash
# tests/run-rollout.bh-984-test.sh — bin/run-rollout.sh, deterministic wave parser.
#
# Drives a byte copy of the repo's script (and of the library it sources) out of
# a scratch checkout, against a scratch harness, so no network, no real board
# and no gh/curl binary is reached. Asserts on the artifacts the script writes:
# children.json, children.txt, rollout-run.txt, rollout-comment.md, and the
# filer call log. The lints in A1 read the repo's own file, not the copy.
#
# Run with no arguments for the whole suite, or with --filter <name> for a
# single VALIDATE command from plan.md:
#   is-rollout, no-section, canonical, refusals, negatives, filing,
#   idempotency, artifacts.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 || { echo "jq missing — skipping"; exit 0; }

FILTER=""
if [ "${1:-}" = "--filter" ]; then
  FILTER="${2:-}"
fi

# helper: true if the current filter is empty or matches the section name
run_section() {
  [ -z "$FILTER" ] || [ "$FILTER" = "$1" ]
}

# ---------------------------------------------------------------------------
# scratch harness ($T/h) and a scratch CHECKOUT ($T/co)
#
# THE DRIVES RUN A COPY of bin/run-rollout.sh and bin/lib/file-children.sh out
# of $T/co, and the lane-module stubs are written BESIDE the copied library, in
# $T/co/bin/lib — the layout tests/file-children.bh-981-test.sh (A8, $T/own) and
# tests/fc-issues.bh-982-test.sh already use. $T/h stays the scratch $HARNESS
# (fleet.conf, env, the gh/curl stubs) and its bin/lib holds NO lane module at
# all. That separation is the point: file_children's rule is "the module beside
# the library I was sourced from wins, $HARNESS/bin/lib is the fallback", and
# stubbing into $HARNESS/bin/lib would leave the suite green under either that
# rule or a $HARNESS-only one (BH-1347). Here only the beside-first rule passes.
# A1 still lints the repo's own script through $ROLLOUT_SRC.
# ---------------------------------------------------------------------------
ROLLOUT_SRC="$DIR/bin/run-rollout.sh"
ROLLOUT="$T/co/bin/run-rollout.sh"

mkdir -p "$T/h/bin/lib" "$T/h/logs" "$T/h/env" "$T/h/prompts"
cp "$DIR/bin/fleet-conf.sh" "$T/h/bin/"

mkdir -p "$T/co/bin/lib"
cp "$ROLLOUT_SRC" "$T/co/bin/"
chmod +x "$T/co/bin/run-rollout.sh"
cp "$DIR/bin/lib/file-children.sh" "$T/co/bin/lib/"
# file_children resolves fleet-conf.sh at `<its own dir>/../fleet-conf.sh`
# before it falls back to $HARNESS, same as BH-981's $T/bare tree.
cp "$DIR/bin/fleet-conf.sh" "$T/co/bin/"
cat > "$T/h/fleet.conf" <<'CONF'
# <project> <repo> <prod> <board-api-prefix> <offset> [box] [ip]
scoutish      example-org/scoutish   https://scoutish.example  -           9 box-1 10.0.0.9
widget-os     example-org/widget-os  https://widget.example    /api/board  2 box-1 10.0.0.2
CONF
export FLEET_CONF="$T/h/fleet.conf"

cat > "$T/co/bin/lib/fc-issues.sh" <<'SH'
#!/bin/bash
# shellcheck shell=bash
fc_file_issues() {
  printf 'lane=issues project=%s parent=%s key=%s kind=%s\n' "$FC_PROJECT" "$FC_PARENT" "$FC_KEY" "$FC_KIND" >> "$FC_BUILD/filer-call.txt"
  if fc_dry; then
    # Simulates the real filer (#982): children.txt carries the BOARD's own
    # keys for the filed children, never the KEY.<n> title label
    # (bin/run-decompose.sh:502, BH-984 C2).
    i=1
    while [ "$i" -le 3 ]; do
      printf 'FAKE-90%s\n' "$i" >> "$FC_BUILD/children.txt"
      i=$((i + 1))
    done
  fi
  return 0
}
SH
cat > "$T/co/bin/lib/fc-board.sh" <<'SH'
#!/bin/bash
# shellcheck shell=bash
fc_file_board() {
  printf 'lane=board project=%s parent=%s key=%s kind=%s\n' "$FC_PROJECT" "$FC_PARENT" "$FC_KEY" "$FC_KIND" >> "$FC_BUILD/filer-call.txt"
  if fc_dry; then
    # Same simulated board-key shape as fc_file_issues above.
    i=1
    while [ "$i" -le 3 ]; do
      printf 'FAKE-90%s\n' "$i" >> "$FC_BUILD/children.txt"
      i=$((i + 1))
    done
  fi
  return 0
}
SH
chmod +x "$T/co/bin/lib/fc-issues.sh" "$T/co/bin/lib/fc-board.sh"

# $T/co-noboard mirrors the repo for the A12 "no filer" case: bin/lib/fc-issues.sh
# ships, bin/lib/fc-board.sh does not. A widget-os drive out of this tree is an
# honest filer-unavailable, so nothing in this suite has to delete a stub to
# provoke rc 3 (BH-1347).
mkdir -p "$T/co-noboard/bin/lib"
cp "$ROLLOUT_SRC" "$T/co-noboard/bin/"
chmod +x "$T/co-noboard/bin/run-rollout.sh"
cp "$DIR/bin/lib/file-children.sh" "$T/co-noboard/bin/lib/"
cp "$DIR/bin/fleet-conf.sh" "$T/co-noboard/bin/"
cp "$T/co/bin/lib/fc-issues.sh" "$T/co-noboard/bin/lib/"

cat > "$T/h/bin/gh" <<'SH'
#!/bin/bash
if [ "$1" = "issue" ] && [ "$2" = "view" ]; then
  cat "$GH_BODY_552"
  exit 0
fi
echo "gh stub: $*" >&2; exit 1
SH
cat > "$T/h/bin/curl" <<'SH'
#!/bin/bash
cat "$CURL_BODY_2"
exit 0
SH
chmod +x "$T/h/bin/gh" "$T/h/bin/curl"

cat > "$T/h/env/widget-os.env" <<'CONF'
WIDGET_INTERNAL_API_TOKEN=tk
WIDGET_API_BASE=https://widget.example
CONF

FIX="$DIR/tests/fixtures/run-rollout"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
run() { # run <project> <ticket> <key> [extra env assignments as separate args]
  local p="$1" t="$2" k="$3"; shift 3
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/issue-552.md" CURL_BODY_2="$FIX/board-2.json" \
      "$@" "$ROLLOUT" "$p" "$t" "$k" "$T/b" )
}

count_filer_calls() { wc -l < "$T/b/filer-call.txt" 2>/dev/null | tr -d ' ' || echo 0; }

# Generate the canonical children.json without counting assertions.
generate_canonical() {
  rm -rf "$T/gen"; mkdir -p "$T/gen"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/issue-552.md" CURL_BODY_2="$FIX/board-2.json" \
      DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/gen" >/dev/null 2>&1 ) || true
  cp "$T/gen/children.json" "$T/canonical.json" 2>/dev/null || :
}

# ---------------------------------------------------------------------------
# A1 — script lints
# ---------------------------------------------------------------------------
a1_lints() {
  # The REPO's script, not the copy the drives run: a lint is about what ships.
  if [ ! -x "$ROLLOUT_SRC" ]; then bad "bin/run-rollout.sh is missing or not executable"; return; fi
  bash -n "$ROLLOUT_SRC" 2>/dev/null && ok || bad "bash -n on run-rollout.sh: $(bash -n "$ROLLOUT_SRC" 2>&1)"
  if command -v shellcheck >/dev/null 2>&1; then
    SC=$(shellcheck -S error "$ROLLOUT_SRC" 2>&1) && ok || bad "shellcheck -S error: $SC"
  else
    echo "note: shellcheck absent — A1 shellcheck assertion did not run"
  fi
}

# ---------------------------------------------------------------------------
# A2 — --is-rollout flag
# ---------------------------------------------------------------------------
a2_is_rollout() {
  # $T/iso.out, not a fixed /tmp path: a fixed path races across parallel
  # suite runs (REMOTE_P, CI shards) sharing the same /tmp.
  is_rollout() { "$ROLLOUT" --is-rollout "$1" >"$T/iso.out" 2>&1; printf '%s' "$?"; }
  [ "$(is_rollout "$FIX/is-rollout-positive.md")" = 0 ] && ok || bad "--is-rollout positive"
  [ ! -s "$T/iso.out" ] && ok || bad "--is-rollout positive printed output"

  for neg in is-rollout-fenced.md is-rollout-tilde-fence.md is-rollout-html-block.md \
             is-rollout-blockquote.md is-rollout-risk.md is-rollout-prose.md; do
    rc=$(is_rollout "$FIX/$neg")
    [ "$rc" = 1 ] && ok || bad "--is-rollout negative $neg (rc=$rc)"
    [ ! -s "$T/iso.out" ] && ok || bad "--is-rollout negative $neg printed output"
  done
}

# ---------------------------------------------------------------------------
# A3 — canonical three-wave fixture
# ---------------------------------------------------------------------------
a3_canonical() {
  OUT=$(run scoutish 552 TK-552 DECOMPOSE_DRY_RUN=1 2>&1); RC=$?
  [ "$RC" -eq 0 ] && ok || bad "canonical dry run exit 0 (rc=$RC): $OUT"
  [ -s "$T/b/children.json" ] && ok || bad "canonical children.json missing"
  [ -s "$T/b/children.txt" ] && ok || bad "canonical children.txt missing"
  [ -s "$T/b/rollout-run.txt" ] && ok || bad "canonical rollout-run.txt missing"
  [ -s "$T/b/rollout-comment.md" ] && ok || bad "canonical rollout-comment.md missing"
  grep -q 'RESULT "ROLLOUT_FILED 3"' "$T/b/rollout-run.txt" \
    && ok || bad "canonical result line: $(cat "$T/b/rollout-run.txt" 2>/dev/null)"
  [ "$(tail -1 "$T/b/rollout-run.txt")" = 'RESULT "ROLLOUT_FILED 3"' ] \
    && ok || bad "canonical result line is last"
  [ "$(jq 'length' "$T/b/children.json")" = 3 ] \
    && ok || bad "canonical wave count"
  [ "$(jq -r '.[2].title' "$T/b/children.json")" = "wire hook" ] \
    && ok || bad "canonical wave 3 title"
  [ "$(jq -c '.[2].after' "$T/b/children.json")" = "[1,2]" ] \
    && ok || bad "canonical wave 3 after"
  ! grep -q 'Master description' <<<"$(jq -r '.[0].body, .[1].body, .[2].body' "$T/b/children.json")" \
    && ok || bad "master description leaked into child bodies"
  [ "$(count_filer_calls)" = 1 ] \
    && ok || bad "exactly one filer call (got $(count_filer_calls))"
  grep -q 'kind=rollout' "$T/b/filer-call.txt" \
    && ok || bad "filer call kind=rollout: $(cat "$T/b/filer-call.txt" 2>/dev/null)"
  grep -q 'lane=issues' "$T/b/filer-call.txt" \
    && ok || bad "issues lane resolved for scoutish"
  cp "$T/b/children.json" "$T/canonical.json"
}

# ---------------------------------------------------------------------------
# A4 — lower-case headings are byte-identical to canonical
# ---------------------------------------------------------------------------
a4_lower_case() {
  generate_canonical
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/lower.md" CURL_BODY_2="$FIX/board-2.json" \
      DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" >/dev/null 2>&1 ); RC=$?
  [ "$RC" -eq 0 ] && ok || bad "lower-case exit 0 (rc=$RC)"
  diff -q "$T/canonical.json" "$T/b/children.json" >/dev/null \
    && ok || bad "lower-case children.json differs from canonical"
}

# ---------------------------------------------------------------------------
# A5 — HTML <h2>/<h3> body is byte-identical to canonical
# ---------------------------------------------------------------------------
a5_html() {
  generate_canonical
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/html.md" CURL_BODY_2="$FIX/board-2.json" \
      DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" >/dev/null 2>&1 ); RC=$?
  [ "$RC" -eq 0 ] && ok || bad "html exit 0 (rc=$RC)"
  diff -q "$T/canonical.json" "$T/b/children.json" >/dev/null \
    && ok || bad "html children.json differs from canonical"
}

# ---------------------------------------------------------------------------
# A6 — in-app board lane path
# ---------------------------------------------------------------------------
a6_board() {
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/issue-552.md" CURL_BODY_2="$FIX/board-2.json" \
      DECOMPOSE_DRY_RUN=1 FILE_CHILDREN_DRY_RUN=1 "$ROLLOUT" widget-os 2 WO-2 "$T/b" >/dev/null 2>&1 ); RC=$?
  [ "$RC" -eq 0 ] && ok || bad "board lane exit 0 (rc=$RC)"
  [ -s "$T/b/children.json" ] && ok || bad "board lane children.json missing"
  grep -q 'lane=board' "$T/b/filer-call.txt" \
    && ok || bad "board lane resolved for widget-os: $(cat "$T/b/filer-call.txt" 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# A7 — no section heading
# ---------------------------------------------------------------------------
a7_no_section() {
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/no-section.md" CURL_BODY_2="$FIX/board-2.json" \
      DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" >/dev/null 2>&1 ); RC=$?
  [ "$RC" -eq 0 ] && ok || bad "no-section exit 0 (rc=$RC)"
  [ -e "$T/b/children.json" ] && bad "no-section must not write children.json" || ok
  [ -e "$T/b/rollout-run.txt" ] && bad "no-section must not write rollout-run.txt" || ok
  COUNT=$(grep -hR -E 'ROLLOUT_FILED|ROLLOUT_FAILED' "$T/b" 2>/dev/null | wc -l | tr -d ' ')
  [ "$COUNT" = 0 ] && ok || bad "no-section must not emit a result line anywhere (count=$COUNT)"
  [ ! -e "$T/b/filer-call.txt" ] && ok || bad "no-section must not call the filer"
}

# ---------------------------------------------------------------------------
# A8 — refusal cases
# ---------------------------------------------------------------------------
a8_refusals() {
  refuse() {
    local fixture="$1" reason_substring="$2"
    rm -rf "$T/b"; mkdir -p "$T/b"
    ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
        GH_BODY_552="$FIX/$fixture" CURL_BODY_2="$FIX/board-2.json" \
        DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" >/dev/null 2>&1 ); RC=$?
    [ "$RC" -ne 0 ] && ok || bad "$fixture refused exit nonzero (rc=$RC)"
    [ ! -e "$T/b/children.json" ] && ok || bad "$fixture refused must leave no children.json"
    [ ! -e "$T/b/filer-call.txt" ] && ok || bad "$fixture refused must make no filer call"
    grep -q "ROLLOUT_FAILED.*$reason_substring" "$T/b/rollout-run.txt" 2>/dev/null \
      && ok || bad "$fixture refused reason missing: $(cat "$T/b/rollout-run.txt" 2>/dev/null)"
  }
  refuse no-waves.md "no waves"
  refuse one-wave.md "too few"
  refuse thirteen-waves.md "too many"
  refuse duplicate-titles.md "duplicate"
  refuse nested-rollout.md "nested"
  refuse after-self.md "self"
  refuse after-later.md "forward"
  refuse after-unknown.md "unknown"
}

# ---------------------------------------------------------------------------
# A9 — deeper after: line is prose, not a dependency
# ---------------------------------------------------------------------------
a9_deeper_after() {
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/deeper-after.md" CURL_BODY_2="$FIX/board-2.json" \
      DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" >/dev/null 2>&1 ); RC=$?
  [ "$RC" -eq 0 ] && ok || bad "deeper-after exit 0 (rc=$RC)"
  [ "$(jq -c '.[1].after' "$T/b/children.json")" = "[]" ] \
    && ok || bad "deeper-after wave 2 after must be empty"
  jq -r '.[1].body' "$T/b/children.json" | grep -q 'after: first' \
    && ok || bad "deeper-after after line must stay in body"
}

# ---------------------------------------------------------------------------
# A10 — wave titled Rollout is an ordinary wave
# ---------------------------------------------------------------------------
a10_rollout_titled() {
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/rollout-titled-wave.md" CURL_BODY_2="$FIX/board-2.json" \
      DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" >/dev/null 2>&1 ); RC=$?
  [ "$RC" -eq 0 ] && ok || bad "rollout-titled-wave exit 0 (rc=$RC)"
  [ "$(jq 'length' "$T/b/children.json")" = 2 ] \
    && ok || bad "rollout-titled-wave wave count"
  [ "$(jq -r '.[0].title' "$T/b/children.json")" = "Rollout" ] \
    && ok || bad "rollout-titled-wave title preserved"
}

# ---------------------------------------------------------------------------
# A11 — idempotent second run skips filing
# ---------------------------------------------------------------------------
a11_idempotency() {
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/issue-552.md" CURL_BODY_2="$FIX/board-2.json" \
      DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" >/dev/null 2>&1 )
  [ -s "$T/b/children.txt" ] && ok || bad "first run wrote children.txt"
  FIRST_CALLS=$(count_filer_calls)
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/issue-552.md" CURL_BODY_2="$FIX/board-2.json" \
      DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" >/dev/null 2>&1 ); RC=$?
  [ "$RC" -eq 0 ] && ok || bad "second run exit 0 (rc=$RC)"
  SECOND_CALLS=$(count_filer_calls)
  [ "$FIRST_CALLS" = "$SECOND_CALLS" ] \
    && ok || bad "second run must not call filer again (first=$FIRST_CALLS second=$SECOND_CALLS)"
}

# ---------------------------------------------------------------------------
# A12 — file_children rc 3 → ROLLOUT_FAILED filer unavailable
# ---------------------------------------------------------------------------
a12_filer_unavailable() {
  # Driven out of $T/co-noboard, where fc-board.sh is absent BESIDE the library
  # and absent from $HARNESS/bin/lib too — the repo's own shape, so the board
  # lane is a truthful "no filer shipped for this lane". Nothing is deleted and
  # nothing has to be put back, which is what the old version of this case got
  # wrong (BH-1347): it removed the stubs every later section depends on.
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/issue-552.md" CURL_BODY_2="$FIX/board-2.json" \
      DECOMPOSE_DRY_RUN=1 "$T/co-noboard/bin/run-rollout.sh" widget-os 2 WO-2 "$T/b" >/dev/null 2>&1 ); RC=$?
  [ "$RC" -ne 0 ] && ok || bad "unimplemented filer exit nonzero (rc=$RC)"
  [ "$(tail -1 "$T/b/rollout-run.txt" 2>/dev/null)" = 'RESULT "ROLLOUT_FAILED filer unavailable"' ] \
    && ok || bad "unimplemented filer RESULT line is last: $(cat "$T/b/rollout-run.txt" 2>/dev/null)"
  [ "$(grep -c 'FILE_CHILDREN_UNIMPLEMENTED board' "$T/b/pipeline.log" 2>/dev/null)" = 1 ] \
    && ok || bad "exactly one FILE_CHILDREN_UNIMPLEMENTED board line: $(cat "$T/b/pipeline.log" 2>/dev/null)"
  [ "$(grep -c 'ROLLOUT_FILER_UNAVAILABLE widget-os/WO-2' "$T/b/pipeline.log" 2>/dev/null)" = 1 ] \
    && ok || bad "exactly one ROLLOUT_FILER_UNAVAILABLE line: $(cat "$T/b/pipeline.log" 2>/dev/null)"
  [ ! -e "$T/b/filer-call.txt" ] \
    && ok || bad "no lane function may have run: $(cat "$T/b/filer-call.txt" 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# A13 — comment voice: lists every wave, near-zero em dashes
# ---------------------------------------------------------------------------
a13_comment() {
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/issue-552.md" CURL_BODY_2="$FIX/board-2.json" \
      DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" >/dev/null 2>&1 )
  grep -q 'scaffold parser' "$T/b/rollout-comment.md" \
    && ok || bad "comment lists wave 1"
  grep -q 'add tests' "$T/b/rollout-comment.md" \
    && ok || bad "comment lists wave 2"
  grep -q 'wire hook' "$T/b/rollout-comment.md" \
    && ok || bad "comment lists wave 3"
  EM=$(grep -c '—' "$T/b/rollout-comment.md" 2>/dev/null)
  [ "$EM" -le 1 ] && ok || bad "too many em dashes in comment ($EM): $(cat "$T/b/rollout-comment.md")"
}

# ---------------------------------------------------------------------------
# A14 — this suite is its ticket's own file
# ---------------------------------------------------------------------------
a14_test_home() {
  if [ -x "$DIR/bin/lib/test-home-lib.sh" ]; then
    # shellcheck source=bin/lib/test-home-lib.sh
    . "$DIR/bin/lib/test-home-lib.sh" 2>/dev/null
    if command -v th_is_own >/dev/null 2>&1; then
      th_is_own tests/run-rollout.bh-984-test.sh BH-984 \
        && ok || bad "suite must be BH-984's own test file"
    fi
  fi
}

# ---------------------------------------------------------------------------
# A15 — untouched sibling files
# ---------------------------------------------------------------------------
a15_untouched() {
  BASE=$(cd "$DIR" && git merge-base origin/main HEAD 2>/dev/null || git merge-base main HEAD 2>/dev/null || true)
  # This arm judges BH-984's OWN slice; on any other branch (one that edits
  # bin/run-build.sh or bin/run-decompose.sh for its own ticket) it must stay
  # inert, so it bites only when the diff touches the ticket's spec or its
  # script. Same guard as file-children.bh-981's A11 (2026-09-22: #1113 and
  # #1114 went red here for touching their own tickets' drivers).
  if [ -n "$BASE" ]; then
    # pr-scoped: ok slice-gated: inert unless this branch carries BH-984's own slice
    TOUCHED=$(cd "$DIR" && git diff --name-only "$BASE"...HEAD 2>/dev/null; cd "$DIR" && git diff --name-only 2>/dev/null)
    if ! grep -qE '^(\.harness/specs/BH-984/|bin/run-rollout\.sh$)' <<<"$(printf '%s\n' "$TOUCHED")"; then
      echo "note: this branch is not BH-984's slice — the A15 untouched-files arm judges only the ticket's own branch"
    else
    FORBIDDEN=$(printf '%s\n' "$TOUCHED" | grep -xE 'bin/(run-decompose|run-build|triage-gate|run-triage|decompose-parent-close)\.sh' || true)
    [ -z "$FORBIDDEN" ] && ok || bad "forbidden sibling files touched:
$FORBIDDEN"
    fi
  else
    echo "note: no merge base — A15 untouched-files assertion did not run"
  fi
}

# ---------------------------------------------------------------------------
# A16 — code spans and fenced blocks survive verbatim in a wave body, and a
# heading-shaped line inside a fence does not open a wave (BH-984 C1)
# ---------------------------------------------------------------------------
a16_code_preserved() {
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/code-preserved.md" CURL_BODY_2="$FIX/board-2.json" \
      DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" >/dev/null 2>&1 ); RC=$?
  [ "$RC" -eq 0 ] && ok || bad "code-preserved exit 0 (rc=$RC)"
  [ "$(jq 'length' "$T/b/children.json" 2>/dev/null)" = 2 ] \
    && ok || bad "code-preserved wave count (a fenced fake heading must not open a third wave)"
  W1=$(jq -r '.[0].body' "$T/b/children.json" 2>/dev/null)
  grep -Fq '`npm test`' <<<"$W1" \
    && ok || bad "code-preserved wave 1 body lost an inline code span: $W1"
  grep -Fq '`bin/run-build.sh`' <<<"$W1" \
    && ok || bad "code-preserved wave 1 body lost a second inline code span: $W1"
  grep -Fq '```sh' <<<"$W1" \
    && ok || bad "code-preserved wave 1 body lost its fence marker: $W1"
  grep -Fq 'make all' <<<"$W1" \
    && ok || bad "code-preserved wave 1 body lost its fenced content: $W1"
  grep -Fq '### Wave 99: fake, not a real wave' <<<"$W1" \
    && ok || bad "code-preserved wave 1 body lost the fenced fake-heading line verbatim: $W1"
  [ "$(jq -r '.[1].title' "$T/b/children.json" 2>/dev/null)" = "finish" ] \
    && ok || bad "code-preserved wave 2 title (parsing must resume correctly after the fence closes)"
}

# ---------------------------------------------------------------------------
# A17 — a later ## section ends the rollout; it is not absorbed into the last
# wave's body (BH-984 I1)
# ---------------------------------------------------------------------------
a17_trailing_sections() {
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/trailing-sections.md" CURL_BODY_2="$FIX/board-2.json" \
      DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" >/dev/null 2>&1 ); RC=$?
  [ "$RC" -eq 0 ] && ok || bad "trailing-sections exit 0 (rc=$RC)"
  [ "$(jq 'length' "$T/b/children.json" 2>/dev/null)" = 2 ] \
    && ok || bad "trailing-sections wave count"
  W2=$(jq -r '.[1].body' "$T/b/children.json" 2>/dev/null)
  ! grep -q 'Notes' <<<"$(printf '%s' "$W2")" \
    && ok || bad "trailing-sections: a later ## Notes leaked into wave 2 body: $W2"
  ! grep -q 'belong to the master' <<<"$(printf '%s' "$W2")" \
    && ok || bad "trailing-sections: master text leaked into wave 2 body: $W2"
  ! grep -q 'Risks' <<<"$(printf '%s' "$W2")" \
    && ok || bad "trailing-sections: a later ## Risks leaked into wave 2 body: $W2"
}

# ---------------------------------------------------------------------------
# A18 — an empty body takes the no-section path, not a lane failure (BH-984 I4)
# ---------------------------------------------------------------------------
a18_empty_body() {
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/empty-body.md" CURL_BODY_2="$FIX/board-2.json" \
      DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" >/dev/null 2>&1 ); RC=$?
  [ "$RC" -eq 0 ] && ok || bad "empty-body exit 0 (rc=$RC)"
  [ -e "$T/b/children.json" ] && bad "empty-body must not write children.json" || ok
  [ -e "$T/b/rollout-run.txt" ] && bad "empty-body must not write rollout-run.txt" || ok
  COUNT=$(grep -hR -E 'ROLLOUT_FILED|ROLLOUT_FAILED' "$T/b" 2>/dev/null | wc -l | tr -d ' ')
  [ "$COUNT" = 0 ] && ok || bad "empty-body must not emit a result line anywhere (count=$COUNT)"
  [ ! -e "$T/b/filer-call.txt" ] && ok || bad "empty-body must not call the filer"
}

# ---------------------------------------------------------------------------
# A19 — early failure paths still write rollout-run.txt with RESULT last
# (BH-984 I2)
# ---------------------------------------------------------------------------
a19_early_failure_artifacts() {
  # fleet-conf missing: a HARNESS with no bin/fleet-conf.sh at all.
  rm -rf "$T/b" "$T/h-nofc"; mkdir -p "$T/b" "$T/h-nofc/bin"
  ( env HARNESS="$T/h-nofc" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      "$ROLLOUT" scoutish 552 TK-552 "$T/b" >/dev/null 2>&1 ); RC=$?
  [ "$RC" -ne 0 ] && ok || bad "fleet-conf-missing exit nonzero (rc=$RC)"
  [ -s "$T/b/rollout-run.txt" ] && ok || bad "fleet-conf-missing must still write rollout-run.txt"
  grep -q 'ROLLOUT_FAILED.*fleet-conf missing' "$T/b/rollout-run.txt" 2>/dev/null \
    && ok || bad "fleet-conf-missing reason: $(cat "$T/b/rollout-run.txt" 2>/dev/null)"
  [ "$(tail -1 "$T/b/rollout-run.txt" 2>/dev/null)" = 'RESULT "ROLLOUT_FAILED fleet-conf missing"' ] \
    && ok || bad "fleet-conf-missing RESULT line is last"

  # fleet-conf lookup failed: a project absent from fleet.conf.
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      "$ROLLOUT" ghostproj 1 GP-1 "$T/b" >/dev/null 2>&1 ); RC=$?
  [ "$RC" -ne 0 ] && ok || bad "fleet-conf-lookup-failed exit nonzero (rc=$RC)"
  [ -s "$T/b/rollout-run.txt" ] && ok || bad "fleet-conf-lookup-failed must still write rollout-run.txt"
  grep -q 'ROLLOUT_FAILED.*fleet-conf lookup failed' "$T/b/rollout-run.txt" 2>/dev/null \
    && ok || bad "fleet-conf-lookup-failed reason: $(cat "$T/b/rollout-run.txt" 2>/dev/null)"
  [ "$(tail -1 "$T/b/rollout-run.txt" 2>/dev/null)" = 'RESULT "ROLLOUT_FAILED fleet-conf lookup failed"' ] \
    && ok || bad "fleet-conf-lookup-failed RESULT line is last"
}

# ---------------------------------------------------------------------------
# A20 — an indented (4-space) heading-shaped line is body text, never a wave
# (BH-984 N1). Mirrors fc_has_rollout's own indent guard
# (bin/lib/file-children.sh:269-275) on the raw-body parser.
# ---------------------------------------------------------------------------
a20_indented_code() {
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/indented-code.md" CURL_BODY_2="$FIX/board-2.json" \
      DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" >/dev/null 2>&1 ); RC=$?
  [ "$RC" -eq 0 ] && ok || bad "indented-code exit 0 (rc=$RC)"
  [ "$(jq 'length' "$T/b/children.json" 2>/dev/null)" = 3 ] \
    && ok || bad "indented-code wave count (an indented heading-shaped line must not open a wave)"
  ! grep -qx 'indented code' <<<"$(jq -r '.[].title' "$T/b/children.json" 2>/dev/null)" \
    && ok || bad "indented-code filed a phantom wave titled 'indented code'"
  W2=$(jq -r '.[1].body' "$T/b/children.json" 2>/dev/null)
  grep -Fq '    ### Wave 9: indented code' <<<"$W2" \
    && ok || bad "indented-code wave 2 body lost the indented heading-shaped line verbatim: $W2"
  grep -Fq '    make all' <<<"$W2" \
    && ok || bad "indented-code wave 2 body lost the indented body line verbatim: $W2"
  [ "$(jq -r '.[2].title' "$T/b/children.json" 2>/dev/null)" = "third" ] \
    && ok || bad "indented-code wave 3 title (parsing must resume correctly after the indented block)"
}

# ---------------------------------------------------------------------------
# A21 — an HTML <pre><code> block is body text, never a wave or section end
# (BH-984 N2). A heading-shaped line AND a `## comment` line inside it must
# both stay inert, the way fc_strip_fences drops pre/code spans wholesale.
# ---------------------------------------------------------------------------
a21_pre_code_block() {
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/pre-code-block.md" CURL_BODY_2="$FIX/board-2.json" \
      DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" >/dev/null 2>&1 ); RC=$?
  [ "$RC" -eq 0 ] && ok || bad "pre-code-block exit 0 (rc=$RC)"
  [ "$(jq 'length' "$T/b/children.json" 2>/dev/null)" = 3 ] \
    && ok || bad "pre-code-block wave count (a heading-shaped line inside <pre><code> must not open a wave, and a ## line inside it must not end the section)"
  ! grep -qx 'phantom' <<<"$(jq -r '.[].title' "$T/b/children.json" 2>/dev/null)" \
    && ok || bad "pre-code-block filed a phantom wave titled 'phantom'"
  W2=$(jq -r '.[1].body' "$T/b/children.json" 2>/dev/null)
  grep -Fq '<pre><code>' <<<"$W2" \
    && ok || bad "pre-code-block wave 2 body lost the <pre><code> open tag: $W2"
  grep -Fq '### Wave 9: phantom' <<<"$W2" \
    && ok || bad "pre-code-block wave 2 body lost the fenced fake-heading line verbatim: $W2"
  grep -Fq '## comment line inside code' <<<"$W2" \
    && ok || bad "pre-code-block wave 2 body lost the fenced ## line verbatim: $W2"
  grep -Fq '</code></pre>' <<<"$W2" \
    && ok || bad "pre-code-block wave 2 body lost the </code></pre> close tag: $W2"
  [ "$(jq -r '.[2].title' "$T/b/children.json" 2>/dev/null)" = "third" ] \
    && ok || bad "pre-code-block wave 3 title (the ## line inside the block must not have ended the section)"
}

# ---------------------------------------------------------------------------
# A22 — a second `## Rollout`, separated from the first by another section,
# refuses instead of reopening and merging (BH-984 N3)
# ---------------------------------------------------------------------------
a22_duplicate_rollout_section() {
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/duplicate-rollout-section.md" CURL_BODY_2="$FIX/board-2.json" \
      DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" >/dev/null 2>&1 ); RC=$?
  [ "$RC" -ne 0 ] && ok || bad "duplicate-rollout-section refused exit nonzero (rc=$RC)"
  [ ! -e "$T/b/children.json" ] && ok || bad "duplicate-rollout-section refused must leave no children.json"
  [ ! -e "$T/b/filer-call.txt" ] && ok || bad "duplicate-rollout-section refused must make no filer call"
  grep -q 'ROLLOUT_FAILED.*duplicate' "$T/b/rollout-run.txt" 2>/dev/null \
    && ok || bad "duplicate-rollout-section refused reason missing: $(cat "$T/b/rollout-run.txt" 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# A23 — a backtick-wrapped mention of <pre>/<code> (e.g. "Strip `<pre><code>`
# spans here.") must not open pre/code block state; every wave still files
# (BH-984 N5, part 1). fc_strip_fences strips backtick spans per line BEFORE
# its <pre>/<code> pass, so the detector already sees all waves — the parser
# must mask backticks the same way before testing for an open/close tag.
# ---------------------------------------------------------------------------
a23_backtick_masked_precode() {
  rm -rf "$T/b"; mkdir -p "$T/b"
  ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
      GH_BODY_552="$FIX/backticked-pre-mention.md" CURL_BODY_2="$FIX/board-2.json" \
      DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" >/dev/null 2>&1 ); RC=$?
  [ "$RC" -eq 0 ] && ok || bad "backticked-pre-mention exit 0 (rc=$RC)"
  [ "$(jq 'length' "$T/b/children.json" 2>/dev/null)" = 3 ] \
    && ok || bad "backticked-pre-mention wave count (a backtick-wrapped <pre><code> mention must not swallow later waves)"
  W2=$(jq -r '.[1].body' "$T/b/children.json" 2>/dev/null)
  grep -Fq '`<pre><code>`' <<<"$W2" \
    && ok || bad "backticked-pre-mention wave 2 body lost the backtick-wrapped mention verbatim: $W2"
  [ "$(jq -r '.[2].title' "$T/b/children.json" 2>/dev/null)" = "c" ] \
    && ok || bad "backticked-pre-mention wave 3 title (must still be filed as its own wave)"
}

# ---------------------------------------------------------------------------
# A24 — an unclosed fence or an unclosed (non-backticked) <pre> refuses with
# "unterminated code block" instead of silently filing a short wave list
# (BH-984 N5, part 2)
# ---------------------------------------------------------------------------
a24_unterminated_code_block() {
  refuse_unterminated() {
    local fixture="$1"
    rm -rf "$T/b"; mkdir -p "$T/b"
    ( env HARNESS="$T/h" FLEET_CONF="$T/h/fleet.conf" PATH="$T/h/bin:$PATH" \
        GH_BODY_552="$FIX/$fixture" CURL_BODY_2="$FIX/board-2.json" \
        DECOMPOSE_DRY_RUN=1 "$ROLLOUT" scoutish 552 TK-552 "$T/b" >/dev/null 2>&1 ); RC=$?
    [ "$RC" -ne 0 ] && ok || bad "$fixture refused exit nonzero (rc=$RC)"
    [ ! -e "$T/b/children.json" ] && ok || bad "$fixture refused must leave no children.json"
    [ ! -e "$T/b/filer-call.txt" ] && ok || bad "$fixture refused must make no filer call"
    grep -q 'ROLLOUT_FAILED.*unterminated' "$T/b/rollout-run.txt" 2>/dev/null \
      && ok || bad "$fixture refused reason missing: $(cat "$T/b/rollout-run.txt" 2>/dev/null)"
  }
  refuse_unterminated unclosed-fence.md
  refuse_unterminated unclosed-pre.md
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
if run_section lints || run_section is-rollout || run_section negatives || run_section filing; then
  a1_lints
fi
if run_section is-rollout || run_section negatives; then
  a2_is_rollout
fi
if run_section canonical || run_section filing || run_section artifacts || run_section idempotency || run_section ""; then
  a3_canonical
fi
if run_section negatives || run_section ""; then
  a4_lower_case
  a5_html
fi
if run_section filing || run_section ""; then
  a6_board
fi
if run_section no-section || run_section negatives || run_section ""; then
  a7_no_section
fi
if run_section refusals || run_section ""; then
  a8_refusals
fi
if run_section ""; then
  a9_deeper_after
  a10_rollout_titled
fi
if run_section idempotency || run_section ""; then
  a11_idempotency
fi
if run_section filing || run_section ""; then
  a12_filer_unavailable
fi
if run_section artifacts || run_section ""; then
  a13_comment
fi
if run_section ""; then
  a16_code_preserved
  a17_trailing_sections
  a18_empty_body
  a19_early_failure_artifacts
  a20_indented_code
  a21_pre_code_block
  a22_duplicate_rollout_section
  a23_backtick_masked_precode
  a24_unterminated_code_block
fi
if run_section ""; then
  a14_test_home
  a15_untouched
fi

echo "run-rollout.bh-984: $PASS pass, $FAIL fail"
[ "$FAIL" -eq 0 ]
