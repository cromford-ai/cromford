#!/bin/bash
# bin/rules-drift-check.sh [--strict] — hub-side proof that every box's live
# Claude Code config still matches the repo.
#
# Why (SDLC item 5, 2026-08-29): the machine-wide /root/.claude/CLAUDE.md was
# made repo-managed on 2026-08-14 (rules/CLAUDE.md, rendered by update-runners
# at 05:17Z), after three boxes were found building client software under a
# 2.5KB ruleset while hub carried 12.4KB. RTK.md joined it 08-22 and
# settings.json 08-23. That closed the drift — but nothing PROVES it stays
# closed, and every failure mode here is silent:
#
#   - update-runners.sh can die before the render. It already has: an npm ENOSPC
#     on the fresh project-1 box (2026-08-23) skipped rules, settings.json, RTK.md
#     and the crontab in one go, and the only evidence was an absent log line.
#   - harness-sync can be stuck behind/diverged, so the box renders faithfully
#     from a checkout that is days old.
#   - context-gate.sh does check live-vs-checkout before a build, but it SELF-
#     HEALS and moves on, and a low-traffic box (project-6, project-5) may go a
#     long time without a build to trigger it.
#
# So drift returns as silence, exactly the way it arrived the first time. This
# is the recurring check that turns that silence into an ALERTS line.
#
# It distinguishes the two failures, because they have different fixes:
#   RENDER drift    live file != what the box's OWN checkout renders
#                   -> update-runners never ran, or someone hand-edited the box
#   CHECKOUT drift  the box's checkout canon != this repo's canon
#                   -> harness-sync is behind/diverged on that box
#
# Read-only everywhere: it never writes to a box, never heals, never deploys.
# Healing is update-runners'/context-gate's job; this one only tells the truth.
#
# exit 0 = every reachable box converged   1 = drift found   2 = a box was unreachable
#
# SELF-REPORTS FIRST (BH-2626). Every box posts the md5 of its rendered
# CLAUDE.md hourly (bin/box-self-report.sh). A box whose row is fresher than
# RULES_DRIFT_SELF_REPORT_FRESH_S (a settings row, default 7200 = 2x that lane's
# period) and whose hash IS the canon is judged from the row and not ssh'd, as
# long as the box's last full ssh probe is younger than RULES_DRIFT_FULL_PROBE_S
# (a settings row, default 86400). The row only carries CLAUDE.md, so RTK.md and
# settings.json are checked by that full probe: in steady state every row is
# fresh, and without it those two files would never be checked again. When the
# full probe is due the box is ssh'd as before, and if ssh does not answer it is
# UNREACHABLE (its RTK.md/settings.json are unverified), re-tried every tick
# until it answers. The per-box report line says which files the row verified
# and when the rest were last verified over ssh. A fresh hash that
# DIFFERS still gets the ssh probe, because only the probe can tell render drift,
# checkout drift and a CLAUDE.local.md overlay apart; if ssh does not answer, the
# row raises RULES DRIFT itself (the row proves the box is up, so no unreach
# alert). A stale or absent row, or a failed read, is the ssh path exactly as
# before, so the check never goes blind. 0 = ignore self-reports, ssh every box.
#
# Overrides (TESTS ONLY): HARNESS, HARNESS_CHECKOUT, RULES_DRIFT_BOXES,
#   RULES_DRIFT_SSH, RULES_DRIFT_CLAUDE_DIR. Never set these in cron.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-rules-drift-check
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off rules-drift-check.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit rules-drift-check
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    rules-drift-check
CHECKOUT="${HARNESS_CHECKOUT:-/root/harness-checkout}"
STATE="$HARNESS/state/rules-drift"
LOG="$HARNESS/logs/rules-drift.log"
ALERTS="$HARNESS/logs/ALERTS.log"
SSH_CMD="${RULES_DRIFT_SSH:-ssh -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new}"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$STATE" "$(dirname "$LOG")"

# The three repo-managed files, in the order the probe reports them. CLAUDE.md is
# the only one with a box-local overlay: update-runners/sync-agent-rules append
# /root/.claude/CLAUDE.local.md to the canon. RTK.md has no overlay, and
# settings.json's box-local layer is settings.local.json, which Claude Code merges
# natively and the render never touches — so for those two, live must equal canon
# byte for byte.
FILES="CLAUDE.md RTK.md settings.json"

