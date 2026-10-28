#!/bin/bash
# tests/lib/scratch.sh — shared scratch library for every tests/*-test.sh.
# Sourced, never executed. Creates a writable temp tree, sets T, and provides
# safe cleanup helpers.
#
# Safety guard: refuses to run as root next to what looks like a live harness
# unless HARNESS_TEST_SANDBOX=1. The harness root can be overridden for tests
# via HARNESS_ROOT_OVERRIDE. The guard `exit`s rather than `return`s: 260 of the
# 262 tests/*-test.sh in this repo run without errexit, so a `return` would end
# the source and let the test run on with T unset — the first rm -rf "$T/x"
# would then be rm -rf /x. The file is sourced and never executed, so exit IS
# the abort.
#
# SCRATCH and T are deliberately NOT exported. A child process that inherited
# SCRATCH would delete its parent's live tree on its own source; a child that
# needs a scratch tree sources this library and gets its own.

# BH-1138: THE choke point for every test's python. tests/gate-selfwrite-test.sh
# loads bin/gate-selfwrite.py through importlib.exec_module, and a dozen more
# tests `sys.path.insert` the repo's bin/ and import alert_family — each of
# which writes bin/__pycache__/<file>.cpython-3XX.pyc into the CHECKOUT, not
# into $T. That is exactly how bin/__pycache__/gate-selfwrite.cpython-312.pyc
# came to be tracked: a test left it behind and the next whole-tree `git add -A`
# committed it. Every test sources this library before it runs anything, so one
# export here covers all of them, including the ones not written yet.
export PYTHONDONTWRITEBYTECODE=1

__scratch_harness_root="${HARNESS_ROOT_OVERRIDE:-/root/harness}"

if [ "$(id -u)" -eq 0 ] && [ -d "$__scratch_harness_root" ] && [ "${HARNESS_TEST_SANDBOX:-}" != "1" ]; then
  echo "scratch.sh: refusing to run as root next to live harness $__scratch_harness_root (set HARNESS_TEST_SANDBOX=1 to override)" >&2
  exit 1
fi

# >>> context-budgets compose (BH-6487)
# catalog/context-budgets.json is composed from catalog/context-budgets.d/ and
# git-ignored. About 100 suites read it and about 100 more load the jobs worker,
# which imports it. Every one of them sources this file before it reads
# anything, so one compose here replaces a line in each suite. It never exits:
# a suite that does not read the manifest must not die on it, and one that does
# fails on its own read with this line above it. An unchanged compose writes
# nothing, and a tree with no context-budgets.d/ (a fixture copy) is skipped.
__scratch_repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd)
if [ -n "$__scratch_repo" ] && [ -d "$__scratch_repo/catalog/context-budgets.d" ] \
   && [ -x "$__scratch_repo/bin/context-budgets-build.sh" ]; then
  "$__scratch_repo/bin/context-budgets-build.sh" --compose --repo "$__scratch_repo" >/dev/null 2>&1 \
    || echo "scratch.sh: catalog/context-budgets.json could not be composed from catalog/context-budgets.d (run bin/context-budgets-build.sh --check)" >&2
fi
unset __scratch_repo
# <<< context-budgets compose

