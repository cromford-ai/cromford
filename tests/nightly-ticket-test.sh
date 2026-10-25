#!/bin/bash
# tests/nightly-ticket-test.sh — a red nightly run files a ticket
# (bin/nightly-ticket.sh, 2026-09-28).
#
# The nightly and guard tiers left the merge-queue batch on the promise that a
# red night is seen. This drives that promise against a stub gh. Since BH-6838
# a failing suite gets its OWN issue (tests/nightly-ticket-split.bh-6838-test.sh
# pins that in depth); the run-level ticket below is for the reds that are not
# a suite (a trace hit, a shard with no verdict, a failed plan, strict):
#   N1  no open ticket: the failing suite gets its own issue, and the run-level
#       ticket is OPENED naming the suite, the trace hit and the shard that
#       left no verdict — and not the suite that passed
#   N2  open tickets carrying the markers: each gets a COMMENT, no new issue
#       (a pull request carrying the marker text is not that ticket)
#   N2b the open tickets are found past the first page of open items
#   N3  a failed plan with no logs still files, and says the plan failed
#   N7  a red strict ratchet pass is quoted; a dead strict job is named
#   N4  GitHub refusing the read or the write is rc 1, never a quiet 0
#   N5  usage: no verdict dir or no NT_REPO is rc 2
# Run from anywhere: tests/nightly-ticket-test.sh   (exit 0 = all pass)
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
NT="$DIR/bin/nightly-ticket.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
command -v jq >/dev/null 2>&1 || { echo "nightly-ticket-test: jq missing — skipping"; exit 0; }

# The stub gh: `api <path> --jq <f>` answers $FAKE_OPEN through jq; a POST
# records its path and copies the body file it was handed.
cat > "$T/gh" <<'GH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_SINK"
[ -n "${FAKE_FAIL_ALL:-}" ] && exit 1
JQ=""; POST=0; BODY=""; P=""; PAGINATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    api) ;;
    --jq) JQ="$2"; shift ;;
    -X) [ "$2" = POST ] && POST=1; shift ;;
    -F) case "$2" in body=@*) BODY="${2#body=@}" ;; esac; shift ;;
    -f) shift ;;
    --paginate) PAGINATE=1 ;;
    *) P="$1" ;;
  esac
  shift
done
if [ "$POST" = 1 ]; then
  [ -n "${FAKE_FAIL_POST:-}" ] && exit 1
  printf '== POST %s\n' "$P" >> "$FAKE_SINK"
  [ -n "$BODY" ] && cat "$BODY" >> "$FAKE_SINK"
  printf '{"number":101}\n' | jq -r "${JQ:-.}"
  exit 0
fi
# Pages: FAKE_OPEN is page 1; FAKE_OPEN2, when set, is page 2 and only a
# --paginate call sees it (gh applies --jq to each page).
jq -r "$JQ" "$FAKE_OPEN"
if [ -n "${FAKE_OPEN2:-}" ] && [ "$PAGINATE" = 1 ]; then jq -r "$JQ" "$FAKE_OPEN2"; fi
GH
chmod +x "$T/gh"

mkdir -p "$T/v"
printf 'tests=3\nfailed=1\nhits=1\npure=fail\ntrace=dirty\n' > "$T/v/shard-0.txt"
cat > "$T/v/shard-0.log" <<'EOF'
--- tests/a-slow-test.sh rc=1 12s
FAIL: something real
--- tests/b-slow-test.sh rc=0 3s
HIT c-slow-test.sh unlink OUTSIDE-A-TEMP-ROOT (fixture line, nothing ran)
--- tests/c-slow-test.sh rc=0 2s
EOF
MARK='<!-- harness-nightly-red -->'
SMARK='<!-- harness-nightly-red:tests/a-slow-test.sh -->'
printf '[]\n' > "$T/none.json"
# BH-6838: the failing suite's own open issue (#78) sits next to the run-level one.
jq -n --arg m "$MARK" --arg sm "$SMARK" '[{number:5,body:("pr " + $m),pull_request:{url:"x"}},{number:77,body:("old " + $m)},{number:78,body:("suite " + $sm)},{number:9,body:"other"}]' > "$T/open.json"

