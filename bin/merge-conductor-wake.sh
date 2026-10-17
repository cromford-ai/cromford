#!/bin/bash
# bin/merge-conductor-wake.sh — MERGE CONDUCTOR WAKE CONSUMER (BH-6975, wave 2
# of BH-6545). A PR event (`pr` wake: pull_request, review, PR comment) or a
# check answer (`checks` wake: check_run, check_suite, status, workflow_run) is a
# wake row written by POST /webhooks/github (worker/jobs core.js wakeOf). Every
# minute this hub lane reads the pr and checks wakes above its own cursor and,
# for each one of an open harness PR, starts the conductor's keyed tick for that
# PR only (MC_ONLY_PR=<owner/repo>#<n>, through kw_conductor in
# bin/lib/keyed-wake.sh). The keyed tick takes the conductor's PR lock itself.
# The 5-minute backstop (411) and the 30-minute full tick (410) stay.
#
# THE CURSOR, NOT A CLAIM. POST /api/wakes/claim marks every row it returns as
# taken, so a wake the budget did not reach would be gone. The lane reads
# GET /api/wakes?since=<cursor> (one unfiltered read; the route takes one kind
# only) and keeps its own watermark in wake_cursors (box `merge-conductor-wake`,
# PUT is MAX-monotonic), as bin/repair-on-push.sh does. The cursor never passes
# a wake that is not complete. When no wake was held and the list came back
# under its limit, the cursor moves to the max id read BEFORE the list. The
# first tick with no cursor row plants it at max id and does nothing else.
# bin/wake-loop.sh still claims the same rows under its own box.
#
# WHICH PR. A pr wake's key is the PR number. A checks wake's key is a head sha:
# it maps through state/merge-conductor/pr-state.tsv (open rows only, prefix
# match both ways, 7-char floor), else one wck_sha_prs read (GET
# commits/<sha>/pulls), at most MC_WAKE_SHA_LOOKUPS a tick. A repo no fleet.conf
# project owns, or a `not-harness <key>` line in state/merge-conductor/
# attempts.txt (the conductor's own verdict), is skipped. Every other PR gets
# the keyed tick and the conductor makes the final call (mc_is_harness_pr).
#
# BUDGET AND CARRY. At most MC_WAKE_BUDGET keyed ticks start a tick. A wake the
# budget does not reach is `hold budget`: the loop stops and the wake stays
# above the cursor for the next minute. kw_conductor answers rc 1 when a keyed
# tick for that PR started less than MC_WAKE_MIN_S ago (its stamp, shared with
# the conductor's other ringers). That tick can have read the PR before this
# event, so the key goes to state/merge-conductor-wake/carry.tsv
# (`<slug>#<n> TAB <event> TAB <at> TAB <wake id>`, one line per key, the first
# `at` kept) and is paid first on the next tick. A wake or carry line older than
# MC_WAKE_MAX_AGE_S is skipped `stale`: the backstop and the full tick own it.
#
# BH-7139: every minute this lane also starts one bin/mc-keyed-pool.sh drain
# (the keyed-tick queue backstop) and runs mc_tick_clock_check (one alert for a
# cron full tick older than 2 x MC_FULL_TICK_PERIOD_S).
#
# Knobs (catalog/lanes.d/merge-conductor-wake.json, settings rows
# lane.merge-conductor-wake.<env>): MC_WAKE_BUDGET (10), MC_WAKE_WAKES (100),
# MC_WAKE_MIN_S (30), MC_WAKE_MAX_AGE_S (900), MC_WAKE_SHA_LOOKUPS (5). Off:
# flags/lane-off-merge-conductor-wake, all-off, a factory stop,
# automerge-disabled, lane-off-merge-conductor, lane.merge-conductor.mc_keyed_wake=0.
#
# ONE LINE PER DECISION -> logs/merge-conductor-wake-cron.log:
#   WAKE pr=<n|-> event=<ev> latency_s=<s|-> repo=<slug> wake=<id|carry> action=tick|skip|carry|hold reason=<r>
# latency_s = now - the wake row's `at` (the worker's receipt of the webhook).
# action=tick means the detached keyed tick was STARTED, not that the PR moved.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$HARNESS/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null || true
LANE=merge-conductor-wake
LOG="$HARNESS/logs/merge-conductor-wake-cron.log"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
say() { mkdir -p "$HARNESS/logs" 2>/dev/null; echo "$(STAMP) [merge-conductor-wake] $1" >> "$LOG"; }

