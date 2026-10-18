#!/bin/bash
# tests/dora-review-block.bh-6969-test.sh — the `review` block of the daily
# DORA digest and its one alert (BH-6969): PRs by review tier and mode, verdict
# flips, reverts and main-red culprits by tier, review cost per PR by tier, and
# one [dora-review-tiers] ALERTS line a UTC day when the low or intent tier's
# 7-day revert rate is more than review.tier_revert_margin over the full tier's.
#
# U1-U9 call bin/dora_review.py with explicit since/until on rows in the shape
# GET /api/metrics/review-tiers answers (worker/jobs/src/routes/review-tiers.js,
# pinned by worker/jobs/test/review-tiers.bh-6969.test.js R2). D1-D6 drive the
# production entry point bin/dora-digest.sh --no-send with a stub
# bin/jobs-client.sh whose _jobs_req answers that route with a fixture.
# D7 a capped read withholds the alert; D8 the module raising is status error.
# Every expected number below is counted by hand off the fixture rows.
# Run from anywhere: tests/dora-review-block.bh-6969-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the day flag and the json name are read by the code and again here; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 60 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
# The review alert lines in one ALERTS.log; an absent file is zero lines.
ralerts() { if [ -f "$1/logs/ALERTS.log" ]; then grep -c '\[dora-review-tiers\]' "$1/logs/ALERTS.log"; else echo 0; fi; }

command -v jq >/dev/null 2>&1 || { echo "dora-review-block: jq required, skipping"; exit 0; }
# The module and the route this block reads; a missing one fails, never skips.
for F in "$DIR/bin/dora_review.py" "$DIR/worker/jobs/src/routes/review-tiers.js"; do
  [ -r "$F" ] || { echo "FAIL: $F is missing"; exit 1; }
done
TODAY=$(date -u +%F)

