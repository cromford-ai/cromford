#!/bin/bash
# gh-identity: raw-by-design — its label POST/DELETE run INSIDE mc_enqueue_mergify, on the identity the conductor already armed for this repo, the same identity that writes the merge-queue label right after them; a second mint here would override that choice.
# bin/lib/queue-flake-fix.sh — A FLAKE FIX GOES FIRST IN THE MERGE QUEUE (BH-7279).
# Sourced, never executed.
#
#   qff_rules_load                     the mode, min count and scope globs
#   qff_mode                           flake_fix.mode: off|shadow|enforce
#   qff_list <root>                    the batch-fail suites, one a line
#   qff_decide <files> <list> [globs]  `<route>\t<suite|->\t<reason>`
#   qff_enqueue_step <slug> <num> <head>  mc_enqueue_mergify's block; rc 0 always
#
# WHY. On 2026-10-17 the fix for a suite that failed merge-queue batches
# (#7194, tests/staff-watchman.bh-5565-test.sh) queued in `default` behind the
# batches that suite kept failing. A PR that fixes a batch-fail suite is the PR
# that saves the other batches, so it gets the `flake-fix` queue (batch_size 1,
# config/mergify/template.yml), which Mergify serves after `hotfix` and before
# `solo` and `default`. It carries no priority rule: it never interrupts
# running checks.
#
# THE RULE. Route `flake-fix` when BOTH hold:
#   - a changed file is EXACTLY a suite on the batch-fail list (whole path), and
#   - every changed file matches a glob of flake_fix.scope_globs (test and doc
#     paths; a bash `*` crosses `/`).
# Everything else routes `default`. The batch-fail list is
# bin/prequeue-learned.sh --list --why: the committed seed suites
# (catalog/prequeue-learned-seed.d/) and the suites counted from failed batch
# runs in its window, kept at count >= flake_fix.min_fails. Seeds are never cut.
#
# UNKNOWN IS TODAY'S ROUTING. A file list or batch-fail list that cannot be
# read routes default, the queue every PR took before this lib.
#
# THE ROWS (a code constant is only the fallback):
#   flake_fix.mode         off|shadow|enforce. No reader, no row or an outage
#                          is enforce; an unknown value is off, one log line.
#   flake_fix.min_fails    a positive integer, default 1. Anything else is 1.
#   flake_fix.scope_globs  space-separated globs, default QFF_SCOPE_GLOBS_DEFAULT.
#                          An empty row is the default.
# The rows and the list are read once per conductor tick (MC_TICK_ID), like
# bin/lib/queue-risk.sh's rows.
#
# The root is ${HARNESS:-${H:-}} and nothing else (D43): empty is a silent rc 0.
# Bash 4, jq.
[ -n "${_QFF_LOADED:-}" ] && return 0
_QFF_LOADED=1

QFF_SCOPE_GLOBS_DEFAULT='tests/* worker/jobs/test/* console-ui/tests/* docs/* .harness/specs/*'
QFF_MIN_FAILS_DEFAULT=1
QFF_SUITE_RE='^tests/(mc/)?[A-Za-z0-9._-]+\.sh$'

_qff_root() { printf '%s' "${HARNESS:-${H:-}}"; }
_qff_log() { command -v mc_log >/dev/null 2>&1 && mc_log "$*"; return 0; }
_qff_trim() { sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }

# _qff_tick_file <name> — the per-tick cache path, or rc 1 without a tick.
_qff_tick_file() {
  [ -n "${MC_TICK_ID:-}" ] && [ -n "${MC_TICK_DIR:-}" ] || return 1
  printf '%s/%s.%s' "$MC_TICK_DIR" "$(printf '%s' "$MC_TICK_ID" | tr -c 'A-Za-z0-9._-' '_')" "$1"
}

# _qff_put <cache> — stdin to the cache file (tmp + mv). A failure is silent.
_qff_put() {
  [ -n "$1" ] && mkdir -p "${1%/*}" 2>/dev/null || { cat >/dev/null; return 0; }
  cat > "$1.tmp.$$" 2>/dev/null && mv -f "$1.tmp.$$" "$1" 2>/dev/null || rm -f "$1.tmp.$$" 2>/dev/null
  return 0
}

