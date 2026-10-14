#!/bin/bash
# bin/model-route-seed-lint.sh [<base-ref>] — a model_routes seed change for a
# role that already exists is inert on live; say so before it merges (BH-1928).
#
# WHY. Since #1917 (BH-1572) every model_routes seed in worker/jobs/schema.sql
# skips a role with ANY hub audit history (model_route_changes), and 47 of the
# 50 live roles have some: an operator PUT them, or removed them. So a PR that
# changes the seed for one of those roles (a new rung, a new model, a dropped
# rung) changes a fresh database and nothing else. The deploy re-applies
# schema.sql, the guard skips the role, and live keeps the old ladder. Nothing
# said so until this lint.
#
# THE RULE. For every role in the BASE seed whose seeded rungs differ at HEAD
# (a model or runner changed, a rung added or removed, the role dropped), the
# same diff must carry ONE of:
#   - the audited PUT that moves live: a changed file under bin/ or scripts/
#     (not tests/) whose code makes a PUT call to /api/model-routes and names
#     the role as a whole token (build.plan does not match build.plan.x); or
#   - the waiver `seed-only: fresh-db`, in the PR body ($PR_BODY) or on an added
#     line of the schema.sql or schema.d/ diff (`-- seed-only: fresh-db`), for a
#     change meant for fresh databases only. Waived roles are printed, never silent.
# A role that is NEW (not in the base seed) passes: it has no hub audit
# history, so its seed lands on live. updated_by / updated_at and comments are
# not changes. CI cannot read live D1, so every role already seeded counts as
# one with history; that is the conservative side.
#
# WHAT IS PARSED. Every statement from `INSERT … INTO model_routes` to the line
# ending `;`, `--` comments stripped, for the three tuple shapes the file uses:
#   ('hub', NULL, '<role>', <pos>, '<model>', '<runner>', …)   8-field VALUES
#   ('<role>', <pos>, '<model>', '<runner>')                    FROM (VALUES …)
#   SELECT 'hub', NULL, '<role>', <pos>, '<model>', '<runner>', …   one bare rung
# Any other table's tuples are outside those statements and never read.
#
# FRAGMENTS (BH-6005). schema.sql is composed from worker/jobs/schema.d/, so a
# PR can carry only a fragment. The lint runs when the diff has schema.sql OR a
# worker/jobs/schema.d/*.sql path. HEAD is the composition of the tree's
# schema.d/ when it exists (bin/schema-build.sh), else the file. BASE is the
# merge-base's schema.sql when it tracks one, else the composition of its
# schema.d/ (schema-build.sh --ref), else empty. A schema.d/ that does not
# compose is rc 2, never an empty seed.
#
# SEAMS (a fixture needs no git): MRSL_BASE_SQL / MRSL_HEAD_SQL (files),
# MRSL_FILES (the changed-file list, one per line), MRSL_ADDED (the added
# schema.sql and schema.d/ lines), MRSL_ROOT (where changed files are read). Any seam left
# unset is read from git: the merge-base of <base-ref> (default origin/main)
# and HEAD.
#
# rc 0 = nothing to say, or every changed role carries its PUT or the waiver;
# rc 1 = a changed role with neither (each one named); rc 2 = could not run
# (base unresolvable, schema.sql unreadable, schema.d/ not composable) — never
# read as a pass.
set -uo pipefail

SCHEMA_PATH="worker/jobs/schema.sql"
FRAG_DIR="worker/jobs/schema.d"
BUILD="$(dirname "$0")/schema-build.sh"
WAIVER="seed-only: fresh-db"
BASE_REF="${1:-origin/main}"
ROOT="${MRSL_ROOT:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/mrsl.XXXXXX") || { echo "model-route-seed-lint: mktemp failed" >&2; exit 2; }
trap 'rm -rf "$TMP"' EXIT

MB=""
need_git() {
  [ -n "$MB" ] && return 0
  MB=$(git -C "$ROOT" merge-base "$BASE_REF" HEAD 2>/dev/null) \
    || { echo "model-route-seed-lint: cannot resolve a merge-base for '$BASE_REF' and HEAD — could not run" >&2; exit 2; }
}

