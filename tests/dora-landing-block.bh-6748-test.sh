#!/bin/bash
# tests/dora-landing-block.bh-6748-test.sh — the `landing` block of the daily
# DORA digest (BH-6748, wave 5 of #6541): merges by path (direct / queued),
# reverts of direct merges, CI job-minutes per merge, open->merge p50/p90 by
# path and the shadow agreement rate, per project.
#
# U1-U9 call bin/dora_landing.py on in-memory sources in the shape
# bin/lib/landing-sources.sh ls_fetch writes. D1-D8 drive the production entry
# point bin/dora-digest.sh --no-send with a stub bin/jobs-client.sh (_jobs_req
# answers each worker route from a fixture) and a stub bin/lib/gh-rest.sh
# (gh_rest answers the pulls list from a fixture). 0 real vendor calls.
# Every expected number below is counted by hand off the fixture rows.
# Run from anywhere: tests/dora-landing-block.bh-6748-test.sh  (exit 0 = pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
# TEST-CHANGE BH-6052: the json name is the UTC date the code reads and this test reads again; never straddle 00:00Z.
. "$(dirname "$0")/lib/day-boundary.sh" || exit 1
clear_boundary 86400 60 || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }

command -v jq >/dev/null 2>&1 || { echo "dora-landing-block: jq required, skipping"; exit 0; }
for F in "$DIR/bin/dora_landing.py" "$DIR/bin/lib/landing-sources.sh"; do
  [ -r "$F" ] || { echo "FAIL: $F is missing"; exit 1; }
done
TODAY=$(date -u +%F)

