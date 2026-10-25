#!/bin/bash
# bin/lib/vendor/codex.sh probe — BH-7965: the Codex proof call. The API key on
# stdin. One `codex exec -` with `ping`, the model from model_for codex.default
# (no literal). Exit codes: bin/lib/vendor/_common.sh.
set -uo pipefail
# shellcheck source=bin/lib/vendor/_common.sh
. "$(dirname "$0")/_common.sh" || exit 99
vendor_probe_real() {
  local m
  m=$(vendor_model codex.default) || { vendor_say "codex: no model route for codex.default"; return 75; }
  vendor_cli_probe codex CODEX_API_KEY codex exec -m "$m" --skip-git-repo-check -
}
vendor_main codex "$@"
