#!/bin/bash
# tests/share-env-prefix.bh-8680-test.sh — every project whose name the
# sanitizer rewrites in shell code must also have an ENV_PREFIXES row (BH-8680).
#
# The PROJECTS rows are case-insensitive. With no prefix row, an uppercase shell
# variable <NAME>_SECTION became `project-21_SECTION=` in the public mirror. That
# is not a shell name: the public CI's shellcheck step failed on bin/lib/rb/pr.sh.
#
# No private name is spelled in this file: it is glued at run time.
#
# Sources under test: "$DIR/bin/share/sanitize.py" "$DIR/bin/share/mapping.py" "$DIR/bin/share/leakcheck.py"
#
# Run from anywhere: tests/share-env-prefix.bh-8680-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0; SKIP=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

if [ ! -f "$DIR/bin/share/sanitize.py" ]; then
  echo "SKIP: bin/share/ is not in this tree (the public mirror)"
  echo "share-env-prefix.bh-8680-test: 0 pass, 0 fail, 1 skip"
  exit 0
fi

LO="toc""sin"
UP="TOC""SIN"
LC="$DIR/bin/share/leakcheck.py"

# E1-E6: the sanitizer, driven through sanitize.rewrite (the publisher's call)
git -C "$DIR" ls-files -- 'bin/*.sh' 'bin/**/*.sh' 'tests/lib/*.sh' > "$T/files.txt"
python3 - "$DIR" "$LO" "$UP" "$T/files.txt" > "$T/s.out" 2>&1 <<'PY'
import os, re, sys
d, lo, up, flist = sys.argv[1:5]
sys.path.insert(0, os.path.join(d, "bin", "share"))
import sanitize
res = []
def eq(name, src, want):
    got = sanitize.rewrite(src)
    res.append((name, got == want, repr(got)))
eq("E1", up + '_SECTION=""', 'PROJECT_21_SECTION=""')
eq("E2", "${" + up + "_BASE_URL-https://" + lo + ".sh}",
   "${PROJECT_21_BASE_URL-https://project-21.example}")
eq("E3", '[ -n "$' + up + '_SECTION" ]', '[ -n "$PROJECT_21_SECTION" ]')
eq("E4", lo + "_build_run", "project-21_build_run")
got = sanitize.rewrite(up + "_x")
res.append(("E5", not got.startswith("PROJECT_21_"), repr(got)))
broken = re.compile(r"(?<![\w-])project-\d+(?:-[a-z]+)?_[A-Z]")
hits = []
with open(flist) as fh:
    files = [l.strip() for l in fh if l.strip()]
for rel in files:
    p = os.path.join(d, rel)
    if not os.path.isfile(p):
        continue
    with open(p, errors="replace") as f:
        out = sanitize.rewrite(f.read())
    for n, line in enumerate(out.splitlines(), 1):
        if broken.search(line):
            hits.append("%s:%d" % (rel, n))
res.append(("E6 (%d files)" % len(files), bool(files) and not hits,
            " ".join(hits[:10])))
for name, good, detail in res:
    print(("OK " if good else "BAD ") + name + " " + detail)
PY
while read -r verdict rest; do
  case "$verdict" in
    OK) ok ;;
    BAD) bad "$rest" ;;
    *) bad "sanitizer driver: $verdict $rest" ;;
  esac
done < "$T/s.out"
[ -s "$T/s.out" ] || bad "sanitizer driver printed nothing"

# E7: the guard refuses a surviving prefix as a prefix, not only as a name
mkdir -p "$T/g7"; printf '%s\n' "${UP}_SECTION=1" > "$T/g7/x.sh"
out=$(python3 "$LC" "$T/g7" 2>/dev/null); rc=$?
if [ "$rc" -eq 1 ] && grep -qx "x.sh:1: per-project env prefix: ${UP}_" <<<"$out"; then ok; else
  bad "E7: guard did not flag the env prefix (rc=$rc): $out"
fi

echo "share-env-prefix.bh-8680-test: $PASS pass, $FAIL fail, $SKIP skip"
[ "$FAIL" -eq 0 ]
