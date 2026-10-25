#!/bin/bash
# bin/lib/vendor/claude.sh probe — BH-7965: the Claude proof call. The OAuth
# token on stdin. One `claude -p` with `ping`, the model from model_for
# claude.ladder (no literal). Exit codes: bin/lib/vendor/_common.sh.
set -uo pipefail
# shellcheck source=bin/lib/vendor/_common.sh
. "$(dirname "$0")/_common.sh" || exit 99
vendor_probe_real() {
  local m
  m=$(vendor_model claude.ladder) || { vendor_say "claude: no model route for claude.ladder"; return 75; }
  vendor_cli_probe claude CLAUDE_CODE_OAUTH_TOKEN claude -p --model "$m"
}
vendor_main claude "$@"
