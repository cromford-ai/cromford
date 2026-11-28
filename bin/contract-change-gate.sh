#!/bin/bash
# bin/contract-change-gate.sh — the per-step gate of a contract-change child
# (BH-9929). A contract-change ticket runs a non-additive schema change as 3
# ordered PRs: expand, migrate, contract. Each step has its own rules, checked
# HERE, before its PR opens (bin/lib/rb/pr.sh `# >>> contract-change gate`).
#
# usage: contract-change-gate.sh <project> <worktree> <base> <step> <evidence-file>
#   <base>           the ref the branch is compared with (origin/main)
#   <step>           expand | migrate | contract
#   <evidence-file>  the step's PR-body lines (the build writes
#                    $BUILD/contract-step.md; pr.sh puts it in the PR body)
#   exit 0  the step passes                (`CONTRACT-GATE: pass <step>`)
#   exit 1  refused, one line per reason   (`CONTRACT-GATE: refused: <why>`)
#   exit 2  could not run (usage, no worktree, unknown step) — callers treat
#           it as refused: fail closed
#
# The SQL is what the branch ADDS under scripts/migrations/*.sql AND under the
# project's migrations_glob.<project> row (cc_sql_added; project-6-os keeps its
# SQL in prisma/sql/). An unreadable row is exit 2. That glob's directory is
# also excluded from the old-shape grep: old migration files are not reads.
#
# expand    every added statement passes bin/check-migration-appliable.sh
#           (additive only). A contract class here is refused.
# migrate   additive SQL only, plus these evidence lines:
#             BACKFILL-COUNTS: before=<n> after=<n>        (integers)
#             OLD-SHAPE-READS: grep=0 query-log=0 window=<h>h
#                              (<h> >= CONTRACT_CHANGE_QUERY_LOG_WINDOW_H)
#             BACKFILL-SCRIPT: <path>   (in the worktree; its first 40 lines
#                              say `idempotent` and `resumable`)
#             OLD-SHAPE: <name>[, <name>...]  (the old table/column names)
#           optional  OLD-SHAPE-WRITERS: <path>[, <path>...]  (files that
#                              still WRITE the old shape until contract)
#           The gate runs the old-shape grep itself and refuses any hit
#           outside the backfill script and the named writers.
# contract  at least one contract statement (bin/lib/contract-change.sh); every
#           other statement (cc_residue_sql) passes check-migration-appliable.sh
#           (no DELETE, TRUNCATE, UPDATE, GRANT or DO beside it); every action
#           inside a contract statement is a contract or additive action
#           (cc_riders_sql: no DISABLE ROW LEVEL SECURITY, OWNER TO ...); and:
#             BACKUP: <ref>       (not empty, not a placeholder)
#             RESTORE-TESTED: <command> -> <scratch db> rc 0
#           The old-shape names (dropped table, dropped column, renamed-from
#           name, plus any OLD-SHAPE: names) must have 0 reads: `git grep -w -i`
#           over tracked files, minus CONTRACT_CHANGE_GREP_EXCLUDE, on the
#           branch AND on <base> (the code production serves: a contract step
#           never removes the last read itself; hotfix-migrate applies it
#           before the merge). On <base>, the last commit that touched a line
#           naming the old shape is at least CONTRACT_CHANGE_QUERY_LOG_WINDOW_H
#           hours old (git log -G). With names, these lines too:
#             OLD-SHAPE-READS: grep=0 query-log=0 window=<h>h
#             optional BACKFILL-SCRIPT: <path>  (excluded from both greps
#                              when it is on <base> with the migrate header)
#
# Knobs (catalog/lanes.d/_lib.contract-change.json, rows
# lib.contract-change[.<project>].<env lowercased>, read through lib_env_apply):
#   CONTRACT_CHANGE_QUERY_LOG_WINDOW_H  fallback 168
#   CONTRACT_CHANGE_GREP_EXCLUDE        fallback scripts/migrations/*,prisma/migrations/*,*.md
set -uo pipefail
PROJECT="${1:-}"; WT="${2:-}"; BASE="${3:-}"; STEP="${4:-}"; EV="${5:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
usage() { echo "CONTRACT-GATE: could not run: $*" ; exit 2; }
[ -n "$PROJECT" ] && [ -n "$BASE" ] || usage "usage: contract-change-gate.sh <project> <worktree> <base> <step> <evidence-file>"
[ -d "$WT" ] && git -C "$WT" rev-parse --git-dir >/dev/null 2>&1 || usage "no git worktree at '$WT'"
case "$STEP" in expand|migrate|contract) ;; *) usage "unknown step '$STEP' (expand|migrate|contract)" ;; esac
. "$HERE/lib/contract-change.sh" 2>/dev/null || usage "bin/lib/contract-change.sh missing"
. "$HERE/lib/migration-files.sh" 2>/dev/null || usage "bin/lib/migration-files.sh missing"
if [ -r "$HERE/lib/lane-gate.sh" ]; then
  # shellcheck source=bin/lib/lane-gate.sh
  . "$HERE/lib/lane-gate.sh" 2>/dev/null && command -v lib_env_apply >/dev/null 2>&1 \
    && lib_env_apply contract-change "$PROJECT" >/dev/null 2>&1
