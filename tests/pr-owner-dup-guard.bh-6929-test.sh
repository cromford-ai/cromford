#!/bin/bash
# tests/pr-owner-dup-guard.bh-6929-test.sh — BH-6929: bin/pr-owner-sweep.sh must
# not close a stacked slice PR, an armed or approved PR, or a reopened PR as a
# duplicate. On 2026-10-15 17:11Z it closed example-org/project-6 #721 and #746
# (TK-702 slices 1 and 2, approved and queued) as duplicates of #770 (slice 3,
# stacked on both).
#
#   U1-U14  po_dup_guard (bin/lib/pr-owner/dup-guard.sh), sourced, on fixtures.
#   E1-E5   the REAL bin/pr-owner-sweep.sh: the project-6 replay, a reopened PR,
#           a true duplicate (still closed, one critical alert), rule 1 and the
#           sweep's own close-duplicate arm.
#
# gh and curl are PATH shims: no network. Every GitHub write is recorded in
# $H/writes.log as `COMMENT <n> …` or `CLOSE <n>`; every lane-alert.sh call is
# one line of its args in $H/alerts.log.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pr-owner-dup-guard.bh-6929-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }
command -v git     >/dev/null || { echo "git missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/bin" "$H/logs" "$H/locks" "$H/state/merge-conductor" "$H/state/pr-owners" "$H/flags" "$H/env" "$H/fixture" "$T/fakebin" "$T/norepos"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$HARNESS/alerts.log"\nexit 0\n' > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"
# The stub above is written FIRST: the closure install never overwrites (D46).
for s in bin/pr-owner-sweep.sh bin/jobs-client.sh bin/fleet-conf.sh bin/lib/ticket-ownership.sh \
         bin/lib/merge-conductor-lib.sh bin/lib/hub-box.sh bin/lib/gh-rest.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "FAIL: closure install failed: $s"; exit 1; }
done
printf 'HARNESS_SECRET=s3cret-fixture\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
printf 'project-6 example-org/project-6 - -\n' > "$H/fleet.conf"

# gh shim. The CLI list reads come from fixture/{open,merged}.json, with only
# the fields the sweep asks for. REST (`gh api -i -X …`) answers a status line:
#   issues/<n>/events    fixture/events-<n>.json (default []), events-<n>.code
#   issues/<n>/comments  fixture/prthread-<n>.json (default [])
#   compare/<a>...<b>    fixture/compare.tsv `<a> <b> <status|code>` (default diverged)
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
F="$HARNESS/fixture"
printf '%s\n' "$*" >> "$HARNESS/gh-calls.log"
resp() { printf 'HTTP/2.0 %s X\r\ncontent-type: application/json\r\n\r\n%s\n' "$1" "$2"; }
case "$1 $2" in
  "api rate_limit") printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":%s},"graphql":{"remaining":4000,"limit":5000,"reset":%s}}}\n' "$(date +%s)" "$(date +%s)"; exit 0 ;;
  "api --paginate")
    case "$3" in repos/*/issues/*/comments*)
      n="${3%/comments*}"; n="${n##*/}"; cat "$F/thread-$n.json" 2>/dev/null || echo '[]'; exit 0 ;;
    esac
    exit 1 ;;
  "api repos/"*/issues/*)
    n="${2##*/}"; [ -f "$F/issue-$n.json" ] || exit 1
    cat "$F/issue-$n.json"; exit 0 ;;
  "api repos/"*) echo 1234; exit 0 ;;
esac
case "$*" in
  *"pr list"*"--state open"*"latestReviews"*) cat "$F/open.json"; exit 0 ;;
  *"pr list"*"--state open"*)   jq -c 'map(del(.latestReviews))' "$F/open.json"; exit 0 ;;
  *"pr list"*"--state merged"*) cat "$F/merged.json"; exit 0 ;;
