#!/bin/bash
# tests/no-state-files.bh-4159-test.sh — the raw state/ file writer ratchet for bin/.
#
# THE POINT. Harness state is a DB row (a jobs-worker table, a settings row, a
# harness_flags row), read DB-first. A bare `echo x > "$H/state/x"` is a
# box-local file: no other box sees it, a box rebuild loses it, and the DB-first
# reader never reads it. This suite stops NEW raw writers under state/ in bin/.
# tests/no-flag-files.bh-4154-test.sh is the other half (flags/). Where each
# kind of state lives now: docs/STATE-STORES.md.
#
# THE ALLOWLIST is by FIRST SEGMENT under state/, not by file: every path that
# catalog/state-paths.json (read in the repo under test, so a PR's own catalog
# edit counts on both sides of the delta) classes `cache` or `box-local`, plus
# the names in ALLOW_EXTRA below. A segment also covers its dot siblings
# (`settings-cache.json.tmp`). To allow a new path, class it in the catalog in
# the same PR; a reviewer sees that diff. A catalog that is missing, is not
# JSON, or has no .paths list is RED ("cannot read the allowlist"), never an
# empty allowlist.
#
# DELTA ONLY (tests/lib/ratchet-delta.sh): count each non-zero file at the base
# and at HEAD. Red only when this diff raised a file's count or added a file
# with sites. A base that does not resolve, or no base, is red. There is no
# committed baseline, so `--strict` and RATCHET_MODE=strict are refused (rc 2).
#
# A SITE. After `#` comments are stripped (quote-aware) and `\` continuations
# are joined, each of these, outside quotes, counts once:
#   - a redirection `>`, `>>`, `>|`, `&>`, `&>>` (so `: >`) to a state path;
#   - a touch / mv / cp / ln / mkdir / rm / rmdir / tee at command position
#     with at least one argument that is a state path.
# A STATE PATH is a word that, with quotes removed, has a `state/` segment (at
# the start or after a `/`), ends in `/state`, or names `state` in a
# `/{a,state}` brace list, and whose first segment after `state/` is not
# allowlisted. The first segment is cut at the next `/`, `$`, `*`, `{`, `}`,
# `?`, `[` or `;`. An empty first segment (`state/$x`, a bare `$H/state`,
# `${S:-$H/state}`, a brace list) is a site: it fails closed. A word that
# starts with $VAR / ${VAR} is expanded with every value the same file gives
# VAR (an assignment, a `for VAR in` list, a `${VAR:-…}` default; chains
# expand), and it is a site when any expansion is.
# NOT A SITE: gh-state/, state-x, --state/x, reads (`<`, cat, grep, `[ -f ]`),
# comments, quoted prose, 2>/dev/null, >&2, flags/ paths (BH-4154's job), and
# any path with no state/ segment, so logs/ and builds/ are out by
# construction. Case group S3 pins each one.
#
# WHAT IT DOES NOT CATCH: a write built at runtime (`eval`, `bash -c`, `xargs
# rm`), a quote that spans two lines, a VAR assigned in another file
# ($STATE_DIR from a lib), a $VAR in the middle of a word, python or node
# writers, and any file outside bin/.
#
# Run from anywhere: tests/no-state-files.bh-4159-test.sh [--list|--list-segments]
#   --list           "<path under bin/>\t<sites>" per file with sites, rc 0.
#   --list-segments  "<first segment>\t<sites>" over all of bin/, rc 0; an
#                    empty or dynamic first segment is "(dynamic)".
# NO_STATE_FILES_REPO=<repo> runs the real check (or a list) on that repo
# instead of this checkout, and skips the case groups. Case S2 uses it.
# Exit 0 = pass. No network, no clock.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/ratchet-delta.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
SELF="$DIR/tests/no-state-files.bh-4159-test.sh"
# The pure caches #4141 names that the catalog does not class:
# bin/lib/gh-policy-cache.sh keeps a file per (repo, name) under it.
ALLOW_EXTRA=(gh-policy-cache)
FIX="new state must be a DB row (bin/lib/jobs/*), a settings row, or a path classed cache/box-local in catalog/state-paths.json; see docs/STATE-STORES.md"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

