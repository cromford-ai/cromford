#!/bin/bash
# bin/context-budgets-build.sh — catalog/context-budgets.json is COMPOSED from
# catalog/context-budgets.d/ (BH-6487, the last part of BH-4987 item 4).
#
#   context-budgets-build.sh [--repo <path>]                       compose (default)
#   context-budgets-build.sh --compose [--repo <path>] [--to <p>]  compose to
#                                     catalog/context-budgets.json, or <p>
#   context-budgets-build.sh --check [--repo <path>]               the fragments
#                                     are valid, the composition reproduces,
#                                     and catalog/context-budgets.json is NOT
#                                     tracked in git
#
# WHY. Every new LLM lane appended one object to the manifest's `lanes` array.
# Two builds that each added a lane both edited the last element's closing
# `    }` line (its comma) and both inserted before the same `  ],`: a
# guaranteed conflict on a hunk no ticket is about. The sources are now:
#   catalog/context-budgets.d/_head.json        the top-level keys BEFORE `lanes`
#   catalog/context-budgets.d/_tail.json        the top-level keys AFTER `lanes`
#   catalog/context-budgets.d/NNNN-<lane>.json  a JSON array of lane objects; the
#                                               first line is `[`, the last `]`
# 0000-base.json holds the 43 lanes the manifest had before 5561-staff.json. A
# NEW lane is a NEW file, NNNN = its ticket number. The composition is
# _head.json minus its closing `}`, then `"lanes": [`, then each fragment's
# lines minus its `[` and `]`, joined with `,`, in LC_ALL=C file-name order,
# then `],`, then _tail.json minus its opening `{`. At the split commit it is
# the old file byte for byte.
#
# REFUSED, rc 2 (nothing is written, the old composed file stays):
#   * _head.json or _tail.json missing, not a JSON object, carrying a `lanes`
#     key, or not closed (head) / opened and closed (tail) by a bare brace line
#   * _head.json and _tail.json sharing a key (jq would keep the last silently)
#   * any other file name than _head.json, _tail.json, NNNN-<lane>.json
#   * a fragment that is not a non-empty array of objects with a string `lane`,
#     or does not open with a line `[` and close with a line `]`
#   * no fragment at all; a composition that does not parse; a lane twice
#
# LEGACY: with no catalog/context-budgets.d/ the committed file is the source
# (scratch repos in older suites); --compose is then rc 0 when it is readable
# and rc 2 when it is missing.
#
# The composed file is git-ignored. `--compose` writes only when the bytes
# differ, by a mode-644 temp file beside the target and a `mv`, so a reader
# sees the old or the new file, never half of one, and an unchanged run writes
# nothing. `--check` composes into $TMPDIR and writes nothing in the repo.
#
# Exit: 0 ok | 1 --check failed (tracked composed file, or not reproducible) |
# 2 refused, or usage.
set -uo pipefail

SELF=context-budgets-build
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
REL=catalog/context-budgets.json
MANIFEST="$REPO/$REL"
FRAGS="$REPO/catalog/context-budgets.d"
D=catalog/context-budgets.d

die2() { echo "$SELF: $1" >&2; exit 2; }
command -v jq >/dev/null 2>&1 || die2 "jq is required"

# _cb_line head|tail <file> — the first or last line, with a CR and trailing
# white space removed: `] ` and CRLF line ends are accepted (plan BH-6487,
# System invariants (c)). The composition drops these lines, so they never
# reach the output.
_cb_line() { "$1" -n 1 "$2" | tr -d '\r' | sed 's/[[:space:]]*$//'; }

