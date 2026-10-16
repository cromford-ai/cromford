#!/bin/bash
# tests/pr-owner-sweep-test.sh — bin/pr-owner-sweep.sh: every open PR is OWNED,
# EXTERNAL, PARKED with an expiry, or closed.
#
# WHY THIS EXISTS (2026-09-15). example-org/project-7 #323, #324, #325, #326, #327
# were opened in June and #359 in August; example-org/project-1 #630 has had a
# conflicting head since 2026-08-30. Six of the seven are harness-authored, and
# not one of them has a ledger row, a merge-conductor state, a park or a close.
# Nobody rebases them, nobody closes them, and no line in any log has ever
# mentioned them — the fleet had no concept of an unowned PR at all.
#
# WHY DRIVEN AND NOT GREPPED. Every claim here is about a DECISION with a WRITE
# behind it: which of the four classes claims a PR, and whether the sweep then
# comments, labels, closes, or clears a marker on somebody else's box. The one
# failure that cannot be taken back is closing a PR that was not ours, so
# "EXTERNAL is never touched" is asserted against a recorded gh argv, not
# against a code path. gh, curl and ssh are PATH shims (no network, no secrets).
# Run from anywhere: tests/pr-owner-sweep-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin/lib" "$H/logs" "$H/state/merge-conductor" "$H/locks" "$H/flags" \
         "$H/env" "$H/fixture" "$T/fakebin"
export HARNESS="$H"
SLUG=example-org/project-5
P=project-5
# TEST-CHANGE: BH-3933 r3 — the sweep's libs (the pr-owner hooks, pr-health,
# gh-rest for every REST write, comment-mark for the hand-back row) arrive with
# its closure, not a hand list (D46); jobs-client.sh brings bin/lib/jobs/*.sh.
scratch_install_closure bin/pr-owner-sweep.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/jobs-client.sh "$H" >/dev/null || { echo "closure install failed"; exit 1; }
scratch_install_closure bin/lib/hub-box.sh "$H" >/dev/null || exit 1; mkdir -p "$H/state"; echo box-hub > "$H/state/box-name"; export HUB_BOX_NAME=box-hub  # TEST-CHANGE: BH-5124 — the conductor file is read only on the conductor's box
cp "$DIR/bin/alert-line.sh" "$H/bin/"  # TEST-CHANGE: BH-2365 — converted writers call bin/alert-line.sh
ln -sf "$DIR/bin/fleet-conf.sh" "$H/bin/fleet-conf.sh"
export FLEET_CONF="$DIR/fleet.conf"
printf 'HARNESS_SECRET=s3cret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
printf 'GH_ADMIN_TOKEN=admintok\n' > "$H/env/github-admin.env"
export GH_TOKEN=defaulttok
export GH_BUDGET_TTL_S=0

# The box this project's watcher runs on. bin/box-for.sh is not what is under
# test here; the hand-back's LOCAL-vs-remote fork is.
printf '#!/bin/bash\nprintf "%%s\\n" "${FAKE_BOX:-box-project-5-1}"\n' > "$H/bin/box-for.sh"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/alerts-called.log"\n' > "$H/bin/lane-alert.sh"
printf '#!/bin/sh\nexit 0\n' > "$H/bin/beat.sh"
chmod +x "$H/bin/box-for.sh" "$H/bin/lane-alert.sh" "$H/bin/beat.sh"

# gh shim. Every WRITE is recorded verbatim, because "did this sweep touch a PR
# it must never touch" is the assertion that matters most here.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/gh-calls.log"
case "$1 $2" in
  "api rate_limit")
    core_rem="${GH_BUDGET_CORE:-4000}"
    graph_rem="${GH_BUDGET_GRAPHQL:-$core_rem}"
    now=$(date -u +%s)
    printf '{"resources":{"core":{"remaining":%s,"limit":5000,"reset":%s},"graphql":{"remaining":%s,"limit":5000,"reset":%s}}}\n' "$core_rem" "$now" "$graph_rem" "$now"
    exit 0 ;;
  "api repos/"*)
    # Repo visibility, per token. GH_VISIBILITY=admin makes the repo answer only
    # to the admin token, which is the hub's real shape on project-5/project-7.
    if [ "${GH_VISIBILITY:-default}" = admin ] && [ "${GH_TOKEN:-}" != admintok ]; then
      echo "gh: Not Found (HTTP 404)" >&2; exit 1; fi
    echo 1234; exit 0 ;;
