#!/bin/bash
# bin/lib/ticket-ref.sh — ONE definition of a ticket reference (BH-7922), for
# every footer the harness writes and reads (`Part of <ref>`,
# `Blocked-by: <ref>[ (hard)]`). A reference is a GitHub number with its hash
# (`#12`) or a tracker key (`CRO-12`, `PROJ-7`, `A1_B-3`: an upper-case letter,
# then upper-case letters, digits or `_`, a dash and a number). A bare `12`,
# `CRO 12`, `cro-12` and `CRO-12-3` are not references.
#
# Sourced, never executed: no `set -e`, no `exit`, no output and no write at
# source time, safe under the caller's `set -u`. Sourcing it twice is inert.
#
#   TICKET_REF_ERE               the ERE of one reference, for grep -E / [[ =~ ]]
#   ticket_ref_valid <s>         rc 0 when the WHOLE string is one reference
#   ticket_ref_blocked_by        stdin -> one ref per line, from every line
#                                `Blocked-by: <ref>[ (hard|soft)][, <ref>…]`
#   ticket_ref_part_of           stdin -> the ref of every line `Part of <ref>`
#   ticket_ref_num <ref>         `#12` -> `12`; a key is printed unchanged
#
# The two line parsers are LINE-ANCHORED and strict: a line with leading
# spaces, a word before the ref (`Blocked-by: see CRO-12`) or anything after it
# (`Not Part of CRO-12`, `Part of CRO-12 maybe`) yields nothing. A
# `Blocked-by:` line that carries one bad item yields nothing at all: a
# half-read dependency list releases a child too early.
# No parser site uses this file yet (BH-7922 slice C0); slice C1 moves them.

TICKET_REF_ERE='(#[0-9]+|[A-Z][A-Z0-9_]*-[0-9]+)'

ticket_ref_valid() {
  [[ "${1:-}" =~ ^${TICKET_REF_ERE}$ ]]
}

# ticket_ref_blocked_by — stdin is a ticket body; stdout one ref per line, in
# the order the lines carry them. Always rc 0.
ticket_ref_blocked_by() {
  local line rest item ref out
  local -a items
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^Blocked-by:[[:blank:]]*(.*)$ ]] || continue
    rest="${BASH_REMATCH[1]}"
    IFS=',' read -r -a items <<<"$rest"
    [ "${#items[@]}" -gt 0 ] || continue
    out=""
    for item in "${items[@]}"; do
      # trim the item, then it is `<ref>` or `<ref> (hard|soft)`, nothing else
      item="${item#"${item%%[![:blank:]]*}"}"
      item="${item%"${item##*[![:blank:]]}"}"
      if [[ "$item" =~ ^${TICKET_REF_ERE}([[:blank:]]*\((hard|soft)\))?$ ]]; then
        ref="${BASH_REMATCH[1]}"
        out="$out$ref"$'\n'
      else
        out=""; break
      fi
    done
    [ -n "$out" ] && printf '%s' "$out"
  done
  return 0
}

# ticket_ref_part_of — stdin is a ticket body; stdout the ref of every
# `Part of <ref>` line, one per line. Always rc 0.
ticket_ref_part_of() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^Part\ of\ ${TICKET_REF_ERE}[[:blank:]]*$ ]] && printf '%s\n' "${BASH_REMATCH[1]}"
  done
  return 0
}

# ticket_ref_num <ref> — the form a tracker call takes: `#12` is GitHub's issue
# 12, so `12`; a key is the key. rc 1 and nothing printed for a non-reference.
ticket_ref_num() {
  ticket_ref_valid "${1:-}" || return 1
  case "$1" in
    '#'*) printf '%s\n' "${1#\#}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}