# ── U1-U9: the module, on explicit since/until ──────────────────────────────
cat > "$T/cost-per-pr.csv" <<'CSV'
pr_url,cost_usd,input_toks,output_toks,cache_read,cache_write,stage_breakdown,build_dirs,auth_account,account_breakdown,fly_usd
https://github.com/Org/a/pull/1,4.70,10,10,0,0,build:3.00;review:1.20;lead-review:0.40;REVIEW-HEAD:0.10,pool-a-1,acct-a,acct-a:4.70,
https://github.com/Org/a/pull/2,2.00,10,10,0,0,execute:2.00,pool-a-2,acct-a,acct-a:2.00,
CSV
PYOUT=$(python3 - "$DIR/bin" "$T/cost-per-pr.csv" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import dora_review as dr
CPP = sys.argv[2]
P = F = 0
def check(name, got, want):
    global P, F
    if got == want:
        P += 1
    else:
        F += 1
        print("FAIL: %s: expected %r, got %r" % (name, want, got))

S, U, S7 = "2026-10-10T00:00:00Z", "2026-10-11T00:00:00Z", "2026-10-04T00:00:00Z"
H = "a" * 40
def v(i, pr, verdict, source, tier, mode, at, head=H, repo="Org/a"):
    return dict(id=i, repo=repo, pr=pr, head_sha=head, verdict=verdict, source=source,
                review_tier=tier, review_mode=mode, created_at=at)
def pay(merges=(), verdicts=(), reverts=(), culprits=(), capped=None):
    return dict(merges=list(merges), verdicts=list(verdicts), reverts=list(reverts),
                culprits=list(culprits), capped=capped or {})
def url(pr, repo="Org/a"):
    return "https://github.com/%s/pull/%d" % (repo, pr)
def run(p, since=S, cpp=""):
    return dr.compute(p, since, U, S7, cpp, "review")
def grp(r, k, f):
    return (r["groups"].get(k) or {}).get(f)

# U1 cohort table
for src, tier, mode, want in [
        ("lead", "medium", "intent", "intent"), ("risk-tier", "low", "risk-tier", "low"),
        ("risk-tier", None, None, "low"), ("lead", "low", "full", "full"),
        ("lead", "high", "full", "full"), ("lead", None, None, "full"),
        ("lead", "medium", None, "full"), ("lead", "Medium", "INTENT", None),
        ("box", None, None, None)]:
    check("U1 cohort %s/%s/%s" % (src, tier, mode),
          dr.cohort(dict(source=src, review_tier=tier, review_mode=mode)), want)
check("U1 group key", dr.group_key(dict(source="lead", review_tier="medium", review_mode="intent")), "medium/intent")
check("U1 group key, no tier", dr.group_key(dict(source="risk-tier", review_tier=None, review_mode=None)), "untiered/risk-tier")
check("U1 group key, no cohort", dr.group_key(dict(source="lead", review_tier="Medium", review_mode="INTENT")), "untiered")

# U2 groups: reviewed by the newest row in the window, merged by the newest row at or before the merge
p = pay(
    merges=[dict(pr_url=url(1), merged_at="2026-10-10T12:00:00Z"),
            dict(pr_url=url(2), merged_at="2026-10-10T12:00:00Z"),
            dict(pr_url=url(3), merged_at="2026-10-10T12:00:00Z"),
            dict(pr_url=url(6), merged_at="2026-10-10T12:00:00Z"),
            dict(pr_url=url(9), merged_at="2026-10-08T12:00:00Z")],
    verdicts=[v(1, 1, "MERGE", "lead", "medium", "intent", "2026-10-10T10:00:00Z"),
              # pr 2: a full review before the merge, a risk-tier row after it
              v(2, 2, "MERGE", "lead", "low", "full", "2026-10-10T10:00:00Z"),
              v(9, 2, "MERGE", "risk-tier", "low", "risk-tier", "2026-10-10T13:00:00Z"),
              v(3, 3, "MERGE", "risk-tier", "low", "risk-tier", "2026-10-09T10:00:00Z"),
              v(4, 4, "MERGE", "lead", "high", "full", "2026-10-10T10:00:00Z"),
              v(5, 5, "MERGE", "lead", None, None, "2026-10-10T10:00:00Z"),
              v(7, 9, "MERGE", "lead", "high", "full", "2026-10-08T10:00:00Z")])
r = run(p)
check("U2 medium/intent reviewed", grp(r, "medium/intent", "reviewed"), 1)
check("U2 medium/intent merged", grp(r, "medium/intent", "merged"), 1)
check("U2 pr 2 merged under the row at or before the merge", grp(r, "low/full", "merged"), 1)
check("U2 pr 2 reviewed under its newest row", grp(r, "low/risk-tier", "reviewed"), 1)
check("U2 pr 3 (verdict before the window) merged under low/risk-tier", grp(r, "low/risk-tier", "merged"), 1)
check("U2 pr 3 is not reviewed in the window", grp(r, "low/risk-tier", "reviewed"), 1)
check("U2 high/full reviewed (pr 4)", grp(r, "high/full", "reviewed"), 1)
check("U2 high/full merged (pr 9 merged before the window)", grp(r, "high/full", "merged"), 0)
check("U2 legacy lead row", grp(r, "untiered/full", "reviewed"), 1)
check("U2 pr 6 merged with no verdict", grp(r, "no-verdict", "merged"), 1)

# U3 flips
fl = pay(verdicts=[
    v(1, 1, "MERGE", "lead", "high", "full", "2026-10-10T01:00:00Z"),
    v(2, 1, "BLOCK", "lead", "high", "full", "2026-10-10T02:00:00Z"),            # flip 1
    v(3, 2, "BLOCK", "lead", "medium", "intent", "2026-10-10T01:00:00Z"),
    v(4, 2, "MERGE-WITH-NOTES", "lead", "medium", "intent", "2026-10-10T02:00:00Z"),  # flip 2
    v(5, 3, "MERGE", "lead", "high", "full", "2026-10-10T01:00:00Z"),
    v(6, 3, "MERGE-WITH-NOTES", "lead", "high", "full", "2026-10-10T02:00:00Z"),  # no flip
    v(7, 4, "BLOCK", "lead", "high", "full", "2026-10-10T01:00:00Z", head="b" * 40),
    v(8, 4, "MERGE", "lead", "high", "full", "2026-10-10T02:00:00Z", head="c" * 40),  # new head: no flip
    v(9, 5, "MERGE", "lead", "high", "full", "2026-10-10T01:00:00Z", head="D" * 40),
    v(10, 5, "BLOCK", "lead", "high", "full", "2026-10-10T02:00:00Z", head="d" * 40),  # case: flip 3
    v(11, 6, "MERGE", "lead", "high", "full", "2026-10-08T01:00:00Z"),
    v(12, 6, "BLOCK", "lead", "high", "full", "2026-10-09T01:00:00Z")])          # before window: no flip
r = run(fl)
check("U3 high/full flips (MERGE->BLOCK, case-normalised head)", grp(r, "high/full", "flips"), 2)
check("U3 medium/intent flips (BLOCK->MERGE-WITH-NOTES)", grp(r, "medium/intent", "flips"), 1)
check("U3 total flips", sum(g["flips"] for g in r["groups"].values()), 3)

# U4 reverts
rv = pay(
    merges=[dict(pr_url=url(1), merged_at="2026-10-10T12:00:00Z"),
            dict(pr_url=url(2), merged_at="2026-10-10T12:00:00Z"),
            dict(pr_url=url(3), merged_at="2026-10-10T12:00:00Z"),
            dict(pr_url=url(4), merged_at="2026-10-08T12:00:00Z")],
    verdicts=[v(1, 1, "MERGE", "risk-tier", "low", "risk-tier", "2026-10-10T10:00:00Z"),
              v(2, 2, "MERGE", "risk-tier", "low", "risk-tier", "2026-10-10T10:00:00Z"),
              v(3, 3, "MERGE", "risk-tier", "low", "risk-tier", "2026-10-10T10:00:00Z"),
              v(4, 4, "MERGE", "risk-tier", "low", "risk-tier", "2026-10-08T10:00:00Z")],
    reverts=[dict(repo="Org/a", pr=url(1), outcome="reverted", created_at="2026-10-10T20:00:00Z"),
             dict(repo="Org/a", pr="2", outcome="reverted", created_at="2026-10-10T20:00:00Z"),
             dict(repo="Org/a", pr=url(3), outcome="reopened", created_at="2026-10-10T20:00:00Z"),
             dict(repo="Org/a", pr=url(3), outcome="merged_then_red", created_at="2026-10-10T20:00:00Z"),
             dict(repo="Org/a", pr=url(4), outcome="reverted", created_at="2026-10-10T20:00:00Z")])
r = run(rv)
check("U4 reverts: url + bare number count, reopened/merged_then_red/old merge do not",
      grp(r, "low/risk-tier", "reverts"), 2)
check("U4 7d revert window counts the older merge", r["revert_7d"]["low"]["reverted"], 3)
check("U4 7d merged", r["revert_7d"]["low"]["merged"], 4)

# U5 culprits
cu = pay(
    merges=[dict(pr_url=url(12), merged_at="2026-10-10T12:00:00Z")],
    verdicts=[v(1, 12, "MERGE", "lead", "medium", "intent", "2026-10-10T10:00:00Z")],
    culprits=[dict(key="Org/a@" + "1" * 40, status="unknown", pr=12, updated_at="2026-10-10T20:00:00Z"),
              dict(key="Org/a@" + "1" * 12, status="gap", pr=12, updated_at="2026-10-10T20:00:00Z"),
              dict(key="Org/a@" + "2" * 40, status="gap", pr=None, updated_at="2026-10-10T20:00:00Z"),
              dict(key="Org/a@" + "3" * 40, status="gap", pr=12, updated_at="2026-10-08T20:00:00Z"),
              dict(key="Org/a@" + "4" * 40, status="gap", pr=77, updated_at="2026-10-10T20:00:00Z")])
r = run(cu)
check("U5 one culprit (status unknown counts; short sha, no pr, old row do not)",
      grp(r, "medium/intent", "main_red_culprits"), 1)
check("U5 a culprit PR with no verdict", grp(r, "no-verdict", "main_red_culprits"), 1)

# U6 untiered
un = pay(verdicts=[v(1, 1, "MERGE", "lead", None, None, "2026-10-10T10:00:00Z"),
                   v(2, 2, "MERGE", "lead", "medium", "INTENT", "2026-10-10T10:00:00Z")])
r = run(un)
check("U6 legacy lead row is full", grp(r, "untiered/full", "reviewed"), 1)
check("U6 an INTENT row is untiered", grp(r, "untiered", "reviewed"), 1)
check("U6 untiered is never a cohort", sorted(r["revert_7d"]), ["full", "intent", "low"])

# U7 cost
co = pay(
    merges=[dict(pr_url=url(1), merged_at="2026-10-10T12:00:00Z"),
            dict(pr_url=url(2), merged_at="2026-10-10T12:00:00Z"),
            dict(pr_url=url(3), merged_at="2026-10-10T12:00:00Z")],
    verdicts=[v(1, 1, "MERGE", "lead", "high", "full", "2026-10-10T10:00:00Z"),
              v(2, 2, "MERGE", "lead", "high", "full", "2026-10-10T10:00:00Z"),
              v(3, 3, "MERGE", "lead", "high", "full", "2026-10-10T10:00:00Z")])
r = run(co, cpp=CPP)
c = grp(r, "high/full", "cost") or {}
check("U7 priced (pr 3 has no csv row)", c.get("priced"), 2)
check("U7 review $/PR = (1.20+0.40+0.10 + 0)/2", c.get("review_usd_per_pr"), 0.85)
check("U7 total $/PR = (4.70+2.00)/2", c.get("total_usd_per_pr"), 3.35)
check("U7 unpriced count", c.get("unpriced"), 1)
one = pay(merges=[dict(pr_url=url(3), merged_at="2026-10-10T12:00:00Z")],
          verdicts=[v(3, 3, "MERGE", "lead", "high", "full", "2026-10-10T10:00:00Z")])
c = grp(run(one, cpp=CPP), "high/full", "cost") or {}
check("U7 a PR with no csv row is unpriced, not $0", (c.get("priced"), c.get("review_usd_per_pr")), (0, None))
c = grp(run(co, cpp=""), "high/full", "cost") or {}
check("U7 no csv: n/a", (c.get("priced"), c.get("total_usd_per_pr")), (None, None))
check("U7 no csv: says why", "absent" in (c.get("unavailable") or ""), True)

# U8 capped
r = run(pay(capped=dict(verdicts=True, culprits=False)))
check("U8 incomplete names the capped read", r["incomplete"], ["verdicts"])
check("U8 the alert is withheld", bool(r["alert_withheld"]), True)
check("U8 uncapped: not withheld", run(pay(capped=dict(culprits=True)))["alert_withheld"], None)

# U9 alert table
def r7(lm, lr, fm, fr, im=0, ir=0):
    return {"low": dict(merged=lm, reverted=lr), "intent": dict(merged=im, reverted=ir),
            "full": dict(merged=fm, reverted=fr)}
for name, rr, want in [
        ("low 1/20 vs full 1/50 fires", r7(20, 1, 50, 1), ["low"]),
        ("low 3/100 vs full 1/50 does not", r7(100, 3, 50, 1), []),
        ("low 2/50 vs full 1/50 is exactly the margin: no", r7(50, 2, 50, 1), []),
        ("low 41/1000 vs full 1/50 fires", r7(1000, 41, 50, 1), ["low"]),
        ("full 0 merges: no alert", r7(20, 5, 0, 0), []),
        ("low 0 merges: no alert", r7(0, 0, 50, 1), []),
        ("intent 1/20 vs full 1/50 fires", r7(0, 0, 50, 1, 20, 1), ["intent"]),
        ("both over", r7(20, 1, 50, 1, 20, 1), ["low", "intent"])]:
    check("U9 " + name, [o["cohort"] for o in dr.over_margin(rr, "0.02")], want)
both = dr.over_margin(r7(20, 1, 50, 1, 20, 1), "0.02")
line = dr.alert_line(both, "0.02", "default")
check("U9 one line for two cohorts", line.count("\n"), 0)
check("U9 the line has the tag", line.startswith("[dora-review-tiers] "), True)
check("U9 the line names both counts", ("low 1/20" in line, "intent 1/20" in line, "full 1/50" in line),
      (True, True, True))
check("U9 the line names the knob", "review.tier_revert_margin (0.02, default)" in line, True)
check("U9 no line when nothing is over", dr.alert_line([], "0.02", "default"), None)

# U10 the minimum sample (review.tier_revert_min_n, default 5)
check("U10 the default is 5", dr.MIN_N_DEFAULT, 5)
for name, rr, n, want in [
        ("low 1/1 vs full 0/1: under the default, no alert", r7(1, 1, 1, 0), 5, []),
        ("low 1/1 vs full 0/1 at min_n 1 fires", r7(1, 1, 1, 0), 1, ["low"]),
        ("low 2/4 vs full 0/50: low under 5", r7(4, 2, 50, 0), 5, []),
        ("low 2/5 vs full 0/50: low at 5 fires", r7(5, 2, 50, 0), 5, ["low"]),
        ("low 3/20 vs full 0/4: full under 5", r7(20, 3, 4, 0), 5, []),
        ("min_n 0 binds as 1", r7(1, 1, 1, 0), 0, ["low"])]:
    check("U10 " + name, [o["cohort"] for o in dr.over_margin(rr, "0.02", n)], want)
check("U10 the default applies without the argument", dr.over_margin(r7(1, 1, 1, 0), "0.02"), [])
print("PY %d %d" % (P, F))
PY
)
PYRC=$?
printf '%s\n' "$PYOUT" | grep '^FAIL' || true
PYP=$(printf '%s\n' "$PYOUT" | awk '/^PY /{print $2}')
PYF=$(printf '%s\n' "$PYOUT" | awk '/^PY /{print $3}')
eq "U1-U9 module run exits 0" "$PYRC" "0"
eq "U1-U9 module failures" "${PYF:-none}" "0"
PASS=$((PASS + ${PYP:-0})); FAIL=$((FAIL + ${PYF:-0}))

