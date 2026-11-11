# shellcheck shell=bash
# bin/blocked-resolver.d/bh-9369-closed-pr-retire.sh — BH-9369 fix 1: a park
# whose PR is closed or merged on GitHub leaves the candidate list in the
# pre-pass, and is skipped in discovery from the next tick.
#
# WHY. br_prepass retired a row only from its RECORD (br_finished): a park of a
# PR that merged elsewhere (a person merged it, or a rebuild landed under
# another PR) kept its record open, and every br_one quiet exit (unchanged,
# pr-hold, fix-round, HELD, STALLED) returned before any merged check. On
# 2026-11-09 project-6#289 was merged and still OVERDUE, offered first on
# every tick, for 38,960 minutes.
#
# ONE READ PER PROJECT PER TICK. bcr_load pages the repo's CLOSED pull list,
# newest update first, and stops at the last tick's newest `updated_at` minus
# 600 s, so the steady state is one page. The answers are kept in a per-project
# store, a depth-1 dotfile the record globs ($ST/*/*.json) never read:
#
#   $ST/.closed-prs-<project>.tsv
#     #wm\t<ISO updated_at of the newest item of the last complete read>
#     <n>\t<merged|closed>\t<closed_at ISO>\t<retired 0|1>
#
# The watermark moves only after a complete read. A row older than
# BR_CLOSED_PR_KEEP_DAYS (by closed_at) is pruned on a rewrite: its retire
# was already marked by then.
#
# THE RETIRE IS KEYED BY PR URL, NOT BY TICKET. The record is the ticket's, and
# another open PR of the same ticket must keep its ladder (BH-8339). So the
# record is not flagged: the store row's `retired` column remembers that the
# event line was said, and it feeds the BH-9029 discovery skip (_BDI_RURL).
#
# WHAT IS NOT RETIRED: an open or reopened PR (in br_open_prs: the veto); a
# `rebuild-*` row (the resolver closes a PR to rebuild it, and the rebuild is
# still owed); a closed-unmerged PR while the open list is unreadable (it may
# have been reopened; a merge is final, so a merged PR still retires); a url
# of another repo, or of no PR at all.
#
# Knobs (catalog/lanes.d/blocked-resolver.knobs.d/):
#   BR_CLOSED_PR_MAX_PAGES  30  pages per read; 0 = no read, this fix is off
#   BR_CLOSED_PR_KEEP_DAYS  90  store rows kept by closed_at age; 0 = keep all
#   BR_CLOSED_PR_OVERLAP_SECS 600 a read stops at the last read's newest updated_at minus this; 0 = no overlap
# Call sites, one line each in the driver: before RAW=$(br_candidates)
# (bcr_load), in br_prepass (bcr_prepass_row), after the pre-pass
# (bcr_commit). BR_OPT_OFF=bh-9369-closed-pr-retire does not source this
# file; each call site then does what it did before.

# bcr_knob <name> <default> — a non-negative integer knob, checked. The value
#   goes to $_BCR_KNOB. A value that is not a number is said once per run and
#   the default is used.
bcr_knob() {
  local n="$1" d="$2" v
  v="${!n:-$d}"
  case "$v" in
    ''|*[!0-9]*)
      case " ${_BCR_KNOB_SAID:-} " in
        *" $n "*) ;;
        *) say "$n is '$v', not a number — the fallback $d is used"
           _BCR_KNOB_SAID="${_BCR_KNOB_SAID:-} $n" ;;
      esac
      v="$d" ;;
  esac
  _BCR_KNOB="$v"
  return 0
}

# bcr_store <project> — the store path.
bcr_store() { printf '%s/.closed-prs-%s.tsv' "$ST" "$1"; }

