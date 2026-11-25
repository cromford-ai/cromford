# shellcheck shell=bash
# owner: BH-7939.1
# bin/lib/vendor/fly-machines.sh — the Fly Machines seam (BH-7975). Sourced
# only: it defines functions and runs nothing.
#
#   fm_create <app> <name> <image> <region>   print the id of machine <name>
#   fm_state <app> <id>                       print the machine state word
#   fm_private_ip <app> <id>                  print the machine's fdaa: address
#   fly_machines_run_help <timeout_s>         the `fly machine run` help (BH-8640)
#
# The fm_* calls take flyctl from fly_bin (bin/lib/fly-bin.sh). The token comes from
# fly_token_resolve (bin/lib/fly-token.sh) for FM_PROJECT, else the app name
# without `box-`. It rides as a FLY_ACCESS_TOKEN= prefix on each flyctl call
# only: it is never exported, never in argv, and cut to <token> in error text.
# Every input is checked before any call. In fake mode the answers come from
# tests/fixtures/vendor-fake/fly-machines.json (bin/lib/vendor/seam.sh) and no call is
# made.
#
# fm_create reads `machine list` first and answers the id of a machine that
# already has <name>, with no `machine run`: a retry never pays for a second
# machine. When FM_TS_KEY_VAR names a set variable, its value is staged as the
# app secret TS_AUTHKEY (`secrets import --stage`, on stdin) before the run.
#
# Env: FLY_ORG (apps create), FM_CALL_TIMEOUT_S (seconds per flyctl call; the
# station passes the settings row onboard.box_call_timeout_s; fallback 120).
# rc 0 the answer; 1 flyctl failed or a bad answer; 2 a bad input or vendor
# mode; 3 no token; 70 an unseeded fake key; 127 no flyctl.
# shellcheck source=seam.sh
. "${BASH_SOURCE[0]%/*}/seam.sh" || return 1
# shellcheck source=../fly-bin.sh
. "${BASH_SOURCE[0]%/*}/../fly-bin.sh" || return 1
# shellcheck source=../fly-token.sh
. "${BASH_SOURCE[0]%/*}/../fly-token.sh" || return 1

# fly_machines_run_help <timeout_s> — print the help text of `fly machine run`
# (BH-8640: the pool's --rootfs-size flag probe). The flyctl binary is
# ${FLY:-fly}; the call is cut after <timeout_s> seconds (the caller's knob).
# In fake mode the answer is the seeded string `fly-machines.run_help` and no
# CLI runs. rc 2 bad vendor mode, rc 70 an unseeded fake, else the CLI's rc.
fly_machines_run_help() {
  local to="${1:-20}" mode out
  mode=$(vendor_mode) || return 2
  if [ "$mode" = fake ]; then
    out=$(vendor_fake fly-machines run_help) || return 70
    jq -r . <<<"$out"
    return 0
  fi
  vendor_call_log fly-machines run-help
  timeout "$to" "${FLY:-fly}" machine run --help 2>/dev/null
}

_FM_NAME_RE='^[a-z0-9][a-z0-9-]{0,62}$'
_FM_ID_RE='^[0-9a-f]{14}$'

# _fm_need <what> <value> <regex> — rc 2 with one line when value fails regex.
_fm_need() {
  [[ "$2" =~ $3 ]] && return 0
  echo "fly: bad $1 '$2'" >&2
  return 2
}

# _fm_prep <app> — real mode only: sets _fm_bin, _fm_tok and _fm_t in the
# caller's locals. rc 3 no token, 127 no flyctl.
_fm_prep() {
  local app="$1"
  _fm_t="${FM_CALL_TIMEOUT_S:-120}"   # knob: settings row onboard.box_call_timeout_s
  [[ "$_fm_t" =~ ^[0-9]+$ ]] && [ "$_fm_t" -ge 1 ] && [ "$_fm_t" -le 1800 ] || _fm_t=120
  if ! fly_token_resolve "${FM_PROJECT:-${app#box-}}"; then
    echo "fly: no Fly token (FLY_API_TOKEN)" >&2
    return 3
  fi
  _fm_tok="$FLY_TOKEN_VAL"
  unset FLY_TOKEN_VAL
  _fm_bin=$(fly_bin) || { echo "fly: flyctl not found" >&2; return 127; }
}

