# shellcheck shell=bash
# bin/lib/mrb-probe.sh — main-red-bisect: which suites went red, does a sha
# run them red, and which merge turned main red. Sourced, never run.
#
# BH-3685 contract (BH-3693): siblings replace the bodies, never the
# signatures. BH-3694 filled in all three bodies below. No driver calls them
# yet: bin/main-red-bisect.sh is a later BH-3685 sibling. The file defines
# functions only: no shell options, no exit, no output when sourced.

# mrb_suites_from_log
#   stdin:  a CI job log. A suite result line looks like `--- tests/x.sh rc=1`,
#           optionally after a job-log timestamp (`2026-09-30T18:30:29.0761234Z `)
#           and with CRLF endings.
#   stdout: the red suites, one tests/ path per line, each at most once,
#           sorted (LC_ALL=C). A line with rc=0, a `HIT` trace line, a path
#           outside tests/ and an unanchored `x--- tests/...` are all ignored.
#   rc:     0. Reads all of stdin, so a writer piping a large log never takes
#           SIGPIPE.
#   bin/nightly-ticket.sh reads the same `--- <suite> rc=<n>` lines with a
#   narrower path class since BH-6838. The timestamp must start with a digit: `[0-9TZ:.-]+ ` alone would
#   also eat the `--- ` of an untimestamped result line.
mrb_suites_from_log() {
  sed -E 's/\r$//; s/^[0-9][0-9TZ:.-]* //' \
    | sed -n 's/^--- \(tests\/[^ ]*\) rc=\([1-9][0-9]*\).*/\1/p' | LC_ALL=C sort -u
  return 0
}

# mrb_probe <repo-dir> <sha> <suites-file>
#   Runs the suites named in <suites-file> (one tests/ path per line; lines
#   outside tests/, or with `..`, are dropped) against a `git archive` snapshot
#   of <sha> in a fresh /tmp/mrb-XXXXXX dir, removed on every exit. The
#   snapshot is `git init`ed, like bin/test-impact-gate.sh's isolated_run.
#   Each suite runs as `bash <suite>` under `env -i` (no HARNESS_TEST_SANDBOX,
#   no tokens) and `timeout -k 10 ${MAIN_RED_BISECT_SUITE_TIMEOUT_S:-900}`
#   (900 when that is not a positive integer), stdin and output discarded.
#   The first red suite ends the probe. One `mrb-probe: <sha7> <suite> rc=<r>`
#   line per suite run goes to stderr, with `timeout after <n>s` on rc 124.
#   Runner: as nobody through `setpriv --reuid --regid --clear-groups`, the
#   snapshot chowned to nobody. `MRB_RUNNER=local` (tests only) runs it as the
#   current user instead, still under env -i.
#   stdout: exactly one word: red | green | norun
#     red    a suite exited non-zero. A timeout is red. A suite missing at an
#            older sha counts as red (bash answers rc 127 for it), never green.
#     green  every listed suite ran and passed.
#     norun  the probe could not run the suites at all: a sha that is not hex
#            or not a commit in <repo-dir>, no suites file or nothing in it to
#            run, a snapshot that failed, or a runner that cannot start
#            (setpriv missing, no nobody user, a caller that cannot switch to
#            it). The reason is one `mrb-probe:` line on stderr. Never read as
#            green.
#   rc:     0 whenever that word was printed.
#   The body is a subshell, so its EXIT trap never replaces the caller's.
mrb_probe() (
  d=""
  trap 'case "$d" in /tmp/mrb-?*) rm -rf "$d" ;; esac' EXIT
  set +e
  set -o pipefail
  _mrb_norun() { echo "mrb-probe: $*" >&2; echo norun; exit 0; }
  repo=${1:-}; sha=${2:-}; list=${3:-}
  case "$sha" in ''|*[!0-9a-fA-F]*) _mrb_norun "not a sha: '$sha'" ;; esac
  [ "${#sha}" -ge 4 ] && [ "${#sha}" -le 64 ] || _mrb_norun "not a sha: '$sha'"
  full=$(git -C "$repo" rev-parse -q --verify "$sha^{commit}" 2>/dev/null) && [ -n "$full" ] \
    || _mrb_norun "$sha is not a commit in $repo"
  sha7=${full:0:7}
  [ -f "$list" ] && [ -r "$list" ] || _mrb_norun "cannot read the suites file $list"
  suites=$(sed 's/\r$//' "$list" | grep -E '^tests/' | grep -vF '..')
  [ -n "$suites" ] || _mrb_norun "nothing to run in $list"
  to=${MAIN_RED_BISECT_SUITE_TIMEOUT_S:-900}
  case "$to" in ''|*[!0-9]*|0*) to=900 ;; esac
  d=$(mktemp -d /tmp/mrb-XXXXXX) || _mrb_norun "mktemp failed"
  mkdir -p "$d/repo" "$d/home" "$d/tmp" || _mrb_norun "cannot lay out $d"
  git -C "$repo" archive --format=tar "$full" | tar -x -C "$d/repo" \
    || _mrb_norun "could not snapshot $sha7"
  ( cd "$d/repo" && git init -q && git add -A \
      && git -c user.email=probe@harness -c user.name=probe commit -q --allow-empty -m snapshot ) >/dev/null 2>&1 \
    || _mrb_norun "could not git-init the snapshot of $sha7"
  printf '%s\n' "$suites" > "$d/list" || _mrb_norun "cannot write $d/list"
  # shellcheck disable=SC2016
  loop='cd "$1" || exit 125
