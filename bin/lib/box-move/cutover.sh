#!/bin/bash
# bin/lib/box-move/cutover.sh — `bin/box-move.sh cutover --step B1..B5` and
# `bin/box-move.sh rollback` (BH-8410, MKF-7 slice C1). Sourced by
# bin/box-move.sh after bin/lib/box-move/common.sh, seed.sh and
# bin/lib/hub-move-reach.sh. The runbook is
# docs/notes/2026-10-26-BH-8410-box-move-cutover.md.
#
# Every cut-over record is on the hub, in $BM_STATE (state/box-move/<newbox>/):
#   steps.tsv     <stamp>\t<step>\t<ok|fail|reset>\t<detail>; the status of a
#                 step is its LAST row
#   old-crontab   the old box `crontab -l`, saved by B2; never overwritten by
#                 an empty one
#   old-rows.tsv  `box\t<oldbox>\t<box_id>\t<ip>\t<role>` and one
#                 `project\t<p>` line per project of the old box, saved once by
#                 B2. B3, B4, B5 and rollback read it: after B4 the rows put
#                 the projects on the new box, and bm_rows_resolve refuses.
#
# A step refuses (exit 3, nothing done) when the step before it is not ok.
# A failed step is recorded `fail` and exits 4; the sub-steps before it stay
# done, and each is safe to run again.
#
# The registry is written only through bin/registry.sh. Never `drain-box`
# here: it deletes the lane rows of a box ID, and the new box keeps the old
# box id, so it would strip the new box too.

# Active crontab lines: not blank, not a comment, not a VAR= line.
BM_ACTIVE_RE='^[[:space:]]*(#|$)|^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*='
BM_S_ACTIVE='crontab -l 2>/dev/null | grep -cvE "'"$BM_ACTIVE_RE"'"'

# $1 harness: `crontab_active=<n>` and `all_off=<on|off>` for this box.
BM_S_STANDBY='c=$('"$BM_S_ACTIVE"'); echo "crontab_active=${c:-0}"
if HARNESS="$1" "$1/bin/jobs-client.sh" flag-has all-off >/dev/null 2>&1; then echo "all_off=on"; else echo "all_off=off"; fi'
# $1 harness, $2 flag, $3 reason: a LOCAL flag on, read back.
BM_S_FLAG_ON='HARNESS="$1" "$1/bin/jobs-client.sh" flag-set --local-only "$2" on "$3" >/dev/null 2>&1
HARNESS="$1" "$1/bin/jobs-client.sh" flag-has "$2" >/dev/null 2>&1'
# $1 harness, $2 flag, $3 reason: a LOCAL flag off, read back (flag-has rc 1;
# rc 2, an unknown answer, is not off).
BM_S_FLAG_OFF='HARNESS="$1" "$1/bin/jobs-client.sh" flag-clear --local-only "$2" "$3" >/dev/null 2>&1
HARNESS="$1" "$1/bin/jobs-client.sh" flag-has "$2" >/dev/null 2>&1; [ $? -eq 1 ]'
# crontab -r, then the active line count (0 is the only good answer).
BM_S_CRON_REMOVE='crontab -r 2>/dev/null; '"$BM_S_ACTIVE"' || true'
# $1 harness, $2 timeout: hub-move.sh drain (no $1/bin/ process left).
BM_S_DRAIN='HARNESS="$1" HUB_MOVE_DRAIN_TIMEOUT_S="$2" "$1/bin/hub-move.sh" drain'
BM_S_BACKUP_TS='jq -r ".ts // empty" "$1/state/backup-last.json" 2>/dev/null; true'
BM_S_BACKUP='BACKUP_FORCE=1 HARNESS="$1" "$1/bin/state-backup.sh"'
# The crontab text rides stdin into a temp file; prints the active count.
BM_S_CRON_INSTALL='t=$(mktemp) || exit 1
cat > "$t" && crontab "$t"; rc=$?
rm -f "$t"
[ "$rc" -eq 0 ] || exit "$rc"
'"$BM_S_ACTIVE"' || true'
# $1 harness, $2 reach host, $3 checkout.
BM_S_TICK_REAL='HUB_MOVE_REACH_HOST="$2" HARNESS="$1" HARNESS_CHECKOUT="$3" "$1/bin/hub-move.sh" tick --real'

