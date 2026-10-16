#!/bin/bash
# bin/lib/suite-runner.sh — the loop that runs the shell suite inside the
# container for bin/run-tests-in-docker.sh (BH-514).
# Sourced, never executed: no `set -e`, no `exit`, no side effect at source time.
#
#   suite_runner_run <suite...>   run these suites, print the totals, return the
#                                 number that failed (capped at 125)
#   suite_runner_main             copy $SRC to $WORK, pick the suite list from
#                                 $SUITES, then suite_runner_run
#   suite_shard_parse <i/n>       validate a shard spec, echo "i n"
#   suite_shard_filter <i> <n> <suite...>
#                                 print shard i of n (duration-balanced)
#   suite_shard_plan <n> <suite...>
#                                 print "shard<TAB>weight_ms<TAB>suite" for all
#   suite_shard_size <budget_ms> <max_n> <suite...>
#                                 print "n<TAB>est_ms<TAB>total_ms<TAB>biggest_ms":
#                                 how many shards keep the slowest one in budget
#
# THE SHARD SPLIT LIVES HERE AND NOWHERE ELSE (BH-1192). CI runs the corpus as
# four parallel shards (`decisions-shard`, `harness-safety-shard`) and a laptop
# runs one shard at a time through bin/run-tests-in-docker.sh; bin/test-suite-run.sh
# and bin/test-trace-safety.sh both take `--shard i/n` and both get the answer
# from these two functions. A second implementation is how a suite ends up in
# two shards or in none, and neither shows up as anything but four green jobs.
#
# WHY THIS IS A LIBRARY AND NOT A HEREDOC. The runner used to hand this loop to
# the container on stdin (`bash -s <<'INNER'`). bash reads a script from stdin a
# line at a time, so the first suite that called `cat` or `read` consumed
# everything after the loop — the summary, the failing list, the final exit —
# and the shell hit EOF and exited 0. A red run printed no totals and reported
# success. Two things fix it and both are load-bearing: the container gets its
# script as a `bash -c` string with nothing on stdin, and every suite here runs
# with `</dev/null` so it cannot reach the runner's stdin even if one comes back.
#
# The totals print unconditionally, after every suite, whatever any of them did.
# The exit status is the number of failing suites, INCLUDING the ones on the
# known-failures list — that list changes how a failure is printed, never
# whether it counts.
#
#   VERBOSE=1             show each suite's own output under a `─── name` header
#   KNOWN_FILE=<path>     the known-failures list (default
#                         tests/known-container-failures.txt, read from the cwd)
#   SUITE_RUNNER_LABEL    the name in the summary line (default "debian trixie")

# suite_shard_parse <spec> — "i/n" in, "i n" out, rc 0. Anything else prints
# what was wrong on stderr and returns 2.
#
# EVERY MALFORMED SPEC IS REFUSED, none is rounded. A spec that fell back to
# "run everything" would quadruple CI silently; one that fell back to shard 0
# would drop three quarters of the corpus and still show four green shards and
# a green fan-in. There is no safe default here, so there is no default.
suite_shard_parse() {
  local spec="${1-}" i n
  case "$spec" in
    */*) i="${spec%%/*}"; n="${spec#*/}" ;;
    *)   echo "suite-runner: shard spec must be i/n, got '$spec'" >&2; return 2 ;;
  esac
  # n keeps everything after the FIRST slash, so "1/2/3" fails the digit test
  # below rather than parsing as 1 of 2.
  case "$i" in ''|*[!0-9]*) echo "suite-runner: shard index must be a whole number, got '$spec'" >&2; return 2 ;; esac
  case "$n" in ''|*[!0-9]*) echo "suite-runner: shard count must be a whole number, got '$spec'" >&2; return 2 ;; esac
  [ "$n" -ge 1 ] || { echo "suite-runner: shard count must be at least 1, got '$spec'" >&2; return 2; }
  [ "$i" -lt "$n" ] || { echo "suite-runner: shard index $i is out of range for $n shards ('$spec')" >&2; return 2; }
  printf '%s %s\n' "$i" "$n"
}

