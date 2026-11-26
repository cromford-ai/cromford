#!/bin/bash
# bin/state-backup.sh — the off-box copy of this box's harness state.
#
# WHY (#388, 2026-09-15). The hub's /root/harness/{env,bin,prompts,logs,builds}
# vanished under a running system with no off-box copy, so nothing came back.
# This lane is one tarball of what a box cannot reconstruct, uploaded to an
# S3-compatible bucket (R2). WHAT GOES IN: env/ encrypted with age (the ONLY way
# env/ leaves the box — the tarball is checked for plaintext env/ entries before
# any upload), state/ (minus state/scratch/, which is operator scratch a restore
# does not want back, and minus state/bundle-cache/, the hub's plaintext copy of
# each pool project's env bundle (BH-9889): env content, so it never leaves the
# box, and the leak check refuses it like a plaintext env/ entry), logs/, flags/, the builds/ summaries, the orchestrator
# checkout minus node_modules/.git, meta/. HOW IT FAILS: ONE actionable
# ALERTS.log line naming the stage and the key NAMES, never a value, then exit
# 1; state/backup-last.json is written only after head-object confirms the
# remote size, so a stamp without a delivered backup is impossible. OFF:
# STATE_BACKUP=0, or the switch state-backup-off read through lane_switch
# (BH-2438): the settings row switch.state-backup-off[.<box>] when one exists,
# else flags/state-backup-off. DEDUPE: flock -n on
# locks/state-backup.lock — a held lock skips, it never waits (that is a queue).
# Rung: the uploader. Restore is #449 (docs/RESTORE.md), the merge side #446,
# the cron line #448.
#
# IDLE PRIORITY AND THE SKIP (BH-6173). On 2026-10-12 the hub ran at 44% steal
# and this lane's zstd took 69% of one CPU every 15 minutes, next to the merge
# conductor. So every heavy child runs under `nice -n 19 ionice -c3 -t`, the
# archive compresses with `zstd -<BACKUP_ZSTD_LEVEL> -T1` (default 1: 34% less
# CPU than the old default 3 for a 16% bigger object), and a run whose inputs
# match the manifest of the last shipped object ships nothing. A skip is not
# blind: it head-objects the last key at its recorded size first, and only then
# moves .ts in the stamp, so the freshness signal means "the off-box copy
# matches this box's inputs at ts". BACKUP_FORCE_HOURS (24) forces a real upload
# anyway; BACKUP_FORCE=1 (bin/box-ops.sh "back up now") always ships. The hub's
# logs/ and state/ change every minute, so there the skip almost never fires and
# the saving is the priority and the level.
set -uo pipefail

H="${HARNESS_ROOT:-${HARNESS:-/root/harness}}"
# shellcheck disable=SC1091
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s/env\n' "$H"; }
HENV=$(harness_env_dir "$H")

# >>> lane gate (BH-1165) — one off-switch and one source of numbers for this
# lane. lane_gate_or_exit exits 0 when flags/all-off, flags/lane-off-state-backup
# (or a pause_flags row driving either) is set; lane_env_apply then puts this
# lane's settings rows into the environment its own ${KNOB:-default} reads use.
# Both fail OPEN: an unreachable worker leaves the lane exactly as it is today.
# Registry: catalog/lanes.json. Operator: bin/harness-ctl.sh off state-backup.
# shellcheck disable=SC1091
. "${HARNESS:-/root/harness}/bin/lib/lane-gate.sh" 2>/dev/null || true
command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit state-backup
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    state-backup
if [ -f "$HENV/global.env" ]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  . "$HENV/global.env" 2>/dev/null
  set +a
fi
# AND AGAIN, BELOW THE ENV LOAD (BH-1165 review). `set -a; . env/global.env`
# re-assigns every name it carries, so the call above lost each knob the box's
# env file also sets — the settings row was gone, the page went on reporting
# `source: settings`, and nothing errored: the exact shape this ticket exists to
# end. The call above still earns its place: the knobs this lane reads BEFORE
# this line have no other way to see a row. Applying twice is idempotent (the
# settings cache is already warm) and section 16 of tests/lanes-registry-test.sh
# is the ordering.
command -v lane_env_apply    >/dev/null 2>&1 && lane_env_apply    state-backup

LOG="$H/logs/state-backup.log"
ALERTS="$H/logs/ALERTS.log"

