#!/bin/bash
# tests/revert-reason.bh-6160-test.sh — BH-6160: why a merge was reverted.
#
# bin/lib/revert-reason.sh finds the reverts on a project's default branch,
# saves the failure signal of each one as the ledger row revert_reason/"<p> <KEY>",
# and the rebuild's plan prompt and the weekly lookback read it.
#
#   A1  the 5 subjects from the ticket parse; 4 look-alikes do not
#   A2  (#12) never matches (#123)
#   A3  a deploy-train rollback: 2 member rows, class probe, GET only
#   A3a a failed status and a failed check run: class build, with the url
#   A3b a deploy_rollback row for the merge: class probe, with the reason
#   A3c the revert PR text: class stated; bots, footers and "Reverts o/r#N" dropped
#   A4  a revert of a revert: a key-less "#N" row, no plan line
#   A5  round trip: 2 reverts of TK-271 on 2 runs -> rv_plan_line, rv_week_line
#   A6  no status, no check run, a button-default body: no-signal, no plan line
#   A7  a failed read: unreadable; 3 runs, one ALERTS line; run 4 reads nothing
#   A8  REVERT_REASON=0: no GitHub read, no row, RV_LOG=off
#   A9  the real bin/reopen-metrics.sh: the run line and the mirror
#   A10 the plan block from bin/lib/rb/plan.sh, verbatim, with a saved row
#   A11 the same block with no row: empty line; the prompt carries the token once
#   A12 the weekly line from fixture indexes, and the real bin/lookback.sh summary
#   A13 the ledger put fails: ledger:false, ALERTS; next run re-puts, no PR read
#   A14 the per-run cap leaves the rest for the next run
#   A15 the 3800-byte cut, and a revert it emptied stays out of the prompt
#
# No network: gh and curl are stubs on PATH. No LLM.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/revert-reason.bh-6160-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
LIB="$DIR/bin/lib/revert-reason.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: expected '$3', got '$2'"; fi; }
has() { case "$2" in *"$3"*) ok ;; *) bad "$1: '$3' not in: $2" ;; esac; }
hasnt() { case "$2" in *"$3"*) bad "$1: '$3' must not be in: $2" ;; *) ok ;; esac; }
count() { if [ -f "$1" ]; then grep -c -- "$2" "$1"; else echo 0; fi; }
command -v jq >/dev/null 2>&1 || { echo "revert-reason.bh-6160-test: SKIPPED — jq missing"; exit 0; }
[ -r "$LIB" ] || { echo "FAIL: $LIB missing"; echo "revert-reason.bh-6160-test: 0 passed, 1 failed"; exit 1; }

# A fixed clock. 2026-10-10T12:00:00Z.
FIXED_NOW=1791633600
SINCE="2026-10-03T12:00:00Z"
SLUG="Acme/project-3"
export GH_ETAG=0

parse() { HARNESS="$T/none" bash -c '. "$0"; rv_parse_subject "$1"' "$LIB" "$1" | tr '\t' '/'; }

