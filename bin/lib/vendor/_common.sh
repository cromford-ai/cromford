#!/bin/bash
# shellcheck shell=bash
# bin/lib/vendor/_common.sh — BH-7965 (BH-7937.2): the shared half of the vendor
# proof-call seams bin/lib/vendor/<v>.sh. Sourced by each seam, never run.
# Doc: docs/SECRETS-ENVELOPE.md.
#
#   <v>.sh probe      the key on stdin (never argv). One proof call.
#     exit 0  proved: the vendor accepted the key
#     exit 1  refused: the vendor said no, the key format is wrong, or a knob
#             is out of range (no call is made for the last two)
#     exit 75 unreachable: no answer, 429, 5xx, a timeout, or no model route
#     exit 99 any other verb (`unimplemented: <verb>` on stderr), or a missing
#             fake fixture
#
# HARNESS_VENDOR_FAKE=1 (test mode): the seam asks only bin/lib/vendor/fake.sh,
# which answers from tests/fixtures/vendor-fake/<v>.json. 0 network calls.
# It is the ONE fake switch (BH-8555); vendor_fake_on below is its only reader,
# and it also reads the retired BH-7974 alias for one release. Any value other
# than unset, '', 0 or 1 fails closed: exit 99, no call.
#
# THE KEY never reaches argv, a log, stdout or stderr. It lives in VENDOR_KEY
# and reaches the vendor only through a pipe (curl -K -) or the environment of
# the one CLI call.
#
# Classifier (decision rule 3, plan BH-7965):
#   API vendors: http 200 = 0; 400 401 403 404 = 1; 429, 5xx, 000 = 75; any
#     other code = 1 (not a proof).
#   claude / codex: rc 0 with stdout = 0; rc 0 with no stdout = 1; rc 124
#     (timeout) = 75; rc != 0 with an auth error on stderr = 1; with a network
#     error on stderr = 75; else 1.

VENDOR_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The checkout this seam sits in (bin/lib/vendor -> the root).
VENDOR_ROOT="$(cd "$VENDOR_DIR/../../.." && pwd)"
VENDOR_KEY=""

vendor_say() { printf 'vendor-probe: %s\n' "$*" >&2; }

# The probe timeout. Lane knob SECRETS_APPLY_PROBE_TIMEOUT_S (settings row
# lane.secrets-apply.secrets_apply_probe_timeout_s); 30 is its documented
# fallback. Out of 5..300 is refused, never clamped.
vendor_timeout() {
  local t="${SECRETS_APPLY_PROBE_TIMEOUT_S:-30}"
  [[ $t =~ ^[0-9]+$ ]] && [ "$t" -ge 5 ] && [ "$t" -le 300 ] || return 1
  printf '%s' "$t"
}

# vendor_read_key — the key from stdin into VENDOR_KEY. One trailing newline is
# dropped. 8..512 of [A-Za-z0-9._-], else rc 1.
vendor_read_key() {
  local k
  k=$(head -c 1024)
  k="${k%$'\n'}"
  [ "${#k}" -ge 8 ] && [ "${#k}" -le 512 ] && [[ $k =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  VENDOR_KEY="$k"
}

# vendor_classify_http <http_code> — decision rule 3, API vendors.
vendor_classify_http() {
  case "$1" in
    200) return 0 ;;
    400|401|403|404) return 1 ;;
    429|5[0-9][0-9]|000|'') return 75 ;;
    *) return 1 ;;
  esac
}

# vendor_classify_cli <rc> <stdout-file> <stderr-file> — decision rule 3, CLIs.
vendor_classify_cli() {
  local rc="$1" out="$2" err="$3"
  if [ "$rc" = 0 ]; then
    [ -s "$out" ] && return 0
    return 1
  fi
  [ "$rc" = 124 ] && return 75
  grep -Eqi '401|unauthori|invalid.*(token|key)|authenticat' "$err" 2>/dev/null && return 1
  grep -Eqi 'ENOTFOUND|ECONNREFUSED|ETIMEDOUT|network|5[0-9][0-9]' "$err" 2>/dev/null && return 75
  return 1
}

# vendor_model <role> — the primary model of a route, through model_for
# (bin/lib/model-route.sh). rc 75 when there is no route: never a literal.
vendor_model() {
  local m
  # shellcheck source=bin/lib/model-route.sh
  . "$VENDOR_ROOT/bin/lib/model-route.sh" 2>/dev/null || return 75
  m=$(model_for "$1" 2>/dev/null) || return 75
  [ -n "$m" ] || return 75
  printf '%s' "$m"
}

# vendor_cli_probe <vendor> <env-name> <cmd...> — run one CLI call with the key
# in <env-name>, `ping` on stdin, in a fresh temp cwd, under timeout.
vendor_cli_probe() {
  local v="$1" envname="$2" t wd rc
  shift 2
  command -v "$1" >/dev/null 2>&1 || { vendor_say "$v: $1 is not installed"; return 75; }
  t=$(vendor_timeout) || return 1
  wd=$(mktemp -d "${TMPDIR:-/tmp}/vendor-probe.XXXXXX") || return 75
  (
    cd "$wd" || exit 75
    unset ANTHROPIC_API_KEY
    export "$envname=$VENDOR_KEY"
    printf 'ping' | timeout "$t" "$@"
  ) > "$wd/.out" 2> "$wd/.err"
  rc=$?
  vendor_classify_cli "$rc" "$wd/.out" "$wd/.err"; rc=$?
  rm -rf "$wd"
  [ "$rc" = 0 ] || vendor_say "$v: probe answered rc $rc"
  return "$rc"
}

