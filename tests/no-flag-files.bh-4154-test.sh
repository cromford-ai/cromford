#!/bin/bash
# tests/no-flag-files.bh-4154-test.sh — the raw flags/ file writer lint for bin/.
#
# THE POINT. A flag is a harness_flags row, read DB-first (BH-4153). A bare
# `touch "$H/flags/x"` is a box-local file. No other box sees it, and a reader
# that uses flag_has stops seeing it too. New flag writes go through
# bin/lib/flags.sh (flag_set / flag_clear). bin/lib/jobs/flags.sh implements
# them. This suite stops new raw writers.
#
# THE ALLOWLIST is two files, by exact path under bin/: lib/jobs/flags.sh (the
# implementation) and flags-import.sh (the one-time file-to-row import). No
# other file is exempt. There is no header marker. The suite excludes the two
# files from the strict count and from both sides of the delta count.
#
# THE BASELINE is one file per writer: tests/no-flag-files-baseline/<path under
# bin/>.txt holds one integer, that file's site count. A PR that converts a file
# deletes or lowers its own baseline file, so parallel PRs touch disjoint paths.
# `--write-baseline` regenerates the whole directory from the current tree.
#
# STRICT (--strict or RATCHET_MODE=strict), per non-allowlisted shell file in
# bin/ (*.sh, or a shell shebang):
#   red   sites > 0 and no baseline file;
#   red   sites > the baseline count;
#   note  baseline N above current M (lower it), or a baseline that names a
#         gone, zero-site or allowlisted file (delete it). A note is not red.
# DELTA (the default, tests/lib/ratchet-delta.sh): count each file at the base
# and at HEAD. Red only when this diff raised a file's count or added a file
# with sites. A base that does not resolve is red, never a skip.
# Case L1 always runs STRICT on the real tree, then the MODE run.
#
# A SITE. After `#` comments are stripped (quote-aware) and `\` continuations
# are joined, each of these, outside quotes, counts once:
#   - a redirection `>`, `>>`, `>|`, `&>`, `&>>` (so `: >`) to a flags path;
#   - a touch / mv / cp / ln / mkdir / rm / rmdir / tee at command position
#     with at least one argument that is a flags path.
# A FLAGS PATH is a word that, with quotes removed, has a `flags/` segment (at
# the start or after a `/`), ends in `/flags`, or names `flags` in a
# `/{a,flags}` brace list. It is also $VAR / ${VAR} when the same file assigns
# VAR such a value (an assignment, a `for VAR in` list, a `${VAR:-…}` default;
# chains resolve).
# NOT A SITE: state/flags-cache/, feature-flags/, --flags/x, reads (`<`, cat,
# grep, `[ -f ]`), comments, quoted prose, 2>/dev/null, >&2. Case L7 pins them.
#
# WHAT IT DOES NOT CATCH: a write built at runtime (`eval`, `bash -c`, `xargs
# rm`), a quote that spans two lines, a VAR assigned in another file, a write
# inside "$(…)" in double quotes, and any file outside bin/.
#
# Run from anywhere: tests/no-flag-files.bh-4154-test.sh [--strict|--write-baseline]
# Exit 0 = pass. No network, no clock.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
BASE="$DIR/tests/no-flag-files-baseline"
# The allowlist: exact paths under bin/. Nothing else is exempt.
ALLOW=(lib/jobs/flags.sh flags-import.sh)
FIX="new flag writes must go through bin/lib/flags.sh (flag_set / flag_clear, implemented in bin/lib/jobs/flags.sh)"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

cat > "$T/scan.py" <<'PY'
import os, re, sys

SHEBANG = re.compile(r"^#!.*\b(ba|da|k|z)?sh\b")
ASSIGN = re.compile(r"(?:^|[\s;(])(?:local\s+|export\s+|readonly\s+|declare\s+(?:-\w+\s+)*)?([A-Za-z_]\w*)=(\S+)")
FORIN = re.compile(r"(?:^|[\s;(])for\s+([A-Za-z_]\w*)\s+in\s+([^;]*)")
DEFAULT = re.compile(r"\$\{([A-Za-z_]\w*):?[-=]([^}]*)\}")
VARPFX = re.compile(r"^\$\{?([A-Za-z_]\w*)")
SEG = re.compile(r"(?:^|/)flags/")
BRACE = re.compile(r"(?:^|/)\{(?:[^{}]*,)?flags(?:,[^{}]*)?\}")
WRITERS = {"touch", "mv", "cp", "ln", "mkdir", "rm", "rmdir", "tee"}
PREFIX = {"if", "then", "do", "else", "elif", "while", "until", "!", "{", "}",
          "time", "command", "builtin", "exec", "sudo", "nice", "nohup"}
