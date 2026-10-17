#!/bin/bash
# bin/lib/test-impact-fn-reach.sh — A LIBRARY CHANGE SELECTS BY THE CHANGED
# FUNCTIONS, NOT BY EVERY SOURCER (BH-7288, wave 2 of BH-7033).
#
# Sourced by bin/test-impact.sh (one hook line in ti_select_from), never run.
# It reads the selector's own globals and helpers: ROOT, TI_TMP,
# TI_NAMED_BASE, TI_READ_RE, TI_RUN_RE, TI_ROOTVAR, TI_AWK_NORM, ti_rootvars.
#
# A diff to bin/lib/x.sh selected every suite that reaches x.sh: the suites
# that source it, the suites that reach it through another script's `source`
# line, and every suite with a bin/lib/ directory row. On 7a15b598 that was 2,044
# sourcer suites for bin/lib/env-path.sh. fnr_apply runs after ti_why_rows wrote the why
# file and before the count. For each ELIGIBLE changed path L it:
#
#   1. diffs the base copy (git show $TI_NAMED_BASE:L) against $ROOT/L and maps
#      every changed line to a function block of its side (rule P). The names
#      are the CHANGED SET F. A deleted function and the old name of a renamed
#      one come from the base side.
#   2. closes F over CALLERS, on the head tree, over every *.sh / *.bash under
#      bin cron fly checks guardrails (the roots of ti_source_edges) and every
#      tests/ subfolder (tests/lib, tests/mc, a fixture: a suite helper that
#      calls a lib function, BH-7288). Comment
#      lines do not count. A call inside a bin/lib/** function whose name passes
#      the name rule adds that NAME and the closure goes on. A call at the top
#      level of a bin/lib/** file, in a bin/lib/** function with a short name,
#      or anywhere in a file outside bin/lib/ adds that FILE to the caller
#      paths. L itself never becomes a caller path. A top-level line of L that
#      names a name in the set runs on every `source` of L, so every sourcer
#      reaches it: that is the `top-level call` fallback. A short-named
#      function of L that calls a name in the set is the `short name` fallback.
#   3. keeps a suite S that reaches L through a source/closure row when one of
#      these is true: S has a reads/learned/regression row for L; S has a named
#      row L#f with f in the closed set; a non-comment line of S names a name in
#      the closed set (whole token, the ti_named_scan rule); S has a map row for
#      a caller path; or S reaches L through a directory row D (bin/lib/,
#      bin/lib/mc/) and a non-comment line of S names D and is not a pure
#      run/copy line (matches TI_RUN_RE and not TI_READ_RE). That last one keeps
#      the linters that grep, find or `for f in` a directory, and drops the
#      suites that only copy it into a scratch tree.
#   4. removes the source/closure rows (S, L) of every S it did not keep, and
#      every named row L#g with g not in the closed set. Every other row stays
#      byte-identical.
#
# RULE E, ELIGIBLE (fnr_eligible): L matches ^bin/lib/(.+/)?[^/]+\.sh$, L is
# not this file (the selector's own lib keeps today's reach), the knob is on,
# and TI_NAMED_BASE is set. Any other path is untouched and logs nothing.
#
# FALLBACK: each reason keeps today's every-sourcer rows for THAT path only,
# and logs `fn-reach: fallback (<why>: <path>)`.
#   no base                     TI_NAMED_BASE empty (a --changed replay)
#   no base copy                git show base:L fails (added, or a rename's new side)
#   deleted file                $ROOT/L is missing
#   no hunks                    diff -U0 shows no changed line (mode only)
#   top-level change at <side>:<n>  a changed line outside every function
#                               block. A comment or a blank line counts.
#   top-level call of <n>       a top-level line of L names <n>, a name in the
#                               closed set (it runs at load time)
#   short name <n>              a changed (or calling) function of L fails the
#                               name rule: no `_` or under 6 characters
#   parse: <reason>             an unclosed block, or diff/git failed
#   call closure did not settle more than FNR_ROUNDS_MAX caller rounds
#   lib failed                  (the hook line) the source or fnr_apply failed
#
# RULE P, FUNCTION BLOCKS. A block starts on a COLUMN-0 definition line
# (`name() {`, `name () {`, `function name {`, `function name() {`), or on one
# whose body opener is alone on the next line. A definition line with as many
# `{` as `}` (one or more) is a one-line block. Otherwise the block ends at the
# first later line that starts with `}` (or `)` for a `name() (` subshell
# body). An indented definition at the top level (an `if command -v` guard) is
# not a block, so a change there is top-level. A column-0 definition before the
# close, or EOF, is `parse: unclosed`. Known safe-side limit: a heredoc in a
# body with `}` at column 0 ends the block early, and the lines after it read
# as top-level, so the path falls back.
#
# THE NAME RULE is TI_AWK_DEFS's: an underscore and 6 or more characters.
#
# KNOB: env TI_FN_REACH. Unset, empty or 1 is on (BH-7033: every wave ships
# ON, and the knob is the rollback). 0 is today's reach. Any other value is
# off too, the safe side. Off logs one `fn-reach: off (TI_FN_REACH=<v>)` line
# when the diff has a bin/lib/ .sh path.
#
# BLIND SPOTS, on purpose. The closure follows calls written as tokens. It does
# not follow exec / `bash <script>` (the BH-1203 N2 note in bin/test-impact.sh)
# and it does not follow dynamic dispatch by a built name ("${pfx}_run", a
# function name in a catalog TSV). The nightly full run (harness-nightly.yml,
# --tier nightly-full) is the backstop. The head side is $ROOT/L, as
# ti_named_rows reads it, also for a <a>..<b> range whose b is not the worktree.
#
# No set -e. Every work file is $TI_TMP/fnr.*. Every awk is LC_ALL=C and
# mawk-safe. fnr_apply returns 0 when it narrowed, fell back or was off; any
# other rc leaves the why file as it was.

