#!/bin/bash
# bin/render-split.sh — a committed file that lives as a fragment folder.
#
#   bin/render-split.sh [--root <dir>] --check [<render path>...]
#   bin/render-split.sh [--root <dir>] --write [<render path>...]
#   bin/render-split.sh [--root <dir>] <render path>        (print to stdout)
#   bin/render-split.sh [--root <dir>] --cut <render path> --min-lines <n> [--at <ERE>]
#
# EDIT the fragment dir, NEVER the render. The render is the fragments
# concatenated verbatim in LC_ALL=C name order, with no banner, so its bytes
# are exactly the bytes the fragments hold. Two PRs that each add a block add
# two fragment files and conflict on no hunk; only the render differs, and a
# regenerate (`--write`) over the merged fragments holds both.
#
# THE REGISTRY: every catalog/splits.d/*.tsv, read in LC_ALL=C order. One row:
#   <render path> TAB <fragment dir>/ TAB <octal mode> [TAB <fragment ext>]
# Paths are repo-relative with no `..`; the dir ends in `/`; the mode is 3
# octal digits (the mode --write gives the render); the fragment extension is
# `txt` (the default when the field is absent) or `sh`. `#` lines and blank
# lines are skipped. The PLAN-stage lib bin/lib/rb/plan.sh (`txt`) is the first
# subject; fly-pool (`sh`) is the second subject (BH-9704 C1). The merge
# conductor bin/merge-conductor.sh (`txt`, cut with `--at '^ *# ' --min-lines
# 60`) is the third (BH-10226). A new split adds its OWN registry file, never a
# line to a shared one, and --check then covers it with no other edit.
#
# THE FRAGMENT DIR holds `NNNN-<slug>.<ext>` files (4 digits, then [a-z0-9-],
# lowercase; <ext> from the row, so a .txt in an `sh` dir is refused and the
# reverse) and an optional README.md. Any other entry (another name, a
# dotfile, a subdir, a symlink) refuses the set. Each fragment must be
# non-empty, end in a newline, hold no CR byte and no line that starts
# `<<<<<<< ` or `>>>>>>> ` (an unresolved merge). A render path ending in .sh
# must pass `bash -n`. A new block is a new fragment numbered between its
# neighbours: 1350-<slug>.<ext> sits between 1300-... and 1400-...
#
# MODES. --check renders every row (or the named ones) to a temp file and
# compares it with the committed file. --write renders and moves the result
# onto the render (temp file in the render's own dir, chmod <mode>, mv), but
# only after the merge guard below passes for every row; any failure writes
# nothing. Print writes one render to stdout. --cut makes the fragment dir from
# the committed render once: it starts a new fragment at a line that starts
# `# >>> ` when the current fragment already has at least <n> lines. The first
# fragment is 0100-head.<ext>, fragment k is <k*100>-<slug of the marker>.<ext>.
# With --at <ERE> the cut point is a block start instead: a line that matches
# the ERE when the line before it does not, so a comment block is never split.
# The slug then comes from the whole line (leading spaces and `#` dropped).
# It refuses a dir that already holds a .<ext>, and it removes what it wrote
# when the fragments do not reproduce the file byte for byte.
#
# THE MERGE GUARD (--write). During a merge, cherry-pick or rebase stop
# (MERGE_HEAD, CHERRY_PICK_HEAD, REBASE_HEAD), or on a merge commit at HEAD,
# every side that changed the render since the merge base must hold a fragment
# dir whose render is that side's render. A side that edited the render by
# hand, or that predates the split and edited it, refuses the write: a
# regenerate there would drop that edit. A side that is itself a merge commit
# (a batch-train union, which takes `--theirs` on a render conflict and
# regenerates once after its last merge) is judged by its parents when its
# render is one parent's render verbatim. Outside a merge there is no guard.
# A render whose bytes already equal the fragments' render is never refused:
# the write changes no byte, so it drops nothing. A fix round that moves a
# hand edit into a fragment therefore reaches rc 0 on the merge commit.
#
# EXIT CODES, the worst over every row:
#   0  rendered, written, printed, or --check found no drift
#   1  --check found drift (`DRIFT <render>` and the first 25 diff lines), or
#      a --cut whose fragments do not reproduce the file
#   2  usage, a bad registry row, a render path with no row, a missing
#      fragment dir or one with no fragments; --check maps any render failure
#      to 2 or 3, never to 0
#   3  a refused fragment set (the file is named on stderr)
#   4  the merge guard refused a --write
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/render-fragments.sh
. "$HERE/lib/render-fragments.sh"

