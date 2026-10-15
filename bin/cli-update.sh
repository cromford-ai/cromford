#!/bin/bash
# bin/cli-update.sh [box-id] — EVERY box, daily (called by bin/update-runners.sh
# at 05:17Z; also runs standalone): bring the claude, codex and grok CLIs to
# their latest release, whatever way they happen to be installed on this box,
# and record before/after versions locally AND in the harness-jobs DB.
#
# WHY A SCRIPT AND NOT TWO npm LINES (the operator, 2026-09-06: "make sure codex and
# Claude get updated daily in general"). The inline `npm install -g` that
# update-runners.sh ran was not an update mechanism, it was a wish:
#   - box-project-9-1's PATH claude sat at 2.1.250 for days while the
#     Fable 5.1 bump needed 2.1.251. `claude update` failed, npm -g hit EEXIST,
#     and the fix (a NATIVE install at ~/.local/bin/claude, /usr/local/bin
#     relinked) meant every later npm update landed on a binary nothing runs.
#   - its codex npm step failed silently every morning (the hand-made
#     /usr/bin/codex -> /usr/local/bin/codex link is an EEXIST to npm, whose
#     global prefix is /usr) and only the box's own log knew: 0.150.1 while the
#     hub ran 0.153.4.
#   - cron's PATH (/usr/bin:/bin) and a login PATH (/usr/local/bin first) can
#     resolve two DIFFERENT claude binaries on one box, so "claude --version"
#     answered one thing to a human and another to the lanes.
#
# WHAT IT DOES, per CLI:
#   1. record what `command -v <cli>` resolves to right now, and its version;
#   2. update every install it can find — a native launcher (~/.local/bin/claude
#      -> `claude install latest`) AND/OR an npm global package (in npm's own
#      prefix or the legacy /usr/local prefix -> `npm install -g <pkg>@latest`,
#      retried with --force on EEXIST/ENOTEMPTY, the two ways npm says "a file
#      I did not make is in my way");
#   3. reconcile the links: among every install found, the NEWEST wins, and a
#      SYMLINK in /usr/local/bin or /usr/bin that resolves to an older one is
#      repointed at it (old link backed up beside it as <cli>.bak-<stamp>).
#      Regular files are never overwritten; a CLI that PATH cannot find at all
#      gets one link into the first PATH dir we manage. So both the cron view
#      and the login view end up on the same, newest, binary;
#   4. append at,box,cli,version_before,version_after,method,ok,path,note to
#      logs/cli-versions.csv and push the same row to the DB through
#      bin/jobs-client.sh metric_cli_version (fail-soft: a worker outage costs
#      the mirror, never the update or the CSV row).
#
# EXIT non-zero ONLY when a CLI ended up WORSE than it started or is missing
# afterwards — the two outcomes worth failing the daily tick over. A failed
# update that leaves the old binary running is logged, not fatal: the box keeps
# working and bin/cli-version-check.sh on the hub alerts on the version gap.
#
# GROK IS THE THIRD CLI (BH-1494, 2026-09-22), and it does not look like the
# other two. There is no npm package: xAI ships a native binary, and its
# installer writes $HOME/.grok/downloads/grok-linux-x64 with the launcher
# $HOME/.grok/bin/grok symlinked at it. It links into /usr/local/bin only when
# its own PATH check says it must, and NEVER into /usr/bin — so cron's PATH can
# be blind to a grok that works perfectly. Every lane reaches it by prepending
# $HOME/.grok/bin (bin/agent-call.sh, bin/lane-probe.sh, bin/orchestrate.sh),
# so that launcher is what this script reads before it asks PATH: MISSING here
# has to mean "the lanes cannot run it", not "cron's /usr/bin has no link". The
# update mechanism is re-running the installer, and the previous downloads/ dir
# is kept one cycle as downloads.prev so a pulled release rolls back with one
# mv — rotated only on a run that actually CHANGED the version, because a no-op
# day that snapshotted would overwrite the real previous release with a copy of
# the current one and the rollback would restore the broken build.
#
# Never prints tokens: command output goes to logs/cli-update.log through a
# redaction filter, and stdout carries only version lines.
#
# HUB-SCOPED SETTINGS ROWS (BH-1517). After a CLI update SUCCEEDS on the hub
# (only the hub — every box runs this daily, and a box mid-catch-up writing its
# own stale version would race the hub's), the new version is written to
# settings rows cli.claude_code.version / cli.codex.version. That is the DB
# value bin/fly-image-build.sh pins the Fly builder image's CLI install to,
# closing the gap where an unpinned `npm install -g ...@latest` in fly/Dockerfile
# let Depot's layer cache serve the SAME (weeks-stale) layer on every nightly
# rebuild while the hub kept moving. Hub identity comes from bin/lib/hub-box.sh
# (is_hub_box/local_box_name), never from `hostname`. Fail-open, same as the
# cost-mirror push below: a worker outage costs the DB mirror, never the update.
#
# FLYCTL AND gh (BH-6742, the operator 2026-10-14: "make sure the fly cli ... are
# regularly getting updated"). Two more tools in the same daily pass, same CSV
# row, same DB push, after the three runner CLIs:
#   flyctl  on every box that has it (only the hub calls Fly). Found at
#           $HOME/.fly/bin/flyctl first (the installer's home, not on cron's
#           PATH), else `command -v flyctl`/`fly`. The binary is copied to
#           <bin>.prev before `flyctl version upgrade`; a run that leaves it
#           missing or older puts .prev back. A no-op day keeps the old .prev.
#   gh      from GitHub's own apt repo (cli.github.com), not the Ubuntu archive
#           that lags upstream (hub: 2.45.0 from 2025-07). The repo and its key
#           are added once (sources.list.d/github-cli.list, keyrings/
#           githubcli-archive-keyring.gpg), then `apt-get install gh` from that
#           list only. apt keeps the old package when the install fails; a run
#           that leaves gh missing or older reinstalls the dpkg version it had.
# CLI_UPDATE_SYS_TOOLS (default "flyctl gh"; empty on a scratch box with
# CLI_UPDATE_HOME set) names them; a box without apt-get skips gh, a box
# without flyctl skips flyctl (no row).
#
# Overrides (tests only; production never sets them): HARNESS, CLI_UPDATE_HOME,
# CLI_UPDATE_NPM_PREFIX, CLI_UPDATE_NPM_PREFIXES, CLI_UPDATE_LINK_DIRS,
# CLI_UPDATE_CLIS, CLI_UPDATE_GROK_INSTALLER, CLI_UPDATE_JOBS_CLIENT,
# CLI_UPDATE_TIMEOUT, BOX_NAME (hub identity, per bin/lib/hub-box.sh),
# CLI_UPDATE_SYS_TOOLS, CLI_UPDATE_APT_ETC, CLI_UPDATE_GH_KEY_URL.
set -uo pipefail
H="${HARNESS:-/root/harness}"
. "${HARNESS:-/root/harness}/bin/lib/env-path.sh" 2>/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }; HENV=$(harness_env_dir "$H")
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=bin/lib/cli-version.sh
. "$HERE/lib/cli-version.sh"
# shellcheck source=bin/lib/hub-box.sh
[ -r "$HERE/lib/hub-box.sh" ] && . "$HERE/lib/hub-box.sh" 2>/dev/null

