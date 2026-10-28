#!/bin/bash
# bin/lib/split-chain.sh — BH-1655: a merged split child makes the next sibling
# launchable on a POLLING board. Sourced, never executed. Defines functions
# only: no `set -e`, nothing runs on source.
#
# WHY. On an in-app board nothing re-read a chained split child after its
# earlier sibling merged. bin/unblocked-children.sh exits for every in-app board
# (no Blocked-by convention), no in-app board serves `dependsOn` yet (BH-815),
# and the merged child's board status is `review`, so the fingerprint did not
# move. bin/triage-gate.sh answered `SKIP no-change` every tick while project-3's
# TK-202 waited 50 minutes on a TK-201 that had already merged.
#
# WHAT IT READS — build records on THIS box, no model and no board call:
#   builds/<p>-<PARENT>-*/RESULT line 1 `DECOMPOSED k1,k2,...`, in LAND ORDER
#     (bin/run-decompose.sh writes children.txt "IN THE ORDER THEY SHOULD LAND").
#   builds/<p>-<CHILD>-*/RESULT line 1 `PR_MERGED <url>` / `PR_CREATED <url>`
#     (pool results are staged into the same shape by bin/lib/rt/staging.sh).
#   state/<p>.keymap.json — the key<->id map of the board's OPEN tickets.
#
# DUE. A child is due when it is listed after the first key of a DECOMPOSED
# line younger than SPLIT_CHAIN_LOOKBACK_S, EVERY earlier key in that line is
# merged, it is open on the board (in the keymap), it is idle (no PR/DECOMPOSED/
# ROLLOUT_FILED result, no build dir without a RESULT, build lock not held), and
# it has not been offered within SPLIT_CHAIN_REMIND_S. "Every earlier sibling"
# is a superset of any real dependency: it can under-wake a genuinely parallel
# wave, never offer a child whose real blocker is unmerged.
#
# MERGED means a merged PR, never a board status: `PR_MERGED` in a RESULT, the
# positive cache state/split-chain/<p>/merged/<SIB>, or a REST read of the
# newest PR_CREATED url (same repo as fleet.conf's, case-insensitive) answering
# `merged`. Any error, cap, low budget, foreign repo, open or closed = NOT
# merged, and nothing is cached — so a failure leaves today's behaviour.
#
# STATE (box-local on purpose — the RESULTs it derives from are box-local):
#   state/split-chain/<p>/offered/<CHILD>  epoch; the dedupe/remind watermark
#   state/split-chain/<p>/merged/<SIB>     PR number; a merge cannot un-merge
#   state/split-ready-keys-<p>             one-shot, consumed by the tick scope
#
# KNOBS (catalog/lanes.d/_lib.json `split-chain`, resolved through
# lib_env_apply; the numbers below are the documented fallback only):
#   SPLIT_CHAIN_REMIND_S (21600)  SPLIT_CHAIN_LOOKBACK_S (1209600)
#   SPLIT_CHAIN_MAX_LOOKUPS (10)  — GitHub reads per pass
# KILL SWITCH: split-chain-off, read by lane_switch (bin/lib/lane-switch.sh,
# BH-2439): a settings row switch.split-chain-off[.<box>] answers first, and
# flags/split-chain-off only when there is no row. ON = the gate and the scope
# behave as before.
# shellcheck shell=bash

_SC_LIBDIR=$(dirname "${BASH_SOURCE[0]}")
_SC_APPLIED=0

# split_chain_on <harness> -> prints 1 or 0
split_chain_on() {
  command -v lane_switch >/dev/null 2>&1 || . "$_SC_LIBDIR/lane-switch.sh" 2>/dev/null \
    || lane_switch() { [ -f "${HARNESS:-/root/harness}/flags/$1" ]; }
  if HARNESS="${1:-/root/harness}" lane_switch split-chain-off file; then echo 0; else echo 1; fi
}