# ── D: the production entry point ───────────────────────────────────────────
# ago <minutes> — the route's ISO stamp, that many minutes before now.
ago() { date -u -d "$1 minutes ago" '+%Y-%m-%dT%H:%M:%SZ'; }
tree() { mkdir -p "$T/$1/logs" "$T/$1/bin" "$T/$1/state/cost"; printf '%s' "$T/$1"; }
# stub <root> — bin/jobs-client.sh: /api/settings for the kill switch, the
# review route from $h/review.json (rc 1 when STUB_REVIEW_RC=1), rc 1 for every
# other path; setting_get answers $h/margin-row when it exists.
stub() {
  cat > "$1/bin/jobs-client.sh" <<'SH'
_jobs_req() {
  [ "$2" = /api/settings ] && { printf '{"settings":[]}'; return 0; }
  echo "$*" >> "$HARNESS/calls"
  case "$2" in
    /api/metrics/review-tiers*) [ "${STUB_REVIEW_RC:-0}" = 0 ] || return 1; cat "$HARNESS/review.json"; return 0 ;;
  esac
  return 1
}
if [ -f "$HARNESS/margin-row" ] || [ -f "$HARNESS/min-n-row" ]; then
  setting_get() {
    [ "$1" = review.tier_revert_margin ] && [ -f "$HARNESS/margin-row" ] && { cat "$HARNESS/margin-row"; return 0; }
    [ "$1" = review.tier_revert_min_n ] && [ -f "$HARNESS/min-n-row" ] && { cat "$HARNESS/min-n-row"; return 0; }
    return 2
  }