stamp() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }
say() {
  mkdir -p "$H/logs" 2>/dev/null
  printf '%s [state-backup] %s\n' "$(stamp)" "$*" >> "$LOG"
}
last_good() { # the ts of the last VERIFIED off-box copy, or never
  local v=""
  v=$(jq -r '.ts // empty' "$H/state/backup-last.json" 2>/dev/null)
  if [ -n "$v" ]; then printf '%s\n' "$v"; else printf 'never\n'; fi
}
alert() { # alert <stage> <reason> — key NAMES only, never values
  mkdir -p "$H/logs" 2>/dev/null
  printf '%s [state-backup] %s: %s FAILED (%s) - last good off-box copy: %s\n' \
    "$(stamp)" "${BOX:-unknown}" "$1" "$2" "$(last_good)" >> "$ALERTS"
}

# ── THIS BOX STATES ITS OWN BACKUP FRESHNESS (BH-1031) ───────────────────────
# The hub used to COLLECT this, by splicing bin/lib/backup-freshness.sh's probe
# into the 15-minute ssh hop bin/fleet-heartbeat.sh already made. That lane is
# deleted in state→DB slice 6 (it answered "can the hub reach the box", not "is
# the lane alive"), so the fact travels the other way now: the machine that owns
# it says so, and the hub reads every box's answer in one call.
#
# THIS SCRIPT IS THE RIGHT PLACE and the only one. It runs on every box the hop
# covered, on the same 15-minute cadence (5,20,35,50), and — decisively — it is
# the WRITER of the stamp. A reporter on its own cron would publish the previous
# run's timestamp: with a 15-minute backup rhythm and a 30-minute stale
# threshold, the reported age would sit at the threshold and flap. Reported from
# here, on the way out, the age is the one the stamp actually has.
#
# ON THE WAY OUT, ON EVERY PATH. The four states are not all reachable from one
# line: `off` exits at the kill switches, `unconfigured` exits at the key check,
# `missing` and `ok` fall out of the upload. An EXIT trap is what makes all four
# report — and a box that reports nothing at all is read by the hub as a box
# that went quiet, which for `off` would be a lie and for `unconfigured` a page
# nobody should get.
#
# BEST EFFORT, AND NEVER THE BACKUP'S PROBLEM. No library, no client, no worker:
# this returns 0 and the backup is byte-identical to what it was. The trap
# preserves the script's own exit status explicitly, because an EXIT trap's last
# command would otherwise become it.
# shellcheck disable=SC1091
. "$H/bin/lib/backup-freshness.sh" 2>/dev/null \
  || . "$(dirname "${BASH_SOURCE[0]}")/lib/backup-freshness.sh" 2>/dev/null || true
bf_push() {
  local facts cli
  command -v bf_facts_local >/dev/null 2>&1 || return 0
  cli="${BF_PUSH_CMD:-$H/bin/jobs-client.sh}"
  [ -x "$cli" ] || return 0
  facts=$(bf_facts_local "$H" 2>/dev/null) || return 0
  # Cut BY POSITION, never `read -r a b c`: tab is IFS whitespace, so read
  # collapses a run of them and a box with no stamp but an unconfigured marker
  # ("		unconfigured") would report its marker as its timestamp — the same
  # trap bf_state_age documents on the reading side.
  # fd 9 is the backup lock. The report is synchronous, so nothing can outlive
  # this call — but it is closed anyway, because a child that inherited the lock
  # would hold the whole lane's dedupe open past the run that took it.
  JOBS_TIMEOUT="${BF_PUSH_TIMEOUT:-5}" JOBS_RETRIES=0 \
    "$cli" box-backup-set \
      "$(printf '%s' "$facts" | cut -f1)" \
      "$(printf '%s' "$facts" | cut -f2)" \
      "$(printf '%s' "$facts" | cut -f3)" >/dev/null 2>&1 9>&-
  return 0
}
trap 'BF_RC=$?; bf_push; exit "$BF_RC"' EXIT

BUCKET="${BACKUP_S3_BUCKET:-harness-state}"
REGION="${BACKUP_S3_REGION:-auto}"
S3C="${BACKUP_S3_CLIENT:-aws}"
KEEP_ALL="${BACKUP_KEEP_ALL_DAYS:-7}"
KEEP_DAILY="${BACKUP_KEEP_DAILY_DAYS:-30}"
CHECKOUT="${HARNESS_CHECKOUT:-/root/harness-checkout}"
ORCH="${ORCHESTRATOR_DIR:-/root/orchestrator}"
NOW="${BACKUP_NOW:-$(date +%s)}"
TS=$(date -u -d "@$NOW" +%Y%m%dT%H%M%SZ 2>/dev/null)
DAY="${TS:0:8}"
BOX=$(tr -dc 'a-z0-9-' < "$H/state/box-id" 2>/dev/null)