ROOT="$(cd "$HERE/.." && pwd)"
MODE=print
CUT_MIN=
CUT_SET=
AT=
AT_SET=
PATHS=()
# frag_re <ext>: the fragment name rule for one row's extension.
frag_re() { printf '^[0-9]{4}-[a-z0-9][a-z0-9-]*\\.%s$' "$1"; }

usage() {
  sed -n '3,7p' "$0" | sed 's/^# //' >&2
  exit 2
}
die() { local rc="$1"; shift; printf 'render-split: %s\n' "$*" >&2; exit "$rc"; }
setmode() { [ "$MODE" = print ] || usage; MODE="$1"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --root)      ROOT="${2:-}"; [ -n "$ROOT" ] || usage; shift 2 ;;
    --check)     setmode check; shift ;;
    --write)     setmode write; shift ;;
    --cut)       setmode cut; [ -n "${2:-}" ] || usage; PATHS+=("$2"); shift 2 ;;
    --min-lines) CUT_SET=1; CUT_MIN="${2:-}"; [ $# -ge 2 ] && shift 2 || shift ;;
    --at)        AT_SET=1; AT="${2:-}"; [ $# -ge 2 ] && shift 2 || shift ;;
    -h|--help)   sed -n '2,70p' "$0"; exit 0 ;;
    -*)          printf 'render-split: unknown argument %s\n' "$1" >&2; usage ;;
    *)           PATHS+=("$1"); shift ;;
  esac
done
if [ "$MODE" = cut ]; then
  [ -n "$CUT_SET" ] || die 2 "--cut needs --min-lines <n>"
  [[ "$CUT_MIN" =~ ^[1-9][0-9]*$ ]] || die 2 "--min-lines must be a positive integer, got '$CUT_MIN'"
  [ -z "$AT_SET" ] || [ -n "$AT" ] || die 2 "--at needs a non-empty ERE"
  [ "${#PATHS[@]}" -eq 1 ] || usage
else
  [ -z "$CUT_SET" ] || die 2 "--min-lines is only for --cut"
  [ -z "$AT_SET" ] || die 2 "--at is only for --cut"
fi
[ "$MODE" != print ] || [ "${#PATHS[@]}" -eq 1 ] || usage

cd "$ROOT" 2>/dev/null || die 2 "cannot enter root $ROOT"
TMPS=()
cleanup() { [ "${#TMPS[@]}" -eq 0 ] || rm -rf -- "${TMPS[@]}"; }
trap cleanup EXIT

# --- the registry ---------------------------------------------------------
REG_RENDER=(); REG_DIR=(); REG_MODE=(); REG_EXT=()
rel_ok() { # rel_ok <path>: repo-relative, no `..` component, not empty
  case "$1" in
    ''|/*|..|../*|*/..|*/../*) return 1 ;;
  esac
  return 0
}
load_registry() {
  local f line ln r d m e extra i
  local -a files=()
  [ -d catalog/splits.d ] || die 2 "no registry: catalog/splits.d/ is missing in $ROOT"
  for f in catalog/splits.d/*.tsv; do [ -f "$f" ] && files+=("$f"); done
  [ "${#files[@]}" -gt 0 ] || die 2 "no registry: catalog/splits.d/ has no .tsv file"
  for f in "${files[@]}"; do
    ln=0
    while IFS= read -r line || [ -n "$line" ]; do
      ln=$((ln + 1))
      case "$line" in ''|'#'*) continue ;; esac
      IFS=$'\t' read -r r d m e extra <<<"$line" || :
      [ -n "${r:-}" ] && [ -n "${d:-}" ] && [ -n "${m:-}" ] && [ -z "${extra:-}" ] \
        || die 2 "$f:$ln: a row is <render path> TAB <fragment dir>/ TAB <octal mode> [TAB <ext>]"
      e=${e:-txt}
      case "$e" in txt|sh) ;; *) die 2 "$f:$ln: bad fragment extension '$e' (txt or sh)" ;; esac
      rel_ok "$r" && [ "${r%/}" = "$r" ] || die 2 "$f:$ln: bad render path '$r'"
      case "$d" in */) ;; *) die 2 "$f:$ln: the fragment dir '$d' must end in /" ;; esac
      d=${d%/}
      rel_ok "$d" || die 2 "$f:$ln: bad fragment dir '$d/'"
      [[ "$m" =~ ^[0-7]{3}$ ]] || die 2 "$f:$ln: bad mode '$m' (3 octal digits)"
      for i in "${!REG_RENDER[@]}"; do
        [ "${REG_RENDER[$i]}" != "$r" ] || die 2 "$f:$ln: $r is registered twice"
      done
      REG_RENDER+=("$r"); REG_DIR+=("$d"); REG_MODE+=("$m"); REG_EXT+=("$e")
    done < "$f"
  done
  [ "${#REG_RENDER[@]}" -gt 0 ] || die 2 "no registry rows in catalog/splits.d/"
}
row_of() { # row_of <render path> -> index, or rc 2
  local i
  for i in "${!REG_RENDER[@]}"; do
    [ "${REG_RENDER[$i]}" = "$1" ] && { printf '%s' "$i"; return 0; }
  done
  printf 'render-split: %s has no row in catalog/splits.d/\n' "$1" >&2
  return 2
}

