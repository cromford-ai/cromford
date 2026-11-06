#!/bin/bash
# bin/lib/shard-building.sh — BH-9113: the triage shard dispatcher skips a key
# that has a running build. Sourced by bin/lib/rt/shards.sh, never executed.
# Defines functions only: no `set -e`, no `exit`, nothing runs at source time.
# Doc: docs/TRIAGE-STATE.md, "Shard skip for a running build (BH-9113)".
#
# WHY. project-3 TK-698 got a triage shard at 20:36, 20:46, 20:56, 21:06 and
# 21:16Z on 2026-11-05. Each one ended in bin/triage-shard.sh with `claim
# refused: ticket :: ticket max 1 already running`, because a build held the
# ticket. The dispatcher had spent a slot on it every tick, and the slot was
# lost. bin/triage-shard.sh's refusal stays as the backstop.
#
#   shard_building_census <harness> <project> <out>
#     ONE read per tick: job_builds_running (bin/lib/jobs/jobs.sh), written to
#     <out> as its TSV (`id ticket_key meta_ticket_id box kind`). A failed read
#     writes `#unreadable` (the caller logs it once and skips nothing). No jobs
#     client loaded: an empty file.
#   shard_building_why <harness> <project> <gh> <census> <key>
#     rc 0 and the reason on stdout when <key> has a running build: a census
#     row whose ticket_key or meta ticket id is <key> (on a GitHub board, also
#     a ticket_key `<PFX>-<key>`), or a held locks/build-key-<p>-<key>.lock (on
#     a GitHub board, also build-key-<p>-<PFX>-<key>.lock). rc 1 otherwise.
#     A dotted child (TK-698.2) or a longer number (TK-6980) is not TK-698.
# shellcheck shell=bash

shard_building_census() {
  local p="${2:-}" out="${3:-}" rows
  [ -n "$p" ] && [ -n "$out" ] || return 0
  : > "$out" 2>/dev/null || return 0
  command -v job_builds_running >/dev/null 2>&1 || return 0
  if rows=$(job_builds_running "$p" 2>/dev/null); then
    [ -n "$rows" ] && printf '%s\n' "$rows" > "$out"
  else
    printf '#unreadable\n' > "$out"
  fi
  return 0
}

# _sb_held <lockfile> — rc 0 when some process holds this flock
_sb_held() {
  command -v triage_shard_held >/dev/null 2>&1 && { triage_shard_held "$1"; return; }
  [ -e "$1" ] || return 1
  ( exec 9>"$1" || exit 0; flock -n 9 || exit 1 ) 2>/dev/null && return 1
  return 0
}

shard_building_why() {
  local h="${1:-}" p="${2:-}" gh="${3:-0}" c="${4:-}" k="${5:-}" r pfx=""
  case "$k" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  if [ -s "$c" ]; then
    r=$(awk -F'\t' -v k="$k" -v gh="$gh" '
      /^#/ { next }
      $2 == k || $3 == k || (gh == 1 && k ~ /^[0-9]+$/ && $2 ~ ("^[A-Za-z]+-" k "$")) { print $1 "\t" $4; exit }' "$c" 2>/dev/null)
    if [ -n "$r" ]; then printf 'jobs ledger: build %s on %s' "${r%%$'\t'*}" "${r#*$'\t'}"; return 0; fi
  fi
  [ -n "$h" ] && [ -n "$p" ] || return 1
  if _sb_held "$h/locks/build-key-$p-$k.lock"; then printf 'local build-key lock held'; return 0; fi
  if [ "$gh" = 1 ] && command -v _ts_prefix >/dev/null 2>&1; then
    case "$k" in *[!0-9]*) ;; *) pfx=$(HARNESS="$h" _ts_prefix "$p") ;; esac
    if [ -n "$pfx" ] && _sb_held "$h/locks/build-key-$p-$pfx-$k.lock"; then printf 'local build-key lock held'; return 0; fi
  fi
  return 1
}
