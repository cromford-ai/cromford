#!/bin/bash
# bin/hub-move.sh — move the hub to a dedicated Fly machine (BH-7715). An
# operator runs it on the OLD hub; `tick` also runs on the target over ssh.
# The runbook is docs/notes/2026-10-20-BH-7715-hub-move.md.
#
# usage:
#   bin/hub-move.sh inventory
#   bin/hub-move.sh provision [--plan]
#   bin/hub-move.sh seed [<ts>|latest]
#   bin/hub-move.sh tick [--real] [--lanes <id,...>]
#   bin/hub-move.sh dry-run [--plan]
#   bin/hub-move.sh cutover (--step C1..C8 | --all) [--confirm] [--force-drain]
#   bin/hub-move.sh rollback [--confirm]
#   bin/hub-move.sh proof [--since <ISO>] [--until <ISO>]
#   bin/hub-move.sh drain
#
# inventory  print every hub role and how it moves, from live sources. Key
#            NAMES only, never an env value.
# provision  Fly only. Create the Fly app, the volume, the staged secrets (TS_AUTHKEY,
#            HUB_AUTHORIZED_KEY) and the machine. Each create runs only after
#            its find answered "absent"; a find that cannot read stops the run
#            and creates nothing. Then wait for the tailnet hostname and write
#            state/hub-move/target.json. --plan prints each action, calls nothing.
#            A non-Fly host (BH-8038, e.g. Hetzner bh-hub-2): write target.json
#            by hand ({"provider":"hetzner","ts_ip":..,"ts_hostname":..}) and
#            skip provision; provision refuses a provider other than fly, and
#            no later verb needs a machine id.
# seed       copy the age identity, the BACKUP_S3_* keys, the hub ssh keys and
#            the harness code to the target; run state-restore.sh --apply and
#            migrate-env-dir.sh there; check state/box-id and state/box-name;
#            then bootstrap-machine.sh --repos-only for each fleet.conf project.
#            Then set a LOCAL flags/all-off on the target (never a fleet row)
#            and write state/hub-move/target-seeded there. Both stay until C6.
#            BH-8108: each ssh key is copied alone; a target key with the
#            same sha256 is not copied, and a different immutable one gets
#            chattr -i, the copy, then chattr +i.
# tick       run each rendered hub cron command once (bin/render-cron.sh <box-id>;
#            comments, env lines and @reboot skipped; the gate kept). Without
#            --real it runs under the no-write shim (bin/lib/hub-move-nowrite.sh)
#            and runs `bin/harness-sync.sh deploy` first; it exports
#            FLY_BIN_DIR=<shim dir> and HUB_MOVE_NOWRITE=1 (alerts-supersede.py
#            reads it as --dry), and it refuses when
#            HUB_MOVE_FLY_HOME_BIN/flyctl (/root/.fly/bin) exists. Both modes
#            fail (exit 4) when bin/lib/fly-bin.sh finds no flyctl. Writes
#            state/hub-move/tick-<ts>.tsv (`lane rc secs refused timed_out`)
#            and each lane's output to state/hub-move/tick-<ts>.out/<row>.out
#            (a trailing >/dev/null / 2>&1 on the cron line is removed, so the
#            output is kept). BH-8195: a lane whose command names an absent
#            /bin/ path is not run: one `tick: <id>: missing script <path>`
#            line, rc 127, and `missing=<n>` at the end of the summary.
#            BH-8038: the cron installers (update-runners,
#            registry-sync, fleet-propagate)
#            never run in a tick (C6 runs update-runners.sh itself); the shim
#            refuses `crontab` writes; a no-write tick runs only on a seeded
#            target (state/hub-move/target-seeded, else exit 3), lifts the
#            local flags/all-off for its lanes and sets it again at the end. On
#            a seeded target, an active crontab line before or after the tick
#            is saved to state/hub-move/target-crontab-found-<ts>.txt and
#            removed, flags/all-off is set, one ALERTS line goes out, the tick
#            table is marked `# mode=<m>-crontab-found` (C1 refuses it), exit 4.
# dry-run    provision, seed latest, tick (no-write) on the target, then print
#            the inventory and the tick table. --plan prints every step, calls
#            nothing.
# cutover    the cut-over steps C1..C8. Without --confirm it prints the step and
#            changes nothing. A step refuses (exit 3) when the step before it is
#            not `ok` in state/hub-move/steps.tsv.
# rollback   stop the target, back it up, restore that backup onto the old hub,
#            put back the saved crontab. Merge stays paused. Needs --confirm.
# proof      load1 load5 load15 nproc load5_per_vcpu, then bin/hub-load-report.sh.
# drain      wait up to HUB_MOVE_DRAIN_TIMEOUT_S for no $HARNESS/bin/ process
#            (hub-move excluded); rc 4 lists what still runs. rollback runs it
#            on the target.
#
# Knobs (env, operator-run, no lane row): HUB_MOVE_APP (harness-hub, exempt in
# catalog/fly-idle-signals.json so bin/fly-idle-reaper.sh never stops it),
# HUB_MOVE_REGION (iad), HUB_MOVE_VM_SIZE (performance-16x), HUB_MOVE_MEM_MB
# (32768), HUB_MOVE_VOLUME_GB (200), HUB_MOVE_TS_HOSTNAME (<box prefix>hub),
# HUB_MOVE_IMAGE (required, no default), HUB_MOVE_TS_WAIT_S (300),
# HUB_MOVE_TICK_TIMEOUT_S (300), HUB_MOVE_TICK_PARALLEL (8),
# HUB_MOVE_DRAIN_TIMEOUT_S (1800), HUB_MOVE_LEASE_WAIT_S (120),
# HUB_MOVE_FLY_HOME_BIN (/root/.fly/bin, the dir the fly-pool lanes prepend),
# HUB_MOVE_TARGET_HARNESS (/root/harness, the harness path on the target),
# HUB_MOVE_OLD_VM_ID (the old hub's Orgo VM id, printed by C8 only),
# HUB_MOVE_C1_ALLOW (empty; a reviewed comma list of tick lane ids that C1
# accepts as failed, e.g. lanes that fail under the shim by design; an id
# also covers its ~N duplicates),
# HUB_MOVE_C1_OLD_WINDOW_S (86400; C1 reads the old hub's cron journal from
# this many seconds before the tick), HUB_MOVE_CRON_JOURNAL (empty; a file in
# journalctl short-unix form that C1 reads in place of journalctl -t CRON),
# HUB_MOVE_TARGET_SECRETS (/root/.config/hub-move), HUB_MOVE_TARGET_SSH_DIR
# (/root/.ssh), HUB_MOVE_SSH_DIR ($HOME/.ssh, the old hub's keys).
#
# Exit: 0 done; 2 usage or a bad knob (nothing done); 3 preflight refused
# (nothing done, one stderr line, one ALERTS line); 4 a step failed (no later
# step ran); 75 Fly answered "rate limited".
set -uo pipefail

SELF_DIR=$(cd "$(dirname "$0")" && pwd)
HARNESS="${HARNESS:-/root/harness}"
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF_DIR/lib/deployment.sh}" || exit 2
# shellcheck source=bin/lib/env-path.sh
. "$SELF_DIR/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s\n' "${1:-$HARNESS}/env"; }
# shellcheck source=bin/lib/hub-move-fly.sh
. "$SELF_DIR/lib/hub-move-fly.sh" || exit 2
# shellcheck source=bin/lib/hub-move-nowrite.sh
. "$SELF_DIR/lib/hub-move-nowrite.sh" || exit 2
# shellcheck source=bin/lib/fly-bin.sh
. "$SELF_DIR/lib/fly-bin.sh" || exit 2
# shellcheck source=bin/lib/flags.sh
. "$SELF_DIR/lib/flags.sh" || exit 2

BIN="$SELF_DIR"
STATE="$HARNESS/state/hub-move"
FLAGS="$HARNESS/flags"
TH="${HUB_MOVE_TARGET_HARNESS:-/root/harness}"
# The orchestrator tree restore-merge writes beside the harness (its
# --orchestrator-live default), on the target and on the old hub.
TORCH="${HUB_MOVE_TARGET_ORCH:-/root/orchestrator}"
LORCH="${HUB_MOVE_ORCH:-/root/orchestrator}"
# The git checkout (bin/harness-sync.sh's default). render-cron.sh resolves its
# ROOT as the parent of its own bin/, and the deployed $HARNESS has no cron/, so
# the crontab renders from the checkout (BH-7715: "no /root/harness/cron/lanes").
CHECKOUT="${HARNESS_CHECKOUT:-/root/harness-checkout}"
TARGET_JSON="$STATE/target.json"
STEPS="$STATE/steps.tsv"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15 -o StrictHostKeyChecking=accept-new)

