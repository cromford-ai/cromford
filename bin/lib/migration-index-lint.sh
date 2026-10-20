#!/bin/bash
# bin/lib/migration-index-lint.sh — the deterministic migration index lint
# (BH-7667). Sourced by bin/lead-review.sh and bin/review-prs.sh.
#
# WHY. A plain `CREATE INDEX` on Postgres takes a lock that blocks every write
# to the table for the whole index build. On project-6's `event` table (about
# 12 GB in prod) that is minutes of failed writes. On 2026-10-20 the lead
# review approved project-6 #2016 (0338_salesforce_connector.sql:61, a plain
# CREATE INDEX on event) as MERGE-WITH-NOTES; #1920 and #1910 carried the same
# defect and a person caught them. The rule needs no model judgment, so no
# model decides it: this lint reads the PR's unified diff and flags it.
#
# THE RULE. In an added or changed statement of a `*.sql` file, a
# `CREATE [UNIQUE] INDEX` with no `CONCURRENTLY` directly after `INDEX`, on a
# table in the project's large-table list, is one finding line:
#   - [BLOCK destructive-migration] <path>:<line>: CREATE INDEX on large table …
# The class is the existing ALWAYS-BLOCK class `destructive-migration`
# (catalog/review-always-block.tsv), so rl_cap keeps the line standing.
#
# THE LIST is the settings row `review.large_tables.<project>` (then
# `review.large_tables`), read through rl_knob (bin/lib/review-level.sh):
# names separated by commas or spaces, compared in lowercase with quotes and a
# schema prefix removed. No row = an empty list = no lint and no diff read.
# REVIEW_LEVEL_LARGE_TABLES in the env wins (rl_knob's test seam). A settings
# outage is rl_knob's fail-open: the default (empty) for that tick.
#
# Bash 3.2 safe, no network, no side effect on source.
# shellcheck shell=bash

# mil_tables <project> — the large-table list, lowercase, space-separated.
# Empty when rl_knob is not loaded or no row names a table.
mil_tables() {
  local v
  command -v rl_knob >/dev/null 2>&1 || return 0
  v=$(rl_knob review.large_tables "${1:-}" "" '^[A-Za-z0-9_.,[:space:]-]*$') || v=""
  printf '%s' "$v" | tr ',[:upper:]' ' [:lower:]' | tr -s '[:space:]' ' ' | sed -E 's/^ +//; s/ +$//'
}