# No timestamp, no key: an unparseable BACKUP_NOW or a mute box clock would
# otherwise name the object "<box>/.tar.zst".
case "$TS" in ''|*[!0-9TZ]*) alert clock "BACKUP_NOW or the box clock gave no usable timestamp"; exit 1 ;; esac

# A retention knob that is not a number is said out loud, never clamped in
# silence — an operator typo must not quietly change what we keep.
case "$KEEP_ALL" in ''|*[!0-9]*)
  say "BACKUP_KEEP_ALL_DAYS is not a number - using 7"; KEEP_ALL=7 ;;
esac
case "$KEEP_DAILY" in ''|*[!0-9]*)
  say "BACKUP_KEEP_DAILY_DAYS is not a number - using 30"; KEEP_DAILY=30 ;;
esac
# BH-6173 knobs. The three tuning knobs are required registry knobs, so
# lane_env_apply above always sets them (row > cached row > env > registry
# default) and this file has no second copy of a default. An empty value only
# happens when lane-gate.sh or the registry could not run (a scratch tree), and
# then the registry default answers in silence, the shape of BR_MAX_REGEN in
# bin/blocked-resolver.sh. A non-empty bad value is said out loud.
ZLVL="${BACKUP_ZSTD_LEVEL:-}"
case "$ZLVL" in
  '') ZLVL=1 ;;
  *[!0-9]*) ZLVL=bad ;;
  *) ZLVL=$((10#$ZLVL)); { [ "$ZLVL" -ge 1 ] && [ "$ZLVL" -le 19 ]; } || ZLVL=bad ;;
esac
[ "$ZLVL" = bad ] && { say "BACKUP_ZSTD_LEVEL is not 1-19 - using 1"; ZLVL=1; }
FORCEH="${BACKUP_FORCE_HOURS:-}"
case "$FORCEH" in
  '') FORCEH=24 ;;
  *[!0-9]*) FORCEH=bad ;;
  *) FORCEH=$((10#$FORCEH)); [ "$FORCEH" -ge 1 ] || FORCEH=bad ;;
esac
[ "$FORCEH" = bad ] && { say "BACKUP_FORCE_HOURS is not a positive number - using 24"; FORCEH=24; }
SKIPU="${BACKUP_SKIP_UNCHANGED:-}"
case "$SKIPU" in 0|1) ;; '') SKIPU=1 ;; *) say "BACKUP_SKIP_UNCHANGED is not 0 or 1 - using 1"; SKIPU=1 ;; esac
# Not required: empty or 0 is "not forced"; only 1 forces an upload.
FORCE="${BACKUP_FORCE:-}"

# ---- kill switches ---------------------------------------------------------
[ "${STATE_BACKUP:-}" = 0 ] && { say "off: STATE_BACKUP=0"; exit 0; }
command -v lane_switch >/dev/null 2>&1 || . "${HARNESS:-/root/harness}/bin/lib/lane-switch.sh" 2>/dev/null || lane_switch() { [ -f "${HARNESS:-/root/harness}/flags/$1" ]; }
# The file-only fallback above sets no LANE_SWITCH_SRC, and this script is set -u.
LANE_SWITCH_SRC=legacy
HARNESS="$H" lane_switch state-backup-off && { say "off: switch state-backup-off ($LANE_SWITCH_SRC)"; exit 0; }

# ---- dedupe, never a queue -------------------------------------------------
mkdir -p "$H/locks" 2>/dev/null
exec 9>"$H/locks/state-backup.lock" || { alert lock "cannot open locks/state-backup.lock"; exit 1; }
flock -n 9 || { say "skip: a backup is still running"; exit 0; }

# ---- idle priority (BH-6173) -----------------------------------------------
# -t: a box whose I/O scheduler refuses the idle class still gets its backup.
LOWPRI=(nice -n 19)
if command -v ionice >/dev/null 2>&1; then
  LOWPRI+=(ionice -c3 -t)
else
  say "ionice not found - running at nice 19 only"
fi

