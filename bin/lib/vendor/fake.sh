#!/bin/bash
# bin/lib/vendor/fake.sh <vendor> — BH-7965: the test-mode answer of a vendor
# seam (HARNESS_VENDOR_FAKE=1). The key on stdin. 0 network calls.
# Fixture: ${HARNESS_VENDOR_FAKE_DIR:-<root>/tests/fixtures/vendor-fake}/<vendor>.json,
#   {"probe":{"accept":[...],"unreachable":[...]}}
# Exit 0 key in probe.accept, 75 key in probe.unreachable, 1 any other key,
# 99 a missing or unreadable fixture, or an unknown vendor name.
set -uo pipefail
v="${1:-}"
case "$v" in ''|*[!a-z0-9]*) printf 'unimplemented: %s\n' "$v" >&2; exit 99 ;; esac
root="$(cd "$(dirname "$0")/../../.." && pwd)"
f="${HARNESS_VENDOR_FAKE_DIR:-$root/tests/fixtures/vendor-fake}/$v.json"
[ -r "$f" ] && jq -e '.probe | type == "object"' "$f" >/dev/null 2>&1 \
  || { printf 'vendor-fake: no fixture for %s\n' "$v" >&2; exit 99; }
key=$(head -c 1024); key="${key%$'\n'}"
# The lists are read into bash and compared here: the key never goes on jq's argv.
mapfile -t acc < <(jq -r '.probe.accept[]? | strings' "$f")
mapfile -t down < <(jq -r '.probe.unreachable[]? | strings' "$f")
for k in "${acc[@]}"; do [ -n "$k" ] && [ "$k" = "$key" ] && exit 0; done
for k in "${down[@]}"; do [ -n "$k" ] && [ "$k" = "$key" ] && exit 75; done
exit 1
