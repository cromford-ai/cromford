# shellcheck shell=bash
# bin/lib/vendor/resend.sh — the Resend email seam (BH-8894). Sourced only.
# The call takes the NAME of the env variable that holds the API key, never the
# key, so the key is in no argv and no log. curl reads its whole config (url,
# headers, body) from stdin (`-K -`) through printf, a builtin, so the key is
# not in /proc/<pid>/cmdline either. In fake mode (HARNESS_VENDOR_FAKE=1) the
# answer comes from tests/fixtures/vendor-fake/resend.json (bin/lib/vendor/seam.sh)
# and no call is made. Contract suite: tests/contract/resend.bh-8894.contract-test.sh.
# shellcheck source=seam.sh
. "${BASH_SOURCE[0]%/*}/seam.sh" || return 1

# _rs_q <value> — the value as a quoted curl config string: backslash, quote,
# CR, LF and tab escaped, so a text line can never start a new config option.
_rs_q() {
  local v="${1//\\/\\\\}"
  v="${v//\"/\\\"}"; v="${v//$'\n'/\\n}"; v="${v//$'\r'/\\r}"; v="${v//$'\t'/\\t}"
  printf '"%s"' "$v"
}

# resend_send <key_var_name> <from> <to> <subject> <text> — one POST
# https://api.resend.com/emails with a plain-text body. Print the raw answer;
# the caller reads `.id` (Resend answers {"id":"..."} on success and
# {"statusCode":...,"message":...} on an error). rc 0 curl answered, rc 1 curl
# failed (the error with the key cut), rc 2 bad variable name or vendor mode,
# rc 3 key not set, rc 4 from, to or subject empty, rc 70 an unseeded fake.
resend_send() {
  local name="${1:-}" from="${2:-}" to="${3:-}" subject="${4:-}" text="${5:-}" key mode data body rc
  [[ "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo "resend: '$name' is not a variable name" >&2; return 2; }
  key="${!name:-}"
  [ -n "$key" ] || { echo "resend: $name is not set" >&2; return 3; }
  [ -n "$from" ] && [ -n "$to" ] && [ -n "$subject" ] || { echo "resend: from, to and subject must be set" >&2; return 4; }
  mode=$(vendor_mode) || return 2
  if [ "$mode" = fake ]; then
    vendor_fake resend send
    return $?
  fi
  vendor_call_log resend send
  local tmo="${RESEND_API_TIMEOUT_S:-20}"   # knob: catalog/lanes.d/_lib.vendor-resend.knobs.d
  [[ $tmo =~ ^[0-9]+$ ]] && [ "$tmo" -ge 1 ] && [ "$tmo" -le 120 ] || tmo=20
  data=$(jq -nc --arg from "$from" --arg to "$to" --arg subject "$subject" --arg text "$text" \
    '{from:$from, to:[$to], subject:$subject, text:$text}') || { echo "resend: cannot build the body" >&2; return 1; }
  body=$({
    printf 'url = %s\n' "$(_rs_q "https://api.resend.com/emails")"
    printf 'header = %s\n' "$(_rs_q "Authorization: Bearer $key")"
    printf 'header = %s\n' "$(_rs_q "Content-Type: application/json")"
    printf 'data = %s\n' "$(_rs_q "$data")"
  } | curl -sS --max-time "$tmo" -K - 2>&1); rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "resend: curl rc $rc: ${body//"$key"/<key>}" >&2
    return 1
  fi
  printf '%s\n' "$body"
}
