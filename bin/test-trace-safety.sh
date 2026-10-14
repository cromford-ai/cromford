#!/bin/bash
# bin/test-trace-safety.sh [--list] [--gate] [--verdict <file>] [--timings <file>] [--shard i/n] [--only-file <list>] [<root>]
#
# A TEST MAY ONLY DELETE WHAT IT MADE. This is the dynamic half of that answer:
# it RUNS every tests/*.sh under a trace and reads what each one actually did.
#
# --shard i/n traces ONE n-th of the corpus (BH-1192). The whole scan took 40-45
# minutes and every PR waited for it, so CI runs four shards in parallel behind
# a fan-in job that keeps the check name `Tests cannot touch a real harness`.
# The split is `suite_shard_filter` in bin/lib/suite-runner.sh, the same
# function bin/test-suite-run.sh uses, because the one thing that must stay
# true is that the four shards are the whole corpus — and a second copy of the
# rule is how that quietly stops being true.
#
# 2026-09-15, 16:50Z (#388, root cause #404, scope #394):
# tests/auth-probe-classify-test.sh set `trap 'rm -rf "$H"'`, then sourced
# bin/claude-auth-check.sh, which assigns H="${HARNESS:-/root/harness}" in the
# sourcing shell. At exit the trap removed the live harness install. Nothing in
# the text of that test is wrong — the clobber happens at run time, one file
# away. checks/tests-scratch-only/check.sh reads the text; this runner reads the
# run. Both, or the next shape slips through the one you kept.
#
# WHAT IT DOES. For every <root>/tests/*.sh, in order:
#   - runs it from <root> with HARNESS, H, HARNESS_CHECKOUT, SCRATCH and T
#     UNSET (the production shape of the incident, plus the two the scratch lib
#     hands out: a test that inherits someone else's SCRATCH removes it),
#   - captures a trace of the test AND of every child bash on fd 199,
#   - reads every deletion and every literal redirect out of that trace and
#     reports the ones that land outside the allowed temp roots,
#   - after a traced `PS4=` reassign (bare, or after export/declare/typeset/
#     local/readonly), also reads the unstamped lines that follow, with src,
#     line and cwd `-`; a relative target on such a line is skipped (BH-5541),
#   - reads the test's captured output (stderr; stdout+stderr under --gate) for
#     default-PS4 `+ rm` lines, which is where a `bash -x` child traces.
#   Every test starts with SIGPIPE at its default action (BH-5544), even when
#   the runner itself started with it ignored, as a CI step does. See DFL_PIPE.
#
# HOW THE TRACE IS TAKEN, and why not `bash -x <test>`:
#   `bash -x` writes to stderr, which pollutes every `OUT=$(cmd 2>&1)` a test
#   makes, and it stops at the first child process. Instead the runner opens
#   fd 199 on the trace file and hands the test a BASH_ENV file that, in every
#   non-interactive bash that is not ALREADY tracing, sets
#   `PS4='+ ${BASH_SOURCE-}:${LINENO}|${PWD}| '`, BASH_XTRACEFD=199 and `set -x`.
#   So: the test is traced, every `bash`/`bash -c` child is traced into the same
#   file, `$(… 2>&1)` captures stay clean, and each line carries the file, the
#   line number and THE WORKING DIRECTORY THE COMMAND RAN IN — which is what
#   makes `cd /; rm -rf ./x` resolvable. `${BASH_SOURCE-}` and not
#   `${BASH_SOURCE##*/}` on purpose: the stripping form is not exempt from
#   `set -u`, and a child that runs `set -u` would print an unstamped line the
#   parser cannot read. A child started with an explicit `bash -x` is left
#   alone: its trace stays on its own stderr with the default PS4, and the
#   runner reads the test's captured output for those default-PS4 `rm` lines
#   (BH-5541, the shape the retired trap-target guard read).
#
# WHAT COUNTS AS A HIT (the ticket's list, nothing more):
#   rm <path>, find <path> … -delete, truncate <path>, git [-C <dir>] clean,
#   and a literal `> <absolute path>` / `>> <absolute path>` inside an argument
#   handed to a shell ON THIS MACHINE (`bash -c`, `sh -c`, `eval`, `su -c`,
#   and `declare`/`typeset`/`local NAME="(…)"`, which re-parses its string the
#   way eval does; never `ssh host '…'`, whose paths are another box's) — whose
#   target, resolved against the traced working directory, is not strictly
#   inside an allowed temp root. A backslash in the target is read the way the
#   inner shell reads it (BH-5266): `printf %q` spells `2>/dev/null || x` as
#   `2\>/dev/null\ \|\|\ x`, so an escaped space or terminator ends the
#   target (`/dev/null`) and any other escaped character is itself. The allow-list is one `case` block, `safe_target`, and it
#   is the only place a path is excused.
#   The deletion rules read the COMMAND POSITION, so a test that prints a
#   command string is not a deletion. The redirect rule is read only against
#   the shells above for exactly that reason: the first full-tree run flagged
#   106 assertion messages that merely quote `cat >/root/harness/...` or spell a
#   branch name `batch/<project>/<stamp>`. See is_interpreter in the parser.
#   CREATION under /nonexistent (BH-2210): `mkdir <path>` and `touch <path>`
#   whose resolved target is /nonexistent or below it, and a per-test existence
#   probe — /nonexistent absent before a test and present after it is
#   `HIT <test> created /nonexistent`, whatever made it (a plain `>` redirect,
#   git, python: writers xtrace never shows). tests/gh-app-ratchet-test.sh made
#   it on the testhosts by sourcing a lib with HARNESS=/nonexistent, and then
#   every suite that used /nonexistent to mean "missing" read a directory. Any
#   other mkdir/touch target is not a hit. If /nonexistent already exists when
#   the run starts, the probe cannot attribute it and says so on stderr:
#   `CHECK-NOTE test-trace-safety: /nonexistent already exists, creation probe
#   cannot attribute` (rc unchanged).
#
# EXIT CODES:
#   0  every test traced, no hit                     (the summary line is the claim)
#   1  at least one hit                              (each hit printed by name)
#   2  the run could not be trusted: no such root, no tests/*.sh, a work dir or
#      trace fd that could not be created, a test that produced an EMPTY trace
#      (a bash script under `set -x` always emits at least one line, so an empty
#      trace means the tracing mechanism was not honoured), a dead parser, a
#      bad knob value, or root next to a live harness. rc 2 prints
#      `CHECK-ERROR test-trace-safety: …` on stderr and NO `TRACE:` line: a scan
#      that did not happen never reads as a clean tree.
#   A test that exits nonzero is COUNTED and printed by name (`EXIT <rc> <test>`,
#   `TIMEOUT <test>`) and does not set rc 1. Whether the suite passes is CI's
#   job; this lane's verdict is hits — EXCEPT under --gate, below.
#
# --gate: ONE RUN, TWO VERDICTS (CI cost cut, 2026-09-24). CI used to run the
#   whole corpus twice per run — once bare for `Pure-logic gate fixtures` and
#   once here for `Tests cannot touch a real harness` — and that second copy was
#   ~half of every CI minute the repo billed. Every test this runner traces has
#   already RUN to completion, so its exit status is the pure-logic verdict for
#   free. --gate asks for it:
#   - the corpus is tests/*.sh AND tests/mc/*.sh (what the bare lane ran);
#   - each test's stdout+stderr is captured and printed in full when it exits
#     nonzero or times out, after a `--- <test> rc=<rc> <secs>s` line that every
#     test gets (the per-suite wall times a duration-balanced split can use);
#   - rc is 1 when there was a hit OR a nonzero exit / timeout, 0 only when
#     both verdicts are clean, 2 as before when the run cannot be trusted.
#   --verdict <file> writes the two verdicts separately, so CI's two fan-in
#   checks each judge their own: `tests=<n>`, `failed=<k>`, `hits=<h>`,
#   `pure=pass|fail`, `trace=clean|dirty`. It is written ONLY when the scan
#   completed, so a missing file means "did not run" and both fan-ins go red.
#   --timings <file> (BH-5518) writes one `<suite>\t<seconds>\t<rc>` row per
#   suite: the path from tests/ on, the wall time to 0.1 s, the exit code. It
#   starts empty on every run. bin/ci-durations.sh merge folds a batch's rows
#   into the shard weights (docs/ci-durations.md).
#
# A TEST PRINTS NO CREDENTIAL (BH-6672). A pool box exports GH_TOKEN as a live
#   GitHub App token, and tests/batch-resolve-test.sh printed it into the run
#   output. Every test here starts with GH_TOKEN and GITHUB_TOKEN set to a
#   CANARY: `ghs_canary` + 30 hex characters, made once per run, never written
#   in source and never printed. A test whose output (stdout and stderr, in
#   both modes) holds the canary is `HIT <test> printed-credential GH_TOKEN
#   (…)`, which counts like any other hit. A test that sources
#   tests/lib/scratch.sh never sees it: the lib unsets both. Under --gate a
#   failed test's output is printed through token_redact
#   (bin/lib/token-redact.sh) when the lib is beside this script.
#
# KNOBS:
#   TRACE_SAFETY_TEST_TIMEOUT  per-test timeout in whole seconds (default 600)
#   TRACE_SAFETY_KEEP=1        keep the work dir and every trace, print where
#   HARNESS_TEST_SANDBOX=1     required to run as root next to a live harness
#   HARNESS_ROOT_OVERRIDE      what "a live harness" means (default /root/harness)
#   TMPDIR, RUNNER_TEMP        additional allowed temp roots when set
#   TRACE_SAFETY_CREATE_ROOT   the root no test may create (default /nonexistent;
#                              absolute, not /). Exists so the suite can point
#                              the probe at a scratch path and never touch /.
#   The work dir is kept automatically when there were hits, so the trace behind
#   a hit is still on disk to read.
#
# KNOWN GAPS, stated rather than papered over:
#   - `#!/bin/sh` children on dash read no BASH_ENV, and `env -i …` children
#     lose it: those are untraced. Their command text still shows in the
#     parent's trace, which is what the redirect rule reads.
#   - A redirect target that is relative or still a `$var` in the traced text
#     cannot be resolved honestly, so it is skipped rather than guessed at.
#   - A redirect inside a string handed to something OTHER than a shell —
#     `python -c`, `xargs sh -c`, a heredoc fed to `ssh` — is not read. Adding
#     an interpreter is one more name in is_interpreter.
#   - A traced command whose text spans lines (a multi-line quoted argument) is
#     read only as far as its first line.
#   - A path containing `|` breaks the stamp, and no path in this repo has one.
#   - An escaped space between a redirect and its target (`2\>\ /dev/null`)
#     leaves a target that does not start with `/`, so it is skipped. `%q` of
#     the shapes in this corpus never produces it.
#   - A `bash -x` child whose stderr goes to /dev/null or to a file the suite
#     owns is not read. The retired trap-target guard did not read it either.
#
# THIS SCRIPT DELETES ONLY ITS OWN `mktemp -d` WORK DIR. Nothing else, ever.
set -uo pipefail
SELF_NAME=test-trace-safety