SEP = {";", ";;", "&&", "||", "|", "|&", "&", "(", ")", "$(", "`", "<(", ">("}
WREDIR = {">", ">>", ">|", "&>", "&>>"}
RREDIR = {"<", "<<", "<<-", "<<<", "<&", "<>", ">&"}
OPS = sorted(["&>>", "<<<", "<<-", ";;", "&&", "||", "|&", "&>", ">>", ">|", ">&",
              "<<", "<&", "<>", "<(", ">(", "$(", ";", "|", "&", "(", ")", ">", "<", "`"],
             key=len, reverse=True)


def strip_comment(line):
    out, sq, dq, esc, prev = [], False, False, False, ""
    for ch in line:
        if esc:
            esc = False
        elif ch == "\\" and not sq:
            esc = True
        elif ch == "'" and not dq:
            sq = not sq
        elif ch == '"' and not sq:
            dq = not dq
        elif ch == "#" and not sq and not dq and (prev == "" or prev.isspace() or prev in ";&|("):
            break
        out.append(ch)
        prev = ch
    return "".join(out)


def unquote(w):
    return w.replace('"', "").replace("'", "")


def tokens(s):
    """(kind, text) pairs: 'w' words (quotes kept) and 'o' operators, outside quotes."""
    out, cur, sq, dq, i = [], [], False, False, 0

    def flush():
        if cur:
            out.append(("w", "".join(cur)))
            del cur[:]

    while i < len(s):
        ch = s[i]
        if sq:
            cur.append(ch); sq = ch != "'"; i += 1; continue
        if dq:
            if ch == "\\" and i + 1 < len(s):
                cur.append(s[i:i + 2]); i += 2; continue
            cur.append(ch); dq = ch != '"'; i += 1; continue
        if ch == "\\" and i + 1 < len(s):
            cur.append(s[i:i + 2]); i += 2; continue
        if ch == "'":
            sq = True; cur.append(ch); i += 1; continue
        if ch == '"':
            dq = True; cur.append(ch); i += 1; continue
        if ch.isspace():
            flush(); i += 1; continue
        if s.startswith("$((", i) or s.startswith("${", i):
            close, depth, j = ("))", 0, i + 3) if s[i + 1] == "(" else ("}", 0, i + 2)
            while j < len(s):
                if s.startswith(close, j) and depth == 0:
                    j += len(close); break
                if s[j] in "({":
                    depth += 1
                elif s[j] in ")}":
                    depth -= 1
                j += 1
            cur.append(s[i:j]); i = j; continue
        op = next((o for o in OPS if s.startswith(o, i)), None)
        if op:
            flush(); out.append(("o", op)); i += len(op); continue
        cur.append(ch); i += 1
    flush()
    return out


def literal_flags(u):
    u = u.rstrip("};)")
    return bool(SEG.search(u) or u.endswith("/flags") or BRACE.search(u))


def is_flags(word, fvars):
    u = unquote(word)
    if literal_flags(u):
        return True
    m = VARPFX.match(u)
    return bool(m and m.group(1) in fvars)


def flag_vars(code):
    fvars, changed = set(), True
    while changed:
        changed = False
        for c in code:
            found = [(m.group(1), m.group(2)) for m in ASSIGN.finditer(c)]
            found += [(v, d) for v, d in DEFAULT.findall(c)]
            found += [(m.group(1), w) for m in FORIN.finditer(c) for w in m.group(2).split()]
            for var, val in found:
                if var in fvars or val.startswith(("$(", "`")):
                    continue
                if is_flags(val, fvars):
                    fvars.add(var)
                    changed = True
    return fvars


