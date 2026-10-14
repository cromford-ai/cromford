#!/bin/bash
# bin/schema-build.sh [--root <dir>] [--worker <name>] [--write|--check|--to <path>]
#                      [--ref <rev> --worker <name> [--to <path>]]
#
# Compose worker/<w>/schema.sql from worker/<w>/schema.d/: every fragment, named
# NNNN-<name>.sql or <yyyymmddhhmm>-<ticket-key>-<name>.sql, sorted by name under
# LC_ALL=C and concatenated with plain `cat` — no banner, no separator, so the
# render is exactly the bytes of the fragments in order.
#
# NEW FRAGMENTS ARE NAMED BY TICKET KEY (BH-5788). A picked "next free" NNNN
# collides with the next build's pick: main held two 0022 fragments on
# 2026-10-14. A new fragment is <yyyymmddhhmm>-<ticket-key>-<name>.sql: the key
# makes the name unique, and the UTC minute the builder creates it is the order
# key, so the same name sort puts every NNNN fragment first and then the new
# ones in creation order. The rules-pack builtin rp_schema_fragment_name refuses
# a new NNNN fragment whose number the base already has, and a stamp that is
# not later than the base's newest stamp.
#
# WHY (BH-4987). docs/CONFLICT_HOTSPOTS.md (BH-4986) ranked
# worker/jobs/schema.sql the top conflict hotspot in this repo: every new table
# went at its EOF, so any two builds that each added one collided on the same
# hunk. A new table is now one NEW file, worker/jobs/schema.d/NNNN-<name>.sql,
# plus `bin/schema-build.sh --write`. Two builds adding two tables touch no
# common source file.
#
# schema.sql IS NOT IN GIT (BH-6005). worker/jobs/schema.sql is the render of
# schema.d/ and is git-ignored (.gitignore). A committed render was the top
# conflict left after the split: two branches that each added one fragment both
# re-rendered it, and on 2026-10-11 that parked 8 approved PRs for up to 1,300
# minutes. Every reader composes it where it reads it: bin/harness-sync.sh's
# deploy (`--to` into its snapshot), CI and the lints (`--ref` for a base
# revision), and the test corpus (tests/lib/jobs-schema.sh,
# worker/jobs/test/lib/jobs-schema.js).
# --check refuses the ignored render coming back into git; a working copy that
# differs from the fragments is a stale local render, a note and never an error.
#
# VALIDATION runs before any write and in --check; each failure prints
# `<path>: <reason>`:
#   * every entry in schema.d/ is a file named
#     ^([0-9]{4}|[0-9]{12})-[a-z0-9][a-z0-9_-]*\.sql$
#     (a stray README, x.sql.bak or subdirectory is an error, never skipped)
#   * every fragment is non-empty and ends in a newline (otherwise its last
#     `-- comment` line would swallow the next fragment's first statement)
#   * every fragment holds whole statements: the statement counts of the
#     fragments, split by bin/lib/d1-schema.sh (the splitter the D1 apply uses),
#     add up to the count of the composition
#   * schema.d/ holds at least one fragment
# A worker with no schema.d/ (worker/watchdog today) is skipped,
# said on stderr, and is never an error.
#
#   --write         rewrite worker/<w>/schema.sql (atomically, only when the
#                   bytes differ); refuses, rc 1, when that would delete a
#                   statement no fragment holds (see NO STATEMENT IS EVER DROPPED)
#   --check         validate, then, by how git holds worker/<w>/schema.sql:
#                   tracked AND ignored -> rc 1, it must not be in git;
#                   untracked and ignored -> rc 0 (a differing working copy is a
#                   one-line stale-render note); anything else (a tracked render,
#                   a non-git tree) -> compare with the file, rc 1 when they differ
#   --to <path>     write the composition to <path> (one worker only)
#   (none)          print the composition on stdout (one worker only)
#   --worker <name> only worker/<name> (default: every worker with a schema.d/)
#   --root <dir>    the repo root (default: this script's repo)
#   --ref <rev>     compose worker/<w>/schema.d as it is at git revision <rev>
#                   (print or --to only, needs --worker); rc 2 when <rev> has
#                   no worker/<w>/schema.d
#
# Exit: 0 OK, 1 a check or validation failure, 2 a usage or setup error.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
MODE=print
TO=""
REF=""
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --root)    [ $# -ge 2 ] || { echo "schema-build.sh: --root needs a directory" >&2; exit 2; }; ROOT="$2"; shift 2 ;;
    --worker)  [ $# -ge 2 ] || { echo "schema-build.sh: --worker needs a name" >&2; exit 2; }; ONLY="$2"; shift 2 ;;
    --write)   MODE=write; shift ;;
    --check)   MODE=check; shift ;;
    --ref)     [ $# -ge 2 ] || { echo "schema-build.sh: --ref needs a revision" >&2; exit 2; }; REF="$2"; shift 2 ;;
    --to)      [ $# -ge 2 ] || { echo "schema-build.sh: --to needs a path" >&2; exit 2; }; MODE=to; TO="$2"; shift 2 ;;
    -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
    *)         echo "schema-build.sh: unexpected argument $1" >&2; exit 2 ;;
  esac
