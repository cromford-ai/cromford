#!/bin/bash
# tests/pr-owner-sweep-stacked.bh-6814-test.sh — BH-6814: the superseded hook of
# bin/pr-owner-sweep.sh must not close a PR another open PR is stacked on, and
# must not close a PR whose issues-board ticket is held, a lead's PR included.
# On 2026-10-14 it closed #6778 as a duplicate of #6787, whose base was #6778's
# head branch, while ticket #6742 carried a HOLD newer than its last RESUME.
#
#   S1-S4  rule 3 and a stacked PR (base = the older PR's head branch).
#   H1-H4  the ticket HOLD binds a lead PR too; RESUME lifts it; unreadable holds.
#
# Driven through the REAL bin/pr-owner-sweep.sh. gh and curl are PATH shims: no
# network. Every GitHub write is recorded in $H/writes.log as `COMMENT <n> …` or
# `CLOSE <n>`, which every "closed / not closed" assertion reads.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/pr-owner-sweep-stacked.bh-6814-test.sh
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
printf 'cromford example-org/cromford - -\n' > "$H/fleet.conf"
printf '#!/bin/bash\nexit 0\n' > "$H/bin/lane-alert.sh"
chmod +x "$H/bin/lane-alert.sh"

# gh shim. The CLI list reads come from fixture/{open,merged}.json. The REST
# reads and writes (`gh api -i -X …`) answer with a status line. hold_check's
# plain `gh api repos/…/issues/<n>` and `gh api --paginate …/comments` read
# fixture/issue-<n>.json and fixture/thread-<n>.json; a thread-<n>.code that is
# not 200 makes the comments read fail.
cat > "$T/fakebin/gh" <<'SH'
#!/bin/bash
F="$HARNESS/fixture"
resp() { printf 'HTTP/2.0 %s X\r\ncontent-type: application/json\r\n\r\n%s\n' "$1" "$2"; }
case "$1 $2" in
  "api rate_limit") printf '{"resources":{"core":{"remaining":4000,"limit":5000,"reset":%s},"graphql":{"remaining":4000,"limit":5000,"reset":%s}}}\n' "$(date +%s)" "$(date +%s)"; exit 0 ;;
  "api --paginate")
    case "$3" in repos/*/issues/*/comments*)
      n="${3%/comments*}"; n="${n##*/}"
      [ -f "$F/thread-$n.json" ] || exit 1
      [ "$(cat "$F/thread-$n.code" 2>/dev/null || echo 200)" = 200 ] || { echo "HTTP 500: boom" >&2; exit 1; }
      cat "$F/thread-$n.json"; exit 0 ;;
    esac
    exit 1 ;;
  "api repos/"*/issues/*)
    n="${2##*/}"; [ -f "$F/issue-$n.json" ] || exit 1
    cat "$F/issue-$n.json"; exit 0 ;;
  "api repos/"*) echo 1234; exit 0 ;;
esac
case "$*" in
  # Only the fields the sweep asks for: a list read without baseRefName stacks nothing.
  *"pr list"*"--state open"*"baseRefName"*) cat "$F/open.json"; exit 0 ;;
  *"pr list"*"--state open"*)   jq -c 'map(del(.baseRefName))' "$F/open.json"; exit 0 ;;
  *"pr list"*"--state merged"*) cat "$F/merged.json"; exit 0 ;;
