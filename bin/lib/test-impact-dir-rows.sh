#!/bin/bash
# bin/lib/test-impact-dir-rows.sh — A DIRECTORY ROW THAT IS NOT A SCAN IS
# NARROWED TO THE FILES IT REACHES (BH-8050, slice C0).
#
# Sourced by bin/test-impact.sh (hook lines in ti_build_map), never run. It
# reads the selector's globals: ROOT, TI_TMP, TI_ROOTVAR, TI_AWK_INDEX,
# TI_AWK_NORM, TI_READ_RE, TI_RUN_RE.
#
# The map gives a suite a `<dir>/` row for any rooted token that ends at a
# directory, and a bin script an edge to a directory for a `source` line with
# a dynamic tail. On 593c547c, 295 suites carried a `bin/` row and 752 a
# `bin/lib/` row, so a change to one lane script selected ~300 suites through
# `bin/` alone. Most of those rows are not scans. They are:
#
#   a LOOP-BOUND tail   for f in a.sh b.sh; do cp "$DIR/bin/$f" "$H/bin/$f"; done
#   a WHOLE COPY        cp -a "$DIR/bin" "$T/alt/bin"; bash "$T/alt/bin/x.sh"
#
# THE SUITE RULE (tdr_rows). The main scan writes one `<suite>\t<line>\t<dir>
# \t<pos>\t<len>` row for each token that made a directory row. For a row
# (S, D), each such line is:
#
#   LOOP-BOUND  the token is followed by `$v` / `${v}` and v is BOUND in S
#               (below). It resolves to D<word><suffix> for each word; the
#               line resolves when every result is a tracked file.
#   COPY-WHOLE  the token names D itself or a glob in D, on a line that
#               matches TI_RUN_RE, does not match TI_READ_RE, has a copy verb
#               (cp, rsync, ln, install, tar), is not in a `for … in` list, and
#               copies to a path that ends in /D. The line resolves when every
#               scratch token of S under D (`<anything>/D<tail>`, not rooted)
#               resolves: a tail that is a tracked file adds that file, a bound
#               `$v` adds its words; D itself, an unbound `$` or a glob keeps
#               the row, except on a line that is only mkdir, chmod or the copy.
#   other       anything else (a scan verb, a glob in a loop header, an unbound
#               `$`, a root passed whole): the line keeps D.
#
# The row (S, D) is DROPPED only when every line that made it resolves and the
# row is not PROTECTED (a treedir, learned or regression row). Every file a
# line resolves to is added as an exact row, even when D is kept, and the
# closure step of ti_build_map closes the added rows over `source`.
#
# THE EDGE RULE (tdr_edges). The edge scan writes `<script>\t<line>\t<dir>` for
# each source line that made a directory edge (never the BH-6293 mm_load edge,
# which the selector writes without this record). For an edge (X, D), each such
# line must hold exactly one BOUND variable v, and the line with v replaced by
# each word must make no D edge and at least one file edge under D. Then the
# edge X -> D is replaced by X -> each file. Otherwise the edge stays.
#
# BOUND. v is bound in a file F when F has a `for v in <words>` statement with
# literal words ([A-Za-z0-9._/+@-], quotes allowed, or "${A[@]}" of a bound
# array A=(<words>) on one line), and F has no other binding of v: no
# non-literal `for v in`, no `for v` without `in` (a list continued with `\`
# is non-literal: `\` is not a literal word), no assignment (`v=`, `v+=`, `local v=`), no `read`/`mapfile`/`getopts`/
# `printf -v` line that names v. A comment line binds nothing. The words of the
# innermost literal loop whose body holds the line are used (its scope runs to
# the first `done` after its header); a line outside every such body uses the
# union of all the literal loops of v.
#
# WHAT IT DOES NOT FOLLOW: exec (the BH-1203 N2 note in bin/test-impact.sh). A
# suite that copies bin/ and runs x.sh reaches x.sh and what x.sh sources, not
# what x.sh runs. The nightly full corpus (harness-nightly.yml) is the backstop.
#
# KNOB: env TI_DIR_ROWS. Unset, empty or 1 is on (BH-7033: every reach wave
# ships on, the knob is the rollback). 0 is off. Any other value is off and
# logs one `dir-rows: off (TI_DIR_ROWS=<v>)` line. ti_inputs (the suite
# fingerprint) always builds with 0.
#
# LOG: on, one `dir-rows: narrowed <k> directory row(s) of <s> suite(s), <e>
# edge(s)` line per map build when k or e is not 0, counted from the rows and
# edges the awk passes actually dropped. `audit` sets TDR_QUIET=1: its contract
# is an empty stderr. A failure is one `dir-rows: fallback
# (…)` line from the hook, and the input is left as it was.
#
# No set -e. Every work file is $TI_TMP/tdr.*. Every awk is LC_ALL=C and
# mawk-safe (no regex intervals, no ternary on an element being created).