STAMP() { date -u '+%Y-%m-%d %H:%M:%SZ'; }
now_s() { printf '%s\n' "${HUB_MOVE_NOW:-$(date +%s)}"; }
say() { echo "$(STAMP) [hub-move] $*"; }
usage() { sed -n '6,15p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
# refuse <text> — preflight refusal: one stderr line, one ALERTS line, exit 3.
refuse() {
  echo "hub-move: refused: $*" >&2
  "$BIN/alert-line.sh" --id hub-move-preflight "[hub-move] refused: $*" >/dev/null 2>&1 || true
  exit 3
}
fail() { echo "hub-move: failed: $*" >&2; exit 4; }

hub_id() { local v; v=$(cat "$HARNESS/state/box-id" 2>/dev/null); printf '%s\n' "${v:-hub}"; }

# ---- knobs ------------------------------------------------------------------
APP="${HUB_MOVE_APP:-harness-hub}"
REGION="${HUB_MOVE_REGION:-iad}"
VM_SIZE="${HUB_MOVE_VM_SIZE:-performance-16x}"
MEM_MB="${HUB_MOVE_MEM_MB:-32768}"
VOLUME_GB="${HUB_MOVE_VOLUME_GB:-200}"
TS_HOSTNAME="${HUB_MOVE_TS_HOSTNAME:-${HARNESS_BOX_PREFIX}hub}"
IMAGE="${HUB_MOVE_IMAGE:-}"
TS_WAIT_S="${HUB_MOVE_TS_WAIT_S:-300}"
TICK_TIMEOUT_S="${HUB_MOVE_TICK_TIMEOUT_S:-300}"
TICK_PARALLEL="${HUB_MOVE_TICK_PARALLEL:-8}"
DRAIN_TIMEOUT_S="${HUB_MOVE_DRAIN_TIMEOUT_S:-1800}"
LEASE_WAIT_S="${HUB_MOVE_LEASE_WAIT_S:-120}"
# The directory fly-pool.sh, fly-dispatch.sh and fly-image-refresh.sh prepend to
# PATH. A flyctl there walks past the no-write shim, so a no-write tick refuses.
FLY_HOME_BIN="${HUB_MOVE_FLY_HOME_BIN:-/root/.fly/bin}"
VOLUME_NAME=hub_data
# BH-8038: the lanes that render and INSTALL a crontab. A tick never runs them:
# a no-write tick of update-runners.sh installed the whole hub crontab on the
# target on 2026-10-22. C6 runs update-runners.sh itself after the real tick.
TICK_SKIP_LANES="update-runners registry-sync fleet-propagate"
# The marker seed writes on the target and C6 removes. A no-write tick refuses
# a box without it: on the live hub the crontab check below would remove the
# live crontab.
TARGET_MARK="$STATE/target-seeded"
C1_ALLOW="${HUB_MOVE_C1_ALLOW:-}"
C1_OLD_WINDOW_S="${HUB_MOVE_C1_OLD_WINDOW_S:-86400}"
# The PATH this script started with: the crontab check runs the real crontab,
# never the no-write shim (which refuses `crontab -r`).
HM_PATH0="$PATH"

is_posint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; [ "$1" -gt 0 ] 2>/dev/null; }
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
is_name() { [[ "$1" != *$'\n'* ]] && grep -qE '^[a-z0-9][a-z0-9-]{0,62}$' <<<"$1"; }

check_knobs() {
  local k
  for k in MEM_MB VOLUME_GB TICK_TIMEOUT_S TICK_PARALLEL DRAIN_TIMEOUT_S C1_OLD_WINDOW_S; do
    is_posint "${!k}" || { echo "hub-move: HUB_MOVE_$k='${!k}' is not a positive integer" >&2; exit 2; }
  done
  for k in TS_WAIT_S LEASE_WAIT_S; do
    is_uint "${!k}" || { echo "hub-move: HUB_MOVE_$k='${!k}' is not a whole number" >&2; exit 2; }
  done
  for k in APP REGION VM_SIZE TS_HOSTNAME; do
    is_name "${!k}" || { echo "hub-move: HUB_MOVE_$k='${!k}' is not a valid name" >&2; exit 2; }
  done
  if [ -n "$C1_ALLOW" ] && { [[ "$C1_ALLOW" == *$'\n'* ]] || ! grep -qE '^[A-Za-z0-9._~-]+(,[A-Za-z0-9._~-]+)*$' <<<"$C1_ALLOW"; }; then
    echo "hub-move: HUB_MOVE_C1_ALLOW='$C1_ALLOW' is not a comma list of lane ids" >&2; exit 2
  fi
}

# ---- state files --------------------------------------------------------------
# tj_set <key> <value> — write one field of target.json (tmp + mv).
tj_set() {
  mkdir -p "$STATE" || return 1
  local cur='{}'
  [ -s "$TARGET_JSON" ] && cur=$(cat "$TARGET_JSON")
  printf '%s' "$cur" | jq -c --arg k "$1" --arg v "$2" '.[$k]=$v' > "$TARGET_JSON.tmp" \
    && mv -f "$TARGET_JSON.tmp" "$TARGET_JSON"
}
tj_get() { jq -r --arg k "$1" '.[$k] // empty' "$TARGET_JSON" 2>/dev/null; }
# target_provider — fly (provision wrote target.json, or no provider field) or
# hetzner (an existing host the operator wrote target.json for). Any other
# value refuses: no verb guesses how to treat an unknown host.
target_provider() {
  local p; p=$(tj_get provider)
  case "${p:-fly}" in
    fly|hetzner) printf '%s\n' "${p:-fly}" ;;
    *) refuse "state/hub-move/target.json provider '$p' is not fly or hetzner" ;;
  esac
}

step_record() { # step_record <step> <ok|fail> <detail>
  mkdir -p "$STATE" || return 1
  local tmp="$STEPS.tmp.$$"
  { [ -f "$STEPS" ] && cat "$STEPS"; printf '%s\t%s\t%s\t%s\n' "$(STAMP)" "$1" "$2" "$3"; } > "$tmp" \
    && mv -f "$tmp" "$STEPS"
}
step_status() { [ -f "$STEPS" ] && awk -F'\t' -v s="$1" '$2==s{v=$3} END{print v}' "$STEPS"; }

# ---- target access ------------------------------------------------------------
target_ip() {
  local ip; ip=$(tj_get ts_ip)
  [ -n "$ip" ] || refuse "state/hub-move/target.json has no ts_ip (run provision first)"
  printf '%s\n' "$ip"
}
# on_target <ip> <command> — run one shell command on the target.
on_target() { ssh "${SSH_OPTS[@]}" "root@$1" "$2"; }

# ---- flags (BH-4153: every flag write goes through bin/lib/flags.sh) ----------
# automerge-disabled is a harness_flags row (fleet scope; both hubs read it).
# lane-off-merge-conductor is a pause_flags row with its flags/ mirror.
# all-off is box-local (--local-only, the flags/ file and no row): a fleet
# all-off row would stop the target too. flag_set / flag_clear answer rc 1
# when no worker is configured even though the file changed, so each write is
# proved by the read that follows it, never by its own rc.
# hm_flag_on <name> <reason> [--local-only] — rc 0 when <name> reads ON after.
hm_flag_on() {
  local n="$1" r="$2" mode="${3:---hold-local}"
  flag_set "$mode" "$n" on "$r" >/dev/null 2>&1
  flag_has "$n" >/dev/null 2>&1
}
# hm_flag_off <name> <reason> [--local-only] — rc 0 when <name> reads OFF after
# (flag_has rc 1; rc 2, an unknown answer, is not off).
hm_flag_off() {
  local n="$1" r="$2" rc
  if [ "${3:-}" = --local-only ]; then flag_clear --local-only "$n" "$r" >/dev/null 2>&1
  else flag_clear "$n" "$r" >/dev/null 2>&1; fi
  flag_has "$n" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ]
}
# t_flag <ip> <jobs-client verb and args> — the same verbs on the target,
# through its own bin/jobs-client.sh (which loads the target's env); prints
# nothing, answers the verb's rc.
t_flag() { local ip="$1"; shift; on_target "$ip" "HARNESS=$TH $TH/bin/jobs-client.sh $* >/dev/null 2>&1"; }

# ==== inventory ================================================================
cmd_inventory() {
  local id cron envd f keys n rc
  id=$(hub_id)
  echo "hub-move inventory: hub=$HARNESS_HUB_BOX box_id=$id harness=$HARNESS"
  echo "| Role | Source on old hub | Live value | How it moves |"
  echo "|---|---|---|---|"
  rc=0; cron=$("$CHECKOUT/bin/render-cron.sh" "$id" 2>/dev/null) || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "| Cron lanes | $CHECKOUT/bin/render-cron.sh $id | ERROR render-cron.sh rc=$rc | update-runners.sh on the target (C6) |"
  else
    n=$(printf '%s\n' "$cron" | grep -c . )
    echo "| Cron lanes | $CHECKOUT/bin/render-cron.sh $id | lines=$n commands=$(cron_commands <<<"$cron" | wc -l) gated=$(printf '%s\n' "$cron" | grep -c 'hub-lease.sh check &&') | update-runners.sh on the target (C6) |"
  fi
  echo "| Flags | flags/ | $(ls "$FLAGS" 2>/dev/null | tr '\n' ' ') | state snapshot (C4) |"
  echo "| State | state/ | $(du -sh "$HARNESS/state" 2>/dev/null | cut -f1) | state snapshot (C4) |"
  echo "| Logs | logs/ | $(du -sh "$HARNESS/logs" 2>/dev/null | cut -f1) | state snapshot (C4) |"
  envd=$(harness_env_dir "$HARNESS")
  for f in "$envd"/*; do
    [ -f "$f" ] || continue
    case "$f" in *.pem|*.key) echo "| Env file | $(basename "$f") | (key file) | age-encrypted in the snapshot (C4) |"; continue ;; esac
    keys=$(sed -nE 's/^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=.*/\2/p' "$f" | tr '\n' ' ')
    echo "| Env file | $(basename "$f") | keys: $keys| age-encrypted in the snapshot (C4) |"
  done
  echo "| Age identity | BACKUP_AGE_IDENTITY_FILE | ${BACKUP_AGE_IDENTITY_FILE:+set}${BACKUP_AGE_IDENTITY_FILE:-unset} | scp to the target, mode 600 (seed) |"
  echo "| Hub ssh key | ${HUB_MOVE_SSH_DIR:-$HOME/.ssh}/id_* | $(ls "${HUB_MOVE_SSH_DIR:-$HOME/.ssh}" 2>/dev/null | grep -c '^id_') files | scp to the target /root/.ssh (seed) |"
  echo "| Tailscale identity | this node | $(tailscale ip -4 2>/dev/null | head -1) | a NEW node, hostname $TS_HOSTNAME, secret TS_AUTHKEY from TS_AUTHKEY_HUB (provision) |"
  echo "| GitHub App, Fly, Orgo, R2 keys | env files above | names only | with env (C4) |"
  echo "| Jobs-worker box id | state/box-id, state/box-name | $id, $(cat "$HARNESS/state/box-name" 2>/dev/null) | snapshot; seed checks both (C4) |"
  echo "| Hub lease | holder $HARNESS_HUB_BOX | unchanged | old hub stops renewing at C3, new hub renews at C6 |"
  echo "| Repos | /root/repos/<p> | $("$BIN/fleet-conf.sh" --projects 2>/dev/null | tr '\n' ' ') | bootstrap-machine.sh --repos-only (seed) |"
  echo "| Claude rules | /root/.claude | rendered | update-runners.sh (C6) |"
  echo "| Warm standby | streams box id $id | unchanged | none |"
}