FNR_ROUNDS_MAX=50
FNR_SELF=bin/lib/test-impact-fn-reach.sh

# fnr_lib_path <p> — rc 0 when <p> is a bin/lib/ .sh path other than this lib
# (rules E1 and E2).
fnr_lib_path() {
  [[ $1 =~ ^bin/lib/(.+/)?[^/]+\.sh$ ]] || return 1
  [ "$1" != "$FNR_SELF" ]
}

# fnr_eligible <p> — rule E: rc 0 when <p> is narrowed (or tried).
fnr_eligible() {
  fnr_lib_path "$1" || return 1
  case "${TI_FN_REACH:-1}" in 1) ;; *) return 1 ;; esac
  [ -n "${TI_NAMED_BASE:-}" ]
}

# The definition shape and the block rules, shared by the strict parser
# (fnr_blocks, the changed file) and the caller pass (fnr_callers).
FNR_AWK_P='
function fnr_isdef(l) {
  return (l ~ /^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_]*[ \t]*[(][ \t]*[)]/ || l ~ /^function[ \t]+[A-Za-z_]/)
}
function fnr_name(l,   nm) {
  nm = l; sub(/^function[ \t]+/, "", nm); sub(/[^A-Za-z0-9_].*$/, "", nm); return nm
}
function fnr_name_ok(nm) { return (index(nm, "_") > 0 && length(nm) >= 6) }
function fnr_count(s, c,   t) { t = s; return gsub(c, "", t) }
# fnr_body <line> — what follows the definition: "1" a one-line block, "}" or
# ")" the closer of an open block, "" no body opener on this line.
function fnr_body(l,   r) {
  r = l; sub(/^function[ \t]+/, "", r); sub(/^[A-Za-z_][A-Za-z0-9_]*[ \t]*/, "", r)
  sub(/^[(][ \t]*[)]/, "", r)
  if (index(r, "{") > 0) {
    if (fnr_count(l, "[{]") == fnr_count(l, "[}]")) return "1"
    return "}"
  }
  if (r ~ /^[ \t]*[(]/) {
    if (fnr_count(r, "[(]") == fnr_count(r, "[)]")) return "1"
    return ")"
  }
  return ""
}
'

# fnr_blocks <file> — `<start>\t<end>\t<name>` per block (rule P), or one
# `ERR\t<reason>` line and rc 3.
fnr_blocks() {
  LC_ALL=C awk "$FNR_AWK_P"'
    function fail(why) { print "ERR\t" why; bad = 1; exit 3 }
    pend != "" {
      if ($0 ~ /^[{]/) { open = pend; closer = "}"; pend = ""; next }
      if ($0 ~ /^[(]/) { open = pend; closer = ")"; pend = ""; next }
      fail("definition of " pend " at line " st " has no body")
    }
    open != "" {
      if ((closer == "}" && $0 ~ /^[}]/) || (closer == ")" && $0 ~ /^[)]/)) {
        print st "\t" NR "\t" open; open = ""; next
      }
      if (fnr_isdef($0)) fail("unclosed " open " at line " st)
      next
    }
    fnr_isdef($0) {
      nm = fnr_name($0); st = NR; b = fnr_body($0)
      if (b == "1") print NR "\t" NR "\t" nm
      else if (b == "") pend = nm
      else { open = nm; closer = b }
    }
    END {
      if (bad) exit 3
      if (open != "") { print "ERR\tunclosed " open " at line " st; exit 3 }
      if (pend != "") { print "ERR\tdefinition of " pend " at line " st " has no body"; exit 3 }
    }
  ' "$1"
}

# fnr_changed_fns <p> — the changed set F of <p>, one name per line, or one
# `FB\t<why>` line. rc != 0 only on an internal failure.
fnr_changed_fns() {
  local p="$1" w="$TI_TMP/fnr.cf" rc
  [ -f "$ROOT/$p" ] || { printf 'FB\tdeleted file\n'; return 0; }
  git -C "$ROOT" show "$TI_NAMED_BASE:$p" > "$w.base" 2>/dev/null || { printf 'FB\tno base copy\n'; return 0; }
  diff -U0 "$w.base" "$ROOT/$p" > "$w.diff" 2>/dev/null; rc=$?
  [ "$rc" -eq 0 ] && { printf 'FB\tno hunks\n'; return 0; }
  [ "$rc" -eq 1 ] || { printf 'FB\tparse: diff rc %s\n' "$rc"; return 0; }
  fnr_blocks "$w.base" > "$w.bb"; rc=$?
  [ "$rc" -eq 0 ] || { printf 'FB\tparse: %s at base\n' "$(cut -f2 "$w.bb" | head -1)"; return 0; }
  fnr_blocks "$ROOT/$p" > "$w.hb"; rc=$?
  [ "$rc" -eq 0 ] || { printf 'FB\tparse: %s at head\n' "$(cut -f2 "$w.hb" | head -1)"; return 0; }
  LC_ALL=C awk -F'\t' -v bbf="$w.bb" -v hbf="$w.hb" "$FNR_AWK_P"'
    FILENAME == bbf { nb++; bs[nb] = $1; be[nb] = $2; bn[nb] = $3; next }
    FILENAME == hbf { nh++; hs[nh] = $1; he[nh] = $2; hn[nh] = $3; next }
    function mapline(side, ln,   i) {
      if (side == "base") { for (i = 1; i <= nb; i++) if (ln >= bs[i] && ln <= be[i]) { F[bn[i]] = 1; return } }
      else { for (i = 1; i <= nh; i++) if (ln >= hs[i] && ln <= he[i]) { F[hn[i]] = 1; return } }
      if (fb == "") fb = "top-level change at " side ":" ln
    }
    /^@@ / {
      h = $0; sub(/^@@ -/, "", h); sub(/ @@.*$/, "", h)
      split(h, sides, " "); sub(/^[+]/, "", sides[2]); split(sides[1], o, ","); split(sides[2], n, ",")
      ob = (o[2] == "") ? 1 : o[2] + 0; nb2 = (n[2] == "") ? 1 : n[2] + 0
      for (i = 0; i < ob; i++) mapline("base", o[1] + i)
      for (i = 0; i < nb2; i++) mapline("head", n[1] + i)
    }
    END {
      if (fb != "") { print "FB\t" fb; exit 0 }
      for (f in F) if (!fnr_name_ok(f)) { print "FB\tshort name " f; exit 0 }
      for (f in F) print f
    }
  ' "$w.bb" "$w.hb" "$w.diff" | LC_ALL=C sort
}

# fnr_callers <seeds> — <seeds> is `<L>\t<name>` rows. Prints, per L, the
# closed name set `<L>\tN\t<name>` and the caller paths `<L>\tP\t<path>`, or
# one `<L>\tFB\t<why>`. ONE parse of the head tree serves every L.
fnr_callers() {
  local seeds="$1" files=() f
  while IFS= read -r f; do [ -n "$f" ] && files+=("./$f"); done < <(
    cd "$ROOT" && { find bin cron fly checks guardrails -type f \( -name '*.sh' -o -name '*.bash' \) 2>/dev/null
                    find tests -mindepth 2 -type f \( -name '*.sh' -o -name '*.bash' \) 2>/dev/null; } | LC_ALL=C sort)
  [ "${#files[@]}" -gt 0 ] || files=(/dev/null)
  ( cd "$ROOT" && LC_ALL=C awk -F'\t' -v sf="$seeds" -v maxr="$FNR_ROUNDS_MAX" "$FNR_AWK_P"'
      BEGIN { SEP = "\034" }
      FILENAME == sf { if (!(($1, $2) in sd)) { sd[$1, $2] = 1; seed[$1] = seed[$1] SEP $2 }; next }
      # One file at a time: a line belongs to the open column-0 block or to the
      # top level. A file the lenient pass cannot close (bad) gives every token
      # to the FILE, the wide answer.
      FNR == 1 { flush(); cur = FILENAME; sub(/^\.\//, "", cur); open = ""; pend = ""; bad = 0 }
      {
        u = "top"
        if (pend != "") {
          if ($0 ~ /^[{]/) { open = pend; closer = "}" } else if ($0 ~ /^[(]/) { open = pend; closer = ")" } else bad = 1
          u = "fn\t" pend; pend = ""
        } else if (open != "") {
          u = "fn\t" open
          if ((closer == "}" && $0 ~ /^[}]/) || (closer == ")" && $0 ~ /^[)]/)) open = ""
          else if (fnr_isdef($0)) bad = 1
        }
        if (open == "" && u == "top" && fnr_isdef($0)) {
          nm = fnr_name($0); b = fnr_body($0); u = "fn\t" nm
          if (b == "") pend = nm; else if (b != "1") { open = nm; closer = b }
        }
        if ($0 ~ /^[ \t]*#/) next
        line = $0; gsub(/[^A-Za-z0-9_]/, " ", line); k = split(line, tok, " ")
        for (i = 1; i <= k; i++) if (fnr_name_ok(tok[i])) rec[u, tok[i]] = 1
      }
      function flush(   key, pr, unit, islib, fn) {
        if (cur == "") return
        if (open != "" || pend != "") bad = 1
        islib = (cur ~ /^bin\/lib\//)
        for (key in rec) {
          split(key, pr, SUBSEP)
          if (bad || !islib) unit = "F" SEP cur
          else if (pr[1] == "top") unit = "T" SEP cur
          else { fn = substr(pr[1], 4)
                 if (fnr_name_ok(fn)) unit = "N" SEP fn; else unit = "S" SEP cur SEP fn }
          if (!((pr[2], unit) in seen)) { seen[pr[2], unit] = 1; callers[pr[2]] = callers[pr[2]] "\035" unit }
        }
        delete rec; cur = ""
      }
      END {
        flush()
        for (L in seed) {
          delete inset; delete cp; delete front; fb = ""
          nf = split(substr(seed[L], 2), s0, SEP)
          for (i = 1; i <= nf; i++) { inset[s0[i]] = 1; front[s0[i]] = 1 }
          rounds = 0
          while (fb == "") {
            delete nxt; grew = 0
            for (n in front) {
              nu = split(substr(callers[n], 2), us, "\035")
              for (j = 1; j <= nu; j++) {
                split(us[j], up, SEP)
                if (up[1] == "N") { if (!(up[2] in inset)) { inset[up[2]] = 1; nxt[up[2]] = 1; grew = 1 } }
                else if (up[1] == "S" && up[2] == L) { fb = "short name " up[3]; break }
                # A top-level line of L that names n runs on every `source` of
                # L, so every sourcer reaches n (BH-7288 lead review). So does
                # any line of L when the lenient pass could not parse L (F).
                else if (up[2] == L) { fb = "top-level call of " n; break }
                else cp[up[2]] = 1
              }
              if (fb != "") break
            }
            if (fb != "" || !grew) break
            if (++rounds > maxr) { fb = "call closure did not settle"; break }
            delete front; for (n in nxt) front[n] = 1
          }
          if (fb != "") { print L "\tFB\t" fb; continue }
          for (n in inset) print L "\tN\t" n
          for (p in cp) print L "\tP\t" p
        }
      }
    ' "$seeds" "${files[@]}" ) | LC_ALL=C sort -u
}

# fnr_keep <map> <why> <closed> — `<L>\t<suite>` for every candidate suite of a
# narrowed L that step 3 keeps. <closed> is fnr_callers' N and P rows.
fnr_keep() {
  local map="$1" why="$2" closed="$3" w="$TI_TMP/fnr.keep" s
  # The candidates: suites with a source/closure row for a narrowed L.
  awk -F'\t' -v cf="$closed" '
    FILENAME == cf { nar[$1] = 1; next }
    ($2 == "source" || $2 == "closure") && ($3 in nar) { print $3 "\t" $1 }
  ' "$closed" "$why" | LC_ALL=C sort -u > "$w.cand"
  [ -s "$w.cand" ] || return 0
  # Kept by a row already in the why file, or by a caller path's map row.
  awk -F'\t' -v cf="$w.cand" -v nf="$closed" -v wf="$why" '
    FILENAME == cf { cand[$1, $2] = 1; bys[$2] = bys[$2] "\t" $1; next }
    FILENAME == nf { if ($2 == "N") nm[$1, $3] = 1; else if ($2 == "P") cpby[$3] = cpby[$3] "\t" $1; next }
    FILENAME == wf {
      if (($2 == "reads" || $2 == "learned" || $2 == "regression") && (($3, $1) in cand)) print $3 "\t" $1
      if ($2 == "named") { i = match($3, /#[^#]*$/); if (i > 0) { p = substr($3, 1, i - 1); g = substr($3, i + 1)
        if (((p, $1) in cand) && ((p, g) in nm)) print p "\t" $1 } }
      next }
    { n = split(cpby[$2], ls, "\t"); for (j = 1; j <= n; j++) if (ls[j] != "" && ((ls[j], $1) in cand)) print ls[j] "\t" $1 }
  ' "$w.cand" "$closed" "$why" "$map" > "$w.rows" || return 1
  # The directory rows: `<L>\t<suite>\t<D>` for a candidate whose map row D is
  # a directory above L.
  awk -F'\t' -v cf="$w.cand" '
    FILENAME == cf { bys[$2] = bys[$2] "\t" $1; next }
    $2 ~ /\/$/ { n = split(bys[$1], ls, "\t"); for (j = 1; j <= n; j++) if (ls[j] != "" && index(ls[j], $2) == 1) print ls[j] "\t" $1 "\t" $2 }
  ' "$w.cand" "$map" | LC_ALL=C sort -u > "$w.dirs" || return 1
  # ONE token-and-directory pass over the candidate suites' text.
  local suites=()
  while IFS= read -r s; do [ -n "$s" ] && [ -f "$ROOT/$s" ] && suites+=("$s"); done < <(cut -f2 "$w.cand" | LC_ALL=C sort -u)
  if [ "${#suites[@]}" -gt 0 ]; then
    ti_rootvars "${suites[@]}" > "$w.rv" || return 1
    local args=(); for s in "${suites[@]}"; do args+=("./$s"); done
    ( cd "$ROOT" && LC_ALL=C awk -v cf="$w.cand" -v nf="$closed" -v df="$w.dirs" -v rvfile="$w.rv" \
        -v ROOTVAR_="$TI_ROOTVAR" -v RR="$TI_READ_RE" -v XR="$TI_RUN_RE" "$TI_AWK_NORM"'
        BEGIN { FS = "\t" }
        FILENAME == cf { lsby[$2] = lsby[$2] "\t" $1; next }
        FILENAME == nf { if ($2 == "N") nm[$1, $3] = 1; next }
        FILENAME == df { dby[$2] = dby[$2] "\t" $1 "\034" $3; next }
        FILENAME == rvfile { if ($2 == "@PYARGV@") PY_[$1] = 1
                             else if ($1 in RV_) RV_[$1] = RV_[$1] "|" $2
                             else RV_[$1] = $2
                             next }
        FNR == 1 { f = FILENAME; sub(/^\.\//, "", f); nl = split(lsby[f], Ls, "\t"); nd = split(dby[f], Ds, "\t") }
        /^[ \t]*#/ { next }
        {
          line = $0; gsub(/[^A-Za-z0-9_]/, " ", line); k = split(line, tok, " ")
          for (j = 1; j <= nl; j++) if (Ls[j] != "" && !((Ls[j], f) in kept))
            for (i = 1; i <= k; i++) if ((Ls[j], tok[i]) in nm) { kept[Ls[j], f] = 1; print Ls[j] "\t" f; break }
          if (nd > 1) {
            ln = ti_norm($0, f)
            if (!(ln ~ XR && ln !~ RR))
              for (j = 1; j <= nd; j++) if (Ds[j] != "") {
                split(Ds[j], dp, "\034")
                if (!((dp[1], f) in kept) && names_dir(ln, dp[2])) { kept[dp[1], f] = 1; print dp[1] "\t" f }
              }
          }
        }
        # names_dir — the line spells directory D (with or without its slash)
        # rooted (@ROOT@/D) or as a bare word, and the next byte ends it: the
        # end, a non-path byte, or a slash that a glob, quote or variable follows.
        function names_dir(ln, d,   dn, rest, off, i, pre, nx) {
          dn = d; sub(/\/$/, "", dn)
          rest = ln; off = 0
          while ((i = index(rest, dn)) > 0) {
            pre = (off + i > 1) ? substr(ln, off + i - 1, 1) : ""
            nx = substr(ln, off + i + length(dn))
            if ((substr(ln, 1, off + i - 1) ~ /@ROOT@\/$/ || pre == "" || pre !~ /[\/A-Za-z0-9._@+$*{-]/) &&
                (nx == "" || nx ~ /^[^A-Za-z0-9._\/-]/ || nx ~ /^\/($|[^A-Za-z0-9._-])/)) return 1
            off += i; rest = substr(rest, i + 1)
          }
          return 0
        }
      ' "$w.cand" "$closed" "$w.dirs" "$w.rv" "${args[@]}" ) >> "$w.rows" || return 1
  fi
  LC_ALL=C sort -u "$w.rows"
}

# fnr_apply <map> <changed> <why> — the filter. rc 0 when it narrowed, fell
# back or was off; any other rc leaves <why> as it was.
fnr_apply() {
  local map="$1" changed="$2" why="$3" w="$TI_TMP/fnr" p any=0 v line
  declare -F ti_rootvars >/dev/null || return 1
  : > "$w.seeds"; : > "$w.paths"
  while IFS= read -r p; do
    fnr_lib_path "$p" || continue
    any=1
    printf '%s\n' "$p" >> "$w.paths"
  done < "$changed"
  [ "$any" = 1 ] || return 0
  v="${TI_FN_REACH-}"
  case "$v" in ''|1) ;; *) echo "fn-reach: off (TI_FN_REACH=$v)" >&2; return 0 ;; esac
  : > "$w.fb"; : > "$w.fset"
  while IFS= read -r p; do
    if [ -z "${TI_NAMED_BASE:-}" ]; then printf '%s\tno base\n' "$p" >> "$w.fb"; continue; fi
    fnr_changed_fns "$p" > "$w.one" || return 1
    if IFS= read -r line < "$w.one" && [[ $line == FB$'\t'* ]]; then
      printf '%s\t%s\n' "$p" "${line#FB$'\t'}" >> "$w.fb"; continue
    fi
    if [ ! -s "$w.one" ]; then printf '%s\tno hunks\n' "$p" >> "$w.fb"; continue; fi
    awk -v p="$p" '{ print p "\t" $0 }' "$w.one" >> "$w.fset"
  done < "$w.paths"
  : > "$w.closed"
  if [ -s "$w.fset" ]; then
    fnr_callers "$w.fset" > "$w.callers" || return 1
    awk -F'\t' '$2 == "FB" { print $1 "\t" $3 }' "$w.callers" >> "$w.fb"
    awk -F'\t' -v fbf="$w.fb" 'FILENAME == fbf { fb[$1] = 1; next } !($1 in fb) && ($2 == "N" || $2 == "P")' \
      "$w.fb" "$w.callers" > "$w.closed" || return 1
  fi
  if [ -s "$w.closed" ]; then
    fnr_keep "$map" "$why" "$w.closed" > "$w.kept" || return 1
    awk -F'\t' -v cf="$w.closed" -v kf="$w.kept" '
      FILENAME == cf { nar[$1] = 1; if ($2 == "N") nm[$1, $3] = 1; next }
      FILENAME == kf { keep[$1, $2] = 1; next }
      ($2 == "source" || $2 == "closure") && ($3 in nar) && !(($3, $1) in keep) { next }
      $2 == "named" { i = match($3, /#[^#]*$/)
                      if (i > 0) { q = substr($3, 1, i - 1); if ((q in nar) && !((q, substr($3, i + 1)) in nm)) next } }
      { print }
    ' "$w.closed" "$w.kept" "$why" > "$why.fnr" || return 1
    # The counts for the log, read before the rename.
    awk -F'\t' -v cf="$w.closed" -v ff="$w.fset" -v kf="$w.kept" -v wf="$why" '
      # mawk: no ternary on an element the same statement creates.
      FILENAME == ff { F[$1, $2] = 1; c = ++nfx[$1]
                       if (c == 1) fl[$1] = $2; else if (c <= 8) fl[$1] = fl[$1] "," $2; else if (c == 9) fl[$1] = fl[$1] ",…"
                       next }
      FILENAME == cf { nar[$1] = 1; if ($2 == "P") ncp[$1]++; else if (!(($1, $3) in F)) ncn[$1]++; next }
      FILENAME == kf { kept[$1, $2] = 1; next }
      ($2 == "source" || $2 == "closure") && ($3 in nar) && !(($3, $1) in cnt) { cnt[$3, $1] = 1; m[$3]++; if (($3, $1) in kept) k[$3]++ }
      END { for (L in nar) printf "%s\tfn-reach: %s: kept %d of %d sourcer suite(s) (%d function(s): %s; %d caller path(s); %d caller name(s))\n",
                                   L, L, k[L], m[L], nfx[L], fl[L], ncp[L], ncn[L] }
    ' "$w.fset" "$w.closed" "$w.kept" "$why" > "$w.log" || return 1
    mv "$why.fnr" "$why" || return 1
  else
    : > "$w.log"
  fi
  # One line per eligible path, in the diff order.
  while IFS= read -r p; do
    line=$(awk -F'\t' -v p="$p" '$1 == p { print $2; exit }' "$w.fb")
    if [ -n "$line" ]; then echo "fn-reach: fallback ($line: $p)" >&2
    else awk -F'\t' -v p="$p" '$1 == p { print $2; exit }' "$w.log" >&2; fi
  done < "$w.paths"
  return 0
}