esac
if [ "$1 $2 $3" = "api -i -X" ]; then
  M="$4"; P="$5"; shift 5
  case "$M $P" in
    "GET repos/"*/issues/*/events*)
      n="${P%/events*}"; n="${n##*/}"
      resp "$(cat "$F/events-$n.code" 2>/dev/null || echo 200)" "$(cat "$F/events-$n.json" 2>/dev/null || echo '[]')" ;;
    "GET repos/"*/issues/*/comments*)
      n="${P%/comments*}"; n="${n##*/}"
      resp 200 "$(cat "$F/prthread-$n.json" 2>/dev/null || echo '[]')" ;;
    "GET repos/"*/compare/*)
      c="${P#*/compare/}"; c="${c%%\?*}"; a="${c%%...*}"; b="${c#*...}"
      st=$(awk -v a="$a" -v b="$b" '$1==a && $2==b {print $3; exit}' "$F/compare.tsv" 2>/dev/null)
      case "${st:-diverged}" in
        [0-9]*) resp "$st" '{"message":"boom"}' ;;
        *) resp 200 "{\"status\":\"${st:-diverged}\",\"ahead_by\":1,\"behind_by\":0}" ;;
      esac ;;
    "GET repos/"*/issues/*)
      n="${P##*/}"
      resp 200 "$(cat "$F/issue-$n.json" 2>/dev/null || echo '{"message":"Not Found"}')" ;;
    "POST repos/"*/comments)
      n="${P%/comments}"; n="${n##*/}"; b=""
      for a in "$@"; do case "$a" in body=@*) b=$(cat "${a#body=@}") ;; esac; done
      printf 'COMMENT %s %s\n' "$n" "$(printf '%s' "$b" | tr '\n' ' ')" >> "$HARNESS/writes.log"
      resp 201 '{"id":1}' ;;
    "PATCH repos/"*/pulls/*)
      n="${P##*/}"
      printf 'CLOSE %s\n' "$n" >> "$HARNESS/writes.log"; touch "$F/closed-$n"
      resp 200 '{"state":"closed"}' ;;
    # TEST-CHANGE (BH-6815 merge): the close-duplicate arm runs
    # po_done_close_guard after po_dup_guard. It reads the PR's file list and
    # main's sha; an empty list is shipped, so the done guard clears.
    "GET repos/"*/pulls/*/files*)
      resp 200 '[]' ;;
    "GET repos/"*/commits/HEAD)
      resp 200 '{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' ;;
    "GET repos/"*/pulls/*)
      n="${P##*/}"; st=open; [ -f "$F/closed-$n" ] && st=closed
      resp 200 "{\"state\":\"$st\",\"merged_at\":null}" ;;
    *) resp 404 '{}' ;;
  esac
  exit 0
fi
exit 1
SH

# curl shim: the jobs API only.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; M=GET; F="$HARNESS/fixture"
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; *) shift ;; esac; done
case "$M $URL" in
  "GET https://jobs.test/api/jobs"*)  printf '%s\n200\n' "$(cat "$F/jobs.json")" ;;
  "GET https://jobs.test/api/queue"*) printf '{"queue":[]}\n200\n' ;;
  "GET https://jobs.test/api/verdicts"*) printf '{"standing":null,"rows":[]}\n200\n' ;;
  "GET https://jobs.test/"*) printf '{"error":"none"}\n404\n' ;;
  *) printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
export BOX_NAME=box-hub HUB_BOX_NAME=box-hub

