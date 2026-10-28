#!/bin/bash
# tests/docs-connectors.bh-7924-test.sh — the Linear and Jira setup steps in
# the connector docs. Two pages carry them: docs/guide/03-connectors.md (the
# user guide) and docs/connecting-a-board.md (the full detail).
#
# One checker (the python below) takes a root and prints one reason line per
# failure:
#
#   D1  no page under docs/guide/ and not docs/connecting-a-board.md says
#       "cannot drive builds" or "can't drive builds"; no Jira or Linear
#       section of the two pages has a "**Not yet:**" paragraph
#   D2  each of the two pages has a "Set up Linear" and a "Set up Jira"
#       heading, and each section holds one numbered list of 5 or more steps,
#       numbered 1..n
#   D3  the Linear steps name `LINEAR_API_KEY`, the Jira steps name
#       `JIRA_API_TOKEN`, and both name `bin/connection-probe.sh`
#   D4  docs/quickstart.md links both setup sections of
#       docs/connecting-a-board.md and the guide page, and each anchor names a
#       heading that exists
#   D5  neither page names `/connections` or PROBE NOW: the console screen is
#       not shipped yet (BH-7924 C1 adds it and flips this case)
#   D6  while bin/lib/rb/pr.sh has no `tracker_kind` route (the build stage
#       resolves only GitHub issues), the "## Jira Cloud" and "## Linear"
#       sections of each page say "Today Cromford reads, triages and wakes"
#       and that a build does not post its PR link back yet
#
# The suite runs the checker on the checkout, then on fixture copies that put
# one fault back each (N1-N4), so a checker that cannot go red is red here.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/docs-connectors.bh-7924-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# check <root>: OUT gets the reason lines, RC the checker's exit code.
check() { OUT=$(python3 - "$1" 2>&1 <<'PY'
import os, re, sys

base = sys.argv[1]
PAGES = ["docs/guide/03-connectors.md", "docs/connecting-a-board.md"]
fails = []


def read(rel):
    with open(os.path.join(base, rel), encoding="utf-8") as f:
        return f.read()


def prose_lines(text):
    """The lines outside fenced code, with their heading level (0 = not a heading)."""
    out, fence = [], False
    for line in text.splitlines():
        if line.lstrip().startswith("```"):
            fence = not fence
            out.append((0, line, True))
            continue
        m = re.match(r"(#{1,6})\s+", line) if not fence else None
        out.append((len(m.group(1)) if m else 0, line, fence))
    return out


def section(text, title):
    """The lines under the first heading whose text is `title`, up to the next
    heading of the same or a higher level. None when there is no such heading."""
    lines = prose_lines(text)
    for i, (lvl, line, _) in enumerate(lines):
        if lvl and re.sub(r"^#+\s+", "", line).strip() == title:
            body = []
            for lvl2, l2, f2 in lines[i + 1:]:
                if lvl2 and lvl2 <= lvl:
                    break
                body.append((l2, f2))
            return body
    return None


def slugs(text):
    out = set()
    for lvl, line, _ in prose_lines(text):
        if lvl:
            h = re.sub(r"^#+\s+", "", line).strip().replace("`", "")
            out.add(re.sub(r"[^\w\- ]", "", h.lower()).replace(" ", "-"))
    return out


# D1
guide = os.path.join(base, "docs", "guide")
d1_pages = sorted("docs/guide/" + f for f in os.listdir(guide) if f.endswith(".md")) \
    if os.path.isdir(guide) else []
for rel in d1_pages + ["docs/connecting-a-board.md"]:
    t = read(rel)
    for phrase in ("cannot drive builds", "can't drive builds"):
        if phrase in t.lower():
            fails.append(f"D1 {rel}: says '{phrase}'")
for rel in PAGES:
    cur = ""
    for lvl, line, fence in prose_lines(read(rel)):
        if lvl:
            cur = line
        elif not fence and line.lstrip().startswith("**Not yet") and re.search(r"Jira|Linear", cur):
            fails.append(f"D1 {rel}: a 'Not yet' paragraph under '{cur.strip()}'")

# D2, D3
NEED = {
    "Set up Linear": ["`LINEAR_API_KEY`", "bin/connection-probe.sh"],
    "Set up Jira": ["`JIRA_API_TOKEN`", "bin/connection-probe.sh"],
}
for rel in PAGES:
    t = read(rel)
    for title, names in NEED.items():
        body = section(t, title)
        if body is None:
            fails.append(f"D2 {rel}: no '{title}' heading")
            continue
        nums = [int(m.group(1)) for l, f in body if not f
                for m in [re.match(r"(\d+)\.\s+\S", l)] if m]
        if len(nums) < 5:
            fails.append(f"D2 {rel}: '{title}' has {len(nums)} numbered steps, want 5 or more")
        elif nums != list(range(1, len(nums) + 1)):
            fails.append(f"D2 {rel}: '{title}' steps are numbered {nums}, want 1..{len(nums)}")
        text = "\n".join(l for l, _ in body)
        for n in names:
            if n not in text:
                fails.append(f"D3 {rel}: '{title}' does not name {n.strip('`')}")

# D4
q = read("docs/quickstart.md")
links = re.findall(r"(?<!!)\[[^\]]*\]\(([^)\s]+)\)", q)
for want in ("connecting-a-board.md#set-up-linear", "connecting-a-board.md#set-up-jira",
             "guide/03-connectors.md#set-up-linear", "guide/03-connectors.md#set-up-jira"):
    if want not in links:
        fails.append(f"D4 docs/quickstart.md: no link to {want}")
        continue
    page, _, anchor = want.partition("#")
    dest = os.path.join("docs", page)
    if not os.path.isfile(os.path.join(base, dest)) or anchor not in slugs(read(dest)):
        fails.append(f"D4 docs/quickstart.md: link {want} names no heading in {dest}")

# D5
for rel in PAGES:
    t = read(rel)
    for word in ("/connections", "PROBE NOW"):
        if word in t:
            fails.append(f"D5 {rel}: names {word}, a screen this release does not ship")

# D6
pr_sh = os.path.join(base, "bin/lib/rb/pr.sh")
routed = os.path.isfile(pr_sh) and "tracker_kind" in open(pr_sh, encoding="utf-8").read()
if not routed:
    for rel in PAGES:
        t = read(rel)
        for title, name in (("Jira Cloud", "Jira"), ("Linear", "Linear")):
            body = section(t, title)
            text = " ".join(" ".join(l for l, f in (body or []) if not f).split())
            if f"Today Cromford reads, triages and wakes on {name} issues." not in text:
                fails.append(f"D6 {rel}: '## {title}' does not say what runs today")
            elif f"PR link or close-out comment back to the {name} issue yet" not in text:
                fails.append(f"D6 {rel}: '## {title}' does not say the PR link is not posted back")

for f in fails:
    print(f)
sys.exit(1 if fails else 0)
PY
); RC=$?; }