# suite_shard_filter <i> <n> <suite...> — print the members of shard i, one per
# line, C-sorted.
#
# DURATION-BALANCED, NOT COUNT-BALANCED (plan item A2, 2026-09-28). A merge-queue
# batch waits for its slowest shard, and a split by count put a 7-minute suite
# and a dozen 1-minute ones on the same shard: one batch measured 10..23 minutes
# across its eight shards when the even share was ~14.4. The split is now a
# greedy LPT over the suite durations file — see suite_shard_plan.
#
# The split is still a property of the NAMES and not of the order a caller's
# glob or locale handed them over: two callers with the same corpus and the
# same durations file compute the same shards, which is what makes "the union
# is the whole list" checkable at all. An empty input prints nothing and
# succeeds; refusing an empty corpus is the caller's job, because only the
# caller knows whether empty is a bug.
suite_shard_filter() {
  local i="$1" n="$2"
  shift 2
  [ "$#" -gt 0 ] || return 0
  suite_shard_plan "$n" "$@" | awk -F'\t' -v i="$i" '$1 == i { print $3 }' | LC_ALL=C sort
}

# suite_shard_plan <n> <suite...> — the whole assignment, one line per suite:
# "<shard>\t<weight ms>\t<suite>". suite_shard_filter is this, narrowed to one
# shard; the tests read it whole to check the balance.
#
# LONGEST FIRST ONTO THE LEAST-LOADED SHARD. Each suite weighs its recorded
# seconds from the durations file ($SUITE_DURATIONS_FILE, default
# catalog/ci-suite-durations.tsv next to this library; `<suite>\t<seconds>\t
# <source run>[\t<values>]`, `#` comments). That file is not committed
# (BH-5518): CI composes it with bin/ci-durations.sh and every shard reads the
# plan job's copy. A suite the file does not name — a new one, or a
# fixture — weighs the MEDIAN of the file, so it is placed like a typical suite
# rather than dropped or piled onto shard 0. No file, or an empty one, makes
# every weight equal, and then the rule below IS the old split: sorted names
# dealt round-robin.
#
# DETERMINISTIC BY CONSTRUCTION: weights are integer milliseconds, the order is
# weight descending then C-sorted name, and a tie between shards goes to the
# lowest index. No float compare, no locale, no input order reaches the answer.
# Every shard of one CI run computes this from the same checkout, and
# --expect-n plus bin/ci-verdicts.sh's tests= sum still catch a split that
# drops or doubles a suite.
#
# A suite is keyed by its path from the LAST `tests/` on: bin/test-trace-safety.sh
# hands over absolute paths, bin/test-suite-run.sh relative ones, and both must
# weigh a suite the same.
suite_shard_plan() {
  local n="$1" df
  shift
  [ "$#" -gt 0 ] || return 0
  df="${SUITE_DURATIONS_FILE-$(dirname "${BASH_SOURCE[0]}")/../../catalog/ci-suite-durations.tsv}"
  [ -r "$df" ] || df=/dev/null
  printf '%s\n' "$@" | awk -F'\t' -v df="$df" '
    function key(s,   p) { while ((p = index(s, "/tests/")) > 0) s = substr(s, p + 1); return s }
    BEGIN {
      m = 0
      while ((getline line < df) > 0) {
        if (line ~ /^[[:space:]]*#/) continue
        split(line, f, "\t")
        if (f[2] !~ /^[0-9]+(\.[0-9]+)?$/) continue
        w = int(f[2] * 1000 + 0.5); if (w < 1) w = 1
        d[f[1]] = w; v[++m] = w
      }
      close(df)
      # median, by insertion sort (a few thousand rows at most)
      for (a = 2; a <= m; a++) { x = v[a]; for (b = a - 1; b >= 1 && v[b] > x; b--) v[b + 1] = v[b]; v[b + 1] = x }
      med = (m == 0) ? 1 : (m % 2 ? v[(m + 1) / 2] : int((v[m / 2] + v[m / 2 + 1]) / 2))
    }
    { k = key($0); print ((k in d) ? d[k] : med) "\t" $0 }
  ' | LC_ALL=C sort -t"$(printf '\t')" -k1,1nr -k2,2 | awk -F'\t' -v n="$n" '
    { best = 0
      for (s = 1; s < n; s++) if (load[s] + 0 < load[best] + 0) best = s
      load[best] += $1
      print best "\t" $1 "\t" $2 }'
}

# suite_shard_size <budget_ms> <max_n> <suite...> — the shard COUNT, by measured
# time (BH-6876): "<n>\t<est_ms>\t<total_ms>\t<biggest_ms>", where est_ms is the
# load of the slowest shard of suite_shard_plan n. The count and the split use
# the same LPT and the same durations file, so n is the split the shards run.
#
# n is the smallest count from ceil(total / budget) up whose slowest shard is
# within max(budget, biggest suite): one suite longer than the budget cannot be
# split, so its own time is the floor. n never passes max_n (the cap) or the
# number of suites (no empty shard); at that bound n is said with its load,
# over budget or not, and the caller says so. No suite prints nothing, rc 0. A
# budget or cap that is not a positive integer is rc 2.
suite_shard_size() {
  local budget="${1-}" max="${2-}" total biggest target n hi load
  shift 2 2>/dev/null || return 2
  case "$budget" in ''|*[!0-9]*|0) echo "suite-runner: shard budget must be a positive whole number of ms, got '$budget'" >&2; return 2 ;; esac
  case "$max" in ''|*[!0-9]*|0) echo "suite-runner: shard cap must be a positive whole number, got '$max'" >&2; return 2 ;; esac
  [ "$#" -gt 0 ] || return 0
  read -r total biggest < <(suite_shard_plan 1 "$@" \
    | awk -F'\t' '{ t += $2; if ($2 > b) b = $2 } END { printf "%d %d\n", t, b }')
  target=$budget; [ "$biggest" -le "$target" ] || target=$biggest
  hi=$#; [ "$max" -ge "$hi" ] || hi=$max
  n=$(( (total + budget - 1) / budget )); [ "$n" -ge 1 ] || n=1; [ "$n" -le "$hi" ] || n=$hi
  while :; do
    load=$(suite_shard_plan "$n" "$@" \
      | awk -F'\t' '{ s[$1] += $2 } END { m = 0; for (k in s) if (s[k] > m) m = s[k]; printf "%d\n", m }')
    [ "$load" -gt "$target" ] && [ "$n" -lt "$hi" ] || break
    n=$((n + 1))
  done
  printf '%s\t%s\t%s\t%s\n' "$n" "$load" "$total" "$biggest"
}

