#!/bin/bash
# tests/leakcheck-prefilter.bh-9465-test.sh — the per-file prefilter in
# bin/share/leakcheck.py scan() skips only rules that cannot hit, and the hit
# list is the same, in the same order, as a scan that runs every rule on every
# line (BH-9465).
#
# scan() ran about 20 regexes on every line of every text file. Over one
# public mirror (14024 files) that took 184 s, and share-publish-clean.bh-795
# took 235 s with the mirror already cached. NAME_RE, one re.I alternation of
# every name, was 13.1 of 19.4 s of that. The prefilter skips NAME_RE on a file
# whose lower-cased text holds no lower-cased name, unless the text holds a
# character re.I folds onto a name letter (leakcheck.NAME_FOLD).
#
#   K1  scan(prefilter=False) == scan(prefilter=True) over a fixture tree built
#       here from bin/share/mapping.py: a name, a bounded name, every pattern
#       shape, several hits on one line, a hit after a "\t" escape, CRLF and
#       CR-only files, \v \f \x1c \x85 \u2028 inside a line (text file
#       iteration splits on "\n" only), no final newline, an empty file, bad
#       UTF-8, a Bearer split over two lines, a known fake.
#   K2  the same over a bounded, deterministic set of this checkout's files
#       (the private tree, so it holds real hits): every 7th file of git's
#       sorted list, the walk order and the line numbers included.
#       Fold twins: a name with k, s or i swapped for U+212A, U+017F or U+0130
#       (re.I matches them), and an astral character: NAME_RE must still run.
#   K3  the prefilter is real: NAME_RE never runs on a file with no name, and
#       NAME_FOLD holds the fold letters and the astral planes.
#   K4  wall time of both modes over the K2 set (printed, not asserted).
#
# No private name is spelled in this file, and none is printed: a failure
# names the case and the counts, never a match.
#
# Sources under test: "$DIR/bin/share/leakcheck.py" "$DIR/bin/share/mapping.py"
#
# Run from anywhere: tests/leakcheck-prefilter.bh-9465-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export PYTHONDONTWRITEBYTECODE=1

if [ ! -f "$DIR/bin/share/leakcheck.py" ] || [ ! -f "$DIR/bin/share/mapping.py" ]; then
  echo "SKIP: bin/share/ is not in this tree (the public mirror)"
  echo "leakcheck-prefilter.bh-9465: 0 pass, 0 fail, 1 skip"
  exit 0
fi

LIST="$T/files.txt"
if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$DIR" ls-files > "$LIST"
else
  ( cd "$DIR" && find . -type f ! -path './.git/*' ! -path '*/node_modules/*' | sed 's|^\./||' ) > "$LIST"
fi
LC_ALL=C sort -o "$LIST" "$LIST"

python3 -B - "$DIR" "$LIST" "$T" <<'PY'
import os, shutil, sys, time
repo, listfile, tmp = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, os.path.join(repo, "bin", "share"))
import leakcheck as lc  # noqa: E402

PASS = FAIL = 0
def ok():
    global PASS
    PASS += 1
def bad(msg):
    global FAIL
    FAIL += 1
    print("FAIL: " + msg)

try:
    lc.scan(os.path.join(tmp, "nothing"), prefilter=False)
except TypeError as e:
    print("FAIL: leakcheck.scan has no prefilter (scan(root, prefilter=...)): %s" % e)
    print("leakcheck-prefilter.bh-9465: 0 pass, 1 fail")
    sys.exit(1)

def compare(case, root):
    old = lc.scan(root, prefilter=False)
    new = lc.scan(root, prefilter=True)
    if old == new:
        ok()
    else:
        diff = sum(1 for a, b in zip(old, new) if a != b) + abs(len(old) - len(new))
        bad("%s: %d hit(s) every rule vs %d prefilter, %d differ" % (case, len(old), len(new), diff))
    return old

# K1 fixture tree, from the mapping, never spelled here.
name = sorted(lc.NAMES, key=len)[-1]
bounded = sorted(lc.BOUNDED)[0]
ticket = "%s-123" % sorted(lc.TICKET_PREFIXES)[0]
fake = sorted(lc.KNOWN_FAKES)[0] if lc.KNOWN_FAKES else "sk-" + "a" * 20
tok = "b1c2" * 8
shapes = [
    # built at run time: this file ships in the public mirror, and its own
    # leakcheck must not hit a spelled address or uuid.
    ".".join(["100", "64", "1", "2"]), ticket,
    "-".join(["1234abcd", "12ab", "34cd", "56ef", "1234567890ab"]), "f" * 31 + "e",
    "prj_" + "Q" * 22, "-100" + "1234567890", "sk-" + "A1b2" * 5, "ghp_" + "Z" * 24,
    "xoxb-" + "1" * 12, "AKIA" + "B" * 16, "-----BEGIN RSA PRIVATE KEY-----",
    "Bearer " + tok, "c" * 63 + "d", "https://%s@o1.ingest.sentry.io/42" % ("a" * 32),
]
K = os.path.join(tmp, "k1")
os.makedirs(os.path.join(K, "sub"))
def w(rel, data):
    with open(os.path.join(K, rel), "wb") as fh:
        fh.write(data if isinstance(data, bytes) else data.encode("utf-8"))
