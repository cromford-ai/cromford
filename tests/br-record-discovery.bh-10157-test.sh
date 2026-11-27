#!/bin/bash
# tests/br-record-discovery.bh-10157-test.sh — BH-10157 (BH-9937 C1): the
# resolver's open-list read (br_open_prs) on the PR record. The read goes
# through prr_read blocked-resolver (seam bin/lib/prr-shadow.d/blocked-resolver.sh,
# fragment bin/blocked-resolver.d/bh-10157-record-discovery.sh), by the step
# in the settings row lane.blocked-resolver.gh_source (env GH_SOURCE).
#
#   S1  brs_open_record maps a fresh record list of 10 harness PRs plus 1 PR
#       of another author to 10 rows in the harness_pr_list shape
#   S2  brs_open_record misses: stale, no-sync, truncated, field:updated_at,
#       and unreadable with no author set. Each rc 1 and an empty file
#   S3  brs_state_record maps a peek row merged (at = merged_at), closed and
#       open; a peek miss is `unknown`, rc 1
#   S4  brs_state_norm gives `other` for open and none
#   D1  record, 10 open PRs on a fresh record list, GitHub's list empty: 0
#       GitHub list reads, and br_from_reviews' candidates are the record's
#   D2  shadow: the record lacks #5 and has #99, GitHub the reverse. Exactly 1
#       PRR_SHADOW key=o/p1#open line; the candidates follow GitHub
#   D3  off: 0 /api/pr-records GETs, and 1 GitHub list read
#   D4  record, a stale list: 1 PRR_MISS ... why=stale fallback=github line
#       and 1 GitHub list read
#   D5  BR_OPT_OFF=bh-10157-record-discovery, GH_SOURCE=record: 0
#       /api/pr-records GETs
#   D6  no GH_SOURCE: the step is shadow (1 jobs list GET plus the GitHub read)
#   D7  no seam file on the box, GH_SOURCE=record: today's GitHub read, 0
#       /api/pr-records GETs (fail open)
#
# WHAT IS DRIVEN. The real bin/blocked-resolver.sh, its modules and its
# fragments, lifted up to the drain (the resolver-review-consumer rig), in a
# scratch $HARNESS: br_from_reviews runs the way br_candidates calls it. No
# vendor is called (BH-7563): gh is a local stub that answers from fixture JSON
# and logs every call, GH_TOKEN is empty, and the jobs worker is a stub
# _jobs_req that answers /api/pr-records from fixture JSON.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/br-record-discovery.bh-10157-test.sh
set -uo pipefail
# shellcheck source=tests/lib/scratch.sh
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

