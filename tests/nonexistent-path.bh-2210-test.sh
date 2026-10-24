#!/bin/bash
# tests/nonexistent-path.bh-2210-test.sh — a directory is never a conf file, and
# a test that creates /nonexistent is a trace-safety hit.
#
# WHY (BH-2210, found 2026-09-24). tests/regenerated-path-conflicts.bh-1162-test.sh
# was red on testhost-1 and green in CI. It forced the compiled default with
# MC_REGENERATED_PATHS_CONF=/nonexistent, and on testhost-1 /nonexistent was a
# real DIRECTORY: `[ -r dir ]` is true, sed failed on it, and the table came back
# EMPTY instead of falling back. The directory came from
# tests/gh-app-ratchet-test.sh, which sourced merge-conductor-lib.sh with
# HARNESS=/nonexistent as root, and bin/lib/lane-gate.sh ran
# `mkdir -p "$HARNESS/state/lane-gate" "$HARNESS/logs"` at source time.
#
# Sections: 1 a conf path that is a directory falls back to the default (both
# mc_regen_paths and its twin mc_generated_globs), 2 an absent conf still falls
# back, 3 bin/test-trace-safety.sh flags mkdir/touch under /nonexistent and the
# existence probe flags a creation xtrace cannot see, 4 the suites that used a
# fixed /nonexistent as "missing" no longer do.
#
# Every trace fixture is built from a heredoc under $T, never committed as a
# file, and every mkdir/touch aimed at /nonexistent is a shell-function shim,
# so running a fixture by hand creates nothing.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
RUN="$DIR/bin/test-trace-safety.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

if [ "$(id -u)" -eq 0 ]; then export HARNESS_TEST_SANDBOX=1; fi

# The library is sourced against a SCRATCH harness, never /root/harness.
export HARNESS="$T/h"
mkdir -p "$T/h/config"
# shellcheck source=/dev/null
. "$DIR/bin/lib/merge-conductor-lib.sh" >/dev/null 2>&1

# ── 1. a conf path that is a DIRECTORY is absent, never an empty table ───────
mkdir -p "$T/confdir/state"
GOT=$(MC_REGENERATED_PATHS_CONF="$T/confdir" mc_regen_paths 2>/dev/null)
[ "$GOT" = "$MC_REGENERATED_PATHS_DEFAULT" ] && ok \
  || bad "1: mc_regen_paths on a directory must print the compiled default, got [$GOT]"
# TEST-CHANGE (BH-8254): this used the docs/notes/INDEX.md row, which left the
# table with the file; rules/CLAUDE.md is a row the default still carries.
GOT=$(MC_REGENERATED_PATHS_CONF="$T/confdir" mc_regen_cmd_for_path rules/CLAUDE.md 2>/dev/null)
[ "$GOT" = "bin/render-rules.sh --write" ] && ok \
  || bad "1: with the conf a directory, rules/CLAUDE.md must still map to bin/render-rules.sh --write, got [$GOT]"
GOT=$(MC_GENERATED_PATHS_CONF="$T/confdir" mc_generated_globs 2>/dev/null)
[ "$GOT" = "$MC_GENERATED_PATHS_DEFAULT" ] && ok \
  || bad "1: mc_generated_globs on a directory must print the compiled default, got [$GOT]"
MC_GENERATED_PATHS_CONF="$T/confdir" mc_path_is_generated docs/build-log/waves/TK-1.md && ok \
  || bad "1: with the conf a directory, a wave file must still be generated"

# Control: a real conf file is still READ, so the guard does not always fall back.
printf '# a comment\nsome/custom.md\tbin/custom-render.sh\n' > "$T/regen.conf"
GOT=$(MC_REGENERATED_PATHS_CONF="$T/regen.conf" mc_regen_paths 2>/dev/null)
[ "$GOT" = $'some/custom.md\tbin/custom-render.sh' ] && ok \
  || bad "1: a regular conf file must be read, got [$GOT]"
