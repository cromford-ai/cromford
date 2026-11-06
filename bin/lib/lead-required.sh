#!/bin/bash
# bin/lib/lead-required.sh — A REPO THAT REQUIRES A LEAD VERDICT IS NEVER
# CLEARED BY THE BUILDER ALONE (BH-8890). Sourced, never executed.
#
# THE CASE (2026-11-01). project-6 #3501 (TK-3499): the pool's own review wrote
# APPROVE to the jobs ledger, the conductor read it, classified the PR READY,
# added the merge-queue label and tried to publish lead-verdict=success. No lead
# had reviewed the head (GET /api/verdicts?repo=example-org/project-6&pr=3501
# returned rows: []).
#
# THE ROW. lead_required.<owner>.<name> (lowercased; the settings key rule
# allows nothing else). 1 = READY also needs a lead or human MERGE /
# MERGE-WITH-NOTES standing on the live head. No row or 0 = no hold (the
# publish context is the same on every repo, lr_clear_context below).
# The seed (worker/jobs/schema.d/202611032342-bh-8890-lead-required-seed.sql)
# sets example-org/project-6 to 1.
#
# lr_required <owner/repo>
#   rc 0 -> the row is 1 (whitespace trimmed)
#   rc 1 -> the row is 0 or absent; or the key fails the settings key rule
#           ([a-z0-9_.-], at most 64 characters: no such row can be written);
#           or no jobs worker is configured (setting_get not loaded, JOBS_URL or
#           HARNESS_SECRET empty: such a process cannot read a lead row either)
#   rc 2 -> the row cannot be read (setting_get rc 1) or holds a value that is
#           not 0 or 1. The caller holds; this answer is NOT memoized.
#   A readable answer is memoized per shell in _LR_MEMO (a plain string, so
#   bash 3.2 on the lead's Mac can source this file).
#
# lr_lead_stands <key|-> <owner/repo> <num> <head>
#   rc 0 -> a lead or human MERGE / MERGE-WITH-NOTES stands on <head>
#           (vd_standing). When nothing stands and <key> is not `-`, a lead
#           word on an older head with the same patch is carried first
#           (lead_carry, BH-6291), the same as mc_lead_ready.
#   rc 1 -> none stands; when another row stands, prints `<verdict> <source>`
#   rc 2 -> the verdict cannot be read (vd_standing rc 2, or no reader loaded)
#
# lr_clear_context <owner/repo> <num> <head>
#   Sets the global LR_CTX to the commit status context a conductor success
#   publish uses, and prints nothing (so the memo survives in the caller's
#   shell). `lead-verdict` only when a lead or human MERGE / MERGE-WITH-NOTES
#   stands on <head> (lr_lead_stands rc 0), on EVERY repo. Else
#   `harness-verdict` (vs_builder_context): a builder-only clearance never
#   reads as a lead pass. BH-9039: this holds on a repo with no lead_required
#   row (or 0) too, so lr_required is not read here, and each call makes ONE
#   verdict read (vd_standing) on every repo. An unreadable or unloaded
#   verdict reader gives harness-verdict. No carry here: the callers carry
#   before they publish. cromford's queue accepts either context
#   (config/mergify/repos/cromford.conf, status_check_any=).
#
# No root and no paths of its own: the readers load off this file's directory.

command -v vd_standing >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/verdicts.sh" ] && . "${BASH_SOURCE[0]%/*}/verdicts.sh"; }
command -v lead_carry >/dev/null 2>&1 || { [ -r "${BASH_SOURCE[0]%/*}/lead-carry.sh" ] && . "${BASH_SOURCE[0]%/*}/lead-carry.sh"; }

_LR_MEMO="${_LR_MEMO:-}"

lr_required() {
  local slug key v rc hit
  slug=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z')
  case "$slug" in ?*/?*) ;; *) return 1 ;; esac
  command -v setting_get >/dev/null 2>&1 || return 1
  [ -n "${JOBS_URL:-}" ] && [ -n "${HARNESS_SECRET:-}" ] || return 1
  key="lead_required.${slug%%/*}.${slug#*/}"
  case "$key" in *[!a-z0-9_.-]*) return 1 ;; esac
  [ "${#key}" -le 64 ] || return 1
  hit=$(printf '%s' "$_LR_MEMO" | awk -v s="$slug" '$1 == s { print $2; exit }')
  [ -n "$hit" ] && return "$hit"
  v=$(setting_get "$key"); rc=$?
  case "$rc" in
    0) v="${v//[[:space:]]/}"
       case "$v" in 1) rc=0 ;; 0) rc=1 ;; *) return 2 ;; esac ;;
    2) rc=1 ;;
    *) return 2 ;;
  esac
  _LR_MEMO="$_LR_MEMO$slug $rc"$'\n'
  return "$rc"
}

lr_lead_stands() {
  local key="${1:--}" slug="$2" num="$3" head="$4" line rc word src
  command -v vd_standing >/dev/null 2>&1 || return 2
  line=$(vd_standing "$slug" "$num" "$head" 2>/dev/null); rc=$?
  if [ "$rc" = 1 ] && [ "$key" != - ] && command -v lead_carry >/dev/null 2>&1 \
     && lead_carry "$key" "$slug" "$num" "$head" >/dev/null 2>&1; then
    line=$(vd_standing "$slug" "$num" "$head" 2>/dev/null); rc=$?
  fi
  case "$rc" in 0) ;; 1) return 1 ;; *) return 2 ;; esac
  word=$(cut -f1 <<<"$line"); src=$(cut -f2 <<<"$line")
  case "$word:$src" in
    MERGE:lead|MERGE:human|MERGE-WITH-NOTES:lead|MERGE-WITH-NOTES:human) return 0 ;;
  esac
  [ -n "$word" ] && printf '%s %s\n' "$word" "${src:--}"
  return 1
}

lr_clear_context() {
  LR_CTX=lead-verdict
  lr_lead_stands - "${1:-}" "${2:-}" "${3:-}" >/dev/null 2>&1 && return 0
  LR_CTX=$(command -v vs_builder_context >/dev/null 2>&1 && vs_builder_context || echo harness-verdict)
  return 0
}
