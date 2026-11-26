#!/bin/bash
# tests/blocked-resolver-verdict-block.bh-9905-test.sh — BH-9905: a standing
# human or lead BLOCK verdict row on the live head of an open harness PR (and a
# review-autopilot box BLOCK whose comment carries a [BLOCK <class>] finding)
# is a fix-round candidate of bin/blocked-resolver.sh.
#
#   V1-V3  bin/lib/verdicts.sh vd_repo_blocks against the fake worker: rows,
#          the worker's own 404 (rc 1), a 500 (rc 2); vd_standing_note
#   C/N    bvb_candidates (the fragment's candidate source), driven for its
#          real TSV over the real libs, the real harness_pr_list and the real
#          jobs transport
#   P1     the cost: one /api/verdict-blocks read per project per tick at 50
#          open PRs, per-PR reads only for the matched PRs
#   E/K    exit paths and knobs
#   L*     THE WHOLE LANE (bin/blocked-resolver.sh), a real local git, an
#          agent fake that records its prompt: the round, the brief, the
#          (PR, head) dedupe with a CHANGES_REQUESTED review, the cap
#          terminal, the moved head, the kill switches, BR_PER_TICK
#   Z1     no request left the fakes, and nothing wrote or retracted a verdict
#
# GitHub is a gh stub (tests/lib/gh-rest-stub.sh), the jobs worker is
# tests/lib/fake-verdict-blocks-worker.bh-9905.py behind a `curl` shim. No
# test reaches a network. Run from anywhere:
#   HARNESS_TEST_SANDBOX=1 bash tests/blocked-resolver-verdict-block.bh-9905-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=tests/lib/verdict-fixture.sh
. "$(dirname "$0")/lib/verdict-fixture.sh" || exit 1
vpf_export || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
FRAG="$DIR/bin/blocked-resolver.d/bh-9905-verdict-block.sh"
[ -r "$FRAG" ] || { echo "FAIL: bin/blocked-resolver.d/bh-9905-verdict-block.sh is missing (BH-9905)"; FAIL=$((FAIL+1)); }

# One clock read for the file (bin/test-determinism-lint.sh): every timestamp
# below is relative to it.
NOW=$(date -u +%s)  # determinism: ok — the lane derives its lookback cutoff from the same clock
ISO() { date -u -d "@$((NOW - ${1:-0}))" '+%Y-%m-%dT%H:%M:%SZ'; }
DAY=86400

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state" "$H/flags" "$H/locks" "$H/env" "$H/builds" \
         "$H/state/merge-conductor" "$H/state/build-queue/tproj" "$T/fakebin" "$T/repos"
cp "$DIR/bin/blocked-resolver.sh" "$DIR/bin/fleet-conf.sh" "$DIR/bin/project-of.sh" \
   "$DIR/bin/box-for.sh" "$DIR/bin/alert-line.sh" "$H/bin/" || exit 1
# shellcheck source=tests/lib/br-modules.sh
. "$DIR/tests/lib/br-modules.sh" || exit 1
br_modules_install "$DIR" "$H" || exit 1
for lib in bin/lib/gh-pr-list.sh bin/lib/merge-conductor-lib.sh bin/lib/gh-budget.sh \
           bin/lib/rebuild-ledger.sh bin/lib/gh-rest.sh bin/lib/hold.sh bin/lib/git-identity.sh \
           bin/lib/verdicts.sh bin/lib/jobs/req.sh bin/lib/tracker/github-issues.sh; do
  scratch_install_closure "$lib" "$H" >/dev/null || { echo "closure install of $lib failed"; exit 1; }
done
export GIT_CONFIG_GLOBAL="$T/gitconfig"
printf '[user]\n\tname = t\n\temail = t@t\n' > "$GIT_CONFIG_GLOBAL"
chmod +x "$H/bin/"*.sh
# Two projects: P1 (the cost test) reads both; every other case seeds tproj only.
printf 'tproj o/tproj - - 2 box-tproj 192.0.2.9\ntproj2 o/tproj2 - - 2 box-tproj 192.0.2.9\n' > "$H/fleet.conf"
export FLEET_CONF="$H/fleet.conf"
. "$DIR/tests/lib/model-route-stub.sh" || exit 1
mrs_fixture "$H" tproj
: > "$H/env/global.env"
for f in run-build.sh deploy-request.sh checks-run.sh pool-cap.sh; do
  printf '#!/bin/bash\nexit 0\n' > "$H/bin/$f"; chmod +x "$H/bin/$f"
done
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/beats.txt"\nexit 0\n' "$T" > "$H/bin/beat.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lane-alert.txt"\nexit 0\n' "$T" > "$H/bin/lane-alert.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/lead-verdict.txt"\necho "requested lead review #r1"\nexit 0\n' "$T" > "$H/bin/lead-verdict.sh"
chmod +x "$H/bin/beat.sh" "$H/bin/lane-alert.sh" "$H/bin/lead-verdict.sh"
# The fragments the lane carries in these cases: the BH-9437 ladder (the review
# park's second round and terminal) and this ticket's.
mkdir -p "$H/bin/blocked-resolver.d" && cp "$DIR"/bin/blocked-resolver.d/bh-9437-*.sh "$H/bin/blocked-resolver.d/" || exit 1
[ -r "$FRAG" ] && { cp "$FRAG" "$H/bin/blocked-resolver.d/" || exit 1; }
# The jobs client: queue writes are recorded, every other request goes through
# the REAL transport (bin/lib/jobs/req.sh) to the fake worker behind `curl`.
VBW="$T/vbw"; mkdir -p "$VBW"
cat > "$H/bin/jobs-client.sh" <<EOF
queue_put() { printf '%s\n' "\$*" >> "$T/queue.txt"; echo queued; }
queue_done() { printf 'done %s\n' "\$*" >> "$T/queue.txt"; return 0; }
queue_list() { return 1; }
JOBS_HARNESS=$H; HARNESS_SECRET=test-secret-fixture; JOBS_URL=https://jobs.invalid; JOBS_RETRIES=0; JOBS_OVERLOAD_RETRIES=0
. $H/bin/lib/jobs/req.sh
EOF
printf '#!/bin/bash\nVBW_STATE=%q exec python3 %q "$@"\n' "$VBW" "$DIR/tests/lib/fake-verdict-blocks-worker.bh-9905.py" > "$T/fakebin/curl"
chmod +x "$T/fakebin/curl"
touch "$H/flags/fly-pool-tproj"