suite_runner_known() {
  [ -f "$1" ] || return 1
  grep -v '^[[:space:]]*#' "$1" | grep -qxF -- "$2"
}

suite_runner_run() {
  local verbose="${VERBOSE:-0}"
  local known_file="${KNOWN_FILE:-tests/known-container-failures.txt}"
  local label="${SUITE_RUNNER_LABEL:-debian trixie}"
  local pass=0 fail=0 failed="" t rc

  for t in "$@"; do
    # A suite we were asked for and cannot run is a FAILURE, not a skip. The
    # old `[ -f "$t" ] || continue` made `bin/run-tests-in-docker.sh
    # tests/typo-test.sh` print "0 pass, 0 fail" and exit 0.
    if [ ! -f "$t" ]; then
      echo "suite-runner: no such suite: $t" >&2
      fail=$((fail+1)); failed="$failed $t"
      continue
    fi
    if [ "$verbose" = 1 ]; then
      echo "─── $t"
      bash "$t" </dev/null
    else
      bash "$t" </dev/null >/dev/null 2>&1
    fi
    rc=$?
    if [ "$rc" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); failed="$failed $t"; fi
  done

  echo
  echo "─────────────────────────────────────────────"
  printf '%s: %d pass, %d fail\n' "$label" "$pass" "$fail"
  if [ "$fail" -gt 0 ]; then
    local expected=0 first_unexpected="" first_failure=""
    echo "failing:"
    for t in $failed; do
      [ -n "$first_failure" ] || first_failure="$t"
      if suite_runner_known "$known_file" "$t"; then
        printf '  %s   expected (%s)\n' "$t" "$known_file"
        expected=$((expected+1))
      else
        printf '  %s\n' "$t"
        [ -n "$first_unexpected" ] || first_unexpected="$t"
      fi
    done
    [ "$expected" -gt 0 ] &&
      printf '%d of %d expected (listed in %s)\n' "$expected" "$fail" "$known_file"
    if [ "$verbose" != 1 ]; then
      # Point at the failure that matters: a listed one is already explained.
      local hint="${first_unexpected:-$first_failure}"
      echo "re-run one of them with its name to see why:"
      echo "  bin/run-tests-in-docker.sh $hint"
    fi
  fi
  echo "─────────────────────────────────────────────"

  [ "$fail" -gt 125 ] && return 125
  return "$fail"
}