to=$2; sha7=$3
while IFS= read -r s; do
  timeout -k 10 "$to" bash "$s" </dev/null >/dev/null 2>&1; r=$?
  if [ "$r" -eq 124 ]; then echo "mrb-probe: $sha7 $s rc=$r timeout after ${to}s" >&2
  else echo "mrb-probe: $sha7 $s rc=$r" >&2; fi
  [ "$r" -eq 0 ] || exit 1
done < "$4"
exit 0'
  if [ "${MRB_RUNNER:-}" = local ]; then
    env -i PATH="$PATH" HOME="$d/home" TMPDIR="$d/tmp" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
      bash -c "$loop" _ "$d/repo" "$to" "$sha7" "$d/list"
  else
    command -v setpriv >/dev/null 2>&1 || _mrb_norun "setpriv is not installed"
    uid=$(id -u nobody 2>/dev/null) && gid=$(id -g nobody 2>/dev/null) \
      || _mrb_norun "there is no 'nobody' user"
    # The probe with the run's own flags (#1541 review C1): a caller that
    # cannot switch would otherwise score its own 127 as a red suite.
    setpriv --reuid="$uid" --regid="$gid" --clear-groups true >/dev/null 2>&1 \
      || _mrb_norun "setpriv cannot switch to nobody here (not root, or no CAP_SETUID/SETGID)"
    chmod 711 "$d" && chown -R "$uid:$gid" "$d" \
      || _mrb_norun "could not hand the snapshot to nobody"
    setpriv --reuid="$uid" --regid="$gid" --clear-groups \
      env -i PATH="$PATH" HOME="$d/home" TMPDIR="$d/tmp" LANG=C.UTF-8 LC_ALL=C.UTF-8 \
      bash -c "$loop" _ "$d/repo" "$to" "$sha7" "$d/list"
  fi
  case $? in 0) echo green ;; 1) echo red ;; *) echo "mrb-probe: the runner could not start at $sha7" >&2; echo norun ;; esac
  exit 0
)

# mrb_bisect <probe-fn> <budget> <cand-sha...>
#   <probe-fn> is called as `<probe-fn> <sha>` and prints red|green|norun.
#   <budget> is the most probe calls to spend. <cand-sha...> are main's
#   first-parent merges after the last green, oldest first; the last one is
#   the red tip. The driver has already proven the anchor before the list
#   green and the tip red, so neither is probed here and neither counts
#   against the budget.
#   Binary search on 1-based indices: lo (0 = the anchor) is the highest index
#   proven green, hi (starts at the tip) the lowest proven red, and hi only
#   moves down to a probed red. The answer is therefore a red whose
#   predecessor is proven green, the earliest of the reds this search probed.
#   On a history that goes red, green, red again it is that first red when
#   the search lands on it; a red run the search never probes cannot be seen.
#   stdout: exactly one line, one of
#     found <sha> <steps>          <sha> is the first red merge (hi == lo+1)
#     bounded <lo> <hi> <steps>    budget ran out, the culprit is in (lo, hi];
#                                  <lo> is `-` when it is still the anchor
#     aborted <sha> <steps>        a probe answered anything but red or green
#                                  at <sha>; `aborted - 0` when the budget is
#                                  not a non-negative integer or there are no
#                                  candidates
#   rc:     0 whenever that line was printed.
mrb_bisect() {
  local probe=${1:-} budget=${2:-} lo=0 hi steps=0 m r
  [ "$#" -ge 3 ] && [ -n "$probe" ] || { echo "aborted - 0"; return 0; }
  case "$budget" in ''|*[!0-9]*) echo "aborted - 0"; return 0 ;; esac
  budget=$((10#$budget))
  shift 2
  local c=("" "$@")
  hi=$#
  while [ "$hi" -gt $((lo + 1)) ]; do
    if [ "$steps" -ge "$budget" ]; then
      if [ "$lo" -eq 0 ]; then m=-; else m=${c[lo]}; fi
      echo "bounded $m ${c[hi]} $steps"
      return 0
    fi
    m=$(( (lo + hi) / 2 ))
    r=$("$probe" "${c[m]}") || true
    steps=$((steps + 1))
    case "$r" in
      red) hi=$m ;;
      green) lo=$m ;;
      *) echo "aborted ${c[m]} $steps"; return 0 ;;
    esac
  done
  echo "found ${c[hi]} $steps"
  return 0
}