LIST=""
for a in "$@"; do
  case "$a" in
    --list|--list-segments) LIST="$a" ;;
    --strict) echo "no-state-files: --strict refused: no baseline, delta only"; exit 2 ;;
    *) echo "no-state-files: unknown argument '$a' (want --list or --list-segments)"; exit 2 ;;
  esac
done
[ "${RATCHET_MODE:-delta}" = delta ] \
  || { echo "no-state-files: RATCHET_MODE='$RATCHET_MODE' refused: no baseline, delta only"; exit 2; }
MODE=delta

cat > "$T/scan.py" <<'PY'
import os, re, sys

SHEBANG = re.compile(r"^#!.*\b(ba|da|k|z)?sh\b")
ASSIGN = re.compile(r"(?:^|[\s;(])(?:local\s+|export\s+|readonly\s+|declare\s+(?:-\w+\s+)*)?([A-Za-z_]\w*)=(\S+)")
FORIN = re.compile(r"(?:^|[\s;(])for\s+([A-Za-z_]\w*)\s+in\s+([^;]*)")
DEFAULT = re.compile(r"\$\{([A-Za-z_]\w*):?[-=]([^}]*)\}")
REFS = re.compile(r"\$\{?([A-Za-z_]\w*)")
VARREF = re.compile(r"^\$(?:\{([A-Za-z_]\w*)(?::?[-=+?][^}]*)?\}|([A-Za-z_]\w*))")
SEG = re.compile(r"(?:^|/)state(?=/|\}|$)")
BRACE = re.compile(r"(?:^|/)\{(?:[^{}]*,)?state(?:,[^{}]*)?\}")
CUT = re.compile(r"[/$*{}?\[;]")
DYN = "(dynamic)"
WRITERS = {"touch", "mv", "cp", "ln", "mkdir", "rm", "rmdir", "tee"}
PREFIX = {"if", "then", "do", "else", "elif", "while", "until", "!", "{", "}",
          "time", "command", "builtin", "exec", "sudo", "nice", "nohup"}
SEP = {";", ";;", "&&", "||", "|", "|&", "&", "(", ")", "$(", "`", "<(", ">("}
WREDIR = {">", ">>", ">|", "&>", "&>>"}
RREDIR = {"<", "<<", "<<-", "<<<", "<&", "<>", ">&"}
OPS = sorted(["&>>", "<<<", "<<-", ";;", "&&", "||", "|&", "&>", ">>", ">|", ">&",
              "<<", "<&", "<>", "<(", ">(", "$(", ";", "|", "&", "(", ")", ">", "<", "`"],
             key=len, reverse=True)
EXPAND_DEPTH, EXPAND_CAP = 8, 64


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


def first_segment(u):
    """None when u is not a state path; else its first segment under state/ or DYN."""
    u = u.rstrip(";)")
    if BRACE.search(u):
        return DYN
    m = SEG.search(u)
    if not m:
        return None
    rest = u[m.end():]
    if not rest.startswith("/"):
        return DYN
    return CUT.split(rest[1:], 1)[0] or DYN


def allowed(seg, allow):
    return seg != DYN and (seg in allow or any(seg.startswith(a + ".") for a in allow))


def expand(u, vals, depth=0):
    m = VARREF.match(u)
    if depth >= EXPAND_DEPTH or not m:
        return {u}
    v = m.group(1) or m.group(2)
    if v not in vals:
        return {u}
    out = set()
    for val in vals[v]:
        out |= expand(unquote(val).rstrip(";)&|") + u[m.end():], vals, depth + 1)
        if len(out) > EXPAND_CAP:
            break
    return out


def site_segment(word, vals, allow):
    """The first non-allowlisted first segment the word reaches, or None."""
    u = unquote(word)
    for e in sorted({u} | expand(u, vals)):
        seg = first_segment(e)
        if seg is not None and not allowed(seg, allow):
            return seg
    return None