# bcr_load — fill the arrays for this run's project (or every fleet project).
#   _BCR_CLOSED[<pr url>]  merged|closed
#   _BCR_OPEN[<pr url>]    1 when the PR is open now (the reopen veto)
#   _BCR_OPENBAD[<slug>]   1 when the open list could not be read
#   _BCR_SLUG[<project>]   the project's repo slug
#   _BCR_RET[<pr url>]     1 when the store row is already retired (said once)
# Fail-open: no slug, no read and no store leave the arrays empty, and the
# pre-pass runs as it did before.
#   It also makes $BCR_RETIRED_OUT, the pre-pass's retired-url file (the
#   driver's EXIT trap removes it), unless the caller already set one.
bcr_load() {
  declare -gA _BCR_CLOSED=() _BCR_OPEN=() _BCR_OPENBAD=() _BCR_SLUG=() _BCR_RET=()
  local p
  [ -n "${BCR_RETIRED_OUT:-}" ] || BCR_RETIRED_OUT=$(mktemp "${TMPDIR:-/tmp}/br-bcr-ret.XXXXXX" 2>/dev/null) || BCR_RETIRED_OUT=""
  if [ -n "${ONLY:-}" ]; then
    bcr_load_one "$ONLY"
  else
    while read -r p; do
      [ -n "${p:-}" ] || continue
      bcr_load_one "$p"
    done < <("$H/bin/fleet-conf.sh" --projects 2>/dev/null)
  fi
  return 0
}