printf 'custom/*.md\n' > "$T/gen.conf"
GOT=$(MC_GENERATED_PATHS_CONF="$T/gen.conf" mc_generated_globs 2>/dev/null)
[ "$GOT" = 'custom/*.md' ] && ok \
  || bad "1: a regular generated-paths conf must be read, got [$GOT]"
# A symlink to a regular file is a file.
ln -s "$T/regen.conf" "$T/regen-link.conf"
GOT=$(MC_REGENERATED_PATHS_CONF="$T/regen-link.conf" mc_regen_paths 2>/dev/null)
[ "$GOT" = $'some/custom.md\tbin/custom-render.sh' ] && ok \
  || bad "1: a symlink to a regular conf must be read, got [$GOT]"

# ── 2. an absent conf falls back (the behaviour that already held) ───────────
GOT=$(MC_REGENERATED_PATHS_CONF="$T/no-such.conf" mc_regen_paths 2>/dev/null)
[ "$GOT" = "$MC_REGENERATED_PATHS_DEFAULT" ] && ok \
  || bad "2: an absent regenerated-paths conf must fall back, got [$GOT]"
GOT=$(MC_GENERATED_PATHS_CONF="$T/no-such.conf" mc_generated_globs 2>/dev/null)
[ "$GOT" = "$MC_GENERATED_PATHS_DEFAULT" ] && ok \
  || bad "2: an absent generated-paths conf must fall back, got [$GOT]"

# ── 3. the trace runner flags creation under /nonexistent ───────────────────
mktree() { # <name> -> path of a fresh fixture tree with a tests/ dir
  mkdir -p "$T/$1/tests"
  printf '%s\n' "$T/$1"
}
# Everything the runner sees: the probe root is left at its default unless a
# case sets it, so a stray TRACE_SAFETY_CREATE_ROOT in the caller cannot leak in.
run_trace() { env -u TRACE_SAFETY_CREATE_ROOT "$RUN" "$@"; }

# (a)+(b) shimmed mkdir and touch aimed at /nonexistent
A=$(mktree create)
cat > "$A/tests/fx-test.sh" <<'FIXEOF'
#!/bin/bash
mkdir() { :; }
touch() { :; }
mkdir -p /nonexistent/state
touch /nonexistent/x
FIXEOF
OUT=$(run_trace "$A" 2>&1); RC=$?
[ "$RC" -eq 1 ] && ok || bad "3a: a mkdir under /nonexistent must be rc 1, got $RC [$OUT]"
has "HIT fx-test.sh mkdir /nonexistent/state " "$OUT" && ok \
  || bad "3a: mkdir -p /nonexistent/state must be a HIT [$OUT]"
has "HIT fx-test.sh touch /nonexistent/x " "$OUT" && ok \
  || bad "3b: touch /nonexistent/x must be a HIT [$OUT]"
has "TRACE: 1 tests, 0 nonzero exit(s), 2 hit(s)" "$OUT" && ok \
  || bad "3a: exactly the two creations are hits [$OUT]"

# (c) the negatives: scratch, /dev/null and the hyphenated sibling are not hits
C=$(mktree fine)
cat > "$C/tests/fine-test.sh" <<'FIXEOF'
#!/bin/bash
D=$(mktemp -d)
trap 'rm -rf "$D"' EXIT
mkdir -p "$D/a"
touch "$D/z"
mkdir() { :; }
touch() { :; }
mkdir -p -m 0700 /dev/null/b /nonexistent-trace-safety/c
mkdir -- relative-dir
touch -d 2026-01-01 -r /nonexistent /nonexistent-trace-safety/y
FIXEOF
OUT=$(run_trace "$C" 2>&1); RC=$?
[ "$RC" -eq 0 ] && has "TRACE: 1 tests, 0 nonzero exit(s), 0 hit(s)" "$OUT" && ok \
  || bad "3c: mkdir/touch outside /nonexistent (and touch -r's reference file) must never be a hit (rc=$RC) [$OUT]"

