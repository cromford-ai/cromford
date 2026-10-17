#!/bin/bash
# tests/harness-ci-cost-shape-test.sh — the CI cost cut (2026-09-24) stays cut,
# and no required check can stall the merge queue because of it.
#
# WHY. MonkCI billed 63K, 93K and 126K minutes on 09-21..23, all overage, and
# cromford was most of it. The measured waste: the corpus ran twice per
# run (fixed by one traced matrix — tests/ci-shard-split-test.sh), every push to
# main re-ran the whole corpus on a tree the merge queue had just tested, and
# superseded PR runs kept burning with no `concurrency:` block. This suite pins
# the workflow-level half, and since the operator's 2026-09-24 direction ("each tree is
# tested exactly once") the queue/merge split that makes it safe:
#
#   S1  concurrency: PR runs keyed on the PR and cancelled when superseded; a
#       merge-queue batch, a push to main, a dispatch are NEVER cancelled
#   S2  the plan job exists and the corpus jobs read its outputs
#   S3  the plan runs on a batch draft (its impact set, or escalated, the
#       corpus), the `full` label, a dispatch and a push to main (never an
#       ordinary PR); the corpus jobs run exactly when it says corpus=1; the
#       seconds-long decision fixtures run in the lint job
#   S4  the metered prompt replay runs on the PR only, never on a batch
#   S5  no schedule, no `labeled` trigger, batch builds keyed on their sha
#   S6  Mergify: queue_conditions = the three fast checks, merge_conditions =
#       all seven (so never an in-place check) in BOTH queues, the conf says the
#       same, and every name is a non-matrix job reachable where it is required
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
WF="${COST_SHAPE_WORKFLOW:-$DIR/.github/workflows/harness-ci.yml}"
MERGIFY="${COST_SHAPE_MERGIFY:-$DIR/.mergify.yml}"
CONF="${COST_SHAPE_CONF:-$DIR/config/mergify/repos/cromford.conf}"
if ! python3 -c 'import yaml' 2>/dev/null; then
  [ -n "${CI:-}" ] && { echo "FAIL: PyYAML missing on a CI runner"; exit 1; }
  echo "harness-ci-cost-shape: PyYAML missing — skipping on this dev machine"; exit 0
fi

python3 - "$WF" "$MERGIFY" "$CONF" <<'PY'
import sys, yaml
wf_path, mergify_path, conf_path = sys.argv[1:4]
wf = yaml.safe_load(open(wf_path))
jobs = wf.get("jobs") or {}
on = wf.get("on", wf.get(True)) or {}
P = F = 0
def ok():
    global P; P += 1
def bad(m):
    global F; F += 1; print("FAIL: " + m)

# ── S1. concurrency
c = wf.get("concurrency") or {}
g = str(c.get("group", "")); cip = str(c.get("cancel-in-progress", ""))
ok() if "github.event_name" in g else bad(f"S1: the group must carry the event, or a push and a PR on one sha share it: {g!r}")
ok() if "github.event.pull_request.number" in g else bad(f"S1: a PR run must be keyed on its PR, got {g!r}")
ok() if "github.sha" in g else bad(f"S1: a non-PR run must be keyed on its own sha, so no two pushes share a group: {g!r}")
ok() if "github.event_name == 'pull_request'" in cip else bad(f"S1: only a pull_request run may be cancelled: {cip!r}")
ok() if "!startsWith(github.head_ref, 'mergify/merge-queue/')" in cip else bad(f"S1: a merge-queue batch must never be cancelled: {cip!r}")
if cip.strip().lower() == "true":
    bad("S1: cancel-in-progress: true cancels pushes to main and merge-queue batches too")
for j, b in jobs.items():
    if isinstance(b, dict) and b.get("concurrency"):
        bad(f"S1: job {j} carries its own concurrency — the workflow-level group is the only one")

# ── S2. the plan job, and who reads it
plan = jobs.get("plan") or {}
ok() if plan else bad("S2: no plan job")
outs = plan.get("outputs") or {}
for k in ("mode", "count", "n", "shards", "summary", "escalation"):
    ok() if k in outs else bad(f"S2: the plan job must output {k}")
