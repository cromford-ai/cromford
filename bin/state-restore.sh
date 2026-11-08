#!/bin/bash
# bin/state-restore.sh — pull a box's off-box state copy back out of the bucket
# and hand it to bin/restore-merge.sh.
#
# WHY (#388, 2026-09-15; parent #396). The hub's /root/harness/{env,bin,prompts,
# logs,builds} vanished under a running system and nothing came back, because
# there was no off-box copy and no command that knew how to bring one home.
# bin/state-backup.sh (#447) is the uploader, bin/restore-merge.sh (#446) is the
# merge policy that never lets old snapshot content win over live content; this
# is the one command an operator runs between them:
#
#   list -> pull -> prove the sha256 -> extract -> decrypt env/ -> print meta
#        -> hand the tree to bin/restore-merge.sh
#
# DRY RUN IS THE DEFAULT. Without --apply nothing in the live tree is written;
# the snapshot is still pulled and extracted so the operator can read the plan
# restore-merge prints. Outside --standby the tool NEVER deletes anything, not
# even its own destination: an existing destination is a refusal with the path, and the
# operator owns the rm (docs/RESTORE.md says so). env.tar.age is split out of
# the tarball BEFORE the tree is extracted, so the encrypted blob can never be
# handed to the merge as a stray root file, and the decrypted env/ is staged
# under the destination and only moved into the tree once age exited 0.
#
# It writes no log line and no ALERTS line: an operator runs it and reads
# stdout. It never prints an env value — only key NAMES, paths, and the two
# meta/ files (the crontab is SHOWN, never installed).
#
# STANDBY MODE (#1923, part of #401). `<hub> latest --apply --standby` is the
# 15-minute state stream a standby box runs to keep env/, state/ and
# orchestrator/ current from its hub's newest tarball — never logs/. It needs an
# identity (no env/ is no standby), pulls under $H/tmp/standby-restore (mode
# 700) and keeps a watermark in <live>/state/standby-stream.json =
# {of, snapshot, key, rc, at}: a snapshot already merged with rc 0 is
# `up to date <ts>` and is not pulled again. The extracted tree is pruned to
# env/ state/ orchestrator/ minus the hub's identity files (state/box-id,
# box-name, hub-lease.json, hub-lease-failing-since, standby-stream.json,
# standby-of) BEFORE the merge, meta/ is not printed, and restore-merge runs
# with --keep-cursor so the standby's own alerts cursor is never touched. The
# run dir holds decrypted env/, so a success REMOVES it; a failure keeps it as
# <ts>.failed, one per hub, and a later run removes the leftover of a killed
# one. It refuses (rc 1, before any bucket call, nothing written or reported)
# on <hub> itself, on a box holding the hub lease (hub-lease.sh check, or
# <live>/state/hub-lease.json held=1), and when <live>/state/standby-of exists
# ("<hub-name> <hub-id>", as standby-install.sh writes it) and <box> is neither
# that id nor that name. A box whose own name is the listed hub name IS that
# hub, and refuses too. Every run past those checks then writes the watermark with its
# real exit code and reports {of, snapshot, ok} to the watchdog's
# /api/standby/<self> (fail-open: a failed POST never changes the exit code),
# then {box, of, snapshot, ok} to the hub's /api/hub/standby/heartbeat through
# bin/standby-heartbeat.sh (BH-2640), fail-open the same way.
#
# Usage:
#   bin/state-restore.sh <box> [ts|latest] [--apply] [--identity <file>]
#                        [--live <dir>] [--dest <dir>]
#                        [--backup-dir <dir>] [--orchestrator-live <dir>]
#                        [--standby]
#
#   <box>                      the box prefix in the bucket ([a-z0-9-])
#   [ts|latest]                20260915T232000Z, or `latest`. No ts at all
#                              lists what is there and stops.
#   --apply                    let restore-merge write; without it, dry run
#   --identity <file>          the age PRIVATE key that decrypts env/. It does
#                              not live on a box (BACKUP_AGE_IDENTITY_FILE is
#                              read if set). Without one, env/ is skipped out
#                              loud and everything else still restores.
#   --live <dir>               the harness tree to merge into (default /root/harness)
#   --dest <dir>               where the snapshot is pulled (default
#                              $H/tmp/state-restore). It may not sit inside
#                              --live anywhere except <live>/tmp — extracting a
#                              snapshot over live content is the wipe again, one
#                              directory deeper, and tmp/ is the one place the
#                              backup never reads from.
#   --backup-dir <dir>         passed through to restore-merge
#   --orchestrator-live <dir>  passed through to restore-merge
#   --standby                  the state stream above; needs a ts and --apply,
#                              and a --dest under $H/tmp/ (default
#                              $H/tmp/standby-restore) because it deletes its
#                              own run dirs
#
# Exit: 0 everything asked for happened (or, --standby, already up to date). 1 refused or partly refused (not
# configured, no backups, sha256 mismatch, wrong identity, extraction failed,
# destination exists, restore-merge failed, --standby on the hub / a lease
# holder / a standby of another box). 2 usage error (including
# --standby without a ts or --apply, or with a --dest outside $H/tmp/), --dest inside
# --live, or no bin/restore-merge.sh next to this script.
set -uo pipefail

