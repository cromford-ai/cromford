#!/bin/bash
# bin/nightly-strict-ratchets.sh [--list <f>] [--summary <f>] — the nightly
# STRICT ratchet pass (2026-09-28).
#
# The ratchets in catalog/nightly-strict.txt judge only the DIFF in every PR and
# batch (tests/lib/ratchet-delta.sh). That is right for a merge gate: drift that
# main already has can't dequeue an unrelated batch. It is blind to drift that
# arrived without a diff, such as a direct push to main or a batch whose impact
# selection skipped the ratchet. So once a night, on main, each listed suite
# runs in strict mode (`--strict` AND RATCHET_MODE=strict: the whole live tree
# against the committed baseline). .github/workflows/harness-nightly.yml runs
# this, and a red result goes into the nightly ticket.
#
# GATED ON THE TREE, NOT ON A DATE. A listed suite whose text does not carry
# strict mode yet (no `rd_mode` / RATCHET_MODE) is SKIPPED with a notice. It is
# never run in its old absolute shape and never counted red. So this pass does
# nothing until the diff-based ratchet PRs land, and turns on by itself when
# they do.
#
# ONE FAILURE IS A NOTE, NOT A PAGE. switch-ratchet's strict R2 goes red when
# the tree sits BELOW its effective floor ("tree at 37, effective floor 38 …
# add tests/switch-ratchet.d/<KEY>.drop"). A legitimate conversion does exactly
# that until someone adds the .drop file. When that line is a suite's ONLY
# failure, it is printed as a NOTE (a ::notice:: in CI) and the pass stays
# green. Any other FAIL line, including R2 "over effective floor", is red.
#
# rc 0 green (skips and notes included), 1 when a strict suite failed or a
# listed suite does not exist, 2 on usage. --summary gets the markdown the
# ticket carries: one section per red suite with its FAIL lines, and nothing
# when green. NSR_ROOT is the tree to run in (tests).
set -uo pipefail
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="${NSR_ROOT:-$(cd "$SELF_DIR/.." && pwd)}"
LIST="$ROOT/catalog/nightly-strict.txt"; SUMMARY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --list)    [ $# -ge 2 ] || { echo "nightly-strict: --list needs a path" >&2; exit 2; }; LIST="$2"; shift ;;
    --summary) [ $# -ge 2 ] || { echo "nightly-strict: --summary needs a path" >&2; exit 2; }; SUMMARY="$2"; shift ;;
    -h|--help) sed -n '2,31p' "$0"; exit 0 ;;
    *) echo "nightly-strict: unknown argument $1" >&2; exit 2 ;;
  esac
  shift
done
[ -r "$LIST" ] || { echo "nightly-strict: cannot read $LIST" >&2; exit 2; }
[ -z "$SUMMARY" ] || : > "$SUMMARY"
NOTE_RE='^FAIL: R2 tree at [0-9]+, effective floor [0-9]+ .*add tests/switch-ratchet\.d/'
RED=0
while read -r s _; do
  case "$s" in ''|'#'*) continue ;; esac
  if [ ! -f "$ROOT/$s" ]; then
    echo "RED  $s: listed in $(basename "$LIST") but no such suite"; RED=1
    [ -z "$SUMMARY" ] || printf '### `%s`\nlisted for the strict pass, but no such suite exists\n\n' "$s" >> "$SUMMARY"
    continue
  fi
  if ! grep -qE 'rd_mode|RATCHET_MODE' "$ROOT/$s"; then
    echo "SKIP $s: this tree's copy has no strict mode yet (it lands with the diff-based ratchet PRs)"
    continue
  fi
  out=$(cd "$ROOT" && RATCHET_MODE=strict bash "$s" --strict </dev/null 2>&1); rc=$?
  fails=$(grep '^FAIL' <<<"$out")
  real=$(grep -vE "$NOTE_RE" <<<"$fails" | grep . || true)
  if [ "$rc" = 0 ]; then
    echo "OK   $s (strict)"
  elif [ -n "$fails" ] && [ -z "$real" ]; then
    echo "NOTE $s: $(head -1 <<<"$fails" | sed 's/^FAIL: //') — add the .drop file; not a page"
    [ -z "${GITHUB_ACTIONS:-}" ] || echo "::notice::nightly strict: $s is below its floor — add tests/switch-ratchet.d/<KEY>.drop"
  else
    RED=1
    echo "RED  $s (strict, rc $rc)"
    printf '%s\n' "${real:-$(tail -5 <<<"$out")}" | sed 's/^/     /'
    if [ -n "$SUMMARY" ]; then
      { printf '### `%s` (strict mode, rc %s)\n```\n' "$s" "$rc"
        head -20 <<<"${real:-$(tail -5 <<<"$out")}"
        printf '```\n\n'; } >> "$SUMMARY"
    fi
  fi
done < "$LIST"
exit "$RED"
