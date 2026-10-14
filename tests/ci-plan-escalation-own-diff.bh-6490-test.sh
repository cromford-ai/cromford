#!/bin/bash
# tests/ci-plan-escalation-own-diff.bh-6490-test.sh — a STACKED merge-queue
# batch escalates to the full corpus only on its OWN PRs' diff (BH-6490).
#
# WHY. A Mergify draft stacked on a lower batch carries the lower batch's diff.
# bin/ci-plan.sh scanned the whole TI_BASE..HEAD diff for escalation, so one PR
# that touched .mergify.yml made every batch above it run the corpus (3 of 8
# full batches on 2026-10-13). The draft body's `checking_base_sha` is the tip
# after the PRs queued ahead; the batch's own diff is checking_base_sha..HEAD.
# Only the full-corpus trigger narrows: selection still reads the full diff.
#
# The REAL bin/ci-plan.sh and its lib run in a scratch git repo (M -> A -> B)
# with the real rules file; a stub selector logs every call.
#
#   O1  A (.mergify.yml) escalates; B (bin/foo.sh) stacked on A is batch-selected
#   O2  an own CI path (.github/workflows/x.yml) still escalates
#   O3  an inherited test-impact full answer is re-judged on the own diff; the
#       list is the own select plus the full diff's --map-only select
#   O4  a-g: no body, two shas, an unrelated sha, a base not below the sha, the
#       sha is TI_BASE, an empty own diff, a sha not below HEAD -> today's
#       escalation, own_base=-, and a refused sha is said on its own
#       `ci-plan: own diff: off (<why>)` line
#   O5  the own select fails -> rc 2, no shard count published
#   O6  an inherited rules-file row delete does not escalate B; an inherited
#       add-only spa row still sets spa=1
#   O7  plan -> shard round trip through own_base: same list, --expect-n rc 0;
#       CI_PLAN_OWN_BASE=- with a stacked body is today's escalation
#   O8  own_base=- on an ordinary PR, a corpus=0 push and --tier nightly
#   M1  the cbe loop reading $CH again turns O1 red (non-vacuity)
#   W1-W3 the workflow passes own_base from the plan job to the shard re-plan
#   R1-R4 bin/ci-plan-own-diff-replay.sh over a stubbed GitHub: the row classes,
#       the summary counts, an unreadable compare and PR list, shard minutes
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
TSV="$DIR/catalog/ci-batch-escalate.tsv"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# ── The scratch repo: the real planner closure and rules, a stub selector.
G="$T/repo"; mkdir -p "$G/catalog" "$G/bin"
scratch_install_closure bin/ci-plan.sh "$G" > /dev/null || { echo "FAIL: cannot install bin/ci-plan.sh's closure"; exit 1; }
[ -f "$G/bin/lib/ci-batch-escalate.sh" ] || { echo "FAIL: the closure has no bin/lib/ci-batch-escalate.sh"; exit 1; }
cp "$TSV" "$G/catalog/ci-batch-escalate.tsv"
# The stub: `select --changed F [--map-only]` maps x/name.ext -> tests/name-test.sh
# plus tests/always-test.sh; ^.github/ and ^bin/test-impact are infra, unknown/*
# is unknown reach; a full answer is all 50 suites. Every call is logged.
cat > "$G/impact.sh" <<'EOF'
#!/bin/bash
cmd="$1"; shift; changed=""; out=""; mo=0
while [ $# -gt 0 ]; do
  case "$1" in --changed) changed="$2"; shift ;; --out) out="$2"; shift ;; --map-only) mo=1 ;; esac; shift