done

# shellcheck source=bin/lib/d1-schema.sh
. "$HERE/lib/d1-schema.sh" || exit 2

ROOT=$(cd "$ROOT" 2>/dev/null && pwd) || { echo "schema-build.sh: --root is not a directory" >&2; exit 2; }
export LC_ALL=C
REF_USAGE="usage: schema-build.sh --ref <rev> --worker <name> [--to <path>]"
[ -z "$REF" ] || [ "$MODE" = print ] || [ "$MODE" = to ] \
  || { echo "schema-build.sh: --ref works only in print mode or with --to ($REF_USAGE)" >&2; exit 2; }
[ -z "$REF" ] || [ -n "$ONLY" ] \
  || { echo "schema-build.sh: --ref needs exactly one worker — name it with --worker ($REF_USAGE)" >&2; exit 2; }

WORKERS=()
if [ -n "$ONLY" ]; then
  case "$ONLY" in */*|.|..) echo "schema-build.sh: --worker wants a name, got $ONLY" >&2; exit 2 ;; esac
  [ -n "$REF" ] || [ -d "$ROOT/worker/$ONLY" ] || { echo "schema-build.sh: no worker/$ONLY under $ROOT" >&2; exit 2; }
  WORKERS=("$ONLY")
else
  for d in "$ROOT"/worker/*/; do
    [ -d "$d" ] || continue
    d="${d%/}"; WORKERS+=("${d##*/}")
  done
fi

