#!/bin/bash
# bin/lib/millwright-read.sh — the reads behind Millwright's metric
# failed_bakes_and_broken_boxes (BH-10124, C3 of #9423). Sourced by
# bin/staff/millwright-collect.sh (the staff tick's collector) and
# bin/staff/millwright-lever.sh (the hourly sample and the bake re-run). It
# holds no state and writes nothing outside the workdir it is given. Safe under
# set -u. The root is the argument; this lib has no /root/harness default.
#
#   mw_bakes <harness-dir>
#       One TSV line per failed bake, sorted by project:
#         <project> <sha40> <at epoch> <reason> <queued 0|1>
#       A pool is a failed bake when state/fleet-propagate.json .pool_fail.<p>
#       exists (bin/fleet-propagate.sh writes it on a failed bake and removes
#       it on an ok one), flags/fly-pool-app-<p> is a non-empty file (the pool
#       still exists), and state/fly/<p>.image is missing or not newer than
#       `at` (no ok bake by any path since: every ok bake writes .image).
#       queued = state/fly/<p>.image-dirty exists (a retry already waits).
#       rc 0 = read (no record or no .pool_fail key is 0 lines); rc 3 = the
#       record exists and is not a JSON object (unreadable, never 0). A project
#       outside [A-Za-z0-9._-] or a sha that is not 40 hex is skipped with
#       one warn line.
#   mw_probe_cmd [resolv-path] [tmp-path]
#       Prints the read-only probe script every box runs. It prints one line
#       `mw resolv=<ok|broken> tmp=<use%|->`. resolv=ok needs the file to
#       exist through its link (a dangling link fails) and to hold a line
#       `nameserver <address>` (a commented line does not count, as
#       bin/dns-guard.sh reads it). tmp is the block use% of `df -P`, or `-`
#       when df fails. It writes nothing on the box.
#   mw_boxes <harness-dir> <workdir>
#       Probes every registry box with a tailnet IP (not box_id hub, not
#       retired; at most MW_BOXES_MAX) over ssh in parallel, each under
#       `timeout MW_SSH_TIMEOUT_S`, probes the hub locally as box `hub`, and
#       reads GET /api/boxes once, in parallel with the probes. One TSV line
#       per fault, sorted:  <box> <kind> <detail>
#         resolv-broken  the probe said resolv=broken
#         tmp-full       /tmp use% >= MW_TMP_FULL_PCT
#         stale-bin      a box_status row whose lag_checked_at is newer than
#                        MW_LAG_FRESH_MIN minutes and whose harness_lag_min is
#                        above harness_version.max_lag_min (fallback 30)
#       A box whose probe times out, exits non-zero or prints no `mw ` line is
#       unreachable: unknown, never a fault. Writes <workdir>/counts:
#         unreachable=<n> probed=<n> boxes_read=<ok|failed> registry=<ok|failed>
#       rc 0 = both halves read; rc 3 = the registry or GET /api/boxes is
#       unreadable (the faults it could read are still printed).
#   mw_metric <harness-dir> <workdir>
#       Runs both reads and prints one JSON object
#         {value, bakes, boxes, resolv, tmp, stale, unreachable}
#       boxes = distinct boxes with a fault; value = bakes + boxes. It keeps
#       <workdir>/bakes.tsv and <workdir>/boxes.tsv for the caller. rc 3 and
#       nothing printed when either half is unreadable.
#
# Knobs (catalog/lanes.d/_lib.staff-millwright.json; the caller applies them
# with lib_env_apply staff-millwright). Out of range is one warn line in
# logs/staff.log and the default, never a clamp.
# Test seams, HARNESS_TEST_SANDBOX=1 only: MW_SSH (the ssh command), MW_NOW
# (epoch), MW_RESOLV and MW_TMPDIR (the paths the LOCAL hub probe reads; never
# sent to a box). MW_FIXTURE is read by the two callers.
# Note: docs/notes/2026-11-25-BH-10124-millwright.md.