# fly/entrypoint.sh exports HARNESS_ENV_DIR on pool machines; resolver rule 1
# would otherwise send every scratch $T/h/env fixture to the live tmpfs.
unset HARNESS H HARNESS_CHECKOUT HARNESS_ENV_DIR
# BH-3223: a pool machine's build env carries HARNESS_SECRET and COST_ROWS_BOX,
# and an UNSET JOBS_URL falls back to the live worker (bin/lib/jobs/req.sh), so
# every stub-runner cost row a suite made landed in prod cost_rows. EMPTY is the
# documented "no worker here" answer; exported so a child bin/agent-call.sh gets
# it too. A test that wants a stub sets JOBS_URL=http://... after sourcing this.
# The secret and the box id go too, so a suite sees the environment CI gives it:
# an ambient HARNESS_SECRET stops bin/jobs-client.sh reading a fixture
# global.env, and an ambient COST_ROWS_BOX outranks a fixture's state/box-id.
export JOBS_URL=
unset HARNESS_SECRET COST_ROWS_BOX
# BH-8079: an UNSET PROJECT_21_BASE_URL is https://project-21.example (bin/project-21-check.sh),
# and every build-lane suite that reaches the pr stage would send its scratch
# lockfiles there. EMPTY is "not configured": no request, the check reports
# failed. A suite that drives the fake API sets it after sourcing this.
export PROJECT_21_BASE_URL=
# BH-6672: a pool machine's build env exports GH_TOKEN as a live GitHub App
# installation token, and tests/batch-resolve-test.sh printed it into the run
# output. A suite gets no GitHub credential from the shell that started it; one
# that needs a token sets a fixture after sourcing this. GH_APP_RATCHET_OWNER_TOKEN
# stays: CI hands it to tests/gh-app-ratchet-test.sh on purpose, by that name.
unset GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN MC_GIT_TOKEN
# BH-5781: lane_gate_or_exit sleeps a per-box start offset (up to 120 s) at a
# quarter-hour minute. A suite that runs a lane at :00/:15/:30/:45 must not
# wait for it; tests/lane-start-offset.bh-5781-test.sh unsets this to drive it.
export LANE_START_SPREAD_S=0
# BH-6942: LANE_RUN_CODE_SYNC=1 also turns on the lane-run worker's boot repo
# check (bin/lib/lane-run-repos.sh), one GitHub read per fleet.conf repo. A
# suite with no gh stub must not reach GitHub through it;
# tests/lane-run-head-read.bh-6942-test.sh sets it to 1 to drive it.
export LANE_RUN_REPO_CHECK=0
# BH-5337: rpool_init (bin/lib/review-pool.sh) caps a review pool at the box's
# vCPU count and counts a tmpfs /tmp as RAM. A pool suite that runs K workers
# at once must size K the same on a 2 vCPU runner with a tmpfs /tmp as on a
# big one; tests/review-pool-cap.bh-5337-test.sh sets both per case.
export REVIEW_POOL_NPROC=64 REVIEW_POOL_TMP_FSTYPE=disk
# BH-5617: a box shell that exported the Sentry DSN would post a suite's fake
# events to the live project. Same reason as HARNESS_SECRET.
unset HARNESS_SENTRY_DSN
# BH-4080: every consumer of the deployment defaults sources
# "${HARNESS_DEPLOYMENT_FILE-<beside itself>/deployment.sh}", and a scratch tree
# that copied one lib or one script has no copy beside it. Point them all at
# this checkout's own file, so a suite sees the defaults a box does. A value a
# suite sets (HARNESS_REPO=o/x) still wins: the file only fills what is unset.
HARNESS_DEPLOYMENT_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/bin/lib/deployment.sh"
export HARNESS_DEPLOYMENT_FILE

__scratch_tmp_base() {
  realpath -m "${TMPDIR:-/tmp}"
}

# A path is inside the base only if it is a scratch.XXXXXX tree we made — never
# the base itself, or an inherited SCRATCH=/tmp would chmod -R +w and rm -rf the
# whole temp directory.
__scratch_inside_base() {
  local target base
  target=$(realpath -m "$1") || return 1
  base=$(__scratch_tmp_base) || return 1
  case "$target" in
    "$base"/scratch.??????) return 0 ;;
    *) return 1 ;;
  esac
}

# __scratch_unlock <dir> — clear chattr +i/+a under a tree WE made, so rm -rf can
# finish (BH-5007: tests/harden-state-test.sh arms +a on eight ledgers in its
# scratch harness and 20 trees leaked on box-small). Caller has
# already proved the path is inside SCRATCH / the scratch base, and calls it
# only when a plain rm -rf left the tree behind. That first rm is quiet; the
# retry after the unlock is not, so a tree that is still stuck says why.
__scratch_unlock() {
  command -v chattr >/dev/null 2>&1 || return 0
  chattr -R -ia -- "$1" 2>/dev/null || true
}

__scratch_cleanup_old() {
  [ -n "${SCRATCH:-}" ] || return 0
  [ "${__scratch_owner_pid:-}" = "${BASHPID:-$$}" ] || return 0
  local old
  old=$(realpath -m "$SCRATCH") || return 0
  if __scratch_inside_base "$old" && [ -d "$old" ]; then
    chmod -R +w "$old"
    rm -rf "$old" 2>/dev/null
    if [ -e "$old" ]; then __scratch_unlock "$old"; rm -rf "$old"; fi
  fi
}

