#!/bin/bash
# tests/lead-delta-restamp.bh-7118-test.sh — BH-7118: the lead-review enqueue
# carries the lead's word on G to a head H that only restamped a schema.d
# fragment (bin/lib/schema-restamp.sh restamp_same), alone or with a clean
# main merge. Before, ld_classify saw the renamed fragment as a protected path
# in the own delta and answered `full protected:...`: #7012 bought 4 lead
# reviews in one day for renames that changed no SQL.
#
# The fixture is a real git repo built with the real restamp writer (sr_apply).
# Main forks with one stamp fragment; the PR (G) adds a fragment stamped before
# the one main gains after the fork, and a script that names it.
#
#   bin/lib/lead-delta.sh ld_classify <clone> origin/main <G> <H> <slug> MERGE
#     L1  H = the sr_apply restamp                         -> replay restamp
#     L2  H = the restamp, then a one-line script edit     -> not replay
#     L3  H = the restamp, then a clean main merge         -> replay restamp
#     L4  H = a conflict-resolved main merge (alone, and
#         after the restamp)                               -> not replay
#     L5  H = the restamp commit that also changes one byte
#         of the fragment                                  -> not replay
#     L6  H = the restamp of a rewritten G (G is not an
#         ancestor of H)                                   -> not replay
#   bin/lib/lead-gates.d/50-replay-delta.sh lg_gate_replay_delta (gate 50)
#     E1  on L1: rc 12, one post of G's MERGE onto H with note
#         `lead-replay:<G12> how:restamp`, one modes.tsv replay row; a second
#         call posts nothing more
#     E2  on L2: rc 0, no post
#   bin/lead-verdict.sh post (the status description)
#     S1  --note "lead-replay:<sha> how:restamp": state success, description
#         ends `, carried from <sha>`
#     S2  no note: the description is exactly `MERGE by <reviewer> (verdict #21)`
#   M1  mutation: ld_classify without the restamp_same ask -> L1 is a review
#       of the protected fragment (`delta ... protected:...` after a MERGE
#       within LEAD_DELTA_PROTECTED_MAX_LINES, else `full protected:...`)
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-delta-restamp.bh-7118-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/lpp-stub.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
for f in bin/lib/lead-delta.sh bin/lib/schema-restamp.sh bin/lib/patch-same.sh bin/lib/lead-gates.d/50-replay-delta.sh bin/lead-verdict.sh; do
  [ -f "$SRC/$f" ] || { echo "FAIL: $f does not exist"; exit 1; }
done
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.invalid GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.invalid
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset LEAD_DELTA_REVIEW_MAX_LINES LEAD_DELTA_REVIEW_MAX_BYTES LEAD_DELTA_PROTECTED_MAX_LINES
export SR_NOW_EPOCH
SR_NOW_EPOCH=$(date -u -d '2026-10-15 09:00' +%s)

# The writer of the restamp commit is the real one.
# shellcheck source=bin/lib/schema-restamp.sh
. "$SRC/bin/lib/schema-restamp.sh" || { echo "FAIL: cannot source bin/lib/schema-restamp.sh"; exit 1; }

# A scratch harness: gate 50's closure and lead-delta's (with its callers' libs).
Q="$T/hq"; mkdir -p "$Q/bin/lib" "$Q/state" "$Q/logs" "$T/log"
for s in bin/lib/lead-gates.d/50-replay-delta.sh bin/lib/lead-delta.sh bin/lib/lead-authority.sh bin/lib/patch-same.sh bin/lib/lane-gate.sh; do
  scratch_install_closure "$s" "$Q" >/dev/null || bad "setup: closure of $s"
done
mkdir -p "$Q/catalog/lanes.d"; cp "$SRC/catalog/lanes.d/_lib.json" "$SRC/catalog/lanes.d/_lib.lead-delta.json" "$Q/catalog/lanes.d/"
SLUG=example-org/demo-os
LPPF="$T/lpp.json"; LPPDOWN="$T/lpp-down"; lpp_install "$T/lppbin" "$LPPF" "$LPPDOWN"
# The stub bin/lead-verdict.sh: records argv, and appends the row it would write.
ROWS="$T/rows.json"; POSTS="$T/log/posts"
cat > "$Q/bin/lead-verdict.sh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$POSTS"
note=""; prev=""; for a in "\$@"; do [ "\$prev" = --note ] && note="\$a"; prev="\$a"; done
jq -c --arg h "\$4" --arg v "\$5" --arg n "\$note" '.rows += [{id:99, head_sha:\$h, source:"lead", verdict:\$v, note:\$n}]' \
  "$ROWS" > "$ROWS.tmp" && mv "$ROWS.tmp" "$ROWS"
