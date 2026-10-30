#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/07-merge-carry.sh — BH-8705: the lead word carries
# across a pure merge of main BEFORE gate 10's CI wait. A "merge main into
# the PR" push moved the head; gate 10 held the unapproved head (rc 11) until
# CI was green, and only then could gate 50 replay the lead word. That was a
# 20 to 40 min wait for a diff that did not change.
#   lg_gate_merge_carry <slug> <pr> <head>, cheapest first:
#     LEAD_REVIEW_MERGE_CARRY (LGK_MERGE_CARRY) is not 1   rc 0, nothing read.
#     the ledger has `leadcarry-carried <slug>#<n> <head>` rc 12, no review.
#     no readable lead token file (gate 50's rule)         rc 0, nothing read.
#     the harness repo (fleet.conf's cromford row), the console QA row
#       lane.lead-review.lead_review_console_qa_gate on (unreadable = on,
#       gate 50's _lgd_cqg_on), and cqg_replay_hold says hold, or either
#       check is not loaded                                 rc 0, one log line.
#     lead_carry (bin/lib/lead-carry.sh) with LC_MERGE_ONLY=1:
#       carried   one ledger line, one log line, rc 12 (no review, no CI wait).
#       any other answer                                    rc 0: the chain
#                 runs as before (gate 10, then gate 50).
#   It never returns 10 or 11, so it never holds a head that would get a review.
# The note of the carried row: `lead-replay:<G12> how:main-merge ref:#<id>
# by:lead-review carried_from:#<id> reason:merge-carry:<H12>`.
# Ledger: state/lead-review-enqueue/merge-carry.tsv, rows `<epoch>\t<line>`
# (lead_carry's `leadcarry` / `leadcarry-held` lines, and this gate's
# `leadcarry-carried`). 99-state-sweep.sh trims it. A lost ledger costs one
# history read: lead_carry then refuses a head a verdict already stands on.
# Sourced by bin/lib/lead-gates.sh, never run.

# shellcheck source=bin/lib/lead-gates-knobs.sh
command -v lgk_load >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lead-gates-knobs.sh" 2>/dev/null || true
# shellcheck source=bin/lib/lead-carry.sh
command -v lead_carry >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lead-carry.sh" 2>/dev/null || true
# shellcheck source=bin/lib/patch-same.sh
command -v patch_same >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../patch-same.sh" 2>/dev/null || true
# shellcheck source=bin/lib/verdicts.sh
command -v _vd_get >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../verdicts.sh" 2>/dev/null || true
# shellcheck source=bin/lib/lead-authority.sh
command -v la_decide >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../lead-authority.sh" 2>/dev/null || true
# shellcheck source=bin/lib/console-qa-gate.sh
command -v cqg_replay_hold >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../console-qa-gate.sh" 2>/dev/null || true

_lgmc_file() { local root="${HARNESS:-${H:-}}"; [ -n "$root" ] || return 1; printf '%s\n' "$root/state/lead-review-enqueue/merge-carry.tsv"; }
# _lgmc_has <line> — rc 0 when the ledger holds <line>. No harness root: rc 1.
_lgmc_has() {
  local f; f=$(_lgmc_file) || return 1
  [ -f "$f" ] && awk -F'\t' -v l="$1" '$2 == l {f = 1} END {exit !f}' "$f" 2>/dev/null
}
# _lgmc_put <line> — appends `<epoch>\t<line>`. No harness root: nothing.
_lgmc_put() {
  local f; f=$(_lgmc_file) || return 0
  mkdir -p "${f%/*}" 2>/dev/null && printf '%s\t%s\n' "$(date +%s)" "$1" >> "$f" 2>/dev/null
  return 0
}

lg_gate_merge_carry() {
  local slug="$1" n="$2" head h12 root="${HARNESS:-${H:-}}" fc tok hrepo project repo cqh rc=0
  head=$(printf '%s' "$3" | tr 'A-F' 'a-f'); h12="${head:0:12}"
  command -v lgk_load >/dev/null 2>&1 && lgk_load
  [ "${LGK_MERGE_CARRY:-0}" = 1 ] || return 0
  if _lgmc_has "leadcarry-carried $slug#$n $head"; then
    _lgt_log "$slug#$n @$h12: lead word already carried onto this head; no review"; return 12
  fi
  tok="${LEAD_VERDICT_TOKEN_FILE:-${HOME:-}/.config/cromford/lead-verdict-token}"
  [ -r "$tok" ] || return 0
  command -v lead_carry >/dev/null 2>&1 || return 0
  # BH-5909: a carried word never skips the console QA gate on the harness repo.
  fc="${FLEET_CONF:-${root:+$root/fleet.conf}}"
  hrepo=$(awk '$1 == "cromford" {print $2; exit}' "$fc" 2>/dev/null)
  if [ -n "$hrepo" ] && [ "${slug,,}" = "${hrepo,,}" ]; then
    if ! command -v cqg_replay_hold >/dev/null 2>&1 || ! command -v _lgd_cqg_on >/dev/null 2>&1; then
      _lgt_log "$slug#$n @$h12: no lead merge carry (the console QA check is not loaded)"; return 0
    fi
  fi
  if [ -n "$hrepo" ] && [ "${slug,,}" = "${hrepo,,}" ] && _lgd_cqg_on; then
    project=$(awk -v r="$slug" '$1 !~ /^#/ && $2 == r {print $1; exit}' "$fc" 2>/dev/null)
    repo="${REPOS_ROOT:-/root/repos}/$project"
    command -v patch_same_fetch >/dev/null 2>&1 && [ -d "$repo/.git" ] && patch_same_fetch "$repo" "" "$head" "$n" >/dev/null 2>&1
    if cqh=$(cqg_replay_hold "$slug" "$n" "$head" "$repo" origin/main "$hrepo"); then
      _lgt_log "$slug#$n @$h12: no lead merge carry ($cqh)"; return 0
    fi
  fi
  ACTIONS=1 LC_MERGE_ONLY=1 LC_BY=lead-review LC_LOG_FN=_lgt_log LC_ATTEMPT_HAS_FN=_lgmc_has LC_ATTEMPT_PUT_FN=_lgmc_put \
    lead_carry "$slug#$n" "$slug" "$n" "$head" "merge-carry:$h12" || rc=$?
  [ "$rc" = 0 ] && [ "${LC_RESULT:-}" = carried ] || return 0
  _lgmc_put "leadcarry-carried $slug#$n $head"
  _lgt_log "$slug#$n @$h12: lead $LC_WORD carried from ${LC_FROM:0:12} (how:main-merge); no review, no CI wait"
  return 12
}