# cron_commands — stdin: crontab text. stdout: one command per line, the
# schedule removed. Skips blank lines, comments, env lines and @reboot.
cron_commands() {
  local line
  while IFS= read -r line; do
    case "$line" in ''|'#'*|[[:space:]]'#'*|@reboot*) continue ;; esac
    grep -qE '^[A-Za-z_][A-Za-z0-9_]*=' <<<"$line" && continue
    case "$line" in
      @*) printf '%s\n' "${line#* }" ;;
      *)  printf '%s\n' "$line" | awk '{ for (i=1;i<=5;i++) sub(/^[^ \t]+[ \t]+/, ""); print }' ;;
    esac
  done
}

# lane_id <command> — the first bin/<x>.sh that is not hub-lease.sh, else word 1.
lane_id() {
  local id
  id=$(printf '%s\n' "$1" | grep -oE '/bin/[A-Za-z0-9._-]+' | sed 's|^/bin/||' | grep -v '^hub-lease\.sh$' | head -1)
  [ -n "$id" ] || id=$(basename "$(printf '%s\n' "$1" | awk '{print $1}')")
  printf '%s\n' "${id%.sh}"
}

# tick_missing_script <command> — print the first absolute path in the command
# that holds a /bin/ segment and does not exist on this box; print nothing when
# every such path exists (BH-8195). Tokens split on whitespace and ;&|()<>, with
# quotes removed; a token with a $ or a glob (not expanded here) or a relative one
# is skipped.
tick_missing_script() {
  local tok toks=()
  read -ra toks <<<"$(printf '%s' "$1" | tr ";&|()<>'\"\n" ' ')"
  for tok in "${toks[@]}"; do
    case "$tok" in /*/bin/*|/bin/*) ;; *) continue ;; esac
    case "$tok" in *'$'*|*[*?[]*) continue ;; esac
    [ -e "$tok" ] || { printf '%s\n' "$tok"; return 0; }
  done
  return 0
}

# lane_rows — stdin: crontab text. stdout: `<id>\t<command>` for each cron
# command, the ids the tick table uses (a repeated id is numbered id~2, id~3).
# The tick and C1 both map ids through here, so the two never disagree.
lane_rows() {
  local cmd id
  declare -A seen=()
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    id=$(lane_id "$cmd")
    if [ -n "${seen[$id]:-}" ]; then seen[$id]=$(( ${seen[$id]} + 1 )); id="$id~${seen[$id]}"; else seen[$id]=1; fi
    printf '%s\t%s\n' "$id" "$cmd"
  done < <(cron_commands)
}

# ---- tick safety (BH-8038) ---------------------------------------------------------
# crontab_active — the active lines of this box's crontab (no blank, comment or
# NAME=value line), read with the real crontab.
crontab_active() {
  PATH="$HM_PATH0" crontab -l 2>/dev/null | grep -vE '^[[:space:]]*(#|$)' | grep -vE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*='
}
# tick_cron_guard <before|after> [<tick-file>] — rc 0 when this box has no
# active crontab line. Else: save the crontab, remove it, set the local
# all-off, mark the tick file so C1 refuses it, one ALERTS line, rc 1.
tick_cron_guard() {
  local when="$1" tf="${2:-}" lines saved
  lines=$(crontab_active)
  [ -z "$lines" ] && return 0
  mkdir -p "$STATE"
  saved="$STATE/target-crontab-found-$(date -u +%Y%m%dT%H%M%SZ)-$$.txt"
  PATH="$HM_PATH0" crontab -l > "$saved" 2>/dev/null
  PATH="$HM_PATH0" crontab -r 2>/dev/null
  hm_flag_on all-off "hub-move tick: a crontab was found on the target $when the tick" --local-only \
    || echo "hub-move: cannot set flags/all-off on this box" >&2
  if [ -n "$tf" ] && [ -f "$tf" ]; then
    sed -i '1s/^# mode=\([a-z]*\) /# mode=\1-crontab-found /' "$tf" 2>/dev/null
  fi
  "$BIN/alert-line.sh" --id hub-move-tick-crontab "[hub-move] tick: $(printf '%s\n' "$lines" | wc -l) active crontab line(s) on the target $when the tick; removed (saved $saved), flags/all-off set" >/dev/null 2>&1 || true
  echo "hub-move: failed: a crontab is installed on this box $when the tick ($(printf '%s\n' "$lines" | wc -l) active lines); removed, saved to $saved, flags/all-off set" >&2
  [ -z "$(crontab_active)" ] || echo "hub-move: the crontab is STILL installed after crontab -r" >&2
  return 1
}
# strip_devnull <command> — the command without a trailing redirect group that
# sends output to /dev/null (`>/dev/null 2>&1`, `2>/dev/null >/dev/null`,
# `&>/dev/null`), so the tick keeps the output. A group with no /dev/null
# (`>> log 2>&1`) is kept as it is.
strip_devnull() {
  local c="$1" t dn=0 tail=""
  # A trailing `|| true` / `|| :` stays; the redirect group before it goes.
  if [[ "$c" =~ ^(.*[^[:space:]])[[:space:]]*(\|\|[[:space:]]*(true|:))[[:space:]]*$ ]]; then
    c="${BASH_REMATCH[1]}"; tail=" ${BASH_REMATCH[2]}"
  fi
  while :; do
    t=$(printf '%s' "$c" | sed -E 's/[[:space:]]*([12]?>>?|&>>?)[[:space:]]*\/dev\/null[[:space:]]*$//')
    if [ "$t" != "$c" ]; then c="$t"; dn=1; continue; fi
    t=$(printf '%s' "$c" | sed -E 's/[[:space:]]*[12]?>&[12][[:space:]]*$//')
    if [ "$t" != "$c" ]; then c="$t"; continue; fi
    break
  done
  if [ "$dn" -eq 1 ]; then printf '%s\n' "$c$tail"; else printf '%s\n' "$1"; fi
}

# ---- the old hub's rc for a lane (C1, BH-8038) ------------------------------------
# cron_journal <t0> <out-file> — the cron journal of this box (the old hub) since
# epoch <t0>, in journalctl short-unix form, into <out-file>. rc 0, or rc 1 with
# the reason on stdout. HUB_MOVE_CRON_JOURNAL names a file to read instead.
cron_journal() {
  local t0="$1" out="$2" rc
  if [ -n "${HUB_MOVE_CRON_JOURNAL:-}" ]; then
    cat "$HUB_MOVE_CRON_JOURNAL" > "$out" 2>/dev/null || { echo "cannot read the cron journal file $HUB_MOVE_CRON_JOURNAL"; return 1; }
    return 0
  fi
  command -v journalctl >/dev/null 2>&1 || { echo "no journalctl on this box"; return 1; }
  journalctl -t CRON -o short-unix --since "@$t0" --no-pager -q > "$out" 2>/dev/null; rc=$?
  [ "$rc" -eq 0 ] || { echo "journalctl -t CRON failed (rc=$rc)"; return 1; }
}
# journal_rc <t0> <journal-file> — env WANT: one cron command. Prints the rc of
# the newest run of WANT at or after epoch <t0>, or `none` when no run is in the
# journal. cron logs `CRON[<pid>]: (<user>) CMD (<command>)` at the start and
# `CRON[<pid>]: (CRON) error (grandchild #<n> failed with exit status <rc>)` for
# a non-zero exit, from the same pid. A run with no error line reads rc 0, so a
# gap in the journal can only keep a target failure, never hide one.
journal_rc() {
  awk -v t0="$1" '
    BEGIN { want = ENVIRON["WANT"]; found = 0 }
    { if ($1 + 0 < t0) next
      if (!match($0, /CRON\[[0-9]+\]: /)) next
      pid = substr($0, RSTART + 5, RLENGTH - 8); rest = substr($0, RSTART + RLENGTH)
      if (match(rest, /^\([^)]*\) CMD \(/)) {
        txt = substr(rest, RLENGTH + 1); sub(/\)[ \t]*$/, "", txt)
        if (txt == want || (length(txt) >= 200 && index(want, txt) == 1)) { found = 1; last = pid; rc = 0; mine[pid] = 1 } else mine[pid] = 0
        next
      }
      if (pid == last && mine[pid] == 1 && match(rest, /failed with exit status [0-9]+/)) {
        s = substr(rest, RSTART, RLENGTH); sub(/.* /, "", s); rc = s + 0
      }
    }
    END { if (found) print rc; else print "none" }' "$2"
}

# ==== provision ================================================================
cmd_provision() {
  local plan=0 a
  for a in "$@"; do case "$a" in --plan) plan=1 ;; *) usage ;; esac; done
  check_knobs
  if [ "$plan" -eq 1 ]; then
    [ -n "$IMAGE" ] || echo "hub-move: HUB_MOVE_IMAGE is not set: a real provision exits 2"
    echo "PLAN provision 1/6: app $APP (find, then create in org \$FLY_ORG if absent)"
    echo "PLAN provision 2/6: volume $VOLUME_NAME ${VOLUME_GB} GB in $REGION (find, then create if absent)"
    echo "PLAN provision 3/6: stage secret TS_AUTHKEY from TS_AUTHKEY_HUB (only when no machine exists)"
    echo "PLAN provision 4/6: stage secret HUB_AUTHORIZED_KEY from the hub id_*.pub (only when no machine exists)"
    echo "PLAN provision 5/6: machine image=${IMAGE:-<HUB_MOVE_IMAGE>} --vm-size $VM_SIZE --vm-memory $MEM_MB -v <volume>:/data --restart always (find, then run if absent)"
    echo "PLAN provision 6/6: wait up to ${TS_WAIT_S}s for tailnet host $TS_HOSTNAME, then write state/hub-move/target.json"
    return 0
  fi
  local prov; prov=$(target_provider) || exit 3
  [ "$prov" = fly ] || refuse "provision is Fly-only; state/hub-move/target.json says provider=$prov (an existing host: keep target.json, skip provision)"
  [ -n "$IMAGE" ] || { echo "hub-move: HUB_MOVE_IMAGE is not set (the pushed hub image ref)" >&2; exit 2; }

  # preflight: every input before the first call.
  local flyenv pub
  flyenv="$(harness_env_dir "$HARNESS")/fly.env"
  [ -r "$flyenv" ] || refuse "$flyenv is not readable"
  set -a
  # shellcheck disable=SC1090
  . "$flyenv" || refuse "$flyenv did not source"
  set +a
  [ -n "${FLY_ORG:-}" ] || refuse "FLY_ORG is not set in fly.env"
  [ -n "${FLY_API_TOKEN:-}" ] || refuse "FLY_API_TOKEN is not set in fly.env"
  [ -n "${TS_AUTHKEY_HUB:-}" ] || refuse "TS_AUTHKEY_HUB is not set in fly.env (mint a tagged key for the hub)"
  pub=$(ls "${HUB_MOVE_SSH_DIR:-$HOME/.ssh}"/id_*.pub 2>/dev/null | head -1)
  [ -n "$pub" ] || refuse "no hub ssh public key in ${HUB_MOVE_SSH_DIR:-$HOME/.ssh}"
  export FLY_API_TOKEN FLY_ACCESS_TOKEN="$FLY_API_TOKEN"

  local rc vid mid ip waited
  # 1. app
  hmf_app_exists "$APP"; rc=$?
  case "$rc" in
    0) say "app $APP exists" ;;
    1) say "creating app $APP"; hmf_app_create "$APP" "$FLY_ORG"; rc=$?
       [ "$rc" -eq 0 ] || { [ "$rc" -eq 75 ] && exit 75; fail "apps create $APP"; } ;;
    75) exit 75 ;;
    *) fail "cannot read the Fly app list; nothing created" ;;
  esac
  tj_set provider fly; tj_set app "$APP"; tj_set region "$REGION"; tj_set size "$VM_SIZE/${MEM_MB}MB/${VOLUME_GB}GB"; tj_set ts_hostname "$TS_HOSTNAME"

  # 2. volume
  vid=$(hmf_volume_find "$APP" "$VOLUME_NAME"); rc=$?
  case "$rc" in
    0) say "volume $VOLUME_NAME exists ($vid)" ;;
    1) say "creating volume $VOLUME_NAME ${VOLUME_GB} GB in $REGION"
       hmf_volume_create "$APP" "$VOLUME_NAME" "$VOLUME_GB" "$REGION"; rc=$?
       [ "$rc" -eq 0 ] || { [ "$rc" -eq 75 ] && exit 75; fail "volumes create"; }
       vid=$(hmf_volume_find "$APP" "$VOLUME_NAME") || fail "volume created but not found" ;;
    75) exit 75 ;;
    *) fail "cannot read the volumes of $APP; nothing created" ;;
  esac
  tj_set volume_id "$vid"

  # 3-5. machine (secrets are staged only for a machine that does not exist yet)
  mid=$(hmf_machine_find "$APP"); rc=$?
  case "$rc" in
    0) say "machine exists ($mid)" ;;
    1) say "staging secrets TS_AUTHKEY, HUB_AUTHORIZED_KEY"
       printf '%s\n' "$TS_AUTHKEY_HUB" | hmf_secret_set_stage "$APP" TS_AUTHKEY; rc=$?
       [ "$rc" -eq 0 ] || { [ "$rc" -eq 75 ] && exit 75; fail "secrets import TS_AUTHKEY"; }
       hmf_secret_set_stage "$APP" HUB_AUTHORIZED_KEY < "$pub"; rc=$?
       [ "$rc" -eq 0 ] || { [ "$rc" -eq 75 ] && exit 75; fail "secrets import HUB_AUTHORIZED_KEY"; }
       say "creating machine $VM_SIZE ${MEM_MB} MB image=$IMAGE"
       hmf_machine_run "$APP" "$IMAGE" "$VM_SIZE" "$MEM_MB" "$vid" "$REGION" "$TS_HOSTNAME"; rc=$?
       [ "$rc" -eq 0 ] || { [ "$rc" -eq 75 ] && exit 75; fail "machine run"; }
       mid=$(hmf_machine_find "$APP") || fail "machine created but not found" ;;
    75) exit 75 ;;
    *) fail "cannot read the machines of $APP; nothing created" ;;
  esac
  tj_set machine_id "$mid"

  # 6. tailnet
  waited=0
  while :; do
    ip=$(tailscale status --json 2>/dev/null | jq -r --arg h "$TS_HOSTNAME" \
      '[(.Peer // {})[] | select((.HostName // "" | ascii_downcase) == $h) | .TailscaleIPs[]? | select(test(":") | not)][0] // empty' 2>/dev/null)
    [ -n "$ip" ] && break
    [ "$waited" -ge "$TS_WAIT_S" ] && fail "tailnet host $TS_HOSTNAME did not appear in ${TS_WAIT_S}s"
    sleep 10; waited=$((waited + 10))
  done
  tj_set ts_ip "$ip"; tj_set provisioned_at "$(STAMP)"
  say "DONE app=$APP machine=$mid volume=$vid ts_ip=$ip"
}

# ==== seed =====================================================================
# clean_swap_script <live> <orch> <fresh> <prev> — print a bash script that
# moves the clean restore in <fresh> over <live> (lead BLOCK #3203 on #7757).
# restore-merge.sh keeps a live file that differs from the snapshot (its rule
# 5), so a restore with --live on a tree that already has state would keep
# dry-run-era state, flags and env on the target, and keep pre-cut-over state
# on the old hub at rollback. The restore therefore runs with --live <fresh>
# (an empty tree, so every snapshot file is ADDed) and this script swaps each
# restored top-level dir in. The dirs it replaces go to <prev>, never deleted.
clean_swap_script() {
  local live="$1" orch="$2" fresh="$3" prev="$4"
  cat <<EOF
set -u
mkdir -p "$prev" || exit 1
for d in state flags logs; do
  [ -e "$fresh/\$d" ] || continue
  if [ -e "$live/\$d" ]; then mv "$live/\$d" "$prev/\$d" || exit 1; fi
  mv "$fresh/\$d" "$live/\$d" || exit 1
done
# env: when <live>/env is the compat link (bin/migrate-env-dir.sh), the lanes
# read the dir it points at. Replace that dir and keep the link.
if [ -e "$fresh/env" ]; then
  if [ -L "$live/env" ]; then
    real=\$(readlink -f "$live/env") && [ -n "\$real" ] || exit 1
    if [ -e "\$real" ]; then mv "\$real" "$prev/env-real" || exit 1; fi
    mv "$fresh/env" "\$real" || exit 1
  else
    if [ -e "$live/env" ]; then mv "$live/env" "$prev/env" || exit 1; fi
    mv "$fresh/env" "$live/env" || exit 1
  fi
fi
# builds/: the snapshot holds only the build summaries (RESULT, cost.csv,
# plan.md, review.md, pipeline.log; bin/state-backup.sh). Those overwrite their
# live copies; every other build file (reviewed-sha, worktrees) stays.
if [ -d "$fresh/builds" ]; then
  mkdir -p "$live/builds" && cp -a "$fresh/builds/." "$live/builds/" || exit 1
fi
if [ -e "$fresh/orchestrator" ]; then
  if [ -e "$orch" ]; then mv "$orch" "$prev/orchestrator" || exit 1; fi
  mv "$fresh/orchestrator" "$orch" || exit 1
fi
# Only ever the empty tree this script was given, under the harness root.
case "$fresh" in "$HARNESS/"*|"$live/tmp/hub-move-fresh-"*) rm -rf "$fresh" ;; esac
EOF
}

# seed_ssh_key <ip> <local key> <target dir> — copy one hub ssh key to the
# target (BH-8108). bin/harden-state.sh sets chattr +i on id_ed25519* there
# after a no-write tick, and scp cannot open an immutable file. Same sha256:
# no copy. Different and immutable: chattr -i, copy, chmod 600, chattr +i.
# Returns 0 (copied or skipped), 1 (probe failed), 2 (chattr -i failed) or
# 3 (scp failed; chattr +i was tried first). A failed chattr +i after a good
# copy is a WARN line and 0: harden-state sets the flag again on its next run.
seed_ssh_key() {
  local ip="$1" k="$2" dir="$3" b f want line got flags imm=0 rc
  b=$(basename "$k"); f="$dir/$b"
  want=$(sha256sum < "$k" | cut -d' ' -f1)
  line=$(on_target "$ip" "if [ -f $f ]; then s=\$(sha256sum < $f | cut -d' ' -f1); a=\$(lsattr -d $f 2>/dev/null | cut -d' ' -f1); echo \"\${s:--} \${a:--}\"; else echo '- -'; fi") || return 1
  read -r got flags <<<"$line"
  [ -n "$got" ] || return 1
  if [ "$got" = "$want" ]; then
    say "seed: $b on the target is the same as the hub key; copy skipped"
    return 0
  fi
  case "$flags" in *i*) imm=1 ;; esac
  if [ "$imm" -eq 1 ]; then
    on_target "$ip" "chattr -i $f" || return 2
    say "seed: $b on the target is immutable and differs; chattr -i"
  fi
  scp "${SSH_OPTS[@]}" -q "$k" "root@$ip:$f"; rc=$?
  if [ "$imm" -eq 1 ]; then
    if on_target "$ip" "chmod 600 $f 2>/dev/null; chattr +i $f"; then
      say "seed: chattr +i $b again"
    else
      say "seed: WARN chattr +i $b failed on $ip; harden-state re-arms it"
    fi
  fi
  [ "$rc" -eq 0 ] || return 3
}

cmd_seed() {
  local ts="${1:-latest}" ip idf envd tmp k id name want_id rc p
  case "$ts" in latest|[0-9]*T[0-9]*Z) ;; *) usage ;; esac
  ip=$(target_ip) || exit 3
  idf="${BACKUP_AGE_IDENTITY_FILE:-}"
  [ -n "$idf" ] && [ -r "$idf" ] || refuse "BACKUP_AGE_IDENTITY_FILE is not set or not readable"
  envd=$(harness_env_dir "$HARNESS")
  tmp=$(mktemp) || fail "mktemp"
  chmod 600 "$tmp"
  # Only the bucket keys, never printed.
  cat "$envd"/*.env 2>/dev/null | grep -E '^(export[[:space:]]+)?BACKUP_S3_[A-Z_]+=' > "$tmp"
  for k in BACKUP_S3_ENDPOINT BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY; do
    grep -qE "^(export[[:space:]]+)?$k=" "$tmp" || { rm -f "$tmp"; refuse "$k is not set in $envd"; }
  done
  want_id=$(hub_id)
  local sec="${HUB_MOVE_TARGET_SECRETS:-/root/.config/hub-move}" tssh="${HUB_MOVE_TARGET_SSH_DIR:-/root/.ssh}"
  say "seed: secrets to $ip:$sec (identity, bucket keys) and the hub ssh keys"
  on_target "$ip" "mkdir -p $sec $tssh && chmod 700 $sec $tssh" || { rm -f "$tmp"; fail "ssh to $ip"; }
  scp "${SSH_OPTS[@]}" -q "$idf" "root@$ip:$sec/age-identity" \
    && scp "${SSH_OPTS[@]}" -q "$tmp" "root@$ip:$sec/backup-s3.env" \
    || { rm -f "$tmp"; fail "scp secrets to $ip"; }
  rm -f "$tmp"
  for k in "${HUB_MOVE_SSH_DIR:-$HOME/.ssh}"/id_*; do
    [ -f "$k" ] || continue
    seed_ssh_key "$ip" "$k" "$tssh"; rc=$?
    case "$rc" in
      0) ;;
      1) fail "probe ssh key ${k##*/} on $ip" ;;
      2) fail "chattr -i ssh key ${k##*/} on $ip" ;;
      *) fail "scp ssh key ${k##*/} on $ip" ;;
    esac
  done
  on_target "$ip" "chmod 600 $sec/* $tssh/id_* 2>/dev/null; true" || fail "chmod on $ip"

  say "seed: harness code to $ip:$TH"
  on_target "$ip" "mkdir -p $TH" || fail "mkdir $TH on $ip"
  for p in bin prompts catalog; do
    [ -d "$HARNESS/$p" ] || continue
    rsync -a -e "ssh ${SSH_OPTS[*]}" "$HARNESS/$p/" "root@$ip:$TH/$p/" || fail "rsync $p to $ip"
  done
  if [ -f "$HARNESS/fleet.conf" ]; then
    rsync -a -e "ssh ${SSH_OPTS[*]}" "$HARNESS/fleet.conf" "root@$ip:$TH/fleet.conf" || fail "rsync fleet.conf to $ip"
  fi
  local co="$CHECKOUT"
  if [ -d "$co/.git" ]; then
    rsync -a --exclude node_modules -e "ssh ${SSH_OPTS[*]}" "$co/" "root@$ip:$co/" || fail "rsync checkout to $ip"
  fi

  # A new --dest each run: state-restore.sh refuses a destination that exists,
  # and the dry-run seed comes before the C4 seed.
  local run dest fresh prev; run="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  dest="$TH/tmp/hub-move-restore-$run"; fresh="$TH/tmp/hub-move-fresh-$run"; prev="$TH/tmp/hub-move-prev-$run"
  say "seed: state-restore $want_id $ts --apply on $ip into an empty tree"
  on_target "$ip" "mkdir -p $fresh/orchestrator && set -a && . $sec/backup-s3.env && set +a && $TH/bin/state-restore.sh $want_id $ts --apply --identity $sec/age-identity --live $fresh --orchestrator-live $fresh/orchestrator --dest $dest"; rc=$?
  [ "$rc" -eq 0 ] || fail "state-restore on $ip rc=$rc"
  say "seed: swap the restored state, flags, env, logs and orchestrator in (old copies to $prev)"
  clean_swap_script "$TH" "$TORCH" "$fresh" "$prev" | on_target "$ip" "bash -s"; rc=$?
  [ "$rc" -eq 0 ] || fail "swap of the restored tree on $ip rc=$rc (old copies in $prev)"
  on_target "$ip" "$TH/bin/migrate-env-dir.sh --harness $TH"; rc=$?
  [ "$rc" -eq 0 ] || fail "migrate-env-dir on $ip rc=$rc"

  id=$(on_target "$ip" "cat $TH/state/box-id" 2>/dev/null)
  name=$(on_target "$ip" "cat $TH/state/box-name" 2>/dev/null)
  [ "$id" = "$want_id" ] || fail "target state/box-id is '$id', want '$want_id'"
  [ "$name" = "$HARNESS_HUB_BOX" ] || fail "target state/box-name is '$name', want '$HARNESS_HUB_BOX'"
  say "seed: box-id=$id box-name=$name"

  for p in $("$BIN/fleet-conf.sh" --projects 2>/dev/null); do
    say "seed: repos for $p"
    on_target "$ip" "$TH/bin/bootstrap-machine.sh $p --repos-only" >/dev/null || fail "bootstrap-machine $p --repos-only on $ip"
  done
  # BH-8038: a LOCAL all-off on the target (the flags/ file, never a fleet row)
  # until C6, so a stray cron line cannot run a lane there; and the marker that
  # lets a no-write tick run on this box.
  t_flag "$ip" flag-set --local-only all-off on "'hub-move seed: the target stands by until C6'"
  t_flag "$ip" flag-has all-off || fail "seed: flags/all-off does not read on on the target"
  on_target "$ip" "mkdir -p $TH/state/hub-move && date -u '+%Y-%m-%dT%H:%M:%SZ seed $ts' > $TH/state/hub-move/target-seeded" \
    || fail "seed: cannot write state/hub-move/target-seeded on the target"
  say "seed: done ($ts); flags/all-off set on the target until C6"
}

