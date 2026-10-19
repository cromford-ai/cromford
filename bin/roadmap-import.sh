#!/bin/bash
# bin/roadmap-import.sh — BH-7243.1 (BH-7264): import a roadmap HTML file into
# the per-project roadmap (roadmap_ideas, roadmap_links, roadmap_decisions)
# through POST /api/roadmap/import on the jobs worker. An operator tool, run by
# hand: it is not a lane, and it has no cron and no catalog row.
#
# Usage:
#   bin/roadmap-import.sh --project <project> --file <roadmap.html> [--dry-run]
#
#   --project   a row of the jobs `projects` table (^[A-Za-z0-9._-]{1,64}$)
#   --file      the roadmap HTML (the example-org/project-6 docs/ROADMAP.html shape)
#   --dry-run   parse and print the counts; send no request
#
# What it reads. Sections are the <h2> headings: the id, or else the first
# word of the heading text (lower case, no trailing colon). now, next, later
# and shipped hold ideas; decisions and open hold decisions. Any other section
# is skipped and named. Rows are the <tr> rows with <td> cells; columns are
# found by the header names of the first <thead> row of each table.
#   idea      title = Item or Title; note = Notes; link = the first GitHub
#             issue or pull URL in the row. A title over 200 characters is cut
#             to 197 + "..." and the full text leads the note.
#             source_ref = the link, else "sha256:" + sha256(section \n title).
#   decision  Date/Decision/Source: kind log, status decided, title = Decision,
#             body = "Source: " + Source, decided_at = Date.
#             Topic/Question/Where: kind open, status open, title = Topic,
#             body = Question + " Where: " + Where.
#             ref = sha256 of the cells joined by \n.
# The worker maps the lanes: later -> ideas; now, next, shipped -> next.
#
# Output: one line per section (`roadmap-import: <section> ideas=<n>` or
# `decisions=<n>`, `roadmap-import: skipped section <id>`), then on a real run
# `roadmap-import: inserted ideas=<n> links=<n> decisions=<n> skipped ideas=<n>
# decisions=<n>`, summed from the worker's answers. A re-run inserts 0.
#
# Env: ROADMAP_IMPORT_ACTOR (default operator:<unix user>) stamps created_by.
#      JOBS_URL and HARNESS_SECRET as bin/jobs-client.sh reads them.
#
# Exit: 0 done (or dry run); 1 the worker refused, did not answer, or JOBS_URL
# is not set (calls before the failure stay written, and a re-run inserts only
# the rest); 2 usage error or a missing file (no request).
set -uo pipefail

usage() { sed -n '7,12p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

PROJECT=""; FILE=""; DRY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --project) [ $# -ge 2 ] || usage; PROJECT="$2"; shift 2 ;;
    --file) [ $# -ge 2 ] || usage; FILE="$2"; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    -h|--help) usage ;;
    *) echo "roadmap-import: unknown argument: $1" >&2; usage ;;
  esac
done
[ -n "$PROJECT" ] && [ -n "$FILE" ] || usage
[[ $PROJECT =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo "roadmap-import: --project must match ^[A-Za-z0-9._-]{1,64}\$" >&2; exit 2; }
[ -f "$FILE" ] && [ -r "$FILE" ] || { echo "roadmap-import: file not found: $FILE" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "roadmap-import: python3 is required" >&2; exit 1; }

ACTOR="${ROADMAP_IMPORT_ACTOR:-operator:$(id -un)}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/roadmap-import.XXXXXX") || { echo "roadmap-import: mktemp failed" >&2; exit 1; }
trap 'rm -rf "$WORK"' EXIT

# Parse the HTML into call bodies of at most 500 rows: $WORK/call-NNN.json.
# Prints the per-section lines.
python3 -I - "$FILE" "$PROJECT" "$ACTOR" "$WORK" <<'PY' || { echo "roadmap-import: could not parse $FILE" >&2; exit 1; }
import hashlib, json, os, re, sys
from html.parser import HTMLParser

