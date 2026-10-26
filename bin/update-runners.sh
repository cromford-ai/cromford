#!/bin/bash
# Daily runner-CLI updater (2026-07-24): keep codex on OpenAI's current best model.
# The codex CLI's default model alias moves forward with CLI releases, and until
# 2026-08-20 we pinned no model — updating the CLI WAS the "always their best
# model" mechanism. Since the ChatGPT default drifted to ~z-ai/glm-latest, the
# codex model is pinned (model_routes role codex.default since BH-1510, and a
# newer model can need a newer CLI); this daily CLI update is what keeps every
# box able to run that pin. Safe under the failover net: if an update
# breaks flags/auth, agent-call fails over to claude and writes an ALERTS line.
# Claude CLI IS auto-updated daily as of 2026-08-14 (the operator directive: newer builds
# carry cross-session messaging the orchestrator uses; models stay env-pinned so a
# CLI update never changes model choice; agent-call's failover net catches breakage).
# Since 2026-09-06 the CLI step is bin/cli-update.sh (below, AFTER the harness
# sync so a box runs today's updater): it updates native AND npm installs,
# retries npm with --force on EEXIST, repoints stale symlinks so cron's PATH and a
# login PATH agree, and records before/after in logs/cli-versions.csv + the DB.
set -uo pipefail

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-update-runners
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off update-runners.
# The entry point owns the root default (BH-2613 rule 4): the libs below have none.
H="${HARNESS:-${H:-/root/harness}}"
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit update-runners
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    update-runners
LOG=/root/harness/logs/update-runners.log
# Overridable so tests can drive the crontab drift guard against a scratch tree.
# Cron never sets it, so production resolves to exactly the path it always had.
HARNESS_ALERTS="${HARNESS_ALERTS:-/root/harness/logs/ALERTS.log}"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }

# DNS first (BH-5337): the sync below needs DNS, and a box whose resolv.conf is
# a dangling systemd stub link has none after a reboot. bin/dns-guard.sh writes
# a static file in that one case and alerts `dns: dead` when the canary fails.
[ -x "$H/bin/dns-guard.sh" ] && HARNESS="$H" "$H/bin/dns-guard.sh" >> "$LOG" 2>&1 || true

# Harness self-sync (2026-07-27; extracted to bin/harness-sync.sh 2026-08-14 so
# the daily tick and the pre-build context gate share ONE implementation — the
# gate now syncs a stale box on demand instead of waiting for this cron).
CHECKOUT=/root/harness-checkout
/root/harness/bin/harness-sync.sh >/dev/null 2>&1 || true

# --- Auditd install/repair (#395 slice, BH-443) --------------------------------
# bin/ and cron/ already ride harness-sync (FLEET_PATHS in bin/lib/fleet-paths.sh
# lists them), but the audit RULES file and the auditd package do not — this call
# is the leg that carries them to every box. Runs AFTER the sync so a box applies
# today's installer, not yesterday's. Fail-open by contract: the installer always
# exits 0, and `|| true` keeps this script's exit-code promise (non-zero only on
# a crontab refusal) even if it is ever made to exit non-zero.
[ -x /root/harness/bin/audit-install.sh ] && /root/harness/bin/audit-install.sh >> "$LOG" 2>&1 || true

# --- /tmp tmpfs size (BH-6041) -------------------------------------------------
# The one place the size is declared: TMPFS_RAM_PCT (this lane's knob) percent
# of RAM, persisted in fstab. Acts only on a tmpfs /tmp, only ever grows it.
# Fail-open: it always exits 0, and a problem is its log line.
[ -x /root/harness/bin/tmpfs-ensure.sh ] && /root/harness/bin/tmpfs-ensure.sh >> "$LOG" 2>&1 || true

# --- OS security updates (BH-6742) ----------------------------------------------
# unattended-upgrades on the security pockets only, no reboot, needrestart in
# list mode, and the 04:17Z cron line. Writes only what differs, so a set-up box
# changes nothing. Fail-open: it always exits 0, and a problem is its log line.
[ -x /root/harness/bin/security-updates-ensure.sh ] && /root/harness/bin/security-updates-ensure.sh >> "$LOG" 2>&1 || true

