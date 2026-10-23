#!/bin/bash
# bin/lib/web-totp.sh — TOTP codes from the web_vault store for the web-task
# lane. Sourced, never run; defines functions only.
#
#   wt_totp_code <project> <site>
#     Reads the vault field totp_secret (base32, required) and the optional
#     fields totp_digits, totp_step and totp_algorithm through wv_read
#     (bin/lib/web-vault.sh), so it runs inside a claimed web-task lane run.
#     A field the vault has no row for (`refused no_entry`) takes the RFC
#     default: 6 digits, 30 s step, sha1. Any other refusal stops. The code
#     comes from bin/lib/totp.mjs beside this file, with the secret on its stdin.
#     rc 0: the code on stdout, with no newline.
#     rc 1: `web-totp: no totp_secret`, `web-totp: totp.mjs gave no code`, or
#           the vault refusal of wv_read (`web-vault: refused <why>`,
#           `web-vault: worker unreachable`).
#     rc 2: usage, or a stored value totp.mjs refuses
#           (`web-totp: bad totp_<field>`; a stored value is never clamped).
#     The secret and the code are held in local variables and go out through
#     printf (a builtin) only: never on an argv, never in a file or a log.
#
# Needs node, curl and jq. The env of wv_read: LANE_RUN_ID, WEB_VAULT_MACHINE
# (or FLY_MACHINE_ID), WEB_VAULT_RUN_TOKEN, JOBS_URL, HARNESS_SECRET.

__wt_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
if ! declare -F wv_read >/dev/null; then
  # shellcheck source=bin/lib/web-vault.sh
  . "$__wt_dir/web-vault.sh" || { echo "web-totp: bin/lib/web-vault.sh did not load" >&2; return 1; }
fi

wt_totp_code() {
  local project="${1:-}" site="${2:-}" secret out rc f m
  local digits=6 step=30 algorithm=sha1
  if [ "$#" -ne 2 ] || [ -z "$project" ] || [ -z "$site" ]; then
    echo "web-totp: usage: wt_totp_code <project> <site>" >&2; return 2
  fi
  # wv_read prints the value OR one error line, so one capture holds either.
  secret=$(wv_read "$project" "$site" totp_secret 2>&1); rc=$?
  if [ "$rc" != 0 ]; then
    if [ "$secret" = "web-vault: refused no_entry" ]; then echo "web-totp: no totp_secret" >&2
    else printf '%s\n' "$secret" >&2; fi
    return "$rc"
  fi
  for f in digits step algorithm; do
    out=$(wv_read "$project" "$site" "totp_$f" 2>&1); rc=$?
    if [ "$rc" = 0 ]; then printf -v "$f" '%s' "$out"
    elif [ "$out" != "web-vault: refused no_entry" ]; then unset secret; printf '%s\n' "$out" >&2; return "$rc"
    fi
  done
  out=$(printf '%s' "$secret" | node "$__wt_dir/totp.mjs" code --digits "$digits" --step "$step" --algorithm "$algorithm" 2>&1); rc=$?
  unset secret
  if [ "$rc" = 0 ]; then
    # rc 0 with no code (or anything but a code) is a failure, never a success.
    if [[ $out =~ ^[0-9]{6,10}$ ]]; then printf '%s' "$out"; return 0; fi
    echo "web-totp: totp.mjs gave no code" >&2; return 1
  fi
  if [[ $out =~ ^totp:\ bad\ (secret|digits|step|algorithm)$ ]]; then
    m="${BASH_REMATCH[1]}"; echo "web-totp: bad totp_$m" >&2; return 2
  fi
  echo "web-totp: totp.mjs failed (rc $rc)" >&2
  return 1
}