# A runner run BY a runner — this lane's own test is one of the tests/*.sh it
# executes — inherits an open fd 199 and a BASH_ENV that turns xtrace on in
# every non-interactive bash, including this one. Our own trace lines then land
# in the file we are about to read as the test's: a trace that is not empty from
# a shell that never ran, which silently disarms the empty-trace guard below.
# Section O of the suite is that case, and it is red without this line.
set +x

die() { echo "CHECK-ERROR $SELF_NAME: $*" >&2; exit 2; }

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
# The shard split, shared with bin/test-suite-run.sh. Sourced before the
# arguments are read because parsing --shard is what it is for; the library
# defines functions and does nothing else at source time.
#
# OPTIONAL ON PURPOSE. This script gets copied somewhere on its own — the
# mutation and nesting fixtures in tests/tests-trace-safety-test.sh both run a
# lone copy, and so does anyone who scp's it at a box — and a whole scan that
# refuses because a shard helper is missing would be a regression in the thing
# it is here to do. A copy therefore still scans; only --shard needs the
# library, and asks for it by name below rather than silently tracing
# everything.
if [ -f "$SELF_DIR/lib/suite-runner.sh" ]; then
  # shellcheck source=lib/suite-runner.sh
  . "$SELF_DIR/lib/suite-runner.sh" || die "cannot source $SELF_DIR/lib/suite-runner.sh"