def count_line(c, fvars):
    toks, n, i, cmdpos = tokens(c), 0, 0, True
    while i < len(toks):
        kind, t = toks[i]
        if kind == "o":
            if t in WREDIR:
                if i + 1 < len(toks) and toks[i + 1][0] == "w" and is_flags(toks[i + 1][1], fvars):
                    n += 1
                i += 2; continue
            if t in RREDIR:
                i += 2; continue
            cmdpos = t in SEP
            i += 1; continue
        if not cmdpos:
            i += 1; continue
        if t in PREFIX or re.match(r"^[A-Za-z_]\w*(\[[^]]*\])?\+?=", unquote(t)):
            i += 1; continue
        cmdpos = False
        name = unquote(t).lstrip("\\").rsplit("/", 1)[-1]
        i += 1
        hit = False
        while i < len(toks) and not (toks[i][0] == "o" and toks[i][1] in SEP):
            k2, a = toks[i]
            if k2 == "o":
                if a in WREDIR and i + 1 < len(toks) and toks[i + 1][0] == "w" and is_flags(toks[i + 1][1], fvars):
                    n += 1
                i += 2; continue
            if name in WRITERS and not unquote(a).startswith("-") and is_flags(a, fvars):
                hit = True
            i += 1
        if hit:
            n += 1
    return n


def logical(lines):
    out, buf = [], ""
    for l in lines:
        c = strip_comment(l).rstrip()
        if c.endswith("\\") and not c.endswith("\\\\"):
            buf += c[:-1] + " "
            continue
        out.append((buf + c).strip())
        buf = ""
    if buf:
        out.append(buf.strip())
    return out


def scan(path):
    with open(path, errors="ignore") as fh:
        lines = fh.read().split("\n")
    code = logical(lines)
    fvars = flag_vars(code)
    return sum(count_line(c, fvars) for c in code if c)


def is_shell(path):
    if path.endswith(".sh"):
        return True
    try:
        with open(path, errors="ignore") as fh:
            return bool(SHEBANG.match(fh.readline()))
    except OSError:
        return False


root, allow = sys.argv[1], set(sys.argv[2:])
for d, _, files in os.walk(root):
    if "__pycache__" in d or "/node_modules" in d:
        continue
    for f in sorted(files):
        p = os.path.join(d, f)
        if os.path.isfile(p) and is_shell(p):
            rel = os.path.relpath(p, root)
            print("%s\t%d\t%d" % (rel, scan(p), int(rel in allow)))
PY

# scan <bin-dir> — "<path under bin/>\t<sites>\t<1 if allowlisted>" per shell file.
scan() { python3 "$T/scan.py" "$1" "${ALLOW[@]}"; }