w("a.md", "plain line\n%s and %s on one line, %s\nclean\n" % (name, name.upper(), bounded))
w("b.sh", "x='\\t%s'\nlast line with no newline %s" % (bounded, shapes[0]))
w("c.txt", "".join("%d %s\n" % (i, s) for i, s in enumerate(shapes)))
w("d.md", ("one\r\ntwo %s\r\nthree %s\r\n" % (name, shapes[1])).encode())
w("e.md", ("one\rtwo %s\rthree\r%s\r" % (name, shapes[2])).encode())
w("f.md", "a\vb %s\fc\x1cd\x85e\u2028f %s\ng %s\n" % (name, shapes[3], bounded))
w("g.md", "")
w("h.md", b"bad \xff\xfe utf8 " + name.encode() + b"\n\xc3\n" + shapes[4].encode() + b"\n")
w("i.md", "Bearer\n" + tok + "\nBearer " + tok + "\n")
w("j.md", "known %s fake\n%s\n" % (fake, shapes[12]))
w("sub/k.md", "nothing here at all\njust prose\n")
# re.I fold twins: a name whose ASCII letters are swapped for the non-ASCII
# letters re.I matches against them. No plain name is in these files, so only
# the NAME_FOLD guard keeps NAME_RE running on them.
TWIN = {"k": "\u212a", "s": "\u017f", "i": "\u0130"}
twins = [n for n in sorted(lc.NAMES_LOW) if any(c in TWIN for c in n)][:5]
for i, nm in enumerate(twins):
    c = next(c for c in nm if c in TWIN)
    w("fold%d.md" % i, "x %s y\n" % nm.replace(c, TWIN[c], 1))
w("astral.md", "\U0001F600 %s\n" % twins[0] if twins else "\U0001F600\n")
w("sub/%s.md" % bounded, "the path itself hits\n")
old = compare("K1 fixture tree", K)
if len(old) >= len(shapes):
    ok()
else:
    bad("K1 the fixture tree must hit (%d hits): it proves nothing otherwise" % len(old))
fold_hits = [h for h in old if h[0].startswith("fold")]
if twins and len(fold_hits) >= len(twins):
    ok()
else:
    bad("K1 every fold twin must be a NAME_RE hit (%d twins, %d hits): the fold case proves nothing otherwise" % (len(twins), len(fold_hits)))

# K2 a bounded sample of this checkout, copied with its paths.
with open(listfile) as fh:
    files = [l.rstrip("\n") for l in fh if l.strip()]
pick = files[::7]
S = os.path.join(tmp, "k2")
n = 0
for rel in pick:
    src = os.path.join(repo, rel)
    if not os.path.isfile(src) or os.path.islink(src):
        continue
    dst = os.path.join(S, rel)
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    shutil.copyfile(src, dst)
    n += 1
t0 = time.time(); old = lc.scan(S, prefilter=False); t1 = time.time()
new = lc.scan(S, prefilter=True); t2 = time.time()
if old == new:
    ok()
else:
    bad("K2 checkout sample: %d hit(s) every rule vs %d prefilter" % (len(old), len(new)))
if old:
    ok()
else:
    bad("K2 the checkout sample must hold real hits (0): it proves nothing otherwise")

# K3 the prefilter is real: NAME_RE never runs on a file with no name in it.
class Counted:
    def __init__(self, rx):
        self.rx, self.n = rx, 0
    def finditer(self, s):
        # a line ends in "\n" (every K tree file does); a path never does,
        # and the path scan is not what the prefilter skips.
        if s.endswith("\n"):
            self.n += 1
        return self.rx.finditer(s)
real = lc.NAME_RE
lc.NAME_RE = Counted(real)
lc.scan(os.path.join(K, "sub"), prefilter=True)
c_clean = lc.NAME_RE.n
lc.NAME_RE = Counted(real)
lc.scan(K, prefilter=True)
c_all = lc.NAME_RE.n
lc.NAME_RE = real
if c_clean == 0 and c_all > 0:
    ok()
else:
    bad("K3 a file with no name must skip NAME_RE (clean dir %d calls, fixture tree %d)" % (c_clean, c_all))
if lc.NAME_FOLD is not None and lc.NAME_FOLD.search("\u212a\u017f") and lc.NAME_FOLD.search("\U0001F600"):
    ok()
else:
    bad("K3 NAME_FOLD must hold U+212A, U+017F and the astral planes")

print("K1: %d fixture files, %d fold twins; K2: %d checkout files, %d hits" % (len(os.listdir(K)), len(twins), n, len(old)))
print("K4: %d files, every rule %.2fs, prefilter %.2fs" % (n, t1 - t0, t2 - t1))
print("leakcheck-prefilter.bh-9465: %d pass, %d fail" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