def var_values(code):
    vals = {}
    for c in code:
        found = [(m.group(1), m.group(2)) for m in ASSIGN.finditer(c)]
        found += [(v, d) for v, d in DEFAULT.findall(c)]
        found += [(m.group(1), w) for m in FORIN.finditer(c) for w in m.group(2).split()]
        for var, val in found:
            if val.startswith(("$(", "`", '"$(', '"`')):
                continue
            vals.setdefault(var, [])
            if val not in vals[var]:
                vals[var].append(val)
    return vals


def line_sites(c, vals, allow):
    """One first segment per site on the logical line c."""
    toks, out, i, cmdpos = tokens(c), [], 0, True

    def target(j):
        if j < len(toks) and toks[j][0] == "w":
            return site_segment(toks[j][1], vals, allow)
        return None

    while i < len(toks):
        kind, t = toks[i]
        if kind == "o":
            if t in WREDIR:
                seg = target(i + 1)
                if seg is not None:
                    out.append(seg)
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
        hit = None
        while i < len(toks) and not (toks[i][0] == "o" and toks[i][1] in SEP):
            k2, a = toks[i]
            if k2 == "o":
                if a in WREDIR:
                    seg = target(i + 1)
                    if seg is not None:
                        out.append(seg)
                i += 2; continue
            if name in WRITERS and hit is None and not unquote(a).startswith("-"):
                hit = site_segment(a, vals, allow)
            i += 1
        if hit is not None:
            out.append(hit)
    return out


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


def state_vars(vals):
    """Names whose values reach the text `state`, directly or through a chain."""
    sv, changed = set(), True
    while changed:
        changed = False
        for var, vs in vals.items():
            if var not in sv and any("state" in v or set(REFS.findall(v)) & sv for v in vs):
                sv.add(var)
                changed = True
    return sv


def scan(path, allow):
    with open(path, errors="ignore") as fh:
        lines = fh.read().split("\n")
    code = logical(lines)
    vals = var_values(code)
    sv = state_vars(vals)
    segs = []
    for c in code:
        # A line with no `state` text and no reference to a state VAR holds no
        # site; skipping it keeps the tokenizer off 9 in 10 lines of bin/.
        if c and ("state" in c or set(REFS.findall(c)) & sv):
            segs += line_sites(c, vals, allow)
    return segs


def is_shell(path):
    if path.endswith(".sh"):
        return True
    try:
        with open(path, errors="ignore") as fh:
            return bool(SHEBANG.match(fh.readline()))
    except OSError:
        return False


mode, root, allow = sys.argv[1], sys.argv[2], set(a for a in sys.argv[3:] if a)
for d, _, files in os.walk(root):
    if "__pycache__" in d or "/node_modules" in d:
        continue
    for f in sorted(files):
        p = os.path.join(d, f)
        if os.path.isfile(p) and is_shell(p):
            rel = os.path.relpath(p, root)
            segs = scan(p, allow)
            if mode == "segs":
                for s in segs:
                    print("%s\t%s" % (s, rel))
            else:
                print("%s\t%d" % (rel, len(segs)))
PY

# allow_of <repo> — the allowlist, one first segment per line: the catalog's
# cache and box-local paths, then ALLOW_EXTRA. rc 1 + a RED line when the
# catalog cannot be read.
allow_of() {
  local cat="$1/catalog/state-paths.json" rows
  [ -f "$cat" ] || { echo "RED: cannot read the allowlist: $cat is missing"; return 1; }
  jq -e '.paths | type == "array"' "$cat" >/dev/null 2>&1 \
    || { echo "RED: cannot read the allowlist: $cat is not JSON with a .paths list"; return 1; }
  rows=$(jq -r '.paths[] | select(.class == "cache" or .class == "box-local") | .path' "$cat") \
    || { echo "RED: cannot read the allowlist: jq failed on $cat"; return 1; }
  printf '%s\n' "$rows" "${ALLOW_EXTRA[@]}"
}

# sites <bin-dir> <allowlist> — "<path under bin/>\t<n>" for every file with sites.
sites() {
  local -a al
  mapfile -t al <<<"$2"
  python3 "$T/scan.py" files "$1" "${al[@]}" | awk -F'\t' '$2 > 0 { print $1 "\t" $2 }' | sort
}
# segments <bin-dir> <allowlist> — "<first segment>\t<n>" over the whole dir.
segments() {
  local -a al
  mapfile -t al <<<"$2"
  python3 "$T/scan.py" segs "$1" "${al[@]}" | awk -F'\t' '{ n[$1]++ } END { for (s in n) print s "\t" n[s] }' | sort
}