fi
WINDOW_MIN="${CONTRACT_CHANGE_QUERY_LOG_WINDOW_H:-168}"
case "$WINDOW_MIN" in ''|*[!0-9]*) WINDOW_MIN=168 ;; esac
EXCLUDE="${CONTRACT_CHANGE_GREP_EXCLUDE:-scripts/migrations/*,prisma/migrations/*,*.md}"

REFUSED=0
refuse() { echo "CONTRACT-GATE: refused: $*"; REFUSED=1; }

# ev <KEY> — the value of the first `<KEY>: <value>` evidence line (an optional
# `- ` bullet), trimmed. Empty when absent.
EVTXT=""; [ -r "$EV" ] && EVTXT=$(tr -d '\r' < "$EV")
ev() {
  sed -nE "s/^[[:space:]]*(- )?$1:[[:space:]]*(.*[^[:space:]])[[:space:]]*\$/\\2/p" <<<"$EVTXT" | head -1
}
placeholder() {
  case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
    ''|-|todo*|tbd*|n/a|na|none|'<'*'>'|'?'|xxx*|placeholder*) return 0 ;;
  esac
  return 1
}

# The project's migration glob (cc_mig_glob: the migrations_glob.<project> row,
# project-6-os prisma/sql/*.sql) is read IN ADDITION to scripts/migrations/.
# An unreadable row is could-not-run: deciding from the default would hide the
# project's own SQL from every check below (BH-9929 review).
MIG_GLOB=$(cc_mig_glob "$PROJECT") || usage "the migrations_glob.$PROJECT row is unreadable or invalid; the gate cannot see this project's SQL"
SQL_LIST=$(cc_sql_added "$PROJECT" "$BASE" "$WT") || usage "the migrations_glob.$PROJECT row is unreadable; the gate cannot see this project's SQL"
mapfile -t SQL < <(printf '%s\n' "$SQL_LIST" | grep -v '^$')
# Old migration files name the old shape by design: never a read.
case ",$EXCLUDE," in *",${MIG_GLOB%/\*.sql}/*,"*) ;; *) EXCLUDE="$EXCLUDE,${MIG_GLOB%/\*.sql}/*" ;; esac
CLASSES=""
for f in ${SQL[@]+"${SQL[@]}"}; do
  c=$(cc_classify_sql "$WT/$f")
  [ -n "$c" ] && CLASSES="${CLASSES:+$CLASSES
}$c"
done

