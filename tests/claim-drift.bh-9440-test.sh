#!/bin/bash
# tests/claim-drift.bh-9440-test.sh — BH-9440 C4: a build whose real diff
# changes a file outside its declared list posts the new files to its claim and
# asks the overlap guard again, before the PR opens (bin/lib/claim-drift.sh,
# called from bin/lib/rb/pr.sh).
#
#   D1  the diff adds src/new.ts outside the claim (src/a.ts): the union is
#       posted through _jobs_req, read back by fclaim_list_dir, kept in
#       <build>/claim-files.txt, state/claims/ is not written (job_claims is
#       its authority, BH-5002), and pipeline.log says `CLAIM_DRIFT n=1`
#   D2  no drift: nothing posted, `CLAIM_DRIFT n=0`, no PR-body section
#   D3  an open PR owns src/new.ts: the guard answers DEFER on the union, the
#       `## Claim drift` section says so, and the PR still opens (rc 0)
#   D4  the claim PUT fails: db=failed is logged, <build>/claim-files.txt
#       still holds the union
#   D5  a claimed directory covers the files under it: no drift
#   D6  a declared touch list is the claim when touch-source is `declared`
#   D7  bin/lib/rb/pr.sh runs the check after the body is written and before
#       the PR create, and inserts the section into the body
#
# Real git, the real bin/overlap-guard.sh against a fresh PR snapshot, a
# file-backed fake jobs client. No network.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); }
bad(){ FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v git >/dev/null || { echo "git missing — skipping"; exit 0; }
unset GH_TOKEN GITHUB_TOKEN

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/flags" "$H/plans" "$H/env" "$H/state/overlap-guard" "$T/fakebin"
: > "$H/env/global.env"
printf 'demo example-org/demo https://demo.example /api/board 0 local -\n' > "$H/fleet.conf"
export HARNESS="$H" FLEET_CONF="$H/fleet.conf" PROJECT=demo KEY=BH-70 JOBS_URL=http://jobs.test JOB_ID=job-70
# The jobs client: PUTs are recorded and stored; GET file-claims answers the
# stored list; GET jobs answers no running build; $T/jobs-fail fails a PUT.
cat > "$H/bin/jobs-client.sh" <<JC
_jobs_req() {
  case "\$1 \$2" in
    "PUT /api/jobs/"*"/file-claim")
      printf 'PUT %s %s\n' "\$2" "\$3" >> "$T/jobs.log"
      [ -e "$T/jobs-fail" ] && return 1
      printf '%s' "\$3" | jq -r '.files' > "$T/claim-store"; echo '{}' ;;
    "GET /api/file-claims"*)
      jq -nc --rawfile f "$T/claim-store" '{claims:[{ticket_id:"BH-70", files_claimed_at:"2026-11-11T00:00:00Z", planned_files:\$f}]}' ;;
    "GET /api/jobs"*) echo '{"jobs":[]}' ;;
    *) return 1 ;;
  esac
}
JC
for L in bin/overlap-guard.sh bin/fleet-conf.sh bin/lib/file-claims.sh bin/lib/claim-drift.sh; do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
rm -f "$H/bin/lib/gh-repo-token.sh"
printf '#!/bin/bash\necho "$*" >> "%s/gh.log"\nexit 1\n' "$T" > "$T/fakebin/gh"; chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
. "$H/bin/jobs-client.sh" || exit 1
. "$H/bin/lib/file-claims.sh" || exit 1
. "$H/bin/lib/claim-drift.sh" || exit 1

# The build worktree: main has src/a.ts; the branch changes it and adds src/new.ts.
R="$T/repo"; mkdir -p "$R/src"
git -C "$R" init -q -b main && git -C "$R" config user.email t@t && git -C "$R" config user.name t
echo a > "$R/src/a.ts"; git -C "$R" add -A && git -C "$R" commit -qm base
git -C "$R" checkout -qb ticket/bh-70
echo b >> "$R/src/a.ts"; echo n > "$R/src/new.ts"; git -C "$R" add -A && git -C "$R" commit -qm work
B="$T/build"
snapshot() { # snapshot <file> — one open PR (#5, feature/x) on <file>, fresh
  jq -nc --arg f "$1" '[{number:5, url:"u", headRefName:"feature/x", isDraft:false, files:[{path:$f}]}]' > "$H/state/overlap-guard/demo-prs.json"
}
reset() { for _p in "$B" "$H/state/claims" "$T/jobs-fail"; do [ -e "$_p" ] && scratch_rm "$_p"; done; mkdir -p "$B"; : > "$T/jobs.log"; : > "$T/claim-store"; snapshot src/other.ts; }
drift() { ( cd "$R" && claim_drift_check "$B" main ); }