# ==== tick =====================================================================
cmd_tick() {
  local real=0 lanes="" a
  while [ $# -gt 0 ]; do
    case "$1" in
      --real) real=1; shift ;;
      --lanes) [ $# -ge 2 ] || usage; lanes="$2"; shift 2 ;;
      *) usage ;;
    esac
  done
  check_knobs
  local run ts mode cron tsv i cmd id seeded=0
  [ -f "$TARGET_MARK" ] && seeded=1
  # BH-8038: a no-write tick lifts and sets flags/all-off and removes a crontab
  # it finds. On the live hub that would stop the fleet, so it runs only on a
  # box seed marked as the target.
  if [ "$real" -eq 0 ] && [ "$seeded" -eq 0 ]; then
    refuse "no-write tick: this box is not a seeded hub-move target (no $TARGET_MARK; run seed for it first)"
  fi
  if [ "$seeded" -eq 1 ] && ! tick_cron_guard before; then
    # A stub table for the stopped tick, so C1 never reads an older clean one.
    local sm=nowrite sf; [ "$real" -eq 1 ] && sm=real
    sf="$STATE/tick-$(date -u +%Y%m%dT%H%M%SZ).tsv"
    printf '# mode=%s-crontab-found at=%s\nlane\trc\tsecs\trefused\ttimed_out\n' "$sm" "$(now_s)" > "$sf" \
      && echo "tick-file: $sf"
    exit 4
  fi
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  mkdir -p "$STATE" || fail "mkdir $STATE"
  run=$(mktemp -d "$STATE/tick-run.XXXXXX") || fail "mktemp"
  # The pool lanes (fly-pool-tick.sh and the scripts it starts) need flyctl, and
  # fly-pool-tick.sh exits 0 without it, so a lane rc cannot show the gap.
  local flyctl_path
  flyctl_path=$(fly_bin) || fail "flyctl not found on this box (PATH, \$HOME/.fly/bin, ${FLY_BIN_DIR:-/root/.fly/bin}, ${FLY_SYSTEM_DIRS-/usr/local/bin}): the pool lanes cannot run"
  mode=real
  if [ "$real" -eq 0 ]; then
    mode=nowrite
    if [ -x "$FLY_HOME_BIN/flyctl" ]; then
      fail "no-write tick: $FLY_HOME_BIN/flyctl exists, and the fly-pool lanes put $FLY_HOME_BIN before the shim on PATH; install flyctl outside $FLY_HOME_BIN (fly/hub/Dockerfile uses /usr/local/bin)"
    fi
    local pathline
    pathline=$(hmn_make_dir "$run/shim") || fail "no-write shim"
    export PATH="${pathline#PATH=}"
    export FLEET_PROPAGATE_PATH="$PATH"
    # fly-pool.sh prepends $FLY_BIN_DIR; point it at the shim. bin/alerts-supersede.py
    # POSTs through urllib, past the shim, so it reads HUB_MOVE_NOWRITE=1 as --dry.
    export FLY_BIN_DIR="$run/shim" HUB_MOVE_NOWRITE=1
  fi
  cron=$("$CHECKOUT/bin/render-cron.sh" "$(hub_id)") || fail "render-cron.sh $(hub_id) (from $CHECKOUT)"

  local ids=() cmds=()
  if [ "$mode" = nowrite ]; then ids+=("harness-sync-deploy"); cmds+=("$BIN/harness-sync.sh deploy"); fi
  local skipped=()
  while IFS=$'\t' read -r id cmd; do
    if [ -n "$lanes" ]; then case ",$lanes," in *",${id%%~*},"*|*",$id,"*) ;; *) continue ;; esac; fi
    case " $TICK_SKIP_LANES " in *" ${id%%~*} "*) skipped+=("$id"); continue ;; esac
    ids+=("$id"); cmds+=("$(strip_devnull "$cmd")")
  done < <(lane_rows <<<"$cron")
  for id in "${skipped[@]}"; do say "tick: skipped $id (it installs a crontab; C6 runs update-runners.sh)"; done
  [ "${#ids[@]}" -gt 0 ] || fail "no lane to tick"

  # BH-8038: seed set a local all-off on the target. The no-write tick lifts it
  # for its own lanes (else every gated lane exits 0 at its gate and the tick
  # proves nothing) and sets it again however the tick ends.
  local rearm=0
  if [ "$mode" = nowrite ]; then
    rearm=1
    trap 'tick_rearm' EXIT
    PATH="$HM_PATH0" hm_flag_off all-off "hub-move tick: the no-write lanes run" --local-only \
      || fail "no-write tick: cannot lift the local flags/all-off (a fleet all-off row?)"
  fi

  say "tick: flyctl=$flyctl_path"
  say "tick: ${#ids[@]} commands, mode=$mode, parallel=$TICK_PARALLEL, timeout=${TICK_TIMEOUT_S}s"
  local running=0 missing=0 gone
  for i in "${!ids[@]}"; do
    # BH-8195: a lane whose script is absent is not run; one line names the path.
    gone=$(tick_missing_script "${cmds[$i]}")
    if [ -n "$gone" ]; then
      echo "tick: ${ids[$i]}: missing script $gone" | tee "$run/$i.out"
      echo "127 0" > "$run/$i.rc"; missing=$((missing + 1))
      continue
    fi
    while [ "$running" -ge "$TICK_PARALLEL" ]; do wait -n 2>/dev/null; running=$((running - 1)); done
    (
      s=$(date +%s)
      HUB_MOVE_NOWRITE_LOG="$run/$i.nowrite" timeout -k 10 "$TICK_TIMEOUT_S" bash -c "${cmds[$i]}" \
        >"$run/$i.out" 2>&1 </dev/null 9>&-
      echo "$? $(( $(date +%s) - s ))" > "$run/$i.rc"
    ) &
    running=$((running + 1))
  done
  wait

  tsv="$STATE/tick-$ts.tsv"
  local rcs secs ref to n=0 ok=0 bad=0 tout=0 refused=0
  {
    printf '# mode=%s at=%s\n' "$mode" "$(now_s)"
    printf 'lane\trc\tsecs\trefused\ttimed_out\n'
    for i in "${!ids[@]}"; do
      read -r rcs secs < "$run/$i.rc" 2>/dev/null || { rcs=255; secs=0; }
      ref=$(grep -c $'\trefuse\t' "$run/$i.nowrite" 2>/dev/null); ref=${ref:-0}
      to=0; [ "$rcs" = 124 ] || [ "$rcs" = 137 ] && to=1
      printf '%s\t%s\t%s\t%s\t%s\n' "${ids[$i]}" "$rcs" "$secs" "$ref" "$to"
    done
  } > "$tsv.tmp" && mv -f "$tsv.tmp" "$tsv" || fail "write $tsv"
  while IFS=$'\t' read -r id rcs secs ref to; do
    n=$((n + 1)); refused=$((refused + ref))
    if [ "$to" = 1 ]; then tout=$((tout + 1)); elif [ "$rcs" = 0 ]; then ok=$((ok + 1)); else bad=$((bad + 1)); fi
  done < <(grep -v '^#' "$tsv" | tail -n +2)
  column -t -s $'\t' < <(grep -v '^#' "$tsv") 2>/dev/null || grep -v '^#' "$tsv"
  # Keep each lane's output beside the table: tick-<ts>.out/<row>.out, row 1 = first lane.
  mkdir -p "$STATE/tick-$ts.out"
  for i in "${!ids[@]}"; do mv -f "$run/$i.out" "$STATE/tick-$ts.out/$((i + 1)).out" 2>/dev/null; done
  rm -rf "$run"
  echo "tick: lanes=$n ok=$ok fail=$bad timeout=$tout refused_writes=$refused mode=$mode skipped=${#skipped[@]} missing=$missing"
  echo "tick-file: $tsv"
  if [ "$rearm" -eq 1 ]; then tick_rearm; trap - EXIT; fi
  if [ "$seeded" -eq 1 ]; then
    tick_cron_guard after "$tsv" || exit 4
  fi
}
# tick_rearm — set the local all-off again after a no-write tick (once).
TICK_REARMED=0
tick_rearm() {
  [ "$TICK_REARMED" -eq 1 ] && return 0
  TICK_REARMED=1
  PATH="$HM_PATH0" hm_flag_on all-off "hub-move tick: the target stands by until C6" --local-only \
    || echo "hub-move: cannot set flags/all-off again after the tick" >&2
}

