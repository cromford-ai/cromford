#!/bin/bash
# tests/ci-plan-pinned-base.bh-6801-test.sh — BH-6801: a stacked PR's shards
# take the plan job's main merge-base, never their own.
#
# WHY. The plan job and every shard check out the repo separately, so each
# reads origin/main at its own fetch time. HEAD is fixed; origin/main is not.
# On #6776 main took the parent's commits between the two fetches: the plan
# job diffed against e961ff7a (2269 suites, 8 shards), the shards against
# 7e4e6c0f (376 suites, 4 shards), and --expect-n refused every shard. Now the
# plan job writes the merge-base it used to CI_PLAN_MAIN_BASE_FILE (inside the
# ci-durations artifact) and a shard reads it:
#
#   P1  the plan job writes main_base=<M0> and base_ref=ticket/parent; n=2
#   P2  main moves on; the shard still diffs against M0, plans the same list,
#       agrees on n, and says "(pinned by the plan job)"
#   P3  control: after the move, a fresh plan picks the parent (n=1), so P2
#       is a real test of the pin
#   R1  a pin with no main_base= line: rc 1, the message names BH-6801
#   R2  CI_PLAN_MAIN_BASE_FILE unset on a stacked shard: rc 1
#   R3  the file is missing: rc 1, the message names the path
#   R4  main_base=abc123 (not a 40-hex sha): rc 1
#   R5  a 40-hex sha this checkout does not hold: rc 1, names the sha
#   R6  base_ref=ticket/other against CI_BASE_REF=ticket/parent: rc 1
#   R7  a sha in the checkout that is not an ancestor of HEAD: rc 1
#   A2  no merge-base in the plan job: main_base=-, the shard runs the full
#       corpus too and agrees
#   D1  an impact dispatch: base_ref=-, and the shard agrees after main moves
#   O1  a batch and a PR on main never write the file
#   O2  a PR-on-main shard never reads it (no file, rc 0)
#   W0  an unwritable pin path: rc 2, no n= published
#   W1  the workflow: both ci-plan steps set CI_PLAN_MAIN_BASE_FILE inside the
#       ci-durations artifact, and the shard keeps --expect-n "$PLAN_N"
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null

# ── the fixture repo: main M0, ticket/parent (+bin/y.sh), the PR ticket/child
# on top (+bin/x.sh). advance_main later moves main past the parent.
R="$T/repo"; mkdir -p "$R/bin/lib" "$R/tests"
scratch_install_closure bin/ci-plan.sh "$R" >/dev/null || { echo "FAIL: closure of bin/ci-plan.sh"; exit 1; }
git -C "$R" init -q -b main
echo base > "$R/README"; git -C "$R" add -A; git -C "$R" commit -qm M0
M0=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -qb ticket/parent
echo y > "$R/bin/y.sh"; git -C "$R" add -A; git -C "$R" commit -qm parent
PARENT=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -qb ticket/child
echo x > "$R/bin/x.sh"; git -C "$R" add -A; git -C "$R" commit -qm child
advance_main() { # main takes the parent, then one more commit
  git -C "$R" checkout -q main && git -C "$R" merge -q --ff-only ticket/parent \
    && echo z > "$R/bin/z.sh" && git -C "$R" add -A && git -C "$R" commit -qm "main moves on" \
    && git -C "$R" checkout -q ticket/child
}

