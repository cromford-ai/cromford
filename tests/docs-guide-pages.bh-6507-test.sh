#!/bin/bash
# tests/docs-guide-pages.bh-6507-test.sh — the user guide folder docs/guide/
# (BH-6507). The docs site builds its guide from this folder: every Markdown
# file under it is a page, the title is frontmatter `title` or the first
# `# Heading`, the order is frontmatter `order` or the filename number, and
# the site owns the home page.
#
# One checker (the python below) takes a root and prints one reason line per
# failure. The suite runs it on the checkout, on the public mirror and on
# negative fixtures:
#
#   G0  docs/guide/ holds exactly the four pages; no index.md or README.md
#   G1  every page has a title
#   G2  order values are whole numbers, unique, and equal the filename number
#   G3  no frontmatter slug; no two pages on one URL
#   G4  every relative link resolves to a file under the root; a .md anchor
#       names a heading; no http:// link
#   G5  every fenced bash/sh command starts with an executable bin/ script or
#       a word on ALLOW; every --flag of a bin/ command is in that script
#   G6  every backticked UPPER_SNAKE setting is defined in env-templates/,
#       catalog/, bin/ or worker/
#   G7  every backticked bin/, catalog/ or env-templates/ path exists
#   G8  no internal tracker id; no "is public" / "now live"
#   G9  docs/guide.md names `docs/guide/`, and its "What Cromford is" text
#       moved to docs/guide/01-quickstart.md
#   P1  the publisher's mirror build carries docs/guide/ with the four pages
#   P2  each mirrored page is byte-identical to its source
#   P3  the shipped name guard and leakcheck pass on the mirror; the checker
#       passes on the mirror
#   P4  every relative non-guide link target also ships in the mirror
#   N1-N5 the checker goes red on: no title, a duplicate order, a dead link,
#       a script that does not exist, a flag the script does not take
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/docs-guide-pages.bh-6507-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/share-mirror.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PAGES=(01-quickstart.md 02-onboarding.md 03-connectors.md 04-archie.md)
# The words a fenced command may start with when it is not a bin/ script.
ALLOW=(bash cp cd git gh python3 node curl corepack)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# check <root>: OUT gets the reason lines, RC the checker's exit code.
check() { OUT=$(python3 - "$1" "${ALLOW[*]}" "${PAGES[*]}" 2>&1 <<'PY'
import os, re, sys

base, allow, want = sys.argv[1], set(sys.argv[2].split()), sys.argv[3].split()
GUIDE = os.path.join(base, "docs", "guide")
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s]+)\)")
CODE_SPAN = re.compile(r"`([^`]+)`")
SETTING = re.compile(r"^([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)(?:=\S*)?$")
TICKET = re.compile(r"(?:^|[\s(])(#\d+)\b|\b([A-Z]{2,}-\d+)\b")
NOT_TICKETS = {"UTF", "SHA", "ISO", "RFC", "CVE"}
OVERLAY = os.path.join("bin", "share", "overlay")
fails = []


def fail(g, rel, why):
    fails.append(f"{g} {rel}: {why}")


def read(p):
    with open(p, encoding="utf-8") as f:
        return f.read()


def front(text):
    """(frontmatter dict, body). Frontmatter is a leading --- block."""
    m = re.match(r"---\n(.*?)\n---\n", text, re.S)
    if not m:
        return {}, text
    fm = {}
    for line in m.group(1).splitlines():
        k, sep, v = line.partition(":")
        if sep and k.strip():
            fm[k.strip()] = v.strip().strip("\"'")
    return fm, text[m.end():]


def split_code(text):
    """(prose lines, [(info, [lines])] fenced blocks)."""
    prose, blocks, cur = [], [], None
    for line in text.splitlines():
        s = line.lstrip()
        if s.startswith("```"):
            if cur is None:
                cur = (s[3:].strip().lower(), [])
            else:
                blocks.append(cur)
                cur = None
            continue
        (cur[1] if cur is not None else prose).append(line)
    return prose, blocks