# ==== dry-run ==================================================================
cmd_dry_run() {
  local plan=0 a out f ip
  for a in "$@"; do case "$a" in --plan) plan=1 ;; *) usage ;; esac; done
  check_knobs
  if [ "$plan" -eq 1 ]; then
    if [ "$(tj_get provider)" = hetzner ]; then
      echo "PLAN dry-run 1/4: provision skipped (target.json provider=hetzner: an existing host)"
    else
      echo "PLAN dry-run 1/4: provision"
      cmd_provision --plan | sed 's/^/  /'
    fi
    echo "PLAN dry-run 2/4: seed latest: scp the age identity, the BACKUP_S3_* keys and the hub ssh keys to the target; rsync bin/ prompts/ catalog/ fleet.conf and the checkout; state-restore.sh $(hub_id) latest --apply; migrate-env-dir.sh; check box-id=$(hub_id) box-name=$HARNESS_HUB_BOX; bootstrap-machine.sh --repos-only for: $("$BIN/fleet-conf.sh" --projects 2>/dev/null | tr '\n' ' ')"
    echo "PLAN dry-run 3/4: on the target: hub-move.sh tick (no-write): harness-sync.sh deploy, then each command of render-cron.sh $(hub_id) once, at most $TICK_PARALLEL at once, ${TICK_TIMEOUT_S}s each"
    echo "PLAN dry-run 4/4: print the inventory and the tick table"
    return 0
  fi
  local prov; prov=$(target_provider) || exit 3
  if [ "$prov" = fly ]; then
    ( cmd_provision ) || exit $?
  else
    say "dry-run: provision skipped (target.json provider=$prov: an existing host)"
  fi
  ( cmd_seed latest ) || exit $?
  ip=$(target_ip) || exit 3
  out=$(on_target "$ip" "HARNESS=$TH $TH/bin/hub-move.sh tick"); a=$?
  printf '%s\n' "$out"
  f=$(printf '%s\n' "$out" | sed -n 's/^tick-file: //p' | tail -1)
  # Fetch the table before the rc check: a stopped tick leaves a
  # `-crontab-found` table, and C1 must read it, not an older clean one.
  if [ -n "$f" ]; then
    mkdir -p "$STATE"
    on_target "$ip" "cat $f" > "$STATE/$(basename "$f")" || fail "fetch $f"
  fi
  [ "$a" -eq 0 ] || fail "tick on $ip rc=$a"
  [ -n "$f" ] || fail "tick on $ip printed no tick-file"
  cmd_inventory
  say "dry-run: done; tick table in $STATE/$(basename "$f")"
}