bm_now() { echo "${HUB_MOVE_NOW:-$(date +%s)}"; }   # the clock hub-move stamps its tick table with

bm_step_record() { # bm_step_record <step> <ok|fail|reset> <detail>
  mkdir -p "$BM_STATE" || return 1
  local f="$BM_STATE/steps.tsv" tmp="$BM_STATE/steps.tsv.tmp.$$"
  { [ -f "$f" ] && cat "$f"; printf '%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$1" "$2" "$3"; } > "$tmp" \
    && mv -f "$tmp" "$f"
}
bm_step_status() { [ -f "$BM_STATE/steps.tsv" ] && awk -F'\t' -v s="$1" '$2 == s {v = $3} END {print v}' "$BM_STATE/steps.tsv"; }
# bm_step_fail <step> <detail> <message> — record the step `fail`, exit 4.
bm_step_fail() { bm_step_record "$1" fail "$2"; bm_fail "cutover $1: $3"; }

bm_step_text() {
  case "$1" in
    B1) echo "B1 preflight (hub only): the newest state/box-move/<newbox>/tick-*.tsv is a no-write tick (# mode=nowrite) under ${BM_TICK_MAX_AGE_S}s old, its # reach line is ssh=0 flyctl=0, and no lane failed except by a refused write, a timeout or BOX_MOVE_B1_ALLOW=${BM_B1_ALLOW:-none}; target.json box_id equals the rows box id of the old box" ;;
    B2) echo "B2 stop the old box: save old-rows.tsv and old-crontab on the hub, local flags/lane-off-update-runners on the old box, crontab -r there, wait up to ${BM_DRAIN_TIMEOUT_S}s for no <old harness>/bin/ process (hub-move.sh drain)" ;;
    B3) echo "B3 copy: BACKUP_FORCE=1 state-backup.sh on the old box, seed the new box from that exact snapshot, local flags/all-off on the old box" ;;
    B4) echo "B4 rows (REGISTRY_SOURCE=db): registry.sh add-box <newbox> with the old box id, move-project of each saved project to <newbox>, read back with fleet-conf.sh" ;;
    B5) echo "B5 start the new box: split-brain check (both crontabs empty, both flags/all-off on), clear the new box local all-off, hub-move.sh tick --real there, remove state/hub-move/target-seeded, update-runners.sh" ;;
  esac
}
bm_prev_step() { case "$1" in B1) echo "" ;; *) echo "B$(( ${1#B} - 1 ))" ;; esac; }

# bm_b1_judge <tick.tsv> — rc 0 and the ok detail on stdout when the table
# lets the cut-over go on; rc 1 and the reason on stdout when it does not.
bm_b1_judge() {
  local f="$1" l1 why at fl lid allowed="" blocking=""
  l1=$(sed -n 1p "$f" 2>/dev/null)
  why=$(hmr_c1_reach "$f")
  [ -z "$why" ] || { echo "the newest tick could not reach the fleet: $why"; return 1; }
  [[ "$l1" =~ ^\#\ mode=nowrite\ at=([0-9]+)$ ]] || { echo "$(basename "$f") is not a no-write tick (line 1: $l1)"; return 1; }
  at="${BASH_REMATCH[1]}"
  [ "$at" -le "$(bm_now)" ] || { echo "$(basename "$f") is stamped in the future (at=$at, now=$(bm_now))"; return 1; }
  [ $(( $(bm_now) - at )) -lt "$BM_TICK_MAX_AGE_S" ] || { echo "$(basename "$f") is older than ${BM_TICK_MAX_AGE_S}s (BOX_MOVE_TICK_MAX_AGE_S)"; return 1; }
  while IFS= read -r fl; do
    [ -n "$fl" ] || continue
    lid=${fl%%"(rc="*}
    # An allow-list id covers its ~N duplicates (lib covers lib~2).
    case ",$BM_B1_ALLOW," in
      ,,) blocking="$blocking $fl" ;;
      *",$lid,"*|*",${lid%%~*},"*) allowed="$allowed $fl" ;;
      *) blocking="$blocking $fl" ;;
    esac
  done < <(grep -v '^#' "$f" | tail -n +2 | awk -F'\t' '$2 != 0 && $4 == 0 && $5 == 0 {print $1 "(rc=" $2 ")"}')
  allowed=${allowed# }; blocking=${blocking# }
  [ -z "$blocking" ] || { echo "lanes failed with no refused write: $blocking (BOX_MOVE_B1_ALLOW=${BM_B1_ALLOW:-none})"; return 1; }
  echo "$(basename "$f") allow=${BM_B1_ALLOW:-none} allowed_failed=$(printf '%s' "${allowed:-none}" | tr ' ' ',')"
}

