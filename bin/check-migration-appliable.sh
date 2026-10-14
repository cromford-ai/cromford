#!/bin/bash
# Migration appliability gate (2026-08-14, after TK-90's 8h stall + TK-64):
# migration SQL that the app's endpoint classifier will REFUSE must be caught
# at BUILD time, not discovered at apply time. TK-90 shipped DO-$$-guarded
# enum→TEXT rewrites the classifier refused — the apply stalled ~8h until a
# human unblocked it (TK-130 then taught the app the lossless widening).
# TK-64's finance tables sat unapplied for days while deployed code threw on
# every load. Both incidents share a shape: a migration that LOOKS done but
# cannot actually be applied by the machinery that applies migrations.
#
# usage: check-migration-appliable.sh <project> <dir> [file...]
#   <dir>   the build worktree (branch checked out). With no explicit files,
#           lints the scripts/migrations/*.sql and scripts/migrate-*.ts files
#           ADDED by the branch vs ${BASE_BRANCH:-main}. With file args
#           (relative to <dir> or absolute), lints exactly those — the
#           standalone/test mode.
#   exit 0  every statement is inside the conservative allowlist
#   exit 1  at least one FLAGGED statement (report on stdout)
#   exit 2  usage / unreadable input
#
# A .ts file (BH-4924) is read by mtd_extract (bin/lib/migrate-ts-ddl.sh,
# sourced only when a .ts is in the list), and its statements go through the
# SAME case block below. A .ts also prints one "<file>: allowed: <stmt>" line
# per statement it passes; a .sql prints only its FLAGGED lines, as before.
#
# THIS GATE NEVER BLOCKS A PR. run-build.sh maps exit 1 to forced tier 2 plus
# a "MIGRATION GATE:" section in the PR body and RESULT — the work still ships
# as a PR; only the unattended merge is withheld so a human sees the SQL first.
#
# Allowlist (conservative, per the endpoint classifier's real behavior):
#   CREATE TABLE, CREATE [UNIQUE] INDEX
#   ALTER TABLE ... ADD COLUMN (single action)
#   ALTER TABLE ... ADD CONSTRAINT (bare NAMED constraint — the TK-137
#     convention; the executor treats duplicate-constraint 42710 as applied)
#   ALTER TABLE ... ENABLE ROW LEVEL SECURITY
#   ALTER TABLE ... ALTER COLUMN x TYPE TEXT USING x::text (SELF-cast only —
#     the TK-130 lossless widening; a cast through any other expression flags)
#   ALTER TABLE ... ALTER COLUMN x DROP NOT NULL (bare anchored shape only —
#     TK-197 constraint relaxation; any rider like CASCADE still flags)
#   ALTER TYPE ... ADD VALUE (additive enum — TK-197; matches the endpoint)
#   REVOKE
# .ts only (a libsql migrate script's idempotent shapes):
#   PRAGMA table_info(<table>) (that exact read, the table bare, "…" or '…';
#     every other PRAGMA flags)
#   INSERT ... WHERE NOT EXISTS / ON CONFLICT [(cols)] DO NOTHING /
#     INSERT OR IGNORE (INSERT OR REPLACE and ON CONFLICT DO UPDATE flag)
#   and a COMPUTED line from mtd_extract always flags: SQL built at run time
#   is SQL this lint never read. UPDATE flags as a data rewrite.
# Everything else flags: DO $$ blocks, CREATE FUNCTION/TRIGGER/EXTENSION,
# DROP/TRUNCATE/DELETE, any GRANT (to anon/authenticated with its own message
# — that one breaks the deny-by-default RLS posture), and the long tail of
# statements this box has no business auto-merging. Default-deny on purpose:
# a false flag costs one human merge; a false pass costs an TK-64.
set -uo pipefail
PROJECT="${1:?project}"; DIR="${2:?worktree-or-dir}"; shift 2
[ -d "$DIR" ] || { echo "check-migration-appliable: no such dir $DIR" >&2; exit 2; }

FILES=("$@")
if [ "${#FILES[@]}" -eq 0 ]; then
  BASE="${BASE_BRANCH:-main}"
  mapfile -t FILES < <(cd "$DIR" && git diff --name-only --diff-filter=A "$BASE"...HEAD -- 'scripts/migrations/*.sql' 'scripts/migrate-*.ts' 2>/dev/null)
fi
[ "${#FILES[@]}" -gt 0 ] || exit 0