path, project, actor, work = sys.argv[1:5]
IDEA_SECTIONS = ("now", "next", "later", "shipped")
DECISION_SECTIONS = ("decisions", "open")
GH = re.compile(r"^https://github\.com/[^/\s]+/[^/\s]+/(issues|pull)/\d+")
CALL_MAX = 500
TITLE_MAX = 200
TEXT_MAX = 4000


def sha(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def clean(s):
    return " ".join(s.split())


def cut(s, n):
    return s if len(s) <= n else s[: n - 3] + "..."


class Roadmap(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.section = None      # the current section name, or None
        self.h2 = None           # [id, text] while inside an <h2>
        self.headers = None      # header names of the current table
        self.in_th = None
        self.head_done = False
        self.cells = None        # cells of the current <tr>
        self.cell = None
        self.hrefs = None
        self.rows = []           # (section, headers, cells, hrefs)
        self.order = []          # section names in the order seen

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "h2":
            self.h2 = [(a.get("id") or "").strip(), ""]
        elif tag == "table":
            self.headers, self.head_done = [], False
        elif tag == "tr":
            self.cells, self.hrefs = [], []
        elif tag == "th" and self.headers is not None and not self.head_done:
            self.in_th = ""
        elif tag == "td" and self.cells is not None:
            self.cell = ""
        elif tag == "a" and self.hrefs is not None and a.get("href"):
            self.hrefs.append(a["href"].strip())

    def handle_endtag(self, tag):
        if tag == "h2" and self.h2 is not None:
            hid, text = self.h2
            self.h2 = None
            if hid:
                name = hid.lower()
            else:
                words = clean(text).split(" ")
                name = words[0].lower().rstrip(":") if words and words[0] else ""
            self.section = name or None
            if self.section and self.section not in self.order:
                self.order.append(self.section)
        elif tag == "th" and self.in_th is not None:
            self.headers.append(clean(self.in_th).lower())
            self.in_th = None
        elif tag == "thead" and self.headers is not None:
            self.head_done = True
        elif tag == "td" and self.cell is not None:
            self.cells.append(clean(self.cell))
            self.cell = None
        elif tag == "tr" and self.cells is not None:
            if self.cells and self.section:
                self.rows.append((self.section, list(self.headers or []), self.cells, self.hrefs))
            self.cells, self.hrefs = None, None
        elif tag == "table":
            self.headers = None

    def handle_data(self, data):
        if self.h2 is not None:
            self.h2[1] += data
        if self.in_th is not None:
            self.in_th += data
        if self.cell is not None:
            self.cell += data


p = Roadmap()
with open(path, encoding="utf-8", errors="replace") as f:
    p.feed(f.read())
p.close()

ideas, decisions, counts = [], [], {}


def col(headers, cells, *names):
    for n in names:
        if n in headers:
            i = headers.index(n)
            if i < len(cells):
                return cells[i]
    return ""


for section, headers, cells, hrefs in p.rows:
    if section in IDEA_SECTIONS:
        full = col(headers, cells, "item", "title")
        if not full:
            continue
        note = col(headers, cells, "notes")
        title = cut(full, TITLE_MAX)
        if title != full:
            note = full + ("\n\n" + note if note else "")
        link = next((h for h in hrefs if GH.match(h)), None)
        row = {"section": section, "title": title,
               "source_ref": link or "sha256:" + sha(section + "\n" + full)}
        if note:
            row["note"] = cut(note, TEXT_MAX)
        if link:
            row["link"] = link
        ideas.append(row)
        counts[section] = counts.get(section, 0) + 1
    elif section in DECISION_SECTIONS:
        ref = sha("\n".join(cells))
        if "decision" in headers:
            full = col(headers, cells, "decision")
            if not full:
                continue
            body = "Source: " + col(headers, cells, "source")
            title = cut(full, TITLE_MAX)
            if title != full:
                body = full + "\n\n" + body
            row = {"kind": "log", "title": title, "body": cut(body, TEXT_MAX), "status": "decided", "ref": ref}
            date = col(headers, cells, "date")
            if re.match(r"^\d{4}-\d{2}-\d{2}", date):
                row["decided_at"] = date[:40]
        elif "topic" in headers:
            full = col(headers, cells, "topic")
            if not full:
                continue
            body = col(headers, cells, "question") + " Where: " + col(headers, cells, "where")
            title = cut(full, TITLE_MAX)
            if title != full:
                body = full + "\n\n" + body
            row = {"kind": "open", "title": title, "body": cut(body, TEXT_MAX), "status": "open", "ref": ref}
        else:
            continue
        decisions.append(row)
        counts[section] = counts.get(section, 0) + 1

for s in p.order:
    if s in IDEA_SECTIONS:
        print("roadmap-import: %s ideas=%d" % (s, counts.get(s, 0)))
    elif s in DECISION_SECTIONS:
        print("roadmap-import: %s decisions=%d" % (s, counts.get(s, 0)))
    else:
        print("roadmap-import: skipped section %s" % s)

rows = [("ideas", r) for r in ideas] + [("decisions", r) for r in decisions]
for k in range(0, len(rows), CALL_MAX):
    part = rows[k:k + CALL_MAX]
    body = {"project": project, "actor": actor,
            "ideas": [r for t, r in part if t == "ideas"],
            "decisions": [r for t, r in part if t == "decisions"]}
    with open(os.path.join(work, "call-%03d.json" % (k // CALL_MAX)), "w", encoding="utf-8") as f:
        json.dump(body, f, ensure_ascii=False)
PY

shopt -s nullglob
CALLS=("$WORK"/call-*.json)
if [ "$DRY" = 1 ]; then
  echo "roadmap-import: dry run, nothing written"
  exit 0
fi
if [ "${#CALLS[@]}" -eq 0 ]; then
  echo "roadmap-import: no rows found in $FILE, nothing to send"
  exit 0
fi

# shellcheck source=bin/jobs-client.sh
. "$(dirname "$0")/jobs-client.sh" || { echo "roadmap-import: cannot load bin/jobs-client.sh" >&2; exit 1; }
# This tool prints the worker's error itself and exits 1: no ALERTS line.
JOBS_ALERT="${JOBS_ALERT:-0}"
jobs_configured || { echo "roadmap-import: JOBS_URL is not set" >&2; exit 1; }

# The sums over the calls: ideas links decisions skipped_ideas skipped_decisions.
TOTAL="0 0 0 0 0"
add_counts() { # add_counts <answer-file> -> prints the new TOTAL, rc 1 on a bad answer
  python3 -I - "$1" "$TOTAL" <<'PY'
import json, sys
a = json.load(open(sys.argv[1], encoding="utf-8"))
t = [int(x) for x in sys.argv[2].split()]
i, s = a["inserted"], a["skipped"]
add = [i["ideas"], i["links"], i["decisions"], s["ideas"], s["decisions"]]
print(" ".join(str(x + int(y)) for x, y in zip(t, add)))
PY
}
summary() {
  local a b c d e
  read -r a b c d e <<<"$TOTAL"
  echo "roadmap-import: inserted ideas=$a links=$b decisions=$c skipped ideas=$d decisions=$e"
}

n=0
for f in "${CALLS[@]}"; do
  n=$((n+1))
  _jobs_req POST /api/roadmap/import "$(cat "$f")" > "$WORK/answer.json"
  rc=$?
  if [ "$rc" -ne 0 ] || [ "${JOBS_HTTP:0:1}" != 2 ]; then
    if [ -n "$JOBS_HTTP" ]; then
      err=$(printf '%s' "$JOBS_BODY" | python3 -I -c 'import json,sys
s=sys.stdin.read()
try: print(json.loads(s).get("error") or s[:300])
except Exception: print(s[:300])')
      echo "roadmap-import: call $n of ${#CALLS[@]} refused (http $JOBS_HTTP): $err" >&2
    else
      echo "roadmap-import: call $n of ${#CALLS[@]}: no answer from the jobs worker at $JOBS_URL" >&2
    fi
    [ "$n" -gt 1 ] && echo "roadmap-import: before the failure, $(summary | sed 's/^roadmap-import: //')" >&2
    exit 1
  fi
  TOTAL=$(add_counts "$WORK/answer.json") || { echo "roadmap-import: call $n of ${#CALLS[@]}: unreadable answer: $(head -c 300 "$WORK/answer.json")" >&2; exit 1; }
done
summary