BOX="${1:-}"
[ -n "$BOX" ] || BOX=$(tr -dc 'A-Za-z0-9._-' < "$H/state/box-id" 2>/dev/null || true)
[ -n "$BOX" ] || BOX=$(hostname -s 2>/dev/null || echo unknown)
LOG="${CLI_UPDATE_LOG:-$H/logs/cli-update.log}"
CSV="$H/logs/cli-versions.csv"
HOMEDIR="${CLI_UPDATE_HOME:-${HOME:-/root}}"
NPM_PREFIX="${CLI_UPDATE_NPM_PREFIX:-$(npm prefix -g 2>/dev/null || echo /usr)}"
# Where a global package may live: npm's own prefix first, then the two the
# fleet has actually used (project-9's codex is under /usr/local, hub's under /usr).
NPM_PREFIXES="${CLI_UPDATE_NPM_PREFIXES:-$NPM_PREFIX /usr/local /usr}"
LINK_DIRS="${CLI_UPDATE_LINK_DIRS:-/usr/local/bin /usr/bin}"
CLIS="${CLI_UPDATE_CLIS:-claude codex grok}"
GROK_LAUNCHER="$HOMEDIR/.grok/bin/grok"
TO="${CLI_UPDATE_TIMEOUT:-600}"
STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
mkdir -p "$H/logs" "$H/state" 2>/dev/null