# check <bin-dir> <baseline-dir> — the STRICT check. Prints findings, rc 1 on red.
check() {
  local bin="$1" base="$2" rc=0 rel n al want f rows
  rows=$(mktemp "$T/rows.XXXXXX") || return 1
  scan "$bin" | sort > "$rows" || { echo "RED: scanner failed"; return 1; }
  while IFS=$'\t' read -r rel n al; do
    [ "$al" = 1 ] && continue
    [ "$n" -gt 0 ] || continue
    f="$base/$rel.txt"
    if [ ! -f "$f" ]; then
      echo "RED: bin/$rel has $n raw flags/ write(s) and no baseline — $FIX"
      rc=1; continue
    fi
    want=$(tr -dc '0-9' < "$f")
    if [ -z "$want" ] || [ "$n" -gt "$want" ]; then
      echo "RED: bin/$rel has $n raw flags/ write(s), baseline ${want:-unreadable} — $FIX"
      rc=1
    fi
  done < "$rows"
  if [ -d "$base" ]; then
    while IFS= read -r f; do
      rel=${f#"$base"/}; rel=${rel%.txt}
      want=$(tr -dc '0-9' < "$f")
      IFS=$'\t' read -r n al < <(awk -F'\t' -v r="$rel" '$1==r {print $2 "\t" $3}' "$rows")
      if [ "${al:-0}" = 1 ]; then
        echo "NOTE: baseline $rel.txt names an allowlisted file — delete it"
      elif [ "${n:-0}" -eq 0 ]; then
        echo "NOTE: baseline $rel.txt names a file with no raw flags/ writes now — delete it"
      elif [ -n "$want" ] && [ "$want" -gt "$n" ]; then
        echo "NOTE: bin/$rel baseline $want above current $n — lower it"
      fi
      n=; al=
    done < <(find "$base" -name '*.txt' | sort)
  fi
  return $rc
}
count_of() { scan "$1" | awk -F'\t' -v f="$2" '$1==f{print $2}'; }

# sites <bin-dir> — "<path under bin/>\t<n>" for every non-allowlisted file with
# raw sites: the per-file counts delta mode compares and the baseline holds.
sites() { scan "$1" | awk -F'\t' '$3 == 0 && $2 > 0 { print $1 "\t" $2 }' | sort; }

# write_baseline <bin-dir> <baseline-dir> — rewrite the baseline from the tree.
write_baseline() {
  local bin="$1" base="$2" rows rel n
  rows=$(mktemp "$T/wb.XXXXXX") || return 1
  sites "$bin" > "$rows" || { echo "scanner failed"; return 1; }
  mkdir -p "$base" && find "$base" -name '*.txt' -delete || return 1
  while IFS=$'\t' read -r rel n; do
    mkdir -p "$(dirname "$base/$rel.txt")" && echo "$n" > "$base/$rel.txt" || return 1
  done < "$rows"
  find "$base" -mindepth 1 -type d -empty -delete
  echo "wrote baseline: $(awk -F'\t' '{s+=$2} END{print NR " files, " s+0 " sites"}' "$rows")"
}

for a in "$@"; do
  [ "$a" = --write-baseline ] || continue
  write_baseline "$DIR/bin" "$BASE" || { echo "FAIL: --write-baseline failed"; exit 1; }
  exit 0
done

# delta_check <repo> <base-commit> — red when THIS diff adds a raw flags/ writer.
delta_check() {
  local repo="$1" ref="$2" w rel n b rc=0
  w=$(mktemp -d "$T/delta-base.XXXXXX") || return 1
  rd_tree "$repo" "$ref" "$w" bin || { echo "RED: cannot read bin/ at base $ref"; return 1; }
  mkdir -p "$w/bin"
  sites "$w/bin" > "$w.base" || { echo "RED: scanner failed on base $ref"; return 1; }
  sites "$repo/bin" > "$w.head" || { echo "RED: scanner failed"; return 1; }
  while IFS=$'\t' read -r rel n b; do
    echo "RED: bin/$rel has $n raw flags/ write(s), $b at base ${ref:0:12} — $FIX"
    rc=1
  done < <(rd_delta "$w.head" "$w.base")
  return $rc
}

# real_check <repo> — the check the run makes, by mode.
real_check() {
  local base
  case "$MODE" in
    strict) check "$1/bin" "$1/tests/no-flag-files-baseline" ;;
    delta)  base=$(rd_base "$1") || { echo "RED: $base"; return 1; }
            delta_check "$1" "$base" ;;
  esac
}
MODE=$(rd_mode "$@") || { echo "FAIL: $MODE"; exit 1; }

if [ "$MODE" = strict ]; then echo "--- L1: the real bin/ is green in strict mode"; else echo "--- L1: the real bin/ is green in strict mode, then in $MODE mode"; fi
OUT=$(check "$DIR/bin" "$BASE"); RC=$?
[ -n "$OUT" ] && printf '%s\n' "$OUT"
[ "$RC" -eq 0 ] && ok || bad "L1 strict: bin/ is over its flags/ writer baseline (see RED lines above)"
if [ "$MODE" != strict ]; then
  OUT=$(real_check "$DIR"); RC=$?
  [ -n "$OUT" ] && printf '%s\n' "$OUT"
  [ "$RC" -eq 0 ] && ok || bad "L1 $MODE: this diff adds a raw flags/ writer in bin/ (see RED lines above)"
fi
ROWS=$(scan "$DIR/bin")
echo "allowlisted: ${ALLOW[*]}"
echo "raw sites: $(awk -F'\t' '$3==0{s+=$2; if($2>0)n++} END{print s+0 " in " n+0 " files"}' <<<"$ROWS")"

# one_red <case> <bin-dir> <baseline-dir> <rel> <want-count> — the planted file
# counts <want-count> and the strict check is red on it with the FIX text.
one_red() {
  local name="$1" bin="$2" base="$3" rel="$4" want="$5" got out rc
  got=$(count_of "$bin" "$rel")
  [ "$got" = "$want" ] || { bad "$name: bin/$rel counted '$got' site(s), want $want"; return; }
  out=$(check "$bin" "$base"); rc=$?
  if [ "$rc" -ne 0 ] && grep -q "bin/$rel has $want .*bin/lib/flags.sh (flag_set / flag_clear" <<<"$out"; then
    ok
  else
    bad "$name: bin/$rel stayed green or the message is wrong (rc=$rc): $out"
  fi
}