exit 0
EOF
chmod +x "$Q/bin/lead-verdict.sh"
printf 'demo-os %s https://demo.test /api 3 testbox\n' "$SLUG" > "$Q/fleet.conf"
printf 'tok-fixture-1\n' > "$T/tok"

# ───────────────────────────── the fixture repo ─────────────────────────────
O="$T/origin"; C="$T/repos/demo-os"; SD=worker/jobs/schema.d
og() { git -C "$O" "$@"; }
commit() { og add -A; og commit -qm "$1"; og rev-parse HEAD; }
# seed [conflict] — G is the PR's commit; with `conflict` main also edits the
#   script's line 2, which the PR edits too.
seed() {
  scratch_rm "$O" 2>/dev/null; scratch_rm "$C" 2>/dev/null
  mkdir -p "$O/$SD" "$O/bin"; og init -q -b main
  printf 'CREATE TABLE z (id INTEGER);\n' > "$O/$SD/202610140000-bh-0-z.sql"
  printf '#!/bin/bash\necho base\n' > "$O/bin/x.sh"
  commit base >/dev/null
  og checkout -qb pr
  printf 'CREATE TABLE b (id INTEGER);\n' > "$O/$SD/202610142106-bh-1-x.sql"
  printf '#!/bin/bash\n# applies 202610142106-bh-1-x.sql\necho base\n' > "$O/bin/x.sh"
  G=$(commit pr-change); G12=${G:0:12}
  og checkout -q main
  printf 'CREATE TABLE a (id INTEGER);\n' > "$O/$SD/202610150259-bh-9-a.sql"
  [ "${1:-}" = conflict ] && printf '#!/bin/bash\n# main says hello\necho base\n' > "$O/bin/x.sh"
  commit main-a >/dev/null
  og checkout -q pr
}
restamp() { sr_apply "$O" main; }
merge_main() { og merge -q --no-edit main >/dev/null 2>&1; og rev-parse HEAD; }
# merge_resolved — merge main with a conflict on bin/x.sh, resolved by hand
merge_resolved() {
  og merge -q --no-edit main >/dev/null 2>&1 && { echo "FIXTURE-NO-CONFLICT"; return 1; }
  printf '#!/bin/bash\n# applies %s\n# main says hello\necho resolved\n' "$(cd "$O/$SD" && ls | grep -- '-bh-1-x.sql')" > "$O/bin/x.sh"
  og add -A; og commit -q --no-edit; og rev-parse HEAD
}
# clone <H> — the hub clone ld_classify and gate 50 read; H rides refs/pull/31/head
clone() {
  og update-ref refs/pull/31/head "$1"; og update-ref refs/pull/30/head "$G"
  og checkout -q main; mkdir -p "$T/repos"; git clone -q "$O" "$C" 2>/dev/null
  git -C "$C" fetch -q origin "+refs/pull/*:refs/remotes/origin/pull/*" 2>/dev/null
}
# cls <G> <H> [word] [lead-delta copy] — ld_classify as the enqueue and gate 50 run it
cls() {
  ( HARNESS="$Q"; . "$Q/bin/lib/lead-authority.sh"; . "$Q/bin/lib/patch-same.sh"; . "${4:-$Q/bin/lib/lead-delta.sh}"
    setting_get() { return 2; }
    _jobs_req() { lpp_jobs_req "$LPPF" "$LPPDOWN" "$@"; }
    ld_classify "$C" origin/main "$1" "$2" "$SLUG" "${3:-MERGE}" ) 2>/dev/null
}
notreplay() { case "$2" in "replay "*) bad "$1: want a class that is not replay, got '$2'" ;; ?*) ok ;; *) bad "$1: empty class" ;; esac; }

# ── L1: the restamp alone ──
seed; H=$(restamp); clone "$H"
[ "$(og log -1 --format=%s "$H")" = 'restamp schema fragments (no SQL change)' ] && ok || bad "L1 setup: H is not the restamp commit"
V=$(cls "$G" "$H")
[ "$V" = "replay restamp" ] && ok || bad "L1 a restamp-only head: want 'replay restamp', got '$V'"
H_L1=$H; G_L1=$G

# ── L2: the restamp, then a one-line script edit ──
seed; restamp >/dev/null
sed -i 's/^echo base$/echo changed/' "$O/bin/x.sh"; H=$(commit one-line); clone "$H"
V=$(cls "$G" "$H"); notreplay "L2 restamp + one code line" "$V"
H_L2=$H; G_L2=$G

# ── L3: the restamp, then a clean main merge ──
seed; restamp >/dev/null; H=$(merge_main); clone "$H"
[ "$(og rev-list --parents -n 1 "$H" | wc -w)" = 3 ] && ok || bad "L3 setup: H is not a merge commit"
V=$(cls "$G" "$H")
[ "$V" = "replay restamp" ] && ok || bad "L3 restamp + clean main merge: want 'replay restamp', got '$V'"