esac
if [ "$1 $2 $3" = "api -i -X" ]; then
  M="$4"; P="$5"; shift 5
  case "$M $P" in
    "GET repos/"*/issues/*/comments*)
      n="${P%/comments*}"; n="${n##*/}"
      resp 200 "$(cat "$F/prthread-$n.json" 2>/dev/null || echo '[]')" ;;
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
    "GET repos/"*/pulls/*)
      n="${P##*/}"; st=open; [ -f "$F/closed-$n" ] && st=closed
      resp 200 "$(jq -c --argjson n "$n" --arg st "$st" '.[] | select(.number == $n)
        | {state:$st, merged_at:null, user:{login:.author.login}, head:{ref:.headRefName}, base:{ref:.baseRefName}, body:(.body // "")}' "$F/open.json")" ;;
    *) resp 404 '{}' ;;
  esac
  exit 0
fi
exit 1
SH

# curl shim: the jobs API only.
cat > "$T/fakebin/curl" <<'SH'
#!/bin/bash
URL="${!#}"; M=GET; B=""; F="$HARNESS/fixture"
while [ $# -gt 0 ]; do case "$1" in -X) M="$2"; shift 2 ;; --data-binary) B="$2"; shift 2 ;; *) shift ;; esac; done
[ "$M" = PUT ] && printf '%s\n' "$B" >> "$HARNESS/puts.log"
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

D=86400
NOWISO() { date -u -d "@$(( $(date +%s) - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }
OLD=$(NOWISO $((3*D)))
SLUG=example-org/cromford
# pr <num> <title> <head> <base> [author] — one open-PR object
pr() {
  jq -nc --argjson n "$1" --arg t "$2" --arg h "$3" --arg b "$4" --arg a "${5:-operator}" --arg old "$OLD" --arg slug "$SLUG" \
    '{number:$n,title:$t,headRefName:$h,baseRefName:$b,headRefOid:("\($n)"+("0"*39))[0:40],author:{login:$a},
      labels:[],body:"",mergeable:"MERGEABLE",updatedAt:$old,createdAt:$old,
      url:"https://github.com/\($slug)/pull/\($n)",isDraft:false}'
}
setup() {
  scratch_rm "$H/fixture" || exit 1; scratch_rm "$H/logs" || exit 1; scratch_rm "$H/locks" || exit 1
  scratch_rm "$H/state" || exit 1
  mkdir -p "$H/fixture" "$H/logs" "$H/locks" "$H/state/merge-conductor" "$H/state/pr-owners"
  rm -f "$H/writes.log" "$H/puts.log"
  echo '[]' > "$H/fixture/open.json"; echo '[]' > "$H/fixture/merged.json"
  echo '{"jobs":[{"id":"build-BH-900","ticket_id":"BH-900","kind":"build","status":"running","meta":"{}"}]}' > "$H/fixture/jobs.json"
  : > "$H/state/merge-conductor/pr-state.tsv"
  printf '{"number":900,"title":"the ticket","state":"open","labels":[{"name":"ai-build"}],"body":""}' > "$H/fixture/issue-900.json"
  echo '[]' > "$H/fixture/thread-900.json"
}
opens() { printf '%s\n' "$@" | jq -s . > "$H/fixture/open.json"; }
# thread <issue> <code> <comment>… — each comment is "<iso> <body>"
thread() {
  local n="$1" c="$2"; shift 2
  printf '%s' "$c" > "$H/fixture/thread-$n.code"
  printf '%s\n' "$@" | jq -R 'split(" ") | {user:{login:"operator",type:"User"},created_at:.[0],body:(.[1:] | join(" "))}' \
    | jq -s . > "$H/fixture/thread-$n.json"
}
run() { env HARNESS="$H" FLEET_CONF="$H/fleet.conf" GH_TOKEN=x GH_BUDGET_TTL_S=0 GH_ETAG=0 JOBS_RETRIES=0 "$@" \
          bash "$H/bin/pr-owner-sweep.sh" --repo "$SLUG" >/dev/null 2>"$T/run.err"; RC=$?; }
W()    { cat "$H/writes.log" 2>/dev/null; }
LOGT() { cat "$H/logs/pr-owner-sweep.log" 2>/dev/null; }
closed()    { grep -qx "CLOSE $1" "$H/writes.log" 2>/dev/null; }
commented() { grep -q "^COMMENT $1 " "$H/writes.log" 2>/dev/null; }
summary() { grep -o "$SLUG: open=.*" "$H/logs/pr-owner-sweep.log" 2>/dev/null | tail -1; }

# ---------- S1 the newer keeper is stacked on the older PR ----------------------
setup
opens "$(pr 100 'BH-900: one' ticket/bh-900 main)" "$(pr 110 'BH-900: tools' ticket/bh-900-tools ticket/bh-900)"
run
[ "$RC" = 0 ] && ok || bad "S1 the sweep exits 0 (rc=$RC): $(head -3 "$T/run.err")"
! closed 100 && ! commented 100 && ok || bad "S1 #100 is not commented on or closed while #110 is stacked on it: $(W)"
grep -q 'held=#100:stacked' <<<"$(summary)" && ok || bad "S1 the summary says held=#100:stacked: $(summary)"
grep -q "$SLUG#100: older duplicate of #110, but #110 is stacked on its branch" <<<"$(LOGT)" && ok \
  || bad "S1 the log says why: $(LOGT | tail -3)"

# ---------- S2 a third PR is the keeper; #110 is still stacked on #100 ------------
setup
opens "$(pr 100 'BH-900: one' ticket/bh-900 main)" "$(pr 110 'BH-900: tools' ticket/bh-900-tools ticket/bh-900)" \
      "$(pr 120 'BH-900: third' ticket/bh-900-c main)"
run
! closed 100 && ok || bad "S2 #100 is not closed while #110 is stacked on it: $(W)"
closed 110 && ok || bad "S2 #110 (nothing stacked on it) is closed for the keeper #120 as today: $(W)"
grep -q 'held=#100:stacked' <<<"$(summary)" && ok || bad "S2 the summary says held=#100:stacked: $(summary)"

# ---------- S3 two PRs stacked on the older one ------------------------------------
setup
opens "$(pr 100 'BH-900: one' ticket/bh-900 main)" "$(pr 101 'BH-900: a' ticket/bh-900-a ticket/bh-900)" \
      "$(pr 102 'BH-900: b' ticket/bh-900-b ticket/bh-900)"
run
! closed 100 && ok || bad "S3 #100 is not closed while two PRs are stacked on it: $(W)"
grep -q "$SLUG#100: older duplicate of #102, but #101, #102 is stacked on its branch" <<<"$(LOGT)" && ok \
  || bad "S3 the log names both stacked PRs: $(LOGT | grep '#100' | tail -3)"

# ---------- S4 a plain duplicate (both base main) still closes --------------------
setup
opens "$(pr 100 'BH-900: one' ticket/bh-900 main)" "$(pr 110 'BH-900: two' ticket/bh-900-b main)"
run
closed 100 && ! closed 110 && ok || bad "S4 the older plain duplicate #100 is closed, #110 kept: $(W)"
grep -q '^COMMENT 100 .*#110' "$H/writes.log" && ok || bad "S4 the comment names #110: $(W)"

# ---------- H1 a lead PR whose ticket has a HOLD newer than its RESUME ------------
setup
opens "$(pr 100 'BH-900: one' ticket/bh-900 main)" "$(pr 110 'BH-900: two' ticket/bh-900-b main)"
thread 900 200 "2026-10-14T22:06:40Z RESUME" "2026-10-14T22:17:15Z HOLD a5-study"
run TO_LEAD_AUTHORS=operator
! closed 100 && ! commented 100 && ok || bad "H1 a lead PR with a held ticket is not closed: $(W)"
grep -q 'held=#100:hold' <<<"$(summary)" && ok || bad "H1 the summary says held=#100:hold: $(summary)"
grep -q "$SLUG#100: superseded but held — ticket #900 is held" <<<"$(LOGT)" && ok || bad "H1 the log names ticket #900: $(LOGT | tail -3)"

# ---------- H2 a RESUME newer than the HOLD lifts it ------------------------------
setup
opens "$(pr 100 'BH-900: one' ticket/bh-900 main)" "$(pr 110 'BH-900: two' ticket/bh-900-b main)"
thread 900 200 "2026-10-14T22:06:40Z HOLD a5-study" "2026-10-14T22:17:15Z RESUME"
run TO_LEAD_AUTHORS=operator
closed 100 && ok || bad "H2 a lifted HOLD lets the duplicate close: $(W)"

# ---------- H3 HOLD only, the author is not a lead (today's path) -----------------
setup
opens "$(pr 100 'BH-900: one' ticket/bh-900 main)" "$(pr 110 'BH-900: two' ticket/bh-900-b main)"
thread 900 200 "2026-10-14T22:17:15Z HOLD a5-study"
run TO_LEAD_AUTHORS=nobody-here
! closed 100 && grep -q 'held=#100:hold' <<<"$(summary)" && ok || bad "H3 a non-lead PR with a held ticket is not closed: $(W) / $(summary)"

# ---------- H4 a lead PR whose ticket thread cannot be read -----------------------
setup
opens "$(pr 100 'BH-900: one' ticket/bh-900 main)" "$(pr 110 'BH-900: two' ticket/bh-900-b main)"
thread 900 500 "2026-10-14T22:06:40Z RESUME"
run TO_LEAD_AUTHORS=operator
! closed 100 && grep -q 'held=#100:hold' <<<"$(summary)" && ok || bad "H4 an unreadable ticket thread holds: $(W) / $(summary)"

echo "pr-owner-sweep-stacked.bh-6814: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
