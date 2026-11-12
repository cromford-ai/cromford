#!/bin/bash
# checks/sql-command-injection/check.sh
#
# FAMILY 53e19b60469c — "Injection (SQL / command / path)", 5 recurrences in 30
# days across project-4, pool-project-4, pool-project-3 and pool-project-2.
#
# WHAT IT CATCHES. Three concrete shapes, each one an added line a tool can see:
#   1. Prisma's by-name-unsafe escape hatches, $queryRawUnsafe / $executeRawUnsafe.
#   2. SQL assembled inside a template literal that interpolates (`... ${x} ...`).
#      The TAGGED form (prisma.$queryRaw`SELECT ... ${id}`) is parameterized and
#      is NOT flagged — only a template literal used as a plain string is.
#   3. A shell command assembled by template interpolation and handed to
#      exec/execSync/spawn.
#
# WHAT SHAPE 2 ACCEPTS (BH-4501). A shape-2 line is NOT reported when EVERY
# ${...} on it is one of these, read off the same file's ADDED lines only:
#   (a) N, where N has exactly one column-0 `[export ]const N = <literal>` with a
#       quoted, no-backslash string (or a backtick one with no $), and N is not
#       declared, assigned, destructured or taken as a parameter (of an arrow,
#       a function or a class/object method) anywhere else in the file's added
#       lines; or N.join(<literal>) where that const is a one-line array of such
#       literals and every other occurrence of N on an added line is also
#       N.join(<literal>), since a push, N[i] = or a splice mutates a const array.
#   (b) cond ? A : B, A || B, or A + B, with every A/B safe (cond is never
#       interpolated, so it is not read); a quoted literal; a nested template
#       literal whose own interpolations are all safe.
#   (c) a bind placeholder: the template text right before ${ is "?", and the
#       expression is an integer literal or X.length[ +/- int], where X is a
#       local array (as in (d), minus the push rule: X.length is a number).
#   (d) N.join(<literal>) where N = [] is declared on an added line at or
#       before the use, every line between that declaration and the use is an
#       added line, and from the declaration to the next one every occurrence of
#       N is the declaration, N.join(, N.length, or N.push(<args>) closing on its
#       line with every arg safe. Any other occurrence (a reassignment, N[i] =,
#       splice, a spread, N passed to a call) makes it unsafe. Shape (c) takes
#       the same array rule but lets any push and a ...N spread through.
#   Everything else still flags: request reads, url.searchParams, body fields,
#   function calls, function-local consts, and any name whose declaration is a
#   context line the check never sees. When in doubt the answer is a hit.
#
# EXCLUSIONS. checks/sql-command-injection/exclusions.tsv, 4 TAB fields
# (kind action pattern why). A path row (an awk ERE) removes every shape on a
# matching file. A tag row names a template tag that binds its parameters
# (sql, Prisma.sql, $queryRaw): a shape-2 line is not a hit when EVERY SQL
# template on it opens right after a listed tag, with an identifier boundary
# before the tag, an optional <...> TypeScript generic and optional spaces.
# sql.unsafe(`...`) is a call, not a tag. Action note prints
# "NOTE<TAB>path:line<TAB>reason" (shown by bin/checks-run.sh, never counted);
# skip prints nothing. A missing list or an invalid row is no exclusion.
#
# Reads the normalized added-line stream on stdin (path<TAB>line<TAB>text).
# Prints "path:line<TAB>reason" per hit. rc 0 = clean, rc 1 = hits.
# DETECTION ONLY: it reads stdin and writes stdout. Nothing else.
set -uo pipefail
LIST="$(dirname "$0")/exclusions.tsv"
OUT=$(awk -F'\t' -v LIST="$LIST" '
# The first tag row whose tag the template opening at s[i] follows, or 0.
function tag_row(s, i,   pre, n, d, j, c, k, tl) {
  pre = substr(s, 1, i - 1); sub(/[[:space:]]+$/, "", pre)
  n = length(pre)
  if (n > 1 && substr(pre, n, 1) == ">" && substr(pre, n - 1, 1) !~ /[-=]/) {
    d = 0
    for (j = n; j >= 1; j--) {
      c = substr(pre, j, 1)
      if (c == ">") d++
      else if (c == "<" && !--d) break
    }
    if (j >= 1) { pre = substr(pre, 1, j - 1); sub(/[[:space:]]+$/, "", pre); n = length(pre) }
  }
  for (k = 1; k <= NT; k++) {
    tl = length(TG[k])
    if (n < tl || substr(pre, n - tl + 1) != TG[k]) continue
    if (n > tl && substr(pre, n - tl, 1) ~ /[A-Za-z0-9_$]/) continue
    return TR[k]
  }
  return 0
}
# The tag row that covers every SQL template on line s, or 0 when one is not
# tagged (or the line does not balance, which fails toward a hit).
function tagged(s,   n, i, j, c, body, r, got) {
  if (!NT) return 0
  n = length(s); i = 1; got = 0
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\"" || c == SQ) { i = skip_str(s, i, c); if (!i) return 0; continue }
    if (c == BT) {
      j = skip_tpl(s, i); if (!j) return 0
      body = substr(s, i, j - i)
      if (body ~ /(SELECT|INSERT INTO|UPDATE |DELETE FROM|DROP |WHERE |FROM )/ && index(body, "${")) {
        r = tag_row(s, i); if (!r) return 0
        if (!got) got = r
      }
      i = j; continue
    }
    i++
  }
  return got
}
# Prints the NOTE (action note) for list row r and record i.
function excluded(r, i, why) {
  if (XA[r] == "note") printf "NOTE\t%s:%s\t%s [excluded by checks/sql-command-injection/exclusions.tsv row %d: %s]\n", P[i], F2[i], why, XL[r], XW[r]
}
function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
function hashes(k,   o) { o = ""; while (k-- > 0) o = o "#"; return o }
# The index just past the closing quote of the string opening at s[i], or 0.
function skip_str(s, i, q,   n, c) {
  n = length(s)
  for (i++; i <= n; i++) { c = substr(s, i, 1); if (c == "\\") { i++; continue }; if (c == q) return i + 1 }
  return 0
}
# The index just past the closing backtick of the template opening at s[i], or 0.
function skip_tpl(s, i,   n, c) {
  n = length(s)
  for (i++; i <= n; i++) {
    c = substr(s, i, 1)
    if (c == "\\") { i++; continue }
    if (c == BT) return i + 1
    if (c == "$" && substr(s, i + 1, 1) == "{") { i = skip_grp(s, i + 2, "{", "}"); if (!i) return 0; i-- }
  }
  return 0
}
# From s[i], just inside an open bracket: the index just past its close, or 0.
function skip_grp(s, i, op, cl,   n, c, d) {
  n = length(s); d = 0
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\"" || c == SQ) { i = skip_str(s, i, c); if (!i) return 0; continue }
    if (c == BT) { i = skip_tpl(s, i); if (!i) return 0; continue }
    if (c == op) d++
    else if (c == cl) { if (!d) return i + 1; d-- }
    i++
  }
  return 0
}
# s with every char inside a string, template or bracket turned into "#", so an
# operator found by index() is a top-level one. MERR=1 when s does not balance.
function mask(s,   o, n, i, j, c, d) {
  MERR = 0; o = ""; n = length(s); d = 0; i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == "\"" || c == SQ || c == BT) {
      j = (c == BT) ? skip_tpl(s, i) : skip_str(s, i, c)
      if (!j) { MERR = 1; return "" }
      o = o hashes(j - i); i = j; continue
    }
    if (c == "(" || c == "[" || c == "{") d++
    else if (c == ")" || c == "]" || c == "}") { if (--d < 0) { MERR = 1; return "" } }
    else if (!d) { o = o c; i++; continue }
    o = o "#"; i++
  }
  if (d) MERR = 1
  return o
}
function is_q(m, j) { return substr(m, j, 1) == "?" && substr(m, j + 1, 1) != "." && substr(m, j + 1, 1) != "?" && substr(m, j - 1, 1) != "?" }
# Is the interpolated expression e (on record i of path p) one the list above accepts?
function safe(e, p, i, before, depth,   m, n, j, k, nest, name) {
  if (depth > 16) return 0
  e = trim(e); if (e == "") return 0
  if (before == "?" && (e ~ /^[0-9]+$/ || (e ~ /^[A-Za-z_][A-Za-z0-9_]*[.]length([[:space:]]*[-+][[:space:]]*[0-9]+)?$/ \
      && local_array(p, i, substr(e, 1, index(e, ".") - 1), "c", depth)))) return 1
  m = mask(e); if (MERR) return 0
  n = length(m)
  if (m ~ /^#+$/ && substr(e, 1, 1) == "(" && substr(e, n, 1) == ")") return safe(substr(e, 2, n - 2), p, i, before, depth + 1)
  for (j = 1; j <= n; j++) if (is_q(m, j)) break
  if (j <= n) {
    nest = 0
    for (k = j + 1; k <= n; k++) {
      if (is_q(m, k)) nest++
      else if (substr(m, k, 1) == ":") { if (!nest) break; nest-- }
    }
    if (k > n) return 0
    return safe(substr(e, j + 1, k - j - 1), p, i, "", depth + 1) && safe(substr(e, k + 1), p, i, "", depth + 1)
  }
  if ((j = index(m, "||"))) return safe(substr(e, 1, j - 1), p, i, "", depth + 1) && safe(substr(e, j + 2), p, i, "", depth + 1)
  if ((j = index(m, "+"))) {
    if (substr(m, j + 1, 1) ~ /[+=]/) return 0
    return safe(substr(e, 1, j - 1), p, i, "", depth + 1) && safe(substr(e, j + 1), p, i, "", depth + 1)
  }
  if (e ~ ("^" LIT "$")) return 1
  if (substr(e, 1, 1) == BT && skip_tpl(e, 1) == n + 1) return tpl_safe(e, p, i, depth)
  if (e ~ /^[A-Za-z_][A-Za-z0-9_]*$/) return modconst(p, e) == "str"
  if (e ~ ("^[A-Za-z_][A-Za-z0-9_]*[.]join[(][[:space:]]*" LIT "[[:space:]]*[)]$")) {
    name = substr(e, 1, index(e, ".") - 1)
    return modconst(p, name) == "arr" || local_array(p, i, name, "d", depth)
  }
  return 0
}
# Every interpolation of the template literal e is safe, each judged with the
# character before its ${ (so a nested `... ?${binds.length}` is a placeholder).
function tpl_safe(e, p, i, depth,   n, j, k) {
  n = length(e) - 1
  for (j = 2; j <= n; j++) {
    if (substr(e, j, 1) == "\\") { j++; continue }
    if (substr(e, j, 2) != "${") continue
    k = skip_grp(e, j + 2, "{", "}"); if (!k) return 0
    if (!safe(substr(e, j + 2, k - j - 3), p, i, substr(e, j - 1, 1), depth + 1)) return 0
    j = k - 1
  }
  return 1
}
# The kind ("str"/"arr") of module const N in path p, or "" when N is not one.
function modconst(p, N,   key) {
  key = p SUBSEP N
  if (!(key in MCACHE)) MCACHE[key] = (MC[key] == 1 && !rebound(p, N, MD[key]) \
      && (MK[key] != "arr" || arr_join_only(p, N, MD[key]))) ? MK[key] : ""
  return MCACHE[key]
}
# A const array is still mutable: 1 only when every occurrence of N on an added
# line of p other than its declaration (record skip) is N.join(<literal>). A
# push, an index assignment, a splice or N handed to a call all answer 0.
function arr_join_only(p, N, skip,   k, x, s, W, st, after) {
  W = "(^|[^A-Za-z0-9_$.])" N "([^A-Za-z0-9_$]|$)"
  for (k = 1; k <= PN[p]; k++) {
    x = PI[p, k]; if (x == skip) continue
    s = TX[x]
    while (match(s, W)) {
      st = (substr(s, RSTART, length(N)) == N) ? RSTART : RSTART + 1
      after = substr(s, st + length(N))
      if (after !~ ("^[.]join[(][[:space:]]*" LIT "[[:space:]]*[)]")) return 0
      s = after
    }
  }
  return 1
}
# 1 when any added line of p other than record skip declares, assigns,
# destructures or takes as a parameter the name N.
function rebound(p, N, skip,   k, x, t, W) {
  W = "(^|[^A-Za-z0-9_$.])" N
  for (k = 1; k <= PN[p]; k++) {
    x = PI[p, k]; if (x == skip) continue
    t = TX[x]; if (!index(t, N)) continue
    if (t ~ ("(^|[^A-Za-z0-9_$.])(const|let|var|function|class)[[:space:]]+" N "([^A-Za-z0-9_$]|$)")) return 1
    if (t ~ (W "[[:space:]]*[-+*/%&|^?<>]*=([^=>]|$)")) return 1
    if (t ~ (W "[[:space:]]*=>")) return 1
    if (t ~ ("((^|[^$])[{]|[,:])[[:space:]]*([.][.][.])?" N "[[:space:]]*([,}=]|$)")) return 1
    if (t ~ ("[[][[:space:]]*([.][.][.])?" N "[[:space:]]*[],]")) return 1
    if ((t ~ /=>|function/ || t ~ MHEAD) && t ~ ("[(,][[:space:]]*([.][.][.])?" N "[[:space:]]*([,)=]|$)")) return 1
    if (t ~ ("^[[:space:]]*" N "[[:space:]]*,?[[:space:]]*$")) return 1
    if (t ~ ("catch[[:space:]]*[(][[:space:]]*" N "([^A-Za-z0-9_$]|$)")) return 1
  }
  return 0
}
# Shapes (c) and (d): N is a local array declared "N = []" on an added line at
# or before record i, with no unseen (context) line between there and i, and
# every occurrence of N from that declaration to the next is a use that keeps it
# an array — and, in mode "d", every value pushed into it is itself safe.
function local_array(p, i, N, mode, depth,   key, D, W, dk, k, end, x, ln, s, st, after, c, args, m, j, a) {
  key = p SUBSEP N
  if (key in BUSY) return 0
  D = "(^|[^A-Za-z0-9_$.])" N "[[:space:]]*=[[:space:]]*[[][[:space:]]*[]]"
  W = "(^|[^A-Za-z0-9_$.])" N "([^A-Za-z0-9_$]|$)"
  for (dk = PK[i]; dk >= 1; dk--) if (TX[PI[p, dk]] ~ D) break
  if (dk < 1) return 0
  for (ln = L[PI[p, dk]]; ln <= L[i]; ln++) if (!((p, ln) in HAS)) return 0
  for (end = dk + 1; end <= PN[p]; end++) if (TX[PI[p, end]] ~ D) break
  BUSY[key] = 1
  for (k = dk; k < end; k++) {
    x = PI[p, k]; s = TX[x]
    while (match(s, W)) {
      st = (substr(s, RSTART, length(N)) == N) ? RSTART : RSTART + 1
      after = substr(s, st + length(N))
      if (after ~ /^[[:space:]]*=[[:space:]]*[[][[:space:]]*[]]/ || after ~ /^[.]length([^A-Za-z0-9_$]|$)/ || after ~ /^[.]join[(]/) {
        s = after; continue
      }
      if (mode == "c" && (after ~ /^[.]push[(]/ || (st > 3 && substr(s, st - 3, 3) == "..."))) { s = after; continue }
      if (mode == "d" && after ~ /^[.]push[(]/) {
        c = skip_grp(after, 7, "(", ")")
        if (!c) { delete BUSY[key]; return 0 }
        args = substr(after, 7, c - 8)
        if (trim(args) != "") {
          m = mask(args); if (MERR) { delete BUSY[key]; return 0 }
          while ((j = index(m, ","))) {
            a = substr(args, 1, j - 1); args = substr(args, j + 1); m = substr(m, j + 1)
            if (!safe(a, p, x, "", depth + 1)) { delete BUSY[key]; return 0 }
          }
          if (!safe(args, p, x, "", depth + 1)) { delete BUSY[key]; return 0 }
        }
        s = substr(after, c); continue
      }
      delete BUSY[key]; return 0
    }
  }
  delete BUSY[key]
  return 1
}
# A shape-2 line is safe when every ${ on it closes on the line and is safe.
function line_safe(i,   s, n, j, k) {
  s = TX[i]; n = length(s)
  for (j = 1; j < n; j++) {
    if (substr(s, j, 2) != "${") continue
    k = skip_grp(s, j + 2, "{", "}"); if (!k) return 0
    if (!safe(substr(s, j + 2, k - j - 3), P[i], i, (j > 1 ? substr(s, j - 1, 1) : ""), 0)) return 0
  }
  return 1
}
BEGIN {
  SQ = sprintf("%c", 39); BT = "`"
  LIT = "(\"[^\"\\\\]*\"|" SQ "[^" SQ "\\\\]*" SQ ")"
  STATIC = "^(" LIT "|`[^`\\\\$]*`)$"
  # A class or object method head, `q(`, `async fetch(`, `static *gen(`. A
  # plain call at the start of a line matches too, which only adds hits.
  MHEAD = "^[[:space:]]*((static|async|get|set)[[:space:]]+)*[*#]?[A-Za-z_$][A-Za-z0-9_$]*[[:space:]]*[(]"
  ARR = "^[[][[:space:]]*(" LIT "([[:space:]]*,[[:space:]]*" LIT ")*[[:space:]]*,?)?[[:space:]]*[]]$"
  NX = 0; NT = 0; ln = 0
  while ((getline row < LIST) > 0) {
    ln++
    if (row ~ /^[[:space:]]*(#|$)/) continue
    if (split(row, a, "\t") != 4 || a[1] !~ /^(path|tag)$/ || a[2] !~ /^(note|skip)$/ || a[3] == "") continue
    NX++; XK[NX] = a[1]; XA[NX] = a[2]; XW[NX] = a[4]; XL[NX] = ln
    if (a[1] == "path") { NPATH++; PX[NPATH] = a[3]; PR[NPATH] = NX }
    else { NT++; TG[NT] = a[3]; TR[NT] = NX }
  }
  close(LIST)
}
{
  n++; P[n] = $1; L[n] = $2 + 0; F2[n] = $2; F3[n] = $3
  TX[n] = substr($0, length($1) + length($2) + 3)
  k = ++PN[$1]; PI[$1, k] = n; PK[n] = k; HAS[$1, L[n]] = 1
  t = TX[n]
  if (t ~ /^(export[[:space:]]+)?const[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/) {
    v = t; sub(/^(export[[:space:]]+)?const[[:space:]]+/, "", v)
    match(v, /^[A-Za-z_][A-Za-z0-9_]*/); name = substr(v, 1, RLENGTH)
    v = substr(v, RLENGTH + 1); sub(/^[[:space:]]*=[[:space:]]*/, "", v); sub(/[[:space:]]*;?[[:space:]]*$/, "", v)
    key = $1 SUBSEP name; MC[key]++; MD[key] = n
    MK[key] = (v ~ STATIC) ? "str" : (v ~ ARR) ? "arr" : ""
  }
}
END {
  for (i = 1; i <= n; i++) {
    t = F3[i]; xr = 0
    for (k = 1; k <= NPATH; k++) if (P[i] ~ PX[k]) { xr = PR[k]; break }
    if (t ~ /[$](query|execute)RawUnsafe[[:space:]]*\(/) {
      r = "raw SQL through $queryRawUnsafe/$executeRawUnsafe — use the tagged $queryRaw`` form, which parameterizes"
    } else if (t ~ /[$](queryRaw|executeRaw)[[:space:]]*(<[^`]*>)?[[:space:]]*[(`]/) {
      continue   # the tagged/parameterized form is the fix, not the finding
    } else if (t ~ /`[^`]*(SELECT|INSERT INTO|UPDATE |DELETE FROM|DROP |WHERE |FROM )[^`]*[$][{]/) {
      if (line_safe(i)) continue
      r = "SQL built by string interpolation inside a template literal — parameterize it"
      if (!xr) xr = tagged(TX[i])
    } else if (t ~ /(execSync|execFileSync|spawnSync|[^A-Za-z_.]exec|^exec)[[:space:]]*\(/ && t ~ /`[^`]*[$][{]/) {
      r = "shell command built by template interpolation — pass an argv array, never an interpolated string"
    } else continue
    r = r " (family 53e19b60469c)"
    if (xr) { excluded(xr, i, r); continue }
    printf "%s:%s\t%s\n", P[i], F2[i], r
  }
}'); RC=$?
# A crashed or unparsable program is rc 2, never an empty "clean" answer.
[ "$RC" -eq 0 ] || exit 2
[ -n "$OUT" ] || exit 0
printf '%s\n' "$OUT"
exit 1
