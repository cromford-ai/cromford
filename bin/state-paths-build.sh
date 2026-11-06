#!/bin/bash
# bin/state-paths-build.sh — catalog/state-paths.json is COMPOSED from
# catalog/state-paths.d/ (BH-8986).
#
#   state-paths-build.sh [--repo <path>]                       compose (default)
#   state-paths-build.sh --compose [--repo <path>] [--to <p>]  compose to
#                                     catalog/state-paths.json, or <p>
#   state-paths-build.sh --check [--repo <path>]               the fragments
#                                     are valid, the composition reproduces,
#                                     and catalog/state-paths.json is NOT
#                                     tracked in git
#
# WHY. Every S1 fix of tests/no-state-files.bh-4159-test.sh appended one row to
# the catalog's `paths` array. Two builds that each added a row both edited the
# last row's line (its comma) and both inserted before the same `  ]`: a
# guaranteed conflict on a hunk no ticket is about (#8931). The sources are now:
#   catalog/state-paths.d/_head.json         the top-level keys BEFORE `paths`
#   catalog/state-paths.d/NNNN-<name>.json   a JSON array of row objects; the
#                                            first line is `[`, the last `]`
# 0000-base.json holds the rows the catalog had at the split. A NEW row is a
# NEW file, NNNN = its ticket number (4 or 5 digits). The composition is
# _head.json minus its closing `}`, then `"paths": [`, then each fragment's
# lines minus its `[` and `]`, joined with `,`, in LC_ALL=C file-name order,
# then `]` and `}`. At the split commit it is the old file byte for byte.
#
# REFUSED, rc 2 (nothing is written, the old composed file stays):
#   * _head.json missing, not a JSON object, carrying a `paths` key, or not
#     closed by a bare `}` line
#   * any other file name than _head.json and NNNN-<name>.json
#   * a fragment that is not a non-empty array of objects with a string `path`,
#     or does not open with a line `[` and close with a line `]`
#   * no fragment at all; a composition that does not parse; a path twice
# The class of a row is checked by bin/state-paths-guard.sh, not here.
#
# LEGACY: with no catalog/state-paths.d/ the committed file is the source
# (fixture repos in older suites); --compose is then rc 0 when it is readable
# and rc 2 when it is missing.
#
# The composed file is git-ignored. `--compose` writes only when the bytes
# differ, by a mode-644 temp file beside the target and a `mv`, so a reader
# sees the old or the new file, never half of one, and an unchanged run writes
# nothing. `--check` composes into $TMPDIR and writes nothing in the repo.
# The readers (bin/state-paths-guard.sh, bin/pool-state-paths-lint.sh,
# bin/state-drain.sh) compose with --to into their own temp file.
#
# Exit: 0 ok | 1 --check failed (tracked composed file, or not reproducible) |
# 2 refused, or usage.
set -uo pipefail

SELF=state-paths-build
CHECK=0
TO=""
REPO=""
while [ $# -gt 0 ]; do
  case "$1" in
    --check)   CHECK=1 ;;
    --compose) : ;;
    --to)      shift; TO="${1:-}"; [ -n "$TO" ] || { echo "$SELF: --to needs a path" >&2; exit 2; } ;;
    --repo)    shift; REPO="${1:-}"; [ -n "$REPO" ] || { echo "$SELF: --repo needs a path" >&2; exit 2; } ;;
    -h|--help) sed -n '2,47p' "$0"; exit 0 ;;
    *) echo "usage: $SELF.sh [--check | --compose [--to <path>]] [--repo <path>]" >&2; exit 2 ;;
  esac
  shift
done
[ -z "$TO" ] || [ "$CHECK" = 0 ] || { echo "$SELF: --to goes with --compose" >&2; exit 2; }
[ -n "$REPO" ] || REPO="$(cd "$(dirname "$0")/.." && pwd)"
REL=catalog/state-paths.json
CATALOG="$REPO/$REL"
FRAGS="$REPO/catalog/state-paths.d"
D=catalog/state-paths.d