# ==== cutover ==================================================================
CUTOVER_STEPS="C1 C2 C3 C4 C5 C6 C7 C8"
step_text() {
  case "$1" in
    C1) echo "C1 preflight: the newest no-write tick is under 24 h old and no lane failed except by a refused write, a timeout, HUB_MOVE_C1_ALLOW=${C1_ALLOW:-none} or the same rc on the old hub (its cron journal, ${C1_OLD_WINDOW_S}s before the tick)" ;;
    C2) echo "C2 pause merge: flag_set automerge-disabled and lane-off-merge-conductor on the old hub" ;;
    C3) echo "C3 drain: save the old crontab to state/hub-move/old-crontab, crontab -r, wait up to ${DRAIN_TIMEOUT_S}s for no $HARNESS/bin/ process" ;;
    C4) echo "C4 copy: BACKUP_FORCE=1 state-backup.sh, seed the target from that exact snapshot, flag_set --local-only all-off on the old hub" ;;
    C5) echo "C5 split-brain check: old crontab empty and flags/all-off set here; on the target crontab empty, flags/all-off (set by seed) and flags/automerge-disabled present" ;;
    C6) echo "C6 start: on the target flag-clear --local-only all-off, hub-lease.sh renew until check rc 0 (${LEASE_WAIT_S}s), hub-move.sh tick --real, remove state/hub-move/target-seeded, update-runners.sh" ;;
    C7) echo "C7 resume merge: flag-clear automerge-disabled and lane-off-merge-conductor on the target" ;;
    C8) echo "C8 cold standby: write state/hub-move/cold-standby-until (now + 7 d) on the target; print the retire step" ;;
  esac
}
prev_step() { case "$1" in C1) echo "" ;; *) echo "C$(( ${1#C} - 1 ))" ;; esac; }

# drain_list — every process running $HARNESS/bin/, hub-move excluded. The
# path rides in the environment, so the awk's own argv never matches it.
drain_list() {
  ps -eo pid=,args= 2>/dev/null | HMP="$HARNESS/bin/" awk 'index($0, ENVIRON["HMP"]) && $0 !~ /hub-move/'
}
# drain_wait <timeout_s> — rc 0 when nothing runs, rc 4 (list on stderr) at the timeout.
drain_wait() {
  local waited=0
  while [ -n "$(drain_list)" ]; do
    if [ "$waited" -ge "$1" ]; then
      echo "hub-move: still running after ${1}s:" >&2
      drain_list >&2
      return 4
    fi
    sleep 1; waited=$((waited + 1))
  done
}