TMP=$(mktemp -d "${TMPDIR:-/tmp}/schema-build.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# --ref <rev> (BH-6005): compose worker/<w>/schema.d as it is at <rev>, not as
# it is in the working tree. git archive reads only that commit's tree, so it
# works at a depth-1 FETCH_HEAD too. SRC_ROOT is where compose() reads from.
SRC_ROOT="$ROOT"
if [ -n "$REF" ]; then
  mkdir -p "$TMP/ref"
  if ! git -C "$ROOT" archive "$REF" "worker/$ONLY/schema.d" 2>/dev/null | tar -x -C "$TMP/ref" 2>/dev/null \
     || [ ! -d "$TMP/ref/worker/$ONLY/schema.d" ]; then
    echo "schema-build.sh: $REF has no worker/$ONLY/schema.d" >&2; exit 2
  fi
  SRC_ROOT="$TMP/ref"
fi

# nstmts <file> — how many statements bin/lib/d1-schema.sh splits <file> into.
nstmts() { d1_schema_statements "$1" | tr -cd '\000' | wc -c; }

# compose <worker> <out> — validate worker/<w>/schema.d/ and write the
# composition to <out>. rc 0 valid, 1 invalid (every reason printed).
compose() {
  local w="$1" out="$2" src="$SRC_ROOT/worker/$1/schema.d" rel="worker/$1/schema.d"
  local f name bad=0 sum=0 n
  local -a frags=()
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    f="$src/$name"
    if [ -d "$f" ] || [ ! -f "$f" ]; then
      echo "$rel/$name: not a fragment file (schema.d/ holds only fragment .sql files)" >&2; bad=1; continue
    fi
    if ! [[ $name =~ ^([0-9]{4}|[0-9]{12})-[a-z0-9][a-z0-9_-]*\.sql$ ]]; then
      echo "$rel/$name: not a fragment name (want <yyyymmddhhmm>-<ticket-key>-<name>.sql or NNNN-<name>.sql, lower case)" >&2; bad=1; continue
    fi
    if [ ! -s "$f" ]; then
      echo "$rel/$name: empty fragment" >&2; bad=1; continue
    fi
    if [ "$(tail -c 1 "$f" | od -An -tx1 | tr -d ' \n')" != 0a ]; then
      echo "$rel/$name: does not end in a newline" >&2; bad=1; continue
    fi
    frags+=("$f")
  done < <(find "$src" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
  if [ "$bad" = 0 ] && [ "${#frags[@]}" = 0 ]; then
    echo "$rel: no fragment (want at least one NNNN-<name>.sql)" >&2; return 1
  fi
  [ "$bad" = 0 ] || return 1
  cat "${frags[@]}" > "$out"
  for f in "${frags[@]}"; do
    n=$(nstmts "$f"); sum=$((sum + n))
  done
  n=$(nstmts "$out")
  if [ "$sum" != "$n" ]; then
    echo "$rel: fragments must hold whole statements — they split into $sum statements one by one and $n composed (a statement starts in one fragment and ends in the next)" >&2
    return 1
  fi
  return 0
}

# NO STATEMENT IS EVER DROPPED (BH-4987 lead review). --write renders schema.sql
# from the fragments alone, so a statement that lives only in schema.sql would
# be deleted by it. That is exactly what a branch cut before the split carries:
# it appended its CREATE TABLE to schema.sql, merges main cleanly, and the
# conductor's regenerate (mc_regen_generated, a batch train's --theirs plus
# --write) would commit the table away; CI's --check is then green and the
# table is never created in prod. So --write REFUSES (rc 1, schema.sql untouched)
# and names each such statement. Refusing, not moving it into a new fragment:
# a branch that EDITED a statement (a column added to a CREATE TABLE) would get
# a second CREATE TABLE IF NOT EXISTS that D1 silently skips, and the edit would
# be lost all the same. A person moves it, once.
#
# A statement must be in a fragment ("known") when it is
#   * in the schema.sql being replaced (a hand edit, or a merge that brought a
#     pre-split branch's table in), or
#   * added to schema.sql by a non-merge commit of HEAD (or MERGE_HEAD) that is
#     not on origin/main, and not removed again by one: a merge resolved by
#     taking the other side has already lost it from the working file.
#     A merge commit counts as removing a statement only when its first
#     parent's fragments held it: that merge edited a fragment (BH-5918, #5892,
#     where a merge edited a table a pre-split commit had added). A merge that
#     drops a statement no fragment held (a --theirs resolution) does not.
# Known = the fragments being composed, plus the fragments at HEAD, its parents
# and MERGE_HEAD, so a fragment edit (the old text is in HEAD's fragments) is
# never refused. A commit's statements also count as known when that commit's
# own fragments hold them (the normal post-split commit: fragment plus render).
#
# AN EARLIER RENDER IS NOT A HAND EDIT (BH-4987 lead review r3). Edit a fragment,
# --write, edit it again, --write: the working schema.sql still holds the FIRST
# edit's text, which is in no fragment any more and not in HEAD's. Counting it
# as lost refused the normal edit loop, and the builder who obeyed the message
# added the old text back as a second CREATE TABLE IF NOT EXISTS that D1 runs
# first, so the edit was lost with no error. So --write records the bytes it
# wrote (a cksum in this checkout's git dir). While the working file still
# equals that record, a working-file statement counts as lost only if HEAD or
# MERGE_HEAD committed it in schema.sql; the branch history check is unchanged.
# Any other change to the file (a hand edit, a merge) gets the full check.

# stmt_lines <file> — its statements, one a line (newlines inside one are \001).
stmt_lines() { d1_schema_statements "$1" | tr '\n\000' '\001\n'; }

# obj_lines <rev:path> — stmt_lines of a blob, or of every fragment in a tree,
# cached by object id. Prints nothing for a path the revision does not have.
obj_lines() {
  local id f n
  id=$(git -C "$ROOT" rev-parse -q --verify "$1" 2>/dev/null) || return 0
  f="$TMP/obj.$id"
  if [ ! -f "$f" ]; then
    case "$(git -C "$ROOT" cat-file -t "$id" 2>/dev/null)" in
      blob) git -C "$ROOT" cat-file blob "$id" > "$f.raw"; stmt_lines "$f.raw" > "$f" ;;
      tree) while IFS= read -r n; do obj_lines "$id:$n"; done \
              < <(git -C "$ROOT" ls-tree --name-only "$id" | grep '\.sql$') > "$f" ;;
      *) : > "$f" ;;
    esac
  fi
  cat "$f"
}

# last_render <worker> — the file where --write records the cksum of the
# schema.sql it wrote; rc 1 outside a git checkout (no record, full check).
last_render() {
  [ "$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" = "$ROOT" ] || return 1
  git -C "$ROOT" rev-parse --path-format=absolute --git-path "schema-build/$1.last" 2>/dev/null
}

# own_render <worker> — rc 0 when worker/<w>/schema.sql is still the bytes the
# last --write in this checkout wrote.
own_render() {
  local f
  f=$(last_render "$1") && [ -s "$f" ] && [ -f "$ROOT/worker/$1/schema.sql" ] || return 1
  [ "$(cksum < "$ROOT/worker/$1/schema.sql")" = "$(cat "$f")" ]
}

