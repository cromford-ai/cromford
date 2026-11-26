#!/bin/bash
# tests/share-sanitize-prefilter.bh-9465-test.sh — the literal prefilter in
# bin/share/sanitize.py rewrite() skips only rules that cannot match, and the
# output is byte-identical to a run that tries every rule (BH-9465).
#
# rewrite() ran every rule of RULES (about 235 compiled regexes) over every
# text file of the tree, and one public-mirror build took more than 11 minutes.
# The prefilter keeps, per rule, a literal that every match must contain
# (NEEDLES, parallel to RULES) and skips the rule when that literal is not in
# the CURRENT text. A case-insensitive rule is never skipped on a text that
# holds a character re.I folds onto an ASCII letter (U+212A Kelvin sign as k,
# U+017F long s as s, sanitize.FOLD_GUARD) or any character above U+FFFF.
#
#   P1  rewrite(prefilter=False) == rewrite(prefilter=True), byte for byte, over
#       a bounded, deterministic set of this checkout's text files: every file
#       that holds a needle (capped) plus a fixed sample of the sorted list.
#   P2  the same over adversarial strings: the empty string, every case-folding
#       non-ASCII twin of every icase needle, every pair where an earlier
#       rule's replacement creates (alone or with the text after it) a later
#       rule's needle, and an ASCII text where a skipped rule would be wrong.
#   P3  the prefilter is real: most rules carry a needle; on an ASCII text with
#       no needle only the needle-less rules run, and the same with an em dash;
#       a text with a folding or astral character runs every icase rule.
#   P4  wall time of both modes over the P1 set (printed, not asserted).
#
# The full-tree old-vs-new proof (diff -r of two whole mirrors) is a one-off in
# the PR body: it takes more than 11 minutes on the old code. This suite never
# reads origin/main, so it passes on main after the merge.
#
# No private name is spelled in this file, and none is printed: a failure names
# the rule index and the file, never the needle.
#
# Sources under test: "$DIR/bin/share/sanitize.py" "$DIR/bin/share/mapping.py"
#
# Run from anywhere: tests/share-sanitize-prefilter.bh-9465-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
export PYTHONDONTWRITEBYTECODE=1

if [ ! -f "$DIR/bin/share/sanitize.py" ]; then
  echo "SKIP: bin/share/ is not in this tree (the public mirror)"
  echo "share-sanitize-prefilter.bh-9465: 0 pass, 0 fail, 1 skip"
  exit 0
fi

# The file list: git's view when this is a checkout, else every file.
LIST="$T/files.txt"
if git -C "$DIR" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$DIR" ls-files > "$LIST"
else
  ( cd "$DIR" && find . -type f ! -path './.git/*' ! -path '*/node_modules/*' | sed 's|^\./||' ) > "$LIST"
fi
LC_ALL=C sort -o "$LIST" "$LIST"

python3 -B - "$DIR" "$LIST" <<'PY'
import hashlib, os, re, sys, time
repo, listfile = sys.argv[1], sys.argv[2]
sys.path.insert(0, os.path.join(repo, "bin", "share"))
import sanitize as sz  # noqa: E402

PASS = FAIL = 0
def ok():
    global PASS
    PASS += 1
def bad(msg):
    global FAIL
    FAIL += 1
    print("FAIL: " + msg)

def both(text):
    return sz.rewrite(text, prefilter=False), sz.rewrite(text, prefilter=True)

try:
    sz.rewrite("", prefilter=False)
    needles = sz.NEEDLES
except (TypeError, AttributeError) as e:
    print("FAIL: sanitize has no prefilter (rewrite(prefilter=...) and NEEDLES): %s" % e)
    print("share-sanitize-prefilter.bh-9465: 0 pass, 1 fail")
    sys.exit(1)

