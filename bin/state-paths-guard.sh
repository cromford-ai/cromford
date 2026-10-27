#!/bin/bash
# bin/state-paths-guard.sh [<base-ref>] — BH-5005, wave 6 of #4951.
#
# Waves 1-5 of #4951 moved the coordination state under state/ (pool spawns,
# claims, PR owners, build notes, the digest guard, the queues) onto DB rows.
# The old files stay as shadows until they are retired. This check stops a NEW
# script from growing another writer of one of them: a script ADDED by the diff
# (git --diff-filter=A) that writes a state/<path> classified `rows` in
# catalog/state-paths.json fails. `cache` and `box-local` paths pass, and so
# does a path the catalog does not list. An existing writer that is modified,
# or renamed, is not checked.
#
# What counts as a write, on one line that names state/<path> (the next
# character not one of [A-Za-z0-9_.-], so state/pool never matches
# state/pool-stats or state/pool.lock) and is not a `#` or `//` comment:
#   - a stdout redirect > or >> (not 2>, &>, >&2, 2>&1, =>, ->, >=),
#   - a write verb as a word: tee touch mkdir mv cp ln install rm truncate
#     rsync, or sed -i,
#   - a file-write API: open(..., "w"|"a"|"x"...), makedirs, write_text,
#     write_bytes, writeFile*, appendFile*,
#   - a shell assignment (NAME=, local/export/readonly/declare NAME=) whose
#     value names the path. That is how a dir variable written later is caught;
#     it also fires on a variable that is only read, which is the same
#     regression for a new script.
# Paths under bin/, scripts/ and cron/ count, plus any .sh .bash .py .js .mjs
# .cjs file. tests/, test/, docs/, catalog/, guardrails/*/fixtures/ and *.md
# never count. Nor does config/fly-pool.d/ (BH-7542): its fragments are the
# source of bin/fly-pool.sh, an existing writer, so an added fragment is an edit
# of that file and is not checked, the same as a direct edit of it.
#
# Configuration (env):
#   SPG_CATALOG  the catalog (default: catalog/state-paths.json beside bin/).
#   SPG_FILES    a file holding the added-file list, one path per line. Set it
#                and no git call is made.
#   SPG_ROOT     the checkout the files are read from (default '.').
#
# rc 0 = clean (or skipped through the skip-guardrail escape hatch).
# rc 1 = a new script writes a rows path.
# rc 2 = could not check: catalog unreadable or invalid, or git diff failed.
set -uo pipefail
set -f
SELF="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SELF/.." && pwd)"
# shellcheck source=../guardrails/lib/escape-hatch.sh
. "$REPO/guardrails/lib/escape-hatch.sh" 2>/dev/null || true
declare -F guardrail_escape_hatch >/dev/null \
  && guardrail_escape_hatch state-paths-guard && exit 0

BASE="${1:-origin/main}"
ROOT="${SPG_ROOT:-.}"
CATALOG="${SPG_CATALOG:-$REPO/catalog/state-paths.json}"
say() { echo "STATE-PATHS-GUARD: $*"; }

