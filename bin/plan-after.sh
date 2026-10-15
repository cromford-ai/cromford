#!/bin/bash
# bin/plan-after.sh — THE `After:` HOLD (BH-4988, wave 3 of BH-4975).
#
# WHY. When bin/plan-overlap.sh finds that a fresh plan needs a file an
# in-flight build already claims, the build stands down (BUILD_DEFERRED) with a
# ten-minute not-before. That floor alone is a spend loop: every ten minutes the
# ticket is re-offered, a whole PLAN session is bought, and it stands down again
# against the same sibling, about six paid plans per hour of sibling build. This
# records WHICH build the ticket is waiting for, and the free pre-PLAN gate
# (`# >>> overlap not-before` in bin/lib/rb/gates.sh) asks here before a plan
# is bought: the ticket is held until that build is finished AND has no open PR
# (merged, or dropped). Nothing is written to the issue: `After:` is a harness
# record, never a `Blocked-by:` line.
#
# usage:
#   plan-after.sh record <project> <KEY> "<OVERLAP_DEFER line>"
#     Writes state/overlap-after/<project>/<KEY> = "<OTHER>\t<epoch>" (tmp+mv),
#     prints `PLAN_HOTSPOT <KEY> choice=after after=<OTHER> fold=not-offered
#     files=[..]` and appends it to logs/plan-hotspot.log.
#     rc 0 written, rc 1 not written (bad line, bad key).
#   plan-after.sh check <project> <KEY>
#     rc 0  build: no marker (file or fleet row); or it expired (PLAN_AFTER_MAX_MIN, default 360,
#           0 = never; stdout is then `EXPIRED <OTHER>`, BH-6292); or a mutual pair released the byte-smaller key; or OTHER
#           is finished with no open PR (marker removed); or the PR question
#           was unreadable (marker KEPT, `choice=unjudged`: plan-overlap
#           re-judges at plan time, which is the behaviour before this file).
#     rc 3  hold. stdout is `AFTER <OTHER> <why>`, why = `in flight`,
#           `PR #<n> open` or `mutual`.
#   Every choice except a hold is one PLAN_HOTSPOT line on stderr and in
#   logs/plan-hotspot.log.
#
# PENDING(OTHER) is any of: its claim file state/claims/<project>/<OTHER>; a
# build dir builds/<project>-<OTHER>-<stamp> with no RESULT touched in the last
# 240 minutes (plan-overlap's liveness rule); its job_claims row through
# fclaim_list_dir (only when bin/jobs-client.sh and bin/lib/file-claims.sh
# load); an open PR through bin/lib/open-pr-precheck.sh. Only open_pr_for_key
# rc 1 is a clean "no PR"; rc 2 (unreadable) is never read as one. A
# job_claims outage is NOT treated the same way: it adds no hold, so with the
# local reads clean and open_pr_for_key rc 1 the marker is released. That costs
# at most one PLAN, where plan-overlap judges the overlap again from scratch.
#
# WHERE THE HOLD IS READ FROM. The marker file first. When this box has none
# (a pool machine is a fresh rootfs on every re-offer), the key's newest
# `overlap_defer` job artifact is read back from the fleet, and a `deferred`
# row whose detail says `choice:"after"` is the same hold, logged `src=fleet`.
# That row cannot be removed from here, so a release on it is re-judged (and
# released again) next time. No marker and no fleet answer (jobs ledger down,
# no client) is no hold: the ten-minute not-before floor is what is left.
#
# KILL FLAG: plan-overlap's own. OVERLAP_SCHED=0 (env or env/global.env), or
# lane_switch plan-overlap-off. Either one exits 0 before reading or writing.
set -uo pipefail
MODE="${1:-}"; PROJECT="${2:-}"; KEY="${3:-}"
HARNESS="${HARNESS:-/root/harness}"
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/env-path.sh
. "$HERE/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$HARNESS}/env"; }
GENV="$(harness_env_dir "$HARNESS")/global.env"