# ---------------------------------------------------------------------------
# Fixtures: the REST shapes GitHub answers with, the verdict rows the worker
# holds, and the comment bin/review-autopilot.sh posts (marker, findings, footer).
# ---------------------------------------------------------------------------
FOOTER='_Automated harness review (Fable) of '
RBODY() { printf 'Two sentences of summary.\n\n1. HIGH src/rate.ts:12 the route is unauthenticated — add the session guard.\n\nTIER: 2\nVERDICT: %s\n\n---\n%s%s. Static review — no build run._\n' "$1" "$FOOTER" "$2"; }
APBODY() { # APBODY <head> <finding lines...> — the autopilot comment, verbatim shape
  local h="$1"; shift
  printf '<!-- harness-review-autopilot %s -->\nThe adversarial pass.\n\n' "${h:0:12}"
  printf '%s\n' "$@"
  printf '\nVERDICT: BLOCK\n\n---\n_Automatic adversarial review (fixture) of `%s`. Push fixes and the next pass reviews the new head._\n' "${h:0:12}"
}
PRWRITE() { jq -s . "$T/prrows" > "$T/openprs"; cp "$T/openprs" "$T/prlist.json"; }
PRRESET() { : > "$T/prrows"; PRWRITE
            rm -f "$T/reviews-"*.json "$T/revrows-"* "$T/pr-"*.json "$T/comments-"*.json "$T/issue-"*.json "$T/icomment-"*.json 2>/dev/null; }
PRADD() { # PRADD <num> <head> <branch> <draft> <age-secs> [login]
  jq -nc --argjson n "$1" --arg h "$2" --arg b "$3" --argjson d "$4" --arg l "${6:-operator}" \
        --arg u "$(ISO "$5")" --arg url "https://github.com/o/tproj/pull/$1" \
    '{number:$n, html_url:$url, title:("TK-"+($n|tostring)+": the work"), body:"body",
      head:{sha:$h, ref:$b}, base:{ref:"main"}, draft:$d,
      user:{login:$l, type:"User"}, created_at:$u, updated_at:$u,
      merged_at:null, closed_at:null, labels:[], state:"open"}' > "$T/pr-$1.json"
  cat "$T/pr-$1.json" >> "$T/prrows"
  PRWRITE
}
REVADD() { # REVADD <num> <id> <state> <commit_id> <login> <body>
  jq -nc --argjson i "$2" --arg s "$3" --arg c "$4" --arg l "$5" --arg b "$6" \
    '{id:$i, state:$s, commit_id:$c, user:({login:$l} + (if ($l | endswith("[bot]")) then {type:"Bot"} else {} end)), body:$b}' >> "$T/revrows-$1"
  jq -s . "$T/revrows-$1" > "$T/reviews-$1.json"
}
CMT() { # CMT <num> <comment-id> <login> <body> — append one issue comment to the PR's thread
  local f="$T/comments-$1.json"; [ -f "$f" ] || echo '[]' > "$f"
  jq --argjson i "$2" --arg l "$3" --arg b "$4" --arg u "https://github.com/o/tproj/pull/$1#issuecomment-$2" \
    '. + [{id:$i, user:{login:$l}, body:$b, html_url:$u}]' "$f" > "$f.tmp" && mv "$f.tmp" "$f"
  jq -nc --argjson n "$1" --argjson c "$(jq length "$f")" '{number:$n,state:"open",title:"FIXTURE",body:"",comments:$c,labels:[{name:"ai-build"}]}' > "$T/issue-$1.json"
  jq -nc --argjson i "$2" --arg l "$3" --arg b "$4" --arg u "https://github.com/o/tproj/pull/$1#issuecomment-$2" \
    '{id:$i, user:{login:$l}, body:$b, html_url:$u}' > "$T/icomment-$2.json"
}
VRESET() { echo '[]' > "$VBW/verdicts.json"; rm -f "$VBW"/missing.* "$VBW"/fail.*; : > "$VBW/requests.log"; }
VB() { # VB <id> <repo> <pr> <head> <verdict> <source> <age-secs> [note] [report_url] [retracted]
  jq --argjson i "$1" --arg r "$2" --argjson p "$3" --arg h "$4" --arg v "$5" --arg s "$6" \
     --arg c "$(ISO "$7")" --arg n "${8:-}" --arg u "${9:-}" --arg x "${10:-}" \
    '. + [{id:$i, repo:$r, pr:$p, head_sha:$h, verdict:$v, source:$s, created_at:$c,
           note:(if $n == "" then null else $n end), report_url:(if $u == "" then null else $u end),
           retracted:($x == "retracted")}]' "$VBW/verdicts.json" > "$VBW/v.tmp" && mv "$VBW/v.tmp" "$VBW/verdicts.json"
}
NREQ() { grep -c -- "$1" "$VBW/requests.log" 2>/dev/null || true; }
RL_HEALTHY='{"resources":{"core":{"remaining":4000,"limit":5000,"reset":0},"graphql":{"remaining":4000,"limit":5000,"reset":0}}}'
printf '%s\n' "$RL_HEALTHY" > "$T/ratelimit.json"
export GH_BUDGET_TTL_S=0