# _sc_knobs — sets _SC_REMIND/_SC_LOOKBACK/_SC_MAXL in THIS shell. The settings
# contract is applied once per process (the gh-policy-cache.sh idiom).
_sc_knobs() {
  if [ "$_SC_APPLIED" = 0 ]; then
    _SC_APPLIED=1
    if ! command -v lib_env_apply >/dev/null 2>&1; then
      # shellcheck source=bin/lib/lane-gate.sh
      [ -r "$_SC_LIBDIR/lane-gate.sh" ] && . "$_SC_LIBDIR/lane-gate.sh"
    fi
    command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply split-chain
  fi
  _SC_REMIND="${SPLIT_CHAIN_REMIND_S:-21600}"
  _SC_LOOKBACK="${SPLIT_CHAIN_LOOKBACK_S:-1209600}"
  _SC_MAXL="${SPLIT_CHAIN_MAX_LOOKUPS:-10}"
  case "$_SC_REMIND" in ''|*[!0-9]*) _SC_REMIND=21600 ;; esac
  case "$_SC_LOOKBACK" in ''|*[!0-9]*) _SC_LOOKBACK=1209600 ;; esac
  case "$_SC_MAXL" in ''|*[!0-9]*) _SC_MAXL=10 ;; esac
  return 0
}

_sc_log() { # _sc_log <harness> <project> <text>
  mkdir -p "$1/logs" 2>/dev/null
  echo "$(date -u '+%Y-%m-%d %H:%M:%SZ') [$2] $3" >> "$1/logs/$2.log" 2>/dev/null
  return 0
}

_sc_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }

# _sc_dirs <harness> <project> <KEY> — this key's own build dirs, one per line.
# `<p>-<KEY>-*` cannot match a longer key: TK-20's glob needs a `-` where
# TK-202 has a `2`.
_sc_dirs() {
  local d
  for d in "$1/builds/$2-$3-"*/ "$1/builds/pool-$2-$3-"*/; do
    [ -d "$d" ] && printf '%s\n' "${d%/}"
  done
  return 0
}

# _sc_idle <harness> <project> <KEY> — rc 0 when nothing covers this key yet.
_sc_idle() {
  local d l lock
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -f "$d/RESULT" ] || return 1          # a build in flight
    l=""; IFS= read -r l < "$d/RESULT" 2>/dev/null
    case "$l" in PR_CREATED*|PR_MERGED*|DECOMPOSED*|ROLLOUT_FILED*|WEBTASK_QUEUED*) return 1 ;; esac
  done < <(_sc_dirs "$1" "$2" "$3")
  lock="$1/locks/build-key-$2-$3.lock"
  if [ -e "$lock" ]; then
    ( exec 9>>"$lock" || exit 1; flock -n 9 ) 2>/dev/null || return 1
  fi
  return 0
}

# _sc_budget_ok — rc 0 when the shared GitHub budget is not low. Asked once
# per pass (_SC_BUDGET), bin/triage-gate.sh's idiom: gh_budget_low rc 0 = low.
_sc_budget_ok() {
  if [ -z "${_SC_BUDGET:-}" ]; then
    if ( [ -r "$_SC_LIBDIR/gh-budget.sh" ] || exit 2
         # shellcheck source=bin/lib/gh-budget.sh
         . "$_SC_LIBDIR/gh-budget.sh"; gh_budget_low split-chain ) >/dev/null 2>&1; then
      _SC_BUDGET=low
    else
      _SC_BUDGET=ok
    fi
  fi
  [ "$_SC_BUDGET" = ok ]
}

# _sc_open_pr <harness> <project> <CHILD> <slug> — BH-3949: open_pr_for_key's
# rc (bin/lib/open-pr-precheck.sh, BH-3948), and _SC_PR_N its `#<n>` on a hit.
# Charged its worst case, 2 reads, against the pass's _SC_READS/_SC_MAXL up
# front. No slug, low budget, the cap, or no contract lib = rc 2, so the child
# is offered exactly as before.
_sc_open_pr() {
  local rc
  _SC_PR_N=""
  [ -n "${4:-}" ] || return 2
  _sc_budget_ok || return 2
  if [ $(( _SC_READS + 2 )) -gt "$_SC_MAXL" ]; then
    _SC_CAPPED=1; return 2
  fi
  if ! command -v open_pr_for_key >/dev/null 2>&1; then
    # shellcheck source=bin/lib/open-pr-precheck.sh
    . "$_SC_LIBDIR/open-pr-precheck.sh" 2>/dev/null || :
    command -v open_pr_for_key >/dev/null 2>&1 || return 2
  fi
  _SC_READS=$((_SC_READS + 2))
  rc=0; _SC_PR_N=$(open_pr_for_key "$4" "$3" 2>/dev/null) || rc=$?
  return "$rc"
}