# bm_registry_preflight <what> — exit 3 (nothing written) unless the rows are
# the D1 registry and both credentials are set. Names only, never a value.
bm_registry_preflight() {
  [ "${REGISTRY_SOURCE:-}" = db ] \
    || bm_refuse "$1 needs REGISTRY_SOURCE=db (it is '${REGISTRY_SOURCE:-unset}'): in file mode the rows are the committed fleet.conf, which box-move never edits; move the projects with bin/box-register.sh in a PR"
  local k
  for k in REGISTRY_ADMIN_TOKEN HARNESS_SECRET; do
    [ -n "${!k:-}" ] || bm_refuse "$1 needs $k set (set -a; . <env dir>/global.env; set +a)"
  done
}

# bm_rows_save <oldbox> <newbox> — write old-rows.tsv. A non-empty file is
# kept once B4 has started (its rows then put projects on the new box); before
# that, and after a rollback reset B4, the rows are read again, so a project
# that came to the old box between two cut-overs is in the file.
bm_rows_save() {
  local old="$1" new="$2" f="$BM_STATE/old-rows.tsv" role p
  case "$(bm_step_status B4)" in
    ""|reset) ;;
    *) [ -s "$f" ] && return 0 ;;
  esac
  bm_rows_resolve "$old" "$new"
  role=$("$BIN/fleet-conf.sh" --boxes-with-roles 2>/dev/null | awk -F'\t' -v b="$old" '$1 == b {print $3; exit}')
  mkdir -p "$BM_STATE" || return 1
  {
    printf 'box\t%s\t%s\t%s\t%s\n' "$old" "$BM_BOX_ID" "$BM_OLD_IP" "${role:--}"
    for p in $BM_PROJECTS; do printf 'project\t%s\n' "$p"; done
  } > "$f.tmp" && mv -f "$f.tmp" "$f"
}
# bm_rows_load — BM_BOX_ID, BM_OLD_IP, BM_OLD_ROLE, BM_PROJECTS from
# old-rows.tsv; rc 1 when it is missing or has no box line.
bm_rows_load() {
  local f="$BM_STATE/old-rows.tsv"
  [ -s "$f" ] || return 1
  BM_BOX_ID=$(awk -F'\t' '$1 == "box" {print $3; exit}' "$f")
  BM_OLD_IP=$(awk -F'\t' '$1 == "box" {print $4; exit}' "$f")
  BM_OLD_ROLE=$(awk -F'\t' '$1 == "box" {print $5; exit}' "$f")
  BM_PROJECTS=$(awk -F'\t' '$1 == "project" {print $2}' "$f" | tr '\n' ' ')
  BM_PROJECTS="${BM_PROJECTS% }"
  [ -n "$BM_BOX_ID" ] && [ -n "$BM_OLD_IP" ]
}
# bm_rows_readback <box with the projects> <box with none> — rc 0 when the
# rows put exactly the saved projects on the first box and none on the second.
bm_rows_readback() {
  local want got empty
  want=$(tr ' ' '\n' <<<"$BM_PROJECTS" | grep . | LC_ALL=C sort | paste -sd' ' -)
  got=$("$BIN/fleet-conf.sh" --projects-on-box "$1" 2>/dev/null | LC_ALL=C sort | paste -sd' ' -)
  empty=$("$BIN/fleet-conf.sh" --projects-on-box "$2" 2>/dev/null)
  BM_READBACK="$1=[${got}] $2=[$(paste -sd' ' - <<<"$empty")] want $1=[$want]"
  [ "$got" = "$want" ] && [ -z "$empty" ]
}
# bm_move_projects <to box> — move-project of each saved project that
# is not on <to box> yet (a re-run moves only what is left).
bm_move_projects() {
  local to="$1" p
  for p in $BM_PROJECTS; do
    [ "$("$BIN/box-for.sh" "$p" 2>/dev/null)" = "$to" ] && continue
    "$BIN/registry.sh" move-project "$p" --box "$to" --actor "box-move-$BM_NEW_NAME" >/dev/null \
      || { BM_MOVE_FAILED="$p"; return 1; }
  done
}