# ── U1-U9: the module, on explicit since/until ──────────────────────────────
PYOUT=$(python3 - "$DIR/bin" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import dora_landing as dl
P = F = 0
def check(name, got, want):
    global P, F
    if got == want:
        P += 1
    else:
        F += 1
        print("FAIL: %s: expected %r, got %r" % (name, want, got))

S, U = "2026-10-10T00:00:00Z", "2026-10-11T00:00:00Z"
IN, IN2, OLD = "2026-10-10T12:00:00Z", "2026-10-10T13:00:00Z", "2026-10-09T12:00:00Z"
R = "Org/alpha"
MAP = {R: "alpha", "Org/beta": "beta"}
def h(c):
    return c * 40
def url(n, repo=R):
    return "https://github.com/%s/pull/%d" % (repo, n)
def dec(i, n, mode="shadow", would="direct", at=IN, head=None, reason=None, repo=R):
    return dict(id=i, repo=repo, number=n, head=head or h("a"), mode=mode, would=would,
                reason=reason or ("ok" if would == "direct" else "tier-high"), at=at)
def mrg(n, detail="merge-conductor", at=IN2, status="merged", repo=R):
    return dict(key=url(n, repo), status=status, detail=detail, updated_at=at)
def pull(n, title="t", created="2026-10-10T10:00:00Z", merged=None, labels=(), ref="ticket/x", body="", repo=R):
    return dict(repo=repo, number=n, title=title, created_at=created, merged_at=merged,
                updated_at=merged or created, head_ref=ref, body=body, labels=list(labels))
def bat(m, at=IN2, repo=R):
    return dict(repo=repo, billed_min=m, completed_at=at)
OK = {k: {"status": "ok", "capped": False} for k in ("decisions", "merges", "ci_batches", "pulls", "ejected")}
def src(decisions=(), merges=(), batches=(), pulls=(), ejected=(), sources=None):
    return dict(decisions=list(decisions), merges=list(merges), ci_batches=list(batches),
                pulls=list(pulls), ejected=list(ejected), sources=sources or OK)
def blk(s):
    return dl.block(s, S, U, MAP)
def proj(b, p="alpha"):
    return b["projects"].get(p) or {}
LBL = ["fix-main-red"]

# U1 merge_path table, and the counts per project (a parked row is no merge)
for d, want in [("merge-conductor path=direct", "direct"), ("x path=direct y", "direct"),
                ("merge-conductor", "queued"), (None, "queued"), ("path=directx", "queued"),
                ("path=direct-ish", "queued"), ('{"by":"merge-sweep"}', "queued")]:
    check("U1 merge_path %r" % d, dl.merge_path(d), want)
b = blk(src(decisions=[dec(1, 1)],
            merges=[mrg(1, "merge-conductor path=direct"), mrg(2), mrg(3, None),
                    mrg(4, "merge-conductor path=direct", status="parked"),
                    mrg(5, "merge-conductor path=direct", at=OLD),
                    mrg(6, repo="Org/beta")]))
check("U1 alpha direct (parked and pre-window rows are not merges)", proj(b)["merges"]["direct"], 1)
check("U1 alpha queued", proj(b)["merges"]["queued"], 2)
check("U1 beta has no landing activity: no project row", "beta" in b["projects"], False)

# U2 path near misses are queued
b = blk(src(decisions=[dec(1, 1)],
            merges=[mrg(1, "path=directx"), mrg(2, None), mrg(3, '{"path":"direct"}')]))
check("U2 near misses are queued", (proj(b)["merges"]["direct"], proj(b)["merges"]["queued"]), (0, 3))

# U3 revert_culprit table, then reverts of direct merges
M = "2026-10-10T20:00:00Z"
for name, pr, want in [
        ("label + revert: #123", pull(9, "revert: #123 — t", merged=M, labels=LBL), 123),
        ("label + main-red-revert branch", pull(9, "fix", merged=M, labels=LBL, ref="main-red-revert/pr-123-abcdef012345"), 123),
        ("label + Revert \" + Reverts body", pull(9, 'Revert "x"', merged=M, labels=LBL, body="Some text\nReverts Org/alpha#123\n"), 123),
        ("no label", pull(9, "revert: #123", merged=M), None),
        ("a forward fix", pull(9, "fix main: suite x", merged=M, labels=LBL), None),
        ("not merged", pull(9, "revert: #123 — t", labels=LBL), None),
        ("#1234 is not #123", pull(9, "revert: #1234 — t", merged=M, labels=LBL), 1234),
        ("body names another repo", pull(9, 'Revert "x"', merged=M, labels=LBL, body="Reverts other/repo#123"), None)]:
    check("U3 revert_culprit " + name, dl.revert_culprit(pr, R), want)
check("U3 the label is the knob value", dl.revert_culprit(pull(9, "revert: #5", merged=M, labels=["red"]), R, "red"), 5)
b = blk(src(decisions=[dec(1, 20)],
            merges=[mrg(20, "merge-conductor path=direct"), mrg(21, "merge-conductor path=direct"),
                    mrg(22, "merge-conductor path=direct"), mrg(23)],
            pulls=[pull(60, "revert: #20 — boom", merged=M, labels=LBL),
                   pull(61, "revert: #21 — boom", labels=LBL),
                   pull(62, "revert: #23 — boom", merged=M, labels=LBL)]))
check("U3 direct reverted 1 of 3 (unmerged revert and queued culprit do not count)",
      proj(b)["direct_reverted"], {"reverted": 1, "of": 3})

# U4 ejected: the decided head only
E = ["ejected Org/alpha#5 " + h("e"), "ejected Org/alpha#6 " + h("f"),
     "ejectrebase Org/alpha#7 " + h("a"), "ejected Org/alpha2#8 " + h("a")]
es = dl.parse_ejected(E)
check("U4 the decided head", dl.is_ejected(es, R, 5, h("e")), True)
check("U4 the same PR, another head", dl.is_ejected(es, R, 6, h("a")), False)
check("U4 ejectrebase is not an eject", dl.is_ejected(es, R, 7, h("a")), False)
check("U4 another repo", dl.is_ejected(es, R, 8, h("a")), False)
check("U4 head case", dl.is_ejected(es, R, 5, h("E")), True)

# U5 shadow agreement
b = blk(src(
    decisions=[dec(1, 1), dec(2, 2), dec(3, 3), dec(4, 4, head=h("b")), dec(5, 5), dec(6, 6),
               dec(7, 7, mode="optimistic"), dec(8, 8, would="queue"), dec(9, 9, at=OLD),
               dec(10, 4, head=h("e"))],
    merges=[mrg(n) for n in (1, 2, 3, 4, 5, 7, 8, 9)],
    pulls=[pull(50, "revert: #5 — x", merged=M, labels=LBL)],
    ejected=["ejected Org/alpha#4 " + h("e"), "ejected Org/alpha#1 " + h("z")]))
check("U5 agree 3 of 5, 1 pending", proj(b)["shadow_agreement"],
      {"agree": 3, "of": 5, "rate": 0.6, "pending": 1})
check("U5 text", [l for l in dl.text_lines(b) if l.startswith("landing alpha:")][0].split("; ")[-1],
      "shadow agree 3 of 5 (60.0%, 1 pending)")
b = blk(src(decisions=[dec(1, 1)], merges=[mrg(1, "merge-conductor path=direct")]))
check("U5 a direct-path merge does not agree", proj(b)["shadow_agreement"],
      {"agree": 0, "of": 1, "rate": 0.0, "pending": 0})
b = blk(src(decisions=[dec(1, 1)]))
check("U5 nothing merged: rate None", proj(b)["shadow_agreement"],
      {"agree": 0, "of": 0, "rate": None, "pending": 1})

# U6 CI job-minutes per merge
Q4 = [mrg(n) for n in (1, 2, 3, 4)] + [mrg(5, "merge-conductor path=direct")]
b = blk(src(decisions=[dec(1, 1)], merges=Q4,
            batches=[bat(30), bat(50), bat(40), bat(999, at=OLD), bat(70, repo="Org/beta")]))
c = proj(b)["ci_min_per_merge"]
check("U6 queued (30+50+40)/4", c["queued"], 30.0)
check("U6 direct n/a", c["direct"], None)
check("U6 direct says why", "ci_batches" in (c.get("why_direct") or ""), True)
b = blk(src(decisions=[dec(1, 1)], merges=Q4))
check("U6 no batch rows: n/a", proj(b)["ci_min_per_merge"]["queued"], None)
b = blk(src(decisions=[dec(1, 1)], merges=[mrg(5, "merge-conductor path=direct")], batches=[bat(30)]))
check("U6 0 queued merges: n/a", proj(b)["ci_min_per_merge"]["queued"], None)

# U6b a project with two repos: both repos' batch minutes over both repos' queued merges
b = dl.block(src(decisions=[dec(1, 1)], merges=[mrg(1), mrg(2), mrg(3, repo="Org/two")],
                 batches=[bat(30), bat(60, repo="Org/two")]), S, U, {R: "alpha", "Org/two": "alpha"})
check("U6b two repos (30+60)/3", proj(b)["ci_min_per_merge"]["queued"], 30.0)
check("U6b the repos are named", proj(b)["repos"], ["Org/alpha", "Org/two"])
b = dl.block(src(decisions=[dec(1, 1)], merges=[mrg(1), mrg(3, repo="Org/two")]), S, U, {R: "alpha", "Org/two": "alpha"})
check("U6b two repos, no batch rows: n/a", proj(b)["ci_min_per_merge"]["queued"], None)

# U7 open->merge p50/p90 by path (nearest rank)
check("U7 pctl empty", dl.pctl([], 0.5), None)
check("U7 pctl", (dl.pctl([600, 1200, 3600], 0.5), dl.pctl([600, 1200, 3600], 0.9)), (1200, 3600))
from datetime import datetime, timedelta
def t0(sec_before, at="2026-10-10T12:00:00Z"):
    return (datetime.strptime(at, "%Y-%m-%dT%H:%M:%SZ") - timedelta(seconds=sec_before)).strftime("%Y-%m-%dT%H:%M:%SZ")
D = [(30, 600), (31, 1200), (32, 3600)]
QV = [(40 + i, s) for i, s in enumerate([700, 100, 1000, 300, 900, 200, 500, 400, 800, 600])]
merges = [mrg(n, "merge-conductor path=direct") for n, _ in D] + [mrg(n) for n, _ in QV] + [mrg(99)]
pulls = [pull(n, created=t0(s), merged="2026-10-10T12:00:00Z") for n, s in D + QV]
b = blk(src(decisions=[dec(1, 1)], merges=merges, pulls=pulls))
o = proj(b)["open_to_merge"]
check("U7 direct", o["direct"], {"p50_s": 1200, "p90_s": 3600, "n": 3, "no_open_time": 0})
check("U7 queued (10 values: 5th and 9th)", o["queued"], {"p50_s": 500, "p90_s": 900, "n": 10, "no_open_time": 1})

# U8 no direct merges: the count is 0, every derived figure n/a
b = blk(src(decisions=[dec(1, 1)], merges=[mrg(1)], batches=[bat(10)],
            pulls=[pull(1, created="2026-10-10T11:00:00Z", merged="2026-10-10T12:00:00Z")]))
p = proj(b)
check("U8 direct count 0", p["merges"]["direct"], 0)
check("U8 direct reverted None", p["direct_reverted"], None)
check("U8 direct p50 None", p["open_to_merge"]["direct"]["p50_s"], None)
line = [l for l in dl.text_lines(b) if l.startswith("landing alpha:")][0]
check("U8 text: merges direct 0", "merges direct 0, queued 1" in line, True)
check("U8 text: direct reverted n/a", "; direct reverted n/a;" in line, True)
check("U8 text: direct p50 n/a p90 n/a", "open->merge direct p50 n/a p90 n/a" in line, True)
check("U8 text: never reverted 0 of 0", "0 of 0" in line, False)
check("U8 text: CI direct n/a", "CI job-min/merge queued 10.0, direct n/a" in line, True)

# U9 a source that is not ok: the figures that need it are n/a, never 0 or 100%
# (the refute repro: one shadow PR merged queued, one direct merge).
def st(**bad):
    return {k: dict(v, status=bad.get(k, "ok")) for k, v in OK.items()}
U9 = dict(decisions=[dec(1, 5)], merges=[mrg(5), mrg(6, "merge-conductor path=direct")])
b = blk(src(sources=st(pulls="error", ejected="absent"), **U9))
p = proj(b)
check("U9 pulls error: direct reverted n/a of 1", p["direct_reverted"], {"reverted": None, "of": 1})
check("U9 pulls error: agreement n/a", p["shadow_agreement"], {"agree": None, "of": 1, "rate": None, "pending": 0})
line = [l for l in dl.text_lines(b) if l.startswith("landing alpha:")][0]
check("U9 text: direct reverted n/a of 1", "; direct reverted n/a of 1;" in line, True)
check("U9 text: shadow agree n/a of 1", line.endswith("; shadow agree n/a of 1 (0 pending)"), True)
check("U9 text: no 100%", "100.0%" in line, False)
check("U9 sources line names both", [l for l in dl.text_lines(b) if l.startswith("landing sources:")],
      ["landing sources: decisions ok, merges ok, ci_batches ok, pulls error, ejected absent"])
b = blk(src(sources=st(ejected="absent"), **U9))
p = proj(b)
check("U9 ejected absent only: reverted still counted", p["direct_reverted"], {"reverted": 0, "of": 1})
check("U9 ejected absent only: agreement n/a", p["shadow_agreement"]["agree"], None)
b = blk(src(sources=st(pulls="partial"), **U9))
check("U9 pulls partial: agreement n/a", proj(b)["shadow_agreement"]["rate"], None)
b = blk(src(**U9))
check("U9 every source ok: 1 of 1", proj(b)["shadow_agreement"], {"agree": 1, "of": 1, "rate": 1.0, "pending": 0})
check("U9 every source ok: reverted 0 of 1", proj(b)["direct_reverted"], {"reverted": 0, "of": 1})
print("PY %d %d" % (P, F))
PY
)
PYRC=$?
printf '%s\n' "$PYOUT" | grep '^FAIL' || true
grep -q '^PY ' <<<"$PYOUT" || tail -5 <<<"$PYOUT"
PYP=$(printf '%s\n' "$PYOUT" | awk '/^PY /{print $2}')
PYF=$(printf '%s\n' "$PYOUT" | awk '/^PY /{print $3}')
eq "U1-U9 module run exits 0" "$PYRC" "0"
eq "U1-U9 module failures" "${PYF:-none}" "0"
PASS=$((PASS + ${PYP:-0})); FAIL=$((FAIL + ${PYF:-0}))