# bcr_load_one <project> — the read, the merge and the arrays for one project.
bcr_load_one() {
  local p="$1" slug store maxp keep overlap wm="" cut="" kcut="" k rc tmp pg new newwm="" stop
  local list n word cat ret url pn pmin pmax
  local -A rows=()
  bcr_knob BR_CLOSED_PR_MAX_PAGES 30; maxp="$_BCR_KNOB"
  bcr_knob BR_CLOSED_PR_KEEP_DAYS 90; keep="$_BCR_KNOB"
  bcr_knob BR_CLOSED_PR_OVERLAP_SECS 600; overlap="$_BCR_KNOB"
  [ "$maxp" -gt 0 ] || return 0
  slug=$("$H/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
  case "$slug" in
    ''|-|*[!A-Za-z0-9._/-]*|*/*/*) say "$p: no repo slug — the closed-PR read is skipped, no park of it is retired by PR state this tick"; return 0 ;;
  esac
  _BCR_SLUG["$p"]="$slug"
  store=$(bcr_store "$p")
  # THE STORED SET. A line that does not have the row shape is ignored.
  if [ -r "$store" ]; then
    while IFS=$'\t' read -r n word cat ret; do
      if [ "$n" = "#wm" ]; then wm="$word"; continue; fi
      case "$n" in ''|*[!0-9]*) continue ;; esac
      case "$word" in merged|closed) ;; *) continue ;; esac
      case "$ret" in 1) ;; *) ret=0 ;; esac
      rows["$n"]="$word	${cat:--}	$ret"
    done < "$store"
  fi
  case "$wm" in [0-9][0-9][0-9][0-9]-*T*Z) cut=$(date -u -d "${wm/T/ } - $overlap seconds" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) ;; *) wm="" ;; esac
  br_use_token "$slug"
  tmp=$(mktemp "${TMPDIR:-/tmp}/br-bcr.XXXXXX" 2>/dev/null) || tmp=""
  stop=""; k=0; new=0
  if [ -z "$tmp" ]; then
    stop="no scratch file"
  else
    while [ "$k" -lt "$maxp" ]; do
      k=$((k+1))
      rc=0
      gh_rest GET "repos/$slug/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=$k" > "$tmp" 2>/dev/null || rc=$?
      if [ "$rc" != 0 ]; then
        stop="page $k (HTTP ${GH_REST_STATUS:-000}, rc $rc)"; break
      fi
      # One jq pass: the rows, then one `#min <updated_at>` and `#max` line.
      pg=$(jq -r '# bcr-closed-page (BH-9369)
              if type != "array" then error("not an array") else . end
              | (map(select((.number|type) == "number")) ) as $a
              | ($a[] | [ (.number|tostring),
                          (if .merged_at != null then "merged" else "closed" end),
                          ((.closed_at // "-") | tostring),
                          ((.updated_at // "") | tostring) ] | @tsv),
                ("#n\t" + ($a | length | tostring)),
                ("#min\t" + ([ $a[].updated_at // empty ] | min // "")),
                ("#max\t" + ([ $a[].updated_at // empty ] | max // ""))' "$tmp" 2>/dev/null) \
        || { stop="page $k (the answer is not a PR list)"; break; }
      pn=0; pmin=""; pmax=""
      while IFS=$'\t' read -r n word cat _; do
        case "$n" in
          '#n') pn="$word"; continue ;;
          '#min') pmin="$word"; continue ;;
          '#max') pmax="$word"; continue ;;
          ''|*[!0-9]*) continue ;;
        esac
        ret=0
        [ -n "${rows["$n"]:-}" ] && ret="${rows["$n"]##*	}"
        rows["$n"]="$word	${cat:--}	$ret"
        new=$((new+1))
      done <<<"$pg"
      if [ -n "$pmax" ] && { [ -z "$newwm" ] || [[ "$pmax" > "$newwm" ]]; }; then newwm="$pmax"; fi
      [ "$pn" -gt 0 ] 2>/dev/null || break
      [ -n "$cut" ] && [ -n "$pmin" ] && [[ "$pmin" < "$cut" ]] && break
      [ "$pn" -ge 100 ] || break
    done
    rm -f "$tmp"
  fi
  if [ -n "$stop" ]; then
    say "closed-PR read for $slug stopped at $stop — the stored set still applies, the watermark stays"
    newwm="$wm"
  fi
  [ -n "$newwm" ] || newwm="$wm"
  # THE PRUNE, by closed_at age. ISO stamps of one shape compare as strings.
  [ "$keep" -gt 0 ] && kcut=$(date -u -d "@$(( $(date -u +%s) - keep * 86400 ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
  if [ -z "$stop" ] || [ "$new" -gt 0 ]; then
    bcr_write "$store" "$newwm" "$kcut" rows || say "$store: the closed-PR store was not written — the next tick reads GitHub from the old watermark"
  fi
  # THE ARRAYS. The open list is the veto; br_open_prs is the run's cached read.
  if list=$(br_open_prs "$slug"); then
    while IFS= read -r url; do
      [ -n "$url" ] && _BCR_OPEN["$url"]=1
    done < <(printf '%s' "$list" | jq -r '.[]? | (.url // empty)' 2>/dev/null)
  else
    _BCR_OPENBAD["$slug"]=1
  fi
  for n in "${!rows[@]}"; do
    IFS=$'\t' read -r word cat ret <<<"${rows["$n"]}"
    [ -n "$kcut" ] && [ "$cat" != "-" ] && [[ "$cat" < "$kcut" ]] && continue
    url="https://github.com/$slug/pull/$n"
    _BCR_CLOSED["$url"]="$word"
    [ "$ret" = 1 ] && _BCR_RET["$url"]=1
    # BH-9029's discovery skip: a row already retired is not discovered again.
    if [ "$ret" = 1 ] && [ "${_BDI_OK:-0}" = 1 ] && [ -z "${_BCR_OPEN["$url"]:-}" ]; then
      _BDI_RURL["$url"]=1
    fi
  done
  br_reset_token
  return 0
}

# bcr_write <store> <wm> <prune-cut ISO or ""> <assoc-array name> — atomic rewrite.
bcr_write() {
  local store="$1" wm="$2" kcut="$3" n word cat ret tmp
  local -n _bcr_rows="$4"
  tmp="$store.tmp.$$"
  {
    printf '#wm\t%s\n' "${wm:-}"
    for n in "${!_bcr_rows[@]}"; do
      IFS=$'\t' read -r word cat ret <<<"${_bcr_rows["$n"]}"
      [ -n "$kcut" ] && [ "$cat" != "-" ] && [[ "$cat" < "$kcut" ]] && continue
      printf '%s\t%s\t%s\t%s\n' "$n" "$word" "$cat" "$ret"
    done | LC_ALL=C sort -n
  } > "$tmp" 2>/dev/null && mv -f "$tmp" "$store" 2>/dev/null && return 0
  rm -f "$tmp" 2>/dev/null
  return 1
}

# bcr_is_closed <url> <reason> — rc 0 and $_BCR_WORD (merged|closed) when this
#   row's PR is closed on GitHub and the row may leave the list. Pure array
#   lookups: it runs inside the pre-pass subshell, which inherits the arrays.
bcr_is_closed() {
  local url="${1:-}" reason="${2:-}" w slug
  _BCR_WORD=""
  case "$url" in https://github.com/*/*/pull/*) ;; *) return 1 ;; esac
  [[ "$url" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$ ]] || return 1
  w="${_BCR_CLOSED["$url"]:-}"
  [ -n "$w" ] || return 1
  [ -z "${_BCR_OPEN["$url"]:-}" ] || return 1
  case "$reason" in rebuild-*) return 1 ;; esac
  slug="${url#https://github.com/}"; slug="${slug%/pull/*}"
  if [ "$w" != merged ] && [ -n "${_BCR_OPENBAD["$slug"]:-}" ]; then return 1; fi
  _BCR_WORD="$w"
  return 0
}

# bcr_said <url> — rc 0 when the store row of this PR is already retired: the
#   event line was said on an earlier tick. Pure.
bcr_said() { [ -n "${_BCR_RET["${1:-}"]:-}" ]; }

# bcr_prepass_row — br_prepass's one call, per keyed row. rc 0 when the row's
#   PR is closed or merged on GitHub: the row is counted (the pre-pass's $n),
#   its build record marked (bdi_mark_build), the event said once, and the
#   pre-pass drops the row. rc 1: the row goes on as before. It reads the
#   pre-pass's locals (src rec url reason key rkey ck) by bash's dynamic scope.
#   The record is the ticket's and is not flagged (BH-8339): the store row is.
bcr_prepass_row() {
  bcr_is_closed "${url:--}" "${reason:-}" || return 1
  n=$((n+1))
  command -v bdi_mark_build >/dev/null 2>&1 && bdi_mark_build "$src" "$rec" "$_BCR_WORD" </dev/null
  if ! bcr_said "${url:--}"; then
    if [ "${OBSERVE:-0}" = 1 ]; then say "$key/$rkey [$reason]: WOULD retire — PR is $_BCR_WORD — observe mode"
    else br_event resolver_retired "$key" "$ck" "$reason" "PR is $_BCR_WORD — dropped from the candidate list, no rung" </dev/null
         bcr_note_retired "${url:--}"; fi
  fi
  return 0
}

# bcr_note_retired <url> — one url per line in $BCR_RETIRED_OUT (the pre-pass
#   runs inside $(...), so the parent reads the file).
#   The url is also marked said in this shell: a PR two sources report (a
#   conductor row and a review row) gets one event line, not two.
bcr_note_retired() {
  [ -n "${1:-}" ] && _BCR_RET["$1"]=1
  [ -n "${BCR_RETIRED_OUT:-}" ] && printf '%s\n' "${1:-}" >> "$BCR_RETIRED_OUT" 2>/dev/null
  return 0
}

# bcr_commit — parent shell, after the pre-pass: `retired=1` on the store rows
#   the pre-pass named. Observe mode writes nothing.
bcr_commit() {
  [ -n "${BCR_RETIRED_OUT:-}" ] && [ -s "$BCR_RETIRED_OUT" ] || return 0
  [ "${OBSERVE:-0}" = 1 ] && return 0
  local p url
  local -A want=()
  while IFS= read -r url; do [ -n "$url" ] && want["$url"]=1; done < "$BCR_RETIRED_OUT"
  for p in "${!_BCR_SLUG[@]}"; do
    bcr_commit_one "$(bcr_store "$p")" "${_BCR_SLUG["$p"]}" want
  done
  return 0
}

# bcr_commit_one <store> <slug> <want-array name> — one store's rewrite.
bcr_commit_one() {
  local store="$1" slug="$2" n word cat ret wm="" changed=0
  local -n _bcr_want="$3"
  local -A rows=()
  [ -r "$store" ] || return 0
  while IFS=$'\t' read -r n word cat ret; do
    if [ "$n" = "#wm" ]; then wm="$word"; continue; fi
    case "$n" in ''|*[!0-9]*) continue ;; esac
    case "$word" in merged|closed) ;; *) continue ;; esac
    case "$ret" in 1) ;; *) ret=0 ;; esac
    if [ "$ret" = 0 ] && [ -n "${_bcr_want["https://github.com/$slug/pull/$n"]:-}" ]; then ret=1; changed=1; fi
    rows["$n"]="$word	${cat:--}	$ret"
  done < "$store"
  [ "$changed" = 1 ] || return 0
  bcr_write "$store" "$wm" "" rows \
    || say "$store: the retired marks were not written — these rows are retired again next tick"
  return 0
}