# --- the fragments --------------------------------------------------------
# frag_list <dir> <ext> -> the fragment paths in C order, or rc 2/3 with a reason.
frag_list() {
  local dir="$1" ext="$2" e name f n listed re
  re=$(frag_re "$ext")
  local -a out=()
  [ -d "$dir" ] || { printf 'render-split: no fragment dir %s/\n' "$dir" >&2; return 2; }
  # Every entry, dotfiles included: a stray file must refuse the set, not hide.
  while IFS= read -r -d '' e; do
    name=${e##*/}
    if [ -L "$e" ]; then rf_fail "$e: a symlink is not a fragment"; return 3; fi
    if [ "$name" = README.md ] && [ -f "$e" ]; then continue; fi
    if [ ! -f "$e" ]; then rf_fail "$e: not a regular file (only fragments and README.md may live here)"; return 3; fi
    [[ "$name" =~ $re ]] || { rf_fail "$e: name is not NNNN-<slug>.$ext"; return 3; }
    out+=("$e")
  done < <(find "$dir" -mindepth 1 -maxdepth 1 -print0)
  [ "${#out[@]}" -gt 0 ] || { printf 'render-split: no fragments in %s/\n' "$dir" >&2; return 2; }
  # The CR scan and the C order are the shared contract's (rf_fragments).
  listed=$(rf_fragments "$dir" "[0-9][0-9][0-9][0-9]-*.$ext") || return $?
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -s "$f" ] || { rf_fail "$f: empty fragment"; return 3; }
    # $(...) strips a trailing newline, so an empty answer means the last byte IS one.
    [ -z "$(tail -c1 -- "$f")" ] || { rf_fail "$f: does not end in a newline"; return 3; }
    n=$(grep -a -n -m1 -E '^(<<<<<<<|>>>>>>>) ' -- "$f" | cut -d: -f1) || n=
    [ -z "$n" ] || { rf_fail "$f:$n: an unresolved merge marker"; return 3; }
    printf '%s\n' "$f"
  done <<<"$listed"
}

# render_to <row> <tmp>: the render of the working-tree fragments, checked.
render_to() {
  local i="$1" tmp="$2" list f
  local -a files=()
  list=$(frag_list "${REG_DIR[$i]}" "${REG_EXT[$i]}") || return $?
  while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done <<<"$list"
  cat -- "${files[@]}" > "$tmp" || { printf 'render-split: render of %s failed\n' "${REG_RENDER[$i]}" >&2; return 2; }
  case "${REG_RENDER[$i]}" in
    *.sh) bash -n "$tmp" 2>/dev/null || { rf_fail "${REG_DIR[$i]}/: the render of ${REG_RENDER[$i]} fails bash -n"; return 3; } ;;
  esac
  return 0
}