fi
SH
}
digest() {
  local h="$1"; shift
  HARNESS="$h" DORA_LEDGER="${LEDGER:-1}" DORA_GH_BUDGET=0 \
    "${DIGEST:-$DIR/bin/dora-digest.sh}" --no-send "$@" > "$h/stdout" 2> "$h/stderr"
}
J() { printf '%s' "$1/state/dora/$TODAY.json"; }
rj() { jq -r "$2" "$(J "$1")"; }
grpf() { rj "$1" ".fleet.review.groups[\"$2\"].$3"; }
unset DORA_REVIEW_TIER_REVERT_MARGIN DORA_REVIEW_TIER_REVERT_MIN_N

# fixture <file> <low_merged> <low_reverted> <full_merged> <full_reverted> —
# merged PRs 2 days ago, each with one verdict an hour before its merge.
fixture() {
  python3 - "$@" <<'PY'
import json, sys, datetime as d
out, lm, lr, fm, fr = sys.argv[1], *map(int, sys.argv[2:6])
now = d.datetime.now(d.timezone.utc).replace(microsecond=0)
iso = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")
m, v, rv, n = [], [], [], 0
for src, mode, tier, nm, nr in (("risk-tier", "risk-tier", "low", lm, lr), ("lead", "full", "high", fm, fr)):
    for i in range(nm):
        n += 1
        u = "https://github.com/Org/alpha/pull/%d" % n
        m.append(dict(pr_url=u, merged_at=iso(now - d.timedelta(days=2))))
        v.append(dict(id=n, repo="Org/alpha", pr=n, head_sha="a" * 40, verdict="MERGE", source=src,
                      review_tier=tier, review_mode=mode, created_at=iso(now - d.timedelta(days=2, hours=1))))
        if i < nr:
            rv.append(dict(repo="Org/alpha", pr=u, outcome="reverted", created_at=iso(now - d.timedelta(days=1))))
json.dump(dict(days=7, merges=m, verdicts=v, reverts=rv, culprits=[],
               capped=dict(merges=False, verdicts=False, reverts=False, culprits=False)), open(out, "w"))
PY
}