# ============================================================================
# A1 the ticket's 5 subjects, and 4 look-alikes
# ============================================================================
eq "A1 TK-271" "$(parse 'Revert "feat(recaps): coach recap review screens and member my sessions TK-271 (#463)" (#465)')" "revert/463/465"
eq "A1 TK-286" "$(parse 'Revert "feat(events): survey nps card and sync switch-off TK-286 (#459)" (#464)')" "revert/459/464"
eq "A1 TK-294" "$(parse 'Revert "feat(members): inline editing on the benefits usage card TK-294 (#471)" (#472)')" "revert/471/472"
eq "A1 TK-304" "$(parse 'Revert "feat(whatsapp): add the gateway service and group delete loop TK-304 (#482)" (#486)')" "revert/482/486"
eq "A1 the batch rollback" "$(parse 'Rollback: revert failed deploy batch (Oct 08 11:21) (#487)')" "rollback//487"
eq "A1 a merge-commit revert" "$(parse 'Revert "Merge pull request #12 from O/ticket/bh-12"')" "revert/12/"
eq "A1 no trailing PR" "$(parse 'Revert "a (#7)"')" "revert/7/"
for s in 'fix: revert the toggle (#470)' 'Reverted copy on the help page (#471)' 'Revert' 'Rollback plan doc (#9)' 'chore: rollback plan doc (#9)'; do
  HARNESS="$T/none" bash -c '. "$0"; rv_parse_subject "$1"' "$LIB" "$s" >/dev/null
  eq "A1 rejects '$s'" "$?" 1
done

# ============================================================================
# A2 #12 vs #123
# ============================================================================
eq "A2 (#123) gives 123" "$(parse 'Revert "fix x (#123)" (#130)')" "revert/123/130"
eq "A2 (#12) gives 12" "$(parse 'Revert "fix x (#12)" (#13)')" "revert/12/13"
eq "A2 a mid-title #12 is not the PR" "$(parse 'Revert "fix #12 again (#123)" (#130)')" "revert/123/130"

# rv_ticket_key
key() { HARNESS="$T/none" bash -c '. "$0"; rv_ticket_key "$1" "$2"' "$LIB" "$1" "$2"; }
eq "key: ticket branch" "$(key ticket/TK-271 'x')" "TK-271"
eq "key: rebuild branch" "$(key ticket/bh-5241-r2 'x')" "BH-5241"
# A ticket branch is ticket/<key> or ticket/<key>-r<n>, nothing else (the
# tests/ticket-branch-ratchet.bh-3835 shape): another suffix falls to the title.
eq "key: other suffix is not a ticket branch" "$(key ticket/bh-1486-local 'x')" ""
eq "key: other suffix, title key" "$(key ticket/bh-1486-local 'fix: y TK-12')" "TK-12"
eq "key: title token" "$(key feat/x 'feat(recaps): coach my sessions TK-271')" "TK-271"
eq "key: title token before (#N)" "$(key '' 'feat(recaps): coach my sessions TK-271 (#463)')" "TK-271"
eq "key: none" "$(key revert-463-ticket/TK-271 'Revert "x (#1)"')" ""

# ============================================================================
# stubs: gh answers `api -i -X GET <path>` from $T/gh.rules (glob<TAB>file|FAIL|404);
# curl is the jobs worker for the real jobs client (A9).
# ============================================================================
mkdir -p "$T/stub" "$T/fx"
cat > "$T/stub/gh" <<'EOF'
#!/bin/bash
TD=__T__
printf '%s\n' "$*" >> "$TD/gh.log"
inc=0; path=""; prev=""
for a in "$@"; do
  [ "$a" = -i ] && inc=1
  [ "$prev" = GET ] && path="$a"
  case "$a" in repos/*) [ -z "$path" ] && path="$a" ;; esac
  prev="$a"
done
ans=""
if [ -r "$TD/gh.rules" ]; then
  while IFS=$'\t' read -r pat f; do
    [ -n "$pat" ] || continue
    # shellcheck disable=SC2053
    if [[ "$path" == $pat ]]; then ans="$f"; break; fi
  done < "$TD/gh.rules"
fi
if [ "$inc" = 0 ]; then [ -n "$ans" ] && [ -f "$ans" ] && cat "$ans" || echo '[]'; exit 0; fi
case "$ans" in
  FAIL|"") printf 'HTTP/2.0 500 Internal Server Error\r\n\r\n{"message":"boom"}\n'; exit 1 ;;
  404) printf 'HTTP/2.0 404 Not Found\r\n\r\n{"message":"Not Found"}\n'; exit 1 ;;
  *) printf 'HTTP/2.0 200 OK\r\n\r\n'; cat "$ans"; echo ;;
esac
EOF
cat > "$T/stub/curl" <<'EOF'
#!/bin/bash
TD=__T__
m=GET; url=""; body=""; w=0; f=0
while [ $# -gt 0 ]; do case "$1" in
  -X) m="$2"; shift 2 ;;
  --data-binary|-d|--data) body="$2"; shift 2 ;;
  -w) w=1; shift 2 ;;
  -m|--connect-timeout|-H|-o) shift 2 ;;
  -sf|-fs|-f|-sSf|-fsS) f=1; shift ;;
  http*) url="$1"; shift ;;
  *) shift ;;
esac; done
case "$body" in @*) body=$(cat "${body#@}") ;; esac
printf '%s\t%s\t%s\n' "$m" "$url" "$body" >> "$TD/curl.log"
line="$m $url $body"; code=200; resp='{}'
if [ -r "$TD/rules" ]; then
  while IFS=$'\t' read -r pat c r; do
    [ -n "$pat" ] || continue
    case "$line" in *"$pat"*) code="$c"; resp="$r"; break ;; esac
  done < "$TD/rules"
fi
if [ "$w" = 1 ]; then printf '%s\n%s' "$resp" "$code"; exit 0; fi
[ "$f" = 1 ] && [ "$code" -ge 400 ] && exit 22
printf '%s' "$resp"
EOF
sed -i "s|__T__|$T|" "$T/stub/gh" "$T/stub/curl"
chmod +x "$T/stub/gh" "$T/stub/curl"
export PATH="$T/stub:$PATH"

# the ledger: job_ledger_put appends to $T/puts.tsv; job_ledger_row reads $T/rows.tsv
cat > "$T/jstub.sh" <<EOF
job_ledger_put() { [ -n "\${STUB_PUT_FAIL:-}" ] && return 1; printf '%s\t%s\t%s\t%s\n' "\$1" "\$2" "\$3" "\$4" >> "$T/puts.tsv"; }
job_ledger_row() {
  [ -n "\${STUB_ROW_FAIL:-}" ] && return 1
  local r; r=\$(awk -F'\t' -v k="\$1" -v key="\$2" '\$1 == k && \$2 == key {print \$3}' "$T/rows.tsv" 2>/dev/null | tail -1)
  [ -n "\$r" ] || return 2
  printf '%s' "\$r"
}
EOF

ghrules() { printf '%s\n' "$@" > "$T/gh.rules"; }
fx() { printf '%s' "$2" > "$T/fx/$1"; printf '%s' "$T/fx/$1"; }
commit() { # commit <sha> <iso> <subject>
  jq -nc --arg s "$1" --arg d "$2" --arg m "$3" '{sha:$s, commit:{message:($m + "\n\nbody line"), committer:{date:$d}}}'
}
SHA_R1=$(printf '1%.0s' {1..40}); SHA_M1=$(printf 'a%.0s' {1..40})
SHA_R2=$(printf '2%.0s' {1..40}); SHA_M2=$(printf 'b%.0s' {1..40})
SHA_RB=$(printf '3%.0s' {1..40}); SHA_X=$(printf 'c%.0s' {1..40}); SHA_Y=$(printf 'd%.0s' {1..40})
SHA_RR=$(printf '4%.0s' {1..40}); SHA_N=$(printf 'e%.0s' {1..40})
OK_STATUS=$(fx ok-status.json '{"state":"success","statuses":[{"state":"success","context":"ci","description":"fine","target_url":"https://ci.example/1"}]}')
OK_CHECKS=$(fx ok-checks.json '{"total_count":1,"check_runs":[{"name":"build","conclusion":"success","html_url":"https://gh.example/c/1","output":{"title":"ok"}}]}')
NO_COMMENTS=$(fx no-comments.json '[]')

H=""
newh() { # newh <name> — a fresh scratch harness root in $H
  H="$T/$1"; scratch_rm "$H"; mkdir -p "$H/bin" "$H/logs" "$H/state"
  cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$H/bin/"
  : > "$T/puts.tsv"; : > "$T/rows.tsv"
}
run_cap() { # run_cap [VAR=v ...] — one capture pass for project-3 and its report; output in $T/cap.out
  local run; run=$(mktemp -d "$T/run.XXXX")
  : > "$T/gh.log"
  env HARNESS="$H" RV_NOW=$FIXED_NOW RV_RUN="$run" "$@" bash -c '
    . "$1"; . "$2"; rv_capture project-3 "$3" "$4"; rv_capture_report' _ "$T/jstub.sh" "$LIB" "$SLUG" "$SINCE" > "$T/cap.out" 2>&1
}
puts() { awk -F'\t' '$1 == "revert_reason"' "$T/puts.tsv"; }
put_detail() { awk -F'\t' -v k="$1" '$1 == "revert_reason" && $2 == k {print $4}' "$T/puts.tsv" | tail -1; }
ghreads() { grep -c -- "$1" "$T/gh.log" 2>/dev/null || true; }
plan_line() { # plan_line <KEY> [VAR=v ...] -> "RV_LOG\nRV_LINE"; the row comes from the mirror or $T/rows.tsv
  local k="$1"; shift
  env HARNESS="$H" RV_NOW=$FIXED_NOW "$@" bash -c '. "$1"; . "$2"; rv_plan_line project-3 "$3" >/dev/null; printf "%s\n%s" "$RV_LOG" "$RV_LINE"' \
    _ "$T/jstub.sh" "$LIB" "$k"
}

# ============================================================================
# A3a/A3b/A3c one revert, one signal per source
# ============================================================================
newh a3x
fx c-a3x.json "[$(commit "$SHA_R1" 2026-10-08T10:00:00Z 'Revert "feat(recaps): coach recap review screens and member my sessions TK-271 (#463)" (#465)')]" >/dev/null
fx pr463.json "{\"number\":463,\"title\":\"feat(recaps): coach recap review screens and member my sessions TK-271\",\"head\":{\"ref\":\"ticket/TK-271\"},\"merge_commit_sha\":\"$SHA_M1\"}" >/dev/null
fx bad-status.json '{"state":"failure","statuses":[{"state":"success","context":"lint","description":"ok","target_url":"https://ci.example/0"},{"state":"failure","context":"vercel","description":"Deployment has failed","target_url":"https://vercel.example/d/1"}]}' >/dev/null
fx bad-checks.json '{"total_count":2,"check_runs":[{"name":"build","conclusion":"failure","html_url":"https://gh.example/runs/9","output":{"title":"Type error in recap.tsx"}},{"name":"lint","conclusion":"success","html_url":"https://gh.example/runs/8","output":{"title":"ok"}}]}' >/dev/null
fx pr465.json '{"number":465,"body":"Reverts Acme/project-3#463\n\nThe recap screen 500s on prod: TypeError cannot read sessions of undefined\n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)","created_at":"2026-10-08T09:59:00Z","html_url":"https://github.com/Acme/project-3/pull/465","user":{"login":"operator","type":"User"}}' >/dev/null
fx c465.json '[{"created_at":"2026-10-08T10:05:00Z","body":"Deploy preview ready","html_url":"https://github.com/Acme/project-3/pull/465#c1","user":{"login":"vercel[bot]","type":"Bot"}},{"created_at":"2026-10-08T10:06:00Z","body":"   ","html_url":"https://github.com/Acme/project-3/pull/465#c2","user":{"login":"operator","type":"User"}},{"created_at":"2026-10-08T10:07:00Z","body":"Same error on the member sessions page","html_url":"https://github.com/Acme/project-3/pull/465#c3","user":{"login":"dana","type":"User"}}]' >/dev/null
ghrules "repos/$SLUG/commits\?*	$T/fx/c-a3x.json" "repos/$SLUG/pulls/463	$T/fx/pr463.json" \
  "repos/$SLUG/commits/$SHA_M1/status	$T/fx/bad-status.json" "repos/$SLUG/commits/$SHA_M1/check-runs*	$T/fx/bad-checks.json" \
  "repos/$SLUG/pulls/465	$T/fx/pr465.json" "repos/$SLUG/issues/465/comments*	$T/fx/c465.json"
printf 'deploy_rollback\tproject-3 TK-271@%s\t%s\n' "${SHA_M1:0:8}" \
  "$(jq -nc --arg d '{"project":"project-3","key":"TK-271","reason":"live probe /api/version returned 500","revert_pr":"https://github.com/Acme/project-3/pull/487"}' '{status:"reopened",detail:$d}')" > "$T/rows.tsv"
run_cap
D=$(put_detail "project-3 TK-271")
eq "A3x one revert_reason put" "$(puts | grep -c .)" 1
eq "A3x put status" "$(puts | cut -f3)" saved
eq "A3a build: the failed status, with its url" "$(jq -r '.reverts[0].signals[] | select(.class=="build" and .source=="vercel") | .text + " " + .url' <<<"$D")" \
  "Deployment has failed https://vercel.example/d/1"
eq "A3a build: the failed check run, with its url" "$(jq -r '.reverts[0].signals[] | select(.class=="build" and .source=="build") | .text + " " + .url' <<<"$D")" \
  "Type error in recap.tsx https://gh.example/runs/9"
eq "A3a build: a passing status or check is not a signal" "$(jq '[.reverts[0].signals[] | select(.class=="build")] | length' <<<"$D")" 2
eq "A3b probe: the deploy_rollback reason" "$(jq -r '.reverts[0].signals[] | select(.class=="probe") | .text + " " + .url' <<<"$D")" \
  "live probe /api/version returned 500 https://github.com/Acme/project-3/pull/487"
eq "A3c stated: body text without the boilerplate and the footer" "$(jq -r '[.reverts[0].signals[] | select(.class=="stated") | .text] | join("|")' <<<"$D")" \
  "Same error on the member sessions page|The recap screen 500s on prod: TypeError cannot read sessions of undefined"
eq "A3c stated: each with its url" "$(jq -r '[.reverts[0].signals[] | select(.class=="stated") | .url] | join("|")' <<<"$D")" \
  "https://github.com/Acme/project-3/pull/465#c3|https://github.com/Acme/project-3/pull/465"
eq "A3x the revert fields" "$(jq -r '.reverts[0] | [.revert_sha[0:8], .revert_pr, .merged_pr, .merge_sha[0:8], .kind, .status, (.attempts|tostring), (.classes|join(","))] | join(" ")' <<<"$D")" \
  "11111111 465 463 aaaaaaaa revert saved 1 build,probe,stated"
eq "A3x the index line" "$(cut -f1,3-6 "$H/state/revert-reasons/project-3/index.tsv")" "$SHA_R1	saved	1	TK-271	build,probe,stated"
eq "A3x mirror ledger:true" "$(jq -r '.status + "|" + (.ledger|tostring)' "$H/state/revert-reasons/project-3/TK-271.json")" "saved|true"
has "A3x run line" "$(cat "$T/cap.out")" "revert reasons: 1 saved, 0 no-signal, 0 unreadable, 0 left for the next run (cap 20)"
eq "A3x every GitHub call is a GET" "$(grep -vc -- '-X GET' "$T/gh.log")" 0
# a second run reads only the commit list
run_cap
eq "A3x run 2: only the commit list is read" "$(grep -c . "$T/gh.log")" 1
has "A3x run 2: nothing new" "$(cat "$T/cap.out")" "revert reasons: 0 saved, 0 no-signal, 0 unreadable, 0 left"

# ============================================================================
# A3 the deploy-train rollback: 2 members, class probe, no tracker call
# ============================================================================
newh a3
fx c-a3.json "[$(commit "$SHA_RB" 2026-10-08T11:30:00Z 'Rollback: revert failed deploy batch (Oct 08 11:21) (#487)')]" >/dev/null
fx pr487.json "{\"number\":487,\"html_url\":\"https://github.com/Acme/project-3/pull/487\",\"body\":\"Automatic rollback (deploy train, per the operator 2026-07-28): production failed to serve abcd1234 after the batch below merged. Reverting to restore last known-good.\n\nReverted: $SHA_X $SHA_Y \n\n🤖 Generated with [Claude Code](https://claude.com/claude-code)\"}" >/dev/null
fx px.json '[{"number":480,"title":"feat(a): one TK-301","head":{"ref":"ticket/TK-301"}}]' >/dev/null
fx py.json '[{"number":481,"title":"feat(b): two TK-302","head":{"ref":"ticket/TK-302"}}]' >/dev/null
ghrules "repos/$SLUG/commits\?*	$T/fx/c-a3.json" "repos/$SLUG/pulls/487	$T/fx/pr487.json" \
  "repos/$SLUG/commits/$SHA_X/pulls	$T/fx/px.json" "repos/$SLUG/commits/$SHA_Y/pulls	$T/fx/py.json"
{ printf 'deploy_rollback\tproject-3 TK-301@%s\t%s\n' "${SHA_X:0:8}" "$(jq -nc --arg d '{"reason":"version probe served 1f2e3d4c, expected abcd1234"}' '{status:"reopened",detail:$d}')"; } > "$T/rows.tsv"
: > "$T/curl.log"
run_cap
eq "A3 two member rows" "$(puts | cut -f2 | sort | paste -sd, -)" "project-3 TK-301,project-3 TK-302"
eq "A3 TK-301: the deploy_rollback reason" "$(put_detail "project-3 TK-301" | jq -r '.reverts[0] | .kind + " " + (.classes|join(",")) + " " + .signals[0].text')" \
  "rollback probe version probe served 1f2e3d4c, expected abcd1234"
eq "A3 TK-302: the rollback PR's first line" "$(put_detail "project-3 TK-302" | jq -r '.reverts[0] | (.classes|join(",")) + " " + .signals[0].source + " " + .signals[0].url')" \
  "probe rollback PR body https://github.com/Acme/project-3/pull/487"
has "A3 TK-302: the text" "$(put_detail "project-3 TK-302" | jq -r '.reverts[0].signals[0].text')" "production failed to serve abcd1234"
eq "A3 merged PRs" "$(for k in TK-301 TK-302; do put_detail "project-3 $k" | jq -r '.reverts[0].merged_pr'; done | paste -sd, -)" "480,481"
eq "A3 one index line, both keys" "$(cut -f3,5,6 "$H/state/revert-reasons/project-3/index.tsv")" "saved	TK-301,TK-302	probe"
eq "A3 every GitHub call is a GET" "$(grep -vc -- '-X GET' "$T/gh.log")" 0
eq "A3 no board call (curl)" "$(count "$T/curl.log" .)" 0
has "A3 run line counts the revert once" "$(cat "$T/cap.out")" "revert reasons: 1 saved,"

# ============================================================================
# A4 a revert of a revert: key-less, never in a plan
# ============================================================================
newh a4
fx c-a4.json "[$(commit "$SHA_RR" 2026-10-08T12:00:00Z 'Revert "Revert "feat(x): y TK-271 (#463)" (#465)" (#470)')]" >/dev/null
fx pr465b.json "{\"number\":465,\"title\":\"Revert \\\"feat(x): y TK-271 (#463)\\\"\",\"head\":{\"ref\":\"revert-463-ticket/TK-271\"},\"merge_commit_sha\":\"$SHA_N\"}" >/dev/null
fx pr470.json '{"number":470,"body":"The revert broke login, putting it back","created_at":"2026-10-08T12:00:00Z","html_url":"https://github.com/Acme/project-3/pull/470","user":{"login":"operator","type":"User"}}' >/dev/null
ghrules "repos/$SLUG/commits\?*	$T/fx/c-a4.json" "repos/$SLUG/pulls/465	$T/fx/pr465b.json" \
  "repos/$SLUG/commits/$SHA_N/status	$OK_STATUS" "repos/$SLUG/commits/$SHA_N/check-runs*	$OK_CHECKS" \
  "repos/$SLUG/pulls/470	$T/fx/pr470.json" "repos/$SLUG/issues/470/comments*	$NO_COMMENTS"
run_cap
eq "A4 the key-less row" "$(puts | cut -f2)" "project-3 #465"
[ -s "$H/state/revert-reasons/project-3/_465.json" ] && ok || bad "A4 mirror at project-3/_465.json"
eq "A4 no plan line for TK-271" "$(plan_line TK-271 | tail -n +2)" ""
eq "A4 TK-271 has no row" "$(plan_line TK-271 | head -1)" "none"

# ============================================================================
# A6 no signal anywhere: no-signal, no plan line
# ============================================================================
newh a6
fx c-a6.json "[$(commit "$SHA_R2" 2026-10-08T13:00:00Z 'Revert "feat(events): survey nps card and sync switch-off TK-286 (#459)" (#464)')]" >/dev/null
fx pr459.json "{\"number\":459,\"title\":\"feat(events): survey nps card and sync switch-off TK-286\",\"head\":{\"ref\":\"feat/nps\"},\"merge_commit_sha\":\"$SHA_M2\"}" >/dev/null
fx pr464.json '{"number":464,"body":"Reverts Acme/project-3#459","created_at":"2026-10-08T13:00:00Z","html_url":"https://github.com/Acme/project-3/pull/464","user":{"login":"operator","type":"User"}}' >/dev/null
ghrules "repos/$SLUG/commits\?*	$T/fx/c-a6.json" "repos/$SLUG/pulls/459	$T/fx/pr459.json" \
  "repos/$SLUG/commits/$SHA_M2/status	$T/fx/st-empty.json" "repos/$SLUG/commits/$SHA_M2/check-runs*	$T/fx/cr-empty.json" \
  "repos/$SLUG/pulls/464	$T/fx/pr464.json" "repos/$SLUG/issues/464/comments*	$NO_COMMENTS"
fx st-empty.json '{"state":"pending","statuses":[]}' >/dev/null; fx cr-empty.json '{"total_count":0,"check_runs":[]}' >/dev/null
run_cap
eq "A6 key from the title, status no-signal" "$(puts | cut -f2,3)" "project-3 TK-286	no-signal"
eq "A6 no signal saved" "$(put_detail "project-3 TK-286" | jq '.reverts[0].signals | length')" 0
has "A6 run line" "$(cat "$T/cap.out")" "revert reasons: 0 saved, 1 no-signal, 0 unreadable"
eq "A6 no plan line" "$(plan_line TK-286 | tail -n +2)" ""
eq "A6 plan log" "$(plan_line TK-286 | head -1)" "none (no signal)"
run_cap
eq "A6 run 2: no-signal is not read again" "$(ghreads pulls/)" 0

# ============================================================================
# A7 a failed read: unreadable, 3 tries, one ALERTS line, then left alone
# ============================================================================
newh a7
ghrules "repos/$SLUG/commits\?*	$T/fx/c-a3x.json" "repos/$SLUG/pulls/463	$T/fx/pr463.json" \
  "repos/$SLUG/commits/$SHA_M1/status	FAIL" "repos/$SLUG/commits/$SHA_M1/check-runs*	$T/fx/bad-checks.json" \
  "repos/$SLUG/pulls/465	$T/fx/pr465.json" "repos/$SLUG/issues/465/comments*	$T/fx/c465.json"
for i in 1 2 3; do
  run_cap
  eq "A7 run $i: unreadable, attempts $i" "$(cut -f3,4 "$H/state/revert-reasons/project-3/index.tsv")" "unreadable	$i"
  eq "A7 run $i: the PR is read" "$(ghreads pulls/463)" 1
  has "A7 run $i: run line" "$(cat "$T/cap.out")" "0 saved, 0 no-signal, 1 unreadable"
  [ "$i" -lt 3 ] && eq "A7 run $i: no ALERTS line yet" "$(count "$H/logs/ALERTS.log" 'not saved after 3 tries')" 0
done
eq "A7 the row says unreadable, never no-signal" "$(put_detail "project-3 TK-271" | jq -r '.reverts[0].status')" unreadable
eq "A7 the plan log says unreadable" "$(plan_line TK-271 | head -1)" "none (unreadable row)"
eq "A7 one ALERTS line after run 3" "$(count "$H/logs/ALERTS.log" 'revert reason not saved after 3 tries')" 1
has "A7 the line names the revert" "$(grep 'not saved after 3 tries' "$H/logs/ALERTS.log")" "project-3 11111111"
run_cap
eq "A7 run 4: no read for that revert" "$(ghreads pulls/)" 0
eq "A7 run 4: no new ALERTS line" "$(count "$H/logs/ALERTS.log" 'not saved after 3 tries')" 1
# the PR read itself fails (the hub-token 404): index only, unreadable
newh a7b
ghrules "repos/$SLUG/commits\?*	$T/fx/c-a3x.json" "repos/$SLUG/pulls/463	404"
run_cap
eq "A7b a 404 on the PR is unreadable" "$(cut -f3,4,5 "$H/state/revert-reasons/project-3/index.tsv")" "unreadable	1	-"
eq "A7b no ticket row" "$(puts | grep -c .)" 0
# the commit list fails 3 runs in a row: one ALERTS line
ghrules "repos/$SLUG/commits\?*	404"
for i in 1 2 3; do run_cap; done
has "A7b the run line names the repo" "$(cat "$T/cap.out")" "(commit list unreadable: project-3)"
eq "A7b one list ALERTS line" "$(count "$H/logs/ALERTS.log" 'commit list unreadable 3 runs in a row')" 1

# ============================================================================
# A8 REVERT_REASON=0
# ============================================================================
newh a8
ghrules "repos/$SLUG/commits\?*	$T/fx/c-a3x.json" "repos/$SLUG/pulls/463	$T/fx/pr463.json"
run_cap REVERT_REASON=0
eq "A8 no GitHub read" "$(grep -c . "$T/gh.log")" 0
eq "A8 no row" "$(puts | grep -c .)" 0
[ ! -e "$H/state/revert-reasons" ] && ok || bad "A8 no mirror may be written"
printf 'revert_reason\tproject-3 TK-271\t%s\n' "$(jq -nc --arg d "$(jq -nc '{v:1,project:"project-3",key:"TK-271",at:"2026-10-10T00:00:00Z",reverts:[{revert_sha:"1111111111",status:"saved",classes:["build"],signals:[{class:"build",source:"ci",text:"t",url:"u"}]}]}')" '{status:"saved",detail:$d}')" > "$T/rows.tsv"
eq "A8 RV_LOG=off, no line" "$(plan_line TK-271 REVERT_REASON=0)" "off"

# ============================================================================
# A5 round trip: 2 reverts of TK-271 on 2 runs
# ============================================================================
newh a5
ghrules "repos/$SLUG/commits\?*	$T/fx/c-a3x.json" "repos/$SLUG/pulls/463	$T/fx/pr463.json" \
  "repos/$SLUG/commits/$SHA_M1/status	$T/fx/bad-status.json" "repos/$SLUG/commits/$SHA_M1/check-runs*	$OK_CHECKS" \
  "repos/$SLUG/pulls/465	$T/fx/pr465.json" "repos/$SLUG/issues/465/comments*	$NO_COMMENTS"
run_cap
fx pr490.json "{\"number\":490,\"title\":\"feat(recaps): coach recap review screens again TK-271\",\"head\":{\"ref\":\"ticket/TK-271-r2\"},\"merge_commit_sha\":\"$SHA_M2\"}" >/dev/null
fx pr491.json '{"number":491,"body":"Still broken: recap list times out after 10 s","created_at":"2026-10-09T09:00:00Z","html_url":"https://github.com/Acme/project-3/pull/491","user":{"login":"operator","type":"User"}}' >/dev/null
fx c-a5.json "[$(commit "$SHA_R2" 2026-10-09T09:00:00Z 'Revert "feat(recaps): coach recap review screens again TK-271 (#490)" (#491)'),$(commit "$SHA_R1" 2026-10-08T10:00:00Z 'Revert "feat(recaps): coach recap review screens and member my sessions TK-271 (#463)" (#465)')]" >/dev/null
ghrules "repos/$SLUG/commits\?*	$T/fx/c-a5.json" "repos/$SLUG/pulls/490	$T/fx/pr490.json" \
  "repos/$SLUG/commits/$SHA_M2/status	$OK_STATUS" "repos/$SLUG/commits/$SHA_M2/check-runs*	$OK_CHECKS" \
  "repos/$SLUG/pulls/491	$T/fx/pr491.json" "repos/$SLUG/issues/491/comments*	$NO_COMMENTS"
run_cap
eq "A5 run 2 reads only the new revert" "$(ghreads pulls/463)" 0
D=$(put_detail "project-3 TK-271")
eq "A5 one row, 2 reverts, newest first" "$(jq -r '[.reverts[].revert_sha[0:8]] | join(",")' <<<"$D")" "22222222,11111111"
# the reader gets the ledger's row, not the mirror
scratch_rm "$H/state/revert-reasons/project-3/TK-271.json"
printf 'revert_reason\tproject-3 TK-271\t%s\n' "$(jq -nc --arg d "$D" '{status:"saved",detail:$d}')" > "$T/rows.tsv"
OUT=$(plan_line TK-271)
eq "A5 plan log" "$(head -1 <<<"$OUT")" "saved 2 revert(s) build,stated"
L=$(tail -n +2 <<<"$OUT")
has "A5 the line" "$L" "THIS TICKET'S LAST MERGE WAS REVERTED (2 time(s)). The rebuild must not fail the same way."
has "A5 the newer revert's signal" "$L" "[stated] revert PR #491 body https://github.com/Acme/project-3/pull/491: Still broken: recap list times out after 10 s"
has "A5 the older revert's signal" "$L" "[build] vercel https://vercel.example/d/1: Deployment has failed"
p22=${L%%revert-22222222 ===*}; p11=${L%%revert-11111111 ===*}
[ "${#p22}" -lt "${#p11}" ] && ok || bad "A5 the newest revert comes first in the line"
for h in 22222222 11111111; do
  eq "A5 one open and one close marker for $h" "$(grep -o "=== UNTRUSTED INPUT revert-$h ===" <<<"$L" | grep -c .)/$(grep -o "=== END UNTRUSTED INPUT revert-$h ===" <<<"$L" | grep -c .)" "1/1"
done
eq "A5 the weekly line counts them" "$(HARNESS="$H" RV_NOW=$FIXED_NOW bash -c '. "$0"; rv_week_line 7' "$LIB")" \
  "reverts 7d: project-3 2 (build 1, probe 0, stated 1, none 0)"
# age: 30 days is used, 31 is old
eq "A5 at 30 d: used" "$(plan_line TK-271 RV_NOW=$((FIXED_NOW + 30 * 86400)) | head -1)" "saved 2 revert(s) build,stated"
eq "A5 at 31 d: old" "$(plan_line TK-271 RV_NOW=$((FIXED_NOW + 31 * 86400)))" "old (31 d)"
# a ledger outage with no mirror: unreadable, no line
eq "A5 ledger outage: unreadable" "$(plan_line TK-271 STUB_ROW_FAIL=1)" "unreadable"

# ============================================================================
# A13 the ledger put fails, then works
# ============================================================================
newh a13
ghrules "repos/$SLUG/commits\?*	$T/fx/c-a3x.json" "repos/$SLUG/pulls/463	$T/fx/pr463.json" \
  "repos/$SLUG/commits/$SHA_M1/status	$T/fx/bad-status.json" "repos/$SLUG/commits/$SHA_M1/check-runs*	$OK_CHECKS" \
  "repos/$SLUG/pulls/465	$T/fx/pr465.json" "repos/$SLUG/issues/465/comments*	$NO_COMMENTS"
run_cap STUB_PUT_FAIL=1
eq "A13 mirror ledger:false" "$(jq -r '.status + "|" + (.ledger|tostring)' "$H/state/revert-reasons/project-3/TK-271.json")" "saved|false"
has "A13 the run line says it" "$(cat "$T/cap.out")" "(1 not in the ledger)"
eq "A13 one ALERTS line" "$(count "$H/logs/ALERTS.log" 'revert reason saved on the hub only')" 1
has "A13 it names the key" "$(grep 'saved on the hub only' "$H/logs/ALERTS.log")" "project-3 TK-271"
run_cap
eq "A13 run 2: re-put" "$(puts | cut -f2,3)" "project-3 TK-271	saved"
eq "A13 run 2: no PR or status read" "$(ghreads pulls/)/$(ghreads /status)" "0/0"
eq "A13 run 2: mirror ledger:true" "$(jq -r '.ledger|tostring' "$H/state/revert-reasons/project-3/TK-271.json")" true
eq "A13 run 2: no new ALERTS line" "$(count "$H/logs/ALERTS.log" 'revert reason saved on the hub only')" 1

# ============================================================================
# A14 the per-run cap
# ============================================================================
newh a14
ghrules "repos/$SLUG/commits\?*	$T/fx/c-a5.json" "repos/$SLUG/pulls/463	$T/fx/pr463.json" \
  "repos/$SLUG/commits/$SHA_M1/status	$OK_STATUS" "repos/$SLUG/commits/$SHA_M1/check-runs*	$OK_CHECKS" \
  "repos/$SLUG/pulls/465	$T/fx/pr465.json" "repos/$SLUG/issues/465/comments*	$NO_COMMENTS" \
  "repos/$SLUG/pulls/490	$T/fx/pr490.json" \
  "repos/$SLUG/commits/$SHA_M2/status	$OK_STATUS" "repos/$SLUG/commits/$SHA_M2/check-runs*	$OK_CHECKS" \
  "repos/$SLUG/pulls/491	$T/fx/pr491.json" "repos/$SLUG/issues/491/comments*	$NO_COMMENTS"
run_cap REVERT_REASON_MAX_PER_RUN=1
has "A14 one read, one left" "$(cat "$T/cap.out")" "revert reasons: 1 saved, 0 no-signal, 0 unreadable, 1 left for the next run (cap 1)"
eq "A14 the oldest is read first" "$(ghreads pulls/463)/$(ghreads pulls/490)" "1/0"
run_cap REVERT_REASON_MAX_PER_RUN=1
eq "A14 next run reads the one left" "$(ghreads pulls/463)/$(ghreads pulls/490)" "0/1"
has "A14 next run line" "$(cat "$T/cap.out")" "1 saved, 0 no-signal, 0 unreadable, 0 left"

# ============================================================================
# A15 the 3800-byte cut drops the oldest signal first, and the plan skips an emptied revert
# ============================================================================
BIG=$(printf 'x%.0s' $(seq 1 450))
R15=$(jq -nc --arg b "$BIG" '[range(3) as $r | {revert_sha:"\($r)\($r)\($r)\($r)\($r)\($r)\($r)\($r)", merged_pr:"\($r)", at:"2026-10-0\($r + 1)T00:00:00Z",
  status:"saved", classes:["stated"], signals:[range(4) | {class:"stated", source:"s\(.)", text:$b, url:"u"}]}]')
E15=$(HARNESS="$T/none" RV_NOW=$FIXED_NOW bash -c '. "$0"; rv_encode project-3 TK-15 "$1"' "$LIB" "$R15")
[ "$(printf '%s' "$E15" | LC_ALL=C wc -c)" -le 3800 ] && ok || bad "A15 the detail must be <= 3800 bytes (got $(printf '%s' "$E15" | wc -c))"
eq "A15 newest first, the oldest revert's signals dropped first" "$(jq -c '[.reverts[] | "\(.revert_sha[0:1]):\(.signals | length)"] | join(",")' <<<"$E15")" '"2:4,1:2,0:0"'
newh a15
printf 'revert_reason\tproject-3 TK-15\t%s\n' "$(jq -nc --arg d "$E15" '{status:"saved",detail:$d}')" > "$T/rows.tsv"
OUT=$(plan_line TK-15)
eq "A15 plan log counts the reverts that still carry a signal" "$(head -1 <<<"$OUT")" "saved 2 revert(s) stated"
hasnt "A15 no empty marker for the emptied revert" "$OUT" "revert-00000000"

# ============================================================================
# A9 the real bin/reopen-metrics.sh
# ============================================================================
R9="$T/r9"; scratch_rm "$R9"; mkdir -p "$R9/env" "$R9/logs" "$R9/state" "$R9/builds" "$R9/bin"
cp "$DIR/bin/alert-line.sh" "$DIR/bin/alert_family.py" "$R9/bin/"
echo 'project-3   Acme/project-3   -   -   6 box-small' > "$R9/fleet.conf"
ghrules "repos/$SLUG/commits\?*	$T/fx/c-a3x.json" "repos/$SLUG/pulls/463	$T/fx/pr463.json" \
  "repos/$SLUG/commits/$SHA_M1/status	$T/fx/bad-status.json" "repos/$SLUG/commits/$SHA_M1/check-runs*	$OK_CHECKS" \
  "repos/$SLUG/pulls/465	$T/fx/pr465.json" "repos/$SLUG/issues/465/comments*	$NO_COMMENTS"
printf '%s\n' "kind=deploy_rollback	404	{\"error\":\"not found\"}" > "$T/rules"
lane9() {
  : > "$T/curl.log"; : > "$T/gh.log"
  env HARNESS="$R9" HARNESS_ENV_DIR="$R9/env" FLEET_CONF="$R9/fleet.conf" HARNESS_SECRET=test-fixture-secret \
    JOBS_URL=http://jobs.test JOBS_RETRIES=0 RV_NOW=$FIXED_NOW "$@" bash "$DIR/bin/reopen-metrics.sh" > "$T/lane.out" 2>&1
  echo $?
}
eq "A9 lane rc" "$(lane9)" 0
has "A9 the run line" "$(cat "$T/lane.out")" "revert reasons: 1 saved, 0 no-signal, 0 unreadable, 0 left for the next run (cap 20)"
eq "A9 the mirror" "$(jq -r '.key + "|" + .status + "|" + (.ledger|tostring)' "$R9/state/revert-reasons/project-3/TK-271.json" 2>/dev/null)" "TK-271|saved|true"
PUT=$(awk -F'\t' '$1=="PUT" && $2 ~ /\/api\/ledger$/ {print $3}' "$T/curl.log" | jq -c 'select(.kind=="revert_reason")' 2>/dev/null)
eq "A9 the real jobs client put the row" "$(jq -r '.key + "|" + .status' <<<"$PUT")" "project-3 TK-271|saved"
has "A9 the commit list since the lookback" "$(cat "$T/gh.log")" "repos/$SLUG/commits?since=2026-10-03T12:00:00Z&per_page=100&page=1"
eq "A9 REVERT_REASON=0: rc" "$(scratch_rm "$R9/state/revert-reasons"; lane9 REVERT_REASON=0)" 0
hasnt "A9 REVERT_REASON=0: no run line" "$(cat "$T/lane.out")" "revert reasons:"
eq "A9 REVERT_REASON=0: no commit read" "$(ghreads commits)" 0

# ============================================================================
# A10/A11 the plan block, verbatim from bin/lib/rb/plan.sh
# ============================================================================
awk '/^# >>> revert reason \(BH-6160\)/{f=1} f; /^# <<< revert reason \(BH-6160\)/{exit}' "$DIR/bin/lib/rb/plan.sh" > "$T/block.sh"
grep -q 'rv_plan_line' "$T/block.sh" && ok || bad "A10 could not extract the revert reason block from bin/lib/rb/plan.sh"
H10="$T/h10"; scratch_rm "$H10"; mkdir -p "$H10/bin" "$H10/build"
scratch_install_closure bin/lib/revert-reason.sh "$H10" >/dev/null || bad "A10 could not install the lib closure"
cp "$DIR/bin/fleet-conf.sh" "$H10/bin/"
printf '%s\n' 'project-3 Acme/project-3 https://project-3.example /api/feature-board 2' 'gamma Acme/gamma - - 6' > "$H10/fleet.conf"
block() { # block <project> <key> [VAR=v ...] -> REVERT_REASON_LINE; pipeline.log in $H10/build
  local p="$1" k="$2"; shift 2
  rm -f "$H10/build/pipeline.log"
  env HARNESS="$H10" FLEET_CONF="$H10/fleet.conf" BUILD="$H10/build" PROJECT="$p" KEY="$k" RV_NOW=$FIXED_NOW "$@" bash -c '
    STAMP() { echo TS; }
    . "$1"; . "$0"; printf "%s" "$REVERT_REASON_LINE"' "$T/block.sh" "$T/jstub.sh" 2>/dev/null
}
plog() { cat "$H10/build/pipeline.log" 2>/dev/null; }
D10=$(jq -nc '{v:1,project:"project-3",key:"TK-271",at:"2026-10-10T00:00:00Z",reverts:[{revert_sha:"1111111111111111",revert_pr:"465",merged_pr:"463",merge_sha:"aaaa",kind:"revert",at:"2026-10-08T10:00:00Z",status:"saved",attempts:1,classes:["build"],signals:[{class:"build",source:"vercel",text:"Deployment has failed",url:"https://vercel.example/d/1"}]}]}')
printf 'revert_reason\tproject-3 TK-271\t%s\n' "$(jq -nc --arg d "$D10" '{status:"saved",detail:$d}')" > "$T/rows.tsv"
L=$(block project-3 TK-271)
has "A10 the line" "$L" "THIS TICKET'S LAST MERGE WAS REVERTED (1 time(s))"
has "A10 inside the markers" "$L" "=== UNTRUSTED INPUT revert-11111111 === revert 11111111 of PR #463 at 2026-10-08T10:00:00Z: [build] vercel https://vercel.example/d/1: Deployment has failed === END UNTRUSTED INPUT revert-11111111 ==="
has "A10 pipeline.log" "$(plog)" "REVERT REASON: saved 1 revert(s) build"
printf 'revert_reason\tgamma #11\t%s\n' "$(jq -nc --arg d "$D10" '{status:"saved",detail:$d}')" > "$T/rows.tsv"
has "A10 a GitHub key BH-11 finds the #11 row" "$(block gamma BH-11)" "LAST MERGE WAS REVERTED"
printf 'revert_reason\tproject-3 #11\t%s\n' "$(jq -nc --arg d "$D10" '{status:"saved",detail:$d}')" > "$T/rows.tsv"
eq "A10 an app board never maps TK-11 to #11" "$(block project-3 TK-11)" ""
: > "$T/rows.tsv"
eq "A11 no row: empty" "$(block project-3 TK-271)" ""
has "A11 no row: pipeline.log" "$(plog)" "REVERT REASON: none"
eq "A11 REVERT_REASON=0: empty" "$(block project-3 TK-271 REVERT_REASON=0)" ""
has "A11 REVERT_REASON=0: pipeline.log" "$(plog)" "REVERT REASON: off"
PS="$DIR/bin/lib/rb/plan.sh"
eq "A11 the prompt carries the token once, before the reopen line" "$(grep -c '${REVERT_REASON_LINE:-}${REOPEN_REASON_LINE:-}$KIND_HINT_LINE' "$PS")" 1
a=$(grep -n '^# <<< reopen reason (BH-6159)' "$PS" | cut -d: -f1); b=$(grep -n '^# >>> revert reason (BH-6160)' "$PS" | cut -d: -f1); c=$(grep -n '^# <<< ticket meta' "$PS" | cut -d: -f1)
[ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && ok \
  || bad "A11 the block must sit after the reopen block and before '# <<< ticket meta' (lines '$a' '$b' '$c')"

# ============================================================================
# A12 the weekly line
# ============================================================================
H12="$T/h12"; scratch_rm "$H12"; mkdir -p "$H12/state/revert-reasons/project-3" "$H12/state/revert-reasons/project-4"
printf '%s\n' \
  "r1	2026-10-08T10:00:00Z	saved	1	TK-1	build,stated" \
  "r2	2026-10-07T10:00:00Z	saved	1	TK-2	build" \
  "r3	2026-10-06T10:00:00Z	saved	1	TK-3,TK-4	probe" \
  "r4	2026-10-05T10:00:00Z	saved	1	TK-5	stated" \
  "r5	2026-09-20T10:00:00Z	saved	1	TK-6	build" > "$H12/state/revert-reasons/project-3/index.tsv"
printf '%s\n' "r6	2026-10-09T10:00:00Z	no-signal	1	TK-1	-" "r7	2026-10-09T11:00:00Z	unreadable	2	-	-" > "$H12/state/revert-reasons/project-4/index.tsv"
wl() { HARNESS="$1" RV_NOW=$FIXED_NOW bash -c '. "$0"; rv_week_line 7' "$LIB" 2>/dev/null; }
eq "A12 the line" "$(wl "$H12")" "reverts 7d: project-3 4 (build 2, probe 1, stated 1, none 0), project-4 2 (build 0, probe 0, stated 0, none 1, unreadable 1)"
H12E="$T/h12e"; scratch_rm "$H12E"; mkdir -p "$H12E/state/revert-reasons/project-3"; : > "$H12E/state/revert-reasons/project-3/index.tsv"
eq "A12 no reverts in the window" "$(wl "$H12E")" "reverts 7d: none"
H12N="$T/h12n"; scratch_rm "$H12N"; mkdir -p "$H12N/state"
eq "A12 no capture yet" "$(wl "$H12N")" "reverts 7d: no data (no capture has run)"
# an index that is not a readable file (root reads through chmod 000, so this one runs as root too)
H12D="$T/h12d"; scratch_rm "$H12D"; cp -r "$H12" "$H12D"; scratch_rm "$H12D/state/revert-reasons/project-4/index.tsv"
mkdir -p "$H12D/state/revert-reasons/project-4/index.tsv"
eq "A12 an index that is a directory: never none or a partial count" "$(wl "$H12D")" "reverts 7d: mirror unreadable"
if [ "$(id -u)" != 0 ]; then
  chmod 000 "$H12/state/revert-reasons/project-3/index.tsv"
  eq "A12 an unreadable index: never none" "$(wl "$H12")" "reverts 7d: mirror unreadable"
  chmod 644 "$H12/state/revert-reasons/project-3/index.tsv"
else
  # root reads through chmod 000; a directory in place of the base is the unreadable mirror
  H12U="$T/h12u"; scratch_rm "$H12U"; mkdir -p "$H12U/state"; echo x > "$H12U/state/revert-reasons"
  eq "A12 an unreadable mirror: never none" "$(wl "$H12U")" "reverts 7d: mirror unreadable"
fi

# the real bin/lookback.sh: the line reaches the one summary sent to lane-alert
if command -v flock >/dev/null 2>&1; then
  HL="$T/h12l"; scratch_rm "$HL"; mkdir -p "$HL/logs" "$HL/env" "$HL/locks" "$HL/flags"
  : > "$HL/env/global.env"
  scratch_install_closure bin/lookback.sh "$HL" >/dev/null || bad "A12 could not install the lookback closure"
  rm -f "$HL"/bin/lib/lookback-{followup,cluster,file,board}.sh
  cp -r "$H12/state" "$HL/state"
  echo '{"items":[{"id":"y","source":"alerts","project":"cromford","ticket":null,"lane":"rebase","reason":"r"}],"sources":{},"incomplete":false}' > "$T/b12.json"
  cat > "$HL/bin/lookback-collect.sh" <<SH
#!/bin/bash
out=""; while [ \$# -gt 0 ]; do [ "\$1" = --out ] && out="\$2"; shift; done
mkdir -p "\$(dirname "\$out")"; cp "$T/b12.json" "\$out"
SH
  printf '_jobs_req() { echo %s; }\n' "'{\"ledgers\":[]}'" > "$HL/bin/jobs-client.sh"
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "%s/calls.lane-alert"\n' "$T" > "$HL/bin/lane-alert.sh"
  chmod +x "$HL/bin/lookback-collect.sh" "$HL/bin/lane-alert.sh"
  rm -f "$T/calls.lane-alert"
  env -i PATH="$PATH" HOME="$T" HARNESS="$HL" HARNESS_ENV_DIR="$HL/env" RV_NOW=$FIXED_NOW bash "$HL/bin/lookback.sh" > "$T/lb.out" 2>&1
  eq "A12 lookback rc" "$?" 0
  has "A12 the lookback summary carries the line" "$(cat "$T/calls.lane-alert" 2>/dev/null)" \
    "reverts 7d: project-3 4 (build 2, probe 1, stated 1, none 0)"
else
  echo "A12 lookback drive SKIPPED — flock missing"
fi

echo "revert-reason.bh-6160-test: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
