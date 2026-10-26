#!/bin/bash
# bin/lib/box-move/seed.sh — `bin/box-move.sh seed <oldbox> <newbox>
# [<ts>|latest]` (BH-8322). Sourced by bin/box-move.sh after
# bin/lib/box-move/common.sh.
#
# bm_seed <ts> <oldbox> <newbox> — the steps, each checked; a failed step is
# exit 4 and no later step runs:
#   1 preflight (exit 3, nothing done): target.json has ts_ip; the rows name
#     the old box (box id, address, projects); the old box env dir holds
#     BACKUP_S3_ENDPOINT, BACKUP_S3_ACCESS_KEY_ID and BACKUP_S3_SECRET_ACCESS_KEY
#     as set lines of a *.env file (a NAME check run on the old box; no value
#     leaves it); the new box env dir is not a symlink.
#   2 code: rsync bin/ prompts/ catalog/ fleet.conf and the checkout from the
#     hub (code, never env).
#   3 env, box to box: one pipe, `tar -c` on the old box into `tar -x` on the
#     new box. Each side resolves its own env dir with its own
#     bin/lib/env-path.sh. The stream crosses the hub in memory only: no hub
#     file, argv or log line holds a value. Both pipe rcs must be 0.
#   4 state: bin/state-restore.sh <box id> <ts> --apply on the new box into an
#     empty tree, with the BACKUP_S3_* files of the new env dir sourced and no
#     --identity (env came in step 3, so env/ is not decrypted).
#   5 swap: bm_swap_script moves the restored state/ flags/ logs/ and
#     orchestrator in (the old copies go to tmp/box-move-prev-<run>, never
#     deleted) and copies the builds/ summaries over. It never touches env.
#   6 identity: the new state/box-id must equal the rows box id; state/box-name
#     is written as <newbox> and read back.
#   7 repos: bin/bootstrap-machine.sh <p> --repos-only for each project of the
#     old box.
#   8 stand-by: a LOCAL flags/all-off on the new box (jobs-client.sh flag-set
#     --local-only, read back with flag-has), then state/hub-move/target-seeded
#     (the marker bin/hub-move.sh tick needs) and state/box-move/seeded
#     (`<ts> <oldbox> <box id>`), both read back.

# The env dir of a harness on this side ($1 = the harness root), through that
# side's own bin/lib/env-path.sh. Sets d.
BM_ENV_RESOLVE='[ -f "$1/bin/lib/env-path.sh" ] || { echo "box-move: no $1/bin/lib/env-path.sh on $(hostname)" >&2; exit 5; }
. "$1/bin/lib/env-path.sh" || exit 5
d=$(harness_env_dir "$1") && [ -n "$d" ] || exit 5'

