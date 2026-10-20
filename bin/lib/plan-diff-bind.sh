#!/bin/bash
# bin/lib/plan-diff-bind.sh — bind the committed plan of a ticket to its diff
# (BH-7273). A sourceable lib (pdb_check) with a CLI main guard.
#
#   bin/lib/plan-diff-bind.sh [--base <ref>] [repo]
#     --base <ref>  judge `git diff --name-only <merge-base of ref and HEAD> HEAD`
#                   (default origin/main). Committed HEAD only, never the
#                   working tree.
#     repo          the checkout (default: the current directory).
#   pdb_check <repo> <base> <head>
#
#   rc 0 the plan and the diff agree, or the check skipped (stderr says why)
#   rc 1 findings, one per stdout line (at most 40, then `... and N more`):
#        `<kind> <path> <plan-path>[:<line>] — <what to fix>`
#   rc 2 bad args, a base or head that does not resolve, no temp dir. The
#        rules pack reads it as could-not-run.
#
# WHICH PLAN: the one changed path `.harness/specs/<KEY>/plan.md` that exists
# at HEAD. No such path, or two and more (a merge-queue batch, a stack): skip.
#
# THE FOUR KINDS:
#   planned-not-changed  an entry line of the `## Files to touch` section (a
#       bullet, a numbered item or a table row, at most one space of indent)
#       names a path as its FIRST path token, in its first three words, and
#       the diff does not change it. A path later in a prose bullet is not an
#       edit claim.
#       A line with `verify-only:`, `only if`, `if needed`, `if required`,
#       `optional` or `optionally` is exempt.
#   changed-not-planned  the diff changes a path under bin/, worker/, tests/ or
#       catalog/ that no path token of the plan names. Tokens in the
#       `## Sibling claims` and `## Verify` sections do not name.
#   class-claim  a sentence says "no path under <dir>/ changes" (or `nothing
#       in <dir>/ is edited`, and the like) and the diff changes a path under
#       <dir>/. A quoted example, a conditional (if, when, unless, whether
#       before it) and an exception (except, other than, besides, apart from,
#       but after it) are not claims.
#   case-missing  a Files-to-touch entry for a changed tests/ file says new or
#       add, names a case ID (R7, a range R1-R6), and the ID is not a word in
#       that file at HEAD. D<n> (a build-discipline rule) and an ID that
#       starts a plan heading (### T4. ...) are never case IDs.
#
# PATH TOKENS: the plan line split on any character outside A-Za-z0-9_./<>*-,
# so backticks, `:755` suffixes and URLs fall away. A token is a path when it
# has a `/` and its first segment is a top-level entry of the repo (so
# `and/or` and `/root/harness/x` are not). A `$VAR/` prefix is dropped first,
# so `"$DIR/bin/x.sh"` names bin/x.sh. `<...>` and `*` make a glob,
# matched as an anchored regex built from the literal token (never eval). A
# trailing `/` makes a dir scope. For changed-not-planned only, a dir scope
# names its paths at 3 segments or more (or 2 with a dot: catalog/lanes.d/),
# and a glob names its paths only when its last segment keeps a literal word
# other than an extension or `test`: `bin/lib/` and `bin/*.sh` in prose do not
# excuse every file under them.
#
# PLAN_DIFF_BIND_IGNORE  comma list of globs the diff side drops (default
# tests/mc/expected-map.d/*, the generated path the plan-files rule ignores).
#
# BLIND SPOTS: task-step prose is not read for planned-not-changed; class-claim
# knows only the "no path under <dir>/ changes" shape; a path mentioned
# anywhere outside the two skipped sections counts as named.