run_step() {
  local s="$1" force_drain="$2" prev ip waited f line ts0 ts1 out
  prev=$(prev_step "$s")
  if [ -n "$prev" ] && [ "$(step_status "$prev")" != ok ]; then
    refuse "cutover $s: step $prev is not ok"
  fi
  say "cutover: $(step_text "$s")"
  case "$s" in
    C1)
      f=$(ls -t "$STATE"/tick-*.tsv 2>/dev/null | head -1)
      [ -n "$f" ] || { step_record C1 fail "no tick file"; fail "C1: no state/hub-move/tick-*.tsv (run dry-run)"; }
      line=$(head -1 "$f")
      case "$line" in "# mode=nowrite at="*) ;; *) step_record C1 fail "newest tick not nowrite"; fail "C1: $f is not a no-write tick" ;; esac
      ts0=${line##*at=}
      is_uint "$ts0" && [ $(( $(now_s) - ts0 )) -lt 86400 ] || { step_record C1 fail "tick older than 24h"; fail "C1: $f is older than 24 h"; }
      local fl allowed="" blocking="" lid
      while IFS= read -r fl; do
        [ -n "$fl" ] || continue
        lid=${fl%%"(rc="*}
        # An allow-list id covers its ~N duplicates (lib covers lib~2).
        if [ -n "$C1_ALLOW" ] && { case ",$C1_ALLOW," in *",$lid,"*|*",${lid%%~*},"*) true ;; *) false ;; esac; }; then
          allowed="$allowed $fl"
        else
          blocking="$blocking $fl"
        fi
      done < <(grep -v '^#' "$f" | tail -n +2 | awk -F'\t' '$2!=0 && $4==0 && $5==0 {print $1"(rc="$2")"}')
      allowed=${allowed# }; blocking=${blocking# }
      say "cutover: C1 HUB_MOVE_C1_ALLOW=${C1_ALLOW:-none}; allowed failures: ${allowed:-none}"
      # BH-8038 item 3: a lane that failed with the same rc on the old hub in
      # the same window is `same-on-old-hub`, not a target failure. The old
      # hub is this box: its cron journal and its rendered crontab.
      local same="" still="" t0 jf jwhy jok=0 orows orc=0 trc ocmd orc_l
      if [ -n "$blocking" ]; then
        t0=$(( ts0 - C1_OLD_WINDOW_S ))
        jf=$(mktemp "$STATE/c1-journal.XXXXXX") || fail "mktemp"
        jwhy=$(cron_journal "$t0" "$jf") || jok=1
        orows=$("$CHECKOUT/bin/render-cron.sh" "$(hub_id)" 2>/dev/null) || orc=$?
        orows=$(lane_rows <<<"$orows")
        for fl in $blocking; do
          lid=${fl%%"(rc="*}; trc=${fl#*"(rc="}; trc=${trc%)}
          if [ "$jok" -ne 0 ]; then still="$still; $fl old hub rc unreadable: $jwhy"; continue; fi
          if [ "$orc" -ne 0 ]; then still="$still; $fl old hub rc unreadable: render-cron.sh $(hub_id) failed (rc=$orc)"; continue; fi
          ocmd=$(awk -F'\t' -v l="$lid" '$1 == l { sub(/^[^\t]*\t/, ""); print; exit }' <<<"$orows")
          if [ -z "$ocmd" ]; then still="$still; $fl old hub rc unreadable: not in the old hub crontab (render-cron.sh $(hub_id))"; continue; fi
          orc_l=$(WANT="$ocmd" journal_rc "$t0" "$jf")
          if [ "$orc_l" = none ]; then still="$still; $fl old hub rc unreadable: no run in the cron journal since @$t0"
          elif [ "$orc_l" = "$trc" ]; then same="$same $fl"
          else still="$still; $fl old hub rc=$orc_l"; fi
        done
        rm -f "$jf"
        blocking=${still#; }; same=${same# }
      fi
      say "cutover: C1 same-on-old-hub: ${same:-none}"
      [ -z "$blocking" ] || { step_record C1 fail "lanes failed: $blocking allow=${C1_ALLOW:-none} same_on_old_hub=$(printf '%s' "${same:-none}" | tr ' ' ',')"; fail "C1: lanes failed with no refused write: $blocking (HUB_MOVE_C1_ALLOW=${C1_ALLOW:-none}; read state/hub-move/$(basename "${f%.tsv}").out/<row>.out)"; }
      step_record C1 ok "$(basename "$f") allow=${C1_ALLOW:-none} allowed_failed=$(printf '%s' "${allowed:-none}" | tr ' ' ',') same_on_old_hub=$(printf '%s' "${same:-none}" | tr ' ' ',')" ;;
    C2)
      hm_flag_on automerge-disabled "hub-move C2: pause merge for the hub move" \
        && hm_flag_on lane-off-merge-conductor "hub-move C2: pause merge for the hub move" \
        || { step_record C2 fail "flags not written"; fail "C2: flags not written"; }
      step_record C2 ok "automerge-disabled lane-off-merge-conductor" ;;
    C3)
      mkdir -p "$STATE"
      out=$(crontab -l 2>/dev/null)
      if [ -n "$out" ] || [ ! -f "$STATE/old-crontab" ]; then
        # Never overwrite a saved crontab with the empty one of a re-run.
        printf '%s\n' "$out" > "$STATE/old-crontab.tmp" && mv -f "$STATE/old-crontab.tmp" "$STATE/old-crontab" \
          || { step_record C3 fail "cannot save crontab"; fail "C3: cannot save the crontab"; }
      fi
      crontab -r 2>/dev/null
      [ -z "$(crontab -l 2>/dev/null | grep -v '^#')" ] || { step_record C3 fail "crontab not removed"; fail "C3: crontab -r did not empty the crontab"; }
      if [ "$force_drain" -eq 0 ] && ! drain_wait "$DRAIN_TIMEOUT_S"; then
        step_record C3 fail "drain timeout"
        fail "C3: drain timeout (rerun with --force-drain to go on)"
      fi
      step_record C3 ok "drained$([ "$force_drain" -eq 1 ] && echo ' (forced)')" ;;
    C4)
      ts0=$(jq -r '.ts // empty' "$HARNESS/state/backup-last.json" 2>/dev/null)
      BACKUP_FORCE=1 "$BIN/state-backup.sh" || { step_record C4 fail "state-backup rc"; fail "C4: state-backup.sh failed"; }
      ts1=$(jq -r '.ts // empty' "$HARNESS/state/backup-last.json" 2>/dev/null)
      [ -n "$ts1" ] && [ "$ts1" != "$ts0" ] || { step_record C4 fail "no new backup"; fail "C4: state/backup-last.json names no new snapshot"; }
      ( cmd_seed "$ts1" ) || { step_record C4 fail "seed $ts1"; fail "C4: seed $ts1 failed"; }
      hm_flag_on all-off "hub-move C4: the old hub stands down" --local-only \
        || { step_record C4 fail "all-off"; fail "C4: cannot set flags/all-off"; }
      step_record C4 ok "snapshot $ts1" ;;
    C5)
      [ -z "$(crontab -l 2>/dev/null | grep -v '^#' | grep .)" ] || { step_record C5 fail "old crontab not empty"; fail "C5: the old hub crontab is not empty"; }
      flag_has all-off >/dev/null 2>&1 || { step_record C5 fail "old all-off missing"; fail "C5: flags/all-off is not set on the old hub"; }
      ip=$(target_ip) || exit 3
      # BH-8038: seed set a local all-off on the target; it stays until C6.
      [ -z "$(on_target "$ip" "crontab -l 2>/dev/null" | grep -vE '^[[:space:]]*(#|$)' | grep -vE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=')" ] \
        || { step_record C5 fail "target crontab not empty"; fail "C5: the target has an active crontab line"; }
      t_flag "$ip" flag-has all-off && t_flag "$ip" flag-has automerge-disabled \
        || { step_record C5 fail "target flags"; fail "C5: on the target all-off or automerge-disabled is missing"; }
      step_record C5 ok "split-brain guard holds" ;;
    C6)
      ip=$(target_ip) || exit 3
      t_flag "$ip" flag-clear --local-only all-off "'hub-move C6: the target starts'"
      t_flag "$ip" flag-has all-off; rc=$?
      [ "$rc" -eq 1 ] || { step_record C6 fail "target all-off"; fail "C6: flags/all-off still reads on on the target"; }
      waited=0
      until on_target "$ip" "$TH/bin/hub-lease.sh renew >/dev/null 2>&1; $TH/bin/hub-lease.sh check"; do
        if [ "$waited" -ge "$LEASE_WAIT_S" ]; then step_record C6 fail "lease"; fail "C6: hub-lease.sh check on the target is not rc 0 after ${LEASE_WAIT_S}s"; fi
        sleep 10; waited=$((waited + 10))
      done
      out=$(on_target "$ip" "HARNESS=$TH $TH/bin/hub-move.sh tick --real") || { step_record C6 fail "tick --real"; fail "C6: tick --real failed"; }
      printf '%s\n' "$out"
      # The marker goes BEFORE update-runners installs the crontab: a C6 rerun
      # after a failed update-runners must not have its tick remove that crontab.
      on_target "$ip" "rm -f $TH/state/hub-move/target-seeded" || { step_record C6 fail "marker"; fail "C6: cannot remove state/hub-move/target-seeded on the target"; }
      on_target "$ip" "$TH/bin/update-runners.sh" || { step_record C6 fail "update-runners"; fail "C6: update-runners.sh failed on the target"; }
      step_record C6 ok "$(printf '%s\n' "$out" | grep '^tick: ' | tail -1)" ;;
    C7)
      ip=$(target_ip) || exit 3
      t_flag "$ip" flag-clear automerge-disabled "'hub-move C7: merge resumes on the target'"
      t_flag "$ip" flag-clear lane-off-merge-conductor "'hub-move C7: merge resumes on the target'"
      t_flag "$ip" flag-has automerge-disabled; rc=$?
      [ "$rc" -eq 1 ] && { t_flag "$ip" flag-has lane-off-merge-conductor; [ $? -eq 1 ]; } \
        || { step_record C7 fail "flags"; fail "C7: cannot remove the merge flags on the target"; }
      step_record C7 ok "merge resumed on the target" ;;
    C8)
      ip=$(target_ip) || exit 3
      ts1=$(date -u -d "@$(( $(now_s) + 7 * 86400 ))" '+%Y-%m-%dT%H:%M:%SZ')
      on_target "$ip" "mkdir -p $TH/state/hub-move && printf '%s\n' '$ts1' > $TH/state/hub-move/cold-standby-until" \
        || { step_record C8 fail "write"; fail "C8: cannot write cold-standby-until on the target"; }
      echo "The new hub: provider=$(target_provider) host=$(tj_get ts_hostname) ts_ip=$ip."
      echo "The old hub is a cold standby until $ts1 (crontab empty, flags/all-off)."
      echo "After $ts1: retire the old hub VM ${HUB_MOVE_OLD_VM_ID:-<HUB_MOVE_OLD_VM_ID>} in the Orgo console, then re-arm cfg:failover."
      step_record C8 ok "cold standby until $ts1" ;;
  esac
}