# Command output is a transcript of an installer, and installers echo their
# environment when they fail. Strip anything token-shaped on the way to disk.
redact() { sed -E 's/(sk-ant-[A-Za-z0-9_-]+|ghp_[A-Za-z0-9]+|gho_[A-Za-z0-9]+|xox[baprs]-[A-Za-z0-9-]+|Bearer [A-Za-z0-9._-]+)/[REDACTED]/g'; }
log() { echo "$(STAMP) [$BOX] $*" >> "$LOG"; }
# run_logged <label> <cmd...> -> rc of cmd; output (redacted) into the log and
# into $RUN_OUT for the caller to classify (the EEXIST retry needs the text).
RUN_OUT=""
run_logged() {
  local label="$1"; shift
  local out rc
  out=$(timeout --kill-after=30 "$TO" "$@" </dev/null 2>&1); rc=$?
  RUN_OUT=$(printf '%s' "$out" | redact)
  { echo "$(STAMP) [$BOX] \$ $label (rc=$rc)"; printf '%s\n' "$RUN_OUT" | tail -40 | sed 's/^/    /'; } >> "$LOG"
  return $rc
}

pkg_for() { case "$1" in claude) echo "@anthropic-ai/claude-code" ;; codex) echo "@openai/codex" ;; *) echo "" ;; esac; }

# cli_path_of <cli> -> the binary the LANES resolve, not just PATH's answer.
# Mirrors the readiness expression in bin/agent-call.sh and bin/orchestrate.sh
# ([ -x "$HOME/.grok/bin/grok" ] || command -v grok): they prepend that dir, so
# reading PATH alone would report MISSING on a box whose grok runs fine.
cli_path_of() {
  [ "$1" = grok ] && [ -x "$GROK_LAUNCHER" ] && { printf '%s\n' "$GROK_LAUNCHER"; return 0; }
  command -v "$1" 2>/dev/null || echo ""
}

# grok_update -> rc of the installer. Sets GROK_DL (so the AFTER block can
# rotate the snapshot) and METHOD_NOTE. The snapshot is taken BEFORE the
# installer runs and rotated after, because only then is it known whether the
# version moved.
GROK_DL=""
grok_update() {
  local rc
  GROK_DL="$HOMEDIR/.grok/downloads"
  if [ -d "$GROK_DL" ]; then
    rm -rf "$GROK_DL.prev.tmp"
    cp -a "$GROK_DL" "$GROK_DL.prev.tmp" 2>>"$LOG" \
      || { log "grok: could not copy $GROK_DL — no rollback snapshot this run"; rm -rf "$GROK_DL.prev.tmp"; }
  fi
  run_logged "grok installer" env HOME="$HOMEDIR" bash -c \
    "${CLI_UPDATE_GROK_INSTALLER:-set -o pipefail; curl -fsSL https://x.ai/cli/install.sh | bash}"; rc=$?
  if [ $rc -ne 0 ]; then
    log "grok: installer FAILED (rc=$rc) — keeping what is installed"
    METHOD_NOTE="${METHOD_NOTE}installer-failed;"
  fi
  return $rc
}