# ---- configured? -----------------------------------------------------------
# Nothing is uploaded and no bucket call is made until every input is present.
# The log says it every run; ALERTS once per UTC day, written BEFORE the marker
# so a failed marker write costs a duplicate line rather than a lost one.
MISSING=""
for V in BACKUP_S3_ENDPOINT BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY BACKUP_AGE_RECIPIENT; do
  [ -n "${!V:-}" ] || MISSING="$MISSING $V"
done
for C in age zstd "$S3C" jq; do
  command -v "$C" >/dev/null 2>&1 || MISSING="$MISSING $C"
done
[ -n "$BOX" ] || MISSING="$MISSING state/box-id"
if [ -n "$MISSING" ]; then
  say "not configured - missing:$MISSING"
  MARK="$H/state/state-backup-unconfigured-$DAY"
  if [ ! -f "$MARK" ]; then
    mkdir -p "$H/logs" "$H/state" 2>/dev/null
    printf '%s [state-backup] %s: not configured - missing:%s. NEEDED FROM OPERATOR/OPS: set the named BACKUP_* keys in env/global.env on %s, apt-get install -y age zstd awscli for the named tools. Last good off-box copy: %s\n' \
      "$(stamp)" "${BOX:-unknown}" "$MISSING" "${BOX:-this box}" "$(last_good)" >> "$ALERTS"
    touch "$MARK" 2>/dev/null
  fi
  # One marker per UTC day is the ALERTS dedupe; keeping the older ones is only
  # litter — a box left unconfigured for a year would carry 365 of them, and no
  # reader ever looks past the freshest (bin/lib/backup-freshness.sh takes any
  # marker inside BF_UNCONF_FRESH_MIN). Outside the `if` on purpose, so the
  # ticks that write nothing still sweep; today's marker is written first, so
  # this can never leave the box with none.
  find "$H/state" -maxdepth 1 -name 'state-backup-unconfigured-*' \
    ! -name "state-backup-unconfigured-$DAY" -exec rm -f {} + 2>/dev/null
  exit 1
fi

# Configured. Clear every unconfigured marker this box left behind (#399): the
# marker is the ONLY evidence bin/lib/backup-freshness.sh has that the keys are
# still a handoff, and that state never pages. A marker left lying after the
# keys land would latch the box at `unconfigured` — the console would tell the
# operator who just configured it "backup not configured" while the uploader
# fails, and `backup-missing` would never fire. This runs before one byte is
# staged, so it clears on the first configured tick whether or not the upload
# then succeeds.
rm -f "$H/state"/state-backup-unconfigured-* 2>/dev/null

s3() { # the only seam to the bucket; credentials are set for this call alone
  AWS_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY_ID" \
  AWS_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_ACCESS_KEY" \
  AWS_DEFAULT_REGION="$REGION" AWS_PAGER= \
  "$S3C" s3api "$1" --endpoint-url "$BACKUP_S3_ENDPOINT" --output json "${@:2}"
}

# ---- the orchestrator checkout: one decision, read by the manifest and tar --
ORCH_ARGS=()
OBN=""
if [ -d "$ORCH" ]; then
  OBN=$(basename "$ORCH")
  case "$OBN" in
    env|state|logs|flags|builds|meta)
      say "orchestrator dir is named $OBN, which collides with a tarball root entry - skipped"
      OBN="" ;;
    *)
      ORCH_ARGS=(-C "$(dirname "$ORCH")" --anchored
                 --exclude="$OBN/node_modules" --exclude="$OBN/.git"
                 --transform="flags=r;s|^$OBN/|orchestrator/|;s|^$OBN\$|orchestrator|"
                 "$OBN") ;;
  esac
fi