fi
# The same holds for the token scrub: a lone copy still finds the canary, and
# only prints a failed test's output unscrubbed.
if [ -f "$SELF_DIR/lib/token-redact.sh" ]; then
  # shellcheck source=lib/token-redact.sh
  . "$SELF_DIR/lib/token-redact.sh" || die "cannot source $SELF_DIR/lib/token-redact.sh"
fi

# ── arguments ────────────────────────────────────────────────────────────────
MODE=run
ROOT=""
SHARD=""
ONLY=""
GATE=0
VERDICT=""
TIMINGS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list)    MODE=list ;;
    --gate)    GATE=1 ;;
    --verdict) [ $# -ge 2 ] || die "--verdict needs a path"
               VERDICT="$2"; shift ;;
    --verdict=*) VERDICT="${1#--verdict=}" ;;
    --timings) [ $# -ge 2 ] || die "--timings needs a path"
               TIMINGS="$2"; shift ;;
    --timings=*) TIMINGS="${1#--timings=}" ;;
    --only-file) [ $# -ge 2 ] || die "--only-file needs a path"
               ONLY="$2"; shift ;;
    --only-file=*) ONLY="${1#--only-file=}" ;;
    --shard)   [ $# -ge 2 ] || die "--shard needs a spec like 0/4"
               SHARD="$2"; shift ;;
    --shard=*) SHARD="${1#--shard=}" ;;
    -h|--help) sed -n '2,160p' "$0"; exit 0 ;;
    -*)        die "unknown flag $1" ;;
    *)         [ -z "$ROOT" ] || die "only one root may be given (got '$ROOT' and '$1')"
               ROOT="$1" ;;
  esac
  shift
done
# A bad spec is rc 2 like every other unusable argument: a scan that traced a
# quarter of what it was asked for, or nothing, must never print a TRACE: line.
SHARD_I=""; SHARD_N=""
if [ -n "$SHARD" ]; then
  command -v suite_shard_parse >/dev/null \
    || die "--shard needs lib/suite-runner.sh next to this script (looked in $SELF_DIR/lib)"
  SPEC=$(suite_shard_parse "$SHARD" 2>&1) || die "$SPEC"
  SHARD_I=${SPEC% *}; SHARD_N=${SPEC#* }
fi
[ -n "$ROOT" ] || ROOT="$(cd "$SELF_DIR/.." && pwd)"
[ -d "$ROOT" ] || die "no such tree '$ROOT'"
ROOT="$(cd "$ROOT" && pwd)" || die "cannot enter '$ROOT'"

TEST_TIMEOUT="${TRACE_SAFETY_TEST_TIMEOUT:-600}"
case "$TEST_TIMEOUT" in
  ''|*[!0-9]*) die "TRACE_SAFETY_TEST_TIMEOUT must be a whole number of seconds, got '$TEST_TIMEOUT'" ;;
esac
# SIGPIPE AT ITS DEFAULT ACTION (BH-5544). The CI runners start their steps with
# SIGPIPE ignored (PR #5221), a process inherits that through every exec, and bash
# cannot reset a signal ignored at entry. A test written on a laptop then sees
# EPIPE ("write error: Broken pipe", rc 1) where it expects SIGPIPE (rc 141).
# Every test starts through this prefix: GNU env's --default-signal, else perl,
# the same pair bin/remote-gate.sh's _rg_dfl_pipe uses.
DFL_PIPE=()
if env --default-signal=PIPE true >/dev/null 2>&1; then
  DFL_PIPE=(env --default-signal=PIPE)
elif command -v perl >/dev/null 2>&1; then
  # shellcheck disable=SC2016 # perl code, not shell
  DFL_PIPE=(perl -e '$SIG{PIPE} = "DEFAULT"; exec { $ARGV[0] } @ARGV or exit 127')
elif [ -n "$(trap -p PIPE)" ]; then
  echo "CHECK-NOTE $SELF_NAME: SIGPIPE is ignored at entry and neither GNU env nor perl can reset it; tests start with it ignored" >&2