# shellcheck source=bin/lib/lane-gate.sh
. "$HARNESS/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit merge-conductor-wake
command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply merge-conductor-wake
# shellcheck source=bin/jobs-client.sh
. "$HARNESS/bin/jobs-client.sh" 2>/dev/null || { say "jobs-client did not load — nothing to do"; exit 0; }
command -v jq >/dev/null 2>&1 || { say "jq missing — nothing to do"; exit 0; }
command -v flag_active >/dev/null 2>&1 || { say "flag_active missing — nothing to do"; exit 0; }
# The same stand-downs as the conductor backstop: no line.
flag_active automerge-disabled && exit 0
flag_active lane-off-merge-conductor && exit 0
MC_KEYED_WAKE=1
command -v lane_knob >/dev/null 2>&1 && MC_KEYED_WAKE=$(lane_knob merge-conductor MC_KEYED_WAKE)
if [ "$MC_KEYED_WAKE" = 0 ]; then
  say "keyed wakes off (lane.merge-conductor.mc_keyed_wake=0) — nothing done"; exit 0
fi
export MC_KEYED_WAKE
[ -x "$HARNESS/bin/merge-conductor.sh" ] || { say "bin/merge-conductor.sh not executable — nothing done"; exit 0; }

# DEDUPE, NEVER A QUEUE: a tick that finds the previous one running exits.
mkdir -p "$HARNESS/locks" 2>/dev/null
exec 8>"$HARNESS/locks/merge-conductor-wake.lock" || exit 0
flock -n 8 || exit 0

knob() { # knob <ENV> <default> — digits only, else the default with one line
  local v=""
  command -v lane_knob >/dev/null 2>&1 && v=$(lane_knob "$LANE" "$1")
  case "$v" in ''|*[!0-9]*) [ -n "$v" ] && say "$1='$v' is not a number — using $2"; v="$2" ;; esac
  printf '%s' "$v"
}
BUDGET=$(knob MC_WAKE_BUDGET 10)
NWAKES=$(knob MC_WAKE_WAKES 100)
[ "$NWAKES" -ge 1 ] || NWAKES=1
MIN_S=$(knob MC_WAKE_MIN_S 30)
MAX_AGE=$(knob MC_WAKE_MAX_AGE_S 900)
LOOKUPS=$(knob MC_WAKE_SHA_LOOKUPS 5)

# THE KEYED POOL BACKSTOP (BH-7139): a keyed tick waits in
# state/merge-conductor/keyed-queue while every MC_KEYED_MAX_PARALLEL slot is
# busy. A slot holder drains it when its tick ends; this one detached drain a
# minute is the backstop, so a queued entry never waits on a lost drain.
if [ -x "$HARNESS/bin/mc-keyed-pool.sh" ]; then
  ( MC_H="$HARNESS" setsid "$HARNESS/bin/mc-keyed-pool.sh" drain </dev/null >/dev/null 2>&1 9>&- 8>&- 7>&- 6>&- 5>&- 4>&- & ) 2>/dev/null
fi
# THE FULL-TICK CLOCK (BH-7139): one alert when a live cron full tick is older
# than 2 x MC_FULL_TICK_PERIOD_S (lane.merge-conductor.mc_full_tick_period_s).
# shellcheck source=bin/lib/mc-tick-clock.sh
if [ -r "$HARNESS/bin/lib/mc-tick-clock.sh" ] && . "$HARNESS/bin/lib/mc-tick-clock.sh"; then
  FTP=1800
  command -v lane_knob >/dev/null 2>&1 && FTP=$(lane_knob merge-conductor MC_FULL_TICK_PERIOD_S)
  case "$FTP" in ''|*[!0-9]*) FTP=1800 ;; esac
  mc_tick_clock_check "$HARNESS" "$FTP" | while IFS= read -r L; do say "$L"; done