# ── D1: the figures through the real digest ────────────────────────────────
D1=$(tree d1); stub "$D1"
jq -n --arg m200 "$(ago 200)" --arg v300 "$(ago 300)" --arg v400 "$(ago 400)" --arg v350 "$(ago 350)" \
  --arg v320 "$(ago 320)" --arg c100 "$(ago 100)" --arg r50 "$(ago 50)" --arg h "$(printf 'a%.0s' $(seq 40))" '{
  days: 7, since: $v400, verdict_since: $v400,
  merges: [{pr_url: "https://github.com/Org/alpha/pull/1", merged_at: $m200},
           {pr_url: "https://github.com/Org/alpha/pull/2", merged_at: $m200},
           {pr_url: "https://github.com/Org/alpha/pull/3", merged_at: $m200}],
  verdicts: [
    {id: 1, repo: "Org/alpha", pr: 1, head_sha: $h, verdict: "MERGE", source: "lead", review_tier: "medium", review_mode: "intent", created_at: $v300},
    {id: 2, repo: "Org/alpha", pr: 2, head_sha: $h, verdict: "MERGE", source: "risk-tier", review_tier: "low", review_mode: "risk-tier", created_at: $v300},
    {id: 3, repo: "Org/alpha", pr: 3, head_sha: $h, verdict: "MERGE", source: "lead", review_tier: "high", review_mode: "full", created_at: $v400},
    {id: 4, repo: "Org/alpha", pr: 3, head_sha: $h, verdict: "BLOCK", source: "lead", review_tier: "high", review_mode: "full", created_at: $v350},
    {id: 5, repo: "Org/alpha", pr: 3, head_sha: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", verdict: "MERGE", source: "lead", review_tier: "high", review_mode: "full", created_at: $v320},
    {id: 6, repo: "Org/alpha", pr: 4, head_sha: $h, verdict: "MERGE", source: "lead", review_tier: null, review_mode: null, created_at: $v300}],
  reverts: [{repo: "Org/alpha", pr: "https://github.com/Org/alpha/pull/2", outcome: "reverted", created_at: $r50}],
  culprits: [{key: ("Org/alpha@" + $h), status: "gap", pr: 3, updated_at: $c100}],
  capped: {merges: false, verdicts: false, reverts: false, culprits: false}, as_of: $c100}' > "$D1/review.json"