# ── L4: a conflict-resolved main merge, alone and after the restamp ──
seed conflict; H=$(merge_resolved); clone "$H"
V=$(cls "$G" "$H"); notreplay "L4a a conflict-resolved merge" "$V"
seed conflict; restamp >/dev/null; H=$(merge_resolved); clone "$H"
V=$(cls "$G" "$H"); notreplay "L4b restamp + a conflict-resolved merge" "$V"

# ── L5: the restamp commit also changes one byte of the fragment ──
seed; restamp >/dev/null
f=$(ls "$O/$SD" | grep -- '-bh-1-x.sql'); sed -i 's/INTEGER/INTEGEr/' "$O/$SD/$f"
og add -A; og commit -q --amend --no-edit; H=$(og rev-parse HEAD); clone "$H"
V=$(cls "$G" "$H"); notreplay "L5 a fragment byte change in the restamp commit" "$V"

# ── L6: G is not an ancestor of H (a force-push: G rewritten, then restamped) ──
seed; og commit -q --amend -m "pr-change rewritten"; H=$(restamp); clone "$H"
git -C "$O" merge-base --is-ancestor "$G" "$H" && bad "L6 setup: G is an ancestor of H" || ok
V=$(cls "$G" "$H"); notreplay "L6 G not an ancestor of H" "$V"

# ── E1/E2: gate 50 on the worklist (the production entry point) ──
# gate <G> <H> — lg_gate_replay_delta for $SLUG#31 at H, the lead MERGEd G (row #7)
gate() {
  ( export HARNESS="$Q" REPOS_ROOT="$T/repos" FLEET_CONF="$Q/fleet.conf" LEAD_VERDICT_TOKEN_FILE="$T/tok" JOBS_BOX=testbox
    . "$Q/bin/lib/lead-authority.sh"; . "$Q/bin/lib/patch-same.sh"; . "$Q/bin/lib/lead-delta.sh"
    . "$Q/bin/lib/lead-gates.d/50-replay-delta.sh" || exit 3
    setting_get() { return 2; }
    _jobs_req() {
      case "$2" in /api/verdicts*) [ "$1" = GET ] && cat "$ROWS" ;; *) lpp_jobs_req "$LPPF" "$LPPDOWN" "$@" ;; esac
    }
    lgs_dir() { mkdir -p "$T/lgs" && printf '%s\n' "$T/lgs"; }
    _lgt_log() { echo "$*" >> "$T/log/gate"; }
    LGB_KEY="$SLUG#31@$2"; LGB_APPROVED=0; LGB_REBOUND=0
    lg_gate_replay_delta "$SLUG" 31 "$2" ) 2>>"$T/log/gate.err"
}
egate() {
  scratch_rm "$Q/state/lead-review-enqueue" 2>/dev/null; : > "$POSTS"; : > "$T/log/gate"
  printf '{"rows":[{"id":7,"source":"lead","head_sha":"%s","verdict":"MERGE","note":"lead-review:lr-1"}],"truncated":false}\n' "$1" > "$ROWS"
}
nposts() { grep -c . "$POSTS"; }

seed; H=$(restamp); clone "$H"
egate "$G"
gate "$G" "$H"; rc=$?
[ "$rc" = 12 ] && ok || bad "E1 gate 50 on a restamp-only head: want rc 12, got $rc (log: $(cat "$T/log/gate"))"
want="post $SLUG 31 $H MERGE --source lead --reviewer box:testbox --note lead-replay:$G12 how:restamp"
[ "$(cat "$POSTS")" = "$want" ] && ok || bad "E1 post argv: want '$want', got '$(cat "$POSTS")'"
[ "$(grep -c $'\treplay\t'"$SLUG"$'\t31\t'"$H"$'\tfrom='"$G12"' how=restamp$' "$Q/state/lead-review-enqueue/modes.tsv" 2>/dev/null)" = 1 ] \
  && ok || bad "E1 want one modes.tsv replay row with how=restamp, got: $(cat "$Q/state/lead-review-enqueue/modes.tsv" 2>/dev/null)"
gate "$G" "$H"; rc=$?
[ "$rc" = 12 ] && [ "$(nposts)" = 1 ] && ok || bad "E1 a second call must post nothing more (rc $rc, posts: $(cat "$POSTS"))"

seed; restamp >/dev/null
sed -i 's/^echo base$/echo changed/' "$O/bin/x.sh"; H=$(commit one-line); clone "$H"
egate "$G"
gate "$G" "$H"; rc=$?
[ "$rc" = 0 ] && [ "$(nposts)" = 0 ] && ok || bad "E2 gate 50 on restamp + a code line: want rc 0 and no post (rc $rc, posts: $(cat "$POSTS"), log: $(cat "$T/log/gate"))"