runs = " ".join(str(s.get("run", "")) for s in (plan.get("steps") or []))
ok() if "bin/ci-plan.sh" in runs else bad("S2: the plan job must run bin/ci-plan.sh")
for j in ("tests-shard", "decisions", "harness-safety"):
    needs = (jobs.get(j) or {}).get("needs") or []
    needs = [needs] if isinstance(needs, str) else needs
    ok() if "plan" in needs else bad(f"S2: {j} must need the plan job")

# ── S3. EACH TREE IS TESTED ONCE. The plan runs on a merge-queue batch, the
#    `full` label, a dispatch and a push to main — never on an ordinary PR — and
#    every corpus job runs only when the plan says corpus=1 (a push the queue
#    already tested says 0).
QUEUE = "startsWith(github.head_ref, 'mergify/merge-queue/')"
pcond = str(plan.get("if", ""))
ok() if QUEUE in pcond else bad(f"S3: the plan must run on a merge-queue batch: {pcond!r}")
ok() if "contains(github.event.pull_request.labels.*.name, 'full')" in pcond else bad(f"S3: the plan must honour the `full` label: {pcond!r}")
ok() if "github.event_name == 'push'" in pcond else bad(f"S3: the plan must run on a push to main (a tree that bypassed the queue is tested once there): {pcond!r}")
ok() if "corpus" in outs else bad("S3: the plan must output corpus")
penv = {}
for st in plan.get("steps") or []:
    penv.update(st.get("env") or {})
for k, want in (("CI_ACTOR", "github.actor"), ("CI_SHA", "github.sha"), ("GH_TOKEN", "github.token")):
    ok() if want in str(penv.get(k, "")) else bad(f"S3: the plan step must pass {k} from {want} (got {penv.get(k)!r})")
ok() if (plan.get("permissions") or {}).get("actions") == "read" else bad("S3: the plan reads the merge-queue runs: permissions.actions must be read")
for j in ("tests-shard", "console-ui", "worker-jobs"):
    b = jobs.get(j) or {}
    ok() if str(b.get("if", "")).strip() == "needs.plan.outputs.corpus == '1'" else bad(f"S3: {j} must run exactly when the plan says corpus=1: if: {b.get('if')!r}")
    nd = b.get("needs") or []
    ok() if "plan" in (nd if isinstance(nd, list) else [nd]) else bad(f"S3: {j} must need the plan job")
for j in ("decisions", "harness-safety"):
    cond = str((jobs.get(j) or {}).get("if", ""))
    ok() if cond == "${{ !cancelled() && (needs.plan.outputs.corpus == '1' || needs.plan.result == 'failure') }}" \
        else bad(f"S3: {j} must judge whenever the corpus was planned, and go red on a failed plan: {cond!r}")
# the seconds-long decision fixtures run on EVERY PR, in the lint job
lint_names = " ".join(str(st.get("name", "")) for st in (jobs.get("lint") or {}).get("steps") or [])
for want in ("tests/ sourcing lint", "model-id literal lint", "triage-gate decides", "merge-sweep refuses"):
    ok() if want in lint_names else bad(f"S3: '{want}' must run in the lint job (a PR-time check)")

# ── S4. the metered replay: PRs only, and never re-spent on a queue batch
pe = jobs.get("prompt-evals") or {}
ok() if str(pe.get("if", "")).strip() == "github.event_name == 'pull_request'" else bad(f"S4: prompt-evals must run on pull_request only: {pe.get('if')!r}")
gate = [st for st in pe.get("steps") or [] if st.get("id") == "gate"]
body = str(gate[0].get("run", "")) if gate else ""
ok() if "mergify/merge-queue/*" in body and "run=0" in body else bad("S4: the replay gate must skip a merge-queue batch (each member PR already replayed)")

# ── S5. no schedule (a tree is tested once); pull_request is not re-triggered
#    by labels (a label run's skipped checks would replace a queued PR's green
#    ones); every job but the two fast checks is gated.
ok() if not on.get("schedule") else bad("S5: a schedule re-tests trees the queue already tested")
push = on.get("push") or {}
ok() if push.get("branches") == ["main"] else bad(f"S5: push must stay main-only: {push!r}")
prt = (on.get("pull_request") or {}).get("types")
ok() if not prt or "labeled" not in prt else bad(f"S5: `labeled` must not trigger a run on a queued PR: {prt!r}")
for j, b in jobs.items():
    cond = str((b or {}).get("if", ""))
    if j in ("lint", "determinism"):
        ok() if not cond else bad(f"S5: {j} is a fast check and must run on every event: {cond!r}")
    elif j == "ci-image":
        # BH-7255: lint needs it, so it runs on every event like lint does.
        ok() if not cond else bad(f"S5: ci-image is needed by the fast check lint and must run on every event: {cond!r}")
    elif not cond:
        bad(f"S5: {j} has no if: — it would run everywhere")
    else:
        ok()