# ---- the input manifest (BH-6173) ------------------------------------------
# One sha256 over the name, size and mtime of every input file (never a byte of
# content, so env/ values stay where they are). Directories count by name only:
# a tmp file made and renamed inside state/ moves the dir mtime, not an input.
# Not inputs: this lane's own outputs (its log, its stamp, the unconfigured
# markers), state/scratch/ (not in the tar), and the TTL caches every lane gate
# rewrites on each run, this one included (state/lane-gate/,
# state/settings-cache.json, state/flags-cache/) — counting them, no run could
# ever match. They still ride in the tar. Computed BEFORE tar reads anything, so
# a file that changes mid-run makes the next manifest differ: over-ship, never
# under-ship.
bk_lines() { # <tag> — find -printf: dirs as a name, everything else name+size+mtime
  printf '%s\n' "( -type d -printf $1\t%p/\n ) -o -printf $1\t%p\t%s\t%T@\n"
}
bk_manifest() {
  {
    # shellcheck disable=SC2046
    [ -d "$HENV" ] && (cd "$HENV/" && "${LOWPRI[@]}" find . -mindepth 1 $(bk_lines env)) 2>/dev/null
    # shellcheck disable=SC2046
    (cd "$H" 2>/dev/null && "${LOWPRI[@]}" find state logs flags -mindepth 1 \
      \( -path state/scratch -o -path state/bundle-cache -o -path state/backup-last.json -o -path state/backup-last.json.tmp \
         -o -path 'state/state-backup-unconfigured-*' -o -path state/lane-gate \
         -o -path state/settings-cache.json -o -path state/flags-cache \
         -o -path logs/state-backup.log \) -prune -o $(bk_lines in)) 2>/dev/null
    [ -d "$H/builds" ] && "${LOWPRI[@]}" find "$H/builds" -mindepth 2 -maxdepth 2 \
      \( -name RESULT -o -name cost.csv -o -name plan.md -o -name review.md -o -name pipeline.log \) \
      -printf 'builds\t%P\t%s\t%T@\n' 2>/dev/null
    # shellcheck disable=SC2046
    [ -n "$OBN" ] && (cd "$(dirname "$ORCH")" && "${LOWPRI[@]}" find "$OBN" \
      \( -path "$OBN/node_modules" -o -path "$OBN/.git" \) -prune -o $(bk_lines orch)) 2>/dev/null
    printf 'meta\tcrontab\t%s\n' "$(crontab -l 2>/dev/null | sha256sum | cut -d' ' -f1)"
    printf 'meta\tcheckout\t%s\n' "$(git -C "$CHECKOUT" rev-parse HEAD 2>/dev/null)"
  } | LC_ALL=C sort | sha256sum | cut -d' ' -f1
}
MANIFEST=$(bk_manifest)
case "$MANIFEST" in *[!0-9a-f]*|'') MANIFEST=none ;; esac

# ---- skip unchanged inputs (BH-6173) ---------------------------------------
# Ship when ANY of: BACKUP_FORCE=1, BACKUP_SKIP_UNCHANGED=0, no stamp, a stamp
# with no manifest, a different manifest, an unparseable or future `shipped`,
# a `shipped` BACKUP_FORCE_HOURS or more ago, or a last object that does not
# head-object at its recorded size. Skip only when none hold.
SHIP_WHY=""
LAST="$H/state/backup-last.json"
OKEY=$(jq -r '.key // empty' "$LAST" 2>/dev/null)
OBYTES=$(jq -r '.bytes // empty' "$LAST" 2>/dev/null)
OMAN=$(jq -r '.manifest // empty' "$LAST" 2>/dev/null)
OSHIP=$(jq -r '.shipped // empty' "$LAST" 2>/dev/null)
if [ "$FORCE" = 1 ]; then SHIP_WHY=forced
elif [ "$SKIPU" = 0 ]; then SHIP_WHY=skip-off
elif [ -z "$OKEY" ] || [ -z "$OMAN" ]; then SHIP_WHY=no-manifest
elif [ "$MANIFEST" = none ] || [ "$MANIFEST" != "$OMAN" ]; then SHIP_WHY=changed
elif ! [[ "$OSHIP" =~ ^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$ ]]; then SHIP_WHY=no-shipped
else
  SHIPE=$(date -u -d "${BASH_REMATCH[1]}-${BASH_REMATCH[2]}-${BASH_REMATCH[3]} ${BASH_REMATCH[4]}:${BASH_REMATCH[5]}:${BASH_REMATCH[6]} UTC" +%s 2>/dev/null)
  AGE=$(( NOW - ${SHIPE:-NOW} ))
  if [ -z "$SHIPE" ] || [ "$AGE" -lt 0 ]; then SHIP_WHY=no-shipped
  elif [ "$AGE" -ge $((FORCEH * 3600)) ]; then SHIP_WHY=force-hours
  fi
fi
if [ -z "$SHIP_WHY" ]; then
  HJ=$(s3 head-object --bucket "$BUCKET" --key "$OKEY" 2>/dev/null)
  HRC=$?
  RB=$(jq -r '.ContentLength // empty' <<<"$HJ" 2>/dev/null)
  if [ "$HRC" -ne 0 ] || [ -z "$RB" ] || [ "$RB" != "$OBYTES" ]; then
    say "skip refused: $OKEY did not verify - shipping"
    SHIP_WHY=unverified
  fi
