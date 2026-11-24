#!/bin/bash
# guardrails/rls-on-create-table/check.sh [file|dir ...]
#
# Every migration that CREATEs a table must ENABLE ROW LEVEL SECURITY on it.
# Supabase auto-grants anon/authenticated full CRUD on every new public table
# and exposes it through PostgREST, so an RLS-off table means anyone holding the
# project URL and the anon key can read, write, and delete it — app auth
# bypassed entirely. Our apps connect as postgres/service-role (both BYPASSRLS),
# so deny-all RLS is a ZERO-app-impact change; there is no cost to being right.
#
# Deliberately NOT a semgrep rule: the condition is "this file creates a table
# AND does not, anywhere in the same file, enable RLS on it" — a whole-file
# absence assertion, which pattern matchers express badly and which reviewers
# then misread. A twenty-line shell check that says exactly what it means is the
# honest tool here.
#
# Default target: prisma/migrations and supabase/migrations, if they exist.
# rc 0 = clean (or skipped via the escape hatch), rc 1 = violation.
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=../lib/escape-hatch.sh
. "$SELF/../lib/escape-hatch.sh" 2>/dev/null || true
declare -F guardrail_escape_hatch >/dev/null \
  && guardrail_escape_hatch rls-on-create-table && exit 0

TARGETS=("$@")
if [ "${#TARGETS[@]}" -eq 0 ]; then
  for d in prisma/migrations supabase/migrations migrations; do
    [ -d "$d" ] && TARGETS+=("$d")
  done
fi
if [ "${#TARGETS[@]}" -eq 0 ]; then
  echo "GUARDRAIL rls-on-create-table: no migration directory found — nothing to check."
  exit 0
fi

FILES=$(find "${TARGETS[@]}" -type f -name '*.sql' 2>/dev/null | sort)
[ -n "$FILES" ] || { echo "GUARDRAIL rls-on-create-table: no .sql files under ${TARGETS[*]} — nothing to check."; exit 0; }
# On a Mergify batch draft, files only a hatched source PR changed are exempt
# (BH-9965). Off a batch draft the exempt list is empty and this is a no-op.
declare -F guardrail_drop_exempt >/dev/null && FILES=$(printf '%s\n' "$FILES" | guardrail_drop_exempt)

BAD=0
while IFS= read -r F; do
  [ -n "$F" ] || continue
  grep -qiE '^[[:space:]]*CREATE[[:space:]]+TABLE' "$F" || continue
  if ! grep -qiE 'ENABLE[[:space:]]+ROW[[:space:]]+LEVEL[[:space:]]+SECURITY' "$F"; then
    echo "GUARDRAIL rls-on-create-table: $F creates a table but never enables RLS."
    grep -inE '^[[:space:]]*CREATE[[:space:]]+TABLE[^(]*' "$F" | head -5 | sed 's/^/    /'
    BAD=$((BAD + 1))
  fi
done <<< "$FILES"

if [ "$BAD" -gt 0 ]; then
  cat <<'EOF'

Add to each such migration, for every table it creates:
    ALTER TABLE public."<Table>" ENABLE ROW LEVEL SECURITY;
Deny-all RLS (enabled, no policies) is correct for tables our apps reach as
postgres/service-role. A worker role that is NOT postgres/service_role and
lacks BYPASSRLS needs a scoped policy created BEFORE the ALTER, or it locks
itself out. Full recipe: ~/.claude/rules/supabase-rls.md
EOF
  exit 1
fi
echo "GUARDRAIL rls-on-create-table: clean."
exit 0