# tracked_state <worker> — how git holds worker/<w>/schema.sql: tracked-ignored
# (an ignored render was added back), untracked-ignored (the BH-6005 shape), or
# other (a tracked render, or no git here). --no-index: check-ignore must answer
# for a path the index holds too.
tracked_state() {
  local p="worker/$1/schema.sql" t=0 i=0
  # Physical paths on both sides: a relative ROOT, a symlinked one or a trailing
  # slash is the same tree, and a byte compare would call it `other`.
  local top phys
  top=$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null) && top=$(cd "$top" 2>/dev/null && pwd -P) || top=""
  phys=$(cd "$ROOT" 2>/dev/null && pwd -P) || phys=""
  [ -n "$top" ] && [ "$top" = "$phys" ] || { echo other; return 0; }
  git -C "$ROOT" ls-files --error-unmatch -- "$p" >/dev/null 2>&1 && t=1
  git -C "$ROOT" check-ignore -q --no-index -- "$p" 2>/dev/null && i=1
  if [ "$i" = 1 ] && [ "$t" = 1 ]; then echo tracked-ignored
  elif [ "$i" = 1 ]; then echo untracked-ignored
  else echo other; fi
}

# unfragmented <worker> <composition> — print `<statement's first line>\t<where>`
# for each statement --write would lose; rc 0 when there is none.
unfragmented() {
  local w="$1" comp="$2" sql="worker/$1/schema.sql" frd="worker/$1/schema.d"
  local k="$TMP/$w.known" cd="$TMP/$w.cand" ch="$TMP/$w.hist" gone="$TMP/$w.removed" r c
  local -a sides=()
  stmt_lines "$comp" > "$k"
  : > "$cd"; : > "$ch"; : > "$gone"
  # An ignored, untracked render is a local copy, never a source (BH-6005): its
  # statements are an earlier render's, so they are not candidates. What a
  # commit put in schema.sql (HEAD, MERGE_HEAD, this branch) is still checked.
  [ -f "$ROOT/$sql" ] && [ "${TSTATE:-other}" != untracked-ignored ] && stmt_lines "$ROOT/$sql" > "$cd"
  if own_render "$w"; then
    # Our own earlier render: only what a commit put in schema.sql can be lost.
    for r in HEAD MERGE_HEAD; do obj_lines "$r:$sql"; done | sort -u > "$TMP/$w.committed"
    sort -u "$cd" | comm -12 - "$TMP/$w.committed" > "$cd.own"; mv "$cd.own" "$cd"
  fi
  if [ "$(git -C "$ROOT" rev-parse --show-toplevel 2>/dev/null)" = "$ROOT" ] \
     && git -C "$ROOT" rev-parse -q --verify HEAD >/dev/null 2>&1; then
    sides=(HEAD)
    git -C "$ROOT" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && sides+=(MERGE_HEAD)
    for r in "${sides[@]}" $(git -C "$ROOT" rev-parse 'HEAD^@' 2>/dev/null); do
      obj_lines "$r:$frd" >> "$k"
    done
    # --full-history: a merge that took the other side's schema.sql is TREESAME
    # to that side, and default simplification would then skip the very branch
    # commit that added the lost statement.
    if git -C "$ROOT" rev-parse -q --verify origin/main >/dev/null 2>&1; then
      while IFS= read -r c; do
        [ -n "$c" ] || continue
        obj_lines "$c:$sql" | sort -u > "$TMP/now"
        obj_lines "$c^:$sql" | sort -u > "$TMP/was"
        obj_lines "$c:$frd" | sort -u > "$TMP/frags"
        comm -23 "$TMP/now" "$TMP/was" | comm -23 - "$TMP/frags" | awk -v c="${c:0:12}" '{ print $0 "\002" c }' >> "$ch"
        comm -13 "$TMP/now" "$TMP/was" >> "$gone"
      done < <(git -C "$ROOT" rev-list --full-history --no-merges "${sides[@]}" ^origin/main -- "$sql" 2>/dev/null)
      # A merge that edited a fragment removed the old text (BH-5918); one that
      # dropped text no fragment of its first parent held (--theirs) did not.
      while IFS= read -r c; do
        [ -n "$c" ] || continue
        obj_lines "$c:$sql" | sort -u > "$TMP/now"
        obj_lines "$c^:$sql" | sort -u > "$TMP/was"
        obj_lines "$c^:$frd" | sort -u > "$TMP/frags"
        comm -13 "$TMP/now" "$TMP/was" | comm -12 - "$TMP/frags" >> "$gone"
      done < <(git -C "$ROOT" rev-list --full-history --merges "${sides[@]}" ^origin/main -- "$sql" 2>/dev/null)
    fi
  fi
  awk -v k="$k" -v rmf="$gone" -v cd="$cd" -v sql="$sql" '
    function first(s) { sub(/\001.*/, "", s); return s }
    FILENAME == k   { known[$0]; next }
    FILENAME == rmf { gone[$0]; next }
    FILENAME == cd  { if (!($0 in known) && !seen[$0]++) { print first($0) "\tin the working file"; n++ } next }
    {
      split($0, p, "\002")
      if ((p[1] in known) || (p[1] in gone) || seen[p[1]]++) next
      print first(p[1]) "\tadded to " sql " by " p[2] " on this branch"; n++
    }
    END { exit n > 0 }
  ' "$k" "$gone" "$cd" "$ch"
}

