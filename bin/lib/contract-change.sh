#!/bin/bash
# bin/lib/contract-change.sh — the contract-change ticket type (BH-9929).
#
# The migration gate (bin/check-migration-appliable.sh) allows additive SQL
# only. That stays the rule for an ordinary build. A non-additive change (drop
# or change a constraint, change a column type or nullability, rename a column
# or table, drop a column, drop a table, merge two tables) has ONE reviewed
# path: a contract-change ticket. The lane runs it as 3 ordered PRs, each with
# its own gate and verdict:
#   expand    add the new shape, write to both
#   migrate   backfill (idempotent, resumable script), switch every read,
#             prove 0 reads of the old shape
#   contract  remove the old shape, after a named backup and a restore test
#
# Sourced, never executed. No side effect at source time. Safe under `set -u`.
# Every function answers a question; the CALLER decides what it means.
#
#   cc_is_ticket <ticket-meta.json>   rc 0 = a contract-change ticket
#   cc_body_is_marked <body-file>     rc 0 = the body has `Contract-change: yes`
#   cc_step_of <body-file>            prints expand|migrate|contract, rc 1 none
#   cc_parent_of <body-file>          prints the `Contract-parent: #<n>` number
#   cc_classify_sql <sql-file>        one class per contract statement
#   cc_scan_sql <sql-file>            `<class>\t<old-name>\t<statement>` lines
#   cc_residue_sql <sql-file>         the statements that are NOT contract statements
#   cc_riders_sql <sql-file>          the non-contract, non-additive ACTIONS inside
#                                     contract statements (must be empty)
#   cc_stmt_riders <STMT>             the same for ONE statement
#   cc_old_names <sql-file>...        the old-shape names a contract step removes
#   cc_class_of_stmt <STMT>           the classes of ONE statement (any case)
#   cc_human_class <classes>          rc 0 = drop-table, drop-column, merge or type
#   cc_enabled <project>              rc 0 on, 1 off, 2 unreadable (= off)
#   cc_mig_glob <project>             the project's migration glob (rc 2 unreadable)
#   cc_sql_added <project> <base> <wt>  the migration SQL files the branch adds,
#                                     under scripts/migrations/ AND the project's
#                                     migrations_glob row (rc 2 = row unreadable)
#
# MARKER FORMATS (writer: bin/lib/fc-contract-change.sh; readers: here):
#   ticket body   `Contract-change: yes`           (a board ticket)
#   ticket label  `contract-change`                (GitHub Issues)
#   child body    `Contract-step: expand|migrate|contract`
#                 `Contract-parent: #<n>`
# Only the BODY counts: a comment with the marker never makes a ticket a
# contract change. A marker inside a ``` or ~~~ fence is an example, not a
# marker.