SELF=$(basename "$0")
HERE=$(cd "$(dirname "$0")" && pwd)

usage() {
  echo "$SELF: usage: $SELF <box> [ts|latest] [--apply] [--identity <file>] [--live <dir>] [--dest <dir>] [--backup-dir <dir>] [--orchestrator-live <dir>] [--standby]" >&2
  echo "$SELF:        no ts lists the backups for <box>; with a ts the default is a DRY RUN." >&2
  exit 2
}

BOX=""; TSARG=""; APPLY=0; IDFILE=""; LIVE="/root/harness"; DEST=""
BACKUP_DIR=""; ORCH_LIVE=""; STANDBY=0
# Set further down, read by the --standby EXIT trap. Initialised here so an
# early exit never acts on (or reports) a value inherited from the caller's
# environment: OUT is an rm -rf target.
OUT=""; TS=""; KEY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)             APPLY=1; shift ;;
    --standby)           STANDBY=1; shift ;;
    --identity)          [ $# -ge 2 ] || usage; IDFILE="$2"; shift 2 ;;
    --live)              [ $# -ge 2 ] || usage; LIVE="$2"; shift 2 ;;
    --dest)              [ $# -ge 2 ] || usage; DEST="$2"; shift 2 ;;
    --backup-dir)        [ $# -ge 2 ] || usage; BACKUP_DIR="$2"; shift 2 ;;
    --orchestrator-live) [ $# -ge 2 ] || usage; ORCH_LIVE="$2"; shift 2 ;;
    -h|--help)           sed -n '2,/^set -uo/p' "$0" | sed 's/^# \{0,1\}//; $d'; exit 0 ;;
    -*)                  echo "$SELF: unknown argument '$1'" >&2; usage ;;
    *)
      if   [ -z "$BOX" ];   then BOX="$1"
      elif [ -z "$TSARG" ]; then TSARG="$1"
      else echo "$SELF: unexpected argument '$1'" >&2; usage
      fi
      shift ;;
  esac
done

# The box name is the object prefix. Anything outside the alphabet
# bin/state-backup.sh can produce is a typo or a path, and neither is worth a
# bucket call.
case "$BOX" in ''|*[!a-z0-9-]*) echo "$SELF: <box> must match [a-z0-9-]+" >&2; usage ;; esac
case "$TSARG" in
  ''|latest) ;;
  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9]Z) ;;
  *) echo "$SELF: [ts] must be 'latest' or YYYYMMDDTHHMMSSZ" >&2; usage ;;
esac
if [ "$STANDBY" -eq 1 ] && { [ -z "$TSARG" ] || [ "$APPLY" -eq 0 ]; }; then
  echo "$SELF: --standby needs a ts (or latest) and --apply" >&2; usage
fi

