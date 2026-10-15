# shellcheck shell=bash
# bin/lib/schema-restamp.sh — RESTAMP A PR'S STALE SCHEMA FRAGMENTS AT QUEUE
# TIME, AND PROVE A COMMIT DID ONLY THAT (BH-6842). Sourced, never run. Pure
# git and python3 -I: no model, no network, no root of its own (every input is
# an argument).
#
# WHY. The rules pack's schema-fragment-name check (rp_schema_fragment_name,
# bin/lib/rules-pack-checks.sh) wants a new stamp-form fragment
# worker/<w>/schema.d/<yyyymmddhhmm>-<key>-<name>.sql to sort AFTER every stamp
# fragment of that worker at the base. A stamp taken at build time goes stale
# whenever another schema PR merges first: #6785 paid two fix rounds and two
# lead reviews on 2026-10-15 for renames that changed no SQL. The merge
# conductor now renames the fragment just before it queues the PR
# (bin/lib/mc-prequeue.d/restamp.sh), and the lead carry accepts that commit.
#
#   sr_plan <git-dir> <main-ref> <head-ref>
#     `old<TAB>new` repo paths, one line per rename, rc 0. Empty = nothing is
#     stale. Per worker/<w>/schema.d/ with PR-added stamp fragments (added since
#     the merge-base): when ANY of them is not later than the newest stamp
#     fragment at <main-ref>, ALL of them are renamed, in their LC_ALL=C order,
#     to consecutive minutes from max(now, newest + 1 minute), so the PR's own
#     order holds. NNNN fragments are never renamed. The clock is the UTC
#     minute; SR_NOW_EPOCH overrides it (the test seam). rc 2 and one stderr
#     line when it cannot tell, or when a new name already exists at main or at
#     the head, or equals another fragment's old name.
#   sr_top <git-dir> <main-ref>
#     the 12-digit stamp of the newest stamp fragment at <main-ref> over every
#     worker, or nothing.
#   sr_apply <worktree> <main-ref>
#     sr_plan on the worktree's HEAD, then `git mv` each pair, rewrite the old
#     basenames to the new ones (fixed strings) in every tracked text file
#     `git grep` finds outside worker/*/schema.d/ (a fragment's bytes never
#     change), and commit ONE commit "restamp schema fragments (no SQL change)"
#     with a `Restamped: <old> -> <new>` body line per pair. Prints the new sha.
#     rc 0 committed | 1 nothing to do | 2 failed (the caller drops the worktree).
#   sr_commit_only <git-dir> <commit>
#     rc 0 only when <commit> has one parent and its tree diff is, with -M100%:
#     at least one R100 rename inside one worker/<w>/schema.d/ between two stamp
#     names with the same `-<key>-<name>.sql` suffix and the same mode, plus M
#     lines outside schema.d whose parent blob, with every old->new basename of
#     those renames replaced, is byte-equal to the child blob. Anything else
#     (A, D, T, C, R<100, a mode change, a binary, a git failure) is rc 1.
#   restamp_same <git-dir> <main-ref> <reviewed> <head>
#     prints `restamp`, rc 0, when <reviewed> is an ancestor of <head> and every
#     commit in `head ^reviewed ^main` is a clean main merge (_ps_clean_merge,
#     bin/lib/patch-same.sh) or sr_commit_only, with at least one restamp. rc 1
#     otherwise. Conservative like patch_same: it never says "close enough".
#   sr_stamp_order_line <line>
#     rc 0 when the line is the rules pack's stamp-order finding, and only that
#     one: the NNNN-taken and malformed-name lines of the same check are not.
#   sr_stamp_split <in> <real-out> <note-out>
#     every non-blank line of <in> to <note-out> when sr_stamp_order_line, else
#     to <real-out> (the rev_env_split shape). rc 1 when <in> is unreadable.

# The rules pack's stamp form (rp_schema_fragment_name), the same regex.
SR_STAMP_RE='^(20[2-9][0-9])(0[1-9]|1[0-2])(0[1-9]|[12][0-9]|3[01])([01][0-9]|2[0-3])[0-5][0-9]-[a-z]+-[0-9]+-[a-z0-9][a-z0-9_-]*\.sql$'
SR_DIR_RE='^worker/[^/]+/schema\.d$'
SR_SUBJECT='restamp schema fragments (no SQL change)'
_sr_dir="${BASH_SOURCE[0]%/*}"

