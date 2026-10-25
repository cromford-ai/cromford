#!/bin/bash
# tests/pr-superseded.bh-3929-test.sh — BH-3936 (BH-3929 ask 4): the superseded
# close for every class, driven through the REAL bin/pr-owner-sweep.sh.
#
#   P1-P10  the three rules, EXTERNAL's @author, PARKED, dry run, the cap, the
#           comment dedupe, and the conductor row through the real mc_transition.
#   N1-N9   adversarial negatives: none of them may close anything.
#   R1-R2 G1 H1 S1  the review guards: rebuilds and live builds, product-board
#           done, a HOLD, a resolver-owned duplicate.
#   U1 K1 K2  conductor rows unread close nothing by rules 2/3; a PARKED PR is
#           never the keeper; a harness PR is kept over an EXTERNAL one.
#   L4      ph_ticket_status on an issues board and a product board.
#
# gh and curl are PATH shims: no network, no secrets. Every GitHub write the
# REST lib makes is recorded in $H/writes.log as `COMMENT <n> <body>` or
# `CLOSE <n>`, which is what every "closed / not closed" assertion reads.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pr-superseded.bh-3929-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq      >/dev/null || { echo "jq missing — skipping"; exit 0; }
command -v python3 >/dev/null || { echo "python3 missing — skipping"; exit 0; }

H="$T/h"
mkdir -p "$H/logs" "$H/locks" "$H/state/merge-conductor" "$H/state/pr-owners" "$H/flags" "$H/env" "$H/fixture" "$T/fakebin"
cp -R "$DIR/bin" "$H/"
printf 'HARNESS_SECRET=s3cret\nJOBS_URL=https://jobs.test\n' > "$H/env/global.env"
cat > "$H/fleet.conf" <<'CONF'
project-4 example-org/project-4 https://os.test /api/board
cromford example-org/cromford - -
CONF
printf '#!/bin/bash\necho tok-for-%s\n' '$1' > "$H/bin/internal-token-for.sh"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/internal-token-for.sh" "$H/bin/lane-alert.sh"

# gh shim. The CLI list reads come from fixture/{open,merged}.json; the REST
# reads and writes (`gh api -i -X …`) answer with a status line, as GitHub does.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
F="$HARNESS/fixture"
resp() { printf 'HTTP/2.0 %s X\r\ncontent-type: application/json\r\n\r\n%s\n' "$1" "$2"; }
case "$1 $2" in
  "api rate_limit") printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":%s},"graphql":{"remaining":4000,"limit":5000,"reset":%s}}}\n' "$(date +%s)" "$(date +%s)"; exit 0 ;;
  "api repos/"*)
    # bg_read's thread reads (--paginate) are unreadable, so health counts no
    # CI-only block; the token's visibility probe sees the repo.
    case "$*" in *--paginate*) exit 1 ;; esac
    # TEST-CHANGE (BH-6814): hold_check's plain issue read answers the issue,
    # as GitHub does, since the superseded hook now reads an issues-board
    # ticket's hold for every PR. A 404 is gh's non-zero exit.
    case "$#:$2" in 2:repos/*/issues/*)
      n="${2##*/}"; [ "$(cat "$F/issue-$n.code" 2>/dev/null || echo 404)" = 200 ] || exit 1
      cat "$F/issue-$n.json"; exit 0 ;;
    esac
    echo 1234; exit 0 ;;
  # hold_check's comments read: the ticket's thread is empty.
  "api --paginate") case "$3" in repos/*/issues/*/comments*) echo '[]'; exit 0 ;; esac; exit 1 ;;
esac
case "$*" in
  # TEST-CHANGE: BH-6929 — po_dup_guard runs before every duplicate close: the open list carries latestReviews as gh writes it when asked, and the guard's reads (issue events, PR comments, compare) answer clean.
  *"pr list"*"--state open"*)   jq 'map(.latestReviews //= [])' "$F/open.json"; exit 0 ;;
  *"pr list"*"--state merged"*) cat "$F/merged.json"; exit 0 ;;
