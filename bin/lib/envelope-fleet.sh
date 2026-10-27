#!/bin/bash
# bin/lib/envelope-fleet.sh — write a fleet secret from an envelope into the
# hub's env files (BH-7976, BH-7939.2). Sourced, never run. It prints nothing at
# source time and never prints a secret value.
#
# Called by bin/envelope-consume.sh for `fleet:` scopes (BH-8541), which
# bin/secrets-apply.sh runs once per pending envelope. See
# docs/notes/2026-10-25-BH-7976-fleet-accounts.md.
#
# THE SCOPE GRAMMAR (worker/jobs/src/routes/secret-envelopes.js FLEET_SCOPE_RE
# is the same; tests/fixtures/fleet-scopes.bh-7939.tsv is the one table):
#   fleet:fly:<org>            org = [a-z0-9][a-z0-9-]{0,62}
#   fleet:tailscale            the fleet Tailscale key
#   fleet:tailscale:<project>  project = [a-z0-9_-][a-z0-9._-]{0,63}, no ..
#   fleet:telegram             the Telegram bot token
#
# THE ENV LINE written is NAME='value'. A value that is empty, or holds ', LF,
# CR or NUL, is refused and nothing is written: the files are sourced with
# `set -a; . file`, and the single quotes keep a Fly token (`FlyV1 a,b`) one
# word. A trailing newline is refused too, never trimmed.
#
#   envelope_fleet_scope_parse <scope>
#     rc 0 prints `<target> <arg>`: `fly <org>`, `tailscale -`,
#     `tailscale <project>` or `telegram -`. rc 1 prints `bad-scope`.
#   env_line_set <file> <NAME> <value-file>
#     The value comes from a file, never argv. NAME is [A-Z_][A-Z0-9_]*. The
#     file is resolved with readlink -f (a symlink is written at its target). A
#     tmp file in the same directory (umask 077) gets every line that does not
#     set NAME (`NAME=`, `export NAME=`, leading blanks allowed) and the one new
#     line in the place of the first match, else at the end; then chmod 600 and
#     mv. A missing file is created. rc 0 written, rc 1 bad NAME or value
#     (nothing written), rc 2 a step failed (old file kept, tmp removed).
#   env_line_check <file> <NAME> <value-file>
#     Sources the file in a subshell with NAME unset first and compares. rc 0
#     equal, rc 2 not. Prints nothing.
#   envelope_fleet_apply <scope> <secret-file>
#     The env dir is harness_env_dir (bin/lib/env-path.sh) with the root
#     ${HARNESS:-${H:-}}; with no HARNESS_ENV_DIR and no root it is rc 2.
#       fly <org>      fly.env FLY_ORG, then FLY_API_TOKEN; flag fly.token_present=1
#       tailscale -    fly.env TS_AUTHKEY; flag tailscale.key_present=1
#       tailscale <p>  fly.env TS_AUTHKEY_<P> (upper case, . and - as _); no flag
#       telegram -     global.env TELEGRAM_BOT_TOKEN; no flag (the hub's
#                      bin/fleet-telegram-chat.sh sets telegram.bot_present)
#     Every line is read back with env_line_check before the flag is set.
#     rc 0 written, checked, flagged. rc 1 bad scope or value, nothing written.
#     rc 2 a write or a read back failed, no flag. rc 3 written and checked, but
#     the flag write failed or setting_set (bin/lib/jobs/settings.sh) is not
#     loaded. One line on stdout: `ENVELOPE_FLEET ok|refused|failed|unflagged
#     <target> <reason>`.
#
# No lock here: the caller holds the secrets-apply lock, so one writer at a time
# touches an env file.

# shellcheck source=bin/lib/env-path.sh
. "${BASH_SOURCE[0]%/*}/env-path.sh" 2>/dev/null || true

envelope_fleet_scope_parse() {
  local LC_ALL=C s="${1:-}"
  if [[ $s =~ ^fleet:fly:([a-z0-9][a-z0-9-]{0,62})$ ]]; then
    printf 'fly %s\n' "${BASH_REMATCH[1]}"; return 0
  fi
  if [ "$s" = fleet:tailscale ]; then printf 'tailscale -\n'; return 0; fi
  if [[ $s =~ ^fleet:tailscale:([a-z0-9_-][a-z0-9._-]{0,63})$ ]] && [[ $s != *..* ]]; then
    printf 'tailscale %s\n' "${BASH_REMATCH[1]}"; return 0
  fi
  if [ "$s" = fleet:telegram ]; then printf 'telegram -\n'; return 0; fi
  printf 'bad-scope\n'; return 1
}

# _ef_value <file>: the value on stdout, rc 1 when it is missing, empty, or
# holds ', LF, CR or NUL. Only a builtin printf ever sees the value.
_ef_value() {
  local LC_ALL=C f="${1:-}" v n
  [ -f "$f" ] && [ -r "$f" ] || return 1
  n=$(wc -c < "$f") || return 1
  v=$(cat -- "$f"; printf x) 2>/dev/null || return 1
  v=${v%x}
  [ -n "$v" ] && [ "${#v}" -eq "$n" ] || return 1
  case "$v" in *"'"*|*$'\n'*|*$'\r'*) return 1 ;; esac
  printf '%s' "$v"
}

