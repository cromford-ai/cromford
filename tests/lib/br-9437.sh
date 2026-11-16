# tests/lib/br-9437.sh — shared setup for the BH-9437 resolver ladder suites
# (tests/br-*.bh-9437-test.sh). Sourced, never executed. Not a suite.
#
# bl9_extract <repo> <T> <fn>... — lift each named br_* function out of the
#   resolver corpus (tests/lib/br-corpus.sh: the driver, then bin/lib/br/*.sh)
#   into <T>/fns.sh. rc 1 when one is not found.
# bl9_tripwire <T> — <T>/fakebin holds gh, curl and agent-call.sh that only
#   log to <T>/vendor.txt and fail. A suite puts it first on PATH and ends with
#   bl9_vendor_calls = 0 (BH-7563: no test calls GitHub or a model).
# shellcheck shell=bash

bl9_extract() {
  local dir="$1" t="$2" fn
  shift 2
  # shellcheck source=tests/lib/br-corpus.sh
  . "$dir/tests/lib/br-corpus.sh" || return 1
  br_corpus "$dir" "$t/br-corpus.sh" || return 1
  : > "$t/fns.sh"
  for fn in "$@"; do
    # index(), not a regex: `^br_record()` would match br_record_index() first.
    awk -v f="$fn() " 'index($0, f) == 1 {p=1} p{print} p&&/^}$/{exit}' "$t/br-corpus.sh" >> "$t/fns.sh"
    grep -q "^$fn() " "$t/fns.sh" || { echo "bl9_extract: $fn not found in the resolver corpus"; return 1; }
  done
}

bl9_tripwire() {
  local t="$1" b
  mkdir -p "$t/fakebin" || return 1
  for b in gh curl agent-call.sh; do
    printf '#!/bin/bash\nprintf "%s %%s\\n" "$*" >> "%s/vendor.txt"\nexit 99\n' "$b" "$t" > "$t/fakebin/$b"
    chmod +x "$t/fakebin/$b"
  done
  : > "$t/vendor.txt"
}

bl9_vendor_calls() { cat "$1/vendor.txt" 2>/dev/null | grep -c .; }

# bl9_fn_body <T> <fn> — the body of one extracted function, for structural checks.
bl9_fn_body() { awk -v f="$2() " 'index($0, f) == 1 {p=1} p{print} p&&/^}$/{exit}' "$1/br-corpus.sh"; }