# The parse. Reads the plan on stdin-file, the changed set D, the top-level
# entries TOP. Prints `F<TAB><finding>` and `C<TAB><path><TAB><line><TAB><id>`
# (a case ID to look for in <path> at HEAD).
PDB_AWK='
function glob_re(g,   r, i, c) {
  r = ""
  for (i = 1; i <= length(g); i++) {
    c = substr(g, i, 1)
    if (c == "*") r = r ".*"
    else if (c == ".") r = r "[.]"
    else r = r c
  }
  return "^" r "$"
}
function is_glob(t) { return index(t, "*") > 0 }
function is_dir(t) { return substr(t, length(t)) == "/" }
function tokens(s, arr,   parts, m, n, i, t, k) {
  gsub(/[$][{]?[A-Za-z_][A-Za-z0-9_]*[}]?\//, " /", s)
  gsub(/[^A-Za-z0-9_.\/<>*-]+/, " ", s)
  m = split(s, parts, " ")
  n = 0
  for (i = 1; i <= m; i++) {
    t = parts[i]
    while (substr(t, 1, 2) == "./") t = substr(t, 3)
    while (substr(t, 1, 1) == "/") t = substr(t, 2)
    if (length(t) > 4 && substr(t, 1, 2) == "**" && substr(t, length(t) - 1) == "**") t = substr(t, 3, length(t) - 4)
    while (length(t) > 0 && substr(t, length(t)) == ".") t = substr(t, 1, length(t) - 1)
    if (index(t, "/") == 0) continue
    k = t; sub(/\/.*/, "", k)
    if (!(k in TOPS)) continue
    gsub(/<[^<>]*>/, "*", t)
    arr[++n] = t
  }
  return n
}
# matches_d <token> — does any changed path match the token
function matches_d(t,   i, re) {
  if (is_glob(t)) { re = glob_re(t); for (i = 1; i <= nd; i++) if (DP[i] ~ re) return 1; return 0 }
  if (is_dir(t)) { for (i = 1; i <= nd; i++) if (index(DP[i], t) == 1) return 1; return 0 }
  return (t in DSET)
}
function broad_dir(t,   n, seg) {
  n = split(t, seg, "/") - 1
  return !(n >= 3 || (n == 2 && index(t, ".") > 0))
}
function broad_glob(t,   n, seg, last) {
  n = split(t, seg, "/")
  last = seg[n]
  gsub(/\*/, "", last)
  sub(/[.][A-Za-z0-9]+$/, "", last)
  gsub(/[^A-Za-z0-9]/, "", last)
  return last == "" || tolower(last) == "test"
}
function name_tokens(line,   arr, n, i, t) {
  n = tokens(line, arr)
  for (i = 1; i <= n; i++) {
    t = arr[i]
    if (is_glob(t)) { if (!broad_glob(t)) NGLOB[glob_re(t)] = 1 }
    else if (is_dir(t)) { if (!broad_dir(t)) NDIR[t] = 1 }
    else NLIT[t] = 1
  }
}
function emit(kind, key, text) {
  if ((kind SUBSEP key) in SEEN) return
  SEEN[kind, key] = 1
  OUT[kind, ++NO[kind]] = text
}
function entry_line(line,   arr, n, t, l, s, i, w, words, nw, a, b, p1, p2, n1, n2, j, seg) {
  if (line !~ /^ ?([-*+][ \t]|[0-9]+[.)][ \t]|\|)/) return
  l = tolower(line)
  if (index(l, "verify-only:") > 0) return
  if (l ~ /(only if|if needed|if required)/ || l ~ /(^|[^a-z])optional(ly)?([^a-z]|$)/) return
  n = tokens(line, arr)
  if (n == 0) return
  t = arr[1]
  # the entry names its file up front: the first path token is one of the
  # first three words after the marker, or the line is prose about callers
  s = line
  sub(/^ ?([-*+]|[0-9]+[.)])?[ \t]*/, "", s)
  gsub(/\|/, " ", s)
  nw = split(s, words, /[ \t]+/)
  w = ""
  for (i = 1; i <= nw && i <= 3; i++) w = w " " words[i]
  if (tokens(w, words) == 0 || words[1] != t) return
  if (!matches_d(t))
    emit(1, t, "planned-not-changed " t " " PLAN ":" NR " \342\200\224 the plan names this path as edited and the diff does not change it; edit the path, or fix the plan line (mark it verify-only: if it is only run)")
  if (is_glob(t) || is_dir(t) || substr(t, 1, 6) != "tests/" || !(t in DSET)) return
  if (l !~ /(^|[^a-z])(new|add|adds|added)([^a-z]|$)/) return
  s = line
  gsub(/\342\200\223/, "-", s)
  while (match(s, /[A-Z][A-Z]?[0-9]+ +(to|through) +[A-Z]/)) {
    seg = substr(s, RSTART, RLENGTH); sub(/ +(to|through) +/, "~", seg)
    s = substr(s, 1, RSTART - 1) seg substr(s, RSTART + RLENGTH)
  }
  gsub(/[.][.]/, "~", s)
  nw = split(s, words, /[^A-Za-z0-9~-]+/)
  for (i = 1; i <= nw; i++) {
    w = words[i]
    if (w ~ /^[A-Z][A-Z]?[0-9]+[-~][A-Z][A-Z]?[0-9]+$/) {
      a = w; sub(/[-~].*/, "", a); b = w; sub(/.*[-~]/, "", b)
      p1 = a; sub(/[0-9]+$/, "", p1); p2 = b; sub(/[0-9]+$/, "", p2)
      if (p1 != p2 || p1 == "D") continue
      n1 = substr(a, length(p1) + 1) + 0; n2 = substr(b, length(p2) + 1) + 0
      if (n2 < n1 || n2 - n1 + 1 > 60) continue
      for (j = n1; j <= n2; j++) CASES[++NC] = t "\t" NR "\t" p1 j
    } else if (w ~ /^[A-Z][A-Z]?[0-9][0-9]?[0-9]?[a-z]?$/ && w !~ /^D[0-9]/) {
      CASES[++NC] = t "\t" NR "\t" w
    }
  }
}
# unquote <unit> — drop quoted examples before the claim match
function unquote(u,   seg) {
  gsub(/\342\200\234|\342\200\235/, "\"", u)
  gsub(/"[^"]*"/, " ", u)
  while (match(u, /`[^`]*`/)) {
    seg = substr(u, RSTART + 1, RLENGTH - 2)
    if (seg ~ /[ \t]/) seg = " "
    u = substr(u, 1, RSTART - 1) seg substr(u, RSTART + RLENGTH)
  }
  while (match(u, /(^|[ (])\047[^\047]*\047/)) {
    seg = substr(u, 1, RSTART - 1)
    if (substr(u, RSTART, 1) != "\047") seg = seg substr(u, RSTART, 1)
    u = seg " " substr(u, RSTART + RLENGTH)
  }
  gsub(/\*/, "", u)
  return u
}
function flush(   u, ns, sent, i, l, m, pre, post, words, nw, j) {
  if (UNIT == "") return
  u = unquote(UNIT)
  gsub(/[.;?!][ \t]+/, "\001", u)
  ns = split(u, sent, "\001")
  for (i = 1; i <= ns; i++) {
    l = tolower(sent[i])
    if (!match(l, CLAIM)) continue
    pre = substr(l, 1, RSTART); post = substr(l, RSTART + RLENGTH - 1)
    if (pre ~ /(^|[^a-z])(if|when|unless|whether)([^a-z]|$)/) continue
    if (post ~ /(^|[^a-z])(except|other than|besides|apart from|but)([^a-z]|$)/) continue
    m = substr(sent[i], RSTART, RLENGTH)
    nw = split(m, words, /[ ,]+/)
    for (j = 1; j <= nw; j++)
      if (words[j] ~ /^[A-Za-z0-9_.\/-]+\/$/ && index(words[j], "/") > 0) CL[++NCL] = words[j] "\t" ULINE
  }
  UNIT = ""
}
BEGIN {
  while ((getline p < TOP) > 0) if (p != "") TOPS[p] = 1
  nd = 0
  ni = split(IGN, ig, ",")
  for (i = 1; i <= ni; i++) if (ig[i] != "") IGRE[glob_re(ig[i])] = 1
  while ((getline p < D) > 0) {
    if (p == "") continue
    DP[++nd] = p; DSET[p] = 1
    if (p ~ /^[.]harness\/specs\//) continue
    skip = 0
    for (r in IGRE) if (p ~ r) skip = 1
    if (!skip) DJ[++ndj] = p
  }
  DIR = "[a-z0-9_.-]+(/[a-z0-9_.-]+)*/"
  CLAIM = "(^|[^a-z])(no|nothing)[ ]+((path|file|code|change)s?[ ]+)?(under|in)[ ]+" DIR "([ ]*,?[ ]*((or|and)[ ]+)?" DIR ")*[ ]+(changes?|(is|are)[ ]+(changed|edited|touched|modified))[ ]*([.,:;!?)]|\342\200\224|$)"
}
{
  line = $0
  sub(/\r$/, "", line)
  if (line ~ /^[ \t]*(```|~~~)/) { flush(); fence = !fence; if (!sib && !ver) name_tokens(line); next }
  if (fence) { if (!sib && !ver) name_tokens(line); next }
  if (line ~ /^#+[ \t]/) {
    flush()
    lvl = line; sub(/[ \t].*/, "", lvl); lvl = length(lvl)
    title = tolower(line); sub(/^#+[ \t]+/, "", title)
    # a task heading (### T4. ...) names a task, never a test case
    h = line; sub(/^#+[ \t]+/, "", h); sub(/[^A-Za-z0-9].*/, "", h)
    if (h ~ /^[A-Z][A-Z]?[0-9]+$/) HEADID[h] = 1
    if (ftt && lvl <= ftt_lvl) ftt = 0
    if (title ~ /files to touch/) { ftt = 1; ftt_lvl = lvl }
    if (lvl <= 2) { sib = (title ~ /^sibling claims/); ver = (title ~ /^verify([^a-z]|$)/) }
    UNIT = line; ULINE = NR; flush()
    if (!sib && !ver) name_tokens(line)
    next
  }
  if (!sib && !ver) name_tokens(line)
  if (ftt) entry_line(line)
  if (line ~ /^[ \t]*$/) { flush(); next }
  if (line ~ /^[ \t]*([-*+][ \t]|[0-9]+[.)][ \t]|>|\|)/ || UNIT == "") { flush(); UNIT = line; ULINE = NR }
  else UNIT = UNIT " " line
}
END {
  flush()
  for (i = 1; i <= ndj; i++) {
    p = DJ[i]
    if (p !~ /^(bin|worker|tests|catalog)\//) continue
    named = (p in NLIT)
    if (!named) for (r in NGLOB) if (p ~ r) { named = 1; break }
    if (!named) for (r in NDIR) if (index(p, r) == 1) { named = 1; break }
    if (!named) emit(2, p, "changed-not-planned " p " " PLAN " \342\200\224 the diff changes this path and the plan does not name it; name it in ## Files to touch, or take it out of the diff")
  }
  for (c = 1; c <= NCL; c++) {
    split(CL[c], cf, "\t")
    for (i = 1; i <= ndj; i++)
      if (index(DJ[i], cf[1]) == 1)
        emit(3, DJ[i], "class-claim " DJ[i] " " PLAN ":" cf[2] " \342\200\224 the plan says no path under " cf[1] " changes and the diff changes this path; fix the claim or the diff")
  }
  for (k = 1; k <= 3; k++) for (i = 1; i <= NO[k]; i++) print "F\t" OUT[k, i]
  for (i = 1; i <= NC; i++) { split(CASES[i], cf, "\t"); if (!(cf[3] in HEADID)) print "C\t" CASES[i] }
}'

# pdb_check <repo> <base> <head> — see the header. Prints findings on stdout.
pdb_check() {
  local repo="${1:-}" base="${2:-}" head="${3:-HEAD}" tmp hs bs fork p plan n i rc
  [ -n "$repo" ] && [ -n "$base" ] || { echo "plan-diff-bind: usage: pdb_check <repo> <base> <head>" >&2; return 2; }
  git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1 || { echo "plan-diff-bind: $repo is not a git work tree" >&2; return 2; }
  hs=$(git -C "$repo" rev-parse --verify -q "$head^{commit}") || { echo "plan-diff-bind: cannot resolve head $head" >&2; return 2; }
  bs=$(git -C "$repo" rev-parse --verify -q "$base^{commit}") || { echo "plan-diff-bind: cannot resolve base $base" >&2; return 2; }
  fork=$(git -C "$repo" merge-base "$bs" "$hs" 2>/dev/null) || { echo "plan-diff-bind: no merge-base between $base and $head" >&2; return 2; }
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/plan-diff-bind.XXXXXX") || { echo "plan-diff-bind: cannot make a temp dir" >&2; return 2; }
  if ! git -C "$repo" -c core.quotePath=false diff --no-renames --name-only "$fork" "$hs" > "$tmp/d"; then
    echo "plan-diff-bind: git diff $fork $hs failed" >&2; rm -rf "$tmp"; return 2
  fi
  : > "$tmp/plans"
  while IFS= read -r p; do
    case "$p" in .harness/specs/*/plan.md) ;; *) continue ;; esac
    case "${p#.harness/specs/}" in */*/*) continue ;; esac
    git -C "$repo" cat-file -e "$hs:$p" 2>/dev/null && printf '%s\n' "$p" >> "$tmp/plans"
  done < "$tmp/d"
  n=$(grep -c . "$tmp/plans")
  if [ "$n" -ne 1 ]; then
    if [ "$n" -eq 0 ]; then echo "plan-diff-bind: skip (no plan in this diff)" >&2
    else echo "plan-diff-bind: skip ($n plans in this diff)" >&2; fi
    rm -rf "$tmp"; return 0
  fi
  plan=$(cat "$tmp/plans")
  if ! git -C "$repo" show "$hs:$plan" > "$tmp/plan" \
     || ! { git -C "$repo" ls-tree --name-only "$hs" && git -C "$repo" ls-tree --name-only "$fork"; } > "$tmp/top"; then
    echo "plan-diff-bind: cannot read $plan or the tree at $hs" >&2; rm -rf "$tmp"; return 2
  fi
  if ! awk -v D="$tmp/d" -v TOP="$tmp/top" -v PLAN="$plan" -v IGN="${PLAN_DIFF_BIND_IGNORE-tests/mc/expected-map.d/*}" \
       "$PDB_AWK" "$tmp/plan" > "$tmp/rows"; then
    echo "plan-diff-bind: the plan parse failed" >&2; rm -rf "$tmp"; return 2
  fi
  awk -F'\t' '$1 == "F" { sub(/^F\t/, ""); print }' "$tmp/rows" > "$tmp/found"
  # case-missing: each named ID must be a word in the file at HEAD
  local cpath cline cid last="" f=""
  i=0
  while IFS=$'\t' read -r _ cpath cline cid; do
    if [ "$cpath" != "$last" ]; then
      i=$((i + 1)); f="$tmp/case.$i"; last=$cpath
      git -C "$repo" show "$hs:$cpath" > "$f" 2>/dev/null || : > "$f"
    fi
    grep -qwF -- "$cid" "$f" && continue
    printf 'case-missing %s %s:%s — case %s is named as added and is not in the file at HEAD; add the case, or fix the plan line\n' \
      "$cpath" "$plan" "$cline" "$cid" >> "$tmp/found"
  done < <(awk -F'\t' '$1 == "C"' "$tmp/rows")
  n=$(grep -c . "$tmp/found")
  rc=0
  if [ "$n" -gt 0 ]; then
    rc=1
    head -n 40 "$tmp/found"
    [ "$n" -le 40 ] || echo "... and $((n - 40)) more"
  fi
  rm -rf "$tmp"
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  PDB_BASE=origin/main PDB_REPO=""
  while [ $# -gt 0 ]; do
    case "$1" in
      -h|--help) awk 'NR > 1 { if ($0 !~ /^#/) exit; print }' "$0"; exit 0 ;;
      --base) [ $# -ge 2 ] && [ -n "$2" ] || { echo "plan-diff-bind: --base needs a ref" >&2; exit 2; }
              PDB_BASE=$2; shift 2 ;;
      -*) echo "plan-diff-bind: unexpected argument $1" >&2; exit 2 ;;
      *) [ -z "$PDB_REPO" ] || { echo "plan-diff-bind: unexpected argument $1" >&2; exit 2; }
         PDB_REPO=$1; shift ;;
    esac
  done
  pdb_check "${PDB_REPO:-.}" "$PDB_BASE" HEAD
  exit $?
fi
