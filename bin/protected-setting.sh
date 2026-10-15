#!/bin/bash
# bin/protected-setting.sh <key> <value> [note] — BH-4090: PUT one protected
# setting (lead_authority.*, risk_tier.*, human_verdict_mode,
# human_verdict_sig_mode) WITH the human verdict token, so the worker accepts a
# loosening and signs the value into setting_sigs. Run on the operator's Mac, the only
# place the token lives.
#   JOBS_URL, HARNESS_SECRET     from the environment
#   HUMAN_VERDICT_TOKEN_FILE     default ~/.config/cromford/human-verdict-token
# The bearer and the token go to curl through a mode-600 header file (-H @file),
# never argv. Prints `<key> = <value>  signed=<signed> sig_seq=<seq>`.
#   rc 0  the worker answered 2xx with signed:true
#   rc 1  anything else: missing env or token, transport failure, non-2xx (the
#         worker's error on stderr), or a 2xx with signed not true (the value is
#         written but reads unproven under sig enforce)
#   rc 2  usage
# Bash 3.2 safe: no arrays, no ${x,,}, no mapfile.
set -u

die() { echo "protected-setting: $*" >&2; exit 1; }
[ $# -ge 2 ] || { echo "usage: bin/protected-setting.sh <key> <value> [note]" >&2; exit 2; }
key="$1"; value="$2"; note="${3:-}"
[ -n "${JOBS_URL:-}" ] || die "JOBS_URL is not set"
[ -n "${HARNESS_SECRET:-}" ] || die "HARNESS_SECRET is not set"
command -v jq >/dev/null 2>&1 || die "jq is required"

HUMAN_VERDICT_TOKEN_FILE="${HUMAN_VERDICT_TOKEN_FILE:-$HOME/.config/cromford/human-verdict-token}"
[ -r "$HUMAN_VERDICT_TOKEN_FILE" ] || die "the human verdict token file (HUMAN_VERDICT_TOKEN_FILE, now $HUMAN_VERDICT_TOKEN_FILE) is not readable"
m=$(stat -c %a "$HUMAN_VERDICT_TOKEN_FILE" 2>/dev/null || stat -f %Lp "$HUMAN_VERDICT_TOKEN_FILE" 2>/dev/null)
[ "$m" = 600 ] || echo "protected-setting: warning: $HUMAN_VERDICT_TOKEN_FILE is mode ${m:-unknown}, not 600 — chmod 600 it" >&2
htok=$(head -1 "$HUMAN_VERDICT_TOKEN_FILE" | tr -d ' \r\n')
[ -n "$htok" ] || die "the human verdict token file $HUMAN_VERDICT_TOKEN_FILE is empty"

hdr=$(umask 077; mktemp "${TMPDIR:-/tmp}/protected-setting-h.XXXXXX") || die "mktemp failed"
trap 'rm -f "$hdr"' EXIT
printf 'authorization: Bearer %s\nx-human-verdict-token: %s\ncontent-type: application/json\n' \
  "$HARNESS_SECRET" "$htok" > "$hdr"
unset htok

body=$(jq -nc --arg k "$key" --arg v "$value" --arg n "$note" --arg a "protected-setting:${USER:-unknown}" \
  '{key: $k, value: $v, actor: $a} + (if $n == "" then {} else {note: $n} end)') || die "could not build the request body"
out=$(curl -sS -m "${JOBS_TIMEOUT:-8}" --connect-timeout 3 -w $'\n%{http_code}' -X PUT \
  -H "@$hdr" --data-binary "$body" "$JOBS_URL/api/settings") || die "worker unreachable ($JOBS_URL)"
code="${out##*$'\n'}"; payload="${out%$'\n'*}"
case "$code" in
  2??) ;;
  *) die "http $code: $(printf '%s' "$payload" | jq -r '.error // .' 2>/dev/null || printf '%s' "$payload")" ;;
esac
signed=$(printf '%s' "$payload" | jq -r 'if has("signed") then .signed else "absent" end' 2>/dev/null)
seq=$(printf '%s' "$payload" | jq -r '.sig_seq // "none"' 2>/dev/null)
echo "$key = $value  signed=$signed sig_seq=$seq"
case "$signed" in
  true) ;;
  false) die "written but NOT signed (worker has no HUMAN_VERDICT_SIG_KEY): it reads unproven under enforce" ;;
  *) die "written but NOT signed ($key is not a protected key, or the worker predates BH-3905)" ;;
esac
exit 0