cat > "$T/fake-impact.sh" <<'FAKE'
#!/bin/bash
printf 'TI_EVENT=%s TI_BASE=%s\n' "${TI_EVENT:-}" "${TI_BASE:-}" >> "$FAKE_SINK"
OUT=""; while [ $# -gt 0 ]; do case "$1" in --out) OUT="$2"; shift ;; esac; shift; done
ALL=$(printf 'tests/%s-test.sh\n' a b c d e x y z)
if [ -z "${TI_BASE:-}" ]; then
  SEL="$ALL"; WHY="full: no base sha to diff against"
else
  SEL=$(git -C "$FAKE_ROOT" diff --name-only "$TI_BASE" HEAD | sed -n 's|^bin/\(.*\)\.sh$|tests/\1-test.sh|p')
  WHY="selected: $(git -C "$FAKE_ROOT" diff --name-only "$TI_BASE" HEAD | grep -c .) changed path(s)"
fi
echo "impact: $(printf '%s' "$SEL" | grep -c .) of 8 suites ($WHY)" >&2
if [ -n "$OUT" ]; then printf '%s' "$SEL" | grep . > "$OUT"; else printf '%s\n' "$SEL"; fi
exit 0
FAKE
chmod +x "$T/fake-impact.sh"

# plan <event> [VAR=value ...] — sets RC, OUT, ERR, GO, SINK. PLAN_ARGS adds
# arguments (--expect-n). CI_SUITES_PER_SHARD=1, so n is the suite count and a
# moved base changes n.
plan() {
  local ev="$1"; shift
  : > "$T/sink"; rm -f "$T/go" "$T/list"
  OUT=$(cd "$R" && env CI_EVENT="$ev" CI_PLAN_IMPACT="$T/fake-impact.sh" FAKE_SINK="$T/sink" FAKE_ROOT="$R" \
          CI_PLAN_MAIN_REF=main TI_BASE="$PARENT" TI_PR_HEAD_REF=ticket/child CI_SUITES_PER_SHARD=1 CI_MAX_SHARDS=20 \
          GITHUB_OUTPUT="$T/go" "$@" "$R/bin/ci-plan.sh" --out "$T/list" ${PLAN_ARGS:-} 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err"); GO=$(cat "$T/go" 2>/dev/null); SINK=$(cat "$T/sink" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
key() { sed -n "s/^$1=//p" "$2" 2>/dev/null | tail -1; }
MSG="no main merge-base from the plan job"
STACK="CI_BASE_REF=ticket/parent"

# ── P1. the plan job writes the pin
plan pull_request "$STACK" CI_PLAN_MAIN_BASE_FILE="$T/mb"
[ "$RC" -eq 0 ] && ok || bad "P1: the plan must succeed (rc=$RC) [$OUT $ERR]"
[ "$(key main_base "$T/mb")" = "$M0" ] && ok || bad "P1: the pin must hold main_base=$M0 [$(cat "$T/mb" 2>&1)]"
[ "$(key base_ref "$T/mb")" = ticket/parent ] && ok || bad "P1: the pin must hold base_ref=ticket/parent [$(cat "$T/mb" 2>&1)]"
[ "$(out n)" = 2 ] && ok || bad "P1: n must be 2 (x, y), got '$(out n)'"
cp "$T/list" "$T/plan-list" 2>/dev/null
has "(pinned by the plan job)" "$OUT" && bad "P1: the plan job itself must not say it was pinned [$OUT]" || ok

# The other plan-job pins, before main moves.
plan pull_request "$STACK" CI_PLAN_MAIN_REF=refs/heads/no-such-main CI_PLAN_MAIN_BASE_FILE="$T/mb-a"
A2N=$(out n)
{ [ "$RC" -eq 0 ] && [ "$(key main_base "$T/mb-a")" = - ] && [ "$(key base_ref "$T/mb-a")" = ticket/parent ]; } && ok \
  || bad "A2: no merge-base must write main_base=- (rc=$RC) [$(cat "$T/mb-a" 2>&1)]"
plan workflow_dispatch CI_DISPATCH_SCOPE=impact TI_BASE= CI_PLAN_MAIN_BASE_FILE="$T/mb-d"
D1N=$(out n)
{ [ "$RC" -eq 0 ] && [ "$(key main_base "$T/mb-d")" = "$M0" ] && [ "$(key base_ref "$T/mb-d")" = - ]; } && ok \
  || bad "D1: an impact dispatch must write main_base=$M0 and base_ref=- (rc=$RC) [$(cat "$T/mb-d" 2>&1)]"

# ── O1. a batch and a PR on main never write the pin
plan pull_request CI_BASE_REF=main TI_PR_HEAD_REF=mergify/merge-queue/x TI_PR_LABELS=full CI_PLAN_MAIN_BASE_FILE="$T/mb-o1"
[ -e "$T/mb-o1" ] && bad "O1: a merge-queue batch must not write the pin" || ok
plan pull_request CI_BASE_REF=main CI_PLAN_MAIN_BASE_FILE="$T/mb-o2"
{ [ "$RC" -eq 0 ] && [ ! -e "$T/mb-o2" ]; } && ok || bad "O1: a PR on main must not write the pin (rc=$RC)"

# ── W0. an unwritable pin path: rc 2, no shard count published
plan pull_request "$STACK" CI_PLAN_MAIN_BASE_FILE="$T/no-dir/mb"
[ "$RC" -eq 2 ] && ok || bad "W0: an unwritable pin must be rc 2, got $RC [$ERR]"
[ -z "$(out n)" ] && ok || bad "W0: no n= may be published, got n=$(out n)"

# ── main moves on between the plan job and the shards
advance_main || { echo "FAIL: advance_main"; exit 1; }

# ── P3. control: a fresh plan now picks the parent, n=1
plan pull_request "$STACK"
{ [ "$RC" -eq 0 ] && has "TI_BASE=$PARENT" "$SINK" && [ "$(out n)" = 1 ]; } && ok \
  || bad "P3: after main moves, a fresh plan must pick the parent and n=1 (rc=$RC n=$(out n)) [$SINK]"

# ── P2. the shard takes the plan job's pin and agrees
PLAN_ARGS="--expect-n 2" plan pull_request "$STACK" CI_PLAN_MAIN_BASE_FILE="$T/mb"
[ "$RC" -eq 0 ] && ok || bad "P2: the shard must agree with the plan job (rc=$RC) [$ERR]"
has "TI_BASE=$M0" "$SINK" && ok || bad "P2: the shard must diff against the pinned ${M0:0:8} [$SINK]"
cmp -s "$T/list" "$T/plan-list" && ok || bad "P2: the shard list must equal the plan list [$(tr '\n' ' ' < "$T/list" 2>&1)]"
has "${M0:0:8} (pinned by the plan job)" "$OUT" && ok || bad "P2: the shard must say the base was pinned [$OUT]"

# ── A2. the shard takes main_base=- and runs the full corpus too
PLAN_ARGS="--expect-n ${A2N:-x}" plan pull_request "$STACK" CI_PLAN_MAIN_BASE_FILE="$T/mb-a"
[ "$RC" -eq 0 ] && ok || bad "A2: the shard must agree on main_base=- (rc=$RC) [$ERR]"
has "TI_BASE= " "$SINK " && ok || bad "A2: the shard must hand on no base [$SINK]"
[ "$(grep -c . "$T/list" 2>/dev/null)" = 8 ] && ok || bad "A2: the shard must run 8 suites, got $(grep -c . "$T/list" 2>/dev/null)"

# ── D1. the impact dispatch shard agrees after main moves
PLAN_ARGS="--expect-n ${D1N:-x}" plan workflow_dispatch CI_DISPATCH_SCOPE=impact TI_BASE= CI_PLAN_MAIN_BASE_FILE="$T/mb-d"
{ [ "$RC" -eq 0 ] && has "TI_BASE=$M0" "$SINK"; } && ok || bad "D1: the dispatch shard must take the pin (rc=$RC) [$SINK $ERR]"

# ── R1-R7. a shard with no usable pin refuses, and never recomputes
refuses() { # refuses <case> <want-in-stderr> [VAR=value ...]
  local c="$1" want="$2"; shift 2
  PLAN_ARGS="--expect-n 2" plan pull_request "$STACK" "$@"
  [ "$RC" -eq 1 ] && ok || bad "$c: rc must be 1, got $RC [$ERR]"
  { has "$want" "$ERR" && has BH-6801 "$ERR"; } && ok || bad "$c: stderr must name '$want' and BH-6801 [$ERR]"
  [ -z "$(out n)" ] && ok || bad "$c: no n= may be published, got n=$(out n)"
  has "TI_BASE=$PARENT" "$SINK" && bad "$c: the shard recomputed main's merge-base [$SINK]" || ok
}
printf 'base_ref=ticket/parent\n' > "$T/r1"
refuses R1 "$MSG" CI_PLAN_MAIN_BASE_FILE="$T/r1"
refuses R2 "$MSG (CI_PLAN_MAIN_BASE_FILE unset)"
refuses R3 "$MSG ($T/absent)" CI_PLAN_MAIN_BASE_FILE="$T/absent"
printf 'main_base=abc123\nbase_ref=ticket/parent\n' > "$T/r4"
refuses R4 "$MSG" CI_PLAN_MAIN_BASE_FILE="$T/r4"
printf 'main_base=0123456789abcdef0123456789abcdef01234567\nbase_ref=ticket/parent\n' > "$T/r5"
refuses R5 "0123456789abcdef0123456789abcdef01234567 is not a commit in this checkout" CI_PLAN_MAIN_BASE_FILE="$T/r5"
printf 'main_base=%s\nbase_ref=ticket/other\n' "$M0" > "$T/r6"
refuses R6 "ticket/other" CI_PLAN_MAIN_BASE_FILE="$T/r6"
has "ticket/parent" "$ERR" && ok || bad "R6: the message must name the shard's base too [$ERR]"
printf 'main_base=%s\nbase_ref=ticket/parent\n' "$(git -C "$R" rev-parse main)" > "$T/r7"
refuses R7 "not an ancestor" CI_PLAN_MAIN_BASE_FILE="$T/r7"

# ── O2. a PR-on-main shard never reads the pin
PLAN_ARGS="--expect-n 1" plan pull_request CI_BASE_REF=main CI_PLAN_MAIN_BASE_FILE="$T/absent"
[ "$RC" -eq 0 ] && ok || bad "O2: a PR-on-main shard must not read the pin (rc=$RC) [$ERR]"

# ── W1. the workflow
WF="$DIR/.github/workflows/harness-ci.yml"
if python3 -c 'import yaml' 2>/dev/null; then
  WOUT=$(python3 - "$WF" <<'PY'
import sys, yaml
wf = yaml.safe_load(open(sys.argv[1]))
jobs = wf.get("jobs") or {}
fails = []
want = "${{ runner.temp }}/ci-durations/main-base.txt"
def plan_steps(job):
    return [s for s in (jobs.get(job) or {}).get("steps") or [] if "bin/ci-plan.sh" in str(s.get("run", ""))]
for job in ("plan", "tests-shard"):
    steps = plan_steps(job)
    if not steps:
        fails.append(f"W1: {job} has no bin/ci-plan.sh step"); continue
    got = (steps[0].get("env") or {}).get("CI_PLAN_MAIN_BASE_FILE")
    if got != want:
        fails.append(f"W1: the {job} plan step must set CI_PLAN_MAIN_BASE_FILE to {want} (got {got!r})")
shard = plan_steps("tests-shard")
if shard and '--expect-n "$PLAN_N"' not in str(shard[0].get("run", "")):
    fails.append("W1: the shard re-plan must keep --expect-n \"$PLAN_N\"")
ups = [s for s in (jobs.get("plan") or {}).get("steps") or []
       if "upload-artifact" in str(s.get("uses", "")) and (s.get("with") or {}).get("name") == "ci-durations"]
if not ups or str(ups[0]["with"].get("path", "")).rstrip("/") != "${{ runner.temp }}/ci-durations":
    fails.append(f"W1: the plan job must upload {'${{ runner.temp }}/ci-durations/'} as ci-durations")
print("\n".join(fails))
PY
)
  if [ -z "$WOUT" ]; then ok; else while IFS= read -r l; do bad "$l"; done <<<"$WOUT"; fi
else
  [ -n "${CI:-}" ] && bad "PyYAML missing on a CI runner" || echo "ci-plan-pinned-base: PyYAML missing — W1 skipped on this dev machine"
fi

echo "ci-plan-pinned-base.bh-6801: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