esac
if [ "$1 $2 $3" = "api -i -X" ]; then
  M="$4"; P="$5"; shift 5
  case "$M $P" in
    "GET repos/"*/issues/*/events*) resp 200 '[]' ;;
    "GET repos/"*/compare/*) resp 200 '{"status":"diverged"}' ;;
    "GET repos/"*/issues/*/comments*)
      # to_merge_hold's thread reads: fixture/thread-<n>.json, else no comments.
      n="${P%/comments*}"; n="${n##*/}"
      resp 200 "$(cat "$F/thread-$n.json" 2>/dev/null || echo '[]')" ;;
    "GET repos/"*/issues/*)
      n="${P##*/}"; c=$(cat "$F/issue-$n.code" 2>/dev/null || echo 404)
      resp "$c" "$(cat "$F/issue-$n.json" 2>/dev/null || echo '{"message":"Not Found"}')" ;;
    "POST repos/"*/comments)
      n="${P%/comments}"; n="${n##*/}"; b=""
      for a in "$@"; do case "$a" in body=@*) b=$(cat "${a#body=@}") ;; esac; done
      [ "${COMMENT_FAIL:-}" = "$n" ] && { resp 500 '{"message":"boom"}'; exit 1; }
      printf 'COMMENT %s %s\n' "$n" "$(printf '%s' "$b" | tr '\n' ' ')" >> "$HARNESS/writes.log"
      resp 201 '{"id":1}' ;;
    "PATCH repos/"*/pulls/*)
      n="${P##*/}"
      [ "${CLOSE_FAIL:-}" = "$n" ] && { resp 500 '{"message":"boom"}'; exit 1; }
      printf 'CLOSE %s\n' "$n" >> "$HARNESS/writes.log"; touch "$F/closed-$n"
      resp 200 '{"state":"closed"}' ;;
    # TEST-CHANGE (BH-6815): a rule 1/2 close now also reads the PR's file list
    # and main's sha (po_done_close_guard). An empty list = nothing left to ship.
    "GET repos/"*/pulls/*/files*)
      n="${P%/files*}"; n="${n##*/}"
      resp 200 "$(cat "$F/files-$n.json" 2>/dev/null || echo '[]')" ;;
    "GET repos/"*/commits/HEAD)
      resp 200 '{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}' ;;
    "GET repos/"*/pulls/*)
      n="${P##*/}"
      if [ -f "$F/closed-$n" ]; then resp 200 '{"state":"closed","merged_at":null}'
      else resp 200 '{"state":"open","merged_at":null}'; fi ;;
    *) resp 404 '{}' ;;
  esac
  exit 0
fi
exit 1
SH

# curl shim: the jobs API (ledger reads/writes logged) and the product board.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; M=GET; B=""; F="$HARNESS/fixture"
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; --data-binary) B="$2"; shift 2 ;; *) shift ;; esac; done
[ "$M" = PUT ] && printf '%s\n' "$B" >> "$HARNESS/puts.log"
case "$M $URL" in
  "GET https://jobs.test/api/jobs"*)  printf '%s\n200\n' "$(cat "$F/jobs.json")" ;;
  "GET https://jobs.test/api/queue"*) printf '{"queue":[]}\n200\n' ;;
  "GET https://jobs.test/api/ledger?kind=pr_superseded"*)
    if [ -n "${LEDGER_CODE:-}" ]; then printf '{"error":"boom"}\n%s\n' "$LEDGER_CODE"
    elif [ -f "$F/ledger-superseded.json" ]; then printf '%s\n200\n' "$(cat "$F/ledger-superseded.json")"
    else printf '{"error":"none"}\n404\n'; fi ;;
  "GET https://jobs.test/api/verdicts"*) printf '{"standing":null,"rows":[]}\n200\n' ;;
  "GET https://jobs.test/"*) printf '{"error":"none"}\n404\n' ;;
  "GET https://os.test/api/board/boards")
    echo "BOARDS" >> "$HARNESS/board-reads.log"
    printf '%s\n%s\n' "$(cat "$F/boards.json" 2>/dev/null || echo '[{"id":"b1"}]')" "${BOARDS_CODE:-200}" ;;
  "GET https://os.test/api/board/boards/"*/tickets)
    echo "TICKETS" >> "$HARNESS/board-reads.log"
    printf '%s\n200\n' "$(cat "$F/tickets.json" 2>/dev/null || echo '[]')" ;;
  *) printf '{"ok":true}\n200\n' ;;
esac
SH
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"
export PATH="$T/fakebin:$PATH"
# TEST-CHANGE: BH-6929 — po_dup_guard's git ancestor check reads no box checkout: none here, so it compares over REST.
export PR_OWNER_REPO_ROOT="$T/no-checkouts"
# This box is the conductor's (BH-5124): po_mc_read reads the fixture's
# pr-state.tsv only there. U1 turns the read off to prove the unread path.
export BOX_NAME=box-hub HUB_BOX_NAME=box-hub