# vendor_base_url <vendor> <fallback> — settings row vendor.<v>.base_url when it
# is an https URL on the SAME host as the fallback, else the fallback (A5). The
# row is writable with the main bearer alone, and the probe sends the plain key
# to this URL: a row may change the path, never the host the key goes to.
vendor_base_url() {
  local v="$1" def="$2" b="" defhost host
  if [ -r "$VENDOR_ROOT/bin/jobs-client.sh" ] && [ -r "$VENDOR_ROOT/bin/lib/jobs/req.sh" ]; then
    # A subshell: the client sets shell options and may exit on a half copy.
    # shellcheck disable=SC1091
    b=$( HARNESS="${HARNESS:-$VENDOR_ROOT}"; . "$VENDOR_ROOT/bin/jobs-client.sh" >/dev/null 2>&1 \
         && JOBS_ALERT=0 setting_get "vendor.$v.base_url" 2>/dev/null ) || b=""
  fi
  defhost="${def#https://}"; defhost="${defhost%%/*}"
  if [[ $b =~ ^https://([A-Za-z0-9.-]+)(/[A-Za-z0-9._/-]*)?$ ]]; then
    host="${BASH_REMATCH[1]}"
    [ "${host,,}" = "${defhost,,}" ] || { vendor_say "$v: base_url row host $host is not $defhost; the fallback is used"; b="$def"; }
  else
    b="$def"
  fi
  printf '%s' "${b%/}"
}

# vendor_api_probe <vendor> <fallback-base> [<path>] — ONE GET <base><path>
# (path default /models; it must be an endpoint that needs the key), the
# bearer header and the URL in a curl config on stdin.
vendor_api_probe() {
  local v="$1" base t code path="${3:-/models}"
  t=$(vendor_timeout) || return 1
  base=$(vendor_base_url "$v" "$2")
  code=$(printf 'header = "Authorization: Bearer %s"\nurl = "%s%s"\n' "$VENDOR_KEY" "$base" "$path" \
    | curl -sS -o /dev/null -w '%{http_code}' -m "$t" -K - 2>/dev/null)
  vendor_classify_http "$code"; local rc=$?
  [ "$rc" = 0 ] || vendor_say "$v: probe answered http ${code:-none} (rc $rc)"
  return "$rc"
}

# vendor_fake_on — the ONE fake-mode switch (BH-8555). rc 0 fake, 1 real, 2 unknown.
#   HARNESS_VENDOR_FAKE  unset, '' or 0 = real; 1 = fake; anything else rc 2.
#   HARNESS_VENDOR_MODE  RETIRED alias (BH-7974 name), read only here, for one
#                        release: unset, '' or real = no say; fake = fake; else rc 2.
#                        #7985 merged and moved to HARNESS_VENDOR_FAKE (seam.sh
#                        vendor_mode calls this); remove the alias next release.
# Fake when either says fake. tests/vendor-fake-switch.bh-8555-test.sh refuses
# the retired name anywhere outside this block.
vendor_fake_on() {
  local f="${HARNESS_VENDOR_FAKE:-}" m="${HARNESS_VENDOR_MODE:-}" on=1
  case "$f" in ''|0) ;; 1) on=0 ;; *) return 2 ;; esac
  case "$m" in
    '') ;;
    real) vendor_say "HARNESS_VENDOR_MODE is retired; use HARNESS_VENDOR_FAKE=0" ;;
    fake) vendor_say "HARNESS_VENDOR_MODE is retired; use HARNESS_VENDOR_FAKE=1"; on=0 ;;
    *) return 2 ;;
  esac
  return "$on"
}

# vendor_main <vendor> <verb> — the one entry every seam calls. The seam defines
# vendor_probe_real (reads VENDOR_KEY) before it calls this.
vendor_main() {
  local v="$1" verb="${2:-}" rc
  if [ "$verb" != probe ]; then printf 'unimplemented: %s\n' "$verb" >&2; exit 99; fi
  vendor_timeout >/dev/null || { vendor_say "SECRETS_APPLY_PROBE_TIMEOUT_S must be an integer 5..300"; exit 1; }
  vendor_read_key || { vendor_say "$v: key format refused (8..512 of A-Z a-z 0-9 . _ -)"; exit 1; }
  vendor_fake_on; rc=$?
  if [ "$rc" = 2 ]; then
    vendor_say "unknown fake switch value: HARNESS_VENDOR_FAKE must be unset, 0 or 1"
    VENDOR_KEY=""; exit 99
  elif [ "$rc" = 0 ]; then
    printf '%s' "$VENDOR_KEY" | "$VENDOR_DIR/fake.sh" "$v"; rc=$?
  else
    vendor_probe_real; rc=$?
  fi
  VENDOR_KEY=""
  exit "$rc"
}
