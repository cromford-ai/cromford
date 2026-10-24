#!/bin/bash
# tests/gh-joblog-escape-lint.bh-8223-test.sh — BH-8223: every `gh api` read
# of an Actions job log (actions/jobs/<id>/logs) in bin/ passes
# --allow-escape-sequences. gh refuses to print a log that holds ANSI escapes
# without it, and a reader that lacks it reads nothing.
#
# A job-log read is a non-comment line of a tracked bin/ file that holds
# `actions/jobs/`, `/logs` and a call token: `gh api`, `$GH api`, `"$GH" api`,
# `"$GH_REAL" api`, `gh_ci_api` or `gshim_api`. A line passes when it holds the
# flag, or the marker `# escape-flag-exempt: <reason>` with a non-empty reason.
#
#   R1  the repo at HEAD has 0 hits.
#   X1  every must-hit fixture line hits; every must-not-hit line does not.
#
# Scan another tree: JOBLOG_LINT_DIR=<checkout> bash <this> --scan
# Run: HARNESS_TEST_SANDBOX=1 bash tests/gh-joblog-escape-lint.bh-8223-test.sh
set -uo pipefail

# scan <dir> — prints path:line for every job-log read with no flag
scan() {
  local dir="$1" f
  git -C "$dir" ls-files bin | while IFS= read -r f; do
    [ -f "$dir/$f" ] || continue
    awk -v f="$f" '
      /^[[:space:]]*#/ { next }
      index($0, "actions/jobs/") == 0 || index($0, "/logs") == 0 { next }
      !/(^|[^A-Za-z0-9_])gh api|\$GH api|"\$GH" api|"\$GH_REAL" api|gh_ci_api|gshim_api/ { next }
      index($0, "--allow-escape-sequences") { next }
      /# escape-flag-exempt: *[^[:space:]]/ { next }
      { print f ":" NR }' "$dir/$f"
  done
}

if [ "${1:-}" = --scan ]; then scan "${JOBLOG_LINT_DIR:-.}"; exit 0; fi

. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

# ==== R1: the repo ============================================================
hits=$(scan "$DIR")
if [ -z "$hits" ]; then ok; else bad "R1: job-log reads with no --allow-escape-sequences:"; echo "$hits"; fi

# ==== X1: fixtures (the guard someone has watched fail) ========================
FX="$T/fx"; mkdir -p "$FX/bin"; git init -q "$FX" || exit 1
cat > "$FX/bin/hit.sh" <<'EOF'
gh api "repos/x/actions/jobs/$j/logs"
lg=$(gh api repos/$R/actions/jobs/$jid/logs 2>/dev/null)
"$GH" api "repos/$R/actions/jobs/$jid/logs"
gh_ci_api "$s" "repos/$s/actions/jobs/$jid/logs"
gshim_api "repos/$S/actions/jobs/$jid/logs"
"$GH_REAL" api repos/x/actions/jobs/1/logs
gh api "repos/x/actions/jobs/$j/logs" # escape-flag-exempt:
EOF
cat > "$FX/bin/miss.sh" <<'EOF'
gh api --allow-escape-sequences "repos/$R/actions/jobs/$jid/logs"
gh api "repos/$R/actions/jobs/$jid/logs" --allow-escape-sequences
  # gh api reads actions/jobs/<id>/logs here
  *actions/jobs/*/logs*) return 1 ;;
_mrb_bytes "repos/$slug/actions/jobs/$jid/logs" "$one"
gh api repos/x/actions/runs/1/logs
gh api "repos/x/actions/jobs/$j/logs" # escape-flag-exempt: bare retry for an old gh
EOF
git -C "$FX" add bin >/dev/null 2>&1 || exit 1
got=$(scan "$FX")
want=$(for n in 1 2 3 4 5 6 7; do echo "bin/hit.sh:$n"; done)
if [ "$got" = "$want" ]; then ok; else bad "X1: want [$(echo $want)] got [$(echo $got)]"; fi

echo "gh-joblog-escape-lint.bh-8223: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