# --- Runner CLIs: claude + codex + grok, through bin/cli-update.sh (2026-09-06) -
# Was two inline `npm install -g` lines above the sync. They were a wish, not a
# mechanism: project-9's PATH claude was a NATIVE install npm never touched, its
# codex npm step hit EEXIST every morning into this log alone, and cron's PATH
# and a login PATH resolved different binaries. cli-update.sh handles every
# install shape and says what it did; the hub's bin/cli-version-check.sh (05:40)
# compares the fleet afterwards. Non-zero from it means a CLI ended up WORSE or
# MISSING — the two outcomes that earn an ALERT; a failed update that left the
# old binary running is a log line and the hub's check catches the gap.
BOX_TAG=$(tr -dc 'a-z0-9-' < /root/harness/state/box-id 2>/dev/null); BOX_TAG="${BOX_TAG:-$(hostname)}"
CLI_UPDATER=/root/harness/bin/cli-update.sh
[ -x "$CLI_UPDATER" ] || CLI_UPDATER="$CHECKOUT/bin/cli-update.sh"
if [ -x "$CLI_UPDATER" ]; then
  CLI_RC=0
  CLI_OUT=$("$CLI_UPDATER" 2>>"$LOG") || CLI_RC=$?
  [ -n "$CLI_OUT" ] && printf '%s\n' "$CLI_OUT" | sed "s/^/$(STAMP) cli-update: /" >> "$LOG"
  if [ "$CLI_RC" != 0 ]; then
    echo "$(STAMP) [$BOX_TAG] cli-update.sh rc=$CLI_RC — a runner CLI is WORSE or MISSING after today's update: $(printf '%s' "$CLI_OUT" | grep 'ok=0' | tr '\n' ' ')see /root/harness/logs/cli-update.log" >> "$HARNESS_ALERTS"
  fi
else
  echo "$(STAMP) [$BOX_TAG] bin/cli-update.sh missing from /root/harness/bin AND $CHECKOUT/bin — claude/codex/grok were NOT updated today. Run /root/harness/bin/harness-sync.sh on this box." >> "$HARNESS_ALERTS"
fi

# --- Kill switches: file -> settings row, daily (BH-2412) ---------------------
# bin/switch-migrate.sh writes the box row `switch.<name>.<box>=1` for every
# registered switch (catalog/switches.d/) whose flags/<name> this box holds, no
# script still reads bare, every catalog reader reads through lane_switch, and
# no row covers yet. Idempotent, and bounded by
# the registry: one settings GET plus at most one PUT per switch. AFTER the
# sync so today's registry and today's script run. rc 75 is "the settings table could not be read, nothing
# written": the jobs client already pages an unreachable worker, so that is a
# log line and tomorrow retries. rc 1 (a refused registry file or a failed
# write) and anything else is one ALERTS line, written by bin/alert-line.sh. It never touches CRON_RC.
# SWITCH_MIGRATE is overridable for tests; cron never sets it.
# >>> switch migrate
SWITCH_MIGRATE="${SWITCH_MIGRATE:-/root/harness/bin/switch-migrate.sh}"
[ -x "$SWITCH_MIGRATE" ] || SWITCH_MIGRATE="$CHECKOUT/bin/switch-migrate.sh"
if [ -x "$SWITCH_MIGRATE" ]; then
  SM_RC=0
  SM_OUT=$("$SWITCH_MIGRATE" 2>&1) || SM_RC=$?
  [ -n "$SM_OUT" ] && printf '%s\n' "$SM_OUT" | sed "s/^/$(STAMP) switch-migrate: /" >> "$LOG"
  case "$SM_RC" in
    0) ;;
    75) echo "$(STAMP) switch-migrate rc=75 — settings unreadable or no jobs client, nothing written; the next daily run retries" >> "$LOG" ;;
    # Through bin/alert-line.sh (BH-2314): it notes the console row now and
    # appends the ALERTS.log line itself; it never fails the caller.
    *) SM_H="${HARNESS:-/root/harness}"
       HARNESS="$SM_H" "$SM_H/bin/alert-line.sh" "[$BOX_TAG] switch-migrate rc=$SM_RC — $(printf '%s\n' "$SM_OUT" | grep -E '^(refused|failed) ' | tr '\n' ' ')see $LOG" ;;
  esac
else
  echo "$(STAMP) switch-migrate: bin/switch-migrate.sh missing from /root/harness/bin AND $CHECKOUT/bin — no kill switch migrated today" >> "$LOG"
fi
# <<< switch migrate