# classify_stream — one statement per line on stdin; prints this file's report
# lines. $F names the file, $IS_TS=1 turns on the .ts-only arms.
# PRAGMA table_info(<t>), the table bare, "double-" or 'single-quoted'.
PRAGMA_INFO_RE='^PRAGMA TABLE_INFO *\( *([A-Z0-9_]+|"[A-Z0-9_]+"|'"'"'[A-Z0-9_]+'"'"') *\)$'
allow() { if [ "$IS_TS" = 1 ]; then echo "$F: allowed: $SNIP"; fi; }
classify_stream() {
  while IFS= read -r ST; do
    [ -n "$ST" ] || continue
    U=$(echo "$ST" | tr '[:lower:]' '[:upper:]')
    SNIP=$(head -c 110 <<<"$ST")
    # .ts-only arms first (BH-4924). A .sql line, or a .ts line none of them
    # decides, falls through to the shared block, so .sql reports are
    # byte-identical to before.
    if [ "$IS_TS" = 1 ]; then
      case "$U" in
        "COMPUTED "*) echo "$F: FLAGGED (computed SQL — never auto-applied): ${ST#COMPUTED }"; continue ;;
        "PRAGMA "*)
          if [[ "$U" =~ $PRAGMA_INFO_RE ]]; then allow; continue; fi ;;
        "INSERT "*)
          if [[ "$U" =~ ON\ CONFLICT.*DO\ UPDATE || "$U" == "INSERT OR REPLACE "* ]]; then
            echo "$F: FLAGGED (INSERT that overwrites rows — never auto-applied): $SNIP"
          elif [[ "$U" == "INSERT OR IGNORE "* || "$U" == *" WHERE NOT EXISTS"* || "$U" =~ ON\ CONFLICT(\ *\([^\)]*\))?\ *DO\ NOTHING$ ]]; then
            allow
          else
            echo "$F: FLAGGED (INSERT without a NOT EXISTS / DO NOTHING / OR IGNORE guard — not idempotent): $SNIP"
          fi
          continue ;;
        "UPDATE "*) echo "$F: FLAGGED (data rewrite — never auto-applied): $SNIP"; continue ;;
      esac
    fi
    case "$U" in
      "END "*|END) continue ;;   # trailing END of a collapsed block rides with its DO flag
      "CREATE TABLE "*) allow; continue ;;
      "CREATE INDEX "*|"CREATE UNIQUE INDEX "*) allow; continue ;;
      "REVOKE "*) allow; continue ;;
      "DO "*|DO) echo "$F: FLAGGED (DO block — the endpoint classifier refuses procedural guards; TK-90/TK-130): $SNIP" ;;
      "CREATE FUNCTION "*|"CREATE OR REPLACE FUNCTION "*|"CREATE TRIGGER "*|"CREATE OR REPLACE TRIGGER "*|"CREATE EXTENSION "*) \
        echo "$F: FLAGGED (CREATE FUNCTION/TRIGGER/EXTENSION — outside the appliable allowlist): $SNIP" ;;
      "DROP "*|"TRUNCATE "*|"DELETE "*) echo "$F: FLAGGED (destructive statement — never auto-merged): $SNIP" ;;
      "GRANT "*)
        if grep -qE 'TO +(ANON|AUTHENTICATED)\b' <<<"$U"; then
          echo "$F: FLAGGED (GRANT to anon/authenticated — breaks the deny-by-default RLS posture): $SNIP"
        else
          echo "$F: FLAGGED (GRANT — outside the appliable allowlist): $SNIP"
        fi ;;
      "ALTER TABLE "*)
        REST=$(echo "$U" | sed -E 's/^ALTER TABLE (IF EXISTS )?(ONLY )?"?[A-Za-z0-9_.]+"?\.?"?[A-Za-z0-9_]*"? //')
        if [[ "$REST" == "ADD COLUMN "* && "$REST" != *","* ]]; then allow; continue; fi
        if [[ "$REST" == "ADD CONSTRAINT "* && "$REST" != *","* ]]; then allow; continue; fi
        if [[ "$REST" == "ENABLE ROW LEVEL SECURITY" ]]; then allow; continue; fi
        # TK-130 self-cast: ALTER COLUMN x TYPE TEXT USING x::text — the
        # USING column must be the SAME column (a lossless in-place widen).
        if [[ "$REST" =~ ^ALTER\ COLUMN\ (\"?[A-Za-z0-9_]+\"?)\ TYPE\ TEXT\ USING\ (\"?[A-Za-z0-9_]+\"?)::TEXT$ ]] \
           && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]; then allow; continue; fi
        # TK-197 constraint relaxation: bare DROP NOT NULL, anchored — a
        # trailing rider (CASCADE) or a second action falls through to FLAG.
        if [[ "$REST" =~ ^ALTER\ COLUMN\ \"?[A-Za-z0-9_]+\"?\ DROP\ NOT\ NULL$ ]]; then allow; continue; fi
        echo "$F: FLAGGED (ALTER TABLE action outside the appliable allowlist): $SNIP" ;;
      "ALTER TYPE "*)
        # TK-197 additive enum: endpoint classifier allows ALTER TYPE … ADD VALUE.
        if [[ "$U" == *" ADD VALUE"* ]]; then allow; continue; fi
        echo "$F: FLAGGED (ALTER TYPE action outside the appliable allowlist): $SNIP" ;;
      *) echo "$F: FLAGGED (outside the appliable allowlist): $SNIP" ;;
    esac
  done
}

REPORT=$(for F in "${FILES[@]}"; do
  P="$F"; [ -f "$P" ] || P="$DIR/$F"
  [ -f "$P" ] || { echo "$F: FLAGGED (file unreadable)"; continue; }
  if [[ "$F" == *.ts ]]; then
    IS_TS=1
    declare -F mtd_extract >/dev/null || . "$(dirname "$0")/lib/migrate-ts-ddl.sh" 2>/dev/null
    declare -F mtd_extract >/dev/null || { echo "$F: FLAGGED (ts extractor unavailable — not linted)"; continue; }
    STMTS=$(mtd_extract "$P") || { echo "$F: FLAGGED (file unreadable)"; continue; }
    printf '%s\n' "$STMTS" | classify_stream
    continue
  fi
  IS_TS=0
  # Normalize to one statement per line: strip -- and /* */ comments, collapse
  # dollar-quoted bodies to a marker (a DO body's inner semicolons would
  # otherwise shred into nonsense fragments — the DO itself is what flags),
  # then split on ';' and squeeze whitespace.
  perl -0777 -pe 's/--[^\n]*//g; s{/\*.*?\*/}{}gs; s/\$[A-Za-z_]*\$.*?\$[A-Za-z_]*\$/ <body> /gs' "$P" \
    | tr '\n' ' ' | tr ';' '\n' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' \
    | classify_stream
done)

[ -n "$REPORT" ] && printf '%s\n' "$REPORT"
[[ "$REPORT" == *": FLAGGED ("* ]] && exit 1
exit 0