# _fm_fly <verb> <flyctl args...> — one flyctl call. stdout passes through;
# stderr is held, the token cut, and printed only on failure.
_fm_fly() {
  local verb="$1" err rc
  shift
  vendor_call_log fly-machines "$verb"
  { err=$(FLY_ACCESS_TOKEN="$_fm_tok" timeout "$_fm_t" "$_fm_bin" "$@" 2>&1 1>&3 3>&-); } 3>&1
  rc=$?
  [ "$rc" = 0 ] && return 0
  err="${err//"$_fm_tok"/<token>}"
  echo "fly: $verb rc $rc: ${err:0:300}" >&2
  return 1
}

# _fm_list_field <app> <select-key> <select-value> <field> — one machine list
# read; prints the field of the first machine whose key equals the value.
_fm_list_field() {
  local list
  list=$(_fm_fly machine-list machine list -a "$1" --json </dev/null) || return 1
  jq -r --arg k "$2" --arg v "$3" --arg f "$4" \
    'if type == "array" then ([.[] | select(.[$k] == $v) | .[$f] // empty][0] // empty) else error("not a list") end' \
    <<<"$list" 2>/dev/null || { echo "fly: machine list is not a JSON list" >&2; return 1; }
}

fm_create() {
  local app="${1:-}" name="${2:-}" image="${3:-}" region="${4:-}" mode id kv=""
  local _fm_bin _fm_tok _fm_t
  _fm_need app "$app" "$_FM_NAME_RE" || return 2
  _fm_need name "$name" "$_FM_NAME_RE" || return 2
  _fm_need image "$image" '^[a-z0-9.-]+(/[a-z0-9._-]+)+(:[A-Za-z0-9._-]{1,128}|@sha256:[0-9a-f]{64})$' || return 2
  _fm_need region "$region" '^[a-z]{3}$' || return 2
  if [ -n "${FM_TS_KEY_VAR:-}" ]; then
    _fm_need "key variable" "$FM_TS_KEY_VAR" '^[A-Z_][A-Z0-9_]*$' || return 2
    kv="${!FM_TS_KEY_VAR:-}"
  fi
  mode=$(vendor_mode) || return 2
  if [ "$mode" = fake ]; then
    id=$(vendor_fake fly-machines create "$app") || return $?
    id=$(jq -r '.id // empty' <<<"$id" 2>/dev/null)
  else
    _fm_need org "${FLY_ORG:-}" '^[a-z0-9-]{1,63}$' || return 2
    _fm_prep "$app" || return $?
    if ! _fm_fly status status -a "$app" </dev/null >/dev/null 2>&1; then
      _fm_fly apps-create apps create "$app" --org "$FLY_ORG" </dev/null >/dev/null || return 1
    fi
    # The dedup before the spend: a machine with this name is the answer.
    id=$(_fm_list_field "$app" name "$name" id) || return 1
    if [ -z "$id" ]; then
      if [ -n "$kv" ]; then
        printf 'TS_AUTHKEY=%s\n' "$kv" | _fm_fly secrets-import secrets import -a "$app" --stage >/dev/null || return 1
      fi
      _fm_fly machine-run machine run "$image" -a "$app" --name "$name" --region "$region" --detach </dev/null >/dev/null || return 1
      id=$(_fm_list_field "$app" name "$name" id) || return 1
    fi
  fi
  [[ "$id" =~ $_FM_ID_RE ]] || { echo "fly: no machine id for $name in $app" >&2; return 1; }
  printf '%s\n' "$id"
}

# _fm_read <method> <field> <check-regex> <app> <id> — fm_state and fm_private_ip.
_fm_read() {
  local method="$1" field="$2" re="$3" app="${4:-}" id="${5:-}" mode v
  local _fm_bin _fm_tok _fm_t
  _fm_need app "$app" "$_FM_NAME_RE" || return 2
  _fm_need "machine id" "$id" "$_FM_ID_RE" || return 2
  mode=$(vendor_mode) || return 2
  if [ "$mode" = fake ]; then
    v=$(vendor_fake fly-machines "$method" "$id") || return $?
    v=$(jq -r 'if type == "string" then . else empty end' <<<"$v" 2>/dev/null)
  else
    _fm_prep "$app" || return $?
    v=$(_fm_list_field "$app" id "$id" "$field") || return 1
  fi
  [[ "$v" =~ $re ]] || { echo "fly: bad $field '${v:0:80}' for $id" >&2; return 1; }
  printf '%s\n' "$v"
}

fm_state() { _fm_read state state '^[a-z_]{1,20}$' "$@"; }
fm_private_ip() { _fm_read private_ip private_ip '^fdaa:[0-9a-f:]{2,36}$' "$@"; }