# --- Flag files -> harness_flags rows, daily (BH-4153) ------------------------
# bin/flags-import.sh moves every legacy flags/paused-*, automerge-disabled*
# and lanedown-* file on this box into its row and deletes the file. The same
# rc handling as the switch migrate above: 75 is "no worker configured or it is
# unreachable, nothing touched", a log line, and tomorrow retries; 1 (a file
# that could not be imported, and is still honoured) is one ALERTS line naming
# it. It never touches CRON_RC. FLAGS_IMPORT is overridable for tests.
# >>> flags import
FLAGS_IMPORT="${FLAGS_IMPORT:-/root/harness/bin/flags-import.sh}"
[ -x "$FLAGS_IMPORT" ] || FLAGS_IMPORT="$CHECKOUT/bin/flags-import.sh"
if [ -x "$FLAGS_IMPORT" ]; then
  FI_RC=0
  FI_OUT=$("$FLAGS_IMPORT" 2>&1) || FI_RC=$?
  [ -n "$FI_OUT" ] && printf '%s\n' "$FI_OUT" | sed "s/^/$(STAMP) flags-import: /" >> "$LOG"
  case "$FI_RC" in
    0) ;;
    75) echo "$(STAMP) flags-import rc=75 — no worker configured or it is unreachable, nothing touched; the next daily run retries" >> "$LOG" ;;
    *) FI_H="${HARNESS:-/root/harness}"
       HARNESS="$FI_H" "$FI_H/bin/alert-line.sh" "[$BOX_TAG] flags-import rc=$FI_RC — $(printf '%s\n' "$FI_OUT" | grep -E '^failed ' | tr '\n' ' ')the files are kept and still honoured; see $LOG" ;;
  esac
else
  echo "$(STAMP) flags-import: bin/flags-import.sh missing from /root/harness/bin AND $CHECKOUT/bin — no flag file imported today" >> "$LOG"
fi
# <<< flags import

# >>> machine rules (tests/prompt-render.bh-7971-test.sh drives this block)
# --- Machine rules are REPO-MANAGED (the operator, 2026-08-14) --------------------
# /root/.claude/CLAUDE.md is now rendered from $CHECKOUT/rules/CLAUDE.md on every
# box, every day. Edit the repo copy, never the box copy — local edits here are
# reverted, exactly like bin/*.sh.
#
# Why: the fleet had drifted badly. hub carried 12355B / 15 sections while project-3,
# project-4 and project-2 carried ~2.5KB holding ONLY the CodeGraph and 08-13
# sections — so Claude itself was running on three boxes with no iron guardrails,
# no data/config iron laws, no UI/UX standards. Copying the file once would have
# drifted again by the next rule change; this makes the repo the single source
# and closes it permanently. It also feeds agent-call.sh's rules injection, so
# the codex/grok lanes get the full set rather than whatever a box happened to
# have. Runs unconditionally (not only when HEAD moved) so a box that fell
# behind catches up on its next tick.
#
# Box-specific additions go in /root/.claude/CLAUDE.local.md, which is appended
# and never overwritten.
# RULES_-prefixed on purpose: the crontab section below has its own LIVE (the
# live crontab's CONTENT) and RENDERED (the rendered crontab's CONTENT), while
# these two are PATHS to files. Two meanings for one name in one script is how a
# later edit reaches for the wrong one and cats a crontab over CLAUDE.md.
#
# Fleet rules win (BH-7971, decision 7): a non-empty
# state/prompts/_fleet/rules.md (a fleet `rules` head, rendered by the hub's
# bin/prompt-render.sh and pushed by fleet-propagate) replaces the repo file as
# the canon. bin/lib/rules-canon.sh decides; without it, the repo file.
# RULES_CLAUDE_DIR overrides /root/.claude for TESTS only.
CANON="$CHECKOUT/rules/CLAUDE.md"
# shellcheck source=bin/lib/rules-canon.sh
. "${HARNESS:-/root/harness}/bin/lib/rules-canon.sh" 2>/dev/null \
  || . "$CHECKOUT/bin/lib/rules-canon.sh" 2>/dev/null || true