H="${HARNESS_ROOT:-${HARNESS:-/root/harness}}"
LIVE=${LIVE%/}
[ "$STANDBY" -eq 1 ] && DEST="${DEST:-$H/tmp/standby-restore}"
DEST="${DEST:-$H/tmp/state-restore}"
DEST=${DEST%/}

# Extracting a snapshot INTO the live tree is the wipe again, one directory
# deeper. Refused before anything is listed or pulled.
DESTR=$(realpath -m "$DEST" 2>/dev/null) || DESTR=""
LIVER=$(realpath -m "$LIVE" 2>/dev/null) || LIVER=""
[ -n "$DESTR" ] || DESTR="$DEST"
[ -n "$LIVER" ] || LIVER="$LIVE"
# --standby deletes its own run dirs, so it only ever pulls under $H/tmp/.
if [ "$STANDBY" -eq 1 ]; then
  case "$DESTR" in
    "$(realpath -m "$H" 2>/dev/null)"/tmp/?*) ;;
    *) echo "$SELF: --standby --dest ($DEST) must sit under $H/tmp/" >&2; exit 2 ;;
  esac
fi
case "$DESTR" in
  "$LIVER"/tmp|"$LIVER"/tmp/*) ;;   # the default, and the one directory inside a
                                    # live tree that nothing is ever restored
                                    # FROM: state-backup.sh does not tar tmp/
  "$LIVER"|"$LIVER"/*)
    echo "$SELF: --dest ($DEST) is inside --live ($LIVE); pull somewhere else" >&2
    exit 2 ;;
esac

RM="$HERE/restore-merge.sh"
if [ ! -f "$RM" ]; then
  echo "$SELF: no bin/restore-merge.sh next to this script ($RM) - it is the half that merges" >&2
  exit 2
fi

# shellcheck disable=SC1091
. "$H/bin/lib/env-path.sh" 2>/dev/null || harness_env_dir() { printf '%s/env\n' "$H"; }
HENV=$(harness_env_dir "$H")
if [ -f "$HENV/global.env" ]; then
  set -a
  # shellcheck disable=SC1090,SC1091
  . "$HENV/global.env" 2>/dev/null
  set +a
fi
# BH-3322: where the watchdog lives; unset skips only the standby report.
# shellcheck disable=SC1091
. "$H/bin/lib/watchdog-url.sh" 2>/dev/null || . "$HERE/lib/watchdog-url.sh" 2>/dev/null || watchdog_url() { return 1; }

BUCKET="${BACKUP_S3_BUCKET:-harness-state}"
REGION="${BACKUP_S3_REGION:-auto}"
S3C="${BACKUP_S3_CLIENT:-aws}"
[ -n "$IDFILE" ] || IDFILE="${BACKUP_AGE_IDENTITY_FILE:-}"

# ---- configured? -----------------------------------------------------------
# Nothing is listed, pulled or written until every input this run needs is
# present. zstd is only needed once we pull; age only when an identity is given
# — a pulled object nobody on this box can open is wasted egress, so both are
# checked BEFORE the first bucket call, not at the moment they are used.
MISSING=""
for V in BACKUP_S3_ENDPOINT BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY; do
  [ -n "${!V:-}" ] || MISSING="$MISSING $V"
done
for C in "$S3C" jq; do
  command -v "$C" >/dev/null 2>&1 || MISSING="$MISSING $C"
done
if [ -n "$TSARG" ]; then
  command -v zstd >/dev/null 2>&1 || MISSING="$MISSING zstd"
  if [ -n "$IDFILE" ]; then
    command -v age >/dev/null 2>&1 || MISSING="$MISSING age"
  fi
fi
[ "$STANDBY" -eq 1 ] && [ -z "$IDFILE" ] && MISSING="$MISSING BACKUP_AGE_IDENTITY_FILE"
if [ -n "$MISSING" ]; then
  printf 'not configured - missing:%s\n' "$MISSING"
  exit 1
fi

# ---- standby: only ever INTO a standby of <box> ----------------------------
# A promoted standby whose stream is still installed would otherwise keep
# merging the OLD hub's tarball into the live hub every 15 minutes: ADD brings
# back files the hub deleted (claims, markers, consumed state). So before any
# bucket call, and before the EXIT trap (a refusal writes no watermark and
# reports nothing), refuse when this box IS <box>, holds the hub lease (the
# worker's answer, or the cache saying held), or is configured as a standby
# of some other box.
if [ "$STANDBY" -eq 1 ]; then
  # state/standby-of is "<hub-name> <hub-id>", as bin/standby-install.sh writes
  # it (and fleet-conf.sh --standby-of prints it); the installer's cron passes
  # the hub ID as <box>. A one-token file (hand-written) is read as the id.
  SB_NAME=""; SB_ID=""
  if [ -f "$LIVE/state/standby-of" ]; then
    read -r SB_NAME SB_ID _ < "$LIVE/state/standby-of" 2>/dev/null || true
    [ -n "$SB_ID" ] || SB_ID="$SB_NAME"
  fi
  SBSELF=$(HARNESS="$H" "$HERE/box-name.sh" 2>/dev/null)
  # Self: this box's name is <box>, or is the hub NAME its standby-of lists —
  # <box> is usually the hub id, which a box name never equals.
  if [ -n "$SBSELF" ] && { [ "$SBSELF" = "$BOX" ] || { [ -n "$SB_NAME" ] && [ "$SB_ID" != "$SB_NAME" ] && [ "$SBSELF" = "$SB_NAME" ]; }; }; then
    echo "REFUSED: --standby of $BOX on $BOX itself (this box is ${SBSELF})"; exit 1
  fi
  if { [ -n "$SBSELF" ] && HARNESS="$H" HUB_LEASE_HOLDER="$SBSELF" "$HERE/hub-lease.sh" check >/dev/null 2>&1; } \
     || jq -e '(.held|tostring) == "1"' "$LIVE/state/hub-lease.json" >/dev/null 2>&1; then
    echo "REFUSED: --standby on a box that holds the hub lease"; exit 1
  fi
  # Another hub's standby: <box> must be the hub standby-of names, by id (what
  # the installer's cron passes) or by name.
  if [ -f "$LIVE/state/standby-of" ] && [ "$BOX" != "$SB_ID" ] && [ "$BOX" != "$SB_NAME" ]; then
    echo "REFUSED: --standby of $BOX but $LIVE/state/standby-of names '${SB_NAME}${SB_ID:+ $SB_ID}'"; exit 1
  fi
fi

# ---- standby: the finish every run past this point takes -------------------
# Order matters: the run dir is disposed of, the watermark records the REAL rc,
# and only then is anything claimed to the watchdog, so a report can never say
# ok for a run the watermark says failed. The URL carries the secret, so it is
# never printed.
W="$LIVE/state/standby-stream.json"
standby_finish() { # $1 = the rc the run is exiting with
  local rc="$1" s="" self="" body="" wd=""
  # Only this run's own dir under the standby dest is ever deleted or moved.
  case "$OUT" in "$DEST/$BOX"/?*) ;; *) OUT="" ;; esac
  if [ -n "$OUT" ] && [ -e "$OUT" ]; then
    if [ "$rc" -eq 0 ]; then
      rm -rf -- "$OUT"
    else
      case "$DEST" in "$H"/tmp/?*) rm -rf -- "$DEST/$BOX"/*.failed ;; esac
      mv -- "$OUT" "$OUT.failed" && echo "kept the failed run at $OUT.failed"
    fi
  fi
  if ! { mkdir -p "$LIVE/state" \
         && jq -n --arg of "$BOX" --arg s "$TS" --arg k "$KEY" --argjson rc "$rc" \
              --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
              '{of: $of, snapshot: $s, key: $k, rc: $rc, at: $at}' > "$W.tmp.$$" \
         && mv -f -- "$W.tmp.$$" "$W"; } 2>/dev/null; then
    rm -f -- "$W.tmp.$$"
    echo "standby watermark NOT written ($W)"
  fi
  [ -r "$HENV/.watchdog-secret" ] && s=$(tr -d '\r\n' < "$HENV/.watchdog-secret" 2>/dev/null)
  [ -n "$s" ] || s="${WATCHDOG_SECRET:-}"
  self=$(HARNESS="$H" "$HERE/box-name.sh" 2>/dev/null)
  if [ -z "$s" ]; then
    echo "standby report skipped: watchdog secret not configured"
  elif [ -z "$self" ]; then
    echo "standby report skipped: box name not configured"
  elif ! wd=$(watchdog_url state-restore "$H"); then
    echo "standby report skipped: WATCHDOG_URL not configured"
  else
    body=$(jq -nc --arg of "$BOX" --arg s "$TS" --argjson rc "$rc" '{of: $of, snapshot: $s, ok: ($rc == 0)}')
    watchdog_curl -fsS -m 10 -X POST -H 'content-type: application/json' --data "$body" \
      "$wd/api/standby/$self" >/dev/null 2>&1 \
      || echo "standby report failed (fail-open)"
  fi
  # The second report, to the hub's standby_status (BH-2640). Also fail-open:
  # it always exits 0 and prints its own one line.
  HARNESS="$H" "$HERE/standby-heartbeat.sh" "$BOX" "$TS" "$rc" 2>/dev/null || true
  exit "$rc"
}
if [ "$STANDBY" -eq 1 ]; then
  trap 'standby_finish $?' EXIT
  { mkdir -p -- "$DEST" && chmod 700 -- "$DEST"; } 2>/dev/null \
    || { echo "REFUSED: cannot create $DEST mode 700"; exit 1; }
fi

s3() { # the only seam to the bucket; credentials are set for this call alone
  AWS_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY_ID" \
  AWS_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_ACCESS_KEY" \
  AWS_DEFAULT_REGION="$REGION" AWS_PAGER= \
  "$S3C" s3api "$1" --endpoint-url "$BACKUP_S3_ENDPOINT" --output json "${@:2}"
}

# ---- the listing, followed to the end --------------------------------------
# A real bucket answers at most 1000 keys per page, lexicographically. Reading
# page one only would make `latest` the OLDEST key on any box that outgrew a
# page, which is the wrong snapshot to restore in exactly the situation this
# tool exists for.
KEYRE="^$BOX/[0-9]{8}T[0-9]{6}Z\\.tar\\.zst\$"
ROWS=""
TOKEN=""
PAGES=0
MAXPAGES=1000        # 1000 pages x 1000 keys; an endpoint that hands back the
                     # same token forever is a bug we stop on, not spin on
while :; do
  PAGES=$((PAGES + 1))
  if [ "$PAGES" -gt "$MAXPAGES" ]; then
    echo "REFUSED: the listing for $BUCKET/$BOX/ did not end after $MAXPAGES pages"
    exit 1
  fi
  if [ -n "$TOKEN" ]; then
    PAGE=$(s3 list-objects-v2 --bucket "$BUCKET" --prefix "$BOX/" --continuation-token "$TOKEN" 2>/dev/null)
  else
    PAGE=$(s3 list-objects-v2 --bucket "$BUCKET" --prefix "$BOX/" 2>/dev/null)
  fi
  LRC=$?
  if [ "$LRC" -ne 0 ]; then
    echo "REFUSED: list-objects-v2 rc=$LRC for $BUCKET/$BOX/"
    exit 1
  fi
  CHUNK=$(printf '%s' "$PAGE" | jq -r --arg re "$KEYRE" \
    '.Contents[]? | select((.Key // "") | test($re)) | "\(.Key)\t\(.Size)"' 2>/dev/null)
  [ -n "$CHUNK" ] && ROWS="$ROWS$CHUNK"$'\n'
  TOKEN=$(printf '%s' "$PAGE" | jq -r \
    'if (.IsTruncated == true) then (.NextContinuationToken // empty) else empty end' 2>/dev/null)
  [ -n "$TOKEN" ] || break
done
ROWS=$(printf '%s' "$ROWS" | grep -v '^$' | LC_ALL=C sort)

if [ -z "$ROWS" ]; then
  echo "no backups for $BOX"
  exit 1
fi

if [ -z "$TSARG" ]; then
  printf '%s\n' "$ROWS" | while IFS=$'\t' read -r k sz; do
    k=${k##*/}
    printf '%s  %s\n' "${k%.tar.zst}" "$sz"
  done
  exit 0
