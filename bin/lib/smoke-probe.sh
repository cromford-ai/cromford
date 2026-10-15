#!/bin/bash
# bin/lib/smoke-probe.sh — the post-merge prod smoke probe (BH-6786).
#
# smoke_url <project> <base-url> — print the URL to probe: <base> plus the
#   settings row deploy.<project>.smoke_path (for example /sign-in). No row, an
#   outage, no client on the box or an invalid value prints <base> unchanged;
#   an invalid value is named once on stderr. The host always comes from the
#   base, never from the row, so a leading // is refused.
# smoke_code <url> — GET <url> following redirects, as a browser page load
#   (Accept, Sec-Fetch-Dest, Sec-Fetch-Mode, browser User-Agent), and print the
#   final HTTP code. Clerk answers a signed-out request that is not a page load
#   with 404. A curl that cannot connect prints 000.
#
# The client is sourced in a SUBSHELL, same as bin/lib/deploy-kind.sh:
# bin/jobs-client.sh `exit 1`s the shell that sources it when a module is
# missing (BH-1194).
smoke_url() {
  local key base="${2:-}" v rc=0 h="${HARNESS:-${H:-}}"
  key="deploy.$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]').smoke_path"
  if [ -n "$h" ]; then
    v=$(
      [ -r "$h/bin/jobs-client.sh" ] || exit 2
      # shellcheck source=/dev/null
      . "$h/bin/jobs-client.sh" 2>/dev/null || exit 2
      declare -F setting_get >/dev/null 2>&1 || exit 2
      setting_get "$key" 2>/dev/null
    ) || rc=$?
  else
    rc=2
  fi
  if [ "$rc" = 0 ]; then
    if [ "$v" = / ] || [[ $v =~ ^/[A-Za-z0-9._~?=\&%-][A-Za-z0-9._~/?=\&%-]{0,199}$ ]]; then
      printf '%s%s\n' "${base%/}" "$v"; return 0
    fi
    echo "smoke_url: $key has invalid value '$v' (want one leading /, at most 200 URL path chars); probing $base" >&2
  fi
  printf '%s\n' "$base"
}

smoke_code() {
  curl -s -o /dev/null -w '%{http_code}' -m 30 -L \
    -H 'Accept: text/html,application/xhtml+xml' \
    -H 'Sec-Fetch-Dest: document' \
    -H 'Sec-Fetch-Mode: navigate' \
    -A 'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36' \
    "${1:?url}"
}
