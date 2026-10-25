#!/bin/bash
# bin/lib/vendor/xai.sh probe — BH-7965: the xAI proof call. The API key on
# stdin. ONE GET <base>/models; base = settings row vendor.xai.base_url (same host only), else
# the documented fallback below (A5). Exit codes: bin/lib/vendor/_common.sh.
set -uo pipefail
# shellcheck source=bin/lib/vendor/_common.sh
. "$(dirname "$0")/_common.sh" || exit 99
# Fallback of settings row vendor.xai.base_url.
vendor_probe_real() { vendor_api_probe xai https://api.x.ai/v1; }
vendor_main xai "$@"