# _grep_spec <extra-exclude-paths-csv> — sets SPEC, the pathspec of every
# old-shape check: `-- .` minus CONTRACT_CHANGE_GREP_EXCLUDE and the extra
# paths. The exclude knob's globs never match a nested path on their own, so
# `dir/*` becomes `dir/**` and a bare `*.md` becomes `**/*.md`.
_grep_spec() {
  local extra="$1" p
  SPEC=(-- .)
  IFS=',' read -ra pats <<<"$EXCLUDE"
  for p in "${pats[@]}"; do
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    [ -n "$p" ] || continue
    case "$p" in */\*) p="${p%/\*}/**" ;; esac
    case "$p" in */*) ;; *) p="**/$p" ;; esac
    SPEC+=(":(exclude,glob)$p")
  done
  IFS=',' read -ra pats <<<"$extra"
  for p in "${pats[@]}"; do
    p="${p#"${p%%[![:space:]]*}"}"; p="${p%"${p##*[![:space:]]}"}"
    [ -n "$p" ] && SPEC+=(":(exclude,literal)$p")
  done
}

# old_shape_grep <names-csv> <extra-exclude-paths-csv> [<ref>] — one refusal
# per name that still has a read. No <ref>: the branch working tree. With
# <ref> (the contract step passes $BASE): the code main holds, which is the
# code production serves. A contract step that removes the last read in the
# same PR as the drop is refused there: before the merge (hotfix-migrate
# applies before it) and until the deploy, production still runs that read
# (BH-9929 refute review).
old_shape_grep() {
  local names="$1" extra="$2" ref="${3:-}" n hits cnt first where=""
  local -a SPEC
  _grep_spec "$extra"
  IFS=',' read -ra pats <<<"$names"
  for n in "${pats[@]}"; do
    n="${n//[[:space:]]/}"
    [ -n "$n" ] || continue
    if [ -n "$ref" ]; then
      hits=$(git -C "$WT" grep -n -I -w -i -F -e "$n" "$ref" "${SPEC[@]}" 2>/dev/null | sed "s#^$ref:##")
      where=" on $ref (the code production serves; switch the reads and writes in an earlier step, merge it, then open the contract step with migration SQL only)"
    else
      hits=$(git -C "$WT" grep -n -I -w -i -F -e "$n" "${SPEC[@]}" 2>/dev/null)
    fi
    [ -n "$hits" ] || continue
    cnt=$(grep -c . <<<"$hits")
    first=$(head -3 <<<"$hits" | cut -d: -f1-2 | paste -sd' ' -)
    refuse "$cnt read(s) of $n in $first$where"
  done
}

# old_shape_window <names-csv> <extra-exclude-paths-csv> — the old shape must
# have been unread ON $BASE for WINDOW_MIN hours before the contract step
# (ticket Scope 2: the query-log window). The last first-parent commit of
# $BASE whose diff touches a line naming the old shape (git log -G, any case,
# the old_shape_grep pathspec) is the merge that removed the last read. Its
# commit time + WINDOW_MIN hours must be in the past. A name no commit on
# $BASE touches passes. A shallow clone whose oldest visible commit is younger
# than the window cannot prove it: refused (fail closed).
old_shape_window() {
  local names="$1" extra="$2" n line sha ct now age oldest
  local -a SPEC
  _grep_spec "$extra"
  now=$(date +%s)
  IFS=',' read -ra pats <<<"$names"
  for n in "${pats[@]}"; do
    n="${n//[[:space:]]/}"
    [ -n "$n" ] || continue
    line=$(git -C "$WT" log --first-parent --diff-merges=first-parent -s -1 --format='%H %ct' \
             -i -G "$n" "$BASE" "${SPEC[@]}" 2>/dev/null)
    if [ -z "$line" ]; then
      if [ "$(git -C "$WT" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
        oldest=$(git -C "$WT" log --first-parent --format=%ct "$BASE" 2>/dev/null | tail -1)
        case "$oldest" in ''|*[!0-9]*) oldest=$now ;; esac
        [ $(( (now - oldest) / 3600 )) -ge "$WINDOW_MIN" ] \
          || refuse "the clone is shallow and its history of $BASE is shorter than ${WINDOW_MIN}h: the gate cannot prove that $n was unread for the window (deepen the clone)"
      fi
      continue
    fi
    sha=${line%% *}; ct=${line#* }
    case "$ct" in ''|*[!0-9]*) refuse "could not read the commit time of ${sha:0:12} on $BASE"; continue ;; esac
    age=$(( (now - ct) / 3600 ))
    [ "$age" -ge "$WINDOW_MIN" ] \
      || refuse "the last change on $BASE to a line naming $n is ${sha:0:12}, ${age}h ago; the old shape must be unread on $BASE for ${WINDOW_MIN}h (CONTRACT_CHANGE_QUERY_LOG_WINDOW_H) before the contract step"
  done
}