# ONE clock read for the file (bin/test-determinism-lint.sh).
NOW=$(date -u +%s)
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }
sha() { printf '%040x' "$1"; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$T/fakebin" "$T/repos" "$T/tmp"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/merge-conductor.sh" "$DIR/bin/fleet-conf.sh" \
   "$DIR/bin/project-of.sh" "$DIR/bin/box-for.sh" "$H/bin/"
mkdir -p "$H/bin/blocked-resolver.d"
cp "$DIR"/bin/blocked-resolver.d/*.sh "$H/bin/blocked-resolver.d/" 2>/dev/null || true
# The files under test, named by rooted path so the orphan check sees them.
FRAG="$DIR/bin/blocked-resolver.d/bh-10157-record-discovery.sh"
SEAMF="$DIR/bin/lib/prr-shadow.d/blocked-resolver.sh"
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
for L in bin/lib/gh-pr-list.sh bin/lib/merge-conductor-lib.sh bin/lib/rebuild-ledger.sh bin/lib/gh-budget.sh \
         bin/lib/hold.sh bin/lib/gh-rest.sh bin/lib/br/opt/profile.sh bin/lib/prr-shadow.sh bin/lib/pr-record.sh \
         $(cd "$DIR" && printf "%s " bin/lib/mc/*.sh); do
  ( cd "$DIR" && scratch_install_closure "$L" "$H" ) >/dev/null || { echo "setup: could not install $L"; exit 1; }
done
# The seam is sourced by prr_seam_load from a computed path, which the closure
# walk cannot follow: install it the same way, by its own closure.
if [ -f "$SEAMF" ]; then
  ( cd "$DIR" && scratch_install_closure bin/lib/prr-shadow.d/blocked-resolver.sh "$H" ) >/dev/null \
    || { echo "setup: could not install the seam"; exit 1; }
fi
chmod +x "$H/bin/"*.sh
printf 'p1 o/p1 - - 2 box-p1 192.0.2.1\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" p1
: > "$H/env/global.env"
for f in beat.sh deploy-request.sh checks-run.sh pool-cap.sh run-build.sh lane-alert.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
"$DIR/bin/lanes-build.sh" --root "$DIR" --to "$T/lanes.json" >/dev/null 2>&1 && [ -s "$T/lanes.json" ] \
  || { echo "FAIL: bin/lanes-build.sh could not compose the registry"; exit 1; }

# THE JOBS STUB. GET /api/pr-records?...state=open answers $T/rec-list.json
# (absent = a failed read); ?...number=<n> answers $T/rec-<n>.json. Every
# request is one line in $T/jobs.txt.
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { return 0; }
queue_list() { return 1; }
_jobs_req() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/jobs.txt"
  case "\$1 \$2" in
    "GET /api/pr-records?"*"state=open"*) [ -f "$T/rec-list.json" ] && cat "$T/rec-list.json" && return 0; return 1 ;;
    "GET /api/pr-records?"*"number="*) local n="\${2##*number=}"; n="\${n%%&*}"
      [ -f "$T/rec-\$n.json" ] && cat "$T/rec-\$n.json" && return 0; return 1 ;;
  esac
  return 1
}
EOF

# THE gh STUB. Every call is a line in $T/gh.txt. Everything is the shared
# stub ($T/openprs is the open list, $T/reviews-<n>.json a PR's reviews).
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/(pull|pulls|issues)/([0-9]+).*#\2#p' | head -1)
case "\$*" in
  *"-i -X "*)
    GHT="$T"
    printf 'ticket/ts-%s' "\$N" > "$T/prbranch"
    printf 'TK-%s: a thing' "\$N" > "$T/prtitle"
    . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"api rate_limit"*) echo '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0},"graphql":{"remaining":4000,"limit":5000,"reset":0}}}' ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
export PATH="$T/fakebin:$PATH"
export GH_TOKEN="" GH_BUDGET_TTL_S=0

awk '/^DONE_KEYS=/{exit} {print}' "$H/bin/blocked-resolver.sh" > "$T/br-lib.sh"
[ -s "$T/br-lib.sh" ] || { echo "FAIL: could not lift the resolver's functions"; exit 1; }
export BRLIB="$T/br-lib.sh"

SHADOW="$H/logs/prr-shadow.log"
LOGF="$H/logs/blocked-resolver.log"
FOOTER='_Automated harness review (Fable) of '
RBODY() { printf 'Two sentences.\n\n1. HIGH src/a.ts:1 fix it.\n\nTIER: 2\nVERDICT: REQUEST_CHANGES\n\n---\n%s%s. Static review — no build run._\n' "$FOOTER" "$1"; }

# gh_open <n>... — GitHub's open list ($T/openprs, the REST array).
gh_open() {
  local n
  for n in "$@"; do
    jq -nc --argjson n "$n" --arg h "$(sha "$n")" --arg u "$(ISO 600)" \
      '{number:$n, html_url:("https://github.com/o/p1/pull/"+($n|tostring)), title:"t", body:"",
        head:{sha:$h, ref:("ticket/ts-"+($n|tostring))}, base:{ref:"main"}, draft:false,
        user:{login:"operator", type:"User"}, created_at:$u, updated_at:$u,
        merged_at:null, closed_at:null, labels:[], state:"open"}'
  done | jq -s . > "$T/openprs"
}
# rec_open [age_s] <n>... — the record's open list, whole; sync age_s as given.
rec_open() {
  local n age="$1"; shift
  for n in "$@"; do
    jq -nc --argjson n "$n" --arg h "$(sha "$n")" --arg u "$(ISO 600)" \
      '{number:$n, head_sha:$h, head_ref:("ticket/ts-"+($n|tostring)), base_ref:"main", author:"operator",
        url:("https://github.com/o/p1/pull/"+($n|tostring)), updated_at:$u, created_at:$u, draft:false}'
  done | jq -s --argjson a "$age" '{rows:., truncated:false, sync:{age_s:$a, synced_at:"2026-11-26T00:00:00Z"}, missing:null, unknown:0}' > "$T/rec-list.json"
}
# rc_review <n>... — a footer REQUEST_CHANGES review at each PR's head.
rc_review() {
  local n
  for n in "$@"; do
    jq -nc --arg c "$(sha "$n")" --arg b "$(RBODY "$(sha "$n")")" \
      '[{id:11, state:"CHANGES_REQUESTED", commit_id:$c, user:{login:"cromford[bot]", type:"Bot"}, body:$b}]' > "$T/reviews-$n.json"
  done
}
CLEAN() { scratch_rm "$H/state/blocked-resolver" 2>/dev/null
          rm -f "$T"/reviews-*.json "$T/rec-list.json" "$T/openprs" "$SHADOW"
          echo '[]' > "$T/openprs"
          : > "$LOGF"; : > "$T/gh.txt"; : > "$T/jobs.txt"; : > "$T/revreads.txt"; }
TICK() { # TICK [VAR=val...] — one discovery pass; candidates in $T/cand.txt
  : > "$T/gh.txt"; : > "$T/jobs.txt"; : > "$T/revreads.txt"
  scratch_rm "$T/tmp" 2>/dev/null; mkdir -p "$T/tmp"
  ( env HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" TMPDIR="$T/tmp" HARNESS_TEST_SANDBOX=1 \
      LANE_REGISTRY="$T/lanes.json" "$@" \
      bash -c 'L="$BRLIB"; set --; . "$L" 2>/dev/null; ONLY=p1; br_from_reviews' \
      > "$T/cand.txt" 2>"$T/tick.err" ) || true
}
CANDS() { cut -f3 "$T/cand.txt" | LC_ALL=C sort | paste -sd' ' -; }
NLIST() { grep -c 'repos/o/p1/pulls?' "$T/gh.txt" 2>/dev/null; }
NRECLIST() { grep -c 'GET /api/pr-records?.*state=open' "$T/jobs.txt" 2>/dev/null; }
NREC() { grep -c '/api/pr-records' "$T/jobs.txt" 2>/dev/null; }

[ -f "$FRAG" ] && ok || bad "0: $FRAG must exist"
[ -f "$SEAMF" ] && ok || bad "0: $SEAMF must exist"

# ============================================================================
# S1-S4 the seam's shapes, in a shell that sources it as prr_seam_load does.
# ============================================================================
SEAM_RUN() { # SEAM_RUN <script> — run a block with the seam and the jobs stub loaded
  ( cd "$T" && env HARNESS="$H" TMPDIR="$T/tmp" LANE_REGISTRY="$T/lanes.json" T="$T" bash -c '
      . "$HARNESS/bin/lib/gh-pr-list.sh" 2>/dev/null
      . "$HARNESS/bin/jobs-client.sh"
      . "$HARNESS/bin/lib/prr-shadow.sh" || exit 3
      prr_seam_load blocked-resolver || { echo noseam; exit 0; }
      '"$1" 2>"$T/seam.err" )
}
# S1
rec_open 5 1 2 3 4 5 6 7 8 9 10
jq '.rows += [{number:11, head_sha:"ABC", head_ref:"b11", base_ref:"main", url:"u11", updated_at:"2026-11-26T00:00:00Z", author:"stranger", draft:false}]
    | .rows[0].draft = 1 | .rows[0].head_sha = "ABCDEF"' "$T/rec-list.json" > "$T/r.tmp" && mv "$T/r.tmp" "$T/rec-list.json"
S1=$(SEAM_RUN 'HARNESS_PR_AUTHORS="operator app/cromford"
  brs_open_record "$T/o.json" o/p1 >/dev/null || { echo rc; exit 0; }
  jq -c "[length, (.[0] | [.number, .url, .headRefOid, .headRefName, .baseRefName, .isDraft, (.updatedAt | test(\"^[0-9-]+T\"))]),
          ([.[].number] | index(11)), (.[1].isDraft)]" "$T/o.json"
  brs_open_norm "$T/o.json" | jq -c ".[0]"')
W1=$(printf '[10,[1,"https://github.com/o/p1/pull/1","ABCDEF","ticket/TK-1","main",true,true],null,false]\n{"n":1,"h":"abcdef","d":true}')
[ "$S1" = "$W1" ] && ok || bad "S1: 10 harness rows in the harness_pr_list shape, the stranger dropped (got '$S1'; err: $(head -3 "$T/seam.err"))"

# S2 — each miss word, rc 1 and an empty file.
s2() { # s2 <case> <want word> <jq edit of the list> [authors]
  rec_open 5 1 2
  jq "$3" "$T/rec-list.json" > "$T/r.tmp" && mv "$T/r.tmp" "$T/rec-list.json"
  local got
  got=$(SEAM_RUN 'HARNESS_PR_AUTHORS="'"${4:-operator}"'"
    echo stale-bytes > "$T/o.json"
    w=$(brs_open_record "$T/o.json" o/p1); rc=$?
    printf "%s:%s:%s" "$rc" "$w" "$(wc -c < "$T/o.json" | tr -d " ")"')
  [ "$got" = "1:$2:0" ] && ok || bad "S2 $1: want '1:$2:0', got '$got' (err: $(head -3 "$T/seam.err"))"
}
s2 stale stale '.sync.age_s = 999999'
s2 no-sync no-sync '.sync = null'
s2 truncated truncated '.truncated = true'
s2 field field:updated_at '.missing = "updated_at"'
s2 no-authors unreadable '.' ' '

# S3 — the peek shapes.
jq -nc '{row:{state:"merged", merged_at:"2026-11-20T00:00:00Z", updated_at:"2026-11-21T00:00:00Z"}, age_s:3}' > "$T/rec-289.json"
jq -nc '{row:{state:"closed", merged_at:null, updated_at:"2026-11-21T00:00:00Z"}, age_s:3}' > "$T/rec-290.json"
jq -nc '{row:{state:"open", merged_at:null, updated_at:"2026-11-22T00:00:00Z"}, age_s:3}' > "$T/rec-291.json"
rm -f "$T/rec-292.json"
S3=$(SEAM_RUN 'for n in 289 290 291; do brs_state_record "$T/s.json" o/p1 $n >/dev/null && cat "$T/s.json"; done
  w=$(brs_state_record "$T/s.json" o/p1 292); echo "$?:$w"')
W3=$(printf '%s\n' '{"number":289,"state":"merged","at":"2026-11-20T00:00:00Z"}' \
  '{"number":290,"state":"closed","at":"2026-11-21T00:00:00Z"}' '{"number":291,"state":"open","at":"2026-11-22T00:00:00Z"}' '1:unknown')
[ "$S3" = "$W3" ] && ok || bad "S3: peek shapes (got '$S3'; err: $(head -3 "$T/seam.err"))"

# S4 — the compare form.
S4=$(SEAM_RUN 'echo "{\"number\":1,\"state\":\"none\"}" > "$T/a.json"; echo "{\"number\":1,\"state\":\"open\",\"at\":\"\"}" > "$T/b.json"
  echo "{\"number\":1,\"state\":\"merged\",\"at\":\"x\"}" > "$T/c.json"
  brs_state_norm "$T/a.json"; brs_state_norm "$T/b.json"; brs_state_norm "$T/c.json"')
W4=$(printf '%s\n' '[{"n":"state","s":"other"}]' '[{"n":"state","s":"other"}]' '[{"n":"state","s":"merged"}]')
[ "$S4" = "$W4" ] && ok || bad "S4: open and none are both other (got '$S4')"

# ============================================================================
# D1 record, 10 open PRs on the record, GitHub's list empty.
# ============================================================================
CLEAN
rec_open 5 1 2 3 4 5 6 7 8 9 10; rc_review 1 2 3
TICK GH_SOURCE=record
[ "$(NLIST)" = 0 ] && ok || bad "D1: record makes 0 GitHub list reads (got $(NLIST): $(grep 'pulls?' "$T/gh.txt" | head -2))"
[ "$(NRECLIST)" = 1 ] && ok || bad "D1: record makes 1 record list read (got $(NRECLIST))"
[ "$(CANDS)" = "o-p1-1 o-p1-2 o-p1-3" ] && ok || bad "D1: the candidates are the record's #1 #2 #3 (got '$(CANDS)'; err: $(head -3 "$T/tick.err"))"
[ "$(grep -c . "$T/revreads.txt")" = 10 ] && ok || bad "D1: the 10 record PRs get their reviews read (got $(grep -c . "$T/revreads.txt"))"

# ============================================================================
# D2 shadow: the record lacks #5 and has #99; GitHub the reverse.
# ============================================================================
CLEAN
gh_open 1 5; rec_open 5 1 99; rc_review 5 99
TICK GH_SOURCE=shadow
[ "$(grep -c 'PRR_SHADOW lane=blocked-resolver key=o/p1#open ' "$SHADOW" 2>/dev/null)" = 1 ] && ok \
  || bad "D2: exactly 1 PRR_SHADOW key=o/p1#open line ($(cat "$SHADOW" 2>/dev/null))"
grep -q 'only_record=1 only_github=1' "$SHADOW" 2>/dev/null && ok || bad "D2: the line counts 1 only_record and 1 only_github"
[ "$(CANDS)" = "o-p1-5" ] && ok || bad "D2: the candidates follow GitHub: #5, not #99 (got '$(CANDS)')"
grep -q '/pulls/99/' "$T/gh.txt" && bad "D2: #99 (record only) is never read" || ok

# ============================================================================
# D3 off: 0 record reads, today's GitHub list read.
# ============================================================================
CLEAN
gh_open 1 2 3; rec_open 5 1 2 3; rc_review 2
TICK GH_SOURCE=off
[ "$(NREC)" = 0 ] && ok || bad "D3: off makes 0 /api/pr-records GETs ($(cat "$T/jobs.txt"))"
[ "$(NLIST)" = 1 ] && [ "$(CANDS)" = o-p1-2 ] && ok || bad "D3: off reads the GitHub list once (got $(NLIST); cands '$(CANDS)')"

# ============================================================================
# D4 record, the record list is stale: one PRR_MISS, one GitHub list read.
# ============================================================================
CLEAN
gh_open 1 2 3; rec_open 999999 1 2 3 4; rc_review 2 4
TICK GH_SOURCE=record
[ "$(grep -c 'PRR_MISS lane=blocked-resolver key=o/p1#open why=stale fallback=github' "$SHADOW" 2>/dev/null)" = 1 ] && ok \
  || bad "D4: 1 PRR_MISS ... why=stale fallback=github line ($(cat "$SHADOW" 2>/dev/null))"
[ "$(NLIST)" = 1 ] && ok || bad "D4: the miss reads the GitHub list once (got $(NLIST))"
[ "$(CANDS)" = o-p1-2 ] && ok || bad "D4: the candidates come from GitHub (got '$(CANDS)')"

# ============================================================================
# D5 the fragment switched off: no record read even in step record.
# ============================================================================
CLEAN
gh_open 1 2 3; rec_open 5 1 2 3; rc_review 2
TICK GH_SOURCE=record BR_OPT_OFF=bh-10157-record-discovery
[ "$(NREC)" = 0 ] && ok || bad "D5: BR_OPT_OFF=bh-10157-record-discovery makes 0 /api/pr-records GETs ($(cat "$T/jobs.txt"))"
[ "$(NLIST)" = 1 ] && [ "$(CANDS)" = o-p1-2 ] && ok || bad "D5: the fragment off reads the GitHub list as today (got $(NLIST); cands '$(CANDS)')"

# ============================================================================
# D6 no GH_SOURCE: the knob's fallback, shadow.
# ============================================================================
CLEAN
gh_open 1 2 3; rec_open 5 1 2 3; rc_review 2
TICK
[ "$(NRECLIST)" = 1 ] && [ "$(NLIST)" = 1 ] && ok || bad "D6: no GH_SOURCE is shadow: 1 record list GET and 1 GitHub list read (got $(NRECLIST) and $(NLIST))"
[ "$(CANDS)" = o-p1-2 ] && ok || bad "D6: shadow acts on GitHub (got '$(CANDS)')"
[ -s "$SHADOW" ] && bad "D6: the same list on both sides writes no shadow line ($(cat "$SHADOW"))" || ok

# ============================================================================
# D7 fail open: the box has no seam file. Step record reads GitHub as today.
# ============================================================================
CLEAN
gh_open 1 2 3; rec_open 5 1 2 3; rc_review 2
mv "$H/bin/lib/prr-shadow.d/blocked-resolver.sh" "$T/seam.away"
TICK GH_SOURCE=record
mv "$T/seam.away" "$H/bin/lib/prr-shadow.d/blocked-resolver.sh"
[ "$(NREC)" = 0 ] && [ "$(NLIST)" = 1 ] && [ "$(CANDS)" = o-p1-2 ] && [ ! -s "$SHADOW" ] && ok \
  || bad "D7: no seam: 0 record GETs, 1 GitHub list read, GitHub's candidates (got $(NREC), $(NLIST), '$(CANDS)'; shadow log: $(cat "$SHADOW" 2>/dev/null); err: $(head -3 "$T/tick.err"))"

echo "br-record-discovery.bh-10157: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
