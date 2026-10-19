#!/bin/bash
# tests/gitleaksignore-baseline-test.sh — the repo-root .gitleaksignore parses.
#
# bin/staff/watchman-collect.sh runs gitleaks with --gitleaks-ignore-path on the
# repo, so the root .gitleaksignore is the allow-list for the watchman's
# first-scan baseline (BH-7531, 221 fixture and doc locations). gitleaks skips a
# line it cannot read without a word, so a malformed line is a finding that
# comes back on the next re-scan. This suite proves every line is a comment or a
# full gitleaks fingerprint (commit:file:rule:line, 40-hex commit), that no line
# repeats, and that the baseline holds 221 fingerprints.
#
# check_file is the one parser. The negatives run it over scratch files first,
# so the real-file arms run through code that is proven to refuse bad lines.
#
# Run from anywhere: tests/gitleaksignore-baseline-test.sh   (exit 0 = all pass)
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

FP_RE='^[0-9a-f]{40}:[^:]+:[^:]+:[0-9]+$'

# check_file <path> — rc 0 when every line is a `#` comment or a fingerprint and
# no line repeats. Prints one reason line per refused line.
check_file() {
  local f=$1 rc=0 n=0 line dups
  [ -s "$f" ] || { echo "empty or missing: $f"; return 1; }
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n+1))
    case "$line" in \#*) continue ;; esac
    if ! [[ $line =~ $FP_RE ]]; then
      echo "line $n is not a comment or a fingerprint: $line"; rc=1
    fi
  done < "$f"
  dups=$(sort "$f" | uniq -d)
  [ -z "$dups" ] || { echo "duplicate line(s): $dups"; rc=1; }
  return "$rc"
}

C40=0123456789abcdef0123456789abcdef01234567
C39=${C40%?}

# --- negatives and the accept case: check_file on scratch files -------------
neg() { # neg <label> <content>
  printf '%s\n' "# header" "$C40:a/b.sh:rule-id:1" "$2" > "$T/case"
  if check_file "$T/case" >/dev/null; then bad "check_file accepted $1"; else ok; fi
}
neg "a 39-hex commit"          "$C39:a/b.sh:rule-id:2"
neg "a non-numeric line field" "$C40:a/b.sh:rule-id:x"
neg "a duplicated fingerprint" "$C40:a/b.sh:rule-id:1"
neg "a blank line"             ""
neg "an uppercase hex commit"  "$(printf '%s' "$C40" | tr 'a-f' 'A-F'):a/b.sh:rule-id:3"
neg "a short-sha line"         "abc1234:file:rule:1"

printf '%s\n' "# header" "$C40:a/b.sh:rule-id:1" "$C40:tests/fixtures/a.b/c.sh:rule-id:1" > "$T/good"
if out=$(check_file "$T/good"); then ok; else bad "check_file refused a valid file: $out"; fi

# --- the real file ------------------------------------------------------------
F="$DIR/.gitleaksignore"
if [ -s "$F" ]; then ok; else bad "A1 $F is missing or empty"; fi
if out=$(check_file "$F"); then ok; else bad "A2/A3 $F does not parse: $out"; fi
n=$(grep -cv '^#' "$F" 2>/dev/null)
if [ "${n:-0}" = 221 ]; then ok; else bad "A4 $F holds ${n:-0} fingerprint lines, expected 221"; fi
if grep -q 'BH-7531' <<<"$(grep '^#' "$F" 2>/dev/null)"; then ok; else bad "A5 the $F header does not name BH-7531"; fi

echo "gitleaksignore-baseline: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