cat > "$D1/state/cost/cost-per-pr.csv" <<'CSV'
pr_url,cost_usd,input_toks,output_toks,cache_read,cache_write,stage_breakdown,build_dirs,auth_account,account_breakdown,fly_usd
https://github.com/Org/alpha/pull/1,4.20,1,1,0,0,build:3.00;review:1.20,pool-alpha-1,acct-a,acct-a:4.20,
https://github.com/Org/alpha/pull/2,2.40,1,1,0,0,execute:2.00;review-head:0.40,pool-alpha-2,acct-a,acct-a:2.40,
CSV
digest "$D1" --window 24h
eq "D1 run exits 0" "$?" "0"
eq "D1 the review read is a GET on days=7" "$(grep -c '^GET /api/metrics/review-tiers?days=7$' "$D1/calls")" "1"
eq "D1 status" "$(rj "$D1" .fleet.review.status)" "ok"
eq "D1 medium/intent reviewed" "$(grpf "$D1" medium/intent reviewed)" "1"
eq "D1 medium/intent merged" "$(grpf "$D1" medium/intent merged)" "1"
eq "D1 medium/intent review \$/PR" "$(grpf "$D1" medium/intent cost.review_usd_per_pr)" "1.2"
eq "D1 medium/intent total \$/PR" "$(grpf "$D1" medium/intent cost.total_usd_per_pr)" "4.2"
eq "D1 low/risk-tier merged" "$(grpf "$D1" low/risk-tier merged)" "1"
eq "D1 low/risk-tier reverts" "$(grpf "$D1" low/risk-tier reverts)" "1"
eq "D1 low/risk-tier review \$/PR" "$(grpf "$D1" low/risk-tier cost.review_usd_per_pr)" "0.4"
eq "D1 high/full flips (MERGE->BLOCK on one head; the new head is not a flip)" "$(grpf "$D1" high/full flips)" "1"
eq "D1 high/full culprits" "$(grpf "$D1" high/full main_red_culprits)" "1"
eq "D1 high/full is unpriced, not \$0" "$(grpf "$D1" high/full cost.review_usd_per_pr)" "null"
eq "D1 high/full priced" "$(grpf "$D1" high/full cost.priced)" "0"
eq "D1 legacy lead row reviewed" "$(grpf "$D1" untiered/full reviewed)" "1"
eq "D1 margin" "$(rj "$D1" .fleet.review.margin)" "0.02"
eq "D1 margin source" "$(rj "$D1" .fleet.review.margin_source)" "default"
eq "D1 the 7d low cohort" "$(rj "$D1" '.fleet.review.revert_7d.low | "\(.reverted)/\(.merged)"')" "1/1"
grep -q '^review medium/intent: reviewed 1, merged 1, flips 0, reverts 0, culprits 0, review \$1.20/PR of \$4.20/PR (1 priced)' \
  "$D1/state/dora/latest.txt" && ok || bad "D1 text line: $(grep '^review' "$D1/state/dora/latest.txt")"
grep -q '^review 7d reverts: low 1/1 (100%), intent 0/1 (0%), full 0/1 (0%); margin 0.02 (default)$' \
  "$D1/state/dora/latest.txt" && ok || bad "D1 7d text line: $(grep '^review 7d' "$D1/state/dora/latest.txt")"
# TEST-CHANGE BH-6969 review: low 1/1 vs full 0/1 used to page. One merge per
# cohort is under the minimum sample (review.tier_revert_min_n, default 5), so
# the default run now writes no line; D9 shows the same fixture fires at 1.
eq "D1 min_n default" "$(rj "$D1" .fleet.review.min_n)/$(rj "$D1" .fleet.review.min_n_source)" "5/default"
eq "D1 no alert line (low 1/1 vs full 0/1 is under the minimum sample)" "$(ralerts "$D1")" "0"

# ── D2: the alert at 5% vs 2%, once a day; none at 3% vs 2% ─────────────────
D2=$(tree d2); stub "$D2"
fixture "$D2/review.json" 20 1 50 1
digest "$D2" --window 24h
eq "D2 run exits 0" "$?" "0"
eq "D2 one line at low 1/20 vs full 1/50" "$(ralerts "$D2")" "1"
grep '\[dora-review-tiers\]' "$D2/logs/ALERTS.log" | grep -q 'low 1/20 (5.0%) vs full 1/50 (2.0%)' \
  && ok || bad "D2 the line names the counts: $(cat "$D2/logs/ALERTS.log")"
