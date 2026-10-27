# shellcheck shell=bash
# bin/lib/vendor/seam.sh — the vendor seam switch (BH-7939.0). Sourced only:
# no output, no file write, no `set` change and no trap on source.
#
# Every vendor adapter in bin/lib/vendor/<vendor>.sh sources this file and asks
# vendor_mode before it calls the network. In fake mode it answers from a seed
# file through vendor_fake and makes no network call. Test-only env:
#   HARNESS_VENDOR_MODE  unset, empty or `real` = real calls (the production
#                        default); exactly `fake` = seed answers; any other
#                        value fails closed (rc 2), so a typo never reads a seed.
#   VENDOR_FAKE_DIR      the seed directory (default <repo>/tests/fakes/vendor).
#   VENDOR_CALL_LOG      in real mode, one `<epoch> <vendor> <method>` line per
#                        real call; the budget test counts them.

# vendor_mode — print `real` or `fake`; rc 2 on any other HARNESS_VENDOR_MODE.
vendor_mode() {
  case "${HARNESS_VENDOR_MODE:-}" in
    ''|real) echo real ;;
    fake) echo fake ;;
    *) echo "vendor-mode: unknown '${HARNESS_VENDOR_MODE}'" >&2; return 2 ;;
  esac
}

# vendor_fake <vendor> <method> [key] — print the seeded answer
# `.[method]` (or `.[method][key]`) of <dir>/<vendor>.json as compact JSON.
# rc 70 when the file, the method or the key is not seeded. Uses jq only.
vendor_fake() {
  local vendor="${1:-}" method="${2:-}" dir out
  dir="${VENDOR_FAKE_DIR:-${BASH_SOURCE[0]%/*}/../../../tests/fakes/vendor}"
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