# qff_rules_load — sets QFF_MODE, QFF_MIN_FAILS, QFF_SCOPE_GLOBS in THIS shell.
qff_rules_load() {
  local cache v rc
  if cache=$(_qff_tick_file flake-fix-rules) && [ -r "$cache" ] && . "$cache" 2>/dev/null \
     && [ -n "${QFF_MODE:-}" ]; then return 0; fi
  QFF_MODE=enforce; QFF_MIN_FAILS=$QFF_MIN_FAILS_DEFAULT; QFF_SCOPE_GLOBS=$QFF_SCOPE_GLOBS_DEFAULT
  if command -v setting_get >/dev/null 2>&1; then
    rc=0; v=$(setting_get flake_fix.mode 2>/dev/null) || rc=$?
    if [ "$rc" = 0 ]; then
      v=$(printf '%s' "$v" | _qff_trim)
      case "$v" in
        off|shadow|enforce) QFF_MODE="$v" ;;
        *) _qff_log "flake_fix.mode '$(printf '%s' "$v" | tr -d '\n' | head -c 40)' is not off|shadow|enforce — flake-fix routing is off"; QFF_MODE=off ;;
      esac
    fi
    rc=0; v=$(setting_get flake_fix.min_fails 2>/dev/null) || rc=$?
    v=$(printf '%s' "$v" | _qff_trim)
    if [ "$rc" = 0 ]; then
      case "$v" in ''|*[!0-9]*) ;; *) [ "$((10#$v))" -ge 1 ] && QFF_MIN_FAILS=$((10#$v)) ;; esac
    fi
    rc=0; v=$(setting_get flake_fix.scope_globs 2>/dev/null) || rc=$?
    v=$(printf '%s' "$v" | tr '\n\t' '  ' | _qff_trim)
    [ "$rc" = 0 ] && [ -n "$v" ] && QFF_SCOPE_GLOBS="$v"
  fi
  [ -n "$cache" ] && printf 'QFF_MODE=%q\nQFF_MIN_FAILS=%q\nQFF_SCOPE_GLOBS=%q\n' "$QFF_MODE" "$QFF_MIN_FAILS" "$QFF_SCOPE_GLOBS" | _qff_put "$cache"
  return 0
}

qff_mode() { qff_rules_load; printf '%s' "$QFF_MODE"; }

# qff_list <root> — the batch-fail suites, sorted and unique. A missing script,
# a non-zero rc or no rows prints nothing (rc 0).
qff_list() {
  local root="${1:-}" s out
  s="$root/bin/prequeue-learned.sh"
  [ -n "$root" ] && [ -r "$s" ] || return 0
  [ -n "${QFF_MIN_FAILS:-}" ] || qff_rules_load
  out=$(bash "$s" --list --why --harness "$root" 2>/dev/null) || return 0
  printf '%s\n' "$out" | while IFS=$'\t' read -r n suite; do
    [[ $suite =~ $QFF_SUITE_RE ]] || continue
    case "$n" in
      seed) printf '%s\n' "$suite" ;;
      ''|*[!0-9]*) ;;
      *) [ "$((10#$n))" -ge "$QFF_MIN_FAILS" ] && printf '%s\n' "$suite" ;;
    esac
  done | LC_ALL=C sort -u
  return 0
}

# _qff_match <path> <glob> — a bash `*` crosses `/`.
_qff_match() {
  # shellcheck disable=SC2053
  [[ $1 == $2 ]]
}

# qff_decide <files-file> <list-file> [globs] — pure. One line,
# `<route>\t<suite|->\t<reason>`, rc 0.
qff_decide() {
  local files="${1:-}" list="${2:-}" globs="${3:-${QFF_SCOPE_GLOBS:-$QFF_SCOPE_GLOBS_DEFAULT}}"
  local p g hit suite="" gs=() listed=()
  local -A onlist=()
  if [ -z "$files" ] || [ ! -r "$files" ] || ! grep -q . "$files" 2>/dev/null; then
    printf 'default\t-\tfiles-unavailable\n'; return 0
  fi
  if [ -n "$list" ] && [ -r "$list" ]; then
    while IFS= read -r p; do [ -n "$p" ] && onlist["$p"]=1; done < "$list"
  fi
  [ "${#onlist[@]}" -gt 0 ] || { printf 'default\t-\tlist-empty\n'; return 0; }
  while IFS= read -r p; do
    [ -n "$p" ] && [ -n "${onlist[$p]:-}" ] && listed+=("$p")
  done < "$files"
  [ "${#listed[@]}" -gt 0 ] || { printf 'default\t-\tno-batch-fail-suite\n'; return 0; }
  suite=$(printf '%s\n' "${listed[@]}" | LC_ALL=C sort | head -1)
  # read -a, never an unquoted expansion: `docs/*` would glob against the cwd.
  read -r -a gs <<<"$globs"
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    hit=""
    for g in "${gs[@]}"; do _qff_match "$p" "$g" && { hit=1; break; }; done
    [ -n "$hit" ] || { printf 'default\t%s\tout-of-scope:%s\n' "$suite" "$p"; return 0; }
  done < "$files"
  printf 'flake-fix\t%s\tin-scope\n' "$suite"
}