# old_shape_reads_line <step> — the `OLD-SHAPE-READS: grep=0 query-log=0
# window=<h>h` evidence line, with <h> >= WINDOW_MIN.
old_shape_reads_line() {
  local v
  v=$(ev OLD-SHAPE-READS)
  if [[ "$v" =~ ^grep=([0-9]+)[[:space:]]+query-log=([0-9]+)[[:space:]]+window=([0-9]+)h$ ]]; then
    [ "${BASH_REMATCH[1]}" = 0 ] || refuse "OLD-SHAPE-READS reports grep=${BASH_REMATCH[1]}, not 0"
    [ "${BASH_REMATCH[2]}" = 0 ] || refuse "OLD-SHAPE-READS reports query-log=${BASH_REMATCH[2]}, not 0"
    [ "${BASH_REMATCH[3]}" -ge "$WINDOW_MIN" ] || refuse "the query-log window is ${BASH_REMATCH[3]}h, under the ${WINDOW_MIN}h the registry asks for"
  else
    refuse "no OLD-SHAPE-READS: grep=0 query-log=0 window=<h>h line ($1 step)"
  fi
}

case "$STEP" in
  expand)
    for c in $CLASSES; do refuse "expand adds the new shape only; it carries a '$c' change (move it to the contract step)"; break; done
    if [ "${#SQL[@]}" -gt 0 ]; then
      out=$("$HERE/check-migration-appliable.sh" "$PROJECT" "$WT" "${SQL[@]}" 2>&1) \
        || refuse "expand SQL is not additive: $(grep -m1 'FLAGGED' <<<"$out")"
    fi
    ;;
  migrate)
    for c in $CLASSES; do refuse "migrate backfills and switches reads only; it carries a '$c' change (move it to the contract step)"; break; done
    if [ "${#SQL[@]}" -gt 0 ]; then
      out=$("$HERE/check-migration-appliable.sh" "$PROJECT" "$WT" "${SQL[@]}" 2>&1) \
        || refuse "migrate SQL is not additive: $(grep -m1 'FLAGGED' <<<"$out")"
    fi
    v=$(ev BACKFILL-COUNTS)
    [[ "$v" =~ ^before=([0-9]+)[[:space:]]+after=([0-9]+)$ ]] \
      || refuse "no BACKFILL-COUNTS: before=<n> after=<n> line"
    old_shape_reads_line migrate
    SCRIPT=$(ev BACKFILL-SCRIPT)
    if [ -z "$SCRIPT" ]; then
      refuse "no BACKFILL-SCRIPT: <path> line"
    elif [ ! -f "$WT/$SCRIPT" ]; then
      refuse "the backfill script $SCRIPT is not in the worktree"
    else
      head -40 "$WT/$SCRIPT" | grep -qiw idempotent || refuse "the backfill script $SCRIPT does not say 'idempotent' in its header"
      head -40 "$WT/$SCRIPT" | grep -qiw resumable  || refuse "the backfill script $SCRIPT does not say 'resumable' in its header"
    fi
    NAMES=$(ev OLD-SHAPE)
    if [ -z "$NAMES" ]; then refuse "no OLD-SHAPE: <name>[, <name>] line (the names the grep proves unread)"
    else old_shape_grep "$NAMES" "${SCRIPT:+$SCRIPT,}$(ev OLD-SHAPE-WRITERS)"; fi
    ;;
  contract)
    [ -n "$CLASSES" ] || refuse "a contract step must remove the old shape: no contract statement in the added migration SQL (scripts/migrations/*.sql, $MIG_GLOB)"
    # Every other statement of the step must be additive: the lane applies a
    # contract file as a whole, so a DELETE, TRUNCATE, UPDATE, GRANT or DO
    # block beside the contract statement would ride along (BH-9929 review).
    for f in ${SQL[@]+"${SQL[@]}"}; do
      res=$(mktemp "${TMPDIR:-/tmp}/cc-residue.XXXXXX") || { refuse "could not write a scratch file for $f"; continue; }
      if ! cc_residue_sql "$WT/$f" > "$res"; then
        refuse "$f could not be read"
      elif [ -s "$res" ]; then
        out=$("$HERE/check-migration-appliable.sh" "$PROJECT" "$WT" "$res" 2>&1) \
          || refuse "$f carries a statement that is not a contract change and not additive: $(grep -m1 'FLAGGED' <<<"$out" | sed 's/^[^:]*: //')"
      fi
      rm -f "$res"
      # Per ACTION too: a contract ALTER TABLE carries only contract actions
      # and additive ones (cc_riders_sql; BH-9929 review).
      if ! riders=$(cc_riders_sql "$WT/$f"); then refuse "$f could not be read"
      elif [ -n "$riders" ]; then
        refuse "$f carries an action inside a contract statement that is not a contract change and not additive: $(head -1 <<<"$riders" | cut -f2 | head -c 160)"
      fi
    done
    v=$(ev BACKUP)
    if [ -z "$v" ]; then refuse "no BACKUP: line"
    elif placeholder "$v"; then refuse "BACKUP: '$v' is a placeholder, not a backup reference"; fi
    v=$(ev RESTORE-TESTED)
    if [ -z "$v" ]; then refuse "no RESTORE-TESTED: line"
    elif ! [[ "$v" =~ ^(.*[^[:space:]])[[:space:]]+-\>[[:space:]]+([^[:space:]].*[^[:space:]]|[^[:space:]])[[:space:]]+rc[[:space:]]+0$ ]]; then
      refuse "RESTORE-TESTED: '$v' is not '<command> -> <scratch db> rc 0'"
    elif placeholder "${BASH_REMATCH[1]}" || placeholder "${BASH_REMATCH[2]}"; then
      refuse "RESTORE-TESTED: '$v' names a placeholder"
    fi
    NAMES=$(for f in ${SQL[@]+"${SQL[@]}"}; do cc_old_names "$WT/$f"; done | sort -u | paste -sd, -)
    X=$(ev OLD-SHAPE); [ -n "$X" ] && NAMES="${NAMES:+$NAMES,}$X"
    if [ -n "$NAMES" ]; then
      # The migrate step's backfill script names the old shape by design and
      # production never serves it: excluded when it is on $BASE and its
      # header says idempotent and resumable (the migrate step's rule).
      BF=$(ev BACKFILL-SCRIPT)
      if [ -n "$BF" ]; then
        BF_HEAD=""
        git -C "$WT" cat-file -e "$BASE:$BF" 2>/dev/null \
          && BF_HEAD=$(git -C "$WT" show "$BASE:$BF" 2>/dev/null | sed -n '1,40p')
        if [ -n "$BF_HEAD" ] \
           && grep -qiw idempotent <<<"$BF_HEAD" \
           && grep -qiw resumable <<<"$BF_HEAD"; then :
        else refuse "BACKFILL-SCRIPT: $BF is not a backfill script on $BASE (the migrate step merges it, its header says idempotent and resumable)"; BF=""; fi
      fi
      old_shape_grep "$NAMES" "$BF"
      old_shape_grep "$NAMES" "$BF" "$BASE"
      old_shape_window "$NAMES" "$BF"
      old_shape_reads_line contract
    fi
    ;;
esac

if [ "$REFUSED" = 1 ]; then exit 1; fi
echo "CONTRACT-GATE: pass $STEP${CLASSES:+ (classes: $(sort -u <<<"$CLASSES" | paste -sd, -))}"
exit 0