esac
case "$*" in
  *"pr list"*"--state open"*)
    [ "${GH_OPEN_FAIL:-}" = 1 ] && { echo "gh: HTTP 401" >&2; exit 1; }
    cat "$HARNESS/fixture/open.json" ;;
  *"pr list"*"--state merged"*) cat "$HARNESS/fixture/merged.json" ;;
  *"pr comment"*|*"pr close"*|*"pr edit"*)
    printf '%s\n' "$*" >> "$HARNESS/gh-writes.log" ;;
  # TEST-CHANGE: BH-3933 — the REST write shapes. A comment's body travels as a
  # file (-F body=@<file>), so its text is appended to the logged line; a close
  # is re-read through GET pulls/<n>, which answers closed once the PATCH landed.
  *"api -i -X POST repos/"*"/comments"*|*"api -i -X PATCH repos/"*"/pulls/"*|*"api -i -X POST repos/"*"/labels"*)
    bf=$(printf '%s\n' "$@" | sed -n 's/^body=@//p')
    case "${GH_COMMENT_FAIL:-}:$*" in 1:*"/comments"*) printf 'HTTP/1.1 500 Server Error\r\n\r\n{}\n'; exit 0 ;; esac
    printf '%s :: %s\n' "$*" "$( [ -n "$bf" ] && tr '\n' ' ' < "$bf")" >> "$HARNESS/gh-writes.log"
    case "$*" in *"-X PATCH"*) touch "$HARNESS/closed-$(sed -nE 's#.*/pulls/([0-9]+).*#\1#p' <<<"$*")" ;; esac
    printf 'HTTP/1.1 200 OK\r\n\r\n{}\n' ;;
  # TEST-CHANGE: BH-6815 — the close-duplicate arm reads the PR's file list and
  # main's sha first (po_done_close_guard); an empty list = nothing left to ship.
  *"api -i -X GET repos/"*"/pulls/"*"/files"*)
    printf 'HTTP/1.1 200 OK\r\n\r\n[]\n' ;;
  *"api -i -X GET repos/"*"/commits/HEAD"*)
    printf 'HTTP/1.1 200 OK\r\n\r\n{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}\n' ;;
  *"api -i -X GET repos/"*"/pulls/"*)
    n=$(sed -nE 's#.*/pulls/([0-9]+).*#\1#p' <<<"$*")
    if [ -f "$HARNESS/closed-$n" ]; then printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"closed","merged_at":null}\n'
    else printf 'HTTP/1.1 200 OK\r\n\r\n{"state":"open","merged_at":null}\n'; fi ;;
  *) exit 1 ;;
esac
SH
chmod +x "$T/fakebin/gh"

# curl shim for jobs-client: /api/jobs and /api/queue from fixtures.
# CURL_MODE=down is the ledger outage the sweep must fail CLOSED on.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"
[ "${CURL_MODE:-ok}" = down ] && exit 7
case "$URL" in
  */api/jobs*)  printf '%s\n200\n' "$(cat "$HARNESS/fixture/jobs.json")" ;;
  */api/queue*) printf '%s\n200\n' "$(cat "$HARNESS/fixture/queuerows.json")" ;;
  *)            printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/curl"

# ssh shim: it records calls so the hand-back can be shown to make NONE (BH-2673:
# the row is the hand-back). It DRAINS STDIN, like the real thing, so a stray
# call would also eat the here-string that feeds the per-repo loop.
cat > "$T/fakebin/ssh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/ssh-calls.log"
cat > /dev/null
exit 0
SH
chmod +x "$T/fakebin/ssh"
export PATH="$T/fakebin:$PATH"

NOWISO() { date -u -d "@$(( $(date +%s) - ${1:-0} ))" '+%Y-%m-%dT%H:%M:%SZ'; }
D=86400

