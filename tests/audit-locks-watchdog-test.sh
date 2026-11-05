#!/bin/bash
# Security regressions for prototype auth, delegated mint scope/caps, and the
# watchdog's dedicated header protocol. No deployment or external service.
set -euo pipefail
AUDIT_REPO=$(cd "$(dirname "$0")/.." && pwd)
node --test "$AUDIT_REPO/tests/locks-worker-security-audit.test.mjs" \
  "$AUDIT_REPO/worker/watchdog/test/audit-header-auth.test.js"