fi
CREATE_ROOT="${TRACE_SAFETY_CREATE_ROOT:-/nonexistent}"
case "$CREATE_ROOT" in
  /) die "TRACE_SAFETY_CREATE_ROOT must not be /" ;;
  /*) CREATE_ROOT="$(realpath -m "$CREATE_ROOT")" || die "cannot resolve TRACE_SAFETY_CREATE_ROOT '$CREATE_ROOT'" ;;
  *) die "TRACE_SAFETY_CREATE_ROOT must be an absolute path, got '$CREATE_ROOT'" ;;
esac

shopt -s nullglob
TESTS=()
for F in "$ROOT"/tests/*.sh; do [ -f "$F" ] && TESTS+=("$F"); done
# --gate stands in for the bare lane, which swept tests/mc too.
if [ "$GATE" = 1 ]; then
  for F in "$ROOT"/tests/mc/*.sh; do [ -f "$F" ] && TESTS+=("$F"); done
fi
shopt -u nullglob
[ -z "$VERDICT" ] || [ "$GATE" = 1 ] || die "--verdict is only meaningful with --gate"
[ -z "$TIMINGS" ] || [ "$GATE" = 1 ] || die "--timings is only meaningful with --gate"
if [ -n "$TIMINGS" ]; then
  { mkdir -p "$(dirname "$TIMINGS")" && : > "$TIMINGS"; } 2>/dev/null || die "cannot write the timings file $TIMINGS"
fi
[ "${#TESTS[@]}" -gt 0 ] \
  || die "'$ROOT/tests' has no *.sh to trace — refusing to report a clean tree from an empty scan"

# The impact selection (BH-1203), applied BEFORE the shard so the four shards
# divide the selection. The list holds repo-relative paths and TESTS holds
# absolute ones, so the comparison is made on the relative form. An unreadable
# list, or one that names none of these tests, is rc 2 — a trace that scanned
# nothing must never print a clean TRACE: line.
if [ -n "$ONLY" ]; then
  [ -r "$ONLY" ] || die "cannot read --only-file '$ONLY'"
  KEPT=()
  while IFS= read -r F; do [ -n "$F" ] && KEPT+=("$ROOT/$F"); done \
    < <(for F in "${TESTS[@]}"; do echo "${F#"$ROOT"/}"; done | LC_ALL=C sort | grep -xF -f "$ONLY" 2>/dev/null)
  [ "${#KEPT[@]}" -gt 0 ] \
    || die "--only-file '$ONLY' selected none of the ${#TESTS[@]} tests under '$ROOT/tests'"
  [ "$MODE" = list ] || echo "impact: ${#KEPT[@]} of ${#TESTS[@]} tests (--only-file $ONLY)"
  TESTS=("${KEPT[@]}")
fi

# The shard is taken AFTER the empty-corpus refusal above, so "this tree has no
# tests" and "this shard has no tests" stay two different answers.
if [ -n "$SHARD_N" ]; then
  ALL=${#TESTS[@]}
  PICKED=()
  while IFS= read -r F; do [ -n "$F" ] && PICKED+=("$F"); done \
    < <(suite_shard_filter "$SHARD_I" "$SHARD_N" "${TESTS[@]}")
  [ "${#PICKED[@]}" -gt 0 ] \
    || die "shard $SHARD selected none of the $ALL tests under '$ROOT/tests'"
  TESTS=("${PICKED[@]}")
  [ "$MODE" = list ] || echo "shard $SHARD_I/$SHARD_N: ${#TESTS[@]} of $ALL tests"
fi

if [ "$MODE" = list ]; then
  for F in "${TESTS[@]}"; do echo "${F#"$ROOT"/}"; done
  exit 0
fi

# ── the guard scratch.sh already makes: never run the suite at a live install ─
# The runner executes tests bare, including any that never ported to the scratch
# library, so it needs the same opt-in the library asks for. Off a box (CI is
# not root, the fixture trees are not /root/harness) this is silent.
LIVE_HARNESS="${HARNESS_ROOT_OVERRIDE:-/root/harness}"
if [ "$(id -u)" -eq 0 ] && [ -d "$LIVE_HARNESS" ] && [ "${HARNESS_TEST_SANDBOX:-}" != "1" ]; then
  die "refusing to run the suite as root next to the live harness $LIVE_HARNESS (set HARNESS_TEST_SANDBOX=1 to override)"
fi

# ── the allowed temp roots: the only place a path is ever excused ────────────
TMP_ALLOW=""
if [ -n "${TMPDIR:-}" ]; then TMP_ALLOW="$(realpath -m "$TMPDIR" 2>/dev/null)"; fi

# /dev/shm is on this list and the ticket did not name it: it is a tmpfs, and the
# harness deliberately keeps short-lived SECRETS there instead of on disk
# (bin/gh-token-rotate.sh, the fly env staging). Those scripts remove their own
# mktemp files, and the first full-tree run reported 15 of them. Strictly UNDER
# it only, like every other root here — /dev/shm itself is not excused, and
# nothing under /dev/null ever is (that is what keeps the suite fixtures inert
# and still detectable).
safe_target() { # <resolved absolute path> — 0 when it is strictly inside a temp root
  case "$1" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*|/dev/shm/*) return 0 ;;
  esac
  [ -n "$TMP_ALLOW" ] && case "$1" in "$TMP_ALLOW"/*) return 0 ;; esac
  [ -n "${RUNNER_TEMP:-}" ] && case "$1" in "${RUNNER_TEMP}"/*) return 0 ;; esac
  return 1
}

# The one root a test may never CREATE (BH-2210). Judged apart from safe_target:
# a mkdir/touch is a hit here and nowhere else.
forbidden_create() { # <resolved absolute path> — 0 when it is the root or below it
  case "$1" in "$CREATE_ROOT"|"$CREATE_ROOT"/*) return 0 ;; esac
  return 1
}

safe_redirect() { # <resolved absolute path> — the devices a redirect may name
  case "$1" in
    /dev/null|/dev/stdout|/dev/stderr|/dev/tty|/dev/fd/*) return 0 ;;
  esac
  safe_target "$1"
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}"/trace-safety.XXXXXX)" \
  || die "cannot create a work dir under ${TMPDIR:-/tmp}"
KEEP_WORK=0
# The credential canary (BH-6672): made at run time, so no source line holds it.
CANARY="ghs_canary$(printf '%s %s %s' "$$" "${EPOCHREALTIME:-}" "$WORK" | sha256sum | cut -c1-30)"
[ "${#CANARY}" = 40 ] || die "could not make the credential canary"
print_redacted() { # <file> — a failed test's output, token shapes scrubbed
  if command -v token_redact >/dev/null 2>&1; then token_redact < "$1"; else cat "$1"; fi
}
cleanup() {
  if [ "$KEEP_WORK" = 1 ] || [ "${TRACE_SAFETY_KEEP:-}" = 1 ]; then
    echo "$SELF_NAME: traces kept in $WORK" >&2
    return 0
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

root_exists() { [ -e "$CREATE_ROOT" ] || [ -L "$CREATE_ROOT" ]; }
if root_exists; then
  echo "CHECK-NOTE $SELF_NAME: $CREATE_ROOT already exists, creation probe cannot attribute" >&2
fi

cat > "$WORK/trace-env.sh" <<'ENVEOF'
# Sourced by every non-interactive bash the runner starts (BASH_ENV), the test
# itself and each child. Traces into the runner's fd 199 only when that fd is
# open and this shell is not already tracing, so a child started with `bash -x`
# keeps its own stderr trace and its own PS4. PS4 is a shell variable, never
# exported, so nothing re-stamps such a child.
case "$-" in
  *x*) ;;
  *) if { true >&199; } 2>/dev/null; then
       PS4='+ ${BASH_SOURCE-}:${LINENO}|${PWD}| '
       BASH_XTRACEFD=199
       set -x
     fi ;;
esac
ENVEOF

# ── the parser ───────────────────────────────────────────────────────────────
# In: trace lines `+ <src>:<line>|<pwd>| <cmd>` (any depth of `+`).
# Out: one candidate per line, verb \t target \t src \t line \t pwd \t raw.
# The target is left as the trace spelled it; resolving it against <pwd> and
# excusing it is safe_target's job above, so the allow-list stays in one place.
# No interval quantifiers ({n}) anywhere: /usr/bin/awk is mawk on Debian and on
# Ubuntu runners, and older mawk silently does not support them — a pattern that
# quietly matches nothing is the vacuous green this lane exists to refuse.
AWK_PARSE='
function basename(p) { sub(/^.*\//, "", p); return p }

# xtrace single-quotes any argument that needs it, and spells odd bytes
# $\047…\047. Tokenise honouring both; a quoted argument is one token.
function tokenize(s, ARR,   n, i, c, nc, cur, inq, started, L) {
  split("", ARR)
  n = 0; cur = ""; inq = 0; started = 0
  L = length(s)
  for (i = 1; i <= L; i++) {
    c = substr(s, i, 1)
    if (inq) {
      if (c == "\\") {
        nc = substr(s, i + 1, 1)
        if (nc == Q) { cur = cur Q; i++ } else { cur = cur c }
        started = 1
        continue
      }
      if (c == Q) { inq = 0; started = 1; continue }
      cur = cur c; started = 1
      continue
    }
    if (c == "$" && substr(s, i + 1, 1) == Q) { inq = 1; started = 1; i++; continue }
    # Outside the quotes a backslash escapes the next character. This is how
    # xtrace spells an embedded single quote: foo=Q...Q\QQ...Q, close, escaped
    # quote, reopen. Reading the escaped quote as an opener instead left the
    # REST of the string unquoted, so its spaces split it into words and a
    # message that merely quoted "rm -rf /" parsed as a deletion — two of those
    # showed up in the first full-tree run.
    if (c == "\\") {
      nc = substr(s, i + 1, 1)
      if (nc != "") { cur = cur nc; i++ } else { cur = cur c }
      started = 1
      continue
    }
    if (c == Q) { inq = 1; started = 1; continue }
    if (c == " " || c == "\t") {
      if (started) { n++; ARR[n] = cur; cur = ""; started = 0 }
      continue
    }
    cur = cur c; started = 1
  }
  if (started) { n++; ARR[n] = cur }
  return n
}

# Skip the NAME=value assignments and the wrappers that stand in front of the
# real command. Returns the index of that command.
function strip_prefix(ARR, n,   i, t, b) {
  i = 1
  while (i <= n) {
    t = ARR[i]
    if (t ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
    b = basename(t)
    if (b == "command" || b == "exec" || b == "sudo") { i++; continue }
    if (b == "env") {
      i++
      while (i <= n) {
        if (ARR[i] == "-u" || ARR[i] == "--unset") { i += 2; continue }
        if (ARR[i] ~ /^-/) { i++; continue }
        if (ARR[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/) { i++; continue }
        break
      }
      continue
    }
    if (b == "timeout") {
      i++
      while (i <= n) {
        if (ARR[i] == "-k" || ARR[i] == "--kill-after" || ARR[i] == "-s" || ARR[i] == "--signal") { i += 2; continue }
        if (ARR[i] ~ /^-/) { i++; continue }
        break
      }
      if (i <= n && ARR[i] ~ /^[0-9]/) i++
      continue
    }
    break
  }
  return i
}

# Every literal `>` / `>>` in the command text whose target is an absolute path.
# xtrace never shows a shell redirection of its own (probed: `echo hi > /tmp/x`
# traces as `+ echo hi`), so the only place one can appear is inside a quoted
# string handed to bash -c / sh -c / eval / ssh — which is exactly the untraced
# child this rule exists to cover, and the ONLY kind of command this rule is
# read against (see is_interpreter). `2>&1`, `>&2` and `>(…)` are not paths, and
# a relative or still-unexpanded target is skipped rather than guessed at.
function redirects(s, OUT,   n, i, j, L, c, prev, nx, ch, tgt) {
  split("", OUT)
  n = 0
  L = length(s)
  for (i = 1; i <= L; i++) {
    c = substr(s, i, 1)
    if (c != ">") continue
    prev = (i > 1) ? substr(s, i - 1, 1) : ""
    if (prev == ">" || prev == "-" || prev == "=" || prev == "<") continue
    j = i + 1
    if (substr(s, j, 1) == ">") j++
    nx = substr(s, j, 1)
    if (nx == "&" || nx == "(") continue
    while (substr(s, j, 1) == " " || substr(s, j, 1) == "\t") j++
    if (substr(s, j, 1) != "/") continue
    tgt = ""
    while (j <= L) {
      ch = substr(s, j, 1)
      # A backslash is read one layer down, as the shell that will run this
      # text reads it (BH-5266): `printf %q` spells `2>/dev/null || x` as
      # `2\>/dev/null\ \|\|\ x`, and the inner shell splits at the escaped
      # space. So an escaped terminator ends the target, any other escaped
      # character is itself, and a trailing lone backslash is dropped.
      if (ch == "\\") {
        ch = substr(s, j + 1, 1)
        if (ch == "" || ch == " " || ch == "\t" || ch == Q || ch == "\"" || ch == ";" || ch == ")" || ch == "|" || ch == "&" || ch == ">" || ch == "<") break
        tgt = tgt ch
        j += 2
        continue
      }
      if (ch == " " || ch == "\t" || ch == Q || ch == "\"" || ch == ";" || ch == ")" || ch == "|" || ch == "&" || ch == ">" || ch == "<") break
      tgt = tgt ch
      j++
    }
    if (tgt != "") { n++; OUT[n] = tgt }
  }
  return n
}

function emit(verb, target, src, lno, cwd, raw) {
  if (target == "") return
  # The stderr pass reads what the retired trap-target guard read (BH-5541):
  # rm and nothing else, so it adds no new false-positive class.
  if (STDERR_SCAN && verb != "rm") return
  printf "%s\t%s\t%s\t%s\t%s\t%s\n", verb, target, src, lno, cwd, raw
}

# A command that will INTERPRET one of its arguments as shell text. The redirect
# rule is read against these and nothing else, because this repo full of tests
# prints command strings for a living: `bad "the guard must block cat
# >/root/harness/state/x.json"` and `bad "must be batch/<project>/<stamp>"` are
# both messages, not redirections, and the first full-tree run flagged 106 of
# them. A redirect the shell really performed is invisible to xtrace anyway
# unless it is inside one of these arguments.
# ssh is deliberately NOT here: a redirect inside an ssh argument names a path
# on ANOTHER machine, which this lane does not police (and in the suite ssh is a
# stub writing to a sink). su -c IS here, because that one lands on this box.
# declare/typeset/local with a `NAME=(` operand are here too (BH-5266): xtrace
# prints `declare -a ARGV="($s)"` as `declare -a QARGV=(…)Q`, and bash re-parses
# that string into words exactly as eval does. Leaving them out made
# `declare -a X="($CMD)"` a way around this gate. A plain `declare -a W`, a
# scalar `local x=msg` and a bare `W=(…)` (traced as an assignment, which
# strip_prefix skips) re-parse nothing and do not qualify.
function is_interpreter(v, ARR, n, st,   j) {
  if (v == "bash" || v == "sh" || v == "dash" || v == "zsh" || v == "ksh") return 1
  if (v == "eval" || v == "su") return 1
  if (v == "declare" || v == "typeset" || v == "local") {
    for (j = st + 1; j <= n; j++) if (ARR[j] ~ /^[A-Za-z_][A-Za-z0-9_]*=\(/) return 1
  }
  return 0
}

function scan(cmd, src, lno, cwd, raw,   ARR, RED, n, nr, k, st, v, j, endopt, hasdel, cnt, c1, dirc) {
  n = tokenize(cmd, ARR)
  if (n == 0) return
  st = strip_prefix(ARR, n)
  if (st > n) return
  v = basename(ARR[st])
  if (is_interpreter(v, ARR, n, st)) {
    nr = redirects(cmd, RED)
    for (k = 1; k <= nr; k++) emit("redirect", RED[k], src, lno, cwd, raw)
  }
  if (v == "rm") {
    endopt = 0
    for (j = st + 1; j <= n; j++) {
      if (!endopt && ARR[j] == "--") { endopt = 1; continue }
      if (!endopt && substr(ARR[j], 1, 1) == "-") continue
      emit("rm", ARR[j], src, lno, cwd, raw)
    }
    return
  }
  if (v == "find") {
    hasdel = 0
    for (j = st + 1; j <= n; j++) if (ARR[j] == "-delete") hasdel = 1
    if (!hasdel) return
    cnt = 0
    for (j = st + 1; j <= n; j++) {
      c1 = substr(ARR[j], 1, 1)
      if (c1 == "-" || c1 == "(" || c1 == "!") break
      cnt++
      emit("find-delete", ARR[j], src, lno, cwd, raw)
    }
    if (cnt == 0) emit("find-delete", ".", src, lno, cwd, raw)
    return
  }
  # Creation verbs (BH-2210). Every operand is emitted; the reader only calls
  # one a hit when it lands under the forbidden-create root.
  if (v == "mkdir") {
    endopt = 0
    for (j = st + 1; j <= n; j++) {
      if (!endopt && ARR[j] == "--") { endopt = 1; continue }
      if (!endopt && (ARR[j] == "-m" || ARR[j] == "--mode" || ARR[j] == "--context")) { j++; continue }
      if (!endopt && substr(ARR[j], 1, 1) == "-") continue
      emit("mkdir", ARR[j], src, lno, cwd, raw)
    }
    return
  }
  if (v == "touch") {
    endopt = 0
    for (j = st + 1; j <= n; j++) {
      if (!endopt && ARR[j] == "--") { endopt = 1; continue }
      if (!endopt && (ARR[j] == "-d" || ARR[j] == "-r" || ARR[j] == "-t" || ARR[j] == "--date" || ARR[j] == "--reference")) { j++; continue }
      if (!endopt && substr(ARR[j], 1, 1) == "-") continue
      emit("touch", ARR[j], src, lno, cwd, raw)
    }
    return
  }
  if (v == "truncate") {
    endopt = 0
    for (j = st + 1; j <= n; j++) {
      if (!endopt && ARR[j] == "--") { endopt = 1; continue }
      if (!endopt && (ARR[j] == "-s" || ARR[j] == "-r" || ARR[j] == "--size" || ARR[j] == "--reference")) { j++; continue }
      if (!endopt && substr(ARR[j], 1, 1) == "-") continue
      emit("truncate", ARR[j], src, lno, cwd, raw)
    }
    return
  }
  if (v == "git") {
    dirc = ""
    j = st + 1
    while (j <= n) {
      if (ARR[j] == "-C") { dirc = ARR[j + 1]; j += 2; continue }
      if (ARR[j] == "-c") { j += 2; continue }
      if (substr(ARR[j], 1, 1) == "-") { j++; continue }
      break
    }
    if (j <= n && ARR[j] == "clean") emit("git-clean", (dirc == "" ? "." : dirc), src, lno, cwd, raw)
    return
  }
}

BEGIN { Q = sprintf("%c", 39) }

# A traced command that reassigns PS4 (BH-5541). After it, trace lines lose the
# src:line|pwd| stamp. Token 1 is a declare word and a later token is PS4=…, or
# every token is a NAME= assignment and one is PS4=…. xtrace spells
# `export PS4="+ "` as `export QPS4=+ Q`, which tokenizes to PS4=+ . Anything
# else (echo QPS4=…Q, a function called with a PS4= argument) is not a reassign.
function sets_ps4(c,   ARR, n, j, t1, hit) {
  n = tokenize(c, ARR)
  if (n == 0) return 0
  t1 = ARR[1]
  if (t1 == "export" || t1 == "declare" || t1 == "typeset" || t1 == "local" || t1 == "readonly") {
    for (j = 2; j <= n; j++) if (ARR[j] ~ /^PS4=/) return 1
    return 0
  }
  hit = 0
  for (j = 1; j <= n; j++) {
    if (ARR[j] !~ /^[A-Za-z_][A-Za-z0-9_]*=/) return 0
    if (ARR[j] ~ /^PS4=/) hit = 1
  }
  return hit
}

# An unstamped line: the src, line and cwd are not known, so each is "-".
function loose_scan(c,   raw) {
  raw = $0
  if (length(raw) > 200) raw = substr(raw, 1, 200)
  scan(c, (STDERR_SCAN ? "stderr" : "-"), "-", "-", raw)
}

{
  if ($0 !~ /^\+\+* /) next
  r2 = $0
  sub(/^\+\+* /, "", r2)
  if (STDERR_SCAN) { loose_scan(r2); next }
  rest = r2
  p = index(rest, "|"); if (p == 0) { if (loose) loose_scan(r2); next }
  srcline = substr(rest, 1, p - 1)
  rest = substr(rest, p + 1)
  p = index(rest, "|"); if (p == 0) { if (loose) loose_scan(r2); next }
  cwd = substr(rest, 1, p - 1)
  cmd = substr(rest, p + 1)
  sub(/^ /, "", cmd)
  if (cmd == "") next
  c = 0
  for (i = length(srcline); i > 0; i--) if (substr(srcline, i, 1) == ":") { c = i; break }
  if (c == 0) { if (loose) loose_scan(r2); next }
  src = basename(substr(srcline, 1, c - 1))
  lno = substr(srcline, c + 1)
  if (lno !~ /^[0-9]+$/) { if (loose) loose_scan(r2); next }
  raw = $0
  if (length(raw) > 200) raw = substr(raw, 1, 200)
  if (sets_ps4(cmd)) loose = 1
  scan(cmd, src, lno, cwd, raw)
}
'

# ── run every test, read every trace ────────────────────────────────────────
NTESTS=0; NEXIT=0; NHIT=0
for TEST_PATH in "${TESTS[@]}"; do
  NAME="$(basename "$TEST_PATH")"
  # The work files are keyed on the path relative to the root, not the
  # basename: --gate adds tests/mc/, and a suite there may share a basename with
  # one in tests/. The names PRINTED stay basenames, as they always were.
  KEY="${TEST_PATH#"$ROOT"/}"; KEY="${KEY//\//__}"
  TRACE="$WORK/$KEY.trace"
  ERRF="$WORK/$KEY.err"
  # stdout, kept only in the plain mode (--gate interleaves it into $ERRF) and
  # only for the canary read below.
  OUTF="$WORK/$KEY.out"; : > "$OUTF"
  NTESTS=$((NTESTS + 1))
  ROOT_BEFORE=0; root_exists && ROOT_BEFORE=1

  if [ "$GATE" = 1 ]; then
    # --gate: the test's own output is the pure-logic lane's evidence, so it is
    # kept (stdout and stderr interleaved, as a reader of a CI log expects)
    # instead of thrown away, and printed below when the test fails. stdin is
    # closed the way bin/lib/suite-runner.sh closes it (BH-514): a suite that
    # reads stdin must never eat the runner's.
    T0=$SECONDS; E0=$EPOCHREALTIME
    ( cd "$ROOT" && exec 199>"$TRACE" \
      && ${DFL_PIPE[@]+"${DFL_PIPE[@]}"} env -u HARNESS -u H -u HARNESS_CHECKOUT -u SCRATCH -u T \
             GH_TOKEN="$CANARY" GITHUB_TOKEN="$CANARY" BASH_ENV="$WORK/trace-env.sh" \
             timeout "$TEST_TIMEOUT" bash "$TEST_PATH" ) </dev/null >"$ERRF" 2>&1
    RC=$?
    E1=$EPOCHREALTIME
    echo "--- ${TEST_PATH#"$ROOT"/} rc=$RC $((SECONDS - T0))s"
    [ -z "$TIMINGS" ] || awk -v s="${TEST_PATH#"$ROOT"/}" -v a="${E0/,/.}" -v b="${E1/,/.}" -v rc="$RC" \
      'BEGIN { printf "%s\t%.1f\t%s\n", s, b - a, rc }' >> "$TIMINGS"
    [ "$RC" -eq 0 ] || print_redacted "$ERRF"
  else
    ( cd "$ROOT" && exec 199>"$TRACE" \
      && ${DFL_PIPE[@]+"${DFL_PIPE[@]}"} env -u HARNESS -u H -u HARNESS_CHECKOUT -u SCRATCH -u T \
             GH_TOKEN="$CANARY" GITHUB_TOKEN="$CANARY" BASH_ENV="$WORK/trace-env.sh" \
             timeout "$TEST_TIMEOUT" bash "$TEST_PATH" ) >"$OUTF" 2>"$ERRF"
    RC=$?
  fi

  EXIT_LINE=""
  if [ "$RC" -ne 0 ]; then
    NEXIT=$((NEXIT + 1))
    if [ "$RC" -eq 124 ]; then EXIT_LINE="TIMEOUT $NAME (killed after ${TEST_TIMEOUT}s)"
    else EXIT_LINE="EXIT $RC $NAME"
    fi
  fi

  [ -f "$TRACE" ] || die "no trace file for $NAME — fd 199 could not be opened in $WORK"
  [ -s "$TRACE" ] || die "$NAME produced no trace — the tracing mechanism was not honoured, so no clean result can be claimed from it"

  awk "$AWK_PARSE" "$TRACE" > "$WORK/candidates.txt"
  ARC=$?
  # The second pass reads the test's captured output for the default-PS4 rm
  # lines of a `bash -x` child (BH-5541). $ERRF is stderr, or stdout+stderr
  # under --gate.
  [ "$ARC" -ne 0 ] || { awk -v STDERR_SCAN=1 "$AWK_PARSE" "$ERRF" >> "$WORK/candidates.txt"; ARC=$?; }
  [ "$ARC" -eq 0 ] \
    || die "the trace parser exited $ARC on $NAME — no clean result can be claimed from it"

  HITS_HERE=0
  while IFS=$'\t' read -r VERB TARGET SRC LNO CWD RAW; do
    [ -n "$VERB" ] || continue
    case "$TARGET" in
      /*) ABS="$TARGET" ;;
      *)  [ "$CWD" != - ] || continue
          ABS="$CWD/$TARGET" ;;
    esac
    RESOLVED="$(realpath -m "$ABS" 2>/dev/null)" || RESOLVED="$ABS"
    [ -n "$RESOLVED" ] || RESOLVED="$ABS"
    if [ "$VERB" = mkdir ] || [ "$VERB" = touch ]; then
      forbidden_create "$RESOLVED" || continue
    elif [ "$VERB" = redirect ]; then
      safe_redirect "$RESOLVED" && continue
    else
      safe_target "$RESOLVED" && continue
    fi
    NHIT=$((NHIT + 1))
    HITS_HERE=$((HITS_HERE + 1))
    printf 'HIT %s %s %s (%s:%s, cwd %s)  %s\n' \
      "$NAME" "$VERB" "$RESOLVED" "$SRC" "$LNO" "$CWD" "$RAW"
  done < "$WORK/candidates.txt"

  if [ "$ROOT_BEFORE" = 0 ] && root_exists; then
    NHIT=$((NHIT + 1))
    HITS_HERE=$((HITS_HERE + 1))
    printf 'HIT %s created %s (existence probe: absent before the test, present after)\n' \
      "$NAME" "$CREATE_ROOT"
  fi

  if grep -qF -- "$CANARY" "$ERRF" "$OUTF" 2>/dev/null; then
    NHIT=$((NHIT + 1))
    HITS_HERE=$((HITS_HERE + 1))
    printf 'HIT %s printed-credential GH_TOKEN (a canary from the runner env reached the test output)\n' "$NAME"
  fi

  [ -z "$EXIT_LINE" ] || echo "$EXIT_LINE"
  if [ "$HITS_HERE" -gt 0 ]; then
    KEEP_WORK=1
  elif [ "${TRACE_SAFETY_KEEP:-}" != 1 ]; then
    rm -f "$TRACE" "$ERRF"
  fi
  rm -f "$OUTF"
done

echo "TRACE: $NTESTS tests, $NEXIT nonzero exit(s), $NHIT hit(s)"
if [ "$GATE" = 1 ]; then
  # Two verdicts from one run. The file is the fan-in jobs' input and is written
  # only here, after every test ran and every trace was read: every rc 2 above
  # exits before this line, so a missing file is a scan that did not complete.
  PURE=pass; [ "$NEXIT" -eq 0 ] || PURE=fail
  TRC=clean; [ "$NHIT" -eq 0 ] || TRC=dirty
  if [ -n "$VERDICT" ]; then
    mkdir -p "$(dirname "$VERDICT")" 2>/dev/null
    { echo "tests=$NTESTS"; echo "failed=$NEXIT"; echo "hits=$NHIT"
      echo "pure=$PURE"; echo "trace=$TRC"; } > "$VERDICT" \
      || die "cannot write the verdict file $VERDICT"
  fi
  echo "GATE: pure-logic $PURE ($NEXIT of $NTESTS failed), trace $TRC ($NHIT hit(s))"
  [ "$NHIT" -eq 0 ] && [ "$NEXIT" -eq 0 ]
  exit $?
fi
[ "$NHIT" -eq 0 ]