fi
if [ -z "$SHIP_WHY" ]; then
  mkdir -p "$H/state" 2>/dev/null
  if ! jq -c --arg ts "$TS" --arg m "$MANIFEST" \
        '{ts: $ts, key: .key, bytes: .bytes, sha256: .sha256, manifest: $m, shipped: .shipped}' \
        "$LAST" > "$LAST.tmp" 2>/dev/null \
     || ! mv "$LAST.tmp" "$LAST"; then
    rm -f "$LAST.tmp" 2>/dev/null
    alert stamp "cannot write state/backup-last.json after verifying $OKEY for a skip"
    exit 1
  fi
  say "skip: inputs unchanged since $OSHIP ($OKEY) - shipped nothing"
  exit 0
fi

# ---- staging ---------------------------------------------------------------
mkdir -p "$H/tmp" 2>/dev/null
STAGE=$(mktemp -d "$H/tmp/state-backup.XXXXXX") || { alert staging "mktemp -d under tmp/ failed"; exit 1; }
cleanup() {
  case "$STAGE" in
    "$H/tmp/state-backup."*) rm -rf "$STAGE" ;;
  esac
}
# The staging cleanup joins the report above rather than replacing it: a
# second `trap ... EXIT` overwrites the first, and dropping the report here
# would silence every box on the ok path — the only path that reaches this
# line — which is every healthy box in the fleet.
trap 'BF_RC=$?; cleanup; bf_push; exit "$BF_RC"' EXIT

# ---- env/, encrypted, and nothing else out of it ---------------------------
"${LOWPRI[@]}" tar -cf - -C "$HENV" --transform 'flags=r;s,^\./,env/,' . 2>"$STAGE/env-tar.err" \
  | "${LOWPRI[@]}" age -r "$BACKUP_AGE_RECIPIENT" > "$STAGE/env.tar.age" 2>"$STAGE/age.err"
RCS=("${PIPESTATUS[@]}")
[ "${RCS[0]}" -ge 2 ] && { alert env-tar "tar rc=${RCS[0]} reading the env dir"; exit 1; }
[ "${RCS[1]}" -ne 0 ] && { alert env-encrypt "age rc=${RCS[1]} - check the recipient named by BACKUP_AGE_RECIPIENT"; exit 1; }

# ---- meta ------------------------------------------------------------------
mkdir -p "$STAGE/meta"
printf '%s\n' "$BOX" > "$STAGE/meta/box.txt"
printf '%s\n' "$TS" > "$STAGE/meta/ts.txt"
crontab -l > "$STAGE/meta/crontab.txt" 2>/dev/null || printf '(none)\n' > "$STAGE/meta/crontab.txt"
git -C "$CHECKOUT" rev-parse HEAD > "$STAGE/meta/checkout-head.txt" 2>/dev/null \
  || printf '(no checkout)\n' > "$STAGE/meta/checkout-head.txt"

# ---- what else goes in -----------------------------------------------------
# Paths relative to $H. A fresh box has some and not others; it tars what exists.
: > "$STAGE/list"
for D in state logs flags; do
  [ -d "$H/$D" ] && printf '%s\n' "$D" >> "$STAGE/list"
done
if [ -d "$H/builds" ]; then
  find "$H/builds" -mindepth 2 -maxdepth 2 \
    \( -name RESULT -o -name cost.csv -o -name plan.md -o -name review.md -o -name pipeline.log \) \
    -printf 'builds/%P\n' 2>/dev/null >> "$STAGE/list"
fi

# logs/ can be appended to while tar reads it: that is rc 1, and rc 1 is fine.
# state/scratch/ is the one part of state/ that stays behind: bin/disk-clean.sh
# moves operator one-offs, .done markers and .bak- copies there (#1044), and a
# restore does not want them back. --anchored around it on purpose: a bare
# pattern also matches any suffix, so an orchestrator checkout that happened to
# carry a state/scratch would be dropped from the backup without a word.
# state/bundle-cache/ stays behind too (BH-9889): it holds plaintext env values
# copied from other boxes, and a restore does not need it (a missing file costs
# one dark-box spawn that fails as before). The leak check below refuses it.
"${LOWPRI[@]}" tar -I "zstd -$ZLVL -T1" --warning=no-file-changed -cf "$STAGE/backup.tar.zst" \
  -C "$STAGE" env.tar.age meta \
  --anchored --exclude=state/scratch --exclude='state/scratch/*' \
  --exclude=state/bundle-cache --exclude='state/bundle-cache/*' --no-anchored \
  -C "$H" -T "$STAGE/list" \
  ${ORCH_ARGS[@]+"${ORCH_ARGS[@]}"} 2>"$STAGE/tar.err"