# a batch build is keyed on its sha, a PR on its number
g = str(c.get("group", ""))
ok() if "!startsWith(github.head_ref, 'mergify/merge-queue/') && github.event.pull_request.number" in g \
    else bad(f"S5: a merge-queue batch must be keyed on its sha, not its draft PR number: {g!r}")

# ── S6. Mergify: queue on the fast checks, merge on everything, from a draft
names = {str(b["name"]): (j, b) for j, b in jobs.items() if isinstance(b, dict) and b.get("name")}
VERDICT = "lead-verdict"
FAST = {"Syntax + shellcheck + config integrity", "Test determinism lint", "Prompt replay evals (prompts/** only)"}
ALL7 = FAST | {"Pure-logic gate fixtures", "Tests cannot touch a real harness",
               "Mission Control SPA — unit tests + build", "Jobs worker — routes + schema"}
def checks(conds):
    out = set()
    for c in conds or []:
        c = str(c)
        if c.startswith("check-success"):
            out.add(c.split("=", 1)[1].strip().strip('"'))
    return out
m = yaml.safe_load(open(mergify_path))
rules = m.get("queue_rules") or []
ok() if {r.get("name") for r in rules} >= {"hotfix", "default"} else bad("S6: both the hotfix and default queues must exist")
for r in rules:
    qn = r.get("name")
    qc, mc = checks(r.get("queue_conditions")), checks(r.get("merge_conditions"))
    # BH-3348: `lead-verdict` is a commit STATUS a head-bound verdict publishes,
    # not a CI job; it gates admission (queue) and never the batch draft (merge).
    ok() if VERDICT in qc and VERDICT not in mc else bad(f"S6: {qn} must require {VERDICT} in queue_conditions only: {sorted(qc)} / {sorted(mc)}")
    qc = qc - {VERDICT}
    ok() if qc == FAST else bad(f"S6: {qn}.queue_conditions must be exactly the fast checks (an ordinary PR never runs the corpus, so asking for it there stalls every PR): {sorted(qc)}")
    ok() if mc == ALL7 else bad(f"S6: {qn}.merge_conditions must be all seven checks (the batch draft runs them): {sorted(mc)}")
    ok() if qc != mc else bad(f"S6: {qn} queue and merge checks are the same list — Mergify could then check a PR in place and never run the corpus")
conf = [l.strip() for l in open(conf_path)]
cq = {l[len("queue_check="):] for l in conf if l.startswith("queue_check=")}
cm = {l[len("check="):] for l in conf if l.startswith("check=")}
ok() if cm == ALL7 else bad(f"S6: {conf_path} check= lines must be the seven merge checks: {sorted(cm)}")
ok() if cq == FAST else bad(f"S6: {conf_path} queue_check= lines must be the fast checks: {sorted(cq)}")
for r in sorted(ALL7):
    if r not in names:
        bad(f"S6: required check {r!r} is not the name of any job in {wf_path} — every merge would stall"); continue
    j, b = names[r]
    if "strategy" in b:
        bad(f"S6: required check {r!r} is a matrix job ({j}); its runs are named per entry and never match")
    cond = str(b.get("if", "")).strip()
    if r in FAST:
        ok() if cond in ("", "github.event_name == 'pull_request'") else bad(f"S6: fast check {r!r} ({j}) must run on every PR: if: {cond!r}")
    else:
        nd = b.get("needs") or []
        nd = nd if isinstance(nd, list) else [nd]
        ok() if "plan" in nd and "needs.plan.outputs.corpus == '1'" in cond else bad(f"S6: merge check {r!r} ({j}) must run wherever the plan runs the corpus — which includes every batch draft (S3): if: {cond!r}")

print(f"harness-ci-cost-shape: {P} pass, {F} fail")
sys.exit(1 if F else 0)
PY
