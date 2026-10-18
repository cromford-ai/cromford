#!/bin/bash
# bin/lib/pr-body-requires.sh — BH-7378: the PR-body coverage check. A plan
# names what the PR body must carry in a fenced block, and the check reports
# each item the body lacks. It is a NOTE only: it never refuses, never holds
# and never changes the verdict. The fix is a body edit, so the head does not
# move. Sourced; defines functions only, no output at source time.
#
# THE BLOCK (in .harness/specs/<KEY>/plan.md):
#   ```pr-body-requires
#   ## Flip evidence <- T3
#   TEST-CHANGE: <- ticket line 4
#   ```
#   One item per line, `<item>` or `<item> <- <source>`. The split is on the
#   LAST ` <- `; no source reads `the plan`. The info string is case-blind
#   (```PR-BODY-REQUIRES counts) and must be the only word. CR, blank lines and
#   control characters are dropped, item and source are cut to 120 chars, a
#   duplicate item keeps its first source. An unclosed fence gives no items.
#   The match is fixed-string and case-sensitive anywhere in the body, so
#   `## Flip evidence` is also found inside `### Flip evidence`.
#
# pbr_items <plan-file>
#   `<item>\t<source>` per item of every block. No file, no block = nothing, rc 0.
# pbr_missing <plan-file> <body-file>
#   `<item>\t<source>` per item the CR-stripped body lacks. rc 0 | 2 the body
#   will not read (a caller says "not verified", never "missing").
# psc_requires_check <repo> <base> <head> <body> <id> [files]
#   The self-check rule body-plan-requires (bin/lib/pr-self-check.sh). Plans =
#   every .harness/specs/*/plan.md the PR changes and the head still has
#   ([files] is psc_check's base...head name list). One
#   `NOTE <id>: the body is missing <item> (required by <source>)` per item,
#   10 at most and then one `... missing <n> more items ...` line: the shape
#   self_check_hold (bin/lead-review-enqueue.sh) and lgsc_notes
#   (bin/lib/lead-gates-selfcheck.sh) forward into the lead review notes.
#   rc 0 on every path.
# pbr_plan_rule
#   The planner sentence (UI_PLAN_NOTE in bin/lib/rb/plan.sh, PP_PREAMBLE in
#   bin/run-preplan.sh).
# The CLI is bin/pr-body-requires.sh.

pbr_items() {
  local f="${1:-}"
  [ -n "$f" ] && [ -r "$f" ] || return 0
  LC_ALL=C awk '
    function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
    function emit(   i, l, p, q, item, src) {
      for (i = 1; i <= n; i++) {
        l = L[i]; gsub(/\t/, " ", l); gsub(/[[:cntrl:]]/, "", l); l = trim(l)
        if (l == "") continue
        # Padded, so `<- src` (no item) and `item <-` (no source) still split.
        l = " " l " "; p = 0; while ((q = index(substr(l, p + 1), " <- ")) > 0) p += q
        if (p > 0) { item = trim(substr(l, 1, p - 1)); src = trim(substr(l, p + 4)) }
        else { item = trim(l); src = "" }
        if (src == "") src = "the plan"
        item = substr(item, 1, 120); src = substr(src, 1, 120)
        if (item == "" || (item in seen)) continue
        seen[item] = 1
        print item "\t" src
      }
    }
    { gsub(/\r/, "") }
    !inb && tolower($0) ~ /^[[:space:]]*```[[:space:]]*pr-body-requires[[:space:]]*$/ { inb = 1; n = 0; next }
    inb && /^[[:space:]]*````*[[:space:]]*$/ { emit(); inb = 0; next }
    inb { L[++n] = $0 }
  ' "$f" 2>/dev/null
  return 0
}

pbr_missing() {
  local plan="${1:-}" body="${2:-}" bf item src
  [ -n "$body" ] && [ -r "$body" ] || return 2
  bf=$(mktemp "${TMPDIR:-/tmp}/pbr-body.XXXXXX" 2>/dev/null) || return 2
  tr -d '\r' < "$body" > "$bf" 2>/dev/null || { rm -f "$bf"; return 2; }
  while IFS=$'\t' read -r item src; do
    [ -n "$item" ] || continue
    grep -qF -- "$item" "$bf" || printf '%s\t%s\n' "$item" "$src"
  done < <(pbr_items "$plan")
  rm -f "$bf"
  return 0
}

psc_requires_check() {
  local repo="$1" base="$2" head="$3" body="$4" id="${5:-body-plan-requires}" files="${6-}" plans p pf all="" miss mrc n=0 item src
  if [ "$#" -lt 6 ]; then
    files=$(git -C "$repo" diff --no-renames --name-only "$base...$head" 2>/dev/null) || return 0
  fi
  plans=$(grep -E '^\.harness/specs/[^/]+/plan\.md$' <<<"$files")
  [ -n "$plans" ] || return 0
  while IFS= read -r p; do
    # A plan the PR deletes is not a plan of this head.
    git -C "$repo" cat-file -e "$head:$p" 2>/dev/null || continue
    pf=$(mktemp "${TMPDIR:-/tmp}/pbr-plan.XXXXXX" 2>/dev/null) \
      || { echo "NOTE $id: $p at the head will not read, so required body items are not checked"; continue; }
    if ! git -C "$repo" show "$head:$p" > "$pf" 2>/dev/null; then
      rm -f "$pf"; echo "NOTE $id: $p at the head will not read, so required body items are not checked"; continue
    fi
    miss=$(pbr_missing "$pf" "$body"); mrc=$?
    rm -f "$pf"
    if [ "$mrc" != 0 ]; then
      echo "NOTE $id: the body will not read, so required body items are not checked"; return 0
    fi
    [ -n "$miss" ] && all="$all$miss"$'\n'
  done <<<"$plans"
  while IFS=$'\t' read -r item src; do
    [ -n "$item" ] || continue
    n=$((n + 1))
    [ "$n" -le 10 ] && echo "NOTE $id: the body is missing $item (required by $src)"
  done < <(printf '%s' "$all" | awk -F'\t' '!seen[$1]++')
  [ "$n" -gt 10 ] && echo "NOTE $id: the body is missing $((n - 10)) more items of the plan's pr-body-requires block"
  return 0
}

pbr_plan_rule() {
  printf '%s' "PR-BODY-REQUIRES (BH-7378): if the ticket, a comment or one of your own VALIDATE lines says the PR body must carry a section or a literal (flip evidence, an owed re-measure, operator steps, a TEST-CHANGE line, BEFORE/AFTER counts), list each one in a fenced \`\`\`pr-body-requires block in plan.md, one per line, as '<exact heading or string> <- <task or ticket line>', for example '## Flip evidence <- T3'. The review gets a [NOTE] for each item the live PR body lacks. Write no block when nothing is required."
}