# registry_json_path (the cached registry the box-ssh probe reads too).
# shellcheck source=bin/lib/registry.sh
. "${BASH_SOURCE[0]%/*}/registry.sh" 2>/dev/null || true

_mw_warn() {
  local h="${HARNESS:-${H:-}}"
  [ -n "$h" ] || return 0
  mkdir -p "$h/logs" 2>/dev/null
  printf '%s agent=millwright warn: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >> "$h/logs/staff.log" 2>/dev/null
  return 0
}

# _mw_knob <name> <default> <min> <max> — the env value in range, else one warn
# line and the default.
_mw_knob() {
  local v="${!1:-}"
  [ -n "$v" ] || { printf '%s' "$2"; return 0; }
  if [[ $v =~ ^[0-9]+$ ]] && [ "$((10#$v))" -ge "$3" ] && [ "$((10#$v))" -le "$4" ]; then
    printf '%s' "$((10#$v))"
  else
    _mw_warn "$1=$v is outside $3..$4; using the default $2"
    printf '%s' "$2"
  fi
}

_mw_now() {
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [[ ${MW_NOW:-} =~ ^[0-9]+$ ]]; then printf '%s' "$MW_NOW"
  else date -u +%s; fi
}

mw_bakes() {
  local h="${1:-}" rec p sha at reason img mt q
  [ -n "$h" ] || return 3
  rec="$h/state/fleet-propagate.json"
  [ -e "$rec" ] || return 0
  jq -e 'type == "object"' "$rec" >/dev/null 2>&1 || return 3
  while IFS=$'\t' read -r p sha at reason; do
    if ! [[ $p =~ ^[A-Za-z0-9._-]+$ ]] || [ "$p" = . ] || [ "$p" = .. ]; then
      _mw_warn "fleet-propagate .pool_fail holds a bad project name '${p:0:40}'; skipped"; continue
    fi
    if ! [[ $sha =~ ^[0-9a-f]{40}$ ]] || ! [[ $at =~ ^[0-9]+$ ]]; then
      _mw_warn "fleet-propagate .pool_fail.$p has no 40-hex sha or epoch; skipped"; continue
    fi
    [ -s "$h/flags/fly-pool-app-$p" ] || continue
    img="$h/state/fly/$p.image"
    if [ -e "$img" ]; then
      mt=$(stat -c %Y "$img" 2>/dev/null) || mt=0
      [ "$mt" -gt "$at" ] && continue
    fi
    q=0; [ -e "$h/state/fly/$p.image-dirty" ] && q=1
    reason=$(printf '%s' "$reason" | tr -c 'A-Za-z0-9._:=-' '_' | cut -c1-60)
    printf '%s\t%s\t%s\t%s\t%s\n' "$p" "$sha" "$at" "${reason:--}" "$q"
  done < <(jq -r '(.pool_fail // {}) | if type == "object" then to_entries | sort_by(.key)[]
             | [.key, (.value.sha // "" | tostring), (.value.at // "" | tostring), (.value.reason // "" | tostring)]
             | @tsv else empty end' "$rec" 2>/dev/null)
  return 0
}

mw_probe_cmd() {
  local r="${1:-/etc/resolv.conf}" t="${2:-/tmp}"
  # Read-only on purpose: no redirection, no write, no delete (soul NEVER).
  cat <<EOF
r=$(printf '%q' "$r"); t=$(printf '%q' "$t")
if [ -e "\$r" ] && grep -Eqs '^[[:space:]]*nameserver[[:space:]]+[^[:space:]#]' "\$r"; then rs=ok; else rs=broken; fi
u=\$(df -P "\$t" | awk 'NR==2 { sub(/%/, "", \$5); print \$5 }')
case "\$u" in ''|*[!0-9]*) u=- ;; esac
echo "mw resolv=\$rs tmp=\$u"
EOF
}

mw_boxes() {
  local h="${1:-}" w="${2:-}" to full fresh maxb reg roster n=0 box ip line rs tu rc
  local unreach=0 probed=0 bread=ok rread=ok thr now cmd lcmd pids=() ssh_cmd=()
  [ -n "$h" ] && [ -n "$w" ] && mkdir -p "$w" 2>/dev/null || return 3
  # fallback 15; row lib.staff-millwright.mw_ssh_timeout_s
  to=$(_mw_knob MW_SSH_TIMEOUT_S 15 1 120)
  # fallback 90; row lib.staff-millwright.mw_tmp_full_pct
  full=$(_mw_knob MW_TMP_FULL_PCT 90 50 100)
  # fallback 60; row lib.staff-millwright.mw_lag_fresh_min
  fresh=$(_mw_knob MW_LAG_FRESH_MIN 60 10 1440)
  # fallback 200; row lib.staff-millwright.mw_boxes_max
  maxb=$(_mw_knob MW_BOXES_MAX 200 1 500)
  local ssh_s="ssh -n -o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new"
  [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && [ -n "${MW_SSH:-}" ] && ssh_s=$MW_SSH
  read -ra ssh_cmd <<< "$ssh_s"
  now=$(_mw_now)
  rm -f "$w"/box.* "$w"/boxes.json "$w"/boxes.rc 2>/dev/null

  # GET /api/boxes, in parallel with the probes (one request).
  if command -v _jobs_req >/dev/null 2>&1; then
    ( JOBS_ALERT=0 _jobs_req GET /api/boxes > "$w/boxes.json" 2>/dev/null; echo $? > "$w/boxes.rc" ) &
    pids+=($!)
  else
    echo 1 > "$w/boxes.rc"
  fi

  cmd=$(mw_probe_cmd)
  roster=""
  reg=$(registry_json_path 2>/dev/null) || reg=""
  if [ -n "$reg" ] && [ -s "$reg" ] && roster=$(jq -r '.boxes[]? | select((.tailnet_ip // "") != "" and .box_id != "hub" and (.role // "") != "retired")
        | [.box, .tailnet_ip] | @tsv' "$reg" 2>/dev/null); then
    while IFS=$'\t' read -r box ip; do
      [[ $box =~ ^[A-Za-z0-9._-]+$ ]] || continue
      [[ $ip =~ ^[0-9A-Fa-f.:]+$ ]] || continue
      [ "$box" = hub ] && continue
      [ "$n" -lt "$maxb" ] || { _mw_warn "more than MW_BOXES_MAX=$maxb boxes; the rest are not probed"; break; }
      n=$((n+1))
      printf '%s\n' "$box" > "$w/box.$n.name"
      ( timeout "$to" "${ssh_cmd[@]}" "root@$ip" "$cmd" </dev/null > "$w/box.$n.out" 2>/dev/null; echo $? > "$w/box.$n.rc" ) &
      pids+=($!)
    done <<< "$roster"
  else
    rread=failed
  fi
  # The hub itself, locally, under the same timeout.
  lcmd=$cmd
  if [ "${HARNESS_TEST_SANDBOX:-}" = 1 ] && { [ -n "${MW_RESOLV:-}" ] || [ -n "${MW_TMPDIR:-}" ]; }; then
    lcmd=$(mw_probe_cmd "${MW_RESOLV:-/etc/resolv.conf}" "${MW_TMPDIR:-/tmp}")
  fi
  n=$((n+1))
  printf 'hub\n' > "$w/box.$n.name"
  ( timeout "$to" bash -c "$lcmd" </dev/null > "$w/box.$n.out" 2>/dev/null; echo $? > "$w/box.$n.rc" ) &
  pids+=($!)
  wait "${pids[@]}" 2>/dev/null

  : > "$w/faults"
  local i
  for ((i = 1; i <= n; i++)); do
    probed=$((probed+1))
    box=$(cat "$w/box.$i.name" 2>/dev/null)
    rc=$(cat "$w/box.$i.rc" 2>/dev/null)
    line=$(grep -m1 '^mw ' "$w/box.$i.out" 2>/dev/null) || line=""
    if [ "$rc" != 0 ] || [ -z "$line" ]; then unreach=$((unreach+1)); continue; fi
    rs=$(sed -n 's/.* resolv=\([a-z]*\).*/\1/p' <<<"$line")
    tu=$(sed -n 's/.* tmp=\([0-9-]*\).*/\1/p' <<<"$line")
    [ "$rs" = broken ] && printf '%s\tresolv-broken\t/etc/resolv.conf has no usable nameserver\n' "$box" >> "$w/faults"
    if [[ $tu =~ ^[0-9]+$ ]] && [ "$((10#$tu))" -ge "$full" ]; then
      printf '%s\ttmp-full\t%s%%\n' "$box" "$((10#$tu))" >> "$w/faults"
    fi
  done

  # Stale bin, from the lag bin/fleet-version-check.sh stores.
  if [ "$(cat "$w/boxes.rc" 2>/dev/null)" = 0 ] && jq -e '.boxes | type == "array"' "$w/boxes.json" >/dev/null 2>&1; then
    # The threshold is fleet-version-check's own row; fallback 30.
    thr=""
    command -v setting_get >/dev/null 2>&1 && thr=$(JOBS_ALERT=0 setting_get harness_version.max_lag_min 2>/dev/null)
    thr="${thr//[[:space:]]/}"
    [[ $thr =~ ^[0-9]+$ ]] || thr=30
    jq -r --argjson now "$now" --argjson fresh "$fresh" --argjson thr "$((10#$thr))" '
      .boxes[] | select(type == "object")
      | select((.box | type) == "string" and (.box | test("^[A-Za-z0-9._-]+$")))
      | select((.harness_lag_min | type) == "number" and .harness_lag_min > $thr)
      | select((.lag_checked_at | type) == "string")
      | ((.lag_checked_at | sub("\\.[0-9]+Z$"; "Z") | try fromdateiso8601 catch null)) as $c
      | select($c != null and ($now - $c) < ($fresh * 60))
      | [.box, "stale-bin", "lag=\(.harness_lag_min) max=\($thr) sha=\((.harness_commit // "-") | tostring | .[0:12])"] | @tsv' \
      "$w/boxes.json" >> "$w/faults" 2>/dev/null
  else
    bread=failed
  fi
  printf 'unreachable=%s probed=%s boxes_read=%s registry=%s\n' "$unreach" "$probed" "$bread" "$rread" > "$w/counts"
  LC_ALL=C sort -u "$w/faults"
  [ "$bread" = ok ] && [ "$rread" = ok ] || return 3
  return 0
}

mw_metric() {
  local h="${1:-}" w="${2:-}" brc=0 xrc=0 bakes boxes resolv tmp stale unreach
  [ -n "$h" ] && [ -n "$w" ] && mkdir -p "$w" 2>/dev/null || return 3
  mw_bakes "$h" > "$w/bakes.tsv" || brc=$?
  mw_boxes "$h" "$w" > "$w/boxes.tsv" || xrc=$?
  [ "$brc" = 0 ] && [ "$xrc" = 0 ] || return 3
  bakes=$(grep -c . "$w/bakes.tsv")
  boxes=$(cut -f1 "$w/boxes.tsv" | LC_ALL=C sort -u | grep -c .)
  resolv=$(awk -F'\t' '$2 == "resolv-broken"' "$w/boxes.tsv" | grep -c .)
  tmp=$(awk -F'\t' '$2 == "tmp-full"' "$w/boxes.tsv" | grep -c .)
  stale=$(awk -F'\t' '$2 == "stale-bin"' "$w/boxes.tsv" | grep -c .)
  unreach=$(sed -n 's/^unreachable=\([0-9]*\).*/\1/p' "$w/counts")
  jq -cn --argjson b "$bakes" --argjson x "$boxes" --argjson r "$resolv" --argjson t "$tmp" \
    --argjson s "$stale" --argjson u "${unreach:-0}" \
    '{value: ($b + $x), bakes: $b, boxes: $x, resolv: $r, tmp: $t, stale: $s, unreachable: $u}'
}