TRC=$?
[ "$TRC" -ge 2 ] && { alert tar "tar rc=$TRC: $(head -c 200 "$STAGE/tar.err" | tr '\n' ' ')"; exit 1; }

# ---- the leak self-check, on the tarball that is about to leave the box -----
ENTRIES=$("${LOWPRI[@]}" tar --zstd -tf "$STAGE/backup.tar.zst" 2>/dev/null)
LRC=$?
# A here-string, not `printf | grep -q`: grep -q stops at env.tar.age, which is
# always line 1, and on a listing past a pipe buffer printf then takes SIGPIPE
# and pipefail reads a present entry as missing (BH-4719).
if [ "$LRC" -ne 0 ] || ! grep -qx 'env.tar.age' <<<"$ENTRIES"; then
  alert leak-check "cannot list the tarball back (rc=$LRC) or env.tar.age is not in it"
  exit 1
fi
# state/bundle-cache/ is env content in plaintext (BH-9889): the same refusal.
LEAKED=$(printf '%s\n' "$ENTRIES" | grep -Ec '^(env|state/bundle-cache)(/|$)')
if [ "$LEAKED" -ne 0 ]; then
  alert leak-check "$LEAKED plaintext env entries in the tarball - nothing uploaded"
  exit 1
fi

# ---- upload ----------------------------------------------------------------
BYTES=$(stat -c%s "$STAGE/backup.tar.zst" 2>/dev/null)
SHA=$("${LOWPRI[@]}" sha256sum "$STAGE/backup.tar.zst" 2>/dev/null | cut -d' ' -f1)
KEY="$BOX/$TS.tar.zst"

s3 put-object --bucket "$BUCKET" --key "$KEY" --body "$STAGE/backup.tar.zst" \
  --metadata "sha256=$SHA" > "$STAGE/put.json" 2>"$STAGE/put.err"
PRC=$?
[ "$PRC" -ne 0 ] && { alert put "put-object rc=$PRC for key $KEY"; exit 1; }

s3 head-object --bucket "$BUCKET" --key "$KEY" > "$STAGE/head.json" 2>"$STAGE/head.err"
HRC=$?
[ "$HRC" -ne 0 ] && { alert verify "head-object rc=$HRC for key $KEY"; exit 1; }
RBYTES=$(jq -r '.ContentLength // empty' "$STAGE/head.json" 2>/dev/null)
case "$RBYTES" in ''|*[!0-9]*)
  alert verify "head-object returned no usable ContentLength for key $KEY"
  exit 1 ;;
esac
[ "$RBYTES" != "$BYTES" ] && { alert size "remote $RBYTES != local $BYTES for key $KEY"; exit 1; }

# Only now is the copy real. tmp + mv so a torn write cannot become the ledger.
mkdir -p "$H/state" 2>/dev/null
if ! printf '{"ts":"%s","key":"%s","bytes":%s,"sha256":"%s","manifest":"%s","shipped":"%s"}\n' \
       "$TS" "$KEY" "$BYTES" "$SHA" "$MANIFEST" "$TS" \
     > "$H/state/backup-last.json.tmp" \
   || ! mv "$H/state/backup-last.json.tmp" "$H/state/backup-last.json"; then
  alert stamp "cannot write state/backup-last.json after a verified upload of $KEY"
  exit 1
fi
say "uploaded $KEY bytes=$BYTES sha256=$SHA"

# ---- retention -------------------------------------------------------------
# Younger than KEEP_ALL days: keep everything. Older than KEEP_DAILY days:
# delete. In between: keep the earliest object of each UTC day. A listing that
# fails, is unparseable, or comes back empty right after a verified upload is a
# listing we do not trust, and nothing is deleted on an untrusted listing.
s3 list-objects-v2 --bucket "$BUCKET" --prefix "$BOX/" > "$STAGE/list.json" 2>"$STAGE/list.err"
LSRC=$?
if [ "$LSRC" -ne 0 ]; then
  say "prune skipped: listing failed (list-objects-v2 rc=$LSRC)"
  exit 0