# --- the merge guard ------------------------------------------------------
# rs_blob <commit> <path> -> the blob id, or empty when absent.
rs_blob() { git rev-parse -q --verify "$1:$2" 2>/dev/null || :; }
# rs_side_render <commit> <dir> <ext> -> the blob id of that side's fragment render.
rs_side_render() {
  local c="$1" d="$2" x="$3" names n
  names=$(git ls-tree --name-only "$c:$d" 2>/dev/null | grep -E "$(frag_re "$x")" | sort) || names=
  { [ -z "$names" ] || while IFS= read -r n; do git cat-file blob "$c:$d/$n"; done <<<"$names"; } | git hash-object --stdin
}
# rs_side_ok <commit> <render> <dir> <ext> <base blob> <base commit> -> rc 0 when
# that side holds no hand edit of the render, rc 1 (RS_BAD = the commit) when
# it does. A side is clean when its render is the base's, when its fragments
# reproduce its render, or when it is an ancestor of the base. A side that is
# itself a merge commit whose render is one parent's render verbatim (a train
# union that took `--theirs` on a render conflict, BH-9704) added no byte of
# its own: it is clean when every parent is, so the guard descends into them.
# A merge commit whose render is no parent's render and not its fragments'
# render was resolved by hand, and it is refused.
RS_SEEN=; RS_BAD=
rs_side_ok() {
  local s="$1" rp="$2" dp="$3" x="$4" bb="$5" base="$6" bs p taken=0
  local -a ps=()
  case " $RS_SEEN " in *" $s "*) return 0 ;; esac
  RS_SEEN="$RS_SEEN $s"
  bs=$(rs_blob "$s" "$rp")
  [ "$bs" != "$bb" ] || return 0
  if [ "$(git cat-file -t "$s:$dp" 2>/dev/null)" = tree ] \
     && [ "$(rs_side_render "$s" "$dp" "$x")" = "$bs" ]; then
    return 0
  fi
  if [ -n "$base" ] && git merge-base --is-ancestor "$s" "$base" 2>/dev/null; then
    return 0
  fi
  read -r -a ps <<<"$(git rev-list --parents -n1 "$s" | cut -d' ' -f2-)"
  if [ "${#ps[@]}" -ge 2 ]; then
    for p in "${ps[@]}"; do [ "$(rs_blob "$p" "$rp")" != "$bs" ] || taken=1; done
    if [ "$taken" = 1 ]; then # the union took one parent's render verbatim
      for p in "${ps[@]}"; do rs_side_ok "$p" "$rp" "$dp" "$x" "$bb" "$base" || return 1; done
      return 0
    fi
  fi
  RS_BAD="$s"
  return 1
}
# rs_guard <render> <dir> <ext> -> rc 0 (write) or rc 4 (refused, reason on stderr).
rs_guard() {
  local render="$1" dir="$2" ext="$3" pre head ref sha base s bb
  local -a sides=()
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  pre=$(git rev-parse --show-prefix 2>/dev/null) || return 0
  head=$(git rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null) || return 0
  for ref in MERGE_HEAD CHERRY_PICK_HEAD REBASE_HEAD; do
    sha=$(git rev-parse -q --verify "$ref^{commit}" 2>/dev/null) || continue
    sides=("$head" "$sha")
    if [ "$ref" = CHERRY_PICK_HEAD ]; then
      base=$(git rev-parse -q --verify "$sha^1" 2>/dev/null) || base=
    else
      base=$(git merge-base "$head" "$sha" 2>/dev/null) || base=
    fi
    break
  done
  if [ "${#sides[@]}" -eq 0 ]; then
    read -r -a sides <<<"$(git rev-list --parents -n1 "$head" | cut -d' ' -f2-)"
    [ "${#sides[@]}" -ge 2 ] || return 0
    base=$(git merge-base --octopus "${sides[@]}" 2>/dev/null) || base=
  fi
  bb=; [ -z "$base" ] || bb=$(rs_blob "$base" "$pre$render")
  RS_SEEN=; RS_BAD=
  for s in "${sides[@]}"; do
    rs_side_ok "$s" "$pre$render" "$pre$dir" "$ext" "$bb" "$base" && continue
    printf 'render-split: refused: %s was edited by hand on %s; move the edit into %s/ (a regenerate here would drop it)\n' \
      "$render" "${RS_BAD:0:12}" "$dir" >&2
    printf 'render-split: when %s/ reproduces %s byte for byte, --check is rc 0 and --write has nothing to refuse\n' "$dir" "$render" >&2
    return 4
  done
  return 0
}