bm_target_ip() {
  local ip; ip=$(bm_tj_get ts_ip)
  grep -qE '^[0-9A-Fa-f.:]+$' <<<"$ip" || return 1
  printf '%s\n' "$ip"
}

# bm_b5_fail <ip> <detail> <message> — a B5 failure after the new box's
# all-off was cleared: put all-off back on and remove any crontab there, so
# the split-brain check lets a B5 re-run start; then record `fail`, exit 4.
bm_b5_fail() {
  bm_sh "$1" "$BM_S_FLAG_ON" "$BM_TH" all-off "box-move B5: $2" >/dev/null 2>&1
  bm_sh "$1" "$BM_S_CRON_REMOVE" >/dev/null 2>&1
  bm_step_fail B5 "$2" "$3"
}

# bm_run_step <B1..B5> <force_drain> <oldbox> <newbox>
bm_run_step() {
  local s="$1" force="$2" old="$3" new="$4" prev out rc f why ip tid ts0 ts1 n
  prev=$(bm_prev_step "$s")
  if [ -n "$prev" ] && [ "$(bm_step_status "$prev")" != ok ]; then
    bm_refuse "cutover $s: step $prev is not ok (steps.tsv in $BM_STATE)"
  fi
  [ "$s" = B4 ] && bm_registry_preflight "cutover B4"
  bm_say "cutover: $(bm_step_text "$s")"
  case "$s" in
    B1)
      bm_rows_resolve "$old" "$new"
      ip=$(bm_target_ip) || bm_step_fail B1 "no ts_ip" "$BM_TJ has no ts_ip address (run provision first)"
      tid=$(bm_tj_get box_id)
      [ "$tid" = "$BM_BOX_ID" ] || bm_step_fail B1 "box_id mismatch" "$BM_TJ box_id '$tid' is not the rows box id '$BM_BOX_ID' of $old"
      f=$(ls "$BM_STATE"/tick-*.tsv 2>/dev/null | LC_ALL=C sort | tail -1)
      [ -n "$f" ] || bm_step_fail B1 "no tick file" "no $BM_STATE/tick-*.tsv (run bin/box-move.sh tick first)"
      out=$(bm_b1_judge "$f") || bm_step_fail B1 "$out" "$out"
      bm_step_record B1 ok "$out" ;;
    B2)
      # (1) the hub record first: nothing on the old box changes unsaved.
      bm_rows_save "$old" "$new" || bm_step_fail B2 "old-rows" "cannot write $BM_STATE/old-rows.tsv"
      bm_rows_load || bm_step_fail B2 "old-rows" "$BM_STATE/old-rows.tsv has no box line"
      bm_sh "$BM_OLD_IP" 'crontab -l 2>/dev/null; true' > "$BM_STATE/old-crontab.tmp" 2>/dev/null; rc=$?
      [ "$rc" -eq 0 ] || { rm -f "$BM_STATE/old-crontab.tmp"; bm_step_fail B2 "old box unreachable rc=$rc" "cannot read the crontab of $old ($BM_OLD_IP) rc=$rc"; }
      # Never overwrite a saved crontab with the empty one of a re-run.
      if [ -s "$BM_STATE/old-crontab.tmp" ]; then
        mv -f "$BM_STATE/old-crontab.tmp" "$BM_STATE/old-crontab" || bm_step_fail B2 "old-crontab" "cannot save $BM_STATE/old-crontab"
      else
        rm -f "$BM_STATE/old-crontab.tmp"
      fi
      [ -s "$BM_STATE/old-crontab" ] || bm_step_fail B2 "old-crontab empty" "$old has no crontab and $BM_STATE/old-crontab is empty"
      bm_say "cutover: B2 saved old-crontab ($(grep -cvE "$BM_ACTIVE_RE" "$BM_STATE/old-crontab") active lines) and old-rows.tsv (projects: ${BM_PROJECTS:-none})"
      # (2) update-runners.sh would put the crontab back (fleet-propagate.sh).
      bm_sh "$BM_OLD_IP" "$BM_S_FLAG_ON" "$BM_OH" lane-off-update-runners "box-move B2: the old box stops" \
        || bm_step_fail B2 "lane-off-update-runners" "flags/lane-off-update-runners does not read on on $old"
      # (3)
      n=$(bm_sh "$BM_OLD_IP" "$BM_S_CRON_REMOVE" 2>/dev/null); rc=$?
      [ "$rc" -eq 0 ] && [ "$n" = 0 ] || bm_step_fail B2 "crontab not removed" "crontab -r on $old left ${n:-?} active lines (rc=$rc)"
      # (4)
      if [ "$force" -eq 0 ]; then
        bm_sh "$BM_OLD_IP" "$BM_S_DRAIN" "$BM_OH" "$BM_DRAIN_TIMEOUT_S"; rc=$?
        [ "$rc" -eq 0 ] || bm_step_fail B2 "drain rc=$rc" "$old did not drain in ${BM_DRAIN_TIMEOUT_S}s (rc=$rc; rerun with --force-drain to go on)"
      fi
      bm_step_record B2 ok "crontab saved and removed, drained$([ "$force" -eq 1 ] && echo ' (forced)')" ;;
    B3)
      bm_rows_load || bm_step_fail B3 "old-rows" "$BM_STATE/old-rows.tsv is missing"
      ts0=$(bm_sh "$BM_OLD_IP" "$BM_S_BACKUP_TS" "$BM_OH" 2>/dev/null) || bm_step_fail B3 "old box unreachable" "cannot read state/backup-last.json on $old"
      bm_sh "$BM_OLD_IP" "$BM_S_BACKUP" "$BM_OH" || bm_step_fail B3 "state-backup rc" "state-backup.sh failed on $old"
      ts1=$(bm_sh "$BM_OLD_IP" "$BM_S_BACKUP_TS" "$BM_OH" 2>/dev/null)
      [ -n "$ts1" ] && [ "$ts1" != "$ts0" ] || bm_step_fail B3 "no new backup" "state/backup-last.json on $old names no new snapshot (before ${ts0:-none}, after ${ts1:-none})"
      ( bm_seed "$ts1" "$old" "$new" ) || bm_step_fail B3 "seed $ts1" "seed $ts1 failed"
      # all-off goes AFTER the backup: state-backup.sh is lane-gated.
      bm_sh "$BM_OLD_IP" "$BM_S_FLAG_ON" "$BM_OH" all-off "box-move B3: the old box stands down" \
        || bm_step_fail B3 "all-off" "flags/all-off does not read on on $old"
      bm_step_record B3 ok "snapshot $ts1" ;;
    B4)
      bm_rows_load || bm_step_fail B4 "old-rows" "$BM_STATE/old-rows.tsv is missing"
      ip=$(bm_target_ip) || bm_step_fail B4 "no ts_ip" "$BM_TJ has no ts_ip address"
      local roleopt=() role="" have_role have_ip
      [ -n "$BM_OLD_ROLE" ] && [ "$BM_OLD_ROLE" != - ] && role="$BM_OLD_ROLE" && roleopt=(--role "$role")
      have_role=$("$BIN/fleet-conf.sh" --boxes-with-roles 2>/dev/null | awk -F'\t' -v b="$new" '$1 == b {print $3; exit}')
      have_ip=$("$BIN/fleet-conf.sh" --tailnet-ip-of-box "$new" 2>/dev/null)
      if [ -z "$have_role" ] && [ -z "$have_ip" ]; then
        "$BIN/registry.sh" add-box "$new" --ip "$ip" --like "$BM_BOX_ID" --id "$BM_BOX_ID" "${roleopt[@]}" --actor "box-move-$new" >/dev/null \
          || bm_step_fail B4 "add-box" "registry.sh add-box $new failed"
      else
        # The row exists (an earlier B4, then a rollback set it retired). The
        # add route answers 409 on any field that differs, so patch the role
        # and check the address instead.
        [ -z "$have_ip" ] || [ "$have_ip" = "$ip" ] \
          || bm_step_fail B4 "ip mismatch" "the rows already have $new at '$have_ip', but $BM_TJ says $ip; correct the box row (PATCH /api/registry/boxes/$new tailnet_ip) and run B4 again"
        # No saved role: the add sent none (null), and only a rollback's
        # retired needs a change; build is the readers' role of a box with projects.
        [ -n "$role" ] || { [ "$have_role" = retired ] && role=build; }
        if [ -n "$role" ] && [ "$have_role" != "$role" ]; then
          "$BIN/registry.sh" set-box-role "$new" "$role" --actor "box-move-$new" >/dev/null \
            || bm_step_fail B4 "set-box-role" "registry.sh set-box-role $new $role failed"
          have_role=$("$BIN/fleet-conf.sh" --boxes-with-roles 2>/dev/null | awk -F'\t' -v b="$new" '$1 == b {print $3; exit}')
          [ "$have_role" = "$role" ] || bm_step_fail B4 "read-back role" "the rows give $new the role '$have_role', want $role"
        fi
      fi
      bm_move_projects "$new" || bm_step_fail B4 "move-project $BM_MOVE_FAILED" "registry.sh move-project $BM_MOVE_FAILED --box $new failed (the projects already moved stay moved; run B4 again)"
      bm_rows_readback "$new" "$old" || bm_step_fail B4 "read-back" "the rows do not read back: $BM_READBACK"
      out=$("$BIN/fleet-conf.sh" --tailnet-ip-of-box "$new" 2>/dev/null)
      [ "$out" = "$ip" ] || bm_step_fail B4 "read-back ip" "the rows give $new the address '$out', want $ip"
      bm_step_record B4 ok "projects $(tr ' ' ',' <<<"$BM_PROJECTS") on $new" ;;
    B5)
      bm_rows_load || bm_step_fail B5 "old-rows" "$BM_STATE/old-rows.tsv is missing"
      ip=$(bm_target_ip) || bm_step_fail B5 "no ts_ip" "$BM_TJ has no ts_ip address"
      # (1) split-brain check: nothing starts unless both boxes stand by.
      out=$(bm_sh "$BM_OLD_IP" "$BM_S_STANDBY" "$BM_OH" 2>/dev/null) || bm_step_fail B5 "old box unreachable" "cannot read $old"
      [ "$out" = $'crontab_active=0\nall_off=on' ] || bm_step_fail B5 "split-brain old" "the old box $old does not stand by: $(tr '\n' ' ' <<<"$out")"
      out=$(bm_sh "$ip" "$BM_S_STANDBY" "$BM_TH" 2>/dev/null) || bm_step_fail B5 "new box unreachable" "cannot read $new"
      [ "$out" = $'crontab_active=0\nall_off=on' ] || bm_step_fail B5 "split-brain new" "the new box $new does not stand by: $(tr '\n' ' ' <<<"$out")"
      # (2)
      bm_sh "$ip" "$BM_S_FLAG_OFF" "$BM_TH" all-off "box-move B5: the new box starts" \
        || bm_step_fail B5 "new all-off" "flags/all-off still reads on on $new"
      # (3) the reach host: HUB_MOVE_REACH_HOST, else the old box address.
      local reach="$BM_REACH"
      [ -n "$reach" ] || reach=$(bm_tj_get old_ip)
      [ -n "$reach" ] || reach="$BM_OLD_IP"
      local tick
      tick=$(bm_sh "$ip" "$BM_S_TICK_REAL" "$BM_TH" "$reach" "$BM_CHECKOUT" 2>&1); rc=$?
      printf '%s\n' "$tick"
      [ "$rc" -eq 0 ] \
        || bm_b5_fail "$ip" "tick --real rc=$rc" "tick --real on $new rc=$rc: $(grep 'hub-move: \(failed\|refused\):' <<<"$tick" | tail -1)"
      # (4) the marker goes BEFORE update-runners installs the crontab: a re-run
      # must not have its tick remove that crontab.
      bm_sh "$ip" 'rm -f "$1/state/hub-move/target-seeded" && [ ! -e "$1/state/hub-move/target-seeded" ]' "$BM_TH" \
        || bm_b5_fail "$ip" "marker" "cannot remove state/hub-move/target-seeded on $new"
      # (5)
      bm_sh "$ip" 'HARNESS="$1" "$1/bin/update-runners.sh"' "$BM_TH" || bm_b5_fail "$ip" "update-runners" "update-runners.sh failed on $new"
      out=$(bm_sh "$ip" "$BM_S_STANDBY" "$BM_TH" 2>/dev/null)
      n=$(sed -n 's/^crontab_active=//p' <<<"$out")
      bm_is_posint "${n:-0}" && grep -qx 'all_off=off' <<<"$out" \
        || bm_b5_fail "$ip" "read-back" "the new box $new reads $(tr '\n' ' ' <<<"$out")(want crontab_active above 0, all_off=off)"
      bm_step_record B5 ok "$(grep '^tick: lanes=' <<<"$tick" | tail -1) crontab_active=$n"
      echo "cutover: B5 done. The old box $old is a cold standby (crontab empty, flags/all-off, lane-off-update-runners). Rollback: bin/box-move.sh rollback --confirm $old $new." ;;
  esac
}