# report_unfragmented <worker> <list> — the refusal, one line a statement.
report_unfragmented() {
  local w="$1" s where
  while IFS=$'\t' read -r s where; do
    echo "worker/$w/schema.sql: \`$s\` ($where) is in no fragment under worker/$w/schema.d/, so --write would delete it — move it into worker/$w/schema.d/NNNN-<name>.sql and run bin/schema-build.sh --write again. If it is an older text of a statement a fragment already holds, do not add it back: edit that fragment (a second CREATE TABLE IF NOT EXISTS is skipped by D1, so the edit would be lost)" >&2
  done < "$2"
}

DONE=()
rc=0
for w in "${WORKERS[@]}"; do
  if [ ! -d "$SRC_ROOT/worker/$w/schema.d" ]; then
    echo "schema-build.sh: worker/$w has no schema.d/ — skipped" >&2; continue
  fi
  out="$TMP/$w.sql"
  compose "$w" "$out" || { rc=1; continue; }
  DONE+=("$w")
  dst="$ROOT/worker/$w/schema.sql"
  TSTATE=other
  case "$MODE" in write|check) TSTATE=$(tracked_state "$w") ;; esac
  case "$MODE" in
    write)
      # Before the equal-bytes shortcut: in the batch-train shape the working
      # file already equals the render and the lost statement is only in history.
      if ! unfragmented "$w" "$out" > "$TMP/$w.lost"; then
        report_unfragmented "$w" "$TMP/$w.lost"; rc=1; continue
      fi
      if ! { [ -f "$dst" ] && cmp -s "$out" "$dst"; }; then
        new=$(mktemp "$ROOT/worker/$w/.schema.sql.XXXXXX")
        cat "$out" > "$new"
        if [ -f "$dst" ]; then chmod --reference="$dst" "$new"; else chmod 644 "$new"; fi
        mv -f "$new" "$dst"
        echo "schema-build.sh: wrote worker/$w/schema.sql" >&2
      fi
      # The record own_render reads. Best effort: no record means a full check.
      if lr=$(last_render "$w"); then
        mkdir -p "${lr%/*}" 2>/dev/null && cksum < "$dst" > "$lr" 2>/dev/null || :
      fi ;;
    check)
      if [ "$TSTATE" = tracked-ignored ]; then
        echo "worker/$w/schema.sql is generated and git-ignored — it must not be in git: git rm --cached worker/$w/schema.sql (schema.sql is not in git; add or edit a fragment under worker/$w/schema.d/)" >&2
        rc=1; continue
      fi
      if [ "$TSTATE" = untracked-ignored ]; then
        if [ -f "$dst" ] && ! cmp -s "$out" "$dst"; then
          echo "worker/$w/schema.sql is a stale local render — bin/schema-build.sh --write refreshes it (not an error)" >&2
        fi
        continue
      fi
      if ! [ -f "$dst" ] || ! cmp -s "$out" "$dst"; then
        echo "worker/$w/schema.sql is generated from worker/$w/schema.d/ — add or edit a fragment there and run bin/schema-build.sh --write; do not edit schema.sql directly" >&2
        unfragmented "$w" "$out" > "$TMP/$w.lost" || report_unfragmented "$w" "$TMP/$w.lost"
        rc=1
      fi ;;
  esac
done

case "$MODE" in
  print|to)
    [ "$rc" = 0 ] || exit "$rc"
    [ "${#DONE[@]}" -le 1 ] || { echo "schema-build.sh: ${#DONE[@]} workers have a schema.d/ — name one with --worker" >&2; exit 2; }
    [ "${#DONE[@]}" = 1 ] || exit 0
    if [ "$MODE" = print ]; then cat "$TMP/${DONE[0]}.sql"; else cat "$TMP/${DONE[0]}.sql" > "$TO"; fi ;;
esac
exit "$rc"
