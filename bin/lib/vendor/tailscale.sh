# shellcheck shell=bash
# owner: BH-7939.1
# bin/lib/vendor/tailscale.sh — the Tailscale seam (BH-7975). Sourced only: it
# defines functions and runs nothing.
#
#   ts_ip_ok <text>                         rc 0 only for one IPv4 in 100.64/10
#   ts_join <host> <authkey_var_name> [ts_hostname]
#       Join <host> to the tailnet and print its tailnet IPv4.
#   ts_ip <host>                            print <host>'s tailnet IPv4
#
# Both calls are ONE ssh to root@<host>. ts_join takes the NAME of the variable
# that holds the auth key, never the key: the key goes over ssh on stdin, the
# remote writes it to a mode-600 temp file for `tailscale up
# --auth-key=file:<f>` and removes it. So the key is in no argv on either side
# and in no log; error text has it cut to <key>. Every input is checked before
# the call. The answer is printed only when ts_ip_ok passes. In fake mode the
# answers come from tests/fixtures/vendor-fake/tailscale.json, keyed by host (a seeded
# {"error": "..."} is a failed call), and no call is made.
#
# Env: TS_CALL_TIMEOUT_S (seconds for the ssh; the station passes the settings
# row onboard.box_call_timeout_s; fallback 120).
# rc 0 the IP; 1 the call failed or the answer is not one tailnet IP; 2 a bad
# input or vendor mode; 3 the key variable is empty; 70 an unseeded fake key.
# shellcheck source=seam.sh
. "${BASH_SOURCE[0]%/*}/seam.sh" || return 1

ts_ip_ok() {
  local o='(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9][0-9]|[0-9])'
  [[ "${1-}" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.$o\.$o$ ]]
}

# _ts_host_ok <host> — an IPv4, an fdaa: (Fly 6PN) IPv6 or an RFC 1123 name.
_ts_host_ok() {
  local h="${1-}"
  [[ "$h" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && return 0
  [[ "$h" =~ ^fdaa:[0-9a-f:]{2,36}$ ]] && return 0
  [ "${#h}" -le 253 ] && [[ "$h" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]]
}

# _ts_ssh <method> <host> <remote command> — one ssh call; stdin passes
# through. Prints the answer; stderr held and printed on failure.
# StrictHostKeyChecking=accept-new: a machine fm_create just made has a host
# key in no known_hosts, and BatchMode turns the default `ask` into "Host key
# verification failed" (bin/box-launch.sh uses the same flag). A CHANGED key
# still fails.
_ts_ssh() {
  local method="$1" host="$2" cmd="$3" t err rc out
  t="${TS_CALL_TIMEOUT_S:-120}"   # knob: settings row onboard.box_call_timeout_s
  [[ "$t" =~ ^[0-9]+$ ]] && [ "$t" -ge 1 ] && [ "$t" -le 1800 ] || t=120
  vendor_call_log tailscale "$method"
  { err=$(timeout "$t" ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout="$t" "root@$host" "$cmd" 2>&1 1>&3 3>&-); } 3>&1
  rc=$?
  [ "$rc" = 0 ] && return 0
  printf 'tailscale: %s over ssh rc %s: %s\n' "$method" "$rc" "${err:0:300}" >&2
  return 1
}

# _ts_answer <fake-json|text> — prints the IP or fails rc 1.
_ts_answer() {
  local ip="$1"
  if ! ts_ip_ok "$ip"; then
    echo "tailscale: answer is not one 100.64/10 address" >&2
    return 1
  fi
  printf '%s\n' "$ip"
}

# _ts_fake <method> <host> — the seeded answer, or the seeded error.
_ts_fake() {
  local v e
  v=$(vendor_fake tailscale "$1" "$2") || return $?
  e=$(jq -r 'if type == "object" then (.error // "error") else empty end' <<<"$v" 2>/dev/null)
  [ -z "$e" ] || { printf '%s\n' "$e" >&2; return 1; }
  jq -r 'if type == "string" then . else empty end' <<<"$v" 2>/dev/null
}

ts_join() {
  local host="${1:-}" name="${2:-}" tsh="${3:-}" key mode out rc
  [[ "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { echo "tailscale: '$name' is not a variable name" >&2; return 2; }
  _ts_host_ok "$host" || { echo "tailscale: bad host '${host:0:80}'" >&2; return 2; }
  if [ -n "$tsh" ] && ! [[ "$tsh" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    echo "tailscale: bad tailnet hostname '${tsh:0:80}'" >&2; return 2
  fi
  key="${!name:-}"
  [ -n "$key" ] || { echo "tailscale: $name is not set" >&2; return 3; }
  mode=$(vendor_mode) || return 2
  if [ "$mode" = fake ]; then
    out=$(_ts_fake join "$host") || return $?
  else
    out=$(printf '%s\n' "$key" | _ts_ssh join "$host" \
      "umask 077; f=\$(mktemp) || exit 1; cat > \"\$f\"; tailscale up --auth-key=\"file:\$f\"${tsh:+ --hostname=$tsh} >/dev/null; rc=\$?; rm -f \"\$f\"; [ \"\$rc\" = 0 ] || { echo \"tailscale up rc \$rc\" >&2; exit 1; }; tailscale ip -4" 2>&1)
    rc=$?
    if [ "$rc" != 0 ]; then printf '%s\n' "${out//"$key"/<key>}" >&2; return 1; fi
  fi
  _ts_answer "$out"
}

ts_ip() {
  local host="${1:-}" mode out
  _ts_host_ok "$host" || { echo "tailscale: bad host '${host:0:80}'" >&2; return 2; }
  mode=$(vendor_mode) || return 2
  if [ "$mode" = fake ]; then
    out=$(_ts_fake ip "$host") || return $?
  else
    out=$(_ts_ssh ip "$host" 'tailscale ip -4' </dev/null) || return 1
  fi
  _ts_answer "$out"
}