# delta_check <repo> <base-commit> — red when THIS diff adds a raw state/ writer.
delta_check() {
  local repo="$1" ref="$2" w al rel n b rc=0
  al=$(allow_of "$repo") || { printf '%s\n' "$al"; return 1; }
  w=$(mktemp -d "$T/delta-base.XXXXXX") || return 1
  rd_tree "$repo" "$ref" "$w" bin || { echo "RED: cannot read bin/ at base $ref"; return 1; }
  mkdir -p "$w/bin"
  sites "$w/bin" "$al" > "$w.base" || { echo "RED: scanner failed on base $ref"; return 1; }
  sites "$repo/bin" "$al" > "$w.head" || { echo "RED: scanner failed"; return 1; }
  while IFS=$'\t' read -r rel n b; do
    echo "RED: bin/$rel has $n raw state/ write(s), $b at base ${ref:0:12} — $FIX"
    rc=1
  done < <(rd_delta "$w.head" "$w.base")
  return $rc
}

# real_check <repo> — the check every run makes.
real_check() {
  local base
  base=$(rd_base "$1") || { echo "RED: $base"; return 1; }
  delta_check "$1" "$base"
}

REPO="${NO_STATE_FILES_REPO:-$DIR}"
if [ -n "$LIST" ]; then
  AL=$(allow_of "$REPO") || { printf '%s\n' "$AL"; exit 1; }
  if [ "$LIST" = --list ]; then sites "$REPO/bin" "$AL"; else segments "$REPO/bin" "$AL"; fi
  exit $?
fi

echo "--- S1: the real bin/ adds no raw state/ writer ($MODE)"
OUT=$(real_check "$REPO"); RC=$?
[ -n "$OUT" ] && printf '%s\n' "$OUT"
[ "$RC" -eq 0 ] && ok || bad "S1: this diff adds a raw state/ writer in bin/, or the check could not run (see RED lines above)"
if [ -n "${NO_STATE_FILES_REPO:-}" ]; then
  echo "no-state-files ($MODE): $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]; exit
fi

# A fixture catalog: two caches, one box-local path, one rows path.
fixture_catalog() {
  mkdir -p "$1/catalog" && cat > "$1/catalog/state-paths.json" <<'JSON'
{"version":1,"paths":[
 {"path":"gh-etag","class":"cache","authority":"fixture"},
 {"path":"settings-cache.json","class":"cache","authority":"fixture"},
 {"path":"box-id","class":"box-local","authority":"fixture"},
 {"path":"merge-conductor","class":"rows","authority":"fixture"}]}
JSON
}
FX="$T/fx"; fixture_catalog "$FX"
FXAL=$(allow_of "$FX") || bad "fixture catalog unreadable: $FXAL"
count_of() { sites "$1" "$FXAL" | awk -F'\t' -v f="$2" '$1==f{print $2}'; }

echo "--- S2: a fixture that writes state/x.txt is red, its base is green (the suite run as shipped)"
R="$T/s2"; mkdir -p "$R/bin"; fixture_catalog "$R"
printf '#!/bin/bash\nH=${HARNESS:-}\necho start\n' > "$R/bin/x.sh"
rd_fixture_repo "$R" || bad "S2: repo setup failed"
OUT=$(NO_STATE_FILES_REPO="$R" RATCHET_BASE= TI_BASE= bash "$SELF" 2>&1); RC=$?
[ "$RC" -eq 0 ] && grep -q 'no-state-files (delta): 1 passed, 0 failed' <<<"$OUT" \
  && ok || bad "S2: the fixture base is not green (rc=$RC): $OUT"
printf 'echo hi > "$H/state/x.txt"\n' >> "$R/bin/x.sh"; rd_git "$R" commit -qam 'pr: x.sh writes state/x.txt'
OUT=$(NO_STATE_FILES_REPO="$R" RATCHET_BASE= TI_BASE= bash "$SELF" 2>&1); RC=$?
if [ "$RC" -eq 1 ] && grep -q 'RED: bin/x.sh has 1 raw state/ write(s), 0 at base .*docs/STATE-STORES.md' <<<"$OUT" \
   && ! grep -q ' 0 failed' <<<"$OUT"; then ok; else bad "S2: the state/x.txt writer is not red (rc=$RC): $OUT"; fi