fi

# shellcheck source=bin/lib/keyed-wake.sh
[ -r "$HARNESS/bin/lib/keyed-wake.sh" ] && . "$HARNESS/bin/lib/keyed-wake.sh"
command -v kw_conductor >/dev/null 2>&1 || { say "kw_conductor not available — nothing done"; exit 0; }
# shellcheck source=bin/lib/gh-app-auth.sh
[ -r "$HARNESS/bin/lib/gh-app-auth.sh" ] && . "$HARNESS/bin/lib/gh-app-auth.sh"
# shellcheck source=bin/lib/wake-conductor-keys.sh
[ -r "$HARNESS/bin/lib/wake-conductor-keys.sh" ] && . "$HARNESS/bin/lib/wake-conductor-keys.sh"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/merge-conductor-wake.XXXXXX") || { say "mktemp failed — nothing done"; exit 0; }
trap 'rm -rf "$TMP"' EXIT

# The cursor. max id first, so a wake written during this tick stays above it.
MAX=$(_jobs_req GET "/api/wakes/cursor?all=1" | jq -er '.max_id | select(type == "number") | floor' 2>/dev/null)
case "$MAX" in ''|*[!0-9]*) say "worker unreachable (wake cursor) — nothing done"; exit 0 ;; esac
CUR=$(wake_cursor_get "$LANE") || { say "worker unreachable (cursor read) — nothing done"; exit 0; }
if [ -z "$CUR" ]; then
  if wake_cursor_put "$LANE" "$MAX"; then say "first tick — cursor planted at $MAX, no keyed tick"
  else say "first tick — cursor PUT failed, retrying next tick"; fi
  exit 0
fi

if ! _jobs_req GET "/api/wakes?since=$CUR&limit=$NWAKES" > "$TMP/wakes.json" \
   || ! jq -e '(.wakes | type) == "array"' "$TMP/wakes.json" >/dev/null 2>&1; then
  say "worker unreachable (wake list) — cursor stays at $CUR"; exit 0
fi
jq -r '.wakes[] | [(.id|tostring), (.repo // "-"), (.kind // "-"), ((.key // "-")|tostring), (.event // "-"), (.at // "-")]
  | map(if . == "" then "-" else gsub("[\t\n]"; " ") end) | @tsv' "$TMP/wakes.json" > "$TMP/wakes.tsv" 2>/dev/null
NREAD=$(grep -c . "$TMP/wakes.tsv")

# project <TAB> slug <TAB> lower-case slug, for every fleet project.
for p in $("$HARNESS/bin/fleet-conf.sh" --projects 2>/dev/null); do
  s=$("$HARNESS/bin/fleet-conf.sh" "$p" repo 2>/dev/null)
  [ -n "$s" ] && printf '%s\t%s\t%s\n' "$p" "$s" "$(printf '%s' "$s" | tr '[:upper:]' '[:lower:]')"
done > "$TMP/projects.tsv"
# lower-case key <TAB> lower-case head, for every pr-state.tsv row still open.
awk -F'\t' '$2 != "MERGED" && $2 != "CLOSED" && $2 != "ABANDONED" && length($4) >= 7 {
    print tolower($1) "\t" tolower($4) }' "$HARNESS/state/merge-conductor/pr-state.tsv" > "$TMP/heads.tsv" 2>/dev/null
# The conductor's own "not a harness PR" verdicts, lower-case keys.
# `not-harness-unread` is not one: that body was never read.
awk '$1 == "not-harness" && NF >= 2 { print tolower($2) }' \
  "$HARNESS/state/merge-conductor/attempts.txt" > "$TMP/notharness" 2>/dev/null
: > "$TMP/started"; : > "$TMP/carry.new"