# (d) the real line-872 shape: HARNESS=/nonexistent, then source a lib that
# makes its state dirs at source time, in a bash -c child.
DD=$(mktree ratchet)
mkdir -p "$DD/bin/lib"
cat > "$DD/bin/lib/stub-lib.sh" <<'FIXEOF'
h="${HARNESS:-/root/harness}"
mkdir -p "$h/state/lane-gate" "$h/logs" 2>/dev/null || true
FIXEOF
cat > "$DD/tests/ratchet-test.sh" <<'FIXEOF'
#!/bin/bash
OUT=$( bash -c \
       'mkdir() { :; }; HARNESS=/nonexistent; . "$1/bin/lib/stub-lib.sh" >/dev/null 2>&1
        printf "rc=%s" "$?"' _ "$PWD" 2>/dev/null )
echo "$OUT"
FIXEOF
OUT=$(run_trace "$DD" 2>&1); RC=$?
[ "$RC" -eq 1 ] && has "HIT ratchet-test.sh mkdir /nonexistent/state/lane-gate " "$OUT" \
  && has "HIT ratchet-test.sh mkdir /nonexistent/logs " "$OUT" && ok \
  || bad "3d: the line-872 shape (HARNESS=/nonexistent, lib mkdir at source time) must be a HIT (rc=$RC) [$OUT]"

# (e) the existence probe: a creation xtrace never shows as mkdir/touch.
# `install -d` is not a mkdir to the parser, so only the probe can see it.
E=$(mktree probe)
cat > "$E/tests/probe-test.sh" <<'FIXEOF'
#!/bin/bash
install -d "$TRACE_SAFETY_CREATE_ROOT/state"
FIXEOF
OUT=$(TRACE_SAFETY_CREATE_ROOT="$T/probe-root" "$RUN" "$E" 2>&1); RC=$?
[ "$RC" -eq 1 ] && has "HIT probe-test.sh created $T/probe-root " "$OUT" \
  && has "TRACE: 1 tests, 0 nonzero exit(s), 1 hit(s)" "$OUT" && ok \
  || bad "3e: a test that creates the root must be a 'created' HIT (rc=$RC) [$OUT]"

# A root that already exists before the run cannot be attributed: a CHECK-NOTE
# on stderr, rc unchanged, never silent and never a false HIT.
mkdir -p "$T/probe-pre"
E2=$(mktree probe-pre-tree)
printf '#!/bin/bash\necho nothing\n' > "$E2/tests/quiet-test.sh"
ERR=$(TRACE_SAFETY_CREATE_ROOT="$T/probe-pre" "$RUN" "$E2" 2>&1 >/dev/null); RC=$?
[ "$RC" -eq 0 ] && has "CHECK-NOTE test-trace-safety: $T/probe-pre already exists, creation probe cannot attribute" "$ERR" && ok \
  || bad "3e: a pre-existing root must print a CHECK-NOTE and keep rc 0 (rc=$RC) [$ERR]"

# The knob, like every other one, is refused rather than guessed at.
OUT=$(TRACE_SAFETY_CREATE_ROOT=relative "$RUN" "$E2" 2>&1); RC=$?
[ "$RC" -eq 2 ] && has "TRACE_SAFETY_CREATE_ROOT" "$OUT" && ok \
  || bad "3e: a relative TRACE_SAFETY_CREATE_ROOT must be rc 2 (rc=$RC) [$OUT]"

# ── 4. no fixed /nonexistent as "missing" in the suites BH-2210 fixed ────────
LEFT=$(cd "$DIR" && grep -nE '(=|[[:space:]])/nonexistent(/|[[:space:]]|"|$)' \
  tests/regenerated-path-conflicts.bh-1162-test.sh tests/generated-path-conflicts-test.sh \
  tests/gh-app-ratchet-test.sh tests/prompt-ceiling-test.sh tests/planned-files-cheap-test.sh \
  tests/env-path-port-b-test.sh tests/readiness-report-test.sh)
[ -z "$LEFT" ] && ok || bad "4: a fixed /nonexistent is still used as 'missing': $LEFT"

echo "nonexistent-path.bh-2210: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