# --- the fixture repo --------------------------------------------------------
# One open PR per class plus every orphan arm, so a single run proves the rule.
fixture() {
  cat > "$H/fixture/open.json" <<JSON
[
 {"number":900,"title":"TK-900: pool build in flight","headRefName":"ticket/TK-900","author":{"login":"operator"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(NOWISO $((2*D)))","createdAt":"$(NOWISO $((3*D)))","url":"https://github.com/$SLUG/pull/900","isDraft":false},
 {"number":901,"title":"TK-901: the conductor is landing it","headRefName":"ticket/TK-901","author":{"login":"app/cromford"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(NOWISO $((2*D)))","createdAt":"$(NOWISO $((3*D)))","url":"https://github.com/$SLUG/pull/901","isDraft":false},
 {"number":902,"title":"Add the CSV mapper","headRefName":"reviewer-1/csv-mapper","author":{"login":"reviewer-1-partner"},
  "labels":[],"body":"","mergeable":"CONFLICTING","updatedAt":"$(NOWISO $((90*D)))","createdAt":"$(NOWISO $((95*D)))","url":"https://github.com/$SLUG/pull/902","isDraft":false},
 {"number":903,"title":"TK-903: org chart After view","headRefName":"ticket/TK-903","author":{"login":"operator"},
  "labels":[],"body":"Parked: waiting on the client's org data until 2099-01-01","mergeable":"MERGEABLE","updatedAt":"$(NOWISO $((30*D)))","createdAt":"$(NOWISO $((40*D)))","url":"https://github.com/$SLUG/pull/903","isDraft":false},
 {"number":904,"title":"TK-904: EU residency","headRefName":"ticket/TK-904","author":{"login":"operator"},
  "labels":[{"name":"parked"}],"body":"","mergeable":"MERGEABLE","updatedAt":"$(NOWISO $((30*D)))","createdAt":"$(NOWISO $((40*D)))","url":"https://github.com/$SLUG/pull/904","isDraft":false},
 {"number":905,"title":"TK-905: retention sweeper","headRefName":"ticket/TK-905","author":{"login":"operator"},
  "labels":[],"body":"Parked: pending the retention policy until 2020-01-01","mergeable":"MERGEABLE","updatedAt":"$(NOWISO $((30*D)))","createdAt":"$(NOWISO $((40*D)))","url":"https://github.com/$SLUG/pull/905","isDraft":false},
 {"number":906,"title":"TK-906: carry-forward","headRefName":"ticket/TK-906","author":{"login":"operator"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(NOWISO $((30*D)))","createdAt":"$(NOWISO $((40*D)))","url":"https://github.com/$SLUG/pull/906","isDraft":false},
 {"number":907,"title":"TK-907: invoice export","headRefName":"ticket/TK-907","author":{"login":"cromford[bot]"},
  "labels":[],"body":"","mergeable":"CONFLICTING","updatedAt":"$(NOWISO $((40*D)))","createdAt":"$(NOWISO $((45*D)))","url":"https://github.com/$SLUG/pull/907","isDraft":false},
 {"number":908,"title":"TK-908: already labelled","headRefName":"ticket/TK-908","author":{"login":"operator"},
  "labels":[{"name":"stale-conflict"}],"body":"","mergeable":"CONFLICTING","updatedAt":"$(NOWISO $((40*D)))","createdAt":"$(NOWISO $((45*D)))","url":"https://github.com/$SLUG/pull/908","isDraft":false},
 {"number":909,"title":"TK-909: the plain orphan","headRefName":"ticket/TK-909","author":{"login":"operator"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(NOWISO $((30*D)))","createdAt":"$(NOWISO $((40*D)))","url":"https://github.com/$SLUG/pull/909","isDraft":false},
 {"number":910,"title":"TK-910: the conductor is DONE with it","headRefName":"ticket/TK-910","author":{"login":"operator"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(NOWISO $((30*D)))","createdAt":"$(NOWISO $((40*D)))","url":"https://github.com/$SLUG/pull/910","isDraft":false},
 {"number":911,"title":"TK-911: opened four minutes ago","headRefName":"ticket/TK-911","author":{"login":"operator"},
  "labels":[],"body":"","mergeable":"MERGEABLE","updatedAt":"$(NOWISO 240)","createdAt":"$(NOWISO 240)","url":"https://github.com/$SLUG/pull/911","isDraft":false}
]
JSON
  echo '[{"number":1200,"title":"TK-906: carry-forward","headRefName":"ticket/TK-906","url":"https://github.com/'"$SLUG"'/pull/1200","mergedAt":"'"$(NOWISO $((5*D)))"'"}]' > "$H/fixture/merged.json"
  cat > "$H/fixture/jobs.json" <<JSON
{"jobs":[
 {"id":"build-project-5-TK-900-1","ticket_id":"TK-900","kind":"build","status":"running","updated_at":"$(NOWISO 600)","meta":"{\"key\":\"TK-900\"}"},
 {"id":"build-project-5-TK-909-0","ticket_id":"TK-909","kind":"build","status":"failed","updated_at":"$(NOWISO 90000)","meta":"{\"key\":\"TK-909\"}"}
]}
JSON
  echo '{"queue":[]}' > "$H/fixture/queuerows.json"
  # The conductor's own rows, read-only: a live one owns #901, a TERMINAL one
  # does not own #910. Columns: key state since head reviewed alerted reason url
  {
    printf '%s#901\tQUEUED\t1757000000\tdeadbee\tdeadbee\t-\tenqueued\thttps://x\n' "$SLUG"
    printf '%s#910\tMERGED\t1757000000\tdeadbee\tdeadbee\t-\tlanded\thttps://x\n' "$SLUG"
  } > "$H/state/merge-conductor/pr-state.tsv"
}

reset() {
  scratch_rm "$H/state/pr-owners"; scratch_rm "$H/state/gh-budget"; scratch_rm "$H/logs"; scratch_rm "$H/locks"; scratch_rm "$H/flags"
  mkdir -p "$H/state/pr-owners" "$H/state/gh-budget" "$H/logs" "$H/locks" "$H/flags"
  rm -f "$H/gh-calls.log" "$H/gh-writes.log" "$H/ssh-calls.log" "$H/alerts-called.log" "$H"/closed-*
  fixture
}
run() { "$H/bin/pr-owner-sweep.sh" --repo "$SLUG" "${1:---explain}" 2>/dev/null; }
writes() { cat "$H/gh-writes.log" 2>/dev/null; }
summary() { grep -o "$SLUG: open=.*" "$H/logs/pr-owner-sweep.log" 2>/dev/null | tail -1; }
STATEF="$H/state/pr-owners/example-org_project-5.json"
sfield() { jq -r --arg n "$1" --arg f "$2" '.prs[$n][$f] // "MISSING"' "$STATEF" 2>/dev/null; }

# ---------- 1. the four classes in one run ----------------------------------
reset
OUT=$(run)
klass() { awk -F'\t' -v n="$1" '$1==n {print $2"/"$3"\t"$5}' <<<"$OUT"; }
grep -q '^900	OWNED	none	TK-900	ledger:' <<<"$OUT" && ok || bad "OWNED: a running ledger job must own its PR: $(klass 900)"
grep -q '^901	OWNED	none	TK-901	conductor:QUEUED' <<<"$OUT" && ok || bad "OWNED: a live merge-conductor row must own its PR: $(klass 901)"
grep -q '^902	EXTERNAL	none' <<<"$OUT" && ok || bad "EXTERNAL: a non-harness author belongs to review-prs: $(klass 902)"
grep -q '^903	PARKED	none' <<<"$OUT" && ok || bad "PARKED: a 'Parked: … until <future>' body line: $(klass 903)"
grep -q '^904	PARKED	none' <<<"$OUT" && ok || bad "PARKED: the 'parked' label: $(klass 904)"
grep -q '^905	ORPHAN	handback:TK-905' <<<"$OUT" && ok || bad "an EXPIRED park is not a park — the whole point of the date: $(klass 905)"
grep -q '^906	ORPHAN	close-duplicate:1200' <<<"$OUT" && ok || bad "ORPHAN whose key already merged elsewhere: $(klass 906)"
grep -q '^907	ORPHAN	stale-conflict:40' <<<"$OUT" && ok || bad "ORPHAN with a head conflicting 40d: $(klass 907)"
grep -q '^908	ORPHAN	none' <<<"$OUT" && ok || bad "a PR already carrying stale-conflict is never commented on twice: $(klass 908)"
grep -q '^909	ORPHAN	handback:TK-909' <<<"$OUT" && ok || bad "a plain ORPHAN's key goes back to its box: $(klass 909)"
grep -q '^910	ORPHAN	handback:TK-910' <<<"$OUT" && ok || bad "a TERMINAL conductor row is not an owner: $(klass 910)"
grep -q '^911	OWNED	none	TK-911	grace:' <<<"$OUT" && ok \
  || bad "GRACE: a PR that just moved belongs to the event path, not to this backstop: $(klass 911)"

# ---------- 2. the writes, and only those writes ----------------------------
# TEST-CHANGE: BH-3933 — the writes are REST argv now (the same three writes).
grep -q "PATCH repos/$SLUG/pulls/906 " <<<"$(writes)" && ok || bad "the duplicate must be CLOSED: $(writes)"
grep -q "POST repos/$SLUG/issues/906/comments .*\*\*TK-906 already shipped in #1200\*\*" <<<"$(writes)" && ok \
  || bad "the close comment must name the PR that shipped the work: $(writes)"
grep -q "POST repos/$SLUG/issues/907/labels -f labels\[\]=stale-conflict" <<<"$(writes)" && ok \
  || bad "the stale head must be LABELLED: $(writes)"
grep -q 'issues/907/comments ' <<<"$(writes)" && ok || bad "the stale head must be commented once: $(writes)"
grep -c 'issues/907/comments ' <<<"$(writes)" | grep -qx 1 && ok || bad "exactly one comment on the stale PR: $(writes)"
grep -q '/908[/ ]' <<<"$(writes)" && bad "a PR already labelled stale-conflict must not be written to again: $(writes)" || ok
# THE ONE THAT CANNOT BE TAKEN BACK
grep -q '/902[/ ]' <<<"$(writes)" && bad "an EXTERNAL PR must never be closed, labelled or commented on: $(writes)" || ok
for N in 900 901 903 904 911; do
  grep -q "/$N[/ ]" <<<"$(writes)" && bad "#$N is owned or parked — nothing may be written to it: $(writes)" || ok
done
# A comment GitHub refused stops the close (D9): the PR is held, never CLOSED.
reset
GH_COMMENT_FAIL=1 run >/dev/null
grep -q "PATCH repos/$SLUG/pulls/906 " <<<"$(writes)" && bad "a refused comment must not be followed by the close: $(writes)" || ok
grep -q 'held=.*#906:write-failed' <<<"$(summary)" && ok || bad "the refused write holds the PR as write-failed: $(summary)"
grep -q 'closed=[^ ]*#906' <<<"$(summary)" && bad "a PR that was not closed must not be reported closed: $(summary)" || ok

# ---------- 3. the hand-back clears the row, never ssh ----------------------
# BH-2317/BH-2673: a cleared `blocked` row outvotes any stamp on the box, so the
# hand-back is that row write and nothing reaches over to the box.
[ ! -s "$H/ssh-calls.log" ] && ok || bad "the hand-back must not ssh to any box: $(cat "$H/ssh-calls.log" 2>/dev/null)"
grep -q 'handed-back=.*#909(TK-909)' <<<"$(summary)" && ok || bad "the plain orphan must be handed back: $(summary)"
grep -q 'handed-back=.*#905(TK-905)' <<<"$(summary)" && ok || bad "the expired park must be handed back too: $(summary)"
# …and the hub's own stamp goes when the hub itself owns the project
reset
mkdir -p "$H/state"
touch "$H/state/blocked-commented-$P-TK-909-202609151200"
FAKE_BOX=local run >/dev/null
[ ! -f "$H/state/blocked-commented-$P-TK-909-202609151200" ] && ok \
  || bad "on a locally-owned project the marker must be cleared in place"

# ---------- 4. the state file is the durable record -------------------------
reset
run >/dev/null
[ "$(sfield 902 state)" = EXTERNAL ] && ok || bad "state/pr-owners must record EXTERNAL: $(sfield 902 state)"
[ "$(sfield 900 state)" = OWNED ] && ok || bad "…and OWNED: $(sfield 900 state)"
[ "$(sfield 904 state)" = PARKED ] && ok || bad "…and PARKED: $(sfield 904 state)"
[ "$(sfield 909 state)" = ORPHAN ] && ok || bad "…and ORPHAN: $(sfield 909 state)"
[ "$(sfield 909 reason)" != MISSING ] && ok || bad "every row carries a reason"
SINCE1=$(sfield 902 since)
case "$SINCE1" in 20*T*Z) ok ;; *) bad "since must be an ISO stamp, got '$SINCE1'" ;; esac
sleep 1
run >/dev/null
[ "$(sfield 902 since)" = "$SINCE1" ] && ok \
  || bad "'since' must mean the first tick this PR read this way, not 'now': $SINCE1 -> $(sfield 902 since)"

# ---------- 5. ONE alert per repo, listing every PR --------------------------
reset
run >/dev/null
[ "$(grep -c . "$H/alerts-called.log")" = 1 ] && ok \
  || bad "one alert per repo, never one per PR: $(cat "$H/alerts-called.log")"
grep -q 'pr-owner-sweep/'"$SLUG" "$H/alerts-called.log" && ok || bad "the alert names the repo: $(cat "$H/alerts-called.log")"
grep -q '#907(40d)' "$H/alerts-called.log" && ok || bad "the alert lists the stale PRs: $(cat "$H/alerts-called.log")"
grep -q '#906(dup of #1200)' "$H/alerts-called.log" && ok || bad "…and the closed ones: $(cat "$H/alerts-called.log")"
# a quiet repo does not page: with nothing actionable there is no alert
reset
jq '[.[] | select(.number==900 or .number==902 or .number==903)]' "$H/fixture/open.json" > "$T/q.json"
mv "$T/q.json" "$H/fixture/open.json"
run >/dev/null
[ ! -s "$H/alerts-called.log" ] && ok || bad "a run with no orphan action must not alert: $(cat "$H/alerts-called.log")"
grep -q 'orphans=0' "$H/logs/pr-owner-sweep.log" && ok || bad "…but it still logs its one line: $(summary)"

# ---------- 6. the cap -------------------------------------------------------
reset
PR_OWNER_MAX_ACTIONS=2 run >/dev/null
[ "$(grep -c 'X PATCH repos/\|/labels ' "$H/gh-writes.log" 2>/dev/null || echo 0)" -le 2 ] && ok \
  || bad "PR_OWNER_MAX_ACTIONS=2 must bound the writes: $(writes)"
grep -q 'held=.*:cap' "$H/logs/pr-owner-sweep.log" && ok || bad "the capped PRs must be logged: $(summary)"

# ---------- 7. dry run writes nothing ---------------------------------------
reset
PR_OWNER_DRY_RUN=1 run >/dev/null
[ ! -s "$H/gh-writes.log" ] && ok || bad "PR_OWNER_DRY_RUN=1 must not touch GitHub: $(writes)"
[ ! -s "$H/ssh-calls.log" ] && ok || bad "PR_OWNER_DRY_RUN=1 must not clear a marker on any box: $(cat "$H/ssh-calls.log")"
grep -q "DRY-RUN would: close $SLUG#906" "$H/logs/pr-owner-sweep.log" && ok \
  || bad "…and it must say what it WOULD have done: $(tail -3 "$H/logs/pr-owner-sweep.log")"
[ -s "$STATEF" ] && ok || bad "a dry run still records owner state — that read is free and is the point"

# ---------- 8. the admin token is what SEES project-5 / project-7 ------------
# The hub's default PAT 404s on both, and an empty PR list there reads exactly
# like a repo with no open PRs (the 2026-09-12 project-5 silence).
reset
GH_VISIBILITY=admin run >/dev/null
grep -q "PATCH repos/$SLUG/pulls/906 " "$H/gh-writes.log" && ok \
  || bad "a repo only the admin token can see must still be swept: $(cat "$H/gh-calls.log" | head -5)"
# …and a repo NO token can see is an ALERT, never a quiet skip
reset
printf 'GH_ADMIN_TOKEN=wrongtok\n' > "$H/env/github-admin.env"
GH_VISIBILITY=admin run >/dev/null
[ ! -s "$H/gh-writes.log" ] && ok || bad "an invisible repo must be acted on by nothing: $(writes)"
grep -q 'INVISIBLE to the default gh token' "$H/logs/ALERTS.log" 2>/dev/null && ok \
  || bad "an invisible repo must ALERT: $(tail -2 "$H/logs/ALERTS.log" 2>/dev/null)"
printf 'GH_ADMIN_TOKEN=admintok\n' > "$H/env/github-admin.env"

# ---------- 9. it fails CLOSED, never open ----------------------------------
# "We cannot name these PRs' owners" and "these PRs have no owner" are different
# sentences, and only one of them may close a pull request.
reset
CURL_MODE=down run >/dev/null
[ ! -s "$H/gh-writes.log" ] && ok || bad "a ledger outage must write nothing: $(writes)"
[ ! -f "$STATEF" ] && ok || bad "a ledger outage must record nothing either"
grep -q 'jobs ledger unreachable' "$H/logs/pr-owner-sweep.log" && ok \
  || bad "…and must say so: $(tail -1 "$H/logs/pr-owner-sweep.log")"
reset
GH_OPEN_FAIL=1 run >/dev/null
[ ! -s "$H/gh-writes.log" ] && ok || bad "a failed PR list must write nothing: $(writes)"

# ---------- 10. the switches -------------------------------------------------
reset
PR_OWNER_SWEEP=0 run >/dev/null
[ ! -s "$H/gh-writes.log" ] && [ ! -s "$H/logs/pr-owner-sweep.log" ] && ok \
  || bad "PR_OWNER_SWEEP=0 must be a silent no-op: $(writes)"
reset
touch "$H/flags/pr-owner-sweep-off"
run >/dev/null
[ ! -s "$H/gh-writes.log" ] && [ ! -s "$H/logs/pr-owner-sweep.log" ] && ok \
  || bad "flags/pr-owner-sweep-off must be a silent no-op: $(writes)"
rm -f "$H/flags/pr-owner-sweep-off"
# a longer stale window stops the labelling and nothing else
reset
PR_OWNER_STALE_DAYS=999 run >/dev/null
grep -q 'labels\[\]=stale-conflict' "$H/gh-writes.log" && bad "PR_OWNER_STALE_DAYS=999 must hold the label back" || ok
grep -q "PATCH repos/$SLUG/pulls/906 " "$H/gh-writes.log" && ok || bad "…while the duplicate close is a different rule: $(writes)"

# ---------- 11. gh-budget skips non-essential reads when low ----------------
# A low GitHub API budget must short-circuit the sweep before any pr list,
# record nothing, and still exit 0.
reset
GH_BUDGET_CORE=100 run >/dev/null
grep -q 'pr list' "$H/gh-calls.log" 2>/dev/null && bad "a low budget must skip pr list reads: $(cat "$H/gh-calls.log" 2>/dev/null)" || ok
[ ! -f "$STATEF" ] && ok || bad "a low budget must record no state file either"
grep -q 'GitHub API budget low' "$H/logs/pr-owner-sweep.log" && ok \
  || bad "a low budget must log one budget-low line: $(cat "$H/logs/pr-owner-sweep.log" 2>/dev/null)"
# A healthy budget leaves existing behavior unchanged.
reset
GH_BUDGET_CORE=4000 run >/dev/null
grep -q "pr list -R $SLUG --state open" "$H/gh-calls.log" && ok \
  || bad "a healthy budget must still read open PRs: $(cat "$H/gh-calls.log" 2>/dev/null)"
grep -q "PATCH repos/$SLUG/pulls/906 " "$H/gh-writes.log" && ok \
  || bad "a healthy budget must still close duplicates: $(writes)"

# ---------- 12. the fleet-wide pass reads the registry ----------------------
# No copy of the project list (tests/fleet-projects-not-hardcoded-test.sh): the
# repos come from fleet.conf, which is what makes example-org/project-7 — enrolled
# as `project-7` — part of the sweep at all.
# It must also survive its own hand-backs: project-1 is the FIRST row in
# fleet.conf, so any child of a hand-back that reads stdin eats every repo after it.
reset
"$H/bin/pr-owner-sweep.sh" --explain >/dev/null 2>&1
for WANT in example-org/project-1 example-org/project-5 example-org/project-7; do
  grep -q "pr list -R $WANT --state open" "$H/gh-calls.log" && ok \
    || bad "the fleet-wide pass must reach $WANT (a hand-back on an earlier repo must not eat the loop's stdin)"
done

echo "pr-owner-sweep: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