# _sc_merged <harness> <project> <SIB> <slug> — rc 0 merged; sets _SC_PR to the
# PR number (or empty). Counts GitHub reads in _SC_READS against _SC_MAXL.
_sc_merged() {
  local h="$1" p="$2" k="$3" slug="$4" d l url newest="" nt=0 t n rslug st mk rc
  _SC_PR=""
  mk="$h/state/split-chain/$p/merged/$k"
  while IFS= read -r d; do
    [ -n "$d" ] && [ -f "$d/RESULT" ] || continue
    l=""; IFS= read -r l < "$d/RESULT" 2>/dev/null
    case "$l" in
      "PR_MERGED "*)
        url=$(printf '%s' "${l#PR_MERGED }" | awk '{print $1}')
        _SC_PR=$(printf '%s' "$url" | sed -nE 's#^https://github\.com/[^/]+/[^/]+/pull/([0-9]+).*#\1#p')
        return 0 ;;
      "PR_CREATED "*)
        t=$(_sc_mtime "$d/RESULT")
        [ "$t" -ge "$nt" ] 2>/dev/null && { nt="$t"; newest="$l"; } ;;
    esac
  done < <(_sc_dirs "$h" "$p" "$k")
  if [ -f "$mk" ]; then
    _SC_PR=$(tr -dc '0-9' < "$mk" 2>/dev/null); return 0
  fi
  [ -n "$newest" ] && [ -n "$slug" ] || return 1
  url=$(printf '%s' "${newest#PR_CREATED }" | awk '{print $1}')
  rslug=$(printf '%s' "$url" | sed -nE 's#^https://github\.com/([^/]+/[^/]+)/pull/[0-9]+([/?#].*)?$#\1#p')
  n=$(printf '%s' "$url" | sed -nE 's#^https://github\.com/[^/]+/[^/]+/pull/([0-9]+)([/?#].*)?$#\1#p')
  [ -n "$rslug" ] && [ -n "$n" ] || return 1
  [ "$(printf '%s' "$rslug" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]')" ] || return 1
  _sc_budget_ok || return 1
  if [ "$_SC_READS" -ge "$_SC_MAXL" ]; then
    _SC_CAPPED=1; return 1
  fi
  if ! command -v gh_rest_pr_state_var >/dev/null 2>&1; then
    # shellcheck source=bin/lib/gh-rest.sh
    [ -r "$_SC_LIBDIR/gh-rest.sh" ] && . "$_SC_LIBDIR/gh-rest.sh" 2>/dev/null
    command -v gh_rest_pr_state_var >/dev/null 2>&1 || return 1
  fi
  _SC_READS=$((_SC_READS + 1))
  st=""; rc=0
  gh_rest_pr_state_var st "$slug" "$n" 2>/dev/null || rc=$?
  [ "$rc" = 0 ] && [ "$st" = merged ] || return 1
  mkdir -p "${mk%/*}" 2>/dev/null && printf '%s\n' "$n" > "$mk" 2>/dev/null
  _SC_PR="$n"
  return 0
}