LINE=$(grep '\[dora-review-tiers\]' "$D2/logs/ALERTS.log" | head -1)
eq "D2 the ALERTS line is the stamp + the json's alert line" "${LINE#* * }" "$(rj "$D2" .fleet.review.alert.line)"
grep -q '^review 7d reverts: low 1/20 (5%), intent n/a (0 merged), full 1/50 (2%); margin 0.02 (default)$' \
  "$D2/state/dora/latest.txt" && ok || bad "D2 7d text line: $(grep '^review 7d' "$D2/state/dora/latest.txt")"
digest "$D2" --window 24h
eq "D2 second run exits 0" "$?" "0"
eq "D2 a second run the same day adds no line" "$(ralerts "$D2")" "1"
D2N=$(tree d2n); stub "$D2N"
fixture "$D2N/review.json" 100 3 50 1
digest "$D2N" --window 24h
eq "D2 negative run exits 0" "$?" "0"
eq "D2 no line at low 3/100 vs full 1/50" "$(ralerts "$D2N")" "0"
eq "D2 negative: the json has no alert line" "$(rj "$D2N" .fleet.review.alert.line)" "null"

# ── D3: the route refused ───────────────────────────────────────────────────
D3=$(tree d3); stub "$D3"
fixture "$D3/review.json" 20 1 50 1
STUB_REVIEW_RC=1 digest "$D3" --window 24h
eq "D3 rc 1 run exits 0" "$?" "0"
eq "D3 status error" "$(rj "$D3" .fleet.review.status)" "error"
eq "D3 no groups" "$(rj "$D3" .fleet.review.groups)" "null"
grep -q '^review: n/a (' "$D3/state/dora/latest.txt" && ok || bad "D3 text: $(grep '^review' "$D3/state/dora/latest.txt")"
eq "D3 no line" "$(ralerts "$D3")" "0"
echo '{"projects":[]}' > "$D3/review.json"
digest "$D3" --window 24h
eq "D3 a body without verdicts: exits 0" "$?" "0"
eq "D3 a body without verdicts: error" "$(rj "$D3" .fleet.review.status)" "error"

# ── D4: DORA_LEDGER=0 ───────────────────────────────────────────────────────
D4=$(tree d4); stub "$D4"
fixture "$D4/review.json" 20 1 50 1
LEDGER=0 digest "$D4" --window 24h
eq "D4 run exits 0" "$?" "0"
eq "D4 status off" "$(rj "$D4" .fleet.review.status)" "off"
eq "D4 no review request" "$(grep -c review-tiers "$D4/calls" 2>/dev/null || echo 0)" "0"
grep -q '^review: off (' "$D4/state/dora/latest.txt" && ok || bad "D4 text: $(grep '^review' "$D4/state/dora/latest.txt")"
eq "D4 no line" "$(ralerts "$D4")" "0"

# ── D5: bin/dora_review.py absent ───────────────────────────────────────────
D5=$(tree d5); stub "$D5"
fixture "$D5/review.json" 20 1 50 1
X="$T/d5bin"
scratch_install_closure bin/dora-digest.sh "$X" >/dev/null || bad "D5 closure install"
scratch_install_closure bin/alert-line.sh "$X" >/dev/null || bad "D5 alert-line closure install"
cp "$DIR/bin/dora-digest.py" "$DIR/bin/dora_conflicts.py" "$X/bin/"
[ -e "$X/bin/dora_review.py" ] && bad "D5 the scratch bin must not hold the module"
DIGEST="$X/bin/dora-digest.sh" digest "$D5" --window 24h
eq "D5 run exits 0" "$?" "0"
eq "D5 status error" "$(rj "$D5" .fleet.review.status)" "error"
rj "$D5" .fleet.review.unavailable | grep -q 'not installed' && ok || bad "D5 says why: $(rj "$D5" .fleet.review.unavailable)"
eq "D5 no line" "$(ralerts "$D5")" "0"