# ── M1: ld_classify without the restamp_same ask answers full on L1 ──
sed 's/how=\$(restamp_same /how=$(false /' "$Q/bin/lib/lead-delta.sh" > "$Q/bin/lib/lead-delta.mut.sh"
if cmp -s "$Q/bin/lib/lead-delta.mut.sh" "$Q/bin/lib/lead-delta.sh"; then
  bad "M1 the mutation anchor 'how=\$(restamp_same ' is missing from bin/lib/lead-delta.sh"
else
  seed; H=$(restamp); clone "$H"
  V=$(cls "$G" "$H" MERGE "$Q/bin/lib/lead-delta.mut.sh")
  case "$V" in "full protected:$SD/"*|"delta "*" protected:$SD/"*) ok ;; *) bad "M1 with the restamp ask removed L1 must be a protected full or delta review, got '$V'" ;; esac
fi
: "${H_L1:?}" "${G_L1:?}" "${H_L2:?}" "${G_L2:?}"

# ── S1/S2: bin/lead-verdict.sh post, the status description ──
HEAD1=aaaaaaaa11111111111111111111111111111111
GH="$T/gh"; W="$T/worker"; mkdir -p "$GH" "$W" "$T/fakebin" "$T/tmp"
cp "$SRC/tests/lib/rest-emit.sh" "$T/fakebin/restpr"; chmod +x "$T/fakebin/restpr"
lpp_install "$T/fakebin" "$T/lpp2.json" "$T/lpp2-down"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$GH/calls"
case "\$*" in
  *"api -i -X GET repos/"*"/pulls/"[0-9]*"/reviews"*) restpr --raw 200 '[]' ;;
  *"api -i -X GET repos/"*"/pulls/"[0-9]*) restpr OPEN "$HEAD1" ticket/x main ;;
  *"api -i -X POST repos/"*"/statuses/"*) restpr --raw 201 '{"id":1}' ;;
  *) echo "" ;;
esac
exit 0
EOF
cat > "$T/fakebin/curl" <<EOF
#!/bin/bash
URL="\${!#}"; M=GET; D=""
while [ \$# -gt 0 ]; do case "\$1" in -X) M="\$2"; shift 2 ;; --data-binary) D="\$2"; shift 2 ;; *) shift ;; esac; done
case "\$M \$URL" in
$(lpp_curl_case M URL D)
  "POST "*/api/verdicts) printf '%s\n201\n' "\$(jq -c '{verdict:(. + {id:21,created_at:"2026-10-16T10:00:00Z"})}' <<<"\$D")" ;;
  *) printf '{"error":"unknown endpoint"}\n404\n' ;;
esac
EOF
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
LH="$T/lh"; mkdir -p "$LH/logs" "$LH/state"
for s in bin/lead-verdict.sh bin/jobs-client.sh; do scratch_install_closure "$s" "$LH" >/dev/null || bad "setup: closure of $s"; done
printf 'lead-test-token\n' > "$T/leadtok"; chmod 600 "$T/leadtok"
# desc [post args...] — the description of the one statuses POST
desc() {
  : > "$GH/calls"
  ( export PATH="$T/fakebin:$PATH" HARNESS="$LH" HARNESS_SECRET=s JOBS_URL=https://jobs.test JOBS_RETRIES=0 \
      JOBS_BOX=mac-lead TMPDIR="$T/tmp" LEAD_VERDICT_TOKEN_FILE="$T/leadtok" GH_APP_TOKENS=0
    unset LEAD_VERDICT_CONTEXT GH_TOKEN
    bash "$LH/bin/lead-verdict.sh" post "$SLUG" 41 "$HEAD1" MERGE "$@" ) >/dev/null 2>"$T/cli.err"
  echo "rc=$?"
  grep -- "-X POST repos/$SLUG/statuses/$HEAD1" "$GH/calls" | sed -n 's/.*-f state=\([a-z]*\).*/state=\1/p'
  grep -- "-X POST repos/$SLUG/statuses/$HEAD1" "$GH/calls" | sed -n 's/.*-f description=\(.*\) -f target_url=.*/\1/p'
}
OUT=$(desc --source lead --note "lead-replay:abc123def456 how:restamp")
grep -qx 'rc=0' <<<"$OUT" && grep -qx 'state=success' <<<"$OUT" && ok || bad "S1 want rc 0 and state success, got: $OUT ($(cat "$T/cli.err"))"
D=$(sed -n 3p <<<"$OUT")
[[ "$D" == *", carried from abc123def456" ]] && ok || bad "S1 the description must end ', carried from abc123def456', got '$D'"
OUT=$(desc --source lead)
D=$(sed -n 3p <<<"$OUT")
[ "$D" = "MERGE by mac-lead (verdict #21)" ] && ok || bad "S2 with no note the description must be 'MERGE by mac-lead (verdict #21)', got '$D' ($OUT)"

echo "lead-delta-restamp: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