case "$MODE" in record|check) ;; *) echo "usage: plan-after.sh record|check <project> <KEY> [line]" >&2; exit 2 ;; esac

# Keys and the project become path segments.
valid_key() { [[ "${1:-}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] && [ "$1" != . ] && [ "$1" != .. ]; }

_sched="${OVERLAP_SCHED:-}"
if [ -z "$_sched" ] && [ -r "$GENV" ]; then
  _sched=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}OVERLAP_SCHED=//p' "$GENV" \
             | tr -d "\"' \t" | tail -1)
fi
case "$(printf '%s' "${_sched:-1}" | tr '[:upper:]' '[:lower:]')" in 0|off|false|no) exit 0 ;; esac
# shellcheck source=bin/lib/lane-switch.sh
. "$HERE/lib/lane-switch.sh" 2>/dev/null || true
command -v lane_switch >/dev/null 2>&1 || lane_switch() { [ -f "$HARNESS/flags/$1" ]; }   # no lib: the file, as before
lane_switch plan-overlap-off && exit 0

if ! valid_key "$PROJECT" || ! valid_key "$KEY"; then
  echo "plan-after: refusing project/key '$PROJECT'/'$KEY'" >&2
  [ "$MODE" = record ] && exit 1
  exit 0
fi
DIR="$HARNESS/state/overlap-after/$PROJECT"
F="$DIR/$KEY"
OUTFD=2; [ "$MODE" = record ] && OUTFD=1
hotspot() { # hotspot <rest> — one choice line, to stdout (record) / stderr (check) and the log
  local line="PLAN_HOTSPOT $KEY $*"
  printf '%s\n' "$line" >&"$OUTFD"
  mkdir -p "$HARNESS/logs" 2>/dev/null && printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$line" >> "$HARNESS/logs/plan-hotspot.log" 2>/dev/null
  return 0
}

if [ "$MODE" = record ]; then
  LINE="${4:-}"
  read -r W1 _ _ OTHER _ <<< "$LINE"
  if [ "${W1:-}" != OVERLAP_DEFER ] || ! valid_key "${OTHER:-}" || [ "$OTHER" = "$KEY" ]; then
    echo "plan-after: not recording, cannot read a valid other key from: $LINE" >&2
    exit 1
  fi
  FILES=$(printf '%s' "$LINE" | grep -o 'files=\[[^]]*\]' | head -1)
  mkdir -p "$DIR" || exit 1
  TMP=$(mktemp "$DIR/.$KEY.XXXXXX") || exit 1
  if printf '%s\t%s\n' "$OTHER" "$(date -u +%s)" > "$TMP" && mv -f "$TMP" "$F"; then
    hotspot "choice=after after=$OTHER fold=not-offered${FILES:+ $FILES}"
    exit 0
  fi
  rm -f "$TMP"; exit 1
fi

# --- check --------------------------------------------------------------------
# The ceiling first: it is also how far back the fleet read below looks.
command -v lib_env_apply >/dev/null 2>&1 && lib_env_apply plan-hotspot "$PROJECT" >/dev/null 2>&1
MAX="${PLAN_AFTER_MAX_MIN:-}"
if [ -z "$MAX" ] && [ -r "$GENV" ]; then
  MAX=$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}PLAN_AFTER_MAX_MIN=//p' "$GENV" \
          | tr -d "\"' \t" | tail -1)
fi
case "${MAX:-}" in ''|*[!0-9]*) MAX=360 ;; esac
NOW=$(date -u +%s)