command -v rules_canon_path >/dev/null 2>&1 && CANON=$(rules_canon_path "${HARNESS:-/root/harness}" "$CHECKOUT")
case "$CANON" in */state/prompts/_fleet/rules.md) RULES_FROM="fleet head" ;; *) RULES_FROM=repo ;; esac
RULES_DIR="${RULES_CLAUDE_DIR:-/root/.claude}"
RULES_LIVE="$RULES_DIR/CLAUDE.md"
if [ -f "$CANON" ]; then
  RULES_RENDERED=$(mktemp)
  cat "$CANON" > "$RULES_RENDERED"
  [ -f "$RULES_DIR/CLAUDE.local.md" ] && {
    printf '\n\n<!-- box-specific, from %s -->\n\n' "$RULES_DIR/CLAUDE.local.md" >> "$RULES_RENDERED"
    cat "$RULES_DIR/CLAUDE.local.md" >> "$RULES_RENDERED"
  }
  if ! cmp -s "$RULES_RENDERED" "$RULES_LIVE"; then
    [ -f "$RULES_LIVE" ] && cp "$RULES_LIVE" "$RULES_LIVE.bak-$(date -u +%Y%m%d%H%M)"
    mkdir -p "$RULES_DIR"
    mv "$RULES_RENDERED" "$RULES_LIVE" && chmod 644 "$RULES_LIVE"
    echo "$(STAMP) machine rules updated from $RULES_FROM ($(stat -c %s "$RULES_LIVE")B, $(grep -cE '^#{1,3} ' "$RULES_LIVE") sections)" >> "$LOG"
  else
    rm -f "$RULES_RENDERED"
  fi
fi
# <<< machine rules

# Re-render AGENTS.md for the non-git dirs. The rules themselves ride the prompt
# injection in agent-call.sh, which reads CLAUDE.md live; this only refreshes the
# on-disk copy the Telegram survival lane picks up from its cwd.
# rtk usage notes are repo-managed too — rules/CLAUDE.md references @RTK.md,
# so the file must exist beside it on every box (incl. freshly provisioned ones).
if [ -f "$CHECKOUT/rules/RTK.md" ] && ! cmp -s "$CHECKOUT/rules/RTK.md" /root/.claude/RTK.md; then
  cp "$CHECKOUT/rules/RTK.md" /root/.claude/RTK.md && chmod 644 /root/.claude/RTK.md
  echo "$(STAMP) RTK.md updated from repo" >> "$LOG"
fi

# --- Claude Code settings are REPO-MANAGED (drift lesson #2, 2026-08-23) ------
# The rtk rollout patched settings.json by hand on 6 boxes and the fly image
# got nothing — same class of drift the 2026-08-14 rules fix closed for
# CLAUDE.md, on the file next to it. rules/settings.json is now the canonical
# hooks/permissions config; box-specific additions belong in settings.local.json
# (Claude Code merges it natively and this render never touches it). A hook
# whose binary is missing fails silent-ish, so verify the binaries too.
if [ -f "$CHECKOUT/rules/settings.json" ] && ! cmp -s "$CHECKOUT/rules/settings.json" /root/.claude/settings.json; then
  cp /root/.claude/settings.json "/root/.claude/settings.json.bak-$(date -u +%Y%m%d%H%M)" 2>/dev/null
  cp "$CHECKOUT/rules/settings.json" /root/.claude/settings.json && chmod 644 /root/.claude/settings.json
  echo "$(STAMP) settings.json applied from repo" >> "$LOG"
fi
for B in /usr/local/bin/rtk /usr/local/bin/codegraph /root/harness/bin/secret-read-guard.py python3; do
  [ -x "$B" ] || command -v "$(basename "$B")" >/dev/null 2>&1 || \
    echo "$(STAMP) [$(hostname)] settings.json references $(basename "$B") but the binary is missing — its hook is dead on this box; install it (see rules/settings.json provenance)" >> /root/harness/logs/ALERTS.log
done

# --- Crontabs are RENDERED FROM fleet.conf (2026-08-30) -----------------------
# Was: apply the hand-maintained cron/<box-id>.cron verbatim. That made the
# crontab a plane with TWO writers and no reconciliation — bootstrap-machine.sh
# installed a new project's lanes live from the registry, this job copied a file
# that had never heard of them back over the top, and project-7's seven lines
# vanished at 05:17 the morning after it was onboarded. Ten hours dead, nothing
# alerted, because from each writer's side nothing was wrong.
#
# Now: cron/<box-id>.cron is the BASE, bin/render-crontab.sh lays the registry's
# project blocks on top, and the result is what gets applied — so a fleet.conf
# row alone is enough to keep a lane alive.
#
# EVERY failure path here is fail-CLOSED — the live crontab keeps what it has
# and an ALERTS line says why. No box id, no cron file, an empty cron file, a
# render that exits non-zero, a render that comes back empty, a render that
# would drop a lane the box is currently running, or a crontab(1) rejection:
# all of them leave the box exactly as it was. A stale crontab is a bad day; a
# wiped one takes the lanes, @reboot and the watchdog ping with it.
BOX_ID=$(cat /root/harness/state/box-id 2>/dev/null | tr -dc 'a-z0-9-')
CRONF="$CHECKOUT/cron/$BOX_ID.cron"
CRON_RC=0