# MC_WAKE_NOW (epoch seconds) is a test seam for the clock; unset in production.
NOW="${MC_WAKE_NOW:-}"; case "$NOW" in ''|*[!0-9]*) NOW=$(date -u +%s) ;; esac
age_of() { # age_of <at> — seconds since <at>, or `-` when unknown
  local s
  [ -n "${1:-}" ] && [ "$1" != - ] || { echo -; return; }
  s=$(date -u -d "$1" +%s 2>/dev/null) || { echo -; return; }
  echo $((NOW - s))
}
# line <pr> <event> <at> <repo> <wake> <action> <reason>
line() { say "WAKE pr=$1 event=$2 latency_s=$(age_of "$3") repo=$4 wake=$5 action=$6 reason=$7"; }
stale() { local a; a=$(age_of "$1"); [ "$a" != - ] && [ "$a" -gt "$MAX_AGE" ]; }

USED=0; CARRIED=0
# launch <slug> <n> <event> <at> <wake> — rc 0 done (started, skipped or
# carried), rc 1 budget spent (nothing started, nothing written).
launch() {
  local slug="$1" n="$2" ev="$3" at="$4" w="$5"
  if grep -qxF "$slug#$n" "$TMP/started"; then line "$n" "$ev" "$at" "$slug" "$w" skip done-this-tick; return 0; fi
  [ "$USED" -lt "$BUDGET" ] || return 1
  if MC_KEYED_WAKE_MIN_S="$MIN_S" kw_conductor "$slug" "$n" "wake $w $ev"; then
    USED=$((USED+1)); echo "$slug#$n" >> "$TMP/started"
    line "$n" "$ev" "$at" "$slug" "$w" tick started
  else
    carry "$slug#$n" "$ev" "$at" "$w"
    line "$n" "$ev" "$at" "$slug" "$w" carry deduped
  fi
  return 0
}
carry() { # carry <key> <event> <at> <wake> — one line per key, the first kept
  cut -f1 "$TMP/carry.new" | grep -qxF "$1" && return 0
  printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" >> "$TMP/carry.new"
  CARRIED=$((CARRIED+1))
}