echo "--- S3: what the scanner counts"
i=0
s3() {  # <want> <line>
  i=$((i+1)); printf '#!/bin/bash\n%s\n' "$2" > "$FX/bin/c$i.sh"
  local got; got=$(count_of "$FX/bin" "c$i.sh"); got=${got:-0}
  [ "$got" = "$1" ] && ok || bad "S3: '$2' counted $got site(s), want $1"
}
mkdir -p "$FX/bin"
s3 1 'echo x > "$H/state/x.txt"'
s3 1 'touch "$HARNESS/state/merge-conductor/a"'
s3 1 'D="$H/state/blocked-resolver"; mkdir -p "$D"'
s3 1 'for d in "$H/state/cost"; do rm -f "$d/x"; done'
s3 1 ': >> "${S:-$H/state}/q"'
s3 1 'mkdir -p "$H/state"'
s3 1 'cp a "$H/{x,state}/y"'
s3 1 'printf x | tee "$H/state/pool/p"'
s3 1 'echo x > "$H/state/$name"'
s3 1 'echo x > "$H/state/gh-etag-$k"'
s3 1 'S="$H/state"; touch "$S/quota-x/y"'
s3 1 'echo a | tee "$H/state/gh-etag/k" "$H/state/cost/c" >/dev/null'
s3 1 'rm -f \
  "$H/state/cont"'
s3 0 'cat "$H/state/x.txt"'
s3 0 '[ -f "$H/state/x" ]'
s3 0 '# echo > $H/state/x'
s3 0 'echo "write state/x later"'
s3 0 "echo 'or rm -f \"\$H/state/x\" in single quotes'"
s3 0 'echo x > "$H/state/gh-etag/k"'
s3 0 'touch "$H/state/box-id"'
s3 0 'echo x > "$H/state/gh-policy-cache/r"'
s3 0 'echo x > "$H/state/settings-cache.json.tmp"'
s3 0 'D="$H/state"; echo x > "$D/gh-etag/k"'
s3 0 'echo x > "$H/gh-state/x"'
s3 0 'echo x > "$H/state-x/y"'
s3 0 'mytool --state/x; touch --state/x'
s3 0 'echo x > "$H/flags/y"'
s3 0 'echo x > "$H/logs/run.log"; touch "$BUILD/pr-body.md"'
s3 0 'grep -q x "$H/state/merge-conductor/a"'
s3 0 'while read -r l; do :; done < "$H/state/q"'
s3 0 'ls "$H/state/" 2>/dev/null'
s3 0 'echo warn >&2'
printf 'X="$H/state/x"\ntouch "$X"\n' > "$FX/bin/noext"; printf '#!/usr/bin/env bash\ntouch "$H/state/x"\n' > "$FX/bin/shebang"
[ "$(count_of "$FX/bin" noext)" = "" ] && [ "$(count_of "$FX/bin" shebang)" = 1 ] \
  && ok || bad "S3: file selection wrong (noext='$(count_of "$FX/bin" noext)' shebang='$(count_of "$FX/bin" shebang)')"