# compose_manifest <out> — the fragments composed into <out>, a temp file the
# caller owns. rc 0 = composed and valid; rc 2 = refused, reason on stderr.
compose_manifest() {
  local out="$1" f name sep="" dups shared
  local head="$FRAGS/_head.json" tail="$FRAGS/_tail.json"
  [ -r "$head" ] || { echo "$SELF: $D/_head.json is missing" >&2; return 2; }
  [ -r "$tail" ] || { echo "$SELF: $D/_tail.json is missing" >&2; return 2; }
  for f in _head.json _tail.json; do
    jq -e 'type == "object" and (has("lanes") | not)' "$FRAGS/$f" >/dev/null 2>&1 \
      || { echo "$SELF: $D/$f must be a JSON object with no \"lanes\" key" >&2; return 2; }
  done
  [ "$(_cb_line tail "$head")" = "}" ] \
    || { echo "$SELF: $D/_head.json must end with a line that is only }" >&2; return 2; }
  [ "$(_cb_line head "$tail")" = "{" ] && [ "$(_cb_line tail "$tail")" = "}" ] \
    || { echo "$SELF: $D/_tail.json must open with a line that is only { and end with a line that is only }" >&2; return 2; }
  shared=$(jq -rn --slurpfile h "$head" --slurpfile t "$tail" '($h[0] | keys) - (($h[0] | keys) - ($t[0] | keys)) | .[]')
  [ -z "$shared" ] || { echo "$SELF: $D/_head.json and _tail.json both carry the key(s): $(printf '%s' "$shared" | tr '\n' ' ')" >&2; return 2; }
  local frags=()
  while IFS= read -r name; do
    case "$name" in _head.json|_tail.json) continue ;; esac
    if ! printf '%s\n' "$name" | grep -qE '^[0-9]{4}-[a-z0-9][a-z0-9._-]*\.json$'; then
      echo "$SELF: $D/$name is not a fragment name (NNNN-<lane>.json, lower case) — rename it or move it out" >&2
      return 2
    fi
    frags+=("$name")
  done < <(cd "$FRAGS" && LC_ALL=C ls -A | LC_ALL=C sort)
  [ "${#frags[@]}" -gt 0 ] || { echo "$SELF: $D/ holds no NNNN-<lane>.json fragment" >&2; return 2; }
  for name in "${frags[@]}"; do
    f="$FRAGS/$name"
    jq -e 'type == "array" and length > 0 and all(.[]; type == "object" and (.lane | type) == "string")' "$f" >/dev/null 2>&1 \
      || { echo "$SELF: $D/$name must be a non-empty JSON array of lane objects, each with a string \"lane\"" >&2; return 2; }
    [ "$(_cb_line head "$f")" = "[" ] && [ "$(_cb_line tail "$f")" = "]" ] && [ "$(wc -l < "$f")" -ge 2 ] \
      || { echo "$SELF: $D/$name must open with a line that is only [ and close with a line that is only ]" >&2; return 2; }
  done
  {
    printf '%s,\n  "lanes": [\n' "$(sed '$d' "$head")"
    for name in "${frags[@]}"; do
      printf '%b%s' "$sep" "$(sed '1d;$d' "$FRAGS/$name")"
      sep=',\n'
    done
    printf '\n  ],\n'
    sed '1d' "$tail"
  } > "$out" || { echo "$SELF: could not write the composition" >&2; return 2; }
  jq -e '.lanes | type == "array"' "$out" >/dev/null 2>&1 \
    || { echo "$SELF: the fragments in $D/ do not compose to JSON with a .lanes array" >&2; return 2; }
  dups=$(jq -r '.lanes[].lane' "$out" | LC_ALL=C sort | uniq -d)
  [ -z "$dups" ] || { echo "$SELF: $D/ carries a lane twice: $(printf '%s' "$dups" | tr '\n' ' ')" >&2; return 2; }
  return 0
}

if [ ! -d "$FRAGS" ]; then
  # LEGACY: no fragments, the committed manifest is the source.
  [ -r "$MANIFEST" ] || die2 "$REL is missing or unreadable ($MANIFEST), and there is no $D/ to compose it from"
  if [ -n "$TO" ]; then
    cmp -s "$MANIFEST" "$TO" 2>/dev/null || { cat "$MANIFEST" > "$TO" || die2 "could not write $TO"; }
  fi
  exit 0
fi

CTMP="" CTMP2="" BESIDE=""
cleanup() { rm -f ${CTMP:+"$CTMP"} ${CTMP2:+"$CTMP2"} ${BESIDE:+"$BESIDE"}; }
trap cleanup EXIT
CTMP=$(mktemp "${TMPDIR:-/tmp}/.context-budgets.XXXXXX") || die2 "mktemp failed"
compose_manifest "$CTMP" || exit 2

if [ "$CHECK" = 1 ]; then
  BAD=0
  # A TRACKED composed file is red whether or not its bytes match: a committed
  # composition is the shared last line every new lane edits again.
  if command -v git >/dev/null 2>&1 && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 \
     && [ -n "$(git -C "$REPO" ls-files -- "$REL" 2>/dev/null)" ]; then
    echo "$SELF: $REL is TRACKED in git. It is COMPOSED from $D/ and must not be committed (BH-6487):" >&2
    echo "$SELF:   move the lane into a fragment: a new $D/NNNN-<lane>.json (a JSON array, one lane), then" >&2
    echo "$SELF:   git rm --cached $REL" >&2
    BAD=1
  fi
  CTMP2=$(mktemp "${TMPDIR:-/tmp}/.context-budgets.XXXXXX") || die2 "mktemp failed"
  if ! compose_manifest "$CTMP2" 2>/dev/null; then
    echo "$SELF: the second compose of $D/ failed — the manifest cannot be reproduced" >&2
    BAD=1
  elif ! cmp -s "$CTMP" "$CTMP2"; then
    echo "$SELF: two compositions of $D/ produced different bytes — the compose is not deterministic" >&2
    BAD=1
  fi
  [ "$BAD" = 0 ] || exit 1
  echo "$SELF: $(jq '.lanes|length' "$CTMP") lanes from $(find "$FRAGS" -maxdepth 1 -name '[0-9]*.json' | wc -l) fragments; $REL is composed, not committed"
  exit 0
fi

if [ -n "$TO" ]; then
  cmp -s "$CTMP" "$TO" 2>/dev/null || { cat "$CTMP" > "$TO" || die2 "could not write $TO"; }
  exit 0
fi
cmp -s "$CTMP" "$MANIFEST" 2>/dev/null && exit 0
BESIDE=$(mktemp "$REPO/catalog/.context-budgets.json.XXXXXX") || die2 "mktemp beside the manifest failed"
# mktemp makes the file 0600 and mv keeps it: open it to every reader, as the
# tracked file was, so a nobody-run suite can still read a root compose.
cat "$CTMP" > "$BESIDE" && chmod 644 "$BESIDE" && mv "$BESIDE" "$MANIFEST" || die2 "could not write $MANIFEST"
BESIDE=""
echo "$SELF: composed $REL ($(jq '.lanes|length' "$MANIFEST") lanes)"
