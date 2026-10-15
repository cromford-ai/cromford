#!/bin/bash
# tests/ci-plan-stacked-base.bh-5795-test.sh — BH-5795: CI must not skip every
# test shard on a PR head that the merge queue does not test as it stands.
#
# WHY. 22 review BLOCKs (#4189..#5395) said "no suite ran on this head". The
# plan job ran only on a merge-queue batch, the `full` label, a dispatch and a
# push, so a PR stacked on a ticket/** base skipped every shard, and a DIRTY
# head (GitHub runs no pull_request workflow on a conflicting PR) had no way to
# run its impact set at all. Now:
#
#   C1  a stacked base: the impact set is diffed against main's merge-base, not
#       the parent branch, so the parent's change is tested too and main's later
#       change is not; one or more shards
#   C2  a base on main: TI_BASE is untouched
#   C3  a stacked base whose main cannot be read: no base is handed on (the full
#       corpus), and the reason says why
#   C4  a dispatch with scope=impact: the head's impact set against main
#   C5  a dispatch with no scope: the full corpus, as before
#   C6  a shard re-plan (--expect-n) agrees on a stacked base
#   Z1  0 suites on a PR that changes bin/x.sh: rc != 0, and the error names
#       the path and the 0 shards
#   W1  the workflow plans a PR whose base is not main
#   W2  workflow_dispatch takes scope (full|impact), full by default
#   W3  the plan step and the shard re-plan step both pass CI_BASE_REF and
#       CI_DISPATCH_SCOPE, so they plan the same list
#
# bin/ci-plan.sh runs from a scratch git repo (its ROOT), with a fake
# bin/test-impact.sh that maps each changed bin/<n>.sh to tests/<n>-test.sh
# over `git diff TI_BASE HEAD`, the way the real ci-select reads a range.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# ── the fixture repo: main M0, parent ticket/parent (+bin/y.sh), the PR on top
# (+bin/x.sh, and a doc), and main moving on afterwards (+bin/z.sh).
R="$T/repo"; mkdir -p "$R/bin/lib" "$R/tests"
scratch_install_closure bin/ci-plan.sh "$R" >/dev/null || { echo "FAIL: closure of bin/ci-plan.sh"; exit 1; }
git -C "$R" init -q -b main
echo base > "$R/README"; git -C "$R" add -A; git -C "$R" commit -qm M0
M0=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -qb ticket/parent
echo y > "$R/bin/y.sh"; git -C "$R" add -A; git -C "$R" commit -qm parent
PARENT=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -qb ticket/child
echo x > "$R/bin/x.sh"; echo doc > "$R/NOTES"; git -C "$R" add -A; git -C "$R" commit -qm child
git -C "$R" checkout -q main
echo z > "$R/bin/z.sh"; git -C "$R" add -A; git -C "$R" commit -qm "main moves on"
git -C "$R" checkout -q ticket/child

cat > "$T/fake-impact.sh" <<'FAKE'
#!/bin/bash
printf 'TI_EVENT=%s TI_BASE=%s\n' "${TI_EVENT:-}" "${TI_BASE:-}" >> "$FAKE_SINK"
OUT=""; while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift ;; esac; shift; done
ALL=$(printf 'tests/%s-test.sh\n' a b c d e x y z)
if [ -z "${TI_BASE:-}" ]; then
  SEL="$ALL"; WHY="full: no base sha to diff against"
elif [ -n "${FAKE_EMPTY:-}" ]; then
  SEL=""; WHY="selected: 1 changed path(s)"
else
  SEL=$(git -C "$FAKE_ROOT" diff --name-only "$TI_BASE" HEAD | sed -n 's|^bin/\(.*\)\.sh$|tests/\1-test.sh|p')
  WHY="selected: $(git -C "$FAKE_ROOT" diff --name-only "$TI_BASE" HEAD | grep -c .) changed path(s)"