echo "--- S4: delta cases, hermetic repos"
# B: bin/a.sh has one raw site; bin/x.sh has none; the catalog classes gh-etag a cache.
dmk() {
  local R="$1"
  scratch_rm "$R" || return 1
  mkdir -p "$R/bin"; fixture_catalog "$R"
  printf '#!/bin/bash\necho 1 > "$H/state/a"\n' > "$R/bin/a.sh"
  printf '#!/bin/bash\n. "$H/bin/lib/jobs.sh"\ntrue\n' > "$R/bin/x.sh"
  rd_fixture_repo "$R"
}
d_main_raw()  { printf 'rm -f "$H/state/b"\n' >> "$1/bin/a.sh"; printf '#!/bin/bash\n: > "$H/state/m"\n' > "$1/bin/m.sh"; }
d_drift()     { rd_main_commit "$1" 'main: writers elsewhere' d_main_raw; }
d_pr_docs()   { echo more >> "$1/README"; rd_git "$1" commit -qam 'pr: docs'; }
d_pr_raw()    { printf 'echo hi > "$H/state/new"\n' >> "$1/bin/x.sh"; rd_git "$1" commit -qam 'pr: x.sh gains a raw writer'; }
d_pr_add()    { printf 'touch "$H/state/a2"\n' >> "$1/bin/a.sh"; rd_git "$1" commit -qam 'pr: a.sh gains a site'; }
d_pr_rmsite() { printf '#!/bin/bash\ntrue\n' > "$1/bin/a.sh"; rd_git "$1" commit -qam 'pr: a.sh drops its site'; }
d_pr_conv()   { printf '#!/bin/bash\njobs_req PUT /api/x\n' > "$1/bin/a.sh"; rd_git "$1" commit -qam 'pr: convert a.sh'; }
d_pr_allow()  { printf 'echo k > "$H/state/gh-etag/k"\n' >> "$1/bin/x.sh"; rd_git "$1" commit -qam 'pr: x.sh writes the etag cache'; }
d_pr_newc()   { printf 'echo k > "$H/state/newcache/k"\n' >> "$1/bin/x.sh"; rd_git "$1" commit -qam 'pr: x.sh writes newcache'; }
d_pr_class()  { jq '.paths += [{"path":"newcache","class":"cache","authority":"fixture"}]' "$1/catalog/state-paths.json" > "$1/c.tmp" \
                  && mv "$1/c.tmp" "$1/catalog/state-paths.json" && rd_git "$1" commit -qam 'pr: class newcache a cache'; }
d_pr_new()    { printf '#!/bin/bash\nmkdir -p "$H/state/n"\n' > "$1/bin/n.sh"; rd_git "$1" add -A; rd_git "$1" commit -qm 'pr: new writer file'; }
d_merge()     { rd_git "$1" merge -q --no-edit refs/remotes/origin/main; }
d_nomain()    { rd_git "$1" update-ref -d refs/remotes/origin/main; }
dcase() {  # <name> <want_rc> <RATCHET_BASE: main|B|none|bogus> <steps...>
  local name="$1" want="$2" rb="$3" R="$T/d-$1" b step out rc
  shift 3
  dmk "$R" || { bad "S4($name): repo setup failed"; return; }
  b=$(rd_git "$R" rev-parse HEAD)
  for step in "$@"; do "$step" "$R" >/dev/null || { bad "S4($name): step $step failed"; return; }; done
  case "$rb" in
    main)  rb=$(rd_git "$R" rev-parse refs/remotes/origin/main) ;;
    B)     rb="$b" ;;
    none)  rb="" ;;
    bogus) rb=0123456789abcdef0123456789abcdef01234567 ;;
  esac
  out=$(RATCHET_BASE="$rb" TI_BASE= real_check "$R" 2>&1); rc=$?
  if [ "$rc" = "$want" ]; then ok; else bad "S4($name) rc=$rc want $want:"$'\n'"$out"; fi
}
dcase pr-adds-writer           1 main  d_pr_raw
dcase pr-adds-site             1 main  d_pr_add
dcase pr-adds-new-file         1 main  d_drift d_pr_new d_merge
dcase pr-adds-after-drift      1 main  d_drift d_pr_raw d_merge
dcase pr-unclassed-cache       1 main  d_pr_newc
dcase bogus-base               1 bogus d_pr_docs
dcase no-base-at-all           1 none  d_pr_docs d_nomain
dcase pr-removes-site          0 main  d_pr_rmsite
dcase pr-converts              0 main  d_pr_conv
dcase pr-allowlisted-write     0 main  d_pr_allow
dcase pr-reclassifies          0 main  d_pr_newc d_pr_class
dcase main-drift-docs-only     0 main  d_drift d_pr_docs d_merge
dcase main-drift-stale-base    0 B     d_drift d_pr_docs d_merge
dcase main-drift-local         0 none  d_drift d_pr_docs d_merge