# mil_scan <diff-file> <tables> [project] — print one finding line per plain
# CREATE INDEX on a listed table. rc 0 no finding, 1 findings, 2 an unreadable
# file or bad args. An empty <tables> is rc 0 and reads nothing.
mil_scan() {
  local f="${1:-}" tables="${2:-}" p="${3:-}"
  tables=$(printf '%s' "$tables" | tr ',[:upper:]' ' [:lower:]' | tr -s '[:space:]' ' ' | sed -E 's/^ +//; s/ +$//')
  [ -n "$tables" ] || return 0
  [ -n "$f" ] && [ -f "$f" ] && [ -r "$f" ] || return 2
  LC_ALL=C awk -v tables="$tables" -v proj="$p" '
    function reset_stmt() { buf = ""; sline = 0; plus = 0 }
    # judge: the statement in buf, started at sline, has an added line.
    function judge(   u, rest, pos, tok, t, n, parts) {
      if (!plus || buf == "") return
      u = toupper(buf)
      gsub(/[[:space:]]+/, " ", u); sub(/^ /, "", u)
      t = buf; gsub(/[[:space:]]+/, " ", t); sub(/^ /, "", t)
      if (!match(u, /^CREATE (UNIQUE )?INDEX( |$)/)) return
      rest = substr(u, RLENGTH + 1)
      if (rest ~ /^CONCURRENTLY( |$)/) return
      if (!match(u, /(^|[ "])ON (ONLY )?/)) return
      pos = RSTART + RLENGTH
      tok = substr(t, pos)
      sub(/[ (;].*$/, "", tok)
      gsub(/"/, "", tok)
      n = split(tok, parts, ".")
      tok = tolower(parts[n])
      if (tok == "" || !(tok in big)) return
      printf "- [BLOCK destructive-migration] %s:%d: CREATE INDEX on large table %s without CONCURRENTLY blocks writes to %s for the whole index build (BH-7667 migration lint; large tables%s: %s). Build it with CREATE INDEX CONCURRENTLY outside a transaction.\n", path, sline, tok, tok, (proj != "" ? " of " proj : ""), tables
      found++
    }
    function flush() { judge(); reset_stmt(); incomment = 0 }
    # feed: one post-image line (text, its new-file line number, added or not).
    function feed(text, ln, added,   out, i, j, k, seg) {
      out = ""
      while (text != "") {
        if (incomment) {
          i = index(text, "*/")
          if (i == 0) { text = ""; break }
          text = substr(text, i + 2); incomment = 0; out = out " "; continue
        }
        i = index(text, "--"); j = index(text, "/*")
        if (i && (!j || i < j)) { out = out substr(text, 1, i - 1); text = ""; break }
        if (j) { out = out substr(text, 1, j - 1); text = substr(text, j + 2); incomment = 1; continue }
        out = out text; text = ""
      }
      # Split on ";": each piece joins the open statement; a ";" ends it.
      while (1) {
        k = index(out, ";")
        seg = (k ? substr(out, 1, k - 1) : out)
        if (seg ~ /[^[:space:]]/) {
          if (buf == "" || buf ~ /^[[:space:]]*$/) sline = ln
          if (added) plus = 1
        }
        buf = buf " " seg
        if (!k) break
        judge(); reset_stmt()
        out = substr(out, k + 1)
      }
    }
    BEGIN {
      nt = split(tables, tl, " "); for (q = 1; q <= nt; q++) big[tl[q]] = 1
      found = 0; inh = 0; sql = 0; path = ""; incomment = 0; reset_stmt()
    }
    {
      line = $0; sub(/\r$/, "", line)
      if (inh) {
        c = substr(line, 1, 1)
        if (c == "\\") next
        if (c == "-") { oldn--; }
        else if (c == "+") { if (sql) feed(substr(line, 2), newl, 1); newl++; newn-- }
        else if (c == " " || line == "") { if (sql) feed(substr(line, 2), newl, 0); newl++; oldn--; newn-- }
        else { inh = 0 }
        if (inh) { if (oldn <= 0 && newn <= 0) { inh = 0; flush() }; next }
      }
      if (line ~ /^diff --git /) { flush(); sql = 0; path = ""; next }
      if (line ~ /^\+\+\+ /) {
        flush()
        p = substr(line, 5); sub(/\t.*$/, "", p)
        if (p ~ /^".*"$/) p = substr(p, 2, length(p) - 2)
        if (p == "/dev/null") { path = ""; sql = 0; next }
        sub(/^b\//, "", p); path = p
        sql = (tolower(p) ~ /\.sql$/)
        next
      }
      if (line ~ /^@@ /) {
        flush()
        if (match(line, /^@@ -[0-9]+(,[0-9]+)? \+[0-9]+(,[0-9]+)? @@/)) {
          h = substr(line, 4, RLENGTH - 6)
          split(h, hp, " ")
          o = substr(hp[1], 2); nw = substr(hp[2], 2)
          if (index(o, ",")) { split(o, oa, ","); oldn = oa[2] + 0 } else oldn = 1
          if (index(nw, ",")) { split(nw, na, ","); newl = na[1] + 0; newn = na[2] + 0 } else { newl = nw + 0; newn = 1 }
          inh = (oldn > 0 || newn > 0)
        }
        next
      }
    }
    END { flush(); exit (found ? 1 : 0) }
  ' "$f"
}

# mil_merge <review-text-file> <findings-file> <block-word> [words] — print the review
# with a `Migration index lint (BH-7667)` section just before its LAST anchored
# verdict line, and that line rewritten to `VERDICT: <block-word>`. The line is
# replaced, never repeated: verdict_parse reads two verdict lines that disagree
# as unknown (bin/lib/verdict-parse.sh). A review with no verdict line gets the
# section and one verdict line at its end. [words] is the verdict vocabulary
# (`|`-separated, default APPROVE|REQUEST_CHANGES|BLOCK|MERGE-WITH-NOTES): a
# line such as `Verdict reasoning:` is not a verdict line. rc 2 on an
# unreadable input.
mil_merge() {
  local rf="${1:-}" ff="${2:-}" bw="${3:-}" words="${4:-APPROVE|REQUEST_CHANGES|BLOCK|MERGE-WITH-NOTES}"
  [ -r "$rf" ] && [ -r "$ff" ] && [ -n "$bw" ] || return 2
  [[ "$words" =~ ^[A-Za-z_|-]+$ ]] || return 2
  awk -v bw="$bw" -v ff="$ff" -v words="$(printf '%s' "$words" | tr '[:lower:]' '[:upper:]')" '
    function section(   l) {
      print ""; print "Migration index lint (BH-7667)"
      while ((getline l < ff) > 0) if (l ~ /[^[:space:]]/) print l
      close(ff); print ""
    }
    BEGIN { vre = "^[[:space:]]*(#+[[:space:]]*)?(\\*\\*)?VERDICT(\\*\\*)?[[:space:]]*:?[[:space:]]*(\\*\\*)?[[:space:]]*(" words ")([^A-Z0-9_-]|$)" }
    { r[NR] = $0; if (toupper($0) ~ vre) v = NR }
    END {
      for (i = 1; i <= NR; i++) {
        if (i == v) { section(); print "VERDICT: " bw; continue }
        print r[i]
      }
      if (!v) { section(); print "VERDICT: " bw }
    }
  ' "$rf"
}