# If the library is sourced again in the same shell, remove the previous tree
# and replace the EXIT trap rather than leaking both.
__scratch_cleanup_old
[ -n "${SCRATCH:-}" ] && [ "${__scratch_owner_pid:-}" = "${BASHPID:-$$}" ] && trap - EXIT

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}"/scratch.XXXXXX)
T=$SCRATCH
__scratch_owner_pid=${BASHPID:-$$}
# 755, not 555: every existing test writes directly into its temp tree, and
# those writes must work under a non-root runner too. The root/live-harness
# guard above and the path checks below carry the safety, not the mode bits.
chmod 755 "$SCRATCH"
# BH-3982: harness_env_dir's rule 3 answers /etc/harness/env, the box's REAL env
# dir, for any $HARNESS with no env/ of its own, and bin/jobs-client.sh then
# reads the real HARNESS_SECRET and JOBS_URL from it (an EMPTY JOBS_URL is
# adopted, not kept). A suite that already pins ETC_HARNESS_ENV per command
# (25 do) still wins; CI has no /etc/harness/env, so this is what CI sees.
export ETC_HARNESS_ENV="$SCRATCH/.no-etc-harness-env"
# BH-6672: and a real `gh` reads no login from the box's ~/.config/gh.
export GH_CONFIG_DIR="$SCRATCH/.gh-config"