D=86400
NOWISO() { date -u -d "@$(( $(date +%s) - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
OLD=$(NOWISO $((3*D)))
# pr <num> <title> <branch> <author> [body] [label] — one open-PR object
pr() {
  jq -nc --argjson n "$1" --arg t "$2" --arg b "$3" --arg a "$4" --arg body "${5:-}" --arg l "${6:-}" --arg old "$OLD" --arg slug "$SLUG" \
    '{number:$n,title:$t,headRefName:$b,headRefOid:("\($n)"+("0"*39))[0:40],author:{login:$a},
      labels:(if $l == "" then [] else [{name:$l}] end),body:$body,mergeable:"MERGEABLE",
      updatedAt:$old,createdAt:$old,url:"https://github.com/\($slug)/pull/\($n)",isDraft:false}'
}
# merged <num> <title> [branch] [author] [mergedAt] — the author defaults to a
# harness login, because only a harness-authored PR teaches the sweep a ticket
# prefix. mergedAt defaults to a day ago, AFTER every open PR here was opened
# ($OLD): rule 1 only counts a merge that came after the PR (BH-3936 review).
MERGED_AT=$(NOWISO $D)
merged() { jq -nc --argjson n "$1" --arg t "$2" --arg b "${3:-x/merged-$1}" --arg a "${4:-operator}" --arg m "${5:-$MERGED_AT}" '{number:$n,title:$t,headRefName:$b,url:"x",mergedAt:$m,author:{login:$a}}'; }
# setup <slug> — empty fixtures, logs, state
setup() {
  SLUG="$1"
  scratch_rm "$H/fixture" || exit 1; scratch_rm "$H/logs" || exit 1; scratch_rm "$H/locks" || exit 1
  scratch_rm "$H/state" || exit 1
  mkdir -p "$H/fixture" "$H/logs" "$H/locks" "$H/state/merge-conductor" "$H/state/pr-owners"
  rm -f "$H/writes.log" "$H/puts.log" "$H/board-reads.log"
  echo '[]' > "$H/fixture/open.json"; echo '[]' > "$H/fixture/merged.json"; echo '{"jobs":[]}' > "$H/fixture/jobs.json"
  : > "$H/state/merge-conductor/pr-state.tsv"
}
opens()  { printf '%s\n' "$@" | jq -s . > "$H/fixture/open.json"; }
mergeds() { printf '%s\n' "$@" | jq -s . > "$H/fixture/merged.json"; }
owned()  { local k; for k in "$@"; do jq --arg k "$k" '.jobs += [{id:("build-"+$k),ticket_id:$k,kind:"build",status:"running",meta:"{}"}]' "$H/fixture/jobs.json" > "$T/j" && mv "$T/j" "$H/fixture/jobs.json"; done; }
mcrow()  { printf '%s#%s\t%s\t1757000000\t%s\t-\t-\tfixture\thttps://x\n' "$SLUG" "$1" "$2" "$(printf '%s%039d' "$1" 0 | cut -c1-40)" >> "$H/state/merge-conductor/pr-state.tsv"; }
tickets() { printf '%s\n' "$@" | jq -R . | jq -s '[.[] | {key: (split(" ")[0]), status: (split(" ")[1])}]' > "$H/fixture/tickets.json"; }
issue()  { printf '%s' "$2" > "$H/fixture/issue-$1.code"; printf '%s' "$3" > "$H/fixture/issue-$1.json"; }
run() { env HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_TOKEN=x GH_BUDGET_TTL_S=0 GH_ETAG=0 JOBS_RETRIES=0 "$@" \
          bash "$H/bin/pr-owner-sweep.sh" --repo "$SLUG" >/dev/null 2>"$T/run.err"; RC=$?; }
W()   { cat "$H/writes.log" 2>/dev/null; }
LOGT() { cat "$H/logs/pr-owner-sweep.log" 2>/dev/null; }
closed() { grep -qx "CLOSE $1" "$H/writes.log" 2>/dev/null; }
nowrite() { [ ! -s "$H/writes.log" ]; }
summary() { grep -o "$SLUG: open=.*" "$H/logs/pr-owner-sweep.log" 2>/dev/null | tail -1; }
STATE_MARK="$T/mark"

project-4=example-org/project-4
BH=example-org/cromford

# ---------- P1 rule 1, an OWNED PR (conductor WAIT_CI) ------------------------
p1_fixture() {
  setup "$project-4"
  opens "$(pr 120 'TK-101: second try' ticket/TK-101-b operator)"
  mergeds "$(merged 115 'TK-101: first try' ticket/TK-101)"
  mcrow 120 WAIT_CI
}
p1_fixture; touch "$STATE_MARK"; sleep 1
run
[ "$RC" = 0 ] && ok || bad "P1 the sweep exits 0 (rc=$RC): $(head -3 "$T/run.err")"
[ "$(grep -c '^COMMENT 120 ' "$H/writes.log" 2>/dev/null)" = 1 ] && grep -q '^COMMENT 120 .*#115' "$H/writes.log" && ok \
  || bad "P1 one comment on #120 naming #115: $(W)"