echo "--- L2: a new touch with no baseline is red"
M="$T/l2"; mkdir -p "$M/bin/lib" "$M/base"
printf '#!/bin/bash\n# fake lane\ntouch "$H/flags/x"\n' > "$M/bin/lib/new.sh"
one_red L2 "$M/bin" "$M/base" lib/new.sh 1

echo "--- L3: printf >, echo >> and : > are each red"
i=0
for w in 'printf x > "$H/flags/x"' 'echo y >> "$H/flags/x"' ': > "$H/flags/x"'; do
  i=$((i+1)); M="$T/l3-$i"; mkdir -p "$M/bin" "$M/base"
  printf '#!/bin/bash\n%s\n' "$w" > "$M/bin/w$i.sh"
  one_red "L3($w)" "$M/bin" "$M/base" "w$i.sh" 1
done

echo "--- L4: rm -f outside the allowlist is red"
M="$T/l4"; mkdir -p "$M/bin" "$M/base"
printf '#!/bin/bash\nrm -f "$H/flags/x"\n' > "$M/bin/clear.sh"
one_red L4 "$M/bin" "$M/base" clear.sh 1

echo "--- L5: a same-file variable is red"
M="$T/l5"; mkdir -p "$M/bin" "$M/base"
printf '#!/bin/bash\nF="$H/flags/alerted-x"; touch "$F"\n' > "$M/bin/var5.sh"
one_red L5 "$M/bin" "$M/base" var5.sh 1

echo "--- L6: the allowlist is two exact paths"
WRITES='touch "$H/flags/x"
printf x > "$H/flags/x"
echo y >> "$H/flags/x"
: > "$H/flags/x"
rm -f "$H/flags/x"
F="$H/flags/alerted-x"; touch "$F"'
M="$T/l6"; mkdir -p "$M/bin/lib/jobs" "$M/base"
printf '#!/bin/bash\n%s\n' "$WRITES" > "$M/bin/lib/jobs/flags.sh"
printf '#!/bin/bash\n%s\n' "$WRITES" > "$M/bin/flags-import.sh"
for rel in lib/jobs/flags.sh flags-import.sh; do
  [ "$(count_of "$M/bin" "$rel")" = 6 ] && ok || bad "L6: bin/$rel counted '$(count_of "$M/bin" "$rel")' site(s), want 6"
done
OUT=$(check "$M/bin" "$M/base"); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "L6: allowlisted bin/lib/jobs/flags.sh or bin/flags-import.sh is red (rc=$RC): $OUT"
printf '#!/bin/bash\n%s\n' "$WRITES" > "$M/bin/lib/jobs/other.sh"
one_red "L6(other.sh)" "$M/bin" "$M/base" lib/jobs/other.sh 6
M="$T/l6b"; mkdir -p "$M/bin/sub" "$M/base"
printf '#!/bin/bash\n%s\n' "$WRITES" > "$M/bin/sub/flags-import.sh"
one_red "L6(sub/flags-import.sh)" "$M/bin" "$M/base" sub/flags-import.sh 6

echo "--- L7: what the scanner counts"
F="$T/fx/bin"; mkdir -p "$F"
cat > "$F/neg.sh" <<'NEG'
#!/bin/bash
touch "$H/state/flags-cache/x"; echo 1 > "$H/state/flags-cache/y"
grep -q on "$H/flags/x"; grep -l x flags/x; grep -l x flags/
[ -f "$H/flags/x" ] && echo on
[ -f flags/x ] && echo on
cat "$H/flags/wip-limit-$P"; cat flags/x
echo "touch flags/x to pause"
echo 'or rm -f "$H/flags/x" in single quotes'
# touch flags/x
touch "$H/feature-flags/x"; echo z > "$H/feature-flags/y"
touch feature-flags/x
mytool --flags/x; touch --flags/x
echo s > "$H/state/x"
while read -r l; do :; done < "$H/flags/x"
ls "$H/flags/" 2>/dev/null
echo warn >&2
n=$(cat "$H/flags/wip-limit-p"); echo "$n" > "$H/state/n"
NEG
[ "$(count_of "$F" neg.sh)" = 0 ] && ok || bad "L7: negatives counted $(count_of "$F" neg.sh) site(s), want 0"
cat > "$F/pos.sh" <<'POS'
#!/bin/bash
touch "$H/flags/x"
: > "$HARNESS/flags/alerted-$d"
f="$H/flags/main-red-$s"
rm -f "$f"
mkdir -p "$H/flags"
mv "$t" "$H/flags/x"
( set -C; : > "$H/flags/alerted-x" )
echo 3 > "$H/flags/wip-limit-p"
POS
[ "$(count_of "$F" pos.sh)" = 7 ] && ok || bad "L7: positives counted $(count_of "$F" pos.sh), want 7"
cat > "$F/var.sh" <<'VAR'
#!/bin/bash
FLAGS="$H/flags"
touch "$FLAGS/x"
g="$FLAGS/y.tmp"; echo 1 >"$g" && mv "$g" "$FLAGS/y"
for f in "$H"/flags/alerted-*; do rm -f "$f"; done
rm -f \
  "$H/flags/cont"