# CARRY FIRST: the keys a deduped launch owed from earlier ticks.
CDIR="$HARNESS/state/merge-conductor-wake"
if [ -s "$CDIR/carry.tsv" ]; then
  while IFS=$'\t' read -r K EV AT WID; do
    [[ "$K" =~ ^([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)#([0-9]+)$ ]] || continue
    S="${BASH_REMATCH[1]}"; NUM="${BASH_REMATCH[2]}"
    if stale "$AT"; then line "$NUM" "$EV" "$AT" "$S" carry skip stale; continue; fi
    if ! launch "$S" "$NUM" "$EV" "$AT" carry; then
      carry "$K" "$EV" "$AT" "$WID"; line "$NUM" "$EV" "$AT" "$S" carry hold budget
    fi
  done < "$CDIR/carry.tsv"
fi

# THE WAKES, in id order.
PC=0; HELD=""; LASTDONE="$CUR"; NLOOK=0
while IFS=$'\t' read -r WID REPO KIND KEY EV AT; do
  case "$KIND" in
    pr|checks) PC=$((PC+1)) ;;
    *) LASTDONE="$WID"; continue ;;
  esac
  LREPO=$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')
  SLUG=$(awk -F'\t' -v s="$LREPO" '$3==s {print $2; exit}' "$TMP/projects.tsv")
  PRN=-; [ "$KIND" = pr ] && PRN="$KEY"
  if [ -z "$SLUG" ]; then line "$PRN" "$EV" "$AT" "$REPO" "$WID" skip unowned-repo; LASTDONE="$WID"; continue; fi
  if { [ "$KIND" = pr ] && ! [[ "$KEY" =~ ^[0-9]+$ ]]; } || { [ "$KIND" = checks ] && ! [[ "$KEY" =~ ^[0-9a-f]{7,64}$ ]]; }; then
    line "$PRN" "$EV" "$AT" "$SLUG" "$WID" skip no-key; LASTDONE="$WID"; continue
  fi
  if stale "$AT"; then line "$PRN" "$EV" "$AT" "$SLUG" "$WID" skip stale; LASTDONE="$WID"; continue; fi

  # The PR number(s) this wake names.
  : > "$TMP/nums"
  if [ "$KIND" = pr ]; then
    echo "$KEY" > "$TMP/nums"
  else
    awk -F'\t' -v r="$LREPO" -v s="$KEY" '{ k=$1; rp=k; sub(/#[^#]*$/, "", rp)
        if (rp == r && (index($2, s) == 1 || index(s, $2) == 1)) { n=k; sub(/.*#/, "", n); print n } }' \
      "$TMP/heads.tsv" | awk '!seen[$0]++' > "$TMP/nums"
    if [ ! -s "$TMP/nums" ]; then
      if [ "$NLOOK" -ge "$LOOKUPS" ] || ! command -v wck_sha_prs >/dev/null 2>&1; then
        line - "$EV" "$AT" "$SLUG" "$WID" skip sha-unplaced; LASTDONE="$WID"; continue
      fi
      NLOOK=$((NLOOK+1))
      GOT=$(wck_sha_prs "$LREPO" "$KEY" </dev/null); RC=$?
      case "$RC" in
        0) printf '%s\n' "$GOT" | sed 's/.*#//' > "$TMP/nums" ;;
        1) line - "$EV" "$AT" "$SLUG" "$WID" skip no-open-pr; LASTDONE="$WID"; continue ;;
        *) line - "$EV" "$AT" "$SLUG" "$WID" skip sha-unplaced; LASTDONE="$WID"; continue ;;
      esac
    fi
  fi

  STARTED_ANY=""
  while read -r NUM; do
    [[ "$NUM" =~ ^[0-9]+$ ]] || continue
    LKEY=$(printf '%s#%s' "$LREPO" "$NUM")
    if grep -qxF "$LKEY" "$TMP/notharness"; then line "$NUM" "$EV" "$AT" "$SLUG" "$WID" skip not-harness; continue; fi
    if launch "$SLUG" "$NUM" "$EV" "$AT" "$WID"; then STARTED_ANY=1; continue; fi
    # Budget spent. Nothing of this wake started yet: hold it. Part of it
    # started (a sha that heads two PRs): carry the rest, the wake is complete.
    if [ -z "$STARTED_ANY" ]; then HELD=1; break; fi
    carry "$SLUG#$NUM" "$EV" "$AT" "$WID"; line "$NUM" "$EV" "$AT" "$SLUG" "$WID" carry budget
  done < "$TMP/nums"
  if [ -n "$HELD" ]; then
    line "$NUM" "$EV" "$AT" "$SLUG" "$WID" hold budget; break
  fi
  LASTDONE="$WID"
done < "$TMP/wakes.tsv"

if [ -z "$HELD" ] && [ "$NREAD" -lt "$NWAKES" ] && [ "$MAX" -gt "$LASTDONE" ]; then LASTDONE="$MAX"; fi
if [ "$LASTDONE" -gt "$CUR" ] && ! wake_cursor_put "$LANE" "$LASTDONE"; then
  say "cursor PUT $LASTDONE failed — the next tick reads those wakes again (kw_conductor dedupes)"
fi

# The carry, written whole: a crash leaves the old file.
mkdir -p "$CDIR" 2>/dev/null
if CT=$(mktemp "$CDIR/carry.XXXXXX" 2>/dev/null); then
  cat "$TMP/carry.new" > "$CT" && mv -f "$CT" "$CDIR/carry.tsv" || rm -f "$CT"
else
  say "carry file not writable in $CDIR — $CARRIED carried key(s) fall to the backstop"
fi
say "tick wakes=$NREAD pc=$PC ticks=$USED carried=$CARRIED budget=$BUDGET cursor=$LASTDONE (ticks = keyed ticks started)"
exit 0