# ── P1 real files ────────────────────────────────────────────────────────────
NEEDLE_CAP, SAMPLE_CAP, MAX_BYTES = 150, 80, 200000
rels = [ln for ln in open(listfile, encoding="utf-8", errors="surrogateescape").read().split("\n") if ln]
def read_text(rel):
    p = os.path.join(repo, rel)
    if rel.startswith("bin/share/") or not os.path.isfile(p) or os.path.getsize(p) > MAX_BYTES:
        return None
    with open(p, "rb") as fh:
        raw = fh.read()
    if b"\0" in raw[:8192]:
        return None
    return raw.decode("utf-8", errors="surrogateescape")
def has_needle(text):
    low = None
    for nd in needles:
        if nd is None:
            continue
        lit, icase = nd
        if icase:
            low = text.lower() if low is None else low
            if lit in low:
                return True
        elif lit in text:
            return True
    return False
picked, with_needle = [], 0
step = max(1, len(rels) // SAMPLE_CAP)
sample = set(rels[::step][:SAMPLE_CAP])
# Needle files in a fixed hash order, so the cap spreads over the whole tree
# instead of the first directories by name.
for rel in sorted(rels, key=lambda r: hashlib.sha1(r.encode("utf-8", "surrogateescape")).hexdigest()):
    in_sample = rel in sample
    if with_needle >= NEEDLE_CAP and not in_sample:
        continue
    text = read_text(rel)
    if text is None:
        continue
    hit = has_needle(text)
    if hit and with_needle < NEEDLE_CAP:
        with_needle += 1
        picked.append((rel, text))
    elif in_sample:
        picked.append((rel, text))
non_ascii = sum(1 for _, t in picked if not t.isascii())
t_off = t_on = 0.0
diff = []
for rel, text in picked:
    a = time.monotonic(); off = sz.rewrite(text, prefilter=False); b = time.monotonic()
    on = sz.rewrite(text, prefilter=True); c = time.monotonic()
    t_off += b - a; t_on += c - b
    if off != on:
        diff.append(rel)
if with_needle >= 20 and len(picked) >= 60:
    ok()
else:
    bad("P1 the file set is too small to prove anything: %d files, %d with a needle" % (len(picked), with_needle))
if not diff:
    ok()
else:
    bad("P1 prefilter output differs from the full rule run in %d file(s): %s" % (len(diff), ", ".join(diff[:8])))
print("P1: %d files (%d with a needle, %d non-ASCII), %d differ" % (len(picked), with_needle, non_ascii, len(diff)))

# ── P2 adversarial strings ───────────────────────────────────────────────────
cases = [("empty", ""), ("ascii, no needle", "plain words, nothing to rewrite here\n")]
# every non-ASCII code point that re.I folds onto an ASCII letter
folds = {}
for cp in range(0x80, 0x10000):
    ch = chr(cp)
    if ch.isascii():
        continue
    for letter in "abcdefghijklmnopqrstuvwxyz":
        if re.fullmatch(re.escape(letter), ch, re.I):
            folds.setdefault(letter, []).append(ch)
if "k" in folds and "\u212a" in folds["k"] and "s" in folds and "\u017f" in folds["s"]:
    ok()
else:
    bad("P2 fixture: this python does not fold U+212A to k and U+017F to s (folds: %r)" % sorted(folds))
cases.append(("Kelvin-sign Key", "\u212aey"))
cases.append(("long-s secret", "\u017fecret"))
n_fold = 0
for i, nd in enumerate(needles):
    if nd is None or not nd[1]:
        continue
    lit = nd[0]
    for pos, letter in enumerate(lit):
        for ch in folds.get(letter, []):
            twin = lit[:pos] + ch + lit[pos + 1:]
            cases.append(("rule %d fold U+%04X at %d" % (i, ord(ch), pos), "x " + twin + " y\n"))
            cases.append(("rule %d fold U+%04X at %d, upper" % (i, ord(ch), pos), twin.upper()))
            n_fold += 1
# an earlier rule's literal replacement creates a later rule's needle, whole or
# as a prefix finished by the text that follows it
n_chain = 0
for j, ndj in enumerate(needles):
    if ndj is None:
        continue
    lj, icj = ndj
    for i in range(j):
        ndi = needles[i]
        if ndi is None:
            continue
        rep = sz.RULES[i][1]
        if not isinstance(rep, str) or "\\" in rep:
            continue
        src = ndi[0]
        r = rep.lower() if icj else rep
        if lj in r:
            cases.append(("rule %d output holds rule %d needle" % (i, j), "a " + src + " b\n"))
            n_chain += 1
            continue
        for k in range(1, min(len(r), len(lj))):
            if r.endswith(lj[:k]):
                cases.append(("rule %d output starts rule %d needle" % (i, j), "a " + src + lj[k:] + " b\n"))
                n_chain += 1
                break
n_diff = 0
for label, text in cases:
    off, on = both(text)
    if off != on:
        n_diff += 1
        if n_diff <= 8:
            bad("P2 %s: prefilter output differs" % label)
if n_diff == 0:
    ok()
elif n_diff > 8:
    bad("P2 ... and %d more adversarial strings differ" % (n_diff - 8))
if n_fold > 0:
    ok()
else:
    bad("P2 fixture: no icase needle holds a folding letter, so the non-ASCII guard went untested")
print("P2: %d strings (%d fold twins, %d chained pairs), %d differ" % (len(cases), n_fold, n_chain, n_diff))

# ── P3 the prefilter really skips ────────────────────────────────────────────
n_needle = sum(1 for nd in needles if nd is not None)
n_none = len(needles) - n_needle
if len(needles) == len(sz.RULES) and n_needle * 2 > len(needles):
    ok()
else:
    bad("P3 NEEDLES must be parallel to RULES and cover most rules (%d of %d rules, %d needles)"
        % (n_needle, len(sz.RULES), len(needles)))

class Count:
    """A rule stand-in that counts sub() calls and delegates to the real one."""
    def __init__(self, rx):
        self.rx, self.n = rx, 0
    def sub(self, rep, text):
        self.n += 1
        return self.rx.sub(rep, text)
    def subn(self, rep, text):
        self.n += 1
        return self.rx.subn(rep, text)
orig = sz.RULES[:]
counted = [(Count(rx), rep) for rx, rep in orig]
sz.RULES[:] = counted
try:
    plain = "plain words, nothing to rewrite here\n"
    sz.rewrite(plain, prefilter=True)
    ran = sum(c.n for c, _ in counted)
    if ran == n_none:
        ok()
    else:
        bad("P3 an ASCII text with no needle must run only the %d needle-less rules (ran %d)" % (n_none, ran))
    n_cs = sum(1 for nd in needles if nd is not None and not nd[1])
    for ch in ("\u212a", "\u017f", "\U0001F600"):
        for c, _ in counted:
            c.n = 0
        sz.rewrite(plain + ch + "\n", prefilter=True)
        ran_na = sum(c.n for c, _ in counted)
        if ran_na == len(needles) - n_cs:
            ok()
        else:
            bad("P3 a text with U+%04X must run every icase rule (ran %d, want %d)"
                % (ord(ch), ran_na, len(needles) - n_cs))
    # An em dash is non-ASCII but folds onto no ASCII letter: the icase rules
    # may still be skipped (most files of this repo hold one).
    for c, _ in counted:
        c.n = 0
    sz.rewrite(plain + "\u2014 caf\u00e9\n", prefilter=True)
    ran_dash = sum(c.n for c, _ in counted)
    if ran_dash == n_none:
        ok()
    else:
        bad("P3 a text whose only non-ASCII is an em dash and an e-acute must run only the %d needle-less rules (ran %d)"
            % (n_none, ran_dash))
    for c, _ in counted:
        c.n = 0
    sz.rewrite(plain, prefilter=False)
    if sum(c.n for c, _ in counted) == len(counted):
        ok()
    else:
        bad("P3 prefilter=False must run every rule")
finally:
    sz.RULES[:] = orig

# ── P4 timing ────────────────────────────────────────────────────────────────
print("P4: %d files, every rule %.2fs, prefilter %.2fs" % (len(picked), t_off, t_on))
print("share-sanitize-prefilter.bh-9465: %d pass, %d fail" % (PASS, FAIL))
sys.exit(1 if FAIL else 0)
PY