# ── D: the production entry point ───────────────────────────────────────────
cat > "$T/fleet.conf" <<'CONF'
alpha  Org/alpha  https://alpha.test  /api/board  1 box-a 192.0.2.1
beta   Org/beta   https://beta.test   -           2 box-b 192.0.2.2
gamma  Org/gamma  https://gamma.test  -           3 box-c 192.0.2.3
CONF
export FLEET_CONF="$T/fleet.conf"
tree() { mkdir -p "$T/$1/logs" "$T/$1/bin/lib" "$T/$1/state/cost" "$T/$1/fx"; printf '%s' "$T/$1"; }
# stub <root> — bin/jobs-client.sh: /api/settings for the kill switch; each
# landing route from fx/ (a missing file = an empty answer of the right shape,
# or $STUB_LANDING_BODY for every landing route when it is set); rc 1 for every
# other path. bin/lib/gh-rest.sh: gh_rest answers the pulls list from fx/
# (or returns $STUB_GH_RC, the quota gate's refusal, when it is set).
stub() {
  cat > "$1/bin/jobs-client.sh" <<'SH'
_fx() { local f="$HARNESS/fx/$1"; if [ -f "$f" ]; then cat "$f"; else printf '%s' "$2"; fi; }
_jobs_req() {
  [ "$2" = /api/settings ] && { printf '{"settings":[]}'; return 0; }
  echo "$*" >> "$HARNESS/calls"
  local r
  case "$2" in
    /api/landing-decisions\?*|/api/ledger\?*|/api/ci-batches\?*)
      [ -n "${STUB_LANDING_BODY:-}" ] && { printf '%s' "$STUB_LANDING_BODY"; return 0; } ;;
  esac
  case "$2" in
    /api/landing-decisions\?repo=*) r="${2#*repo=}"; r="${r%%&*}"; _fx "ld-${r//\//_}.json" '{"rows":[],"truncated":false}' ;;
    /api/ledger\?kind=merge*) _fx ledger.json '{"ledgers":[]}' ;;
    /api/ci-batches\?repo=*) r="${2#*repo=}"; r="${r%%&*}"; _fx "ci-${r//\//_}.json" '{"rows":[],"truncated":false}' ;;
    *) return 1 ;;
  esac
}
if [ -n "${STUB_DECISION_PAGES:-}" ]; then
  setting_get() { [ "$1" = landing.report.decision_pages ] && { echo "$STUB_DECISION_PAGES"; return 0; }; return 2; }
