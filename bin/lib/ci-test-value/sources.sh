#!/bin/bash
# bin/lib/ci-test-value/sources.sh — ctv_fetch_sources <out>: the reads the
# report adds beside the job logs. bin/ci-test-value-report.sh calls it before
# the render, with CTV_REPO and FROM (the window start, YYYY-MM-DD) set.
#
# It writes into <out>/cache/, each file through a temp file and mv:
#   suite-durations.json  GET /api/ci/suite-durations (the CI median per suite)
#   suite-passes.json     GET /api/suite-results/passes?repo=&since=FROM
#   flakes.json           GET /api/metrics/flakes?repo=&since=FROM&limit=2000
#   suites-on-disk.txt    the suite files in git HEAD of this checkout
# GET only, through _jobs_req (bin/jobs-client.sh). These are live aggregates,
# so every run reads them again. A read that fails, or a body of the wrong
# shape, leaves its file ABSENT (an earlier run's copy is removed) and prints
# one `ctv: source <name> unread (<why>)` line on stderr. No stdout.
# It returns 0 on every path: an unread source is named by the renderer, it
# never stops the run.
_CTV_SUITES_ERE='^tests/[^/]+\.sh$|^tests/mc/[^/]+\.sh$|^worker/jobs/test/.*\.test\.js$|^console-ui/.*\.test\.[^/]+$'

# _ctv_source_get <cache> <name> <file> <path> <jq shape>
_ctv_source_get() {
  local f="$1/$3" rc=0
  _jobs_req GET "$4" > "$f.tmp.$$" || rc=$?
  if [ "$rc" = 0 ] && jq -e "$5" "$f.tmp.$$" >/dev/null 2>&1 && mv -f "$f.tmp.$$" "$f"; then return 0; fi
  rm -f "$f.tmp.$$"
  if [ "$rc" = 0 ]; then
    echo "ctv: source $2 unread (bad shape)" >&2
  else
    echo "ctv: source $2 unread (rc $rc, http ${JOBS_HTTP:-none})" >&2
  fi
}

# _ctv_fetch_worker <cache> — runs in a subshell: bin/jobs-client.sh sets shell
# options and exits on a missing module, and neither may reach the driver. It
# removes the three files first, so only a read of this run leaves one.
_ctv_fetch_worker() {
  local c="$1" r
  rm -f "$c/suite-durations.json" "$c/suite-passes.json" "$c/flakes.json"
  if ! command -v _jobs_req >/dev/null 2>&1; then
    # shellcheck source=bin/jobs-client.sh
    . "$_CTV_LIB_DIR/../jobs-client.sh" >/dev/null || return 1
  fi
  _ctv_source_get "$c" suite_durations suite-durations.json /api/ci/suite-durations \
    '(.rows|type) == "array" and all(.rows[]; (.suite|type) == "string" and (.seconds|type) == "number")'
  if [ -z "${FROM:-}" ] || [ -z "${CTV_REPO:-}" ]; then
    echo "ctv: source suite_passes unread (no window start or repo)" >&2
    echo "ctv: source flakes unread (no window start or repo)" >&2
    return 0
  fi
  r=$(jq -rn --arg r "$CTV_REPO" '$r|@uri')
  _ctv_source_get "$c" suite_passes suite-passes.json "/api/suite-results/passes?repo=$r&since=$FROM" \
    '(.suites|type) == "array" and all(.suites[]; (.suite|type) == "string" and (.passes|type) == "number" and (.fails|type) == "number")'
  _ctv_source_get "$c" flakes flakes.json "/api/metrics/flakes?repo=$r&since=$FROM&limit=2000" \
    '(.flakes|type) == "array"'
  return 0
}

ctv_fetch_sources() { # ctv_fetch_sources <out>
  local out="${1:-}" c root f rc=0
  if [ -z "$out" ] || [ ! -d "$out" ] || ! mkdir -p "$out/cache" 2>/dev/null; then
    echo "ctv: source cache unread (no out dir: ${out:-empty})" >&2
    return 0
  fi
  c="$out/cache"
  ( _ctv_fetch_worker "$c" ) || rc=$?
  [ "$rc" = 0 ] || echo "ctv: source suite_durations, suite_passes, flakes unread (bin/jobs-client.sh did not load, rc $rc)" >&2
  f="$c/suites-on-disk.txt"
  rm -f "$f"
  root=$(cd "$_CTV_LIB_DIR/../.." && pwd) || root=
  if [ -n "$root" ] && git -C "$root" ls-tree -r --name-only HEAD > "$f.all.$$" 2>/dev/null; then
    { grep -E "$_CTV_SUITES_ERE" "$f.all.$$" || true; } | LC_ALL=C sort -u > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"
  else
    echo "ctv: source suites_on_disk unread (git ls-tree failed in ${root:-unknown root})" >&2
  fi
  rm -f "$f.all.$$" "$f.tmp.$$"
  return 0
}