DAY=86400
NOWISO() { date -u -d "@$(( $(date +%s) - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
OLD=$(NOWISO $((3*DAY))); YDAY=$(NOWISO $DAY)
SLUG=example-org/project-6
hd() { printf '%s' "$1" | sha1sum | cut -c1-40; }   # a fixed 40-hex head per name
# pr <num> <title> <branch> [author] [body] [reviews-json] — one open-PR object, head $(hd <num>)
pr() {
  jq -nc --argjson n "$1" --arg t "$2" --arg b "$3" --arg a "${4:-operator}" --arg body "${5:-}" \
     --argjson rv "${6:-[]}" --arg h "$(hd "$1")" --arg old "$OLD" --arg slug "$SLUG" \
    '{number:$n,title:$t,headRefName:$b,baseRefName:"main",headRefOid:$h,author:{login:$a},
      labels:[],body:$body,mergeable:"MERGEABLE",updatedAt:$old,createdAt:$old,latestReviews:$rv,
      url:"https://github.com/\($slug)/pull/\($n)",isDraft:false}'
}
opens() { printf '%s\n' "$@" | jq -s . > "$H/fixture/open.json"; }
cmp() { printf '%s %s %s\n' "$(hd "$1")" "$(hd "$2")" "$3" >> "$H/fixture/compare.tsv"; }  # cmp <a> <b> <status>
setup() {
  scratch_rm "$H/fixture" || exit 1; scratch_rm "$H/logs" || exit 1; scratch_rm "$H/locks" || exit 1
  scratch_rm "$H/state" || exit 1
  mkdir -p "$H/fixture" "$H/logs" "$H/locks" "$H/state/merge-conductor" "$H/state/pr-owners"
  rm -f "$H/writes.log" "$H/alerts.log" "$H/gh-calls.log"
  echo '[]' > "$H/fixture/open.json"; echo '[]' > "$H/fixture/merged.json"; : > "$H/fixture/compare.tsv"
  echo '{"jobs":[{"id":"build-TK-702","ticket_id":"TK-702","kind":"build","status":"running","meta":"{}"}]}' > "$H/fixture/jobs.json"
  : > "$H/state/merge-conductor/pr-state.tsv"
  printf '{"number":702,"title":"the ticket","state":"open","labels":[],"body":""}' > "$H/fixture/issue-702.json"
}
run() { env HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_TOKEN=x GH_BUDGET_TTL_S=0 GH_ETAG=0 JOBS_RETRIES=0 \
          PR_OWNER_REPO_ROOT="$T/norepos" "$@" \
          bash "$H/bin/pr-owner-sweep.sh" --repo "$SLUG" >/dev/null 2>"$T/run.err"; RC=$?; }
W()    { cat "$H/writes.log" 2>/dev/null; }
LOGT() { cat "$H/logs/pr-owner-sweep.log" 2>/dev/null; }
closed()    { grep -qx "CLOSE $1" "$H/writes.log" 2>/dev/null; }
commented() { grep -q "^COMMENT $1 " "$H/writes.log" 2>/dev/null; }
summary() { grep -o "$SLUG: open=.*" "$H/logs/pr-owner-sweep.log" 2>/dev/null | tail -1; }
crit() { cat "$H/alerts.log" 2>/dev/null | grep -c -- "--severity critical"; }

# ---------- unit harness: po_dup_guard sourced on fixtures -----------------------
# ug <num> <ekey> [NAME=value ...] — prints `rc=<n> held=<HELD>`; the say lines go to $U/say.log.
U="$T/u"
usetup() {
  setup; scratch_rm "$U" || exit 1; mkdir -p "$U/td"; : > "$U/td/verdicts.tsv"; : > "$U/say.log"
}
# vrow <num> <head> <ekey> — one verdicts.tsv row in the sweep's 17-column shape
vrow() { printf '%s\tORPHAN\tnone\t%s\tr\t-\toperator\t%s\t0\tMERGEABLE\t%s\t%s\t-\t-\t-\tb-%s\t-\n' \
           "$1" "$3" "$OLD" "$2" "$3" "$1" >> "$U/td/verdicts.tsv"; }
