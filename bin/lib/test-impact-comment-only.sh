#!/bin/bash
# bin/lib/test-impact-comment-only.sh — A COMMENT EDIT OF A SHELL FILE SELECTS
# ONLY THE SUITES THAT READ IT (BH-8099, slice C2 of BH-8050).
#
# Sourced by bin/test-impact.sh (hook lines in ti_select_from) and read by
# bin/lib/test-impact-fn-reach.sh (rule P), never run. It reads the
# selector's own globals and helpers: ROOT, TI_TMP, TI_NAMED_BASE,
# TI_READ_RE, TI_RUN_RE, TI_ROOTVAR, TI_AWK_NORM, ti_rootvars, and
# FNR_AWK_NAMES_DIR from the fn-reach lib.
#
# A changed shell file that differs from its base copy only in comment lines
# and blank lines that bash ignores runs the same commands. The suites that
# reach it through `source`, `closure` and `named` rows cannot see the change.
# The rows of kind self, reads, learned, regression and always stay: a suite
# that reads the file as data can see a comment.
#
# THE SET (tco_set). A changed path P is COMMENT-ONLY when it is eligible
# (tco_path_ok, the knob, TI_NAMED_BASE), it has a base copy, it exists at
# the head, diff -U0 shows hunks, tco_classes reads both sides, and EVERY
# changed line on both sides is class I. The set is written to
# $TI_TMP/comment-only, one path per line, in the diff order.
#
# THE CLASSES (tco_classes <file>): one line per input line.
#   I        an inert line: blank, or a comment line at the start of a command
#   X        any other line (code, a heredoc body, a line inside an open
#            quote, a line after a `\` continuation, line 1 `#!`, a
#            `# shellcheck` directive)
#   D\t<tag> a comment line `# <tag>:` or `# <tag>=` whose tag some script
#            reads (tco_tags): a directive, not prose
#   S        a comment line of a file that reads its own text ($0,
#            BASH_SOURCE on a line with a read verb or `<`)
# EOF inside a heredoc or an open quote prints only `ERR\t<why>`, rc 3.
# The scan of a code line: `#` starts a comment only at a word start (line
# start, or after a blank or one of ;&|()<>); `\` escapes the next byte
# outside single quotes; ${#v}, $# and a#b are code. `<<<` is not a heredoc.
# Known safe-side limits: `$((1<<2))` reads as a heredoc of `2` (EOF inside a
# heredoc, so the path falls back), and a `"` inside `$(…)` inside a
# double-quoted string can leave a quote open (the lines after it are X).
#
# THE FILTER (tco_apply <map> <why>): drops every row of kind source or
# closure whose path is in the set, and every named row whose path part
# (before the last `#`) is in the set. A suite keeps its rows for P when it
# has a map row D that is a directory above P, and a non-comment line of the
# suite names D and is not a pure run/copy line (the fn-reach step-3 rule,
# FNR_AWK_NAMES_DIR): a lint that greps or loops over bin/ can read comments.
#
# KNOB: env TI_COMMENT_ONLY. Unset, empty or 1 is on (BH-7033: every reach
# wave ships ON, and the knob is the rollback). 0 is today's selection. Any
# other value is off too, the safe side, and logs one
# `comment-only: off (TI_COMMENT_ONLY=<v>)` line when the diff has a shell path.
#
# LOG LINES (stderr):
#   comment-only: <p>: dropped <k> row(s), <m> of <n> suite(s) left, <d> kept by a directory scan
#   comment-only: fallback (<why>: <p>)      the path keeps today's rows
#   comment-only: fallback (directive tags unreadable)
#   comment-only: off (TI_COMMENT_ONLY=<v>)
#
# No set -e. Every work file is $TI_TMP/tco.*. Every awk is LC_ALL=C and
# mawk-safe. tco_apply replaces the why file only after every step had rc 0.

TCO_SELF_RE='^bin/lib/test-impact-[^/]*\.sh$'

# tco_on — rc 0 when the knob is on (unset, empty or 1).
tco_on() {
  case "${TI_COMMENT_ONLY-}" in ''|1) return 0 ;; *) return 1 ;; esac
}

