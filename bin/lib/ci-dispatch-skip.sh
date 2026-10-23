#!/bin/bash
# bin/lib/ci-dispatch-skip.sh — BH-8049: do not dispatch a PR's CI workflow on a
# head that a pull_request or merge-queue run of that workflow already covers.
# Sourced by bin/lib/mc-stuck-timers.sh and bin/lib/mc/block-ci.sh. Functions
# only: no side effect and no output at source time.
#
# WHY. project-6's ci.yml declares `workflow_dispatch:` with no inputs, so a
# dispatch is always the full 42-minute lane. Two conductor lanes dispatch a
# PR's CI on its head branch (mst_ci_nostart, mc_block_ci_step), and neither
# looked for a green or running PR run of the same workflow first: about 42
# duplicate full runs a day (BH-8049).
#
# cds_check <owner/repo> <head sha> <workflow file> [runs-json]
#   Reads the head's runs (one GET of actions/runs?head_sha=, unless the caller
#   hands the JSON it already read). It looks only at runs whose head_sha is
#   exactly <head>, whose event is pull_request or merge_group, and whose path
#   ends with /<workflow file> (an @<ref> suffix is ignored).
#   rc 0   skip. One of them is completed+success (status word `green`) or not
#          completed yet (status word = its status: queued, in_progress, ...).
#          A green run is named first, else the newest unfinished one. Prints
#          `ci-dispatch: skip <sha12>: <workflow> run <id> is <status>`.
#   rc 1   dispatch. No such run, or every one ended another way (failure,
#          cancelled, timed_out, skipped, ...). Prints nothing. A head GitHub
#          never ran (DIRTY) has no run, so it still gets its dispatch.
#   rc 75  unreadable: the read failed or the JSON did not parse. Prints
#          `ci-dispatch: runs unreadable for <sha12>; dispatching as before`.
#          The caller dispatches, as it did before this check existed.
cds_check() {
  local slug="${1:-}" head="${2:-}" wf="${3:-}" runs="${4-}" t rc=0 ans
  if [ $# -lt 4 ]; then
    t=$(mktemp "${TMPDIR:-/tmp}/cds.XXXXXX") || t=""
    if [ -n "$t" ]; then
      gh_rest GET "repos/$slug/actions/runs?head_sha=$head&per_page=100" > "$t" 2>/dev/null || rc=$?
      runs=$(cat "$t" 2>/dev/null); rm -f "$t"
    else
      rc=75
    fi
  fi
  [ "$rc" != 0 ] || [ -n "$runs" ] || rc=75
  if [ "$rc" = 0 ]; then
    ans=$(jq -r --arg h "$head" --arg w "/$wf" '
      if type != "object" then error("not an object") else . end
      | [(.workflow_runs // [])[]
         | select(.head_sha == $h and (.event == "pull_request" or .event == "merge_group")
                  and ((.path // "") | sub("@.*$"; "") | endswith($w)))] as $r
      | ([$r[] | select(.status == "completed" and .conclusion == "success")] | max_by(.id)) as $g
      | ([$r[] | select(.status != "completed")] | max_by(.id)) as $p
      | if $g != null then "\($g.id) green"
        elif $p != null then "\($p.id) \($p.status)"
        else "" end' <<<"$runs" 2>/dev/null) || rc=75
  fi
  if [ "$rc" != 0 ]; then
    printf 'ci-dispatch: runs unreadable for %s; dispatching as before\n' "${head:0:12}"
    return 75
  fi
  [ -n "$ans" ] || return 1
  printf 'ci-dispatch: skip %s: %s run %s is %s\n' "${head:0:12}" "$wf" "${ans%% *}" "${ans#* }"
  return 0
}