# tdr_enabled — rc 0 when the knob is on; logs the off line for an odd value.
tdr_enabled() {
  case "${TI_DIR_ROWS-}" in
    ''|1) return 0 ;;
    0) return 1 ;;
    *) echo "dir-rows: off (TI_DIR_ROWS=$TI_DIR_ROWS)" >&2; return 1 ;;
  esac
}

# The binding rules, shared by the suite and the edge pass. tdr_bind(F, s, n)
# reads line n of file F; tdr_words(F, v, n) is the word list of v at line n,
# or "\001" when v is not bound there.
TDR_AWK_BIND='
function tdr_unq(w) {
  if (length(w) >= 2 && ((substr(w, 1, 1) == "\"" && substr(w, length(w), 1) == "\"") || (substr(w, 1, 1) == "\047" && substr(w, length(w), 1) == "\047")))
    return substr(w, 2, length(w) - 2)
  return w
}
function tdr_bind(F, s, ln,   rest, m, v, lst, n, a, i, w, nm, cnt, k, arr, body, t, dn) {
  if (s ~ /^[ \t]*#/) return
  arr = ""
  if (match(s, /^[ \t]*(local[ \t]+|declare[ \t]+-a[ \t]+|readonly[ \t]+)?[A-Za-z_][A-Za-z0-9_]*=[(][^()]*[)][ \t]*;?[ \t]*$/)) {
    arr = s; sub(/^[ \t]*(local[ \t]+|declare[ \t]+-a[ \t]+|readonly[ \t]+)?/, "", arr)
    body = arr; sub(/=.*$/, "", arr); sub(/^[^(]*[(]/, "", body); sub(/[)].*$/, "", body)
    ARRDEF[F, arr]++
    n = split(body, a, /[ \t]+/)
    for (i = 1; i <= n; i++) {
      if (a[i] == "") continue
      w = tdr_unq(a[i])
      if (w ~ /^[A-Za-z0-9._\/+@-]+$/) ARRW[F, arr] = ARRW[F, arr] " " w
      else ARRUNB[F, arr] = 1
    }
  }
  rest = s
  while (match(rest, /(^|[;&|({ \t])for[ \t]+[A-Za-z_][A-Za-z0-9_]*/)) {
    m = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
    v = m; sub(/^.*for[ \t]+/, "", v)
    if (!match(rest, /^[ \t]+in([ \t]|;|$)/)) { UNB[F, v] = 1; continue }
    lst = substr(rest, RLENGTH + 1)
    if (substr(rest, RLENGTH, 1) == ";") lst = ""
    else if (match(lst, /;|[ \t]do([ \t]|$)/)) lst = substr(lst, 1, RSTART - 1)
    n = split(lst, a, /[ \t]+/); cnt = 0; t = ""
    for (i = 1; i <= n; i++) {
      if (a[i] == "") continue
      w = tdr_unq(a[i])
      if (w ~ /^[$][{][A-Za-z_][A-Za-z0-9_]*[[]@[]][}]$/) {
        nm = substr(w, 3); sub(/[[].*$/, "", nm); AREF[F, v] = AREF[F, v] " " nm; cnt++; continue
      }
      if (w ~ /^[A-Za-z0-9._\/+@-]+$/) { t = t " " w; cnt++; continue }
      UNB[F, v] = 1
    }
    if (cnt == 0) { UNB[F, v] = 1; continue }
    k = ++LN_[F, v]; LS_[F, v, k] = ln; LE_[F, v, k] = ln; LW_[F, v, k] = t
    W_[F, v] = W_[F, v] t
    OPEN_[F, ++NO_[F]] = v SUBSEP k
  }
  # Each `done` word closes the innermost open literal loop of this file.
  t = s
  while (match(t, /(^|[;&| \t])done([;&|)<> \t]|$)/)) {
    t = substr(t, RSTART + RLENGTH)
    if (NO_[F] > 0) { split(OPEN_[F, NO_[F]], dn, SUBSEP); LE_[F, dn[1], dn[2]] = ln; NO_[F]-- }
  }
  rest = s
  while (match(rest, /(^|[^A-Za-z0-9_$.\/-])[A-Za-z_][A-Za-z0-9_]*([[][^=]*)?[+]?=/)) {
    m = substr(rest, RSTART, RLENGTH); rest = substr(rest, RSTART + RLENGTH)
    sub(/^[^A-Za-z_]/, "", m); sub(/[[+=].*$/, "", m)
    if (m == arr) continue
    ASG[F, m] = 1
  }
  if (s ~ /(^|[^A-Za-z0-9_-])(read|readarray|mapfile|getopts)[ \t]/ || s ~ /printf[ \t]+-v[ \t]/) {
    t = s; gsub(/[^A-Za-z0-9_]+/, " ", t); n = split(t, a, " ")
    for (i = 1; i <= n; i++) RD[F, a[i]] = 1
  }
}
function tdr_free(F, v) {
  return (((F, v) in UNB) || ((F, v) in ASG) || ((F, v) in RD) || ((F, v) in ARRDEF))
}
function tdr_words(F, v, ln,   out, best, k, n, a, i) {
  if (!((F, v) in LN_) || tdr_free(F, v)) return "\001"
  best = 0
  for (k = 1; k <= LN_[F, v]; k++)
    if (LS_[F, v, k] <= ln && ln <= LE_[F, v, k] && (best == 0 || LS_[F, v, k] > LS_[F, v, best])) best = k
  out = (best > 0) ? LW_[F, v, best] : W_[F, v]
  n = split(AREF[F, v], a, " ")
  for (i = 1; i <= n; i++) {
    if (ARRDEF[F, a[i]] != 1 || ((F, a[i]) in ARRUNB) || ((F, a[i]) in ASG) || ((F, a[i]) in RD) || ((F, a[i]) in UNB)) return "\001"
    out = out ARRW[F, a[i]]
  }
  return out
}
# tdr_var(t) — rc 1 when t starts with $name or ${name}; sets VN_ and VL_.
function tdr_var(t) {
  if (match(t, /^[$][{][A-Za-z_][A-Za-z0-9_]*[}]/)) { VN_ = substr(t, 3, RLENGTH - 3); VL_ = RLENGTH; return 1 }
  if (match(t, /^[$][A-Za-z_][A-Za-z0-9_]*/)) { VN_ = substr(t, 2, RLENGTH - 1); VL_ = RLENGTH; return 1 }
  return 0
}
function tdr_stop(c) { return (c == "$" || c == "*" || c == "?" || c == "[" || c == "{" || c == "(" || c == "`") }
'

# tdr_rows <index> <direct> <protected> — the direct rows with every
# resolved directory row dropped and the files it named added, sorted, on
# stdout. Reads $TI_TMP/dirlines.suites and $TI_TMP/rootvars, writes
# `<rows dropped> <suites>` to $TI_TMP/tdr.rows.n. rc 2 on any failure.
tdr_rows() {
  local idx="$1" direct="$2" prot="$3" dl="$TI_TMP/dirlines.suites" s _files=()
  [ -r "$dl" ] && [ -r "$idx" ] && [ -r "$direct" ] || return 2
  [ -r "$prot" ] || return 2
  while IFS= read -r s; do [ -n "$s" ] && _files+=("$s"); done < <(cut -f1 "$dl" | LC_ALL=C sort -u)
  if [ "${#_files[@]}" -eq 0 ]; then
    echo "0 0" > "$TI_TMP/tdr.rows.n" || return 2
    LC_ALL=C sort -u "$direct"; return
  fi
  ( cd "$ROOT" && LC_ALL=C awk -v idxfile="$idx" -v rvfile="$TI_TMP/rootvars" -v dlfile="$dl" \
      -v protfile="$prot" -v directfile="$direct" -v cntfile="$TI_TMP/tdr.rows.n" \
      -v ROOTVAR_="$TI_ROOTVAR" -v RR="$TI_READ_RE" -v XR="$TI_RUN_RE" \
      "$TI_AWK_INDEX$TI_AWK_NORM$TDR_AWK_BIND"'
      FILENAME == idxfile { FILE_[$0] = 1; adddirs($0); next }
      FILENAME == rvfile  { split($0, f, "\t")
                            if (f[2] == "@PYARGV@") PY_[f[1]] = 1
                            else if (f[1] in RV_) RV_[f[1]] = RV_[f[1]] "|" f[2]
                            else RV_[f[1]] = f[2]
                            next }
      FILENAME == dlfile  { split($0, f, "\t"); k = f[1] SUBSEP f[3]
                            if (!(k in CAND)) { CAND[k] = 1 }
                            OCC[k] = OCC[k] " " f[2] ":" f[4] ":" f[5]; next }
      FILENAME == protfile { PROT[$0] = 1; next }
      FILENAME == directfile {
        if (!decided) { decide(); decided = 1 }
        if ($0 in DROP) { dropped++; split($0, z, "\t"); if (!(z[1] in DS)) { DS[z[1]] = 1; nds++ }; next }
        print; next
      }
      { SR[FILENAME, FNR] = $0; SN[FILENAME, FNR] = ti_norm($0, FILENAME); NL[FILENAME] = FNR
        tdr_bind(FILENAME, $0, FNR) }
      END {
        if (!decided) decide()
        for (k in ADD) print k
        print (dropped + 0) " " (nds + 0) > cntfile
      }
      function decide(   k, p, S, D, n, ls, i, q, okall) {
        for (k in CAND) {
          split(k, p, SUBSEP); S = p[1]; D = p[2]
          okall = 1
          n = split(OCC[k], ls, " ")
          for (i = 1; i <= n; i++) {
            split(ls[i], q, ":")
            if (!occ(S, D, q[1] + 0, q[2] + 0, q[3] + 0)) okall = 0
          }
          if (okall && !((S "\t" D) in PROT)) DROP[S "\t" D] = 1
        }
      }
      # loopres(F, base, t, ln) — t starts at a `$`: rc 1 when the variable is
      # bound and base<word><suffix> is a tracked file for every word.
      function loopres(F, base, t, ln,   ws, n, a, i, sfx, p, okk) {
        if (!tdr_var(t)) return 0
        ws = tdr_words(F, VN_, ln); if (ws == "\001") return 0
        t = substr(t, VL_ + 1)
        match(t, /^[A-Za-z0-9._\/@+-]*/); sfx = substr(t, 1, RLENGTH)
        if (tdr_stop(substr(t, RLENGTH + 1, 1))) return 0
        n = split(ws, a, " "); if (n == 0) return 0
        okk = 1
        for (i = 1; i <= n; i++) {
          p = base a[i] sfx; gsub(/\/\/+/, "/", p); sub(/^\.\//, "", p)
          if (isfile(p)) ADD[F "\t" p] = 1; else okk = 0
        }
        return okk
      }
      function occ(S, D, ln, pos, len,   N, tok, rest) {
        N = SN[S, ln]
        tok = substr(N, pos, len); if (substr(tok, 1, 7) != "@ROOT@/") return 0
        tok = substr(tok, 8); rest = substr(N, pos + len)
        if (index(tok, "*") == 0 && substr(rest, 1, 1) == "$") return loopres(S, tok, rest, ln)
        if (rest ~ /^"?[$]/) return 0
        if (!copyline(N, D, pos)) return 0
        return scratch(S, D)
      }
      function copyline(N, D, pos,   t, off, fs, hl, r2, fe) {
        if (N !~ XR || N ~ RR) return 0
        if (N !~ /(^|[^A-Za-z0-9_.-])(cp|rsync|ln|install|tar)[ \t]/) return 0
        t = N; off = 0
        while (match(t, /(^|[;&|({ \t])for[ \t]+[A-Za-z_][A-Za-z0-9_]*[ \t]+in[ \t]/)) {
          fs = off + RSTART; hl = RLENGTH
          r2 = substr(N, fs + hl); fe = length(N)
          if (match(r2, /;|[ \t]do([ \t]|$)/)) fe = fs + hl + RSTART - 2
          if (pos >= fs && pos <= fe) return 0
          off = fs + hl - 1; t = substr(N, off + 1)
        }
        return dest(N, D)
      }
      # dest — a non-rooted /D on the line, ended by /, a quote, a blank or EOL.
      function dest(N, D,   Dn, t, off, i, c) {
        Dn = D; sub(/\/$/, "", Dn); t = N; off = 0
        while ((i = index(t, "/" Dn)) > 0) {
          off += i; t = substr(t, i + 1)
          if (off > 6 && substr(N, off - 6, 6) == "@ROOT@") continue
          c = substr(N, off + 1 + length(Dn), 1)
          if (c == "" || c == "/" || c == "\"" || c == "\047" || c == " " || c == "\t") return 1
        }
        return 0
      }
      function exempt(N, D,   Dn) {
        if (N ~ /(^|[^A-Za-z0-9_.-])(bash|sh|exec|source|python|python3|env)[ \t]/ || N ~ /^[ \t]*[.][ \t]/) return 0
        if (N ~ /^[ \t]*(mkdir|chmod)[ \t]/) return 1
        Dn = D; sub(/\/$/, "", Dn)
        if (N ~ /(^|[^A-Za-z0-9_.-])(cp|rsync|ln|install|tar)[ \t]/ && index(N, "@ROOT@/" Dn) > 0) return 1
        return 0
      }
      # scratch(S, D) — rc 1 when every scratch token of S under D resolves.
      function scratch(S, D,   k, Dn, f, N, ex, t, off, i, c, lit, L, nx, p, d) {
        k = S SUBSEP D
        if (k in SCR) return SCR[k]
        SCR[k] = 0
        Dn = D; sub(/\/$/, "", Dn)
        for (f = 1; f <= NL[S]; f++) {
          if (SR[S, f] ~ /^[ \t]*#/) continue
          N = SN[S, f]; if (index(N, "/" Dn) == 0) continue
          ex = exempt(N, D); t = N; off = 0
          while ((i = index(t, "/" Dn)) > 0) {
            off += i; t = substr(t, i + 1)
            if (off > 6 && substr(N, off - 6, 6) == "@ROOT@") continue
            c = substr(N, off + 1 + length(Dn), 1)
            if (c ~ /[A-Za-z0-9._@+-]/) continue
            if (c != "/") { if (!ex) return 0; continue }
            lit = substr(N, off + 2 + length(Dn))
            match(lit, /^[A-Za-z0-9._\/@+-]*/); L = substr(lit, 1, RLENGTH); nx = substr(lit, RLENGTH + 1, 1)
            if (nx == "$") {
              if (loopres(S, D L, substr(lit, RLENGTH + 1), f)) continue
              if (!ex) return 0
              continue
            }
            if (tdr_stop(nx)) { if (!ex) return 0; continue }
            if (L == "") { if (!ex) return 0; continue }
            p = D L; sub(/[.,]+$/, "", p)
            if (isfile(p)) { ADD[S "\t" p] = 1; continue }
            d = asdir(p); if (d != "" && !ex) ADD[S "\t" d] = 1
          }
        }
        SCR[k] = 1
        return 1
      }
    ' "$idx" "$TI_TMP/rootvars" "$dl" "$prot" "${_files[@]}" "$direct" ) > "$TI_TMP/tdr.rows.out" || return 2
  [ -s "$TI_TMP/tdr.rows.n" ] || return 2
  LC_ALL=C sort -u "$TI_TMP/tdr.rows.out"
}

# tdr_edges <index> <edges> — the source edges with every resolved directory
# edge replaced by its file edges, sorted, on stdout. Reads
# $TI_TMP/dirlines.edges, writes the drop count to $TI_TMP/tdr.edges.n.
# rc 2 on any failure.
tdr_edges() {
  local idx="$1" edges="$2" dl="$TI_TMP/dirlines.edges" s _files=()
  [ -r "$dl" ] && [ -r "$idx" ] && [ -r "$edges" ] || return 2
  while IFS= read -r s; do [ -n "$s" ] && [ -f "$ROOT/$s" ] && _files+=("$s"); done < <(cut -f1 "$dl" | LC_ALL=C sort -u)
  if [ "${#_files[@]}" -eq 0 ]; then
    echo 0 > "$TI_TMP/tdr.edges.n" || return 2
    LC_ALL=C sort -u "$edges"; return
  fi
  ( cd "$ROOT" && LC_ALL=C awk -v idxfile="$idx" -v dlfile="$dl" -v edgefile="$edges" \
      -v cntfile="$TI_TMP/tdr.edges.n" "$TI_AWK_INDEX$TDR_AWK_BIND"'
      FILENAME == idxfile { FILE_[$0] = 1; adddirs($0); next }
      FILENAME == dlfile  { split($0, f, "\t"); k = f[1] SUBSEP f[3]
                            OCC[k] = OCC[k] " " f[2]; next }
      FILENAME == edgefile {
        if (!decided) { decide(); decided = 1 }
        if ($0 in DROP) { dropped++; next }
        print; next
      }
      { SR[FILENAME, FNR] = $0; tdr_bind(FILENAME, $0, FNR) }
      END {
        if (!decided) decide()
        for (k in ADD) print k
        print (dropped + 0) > cntfile
      }
      # targets(line, sd) — the edges one source line makes, the rule of
      # ti_source_edges in bin/test-impact.sh, as " <target>" words.
      function targets(line, sd,   out, n, w, i, t, j, cand, d) {
        out = ""
        gsub(/\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/, " ", line)
        n = split(line, w, /[^A-Za-z0-9._\/@+-]+/)
        for (i = 1; i <= n; i++) {
          t = w[i]
          if (t == "" || t !~ /\//) continue
          sub(/^[.\/]+/, "", t)
          if (t == "" || t !~ /\//) continue
          for (j = 0; j < 2; j++) {
            cand = (j == 0) ? t : sd t
            if (isfile(cand) && cand ~ /\.(sh|bash|py|mjs|js)$/) { out = out " " cand; break }
            d = asdir(cand)
            if (d != "" && d != "bin/" && d != "cron/" && d != "fly/") { out = out " " d; break }
          }
        }
        return out " "
      }
      # subst(s, v, w) — s with every $v and ${v} replaced by w.
      function subst(s, v, w,   o, i, r) {
        o = ""
        while ((i = index(s, "$")) > 0) {
          o = o substr(s, 1, i - 1); r = substr(s, i)
          if (tdr_var(r) && VN_ == v) { o = o w; s = substr(r, VL_ + 1) }
          else { o = o "$"; s = substr(r, 2) }
        }
        return o s
      }
      function decide(   k, p, X, D, n, ls, i, okall, sd) {
        for (k in OCC) {
          split(k, p, SUBSEP); X = p[1]; D = p[2]
          sd = X; sub(/[^\/]*$/, "", sd)
          okall = 1
          n = split(OCC[k], ls, " ")
          for (i = 1; i <= n; i++) if (!line_ok(X, D, ls[i] + 0, sd)) okall = 0
          if (okall) DROP[X "\t" D] = 1
        }
      }
      function line_ok(X, D, ln, sd,   s, t, v, nv, ws, n, a, i, tg, m, b, j, got, ok) {
        s = SR[X, ln]; t = s; nv = 0; v = ""
        while ((i = index(t, "$")) > 0) {
          t = substr(t, i)
          if (tdr_var(t)) {
            if (tdr_words(X, VN_, ln) != "\001" && VN_ != v) { v = VN_; nv++ }
            t = substr(t, VL_ + 1)
          } else t = substr(t, 2)
        }
        if (nv != 1) return 0
        ws = tdr_words(X, v, ln); n = split(ws, a, " "); if (n == 0) return 0
        ok = 1
        for (i = 1; i <= n; i++) {
          tg = targets(subst(s, v, a[i]), sd)
          if (index(tg, " " D " ") > 0) return 0
          m = split(tg, b, " "); got = 0
          for (j = 1; j <= m; j++) if (b[j] !~ /\/$/ && index(b[j], D) == 1) { ADD[X "\t" b[j]] = 1; got = 1 }
          if (!got) ok = 0
        }
        return ok
      }
    ' "$idx" "$dl" "${_files[@]}" "$edges" ) > "$TI_TMP/tdr.edges.out" || return 2
  [ -s "$TI_TMP/tdr.edges.n" ] || return 2
  LC_ALL=C sort -u "$TI_TMP/tdr.edges.out"
}

# tdr_report — the one narrowed line, from the two counts the passes wrote.
tdr_report() {
  local k=0 s=0 e=0
  [ "${TDR_QUIET:-0}" = 1 ] && return 0
  [ -r "$TI_TMP/tdr.rows.n" ] && read -r k s < "$TI_TMP/tdr.rows.n"
  [ -r "$TI_TMP/tdr.edges.n" ] && e=$(cat "$TI_TMP/tdr.edges.n")
  [ "$k" = 0 ] && [ "$e" = 0 ] && return 0
  echo "dir-rows: narrowed $k directory row(s) of $s suite(s), $e edge(s)" >&2
}
