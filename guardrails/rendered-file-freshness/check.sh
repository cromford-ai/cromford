#!/bin/bash
# guardrails/rendered-file-freshness/check.sh [<base-ref>]
#
# A file that is RENDERED from fragments is edited through its fragments, never
# by hand. A hand edit survives until the next render and then vanishes without
# a trace — the repo has two spellings of the same thing and the one in the diff
# is the one that loses. So a PR that changes a rendered registry file and none
# of that file's inputs fails here, with the fragment dir and the render command
# in the message.
#
# The rendered paths, their inputs and their render commands are ONE spelling,
# owned by bin/lib/render-fragments.sh's rf_registry(). The default map below is
# that list, and tests/guardrails-test.sh extracts it by its markers and diffs it
# against rf_registry so the two cannot drift.
#
# Configuration (env, so a repo tunes it without forking the script):
#   RFF_MAP       rows '<rendered glob>|<input paths>|<renderer command>',
#                 newline separated. Blank lines and # comments are skipped.
#   RFF_MAP_FILE  a file of the same rows — a target repo's own registry. It
#                 wins over RFF_MAP, which wins over the baked default.
#   RFF_FILES     a file holding the changed-file list, one path per line. Set
#                 it and no git call is made — that is how the check is testable
#                 on fixtures, and how a CI that already has the list avoids a
#                 second diff.
#   RFF_ROOT      the checkout adoption is judged in (default '.').
#
# rc 0 = fresh / not adopted / no rendered file / not checked. rc 1 = a rendered
# file changed without its inputs.
set -uo pipefail
# No pathname expansion: the map's input tokens are split on whitespace and a
# token must never be expanded against the working directory. `case` patterns
# are unaffected, so the rendered globs still match.
set -f
SELF="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/escape-hatch.sh
. "$SELF/../lib/escape-hatch.sh" 2>/dev/null || true
declare -F guardrail_escape_hatch >/dev/null \
  && guardrail_escape_hatch rendered-file-freshness && exit 0

BASE="${1:-origin/main}"
ROOT="${RFF_ROOT:-.}"