fi

# ---- which object ----------------------------------------------------------
if [ "$TSARG" = latest ]; then
  KEY=$(printf '%s\n' "$ROWS" | tail -1 | cut -f1)
  TS=${KEY##*/}; TS=${TS%.tar.zst}
else
  TS="$TSARG"
  KEY="$BOX/$TS.tar.zst"
  # grep reads to the end (no -q): an early exit SIGPIPEs cut on a long
  # listing and pipefail would call a listed snapshot missing (BH-4719).
  printf '%s\n' "$ROWS" | cut -f1 | grep -xF "$KEY" >/dev/null || {
    echo "no backup $KEY"
    exit 1
  }
fi

if [ "$STANDBY" -eq 1 ] \
   && jq -e --arg of "$BOX" --arg s "$TS" '.of == $of and .snapshot == $s and .rc == 0' "$W" >/dev/null 2>&1; then
  echo "up to date $TS"
  exit 0
fi

OUT="$DEST/$BOX/$TS"
# A standby run dir that already exists is a killed earlier run's partial pull,
# under this mode's own destination: it is removed, not refused.
[ "$STANDBY" -eq 1 ] && rm -rf -- "$OUT"
if [ -e "$OUT" ]; then
  echo "already pulled at $OUT; remove it or pass --dest"
  exit 1
fi
mkdir -p "$OUT/tree" 2>/dev/null || { echo "REFUSED: cannot create $OUT"; exit 1; }

# ---- pull ------------------------------------------------------------------
TARBALL="$OUT/snapshot.tar.zst"
s3 get-object --bucket "$BUCKET" --key "$KEY" "$TARBALL" > "$OUT/get.json" 2>"$OUT/get.err"
GRC=$?
if [ "$GRC" -ne 0 ] || [ ! -f "$TARBALL" ]; then
  echo "REFUSED: get-object rc=$GRC for $KEY"
  exit 1
fi
echo "pulled $KEY -> $TARBALL"

# ---- prove it is the object that was uploaded ------------------------------
# An empty stored sha256 is ABSENT, not a match: the one thing this must never
# do is call a tampered or truncated tarball verified.
DLSHA=$(sha256sum "$TARBALL" 2>/dev/null | cut -d' ' -f1)
HEADJ=$(s3 head-object --bucket "$BUCKET" --key "$KEY" 2>/dev/null)
HRC=$?
if [ "$HRC" -ne 0 ]; then
  echo "sha256 unverified (head-object rc=$HRC)"
else
  STORED=$(printf '%s' "$HEADJ" | jq -r '.Metadata.sha256 // empty' 2>/dev/null)
  if [ -z "$STORED" ]; then
    echo "sha256 unverified (no metadata)"
  elif [ "$STORED" != "$DLSHA" ]; then
    echo "REFUSED: sha256 mismatch for $KEY (stored $STORED, downloaded $DLSHA)"
    exit 1
  else
    echo "sha256 ok $DLSHA"
  fi
fi

# ---- extract, in two steps -------------------------------------------------
# env.tar.age first and on its own, so the encrypted blob lands NEXT TO the
# tree and never inside it. The member is absent from a foreign or older
# tarball, and tar says so with rc 2; the file on disk is the answer, not the
# rc.
tar --zstd -xf "$TARBALL" -C "$OUT" env.tar.age 2>"$OUT/tar-env.err"
tar --zstd -xf "$TARBALL" -C "$OUT/tree" --exclude=env.tar.age 2>"$OUT/tar-tree.err"
TRC=$?
if [ "$TRC" -ne 0 ]; then
  echo "REFUSED: tar rc=$TRC extracting $KEY ($(head -c 200 "$OUT/tar-tree.err" | tr '\n' ' '))"
  exit 1
fi
if [ -z "$(find "$OUT/tree" -mindepth 1 -print -quit 2>/dev/null)" ]; then
  echo "REFUSED: nothing extracted from $KEY"
  exit 1
fi
echo "extracted $KEY -> $OUT/tree"

# ---- env/ ------------------------------------------------------------------
# The private key is not on a box. Without one this is a state restore that
# skips env/ out loud; with the wrong one it is a state restore that REFUSES
# env/ and still exits 1 at the end, so nobody reads the merge summary as "env
# came back".
ENV_RC=0
if [ -z "$IDFILE" ]; then
  echo "env/ NOT decrypted (no identity given): env files will not be restored"
elif [ ! -f "$OUT/env.tar.age" ]; then
  echo "no env.tar.age in this snapshot"
else
  mkdir -p "$OUT/env-stage" 2>/dev/null
  age -d -i "$IDFILE" "$OUT/env.tar.age" 2>"$OUT/age.err" | tar -xf - -C "$OUT/env-stage" 2>"$OUT/tar-env-stage.err"
  ERCS=("${PIPESTATUS[@]}")
  # Whatever a failure wrote stays in env-stage/, under the destination, never
  # under --live. Nothing is removed: a half-decrypt is evidence. Each failure
  # says which half failed — "wrong identity?" on a successful decrypt would
  # send the operator hunting for the wrong key.
  if [ "${ERCS[0]}" -ne 0 ] || [ "${ERCS[1]}" -ne 0 ] || [ ! -d "$OUT/env-stage/env" ]; then
    echo "REFUSED env/: age rc=${ERCS[0]} (wrong identity?), tar rc=${ERCS[1]} - env files will not be restored"
    ENV_RC=1
  elif mv "$OUT/env-stage/env" "$OUT/tree/env" 2>/dev/null; then
    NENV=$(find "$OUT/tree/env" -type f 2>/dev/null | wc -l)
    echo "env/ decrypted: $NENV files staged"
  else
    echo "REFUSED env/: decrypted, but $OUT/env-stage/env could not be staged into the tree - env files will not be restored"
    ENV_RC=1
  fi
fi

# ---- standby: only env/ state/ orchestrator/, and never the hub's identity --
# Pruned from the extracted TREE, never from live.
if [ "$STANDBY" -eq 1 ]; then
  find "$OUT/tree" -mindepth 1 -maxdepth 1 ! -name env ! -name state ! -name orchestrator -exec rm -rf {} +
  for f in box-id box-name hub-lease.json hub-lease-failing-since standby-stream.json standby-of; do
    rm -f -- "$OUT/tree/state/$f"
  done
  echo "pruned tree to env/ state/ orchestrator/"
else
# ---- what the box was, for the operator ------------------------------------
for M in checkout-head.txt crontab.txt; do
  printf -- '--- meta/%s ---\n' "$M"
  if [ -f "$OUT/tree/meta/$M" ]; then cat "$OUT/tree/meta/$M"; else echo '(missing)'; fi
done
echo 'crontab is shown, not installed'
fi

# ---- the merge ---------------------------------------------------------------
# A child, not an exec: a wrong identity has to outlive restore-merge's rc so
# the run can still end 1.
RMARGS=(--snapshot "$OUT/tree" --live "$LIVE")
[ "$APPLY" -eq 1 ] && RMARGS+=(--apply)
[ -n "$BACKUP_DIR" ] && RMARGS+=(--backup-dir "$BACKUP_DIR")
[ -n "$ORCH_LIVE" ] && RMARGS+=(--orchestrator-live "$ORCH_LIVE")
[ "$STANDBY" -eq 1 ] && RMARGS+=(--backup-dir "$OUT/merge-backup" --keep-cursor)
"$RM" "${RMARGS[@]}"
MRC=$?

[ "$ENV_RC" -eq 1 ] && exit 1
exit "$MRC"