x=$(touch "${FLAGS}/z")
echo a | tee "$H/flags/t" >/dev/null
VAR
[ "$(count_of "$F" var.sh)" = 7 ] && ok || bad "L7: \$VAR / continuation / subshell writes counted $(count_of "$F" var.sh), want 7"
printf 'X="$H/flags/x"\ntouch "$X"\n' > "$F/noext"; printf '#!/usr/bin/env bash\ntouch "$H/flags/x"\n' > "$F/shebang"
[ "$(count_of "$F" noext)" = "" ] && [ "$(count_of "$F" shebang)" = 1 ] \
  && ok || bad "L7: file selection wrong (noext='$(count_of "$F" noext)' shebang='$(count_of "$F" shebang)')"

echo "--- L8: one above the baseline is red, one below is a note"
M="$T/l8"; mkdir -p "$M/bin" "$M/base"
printf '#!/bin/bash\ntouch "$H/flags/a"\nrm -f "$H/flags/b"\n' > "$M/bin/w.sh"
write_baseline "$M/bin" "$M/base" >/dev/null || bad "L8: write_baseline failed"
[ "$(tr -dc '0-9' < "$M/base/w.sh.txt")" = 2 ] && ok || bad "L8: write_baseline wrote '$(cat "$M/base/w.sh.txt")' for w.sh, want 2"
OUT=$(check "$M/bin" "$M/base"); RC=$?
[ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok || bad "L8: a file at its baseline is not green (rc=$RC): $OUT"
printf '%s\n' 'touch "$H/flags/new-off"' >> "$M/bin/w.sh"
OUT=$(check "$M/bin" "$M/base"); RC=$?
[ "$RC" -ne 0 ] && grep -q 'bin/w.sh has 3 .* baseline 2 .*bin/lib/flags.sh' <<<"$OUT" \
  && ok || bad "L8: one site above the baseline stayed green (rc=$RC): $OUT"
printf '#!/bin/bash\ntouch "$H/flags/a"\n' > "$M/bin/w.sh"
OUT=$(check "$M/bin" "$M/base"); RC=$?
[ "$RC" -eq 0 ] && grep -q 'NOTE: bin/w.sh baseline 2 above current 1 — lower it' <<<"$OUT" \
  && ok || bad "L8: one site below the baseline: want rc 0 and a 'lower it' NOTE (rc=$RC): $OUT"
rm -f "$M/bin/w.sh"
OUT=$(check "$M/bin" "$M/base"); RC=$?
[ "$RC" -eq 0 ] && grep -q 'NOTE: baseline w.sh.txt names a file with no raw flags/ writes now — delete it' <<<"$OUT" \
  && ok || bad "L8: a baseline for a gone file: want rc 0 and a 'delete it' NOTE (rc=$RC): $OUT"

echo "--- L9: delta mode, hermetic repos"
# B: bin/a.sh has one raw site and a baseline that says so; bin/x.sh has none;
# bin/lib/jobs/flags.sh (allowlisted) has one.
dmk() {
  local R="$1"
  scratch_rm "$R" || return 1
  mkdir -p "$R/bin/lib/jobs" "$R/tests/no-flag-files-baseline"
  printf '#!/bin/bash\ntouch "$H/flags/a"\n' > "$R/bin/a.sh"
  printf '#!/bin/bash\n. "$H/bin/lib/flags.sh"\ntrue\n' > "$R/bin/x.sh"
  printf '#!/bin/bash\ntouch "$H/flags/lib"\n' > "$R/bin/lib/jobs/flags.sh"
  echo 1 > "$R/tests/no-flag-files-baseline/a.sh.txt"
  rd_fixture_repo "$R"
}
d_main_raw()  { printf 'rm -f "$H/flags/b"\n' >> "$1/bin/a.sh"; printf '#!/bin/bash\n: > "$H/flags/m"\n' > "$1/bin/m.sh"; }
d_drift()     { rd_main_commit "$1" 'main: writers elsewhere' d_main_raw; }
d_pr_docs()   { echo more >> "$1/README"; rd_git "$1" commit -qam 'pr: docs'; }
d_pr_raw()    { printf 'touch "$H/flags/new-off"\n' >> "$1/bin/x.sh"; rd_git "$1" commit -qam 'pr: x.sh gains a raw writer'; }
d_pr_add()    { printf 'rm -f "$H/flags/a2"\n' >> "$1/bin/a.sh"; rd_git "$1" commit -qam 'pr: a.sh gains a site'; }
d_pr_rmsite() { printf '#!/bin/bash\ntrue\n' > "$1/bin/a.sh"; rd_git "$1" commit -qam 'pr: a.sh drops its site'; }
d_pr_lib()    { printf 'flag_set new-off\n' >> "$1/bin/x.sh"; rd_git "$1" commit -qam 'pr: x.sh sets through the lib'; }
d_pr_allow()  { printf ': > "$H/flags/lib2"\n' >> "$1/bin/lib/jobs/flags.sh"; rd_git "$1" commit -qam 'pr: the lib gains a site'; }
d_pr_new()    { printf '#!/bin/bash\nmkdir -p "$H/flags"\n' > "$1/bin/n.sh"; rd_git "$1" add -A; rd_git "$1" commit -qm 'pr: new writer file'; }
d_pr_conv()   { printf '#!/bin/bash\nflag_set a\n' > "$1/bin/a.sh"; rd_git "$1" commit -qam 'pr: convert a.sh'; }
d_merge()     { rd_git "$1" merge -q --no-edit refs/remotes/origin/main; }
d_nomain()    { rd_git "$1" update-ref -d refs/remotes/origin/main; }
dcase() {  # <name> <want_rc> <RATCHET_BASE: main|B|none|bogus> <mode> <steps...>
  local name="$1" want="$2" rb="$3" mode="$4" R="$T/d-$1" b step out rc
  shift 4
  dmk "$R" || { bad "L9($name): repo setup failed"; return; }
  b=$(rd_git "$R" rev-parse HEAD)
  for step in "$@"; do "$step" "$R" >/dev/null || { bad "L9($name): step $step failed"; return; }; done
  case "$rb" in
    main)  rb=$(rd_git "$R" rev-parse refs/remotes/origin/main) ;;
    B)     rb="$b" ;;
    none)  rb="" ;;
    bogus) rb=0123456789abcdef0123456789abcdef01234567 ;;
  esac
  out=$(MODE="$mode" RATCHET_BASE="$rb" TI_BASE= real_check "$R" 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then ok; else bad "L9($name) rc=$rc want $want:"$'\n'"$out"; fi
}
dcase main-drift-pr-base       0 main  delta d_drift d_pr_docs d_merge
dcase main-drift-queue-draft   0 main  delta d_pr_docs d_drift d_merge
dcase main-drift-stale-base    0 B     delta d_drift d_pr_docs d_merge
dcase main-drift-local         0 none  delta d_drift d_pr_docs d_merge
dcase pr-adds-writer           1 main  delta d_pr_raw
dcase pr-adds-site             1 main  delta d_pr_add
dcase pr-removes-site          0 main  delta d_pr_rmsite
dcase pr-uses-flag-set         0 main  delta d_pr_lib
dcase pr-allowlisted-site      0 main  delta d_pr_allow
dcase pr-adds-after-drift      1 main  delta d_drift d_pr_raw d_merge
dcase pr-adds-new-file         1 main  delta d_drift d_pr_new d_merge
dcase pr-converts              0 main  delta d_pr_conv
dcase bogus-base               1 bogus delta d_pr_docs
dcase no-base-at-all           1 none  delta d_pr_docs d_nomain
dcase strict-sees-drift        1 main  strict d_drift d_pr_docs d_merge
dcase strict-clean             0 main  strict d_pr_docs
dcase strict-allowlisted-site  0 main  strict d_pr_allow

echo "no-flag-files ($MODE): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