cmd_cutover() {
  local step="" all=0 confirm=0 force=0 s
  while [ $# -gt 0 ]; do
    case "$1" in
      --step) [ $# -ge 2 ] || usage; step="$2"; shift 2 ;;
      --all) all=1; shift ;;
      --confirm) confirm=1; shift ;;
      --force-drain) force=1; shift ;;
      *) usage ;;
    esac
  done
  check_knobs
  if [ "$all" -eq 1 ]; then step=""; else
    case " $CUTOVER_STEPS " in *" $step "*) [ -n "$step" ] || usage ;; *) usage ;; esac
  fi
  local list="$step"
  if [ "$all" -eq 1 ]; then
    list=""
    for s in $CUTOVER_STEPS; do [ "$(step_status "$s")" = ok ] || list="$list $s"; done
  fi
  if [ "$confirm" -eq 0 ]; then
    for s in $list; do echo "WOULD RUN $(step_text "$s")"; done
    echo "nothing changed: add --confirm to run"
    return 0
  fi
  for s in $list; do run_step "$s" "$force"; done
}

# ==== rollback =================================================================
cmd_rollback() {
  local confirm=0 ip ts rc
  for a in "$@"; do case "$a" in --confirm) confirm=1 ;; *) usage ;; esac; done
  check_knobs
  [ -f "$STATE/old-crontab" ] || refuse "rollback: no state/hub-move/old-crontab (C3 never ran here)"
  if [ "$confirm" -eq 0 ]; then
    echo "WOULD RUN rollback: target crontab -r, drain, state-backup, flags/all-off; old hub state-restore of that snapshot, rm flags/all-off, crontab state/hub-move/old-crontab"
    echo "nothing changed: add --confirm to run"
    return 0
  fi
  ip=$(target_ip) || exit 3
  say "rollback: stop the target"
  on_target "$ip" "crontab -r 2>/dev/null; HARNESS=$TH $TH/bin/hub-move.sh drain" \
    || fail "rollback: the target did not drain in ${DRAIN_TIMEOUT_S}s"
  on_target "$ip" "BACKUP_FORCE=1 $TH/bin/state-backup.sh" || fail "rollback: state-backup on the target"
  ts=$(on_target "$ip" "jq -r '.ts // empty' $TH/state/backup-last.json")
  [ -n "$ts" ] || fail "rollback: the target backup-last.json names no snapshot"
  t_flag "$ip" flag-set --local-only all-off on "'hub-move rollback: the target stands down'"
  t_flag "$ip" flag-has all-off || fail "rollback: flags/all-off on the target"
  say "rollback: restore snapshot $ts onto the old hub"
  local run fresh prev; run="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fresh="$HARNESS/tmp/hub-move-fresh-$run"; prev="$HARNESS/tmp/hub-move-prev-$run"
  mkdir -p "$fresh/orchestrator" || fail "rollback: mkdir $fresh"
  "$BIN/state-restore.sh" "$(hub_id)" "$ts" --apply --live "$fresh" --orchestrator-live "$fresh/orchestrator" \
    --dest "$HARNESS/tmp/hub-move-restore-$run" \
    ${BACKUP_AGE_IDENTITY_FILE:+--identity "$BACKUP_AGE_IDENTITY_FILE"}; rc=$?
  [ "$rc" -eq 0 ] || fail "rollback: state-restore rc=$rc"
  # This hub's own hub-move record (old-crontab, steps.tsv, target.json) is
  # not the target's: carry it over the swap, or the crontab restore below has
  # nothing to read.
  case "$fresh" in "$HARNESS/"*) rm -rf "$fresh/state/hub-move" ;; *) fail "rollback: $fresh is not under $HARNESS" ;; esac
  mkdir -p "$fresh/state" && cp -a "$STATE" "$fresh/state/hub-move" \
    || fail "rollback: cannot carry $STATE into $fresh"
  clean_swap_script "$HARNESS" "$LORCH" "$fresh" "$prev" | bash -s; rc=$?
  [ "$rc" -eq 0 ] || fail "rollback: swap of the restored tree rc=$rc (old copies in $prev)"
  # The target's flags replaced this hub's; keep merge paused as the line below says.
  hm_flag_on automerge-disabled "hub-move rollback: merge stays paused" \
    && hm_flag_on lane-off-merge-conductor "hub-move rollback: merge stays paused" \
    || fail "rollback: cannot set the merge pause flags"
  # A later cutover starts at C1 again, so C5 (the split-brain check) runs.
  local st; for st in C1 C2 C3 C4 C5 C6 C7 C8; do step_record "$st" reset "rollback $ts"; done
  hm_flag_off all-off "hub-move rollback: the old hub resumes" --local-only || fail "rollback: flags/all-off still reads on here"
  crontab "$STATE/old-crontab" || fail "rollback: crontab restore"
  step_record rollback ok "snapshot $ts"
  echo "Rollback done. Merge is still paused: when the old hub is healthy, run $BIN/jobs-client.sh flag-clear automerge-disabled and $BIN/jobs-client.sh flag-clear lane-off-merge-conductor."
}

# ==== proof ====================================================================
cmd_proof() {
  local args=() la np
  while [ $# -gt 0 ]; do
    case "$1" in
      --since|--until) [ $# -ge 2 ] || usage; args+=("$1" "$2"); shift 2 ;;
      *) usage ;;
    esac
  done
  la=$(cat "${HUB_MOVE_PROC_LOADAVG:-/proc/loadavg}" 2>/dev/null) || fail "cannot read loadavg"
  np="${HUB_MOVE_NPROC:-$(nproc)}"
  is_posint "$np" || fail "nproc '$np'"
  printf '%s\n' "$la" | awk -v n="$np" -v h="$(hostname)" \
    '{ printf "hub-move proof host=%s load1=%s load5=%s load15=%s nproc=%d load5_per_vcpu=%.2f\n", h, $1, $2, $3, n, $2/n }'
  "$BIN/hub-load-report.sh" "${args[@]}"
}

# ==== test sandbox guard =======================================================
# BH-7715: under HARNESS_TEST_SANDBOX=1 every tree this script moves, removes or
# writes (here or, through the suite's ssh stub, "on the target") must sit in a
# test scratch tree ($TMPDIR/scratch.XXXXXX, tests/lib/scratch.sh). A suite
# case that left HUB_MOVE_ORCH unset once ran the swap against the hub's real
# /root/orchestrator as root, and the tree was lost. Refused before any lock,
# write or vendor call: exit 2, one stderr line.
sandbox_guard() {
  [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] || return 0
  local base pair label p r
  base=$(realpath -m "${TMPDIR:-/tmp}" 2>/dev/null) || base=""
  for pair in "HARNESS=$HARNESS" "HUB_MOVE_TARGET_HARNESS=$TH" "HUB_MOVE_TARGET_ORCH=$TORCH" "HUB_MOVE_ORCH=$LORCH" \
      "HUB_MOVE_TARGET_SECRETS=${HUB_MOVE_TARGET_SECRETS:-/root/.config/hub-move}" \
      "HUB_MOVE_TARGET_SSH_DIR=${HUB_MOVE_TARGET_SSH_DIR:-/root/.ssh}" \
      "HARNESS_CHECKOUT=${HARNESS_CHECKOUT:-/root/harness-checkout}"; do
    label="${pair%%=*}"; p="${pair#*=}"
    r=$(realpath -m "$p" 2>/dev/null) || r=""
    case "$r" in /root/orchestrator|/root/orchestrator/*|/root/harness|/root/harness/*) r="" ;; esac
    case "$r" in
      "$base"/scratch.??????/*) [ -n "$base" ] && continue ;;
    esac
    echo "hub-move: refused: HARNESS_TEST_SANDBOX=1 and $label=$p is outside the test scratch root ${base:-?}/scratch.*" >&2
    exit 2
  done
  # BH-8038: tick, cutover and rollback run `crontab -l` / `crontab -r`. Under
  # the sandbox the crontab on PATH must be the suite's stub.
  p=$(command -v crontab 2>/dev/null) || return 0
  r=$(realpath -m "$p" 2>/dev/null) || r=""
  case "$r" in "$base"/scratch.??????/*) [ -n "$base" ] && return 0 ;; esac
  echo "hub-move: refused: HARNESS_TEST_SANDBOX=1 and crontab=$p is outside the test scratch root ${base:-?}/scratch.*" >&2
  exit 2
}

# ==== main =====================================================================
sandbox_guard || exit 2
VERB="${1:-}"; [ $# -gt 0 ] && shift
case "$VERB" in
  inventory|proof|drain) ;;
  provision|seed|tick|dry-run|cutover|rollback)
    # Dedupe, never a queue: a held lock means another run is on it. --plan
    # writes nothing, so it takes no lock.
    case " $* " in *" --plan "*) ;; *)
    mkdir -p "$HARNESS/locks" 2>/dev/null
    exec 9>"$HARNESS/locks/hub-move.lock" || fail "cannot open locks/hub-move.lock"
    flock -n 9 || { echo "hub-move: already running (locks/hub-move.lock held)"; exit 0; }
    ;; esac ;;
  *) usage ;;
esac
case "$VERB" in
  inventory) cmd_inventory "$@" ;;
  provision) cmd_provision "$@" ;;
  seed)      cmd_seed "$@" ;;
  tick)      cmd_tick "$@" ;;
  dry-run)   cmd_dry_run "$@" ;;
  cutover)   cmd_cutover "$@" ;;
  rollback)  cmd_rollback "$@" ;;
  proof)     cmd_proof "$@" ;;
  drain)     check_knobs; drain_wait "$DRAIN_TIMEOUT_S" ;;
esac