# ── D1 ──────────────────────────────────────────────────────────────────────
reset; printf 'src/a.ts\n' > "$B/planned-files.txt"
drift; RC=$?
[ "$RC" = 0 ] && ok || bad "D1: rc 0 ($RC)"
grep -q 'CLAIM_DRIFT n=1 files=src/new.ts db=ok guard=LAUNCH' "$B/pipeline.log" && ok || bad "D1: THE GAP: the drift is logged: $(cat "$B/pipeline.log" 2>/dev/null)"
grep -q '^PUT /api/jobs/job-70/file-claim ' "$T/jobs.log" && ok || bad "D1: the union is posted: $(cat "$T/jobs.log")"
mkdir -p "$T/fc"; fclaim_list_dir demo "$T/fc"; FRC=$?
[ "$FRC" = 0 ] && [ "$(sort "$T/fc/BH-70" 2>/dev/null | paste -sd, -)" = "src/a.ts,src/new.ts" ] && ok \
  || bad "D1: fclaim_list_dir reads the union back (rc $FRC): $(cat "$T/fc/BH-70" 2>/dev/null)"
[ "$(sort "$B/claim-files.txt" 2>/dev/null | paste -sd, -)" = "src/a.ts,src/new.ts" ] && ok || bad "D1: the build's claim-files.txt holds the union"
[ -e "$H/state/claims/demo/BH-70" ] && bad "D1: state/claims is not written (job_claims is the authority)" || ok
grep -q '^## Claim drift' "$B/claim-drift.md" 2>/dev/null && grep -q '`src/new.ts`' "$B/claim-drift.md" && ok || bad "D1: a PR-body section names the file: $(cat "$B/claim-drift.md" 2>/dev/null)"

# ── D2: no drift ────────────────────────────────────────────────────────────
reset; printf 'src/a.ts\nsrc/new.ts\n' > "$B/planned-files.txt"
drift
grep -q 'CLAIM_DRIFT n=0' "$B/pipeline.log" && ok || bad "D2: no drift is logged as n=0: $(cat "$B/pipeline.log")"
[ -s "$T/jobs.log" ] && bad "D2: nothing is posted: $(cat "$T/jobs.log")" || ok
[ -e "$B/claim-drift.md" ] && bad "D2: no PR-body section" || ok

# ── D3: an open PR owns the new file: DEFER, the PR still opens ─────────────
reset; printf 'src/a.ts\n' > "$B/planned-files.txt"; snapshot src/new.ts
drift; RC=$?
[ "$RC" = 0 ] && ok || bad "D3: a DEFER never stops the PR (rc $RC)"
grep -q 'CLAIM_DRIFT n=1 files=src/new.ts db=ok guard=DEFER BH-70 vs PR#5' "$B/pipeline.log" && ok \
  || bad "D3: the guard judged the UNION and deferred on PR #5: $(cat "$B/pipeline.log")"
grep -q 'DEFER BH-70 vs PR#5' "$B/claim-drift.md" && grep -q 'The PR opens anyway' "$B/claim-drift.md" && ok \
  || bad "D3: the section records the DEFER: $(cat "$B/claim-drift.md" 2>/dev/null)"

# ── D4: the claim PUT fails ─────────────────────────────────────────────────
reset; printf 'src/a.ts\n' > "$B/planned-files.txt"; touch "$T/jobs-fail"
drift
grep -q 'CLAIM_DRIFT n=1 .* db=failed ' "$B/pipeline.log" && ok || bad "D4: db=failed is logged: $(cat "$B/pipeline.log")"
grep -qx 'src/new.ts' "$B/claim-files.txt" 2>/dev/null && ok || bad "D4: the build's claim-files.txt still holds the union"

# ── D5: a claimed directory covers its files ────────────────────────────────
reset; printf 'src\n' > "$B/planned-files.txt"
drift
grep -q 'CLAIM_DRIFT n=0' "$B/pipeline.log" && ok || bad "D5: src/ covers src/new.ts: $(cat "$B/pipeline.log")"

# ── D6: the declared touch list is the claim ────────────────────────────────
reset; printf 'src/a.ts\nsrc/new.ts\n' > "$B/planned-files.txt"; printf 'src/a.ts\n' > "$B/touch-files.txt"; echo declared > "$B/touch-source"
drift
grep -q 'CLAIM_DRIFT n=1 files=src/new.ts' "$B/pipeline.log" && ok || bad "D6: the declared list is the claim: $(cat "$B/pipeline.log")"

# ── D7: bin/lib/rb/pr.sh wires it before the create ─────────────────────────
PR="$DIR/bin/lib/rb/pr.sh"
LB=$(grep -n '^PR_BODY_FOR "\$EVIDENCE_SECTION" > "\$BUILD/pr-body.md"' "$PR" | cut -d: -f1)
LC=$(grep -n '^  claim_drift_check "\$BUILD" "origin/\$BASE"' "$PR" | cut -d: -f1)
LI=$(grep -n '_pr_body_insert "\$BUILD/pr-body.md" "\$BUILD/claim-drift.md"' "$PR" | cut -d: -f1)
LP=$(grep -n 'PR_URL=\$(gh_pr_create_ladder' "$PR" | head -n 1 | cut -d: -f1)
[ -n "$LB" ] && [ -n "$LC" ] && [ -n "$LI" ] && [ -n "$LP" ] && [ "$LB" -lt "$LC" ] && [ "$LC" -lt "$LI" ] && [ "$LI" -lt "$LP" ] && ok \
  || bad "D7: pr.sh runs the check after the body ($LB) and before the create ($LP): check=$LC insert=$LI"

[ ! -s "$T/gh.log" ] && ok || bad "no gh call was made: $(head -3 "$T/gh.log")"
echo "claim-drift.bh-9440: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
