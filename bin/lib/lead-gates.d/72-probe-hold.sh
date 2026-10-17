#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-gates.d/72-probe-hold.sh — BH-5878: the live-probe order of
# bin/lead-review-enqueue.sh (BH-5801). The enqueue runs a PR's declared probes
# (lp_run_for_head) before it asks for the lead review, so the review reads
# their evidence. A worklist start does not run them, so this gate holds
# a worklist head whose PR body declares a probe (a fenced ```live-probes
# block, lp_declared of bin/lib/live-probes.sh) until the harness App's
# `<!-- live-probes:<head> -->` comment for THIS head is on the PR
# (lp_evidence). A comment for an earlier head does not count.
#   no probe declared, no lib, or LEAD_REVIEW_PROBE_WAIT_MAX_MIN=0   rc 0.
#   the App comment for this head                                    rc 0.
#   none yet, held under the bound                                   rc 11, one
#       log line a head a process. The hold marker
#       state/lead-review-gates/probe-wait-<slug_>-<n>-<sha12> records when
#       the hold began.
#   none after LEAD_REVIEW_PROBE_WAIT_MAX_MIN (default 60) minutes  rc 0, and
#       field probe_note says `no live-probe comment after <n> min`. A marker
#       that cannot be written or read holds nothing: rc 0 with the note.
# The PR body is gate 55's one read (lgs_pr_body); an unreadable body is rc 11.
# Markers go after 14 days (lg_tick_probe_hold). Sourced by bin/lib/lead-gates.sh.

# shellcheck source=bin/lib/live-probes.sh
command -v lp_declared >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/../live-probes.sh" 2>/dev/null || true

declare -g _LGPH_PRUNED="" _LGPH_KEY="" _LGPH_NOTE=""

lg_tick_probe_hold() {
  local root="${HARNESS:-${H:-}}"
  [ -n "$_LGPH_PRUNED" ] && return 0
  _LGPH_PRUNED=1
  [ -n "$root" ] && [ -d "$root/state/lead-review-gates" ] \
    && find "$root/state/lead-review-gates" -maxdepth 1 -type f -name 'probe-wait-*' -mtime +14 -delete 2>/dev/null
  return 0
}

lg_gate_probe_hold() {
  local slug="$1" n="$2" head h12="${3:0:12}" root="${HARNESS:-${H:-}}" max rc=0 d bf ev waitf w0 age
  head=$(printf '%s' "$3" | tr 'A-F' 'a-f')
  _LGPH_KEY="$slug#$n@$head"; _LGPH_NOTE=""
  [ -n "$_LGPH_PRUNED" ] || lg_tick_probe_hold "$slug"
  command -v lp_declared >/dev/null 2>&1 && command -v lp_evidence >/dev/null 2>&1 || return 0
  max="${LEAD_REVIEW_PROBE_WAIT_MAX_MIN:-60}"
  [[ "$max" =~ ^[0-9]{1,5}$ ]] || max=60
  [ "$max" = 0 ] && return 0
  command -v lgs_pr_body >/dev/null 2>&1 || return 0
  lgs_pr_body "$slug" "$n" || rc=$?
  if [ "$rc" != 0 ] || [ ! -s "${LGS_BODY_FILE:-}" ]; then
    _lgt_log "$slug#$n @$h12: live probes: PR body unreadable (rc $rc); held"; return 11
  fi
  d=$(lgs_dir 2>/dev/null) || return 0
  bf="$d/probe-body-$n"
  jq -r '.body // ""' "$LGS_BODY_FILE" > "$bf" 2>/dev/null
  [ -n "$(lp_declared "$bf")" ] || return 0
  ev=$(lp_evidence "$slug" "$n" "$head")
  case "$ev" in "<!-- live-probes:$head -->"*) return 0 ;; esac
  if [ -z "$root" ]; then _LGPH_NOTE="no live-probe comment (no harness root to time the hold)"; return 0; fi
  waitf="$root/state/lead-review-gates/probe-wait-$(printf '%s' "${slug//\//_}" | tr -cd 'A-Za-z0-9._-')-$n-$h12"
  mkdir -p "${waitf%/*}" 2>/dev/null
  [ -e "$waitf" ] || : > "$waitf" 2>/dev/null
  w0=$(stat -c %Y "$waitf" 2>/dev/null)
  if ! [[ "$w0" =~ ^[0-9]+$ ]]; then
    _LGPH_NOTE="no live-probe comment (hold marker unusable)"
    _lgt_log "$slug#$n @$h12: live probes declared, hold marker $waitf unusable; starting"
    return 0
  fi
  age=$(( $(date +%s) - w0 ))
  if [ "$age" -lt $((max * 60)) ]; then
    _lgt_once "probe-$slug-$n-$h12" "$slug#$n @$h12: live probes declared, no harness App comment for this head yet; held (${age}s of ${max}m)"
    return 11
  fi
  _LGPH_NOTE="no live-probe comment after $max min"
  _lgt_log "$slug#$n @$h12: live probes declared, no harness App comment after ${max}m; starting"
  return 0
}

lg_field_probe_note() {
  [ "$_LGPH_KEY" = "$1#$2@$(printf '%s' "$3" | tr 'A-F' 'a-f')" ] && printf '%s' "$_LGPH_NOTE"
  return 0
}