# --- the probe -------------------------------------------------------------
# Runs on the far box (or locally for the hub) and prints ONE line per file:
#   <name> <live-md5> <rendered-md5> <checkout-canon-md5>
# plus a trailing "overlay <bytes|none>". "-" means the file is absent, which is
# itself drift: every box is supposed to carry all three.
read -r -d '' PROBE <<'PROBE_EOF'
CK="${HARNESS_CHECKOUT:-/root/harness-checkout}"
CD="${RULES_DRIFT_CLAUDE_DIR:-/root/.claude}"
m() { [ -f "$1" ] && md5sum "$1" 2>/dev/null | cut -d' ' -f1 || echo -; }
# CLAUDE.md: rendered = canon + the box-local overlay, byte-identical to the
# render in sync-agent-rules.sh apply_machine_rules(). The canon is the fleet
# rules head when the box holds a non-empty one (BH-7971, the rule of
# bin/lib/rules-canon.sh, inline because this text runs on the far box), else
# the checkout's file. The third column stays the checkout's own canon.
FR="${HARNESS:-/root/harness}/state/prompts/_fleet/rules.md"
if [ -f "$FR" ] && [ -r "$FR" ] && [ -s "$FR" ]; then SRC="$FR"; else SRC="$CK/rules/CLAUDE.md"; fi
R=$(mktemp)
if [ -f "$CK/rules/CLAUDE.md" ]; then
  cat "$SRC" > "$R"
  [ -f "$CD/CLAUDE.local.md" ] && {
    printf '\n\n<!-- box-specific, from %s -->\n\n' "$CD/CLAUDE.local.md" >> "$R"
    cat "$CD/CLAUDE.local.md" >> "$R"
  }
  echo "CLAUDE.md $(m "$CD/CLAUDE.md") $(m "$R") $(m "$CK/rules/CLAUDE.md")"
else
  echo "CLAUDE.md $(m "$CD/CLAUDE.md") - -"
fi
rm -f "$R"
for F in RTK.md settings.json; do
  echo "$F $(m "$CD/$F") $(m "$CK/rules/$F") $(m "$CK/rules/$F")"
done
if [ -f "$CD/CLAUDE.local.md" ]; then
  echo "overlay $(wc -c < "$CD/CLAUDE.local.md")"
else
  echo "overlay none"
fi
PROBE_EOF

# --- box list --------------------------------------------------------------
# fleet.conf column 6, plus the hub itself. A commented-out (PARKED) row is not a
# box: its machine is stopped, so probing it would alert forever.
if [ -n "${RULES_DRIFT_BOXES:-}" ]; then
  BOXES="$RULES_DRIFT_BOXES"
else
  BOXES=$(printf 'local\n%s\n' \
    "$(awk '!/^[[:space:]]*(#|$)/ && NF>=6 {print $6}' "$CHECKOUT/fleet.conf" 2>/dev/null)" \
    | grep -v '^$' | sort -u)
fi

# Canon digests, from THIS repo checkout — the thing every box is measured against.
declare -A CANON=()
for F in $FILES; do
  if [ -f "$CHECKOUT/rules/$F" ]; then CANON[$F]=$(md5sum "$CHECKOUT/rules/$F" | cut -d' ' -f1); else CANON[$F]=-; fi
done
[ "${CANON[CLAUDE.md]}" = - ] && { echo "$(STAMP) rules-drift-check: no canon at $CHECKOUT/rules/CLAUDE.md — nothing to compare against" >> "$LOG"; exit 2; }

# --- alert once per (box,file,kind), and say so when it heals ---------------
# A drifted box would otherwise re-alert every run; a healed one would leave the
# operator wondering whether it was ever fixed.
note() { # note <key> <alert-line>
  local key="$1" line="$2"
  [ -f "$STATE/$key" ] && return 0
  echo "$(STAMP) $line" >> "$ALERTS"
  : > "$STATE/$key"
}
clear_note() { # clear_note <key> <box> <file>
  [ -f "$STATE/$1" ] || return 0
  rm -f "$STATE/$1"
  echo "$(STAMP) rules drift RESOLVED on $2 ($3)" >> "$LOG"
}

