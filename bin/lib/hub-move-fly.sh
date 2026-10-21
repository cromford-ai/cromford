#!/bin/bash
# bin/lib/hub-move-fly.sh — the Fly seam of bin/hub-move.sh (BH-7715). It is the
# ONLY hub-move file that runs flyctl. Sourced.
#
# The flyctl binary is $HMF_FLYCTL, else `flyctl`, else `fly` on PATH. The
# token comes from the caller's environment (FLY_API_TOKEN, exported by
# bin/hub-move.sh from env/fly.env, as bin/fly-provision.sh does).
#
# Find functions print the id (or nothing for an app) and answer:
#   0 present, 1 absent, 2 could not read (flyctl failed or the JSON did not
#   parse), 75 Fly answered "rate limited".
# An unreadable find is never "absent": the caller stops and creates nothing.
#   hmf_app_exists <app>
#   hmf_volume_find <app> <volume-name>
#   hmf_machine_find <app>
# Create functions answer 0 done, 2 failed, 75 rate limited:
#   hmf_app_create <app> <org>
#   hmf_volume_create <app> <volume-name> <size_gb> <region>
#   hmf_machine_run <app> <image> <vm_size> <mem_mb> <volume_id> <region> <ts_hostname>
#   hmf_secret_set_stage <app> <key>      (the value is read from stdin, so it
#                                          never appears in argv or a log)

_hmf_bin() {
  if [ -n "${HMF_FLYCTL:-}" ]; then printf '%s\n' "$HMF_FLYCTL"; return 0; fi
  command -v flyctl 2>/dev/null || command -v fly 2>/dev/null || return 1
}

# _hmf_call <args...> — run flyctl, stdout to stdout; rc 75 on a rate limit.
_hmf_call() {
  local bin err rc
  bin=$(_hmf_bin) || { echo "hub-move-fly: flyctl not installed" >&2; return 2; }
  err=$(mktemp) || return 2
  "$bin" "$@" 2>"$err"; rc=$?
  if [ "$rc" -ne 0 ]; then
    if grep -qiE 'rate.?limit|429|too many requests' "$err"; then rc=75; else rc=2; fi
    sed 's/^/hub-move-fly: /' "$err" >&2
  fi
  rm -f "$err"
  return "$rc"
}

hmf_app_exists() {
  local out rc
  out=$(_hmf_call apps list --json); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1 || return 2
  printf '%s' "$out" | jq -e --arg a "$1" 'any(.[]; (.Name // .name) == $a)' >/dev/null 2>&1 && return 0
  return 1
}

hmf_volume_find() {
  local out rc id
  out=$(_hmf_call volumes list -a "$1" --json); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1 || return 2
  id=$(printf '%s' "$out" | jq -r --arg n "$2" '[.[] | select(.name == $n)][0].id // empty')
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

hmf_machine_find() {
  local out rc id
  out=$(_hmf_call machine list -a "$1" --json); rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$out" | jq -e 'type=="array"' >/dev/null 2>&1 || return 2
  id=$(printf '%s' "$out" | jq -r '.[0].id // empty')
  [ -n "$id" ] || return 1
  printf '%s\n' "$id"
}

hmf_app_create() {
  _hmf_call apps create "$1" --org "$2" >/dev/null
}

hmf_volume_create() {
  _hmf_call volumes create "$2" -a "$1" --size "$3" -r "$4" -y >/dev/null
}

hmf_machine_run() {
  _hmf_call machine run "$2" -a "$1" -r "$6" --name hub \
    --vm-size "$3" --vm-memory "$4" -v "$5:/data" \
    --restart always --autostop=off \
    --env "HUB_TS_HOSTNAME=$7" >/dev/null
}

hmf_secret_set_stage() {
  local v
  IFS= read -r v || [ -n "$v" ] || return 2
  printf '%s=%s\n' "$2" "$v" | _hmf_call secrets import -a "$1" --stage >/dev/null
}
