#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/78-body-lint.sh — gate 8 of bin/lead-review-enqueue.sh,
# the PR-body section lint (BH-5790): the body-* rules of
# catalog/pr-self-check.tsv, on the same psc_check run as 75-self-check.sh
# (lgsc_run caches it per head).
#   A `REFUSE body-*` line  lgsc_hold, as gate 7: rc 11 inside the bound, rc 0
#       past it.
#   On a pass it writes the head's notes ONCE to the enqueue's per-head file
#   state/lead-review-enqueue/selfcheck-notes-<slug_>-<n>-<h12> and never
#   rewrites it: `self-check: <every refusal>` when the head passes with
#   refusals (past the bound), then `self-check notes: <the note rules>`
#   (body-mutation, body-d1: they hold nothing), joined by `; `. Nothing to
#   say = no file.
#   lg_field_self_check_notes  prints that file: the job meta key
#   self_check_notes, byte-identical on every job of the head.
# Sourced by bin/lib/lead-gates.sh, never run.

# shellcheck source=bin/lib/lead-gates-selfcheck.sh
command -v lgsc_run >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lead-gates-selfcheck.sh" 2>/dev/null || true

# _lgbl_notes_file <slug> <n> <head> — the per-head notes path; rc 1 with no root.
_lgbl_notes_file() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$root" ] || return 1
  printf '%s/state/lead-review-enqueue/selfcheck-notes-%s-%s-%s\n' "$root" \
    "$(printf '%s' "${1//\//_}" | tr -cd 'A-Za-z0-9._-')" "$2" "${3:0:12}"
}

lg_gate_body_lint() {
  local head rc=0 all notes text="" f
  head=$(printf '%s' "$3" | tr 'A-F' 'a-f')
  command -v lgsc_run >/dev/null 2>&1 || return 0
  lgsc_run "$1" "$2" "$head" || return 0
  all=$(lgsc_refusals all)
  if [ -n "$(lgsc_refusals body)" ]; then
    lgsc_hold "$1" "$2" "$head" "$all" || rc=$?
    [ "$rc" = 0 ] || return "$rc"
  fi
  f=$(_lgbl_notes_file "$1" "$2" "$head") || return 0
  [ -e "$f" ] && return 0
  notes=$(lgsc_notes)
  [ -n "$all" ] && text="self-check: $(printf '%s' "$all" | tr '\n' ';' | cut -c1-400)"
  [ -n "$notes" ] && text="${text:+$text; }self-check notes: $(printf '%s' "$notes" | tr '\n' ';' | cut -c1-400)"
  [ -n "$text" ] || return 0
  mkdir -p "${f%/*}" 2>/dev/null
  printf '%s' "$text" > "$f" 2>/dev/null || _lgt_log "$1#$2 @${head:0:12}: self-check notes not written to $f; the job carries none"
  return 0
}

lg_field_self_check_notes() {
  local f
  f=$(_lgbl_notes_file "$1" "$2" "$(printf '%s' "$3" | tr 'A-F' 'a-f')") || return 0
  [ -s "$f" ] && cat "$f"
  return 0
}