# >>> rff default map
RFF_DEFAULT_MAP=$(cat <<'EOF'
cron/*.cron|cron/lanes/ cron/boxes/ fleet.conf bin/lib/cron-lines.sh|bin/render-crontab.sh --from-fragments --all --write
env-templates/global.env.example|env-templates/lanes/|bin/render-env-example.sh --write
rules/CLAUDE.md|rules/topics/|bin/render-rules.sh --write
docs/PR-OWNERSHIP.md|docs/PR-OWNERSHIP.d/|bin/render-doc-sections.sh --write
EOF
)
# <<< rff default map

if [ -n "${RFF_MAP_FILE:-}" ]; then
  # -r, not -f: a process substitution (RFF_MAP_FILE=<(...)) is a readable fd,
  # not a regular file, and refusing it would make the documented one-liner lie.
  [ -r "$RFF_MAP_FILE" ] || { echo "GUARDRAIL rendered-file-freshness: RFF_MAP_FILE=$RFF_MAP_FILE not readable — not checked."; exit 0; }
  MAP=$(cat "$RFF_MAP_FILE")
elif [ -n "${RFF_MAP:-}" ]; then
  MAP=$RFF_MAP
else
  MAP=$RFF_DEFAULT_MAP
fi

if [ -n "${RFF_FILES:-}" ]; then
  [ -r "$RFF_FILES" ] || { echo "GUARDRAIL rendered-file-freshness: RFF_FILES=$RFF_FILES not readable — not checked."; exit 0; }
  CHANGED=$(cat "$RFF_FILES")
else
  CHANGED=$(git diff --name-only "$BASE"...HEAD 2>/dev/null) || {
    echo "GUARDRAIL rendered-file-freshness: could not diff against $BASE — not checked."
    exit 0
  }
fi

ADOPTED=0; RENDERED_ALL=""; STALE=""; FIXES=""
while IFS= read -r ROW; do
  case "$ROW" in ''|'#'*) continue ;; esac
  IFS='|' read -r GLOB INPUTS CMD <<< "$ROW"
  if [ -z "$GLOB" ] || [ -z "${INPUTS:-}" ] || [ -z "${CMD:-}" ]; then
    echo "GUARDRAIL rendered-file-freshness: malformed row skipped: $ROW"
    continue
  fi
  # Adoption is a fact about the CHECKOUT or the BASE, never about this diff: a
  # row counts as adopted when its first input exists in the checkout OR at the
  # base ref, so a PR that deletes the fragment dir and hand-edits the rendered
  # file cannot report "not adopted" and pass — the exact PR this check exists
  # to stop. -e, and `ls-tree` without -d, because a row's first input may be a
  # file (only via RFF_MAP_FILE) and -d prints tree entries only — a blob path
  # would read as "not adopted". `set --` splits on whitespace, so a leading space in the
  # input field cannot yield an empty FIRST that adopts the row unconditionally.
  # shellcheck disable=SC2086  # word-splitting is the point (set -f is on)
  set -- $INPUTS; FIRST=${1:-}
  if [ -z "$FIRST" ]; then
    echo "GUARDRAIL rendered-file-freshness: malformed row skipped (empty inputs): $ROW"
    continue
  fi
  if [ ! -e "$ROOT/${FIRST%/}" ] \
     && ! git -C "$ROOT" ls-tree "$BASE" -- "${FIRST%/}" 2>/dev/null | grep -q .; then
    echo "GUARDRAIL rendered-file-freshness: row $GLOB not adopted in $ROOT (nor at $BASE) — skipped."
    continue
  fi
  ADOPTED=$((ADOPTED + 1))
  HIT=""; INPUT_HIT=""
  while IFS= read -r F; do
    [ -n "$F" ] || continue
    # The renderer script itself is an input of its row: a rendered file may
    # legitimately change because the renderer changed.
    IN_THIS=""
    for TOK in $INPUTS ${CMD%% *}; do
      case "$TOK" in
        */) case "$F" in "$TOK"*) IN_THIS="yes" ;; esac ;;
        *)  [ "$F" = "$TOK" ] && IN_THIS="yes" ;;
      esac
    done
    # An input is never also a rendered file: 'cron/*.cron' matches
    # cron/lanes/x.cron ('*' crosses '/'), so without this a fragment-only diff
    # counted a fragment as a rendered file in the clean message.
    if [ -n "$IN_THIS" ]; then INPUT_HIT="yes"; continue; fi
    # Rendered side only: on a Mergify batch draft a rendered file only a hatched
    # source PR changed is exempt (BH-9965). A fragment edit always counts.
    declare -F guardrail_is_exempt >/dev/null && guardrail_is_exempt "$F" && continue
    # shellcheck disable=SC2254  # $GLOB is a glob on purpose
    case "$F" in $GLOB) HIT="$HIT$F"$'\n' ;; esac
  done <<< "$CHANGED"
  [ -n "$HIT" ] || continue
  RENDERED_ALL="$RENDERED_ALL$HIT"
  [ -n "$INPUT_HIT" ] && continue
  STALE="$STALE$HIT"
  FIXES="$FIXES    Edit the fragments under $FIRST and re-render with $CMD"$'\n'
done <<< "$MAP"

if [ "$ADOPTED" -eq 0 ]; then
  echo "GUARDRAIL rendered-file-freshness: none of the rendered registries is adopted in $ROOT yet — not adopted, nothing to keep fresh."
  exit 0
fi
if [ -z "$RENDERED_ALL" ]; then
  echo "GUARDRAIL rendered-file-freshness: no rendered registry file in this diff — nothing to keep fresh."
  exit 0
fi
if [ -z "$STALE" ]; then
  N=$(printf '%s' "$RENDERED_ALL" | sort -u | grep -c .)
  echo "GUARDRAIL rendered-file-freshness: $N rendered file(s) changed with their inputs. Clean."
  exit 0
fi

echo "GUARDRAIL rendered-file-freshness: this diff changes rendered file(s) without touching their inputs."
printf '%s' "$STALE" | sort -u | head -20 | sed 's/^/    /'
printf '%s' "$FIXES"
cat <<EOF

A hand edit to a rendered file is reverted by the next render, silently, and
until then the repo holds two spellings of the same thing. Change the fragment,
re-render, and commit both in this PR.

If this genuinely needs no fragment change, take the escape hatch: add the
'skip-guardrail' label AND say why in GUARDRAIL_JUSTIFICATION. The reason stays
in the PR record.
EOF
exit 1