# The fleet clients, loaded once: in_flight's job_claims read and the fleet
# marker read below both need them. Missing either is "no fleet answer".
# shellcheck source=/dev/null
[ -r "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" >/dev/null 2>&1
# shellcheck source=bin/lib/file-claims.sh
[ -r "$HARNESS/bin/lib/file-claims.sh" ] && . "$HARNESS/bin/lib/file-claims.sh" >/dev/null 2>&1

# THE MARKER FILE LIVES ON ONE MACHINE, and a pool machine is ephemeral: the
# re-offer of a deferred ticket spawns a fresh one, where the file is not. So
# when this box has no marker, the hold is read back from the fleet: the
# deferring build wrote `{choice:"after",after:<OTHER>}` into its
# `overlap_defer` artifact (`# >>> plan overlap` in bin/lib/rb/gates.sh), the
# same row the not-before block reads its window from. Only the key's NEWEST
# overlap_defer row counts, and only when it is a `deferred` After: row; any
# later row (a `proceeded` verdict, a defer that recorded no After:) ends it.
# THE WINDOW IS WIDER THAN THE CAP (BH-6292 review). The worker returns only
# rows with updated_at > since, and a held ticket writes no new row while it
# waits, so the row's updated_at is when the hold began. Asking for exactly
# the cap window hid every row past the cap: no EXPIRED, and the in-flight
# check started a fresh hold, forever. So the read reaches FEED_SPAN caps back
# and the age test below judges the row. A held ticket is re-offered every few
# minutes, so it is re-checked long before its row leaves that window.
# READ ONLY: a fleet row cannot be removed from here
# (no job is open yet at this gate), so a release re-judges it next time and
# releases again; it never strands a ticket past the ceiling.
FEED_LIMIT=500; FEED_ST=unread; FEED=""; FEED_SPAN=4
fleet_feed() {
  case "$FEED_ST" in ok) return 0 ;; none) return 1 ;; esac
  FEED_ST=none
  command -v job_artifact_feed >/dev/null 2>&1 || return 1
  local since=""
  [ "$MAX" -gt 0 ] && since=$(date -u -d "@$(( NOW - MAX * 60 * FEED_SPAN ))" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null)
  FEED=$(job_artifact_feed overlap_defer "$PROJECT" "$since" "$FEED_LIMIT" 2>/dev/null) || return 1
  FEED_ST=ok
}
fleet_marker() { # fleet_marker <key> -> "<OTHER>\t<epoch>" when that key's newest row is an After: hold
  local row ref upd det after at
  fleet_feed || return 1
  row=$(printf '%s\n' "$FEED" | awk -F'\t' -v k="$1" 'NF >= 6 && $4 == k { print; exit }')
  if [ -z "$row" ]; then
    # D12: a full page that does not name the key cannot rule out an older
    # row. That is not a hold either; plan-overlap re-judges at plan time.
    [ "$(printf '%s\n' "$FEED" | grep -c .)" -ge "$FEED_LIMIT" ] \
      && echo "plan-after: overlap_defer feed for $PROJECT hit its $FEED_LIMIT-row cap without $1; no fleet hold read" >&2
    return 1
  fi
  IFS=$'\t' read -r _ ref _ _ upd det <<< "$row"
  [ "$ref" = deferred ] || return 1
  after=$(printf '%s' "$det" | jq -r 'select(.choice == "after") | .after // empty' 2>/dev/null)
  valid_key "$after" && [ "$after" != "$1" ] || return 1
  # An empty stamp is no hold: GNU date -d "" answers today 00:00Z.
  [ -n "$upd" ] || return 1
  at=$(date -u -d "$upd" +%s 2>/dev/null)
  case "${at:-}" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\t%s\n' "$after" "$at"
}

SRC=local; SRCN=""
if [ -f "$F" ]; then
  IFS=$'\t' read -r OTHER AT _ < "$F" 2>/dev/null
  case "${AT:-}" in ''|*[!0-9]*) AT="" ;; esac
  if ! valid_key "${OTHER:-}" || [ -z "$AT" ]; then
    rm -f "$F"
    hotspot "choice=released after=? (malformed marker, not a hold)"
    exit 0
  fi
else
  FM=$(fleet_marker "$KEY") || exit 0
  IFS=$'\t' read -r OTHER AT <<< "$FM"
  SRC=fleet; SRCN=" src=fleet"