suite_runner_main() {
  local src="${SRC:-/repo}" work="${WORK:-/work/src}"
  # The mount is read-only and several suites write next to their fixtures, so
  # the suite runs against a copy. A copy that did not happen is a failure.
  cp -a "$src" "$work" 2>/dev/null ||
    { mkdir -p "$work" && cp -a "$src/." "$work/"; } ||
    { echo "suite-runner: could not copy $src to $work" >&2; return 2; }
  cd "$work" || return 2
  chmod -R u+w . 2>/dev/null

  # Whole-suite runs print names only — 124 suites of output is unreadable.
  # Naming suites on the command line prints everything they say, because at
  # that point you are debugging one and the output IS the answer.
  if [ -n "${SUITES:-}" ]; then
    # shellcheck disable=SC2086
    set -- $SUITES
    VERBOSE=1
  else
    set -- tests/*.sh tests/mc/*.sh
    # tests/mc/ is empty until the split's module suites land, and the loop
    # above counts a non-file argument as a FAILED suite on purpose (BH-514),
    # so the unmatched glob is dropped here — on the default path only.
    local _d=() _f; for _f in "$@"; do [ -f "$_f" ] && _d+=("$_f"); done; set -- "${_d[@]}"
    # An empty match is a broken copy or a wrong SRC, never a green run
    # (BH-514 removed exactly this vacuous 0 pass, 0 fail).
    [ "$#" -gt 0 ] || { echo "suite-runner: no suites matched tests/*.sh tests/mc/*.sh in $work" >&2; return 2; }
    # SUITE_SHARD=i/n runs one quarter of the corpus (BH-1192). It applies to
    # the whole-suite path only: naming suites on the command line is how you
    # debug one, and quietly dropping three of four named suites because a
    # shard was exported in this shell would be its own silent failure.
    if [ -n "${SUITE_SHARD:-}" ]; then
      local _spec _i _n _picked=() _one
      _spec=$(suite_shard_parse "$SUITE_SHARD") || return 2
      _i=${_spec% *}; _n=${_spec#* }
      while IFS= read -r _one; do [ -n "$_one" ] && _picked+=("$_one"); done \
        < <(suite_shard_filter "$_i" "$_n" "$@")
      # A shard with nothing in it is a misconfiguration (more shards than
      # suites), never a green run — the same vacuous 0 pass, 0 fail BH-514
      # removed, one level up.
      [ "${#_picked[@]}" -gt 0 ] \
        || { echo "suite-runner: shard $SUITE_SHARD selected none of the $# suites in $work" >&2; return 2; }
      set -- "${_picked[@]}"
      SUITE_RUNNER_LABEL="${SUITE_RUNNER_LABEL:-debian trixie} shard $_i/$_n"
    fi
    VERBOSE=0
  fi
  suite_runner_run "$@"
}