uopens() { opens "$@"; cp "$H/fixture/open.json" "$U/td/open.json"; }
ug() {
  local n="$1" k="$2"; shift 2
  ( export HARNESS="$H" GH_TOKEN=x GH_ETAG=0 GH_BUDGET_TTL_S=0 PR_OWNER_REPO_ROOT="$T/norepos"
    say() { printf '%s\n' "$*" >> "$U/say.log"; }
    [ -r "$H/bin/lib/pr-owner/dup-guard.sh" ] || { echo "rc=9 held=no-lib"; exit 0; }
    . "$H/bin/lib/pr-owner/dup-guard.sh" || { echo "rc=9 held=no-lib"; exit 0; }
    TD="$U/td" PO_SLUG="$SLUG" PO_NUM="$n" PO_EKEY="$k" PO_PROJECT=project-6 PO_MC_STATE=- HELD=""
    PO_HEAD=$(jq -r --argjson n "$n" '.[] | select(.number == $n) | .headRefOid' "$U/td/open.json")
    [ $# -gt 0 ] && export "$@"
    po_dup_guard </dev/null; r=$?
    echo "rc=$r held=$HELD" )
}
SAY() { cat "$U/say.log" 2>/dev/null; }
# std <titleA> [bodyB] [reviewsA] — #721 (title A) and #770, same key, verdict rows, heads diverged
std() {
  usetup
  uopens "$(pr 721 "$1" ticket/TK-702-a operator "" "${3:-[]}")" "$(pr 770 'TK-702: three' ticket/TK-702-c operator "${2:-}")"
  vrow 721 "$(hd 721)" TK-702; vrow 770 "$(hd 770)" TK-702
}

# U1 / U2 slice titles
std 'TK-702 slice 1: x'; R=$(ug 721 TK-702)
[ "$R" = "rc=0 held=#721:slice" ] && ok || bad "U1 a 'slice' title keeps the PR: $R"
grep -q "$SLUG#721: duplicate close refused — slice" <<<"$(SAY)" && ok || bad "U1 the keep line names the tag: $(SAY)"
std 'BH-1 (part 2 of 3)'; R=$(ug 721 TK-702)
[ "$R" = "rc=0 held=#721:slice" ] && ok || bad "U2 a 'part N' title keeps the PR: $R"

# U3 another open PR names it in Blocked-by
std 'TK-702: one' $'Some text\nBlocked-by: #721\n'; R=$(ug 721 TK-702)
[ "$R" = "rc=0 held=#721:blocked-by" ] && ok || bad "U3 a Blocked-by line naming #721 keeps it: $R"
std 'TK-702: one' 'Blocked-by: https://github.com/example-org/project-6/pull/721'; R=$(ug 721 TK-702)
[ "$R" = "rc=0 held=#721:blocked-by" ] && ok || bad "U3b a Blocked-by /pull/721 URL keeps it: $R"

# U4 armed by the conductor
for s in READY QUEUED MERGING; do
  std 'TK-702: one'; R=$(ug 721 TK-702 PO_MC_STATE=$s)
  [ "$R" = "rc=0 held=#721:armed" ] && ok || bad "U4 conductor state $s keeps it: $R"
done

# U5 an APPROVED latest review
std 'TK-702: one' '' '[{"author":{"login":"rev"},"state":"APPROVED","submittedAt":"2026-10-15T10:00:00Z"}]'; R=$(ug 721 TK-702)
[ "$R" = "rc=0 held=#721:approved" ] && ok || bad "U5 an APPROVED review keeps it: $R"

# U6 reopened before
std 'TK-702: one'; echo '[{"event":"closed"},{"event":"reopened"}]' > "$H/fixture/events-721.json"; R=$(ug 721 TK-702)
[ "$R" = "rc=0 held=#721:reopened" ] && ok || bad "U6 a reopened event keeps it: $R"

# U7 a "not a duplicate" comment
std 'TK-702: one'; echo '[{"user":{"login":"x"},"body":"This is NOT a duplicate. It has the migration."}]' > "$H/fixture/prthread-721.json"
R=$(ug 721 TK-702)
[ "$R" = "rc=0 held=#721:not-a-duplicate" ] && ok || bad "U7 a 'not a duplicate' comment keeps it: $R"

# U8 a clean true duplicate is clear to close
std 'TK-702: one'; R=$(ug 721 TK-702)
[ "$R" = "rc=1 held=" ] && ok || bad "U8 a true duplicate is clear to close: $R"
[ ! -s "$U/say.log" ] && ok || bad "U8 a clear PR prints no keep line: $(SAY)"

# U9 / U10 adversarial titles and bodies
std 'BH-1 sliced cache'; R=$(ug 721 TK-702)
[ "$R" = "rc=1 held=" ] && ok || bad "U9 'sliced' is not 'slice': $R"
usetup
uopens "$(pr 721 'BH-1 partial rewrite' ticket/TK-702-a operator 'Part of #900')" "$(pr 770 'TK-702: three' ticket/TK-702-c)"
vrow 721 "$(hd 721)" TK-702; vrow 770 "$(hd 770)" TK-702
R=$(ug 721 TK-702)
[ "$R" = "rc=1 held=" ] && ok || bad "U10 'partial' and a body 'Part of #900' are not slices: $R"

# U11 near misses: Blocked-by #7210, a COMMENTED review, a 'duplicate of' comment
std 'TK-702: one' 'Blocked-by: #7210' '[{"author":{"login":"rev"},"state":"COMMENTED"},{"author":{"login":"r2"},"state":"CHANGES_REQUESTED"}]'
echo '[{"user":{"login":"x"},"body":"duplicate of #12"}]' > "$H/fixture/prthread-721.json"
R=$(ug 721 TK-702)
[ "$R" = "rc=1 held=" ] && ok || bad "U11 #7210, COMMENTED/CHANGES_REQUESTED and 'duplicate of' keep nothing: $R"

# U12 the git path: a checkout with both heads
GR="$T/repos"; scratch_rm "$GR" || exit 1; mkdir -p "$GR/project-6"
( cd "$GR/project-6" && git init -q && git config user.email t@example.com && git config user.name t \
  && git commit -q --allow-empty -m A && git rev-parse HEAD > ../A \
  && git commit -q --allow-empty -m B && git rev-parse HEAD > ../B \
  && git checkout -q -b side HEAD~1 && git commit -q --allow-empty -m C && git rev-parse HEAD > ../C ) \
  || { echo "FAIL: cannot build the scratch repo"; exit 1; }
GA=$(cat "$GR/A"); GB=$(cat "$GR/B"); GC=$(cat "$GR/C")
gitcase() { # gitcase <this-head> <sibling-head>
  usetup; uopens "$(pr 721 'TK-702: one' ticket/TK-702-a)" "$(pr 770 'TK-702: three' ticket/TK-702-c)"
  vrow 721 "$1" TK-702; vrow 770 "$2" TK-702
  ug 721 TK-702 PO_HEAD="$1" PR_OWNER_REPO_ROOT="$GR"
}
R=$(gitcase "$GA" "$GB")
[ "$R" = "rc=0 held=#721:stacked" ] && ok || bad "U12 git: this head is an ancestor of the sibling's head → stacked: $R"
grep -q 'duplicate close refused — stacked' <<<"$(SAY)" && ok || bad "U12 the keep line says stacked: $(SAY)"
R=$(gitcase "$GB" "$GA")
[ "$R" = "rc=0 held=#721:stacked" ] && ok || bad "U12b git: the sibling's head is an ancestor of this head → stacked: $R"
R=$(gitcase "$GB" "$GC")
[ "$R" = "rc=1 held=" ] && ok || bad "U12c git: diverged heads are clear to close: $R"
! grep -q /compare/ "$H/gh-calls.log" 2>/dev/null && ok || bad "U12 the git path makes no REST compare: $(grep /compare/ "$H/gh-calls.log")"

# U13 the REST path (no checkout)
for c in ahead:0:stacked behind:0:stacked identical:0:stacked diverged:1:; do
  st="${c%%:*}"; rest="${c#*:}"; want="${rest%%:*}"; tag="${rest#*:}"
  std 'TK-702: one'; cmp 721 770 "$st"; R=$(ug 721 TK-702)
  exp="rc=$want held="; [ -n "$tag" ] && exp="rc=$want held=#721:$tag"
  [ "$R" = "$exp" ] && ok || bad "U13 REST compare '$st' → $exp: $R"
done
std 'TK-702: one'; cmp 721 770 500; R=$(ug 721 TK-702)
[ "$R" = "rc=0 held=#721:guard-unread" ] && ok || bad "U13b a failed compare keeps it guard-unread: $R"

# U14 an unreadable events read keeps it, and never as `reopened`
std 'TK-702: one'; echo 500 > "$H/fixture/events-721.code"; echo '[{"event":"reopened"}]' > "$H/fixture/events-721.json"
R=$(ug 721 TK-702)
[ "$R" = "rc=0 held=#721:guard-unread" ] && ok || bad "U14 events 500 → guard-unread: $R"
std 'TK-702: one'; echo '{"message":"x"}' > "$H/fixture/events-721.json"; R=$(ug 721 TK-702)
[ "$R" = "rc=0 held=#721:guard-unread" ] && ok || bad "U14b a non-array events answer → guard-unread: $R"
std 'TK-702: one'; jq 'map(del(.latestReviews))' "$U/td/open.json" > "$U/td/o2" && mv "$U/td/o2" "$U/td/open.json"
R=$(ug 721 TK-702)
[ "$R" = "rc=0 held=#721:guard-unread" ] && ok || bad "U14c an open list with no latestReviews field → guard-unread: $R"
usetup; uopens "$(pr 721 'TK-702: one' ticket/TK-702-a)"
for i in $(seq 800 811); do vrow "$i" "$(hd "$i")" TK-702; done; vrow 721 "$(hd 721)" TK-702
R=$(ug 721 TK-702)
[ "$R" = "rc=0 held=#721:guard-unread" ] && ok || bad "U14d more than 10 open siblings → guard-unread: $R"

# ---------- E1 the project-6 replay: three stacked slices, base main -----------
setup
opens "$(pr 721 'TK-702 slice 1: ledger' ticket/TK-702-1)" "$(pr 746 'TK-702 slice 3: mac' ticket/TK-702-2-mac)" \
      "$(pr 770 'TK-702 slice 4: ui' ticket/TK-702-4)"
cmp 721 746 ahead; cmp 721 770 ahead; cmp 746 770 ahead
run
[ "$RC" = 0 ] && ok || bad "E1 the sweep exits 0 (rc=$RC): $(head -3 "$T/run.err")"
! closed 721 && ! closed 746 && ! commented 721 && ! commented 746 && ok || bad "E1 #721 and #746 are not commented on or closed: $(W)"
grep -q "$SLUG#721: duplicate close refused — slice" <<<"$(LOGT)" && grep -q "$SLUG#746: duplicate close refused — slice" <<<"$(LOGT)" \
  && ok || bad "E1 the log says why for both: $(LOGT | grep -E '#(721|746)' | tail -4)"
grep -q 'held=#721:slice,#746:slice' <<<"$(summary)" && ok || bad "E1 the summary holds both: $(summary)"
[ "$(crit)" = 0 ] && ok || bad "E1 nothing closed → no critical alert: $(cat "$H/alerts.log" 2>/dev/null)"

# ---------- E1b the same stack with plain titles: the heads decide ---------------
setup
opens "$(pr 721 'TK-702: ledger' ticket/TK-702-1)" "$(pr 746 'TK-702: mac' ticket/TK-702-2-mac)" "$(pr 770 'TK-702: ui' ticket/TK-702-4)"
cmp 721 746 ahead; cmp 721 770 ahead; cmp 746 770 ahead
run
! closed 721 && ! closed 746 && ok || bad "E1b stacked heads are not closed: $(W)"
grep -q 'held=#721:stacked,#746:stacked' <<<"$(summary)" && ok || bad "E1b the summary holds both as stacked: $(summary)"

# ---------- E2 a PR reopened before is not closed on the next sweep -------------
setup
opens "$(pr 10 'TK-702: a' ticket/TK-702-a)" "$(pr 11 'TK-702: b' ticket/TK-702-b)"
echo '[{"event":"closed","actor":{"login":"operator"}},{"event":"reopened","actor":{"login":"operator"}}]' > "$H/fixture/events-10.json"
run
! closed 10 && ! commented 10 && ok || bad "E2 a reopened PR is not closed: $(W)"
grep -q 'held=#10:reopened' <<<"$(summary)" && ok || bad "E2 the summary says reopened: $(summary)"

# ---------- E3 true duplicates are still closed, with ONE critical alert --------
setup
opens "$(pr 10 'TK-702: a' ticket/TK-702-a)" "$(pr 11 'TK-702: b' ticket/TK-702-b)" "$(pr 12 'TK-702: c' ticket/TK-702-c)"
run
closed 10 && closed 11 && ! closed 12 && ok || bad "E3 #10 and #11 are closed for the keeper #12: $(W)"
grep -q '^COMMENT 10 .*reopen' "$H/writes.log" && ok || bad "E3 the close comment still says to reopen: $(W)"
[ "$(crit)" = 1 ] && ok || bad "E3 exactly one critical alert for the repo: $(cat "$H/alerts.log" 2>/dev/null)"
[ "$(grep -c . "$H/alerts.log")" = 1 ] && ok || bad "E3 still one alert per repo, not one more: $(cat "$H/alerts.log" 2>/dev/null)"
grep -q 'Closed as duplicate: .*reopen' "$H/alerts.log" && ok || bad "E3 the alert says a reopen stops the sweep: $(cat "$H/alerts.log" 2>/dev/null)"
grep -- '--severity critical' "$H/alerts.log" 2>/dev/null | grep -q '#10(superseded:newer-#12),#11(superseded:newer-#12)' \
  && ok || bad "E3 the critical alert names both closed PRs: $(cat "$H/alerts.log" 2>/dev/null)"
CRIT=$(grep -- '--severity critical' "$H/alerts.log" 2>/dev/null)
grep -q 'newer-#12' <<<"$CRIT" && ! grep -q '#12(' <<<"$CRIT" \
  && ok || bad "E3 the alert never lists the keeper as closed: $CRIT"
setup
opens "$(pr 10 'TK-702: a' ticket/TK-702-a)" "$(pr 11 'TK-702: b' ticket/TK-702-b)"
run PR_OWNER_DRY_RUN=1
[ "$(crit)" = 0 ] && ! closed 10 && ok || bad "E3b a dry run sends no critical alert: $(cat "$H/alerts.log" 2>/dev/null) / $(W)"

# ---------- E4 rule 1: a slice whose key merged in another PR --------------------
setup
echo '{"jobs":[]}' > "$H/fixture/jobs.json"
opens "$(pr 8 'TK-702 slice 2: y' ticket/TK-702-2 some-dev)"
jq -nc --arg y "$YDAY" '[{number:5,title:"TK-702: x",headRefName:"ticket/TK-702",url:"https://github.com/example-org/project-6/pull/5",mergedAt:$y,author:{login:"operator"}}]' > "$H/fixture/merged.json"
run
! closed 8 && ! commented 8 && ok || bad "E4 rule 1 keeps a slice: $(W)"
grep -q "$SLUG#8: duplicate close refused — slice" <<<"$(LOGT)" && ok || bad "E4 the log says why: $(LOGT | tail -3)"

# ---------- E5 the sweep's close-duplicate arm: an APPROVED ORPHAN ---------------
setup
echo '{"jobs":[]}' > "$H/fixture/jobs.json"
opens "$(pr 8 'TK-702: y' ticket/TK-702-b operator '' '[{"author":{"login":"rev"},"state":"APPROVED"}]')"
jq -nc --arg y "$YDAY" '[{number:5,title:"TK-702: x",headRefName:"ticket/TK-702",url:"https://github.com/example-org/project-6/pull/5",mergedAt:$y,author:{login:"operator"}}]' > "$H/fixture/merged.json"
run
! closed 8 && ! commented 8 && ok || bad "E5 the arm keeps an approved PR: $(W)"
grep -q 'held=#8:approved' <<<"$(summary)" && ok || bad "E5 the summary says approved: $(summary)"
# E5b the same ORPHAN with no review is still closed by the arm, with the critical alert.
setup
echo '{"jobs":[]}' > "$H/fixture/jobs.json"
opens "$(pr 8 'TK-702: y' ticket/TK-702-b)"
jq -nc --arg y "$YDAY" '[{number:5,title:"TK-702: x",headRefName:"ticket/TK-702",url:"https://github.com/example-org/project-6/pull/5",mergedAt:$y,author:{login:"operator"}}]' > "$H/fixture/merged.json"
run
closed 8 && ok || bad "E5b the arm still closes a plain leftover: $(W)"
grep -- '--severity critical' "$H/alerts.log" 2>/dev/null | grep -q '#8(dup of #5)' && ok || bad "E5b the critical alert names #8: $(cat "$H/alerts.log" 2>/dev/null)"

echo "pr-owner-dup-guard.bh-6929: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