fi
echo "impact: $(printf '%s' "$SEL" | grep -c .) of 8 suites ($WHY)" >&2
if [ -n "$OUT" ]; then printf '%s' "$SEL" | grep . > "$OUT"; else printf '%s\n' "$SEL"; fi
exit 0
FAKE
chmod +x "$T/fake-impact.sh"

plan() { # plan <event> [VAR=value ...] [-- args] — sets RC, OUT, GO, SINK
  local ev="$1"; shift
  : > "$T/sink"; rm -f "$T/go" "$T/list"
  OUT=$(cd "$R" && env CI_EVENT="$ev" CI_PLAN_IMPACT="$T/fake-impact.sh" FAKE_SINK="$T/sink" FAKE_ROOT="$R" \
          CI_PLAN_MAIN_REF=main TI_BASE="$PARENT" TI_PR_HEAD_REF=ticket/child \
          GITHUB_OUTPUT="$T/go" "$@" "$R/bin/ci-plan.sh" --out "$T/list" ${PLAN_ARGS:-} 2>&1); RC=$?
  GO=$(cat "$T/go" 2>/dev/null); SINK=$(cat "$T/sink" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
lists() { grep -qxF "$1" "$T/list" 2>/dev/null; }

# ── C1. a stacked base: diffed against main, not the parent
plan pull_request CI_BASE_REF=ticket/parent
[ "$RC" -eq 0 ] && ok || bad "C1: a stacked PR must plan cleanly (rc=$RC) [$OUT]"
has "TI_BASE=$M0" "$SINK" && ok || bad "C1: the impact range must start at main's merge-base ${M0:0:8}, not the parent ${PARENT:0:8} [$SINK]"
lists tests/x-test.sh && ok || bad "C1: the PR's own bin/x.sh must be selected [$OUT]"
lists tests/y-test.sh && ok || bad "C1: the parent's bin/y.sh is not on main yet, so it must be selected too [$OUT]"
lists tests/z-test.sh && bad "C1: main's own later change (bin/z.sh) must not be selected" || ok
n=$(out n); [ "${n:-0}" -ge 1 ] 2>/dev/null && ok || bad "C1: a stacked PR that changes bin/ must plan one or more shards, n='$n'"
[ "$(out mode)" = selected ] && ok || bad "C1: mode must be selected, got '$(out mode)'"
has "ticket/parent" "$(out summary)" && ok || bad "C1: the summary must say the base is not main: '$(out summary)'"

# ── C2. a base on main: TI_BASE untouched
plan pull_request CI_BASE_REF=main TI_BASE="$M0"
{ [ "$RC" -eq 0 ] && has "TI_BASE=$M0" "$SINK"; } && ok || bad "C2: a base on main keeps its own TI_BASE (rc=$RC) [$SINK]"
plan pull_request CI_BASE_REF=main
has "TI_BASE=$PARENT" "$SINK" && ok || bad "C2: a base on main must never be rewritten [$SINK]"

# ── C3. a stacked base whose main cannot be read: no base handed on, said
plan pull_request CI_BASE_REF=ticket/parent CI_PLAN_MAIN_REF=refs/heads/no-such-main
[ "$RC" -eq 0 ] && ok || bad "C3: an unreadable main must still plan (rc=$RC) [$OUT]"
has "TI_BASE= " "$SINK " && ok || bad "C3: with no merge-base the plan must hand on no base (the full corpus) [$SINK]"
[ "$(grep -c . "$T/list" 2>/dev/null)" = 8 ] && ok || bad "C3: no base must run the full corpus, got $(grep -c . "$T/list" 2>/dev/null)"
has "merge-base" "$OUT$(out summary)" && ok || bad "C3: the plan must say main's merge-base could not be read [$OUT]"

# ── C4. a dispatch with scope=impact: the head's own impact set
plan workflow_dispatch CI_DISPATCH_SCOPE=impact TI_BASE=
[ "$RC" -eq 0 ] && ok || bad "C4: an impact dispatch must plan cleanly (rc=$RC) [$OUT]"
has "TI_EVENT=pull_request TI_BASE=$M0" "$SINK" && ok || bad "C4: an impact dispatch selects against main's merge-base [$SINK]"
{ lists tests/x-test.sh && lists tests/y-test.sh && ! lists tests/z-test.sh; } && ok || bad "C4: the dispatch must run the head's impact set [$(tr '\n' ' ' < "$T/list")]"
[ "$(out mode)" = selected ] && ok || bad "C4: mode must be selected, got '$(out mode)'"

# ── C5. a dispatch with no scope: the full corpus, as before
plan workflow_dispatch TI_BASE=
{ [ "$RC" -eq 0 ] && [ "$(out mode)" = full ]; } && ok || bad "C5: a plain dispatch is the full corpus (rc=$RC mode=$(out mode)) [$OUT]"

# ── C6. a shard re-plans with --expect-n and agrees on a stacked base
# BH-6801: the shard reads the plan job's merge-base pin, so both runs pass it.
plan pull_request CI_BASE_REF=ticket/parent CI_PLAN_MAIN_BASE_FILE="$T/main-base.txt"; N1=$(out n)
PLAN_ARGS="--expect-n ${N1:-x}" plan pull_request CI_BASE_REF=ticket/parent CI_PLAN_MAIN_BASE_FILE="$T/main-base.txt"
[ "$RC" -eq 0 ] && ok || bad "C6: the shard's re-plan must agree with the plan job (n=$N1, rc=$RC) [$OUT]"

# ── Z1. 0 suites on a PR that changes bin/: an error that names the path
plan pull_request CI_BASE_REF=ticket/parent FAKE_EMPTY=1
[ "$RC" -ne 0 ] && ok || bad "Z1: 0 shards on a PR that changes bin/ must not pass (rc=$RC)"
has "bin/x.sh" "$OUT" && ok || bad "Z1: the error must name the changed bin/ path [$OUT]"
has "0 shards" "$OUT" && ok || bad "Z1: the error must say 0 shards [$OUT]"
[ -z "$(out n)" ] && ok || bad "Z1: no shard count may be published, got n=$(out n)"

# ── W1-W3. the workflow
WF="$DIR/.github/workflows/harness-ci.yml"
if python3 -c 'import yaml' 2>/dev/null; then
  WOUT=$(python3 - "$WF" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
jobs = wf.get("jobs") or {}
on = wf.get("on", wf.get(True)) or {}
fails = []
pcond = str((jobs.get("plan") or {}).get("if", ""))
if "github.base_ref != 'main'" not in pcond:
    fails.append(f"W1: the plan job must run on a PR whose base is not main: {pcond!r}")
inp = ((on.get("workflow_dispatch") or {}).get("inputs") or {}).get("scope") or {}
if sorted(inp.get("options") or []) != ["full", "impact"] or inp.get("default") != "full":
    fails.append(f"W2: workflow_dispatch must take scope full|impact, default full: {inp!r}")
def plan_steps(job):
    return [s for s in (jobs.get(job) or {}).get("steps") or [] if "bin/ci-plan.sh" in str(s.get("run", ""))]
for job in ("plan", "tests-shard"):
    steps = plan_steps(job)
    if not steps:
        fails.append(f"W3: {job} has no bin/ci-plan.sh step"); continue
    env = steps[0].get("env") or {}
    for k, want in (("CI_BASE_REF", "github.base_ref"), ("CI_DISPATCH_SCOPE", "inputs.scope")):
        if want not in str(env.get(k, "")):
            fails.append(f"W3: the {job} plan step must pass {k} from {want} (got {env.get(k)!r})")
print("\n".join(fails))
PY
)
  if [ -z "$WOUT" ]; then ok; else while IFS= read -r l; do bad "$l"; done <<<"$WOUT"; fi
else
  [ -n "${CI:-}" ] && bad "PyYAML missing on a CI runner" || echo "ci-plan-stacked-base: PyYAML missing — W1-W3 skipped on this dev machine"
fi

echo "ci-plan-stacked-base.bh-5795: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