done
n=$(( $(cat "$STUB_SEEN.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STUB_SEEN.n"
printf '%s mo=%s named=%s changed=%s\n' "$cmd" "$mo" "${TI_NAMED_BASE:-}" "$(paste -sd, "$changed" 2>/dev/null)" >> "$STUB_SEEN.log"
# A failing call still prints an impact line: only its exit code says it failed.
[ "${STUB_FAIL_ON:-0}" != "$n" ] || { echo "impact: 2 of 50 suites (selected: 1 changed path(s))" >&2; exit 1; }
all() { for i in $(seq -w 0 49); do echo "tests/s$i-test.sh"; done > "$out"; }
if [ "$cmd" != select ]; then all; echo "impact: 50 of 50 suites (full: corpus)" >&2; exit 0; fi
full=""; : > "$out.m"
while IFS= read -r p; do
  [ -n "$p" ] || continue
  if [ -z "$full" ]; then
    case "$p" in
      .github/*|bin/test-impact*) full="full: infra change ($p)" ;;
      unknown/*) full="full: unknown reach ($p)" ;;
    esac
  fi
  b="${p##*/}"; b="${b#.}"; echo "tests/${b%%.*}-test.sh" >> "$out.m"
done < "$changed"
if [ -n "$full" ] && [ "$mo" = 0 ]; then all; echo "impact: 50 of 50 suites ($full)" >&2; exit 0; fi
{ cat "$out.m"; echo tests/always-test.sh; } | LC_ALL=C sort -u > "$out"; rm -f "$out.m"
r="${full:+map-only: CI runs the corpus, $full}"
echo "impact: $(grep -c . "$out") of 50 suites (${r:-selected: $(grep -c . "$changed") changed path(s)})" >&2
EOF
printf '#!/bin/bash\ncat\n' > "$G/tiers.sh"
chmod +x "$G/impact.sh" "$G/tiers.sh"
gcommit() { git -C "$G" add -A && git -C "$G" -c user.email=t@example.invalid -c user.name=t commit -qm "$1" --allow-empty; }
git -C "$G" init -q && gcommit base || { echo "FAIL: cannot commit the scratch base"; exit 1; }
M=$(git -C "$G" rev-parse HEAD)
echo "queue: {}" > "$G/.mergify.yml"; gcommit A; A=$(git -C "$G" rev-parse HEAD)
echo 'echo foo' > "$G/bin/foo.sh"; gcommit B; B=$(git -C "$G" rev-parse HEAD)

# body <sha>... — a Mergify-shaped draft body with one checking_base_sha line per sha
body() {
  printf 'This pull request has been created by Mergify to speculatively check the mergeability of #101.\n'
  printf 'You don'"'"'t need to do anything. Mergify will close this pull request automatically when it is complete.\n\n'
  printf '**Required conditions of queue** `default` **for merge:**\n\n'
  printf -- '- [ ] `check-success=Harness CI`\n\n**Required conditions to stay in the queue:**\n\n'
  printf '```yaml\n---\n'
  local s; for s in "$@"; do printf 'checking_base_sha: %s\n' "$s"; done
  printf 'pull_requests:\n  - number: 101\n    scopes: []\nprevious_failed_batches: []\n...\n\n```\n'
}

# gplan <head> [VAR=val ...] — the real planner at <head>, TI_BASE=$M; sets RC OUT GO
gplan() {
  local head="$1"; shift
  git -C "$G" checkout -q --detach "$head" || { bad "cannot check out $head"; return 1; }
  rm -f "$T/go" "$T/seen".* "$T/list"
  OUT=$(cd "$G" && env -u GITHUB_ACTIONS -u CI_PLAN_OWN_BASE -u CI_PR_BODY CI_EVENT=pull_request \
          TI_PR_HEAD_REF=mergify/merge-queue/t TI_BASE="$M" CI_PLAN_ESCALATION=- TI_PR_LABELS= CI_QUARANTINE= \
          CI_PLAN_IMPACT="$G/impact.sh" CI_PLAN_TIERS="$G/tiers.sh" STUB_SEEN="$T/seen" GITHUB_OUTPUT="$T/go" \
          "$@" bash "${PLAN_SH:-bin/ci-plan.sh}" --out "$T/list" ${PLAN_ARGS:-} 2>&1); RC=$?
  GO=$(cat "$T/go" 2>/dev/null)
}
out() { printf '%s\n' "$GO" | sed -n "s/^$1=//p" | tail -1; }
st() { echo "rc=$RC mode=$(out mode) escalation='$(out escalation)' own_base=$(out own_base) summary='$(out summary)'"; }

# ── O1. A escalates on its own .mergify.yml; B, stacked on A, does not.
gplan "$A" CI_PR_BODY="$(body "$M")"
{ [ "$RC" = 0 ] && [ "$(out mode)" = full ] && [ "$(out escalation)" = "selection input: .mergify.yml" ] && [ "$(out own_base)" = - ]; } && ok \
  || bad "O1: A must escalate on .mergify.yml with own_base=- ($(st)) [$OUT]"
o1b() { # the B assertions, shared with M1
  gplan "$B" CI_PR_BODY="$(body "$A")"
  { [ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ] && [ "$(out escalation)" = - ] && [ "$(out own_base)" = "$A" ]; } && ok \
    || bad "O1: B stacked on A must be batch-selected with own_base=A ($(st)) [$OUT]"
  grep -qx tests/foo-test.sh "$T/list" 2>/dev/null && ok || bad "O1: B's list must carry tests/foo-test.sh"
  [ "$(grep -c . "$T/list" 2>/dev/null)" -lt 50 ] && ok || bad "O1: B's list must not be every suite"
}
o1b
# Selection still reads the full stacked diff: the inherited path's suite runs.
grep -qx tests/mergify-test.sh "$T/list" 2>/dev/null && ok || bad "O1: the selection must still read the full diff (tests/mergify-test.sh missing)"
has "selected: 2 changed path(s)" "$(out summary)" && ok || bad "O1: the selection must be over both paths: '$(out summary)'"

# ── O2. B2's own diff adds a workflow: it escalates on its own path.
git -C "$G" checkout -q --detach "$A"; mkdir -p "$G/.github/workflows"; echo 'on: push' > "$G/.github/workflows/x.yml"; gcommit B2
B2=$(git -C "$G" rev-parse HEAD)
gplan "$B2" CI_PR_BODY="$(body "$A")"
{ [ "$(out mode)" = full ] && [ "$(out escalation)" = "selection input: .github/workflows/x.yml" ]; } && ok \
  || bad "O2: an own CI path must escalate on that path ($(st)) [$OUT]"

# ── O3. A3 touches bin/test-impact.sh (an escalate row AND test-impact infra).
git -C "$G" checkout -q --detach "$M"; echo '# x' > "$G/bin/test-impact.sh"; gcommit A3; A3=$(git -C "$G" rev-parse HEAD)
echo 'echo foo' > "$G/bin/foo.sh"; gcommit B3; B3=$(git -C "$G" rev-parse HEAD)
gplan "$B3" CI_PR_BODY="$(body "$A3")"
{ [ "$RC" = 0 ] && [ "$(out mode)" = batch-selected ] && [ "$(out escalation)" = - ] && [ "$(out own_base)" = "$A3" ]; } && ok \
  || bad "O3: an inherited infra path must not escalate B3 ($(st)) [$OUT]"
[ "$(grep -c '^select ' "$T/seen.log" 2>/dev/null)" = 3 ] && ok || bad "O3: three selects expected: $(cat "$T/seen.log" 2>/dev/null)"
sed -n 2p "$T/seen.log" | grep -qx "select mo=0 named=$A3 changed=bin/foo.sh" && ok \
  || bad "O3: the 2nd select must be the own diff against base A3: '$(sed -n 2p "$T/seen.log")'"
sed -n 3p "$T/seen.log" | grep -qx "select mo=1 named=$M changed=bin/foo.sh,bin/test-impact.sh" && ok \
  || bad "O3: the 3rd select must be the full diff --map-only against TI_BASE: '$(sed -n 3p "$T/seen.log")'"
printf 'tests/always-test.sh\ntests/foo-test.sh\ntests/test-impact-test.sh\n' > "$T/o3.want"
cmp -s "$T/o3.want" "$T/list" && ok || bad "O3: the list must be the union of both selects: $(paste -sd' ' "$T/list" 2>/dev/null)"
has "own diff: 1 of 2 paths, base ${A3:0:8}; inherited: bin/test-impact.sh" "$(out summary)" && ok \
  || bad "O3: the reason must name the own diff and the inherited trigger: '$(out summary)'"

# ── O4. Every doubt is today's escalation, and own_base=-.
# commit-tree needs an identity like gcommit: a CI image has no git user, and
# an empty sha turned O4c into a false FAIL.
O=$(git -C "$G" -c user.email=t@example.invalid -c user.name=t commit-tree "$(git -C "$G" rev-parse "$M^{tree}")" -m orphan)
[ -n "$O" ] || { echo "FAIL: cannot make the orphan commit"; exit 1; }
o4() { # o4 <tag> <want-off-note: why|0> [VAR=val ...]
  local tag="$1" off="$2"; shift 2
  gplan "$B" "$@"
  { [ "$RC" = 0 ] && [ "$(out mode)" = full ] && [ "$(out escalation)" = "selection input: .mergify.yml" ] && [ "$(out own_base)" = - ]; } && ok \
    || bad "O4$tag: B must escalate on .mergify.yml exactly as before ($(st)) [$OUT]"
  # The note is its own line: a full REASON stays `full: <escalation>`, which
  # bin/ci-batch-ledger.sh reads the escalation out of.
  if [ "$off" != 0 ]; then grep -qxF "ci-plan: own diff: off ($off)" <<<"$OUT" && ok || bad "O4$tag: the run must say 'own diff: off ($off)' [$OUT]"
  else has "own diff" "$OUT" && bad "O4$tag: no own-diff text expected [$OUT]" || ok; fi
  has "own diff" "$(out summary)" && bad "O4$tag: the full summary must not carry the own-diff note: '$(out summary)'" || ok
}
o4 a 0
o4 b "2 checking_base_sha values" CI_PR_BODY="$(body "$A" "$M")"
o4 c "${O:0:8} is not above the batch base ${M:0:8}" CI_PR_BODY="$(body "$O")"
o4 d "${A:0:8} is not above the batch base ${A3:0:8}" CI_PR_BODY="$(body "$A")" TI_BASE="$A3"
o4 e 0 CI_PR_BODY="$(body "$M")"
o4 f "the diff from ${B:0:8} is empty" CI_PR_BODY="$(body "$B")"
# A sha not below HEAD (a later commit) is refused too.
o4 g "${B3:0:8} is not below HEAD" CI_PR_BODY="$(body "$B3")" TI_BASE="$M"

# ── O5. The own select fails: rc 2 and no shard count.
gplan "$B3" CI_PR_BODY="$(body "$A3")" STUB_FAIL_ON=2
{ [ "$RC" = 2 ] && ! grep -q '^n=' <<<"$GO"; } && ok || bad "O5: a failed own select must be rc 2 with no n= ($(st)) [$OUT]"
gplan "$B3" CI_PR_BODY="$(body "$A3")" STUB_FAIL_ON=3
{ [ "$RC" = 2 ] && ! grep -q '^n=' <<<"$GO"; } && ok || bad "O5: a failed --map-only select must be rc 2 with no n= ($(st)) [$OUT]"

# ── O6. The rules file changed in the lower batch only.
git -C "$G" checkout -q --detach "$M"; sed -i '/^bin\/test-tiers.sh\t/d' "$G/catalog/ci-batch-escalate.tsv"; gcommit A6
A6=$(git -C "$G" rev-parse HEAD); echo 'echo foo' > "$G/bin/foo.sh"; gcommit B6; B6=$(git -C "$G" rev-parse HEAD)
gplan "$A6" CI_PR_BODY="$(body "$M")"
[ "$(out escalation)" = "selection input: catalog/ci-batch-escalate.tsv" ] && ok || bad "O6: A6's own row delete must escalate ($(st))"
gplan "$B6" CI_PR_BODY="$(body "$A6")"
{ [ "$(out mode)" = batch-selected ] && [ "$(out escalation)" = - ]; } && ok || bad "O6: an inherited row delete must not escalate B6 ($(st)) [$OUT]"
has "escalation rows added only" "$(out summary)" && bad "O6: an inherited diff gets no add-only note: '$(out summary)'" || ok
git -C "$G" checkout -q --detach "$M"; printf 'zz-bh6490-spa/\tspa\ta path the SPA reads (fixture)\n' >> "$G/catalog/ci-batch-escalate.tsv"; gcommit A6s
A6S=$(git -C "$G" rev-parse HEAD); echo 'echo foo' > "$G/bin/foo.sh"; gcommit B6s; B6S=$(git -C "$G" rev-parse HEAD)
gplan "$B6S" CI_PR_BODY="$(body "$A6S")"
{ [ "$(out mode)" = batch-selected ] && [ "$(out spa)" = 1 ] && [ "$(out worker)" = 0 ]; } && ok \
  || bad "O6: an inherited add-only spa row must keep spa=1 (spa=$(out spa) worker=$(out worker); $(st)) [$OUT]"

# ── O7. Plan job -> shard: the shard gets own_base, no body, and agrees.
for h in B B3; do
  head=${!h}; base=$A; [ "$h" = B3 ] && base=$A3
  gplan "$head" CI_PR_BODY="$(body "$base")"
  ob=$(out own_base); esc=$(out escalation); n=$(out n); cp "$T/list" "$T/o7.plan"
  [ "$ob" = "$base" ] && ok || bad "O7 $h: the plan must publish own_base=$base (got '$ob')"
  PLAN_ARGS="--expect-n $n" gplan "$head" CI_PLAN_OWN_BASE="$ob" CI_PLAN_ESCALATION="$esc"
  { [ "$RC" = 0 ] && cmp -s "$T/o7.plan" "$T/list" && [ "$(out own_base)" = "$ob" ]; } && ok \
    || bad "O7 $h: the shard must plan the same list with --expect-n $n ($(st)) [$OUT]"
done
gplan "$B" CI_PR_BODY="$(body "$A")" CI_PLAN_OWN_BASE=-
{ [ "$(out mode)" = full ] && [ "$(out escalation)" = "selection input: .mergify.yml" ] && [ "$(out own_base)" = - ]; } && ok \
  || bad "O7b: CI_PLAN_OWN_BASE=- must win over the body ($(st)) [$OUT]"

# ── O8. Paths that are not a batch publish own_base=-.
gplan "$B" TI_PR_HEAD_REF=feature/x CI_PR_BODY="$(body "$A")"
{ [ "$RC" = 0 ] && [ "$(out mode)" != batch-selected ] && [ "$(out own_base)" = - ]; } && ok || bad "O8: an ordinary PR must write own_base=- ($(st)) [$OUT]"
printf '#!/bin/bash\necho %s\n' "'{\"workflow_runs\":[]}'" > "$T/fake-gh"; chmod +x "$T/fake-gh"
gplan "$B" CI_EVENT=push CI_ACTOR='mergify[bot]' CI_REPO=o/r CI_PLAN_GH="$T/fake-gh" CI_SHA=s0 CI_PLAN_SETTLE_S=0 CI_PLAN_MAIN_HEAD_CMD="echo s9"
{ [ "$RC" = 0 ] && [ "$(out corpus)" = 0 ] && [ "$(out own_base)" = - ]; } && ok || bad "O8: a corpus=0 push must write own_base=- ($(st) corpus=$(out corpus)) [$OUT]"
PLAN_ARGS="--tier nightly" gplan "$B" CI_PR_BODY="$(body "$A")"
{ [ "$RC" = 0 ] && [ "$(out own_base)" = - ]; } && ok || bad "O8: --tier nightly must write own_base=- ($(st)) [$OUT]"

# ── M1. Non-vacuity: the cbe loop reading the full diff again turns O1 red.
if grep -q 'done < "\$OWNCH"' "$G/bin/ci-plan.sh"; then
  sed 's/done < "\$OWNCH"/done < "$CH"/' "$G/bin/ci-plan.sh" > "$G/bin/ci-plan-m1.sh"
  FAIL0=$FAIL; PASS0=$PASS
  PLAN_SH=bin/ci-plan-m1.sh o1b > /dev/null
  [ "$FAIL" -gt "$FAIL0" ] && { FAIL=$FAIL0; PASS=$((PASS0 + 1)); } || { FAIL=$FAIL0; PASS=$PASS0; bad "M1: the mutant must fail O1's B case"; }
  rm -f "$G/bin/ci-plan-m1.sh"
else
  bad "M1: bin/ci-plan.sh has no cbe loop over \$OWNCH to mutate"
fi

# ── W1-W3. The workflow wires own_base from the plan job to the shard re-plan.
if python3 -c 'import yaml' 2>/dev/null; then
  W=$(python3 - "$DIR/.github/workflows/harness-ci.yml" <<'PY'
import sys, yaml
jobs = yaml.safe_load(open(sys.argv[1])).get("jobs") or {}
outs = (jobs.get("plan") or {}).get("outputs") or {}
print("W1 ok" if outs.get("own_base") == "${{ steps.plan.outputs.own_base }}" else f"W1 plan outputs.own_base is {outs.get('own_base')!r}")
rp = [s for s in (jobs.get("tests-shard") or {}).get("steps", []) if "bin/ci-plan.sh" in str(s.get("run", ""))]
env = (rp[0].get("env") or {}) if len(rp) == 1 else {}
print("W2 ok" if env.get("CI_PLAN_OWN_BASE") == "${{ needs.plan.outputs.own_base }}" else f"W2 shard CI_PLAN_OWN_BASE is {env.get('CI_PLAN_OWN_BASE')!r} ({len(rp)} re-plan steps)")
print("W3 ok" if len(rp) == 1 and "CI_PR_BODY" not in env else "W3 the shard re-plan must not get CI_PR_BODY")
PY
)
  for w in W1 W2 W3; do grep -qx "$w ok" <<<"$W" && ok || bad "$(grep "^$w" <<<"$W")"; done
else
  [ -n "${CI:-}" ] && bad "W: PyYAML missing on a CI runner" || echo "ci-plan-escalation-own-diff: PyYAML missing — W1-W3 skipped on this dev machine"
fi

# ── R1-R4. The replay over a stubbed GitHub (three drafts).
REPLAY="$DIR/bin/ci-plan-own-diff-replay.sh"
FX="$T/fx"; mkdir -p "$FX"
S1=1111111111111111111111111111111111111111; H1=a111111111111111111111111111111111111111
S2=2222222222222222222222222222222222222222; H2=a222222222222222222222222222222222222222; C2=c222222222222222222222222222222222222222
S3=3333333333333333333333333333333333333333; H3=a333333333333333333333333333333333333333; C3=c333333333333333333333333333333333333333
draft() { # draft <n> <base> <head> <checking> <title>
  jq -nc --argjson n "$1" --arg b "$2" --arg h "$3" --arg body "$(body "$4")" --arg t "$5" \
    '{number:$n, title:$t, body:$body, user:{login:"mergify[bot]"}, base:{sha:$b}, head:{sha:$h, ref:("mergify/merge-queue/" + ($n|tostring))}}'
}
{ echo '['
  draft 903 "$S3" "$H3" "$C3" "merge queue: checking #13 stacked on #902"; echo ,
  draft 902 "$S2" "$H2" "$C2" "merge queue: checking #12 stacked on #901"; echo ,
  draft 901 "$S1" "$H1" "$S1" "merge queue: checking #11 on main"; echo ,
  jq -nc '{number:900, title:"a human PR", body:"", user:{login:"operator"}, base:{sha:"x"}, head:{sha:"y", ref:"feature/x"}}'
  echo ']'; } > "$FX/pulls.json"
files() { jq -nc '{files: [$ARGS.positional[] | {filename: .}]}' --args "$@"; }
files .mergify.yml bin/a.sh > "$FX/cmp-$S1-$H1.json"
files .mergify.yml bin/b.sh > "$FX/cmp-$S2-$H2.json"; files bin/b.sh > "$FX/cmp-$C2-$H2.json"
files .mergify.yml bin/b.sh .github/workflows/y.yml > "$FX/cmp-$S3-$H3.json"; files .github/workflows/y.yml > "$FX/cmp-$C3-$H3.json"
for i in 1 2 3; do
  h=$(eval echo "\$H$i")
  jq -nc --argjson id "$i" '{workflow_runs: [{id: $id, name: "Harness CI", event: "pull_request"}]}' > "$FX/runs-$h.json"
  jq -nc --argjson id "$i" '{jobs: [{name: "CI plan (what this run tests)", check_run_url: ("https://api.github.com/repos/o/r/check-runs/" + ($id|tostring))},
    {name: "Tests, traced (shard 0)", started_at: "2026-10-13T10:00:00Z", completed_at: "2026-10-13T10:36:00Z"},
    {name: "Tests, traced (shard 1)", started_at: "2026-10-13T10:00:00Z", completed_at: "2026-10-13T10:34:00Z"}]}' > "$FX/jobs-$i.json"
  jq -nc '[{annotation_level: "notice", title: "ci-plan", message: "mode=full count=50 total=50 n=1 reason=full: selection input: .mergify.yml"}]' > "$FX/ann-$i.json"
done
cat > "$T/replay-gh" <<EOF
#!/bin/bash
# a stub of \`gh api <path>\` over the fixture files
[ "\$1" = api ] || exit 9
p="\$2"; echo "\$p" >> "$FX/asked"
[ "\${STUB_LIST_FAIL:-0}" = 1 ] && case "\$p" in *pulls\?*) exit 1 ;; esac
case "\$p" in
  *pulls\?*page=1) cat "$FX/pulls.json" ;;
  *pulls\?*) echo '[]' ;;
  *compare/*) r="\${p##*compare/}"; f="$FX/cmp-\${r%%...*}-\${r##*...}.json"
              [ "\${STUB_BIG:-}" = "\${r##*...}" ] && { jq -nc '{files: [range(300) | {filename: ("f" + tostring)}]}'; exit 0; }
              [ -f "\$f" ] && cat "\$f" || exit 1 ;;
  *actions/runs\?*) h="\${p##*head_sha=}"; h="\${h%%&*}"; cat "$FX/runs-\$h.json" ;;
  *actions/runs/*/jobs*) i="\${p#*actions/runs/}"; cat "$FX/jobs-\${i%%/*}.json" ;;
  *check-runs/*/annotations*) i="\${p#*check-runs/}"; cat "$FX/ann-\${i%%/*}.json" ;;
  *) exit 1 ;;
esac
EOF
# The replay's test-impact step: unknown/* is unknown reach, anything else selects.
cat > "$T/replay-impact" <<'EOF'
#!/bin/bash
c=""; while [ $# -gt 0 ]; do [ "$1" = --changed ] && c="$2"; shift; done
p=$(grep -m1 '^unknown/' "$c")
if [ -n "$p" ]; then echo "impact: 50 of 50 suites (full: unknown reach ($p))" >&2
else echo "impact: 2 of 50 suites (selected: $(grep -c . "$c") changed path(s))" >&2; fi
EOF
chmod +x "$T/replay-gh" "$T/replay-impact"
RENV=(REPLAY_GH="$T/replay-gh" REPLAY_IMPACT="$T/replay-impact")
ROUT=$(env "${RENV[@]}" bash "$REPLAY" --last 30 --repo o/r --out "$T/replay.tsv" 2>&1); RRC=$?
row() { awk -F'\t' -v d="$1" '$1 == d' "$T/replay.tsv" 2>/dev/null; }
col() { row "$1" | cut -f"$2"; }
[ "$RRC" = 0 ] && ok || bad "R1: the replay must be rc 0 (rc=$RRC) [$ROUT]"
[ "$(col 901 6)" = own ] && ok || bad "R1: draft 901 (not stacked, own .mergify.yml) must be 'own': '$(row 901)'"
[ "$(col 902 6)" = "inherited→selected" ] && ok || bad "R1: draft 902 (stacked, inherited only) must be 'inherited→selected': '$(row 902)'"
[ "$(col 903 6)" = "inherited→full" ] && ok || bad "R1: draft 903 (stacked, old trigger inherited, own .github/workflows/y.yml) must be 'inherited→full': '$(row 903)'"
[ "$(col 903 7)" = "selection input: .github/workflows/y.yml" ] && ok || bad "R1: draft 903's new reason must name its own path: '$(row 903)'"
[ "$(col 902 3)" = "${C2:0:8}" ] && [ "$(col 901 3)" = - ] && ok || bad "R1: own8 must be the checking base when stacked, '-' when not: '$(row 901)' '$(row 902)'"
[ -z "$(row 900)" ] && ok || bad "R1: a non-Mergify PR is not a batch: '$(row 900)'"
has "inherited-trigger full: 2 -> 1" "$ROUT" && ok || bad "R2: the summary must say 'inherited-trigger full: 2 -> 1' [$ROUT]"
has "narrowed by the own diff: 1" "$ROUT" && ok || bad "R2: the summary must say 'narrowed by the own diff: 1' [$ROUT]"
has "full fallback still fires: 2 of 3 (own base -: 1)" "$ROUT" && ok || bad "R2: the summary must say 'full fallback still fires: 2 of 3' [$ROUT]"
[ "$(awk -F'\t' 'NR > 1 && $6 == "inherited→selected"' "$T/replay.tsv" | grep -c .)" = 1 ] && ok || bad "R2: the summary must match the rows"
has "approx: current map" "$ROUT" && ok || bad "R2: the output must say the selection part is approximated [$ROUT]"
# R3. a capped compare is unreadable, never narrowed; an unreadable PR list is rc 2.
ROUT3=$(env "${RENV[@]}" STUB_BIG="$H2" bash "$REPLAY" --repo o/r --out "$T/replay3.tsv" 2>&1); RRC=$?
{ [ "$RRC" = 0 ] && [ "$(awk -F'\t' '$1 == 902 { print $6 }' "$T/replay3.tsv")" = unreadable ]; } && ok \
  || bad "R3: a 300-file compare must be an 'unreadable' row, rc 0 (rc=$RRC) [$(cat "$T/replay3.tsv" 2>/dev/null)]"
has "narrowed by the own diff: 0" "$ROUT3" && ok || bad "R3: an unreadable row is never counted as narrowed [$ROUT3]"
env "${RENV[@]}" STUB_LIST_FAIL=1 bash "$REPLAY" --repo o/r > /dev/null 2>&1; RRC=$?
[ "$RRC" = 2 ] && ok || bad "R3: an unreadable PR list must be rc 2 (rc=$RRC)"
# R4. the mean shard minutes come from the fixture timestamps: (36 + 34) / 2 = 35.0.
[ "$(col 902 8)" = 35.0 ] && ok || bad "R4: draft 902's mean shard minutes must be 35.0: '$(row 902)'"
has "inherited-only mean shard min (old): 35.0" "$ROUT" && ok || bad "R4: the summary must carry the inherited-only mean [$ROUT]"

echo "ci-plan-escalation-own-diff.bh-6490-test.sh: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