run() { # run <open.json> [VAR=value ...]
  local open="$1"; shift
  : > "$T/sink"
  OUT=$(env NT_GH="$T/gh" FAKE_SINK="$T/sink" FAKE_OPEN="$open" NT_REPO=o/r NT_SHA=abc123 \
          NT_RUN_URL=https://example.invalid/run/1 NT_PLAN_RESULT=success NT_PLAN_N=2 NT_APP_TOKEN=app-tok-fixture "$@" \
          bash "$NT" "$T/v" 2>&1); RC=$?
  SINK=$(cat "$T/sink")
}

# N1. first red night: one new issue.
run "$T/none.json"
[ "$RC" = 0 ] && ok || bad "N1: filing must exit 0 (rc=$RC): $OUT"
grep -qx '== POST repos/o/r/issues' <<<"$SINK" && ok || bad "N1: no issue was opened: $SINK"
has "/comments" "$SINK" && bad "N1: there was no ticket to comment on: $SINK" || ok
has "title=Nightly test tier is red on main" "$SINK" && ok || bad "N1: the issue must carry the fixed title: $SINK"
has "$MARK" "$SINK" && ok || bad "N1: the body must carry the marker the next night finds: $SINK"
has 'tests/a-slow-test.sh` (rc 1)' "$SINK" && ok || bad "N1: the failing suite must be named: $SINK"
has 'tests/b-slow-test.sh' "$SINK" && bad "N1: a suite that passed must not be named: $SINK" || ok
has 'c-slow-test.sh' "$SINK" && ok || bad "N1: the trace hit must be named: $SINK"
has 'Shard(s) 1 left no verdict' "$SINK" && ok || bad "N1: the shard with no verdict must be named: $SINK"
has 'https://example.invalid/run/1' "$SINK" && ok || bad "N1: the run must be linked: $SINK"
has "opened #101" "$OUT" && ok || bad "N1: it must say what it opened: $OUT"
# BH-6838: the failing suite has its own issue, with its own marker and title.
has "title=Nightly: tests/a-slow-test.sh red on main" "$SINK" && ok || bad "N1: the failing suite must get its own issue: $SINK"
has "$SMARK" "$SINK" && ok || bad "N1: the suite's issue must carry its own marker: $SINK"

# N2. an open ticket: a comment on it, never a second issue.
run "$T/open.json"
[ "$RC" = 0 ] && ok || bad "N2: commenting must exit 0 (rc=$RC): $OUT"
has "== POST repos/o/r/issues/77/comments" "$SINK" && ok || bad "N2: the open ticket #77 must get the comment: $SINK"
grep -qx '== POST repos/o/r/issues' <<<"$SINK" && bad "N2: a second issue was opened: $SINK" || ok
has "issues/5/comments" "$SINK" && bad "N2: a pull request is not the ticket: $SINK" || ok
has "updated #77" "$OUT" && ok || bad "N2: it must say what it updated: $OUT"
has "== POST repos/o/r/issues/78/comments" "$SINK" && ok || bad "N2: the suite's open issue #78 must get the comment: $SINK"

# N2b. MORE THAN A PAGE of newer open items (issues and PRs) in front of the
# ticket: it is still found and commented on, never duplicated.
jq -n '[range(0;100) | {number:(1000+.), body:"unrelated", pull_request:(if . % 2 == 0 then {url:"x"} else null end)}]' > "$T/page1.json"
jq -n --arg m "$MARK" --arg sm "$SMARK" '[{number:12,body:("old " + $m)},{number:13,body:("suite " + $sm)}]' > "$T/page2.json"
run "$T/page1.json" FAKE_OPEN2="$T/page2.json"
[ "$RC" = 0 ] && ok || bad "N2b: rc=$RC: $OUT"
grep -qx '== POST repos/o/r/issues/12/comments' <<<"$SINK" && ok || bad "N2b: the ticket on page 2 must get the comment: $SINK"
grep -qx '== POST repos/o/r/issues/13/comments' <<<"$SINK" && ok || bad "N2b: the suite's issue on page 2 must get the comment: $SINK"
grep -qx '== POST repos/o/r/issues' <<<"$SINK" && bad "N2b: a second ticket was opened because the first was past page 1: $SINK" || ok