_sr_say() { printf 'schema-restamp: %s\n' "$*" >&2; }

_sr_sha() { # <git-dir> <rev> -> the full commit sha
  local s
  s=$(git -C "$1" rev-parse --verify --quiet "$2^{commit}" 2>/dev/null) || return 1
  [[ "$s" =~ ^[0-9a-f]{40}$ ]] || return 1
  printf '%s' "$s"
}

# _sr_now -> the current UTC minute, as an epoch at :00
_sr_now() {
  local e="${SR_NOW_EPOCH:-}"
  [[ "$e" =~ ^[0-9]+$ ]] || e=$(date -u +%s)
  printf '%s' "$(( e / 60 * 60 ))"
}
_sr_epoch() { date -u -d "${1:0:4}-${1:4:2}-${1:6:2} ${1:8:2}:${1:10:2}" +%s 2>/dev/null; }
_sr_stamp() { date -u -d "@$1" +%Y%m%d%H%M 2>/dev/null; }

# _sr_tops <git-dir> <main-ref> -> `<dir><TAB><newest stamp basename>` per dir
_sr_tops() {
  git -C "$1" ls-tree -r --name-only "$2" -- worker/ 2>/dev/null | while IFS= read -r p; do
    [[ ${p%/*} =~ $SR_DIR_RE ]] && [[ ${p##*/} =~ $SR_STAMP_RE ]] && printf '%s\t%s\n' "${p%/*}" "${p##*/}"
  done | LC_ALL=C sort | awk -F'\t' '{t[$1] = $2} END {for (d in t) print d "\t" t[d]}' | LC_ALL=C sort
}

sr_top() {
  [ -n "${1:-}" ] && [ -n "${2:-}" ] || return 1
  _sr_tops "$1" "$2" | cut -f2 | cut -c1-12 | LC_ALL=C sort | tail -n 1
}