__scratch_inside() {
  [ -n "${SCRATCH:-}" ] || return 1
  local target base
  target=$(realpath -m "$1") || return 1
  base=$(realpath -m "$SCRATCH") || return 1
  case "$target" in
    "$base"|"$base"/*) return 0 ;;
    *) return 1 ;;
  esac
}

scratch_rm() {
  local target
  target="$1"
  if ! __scratch_inside "$target"; then
    echo "scratch_rm: refusing path outside SCRATCH: $target" >&2
    return 1
  fi
  rm -rf "$target"
}

scratch_cleanup() {
  local target
  target="${1:-$SCRATCH}"
  if ! __scratch_inside "$target"; then
    echo "scratch_cleanup: refusing path outside SCRATCH: $target" >&2
    return 1
  fi
  [ -e "$target" ] || return 0
  chmod -R +w "$target"
  rm -rf "$target" 2>/dev/null
  if [ -e "$target" ]; then __scratch_unlock "$target"; rm -rf "$target"; fi
}

# The trap fires in subshells too; only the shell (or subshell) that created the tree may
# remove it.
__scratch_exit_trap() {
  [ "${__scratch_owner_pid:-}" = "${BASHPID:-$$}" ] || return 0
  scratch_cleanup
}

trap __scratch_exit_trap EXIT

# BH-4552: a scratch tree gets a script's whole SOURCE CLOSURE, not a hand list.
# Suites that copied "the libs this lane sources" by name went red in the merge
# queue each time a lane grew a new lib or lib directory (bin/lib/tracker/ for
# #4242, bin/lib/pr-owner/ for #4002, bin/lib/deployment.sh for #4415).
# docs/notes/2026-10-05-BH-4552-scratch-install-closure.md has the rules.
#
#   scratch_closure_list <repo-rel-script>
#       print the script, then every bin/lib file it sources, transitively,
#       sorted. rc 1 (stderr names it) when a source line names a literal
#       file that resolves nowhere; rc 2 on an empty, absolute, `..` or
#       nonexistent script.
#   scratch_install_closure <repo-rel-script> <dest-root>
#       copy that list to <dest-root>/<rel> (cp -p), printing what it copied.
#       NO-CLOBBER: a file the suite already wrote there (a stub) is kept.
#       rc 2 for a dest outside SCRATCH; rc 1 from the list copies nothing.
#
# The repo is the one this library lives in; SCRATCH_CLOSURE_REPO overrides it
# for a suite's synthetic repos.

__scratch_closure_lib=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

__scratch_closure_repo() {
  realpath -m "${SCRATCH_CLOSURE_REPO:-$__scratch_closure_lib/../..}"
}

# __scratch_closure_resolve <repo> <fdir> <tail> — print "ok<TAB><rel>" for
# each bin/lib file <tail> names, seen from a file in <fdir>. rc 0 when it
# names an existing file (inside bin/lib or not), 1 when a literal tail names
# nothing, 3 when the tail is not resolvable statically.
#   bin/... from the repo; lib/... from <fdir>, then bin/; anything else from
#   <fdir>, then bin/lib/, then bin/. A `$` or `*` in the last segment is a
#   glob, taken only with a literal part (fc-$lane.sh) or under a bin/lib
#   subdirectory (tracker/$a.sh), never a bare $mod.sh over all of bin/lib.
__scratch_closure_resolve() {
  local repo="$1" fdir="$2" tail="$3" seg dpart pat lit base p g found="" hit=1
  seg="${tail##*/}"; dpart=""
  [[ $tail == */* ]] && dpart="${tail%/*}/"
  [[ $dpart == *[\$*]* ]] && return 3
  case "$tail" in
    bin/*) set -- "$repo" ;;
    lib/*) set -- "$fdir" "$repo/bin" ;;
    *)     set -- "$fdir" "$repo/bin/lib" "$repo/bin" ;;
  esac
  if [[ $seg == *[\$*]* ]]; then
    pat=$(sed -E 's/\$\{[^}]*\}|\$[A-Za-z0-9_]+|\*+/*/g' <<< "$seg")
    lit="${pat//\*/}"; lit="${lit%.sh}"
    for base in "$@"; do
      p=$(realpath -m "$base/$dpart") || continue
      [[ $p == "$repo/bin/lib/"* || ( -n $lit && $p == "$repo/bin/lib" ) ]] || continue
      while IFS= read -r g; do
        [ -f "$g" ] && { printf 'ok\t%s\n' "${g#"$repo"/}"; hit=0; }
      done < <(compgen -G "$p/$pat")
    done
    [ "$hit" = 0 ] && return 0
    return 3
  fi
  for base in "$@"; do
    p="$base/$tail"
    [[ $p == */../* || $p == */./* ]] && p=$(realpath -m "$p")
    [ -f "$p" ] && { found="$p"; break; }
  done
  [ -n "$found" ] || return 1
  [[ $found == "$repo/bin/lib/"* ]] && printf 'ok\t%s\n' "${found#"$repo"/}"
  return 0
}

# __scratch_closure_scan <repo> <rel> — one line per reference in <rel>:
# "ok<TAB><rel>" for a bin/lib file it reaches, "missing<TAB><tail>" for a
# literal source that resolves nowhere. Lines read: source statements, `for x
# in` lists and NAME= assignments; each `.sh` token on them is cut to its tail
# after the last `}`, `)` or `$NAME` before a `/`, so $(dirname "$0")/lib/x.sh,
# ${HARNESS:-...}/bin/lib/x.sh and "$dir/x.sh" all come down to a relative path.
# A NAME= whose value cuts to a literal directory (MC_LIB_DIR=".../mc") is
# remembered, and "$NAME/x.sh" later in the file is tried as mc/x.sh first.
__scratch_closure_scan() {
  local repo="$1" rel="$2" fdir line rest tok tail pre v opnd rc t r
  local -A dirvar=()
  local re_src='(^|[;{(&|]|(^|[[:space:]])(then|else|do|if|!))[[:space:]]*(\.|source)[[:space:]]'
  local re_for='(^|[;{(&|[:space:]])for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]'
  local re_asg='(^|[;{(&|[:space:]])[A-Za-z_][A-Za-z0-9_]*='
  local re_dir='^[[:space:]]*(local[[:space:]]+|export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)='
  local re_tok='([^[:space:]"'\''`;|&<>=]*\.sh)([^[:alnum:]_.-]|$)'
  local re_cut='^(.*)(\}|\)|\$[A-Za-z_][A-Za-z0-9_]*|\$[0-9#@*?!])/(.*)$'
  fdir=$(dirname "$repo/$rel")
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ ^[[:space:]]*# ]] && continue
    if [[ $line == *=*/* && $line =~ $re_dir ]]; then
      v="${BASH_REMATCH[2]}"; tail="${line#*"$v"=}"; tail="${tail//[\"\']/}"
      unset 'dirvar[$v]'
      if [[ $tail != *.sh ]] && [[ $tail =~ $re_cut ]]; then
        tail="${BASH_REMATCH[3]%/}"
        [[ $tail =~ ^[A-Za-z0-9_.][A-Za-z0-9_./-]*$ ]] && dirvar[$v]="$tail"
      fi
    fi
    [[ $line == *.sh* ]] || continue
    line="${line%%[[:space:]]#*}"
    # The operand of each `.`/`source` is the first .sh token after it in the
    # same simple command; only an operand that resolves nowhere is "missing"
    # (a printf '%s/lib/x.sh' on the same line is not).
    opnd=" "; rest="$line"
    while [[ $rest =~ $re_src ]]; do
      rest="${rest#*"${BASH_REMATCH[0]}"}"
      [[ $rest =~ $re_tok ]] || break
      pre="${rest%%"${BASH_REMATCH[1]}"*}"
      [[ $pre == *[\;\|\&]* ]] || opnd+="${BASH_REMATCH[1]} "
    done
    if [ "$opnd" = " " ] && ! [[ $line =~ $re_src ]] && ! [[ $line =~ $re_for ]] && ! [[ $line =~ $re_asg ]]; then
      continue
    fi
    rest="$line"
    while [[ $rest =~ $re_tok ]]; do
      tok="${BASH_REMATCH[1]}"
      rest="${rest#*"$tok"}"
      tail="$tok"; t=""
      if [[ $tail =~ $re_cut ]]; then
        pre="${BASH_REMATCH[1]}${BASH_REMATCH[2]}"; tail="${BASH_REMATCH[3]}"
        [[ $pre =~ \$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$ && -n ${dirvar[${BASH_REMATCH[1]}]:-} ]] \
          && t="${dirvar[${BASH_REMATCH[1]}]}/$tail"
      fi
      tail="${tail#/}"
      [[ $tail == */bin/lib/* ]] && tail="bin/lib/${tail#*/bin/lib/}"
      [ -n "$tail" ] || continue
      rc=1
      for r in ${t:+"$t"} "$tail"; do
        __scratch_closure_resolve "$repo" "$fdir" "$r"; rc=$?
        [ "$rc" = 0 ] && break
      done
      [ "$rc" = 1 ] && [[ $opnd == *" $tok "* ]] && printf 'missing\t%s\n' "$tail"
    done
  done < "$repo/$rel"
}

scratch_closure_list() {
  local script="${1:-}" repo kind f bad=0 i=0
  local -a queue
  local -A seen
  case "$script" in
    ''|/*|..|../*|*/..|*/../*) echo "scratch_closure_list: want a repo-relative script, got '$script'" >&2; return 2 ;;
  esac
  repo=$(__scratch_closure_repo) || return 2
  [ -f "$repo/$script" ] || { echo "scratch_closure_list: no $script in $repo" >&2; return 2; }
  script="${script#./}"
  queue=("$script"); seen[$script]=1
  while [ "$i" -lt "${#queue[@]}" ]; do
    while IFS=$'\t' read -r kind f; do
      case "$kind" in
        ok) [ -n "${seen[$f]:-}" ] || { seen[$f]=1; queue+=("$f"); } ;;
        missing) echo "scratch_closure: ${queue[$i]}: sources missing $f" >&2; bad=1 ;;
      esac
    done < <(__scratch_closure_scan "$repo" "${queue[$i]}")
    i=$((i + 1))
  done
  [ "$bad" = 0 ] || return 1
  printf '%s\n' "$script"
  printf '%s\n' "${queue[@]:1}" | LC_ALL=C sort -u | grep -v '^$'
  return 0
}

scratch_install_closure() {
  local script="${1:-}" dest="${2:-}" repo list f
  if [ -z "$dest" ] || ! __scratch_inside "$dest"; then
    echo "scratch_install_closure: refusing dest outside SCRATCH: '$dest'" >&2; return 2
  fi
  list=$(scratch_closure_list "$script") || return $?
  repo=$(__scratch_closure_repo) || return 2
  while IFS= read -r f; do
    [ -e "$dest/$f" ] || [ -L "$dest/$f" ] && continue
    mkdir -p "$dest/$(dirname "$f")" && cp -p "$repo/$f" "$dest/$f" \
      || { echo "scratch_install_closure: cannot copy $f to $dest" >&2; return 1; }
    printf '%s\n' "$f"
  done <<< "$list"
}