# fixture <dest>: a copy of the docs files and the pr.sh the checker reads.
fixture() {
  mkdir -p "$1/docs/guide" "$1/bin/lib/rb" || return 1
  cp "$DIR"/docs/guide/*.md "$1/docs/guide/" && \
  cp "$DIR/docs/connecting-a-board.md" "$DIR/docs/quickstart.md" "$1/docs/" && \
  # scratch-closure-allow: fixture data for D6; the checker greps pr.sh for tracker_kind, never sources or runs it
  cp "$DIR/bin/lib/rb/pr.sh" "$1/bin/lib/rb/"
}

# D1-D6 on the checkout.
check "$DIR"
[ "$RC" = 0 ] && ok || bad "D1-D6 the checkout rc=$RC:
$OUT"
for d in D1 D2 D3 D4 D5 D6; do
  grep -q "^$d " <<<"$OUT" && bad "$d failed on the checkout" || ok
done

# N1-N4: the checker goes red on each fault, with the reason.
neg() { # neg <name> <reason substring> <python edit of the docs/ dir in $1>
  local r="$T/$1"
  scratch_rm "$r" || { bad "$1 scratch_rm refused $r"; return; }
  fixture "$r" || { bad "$1 fixture copy failed"; return; }
  python3 - "$r/docs" <<<"$3" || { bad "$1 fixture edit failed"; return; }
  check "$r"
  [ "$RC" = 1 ] && [[ "$OUT" == *"$2"* ]] && ok || bad "$1 want rc 1 with '$2', got rc=$RC:
$OUT"
}
neg N1 "D1 docs/connecting-a-board.md: a 'Not yet' paragraph under '## Linear'" '
import sys
p = sys.argv[1] + "/connecting-a-board.md"
t = open(p).read()
t = t.replace("\n## Linear\n", "\n## Linear\n\n**Not yet:** the adapter is built, but a Linear board cannot drive builds today.\n", 1)
open(p, "w").write(t)'
neg N1b "D1 docs/guide/01-quickstart.md: says 'can't drive builds'" '
import sys
p = sys.argv[1] + "/guide/01-quickstart.md"
open(p, "a").write("\nA Jira board can'"'"'t drive builds.\n")'
neg N2 "D2 docs/guide/03-connectors.md: 'Set up Jira' has 4 numbered steps" '
import re, sys
p = sys.argv[1] + "/guide/03-connectors.md"
t = open(p).read()
i = t.index("Set up Jira")
j = t.find("\n#", i)
j = len(t) if j < 0 else j
body = re.sub(r"(?m)^([5-9]|[1-9][0-9])\.(\s)", r"-\2", t[i:j])
open(p, "w").write(t[:i] + body + t[j:])'
neg N3 "D3 docs/connecting-a-board.md: 'Set up Linear' does not name LINEAR_API_KEY" '
import sys
p = sys.argv[1] + "/connecting-a-board.md"
t = open(p).read()
i = t.index("Set up Linear")
j = t.index("\n#", i)
t = t[:i] + t[i:j].replace("`LINEAR_API_KEY`", "the key") + t[j:]
open(p, "w").write(t)'
neg N4 "D4 docs/quickstart.md: no link to connecting-a-board.md#set-up-jira" '
import sys
p = sys.argv[1] + "/quickstart.md"
t = open(p).read().replace("connecting-a-board.md#set-up-jira", "connecting-a-board.md")
open(p, "w").write(t)'
neg N4b "D4 docs/quickstart.md: link guide/03-connectors.md#set-up-linear names no heading" '
import sys
p = sys.argv[1] + "/guide/03-connectors.md"
t = open(p).read().replace("Set up Linear", "Linear setup")
open(p, "w").write(t)'

neg N5 "D5 docs/guide/03-connectors.md: names /connections" '
import sys
p = sys.argv[1] + "/guide/03-connectors.md"
open(p, "a").write("\nOpen `/connections` in the console.\n")'
neg N5b "D5 docs/connecting-a-board.md: names PROBE NOW" '
import sys
p = sys.argv[1] + "/connecting-a-board.md"
open(p, "a").write("\nPress PROBE NOW.\n")'
neg N6 "D6 docs/connecting-a-board.md: '## Linear' does not say what runs today" '
import sys
p = sys.argv[1] + "/connecting-a-board.md"
t = open(p).read().replace("Today Cromford reads, triages and wakes on Linear issues.", "Linear works.")
open(p, "w").write(t)'
# N6b: once pr.sh routes on tracker_kind, D6 does not ask for the sentence.
r="$T/N6b"
if scratch_rm "$r" && fixture "$r"; then
  python3 - "$r/docs" <<'PY'
import sys
p = sys.argv[1] + "/connecting-a-board.md"
t = open(p).read().replace("Today Cromford reads, triages and wakes on Linear issues.", "Linear works.")
open(p, "w").write(t)
PY
  echo '_pr_route() { tracker_kind "$1"; }' >>"$r/bin/lib/rb/pr.sh"
  check "$r"
  [ "$RC" = 0 ] && ok || bad "N6b want rc 0 when pr.sh routes on tracker_kind, got rc=$RC:
$OUT"
else
  bad "N6b fixture failed"
fi

echo "docs-connectors: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