# ── D6: the settings row ────────────────────────────────────────────────────
D6=$(tree d6); stub "$D6"
fixture "$D6/review.json" 20 1 50 1
printf '0.05' > "$D6/margin-row"
digest "$D6" --window 24h
eq "D6 row run exits 0" "$?" "0"
eq "D6 margin from the row" "$(rj "$D6" .fleet.review.margin)" "0.05"
eq "D6 margin source row" "$(rj "$D6" .fleet.review.margin_source)" "row"
eq "D6 5% vs 2% under a 0.05 margin: no line" "$(ralerts "$D6")" "0"
D6B=$(tree d6b); stub "$D6B"
fixture "$D6B/review.json" 20 1 50 1
printf '2%%' > "$D6B/margin-row"
digest "$D6B" --window 24h
eq "D6 '2%' row run exits 0" "$?" "0"
eq "D6 '2%' is ignored: default" "$(rj "$D6B" .fleet.review.margin_source)" "default"
eq "D6 '2%' is ignored: 0.02" "$(rj "$D6B" .fleet.review.margin)" "0.02"
eq "D6 and the default margin fires" "$(ralerts "$D6B")" "1"
D6C=$(tree d6c); stub "$D6C"
fixture "$D6C/review.json" 20 1 50 1
DORA_REVIEW_TIER_REVERT_MARGIN=0.1 digest "$D6C" --window 24h
eq "D6 env margin" "$(rj "$D6C" .fleet.review.margin_source)/$(rj "$D6C" .fleet.review.margin)" "env/0.1"
eq "D6 env 0.1: no line" "$(ralerts "$D6C")" "0"

# ── D7: a capped read withholds the alert and says so ──────────────────────
D7=$(tree d7); stub "$D7"
fixture "$D7/review.json" 20 1 50 1
jq '.capped.verdicts = true' "$D7/review.json" > "$D7/r.json" && mv "$D7/r.json" "$D7/review.json"
digest "$D7" --window 24h
eq "D7 run exits 0" "$?" "0"
eq "D7 status ok" "$(rj "$D7" .fleet.review.status)" "ok"
eq "D7 incomplete names the read" "$(rj "$D7" '.fleet.review.incomplete | join(",")')" "verdicts"
eq "D7 no line at 5% vs 2% while the verdicts read is capped" "$(ralerts "$D7")" "0"
grep -q '^review 7d reverts: .*; INCOMPLETE (verdicts read capped), alert withheld$' "$D7/state/dora/latest.txt" \
  && ok || bad "D7 text: $(grep '^review 7d' "$D7/state/dora/latest.txt")"

# ── D8: the module raises -> status error, the digest still writes ──────────
D8=$(tree d8); stub "$D8"
printf '{"verdicts":[],"merges":"not-a-list"}' > "$D8/review.json"
digest "$D8" --window 24h
eq "D8 run exits 0" "$?" "0"
eq "D8 status error" "$(rj "$D8" .fleet.review.status)" "error"
rj "$D8" .fleet.review.unavailable | grep -q 'the review block failed: AttributeError' && ok \
  || bad "D8 names the exception class: $(rj "$D8" .fleet.review.unavailable)"
eq "D8 the rest of the digest is written" "$(rj "$D8" '.fleet | has("conflicts")')" "true"
eq "D8 no line" "$(ralerts "$D8")" "0"

# ── D9: the minimum sample knob: env, then the settings row ────────────────
D9=$(tree d9); stub "$D9"
fixture "$D9/review.json" 1 1 1 0
digest "$D9" --window 24h
eq "D9 default run exits 0" "$?" "0"
eq "D9 low 1/1 vs full 0/1 under min_n 5: no line" "$(ralerts "$D9")" "0"
eq "D9 the json says why: no cohort over" "$(rj "$D9" '.fleet.review.alert.over | length')" "0"
D9E=$(tree d9e); stub "$D9E"
fixture "$D9E/review.json" 1 1 1 0
DORA_REVIEW_TIER_REVERT_MIN_N=1 digest "$D9E" --window 24h
eq "D9 env run exits 0" "$?" "0"
eq "D9 env min_n" "$(rj "$D9E" .fleet.review.min_n_source)/$(rj "$D9E" .fleet.review.min_n)" "env/1"
eq "D9 env min_n 1: one line" "$(ralerts "$D9E")" "1"
D9R=$(tree d9r); stub "$D9R"
fixture "$D9R/review.json" 1 1 1 0
printf '1' > "$D9R/min-n-row"
DORA_REVIEW_TIER_REVERT_MIN_N=9 digest "$D9R" --window 24h
eq "D9 row run exits 0" "$?" "0"
eq "D9 the row wins over env" "$(rj "$D9R" .fleet.review.min_n_source)/$(rj "$D9R" .fleet.review.min_n)" "row/1"
eq "D9 row min_n 1: one line" "$(ralerts "$D9R")" "1"
D9J=$(tree d9j); stub "$D9J"
fixture "$D9J/review.json" 20 1 50 1
DORA_REVIEW_TIER_REVERT_MIN_N=junk digest "$D9J" --window 24h
eq "D9 junk env: default 5" "$(rj "$D9J" .fleet.review.min_n_source)/$(rj "$D9J" .fleet.review.min_n)" "default/5"
eq "D9 junk env: 20 and 50 merges still fire" "$(ralerts "$D9J")" "1"

echo "dora-review-block: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