if [ -n "${MRSL_FILES+x}" ]; then FILES="$MRSL_FILES"
else need_git; FILES=$(git -C "$ROOT" diff --name-only "$MB" HEAD) || exit 2; fi

grep -qxF "$SCHEMA_PATH" <<<"$FILES" || grep -qE '^worker/jobs/schema\.d/[^/]+\.sql$' <<<"$FILES" \
  || { echo "model-route-seed-lint: $SCHEMA_PATH not in the diff (no schema.sql, no schema.d fragment) — nothing to check"; exit 0; }

if [ -n "${MRSL_HEAD_SQL:-}" ]; then HEAD_SQL="$MRSL_HEAD_SQL"
elif [ -d "$ROOT/$FRAG_DIR" ]; then
  HEAD_SQL="$TMP/head.sql"
  "$BUILD" --root "$ROOT" --worker jobs --to "$HEAD_SQL" \
    || { echo "model-route-seed-lint: $FRAG_DIR could not be composed — could not run" >&2; exit 2; }
else HEAD_SQL="$ROOT/$SCHEMA_PATH"; fi
[ -r "$HEAD_SQL" ] || { echo "model-route-seed-lint: $HEAD_SQL unreadable — could not run" >&2; exit 2; }
if [ -n "${MRSL_BASE_SQL:-}" ]; then BASE_SQL="$MRSL_BASE_SQL"
elif [ "${MRSL_PARSE_ONLY:-0}" != 1 ]; then
  need_git; BASE_SQL="$TMP/base.sql"
  if git -C "$ROOT" cat-file -e "$MB:$SCHEMA_PATH" 2>/dev/null; then
    git -C "$ROOT" show "$MB:$SCHEMA_PATH" > "$BASE_SQL" \
      || { echo "model-route-seed-lint: git show $MB:$SCHEMA_PATH failed — could not run" >&2; exit 2; }
  elif git -C "$ROOT" cat-file -e "$MB:$FRAG_DIR" 2>/dev/null; then
    "$BUILD" --root "$ROOT" --ref "$MB" --worker jobs --to "$BASE_SQL" \
      || { echo "model-route-seed-lint: $FRAG_DIR at $MB could not be composed — could not run" >&2; exit 2; }
  else
    : > "$BASE_SQL"   # a PR that adds the schema has no base seed
  fi
fi