def slugs(text):
    seen, out = {}, set()
    for line in split_code(text)[0]:
        m = re.match(r"#{1,6}\s+(.*?)\s*#*\s*$", line)
        if not m:
            continue
        h = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", m.group(1)).replace("`", "")
        s = re.sub(r"[^\w\- ]", "", h.lower()).replace(" ", "-")
        n = seen.get(s, 0)
        seen[s] = n + 1
        out.add(s if n == 0 else f"{s}-{n}")
    return out


def found(path):
    for p in (os.path.join(base, path), os.path.join(base, OVERLAY, path)):
        if os.path.exists(p):
            return p
    return None


_words = None


def defined(name):
    """name is a whole word in env-templates/, catalog/, bin/ or worker/."""
    global _words
    if _words is None:
        _words = set()
        for top in ("env-templates", "catalog", "bin", "worker"):
            for d, subdirs, files in os.walk(os.path.join(base, top), followlinks=True):
                subdirs[:] = [s for s in subdirs if s not in ("node_modules", ".git")]
                for fn in files:
                    try:
                        with open(os.path.join(d, fn), encoding="utf-8", errors="ignore") as f:
                            _words.update(re.findall(r"[A-Za-z0-9_]+", f.read()))
                    except OSError:
                        pass
    return name in _words


# G0
if not os.path.isdir(GUIDE):
    print("G0 docs/guide: missing folder")
    sys.exit(1)
pages = []
for d, _, files in os.walk(GUIDE):
    for fn in files:
        if fn.endswith((".md", ".mdx")):
            pages.append(os.path.relpath(os.path.join(d, fn), GUIDE))
pages.sort()
if pages != sorted(want):
    fail("G0", "docs/guide", f"pages are {pages}, want {sorted(want)}")
for fn in ("index.md", "index.mdx", "README.md"):
    if os.path.exists(os.path.join(GUIDE, fn)):
        fail("G0", "docs/guide", f"has a root {fn}; the site owns the home page")

orders, urls = {}, {}
for page in pages:
    rel = "docs/guide/" + page
    path = os.path.join(GUIDE, page)
    text = read(path)
    fm, body = front(text)
    prose, blocks = split_code(body)
    stem = os.path.splitext(os.path.basename(page))[0]
    # G1
    heading = next((l[2:].strip() for l in prose if l.startswith("# ")), "")
    if not fm.get("title") and not heading:
        fail("G1", rel, "no title (frontmatter title or a first # heading)")
    # G2
    num = re.match(r"(\d+)-", os.path.basename(page))
    if "order" in fm:
        if not re.fullmatch(r"\d+", fm["order"]):
            fail("G2", rel, f"order {fm['order']!r} is not a whole number")
            order = None
        else:
            order = int(fm["order"])
            if num and int(num.group(1)) != order:
                fail("G2", rel, f"order {order} does not match the filename number {int(num.group(1))}")
    elif num:
        order = int(num.group(1))
    else:
        order = None
        fail("G2", rel, "no order (frontmatter order or a filename number)")
    if order is not None:
        if order in orders:
            fail("G2", rel, f"order {order} is also on {orders[order]}")
        orders[order] = rel
    # G3
    if "slug" in fm:
        fail("G3", rel, "frontmatter slug is not allowed")
    url = re.sub(r"^\d+-", "", stem)
    url = os.path.join(os.path.dirname(page), url)
    if url in urls:
        fail("G3", rel, f"same URL /{url}/ as {urls[url]}")
    urls[url] = rel
    # G4
    flat = "\n".join(CODE_SPAN.sub("``", l) for l in prose)
    for target in LINK.findall(flat):
        if target.startswith("http://"):
            fail("G4", rel, f"link {target} is not https://")
            continue
        if target.startswith(("https://", "mailto:", "#")):
            continue
        p, _, anchor = target.partition("#")
        dest = os.path.normpath(os.path.join(os.path.dirname(path), p))
        if not dest.startswith(os.path.abspath(base) + os.sep):
            fail("G4", rel, f"link {target} leaves the root")
        elif not os.path.isfile(dest):
            fail("G4", rel, f"link {target} does not resolve to a file")
        elif anchor and dest.endswith(".md") and anchor not in slugs(read(dest)):
            fail("G4", rel, f"link {target} names no heading #{anchor}")
    # G5
    for info, lines in blocks:
        if info not in ("bash", "sh"):
            continue
        cont = False
        for line in lines:
            was, cont = cont, line.rstrip().endswith("\\")
            s = line.strip()
            if s.startswith("$ "):
                s = s[2:].strip()
            if was or not s or s.startswith("#"):
                continue
            words = s.split()
            first = words[0]
            if first.startswith("bin/"):
                script = os.path.join(base, first)
                if not (os.path.isfile(script) and os.access(script, os.X_OK)):
                    fail("G5", rel, f"{first} is not an executable script: {s}")
                    continue
                src = read(script)
                for tok in words[1:]:
                    if not tok.startswith("--"):
                        continue
                    flag = tok.split("=")[0]
                    if not re.search(r"(^|[\s|(\[])%s([\])|\s]|$)" % re.escape(flag), src, re.M):
                        fail("G5", rel, f"{first} has no {flag}: {s}")
            elif first not in allow:
                fail("G5", rel, f"{first} is not a bin/ script or an allowed tool: {s}")
    # G6, G7
    for span in CODE_SPAN.findall("\n".join(prose)):
        span = span.strip()
        m = SETTING.match(span)
        if m and not defined(m.group(1)):
            fail("G6", rel, f"setting {m.group(1)} is not defined in env-templates/, catalog/, bin/ or worker/")
        tok = span.split()[0] if span.split() else ""
        if tok.startswith(("bin/", "catalog/", "env-templates/")) and not re.search(r"[<*]", tok):
            if not found(tok.rstrip(".,:;")):
                fail("G7", rel, f"path {tok} does not exist")
    # G8
    for ref in TICKET.findall("\n".join(prose)):
        ref = ref[0] or ref[1]
        if ref.split("-")[0] not in NOT_TICKETS:
            fail("G8", rel, f"internal ticket ref {ref}")
    for m in re.finditer(r"\b(is|now) (public|live)\b", text, re.I):
        fail("G8", rel, f"says '{m.group(0)}'")

# G9
index = os.path.join(base, "docs", "guide.md")
if not os.path.isfile(index):
    fail("G9", "docs/guide.md", "missing")
else:
    t = read(index)
    if "`docs/guide/`" not in t:
        fail("G9", "docs/guide.md", "does not name `docs/guide/` in a code span")
    if "## What Cromford is" in t:
        fail("G9", "docs/guide.md", "still carries ## What Cromford is")
qs = os.path.join(GUIDE, "01-quickstart.md")
if not (os.path.isfile(qs) and "Cromford watches your boards." in read(qs)):
    fail("G9", "docs/guide/01-quickstart.md", "does not carry the What Cromford is text")

for f in fails:
    print(f)
sys.exit(1 if fails else 0)
PY
); RC=$?; }

# guide_root <dest>: a root like the checkout, with docs/guide/ copied so a
# case can edit it and everything else linked.
guide_root() {
  local p
  mkdir -p "$1/docs"
  cp -r "$DIR/docs/guide" "$1/docs/guide"
  for p in "$DIR"/docs/* "$DIR"/docs/.[!.]*; do
    [ -e "$p" ] || continue
    case "${p##*/}" in guide) ;; *) ln -s "$p" "$1/docs/${p##*/}" ;; esac
  done
  for p in "$DIR"/* "$DIR"/.[!.]*; do
    [ -e "$p" ] || continue
    case "${p##*/}" in docs|.git) ;; *) ln -s "$p" "$1/${p##*/}" ;; esac
  done
}

# G0-G9 on the checkout.
check "$DIR"
[ "$RC" = 0 ] && ok || bad "G0-G9 the checkout's guide rc=$RC:
$OUT"
if [ ! -d "$DIR/docs/guide" ]; then
  echo "docs-guide-pages: $PASS passed, $FAIL failed"
  exit 1
fi
# Each arm by name, so a red run says which rule broke.
for g in G1 G2 G3 G4 G5 G6 G7 G8 G9; do
  grep -q "^$g " <<<"$OUT" && bad "$g failed on the checkout" || ok
done

# P1-P4: the mirror bin/publish-share.sh would publish from this tree.
share_mirror_get "$DIR" --or-copy
if [ "${SM_SANITIZE_RC:-x}" != 0 ]; then
  bad "P1 sanitize rc=${SM_SANITIZE_RC:-unset}: $(tail -n 20 <<<"${SM_SANITIZE_OUT:-}")"
else
  M="$SM_MIRROR"
  got=$(cd "$M/docs/guide" 2>/dev/null && ls | LC_ALL=C sort | tr '\n' ' ')
  [ "$got" = "${PAGES[*]} " ] && ok || bad "P1 mirror docs/guide/ holds '$got', want '${PAGES[*]} '"
  for p in "${PAGES[@]}"; do
    d=$(diff "$DIR/docs/guide/$p" "$M/docs/guide/$p" 2>&1) && ok || bad "P2 sanitize changed docs/guide/$p:
$d"
  done
  bash "$M/tests/no-client-identifiers-test.sh" > "$T/guard.txt" 2>&1 && ok \
    || bad "P3 the shipped name guard is red on the mirror: $(tail -n 20 "$T/guard.txt")"
  python3 "$DIR/bin/share/leakcheck.py" --quiet "$M/docs/guide" > "$T/leak.txt" 2>&1 && ok \
    || bad "P3 leakcheck is red on the mirror's docs/guide: $(cat "$T/leak.txt")"
  check "$M"
  [ "$RC" = 0 ] && ok || bad "P3 the checker is red on the mirror rc=$RC:
$OUT"
  missing=$(python3 - "$DIR" "$M" "${PAGES[@]}" <<'PY'
import os, re, sys
src, mirror, pages = sys.argv[1], sys.argv[2], sys.argv[3:]
LINK = re.compile(r"(?<!!)\[[^\]]*\]\(([^)\s#]+)(?:#[^)\s]*)?\)")
for p in pages:
    text = re.sub(r"```.*?```", "", open(os.path.join(src, "docs/guide", p)).read(), flags=re.S)
    text = re.sub(r"`[^`]+`", "``", text)
    for t in LINK.findall(text):
        if t.startswith(("https://", "mailto:")) or "/" not in t:
            continue
        rel = os.path.normpath(os.path.join("docs/guide", t))
        if not os.path.isfile(os.path.join(mirror, rel)):
            print(f"{p}: {t} ({rel})")
PY
)
  [ -z "$missing" ] && ok || bad "P4 link targets the mirror does not ship:
$missing"
fi

# N1-N5: the checker goes red on each broken page, with the reason.
neg() { # neg <name> <reason substring> <python edit of docs/guide in $1>
  local r="$T/$1"
  scratch_rm "$r" || { bad "$1 scratch_rm refused $r"; return; }
  guide_root "$r"
  python3 - "$r/docs/guide" <<<"$3" || { bad "$1 fixture edit failed"; return; }
  check "$r"
  [ "$RC" = 1 ] && [[ "$OUT" == *"$2"* ]] && ok || bad "$1 want rc 1 with '$2', got rc=$RC:
$OUT"
}
neg N1 "G1 docs/guide/02-onboarding.md: no title" '
import re, sys
p = sys.argv[1] + "/02-onboarding.md"
t = open(p).read()
t = re.sub(r"^title:.*\n", "", t, flags=re.M)
t = re.sub(r"^# .*\n", "", t, flags=re.M)
open(p, "w").write(t)'
neg N2 "G2 docs/guide/03-connectors.md: order 2 does not match" '
import re, sys
p = sys.argv[1] + "/03-connectors.md"
t = re.sub(r"^order:.*$", "order: 2", open(p).read(), count=1, flags=re.M)
open(p, "w").write(t)'
neg N2b "is also on" '
import os, re, sys
d = sys.argv[1]
t = re.sub(r"^order:.*\n", "", open(d + "/03-connectors.md").read(), count=1, flags=re.M)
os.remove(d + "/03-connectors.md")
open(d + "/02-connectors.md", "w").write(t)'
neg N3 "G4 docs/guide/01-quickstart.md: link nope.md does not resolve" '
import sys
p = sys.argv[1] + "/01-quickstart.md"
open(p, "a").write("\nSee [this](nope.md).\n")'
neg N4 "G5 docs/guide/01-quickstart.md: bin/no-such.sh is not an executable script" '
import sys
p = sys.argv[1] + "/01-quickstart.md"
open(p, "a").write("\n```bash\nbin/no-such.sh --x\n```\n")'
neg N5 "G5 docs/guide/02-onboarding.md: bin/load-project.sh has no --no-such-flag" '
import sys
p = sys.argv[1] + "/02-onboarding.md"
open(p, "a").write("\n```bash\n$ bin/load-project.sh <owner/repo> --no-such-flag\n```\n")'
# BH-7919: LINEAR_API_KEY is defined in bin/lib/tracker/linear.sh now, so the
# undefined setting is a name no tree defines.
neg N6 "G6 docs/guide/03-connectors.md: setting GUIDE_NOSUCH_SETTING" '
import sys
p = sys.argv[1] + "/03-connectors.md"
open(p, "a").write("\nSet `GUIDE_NOSUCH_SETTING`.\n")'
neg N7 "G5 docs/guide/04-archie.md: rm is not a bin/ script" '
import sys
p = sys.argv[1] + "/04-archie.md"
open(p, "a").write("\n```sh\nrm -rf state\n```\n")'

echo "docs-guide-pages: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
