#!/bin/bash
# bin/lib/e2e-paths.sh — the fleet's ONE definition of "this diff can change
# what a browser E2E suite sees" and "this check is a browser/prod-targeted
# check". Sourced, never executed. Policy: docs/E2E-POLICY.md (the operator, 2026-09-12).
#
# WHY ONE FILE. The E2E policy lives in three places that each read PR check
# state — the external-PR re-review debounce (bin/review-prs.sh), the aging-PR
# autopilot reviewer (bin/review-autopilot.sh) and the app repos' own paths:
# filters — and the harness-side rule is the same sentence everywhere: an E2E /
# Production-QA / deployment-targeted check is ADVISORY unless the diff touches
# an E2E path, in which case a red one blocks. Two copies of that regex would
# drift, and a drifted copy is exactly how a red check that should have blocked
# gets waved through (or a green one keeps a re-review deferred for 12 hours).
#
#   e2e_path_hit            reads newline-separated paths on STDIN; rc 0 when
#                           any of them is an E2E path, rc 1 when none is
#   e2e_check_name <name>   rc 0 when a workflow/check NAME is E2E-class
#   E2E_PATH_RE / E2E_CHECK_RE  the regexes, for jq/awk callers
#
# The path list mirrors the app repos' paths: filters (app/ src/app/ pages/
# components/ ui/ middleware.* proxy.* route handlers, auth code, e2e specs,
# playwright config, deps and global styling). Keep the two in step: a path
# the repos gate on but this file ignores would let the harness call a red E2E
# advisory on the very diff the repo decided to run it for.
E2E_PATH_RE='(^|/)(app|pages|components|ui|e2e|auth|__e2e__)/|(^|/)(middleware|proxy|auth)\.[cm]?[jt]sx?$|(^|/)route\.[cm]?[jt]sx?$|(^|/)playwright[^/]*$|(^|/)playwright/|(^|/)(package\.json|package-lock\.json|pnpm-lock\.yaml|yarn\.lock|bun\.lockb?)$|(^|/)(next|tailwind|postcss)\.config\.[^/]+$|(^|/)(globals?|global|index|app|styles)\.css$|\.spec\.[jt]sx?$|(^|/)\.github/workflows/[^/]*(e2e|playwright|qa)[^/]*$'
# Check NAMES, case-insensitive: "E2E Tests", "Production QA", "e2e-prod",
# "Preview QA", "playwright", "browser". Typecheck/Lint/Unit/Guard never match.
# Deliberately NOT "smoke" or "deploy": project-5's "Bridge npm smoke test" is
# a unit-class check and "Deploy Worker to Railway" is a push-time deploy, and
# a name regex that made either advisory would loosen the review debounce past
# what the policy says. A repo's prod-targeted check must carry one of the
# words above (the sibling PRs name theirs "Production QA" / "E2E Tests").
E2E_CHECK_RE='e2e|playwright|production[ _-]?qa|prod[ _-]?qa|preview[ _-]?qa|browser'

e2e_path_hit() { # stdin: one path per line
  grep -qE "$E2E_PATH_RE"
}
e2e_check_name() { # e2e_check_name <name>
  grep -qiE "$E2E_CHECK_RE" <<<"${1:-}"
}