fi
SH
  cat > "$1/bin/lib/gh-rest.sh" <<'SH'
gh_rest() {
  echo "$* optional=${GH_REST_OPTIONAL:-0}" >> "$HARNESS/gh-calls"
  local p="$2" r n
  [ -n "${STUB_GH_RC:-}" ] && { GH_REST_STATUS=000; GH_REST_REASON="quota refused"; return "$STUB_GH_RC"; }
  case "$p" in
    repos/*/pulls\?*) r="${p#repos/}"; r="${r%/pulls*}"; n="${p##*page=}"
      if [ -f "$HARNESS/fx/pulls-${r//\//_}-$n.json" ]; then cat "$HARNESS/fx/pulls-${r//\//_}-$n.json"; else printf '[]'; fi
      GH_REST_STATUS=200; return 0 ;;
  esac
  GH_REST_STATUS=404; return 44
}
SH
}
digest() {
  local h="$1"; shift
  HARNESS="$h" DORA_LEDGER="${LEDGER:-1}" DORA_GH_BUDGET=0 LANDING_ATTEMPTS="$h/attempts.txt" \
    "${DIGEST:-$DIR/bin/dora-digest.sh}" --no-send "$@" > "$h/stdout" 2> "$h/stderr"
}
J() { printf '%s' "$1/state/dora/$TODAY.json"; }
lj() { jq -r "$2" "$(J "$1")"; }
ltxt() { grep '^landing' "$1/state/dora/latest.txt"; }
ghn() { if [ -f "$1/gh-calls" ]; then wc -l < "$1/gh-calls" | tr -d ' '; else echo 0; fi; }

# fixture <root> — alpha: shadow would=direct PRs 1,2,3 (1,2 merged queued, 3
# pending); direct merges 10 and 11; queued merges 1, 2, 12; revert PR 60 of
# #10 (merged); batches 20+25 billed min. beta: one would=queue decision, PR 7
# merged queued. gamma: queued merge 5, no decision (no activity).
fixture() {
  python3 - "$1/fx" <<'PY'
import json, sys, datetime as d
fx = sys.argv[1]
now = d.datetime.now(d.timezone.utc).replace(microsecond=0)
iso = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")
ago = lambda **k: now - d.timedelta(**k)
M = ago(hours=5)
def w(name, obj):
    json.dump(obj, open("%s/%s" % (fx, name), "w"))
def dec(i, n, would="direct", repo="Org/alpha"):
    return dict(id=i, repo=repo, number=n, head=("%x" % n) * 40, mode="shadow", would=would,
                reason="ok" if would == "direct" else "tier-high", at=iso(ago(hours=8)), outcome=None, outcome_at=None)
w("ld-Org_alpha.json", {"rows": [dec(13, 3), dec(12, 2), dec(11, 1),
                                 dict(dec(10, 1), at=iso(ago(days=3)))], "truncated": False})
w("ld-Org_beta.json", {"rows": [dec(20, 7, "queue", "Org/beta")], "truncated": False})
def led(repo, n, detail="merge-conductor", at=M):
    return dict(kind="merge", key="https://github.com/%s/pull/%d" % (repo, n), status="merged",
                detail=detail, updated_at=iso(at))
w("ledger.json", {"ledgers": [led("Org/alpha", 10, "merge-conductor path=direct"),
                              led("Org/alpha", 11, "merge-conductor path=direct"),
                              led("Org/alpha", 1), led("Org/alpha", 2), led("Org/alpha", 12),
                              led("Org/beta", 7), led("Org/gamma", 5),
                              led("Org/alpha", 9, "merge-conductor path=direct", ago(days=2))]})
w("ci-Org_alpha.json", {"rows": [dict(repo="Org/alpha", billed_min=20, completed_at=iso(ago(hours=6))),
                                 dict(repo="Org/alpha", billed_min=25, completed_at=iso(ago(hours=4)))],
                        "truncated": False})
def pr(n, open_s, title="t", labels=(), merged=M):
    return dict(number=n, title=title, created_at=iso(merged - d.timedelta(seconds=open_s)),
                merged_at=iso(merged), updated_at=iso(merged), head={"ref": "ticket/x"}, body="",
                labels=[{"name": l} for l in labels])
w("pulls-Org_alpha-1.json", [pr(10, 7200), pr(11, 600), pr(1, 3600), pr(2, 1800), pr(12, 5400),
                             pr(60, 300, "revert: #10 — boom", ["fix-main-red"], ago(hours=1)),
                             dict(pr(3, 60), merged_at=None, updated_at=iso(ago(days=3)))])
w("pulls-Org_beta-1.json", [pr(7, 900)])
PY
}

# ── D1: the figures through the real digest ────────────────────────────────
D1=$(tree d1); stub "$D1"; fixture "$D1"
# The conductor's attempts file: PR 1 was ejected at ANOTHER head (not the
# decided one) and PR 2 only rebased, so neither breaks the agreement.
printf 'ejected Org/alpha#1 %s\nejectrebase Org/alpha#2 %s\n' "$(printf 'f%.0s' {1..40})" "$(printf '2%.0s' {1..40})" > "$D1/attempts.txt"
digest "$D1" --window 24h
eq "D1 run exits 0" "$?" "0"
eq "D1 status ok" "$(lj "$D1" .fleet.landing.status)" "ok"
eq "D1 alpha direct" "$(lj "$D1" .fleet.landing.projects.alpha.merges.direct)" "2"
eq "D1 alpha queued" "$(lj "$D1" .fleet.landing.projects.alpha.merges.queued)" "3"
eq "D1 alpha direct reverted" "$(lj "$D1" '.fleet.landing.projects.alpha.direct_reverted | "\(.reverted) of \(.of)"')" "1 of 2"
eq "D1 alpha CI min per queued merge (20+25)/3" "$(lj "$D1" '.fleet.landing.projects.alpha.ci_min_per_merge.queued == 15')" "true"
eq "D1 alpha direct p50/p90" "$(lj "$D1" '.fleet.landing.projects.alpha.open_to_merge.direct | "\(.p50_s) \(.p90_s)"')" "600 7200"
eq "D1 alpha queued p50/p90" "$(lj "$D1" '.fleet.landing.projects.alpha.open_to_merge.queued | "\(.p50_s) \(.p90_s)"')" "3600 5400"
eq "D1 alpha shadow" "$(lj "$D1" '.fleet.landing.projects.alpha.shadow_agreement | "\(.agree) \(.of) \(.rate == 1) \(.pending)"')" "2 2 true 1"
eq "D1 gamma has no landing activity" "$(lj "$D1" '.fleet.landing.projects | has("gamma")')" "false"
eq "D1 alpha text" "$(ltxt "$D1" | grep '^landing alpha:')" \
  "landing alpha: merges direct 2, queued 3; direct reverted 1 of 2; CI job-min/merge queued 15.0, direct n/a; open->merge direct p50 10m p90 2h, queued p50 1h p90 1h30m; shadow agree 2 of 2 (100.0%, 1 pending)"
eq "D1 the worker reads, in order" "$(grep -E 'landing-decisions|ledger|ci-batches' "$D1/calls")" \
"GET /api/landing-decisions?repo=Org/alpha&limit=200
GET /api/landing-decisions?repo=Org/beta&limit=200
GET /api/landing-decisions?repo=Org/gamma&limit=200
GET /api/ledger?kind=merge&limit=1000
GET /api/ci-batches?repo=Org/alpha&since=$(lj "$D1" .window.since)&limit=5000
GET /api/ci-batches?repo=Org/beta&since=$(lj "$D1" .window.since)&limit=5000"
eq "D1 the pulls reads: one page per active repo, marked optional" "$(cut -d' ' -f1,2,3 "$D1/gh-calls")" \
"GET repos/Org/alpha/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=1 optional=1
GET repos/Org/beta/pulls?state=closed&sort=updated&direction=desc&per_page=100&page=1 optional=1"
eq "D1 sources: decisions ok, not capped" "$(lj "$D1" '.fleet.landing.sources.decisions | "\(.status) \(.capped)"')" "ok false"
eq "D1 sources: ejected ok (attempts file read)" "$(lj "$D1" .fleet.landing.sources.ejected.status)" "ok"
ltxt "$D1" | grep -q '^landing sources: decisions ok, merges ok, ci_batches ok, pulls ok, ejected ok$' && ok \
  || bad "D1 sources line: $(ltxt "$D1" | grep '^landing sources')"

# ── D8: the pulls read refused (rc 75) and no attempts file: n/a, not 0 or 100%
D8=$(tree d8); stub "$D8"; fixture "$D8"
STUB_GH_RC=75 digest "$D8" --window 24h
eq "D8 run exits 0" "$?" "0"
eq "D8 status ok" "$(lj "$D8" .fleet.landing.status)" "ok"
eq "D8 pulls error" "$(lj "$D8" .fleet.landing.sources.pulls.status)" "error"
eq "D8 sources: ejected absent (no attempts file)" "$(lj "$D8" .fleet.landing.sources.ejected.status)" "absent"
eq "D8 alpha direct reverted: null of 2" "$(lj "$D8" '.fleet.landing.projects.alpha.direct_reverted | "\(.reverted) of \(.of)"')" "null of 2"
eq "D8 alpha shadow: agree null, rate null" "$(lj "$D8" '.fleet.landing.projects.alpha.shadow_agreement | "\(.agree) \(.of) \(.rate) \(.pending)"')" "null 2 null 1"
eq "D8 alpha text" "$(ltxt "$D8" | grep '^landing alpha:')" \
  "landing alpha: merges direct 2, queued 3; direct reverted n/a of 2; CI job-min/merge queued 15.0, direct n/a; open->merge direct p50 n/a p90 n/a, queued p50 n/a p90 n/a; shadow agree n/a of 2 (1 pending)"
ltxt "$D8" | grep -q '^landing sources: decisions ok, merges ok, ci_batches ok, pulls error, ejected absent$' && ok \
  || bad "D8 sources line: $(ltxt "$D8" | grep '^landing sources')"

# ── D3: a project with no direct merges prints n/a for what derives from them
eq "D3 beta direct 0" "$(lj "$D1" .fleet.landing.projects.beta.merges.direct)" "0"
eq "D3 beta text" "$(ltxt "$D1" | grep '^landing beta:')" \
  "landing beta: merges direct 0, queued 1; direct reverted n/a; CI job-min/merge queued n/a, direct n/a; open->merge direct p50 n/a p90 n/a, queued p50 15m p90 15m; shadow agree n/a (0 pending)"

# ── D2: a capped decisions source says so ──────────────────────────────────
D2=$(tree d2); stub "$D2"; fixture "$D2"
jq '.truncated = true | .rows |= map(select(.id != 10))' "$D2/fx/ld-Org_alpha.json" > "$D2/fx/x" && mv "$D2/fx/x" "$D2/fx/ld-Org_alpha.json"
LANDING_REPORT_DECISION_PAGES=1 digest "$D2" --window 24h
eq "D2 run exits 0" "$?" "0"
eq "D2 decisions capped" "$(lj "$D2" .fleet.landing.sources.decisions.capped)" "true"
eq "D2 one decisions page for alpha" "$(grep -c 'landing-decisions?repo=Org/alpha' "$D2/calls")" "1"
ltxt "$D2" | grep -q '^landing sources: decisions ok (capped), ' && ok || bad "D2 text: $(ltxt "$D2")"

# ── D4: a wrong-shape body on the landing routes ───────────────────────────
D4=$(tree d4); stub "$D4"; fixture "$D4"
STUB_LANDING_BODY='{"projects":[]}' digest "$D4" --window 24h
eq "D4 run exits 0" "$?" "0"
eq "D4 status error" "$(lj "$D4" .fleet.landing.status)" "error"
eq "D4 one landing line" "$(ltxt "$D4" | wc -l | tr -d ' ')" "1"
ltxt "$D4" | grep -q '^landing: n/a (' && ok || bad "D4 text: $(ltxt "$D4")"
eq "D4 the rest of the digest is written" "$(lj "$D4" '.fleet | has("conflicts") and has("review")')" "true"
eq "D4 no GitHub read" "$(ghn "$D4")" "0"

# ── D5: bin/dora_landing.py not installed ──────────────────────────────────
D5=$(tree d5); stub "$D5"; fixture "$D5"
mkdir -p "$T/d5root"
scratch_install_closure bin/dora-digest.sh "$T/d5root" >/dev/null || bad "D5 closure of bin/dora-digest.sh"
scratch_install_closure bin/fleet-conf.sh "$T/d5root" >/dev/null || bad "D5 closure of bin/fleet-conf.sh"
# The digest's python and its two other block modules; bin/dora_landing.py is the one left out.
cp "$DIR/bin/dora-digest.py" "$DIR/bin/dora_conflicts.py" "$DIR/bin/dora_review.py" "$T/d5root/bin/"
[ ! -e "$T/d5root/bin/dora_landing.py" ] && ok || bad "D5 the scratch bin must not have dora_landing.py"
DIGEST="$T/d5root/bin/dora-digest.sh" digest "$D5" --window 24h
eq "D5 run exits 0" "$?" "0"
eq "D5 status error" "$(lj "$D5" .fleet.landing.status)" "error"
lj "$D5" .fleet.landing.unavailable | grep -q 'dora_landing.py is not installed' && ok \
  || bad "D5 says not installed: $(lj "$D5" .fleet.landing.unavailable)"

# ── D7: the module raises on a row it cannot read: status error, rc 0 ─────
D7=$(tree d7); stub "$D7"; fixture "$D7"
jq '.rows[0].number = "abc"' "$D7/fx/ld-Org_alpha.json" > "$D7/fx/x" && mv "$D7/fx/x" "$D7/fx/ld-Org_alpha.json"
digest "$D7" --window 24h
eq "D7 run exits 0" "$?" "0"
eq "D7 status error" "$(lj "$D7" .fleet.landing.status)" "error"
lj "$D7" .fleet.landing.unavailable | grep -q 'the landing block failed: ValueError' && ok \
  || bad "D7 names the exception class: $(lj "$D7" .fleet.landing.unavailable)"
eq "D7 the rest of the digest is written" "$(lj "$D7" '.fleet | has("conflicts") and has("review")')" "true"

# ── D6: no landing activity anywhere ───────────────────────────────────────
D6=$(tree d6); stub "$D6"
digest "$D6" --window 24h
eq "D6 run exits 0" "$?" "0"
eq "D6 status ok" "$(lj "$D6" .fleet.landing.status)" "ok"
eq "D6 projects {}" "$(lj "$D6" '.fleet.landing.projects | length')" "0"
eq "D6 no landing text line" "$(ltxt "$D6" | wc -l | tr -d ' ')" "0"
eq "D6 0 GitHub calls" "$(ghn "$D6")" "0"
eq "D6 no ci-batches read" "$(grep -c ci-batches "$D6/calls")" "0"
eq "D6 pulls off" "$(lj "$D6" '.fleet.landing.sources.pulls | "\(.status) \(.why)"')" "off no landing activity"
# The page-cap fallbacks with no row and no env (the settings seeds name them).
eq "D6 knob fallbacks" "$(lj "$D6" '.fleet.landing.sources.knobs | "\(.decision_pages) \(.ledger_pages) \(.gh_pages)"')" "10 5 3"
LEDGER=0 digest "$D6" --window 24h
eq "D6 DORA_LEDGER=0: off" "$(lj "$D6" .fleet.landing.status)" "off"
ltxt "$D6" | grep -q '^landing: off (DORA_LEDGER=0)$' && ok || bad "D6 off text: $(ltxt "$D6")"

echo "dora-landing-block: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