# mrsl_seed <file> -> role\tposition\tmodel\trunner, one line per seeded rung.
mrsl_seed() {
  awk '
    function emit(s,   f) {
      while (match(s, /\(\x27hub\x27, *NULL, *\x27[^\x27]*\x27, *[0-9]+, *\x27[^\x27]*\x27, *\x27[^\x27]*\x27/) \
          || match(s, /SELECT +\x27hub\x27, *NULL, *\x27[^\x27]*\x27, *[0-9]+, *\x27[^\x27]*\x27, *\x27[^\x27]*\x27/)) {
        t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        n = split(t, f, "\x27")
        pos = f[5]; gsub(/[^0-9]/, "", pos)
        print f[4] "\t" pos "\t" f[6] "\t" f[8]
      }
      return s
    }
    function emit4(s,   f) {
      while (match(s, /\(\x27[^\x27]*\x27, *[0-9]+, *\x27[^\x27]*\x27, *\x27[^\x27]*\x27\)/)) {
        t = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        split(t, f, "\x27")
        pos = f[3]; gsub(/[^0-9]/, "", pos)
        print f[2] "\t" pos "\t" f[4] "\t" f[6]
      }
    }
    {
      line = $0; sub(/--.*/, "", line)
      if (!inmr && line ~ /INSERT( +OR +IGNORE)? +INTO +model_routes[ (]/) { inmr = 1; buf = "" }
      if (inmr) {
        buf = buf " " line
        if (line ~ /; *$/) { rest = emit(buf); emit4(rest); inmr = 0; buf = "" }
      }
    }' "$1" | LC_ALL=C sort -u
}

# MRSL_PARSE_ONLY=1: print HEAD's parsed seed and stop (the suite's L1 seam).
[ "${MRSL_PARSE_ONLY:-0}" = 1 ] && { mrsl_seed "$HEAD_SQL"; exit 0; }

if [ -n "${MRSL_ADDED+x}" ]; then ADDED="$MRSL_ADDED"
else need_git; ADDED=$(git -C "$ROOT" diff "$MB" HEAD -- "$SCHEMA_PATH" "$FRAG_DIR" | grep '^+' | grep -v '^+++'); fi

mrsl_seed "$BASE_SQL" > "$TMP/b.tsv"
mrsl_seed "$HEAD_SQL" > "$TMP/h.tsv"

CHANGED=""
for role in $(cut -f1 "$TMP/b.tsv" | LC_ALL=C sort -u); do
  if [ "$(awk -F'\t' -v r="$role" '$1==r' "$TMP/b.tsv")" != "$(awk -F'\t' -v r="$role" '$1==r' "$TMP/h.tsv")" ]; then
    CHANGED="$CHANGED $role"
  fi
done
[ -n "$CHANGED" ] || { echo "model-route-seed-lint: no seeded role that already exists changed"; exit 0; }

# The audited PUT for a role: a changed bin/ or scripts/ file, at HEAD, whose
# CODE (lines that are not `#` or `//` comments) names /api/model-routes, makes
# a PUT call (`_jobs_req PUT`, `-X PUT`, `--request PUT`, `method: 'PUT'`), and
# names the role as a whole token. A file that only MENTIONS the API, the way
# bin/lib/model-route.sh's alert text says "PUT /api/model-routes", is not one.
has_put() {
  local role="$1" f re code
  re="(^|[^a-z0-9._-])$(printf '%s' "$role" | sed 's/[.]/\\./g')(\$|[^a-z0-9._-])"
  while IFS= read -r f; do
    case "$f" in bin/*|scripts/*) ;; *) continue ;; esac
    [ -f "$ROOT/$f" ] || continue
    code=$(grep -vE '^[[:space:]]*(#|//)' "$ROOT/$f")
    grep -qF '/api/model-routes' <<<"$code" || continue
    grep -qE "_jobs_req[[:space:]]+PUT|-X[[:space:]]*[\"']?PUT|--request[[:space:]]+[\"']?PUT|method:[[:space:]]*[\"']PUT" <<<"$code" || continue
    grep -qE "$re" <<<"$code" && { echo "$f"; return 0; }
  done <<<"$FILES"
  return 1
}

WAIVED=0
if grep -qF "$WAIVER" <<<"${PR_BODY:-}" || grep -qF "$WAIVER" <<<"$ADDED"; then WAIVED=1; fi

BAD=""; WAIVE_LIST=""
for role in $CHANGED; do
  if f=$(has_put "$role"); then
    echo "model-route-seed-lint: $role seed changed — ships its audited PUT in $f"
  elif [ "$WAIVED" = 1 ]; then
    WAIVE_LIST="$WAIVE_LIST $role"
  else
    BAD="$BAD $role"
  fi
done
[ -n "$WAIVE_LIST" ] && echo "model-route-seed-lint: WAIVED ('$WAIVER') — fresh databases only, live keeps its ladder for:$WAIVE_LIST"
[ -z "$BAD" ] && exit 0

cat <<EOF
model-route-seed-lint: FAIL — the model_routes seed changed for role(s) that already exist:$BAD
  Every model_routes seed in $SCHEMA_PATH skips a role with hub audit history
  (BH-1572), and most live roles have some, so this change reaches a fresh
  database and never live. Either:
    - ship the audited PUT that moves live in the same PR: a bin/ or scripts/
      one-shot whose code calls PUT /api/model-routes (_jobs_req PUT, curl -X
      PUT) and names the role; or
    - if the change is for fresh databases only, say so with '$WAIVER'
      in the PR body or on an added line of the schema.sql or schema.d/ diff.
  See docs/MODEL-ROUTES.md ("A seed change to an existing role").
EOF
exit 1
