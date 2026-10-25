#!/bin/bash
# bin/lib/vendor/openrouter.sh probe — BH-7965: the OpenRouter proof call. The API key on
# stdin. ONE GET <base>/key; base = settings row vendor.openrouter.base_url (same
# host only), else the documented fallback below (A5). Not /models: OpenRouter
# answers /models with 200 for any key or none, so it proves nothing. /key
# answers 401 for a bad key. Exit codes: bin/lib/vendor/_common.sh.
set -uo pipefail
# shellcheck source=bin/lib/vendor/_common.sh
. "$(dirname "$0")/_common.sh" || exit 99
# Fallback of settings row vendor.openrouter.base_url.
vendor_probe_real() { vendor_api_probe openrouter https://openrouter.ai/api/v1 /key; }
vendor_main openrouter "$@"
