# shellcheck shell=bash
# tests/lib/jobs-schema.sh — SOURCED by shell suites, never executed.
#
# jobs_schema_render [<root>] — compose <root>/worker/jobs/schema.sql from
# <root>/worker/jobs/schema.d/ with this repo's bin/schema-build.sh, so a suite
# that reads the file reads the fragments (BH-6005). <root> defaults to the repo
# this file is in.
#
#   * no schema.d/: rc 0 when schema.sql exists, else a FAIL line and rc 1.
#   * equal bytes: no write, rc 0.
#   * different bytes: the composition is moved next to schema.sql and renamed
#     over it, rc 0.
#   * a read-only worker/jobs (bin/test-impact-gate.sh runs suites as nobody in
#     a root-owned snapshot): rc 0 when the bytes are equal, else a FAIL line
#     and rc 1.
#   * schema-build.sh refuses: a FAIL line with its first 3 lines of output, rc 1.
# The composition is built in a temp file under ${TMPDIR:-/tmp}, never inside
# the tree: a test may only delete what it made, and bin/test-trace-safety.sh
# counts an rm under the repo as a hit (merge-queue batch #6358). The only
# write into the tree is a rename; nothing there is ever removed. Every failure
# path removes its temp file and leaves schema.sql as it was.
#
# Use it on the line after the suite's scratch.sh source:
#   . "$(dirname "$0")/lib/jobs-schema.sh" && jobs_schema_render || exit 1
jobs_schema_render() {
  local repo root out dir tmp msg
  repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd) || return 1
  root=${1:-$repo}
  dir=$root/worker/jobs
  out=$dir/schema.sql
  if [ ! -d "$dir/schema.d" ]; then
    [ -f "$out" ] && return 0
    echo "FAIL: jobs_schema_render: no schema.d and no schema.sql under $root"
    return 1
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/jobs-schema.XXXXXX") \
    || { echo "FAIL: jobs_schema_render: no temp file under ${TMPDIR:-/tmp}"; return 1; }
  if ! msg=$("$repo/bin/schema-build.sh" --root "$root" --worker jobs --to "$tmp" 2>&1); then
    echo "FAIL: jobs_schema_render: bin/schema-build.sh failed: $(printf '%s\n' "$msg" | head -n 3)"
    rm -f "$tmp"
    return 1
  fi
  if [ -f "$out" ] && cmp -s "$tmp" "$out"; then
    rm -f "$tmp"
    return 0
  fi
  if [ ! -w "$dir" ]; then
    if [ -f "$out" ]; then echo "FAIL: jobs_schema_render: $out differs from schema.d and $dir is not writable"
    else echo "FAIL: jobs_schema_render: $dir is not writable and holds no schema.sql"; fi
    rm -f "$tmp"
    return 1
  fi
  chmod 644 "$tmp"
  # Two renames: the first may cross filesystems (a copy), the second is the
  # atomic one, inside worker/jobs, so a reader never sees half a file.
  mv -f "$tmp" "$dir/.schema.sql.$$" && mv -f "$dir/.schema.sql.$$" "$out" \
    || { echo "FAIL: jobs_schema_render: cannot move the composition to $out"; rm -f "$tmp"; return 1; }
}