fi
COUNT=$(jq -r '.Contents | length' "$STAGE/list.json" 2>/dev/null)
case "$COUNT" in ''|*[!0-9]*)
  say "prune skipped: listing failed (unparseable response)"
  exit 0 ;;
esac
if [ "$COUNT" -eq 0 ]; then
  say "prune skipped: listing failed (empty right after a verified upload)"
  exit 0
fi

jq -r --arg re "^$BOX/[0-9]{8}T[0-9]{6}Z\\.tar\\.zst\$" --arg cur "$KEY" \
  '.Contents[]?.Key // empty | select(. != $cur) | select(test($re))' \
  "$STAGE/list.json" 2>/dev/null | LC_ALL=C sort > "$STAGE/cands"
NCAND=$(wc -l < "$STAGE/cands")
if [ "$NCAND" -eq 0 ]; then
  say "pruned 0 kept 0"
  exit 0
fi
sed -E 's|^.*/||; s|^(....)(..)(..)T(..)(..)(..)Z\.tar\.zst$|\1-\2-\3 \4:\5:\6 UTC|' \
  "$STAGE/cands" > "$STAGE/cand-dates"
date -u -f "$STAGE/cand-dates" +%s > "$STAGE/cand-epochs" 2>/dev/null
if [ "$(wc -l < "$STAGE/cand-epochs")" -ne "$NCAND" ]; then
  say "prune skipped: could not read $NCAND candidate timestamps back"
  exit 0
fi
paste "$STAGE/cands" "$STAGE/cand-epochs" > "$STAGE/cand-pairs"

: > "$STAGE/todelete"
CLASS=$(awk -F'\t' -v now="$NOW" -v ka="$((KEEP_ALL * 86400))" -v kd="$((KEEP_DAILY * 86400))" \
  -v del="$STAGE/todelete" '
  { age = now - $2
    if (age < 0)   { kept++; next }            # a future stamp is never ours to delete
    if (age < ka)  { kept++; next }
    if (age >= kd) { print $1 > del; gone++; next }
    day = $1; sub(/^.*\//, "", day); day = substr(day, 1, 8)
    if (!(day in seen)) { seen[day] = 1; kept++; next }   # input is sorted: earliest first
    print $1 > del; gone++
  }
  END { printf "%d %d\n", gone + 0, kept + 0 }' "$STAGE/cand-pairs")
GONE="${CLASS%% *}"; KEPT="${CLASS##* }"
case "$GONE$KEPT" in ''|*[!0-9]*)
  say "prune skipped: could not classify $NCAND candidates"
  exit 0 ;;
esac

if [ "$GONE" -gt 0 ]; then
  rm -f "$STAGE"/batch.* 2>/dev/null
  split -l 1000 "$STAGE/todelete" "$STAGE/batch."
  for B in "$STAGE"/batch.*; do
    [ -f "$B" ] || continue
    NB=$(wc -l < "$B")
    DJSON=$(jq -R -n -c '{Objects: [inputs | {Key: .}], Quiet: true}' < "$B" 2>/dev/null)
    s3 delete-objects --bucket "$BUCKET" --delete "$DJSON" > "$STAGE/del.json" 2>"$STAGE/del.err"
    DRC=$?
    ERRS=$(jq -r '(.Errors // []) | length' "$STAGE/del.json" 2>/dev/null)
    # A Quiet batch that fully succeeded is an empty <DeleteResult/>, and the CLI
    # prints NOTHING for an empty response. rc 0 with no body is zero errors, not
    # an unreadable one — reading it as a failure alerts on every good prune.
    if [ "$DRC" -eq 0 ] && [ ! -s "$STAGE/del.json" ]; then ERRS=0; fi
    case "$ERRS" in ''|*[!0-9]*) ERRS=unknown ;; esac
    if [ "$DRC" -ne 0 ] || [ "$ERRS" != 0 ]; then
      # Never counted as pruned. The backup itself is already verified and
      # stamped, so the run still ends 0 — the alert carries the prune failure.
      say "prune batch failed: delete-objects rc=$DRC errors=$ERRS keys=$NB"
      alert prune "delete-objects rc=$DRC errors=$ERRS on a batch of $NB keys under $BOX/"
      GONE=$((GONE - NB))
    fi
  done
fi
say "pruned $GONE kept $KEPT"
exit 0