# --- cut ------------------------------------------------------------------
cut_split() {
  local i="$1" render="${REG_RENDER[$1]}" dir="${REG_DIR[$1]}" ext="${REG_EXT[$1]}" stage f rc=0 chk
  [ -f "$render" ] || die 2 "--cut: no file $render"
  if [ -d "$dir" ]; then
    for f in "$dir"/*."$ext"; do [ -e "$f" ] && die 2 "--cut: $dir/ already holds fragments; remove them first"; done
  fi
  stage=$(mktemp -d); TMPS+=("$stage")
  # The ERE rides in the environment: awk -v would process backslash escapes.
  RS_AT="$AT" awk -v n="$CUT_MIN" -v out="$stage" -v ext="$ext" '
    function slug(s) {
      s = tolower(s); gsub(/[^a-z0-9]+/, "-", s); sub(/^-+/, "", s); sub(/-+$/, "", s)
      s = substr(s, 1, 40); sub(/-+$/, "", s)
      return s == "" ? "block" : s
    }
    BEGIN { k = 1; cnt = 0; f = out "/0100-head." ext; at = ENVIRON["RS_AT"]; prev = "" }
    {
      if (at == "" ? (substr($0, 1, 6) == "# >>> " && cnt >= n) : ($0 ~ at && !(prev ~ at) && cnt >= n)) {
        close(f); k++
        if (k * 100 > 9999) { print "render-split: --cut: more than 99 fragments; use a larger --min-lines" > "/dev/stderr"; exit 2 }
        f = sprintf("%s/%04d-%s.%s", out, k * 100, slug(at == "" ? substr($0, 7) : $0), ext); cnt = 0
      }
      print > f; cnt++; prev = $0
    }' "$render" || die 2 "--cut: the walk of $render failed"
  [ -n "$(ls -A "$stage")" ] || die 2 "--cut: $render is empty"
  mkdir -p "$dir"
  local -a made=()
  for f in "$stage"/*."$ext"; do cp -- "$f" "$dir/"; made+=("$dir/${f##*/}"); done
  chk=$(mktemp); TMPS+=("$chk")
  render_to "$i" "$chk" || rc=$?
  if [ "$rc" -ne 0 ] || ! cmp -s -- "$chk" "$render"; then
    rm -f -- "${made[@]}"
    die 1 "--cut: the fragments do not reproduce $render byte for byte; nothing kept"
  fi
  printf '%s\n' "${made[@]}"
}

# --- main -----------------------------------------------------------------
load_registry
ROWS=()
if [ "${#PATHS[@]}" -eq 0 ]; then
  ROWS=("${!REG_RENDER[@]}")
else
  for p in "${PATHS[@]}"; do
    idx=$(row_of "$p") || exit 2
    ROWS+=("$idx")
  done
fi

case "$MODE" in
  cut)
    cut_split "${ROWS[0]}"
    ;;
  print)
    tmp=$(mktemp); TMPS+=("$tmp")
    rc=0; render_to "${ROWS[0]}" "$tmp" || rc=$?
    [ "$rc" -eq 0 ] || exit "$rc"
    cat -- "$tmp"
    ;;
  check)
    worst=0
    for i in "${ROWS[@]}"; do
      tmp=$(mktemp); TMPS+=("$tmp")
      rc=0; render_to "$i" "$tmp" || rc=$?
      if [ "$rc" -eq 0 ]; then
        rf_check "${REG_RENDER[$i]}" "$tmp" || rc=$?
        [ "$rc" -ne 1 ] || printf 'fix: edit %s/ and run bin/render-split.sh --write\n' "${REG_DIR[$i]}"
      elif [ "$rc" -ne 3 ]; then
        rc=2
      fi
      [ "$rc" -le "$worst" ] || worst=$rc
    done
    exit "$worst"
    ;;
  write)
    # Phase 1: guard and render every row; any failure writes nothing at all.
    TMPW=()
    for i in "${ROWS[@]}"; do
      mkdir -p "$(dirname -- "${REG_RENDER[$i]}")"
      tmp=$(mktemp "$(dirname -- "${REG_RENDER[$i]}")/.render-split.XXXXXX"); TMPS+=("$tmp")
      rc=0; render_to "$i" "$tmp" || rc=$?
      [ "$rc" -eq 0 ] || exit "$rc"
      # A render that already holds these bytes loses nothing, so the guard
      # is not asked (only the mode can change).
      if ! { [ -f "${REG_RENDER[$i]}" ] && cmp -s -- "$tmp" "${REG_RENDER[$i]}"; }; then
        rc=0; rs_guard "${REG_RENDER[$i]}" "${REG_DIR[$i]}" "${REG_EXT[$i]}" || rc=$?
        [ "$rc" -eq 0 ] || exit "$rc"
      fi
      chmod "${REG_MODE[$i]}" "$tmp"
      TMPW+=("$tmp")
    done
    # Phase 2: move every render into place.
    for k in "${!ROWS[@]}"; do
      rf_write_atomic "${REG_RENDER[${ROWS[$k]}]}" "${TMPW[$k]}"
    done
    ;;
esac
exit 0
