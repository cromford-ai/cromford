# shellcheck shell=bash
# bin/lib/vendor/seam.sh — the vendor seam switch (BH-7939.0). Sourced only:
# no output, no file write, no `set` change and no trap on source.
#
# Every vendor adapter in bin/lib/vendor/<vendor>.sh sources this file and asks
# vendor_mode before it calls the network. In fake mode it answers from a seed
# file through vendor_fake and makes no network call. Test-only env (BH-8555:
# the ONE fake switch of every bin/lib/vendor/ seam, read by vendor_fake_on in
# _common.sh):
#   HARNESS_VENDOR_FAKE      unset, empty or 0 = real calls (the production
#                            default); exactly 1 = seed answers; any other
#                            value fails closed (rc 2), so a typo never reads
#                            a seed and never calls the vendor.
#   HARNESS_VENDOR_FAKE_DIR  the seed directory (default
#                            <repo>/tests/fixtures/vendor-fake).
#   VENDOR_CALL_LOG          in real mode, one `<epoch> <vendor> <method>` line
#                            per real call; the budget test counts them.
# shellcheck source=_common.sh
. "${BASH_SOURCE[0]%/*}/_common.sh" || return 1

# vendor_mode — print `real` or `fake`; rc 2 on an unknown switch value.
vendor_mode() {
  vendor_fake_on
  case $? in
    0) echo fake ;;
    1) echo real ;;
    *) echo "vendor-mode: unknown fake switch value '${HARNESS_VENDOR_FAKE:-}' (use unset, 0 or 1)" >&2; return 2 ;;
  esac
}

# vendor_fake <vendor> <method> [key] — print the seeded answer
# `.[method]` (or `.[method][key]`) of <dir>/<vendor>.json as compact JSON.
# rc 70 when the file, the method or the key is not seeded. Uses jq only.
vendor_fake() {
  local vendor="${1:-}" method="${2:-}" dir out
  dir="${HARNESS_VENDOR_FAKE_DIR:-${BASH_SOURCE[0]%/*}/../../../tests/fixtures/vendor-fake}"
  if [[ "$vendor" =~ ^[a-z0-9_-]+$ ]] && [ -r "$dir/$vendor.json" ]; then
    if [ $# -ge 3 ]; then
      out=$(jq -c --arg m "$method" --arg k "$3" \
        'if (.[$m]|type) == "object" and (.[$m]|has($k)) then .[$m][$k] else error("unseeded") end' \
        "$dir/$vendor.json" 2>/dev/null)
    else
      out=$(jq -c --arg m "$method" 'if has($m) then .[$m] else error("unseeded") end' \
        "$dir/$vendor.json" 2>/dev/null)
    fi && { printf '%s\n' "$out"; return 0; }
  fi
  echo "vendor-fake: $vendor.$method not implemented" >&2
  return 70
}

# vendor_call_log <vendor> <method> — in real mode with VENDOR_CALL_LOG set,
# append `<epoch> <vendor> <method>`. Otherwise write nothing. Always rc 0.
vendor_call_log() {
  [ -n "${VENDOR_CALL_LOG:-}" ] || return 0
  [ "$(vendor_mode 2>/dev/null)" = real ] || return 0
  printf '%s %s %s\n' "$(date -u +%s)" "${1:-}" "${2:-}" >> "$VENDOR_CALL_LOG" 2>/dev/null
  return 0
}