sr_plan() {
  local g="${1:-}" main head mb added tops d top s stale start i old new olds out="" line
  local -a dirs=() frags=()
  [ -n "$g" ] || return 2
  main=$(_sr_sha "$g" "${2:-}") || { _sr_say "main ref '${2:-}' does not resolve"; return 2; }
  head=$(_sr_sha "$g" "${3:-}") || { _sr_say "head ref '${3:-}' does not resolve"; return 2; }
  mb=$(git -C "$g" merge-base "$main" "$head" 2>/dev/null) || { _sr_say "no merge-base of ${main:0:12} and ${head:0:12}"; return 2; }
  added=$(git -C "$g" diff --no-renames --name-only --diff-filter=A "$mb" "$head" -- 'worker/*/schema.d/*' 2>/dev/null) \
    || { _sr_say "the PR's added fragments could not be listed"; return 2; }
  added=$(while IFS= read -r line; do
            [[ ${line%/*} =~ $SR_DIR_RE ]] && [[ ${line##*/} =~ $SR_STAMP_RE ]] && printf '%s\n' "$line"
          done <<<"$added" | LC_ALL=C sort)
  [ -n "$added" ] || return 0
  tops=$(_sr_tops "$g" "$main")
  mapfile -t dirs < <(cut -d/ -f1-3 <<<"$added" | LC_ALL=C sort -u)
  for d in "${dirs[@]}"; do
    top=$(awk -F'\t' -v d="$d" '$1 == d {print substr($2, 1, 12)}' <<<"$tops")
    [ -n "$top" ] || continue
    mapfile -t frags < <(awk -v d="$d/" 'index($0, d) == 1' <<<"$added")
    stale=0
    for s in "${frags[@]}"; do
      s=${s##*/}
      [[ "${s:0:12}" > "$top" ]] || stale=1   # sr-stale-compare: not later than main's newest is stale
    done
    [ "$stale" = 1 ] || continue
    start=$(_sr_now); s=$(_sr_epoch "$top") || s=""
    [[ "$s" =~ ^[0-9]+$ ]] || { _sr_say "$d: the stamp $top is not a UTC minute date can read"; return 2; }
    [ $(( s + 60 )) -gt "$start" ] && start=$(( s + 60 ))
    olds=$(printf '%s\n' "${frags[@]##*/}")
    i=0
    for old in "${frags[@]}"; do
      new="$d/$(_sr_stamp $(( start + 60 * i )))${old:${#d}+13}"
      i=$((i + 1))
      [ "$new" = "$old" ] && continue
      if grep -qxF -- "${new##*/}" <<<"$olds"; then
        _sr_say "$old: the new name ${new##*/} is another of this PR's fragments; rename by hand"; return 2
      fi
      if git -C "$g" cat-file -e "$main:$new" 2>/dev/null || git -C "$g" cat-file -e "$head:$new" 2>/dev/null; then
        _sr_say "$old: the new name $new already exists at main or at the head"; return 2
      fi
      out+="$old"$'\t'"$new"$'\n'
    done
  done
  printf '%s' "$out"
}

# _sr_py_replace <mode> <pairs-file> <file...>
#   mode rewrite: replace every old basename with its new one in each file, one
#   pass, fixed strings. mode equal: rc 0 when replace(<file1>) == <file2> and
#   neither has a NUL byte. The pairs file is `old<TAB>new` basenames.
_sr_py_replace() {
  python3 -I -c '
import re, sys
mode, pairs, files = sys.argv[1], sys.argv[2], sys.argv[3:]
m = {}
for ln in open(pairs, encoding="utf-8"):
    ln = ln.rstrip("\n")
    if ln:
        o, n = ln.split("\t")
        m[o.encode()] = n.encode()
if not m:
    sys.exit(1)
rx = re.compile(b"|".join(re.escape(k) for k in sorted(m, key=len, reverse=True)))
sub = lambda b: rx.sub(lambda x: m[x.group(0)], b)
if mode == "rewrite":
    for f in files:
        with open(f, "rb") as fh:
            b = fh.read()
        nb = sub(b)
        if nb != b:
            with open(f, "wb") as fh:
                fh.write(nb)
    sys.exit(0)
a, b = (open(f, "rb").read() for f in files[:2])
sys.exit(0 if b"\0" not in a and b"\0" not in b and sub(a) == b else 1)
' "$@"
}

sr_apply() {
  local wt="${1:-}" main="${2:-}" plan rc=0 old new pf files f body="" old_head
  [ -n "$wt" ] && [ -n "$main" ] || return 2
  plan=$(sr_plan "$wt" "$main" HEAD) || rc=$?
  [ "$rc" = 0 ] || return 2
  [ -n "$plan" ] || return 1
  old_head=$(_sr_sha "$wt" HEAD) || return 2
  pf=$(mktemp "${TMPDIR:-/tmp}/sr-pairs.XXXXXX") || return 2
  while IFS=$'\t' read -r old new; do
    [ -n "$old" ] || continue
    git -C "$wt" mv -- "$old" "$new" >/dev/null 2>&1 || { _sr_say "git mv $old $new failed"; rm -f "$pf"; return 2; }
    printf '%s\t%s\n' "${old##*/}" "${new##*/}" >> "$pf"
    body+="Restamped: ${old##*/} -> ${new##*/}"$'\n'
  done <<<"$plan"
  files=$(cut -f1 "$pf" | while IFS= read -r old; do
            git -C "$wt" grep -l -I -F -e "$old" -- . ':(exclude,glob)worker/*/schema.d/**' 2>/dev/null
          done | LC_ALL=C sort -u)
  if [ -n "$files" ]; then
    local -a abs=()
    while IFS= read -r f; do abs+=("$wt/$f"); done <<<"$files"
    _sr_py_replace rewrite "$pf" "${abs[@]}" || { _sr_say "the reference rewrite failed"; rm -f "$pf"; return 2; }
    while IFS= read -r f; do git -C "$wt" add -- "$f" >/dev/null 2>&1 || { rm -f "$pf"; return 2; }; done <<<"$files"
  fi
  rm -f "$pf"
  git -C "$wt" -c "user.name=${MC_GIT_NAME:-${HARNESS_MERGE_GIT_NAME:-box}}" \
      -c "user.email=${MC_GIT_EMAIL:-${HARNESS_GIT_EMAIL:-box@users.noreply.github.com}}" \
      -c commit.gpgsign=false commit -q --no-verify -m "$SR_SUBJECT" -m "${body%$'\n'}" >/dev/null 2>&1 \
    || { _sr_say "the restamp commit failed"; return 2; }
  new=$(_sr_sha "$wt" HEAD) || return 2
  [ "$new" != "$old_head" ] || return 2
  printf '%s\n' "$new"
}

sr_commit_only() {
  local g="${1:-}" c parents p1 extra raw meta path path2 st om nm ob nb ren=0 td rc=0
  local -a mods=()
  [ -n "$g" ] || return 1
  c=$(_sr_sha "$g" "${2:-}") || return 1
  parents=$(git -C "$g" rev-list --parents -n 1 "$c" 2>/dev/null) || return 1
  read -r _ p1 extra <<<"$parents"
  [[ "${p1:-}" =~ ^[0-9a-f]{40}$ ]] && [ -z "${extra:-}" ] || return 1
  td=$(mktemp -d "${TMPDIR:-/tmp}/sr-only.XXXXXX") || return 1
  raw="$td/raw"
  git -C "$g" diff-tree -r -z --raw -M100% --no-commit-id "$p1" "$c" > "$raw" 2>/dev/null || { rm -rf "$td"; return 1; }
  : > "$td/pairs"
  while IFS= read -r -d '' meta; do
    read -r om nm ob nb st <<<"${meta#:}"
    IFS= read -r -d '' path || { rc=1; break; }
    case "$st" in
      R100)
        IFS= read -r -d '' path2 || { rc=1; break; }
        [ "$om" = "$nm" ] && [ "${path%/*}" = "${path2%/*}" ] && [[ ${path%/*} =~ $SR_DIR_RE ]] \
          && [[ ${path##*/} =~ $SR_STAMP_RE ]] && [[ ${path2##*/} =~ $SR_STAMP_RE ]] \
          && [ "${path##*/}" != "${path2##*/}" ] && [ "$(basename "$path" | cut -c13-)" = "$(basename "$path2" | cut -c13-)" ] \
          || { rc=1; break; }
        printf '%s\t%s\n' "${path##*/}" "${path2##*/}" >> "$td/pairs"; ren=$((ren + 1)) ;;
      M)
        [ "$om" = "$nm" ] && [[ ! ${path%/*} =~ $SR_DIR_RE ]] && [ "${om:0:3}" = 100 ] || { rc=1; break; }
        mods+=("$ob $nb") ;;
      *) rc=1; break ;;
    esac
  done < "$raw"
  if [ "$rc" = 0 ] && [ "$ren" -gt 0 ]; then
    for meta in "${mods[@]}"; do
      read -r ob nb <<<"$meta"
      git -C "$g" cat-file blob "$ob" > "$td/a" 2>/dev/null && git -C "$g" cat-file blob "$nb" > "$td/b" 2>/dev/null \
        && _sr_py_replace equal "$td/pairs" "$td/a" "$td/b" || { rc=1; break; }
    done
  else
    rc=1
  fi
  rm -rf "$td"
  return "$rc"
}

restamp_same() {
  local g="${1:-}" main rev head list c n=0
  [ -n "$g" ] || return 1
  command -v _ps_clean_merge >/dev/null 2>&1 || { [ -r "$_sr_dir/patch-same.sh" ] && . "$_sr_dir/patch-same.sh"; }
  command -v _ps_clean_merge >/dev/null 2>&1 || return 1
  main=$(_sr_sha "$g" "${2:-}") || return 1
  rev=$(_sr_sha "$g" "${3:-}") || return 1
  head=$(_sr_sha "$g" "${4:-}") || return 1
  [ "$rev" != "$head" ] || return 1
  git -C "$g" merge-base --is-ancestor "$rev" "$head" 2>/dev/null || return 1
  list=$(git -C "$g" rev-list "$head" "^$rev" "^$main" 2>/dev/null) || return 1
  for c in $list; do
    [[ "$c" =~ ^[0-9a-f]{40}$ ]] || return 1
    if sr_commit_only "$g" "$c"; then n=$((n + 1))
    else _ps_clean_merge "$g" "$c" || return 1; fi
  done
  [ "$n" -gt 0 ] || return 1
  printf 'restamp'
}

sr_stamp_order_line() {
  [[ "${1:-}" == *"schema-fragment-name: the stamp must be later than every fragment at the base"* ]]
}

sr_stamp_split() {
  local line
  [ -r "${1:-}" ] || return 1
  : > "$2"; : > "$3"
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ [^[:space:]] ]] || continue
    if sr_stamp_order_line "$line"; then printf '%s\n' "$line" >> "$3"; else printf '%s\n' "$line" >> "$2"; fi
  done < "$1"
  return 0
}
