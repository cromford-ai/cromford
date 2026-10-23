#!/bin/bash
# shellcheck shell=bash
# bin/lib/lead-unread.sh — BH-8081: a lead review round that bought no
# readable verdict does not spend the head's only paid call, and a head that
# stays guard-blocked with no verdict raises ONE alert keyed by the LR key.
# Sourced by bin/lead-review.sh through
# bin/lib/lead-review/libs.d/202610231206-bh-8081-lead-unread.sh. Functions
# only, no side effect at source. Needs the host's log, lead_fp
# (bin/lib/review-bought.sh), lr_body_reason (bin/lib/lead-reviews.sh) and
# lr_guard_spent (bin/lib/lead-review/attempts.sh); $H is the harness.
#
# The extra call is a named reason on the lead-head guard key (the BH-3930
# pattern): `~unread`, or `~unbody<D>` on a changed body (BH-5888). The D1
# call-guard (K=1 on lead-head, CALL_GUARD_WINDOW_S) caps it at 1 per head per
# window, so this lib holds no cap. The evidence that the paid round was
# unreadable is a paid `~noverdict` (`~nvbody<D>`) key: review_one buys that
# retry only when the first answer had no readable verdict. It is a D1 fact, so
# it survives the .empty delete of a reset request and a move to another box.
#
# Knobs (catalog/lanes.d/lead-review.knobs.d/):
#   LEAD_REVIEW_UNREAD_RETRY        1 = the extra paid call (default), 0 = off
#   LEAD_REVIEW_GUARD_ALERT_TICKS   guard-blocked ticks before the alert (2), 0 = off

# _lu_log <text> — the host's log, else stderr.
_lu_log() { if command -v log >/dev/null 2>&1; then log "$*"; else echo "lead-unread: $*" >&2; fi; }

# _lu_knob <env> <default> <min> <max> — the integer value of knob <env>. Empty
#   is the default; a value that is not an integer in min..max is one log line
#   and the default.
_lu_knob() {
  local v="${!1:-}"
  if [ -z "$v" ]; then printf '%s' "$2"; return 0; fi
  if [[ "$v" =~ ^[0-9]{1,9}$ ]] && [ "$((10#$v))" -ge "$3" ] && [ "$((10#$v))" -le "$4" ]; then
    printf '%s' "$((10#$v))"; return 0
  fi
  _lu_log "$1='$v' is not an integer in $3..$4; using $2 (BH-8081)"
  printf '%s' "$2"
}

# lu_extra_fp <project> <repo> <pr> <sha> <bchg> <bfp> — rc 0 and LU_FP = the
#   extra lead-head guard key when LEAD_REVIEW_UNREAD_RETRY=1, the unreadable
#   evidence key is paid and the extra key is not. Else rc 1, LU_FP empty and
#   LU_WHY = off | no-unread-evidence | extra-spent. An evidence peek that
#   cannot be read is no-unread-evidence: nothing is spent on an unknown. The
#   keys follow review_one: <bchg>=1 with a good <bfp> = the body keys.
lu_extra_fp() {
  local p="$1" repo="$2" pr="$3" sha="$4" ev un rsn
  LU_FP=""; LU_WHY=""
  if [ "$(_lu_knob LEAD_REVIEW_UNREAD_RETRY 1 0 1)" != 1 ]; then LU_WHY=off; return 1; fi
  if ! command -v lead_fp >/dev/null 2>&1 || ! command -v lr_guard_spent >/dev/null 2>&1; then
    LU_WHY=no-unread-evidence; return 1
  fi
  if [ "${5:-0}" = 1 ] && rsn=$(lr_body_reason "${6:-}" nv); then
    ev=$(lead_fp "$repo" "$pr" "$sha" "$rsn"); un=$(lead_fp "$repo" "$pr" "$sha" "un${rsn#nv}")
  else
    ev=$(lead_fp "$repo" "$pr" "$sha" noverdict); un=$(lead_fp "$repo" "$pr" "$sha" unread)
  fi
  lr_guard_spent "$p" "$ev" >/dev/null || { LU_WHY=no-unread-evidence; return 1; }
  if lr_guard_spent "$p" "$un" >/dev/null; then LU_WHY=extra-spent; return 1; fi
  LU_FP="$un"
}

# lu_alert <project> <repo> <pr> <sha> <fp> <why> — one warn through
#   bin/lane-alert.sh with the id lead-noverdict-<owner_repo>-<pr>-<sha12>
#   (lane-alert's state machine sends an open id once). The text names the
#   recovery command for the guard key <fp>. A failed alert is one log line.
lu_alert() {
  local id="lead-noverdict-${2//\//_}-$3-${4:0:12}" rc=0
  "$H/bin/lane-alert.sh" --severity warn --id "$id" lead-review \
    "LEAD REVIEW NO VERDICT: $2#$3@${4:0:12}: $6. No readable lead verdict and no paid call left on this head for the call-guard window. Recover: bin/jobs-client.sh call-guard-reset $1 lead-head \"$5\" \"<reason>\" (BH-8081)" \
    >/dev/null 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then _lu_log "lr-$3-${4:0:12}: alert $id ($6)"
  else _lu_log "lr-$3-${4:0:12}: lane-alert for $id failed (rc=$rc)"; fi
}

# _lu_prune <dir> <window_s> — remove the *.gblock markers older than the window.
_lu_prune() { find "$1" -maxdepth 1 -type f -name '*.gblock' -mmin +"$(( ($2 + 59) / 60 ))" -delete 2>/dev/null; }

# lu_guard_blocked <project> <repo> <pr> <sha> <key> <fp> <paid> — one
#   guard-blocked tick with no verdict. Prunes markers older than
#   CALL_GUARD_WINDOW_S, adds 1 to state/lead-reviews/<key>.gblock (one integer
#   line), and alerts when LU_WHY (from lu_extra_fp) is extra-spent or the count
#   reaches LEAD_REVIEW_GUARD_ALERT_TICKS (0 = no alert). The count is written
#   before the alert, so a failed alert is sent again on the next blocked tick.
lu_guard_blocked() {
  local d="$H/state/lead-reviews" f n ticks win why=""
  win="${CALL_GUARD_WINDOW_S:-86400}"; case "$win" in ''|*[!0-9]*) win=86400 ;; esac
  mkdir -p "$d" 2>/dev/null; _lu_prune "$d" "$win"
  f="$d/$5.gblock"
  n=$(head -n 1 "$f" 2>/dev/null); [[ "$n" =~ ^[0-9]{1,9}$ ]] || n=0; n=$((10#$n + 1))
  printf '%s\n' "$n" > "$f.tmp.$$" && mv -f "$f.tmp.$$" "$f" || _lu_log "$5: could not write $f"
  ticks=$(_lu_knob LEAD_REVIEW_GUARD_ALERT_TICKS 2 0 48)
  _lu_log "$5: guard-blocked with no readable verdict on $6 (paid $7, ${LU_WHY:-unknown}), tick $n; alert at ${ticks} (0 = off)"
  [ "$ticks" -gt 0 ] || return 0
  if [ "${LU_WHY:-}" = extra-spent ]; then why="extra paid call already spent"
  elif [ "$n" -ge "$ticks" ]; then why="guard-blocked $n ticks"; fi
  [ -z "$why" ] || lu_alert "$1" "$2" "$3" "$4" "$6" "$why"
}