# The DB side is optional at every step: a box mid-bootstrap has no client, a
# worker outage answers nothing, and neither may stop the update. Sourced
# before global.env is needed: the client reads HARNESS_SECRET from the env,
# and cron does not source it, so do it here (+u: an unbound reference inside
# the env file must not kill the updater — see extra-usage-track.sh).
set -a +u; . "$HENV/global.env" 2>/dev/null; set +a -u
JOBS_CLIENT="${CLI_UPDATE_JOBS_CLIENT:-$H/bin/jobs-client.sh}"
# shellcheck source=/dev/null
[ -f "$JOBS_CLIENT" ] && . "$JOBS_CLIENT" 2>/dev/null

[ -s "$CSV" ] || echo "at,box,cli,version_before,version_after,method,ok,path,note" > "$CSV"

# ---------------------------------------------------------------------------
# candidates <cli> <pkg> -> lines "<version> <launcher-path> <resolved-path>"
#   every distinct install of the CLI on this box, deduped on the resolved
#   file. The launcher path is what a link should point at: the native
#   launcher (~/.local/bin/claude) is repointed by `claude install` itself, and
#   npm's bin entry is what npm rewrites on the next install — so a link at
#   either keeps following updates. Sorted newest first.
candidates() {
  local p r v seen=""
  while read -r _kind p; do
    [ -n "$p" ] || continue
    r=$(readlink -f "$p" 2>/dev/null) || continue
    case " $seen " in *" $r "*) continue ;; esac
    seen="$seen $r"
    v=$(cli_version_of "$p")
    echo "$v $p $r"
  done < <(candidates_raw "$1" "$2")
}
candidates_raw() {
  local cli="$1" pkg="$2" p d
  p="$HOMEDIR/.local/bin/$cli"; [ -x "$p" ] && echo "native $p"
  [ "$cli" = grok ] && [ -x "$GROK_LAUNCHER" ] && echo "native $GROK_LAUNCHER"
  for d in $NPM_PREFIXES; do
    [ -n "$pkg" ] && [ -d "$d/lib/node_modules/$pkg" ] && [ -x "$d/bin/$cli" ] && echo "npm $d/bin/$cli"
  done
  for d in $LINK_DIRS; do [ -x "$d/$cli" ] && echo "link $d/$cli"; done
  return 0
}

# best_of <candidate lines on stdin> -> "<version> <launcher> <resolved>" of the
# newest parseable candidate (first one wins a tie: two files of equal version
# are equivalent, and candidates_raw lists the native launcher first).
best_of() {
  local line best="" bv=""
  while read -r line; do
    [ -n "$line" ] || continue
    case "$line" in missing\ *) continue ;; esac
    if [ -z "$best" ] || cli_version_gt "${line%% *}" "$bv"; then best="$line"; bv="${line%% *}"; fi
  done
  [ -n "$best" ] && echo "$best"
}

# npm_update <pkg> -> rc; sets METHOD_NOTE. --force ONLY after an EEXIST /
# ENOTEMPTY, which are npm's words for "something not mine is at the path I
# link" (the hand-made /usr/bin/codex on project-9) — a network or registry
# failure is retried by tomorrow's tick, never forced.
npm_update() {
  local pkg="$1" rc
  run_logged "npm install -g $pkg@latest" npm install -g "$pkg@latest"; rc=$?
  if [ $rc -ne 0 ] && grep -qE 'EEXIST|ENOTEMPTY' <<<"$RUN_OUT"; then
    log "npm $pkg: EEXIST/ENOTEMPTY — retrying with --force"
    run_logged "npm install -g --force $pkg@latest" npm install -g --force "$pkg@latest"; rc=$?
    [ $rc -eq 0 ] && METHOD_NOTE="${METHOD_NOTE}npm-forced;"
  fi
  return $rc
}