closed 120 && ok || bad "P1 #120 closed: $(W)"
grep -q "$project-4#120: OWNED closed (superseded:merged-#115)" <<<"$(LOGT)" && ok || bad "P1 the log line: $(LOGT | tail -3)"
grep -q "closed=#120(superseded:merged-#115)" <<<"$(summary)" && ok || bad "P1 the summary names the close: $(summary)"
[ "$(awk -F'\t' -v k="$project-4#120" '$1==k {print $2" "$7}' "$H/state/merge-conductor/pr-state.tsv")" = "CLOSED superseded:merged-#115" ] && ok \
  || bad "P1 the conductor row goes CLOSED superseded:merged-#115: $(cat "$H/state/merge-conductor/pr-state.tsv")"
jq -e 'select(.kind=="pr_superseded" and .key=="example-org/project-4#120" and .status=="closed")' "$H/puts.log" >/dev/null 2>&1 && ok \
  || bad "P1 the pr_superseded ledger row ends closed: $(jq -c 'select(.kind=="pr_superseded")' "$H/puts.log" 2>/dev/null)"
# TEST-CHANGE (BH-3933): the sweep is a hub lane now and ticks its heartbeat
# (bin/lib/heartbeat.sh, state/heartbeat/<lane>.<pid>.json), the lane's own
# file like every other lane's. It is not hook state.
NEWF=$(find "$H/state" "$H/flags" -type f -newer "$STATE_MARK" 2>/dev/null | sed "s#^$H/##" \
  | grep -vE '^state/pr-owners/[^/]+\.json$|^state/pr-owner-sweep/[^/]+/(openlist|mergedlist)\.(json|meta)$|^state/merge-conductor/pr-state\.tsv(\.lock)?$|^state/(gh-budget|gh-rest-ledger|gh-etag|lane-gate)/|^state/heartbeat/pr-owner-sweep\.[0-9]+\.json$' | sort)
[ -z "$NEWF" ] && ok || bad "P1 no new state/ or flags/ file beyond the sweep's and the conductor's: $NEWF"

# ---------- P8 dry run over the P1 fixture ------------------------------------
p1_fixture; cp "$H/state/merge-conductor/pr-state.tsv" "$T/mc-before"
run PR_OWNER_DRY_RUN=1
nowrite && ok || bad "P8 dry run writes nothing to GitHub: $(W)"
grep -q 'DRY-RUN would: superseded close #120 (merged-#115)' <<<"$(LOGT)" && ok || bad "P8 the decision is logged: $(LOGT | tail -3)"
cmp -s "$T/mc-before" "$H/state/merge-conductor/pr-state.tsv" && ok || bad "P8 the conductor row is untouched"
! jq -e 'select(.kind=="pr_superseded")' "$H/puts.log" >/dev/null 2>&1 && ok || bad "P8 no pr_superseded row in a dry run"

# ---------- P10 the comment was already posted --------------------------------
p1_fixture
printf '{"ledger":{"status":"commented","detail":"{\\"by\\":\\"merged-#115\\"}"}}' > "$H/fixture/ledger-superseded.json"
run
! grep -q '^COMMENT 120' "$H/writes.log" 2>/dev/null && closed 120 && ok || bad "P10 a ledgered comment is not posted again, only the close: $(W)"

# ---------- comment failure and close failure ---------------------------------
p1_fixture; run COMMENT_FAIL=120
nowrite && ok || bad "P1c a failed comment means no close: $(W)"
grep -q 'held=#120:comment-failed' <<<"$(summary)" && ok || bad "P1c held as comment-failed: $(summary)"
p1_fixture; run CLOSE_FAIL=120
grep -q '^COMMENT 120' "$H/writes.log" && ! closed 120 && grep -q 'held=#120:close-failed' <<<"$(summary)" && ok \
  || bad "P1d a failed close is held, never claimed: $(W) / $(summary)"
grep -q 'closed=-' <<<"$(summary)" && ok || bad "P1d no CLOSED claim on a failed close: $(summary)"

# ---------- P2 EXTERNAL, keyed by the body's first line -----------------------
setup "$project-4"
opens "$(pr 140 'Improve the thing' feature/x collaborator-1 $'TK-102: carry the fix\n\nmore words')"
mergeds "$(merged 116 'TK-102: the fix' ticket/TK-102)"
run
closed 140 && ok || bad "P2 the EXTERNAL PR is closed: $(W)"
grep -q '^COMMENT 140 @collaborator-1 Closing this one: TK-102 already shipped in #116' "$H/writes.log" && ok \
  || bad "P2 the comment starts @author and names #116: $(W)"
! grep -q '—' "$H/writes.log" && ok || bad "P2 no em dash in the comment"

# ---------- P3 rule 2 on an issues board, conductor WAIT_CI -------------------
setup "$BH"
opens "$(pr 300 'BH-50: the thing' ticket/bh-50 operator)"
# TEST-CHANGE (BH-6815): a READY row is merge-armed, and the done-ticket close
# guard keeps an armed PR open (pinned in tests/pr-owner-done-guard.bh-6815-test.sh
# D2). The rule 2 close this case pins runs on a WAIT_CI row.
mcrow 300 WAIT_CI
issue 50 200 '{"number":50,"state":"closed","state_reason":"completed"}'
run
closed 300 && ok || bad "P3 closed on a done ticket: $(W)"
grep -q '^COMMENT 300 .*BH-50.*done' "$H/writes.log" && ok || bad "P3 the comment names BH-50 and done: $(W)"
[ "$(awk -F'\t' -v k="$BH#300" '$1==k {print $2" "$7}' "$H/state/merge-conductor/pr-state.tsv")" = "CLOSED superseded:ticket-done" ] && ok \
  || bad "P3 the conductor row: $(cat "$H/state/merge-conductor/pr-state.tsv")"

# ---------- P4 / N6 the ticket read fails: no action, not even rule 3 ---------
setup "$BH"
opens "$(pr 300 'BH-50: the thing' ticket/bh-50 operator)" "$(pr 310 'BH-50: again' ticket/bh-50-b operator)"
owned BH-50
issue 50 500 '{"message":"boom"}'
run
nowrite && ok || bad "P4/N6 a 500 on the issue read closes nothing, not even the older duplicate: $(W)"
grep -q "superseded-unknown" <<<"$(LOGT)" && ok || bad "P4 superseded-unknown is logged: $(LOGT | tail -3)"

# ---------- P5 rule 3: older duplicate, no conductor rows ---------------------
setup "$project-4"
opens "$(pr 100 'TK-103: one' ticket/TK-103 operator)" "$(pr 110 'TK-103: two' ticket/TK-103-b operator)"
owned TK-103; tickets 'TK-103 in_progress'
run
closed 100 && ! closed 110 && ok || bad "P5 #100 closed for the newer #110, #110 untouched: $(W)"
grep -q '^COMMENT 100 .*#110' "$H/writes.log" && ok || bad "P5 the comment names #110: $(W)"
[ "$(grep -c TICKETS "$H/board-reads.log" 2>/dev/null)" = 1 ] && ok || bad "P5 one board list per project per run: $(cat "$H/board-reads.log" 2>/dev/null)"

# ---------- P6 D4: the older READY one stays ----------------------------------
setup "$project-4"
opens "$(pr 100 'TK-103: one' ticket/TK-103 operator)" "$(pr 110 'TK-103: two' ticket/TK-103-b operator)"
mcrow 100 READY; mcrow 110 WAIT_CI; tickets 'TK-103 review'
run
closed 110 && ! closed 100 && ok || bad "P6 #110 closed, the READY #100 stays: $(W)"
grep -q '^COMMENT 110 .*#100' "$H/writes.log" && grep -q 'superseded:ready-#100' <<<"$(summary)" && ok || bad "P6 names #100: $(W) $(summary)"

# ---------- P7 / N5 PARKED: rule 1 only ---------------------------------------
setup "$project-4"
opens "$(pr 150 'TK-104: parked' ticket/TK-104 operator 'Parked: waiting on the client until 2099-01-01')" \
      "$(pr 130 'TK-105: parked old' ticket/TK-105 operator 'Parked: hold until 2099-01-01')" \
      "$(pr 131 'TK-105: newer' ticket/TK-105-b operator)"
tickets 'TK-104 done' 'TK-105 todo'   # no ledger job: a live one would make #130 OWNED, not PARKED
run
! closed 150 && ok || bad "P7 a PARKED PR with a done ticket is not closed: $(W)"
! closed 130 && ok || bad "N5 a PARKED older duplicate is not closed: $(W)"
setup "$project-4"
opens "$(pr 150 'TK-104: parked' ticket/TK-104 operator 'Parked: waiting on the client until 2099-01-01')"
mergeds "$(merged 151 'TK-104: shipped' ticket/TK-104-z)"
run
closed 150 && ok || bad "P7 rule 1 does close a PARKED PR whose key merged: $(W)"

# ---------- P9 the cap ---------------------------------------------------------
setup "$project-4"
opens "$(pr 120 'TK-101: x' ticket/TK-101-b operator)" "$(pr 121 'TK-106: y' ticket/TK-106-b operator)"
mcrow 120 WAIT_CI; mcrow 121 WAIT_CI   # a live ledger job would keep rule 1 off (R2)
mergeds "$(merged 115 'TK-101: a' ticket/TK-101)" "$(merged 117 'TK-106: b' ticket/TK-106)"
run PR_OWNER_MAX_ACTIONS=1
[ "$(grep -c '^CLOSE ' "$H/writes.log" 2>/dev/null)" = 1 ] && closed 120 && ok || bad "P9 one close under a cap of 1: $(W)"
grep -q 'held=#121:cap' <<<"$(summary)" && ok || bad "P9 the second is held #121:cap: $(summary)"

# ---------- A1 an ORPHAN keyed by branch stays with close-duplicate -----------
setup "$project-4"
opens "$(pr 160 'TK-107: leftover' ticket/TK-107-b operator)"
mergeds "$(merged 118 'TK-107: shipped' ticket/TK-107)"
run
# TEST-CHANGE (BH-3933 merged with BH-3936): close-duplicate's comment and close
# go over REST now too, so they land in writes.log. The case still pins that
# the superseded hook leaves this PR to close-duplicate: exactly one comment,
# and it is close-duplicate's (its sweep footer), never the hook's text.
[ "$(grep -c '^COMMENT 160 ' "$H/writes.log" 2>/dev/null)" = 1 ] \
  && grep '^COMMENT 160 ' "$H/writes.log" | grep -qF '_bin/pr-owner-sweep.sh — every open PR is owned' \
  && ! grep -qF "If something here didn't make it in" "$H/writes.log" \
  && ok || bad "A1 the REST path leaves a branch-keyed ORPHAN to close-duplicate: $(W)"
grep -q "$project-4#160: ORPHAN closed — TK-107 already merged in #118" <<<"$(LOGT)" && ok || bad "A1 close-duplicate still closes it: $(LOGT | tail -2)"

# ---------- N1-N9 nothing closes ------------------------------------------------
setup "$project-4"
opens "$(pr 201 'Small cleanup' fix/cleanup collaborator-1 'Follow-up to TK-101 work')" \
      "$(pr 202 'Fix UTF-8 handling' fix/encoding collaborator-1)" \
      "$(pr 203 'TK-110: review status' ticket/TK-110 operator)" \
      "$(pr 204 'TK-111: self' ticket/TK-111 operator)" \
      "$(pr 205 'TK-112: keeper' ticket/TK-112-b operator)" "$(pr 199 'TK-112: older' ticket/TK-112 operator 'Parked: x until 2099-01-01')"
owned TK-110 TK-111   # not TK-112: a live job would make #199 OWNED, not PARKED
mergeds "$(merged 115 'TK-101: first' ticket/TK-101)" "$(merged 90 'UTF-8 support' x/utf)" "$(merged 204 'TK-111: same number' ticket/TK-111)"
tickets 'TK-110 review' 'TK-111 in_progress' 'TK-112 todo'
run
for n in 201 202 203 204 205 199; do closed "$n" && bad "N1-N9 #$n must not be closed: $(W)" || ok; done
setup "$BH"
opens "$(pr 320 'BH-51: x' ticket/bh-51 operator)" "$(pr 321 'BH-52: y' ticket/bh-52 operator)"
owned BH-51 BH-52
issue 51 200 '{"number":51,"state":"closed","state_reason":null}'
issue 52 200 '{"number":52,"state":"open","pull_request":{"url":"x"}}'
run
nowrite && ok || bad "N3/N8 a null state_reason and an issue that is a PR close nothing: $(W)"

# ---------- B1 version-shaped keys never reach the superseded hook -------------
# dependabot bumps: `vitest-4.1.2` merged reads VITEST-4, and so do the two open
# bumps; none of them is a ticket, so nothing is "already shipped" or a dup.
setup "$project-4"
opens "$(pr 400 'Bump vitest from 4.1.2 to 4.1.3' dependabot/npm_and_yarn/vitest-4.1.3 'app/dependabot')" \
      "$(pr 401 'Bump vitest from 4.1.2 to 4.1.4' dependabot/npm_and_yarn/vitest-4.1.4 'dependabot[bot]')" \
      "$(pr 402 'Bump wrangler' dependabot/npm_and_yarn/worker/jobs/wrangler-3.80.1 'app/dependabot')"
mergeds "$(merged 395 'Bump vitest from 4.1.1 to 4.1.2' dependabot/npm_and_yarn/vitest-4.1.2 'app/dependabot')" \
        "$(merged 396 'TK-120: ours' ticket/TK-120)"
run
nowrite && ok || bad "B1 a dependabot bump is never closed as shipped or as a duplicate: $(W)"
# A human's `fix/utf-8-encoding` on an issues board: UTF-8 must not read issue #8,
# even though #8 is closed as completed and the human is not a bot.
setup "$BH"
opens "$(pr 410 'Fix encoding' fix/utf-8-encoding collaborator-1)" \
      "$(pr 411 'Bump wrangler' dependabot/npm_and_yarn/worker/jobs/wrangler-3.80.0 collaborator-1)"
mergeds "$(merged 405 'BH-70: ours' ticket/bh-70)"
issue 8 200 '{"number":8,"state":"closed","state_reason":"completed"}'
issue 3 200 '{"number":3,"state":"closed","state_reason":"completed"}'
run
nowrite && ok || bad "B1 UTF-8 / WRANGLER-3 never read an unrelated issue and close: $(W)"
# The gate is the prefix, not the author: an external PR keyed with our prefix still closes (P2).
setup "$BH"
opens "$(pr 412 'BH-71: contributor fix' contrib/bh-71 collaborator-1)"
mergeds "$(merged 406 'BH-71: shipped' ticket/bh-71)"
issue 71 200 '{"number":71,"state":"closed","state_reason":"completed","labels":[]}'
run
closed 412 && ok || bad "B1 an external PR on a known prefix still closes: $(W)"

# ---------- B2 a PR we closed and a human reopened is left alone ----------------
p1_fixture
printf '{"ledger":{"status":"closed","detail":"{\\"by\\":\\"merged-#115\\"}"}}' > "$H/fixture/ledger-superseded.json"
run
nowrite && ok || bad "B2 a reopened PR is not commented on or closed again: $(W)"
grep -q "$project-4#120: superseded (merged-#115) but we closed it before and it was reopened" <<<"$(LOGT)" && ok \
  || bad "B2 the hands-off decision is logged: $(LOGT | tail -3)"
run
nowrite && ok || bad "B2 still hands off on the next tick: $(W)"
# A ledger it cannot read holds the PR rather than risk re-closing a reopened one.
p1_fixture; LEDGER_CODE=500; export LEDGER_CODE
run
unset LEDGER_CODE
nowrite && grep -q 'held=#120:ledger-unreadable' <<<"$(summary)" && ok || bad "B2 an unreadable ledger closes nothing: $(W) / $(summary)"

# ---------- R1/R2 rule 1 leaves rebuilds and live builds alone (BH-3936 review) --
# R1: an OWNED PR opened AFTER its key merged is a reopened ticket's rebuild.
setup "$project-4"
opens "$(pr 120 'TK-101: rebuild' ticket/TK-101-b operator)"
mergeds "$(merged 115 'TK-101: first try' ticket/TK-101 operator "$(NOWISO $((5*D)))")"
mcrow 120 WAIT_CI; tickets 'TK-101 in_progress'
run
nowrite && ok || bad "R1 an OWNED PR created after its key merged is not closed: $(W)"
# R1b: an unreadable createdAt proves nothing came first.
setup "$project-4"
opens "$(pr 120 'TK-101: x' ticket/TK-101-b operator | jq -c '.createdAt = "garbage"')"
mergeds "$(merged 115 'TK-101: first try' ticket/TK-101)"
mcrow 120 WAIT_CI; tickets 'TK-101 in_progress'
run
nowrite && ok || bad "R1b an unreadable createdAt closes nothing: $(W)"
# R2: a PR opened before the merge, but a build job for the key is live.
setup "$project-4"
opens "$(pr 120 'TK-101: second try' ticket/TK-101-b operator)"
mergeds "$(merged 115 'TK-101: first try' ticket/TK-101)"
owned TK-101; tickets 'TK-101 in_progress'
run
nowrite && ok || bad "R2 a live build job for the key keeps rule 1 off: $(W)"

# ---------- G1 rule 2 on a product board: done is set before the merge ----------
setup "$project-4"
opens "$(pr 170 'TK-130: to-spec copy' ticket/TK-130 operator)" "$(pr 171 'TK-131: copy' ticket/TK-131 operator)"
mcrow 170 READY; owned TK-131; tickets 'TK-130 done' 'TK-131 done'
run
nowrite && ok || bad "G1 product-board done does not close an OWNED or conductor-rowed PR: $(W)"
grep -q "$project-4#170: TK-130 is done on a product board" <<<"$(LOGT)" && ok || bad "G1 the skip is logged: $(LOGT | tail -3)"
# ...but an EXTERNAL PR with no conductor row still closes on it.
setup "$project-4"
opens "$(pr 172 'Tidy copy' feature/copy collaborator-1 $'TK-132: copy\n')"
mergeds "$(merged 160 'TK-132: earlier' ticket/TK-132-z operator "$(NOWISO $((5*D)))")"
tickets 'TK-132 done'
run
closed 172 && ok || bad "G1 an unowned PR on a done product ticket still closes: $(W)"

# ---------- H1 a HOLD on the PR thread keeps it ---------------------------------
p1_fixture
printf '[{"user":{"login":"operator","type":"User"},"created_at":"2026-10-01T00:00:00Z","body":"HOLD: waiting on me"}]' > "$H/fixture/thread-120.json"
run
nowrite && ok || bad "H1 a held PR is not closed: $(W)"
grep -q 'held=#120:hold' <<<"$(summary)" && ok || bad "H1 held as #120:hold: $(summary)"
p1_fixture
printf '[{"user":{"login":"operator","type":"User"},"created_at":"2026-10-01T00:00:00Z","body":"HOLD"},{"user":{"login":"operator","type":"User"},"created_at":"2026-10-02T00:00:00Z","body":"RESUME"}]' > "$H/fixture/thread-120.json"
run
closed 120 && ok || bad "H1 a lifted HOLD closes again: $(W)"

# ---------- S1 rule 3 never closes a PR the blocked resolver owns ---------------
setup "$project-4"
opens "$(pr 100 'TK-103: one' ticket/TK-103 operator)" "$(pr 110 'TK-103: rebuild' ticket/TK-103-b operator)"
mcrow 100 BLOCKED_HUMAN; mcrow 110 WAIT_CI; tickets 'TK-103 review'
run
nowrite && ok || bad "S1 a resolver-owned older duplicate is left to the rebuild rung: $(W)"

# ---------- U1 conductor rows unread: rules 2 and 3 close nothing ---------------
# The G1 product-board fixture plus an unowned PR and a duplicate pair with an
# older READY member, with the file read turned off: every guard that reads the
# conductor's rows would fail open, so nothing may close.
setup "$project-4"
opens "$(pr 170 'TK-130: to-spec copy' ticket/TK-130 operator)" "$(pr 173 'TK-133: copy' ticket/TK-133 operator)" \
      "$(pr 100 'TK-103: one' ticket/TK-103 operator)" "$(pr 110 'TK-103: two' ticket/TK-103-b operator)"
mcrow 170 READY; mcrow 100 READY; mcrow 110 WAIT_CI
tickets 'TK-130 done' 'TK-133 done' 'TK-103 review'
run PR_OWNER_MC_MAX_AGE_S=0
nowrite && ok || bad "U1 conductor rows unread: a done product ticket and a duplicate close nothing: $(W)"
grep -q 'conductor-unread=' <<<"$(summary)" && grep -q 'conductor=unread' <<<"$(summary)" && ok || bad "U1 the run read the rows as unread: $(summary)"
grep -q "$project-4#173: conductor rows unread — rules 2 and 3 not tried" <<<"$(LOGT)" && ok || bad "U1 the decline is logged: $(LOGT | tail -3)"

# ---------- K1 a PARKED PR is never the keeper ----------------------------------
setup "$project-4"
opens "$(pr 100 'TK-140: one' ticket/TK-140 operator)" "$(pr 110 'TK-140: parked' ticket/TK-140-b operator 'Parked: hold until 2099-01-01')"
mcrow 100 WAIT_CI; tickets 'TK-140 review'
run
nowrite && ok || bad "K1 an older OWNED PR is not closed for a newer PARKED one: $(W)"

# ---------- K2 a harness PR is kept over an EXTERNAL one ------------------------
setup "$project-4"
opens "$(pr 100 'TK-141: ours' ticket/TK-141 operator)" "$(pr 110 'TK-141: contributor' contrib/TK-141 collaborator-1)"
mcrow 100 WAIT_CI; tickets 'TK-141 review'
run
! closed 100 && ok || bad "K2 the older harness PR is not closed for a newer EXTERNAL one: $(W)"
closed 110 && grep -q '^COMMENT 110 @collaborator-1 .*#100' "$H/writes.log" && ok || bad "K2 the EXTERNAL duplicate is the one closed, naming #100: $(W)"

# ---------- L4 ph_ticket_status ------------------------------------------------
l4() { # l4 <project> <KEY> -> "<rc>:<stdout>"
  local o rc
  o=$(env HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_ETAG=0 TD= bash -c '. "$HARNESS/bin/lib/pr-owner/superseded.sh" || exit 9; ph_ticket_status "$@"' _ "$1" "$2" 2>/dev/null); rc=$?
  printf '%s:%s' "$rc" "$o"
}
setup "$BH"
issue 60 200 '{"state":"closed","state_reason":"completed"}'; [ "$(l4 cromford BH-60)" = "0:done" ] && ok || bad "L4 completed is done: $(l4 cromford BH-60)"
issue 61 200 '{"state":"closed","state_reason":"not_planned"}'; [ "$(l4 cromford BH-61)" = "0:rejected" ] && ok || bad "L4 not_planned is rejected"
issue 62 200 '{"state":"closed","state_reason":null}'; [ "$(l4 cromford BH-62)" = "0:unknown" ] && ok || bad "L4 closed/null is unknown"
issue 63 200 '{"state":"open"}'; [ "$(l4 cromford BH-63)" = "0:open" ] && ok || bad "L4 open is open"
[ "$(l4 cromford BH-64)" = "0:unknown" ] && ok || bad "L4 a 404 is unknown: $(l4 cromford BH-64)"
issue 65 500 '{}'; [ "$(l4 cromford BH-65)" = "1:" ] && ok || bad "L4 a 500 is rc 1, nothing printed: $(l4 cromford BH-65)"
tickets 'TK-1 closed' 'TK-2 done' 'TK-3 review'
[ "$(l4 project-4 TK-1)" = "0:rejected" ] && ok || bad "L4 product closed is rejected: $(l4 project-4 TK-1)"
[ "$(l4 project-4 TK-2)" = "0:done" ] && ok || bad "L4 product done is done"
[ "$(l4 project-4 TK-3)" = "0:open" ] && ok || bad "L4 product review is open"
[ "$(l4 project-4 TK-9)" = "0:unknown" ] && ok || bad "L4 a product key not on the board is unknown"
BOARDS_CODE=500; export BOARDS_CODE
[ "$(l4 project-4 TK-2)" = "1:" ] && ok || bad "L4 /boards 500 is rc 1: $(l4 project-4 TK-2)"
unset BOARDS_CODE

echo "pr-superseded.bh-3929: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