die2() { echo "$SELF: $1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die2 "jq is required"

# _sp_line head|tail <file> — the first or last line, with a CR and trailing
# white space removed: `] ` and CRLF line ends are accepted. The composition
# drops these lines, so they never reach the output.
_sp_line() { "$1" -n 1 "$2" | tr -d '\r' | sed 's/[[:space:]]*$//'; }

# compose_catalog <out> — the fragments composed into <out>, a temp file the
# caller owns. rc 0 = composed and valid; rc 2 = refused, reason on stderr.
compose_catalog() {
  local out="$1" f name sep="" dups
  local head="$FRAGS/_head.json"
  [ -r "$head" ] || { echo "$SELF: $D/_head.json is missing" >&2; return 2; }
  jq -e 'type == "object" and (has("paths") | not)' "$head" >/dev/null 2>&1 \
    || { echo "$SELF: $D/_head.json must be a JSON object with no \"paths\" key" >&2; return 2; }
  [ "$(_sp_line tail "$head")" = "}" ] \
    || { echo "$SELF: $D/_head.json must end with a line that is only }" >&2; return 2; }
  local frags=()
  while IFS= read -r name; do
    [ "$name" = _head.json ] && continue
    if ! grep -qE '^[0-9]{4,5}-[a-z0-9][a-z0-9._-]*\.json$' <<<"$name"; then
      echo "$SELF: $D/$name is not a fragment name (NNNN-<name>.json, lower case) — rename it or move it out" >&2
      return 2
    fi
    frags+=("$name")
  done < <(cd "$FRAGS" && LC_ALL=C ls -A | LC_ALL=C sort)
  [ "${#frags[@]}" -gt 0 ] || { echo "$SELF: $D/ holds no NNNN-<name>.json fragment" >&2; return 2; }
  for name in "${frags[@]}"; do
    f="$FRAGS/$name"
    jq -e 'type == "array" and length > 0 and all(.[]; type == "object" and (.path | type) == "string")' "$f" >/dev/null 2>&1 \
      || { echo "$SELF: $D/$name must be a non-empty JSON array of row objects, each with a string \"path\"" >&2; return 2; }
    [ "$(_sp_line head "$f")" = "[" ] && [ "$(_sp_line tail "$f")" = "]" ] && [ "$(wc -l < "$f")" -ge 2 ] \
      || { echo "$SELF: $D/$name must open with a line that is only [ and close with a line that is only ]" >&2; return 2; }
  done
  {
    printf '%s,\n  "paths": [\n' "$(sed '$d' "$head")"
    for name in "${frags[@]}"; do
      printf '%b%s' "$sep" "$(sed '1d;$d' "$FRAGS/$name")"
      sep=',\n'
    done
    printf '\n  ]\n}\n'
  } > "$out" || { echo "$SELF: could not write the composition" >&2; return 2; }
  jq -e '.paths | type == "array"' "$out" >/dev/null 2>&1 \
    || { echo "$SELF: the fragments in $D/ do not compose to JSON with a .paths array" >&2; return 2; }
  dups=$(jq -r '.paths[].path' "$out" | LC_ALL=C sort | uniq -d)
  [ -z "$dups" ] || { echo "$SELF: $D/ carries a path twice: $(printf '%s' "$dups" | tr '\n' ' ')" >&2; return 2; }
  return 0
}

if [ ! -d "$FRAGS" ]; then
  # LEGACY: no fragments, the committed catalog is the source.
  [ -r "$CATALOG" ] || die2 "$REL is missing or unreadable ($CATALOG), and there is no $D/ to compose it from"
  if [ -n "$TO" ]; then
    cmp -s "$CATALOG" "$TO" 2>/dev/null || { cat "$CATALOG" > "$TO" || die2 "could not write $TO"; }
  fi
  exit 0
fi

CTMP="" CTMP2="" BESIDE=""
cleanup() { rm -f ${CTMP:+"$CTMP"} ${CTMP2:+"$CTMP2"} ${BESIDE:+"$BESIDE"}; }
trap cleanup EXIT
CTMP=$(mktemp "${TMPDIR:-/tmp}/.state-paths.XXXXXX") || die2 "mktemp failed"
compose_catalog "$CTMP" || exit 2

if [ "$CHECK" = 1 ]; then
  BAD=0
  # A TRACKED composed file is red whether or not its bytes match: a committed
  # composition is the shared last line every new row edits again.
  if command -v git >/dev/null 2>&1 && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
     && [ -n "$(git -C "$REPO" ls-files -- "$REL" 2>/dev/null)" ]; then
    echo "$SELF: $REL is TRACKED in git. It is COMPOSED from $D/ and must not be committed (BH-8986):" >&2
    echo "$SELF:   git rm --cached $REL; a new row is a new $D/NNNN-<name>.json" >&2
    BAD=1
  fi
  CTMP2=$(mktemp "${TMPDIR:-/tmp}/.state-paths.XXXXXX") || die2 "mktemp failed"
  if ! compose_catalog "$CTMP2" 2>/dev/null; then
    echo "$SELF: the second compose of $D/ failed — the catalog cannot be reproduced" >&2
    BAD=1
  elif ! cmp -s "$CTMP" "$CTMP2"; then
    echo "$SELF: two compositions of $D/ produced different bytes — the compose is not deterministic" >&2
    BAD=1
  fi
  [ "$BAD" = 0 ] || exit 1
  echo "$SELF: $(jq '.paths|length' "$CTMP") paths from $(find "$FRAGS" -maxdepth 1 -name '[0-9]*.json' | wc -l) fragments; $REL is composed, not committed"
  exit 0
fi

if [ -n "$TO" ]; then
  cmp -s "$CTMP" "$TO" 2>/dev/null || { cat "$CTMP" > "$TO" || die2 "could not write $TO"; }
  exit 0
fi
cmp -s "$CTMP" "$CATALOG" 2>/dev/null && exit 0
BESIDE=$(mktemp "$REPO/catalog/.state-paths.json.XXXXXX") || die2 "mktemp beside the catalog failed"
# mktemp makes the file 0600 and mv keeps it: open it to every reader, as the
# tracked file was, so a nobody-run suite can still read a root compose.
cat "$CTMP" > "$BESIDE" && chmod 644 "$BESIDE" && mv "$BESIDE" "$CATALOG" || die2 "could not write $CATALOG"
BESIDE=""
echo "$SELF: composed $REL ($(jq '.paths|length' "$CATALOG") paths)"