fi
drop() { [ "$SRC" = local ] && rm -f "$F"; return 0; }

if [ "$MAX" -gt 0 ] && [ $(( NOW - AT )) -ge $(( MAX * 60 )) ]; then
  drop
  hotspot "choice=expired after=$OTHER (held $(( (NOW - AT) / 60 ))m, ceiling ${MAX}m)$SRCN"
  echo "EXPIRED $OTHER"
  exit 0
fi

# MUTUAL: both deferred against each other in the same tick. Holding both is a
# deadlock until expiry, so the byte-smaller key goes first. The larger holds
# on the mutual only while OTHER's marker is a FILE here, which OTHER's release
# removes. OTHER's fleet row outlives its release, so against that the larger
# key falls through to the pending check instead: OTHER's own build (claim,
# build dir, job_claims row, PR) is what holds it from then on.
OF="$DIR/$OTHER"
OM_SRC=""; OM=""
if [ -f "$OF" ]; then
  OM=$(cut -f1 "$OF" 2>/dev/null | head -1); OM_SRC=local
else
  OM=$(fleet_marker "$OTHER" | cut -f1); OM_SRC=fleet
fi
if [ -n "$OM" ] && [ "$OM" = "$KEY" ]; then
  LC_ALL=C
  if [[ "$KEY" < "$OTHER" ]]; then
    drop
    hotspot "choice=released after=$OTHER mutual$SRCN"
    exit 0
  fi
  if [ "$OM_SRC" = local ]; then
    echo "AFTER $OTHER mutual"
    exit 3
  fi
fi

# PENDING, cheapest first; the PR read is asked only when nothing local holds.
in_flight() {
  local d n fcd rc=1
  [ -e "$HARNESS/state/claims/$PROJECT/$OTHER" ] && return 0
  for d in "$HARNESS/builds/$PROJECT-$OTHER-"*; do
    [ -d "$d" ] || continue
    n=$(basename "$d")
    [[ "${n#"$PROJECT-$OTHER-"}" =~ ^[0-9]{8,}$ ]] || continue   # not BH-A-1's dir
    [ -f "$d/RESULT" ] && continue
    [ -n "$(find "$d" -maxdepth 1 -mmin -240 -print -quit 2>/dev/null)" ] && return 0
  done
  local fc=""
  for n in fclaim_list_dir fc_list_dir; do command -v "$n" >/dev/null 2>&1 && { fc="$n"; break; }; done
  if [ -n "$fc" ]; then
    fcd=$(mktemp -d) || return 1
    # stderr passes through: FILE_CLAIMS_INCOMPLETE reaches the pipeline.log
    "$fc" "$PROJECT" "$fcd" && [ -e "$fcd/$OTHER" ] && rc=0
    rm -rf "$fcd"
  fi
  return "$rc"
}
if in_flight; then
  echo "AFTER $OTHER in flight"
  exit 3
fi

SLUG=$(FLEET_CONF="${FLEET_CONF:-$HARNESS/fleet.conf}" "$HERE/fleet-conf.sh" "$PROJECT" repo 2>/dev/null) || SLUG=""
# shellcheck source=bin/lib/open-pr-precheck.sh
[ -r "$HERE/lib/open-pr-precheck.sh" ] && . "$HERE/lib/open-pr-precheck.sh" 2>/dev/null
PR_RC=2; PR=""
if [ -n "$SLUG" ] && command -v open_pr_for_key >/dev/null 2>&1; then
  PR=$(open_pr_for_key "$SLUG" "$OTHER" 2>/dev/null); PR_RC=$?
fi
case "$PR_RC" in
  0) echo "AFTER $OTHER PR ${PR:-#?} open"; exit 3 ;;
  1) drop
     hotspot "choice=released after=$OTHER (finished, no open PR)$SRCN"
     exit 0 ;;
  *) hotspot "choice=unjudged after=$OTHER (open-PR read unavailable; plan-overlap re-judges at plan time)$SRCN"
     exit 0 ;;
esac