# _cc_unfenced <file> — the file with fenced blocks (``` and ~~~) removed.
_cc_unfenced() {
  awk '
    { line=$0; t=line; sub(/^[[:space:]]+/, "", t) }
    fence == "" && (t ~ /^```/ || t ~ /^~~~/) { fence=substr(t,1,3); next }
    fence != "" { if (index(t, fence) == 1) fence=""; next }
    { print line }
  ' "${1:-/dev/null}" 2>/dev/null
}

# cc_body_is_marked <body-file> — a line `Contract-change: yes` (any case, an
# optional `- ` bullet) outside a fence. `yes please`, `no` and prose do not count.
cc_body_is_marked() {
  [ -r "${1:-}" ] || return 1
  _cc_unfenced "$1" | grep -qiE '^[[:space:]]*(- )?contract-change:[[:space:]]*yes[[:space:]]*$'
}

# cc_is_ticket <ticket-meta.json> — label `contract-change` (exact word, any
# case) or the body marker. Labels may be objects ({name}) or strings.
cc_is_ticket() {
  local meta="${1:-}" tmp rc
  [ -r "$meta" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  if jq -e '[.labels[]? | if type == "object" then (.name // "") else tostring end
            | ascii_downcase] | index("contract-change") != null' "$meta" >/dev/null 2>&1; then
    return 0
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/cc-body.XXXXXX") || return 1
  jq -r '.body // ""' "$meta" > "$tmp" 2>/dev/null
  cc_body_is_marked "$tmp"; rc=$?
  rm -f "$tmp"
  return "$rc"
}

# cc_step_of <body-file> — the step word of a contract-change child.
cc_step_of() {
  local s
  [ -r "${1:-}" ] || return 1
  s=$(_cc_unfenced "$1" | sed -nE 's/^[[:space:]]*(- )?[Cc]ontract-step:[[:space:]]*([A-Za-z]+)[[:space:]]*$/\2/p' \
      | head -1 | tr '[:upper:]' '[:lower:]')
  case "$s" in expand|migrate|contract) printf '%s\n' "$s"; return 0 ;; esac
  return 1
}

# cc_parent_of <body-file> — the parent issue number of a contract-change child.
cc_parent_of() {
  local n
  [ -r "${1:-}" ] || return 1
  n=$(_cc_unfenced "$1" | sed -nE 's/^[[:space:]]*(- )?[Cc]ontract-parent:[[:space:]]*#?([0-9]+)[[:space:]]*$/\2/p' | head -1)
  [ -n "$n" ] || return 1
  printf '%s\n' "$n"
}

# _cc_statements <sql-file> — one statement per line: the SAME normalizer as
# bin/check-migration-appliable.sh (strip -- and /* */ comments, collapse
# dollar-quoted bodies, split on ';', squeeze whitespace).
_cc_statements() {
  [ -r "${1:-}" ] || return 1
  perl -0777 -pe 's/--[^\n]*//g; s{/\*.*?\*/}{}gs; s/\$[A-Za-z_]*\$.*?\$[A-Za-z_]*\$/ <body> /gs' "$1" \
    | tr '\n' ' ' | tr ';' '\n' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//' | grep -v '^$'
}

# _cc_ident <word> — an identifier without quotes or a schema prefix.
_cc_ident() {
  local w="${1:-}"
  w=${w//\"/}; w=${w//\`/}
  w=${w##*.}
  printf '%s' "$w"
}

# cc_class_of_stmt <STMT> — the contract classes of one statement, one per line,
# `<class>\t<old-name>`. <old-name> is the name a reader of the OLD shape uses
# (dropped table, dropped column, renamed-from name), or "-". No output = not a
# contract statement. A CHECK constraint ADDED alone is not a class here: the
# file-level scan (cc_scan_sql) decides that, because only a drop in the same
# file makes it a CHECK-list change.
cc_class_of_stmt() {
  local st="${1:-}" u rest tbl col act
  u=$(printf '%s' "$st" | tr '[:lower:]' '[:upper:]')
  case "$u" in
    "DROP TABLE "*)
      tbl=$(printf '%s' "$st" | sed -E 's/^[Dd][Rr][Oo][Pp] [Tt][Aa][Bb][Ll][Ee] ([Ii][Ff] [Ee][Xx][Ii][Ss][Tt][Ss] )?//; s/[ ,].*$//')
      printf 'drop-table\t%s\n' "$(_cc_ident "$tbl")"; return 0 ;;
    "ALTER TYPE "*)
      [[ "$u" == *" ADD VALUE"* ]] && return 0
      printf 'type\t-\n'; return 0 ;;
    "ALTER TABLE "*) ;;
    *) return 0 ;;
  esac
  # ALTER TABLE [IF EXISTS] [ONLY] <name> <action>[, <action>...]
  tbl=$(printf '%s' "$st" | sed -E 's/^[Aa][Ll][Tt][Ee][Rr] [Tt][Aa][Bb][Ll][Ee] ([Ii][Ff] [Ee][Xx][Ii][Ss][Tt][Ss] )?([Oo][Nn][Ll][Yy] )?//; s/ .*$//')
  rest=$(printf '%s' "$st" | sed -E 's/^[Aa][Ll][Tt][Ee][Rr] [Tt][Aa][Bb][Ll][Ee] ([Ii][Ff] [Ee][Xx][Ii][Ss][Tt][Ss] )?([Oo][Nn][Ll][Yy] )?[^ ]+ //')
  # One action per line (_cc_actions: commas outside parentheses and quotes).
  while IFS= read -r act; do
    [ -n "$act" ] || continue
    u=$(printf '%s' "$act" | tr '[:lower:]' '[:upper:]')
    # The TK-130 self-cast and the TK-197 bare DROP NOT NULL are allowlisted
    # widenings, not contract changes.
    if [[ "$u" =~ ^ALTER\ COLUMN\ (\"?[A-Z0-9_]+\"?)\ TYPE\ TEXT\ USING\ (\"?[A-Z0-9_]+\"?)::TEXT$ ]] \
       && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]; then continue; fi
    case "$u" in
      "DROP CONSTRAINT "*) printf 'constraint\t-\n' ;;
      "ALTER "*" SET NOT NULL"*) printf 'nullability\t-\n' ;;
      "ALTER "*" DROP NOT NULL"*|"ALTER "*" SET DEFAULT"*|"ALTER "*" DROP DEFAULT"*) ;;
      "ALTER "*" TYPE "*) printf 'type\t-\n' ;;
      "RENAME TO "*) printf 'rename\t%s\n' "$(_cc_ident "$tbl")" ;;
      "RENAME "*" TO "*)
        col=$(printf '%s' "$act" | sed -E 's/^[^ ]+ ([Cc][Oo][Ll][Uu][Mm][Nn] )?//; s/ .*$//')
        printf 'rename\t%s\n' "$(_cc_ident "$col")" ;;
      "DROP "*)
        col=$(printf '%s' "$act" | sed -E 's/^[^ ]+ ([Cc][Oo][Ll][Uu][Mm][Nn] )?([Ii][Ff] [Ee][Xx][Ii][Ss][Tt][Ss] )?//; s/ .*$//')
        case "$(printf '%s' "$col" | tr '[:lower:]' '[:upper:]')" in
          ''|CONSTRAINT|NOT|DEFAULT|IDENTITY|EXPRESSION) ;;
          *) printf 'drop-column\t%s\n' "$(_cc_ident "$col")" ;;
        esac ;;
    esac
  done < <(_cc_actions "$rest")
  return 0
}

# _cc_actions <text> — the actions of an ALTER TABLE, one per line: split on
# commas outside parentheses, '...' literals and "..." identifiers. A `)` or
# `,` inside a literal or a quoted name never hides the next action (BH-9929
# review: `CHECK (note NOT LIKE '%:)'), DROP COLUMN x` hid the DROP COLUMN).
# A '' or "" inside a quote is the escaped quote. Text that ends inside a
# quote or with unbalanced parentheses prints the line `<unbalanced>` last.
_cc_actions() {
  printf '%s\n' "${1:-}" | awk '{
      d=0; q=""; cur="";
      for (i=1; i<=length($0); i++) { c=substr($0,i,1);
        if (q != "") { cur=cur c; if (c==q) { if (substr($0,i+1,1)==q) { cur=cur q; i++ } else q="" } continue }
        if (c=="\047" || c=="\"") { q=c; cur=cur c; continue }
        if (c=="(") d++; else if (c==")") d--;
        if (c=="," && d==0) { sub(/^ +/,"",cur); print cur; cur=""; continue }
        cur=cur c }
      sub(/^ +/,"",cur); print cur
      if (q != "" || d != 0) print "<unbalanced>" }'
}

# _cc_action_known <ACTION-UPPERCASE> — rc 0 when one ALTER TABLE action is a
# contract action this lib classifies, or an action the migration gate
# (bin/check-migration-appliable.sh) allows. Every other action is a rider.
_cc_action_known() {
  local u="${1:-}" re
  case "$u" in
    "ADD COLUMN "*|"ADD CONSTRAINT "*) return 0 ;;
  esac
  for re in \
    '^DROP CONSTRAINT (IF EXISTS )?[^ ]+( RESTRICT)?$' \
    '^RENAME TO [^ ]+$' \
    '^RENAME (COLUMN )?[^ ]+ TO [^ ]+$' \
    '^DROP (COLUMN )?(IF EXISTS )?[^ ]+( RESTRICT)?$' \
    '^ALTER (COLUMN )?[^ ]+ (SET|DROP) NOT NULL$' \
    '^ALTER (COLUMN )?[^ ]+ (SET DATA )?TYPE '; do
    [[ "$u" =~ $re ]] && return 0
  done
  return 1
}

# cc_stmt_riders <STMT> — for a contract statement (a cc_scan_sql line), the
# parts of it that are neither a contract action nor an additive action, one
# per line. No output = the statement is clean. A statement that is not a
# contract statement is cc_residue_sql's, and the migration gate judges it.
# The residue check is per statement; this is the same check per ACTION, so a
# `DISABLE ROW LEVEL SECURITY` or an `OWNER TO anon` inside a contract
# ALTER TABLE never rides along (BH-9929 review). Fails closed: a backslash
# (an E'' escape this lib does not parse), an unbalanced quote or parenthesis,
# a DROP TABLE of more than one table or with CASCADE, and an ALTER TYPE that
# is not RENAME VALUE or RENAME TO are riders too.
cc_stmt_riders() {
  local st="${1:-}" u rest act re_drop re_type
  case "$st" in *\\*) printf '%s\n' "backslash in a contract statement"; return 0 ;; esac
  u=$(printf '%s' "$st" | tr '[:lower:]' '[:upper:]')
  re_drop='^DROP TABLE (IF EXISTS )?[^ ,'"'"'"]+( RESTRICT)?$'
  re_type='^ALTER TYPE [^ ]+ RENAME (VALUE '"'"'[^'"'"']*'"'"' TO '"'"'[^'"'"']*'"'"'|TO [^ ]+)$'
  case "$u" in
    "DROP TABLE "*) [[ "$u" =~ $re_drop ]] || printf '%s\n' "$st"; return 0 ;;
    "ALTER TYPE "*) [[ "$u" =~ $re_type ]] || printf '%s\n' "$st"; return 0 ;;
  esac
  rest=$(printf '%s' "$st" | sed -E 's/^[Aa][Ll][Tt][Ee][Rr] [Tt][Aa][Bb][Ll][Ee] ([Ii][Ff] [Ee][Xx][Ii][Ss][Tt][Ss] )?([Oo][Nn][Ll][Yy] )?[^ ]+ //')
  while IFS= read -r act; do
    [ -n "$act" ] || { printf '%s\n' "<empty action>"; continue; }
    u=$(printf '%s' "$act" | tr '[:lower:]' '[:upper:]')
    _cc_action_known "$u" || printf '%s\n' "$act"
  done < <(_cc_actions "$rest")
  return 0
}

# cc_riders_sql <sql-file> — cc_stmt_riders over every contract statement of
# the file (every statement cc_scan_sql prints, the file-level CHECK rule
# included), `<statement>\t<rider>` per line. rc 1 = unreadable.
cc_riders_sql() {
  local st r stmts
  _cc_statements "${1:-}" >/dev/null || return 1
  stmts=$(cc_scan_sql "$1" | cut -f3- | sort -u)
  while IFS= read -r st; do
    [ -n "$st" ] || continue
    while IFS= read -r r; do
      [ -n "$r" ] && printf '%s\t%s\n' "$st" "$r"
    done < <(cc_stmt_riders "$st")
  done <<<"$stmts"
  return 0
}

# cc_scan_sql <sql-file> — `<class>\t<old-name>\t<statement>` per contract
# statement of the file. Two file-level rules:
#   - `ADD CONSTRAINT .. CHECK` is class `constraint` only when the same file
#     drops a constraint (a CHECK-list change); a bare add is allowlisted.
#   - `INSERT INTO a .. SELECT .. FROM b` plus `DROP TABLE b` in the same file
#     is a `merge`: the DROP TABLE b line is printed as merge, not drop-table.
cc_scan_sql() {
  local f="${1:-}" stmts st u line cls name has_drop_constraint=0 merged=""
  stmts=$(_cc_statements "$f") || return 1
  [ -n "$stmts" ] || return 0
  if grep -qiE '^ALTER TABLE .*(^|, ?| )DROP CONSTRAINT ' <<<"$stmts"; then has_drop_constraint=1; fi
  # merge sources: INSERT INTO <a> [ (cols) ] SELECT ... FROM <b>
  merged=$(grep -iE '^INSERT (OR [A-Z]+ )?INTO [^ ]+.* SELECT .* FROM [^ ]+' <<<"$stmts" \
    | sed -nE 's/.* [Ff][Rr][Oo][Mm] ([^ ,;()]+).*/\1/p' | while IFS= read -r n; do _cc_ident "$n"; echo; done \
    | tr '[:upper:]' '[:lower:]' | sort -u)
  while IFS= read -r st; do
    [ -n "$st" ] || continue
    u=$(printf '%s' "$st" | tr '[:lower:]' '[:upper:]')
    if [ "$has_drop_constraint" = 1 ] && [[ "$u" =~ ^ALTER\ TABLE\ .*ADD\ CONSTRAINT\ [^\ ]+\ CHECK ]] \
       && ! [[ "$u" =~ DROP\ CONSTRAINT ]]; then
      printf 'constraint\t-\t%s\n' "$st"; continue
    fi
    while IFS=$'\t' read -r cls name; do
      [ -n "$cls" ] || continue
      if [ "$cls" = drop-table ] && [ -n "$merged" ] \
         && grep -qxF "$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" <<<"$merged"; then
        cls=merge
      fi
      printf '%s\t%s\t%s\n' "$cls" "$name" "$st"
    done < <(cc_class_of_stmt "$st")
  done <<<"$stmts"
}

# cc_classify_sql <sql-file> — the class column of cc_scan_sql.
cc_classify_sql() {
  local out
  out=$(cc_scan_sql "$1") || return 1
  [ -n "$out" ] && cut -f1 <<<"$out"
  return 0
}

# cc_residue_sql <sql-file> — the statements of the file that are NOT contract
# statements (no cc_scan_sql line), one per line, each ending in `;`. A
# contract step may carry these only when bin/check-migration-appliable.sh
# passes them: a DELETE, TRUNCATE, UPDATE, GRANT or DO block beside a contract
# statement is not part of the lane (BH-9929 review). rc 1 = unreadable.
cc_residue_sql() {
  local f="${1:-}" stmts scanned
  stmts=$(_cc_statements "$f") || return 1
  [ -n "$stmts" ] || return 0
  scanned=$(cc_scan_sql "$f" | cut -f3- | sort -u)
  if [ -n "$scanned" ]; then
    grep -vxF -f <(printf '%s\n' "$scanned") <<<"$stmts" | sed 's/$/;/'
  else
    sed 's/$/;/' <<<"$stmts"
  fi
  return 0
}

# cc_old_names <sql-file>... — the unique old-shape names (not "-") the files
# remove or rename. A contract step must leave 0 reads of each.
cc_old_names() {
  local f
  for f in "$@"; do cc_scan_sql "$f"; done | awk -F'\t' '$2 != "-" && $2 != "" {print $2}' | sort -u
}

# cc_mig_glob <project> — the glob of the project's own migration SQL: the
# settings row migrations_glob.<project> through mg_glob
# (bin/lib/migrations-glob.sh; project-6-os: prisma/sql/*.sql), else
# scripts/migrations/*.sql. rc 2 when the row is set but unreadable or invalid:
# a contract-change reader must not decide from the default then, because the
# project's SQL would be invisible to it (BH-9929 review: project-6-os keeps its
# SQL in prisma/sql/, and the gate read only scripts/migrations/).
cc_mig_glob() {
  local here
  here="$(dirname "${BASH_SOURCE[0]}")"
  if ! command -v mg_glob >/dev/null 2>&1 && [ -r "$here/migrations-glob.sh" ]; then
    # shellcheck source=bin/lib/migrations-glob.sh
    . "$here/migrations-glob.sh" 2>/dev/null
  fi
  if ! command -v mg_glob >/dev/null 2>&1; then printf 'scripts/migrations/*.sql\n'; return 0; fi
  mg_glob "${1:-}" >/dev/null 2>&1
  printf '%s\n' "$MG_GLOB"
  case "$MG_SRC" in unreadable|invalid) return 2 ;; esac
  return 0
}

# cc_sql_added <project> <base> <worktree> — the SQL files the branch ADDS, one
# path per line, sorted: migration_sql_added (scripts/migrations/*.sql) plus the
# files under cc_mig_glob <project> (git's :(glob) magic, so `*` stays in the
# one directory, as bin/hotfix-migrate.sh reads it). rc 2 = the glob row is
# unreadable: callers fail closed.
cc_sql_added() {
  local p="${1:-}" base="${2:-}" wt="${3:-.}" g rc=0 here
  here="$(dirname "${BASH_SOURCE[0]}")"
  if ! command -v migration_sql_added >/dev/null 2>&1 && [ -r "$here/migration-files.sh" ]; then
    # shellcheck source=bin/lib/migration-files.sh
    . "$here/migration-files.sh" 2>/dev/null
  fi
  g=$(cc_mig_glob "$p") || rc=$?
  [ "$rc" = 0 ] || return 2
  {
    command -v migration_sql_added >/dev/null 2>&1 && migration_sql_added "$base" "$wt"
    [ "$g" = 'scripts/migrations/*.sql' ] \
      || git -C "$wt" diff --name-only --diff-filter=A "$base"...HEAD -- ":(glob)$g" 2>/dev/null
  } | grep -v '^$' | sort -u
  return 0
}

# cc_human_class <classes...> — rc 0 when a class needs the owner's human
# verdict (Scope 4): drop-table, drop-column, merge, and type. A type change
# can lose every stored value as a drop does (`TYPE integer USING NULL`, or a
# numeric -> integer cast that rounds each amount), so a person confirms the
# self-attested BACKUP and RESTORE-TESTED lines first (BH-9929 refute
# review). The ticket names only a constraint or CHECK-list change as
# normal-review; nullability and rename keep every stored value. Classes come
# as args or as one whitespace/newline-separated string.
cc_human_class() {
  local c
  for c in $*; do
    case "$c" in drop-table|drop-column|merge|type) return 0 ;; esac
  done
  return 1
}

# cc_enabled <project> — the per-project switch (Scope 8), the settings row
# lib.contract-change.<project>.contract_change_enabled, then env
# CONTRACT_CHANGE_ENABLED, then 0. rc 0 on, 1 off, 2 the registry read could
# not run. Every caller treats 2 as off: fail closed.
cc_enabled() {
  local p="${1:-}" h v
  [ -n "$p" ] || return 1
  h="${HARNESS:-${H:-}}"
  v=$(
    _here="$(dirname "${BASH_SOURCE[0]}")"
    if [ -r "$_here/lane-gate.sh" ]; then . "$_here/lane-gate.sh" 2>/dev/null
    elif [ -n "$h" ] && [ -r "$h/bin/lib/lane-gate.sh" ]; then . "$h/bin/lib/lane-gate.sh" 2>/dev/null; fi
    command -v lib_env_apply >/dev/null 2>&1 || { echo unreadable; exit 0; }
    HARNESS="$h" lib_env_apply contract-change "$p" >/dev/null 2>&1 || { echo unreadable; exit 0; }
    printf '%s\n' "${CONTRACT_CHANGE_ENABLED:-0}"
  )
  case "$v" in
    1|true|on|yes) return 0 ;;
    unreadable|'') return 2 ;;
    *) return 1 ;;
  esac
}

# cc_plan_note <step> <parent> <build-dir> — the one plan-prompt note of a
# contract-change child (bin/lib/rb/plan.sh `# >>> contract-step note`).
cc_plan_note() {
  printf 'CONTRACT-CHANGE STEP (BH-9929): this ticket is the %s step of contract-change #%s. Keep to the rules of that step in the ticket body. The plan'"'"'s last task writes %s/contract-step.md with the evidence lines the ticket body lists for this step; the PR stage runs bin/contract-change-gate.sh on that file and the diff, and opens no PR while it refuses.' \
    "${1:-?}" "${2:-?}" "${3:-\$BUILD}"
}