# The same cron file also names this box to the fleet (the watchdog-ping
# argument), so resolve it into state/box-name while it is in hand. Without
# this every box reports `hostname` — the Orgo image default "orgo-desktop" on
# all five — into the jobs ledger's box column, which the worker slugs into
# paused-box-<box>, counts scope=box concurrency rules by, and compares on the
# claim-resume path. Best-effort by design: a failure here must never stop a
# sync, and bin/jobs-client.sh falls back to the hostname exactly as before.
if [ -x "$CHECKOUT/bin/box-name.sh" ]; then
  BOX_NAME_RESOLVED=$(CHECKOUT="$CHECKOUT" "$CHECKOUT/bin/box-name.sh" --write 2>/dev/null || true)
  [ -n "$BOX_NAME_RESOLVED" ] \
    && echo "$(STAMP) box name: $BOX_NAME_RESOLVED" >> "$LOG"
fi
# cron/<box>.cron is GENERATED and no longer committed (BH-1247), so "the
# checkout has the file" stopped being the right precondition — a fresh
# checkout never does, and this tick would skip the crontab forever while
# reporting a clean sync. The precondition is now "this box can be rendered":
# a box id, and a renderer in the checkout. render-crontab.sh renders the base
# itself and fails closed if it cannot, so every failure path below is reached
# exactly as it was when the file was read from git.
if [ -n "$BOX_ID" ] && { [ -s "$CRONF" ] || [ -x "$CHECKOUT/bin/render-cron.sh" ]; }; then
  LIVE=$(crontab -l 2>/dev/null)
# >>> crontab render
  # FAIL CLOSED. A render that failed tells us nothing about what this box
  # should be running, so the answer is to touch nothing and say so — not to
  # fall back to the committed file (which may be the stale half of the very
  # disagreement that failed) and not to install a partial result.
  #
  # The exit status has to be captured EXPLICITLY: `X=$(cmd)` reports the
  # assignment's status, so a plain `if [ -z "$X" ]` check silently accepts a
  # non-empty partial write from a command that died. That swallowed rc is the
  # whole finding.
  RENDER_RC=0
  RENDERED=$("$CHECKOUT/bin/render-crontab.sh" --root "$CHECKOUT" "$BOX_ID" 2>>"$LOG") || RENDER_RC=$?
  if [ "$RENDER_RC" != 0 ] || [ -z "$RENDERED" ]; then
    echo "$(STAMP) [$BOX_ID] CRONTAB RENDER FAILED (rc=$RENDER_RC) — the LIVE crontab was NOT touched and this box's lanes are unchanged. Until this is fixed no new fleet.conf lane can reach it. Check $CHECKOUT/fleet.conf, the cron marker balance in cron/$BOX_ID.cron, and this log for stderr." >> "$HARNESS_ALERTS"
    RENDER_RC=1
    RENDERED=""
  fi
# <<< crontab render

if [ "$RENDER_RC" != 0 ]; then
  # Fail closed: nothing below runs, the live crontab keeps whatever it has,
  # and the ALERTS line above is the record. CRON_RC carries the non-zero exit
  # to the end of the script so the rules sync still happens.
  CRON_RC=1
else
  # Which projects does the registry give this box? The drift guard below is a
  # claim about lanes, and a lane is a project, not a line.
  BOX_PROJECTS=""
  if [ -r "$CHECKOUT/bin/lib/cron-lines.sh" ]; then
    # shellcheck source=bin/lib/cron-lines.sh
    . "$CHECKOUT/bin/lib/cron-lines.sh"
    export FLEET_CONF="$CHECKOUT/fleet.conf"
    while read -r _P; do
      [ -n "$_P" ] || continue
      _B=$("$CHECKOUT/bin/box-for.sh" "$_P" 2>/dev/null) || continue
      [ "$(cron_box_id_for "$_B")" = "$BOX_ID" ] && BOX_PROJECTS="$BOX_PROJECTS $_P"
    done < <("$CHECKOUT/bin/fleet-conf.sh" --projects 2>/dev/null)
    unset FLEET_CONF
  fi