# qff_enqueue_step <slug> <num> <head> — mc_enqueue_mergify's block, BEFORE the
# queue-risk block and the merge-queue label. rc 0 always: it never holds a PR.
# Runs only for a repo whose config/mergify/repos/<repo>.conf names this slug
# AND carries a flake_fix_label= line, so an opted-out repo costs no read.
#   enforce + flake-fix   POST the label (before merge-queue, so the PR is
#                         never briefly in default without it)
#   enforce + default     DELETE the label the PR still carries from an older
#                         head
#   shadow                log only, with `(would route <r>)`
# A fix-main-red PR (the hotfix queue) and a train PR are logged and get no
# label write.
qff_enqueue_step() {
  local slug="$1" num="$2" head="$3" root conf label pj="" labels="" title="" ref="" files list
  local out route suite reason note="" enc err cache
  root=$(_qff_root); [ -n "$root" ] || return 0
  conf="$root/config/mergify/repos/${slug#*/}.conf"
  [ -r "$conf" ] && grep -qx "slug=$slug" "$conf" 2>/dev/null || return 0
  label=$(sed -n 's/^flake_fix_label=\([a-z0-9][a-z0-9-]*\)[[:space:]]*$/\1/p' "$conf" | tail -1)
  [ -n "$label" ] || return 0
  qff_rules_load
  [ "$QFF_MODE" = off ] && return 0
  files=$(mktemp "${TMPDIR:-/tmp}/qff-files.XXXXXX") || files=""
  list=$(mktemp "${TMPDIR:-/tmp}/qff-list.XXXXXX") || list=""
  if command -v gh_rest_var >/dev/null 2>&1 && gh_rest_var pj GET "repos/$slug/pulls/$num" 2>/dev/null && [ -n "$pj" ] \
     && jq -e 'type == "object"' >/dev/null 2>&1 <<<"$pj"; then
    labels=$(jq -r '[.labels[]?.name] | join(",")' <<<"$pj" 2>/dev/null)
    title=$(jq -r '.title // ""' <<<"$pj" 2>/dev/null)
    ref=$(jq -r '.head.ref // ""' <<<"$pj" 2>/dev/null)
  else
    pj=""
  fi
  command -v train_is_train >/dev/null 2>&1 \
    || { [ -r "${BASH_SOURCE[0]%/*}/train-shape.sh" ] && . "${BASH_SOURCE[0]%/*}/train-shape.sh"; }
  if [ -z "$pj" ]; then
    out=$(printf 'default\t-\tpr-unreadable')
  elif [[ ",$labels," == *,fix-main-red,* ]]; then
    out=$(printf 'hotfix\t-\tfix-main-red')
  elif command -v train_is_train >/dev/null 2>&1 && train_is_train "$title" "$ref"; then
    out=$(printf 'default\t-\ttrain')
  else
    [ -n "$files" ] && command -v mc_pr_files >/dev/null 2>&1 && mc_pr_files "$slug" "$num" "" "$head" > "$files" 2>/dev/null
    if [ -n "$list" ]; then
      if cache=$(_qff_tick_file flake-fix-list) && [ -r "$cache" ]; then cat "$cache" > "$list" 2>/dev/null
      else qff_list "$root" > "$list"; [ -n "$cache" ] && _qff_put "$cache" < "$list"; fi
    fi
    out=$(qff_decide "$files" "$list" "$QFF_SCOPE_GLOBS")
  fi
  [ -n "$files" ] && rm -f "$files"
  [ -n "$list" ] && rm -f "$list"
  IFS=$'\t' read -r route suite reason <<<"$out"
  [ "$QFF_MODE" = shadow ] && note=" (would route $route)"
  _qff_log "QFLAKE $slug#$num@${head:0:12} suite=${suite:--} queue=$route mode=$QFF_MODE$note reason=${reason:--}"
  [ "$QFF_MODE" = enforce ] || return 0
  case "$reason" in pr-unreadable|fix-main-red|train) return 0 ;; esac
  if [ "$route" = flake-fix ]; then
    [[ ",$labels," == *",$label,"* ]] && return 0
    err=$(gh api -X POST "repos/$slug/issues/$num/labels" -f "labels[]=$label" 2>&1 >/dev/null) \
      || _qff_log "QFLAKE $slug#$num: label $label could not be added ($(head -1 <<<"$err")) — it queues in default"
  elif [[ ",$labels," == *",$label,"* ]]; then
    enc=$(jq -rn --arg l "$label" '$l | @uri')
    err=$(gh api -X DELETE "repos/$slug/issues/$num/labels/$enc" 2>&1 >/dev/null) \
      || _qff_log "QFLAKE $slug#$num: stale label $label could not be removed ($(head -1 <<<"$err"))"
  fi
  return 0
}