# --- catalog -----------------------------------------------------------------
command -v jq >/dev/null 2>&1 || { say "jq not found, cannot read $CATALOG"; exit 2; }
[ -r "$CATALOG" ] || { say "catalog $CATALOG is missing or unreadable"; exit 2; }
DEFECT=$(jq -r '
  if (.paths | type) != "array" then "no .paths array"
  else
    ( [ .paths[] | select((.path | type) != "string" or (.path | test("^[A-Za-z0-9._-]+$") | not)) ]
      | if length > 0 then "invalid path \(.[0].path | tojson) (empty, or a character outside [A-Za-z0-9._-])" else empty end ),
    ( [ .paths[] | select((.class | IN("rows", "cache", "box-local")) | not) ]
      | if length > 0 then "path \(.[0].path | tojson) has unknown class \(.[0].class | tojson) (want rows, cache or box-local)" else empty end ),
    ( [ .paths[].path ] | group_by(.) | map(select(length > 1) | .[0])
      | if length > 0 then "duplicate path \(.[0] | tojson)" else empty end )
  end' "$CATALOG" 2>/dev/null)
JQ_RC=$?
if [ "$JQ_RC" -ne 0 ]; then say "catalog $CATALOG is not valid JSON"; exit 2; fi
if [ -n "$DEFECT" ]; then say "catalog $CATALOG: $(head -1 <<<"$DEFECT")"; exit 2; fi
ROWS=$(jq -r '.paths[] | select(.class == "rows") | "\(.path)\t\(.authority // "")"' "$CATALOG") \
  || { say "catalog $CATALOG could not be read"; exit 2; }

# --- the added files ---------------------------------------------------------
if [ -n "${SPG_FILES:-}" ]; then
  [ -r "$SPG_FILES" ] || { say "SPG_FILES=$SPG_FILES is not readable"; exit 2; }
  ADDED=$(cat "$SPG_FILES")
else
  ADDED=$(git -C "$ROOT" diff --name-only --diff-filter=A "$BASE"...HEAD 2>/dev/null) || {
    say "could not diff against $BASE"
    exit 2
  }
fi

is_script() {
  case "$1" in
    *.md|tests/*|test/*|*/tests/*|*/test/*|docs/*|catalog/*|guardrails/*/fixtures/*) return 1 ;;
    config/fly-pool.d/*) return 1 ;;
    bin/*|scripts/*|cron/*) return 0 ;;
    *.sh|*.bash|*.py|*.js|*.mjs|*.cjs) return 0 ;;
  esac
  return 1
}

# Write shapes, as bash EREs. The redirect arm's surrounding classes keep
# 2>/dev/null, &>, >&2, 2>&1, =>, ->, >= and >> 's second > from counting.
RE_REDIRECT='(^|[^0-9&>=-])>>?([^&>=]|$)'
RE_VERB='(^|[^A-Za-z0-9_-])(tee|touch|mkdir|mv|cp|ln|install|rm|truncate|rsync)([^A-Za-z0-9_-]|$)'
RE_SED='(^|[^A-Za-z0-9_-])sed[[:space:]]([^|;&]*[[:space:]])?-[A-Za-z]*i'
RE_API='(open\(.*["'"'"'][rb]*[wax]|makedirs|write_text|write_bytes|writeFile|appendFile)'
RE_ASSIGN='^[[:space:]]*((local|export|readonly)[[:space:]]+|declare[[:space:]]+[^[:space:]]*[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*='

CHECKED=0; HITS=""
while IFS= read -r F; do
  [ -n "$F" ] || continue
  is_script "$F" || continue
  if [ ! -f "$ROOT/$F" ]; then say "skipped $F: not on disk under $ROOT"; continue; fi
  CHECKED=$((CHECKED + 1))
  N=0
  while IFS= read -r LINE || [ -n "$LINE" ]; do
    N=$((N + 1))
    LINE=${LINE%$'\r'}
    case "$LINE" in *state/*) ;; *) continue ;; esac
    TRIM=${LINE#"${LINE%%[![:space:]]*}"}
    case "$TRIM" in '#'*|'//'*) continue ;; esac
    if ! { [[ $LINE =~ $RE_REDIRECT ]] || [[ $LINE =~ $RE_VERB ]] || [[ $LINE =~ $RE_SED ]] \
           || [[ $LINE =~ $RE_API ]] || [[ $LINE =~ $RE_ASSIGN ]]; }; then
      continue
    fi
    while IFS=$'\t' read -r P AUTH; do
      [ -n "$P" ] || continue
      RE_PATH="state/${P//./\\.}([^A-Za-z0-9_.-]|\$)"
      if [[ $LINE =~ $RE_PATH ]]; then
        HITS="${HITS}STATE-PATHS-GUARD: $F:$N: writes state/$P (class rows, authority: $AUTH)"$'\n'
      fi
    done <<< "$ROWS"
  done < "$ROOT/$F"
done <<< "$ADDED"

if [ -z "$HITS" ]; then
  say "clean ($CHECKED new scripts checked)"
  exit 0
fi
printf '%s' "$HITS"
cat <<EOF

A new script writes a state/ path whose record is now a DB row (#4951). A file
written next to the row is a second spelling of the same state, and the two
drift. Write the row through bin/jobs-client.sh instead. If the path really is
a local cache or belongs to this box only, change its class in
catalog/state-paths.json in this same PR.

If this genuinely needs the file, take the escape hatch: add the
'skip-guardrail' label AND a 'Guardrail-Justification: <reason>' line in the
PR body. The reason stays in the PR record.
EOF
exit 1