_ef_name_ok() { local LC_ALL=C; [[ ${1:-} =~ ^[A-Z_][A-Z0-9_]*$ ]]; }

env_line_set() {
  local file="${1:-}" name="${2:-}" vf="${3:-}" val target dir tmp line re hit=0
  _ef_name_ok "$name" || return 1
  val=$(_ef_value "$vf") || return 1
  [ -n "$file" ] || return 2
  target=$(readlink -f -- "$file" 2>/dev/null) || return 2
  dir=$(dirname -- "$target")
  [ -d "$dir" ] || return 2
  tmp="$target.envtmp.$$"
  re="^[[:space:]]*(export[[:space:]]+)?${name}="
  if ! (
    umask 077
    {
      if [ -e "$target" ]; then
        [ -r "$target" ] || exit 2
        while IFS= read -r line || [ -n "$line" ]; do
          if [[ $line =~ $re ]]; then
            [ "$hit" = 1 ] && continue
            printf "%s='%s'\n" "$name" "$val"; hit=1
          else
            printf '%s\n' "$line"
          fi
        done < "$target" || exit 2
      fi
      [ "$hit" = 1 ] || printf "%s='%s'\n" "$name" "$val"
    } > "$tmp" || exit 2
    chmod 600 "$tmp" || exit 2
    mv -f -- "$tmp" "$target" || exit 2
  ); then
    rm -f -- "$tmp" 2>/dev/null
    return 2
  fi
  return 0
}

env_line_check() {
  local file="${1:-}" name="${2:-}" vf="${3:-}" val
  _ef_name_ok "$name" || return 2
  val=$(_ef_value "$vf") || return 2
  [ -r "$file" ] || return 2
  ( unset "$name"; set -a; . "$file" >/dev/null 2>&1; [ "${!name-}" = "$val" ] ) || return 2
  return 0
}

_ef_say() { printf 'ENVELOPE_FLEET %s %s %s\n' "$1" "$2" "$3"; }

envelope_fleet_apply() {
  local scope="${1:-}" sf="${2:-}" parsed target arg dir file name flag="" rc orgf
  if ! parsed=$(envelope_fleet_scope_parse "$scope"); then _ef_say refused - bad-scope; return 1; fi
  target=${parsed%% *}; arg=${parsed#* }
  if ! _ef_value "$sf" >/dev/null; then _ef_say refused "$target" bad-value; return 1; fi
  if [ -z "${HARNESS_ENV_DIR:-}" ] && [ -z "${HARNESS:-${H:-}}" ]; then _ef_say failed "$target" no-env-dir; return 2; fi
  if ! declare -F harness_env_dir >/dev/null; then _ef_say failed "$target" no-env-path-lib; return 2; fi
  dir=$(harness_env_dir "${HARNESS:-${H:-}}")
  case "$target" in
    fly)
      file="$dir/fly.env"; name=FLY_API_TOKEN; flag=fly.token_present
      orgf=$(mktemp "${TMPDIR:-/tmp}/envelope-fleet.XXXXXX") || { _ef_say failed fly tmp; return 2; }
      printf '%s' "$arg" > "$orgf"
      env_line_set "$file" FLY_ORG "$orgf"; rc=$?
      [ "$rc" = 0 ] && { env_line_check "$file" FLY_ORG "$orgf"; rc=$?; }
      rm -f -- "$orgf"
      if [ "$rc" != 0 ]; then _ef_say failed fly FLY_ORG; return 2; fi
      ;;
    tailscale)
      file="$dir/fly.env"
      if [ "$arg" = - ]; then name=TS_AUTHKEY; flag=tailscale.key_present
      else name="TS_AUTHKEY_$(printf '%s' "$arg" | tr '[:lower:].-' '[:upper:]__')"; fi
      ;;
    telegram) file="$dir/global.env"; name=TELEGRAM_BOT_TOKEN ;;
  esac
  env_line_set "$file" "$name" "$sf"; rc=$?
  if [ "$rc" = 1 ]; then _ef_say refused "$target" bad-value; return 1; fi
  if [ "$rc" != 0 ]; then _ef_say failed "$target" "write $name"; return 2; fi
  if ! env_line_check "$file" "$name" "$sf"; then _ef_say failed "$target" "read-back $name"; return 2; fi
  if [ -n "$flag" ]; then
    if ! declare -F setting_set >/dev/null; then _ef_say unflagged "$target" "no setting_set for $flag"; return 3; fi
    if ! setting_set "$flag" 1; then _ef_say unflagged "$target" "$flag write failed"; return 3; fi
  fi
  _ef_say ok "$target" "$name"
  return 0
}