# bm_cutover <step> <confirm> <force_drain> <oldbox> <newbox>
bm_cutover() {
  BM_NEW_NAME="$5"
  if [ "$2" -eq 0 ]; then
    echo "WOULD RUN $(bm_step_text "$1")"
    echo "nothing changed: add --confirm to run"
    return 0
  fi
  bm_run_step "$1" "$3" "$4" "$5"
}

# bm_rollback <confirm> <force_drain> <oldbox> <newbox>
bm_rollback() {
  local confirm="$1" force="$2" old="$3" new="$4" rows=0 ip n rc want st
  BM_NEW_NAME="$new"
  # 1. preflight: nothing changes unless B2 saved what rollback puts back.
  [ -s "$BM_STATE/old-crontab" ] || bm_refuse "rollback: no $BM_STATE/old-crontab (B2 never ran)"
  want=$(grep -cvE "$BM_ACTIVE_RE" "$BM_STATE/old-crontab")
  [ "${want:-0}" -gt 0 ] || bm_refuse "rollback: $BM_STATE/old-crontab has 0 active lines; it will not install an empty crontab on $old"
  bm_rows_load || bm_refuse "rollback: no usable $BM_STATE/old-rows.tsv (B2 never ran)"
  awk -F'\t' '$2 == "B4" {f = 1} END {exit !f}' "$BM_STATE/steps.tsv" 2>/dev/null && rows=1
  [ "$rows" -eq 0 ] || bm_registry_preflight "rollback (B4 moved the rows)"
  if [ "$confirm" -eq 0 ]; then
    echo "WOULD RUN rollback: on $new local flags/all-off, crontab -r, drain (${BM_DRAIN_TIMEOUT_S}s); $([ "$rows" -eq 1 ] && echo "move-project ${BM_PROJECTS// /,} back to $old, set-box-role $new retired; " || echo "rows unchanged (B4 never ran); ")on $old clear flags/all-off and lane-off-update-runners, crontab $BM_STATE/old-crontab ($want active lines)"
    echo "nothing changed: add --confirm to run"
    return 0
  fi
  # 2. stop the new box: all-off FIRST, so no lane and no update-runners starts.
  if ip=$(bm_target_ip); then
    if ! bm_sh "$ip" 'true' 2>/dev/null; then
      [ "$force" -eq 1 ] || bm_fail "rollback: the new box $new ($ip) is unreachable; nothing changed. If it is dead (so already stopped), rerun with --force-drain"
      bm_say "rollback: the new box $new ($ip) is unreachable; --force-drain: taken as stopped"
    else
      bm_sh "$ip" "$BM_S_FLAG_ON" "$BM_TH" all-off "box-move rollback: the new box stands down" \
        || bm_fail "rollback: flags/all-off does not read on on $new"
      n=$(bm_sh "$ip" "$BM_S_CRON_REMOVE" 2>/dev/null); rc=$?
      [ "$rc" -eq 0 ] && [ "$n" = 0 ] || bm_fail "rollback: crontab -r on $new left ${n:-?} active lines (rc=$rc)"
      if [ "$force" -eq 0 ]; then
        bm_sh "$ip" "$BM_S_DRAIN" "$BM_TH" "$BM_DRAIN_TIMEOUT_S"; rc=$?
        [ "$rc" -eq 0 ] || bm_fail "rollback: $new did not drain in ${BM_DRAIN_TIMEOUT_S}s (rc=$rc; rerun with --force-drain to go on)"
      fi
    fi
  fi
  # 3. rows back (only when B4 ran in any form).
  if [ "$rows" -eq 1 ]; then
    bm_move_projects "$old" || bm_fail "rollback: registry.sh move-project $BM_MOVE_FAILED --box $old failed; the old crontab is NOT installed (run rollback again)"
    if "$BIN/fleet-conf.sh" --boxes-with-roles 2>/dev/null | awk -F'\t' -v b="$new" '$1 == b {f = 1} END {exit !f}'; then
      "$BIN/registry.sh" set-box-role "$new" retired --actor "box-move-$new" >/dev/null \
        || bm_fail "rollback: registry.sh set-box-role $new retired failed; the old crontab is NOT installed (run rollback again)"
    fi
    bm_rows_readback "$old" "$new" || bm_fail "rollback: the rows do not read back: $BM_READBACK"
  fi
  # 4. the old box starts again.
  bm_sh "$BM_OLD_IP" "$BM_S_FLAG_OFF" "$BM_OH" all-off "box-move rollback: the old box resumes" \
    && bm_sh "$BM_OLD_IP" "$BM_S_FLAG_OFF" "$BM_OH" lane-off-update-runners "box-move rollback: the old box resumes" \
    || bm_fail "rollback: flags/all-off or lane-off-update-runners still reads on on $old"
  n=$(bm_sh "$BM_OLD_IP" "$BM_S_CRON_INSTALL" < "$BM_STATE/old-crontab" 2>/dev/null); rc=$?
  [ "$rc" -eq 0 ] && [ "$n" = "$want" ] || bm_fail "rollback: the crontab on $old reads ${n:-?} active lines after install, want $want (rc=$rc)"
  # 5. a later cutover starts at B1, so the B5 split-brain check runs again.
  for st in B1 B2 B3 B4 B5; do bm_step_record "$st" reset "rollback"; done
  bm_step_record rollback ok "old crontab $want lines$([ "$rows" -eq 1 ] && echo ", rows back on $old")"
  echo "Rollback done. $old runs its crontab ($want active lines)$([ "$rows" -eq 1 ] && echo " and the rows put ${BM_PROJECTS// /,} on it")."
  echo "The new box $new keeps its state and stands by with flags/all-off; state written on $new after B3 is not copied back."
}