# relink <cli> <best-version> <best-launcher> <best-resolved>
#   Every SYMLINK in LINK_DIRS that resolves to something older than the best
#   install is repointed at the best launcher, old link saved beside it. A
#   regular file is reported, never replaced — that is someone's deliberate
#   install and overwriting it is how the next incident starts.
relink() {
  local cli="$1" bv="$2" bl="$3" br="$4" d p v r
  for d in $LINK_DIRS; do
    p="$d/$cli"
    [ -e "$p" ] || [ -L "$p" ] || continue
    r=$(readlink -f "$p" 2>/dev/null || echo "")
    [ "$r" = "$br" ] && continue
    v=$(cli_version_of "$p")
    if cli_version_ge "$v" "$bv"; then continue; fi
    if [ -L "$p" ]; then
      cp -P "$p" "$p.bak-$(date -u +%Y%m%d%H%M)" 2>/dev/null
      if ln -sfn "$bl" "$p" 2>>"$LOG"; then
        log "$cli: relinked $p ($v -> $bv, now -> $bl; old link backed up)"
        METHOD_NOTE="${METHOD_NOTE}relinked $p;"
      else
        log "$cli: could NOT relink $p (still $v; best is $bv at $bl)"
        METHOD_NOTE="${METHOD_NOTE}relink-failed $p;"
      fi
    else
      log "$cli: $p is a regular file at $v, older than $bv at $bl — NOT touched (replace it by hand)"
      METHOD_NOTE="${METHOD_NOTE}stale-file $p=$v;"
    fi
  done
}