echo "--- S5: an unreadable catalog is red, never an empty allowlist"
s5() {  # <name> <catalog-step>
  local R="$T/s5-$1" out rc
  dmk "$R" >/dev/null || { bad "S5($1): repo setup failed"; return; }
  "$2" "$R"
  out=$(RATCHET_BASE= TI_BASE= real_check "$R" 2>&1); rc=$?
  [ "$rc" -eq 1 ] && grep -q 'RED: cannot read the allowlist' <<<"$out" \
    && ok || bad "S5($1): want rc 1 and 'cannot read the allowlist' (rc=$rc): $out"
}
c_missing() { rm -f "$1/catalog/state-paths.json"; }
c_badjson() { echo '{"paths": [' > "$1/catalog/state-paths.json"; }
c_nolist()  { echo '{"paths": {"gh-etag": "cache"}}' > "$1/catalog/state-paths.json"; }
s5 missing c_missing
s5 bad-json c_badjson
s5 paths-not-a-list c_nolist
OUT=$(NO_STATE_FILES_REPO="$T/s5-missing" bash "$SELF" --list 2>&1); RC=$?
[ "$RC" -eq 1 ] && grep -q 'RED: cannot read the allowlist' <<<"$OUT" \
  && ok || bad "S5: --list on a missing catalog: want rc 1 (rc=$RC): $OUT"

echo "--- S6: --list and --list-segments rows, and a round trip through rd_delta"
OUT=$(bash "$SELF" --list); RC=$?
N=$(grep -c . <<<"$OUT"); SHAPE=$(grep -cvP '^[^\t]+\t[1-9][0-9]*$' <<<"$OUT")
[ "$RC" -eq 0 ] && [ "$N" -ge 1 ] && [ "$SHAPE" -eq 0 ] \
  && ok || bad "S6: --list on the real tree: rc=$RC rows=$N bad-shape=$SHAPE"
R="$T/s6"; dmk "$R" >/dev/null || bad "S6: repo setup failed"
printf 'echo k > "$H/state/gh-etag/k"\nmkdir -p "$H/state/$x"\n' >> "$R/bin/x.sh"
NO_STATE_FILES_REPO="$R" bash "$SELF" --list > "$T/s6.base"; RC=$?
[ "$RC" -eq 0 ] && [ "$(cat "$T/s6.base")" = $'a.sh\t1\nx.sh\t1' ] \
  && ok || bad "S6: --list on the fixture (rc=$RC): $(cat "$T/s6.base")"
OUT=$(NO_STATE_FILES_REPO="$R" bash "$SELF" --list-segments); RC=$?
[ "$RC" -eq 0 ] && [ "$OUT" = $'(dynamic)\t1\na\t1' ] \
  && ok || bad "S6: --list-segments on the fixture (rc=$RC): $OUT"
printf 'touch "$H/state/a3"\n' >> "$R/bin/a.sh"
NO_STATE_FILES_REPO="$R" bash "$SELF" --list > "$T/s6.head"
OUT=$(rd_delta "$T/s6.head" "$T/s6.base"); RC=$?
[ "$RC" -eq 1 ] && [ "$OUT" = $'a.sh\t2\t1' ] && ok || bad "S6: rd_delta over two --list outputs (rc=$RC): $OUT"

echo "--- S7: strict mode and unknown flags are refused"
# The child runs point at a fixture, so a broken refusal runs S1 there and
# stops; it never starts these case groups again.
for args in "--strict" "--write-baseline"; do
  OUT=$(NO_STATE_FILES_REPO="$R" RATCHET_BASE= TI_BASE= bash "$SELF" $args 2>&1); RC=$?
  [ "$RC" -eq 2 ] && ok || bad "S7: '$args' want rc 2 (rc=$RC): $OUT"
done
OUT=$(NO_STATE_FILES_REPO="$R" RATCHET_BASE= TI_BASE= RATCHET_MODE=strict bash "$SELF" 2>&1); RC=$?
[ "$RC" -eq 2 ] && grep -q 'delta only' <<<"$OUT" && ok || bad "S7: RATCHET_MODE=strict want rc 2 (rc=$RC): $OUT"

echo "no-state-files ($MODE): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