# --- self-reports (BH-2626) ---------------------------------------------------
# box_status names a box by what the box calls itself (box-project-3-2),
# fleet.conf by its box column; both are compared as the cron box id
# (bin/lib/cron-lines.sh), and where two rows answer for one id the newest
# rules_reported_at wins — pipeline-health's box_heads precedent.
# shellcheck source=/dev/null
[ -f "$HARNESS/bin/jobs-client.sh" ] && . "$HARNESS/bin/jobs-client.sh" 2>/dev/null
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/cron-lines.sh
[ -r "$HERE/lib/cron-lines.sh" ] && . "$HERE/lib/cron-lines.sh"
declare -F cron_box_id_for >/dev/null 2>&1 || cron_box_id_for() { local b="${1#box-}"; case "$b" in ''|local|1) echo hub ;; *) echo "${b%-[0-9]*}" ;; esac; }
FRESH="${RULES_DRIFT_SELF_REPORT_FRESH_S:-7200}"
case "$FRESH" in ''|*[!0-9]*) FRESH=7200 ;; esac
FULL="${RULES_DRIFT_FULL_PROBE_S:-86400}"
case "$FULL" in ''|*[!0-9]*) FULL=86400 ;; esac
NOW=$(date +%s)
# full_probe_age <box> — seconds since the box last answered a full ssh probe,
# stamped in $STATE/fullprobe-<box>; empty when it never has (or the stamp is bad).
full_probe_age() {
  local e
  e=$(cat "$STATE/fullprobe-$1" 2>/dev/null)
  case "$e" in ''|*[!0-9]*) return 0 ;; esac
  echo $((NOW - e))
}
# sr_fresh <at> — rc 0 when <at> is the exact UTC stamp shape, at most 300 s in
# the future (clock skew) and younger than FRESH. Anything else is stale.
sr_fresh() {
  local e
  [[ "${1:-}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || return 1
  [ -n "$1" ] || return 1
  e=$(date -u -d "$1" +%s 2>/dev/null) || return 1
  [ $((NOW - e + 300)) -ge 0 ] && [ $((NOW - e)) -lt "$FRESH" ]
}
declare -A SR_RULES=()   # cron id -> "<hash>\t<rules_reported_at>"
if [ "$FRESH" -gt 0 ] && declare -F box_self_reports >/dev/null 2>&1; then
  if SR=$(box_self_reports 2>/dev/null); then
    # \037, not a tab, as the read separator: tab is IFS whitespace, so an empty
    # cli_version column would collapse and shift every field after it.
    while IFS=$'\037' read -r SB _ _ _ SH SA; do
      [ -n "$SB" ] && [ -n "$SH" ] && [ -n "$SA" ] || continue
      SID=$(cron_box_id_for "$SB")
      PREV="${SR_RULES[$SID]:-}"
      if [ -z "$PREV" ] || [[ "$SA" > "${PREV#*$'\t'}" ]]; then SR_RULES[$SID]="$SH"$'\t'"$SA"; fi
    done < <(printf '%s\n' "$SR" | tr '\t' '\037')
  else
    echo "$(STAMP) rules-drift-check: self-report read failed; ssh for every box" >> "$LOG"
  fi
fi

DRIFT=0; UNREACH=0; OK=0; REPORT=""
for BOX in $BOXES; do
  SR_HASH=""; SR_AT=""
  if [ "$BOX" != local ]; then
    SR_ROW="${SR_RULES[$(cron_box_id_for "$BOX")]:-}"
    if [ -n "$SR_ROW" ] && sr_fresh "${SR_ROW#*$'\t'}"; then
      SR_HASH="${SR_ROW%%$'\t'*}"; SR_AT="${SR_ROW#*$'\t'}"
    fi
  fi
  # A fresh row whose hash is the canon: the box runs the repo's rules. No ssh,
  # unless RTK.md/settings.json (which the row cannot answer) are due a full probe.
  SR_MATCH=""
  if [ -n "$SR_HASH" ] && [ "$SR_HASH" = "${CANON[CLAUDE.md]}" ]; then
    SR_MATCH=1
    AGE=$(full_probe_age "$BOX")
    if [ -n "$AGE" ] && [ "$AGE" -ge 0 ] && [ "$AGE" -lt "$FULL" ]; then
      clear_note "render-$BOX-CLAUDE.md" "$BOX" "CLAUDE.md render"
      clear_note "checkout-$BOX-CLAUDE.md" "$BOX" "CLAUDE.md checkout"
      clear_note "unreach-$BOX" "$BOX" ssh
      OK=$((OK+1)); REPORT="$REPORT\n  $BOX ok (CLAUDE.md via self-report $SR_AT; RTK.md/settings.json via ssh $(date -u -d "@$((NOW - AGE))" +%Y-%m-%dT%H:%M:%SZ))"
      continue
    fi
  fi
  if [ "$BOX" = local ]; then
    OUT=$(HARNESS="$HARNESS" HARNESS_CHECKOUT="$CHECKOUT" RULES_DRIFT_CLAUDE_DIR="${RULES_DRIFT_CLAUDE_DIR:-/root/.claude}" bash -c "$PROBE" 2>/dev/null)
  else
    OUT=$($SSH_CMD "root@$BOX" "bash -s" <<<"$PROBE" 2>/dev/null)
  fi
  if { [ -z "$OUT" ] || ! grep -q '^CLAUDE.md ' <<<"$OUT"; } && [ -n "$SR_HASH" ] && [ -z "$SR_MATCH" ]; then
    # ssh did not answer, but a fresh row says the live file is not the canon.
    clear_note "unreach-$BOX" "$BOX" ssh
    note "render-$BOX-CLAUDE.md" "[$BOX] RULES DRIFT: /root/.claude/CLAUDE.md self-reported ${SR_HASH:0:8} at $SR_AT, canon ${CANON[CLAUDE.md]:0:8}; ssh could not confirm, so render-vs-checkout (or a CLAUDE.local.md overlay) is undiagnosed. Fix: /root/harness/bin/update-runners.sh on $BOX (and check its update-runners.log for the run that failed)."
    DRIFT=$((DRIFT+1)); REPORT="$REPORT\n  $BOX DRIFT: CLAUDE.md(self-report ${SR_HASH:0:8} at $SR_AT, ssh down)"
    continue
  fi
  if [ -z "$OUT" ] || ! grep -q '^CLAUDE.md ' <<<"$OUT"; then
    if [ -n "$SR_MATCH" ]; then
      UNREACH=$((UNREACH+1)); REPORT="$REPORT\n  $BOX UNREACHABLE (CLAUDE.md ok via self-report $SR_AT; RTK.md/settings.json full probe due, no probe output)"
      note "unreach-$BOX" "[$BOX] rules-drift-check could not probe the box over ssh — CLAUDE.md matches canon by its self-report at $SR_AT, but RTK.md and settings.json are unverified (the row does not carry them). Check the box is up and ssh works from hub."
    else
      UNREACH=$((UNREACH+1)); REPORT="$REPORT\n  $BOX UNREACHABLE (no probe output)"
      note "unreach-$BOX" "[$BOX] rules-drift-check could not probe the box over ssh — its Claude Code config is unverified. Check the box is up and ssh works from hub."
    fi
    continue
  fi
  clear_note "unreach-$BOX" "$BOX" ssh
  [ "$BOX" = local ] || echo "$NOW" > "$STATE/fullprobe-$BOX"

  BOX_DRIFT=""
  for F in $FILES; do
    read -r _ LIVE RENDERED CK_CANON < <(grep "^$F " <<<"$OUT")
    KEY_R="render-$BOX-$F"; KEY_C="checkout-$BOX-$F"
    # CHECKOUT drift first: if the box's canon is not our canon, its render is
    # faithful-but-wrong, and re-rendering would not fix it.
    if [ "$CK_CANON" != "${CANON[$F]}" ]; then
      BOX_DRIFT="$BOX_DRIFT $F(checkout)"
      note "$KEY_C" "[$BOX] CHECKOUT DRIFT: rules/$F in the box's harness checkout is not the repo's (${CK_CANON:0:8} vs ${CANON[$F]:0:8}). The box renders its Claude Code config faithfully from a stale/diverged checkout. Fix: /root/harness/bin/harness-sync.sh on $BOX (a diverged checkout is never force-reset — that would destroy uncommitted work on the box)."
    else
      clear_note "$KEY_C" "$BOX" "$F checkout"
    fi
    if [ "$LIVE" != "$RENDERED" ]; then
      BOX_DRIFT="$BOX_DRIFT $F(render)"
      note "$KEY_R" "[$BOX] RULES DRIFT: /root/.claude/$F does not match what its checkout renders (${LIVE:0:8} vs ${RENDERED:0:8}). Claude on this box is running under config no commit records. Fix: /root/harness/bin/update-runners.sh on $BOX (and check its update-runners.log for the run that failed)."
    else
      clear_note "$KEY_R" "$BOX" "$F render"
    fi
  done

  OVERLAY=$(awk '/^overlay /{print $2}' <<<"$OUT")
  if [ -n "$BOX_DRIFT" ]; then
    DRIFT=$((DRIFT+1)); REPORT="$REPORT\n  $BOX DRIFT:$BOX_DRIFT"
  else
    OK=$((OK+1))
    REPORT="$REPORT\n  $BOX ok$([ "$OVERLAY" != none ] && echo " (overlay ${OVERLAY}B)")"
  fi
done

SUMMARY="rules-drift-check: $OK converged, $DRIFT drifted, $UNREACH unreachable (canon ${CANON[CLAUDE.md]:0:8})"
echo "$(STAMP) $SUMMARY" >> "$LOG"
echo "$SUMMARY"; printf '%b\n' "$REPORT"
[ "$DRIFT" -gt 0 ] && exit 1
[ "$UNREACH" -gt 0 ] && exit 2
exit 0