# The gh stub: every call recorded; the REST envelope answered by the shared
# stub, plus the two single-object reads the brief makes (a comment by id and
# a review by id), which the shared stub does not know.
echo '[]' > "$T/empty.json"
cat > "$T/fakebin/gh" <<EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$T/gh.txt"
N=\$(printf '%s' "\$*" | sed -nE 's#.*/pulls/([0-9]+).*#\1#p' | head -1)
# gh applies --jq itself, so the stub applies it too.
JQX=""; PREV=""
for A in "\$@"; do case "\$PREV" in --jq) JQX="\$A" ;; esac; PREV="\$A"; done
emit() { local f="\$1"; [ -s "\$f" ] || f="$T/empty.json"; if [ -n "\$JQX" ]; then jq -r "\$JQX" < "\$f" 2>/dev/null; else cat "\$f"; fi; }
case "\$*" in
  *contents/.mergify.yml*) printf 'HTTP/1.1 404 Not Found\r\nServer: stub\r\n\r\n{"message":"Not Found"}'; exit 0 ;;
  *"-i -X GET"*"/issues/comments/"*)
    I=\$(printf '%s' "\$*" | sed -nE 's#.*/issues/comments/([0-9]+).*#\1#p')
    if [ -f "$T/icomment-\$I.json" ]; then printf 'HTTP/2 200\r\nserver: x\r\n\r\n%s' "\$(cat "$T/icomment-\$I.json")"
    else printf 'HTTP/2 404\r\nserver: x\r\n\r\n{"message":"Not Found"}'; fi; exit 0 ;;
  *"-i -X GET"*"/issues/"*"/comments"*)
    [ -f "$T/comments-fail" ] && { printf 'HTTP/2 500\r\nserver: x\r\n\r\n{}'; exit 0; }
    GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"-i -X POST"*"/comments"*)
    printf 'comment %s\n' "\$*" >> "$T/posted.txt"
    jq -r '.head.sha // ""' "$T/pr-\$N.json" 2>/dev/null > "$T/prhead"
    GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"-i -X "*)
    jq -r '.head.sha // ""' "$T/pr-\$N.json" 2>/dev/null > "$T/prhead"
    jq -r '.head.ref // ""' "$T/pr-\$N.json" 2>/dev/null > "$T/prbranch"
    jq -r '.title // ""'    "$T/pr-\$N.json" 2>/dev/null > "$T/prtitle"
    GHT="$T"; . "$DIR/tests/lib/gh-rest-stub.sh"; gh_rest_stub "\$@" ;;
  *"api rate_limit"*) cat "$T/ratelimit.json" ;;
  *"pr close"*) printf '%s\n' "\$*" >> "$T/closed.txt"; exit 0 ;;
  *"pr comment"*) printf 'pr comment %s\n' "\$2" >> "$T/comments.txt"; printf '%s\n' "\$*" >> "$T/comment-bodies.txt"; exit 0 ;;
  *"--json state"*) echo OPEN ;;
  *"/pulls/"*) emit "$T/pr-\$N.json" ;;
  *) echo "" ;;
esac
exit 0
EOF
chmod +x "$T/fakebin/gh"
printf '#!/bin/bash\nexit 0\n' > "$T/fakebin/flock"; chmod +x "$T/fakebin/flock"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/ssh.txt"\nexit 0\n' "$T" > "$T/fakebin/br-ssh"; chmod +x "$T/fakebin/br-ssh"
export PATH="$T/fakebin:$PATH"
: > "$T/gh.txt"; : > "$T/closed.txt"; : > "$T/comments.txt"; : > "$T/posted.txt"; : > "$T/queue.txt"
export GH_TOKEN=""
# Every request the code makes stays on the fakes: an unset token, gh and curl
# both stubs first on PATH.
VRESET

# ============================================================================
# V. bin/lib/verdicts.sh — the one reader
# ============================================================================
VD() { ( export HARNESS="$H"; . "$H/bin/jobs-client.sh"; . "$H/bin/lib/verdicts.sh"; "$@" ) 2>/dev/null; }
SHA_A=aaaa1111aaaa1111aaaa1111aaaa1111aaaa1111
SHA_B=bbbb2222bbbb2222bbbb2222bbbb2222bbbb2222
SHA_C=cccc3333cccc3333cccc3333cccc3333cccc3333
SHA_OLD=dddd4444dddd4444dddd4444dddd4444dddd4444
VRESET
VB 6214 o/tproj 7 "$SHA_A" BLOCK human 3600 "rename the variable"
VB 6215 o/tproj 8 "$SHA_B" BLOCK box 7200
VB 6216 o/tproj 9 "$SHA_C" MERGE lead 60
VB 6217 o/other 7 "$SHA_A" BLOCK lead 60
VB 6218 o/tproj 10 "$SHA_A" BLOCK lead 60 "" "" retracted
VB 6219 o/tproj 11 "$SHA_A" BLOCK lead $((40 * DAY))
out=$(VD vd_repo_blocks o/tproj "$(ISO $((30 * DAY)))" 500); rc=$?
[ "$rc" = 0 ] && ok || bad "V1 vd_repo_blocks rc 0 on a 200, got $rc"
[ "$(grep -c . <<<"$out")" = 2 ] && ok || bad "V1 two BLOCK rows of o/tproj in the window (not MERGE, not the other repo, not retracted, not 40 days old): $out"
grep -qxF "7	$SHA_A	6214	human	$(ISO 3600)" <<<"$out" && ok || bad "V1 the TSV is pr, head, id, source, created_at: $out"
grep -qxF "8	$SHA_B	6215	box	$(ISO 7200)" <<<"$out" && ok || bad "V1 the box row is in the batch: $out"
[ "$(head -1 <<<"$out" | cut -f3)" = 6214 ] && ok || bad "V1 newest first: $out"
grep -q '^GET /api/verdict-blocks?repo=o/tproj&since=.*&limit=500$' "$VBW/requests.log" && ok || bad "V1 one GET with repo, since and limit: $(cat "$VBW/requests.log")"
touch "$VBW/missing.verdict-blocks"
VD vd_repo_blocks o/tproj "$(ISO $DAY)" 500 >/dev/null; rc=$?
[ "$rc" = 1 ] && ok || bad "V2 the worker's own 404 is rc 1 (route not deployed), got $rc"
rm -f "$VBW/missing.verdict-blocks"; touch "$VBW/fail.verdict-blocks"
VD vd_repo_blocks o/tproj "$(ISO $DAY)" 500 >/dev/null; rc=$?
[ "$rc" = 2 ] && ok || bad "V3 a 500 is rc 2 (unreadable), got $rc"
rm -f "$VBW/fail.verdict-blocks"
VD vd_repo_blocks o/tproj "yesterday" 500 >/dev/null; rc=$?
[ "$rc" = 2 ] && ok || bad "V3b a since that is not an ISO stamp is rc 2 and sends nothing, got $rc"
# vd_standing_note: the standing row and its note, one GET.
out=$(VD vd_standing_note o/tproj 7 "$SHA_A"); rc=$?
[ "$rc" = 0 ] && ok || bad "V4 vd_standing_note rc 0 when a row stands, got $rc"
[ "$(head -1 <<<"$out")" = "BLOCK	6214	human	-" ] && ok || bad "V4 line 1 is verdict, id, source, report_url: $out"
[ "$(sed -n 2p <<<"$out")" = "rename the variable" ] && ok || bad "V4 the note follows: $out"
VD vd_standing_note o/tproj 8 "$SHA_B" >/dev/null; rc=$?
[ "$rc" = 1 ] && ok || bad "V4 a box row never stands: rc 1, got $rc"
touch "$VBW/fail.verdicts"
VD vd_standing_note o/tproj 7 "$SHA_A" >/dev/null; rc=$?
[ "$rc" = 2 ] && ok || bad "V4 unreadable is rc 2, got $rc"
rm -f "$VBW/fail.verdicts"

