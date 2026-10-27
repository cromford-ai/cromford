# shellcheck shell=bash
# bin/lib/roadmap-html.sh — render a roadmap board as docs/ROADMAP.html.
# Sourced, never executed. No side effect at source time.
#
#   roadmap_html <board.json> <project> <generated_at>
#
# <board.json> is one answer of GET /api/roadmap/board (worker/jobs/src/routes/
# roadmap-board.js). The page is written to stdout. It is deterministic: the
# same board, project and generated_at give the same bytes, and nothing in it
# reads the clock. rc 1 (and nothing on stdout) when the board is not a board
# answer or generated_at is not an ISO time.
#
# THE SHAPE (the example-org/project-6 docs/ROADMAP.html shape, which
# bin/roadmap-import.sh reads back):
#   line 1  <!DOCTYPE html>
#   line 2  <!-- generated-at: <generated_at> -->   the ONLY line that changes
#           when the board does not; bin/roadmap-render.sh drops it before it
#           compares a render with the file on the default branch.
#   sections, each an <h2 id=...>: now, next, later (the Ideas column),
#   shipped, decisions, open. Cards keep the route's order (newest change
#   first).
#   lane tables: <table class="sortable"> Issue | Item | Status | Label | Size |
#   Notes. Issue = each linked #n, a link to its issue; Status = the column
#   and each link's state; Label = the idea's source; Size is empty (ideas
#   store no size); Notes = the note.
#   decisions: Date | Decision | Source (who decided). open: Topic | Question |
#   Where (empty: not stored).
# Every text value is HTML-escaped (& < > " '). A URL is written as an href
# only when it starts with https://github.com/; any other URL is plain text.

roadmap_html() {
  local board="${1-}" project="${2-}" gen="${3-}"
  [ -n "$board" ] && [ -r "$board" ] || return 1
  [[ "$gen" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  jq -e '(.columns | type) == "object" and ([.columns.ideas, .columns.next, .columns.now, .columns.shipped] | all(type == "array"))' \
    "$board" >/dev/null 2>&1 || return 1
  jq -r --arg project "$project" --arg gen "$gen" '
    def esc: tostring | gsub("&"; "&amp;") | gsub("<"; "&lt;") | gsub(">"; "&gt;") | gsub("\""; "&quot;") | gsub("'"'"'"; "&#39;");
    def link($u; $t): if ($u | type) == "string" and ($u | startswith("https://github.com/"))
      then "<a href=\"\($u | esc)\">\($t | esc)</a>" else ($t | esc) end;
    def state: if . == null then "not read yet" elif . == "open" then "open"
      elif . == "closed_completed" then "closed: done" elif . == "closed_other" then "closed" else tostring end;
    def td: "<td>\(.)</td>";
    def table($heads; $rows):
      if ($rows | length) == 0 then "<p>Nothing here.</p>"
      else "<table class=\"sortable\">\n<thead><tr>" + ($heads | map("<th>\(.)</th>") | join("")) + "</tr></thead>\n<tbody>\n"
        + ($rows | join("\n")) + "\n</tbody>\n</table>" end;
    def card($status): (.links // []) as $ls
      | "<tr>" + ([$ls[] | link(.url; "#\(.issue)")] | join(" ") | td)
      + (.title | esc | td)
      + (($status + (if ($ls | length) > 0 then " (" + ([$ls[] | "#\(.issue) \(.issue_state | state)"] | join(", ")) + ")" else "" end)) | esc | td)
      + ((.source // "") | esc | td) + ("" | td) + ((.note // "") | esc | td) + "</tr>";
    def lane($id; $title; $cards):
      "<section>\n<h2 id=\"\($id)\">\($title)</h2>\n"
      + table(["Issue", "Item", "Status", "Label", "Size", "Notes"]; [$cards[] | card($title)]) + "\n</section>";
    def section($id; $title; $body): "<section>\n<h2 id=\"\($id)\">\($title)</h2>\n\($body)\n</section>";
    "<!DOCTYPE html>",
    "<!-- generated-at: \($gen) -->",
    "<html lang=\"en\">",
    "<head>",
    "<meta charset=\"utf-8\">",
    "<title>Roadmap: \($project | esc)</title>",
    "<style>table.sortable{border-collapse:collapse;width:100%}table.sortable th,table.sortable td{border:1px solid #ccc;padding:4px 8px;text-align:left;vertical-align:top}</style>",
    "</head>",
    "<body>",
    "<h1>Roadmap: \($project | esc)</h1>",
    "<p>bin/roadmap-render.sh writes this file from the roadmap board. Do not edit it by hand: the next render replaces it.</p>",
    lane("now"; "Now"; .columns.now),
    lane("next"; "Next"; .columns.next),
    lane("later"; "Later"; .columns.ideas),
    lane("shipped"; "Shipped"; .columns.shipped),
    section("decisions"; "Decisions"; table(["Date", "Decision", "Source"];
      [(.decisions // [])[] | "<tr>" + ((.decided_at // .created_at // "") | .[0:10] | esc | td) + (.title | esc | td)
        + ((.decided_by // .created_by // "") | esc | td) + "</tr>"])),
    section("open"; "Open decisions"; table(["Topic", "Question", "Where"];
      [(.open_decisions // [])[] | "<tr>" + (.title | esc | td) + ((.body // "") | esc | td) + ("" | td) + "</tr>"])),
    "</body>",
    "</html>"
  ' "$board"
}