# Old box: print the first BACKUP_S3 name that no *.env file sets, rc 3; rc 0
# when all three are set.
BM_S_OLD_NAMES="$BM_ENV_RESOLVE"'
[ -d "$d" ] || { echo "(no env dir)"; exit 3; }
for k in BACKUP_S3_ENDPOINT BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_SECRET_ACCESS_KEY; do
  found=0
  for f in "$d"/*.env; do
    [ -f "$f" ] && grep -qE "^(export[[:space:]]+)?$k=." "$f" && { found=1; break; }
  done
  [ "$found" = 1 ] || { echo "$k"; exit 3; }
done'

# New box: rc 3 when the env dir is a symlink. A box without the code yet
# answers for <harness>/env.
BM_S_NEW_ENV_CHECK='if [ -f "$1/bin/lib/env-path.sh" ]; then . "$1/bin/lib/env-path.sh" || exit 5; d=$(harness_env_dir "$1"); else d="$1/env"; fi
[ -L "$d" ] && { echo "$d"; exit 3; }
exit 0'

BM_S_OLD_TAR="$BM_ENV_RESOLVE"'
[ -d "$d" ] || { echo "box-move: no env dir $d" >&2; exit 5; }
tar -C "$d" -cf - .'

BM_S_NEW_UNTAR="$BM_ENV_RESOLVE"'
[ -L "$d" ] && { echo "box-move: the env dir $d is a symlink" >&2; exit 6; }
mkdir -p "$d" && chmod 700 "$d" && tar -C "$d" -xf - && chmod 700 "$d" && find "$d" -type f -exec chmod 600 {} +'

# $1 harness, $2 box id, $3 ts, $4 fresh, $5 dest
BM_S_RESTORE="$BM_ENV_RESOLVE"'
mkdir -p "$4/orchestrator" || exit 1
set -a
for f in "$d"/*.env; do
  [ -f "$f" ] && grep -qE "^(export[[:space:]]+)?BACKUP_S3_" "$f" && . "$f"
done
set +a
unset BACKUP_AGE_IDENTITY_FILE
"$1/bin/state-restore.sh" "$2" "$3" --apply --live "$4" --orchestrator-live "$4/orchestrator" --dest "$5"'

# bm_swap_script — the swap of step 5. Args on the remote side: $1 live
# harness, $2 orchestrator dir, $3 fresh restore tree, $4 prev dir.
bm_swap_script() {
  cat <<'EOF'
set -u
live="$1" orch="$2" fresh="$3" prev="$4"
mkdir -p "$prev" || exit 1
for x in state flags logs; do
  [ -e "$fresh/$x" ] || continue
  if [ -e "$live/$x" ]; then mv "$live/$x" "$prev/$x" || exit 1; fi
  mv "$fresh/$x" "$live/$x" || exit 1
done
if [ -d "$fresh/builds" ]; then
  mkdir -p "$live/builds" && cp -a "$fresh/builds/." "$live/builds/" || exit 1
fi
if [ -e "$fresh/orchestrator" ]; then
  if [ -e "$orch" ]; then mv "$orch" "$prev/orchestrator" || exit 1; fi
  mkdir -p "$(dirname "$orch")" && mv "$fresh/orchestrator" "$orch" || exit 1
fi
case "$fresh" in "$live/tmp/box-move-fresh-"*) rm -rf "$fresh" ;; esac
EOF
}

# bm_env_pipe <old ip> <new ip> — step 3. rc 0 only when both sides answered 0.
bm_env_pipe() {
  local rcs
  bm_sh "$1" "$BM_S_OLD_TAR" "$BM_OH" | bm_sh "$2" "$BM_S_NEW_UNTAR" "$BM_TH"
  rcs=("${PIPESTATUS[@]}")
  BM_PIPE_RCS="old=${rcs[0]} new=${rcs[1]}"
  [ "${rcs[0]}" -eq 0 ] && [ "${rcs[1]}" -eq 0 ]
}

bm_seed() {
  local ts="$1" old="$2" new="$3" ip out rc p id name run fresh dest prev
  case "$ts" in latest|[0-9]*T[0-9]*Z) ;; *) echo "box-move: seed ts '$ts' is not latest or <YYYYMMDDTHHMMSSZ>" >&2; exit 2 ;; esac
  # 1. preflight
  ip=$(bm_tj_get ts_ip)
  [ -n "$ip" ] || bm_refuse "$BM_TJ has no ts_ip (run provision first)"
  grep -qE '^[0-9A-Fa-f.:]+$' <<<"$ip" || bm_refuse "$BM_TJ ts_ip '$ip' is not an address"
  bm_rows_resolve "$old" "$new"
  out=$(bm_sh "$BM_OLD_IP" "$BM_S_OLD_NAMES" "$BM_OH" 2>/dev/null); rc=$?
  case "$rc" in
    0) ;;
    3) bm_refuse "$out is not set in a *.env file of the env dir on $old (seed needs the MKF-6 backup keys)" ;;
    *) bm_refuse "cannot read the env key names on $old ($BM_OLD_IP) rc=$rc" ;;
  esac
  out=$(bm_sh "$ip" "$BM_S_NEW_ENV_CHECK" "$BM_TH" 2>/dev/null); rc=$?
  case "$rc" in
    0) ;;
    3) bm_refuse "the env dir $out on $new is a symlink" ;;
    *) bm_refuse "cannot check the env dir on $new ($ip) rc=$rc" ;;
  esac

  # 2. code
  bm_say "seed: harness code to $ip:$BM_TH"
  bm_sh "$ip" 'mkdir -p "$1"' "$BM_TH" || bm_fail "mkdir $BM_TH on $ip"
  for p in bin prompts catalog; do
    [ -d "$HARNESS/$p" ] || continue
    rsync -a -e "ssh ${BM_SSH_OPTS[*]}" "$HARNESS/$p/" "root@$ip:$BM_TH/$p/" || bm_fail "rsync $p to $ip"
  done
  if [ -f "$HARNESS/fleet.conf" ]; then
    rsync -a -e "ssh ${BM_SSH_OPTS[*]}" "$HARNESS/fleet.conf" "root@$ip:$BM_TH/fleet.conf" || bm_fail "rsync fleet.conf to $ip"
  fi
  if [ -d "$BM_CHECKOUT/.git" ]; then
    rsync -a --exclude node_modules -e "ssh ${BM_SSH_OPTS[*]}" "$BM_CHECKOUT/" "root@$ip:$BM_CHECKOUT/" || bm_fail "rsync checkout to $ip"
  fi

  # 3. env, box to box
  bm_say "seed: env from $old ($BM_OLD_IP) to $new ($ip), one pipe"
  bm_env_pipe "$BM_OLD_IP" "$ip" || bm_fail "env pipe $old -> $new ($BM_PIPE_RCS); state not restored"

  # 4. state
  run="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  fresh="$BM_TH/tmp/box-move-fresh-$run"; dest="$BM_TH/tmp/box-move-restore-$run"; prev="$BM_TH/tmp/box-move-prev-$run"
  bm_say "seed: state-restore $BM_BOX_ID $ts --apply on $ip into an empty tree (no identity: env came box to box)"
  bm_sh "$ip" "$BM_S_RESTORE" "$BM_TH" "$BM_BOX_ID" "$ts" "$fresh" "$dest"; rc=$?
  [ "$rc" -eq 0 ] || bm_fail "state-restore on $ip rc=$rc"

  # 5. swap
  bm_say "seed: swap the restored state, flags, logs and orchestrator in (old copies to $prev)"
  bm_sh "$ip" "$(bm_swap_script)" "$BM_TH" "$BM_TORCH" "$fresh" "$prev"; rc=$?
  [ "$rc" -eq 0 ] || bm_fail "swap of the restored tree on $ip rc=$rc (old copies in $prev)"

  # 6. identity
  id=$(bm_sh "$ip" 'cat "$1/state/box-id"' "$BM_TH" 2>/dev/null)
  [ "$id" = "$BM_BOX_ID" ] || bm_fail "the new state/box-id is '$id', want '$BM_BOX_ID' (the rows of $old)"
  name=$(bm_sh "$ip" 'printf "%s\n" "$2" > "$1/state/box-name" && cat "$1/state/box-name"' "$BM_TH" "$new" 2>/dev/null)
  [ "$name" = "$new" ] || bm_fail "the new state/box-name reads '$name', want '$new'"
  bm_say "seed: box-id=$id box-name=$name"

  # 7. repos
  for p in $BM_PROJECTS; do
    bm_say "seed: repos for $p"
    bm_sh "$ip" '"$1/bin/bootstrap-machine.sh" "$2" --repos-only' "$BM_TH" "$p" >/dev/null \
      || bm_fail "bootstrap-machine $p --repos-only on $ip"
  done

  # 8. stand-by: a LOCAL all-off (the flags/ file, never a fleet row) and the markers.
  bm_sh "$ip" 'HARNESS="$1" "$1/bin/jobs-client.sh" flag-set --local-only all-off on "box-move seed: the new box stands by until cutover" >/dev/null 2>&1' "$BM_TH"
  bm_sh "$ip" 'HARNESS="$1" "$1/bin/jobs-client.sh" flag-has all-off >/dev/null 2>&1' "$BM_TH" \
    || bm_fail "flags/all-off does not read on on $new"
  bm_sh "$ip" 'mkdir -p "$1/state/hub-move" "$1/state/box-move" \
    && date -u "+%Y-%m-%dT%H:%M:%SZ box-move seed $2" > "$1/state/hub-move/target-seeded" \
    && printf "%s %s %s\n" "$2" "$3" "$4" > "$1/state/box-move/seeded" \
    && [ -s "$1/state/hub-move/target-seeded" ] && [ -s "$1/state/box-move/seeded" ]' "$BM_TH" "$ts" "$old" "$BM_BOX_ID" \
    || bm_fail "cannot write state/hub-move/target-seeded and state/box-move/seeded on $new"
  local plist="${BM_PROJECTS// /,}"
  bm_say "seed: done ($ts) box_id=$BM_BOX_ID projects=${plist:--}"
}