# ============================================================================
# C / N. bvb_candidates — the source's real TSV
# ============================================================================
awk '/^DONE_KEYS=/{exit} {print}' "$H/bin/blocked-resolver.sh" > "$T/br-lib.sh"
export BRLIB="$T/br-lib.sh"
CAND() { # the rows the source prints; $1 = ONLY (default tproj); env passes through
  ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" ONLYARG="${1-tproj}" \
    bash -c 'L="$BRLIB"; set --; . "$L" 2>/dev/null; ONLY="$ONLYARG"; command -v bvb_candidates >/dev/null || exit 0; bvb_candidates' 2>/dev/null )
}
LOGF="$H/logs/blocked-resolver.log"
FRESH() { PRRESET; VRESET; : > "$LOGF"; scratch_rm "$H/state/blocked-resolver"; : > "$H/state/merge-conductor/pr-state.tsv"; }

# C1: a human BLOCK on the live head, no GitHub review at all.
FRESH
PRADD 21 "$SHA_A" ticket/TK-21 false 600
VB 7001 o/tproj 21 "$SHA_A" BLOCK human 3600 "the fee field must stay editable"
row=$(CAND)
[ "$(grep -c . <<<"$row")" = 1 ] && ok || bad "C1 one candidate for a human BLOCK on the live head, got: $row"
[ "$(cut -f1 <<<"$row")" = verdict-block ] && ok || bad "C1 the source word is verdict-block: $row"
[ "$(cut -f4 <<<"$row")" = review-changes-requested ] && ok || bad "C1 the reason is the review family's: $row"
[ "$(cut -f3 <<<"$row")" = o-tproj-21 ] && ok || bad "C1 the rkey is the one br_from_reviews derives: $row"
[ "$(cut -f5 <<<"$row")" = https://github.com/o/tproj/pull/21 ] && ok || bad "C1 the PR url: $row"
[ "$(cut -f7 <<<"$row")" = TK-21 ] && ok || bad "C1 the ticket key from the branch: $row"
[ "$(awk -F'\t' '{print NF}' <<<"$row")" = 8 ] && ok || bad "C1 the candidate TSV is 8 fields wide: $row"
# C2: a lead BLOCK.
FRESH
PRADD 22 "$SHA_A" ticket/TK-22 false 600
VB 7002 o/tproj 22 "$SHA_A" BLOCK lead 3600 "add the guard"
[ "$(CAND | cut -f1)" = verdict-block ] && ok || bad "C2 a lead BLOCK is a verdict-block candidate: $(CAND)"
# C3: a box BLOCK and the autopilot comment with a [BLOCK <class>] finding.
FRESH
PRADD 23 "$SHA_A" ticket/TK-23 false 600
VB 7003 o/tproj 23 "$SHA_A" BLOCK box 3600
CMT 23 9101 "cromford[bot]" "$(APBODY "$SHA_A" '- [BLOCK wrong-data] the total sums the wrong column')"
row=$(CAND)
[ "$(cut -f1 <<<"$row")" = autopilot-block ] && [ "$(cut -f4 <<<"$row")" = review-changes-requested ] && ok || bad "C3 an autopilot BLOCK is an autopilot-block candidate: $row"
# C4: last updated 5 days ago — still offered (no BR_REVIEW_LOOKBACK_SECS here).
FRESH
PRADD 24 "$SHA_A" ticket/TK-24 false $((5 * DAY))
VB 7004 o/tproj 24 "$SHA_A" BLOCK lead $((2 * DAY)) "fix the E2E"
[ "$(CAND | cut -f1)" = verdict-block ] && ok || bad "C4 a PR updated 5 days ago with a standing BLOCK is offered: $(CAND)"
# C4b: the same PR with only a CHANGES_REQUESTED review — br_from_reviews keeps its lookback.
VRESET
REVADD 24 11 CHANGES_REQUESTED "$SHA_A" "cromford[bot]" "$(RBODY REQUEST_CHANGES "$SHA_A")"
c4b=$( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" bash -c 'L="$BRLIB"; set --; . "$L" 2>/dev/null; ONLY=tproj; br_from_reviews' 2>/dev/null )
[ -z "$c4b" ] && ok || bad "C4b br_from_reviews still skips a review-only PR past 48 h: $c4b"
[ -z "$(CAND)" ] && ok || bad "C4b no verdict row, no verdict-block candidate: $(CAND)"
# C5: the BLOCK row is on an OLDER head.
FRESH
PRADD 25 "$SHA_B" ticket/TK-25 false 600
VB 7005 o/tproj 25 "$SHA_OLD" BLOCK human 3600 "old head"
[ -z "$(CAND)" ] && ok || bad "C5 a BLOCK on an old head is not a candidate: $(CAND)"
# C6: a newer human MERGE stands over the BLOCK on the same head.
FRESH
PRADD 26 "$SHA_A" ticket/TK-26 false 600
VB 7006 o/tproj 26 "$SHA_A" BLOCK human 3600 "x"
VB 7007 o/tproj 26 "$SHA_A" MERGE human 60 "ok now"
[ -z "$(CAND)" ] && ok || bad "C6 a standing MERGE over the BLOCK is no candidate: $(CAND)"
# C7: a draft.
FRESH
PRADD 27 "$SHA_A" ticket/TK-27 true 600
VB 7008 o/tproj 27 "$SHA_A" BLOCK human 3600 "x"
[ -z "$(CAND)" ] && ok || bad "C7 a draft is no candidate: $(CAND)"
# C8: a retracted lead BLOCK.
FRESH
PRADD 28 "$SHA_A" ticket/TK-28 false 600
VB 7009 o/tproj 28 "$SHA_A" BLOCK lead 3600 "x" "" retracted
[ -z "$(CAND)" ] && ok || bad "C8 a retracted BLOCK is no candidate: $(CAND)"
# C9: the conductor already parks this head as review-block (BH-9260 owns it).
FRESH
PRADD 29 "$SHA_A" ticket/TK-29 false 600
VB 7010 o/tproj 29 "$SHA_A" BLOCK box 3600
CMT 29 9102 "cromford[bot]" "$(APBODY "$SHA_A" '- [BLOCK core-flow-broken] the button is dead')"
printf 'o/tproj#29\tBLOCKED_HUMAN\t%s\t%s\t%s\t-\t%s\t%s\n' "$NOW" "$SHA_A" "$SHA_A" \
  "review-block: 9102 [BLOCK core-flow-broken] https://github.com/o/tproj/pull/29#issuecomment-9102" \
  https://github.com/o/tproj/pull/29 > "$H/state/merge-conductor/pr-state.tsv"
[ -z "$(CAND)" ] && ok || bad "C9 a conductor review-block park on the same head is not offered twice: $(CAND)"
: > "$H/state/merge-conductor/pr-state.tsv"
[ "$(CAND | cut -f1)" = autopilot-block ] && ok || bad "C9 without the park the same PR is an autopilot-block: $(CAND)"

# N1-N6: an autopilot comment that does not qualify buys nothing.
NCASE() { # NCASE <name> <login> <body> [no-comment]
  FRESH
  PRADD 31 "$SHA_A" ticket/TK-31 false 600
  VB 7020 o/tproj 31 "$SHA_A" BLOCK box 3600
  [ "${4:-}" = no-comment ] || CMT 31 9201 "$2" "$3"
  local got; got=$(CAND)
  [ -z "$got" ] && ok || bad "$1: not a candidate, got: $got"
}
NCASE "N1 [NOTE] findings only" "cromford[bot]" "$(APBODY "$SHA_A" '- [NOTE] a px off' '- [NOTE] copy')"
NCASE "N2 [BLOCK needs-human] only" "cromford[bot]" "$(APBODY "$SHA_A" '- [BLOCK needs-human] set the DNS record')"
NCASE "N3 a marker for another head" "cromford[bot]" "$(APBODY "$SHA_B" '- [BLOCK wrong-data] x')"
NCASE "N4 an untrusted login" "someuser" "$(APBODY "$SHA_A" '- [BLOCK wrong-data] x')"
NCASE "N5 [BLOCK console-qa] only" "cromford[bot]" "$(APBODY "$SHA_A" '- [BLOCK console-qa] the screenshot')"
NCASE "N6 a box BLOCK with no autopilot comment" "" "" no-comment
NCASE "N7 [BLOCK inside a [NOTE] line and a code fence" "cromford[bot]" "$(APBODY "$SHA_A" '- [NOTE] the old review said [BLOCK wrong-data]' '```' '- [BLOCK wrong-data] quoted' '```')"
# N8: the newest autopilot comment decides: a BLOCK review then a clean re-review on the same head.
FRESH
PRADD 32 "$SHA_A" ticket/TK-32 false 600
VB 7021 o/tproj 32 "$SHA_A" BLOCK box 3600
CMT 32 9301 "cromford[bot]" "$(APBODY "$SHA_A" '- [BLOCK wrong-data] x')"
CMT 32 9302 "cromford[bot]" "$(APBODY "$SHA_A" '- [NOTE] fine now')"
[ -z "$(CAND)" ] && ok || bad "N8 the newest autopilot comment has no BLOCK finding: not a candidate, got: $(CAND)"
# N9: a human BLOCK whose note asks a person (needs-human) is not a code round.
FRESH
PRADD 33 "$SHA_A" ticket/TK-33 false 600
VB 7022 o/tproj 33 "$SHA_A" BLOCK human 3600 "[BLOCK needs-human] the Stripe key"
[ -z "$(CAND)" ] && ok || bad "N9 a needs-human BLOCK note is not a fix round: $(CAND)"

# ============================================================================
# E / K. exit paths and knobs
# ============================================================================
FRESH
PRADD 41 "$SHA_A" ticket/TK-41 false 600
VB 7041 o/tproj 41 "$SHA_A" BLOCK human 3600 "x"
got=$(BR_VERDICT_BLOCK=0 CAND)
[ -z "$got" ] && ok || bad "E1 BR_VERDICT_BLOCK=0: no candidate, got $got"
[ "$(NREQ 'verdict-blocks')" = 0 ] && ok || bad "E1 BR_VERDICT_BLOCK=0 reads nothing: $(cat "$VBW/requests.log")"
: > "$VBW/requests.log"; touch "$VBW/fail.verdict-blocks"; : > "$LOGF"
[ -z "$(CAND)" ] && ok || bad "E2 an unreadable batch read is no candidate"
grep -q 'standing-BLOCK read failed' "$LOGF" && ok || bad "E2 the failed batch read is said: $(cat "$LOGF")"
rm -f "$VBW/fail.verdict-blocks"; touch "$VBW/fail.verdicts"; : > "$LOGF"
[ -z "$(CAND)" ] && ok || bad "E3 an unreadable per-PR confirm is no candidate"
grep -q 'standing verdict.*could not be read' "$LOGF" && ok || bad "E3 the unreadable confirm is said: $(cat "$LOGF")"
rm -f "$VBW/fail.verdicts"
# K3/K4: the lookback and the limit are the knobs (lane_env_apply sets them from
# the settings rows lane.blocked-resolver.br_verdict_block_*); unset = the fallbacks.
: > "$VBW/requests.log"
BR_VERDICT_BLOCK_LOOKBACK_DAYS=2 BR_VERDICT_BLOCK_LIMIT=7 CAND >/dev/null
q=$(grep -m1 'verdict-blocks' "$VBW/requests.log")
since=$(sed -nE 's/.*since=([^&]*).*/\1/p' <<<"$q"); sep=$(date -u -d "$since" +%s 2>/dev/null || echo 0)
d=$(( sep - (NOW - 2 * DAY) )); [ "$d" -ge 0 ] && [ "$d" -lt 1800 ] && ok || bad "K3 BR_VERDICT_BLOCK_LOOKBACK_DAYS=2 reads 2 days back: $q"
grep -q 'limit=7$' <<<"$q" && ok || bad "K3 BR_VERDICT_BLOCK_LIMIT=7 is the limit: $q"
: > "$VBW/requests.log"
CAND >/dev/null
q=$(grep -m1 'verdict-blocks' "$VBW/requests.log")
since=$(sed -nE 's/.*since=([^&]*).*/\1/p' <<<"$q"); sep=$(date -u -d "$since" +%s 2>/dev/null || echo 0)
d=$(( sep - (NOW - 30 * DAY) )); [ "$d" -ge 0 ] && [ "$d" -lt 1800 ] && ok || bad "K4 the lookback fallback is 30 days: $q"
grep -q 'limit=500$' <<<"$q" && ok || bad "K4 the limit fallback is 500: $q"

# ============================================================================
# P1. the cost: 2 projects x 50 open PRs, 3 BLOCK rows on live heads
# ============================================================================
FRESH
for n in $(seq 101 150); do PRADD "$n" "$(printf '%040x' "$n")" "ticket/ts-$n" false 600; done
VB 8001 o/tproj 110 "$(printf '%040x' 110)" BLOCK human 3600 "a"
VB 8002 o/tproj 120 "$(printf '%040x' 120)" BLOCK lead 3600 "b"
VB 8003 o/tproj2 130 "$(printf '%040x' 130)" BLOCK human 3600 "c"
VB 8004 o/tproj 140 "$SHA_OLD" BLOCK human 3600 "an old head"
: > "$VBW/requests.log"
got=$(CAND "")
[ "$(grep -c . <<<"$got")" = 3 ] && ok || bad "P1 three candidates over two projects, got: $got"
[ "$(NREQ ' /api/verdict-blocks?')" = 2 ] && ok || bad "P1 exactly one batch read per project (2), got $(NREQ ' /api/verdict-blocks?')"
nper=$(NREQ ' /api/verdicts?')
[ "$nper" = 3 ] && ok || bad "P1 one per-PR read for each of the 3 matched PRs (the old-head row costs nothing), got $nper: $(cat "$VBW/requests.log")"

# ============================================================================
# L. THE WHOLE LANE — the real script, the real candidate wiring, a real git
# ============================================================================
ORIGIN="$T/origin.git"; SEED="$T/seed"
git init -q --bare "$ORIGIN"
git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main
git init -q "$SEED"
git -C "$SEED" config user.email t@t; git -C "$SEED" config user.name t
git -C "$SEED" remote add origin "$ORIGIN"
printf 'line one\n' > "$SEED/a.txt"
git -C "$SEED" add -A; git -C "$SEED" commit -qm base
git -C "$SEED" branch -M main; git -C "$SEED" push -q origin main
mkbranch() {
  git -C "$SEED" checkout -q main
  git -C "$SEED" checkout -q -b "$1"
  printf '%s\n' "$1" > "$SEED/f-${1##*/}.txt"
  git -C "$SEED" add -A; git -C "$SEED" commit -qm "work on $1"; git -C "$SEED" push -q origin "$1"
}
for b in 61 62 63 64 65 66 67 68; do mkbranch "ticket/ts-$b"; done
git clone -q "$ORIGIN" "$T/repos/tproj"
git -C "$T/repos/tproj" config user.email t@t; git -C "$T/repos/tproj" config user.name t
osha() { git -C "$ORIGIN" rev-parse "$1"; }
cat > "$H/bin/agent-call.sh" <<EOF
#!/bin/bash
printf 'agent-call %s %s\n' "\$1" "\$2" >> "$T/agent.txt"
printf '%s\n=====\n' "\$6" >> "$T/prompt.txt"
if [ -f "$T/agent-commits" ]; then
  printf 'the finding, answered\n' > answered.txt
  git add -A >/dev/null 2>&1
  git -c user.email=t@t -c user.name=t commit -q -m "fix round: answered the BLOCK" >/dev/null 2>&1
fi
exit 0
EOF
chmod +x "$H/bin/agent-call.sh"
BRENV=()
RUN() { ( HARNESS="$H" FLEET_CONF="$H/fleet.conf" REPOS_ROOT="$T/repos" BR_SSH="$T/fakebin/br-ssh" \
          env ${BRENV[*]:+"${BRENV[@]}"} bash "$H/bin/blocked-resolver.sh" tproj >>"$T/run.log" 2>&1 ) || true; }
STATEJSON() { cat "$H/state/blocked-resolver/tproj/$1.json" 2>/dev/null; }
RESET() { : > "$T/agent.txt"; : > "$T/prompt.txt"; : > "$T/closed.txt"; : > "$T/comments.txt"
          : > "$T/comment-bodies.txt"; : > "$T/posted.txt"; : > "$T/queue.txt"; : > "$LOGF"
          : > "$H/logs/ALERTS.log"; scratch_rm "$H/state/gh-budget"; rm -f "$H/flags/blocked-resolver-disabled" "$H/flags/automerge-disabled"; BRENV=(); }
NAGENT() { grep -c . "$T/agent.txt" 2>/dev/null || true; }
FRESH; RESET

# L1 (C1 end to end, B1): a human BLOCK row, no review -> ONE round, the note is the brief.
S61=$(osha ticket/TK-61)
PRADD 61 "$S61" ticket/TK-61 false 600
VB 9001 o/tproj 61 "$S61" BLOCK human 3600 "NOTE-61: the discount toggle must stay, rename the field"
touch "$T/agent-commits"
RUN
[ "$(NAGENT)" = 1 ] && ok || bad "L1 a human BLOCK row buys exactly one fix round, got $(NAGENT) (log: $(tail -5 "$LOGF"))"
grep -q 'o-tproj-61 \[verdict-block/review-changes-requested\] -> fix-round' "$LOGF" && ok || bad "L1 the log line names the source and reason: $(grep -- '->' "$LOGF" | head -3)"
grep -q 'NOTE-61: the discount toggle must stay' "$T/prompt.txt" && ok || bad "B1 the row note is in the round's prompt: $(head -c 600 "$T/prompt.txt")"
grep -q "BLOCK verdict #9001 by human on ${S61:0:12}" "$T/prompt.txt" && ok || bad "B1 the brief names the row: $(head -c 600 "$T/prompt.txt")"
grep -q 'LEAD FINDINGS' "$T/prompt.txt" && ok || bad "B1 the brief is framed as the lead's findings (the lead gate applies)"
[ "$(STATEJSON tproj-TK-61 | jq -r '.review_fix_heads | join(",")')" = "$S61" ] && ok || bad "L1 the (PR, head) key is recorded: $(STATEJSON tproj-TK-61 | jq -c .review_fix_heads)"
[ "$(osha ticket/TK-61)" != "$S61" ] && ok || bad "L1 the round pushed a new head"
# D3: the PR's head moved to the pushed one; the old-head row no longer binds.
N61=$(osha ticket/TK-61)
PRRESET; PRADD 61 "$N61" ticket/TK-61 false 600
: > "$T/agent.txt"; : > "$LOGF"
RUN
[ "$(NAGENT)" = 0 ] && ok || bad "D3 after the push the old-head row buys nothing, got $(NAGENT)"
grep -q 'verdict-block' "$LOGF" && bad "D3 no verdict-block candidate on the new head: $(grep verdict-block "$LOGF")" || ok

# B2: a lead BLOCK whose report_url is a comment on THIS PR — the comment body joins the brief.
FRESH; RESET; rm -f "$T/agent-commits"
S62=$(osha ticket/TK-62)
PRADD 62 "$S62" ticket/TK-62 false 600
CMT 62 5551 operator "LINKED-62: the totals row double counts refunds"
VB 9002 o/tproj 62 "$S62" BLOCK lead 3600 "see the comment" "https://github.com/o/tproj/pull/62#issuecomment-5551"
RUN
[ "$(NAGENT)" = 1 ] && ok || bad "B2 one round, got $(NAGENT) (log: $(tail -4 "$LOGF"))"
grep -q 'LINKED-62: the totals row double counts refunds' "$T/prompt.txt" && ok || bad "B2 the linked comment body is in the prompt: $(head -c 800 "$T/prompt.txt")"
grep -q 'see the comment' "$T/prompt.txt" && ok || bad "B2 the note itself is in the prompt too"

# B3 (C3 end to end): the autopilot comment is the brief.
FRESH; RESET
S63=$(osha ticket/TK-63)
PRADD 63 "$S63" ticket/TK-63 false 600
VB 9003 o/tproj 63 "$S63" BLOCK box 3600
CMT 63 9401 "cromford[bot]" "$(APBODY "$S63" '- [BLOCK wrong-data] AUTOPILOT-63 the E2E asserts hidden DOM')"
RUN
[ "$(NAGENT)" = 1 ] && ok || bad "B3 one round on an autopilot BLOCK, got $(NAGENT) (log: $(tail -4 "$LOGF"))"
grep -q 'o-tproj-63 \[autopilot-block/review-changes-requested\] -> fix-round' "$LOGF" && ok || bad "B3 the log names autopilot-block: $(grep -- '->' "$LOGF" | head -3)"
grep -q 'AUTOPILOT-63 the E2E asserts hidden DOM' "$T/prompt.txt" && ok || bad "B3 the autopilot comment is in the prompt"
grep -q "AUTOPILOT REVIEW FINDINGS (harness-review-autopilot on ${S63:0:12})" "$T/prompt.txt" && ok || bad "B3 the comment is framed as the autopilot's findings"

# D1 / B4: a CHANGES_REQUESTED review AND a BLOCK row on one head -> one round over two ticks.
FRESH; RESET
S64=$(osha ticket/TK-64)
PRADD 64 "$S64" ticket/TK-64 false 600
REVADD 64 11 CHANGES_REQUESTED "$S64" "cromford[bot]" "$(RBODY REQUEST_CHANGES "$S64")"
VB 9004 o/tproj 64 "$S64" BLOCK human 3600 "NOTE-64 also check the guard"
touch "$T/agent-commits"
RUN
[ "$(NAGENT)" = 1 ] && ok || bad "D1 a review and a BLOCK row on one head are one round in the tick, got $(NAGENT)"
grep -q 'o-tproj-64 \[reviews/review-changes-requested\]' "$LOGF" && grep -q 'tick: candidates=2 ' "$LOGF" \
  && ok || bad "D1 both sources offered the PR (2 candidates, one round): $(grep -E 'tick:|o-tproj-64' "$LOGF" | head -4)"
[ "$(grep -c 'the route is unauthenticated' "$T/prompt.txt")" = 1 ] && ok || bad "B4 the review body is in the prompt once: $(grep -c 'the route is unauthenticated' "$T/prompt.txt")"
[ "$(grep -c 'NOTE-64 also check the guard' "$T/prompt.txt")" = 1 ] && ok || bad "B4 the row note is in the prompt once: $(grep -c 'NOTE-64' "$T/prompt.txt")"
: > "$T/agent.txt"; : > "$LOGF"
RUN
[ "$(NAGENT)" = 0 ] && ok || bad "D1 tick 2 on the same head buys nothing, got $(NAGENT)"
grep -q 'fix round already ran on' "$LOGF" && ok || bad "D1 tick 2 says why: $(tail -4 "$LOGF")"

# D2: the cap is spent -> the existing terminal, no further round.
FRESH; RESET
S65=$(osha ticket/TK-65)
PRADD 65 "$S65" ticket/TK-65 false 600
VB 9005 o/tproj 65 "$S65" BLOCK human 3600 "still wrong"
mkdir -p "$H/state/blocked-resolver/tproj"
jq -nc '{project:"tproj",rkey:"tproj-TK-65",fixrounds:2,rebuilds:0,mechanicals:0,outcome:"",review_fix_heads:["oldheadone","oldheadtwo"],
   attempts:[{at:"2026-11-20T10:00:00Z",action:"fix-round",reason:"review-changes-requested",detail:"pushed aaaa111 to ticket/TK-65"}]}' \
  > "$H/state/blocked-resolver/tproj/tproj-TK-65.json"
RUN
[ "$(NAGENT)" = 0 ] && ok || bad "D2 a spent cap buys no round, got $(NAGENT)"
oc=$(STATEJSON tproj-TK-65 | jq -r '.outcome // ""')
[ -n "$oc" ] && ok || bad "D2 the terminal recorded an outcome (log: $(tail -5 "$LOGF"))"
[ "$(STATEJSON tproj-TK-65 | jq -r .fixrounds)" = 2 ] && ok || bad "D2 no further round counted"
: > "$T/agent.txt"; RUN
[ "$(NAGENT)" = 0 ] && ok || bad "D2 the next tick buys nothing either, got $(NAGENT)"

# K1: flags/blocked-resolver-disabled -> nothing.
FRESH; RESET
S66=$(osha ticket/TK-66)
PRADD 66 "$S66" ticket/TK-66 false 600
VB 9006 o/tproj 66 "$S66" BLOCK human 3600 "x"
touch "$H/flags/blocked-resolver-disabled"
RUN
[ "$(NAGENT)" = 0 ] && ok || bad "K1 blocked-resolver-disabled: 0 rounds, got $(NAGENT)"
grep -q 'verdict-block' "$LOGF" && bad "K1 nothing is offered: $(grep verdict-block "$LOGF")" || ok
# K2: the automerge kill switch -> a WOULD line, no round, no queue row.
rm -f "$H/flags/blocked-resolver-disabled"; touch "$H/flags/automerge-disabled"; : > "$LOGF"
RUN
[ "$(NAGENT)" = 0 ] && ok || bad "K2 automerge-disabled: 0 rounds, got $(NAGENT)"
grep -q 'o-tproj-66.*WOULD' "$LOGF" && ok || bad "K2 a WOULD line for the verdict-block row: $(grep o-tproj-66 "$LOGF" | head -3)"
grep -q . <<<"$(grep -v '^done ' "$T/queue.txt")" && bad "K2 nothing enqueued: $(cat "$T/queue.txt")" || ok
rm -f "$H/flags/automerge-disabled"

# E4: three candidates and BR_PER_TICK=1 -> one round this tick.
FRESH; RESET
for b in 66 67 68; do
  s=$(osha "ticket/ts-$b"); PRADD "$b" "$s" "ticket/ts-$b" false 600
  VB "$((9100 + b))" o/tproj "$b" "$s" BLOCK human 3600 "note $b"
done
BRENV=(BR_PER_TICK=1)
RUN
[ "$(NAGENT)" = 1 ] && ok || bad "E4 BR_PER_TICK=1 with 3 candidates: one round, got $(NAGENT)"

# ============================================================================
# Z1. nothing left the fakes; this lane writes and retracts no verdict
# ============================================================================
grep -qvE '^(GET|POST|PUT|DELETE|PATCH) /' "$VBW/requests.log" && bad "Z1 a malformed worker request line" || ok
grep -qE '^(POST|PUT|DELETE|PATCH) /api/verdict' "$VBW/requests.log" && bad "D4 the lane wrote a verdict: $(grep -E '^(POST|PUT) /api/verdict' "$VBW/requests.log")" || ok
grep -qi 'retract' "$VBW/requests.log" && bad "D4 the lane retracted a verdict: $(grep -i retract "$VBW/requests.log")" || ok
grep -qE '/api/verdict|_jobs_req' <<<"$(grep -v '^[[:space:]]*#' "$FRAG")" && bad "T2 the fragment names a verdicts route itself (one reader: bin/lib/verdicts.sh)" || ok

echo "blocked-resolver-verdict-block.bh-9905: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
