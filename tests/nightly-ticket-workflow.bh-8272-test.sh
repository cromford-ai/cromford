#!/bin/bash
# tests/nightly-ticket-workflow.bh-8272-test.sh — the nightly verdict job mints
# the harness App token on main and files a ticket only with it (BH-8272).
# Run 39920471215 skipped the mint because vars.HARNESS_APP_ID was empty, and
# the filer opened #8139 as github-actions[bot], a label the trigger-actor gate
# refuses. The mint is now loud and the filer needs its token:
#   W1  the app-token step is not continue-on-error: true
#   W2  its if: is main-only and does not test vars.HARNESS_APP_ID
#   W3  the verdict step if: carries !cancelled(), so a failed mint still judges
#   W4  the verdict step's REAL run text, executed with bash against stub
#       bin/ci-verdicts.sh and bin/nightly-ticket.sh: a red night on main with
#       NT_APP_TOKEN empty calls the filer 0 times, prints the
#       `no App token was minted` ::error::, exits 1; with the token it calls
#       the filer once and still exits 1
# Run from anywhere: tests/nightly-ticket-workflow.bh-8272-test.sh (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
WF="$DIR/.github/workflows/harness-nightly.yml"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -n "${CI:-}" ] && { echo "FAIL: PyYAML missing on a CI runner"; exit 1; }
  echo "nightly-ticket-workflow: PyYAML missing — skipping on this dev machine"; exit 0
fi

# W1-W3 from the parsed workflow; the verdict run text goes to $T/run.sh.
W=$(python3 - "$WF" "$T/run.sh" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
steps = d["jobs"]["verdict"]["steps"]
errs = []
a = next((s for s in steps if s.get("id") == "app-token"), None)
v = next((s for s in steps if "nightly-ticket.sh" in str(s.get("run", ""))), None)
if a is None: errs.append("W1: no app-token step")
else:
    if a.get("continue-on-error") is True: errs.append("W1: the app-token step must not be continue-on-error: true")
    cond = str(a.get("if", ""))
    if "refs/heads/main" not in cond: errs.append(f"W2: the mint must run on main: if: {cond!r}")
    if "HARNESS_APP_ID" in cond: errs.append(f"W2: an unset app id must fail the mint, not skip it: if: {cond!r}")
if v is None: errs.append("W3: no verdict step runs bin/nightly-ticket.sh")
else:
    if "!cancelled()" not in str(v.get("if", "")): errs.append(f"W3: a failed mint must not skip the judge: if: {v.get('if')!r}")
    open(sys.argv[2], "w").write(str(v.get("run", "")))
print("\n".join(errs))
PY
)
if [ -n "$W" ]; then while IFS= read -r l; do bad "$l"; done <<<"$W"; else ok; fi

# ── W4 ──────────────────────────────────────────────────────────────────────
if [ -s "$T/run.sh" ]; then
  grep -qF '[ -n "$NT_APP_TOKEN" ]' "$T/run.sh" && ok || bad "W4: the filer call must be guarded by [ -n \"\$NT_APP_TOKEN\" ]"
  mkdir -p "$T/w/bin" "$T/rt/verdicts"
  printf '#!/bin/bash\nexit 1\n' > "$T/w/bin/ci-verdicts.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$CALLS"\nexit 0\n' > "$T/w/bin/nightly-ticket.sh"
  chmod +x "$T/w/bin/ci-verdicts.sh" "$T/w/bin/nightly-ticket.sh"
  wrun() { # wrun <app-token>
    rm -f "$T/calls"; : > "$T/summary"
    OUT=$(cd "$T/w" && env CALLS="$T/calls" RUNNER_TEMP="$T/rt" GITHUB_STEP_SUMMARY="$T/summary" GITHUB_REF=refs/heads/main \
            PLAN_RESULT=success PLAN_N=1 PLAN_COUNT=1 PLAN_SUMMARY=plan STRICT_RESULT=success LINTS_RESULT=success \
            NT_ON_MAIN=true NT_APP_TOKEN="$1" bash "$T/run.sh" 2>&1); RC=$?
  }
  wrun ""
  [ "$RC" = 1 ] && ok || bad "W4: a red night exits 1 (got $RC: $OUT)"
  [ ! -s "$T/calls" ] && ok || bad "W4: with no App token the filer must not run: $(cat "$T/calls")"
  grep -qF '::error::the nightly run is red and no App token was minted: no ticket filed (BH-8272)' <<<"$OUT" && ok \
    || bad "W4: the no-token branch prints its ::error::: $OUT"
  wrun app-tok-fixture
  [ "$RC" = 1 ] && ok || bad "W4: a red night with the token still exits 1 (got $RC)"
  [ "$(grep -c . "$T/calls" 2>/dev/null)" = 1 ] && ok || bad "W4: with the token the filer runs once: $(cat "$T/calls" 2>/dev/null)"
  grep -q 'no App token was minted' <<<"$OUT" && bad "W4: no ::error:: when the token is present" || ok
fi

echo "nightly-ticket-workflow: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