RC=0
for CLI in $CLIS; do
  PKG=$(pkg_for "$CLI")
  METHOD=""; METHOD_NOTE=""; GROK_DL=""
  AT=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  hash -r 2>/dev/null
  BEFORE_PATH=$(cli_path_of "$CLI")
  BEFORE=$(cli_version_of "${BEFORE_PATH:-/nonexistent}")
  log "$CLI: before $BEFORE at ${BEFORE_PATH:-<not on PATH>} -> $(readlink -f "${BEFORE_PATH:-/nonexistent}" 2>/dev/null || echo -)"

  # --- what installs exist -------------------------------------------------
  HAS_NATIVE=0; HAS_NPM=0
  NATIVE="$HOMEDIR/.local/bin/$CLI"
  [ "$CLI" = claude ] && [ -x "$NATIVE" ] && HAS_NATIVE=1
  [ "$CLI" = grok ] && [ -x "$GROK_LAUNCHER" ] && HAS_NATIVE=1
  for d in $NPM_PREFIXES; do [ -n "$PKG" ] && [ -d "$d/lib/node_modules/$PKG" ] && HAS_NPM=1; done
  # A PATH binary that lives under the native versions dir is a native install
  # even if the launcher is not where we expect it.
  case "$(readlink -f "${BEFORE_PATH:-/nonexistent}" 2>/dev/null)" in
    "$HOMEDIR"/.local/share/claude/*) HAS_NATIVE=1 ;;
    "$HOMEDIR"/.grok/downloads/*)     HAS_NATIVE=1 ;;
  esac

  # --- update each install ---------------------------------------------------
  if [ "$CLI" = grok ]; then
    # One mechanism whether or not anything is installed: re-running the
    # installer IS the update, and on a box with no grok at all it is the
    # bootstrap (small, 2026-09-22). PKG is empty for grok, so the npm branch
    # below never fires for it.
    METHOD="${METHOD}native+"
    grok_update || true
  elif [ "$HAS_NATIVE" = 1 ]; then
    METHOD="${METHOD}native+"
    if [ -x "$NATIVE" ]; then NB="$NATIVE"; else NB="$BEFORE_PATH"; fi
    if run_logged "$NB install latest" "$NB" install latest; then :; else
      log "$CLI: native install latest FAILED (rc=$?) — see above"; METHOD_NOTE="${METHOD_NOTE}native-failed;"
    fi
  fi
  if [ "$HAS_NPM" = 1 ] || { [ "$HAS_NATIVE" = 0 ] && [ -n "$PKG" ]; }; then
    # No install of any kind found: npm is the bootstrap path, so try it.
    [ "$HAS_NPM" = 1 ] || log "$CLI: no install found — bootstrapping through npm"
    METHOD="${METHOD}npm+"
    if [ -n "$PKG" ] && command -v npm >/dev/null 2>&1; then
      npm_update "$PKG" || { log "$CLI: npm update FAILED — keeping what is installed"; METHOD_NOTE="${METHOD_NOTE}npm-failed;"; }
    else
      log "$CLI: npm not available — cannot update the npm install"; METHOD_NOTE="${METHOD_NOTE}no-npm;"
    fi
  fi
  METHOD="${METHOD%+}"; [ -n "$METHOD" ] || METHOD=none

  # --- reconcile the links so every PATH sees the newest -------------------
  hash -r 2>/dev/null
  CANDS=$(candidates "$CLI" "$PKG")
  BEST=$(best_of <<<"$CANDS")
  if [ -n "$BEST" ]; then
    read -r BV BL BR <<<"$BEST"
    log "$CLI: installs:$(printf '\n%s' "$CANDS" | sed 's/^/ /' | tr '\n' ' ')"
    relink "$CLI" "$BV" "$BL" "$BR"
    # Nothing on PATH at all, but an install exists: give PATH one link, in the
    # first managed dir PATH actually contains, so the lanes can find it.
    hash -r 2>/dev/null
    if ! command -v "$CLI" >/dev/null 2>&1; then
      for d in $LINK_DIRS; do
        case ":$PATH:" in *":$d:"*) ;; *) continue ;; esac
        if ln -sfn "$BL" "$d/$CLI" 2>>"$LOG"; then
          log "$CLI: was not on PATH — linked $d/$CLI -> $BL"; METHOD_NOTE="${METHOD_NOTE}linked $d/$CLI;"
        fi
        break
      done
    fi
  fi

  # --- after -----------------------------------------------------------------
  hash -r 2>/dev/null
  AFTER_PATH=$(cli_path_of "$CLI")
  AFTER=$(cli_version_of "${AFTER_PATH:-/nonexistent}")
  # Retention, now that it is known whether anything moved. A run that changed
  # nothing must leave the real previous release alone.
  if [ "$CLI" = grok ] && [ -n "$GROK_DL" ]; then
    if [ "$AFTER" != "$BEFORE" ] && [ -d "$GROK_DL.prev.tmp" ]; then
      rm -rf "$GROK_DL.prev"
      if mv "$GROK_DL.prev.tmp" "$GROK_DL.prev" 2>>"$LOG"; then
        log "grok: previous release kept at $GROK_DL.prev — rollback: mv $GROK_DL.prev/grok-linux-x64 $GROK_DL/grok-linux-x64"
        METHOD_NOTE="${METHOD_NOTE}prev-kept;"
      fi
    fi
    rm -rf "$GROK_DL.prev.tmp"
  fi
  OK=1
  if [ "$AFTER" = missing ]; then OK=0; RC=1; log "$CLI: MISSING after update"
  elif ! cli_version_ge "$AFTER" "$BEFORE"; then OK=0; RC=1; log "$CLI: WORSE after update ($BEFORE -> $AFTER)"
  fi
  # A newer install that PATH still does not resolve is worth a word even when
  # nothing got worse: it is exactly the split the check script alerts on.
  if [ -n "${BV:-}" ] && [ "$AFTER" != missing ] && cli_version_gt "$BV" "$AFTER"; then
    METHOD_NOTE="${METHOD_NOTE}path-behind-best $BV@$BL;"
  fi
  NOTE=$(printf '%s' "$METHOD_NOTE" | tr -d ',\n' | sed 's/;$//')
  [ "$BEFORE" != "$AFTER" ] && log "$CLI: $BEFORE -> $AFTER ($METHOD)"
  echo "$AT,$BOX,$CLI,$BEFORE,$AFTER,$METHOD,$OK,${AFTER_PATH:-},$NOTE" >> "$CSV"
  echo "$CLI $BEFORE -> $AFTER method=$METHOD ok=$OK path=${AFTER_PATH:--} ${NOTE:+note=$NOTE}"
  if declare -F metric_cli_version >/dev/null 2>&1; then
    metric_cli_version "$BOX" "$CLI" "$BEFORE" "$AFTER" "$METHOD" "$OK" "$AT" "${AFTER_PATH:-}" "$NOTE" update \
      || log "$CLI: DB push skipped/failed (http=${JOBS_HTTP:-none}) — CSV row is the record"
  fi
  # BH-1517: hub-scoped — only the hub's view of "current" is the fleet's floor
  # for bin/fly-image-build.sh to pin against. Written only on a genuine success
  # (OK=1, AFTER present); a failed or WORSE update leaves the last good row.
  if [ "$OK" = 1 ] && [ "$AFTER" != missing ] && declare -F setting_set >/dev/null 2>&1 \
     && declare -F is_hub_box >/dev/null 2>&1 && is_hub_box "$(local_box_name)"; then
    SKEY=""
    case "$CLI" in claude) SKEY=cli.claude_code.version ;; codex) SKEY=cli.codex.version ;; esac
    if [ -n "$SKEY" ]; then
      setting_set "$SKEY" "$AFTER" "hub's current $CLI version (bin/cli-update.sh, BH-1517)" \
        || log "$CLI: setting $SKEY not written (worker unreachable or refused) — CSV is the record"
    fi
  fi
  unset BV BL BR SKEY
done

# --- system tools: flyctl and gh (BH-6742) -----------------------------------
# A scratch box (CLI_UPDATE_HOME set, tests only) never reaches the real apt or
# a real flyctl unless it names CLI_UPDATE_SYS_TOOLS itself.
if [ -n "${CLI_UPDATE_HOME:-}" ]; then SYS_TOOLS="${CLI_UPDATE_SYS_TOOLS-}"; else SYS_TOOLS="${CLI_UPDATE_SYS_TOOLS-flyctl gh}"; fi
APT_ETC="${CLI_UPDATE_APT_ETC:-/etc/apt}"
GH_KEY_URL="${CLI_UPDATE_GH_KEY_URL:-https://cli.github.com/packages/githubcli-archive-keyring.gpg}"
GH_LIST="$APT_ETC/sources.list.d/github-cli.list"
GH_KEYRING="$APT_ETC/keyrings/githubcli-archive-keyring.gpg"

# sys_record <tool> <before> <after> <method> <path> <note> — the same CSV row,
# stdout line and DB push as a runner CLI. Sets RC=1 when it ended worse.
sys_record() {
  local tool="$1" before="$2" after="$3" method="$4" path="$5" note="$6" ok=1 at
  at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  if [ "$after" = missing ]; then ok=0; RC=1; log "$tool: MISSING after update"
  elif ! cli_version_ge "$after" "$before"; then ok=0; RC=1; log "$tool: WORSE after update ($before -> $after)"
  fi
  note=$(printf '%s' "$note" | tr -d ',\n' | sed 's/;$//')
  [ "$before" != "$after" ] && log "$tool: $before -> $after ($method)"
  echo "$at,$BOX,$tool,$before,$after,$method,$ok,$path,$note" >> "$CSV"
  echo "$tool $before -> $after method=$method ok=$ok path=${path:--} ${note:+note=$note}"
  if declare -F metric_cli_version >/dev/null 2>&1; then
    metric_cli_version "$BOX" "$tool" "$before" "$after" "$method" "$ok" "$at" "$path" "$note" update \
      || log "$tool: DB push skipped/failed (http=${JOBS_HTTP:-none}) — CSV row is the record"
  fi
}

# flyctl_update — on a box that has flyctl. Keeps the previous binary.
flyctl_update() {
  local bin real before after note=""
  bin="$HOMEDIR/.fly/bin/flyctl"
  [ -x "$bin" ] || bin=$(command -v flyctl 2>/dev/null || command -v fly 2>/dev/null || true)
  [ -n "$bin" ] && [ -x "$bin" ] || { log "flyctl: not installed on this box — skipped"; return 0; }
  real=$(readlink -f "$bin" 2>/dev/null || echo "$bin")
  before=$(cli_version_of "$bin")
  rm -f "$real.prev.tmp"
  cp -p "$real" "$real.prev.tmp" 2>>"$LOG" || { log "flyctl: could not copy $real — no rollback copy, update skipped"; sys_record flyctl "$before" "$before" upgrade "$bin" "no-prev-copy;skipped"; return 0; }
  if ! run_logged "flyctl version upgrade" "$bin" version upgrade; then
    note="${note}upgrade-failed;"; log "flyctl: version upgrade FAILED — keeping what is installed"
  fi
  after=$(cli_version_of "$bin")
  if [ "$after" = missing ] || ! cli_version_ge "$after" "$before"; then
    if cp -p "$real.prev.tmp" "$real" 2>>"$LOG"; then
      log "flyctl: $after after the upgrade — restored the previous binary ($before)"
      note="${note}restored-prev;"; after=$(cli_version_of "$bin")
    fi
    rm -f "$real.prev.tmp"
  elif [ "$after" != "$before" ]; then
    mv -f "$real.prev.tmp" "$real.prev" 2>>"$LOG" && note="${note}prev-kept;" \
      && log "flyctl: previous $before kept at $real.prev — rollback: cp -p $real.prev $real"
  else
    rm -f "$real.prev.tmp"
  fi
  sys_record flyctl "$before" "$after" upgrade "$bin" "$note"
}

# gh_update — gh from GitHub's own apt repo. Needs apt-get and root.
gh_update() {
  local before after pkgv note="" bin
  command -v apt-get >/dev/null 2>&1 || { log "gh: no apt-get on this box — skipped"; return 0; }
  bin=$(command -v gh 2>/dev/null || true)
  before=$(cli_version_of "${bin:-/nonexistent}")
  pkgv=$(dpkg-query -W -f='${Version}' gh 2>/dev/null || true)
  if [ ! -s "$GH_LIST" ] || [ ! -s "$GH_KEYRING" ]; then
    mkdir -p "$APT_ETC/keyrings" "$APT_ETC/sources.list.d" 2>>"$LOG"
    if run_logged "curl $GH_KEY_URL" curl -fsSL -o "$GH_KEYRING.tmp" "$GH_KEY_URL" && [ -s "$GH_KEYRING.tmp" ]; then
      mv -f "$GH_KEYRING.tmp" "$GH_KEYRING" && chmod 644 "$GH_KEYRING"
      printf 'deb [arch=%s signed-by=%s] https://cli.github.com/packages stable main\n' \
        "$(dpkg --print-architecture 2>/dev/null || echo amd64)" "$GH_KEYRING" > "$GH_LIST"
      log "gh: added GitHub's apt repo ($GH_LIST)"; note="${note}repo-added;"
    else
      rm -f "$GH_KEYRING.tmp"
      log "gh: could not fetch GitHub's apt key — keeping what is installed"
      sys_record gh "$before" "$before" apt "${bin:-}" "key-fetch-failed"; return 0
    fi
  fi
  if run_logged "apt-get update (github-cli.list)" apt-get update -o "Dir::Etc::sourcelist=$GH_LIST" \
       -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0; then
    run_logged "apt-get install gh" env DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::=--force-confold gh \
      || { note="${note}install-failed;"; log "gh: apt-get install FAILED — apt keeps the old package"; }
  else
    note="${note}apt-update-failed;"; log "gh: apt-get update of the GitHub list FAILED — keeping what is installed"
  fi
  hash -r 2>/dev/null; bin=$(command -v gh 2>/dev/null || true)
  after=$(cli_version_of "${bin:-/nonexistent}")
  if { [ "$after" = missing ] || ! cli_version_ge "$after" "$before"; } && [ -n "$pkgv" ]; then
    if run_logged "apt-get install gh=$pkgv" env DEBIAN_FRONTEND=noninteractive apt-get install -y --allow-downgrades "gh=$pkgv"; then
      note="${note}restored-prev;"; hash -r 2>/dev/null; bin=$(command -v gh 2>/dev/null || true)
      after=$(cli_version_of "${bin:-/nonexistent}")
    fi
  fi
  sys_record gh "$before" "$after" apt "${bin:-}" "$note"
}

for TOOL in $SYS_TOOLS; do
  case "$TOOL" in
    flyctl) flyctl_update ;;
    gh)     gh_update ;;
    *)      log "unknown system tool '$TOOL' in CLI_UPDATE_SYS_TOOLS — skipped" ;;
  esac
done
exit "$RC"