# split_chain_due <harness> <project> [--any-offer]
# Prints `<CHILD>\t<PARENT>\t<dep>=<#pr|merged>,...` per due child. With
# --any-offer the remind window is not checked (the scope re-verifies keys the
# gate has just stamped). Always rc 0.
split_chain_due() {
  local h="${1:-}" p="${2:-}" anyoff="${3:-}" km slug now r l parent keys k i j c ok deps memo="" \
        seen=" " off m
  [ -n "$h" ] && [ -n "$p" ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  km="$h/state/$p.keymap.json"
  jq -e 'type == "object"' "$km" >/dev/null 2>&1 || return 0
  _sc_knobs
  slug=$("$h/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || slug=""
  now=$(date +%s)
  _SC_READS=0; _SC_CAPPED=0; _SC_BUDGET=""
  for r in "$h/builds/$p-"*/RESULT "$h/builds/pool-$p-"*/RESULT; do
    [ -f "$r" ] || continue
    l=""; IFS= read -r l < "$r" 2>/dev/null
    case "$l" in "DECOMPOSED "*) ;; *) continue ;; esac
    [ $(( now - $(_sc_mtime "$r") )) -le "$_SC_LOOKBACK" ] || continue
    parent=${r%/RESULT}; parent=${parent##*/}; parent=${parent#pool-}; parent=${parent#"$p"-}
    parent=$(printf '%s' "$parent" | sed -nE 's/^([A-Za-z]+-[0-9]+).*/\1/p')
    keys=()
    while IFS= read -r k; do
      k=$(printf '%s' "$k" | tr -d '[:space:]')
      grep -qE '^[A-Za-z]+-[0-9]+$' <<<"$k" && keys+=("$k")
    done < <(printf '%s\n' "${l#DECOMPOSED }" | tr ',' '\n')
    for (( i = 1; i < ${#keys[@]}; i++ )); do
      c="${keys[$i]}"
      case "$seen" in *" $c "*) continue ;; esac
      # Cheap, local checks first; a GitHub read is the last thing asked.
      jq -e --arg k "$c" 'has($k)' "$km" >/dev/null 2>&1 || continue
      _sc_idle "$h" "$p" "$c" || continue
      if [ "$anyoff" != "--any-offer" ]; then
        off=$(tr -dc '0-9' < "$h/state/split-chain/$p/offered/$c" 2>/dev/null)
        [ -n "$off" ] && [ $(( now - off )) -lt "$_SC_REMIND" ] && continue
      fi
      ok=1; deps=""
      for (( j = 0; j < i; j++ )); do
        k="${keys[$j]}"
        case "$memo" in
          *" $k=0 "*) ok=0; break ;;
          *" $k=1:"*) m=${memo#*" $k=1:"}; m=${m%% *} ;;
          *)
            if _sc_merged "$h" "$p" "$k" "$slug"; then
              m="$_SC_PR"; memo="$memo $k=1:$m "
            else
              memo="$memo $k=0 "; ok=0; break
            fi ;;
        esac
        deps="${deps:+$deps,}$k=${m:+#$m}"
        [ -n "$m" ] || deps="${deps}merged"
      done
      [ "$ok" = 1 ] || continue
      seen="$seen$c "
      printf '%s\t%s\t%s\n' "$c" "${parent:-?}" "$deps"
    done
  done
  [ "$_SC_CAPPED" = 1 ] && _sc_log "$h" "$p" "split-chain: lookup cap hit ($_SC_MAXL GitHub reads) — the rest read not-merged this pass"
  return 0
}

# split_chain_gate <harness> <project> — the gate's step 1c. For each due child:
# BH-3949 first asks whether an open PR already covers it (SPLIT_DEFER, the
# remind watermark written, not offered); otherwise the offered marker FIRST (so
# two observers of one merge make one offer), then the one-shot keys file, then
# one SPLIT_READY log line. Prints the offered keys space-separated; nothing
# when none is due or every due key was deferred.
split_chain_gate() {
  local h="${1:-}" p="${2:-}" due c parent deps out="" now tf slug capped=0
  # split_chain_due runs in THIS shell, not a $( ), so the open-PR reads below
  # share its pass's _SC_READS against _SC_MAXL.
  tf=$(mktemp "${TMPDIR:-/tmp}/split-chain-due.XXXXXX" 2>/dev/null) || tf=""
  if [ -n "$tf" ]; then
    split_chain_due "$h" "$p" > "$tf"; due=$(cat "$tf" 2>/dev/null); rm -f "$tf"
  else
    due=$(split_chain_due "$h" "$p") || due=""
    _sc_knobs; _SC_READS="$_SC_MAXL"   # reads made unknown: no open-PR read
  fi
  [ -n "$due" ] || return 0
  now=$(date +%s)
  mkdir -p "$h/state/split-chain/$p/offered" 2>/dev/null || return 0
  slug=$("$h/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || slug=""
  while IFS=$'\t' read -r c parent deps; do
    [ -n "$c" ] || continue
    _SC_CAPPED=0
    if _sc_open_pr "$h" "$p" "$c" "$slug"; then
      printf '%s\n' "$now" > "$h/state/split-chain/$p/offered/$c" 2>/dev/null
      _sc_log "$h" "$p" "SPLIT_DEFER $c open-pr $_SC_PR_N - paid_avoided"
      # shellcheck source=bin/lib/triage-park.sh
      command -v triage_park_note >/dev/null 2>&1 || . "$_SC_LIBDIR/triage-park.sh" 2>/dev/null || :
      command -v triage_park_note >/dev/null 2>&1 && triage_park_note "$h" "$p" "$c" "skip split-defer open-pr $_SC_PR_N"
      continue
    fi
    [ "$_SC_CAPPED" = 1 ] && capped=1
    printf '%s\n' "$now" > "$h/state/split-chain/$p/offered/$c" 2>/dev/null || continue
    printf '%s\n' "$c" >> "$h/state/split-ready-keys-$p" 2>/dev/null || continue
    _sc_log "$h" "$p" "SPLIT_READY $c (after $deps)"
    out="${out:+$out }$c"
  done <<<"$due"
  [ "$capped" = 1 ] && _sc_log "$h" "$p" "split-chain: lookup cap hit ($_SC_MAXL GitHub reads) — open-PR check skipped, key(s) offered unchecked this pass"
  [ -n "$out" ] && printf '%s\n' "$out"
  return 0
}

# split_chain_take_lines <harness> <project> — the tick's half. Reads and
# DELETES state/split-ready-keys-<p> (one-shot), re-verifies every key, and
# prints one gate-diff-shaped `board split: UNBLOCKED <CHILD> ...` line per key
# still due. A keys file older than the remind window is deleted unread.
split_chain_take_lines() {
  local h="${1:-}" p="${2:-}" f keys due c parent deps id title
  [ -n "$h" ] && [ -n "$p" ] || return 0
  [ "$(split_chain_on "$h")" = 1 ] || return 0
  f="$h/state/split-ready-keys-$p"
  [ -e "$f" ] || return 0
  _sc_knobs
  if [ $(( $(date +%s) - $(_sc_mtime "$f") )) -gt "$_SC_REMIND" ]; then
    rm -f "$f"; return 0
  fi
  keys=$(grep -E '^[A-Za-z]+-[0-9]+$' "$f" 2>/dev/null | awk '!seen[$0]++')
  rm -f "$f"
  [ -n "$keys" ] || return 0
  due=$(split_chain_due "$h" "$p" --any-offer) || due=""
  while IFS=$'\t' read -r c parent deps; do
    [ -n "$c" ] || continue
    grep -qxF -- "$c" <<<"$keys" || continue
    id=$(jq -r --arg k "$c" '.[$k] // empty' "$h/state/$p.keymap.json" 2>/dev/null) || id=""
    title=""
    [ -n "$id" ] && title=$(jq -r --arg id "$id" \
      '[.[]? | .[]? | select(type == "object") | select((.id | tostring) == $id) | .title // ""][0] // "" | gsub("[\\n\\t\\r]"; " ")' \
      "$h/state/$p.gate.json" 2>/dev/null)
    printf 'board split: UNBLOCKED %s "%s" (%s — split sibling of %s, dependency %s merged: its earlier siblings'"'"' PRs are merged; fetch it and launch per the queue rules if no PR or build already covers it. If you do not launch it this tick, write ONE line `SPLIT_DEFER %s :: <reason>` in your output)\n' \
      "$c" "$title" "$c" "$parent" "$deps" "$c"
  done <<<"$due"
  return 0
}

# split_chain_key_merged <harness> <project> <KEY> — BH-3825: the public form of
# _sc_merged for bin/lib/gate-release.sh. One fresh pass per call (reads, cap
# and budget reset here), so the caller bounds its own calls. Prints the PR
# number (maybe empty) and returns 0 when merged; rc 1 otherwise.
split_chain_key_merged() {
  local h="${1:-}" p="${2:-}" k="${3:-}" slug
  [ -n "$h" ] && [ -n "$p" ] && [ -n "$k" ] || return 1
  _sc_knobs
  slug=$("$h/bin/fleet-conf.sh" "$p" repo 2>/dev/null) || slug=""
  _SC_READS=0; _SC_CAPPED=0; _SC_BUDGET=""
  _sc_merged "$h" "$p" "$k" "$slug" || return 1
  printf '%s\n' "$_SC_PR"
}