# tco_path_ok <p> — rc 0 when <p> is a shell path the rule may read: it ends
# in .sh or .bash and it is not one of the selector's own libs.
tco_path_ok() {
  [[ $1 =~ \.(sh|bash)$ ]] || return 1
  ! [[ $1 =~ $TCO_SELF_RE ]]
}

# tco_eligible <p> — the path rule, the knob and a base to diff against.
tco_eligible() {
  tco_path_ok "$1" && tco_on && [ -n "${TI_NAMED_BASE:-}" ]
}

# tco_directive_tags — the tags a script may read from a comment line: every
# `#<tag>:`, `# <tag>:`, `#<tag>=` or `# <tag>=` spelling on a line of a
# script under bin cron fly checks guardrails tests/lib whose first non-blank
# byte is not `#` (a string, a regex, a trailing comment: all count, the safe
# side). One per line. rc 1 when git grep failed.
tco_directive_tags() {
  local out rc
  out=$(git -C "$ROOT" grep -h -I -E '#[ ]?[A-Za-z][A-Za-z0-9_-]*[:=]' -- \
          'bin/*.sh' 'bin/*.bash' 'bin/*.py' 'cron/*.sh' 'cron/*.bash' 'cron/*.py' \
          'fly/*.sh' 'fly/*.bash' 'fly/*.py' 'checks/*.sh' 'checks/*.bash' 'checks/*.py' \
          'guardrails/*.sh' 'guardrails/*.bash' 'guardrails/*.py' \
          'tests/lib/*.sh' 'tests/lib/*.bash' 'tests/lib/*.py' 2>/dev/null); rc=$?
  [ "$rc" -le 1 ] || return 1
  printf '%s\n' "$out" | LC_ALL=C awk '
    /^[ \t]*#/ { next }
    { s = $0
      while (match(s, /#[ ]?[A-Za-z][A-Za-z0-9_-]*[:=]/)) {
        t = substr(s, RSTART + 1, RLENGTH - 2); sub(/^ /, "", t); print t
        s = substr(s, RSTART + RLENGTH) } }' | LC_ALL=C sort -u
}

# tco_tags_file — the path of the tag file, computed once per select. When
# git grep fails the file holds `*` (every tag-shaped comment is a directive)
# and one fallback line is logged.
tco_tags_file() {
  local f="$TI_TMP/tco.tags"
  if [ ! -f "$f" ]; then
    tco_directive_tags > "$f.tmp" && mv "$f.tmp" "$f" || {
      printf '*\n' > "$f"; echo "comment-only: fallback (directive tags unreadable)" >&2; }
  fi
  printf '%s\n' "$f"
}

# tco_classes <file> — one class per line (see THE CLASSES), or `ERR\t<why>`
# and rc 3.
tco_classes() {
  local tags
  tags=$(tco_tags_file) || return 1
  LC_ALL=C awk -v tagf="$tags" -v RR="$TI_READ_RE" '
    BEGIN { while ((getline t < tagf) > 0) if (t != "") tag[t] = 1
            st = ""; cont = 0; hi = 1; hn = 0; nq = 0; err = "" }
    # scan <s> — walk one code line from the carried quote state.
    function scan(s,   i, L, c, p, w, j, strip, esc) {
      L = length(s); i = 1; esc = 0
      while (i <= L) {
        c = substr(s, i, 1)
        if (st == "sq") { if (c == "\047") st = ""; i++; continue }
        if (st == "dsq" || st == "dq") {
          if (c == "\\") { i += 2; continue }
          if ((st == "dsq" && c == "\047") || (st == "dq" && c == "\"")) st = ""
          i++; continue
        }
        if (c == "\\") { if (i == L) { cont = 1; return } i += 2; esc = 1; continue }
        if (c == "\047") { st = (i > 1 && !esc && substr(s, i - 1, 1) == "$") ? "dsq" : "sq"; i++; esc = 0; continue }
        if (c == "\"") { st = "dq"; i++; esc = 0; continue }
        if (c == "#") {
          p = (i == 1) ? " " : substr(s, i - 1, 1)
          if (!esc && p ~ /[ \t;&|()<>]/) return
          i++; esc = 0; continue
        }
        if (substr(s, i, 3) == "<<<") { i += 3; esc = 0; continue }
        if (substr(s, i, 2) == "<<") {
          i += 2; strip = 0
          if (substr(s, i, 1) == "-") { strip = 1; i++ }
          while (i <= L && substr(s, i, 1) ~ /[ \t]/) i++
          w = ""
          while (i <= L) {
            c = substr(s, i, 1)
            if (c ~ /[ \t;&|()<>]/) break
            if (c == "\047" || c == "\"") {
              j = index(substr(s, i + 1), c)
              if (j == 0) { if (err == "") err = "unclosed heredoc word at line " NR; return }
              w = w substr(s, i + 1, j - 1); i += j + 1; continue
            }
            if (c == "\\") { w = w substr(s, i + 1, 1); i += 2; continue }
            w = w c; i++
          }
          if (w != "") { nq++; qw[nq] = w; qs[nq] = strip; ql[nq] = NR }
          esc = 0; continue
        }
        esc = 0; i++
      }
    }
    {
      line = $0
      if (hi <= hn) {
        cls[NR] = "X"
        cmp = line; if (hs[hi]) sub(/^\t+/, "", cmp)
        if (cmp == hw[hi]) hi++
        next
      }
      if (st == "" && !cont) {
        if (line ~ /^[ \t]*$/) { cls[NR] = "I"; next }
        if (line ~ /^[ \t]*#/) {
          if (NR == 1 && line ~ /^#!/) cls[NR] = "X"
          else if (line ~ /^[ \t]*#[ \t]*shellcheck([ \t]|$)/) cls[NR] = "X"
          else {
            tg = ""
            if (match(line, /^[ \t]*#[ \t]*[A-Za-z][A-Za-z0-9_-]*[:=]/)) tg = tco_tag(substr(line, RSTART, RLENGTH))
            if (tg != "" && ((tg in tag) || ("*" in tag))) cls[NR] = "D\t" tg
            else { cls[NR] = "I"; com[NR] = 1 }
          }
          next
        }
      }
      cls[NR] = "X"; cont = 0
      scan(line)
      if (nq > 0) { hi = 1; hn = nq; for (k = 1; k <= nq; k++) { hw[k] = qw[k]; hs[k] = qs[k]; hl[k] = ql[k] }; nq = 0 }
      if ((line ~ RR || index(line, "<") > 0) && line ~ /[$]0([^0-9A-Za-z_]|$)|[$][{]0[}]|BASH_SOURCE/) selfread = 1
    }
    function tco_tag(m,   t) { t = m; sub(/^[ \t]*#[ \t]*/, "", t); sub(/[:=]$/, "", t); return t }
    END {
      if (err == "" && hi <= hn) err = "EOF inside the heredoc " hw[hi] " of line " hl[hi]
      if (err == "" && st != "") err = "EOF inside an open quote"
      if (err != "") { print "ERR\t" err; exit 3 }
      for (n = 1; n <= NR; n++) print ((selfread && com[n]) ? "S" : cls[n])
    }
  ' "$1"
}

# tco_verdict <base-classes> <head-classes> <diff> — the class of the change:
# `CO` every changed line is I; `X` a changed line is code; else the first
# reason a comment edit is not inert: `D\t<tag>` or `S`.
tco_verdict() {
  LC_ALL=C awk -F'\t' -v bf="$1" -v hf="$2" '
    FILENAME == bf { bc[FNR] = $1; bt[FNR] = $2; next }
    FILENAME == hf { hc[FNR] = $1; ht[FNR] = $2; next }
    function see(c, t) {
      if (c == "I") return
      if (c == "X" || c == "") { x = 1; return }
      if (c == "D" && d == "") d = t
      if (c == "S") s = 1
    }
    /^@@ / {
      h = $0; sub(/^@@ -/, "", h); sub(/ @@.*$/, "", h)
      split(h, sides, " "); sub(/^[+]/, "", sides[2]); split(sides[1], o, ","); split(sides[2], n, ",")
      ob = (o[2] == "") ? 1 : o[2] + 0; nh = (n[2] == "") ? 1 : n[2] + 0
      for (i = 0; i < ob; i++) see(bc[o[1] + i], bt[o[1] + i])
      for (i = 0; i < nh; i++) see(hc[n[1] + i], ht[n[1] + i])
    }
    END {
      if (x) print "X"; else if (d != "") print "D\t" d; else if (s) print "S"; else print "CO"
    }
  ' "$1" "$2" "$3"
}

# tco_set <changed> — writes $TI_TMP/comment-only (see THE SET) and the
# fallback lines. rc != 0 only on an internal failure.
tco_set() {
  local changed="$1" out="$TI_TMP/comment-only" w="$TI_TMP/tco" p v rc any=0 verdict
  : > "$out" || return 1
  while IFS= read -r p; do [[ $p =~ \.(sh|bash)$ ]] && { any=1; break; }; done < "$changed"
  [ "$any" = 1 ] || return 0
  v="${TI_COMMENT_ONLY-}"
  case "$v" in ''|1) ;; 0) return 0 ;; *) echo "comment-only: off (TI_COMMENT_ONLY=$v)" >&2; return 0 ;; esac
  [ -n "${TI_NAMED_BASE:-}" ] || return 0
  while IFS= read -r p; do
    tco_eligible "$p" || continue
    git -C "$ROOT" show "$TI_NAMED_BASE:$p" > "$w.base" 2>/dev/null || continue
    [ -f "$ROOT/$p" ] || continue
    diff -U0 "$w.base" "$ROOT/$p" > "$w.diff" 2>/dev/null; rc=$?
    [ "$rc" -eq 0 ] && continue
    [ "$rc" -eq 1 ] || { echo "comment-only: fallback (parse: diff rc $rc: $p)" >&2; continue; }
    tco_classes "$w.base" > "$w.bc"; rc=$?
    [ "$rc" -eq 0 ] || { echo "comment-only: fallback (parse: $(cut -f2 "$w.bc" | head -1) at base: $p)" >&2; continue; }
    tco_classes "$ROOT/$p" > "$w.hc"; rc=$?
    [ "$rc" -eq 0 ] || { echo "comment-only: fallback (parse: $(cut -f2 "$w.hc" | head -1) at head: $p)" >&2; continue; }
    verdict=$(tco_verdict "$w.bc" "$w.hc" "$w.diff") || return 1
    case "$verdict" in
      CO) printf '%s\n' "$p" >> "$out" ;;
      D$'\t'*) echo "comment-only: fallback (directive ${verdict#D$'\t'}: $p)" >&2 ;;
      S) echo "comment-only: fallback (self-read: $p)" >&2 ;;
    esac
  done < "$changed"
  return 0
}

# tco_apply <map> <why> — the filter (see THE FILTER). rc != 0 leaves <why>
# as it was.
tco_apply() {
  local map="$1" why="$2" set="$TI_TMP/comment-only" w="$TI_TMP/tco" s p
  [ -s "$set" ] || return 0
  [ -n "${FNR_AWK_NAMES_DIR:-}" ] || return 1
  declare -F ti_rootvars >/dev/null || return 1
  # The candidates: `<P>\t<suite>` for each suite with a droppable row for P.
  LC_ALL=C awk -F'\t' -v sf="$set" '
    FILENAME == sf { if ($0 != "") co[$0] = 1; next }
    ($2 == "source" || $2 == "closure") && ($3 in co) { print $3 "\t" $1; next }
    $2 == "named" { i = match($3, /#[^#]*$/); if (i > 0 && (substr($3, 1, i - 1) in co)) print substr($3, 1, i - 1) "\t" $1 }
  ' "$set" "$why" | LC_ALL=C sort -u > "$w.cand" || return 1
  : > "$w.kept"
  if [ -s "$w.cand" ]; then
    # The directory rows: `<P>\t<suite>\t<D>` for a candidate whose map row D
    # is a directory above P.
    LC_ALL=C awk -F'\t' -v cf="$w.cand" '
      FILENAME == cf { bys[$2] = bys[$2] "\t" $1; next }
      $2 ~ /\/$/ { n = split(bys[$1], ps, "\t"); for (j = 1; j <= n; j++) if (ps[j] != "" && index(ps[j], $2) == 1) print ps[j] "\t" $1 "\t" $2 }
    ' "$w.cand" "$map" | LC_ALL=C sort -u > "$w.dirs" || return 1
    local suites=()
    while IFS= read -r s; do [ -n "$s" ] && [ -f "$ROOT/$s" ] && suites+=("$s"); done < <(cut -f2 "$w.dirs" | LC_ALL=C sort -u)
    if [ "${#suites[@]}" -gt 0 ]; then
      ti_rootvars "${suites[@]}" > "$w.rv" || return 1
      local args=(); for s in "${suites[@]}"; do args+=("./$s"); done
      ( cd "$ROOT" && LC_ALL=C awk -v df="$w.dirs" -v rvfile="$w.rv" \
          -v ROOTVAR_="$TI_ROOTVAR" -v RR="$TI_READ_RE" -v XR="$TI_RUN_RE" "$TI_AWK_NORM$FNR_AWK_NAMES_DIR"'
          BEGIN { FS = "\t" }
          FILENAME == df { dby[$2] = dby[$2] "\t" $1 "\034" $3; next }
          FILENAME == rvfile { if ($2 == "@PYARGV@") PY_[$1] = 1
                               else if ($1 in RV_) RV_[$1] = RV_[$1] "|" $2
                               else RV_[$1] = $2
                               next }
          FNR == 1 { f = FILENAME; sub(/^\.\//, "", f); nd = split(dby[f], Ds, "\t") }
          /^[ \t]*#/ { next }
          nd > 1 {
            ln = ti_norm($0, f)
            if (ln ~ XR && ln !~ RR) next
            for (j = 1; j <= nd; j++) if (Ds[j] != "") {
              split(Ds[j], dp, "\034")
              if (!((dp[1], f) in kept) && names_dir(ln, dp[2])) { kept[dp[1], f] = 1; print dp[1] "\t" f }
            }
          }
        ' "$w.dirs" "$w.rv" "${args[@]}" ) | LC_ALL=C sort -u > "$w.kept" || return 1
    fi
  fi
  LC_ALL=C awk -F'\t' -v cf="$w.cand" -v kf="$w.kept" '
    FILENAME == cf { cand[$1, $2] = 1; next }
    FILENAME == kf { keep[$1, $2] = 1; next }
    { p = ""
      if ($2 == "source" || $2 == "closure") p = $3
      else if ($2 == "named") { i = match($3, /#[^#]*$/); if (i > 0) p = substr($3, 1, i - 1) }
      if (p != "" && ((p, $1) in cand) && !((p, $1) in keep)) next
      print }
  ' "$w.cand" "$w.kept" "$why" > "$why.tco" || return 1
  # The counts for the log, from the files the filter read and wrote.
  LC_ALL=C awk -F'\t' -v sf="$set" -v kf="$w.kept" -v bf="$why" -v af="$why.tco" '
    function pathof(   i) {
      if ($2 == "named") { i = match($3, /#[^#]*$/); return (i > 0) ? substr($3, 1, i - 1) : "" }
      return $3
    }
    FILENAME == sf { if ($0 != "") { co[$0] = 1; ord[++np] = $0 }; next }
    FILENAME == kf { if (!(($1, $2) in kd)) { kd[$1, $2] = 1; d[$1]++ }; next }
    FILENAME == bf { p = pathof(); if (p in co) { rb[p]++; if (!((p, $1) in sb)) { sb[p, $1] = 1; nb[p]++ } }; next }
    FILENAME == af { p = pathof(); if (p in co) { ra[p]++; if (!((p, $1) in sa)) { sa[p, $1] = 1; na[p]++ } }; next }
    END { for (i = 1; i <= np; i++) { p = ord[i]
            printf "comment-only: %s: dropped %d row(s), %d of %d suite(s) left, %d kept by a directory scan\n", p, rb[p] - ra[p], na[p], nb[p], d[p] } }
  ' "$set" "$w.kept" "$why" "$why.tco" > "$w.log" || return 1
  mv "$why.tco" "$why" || return 1
  cat "$w.log" >&2
  return 0
}