# N3. the plan failed and nothing ran: still a ticket, saying so.
mkdir -p "$T/empty"
: > "$T/sink"
OUT=$(env NT_GH="$T/gh" FAKE_SINK="$T/sink" FAKE_OPEN="$T/none.json" NT_REPO=o/r NT_PLAN_RESULT=failure NT_PLAN_N=0 NT_APP_TOKEN=app-tok-fixture \
        bash "$NT" "$T/empty" 2>&1); RC=$?; SINK=$(cat "$T/sink")
{ [ "$RC" = 0 ] && has "== POST repos/o/r/issues" "$SINK" && has "plan job did not succeed (failure)" "$SINK"; } && ok \
  || bad "N3: a failed plan must still file, and say the plan failed (rc=$RC): $SINK"

# N7. a red strict ratchet pass is quoted in the ticket; a strict job that
# died with no summary is still named.
mkdir -p "$T/vs"; cp "$T/v/shard-0.txt" "$T/v/shard-0.log" "$T/vs/"
printf '### `tests/gh-graphql-reads-lint.bh-1585-test.sh` (strict mode, rc 1)\n```\nFAIL: bin/x.sh: 2 GraphQL reads over its allowlisted 1\n```\n' > "$T/vs/strict.md"
: > "$T/sink"
OUT=$(env NT_GH="$T/gh" FAKE_SINK="$T/sink" FAKE_OPEN="$T/none.json" NT_REPO=o/r NT_PLAN_N=1 NT_STRICT_RESULT=failure NT_APP_TOKEN=app-tok-fixture \
        bash "$NT" "$T/vs" 2>&1); RC=$?; SINK=$(cat "$T/sink")
{ [ "$RC" = 0 ] && has "Strict ratchets" "$SINK" && has "2 GraphQL reads over its allowlisted 1" "$SINK"; } && ok \
  || bad "N7: the strict summary must be in the ticket (rc=$RC): $SINK"
: > "$T/sink"; rm -f "$T/vs/strict.md"
OUT=$(env NT_GH="$T/gh" FAKE_SINK="$T/sink" FAKE_OPEN="$T/none.json" NT_REPO=o/r NT_PLAN_N=1 NT_STRICT_RESULT=failure NT_APP_TOKEN=app-tok-fixture \
        bash "$NT" "$T/vs" 2>&1); SINK=$(cat "$T/sink")
has "strict ratchet pass did not succeed (failure)" "$SINK" && ok || bad "N7: a dead strict job must be named: $SINK"

# N4. GitHub refusing is loud.
run "$T/none.json" FAKE_FAIL_ALL=1
[ "$RC" = 1 ] && ok || bad "N4: an unreadable issue list must be rc 1 (rc=$RC): $OUT"
run "$T/none.json" FAKE_FAIL_POST=1
[ "$RC" = 1 ] && ok || bad "N4: a refused create must be rc 1 (rc=$RC): $OUT"
run "$T/open.json" FAKE_FAIL_POST=1
[ "$RC" = 1 ] && ok || bad "N4: a refused comment must be rc 1 (rc=$RC): $OUT"

# N5. usage.
OUT=$(env -u NT_REPO bash "$NT" "$T/v" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "N5: no NT_REPO must be rc 2 (rc=$RC): $OUT"
OUT=$(NT_REPO=o/r bash "$NT" 2>&1); RC=$?
[ "$RC" = 2 ] && ok || bad "N5: no verdict dir must be rc 2 (rc=$RC): $OUT"

echo "nightly-ticket-test: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
