# shellcheck shell=bash
# owner: BH-7939.1
# bin/lib/vendor/tailscale.sh — the tailscale seam. BH-7939.1 adds its calls here.
# shellcheck source=seam.sh
. "${BASH_SOURCE[0]%/*}/seam.sh" || return 1