# >>> crontab drift guard
  # The reconciliation the incident was missing. Two shapes, and they are NOT
  # the same event, so they do not get the same response:
  #
  #   a live lane the render would DROP  -> refuse the whole apply. This is the
  #     project-7 wipe. Applying it kills a board's watcher silently, and the
  #     cost of being wrong in the other direction (a stale crontab for one more
  #     day, loudly) is nothing next to that.
  #   a registry lane with NO live lines -> apply, and say so. A project sitting
  #     in fleet.conf that no cron ever ran is a board nobody is watching, which
  #     looks exactly like a quiet week.
  #
  # Keyed on run-triage.sh <project>: it is the one line every watched project
  # has, and its absence is precisely "this lane is not running".
  DRIFT_RC=0
  for _P in $BOX_PROJECTS; do
    _LANE="/root/harness/bin/run-triage.sh $_P"
    if grep -qF "$_LANE" <<<"$LIVE"; then
      if ! grep -qF "$_LANE" <<<"$RENDERED"; then
        echo "$(STAMP) [$BOX_ID] CRONTAB DRIFT: the render would DROP the live triage lane for $_P — REFUSING to apply, live crontab untouched. fleet.conf and cron/$BOX_ID.cron disagree about this box; reconcile them and re-run bin/render-crontab.sh $BOX_ID." >> "$HARNESS_ALERTS"
        DRIFT_RC=1
      fi
    else
      echo "$(STAMP) [$BOX_ID] CRONTAB GAP: fleet.conf assigns $_P to this box but the LIVE crontab has no triage lane for it — installing it now. A registry row with no cron behind it is a board nobody is watching." >> "$HARNESS_ALERTS"
    fi
  done
# <<< crontab drift guard

  if [ "$DRIFT_RC" != 0 ]; then
    CRON_RC=1
  elif [ "$LIVE" != "$RENDERED" ]; then
    printf '%s\n' "$LIVE" > "/root/harness/state/crontab.bak-$(date -u +%Y%m%d%H%M)"
    NEWF=$(mktemp); printf '%s\n' "$RENDERED" > "$NEWF"
    if crontab "$NEWF" 2>>"$LOG"; then
      echo "$(STAMP) crontab applied (rendered from fleet.conf onto cron/$BOX_ID.cron, $(grep -c . "$NEWF") lines)" >> "$LOG"
      # The diff, not just the fact. A crontab that changed and nobody can say
      # how is the same blind spot one layer down from the one being closed.
      comm -13 <(printf '%s\n' "$LIVE" | sort) <(printf '%s\n' "$RENDERED" | sort) \
        | sed "s/^/$(STAMP) crontab + /" >> "$LOG"
      comm -23 <(printf '%s\n' "$LIVE" | sort) <(printf '%s\n' "$RENDERED" | sort) \
        | sed "s/^/$(STAMP) crontab - /" >> "$LOG"
    else
      echo "$(STAMP) [$BOX_ID] rendered crontab REJECTED by crontab(1) — live crontab untouched; fix cron/$BOX_ID.cron or the fleet.conf row" >> "$HARNESS_ALERTS"
      CRON_RC=1
    fi
    rm -f "$NEWF"
  fi
fi
elif [ -n "$BOX_ID" ]; then
  echo "$(STAMP) [${BOX_ID:-<no box id>}] cannot render a crontab for this box — no box id in state/box-id, or no bin/render-cron.sh in the checkout. Crontab left as-is. cron/$BOX_ID.cron is GENERATED (BH-1247); capture a hand-managed box with bin/render-crontab.sh --base-live $BOX_ID" >> "$LOG"
fi

if [ -x /root/harness/bin/sync-agent-rules.sh ]; then
  /root/harness/bin/sync-agent-rules.sh install >/dev/null 2>&1 \
    || echo "$(STAMP) sync-agent-rules failed" >> "$LOG"
fi
# Non-zero ONLY when the crontab reconcile refused or was rejected. Everything
# above it still ran — a refused crontab must not cost the box its rules sync.
exit "$CRON_RC"
