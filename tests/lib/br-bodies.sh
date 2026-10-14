# tests/lib/br-bodies.sh — the SET of br_* function bodies a group of files
# carries, for the byte-for-byte check that a bin/lib/br/ move is pure (BH-5241).
# Sourced, never executed. Not a suite: tests/*.sh does not glob tests/lib/.
#
# br_bodies <file>... prints one sorted, unique line per distinct body:
#   <name><TAB><sha256 of the body text, joined onto one line>
# A body is a column-0 `br_x() {` line through the next `^}` line, or the one
# line itself when it also closes there (`br_x() { …; }`). Indented definitions
# are out of scope. The opener is matched with bracket classes, never `\(` in a
# regex: gawk reads those escapes back as metacharacters (the fn_body lesson in
# tests/br-split-layout-test.sh). A function that moved byte for byte from one
# file to another gives the same line; a dark copy (the same body in two files)
# gives one line. So two runs differ exactly when a body changed, a function was
# dropped, or one was renamed.
# shellcheck shell=bash

br_bodies() { # br_bodies <file>... — rc 1 when a file is unreadable
  local f name body
  for f in "$@"; do [ -r "$f" ] || return 1; done
  # awk joins each body onto ONE line (a backslash doubled, a newline as \n),
  # which is reversible, so equal lines mean equal bytes.
  awk '
    function esc(s) { gsub(/\\/, "\\\\", s); return s }
    function flush() { printf "%s\t%s\n", name, body; f = 0 }
    FNR == 1 { f = 0 }
    !f && /^br_[A-Za-z0-9_]*[(][)] [{]/ {
      name = $0; sub(/[(].*/, "", name); body = esc($0); f = 1
      if ($0 ~ /[}][[:space:]]*$/) flush()
      next
    }
    f { body = body "\\n" esc($0); if ($0 ~ /^[}]$/) flush() }
  ' "$@" | while IFS=$'\t' read -r name body; do
    printf '%s\t%s\n' "$name" "$(printf '%s' "$body" | sha256sum | cut -d' ' -f1)"
  done | LC_ALL=C sort -u
}
