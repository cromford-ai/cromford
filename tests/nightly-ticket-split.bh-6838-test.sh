#!/bin/bash
# tests/nightly-ticket-split.bh-6838-test.sh — a red nightly files ONE ISSUE
# PER FAILING SUITE, with the commit range, and the daily full dispatch is off
# unless its knob says 1 (BH-6838, Task 4).
#
# Drives the REAL bin/nightly-ticket.sh against a fake gh that logs every call
# and answers fixture files, and the REAL bin/ci-nightly-full.sh (installed
# with its closure into a scratch $HARNESS):
#   N1  one failed suite, no open issue: one create with the per-suite marker,
#       label ai-build, LAST_GREEN..SHA, the commit subjects and the log tail;
#       one `new` row; rc 0. N1b: no last green -> sha~20..sha, said.
#   N2  an open issue with that suite's marker: one comment, no create; a pull
#       request carrying the marker is not that issue; row `comment`
#   N3  12 failed suites, NT_MAX_NEW=10: 10 creates, 2 `over-cap` rows listed
#       on the run-level ticket; a non-integer cap is the default 10, said
#   N4  one suite's search fails: `skipped-unreadable`, no create for it, the
#       other suite is filed, rc 0
#   N5  ticket-requests.tsv: 4 tab-separated columns, one row per decision
#   N6  ci-nightly-full.sh dispatch with the knob unset or 0: `dispatch: skip
#       dispatch-off`, no gh call, no claim dir; knob 1 passes the gate
#   N7  rc=0 lines, a suite that passed on retry, a cancelled shard and a
#       trace notice that is not HIT file no per-suite issue
# Run: HARNESS_TEST_SANDBOX=1 bash tests/nightly-ticket-split.bh-6838-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
NT="$REPO_DIR/bin/nightly-ticket.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "PASS: $1"; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name"; fi; }
has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }
command -v jq >/dev/null 2>&1 || { echo "nightly-ticket-split: jq missing — skipping"; exit 0; }

# --- the fake gh ------------------------------------------------------------
# Every argv is one line in $FAKE_SINK. A GET applies its --jq to $FAKE_OPEN
# (and $FAKE_OPEN2 on --paginate, as page 2); it exits 1 when its --jq names
# $FAKE_FAIL_SEARCH_FOR. A POST writes `== POST <path>` to the sink and copies
# its body file to $FAKE_BODIES/<n>.md; a create answers the next number from
# 200 up, labelled ai-build.
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'GH'
#!/bin/bash
printf '%s\n' "$*" >> "$FAKE_SINK"
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
  n=$(cat "$FAKE_BODIES/.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$FAKE_BODIES/.n"
  printf '== POST %s\n' "$P" >> "$FAKE_SINK"
  [ -n "$BODY" ] && cp "$BODY" "$FAKE_BODIES/$n.md"
  printf '%s\n' "$P" > "$FAKE_BODIES/$n.path"
  case "$P" in
    */comments) printf '{"id":1}\n' | jq -r "${JQ:-.}" ;;
    */labels) printf '[{"name":"ai-build"}]\n' | jq -r "${JQ:-.}" ;;
    *) num=$(cat "$FAKE_BODIES/.num" 2>/dev/null || echo 199); num=$((num + 1)); echo "$num" > "$FAKE_BODIES/.num"
       jq -n --argjson n "$num" '{number:$n,labels:[{name:"ai-build"}]}' | jq -r "${JQ:-.}" ;;
  esac
  exit 0
fi
if [ -n "${FAKE_FAIL_SEARCH_FOR:-}" ]; then
  case "$JQ" in *"$FAKE_FAIL_SEARCH_FOR"*) exit 1 ;; esac
fi
jq -r "$JQ" "$FAKE_OPEN"
if [ -n "${FAKE_OPEN2:-}" ] && [ "$PAGINATE" = 1 ]; then jq -r "$JQ" "$FAKE_OPEN2"; fi
GH
chmod +x "$T/bin/gh"

# --- a scratch git history: A (last green), three commits, B (red) ---------
GITW="$T/git"; mkdir -p "$GITW"
G() { git -C "$GITW" -c user.name=fixture -c user.email=fixture@example.invalid "$@" >/dev/null 2>&1; }
G init -q -b main
printf 'a\n' > "$GITW/f"; G add -A; G commit -qm 'fixture base commit'
A=$(git -C "$GITW" rev-parse HEAD)
for s in one two three; do printf '%s\n' "$s" >> "$GITW/f"; G add -A; G commit -qm "fixture commit $s"; done
B=$(git -C "$GITW" rev-parse HEAD)
[ -n "$A" ] && [ -n "$B" ] && [ "$A" != "$B" ] || { echo "FAIL: fixture git history"; exit 1; }

printf '[]\n' > "$T/none.json"
RUN_URL=https://example.invalid/o/r/actions/runs/1

run() { # run <verdict-dir> <open.json> [VAR=value ...]
  local v="$1" open="$2"; shift 2
  scratch_rm "$T/bodies"; mkdir -p "$T/bodies"; : > "$T/sink"
  OUT=$(env NT_GH="$T/bin/gh" FAKE_SINK="$T/sink" FAKE_BODIES="$T/bodies" FAKE_OPEN="$open" \
          NT_REPO=o/r NT_SHA="$B" NT_LAST_GREEN="$A" NT_GIT_DIR="$GITW" NT_RUN_URL="$RUN_URL" \
          NT_PLAN_RESULT=success NT_PLAN_N=1 NT_APP_TOKEN=app-tok-fixture "$@" bash "$NT" "$v" 2>"$T/err"); RC=$?
  ERR=$(cat "$T/err"); SINK=$(cat "$T/sink")
  TSV=""; [ -f "$v/ticket-requests.tsv" ] && TSV=$(cat "$v/ticket-requests.tsv")
}
creates() { grep -c '^== POST repos/o/r/issues$' "$T/sink"; }
suite_creates() { grep -c '^api -X POST repos/o/r/issues -f title=Nightly: tests/' "$T/sink"; }
runlevel_creates() { grep -c '^api -X POST repos/o/r/issues -f title=Nightly test tier is red on main' "$T/sink"; }
body_of() { # body_of <path> — the body of the first POST to <path>
  local f
  for f in "$T/bodies"/*.path; do
    [ -e "$f" ] || continue
    [ "$(cat "$f")" = "$1" ] && { cat "${f%.path}.md"; return 0; }
  done
  return 1
}
rows() { awk -F'\t' -v a="$1" '$3 == a' "$2/ticket-requests.tsv" 2>/dev/null | wc -l; }

verdict() { # verdict <dir> <log-text> — one finished shard 0
  mkdir -p "$1"; rm -f "$1"/*
  printf 'tests=1\nfailed=1\nhits=0\npure=fail\ntrace=clean\n' > "$1/shard-0.txt"
  printf '%s\n' "$2" > "$1/shard-0.log"
}

# ── N1 one failed suite, no open issue ───────────────────────────────────────
verdict "$T/v1" "--- tests/red-one-test.sh rc=1 4s
FAIL: fixture assertion broke at line 12
--- tests/green-one-test.sh rc=0 1s"
run "$T/v1" "$T/none.json"
check "N1 rc 0" [ "$RC" = 0 ]
check "N1 exactly one create" [ "$(creates)" = 1 ]
check "N1 the create is the per-suite title" [ "$(suite_creates)" = 1 ]
grep -qF 'title=Nightly: tests/red-one-test.sh red on main' < <(grep '^api -X POST repos/o/r/issues ' "$T/sink") \
  && ok "N1 title names the suite" || bad "N1 title names the suite: $SINK"
grep -qF 'labels[]=ai-build' < <(grep '^api -X POST repos/o/r/issues ' "$T/sink") \
  && ok "N1 labelled ai-build" || bad "N1 labelled ai-build: $SINK"
check "N1 no run-level ticket for a suite-only red" [ "$(runlevel_creates)" = 0 ]
BODY=$(body_of repos/o/r/issues)
has '<!-- harness-nightly-red:tests/red-one-test.sh -->' "$BODY" && ok "N1 per-suite marker" || bad "N1 per-suite marker: $BODY"
has "$A..$B" "$BODY" && ok "N1 range LAST_GREEN..SHA" || bad "N1 range LAST_GREEN..SHA: $BODY"
has "https://github.com/o/r/compare/$A...$B" "$BODY" && ok "N1 compare link" || bad "N1 compare link: $BODY"
has "$RUN_URL" "$BODY" && ok "N1 run url" || bad "N1 run url: $BODY"
has 'fixture commit two' "$BODY" && ok "N1 commit subjects" || bad "N1 commit subjects: $BODY"
has 'fixture base commit' "$BODY" && bad "N1 the last green commit is not in the range: $BODY" || ok "N1 range excludes last green"
has 'FAIL: fixture assertion broke at line 12' "$BODY" && ok "N1 log tail" || bad "N1 log tail: $BODY"
has 'green-one-test.sh' "$BODY" && bad "N1 the passing suite's line is not in the tail: $BODY" || ok "N1 tail stops at the next suite"
check "N1 one new row" [ "$(rows new "$T/v1")" = 1 ]
grep -qxF "$(printf 'tests/red-one-test.sh\t%s..%s\tnew\thttps://github.com/o/r/issues/200' "$A" "$B")" <<<"$TSV" \
  && ok "N1 new row names suite, range and url" || bad "N1 new row: $TSV"
has 'filed 1 new, 0 comments, 0 over cap' "$ERR$OUT" && ok "N1 summary line" || bad "N1 summary line: $OUT / $ERR"

# N1b no recorded green: the fallback range is said
run "$T/v1" "$T/none.json" NT_LAST_GREEN=
BODY=$(body_of repos/o/r/issues)
check "N1b rc 0" [ "$RC" = 0 ]
has "$B~20..$B" "$BODY" && ok "N1b fallback range" || bad "N1b fallback range: $BODY"
has 'No green nightly is recorded' "$BODY" && ok "N1b says why" || bad "N1b says why: $BODY"
has 'could not be read' "$BODY" && ok "N1b unreadable commit list is said" || bad "N1b unreadable commit list is said: $BODY"
grep -qF "$(printf 'tests/red-one-test.sh\t%s~20..%s\tnew\t' "$B" "$B")" <<<"$TSV" \
  && ok "N1b row carries the fallback range" || bad "N1b row: $TSV"

# ── N2 an open issue with that suite's marker ────────────────────────────────
jq -n '[{number:301,body:"pr <!-- harness-nightly-red:tests/red-one-test.sh -->",pull_request:{url:"x"}},
        {number:300,body:"old <!-- harness-nightly-red:tests/red-one-test.sh -->"},
        {number:302,body:"other <!-- harness-nightly-red:tests/red-other-test.sh -->"}]' > "$T/open.json"
run "$T/v1" "$T/open.json"
check "N2 rc 0" [ "$RC" = 0 ]
check "N2 no create" [ "$(creates)" = 0 ]
check "N2 one comment on #300" [ "$(grep -c '^== POST repos/o/r/issues/300/comments$' "$T/sink")" = 1 ]
has 'issues/301/comments' "$SINK" && bad "N2 a pull request is not the issue: $SINK" || ok "N2 pull request skipped"
has 'issues/302/comments' "$SINK" && bad "N2 another suite's issue is not this one: $SINK" || ok "N2 other suite's issue skipped"
has 'labels' "$(grep '^api -X POST' "$T/sink")" && bad "N2 a comment never touches labels: $SINK" || ok "N2 no label call"
BODY=$(body_of repos/o/r/issues/300/comments)
{ has "$B" "$BODY" && has "$RUN_URL" "$BODY" && has "$A..$B" "$BODY"; } && ok "N2 comment has sha, run url, range" || bad "N2 comment: $BODY"
grep -qxF "$(printf 'tests/red-one-test.sh\t%s..%s\tcomment\thttps://github.com/o/r/issues/300' "$A" "$B")" <<<"$TSV" \
  && ok "N2 comment row" || bad "N2 comment row: $TSV"
has 'filed 0 new, 1 comments, 0 over cap' "$ERR$OUT" && ok "N2 summary line" || bad "N2 summary line: $ERR"

# N2b the marker issue is on page 2 of the open items
jq -n '[range(0;100) | {number:(1000+.), body:"unrelated"}]' > "$T/page1.json"
jq -n '[{number:12,body:"x <!-- harness-nightly-red:tests/red-one-test.sh -->"}]' > "$T/page2.json"
run "$T/v1" "$T/page1.json" FAKE_OPEN2="$T/page2.json"
{ [ "$(creates)" = 0 ] && grep -qx '== POST repos/o/r/issues/12/comments' "$T/sink"; } \
  && ok "N2b found past page 1" || bad "N2b found past page 1: $SINK"

# ── N3 12 failed suites, cap 10 ──────────────────────────────────────────────
L3=""; for i in 01 02 03 04 05 06 07 08 09 10 11 12; do L3="$L3--- tests/red-$i-test.sh rc=1 1s
"; done
verdict "$T/v3" "$L3"
run "$T/v3" "$T/none.json" NT_MAX_NEW=10
check "N3 rc 0" [ "$RC" = 0 ]
check "N3 ten per-suite creates" [ "$(suite_creates)" = 10 ]
check "N3 one run-level create" [ "$(runlevel_creates)" = 1 ]
check "N3 ten new rows" [ "$(rows new "$T/v3")" = 10 ]
check "N3 two over-cap rows" [ "$(rows over-cap "$T/v3")" = 2 ]
check "N3 one run-level row" [ "$(rows run-level "$T/v3")" = 1 ]
grep -qF 'title=Nightly: tests/red-11-test.sh' "$T/sink" && bad "N3 red-11 is over the cap" || ok "N3 red-11 not created"
RBODY=$(for f in "$T/bodies"/*.md; do grep -qF '<!-- harness-nightly-red -->' "$f" && cat "$f"; done)
{ has 'tests/red-11-test.sh' "$RBODY" && has 'tests/red-12-test.sh' "$RBODY" && has 'over the cap' "$RBODY"; } \
  && ok "N3 run-level ticket lists the over-cap suites" || bad "N3 run-level body: $RBODY"
RL=$(awk -F'\t' '$3 == "run-level" {print $4}' "$T/v3/ticket-requests.tsv")
OC=$(awk -F'\t' '$3 == "over-cap" {print $4}' "$T/v3/ticket-requests.tsv" | sort -u)
{ [ -n "$RL" ] && [ "$RL" != - ] && [ "$OC" = "$RL" ]; } && ok "N3 over-cap rows point at the run-level ticket" || bad "N3 over-cap urls '$OC' vs run-level '$RL'"
has 'filed 10 new, 0 comments, 2 over cap' "$ERR$OUT" && ok "N3 summary line" || bad "N3 summary line: $ERR"
cp "$T/v3/ticket-requests.tsv" "$T/n5.tsv"
run "$T/v3" "$T/none.json" NT_MAX_NEW=ten
{ [ "$(suite_creates)" = 10 ] && has "NT_MAX_NEW='ten'" "$ERR"; } && ok "N3 non-integer cap is the default 10, said" || bad "N3 non-integer cap: $(suite_creates) creates; $ERR"
run "$T/v3" "$T/none.json" NT_MAX_NEW=3
{ [ "$(suite_creates)" = 3 ] && [ "$(rows over-cap "$T/v3")" = 9 ]; } && ok "N3 the cap is read" || bad "N3 cap 3: $(suite_creates) creates"

# ── N4 a failed search ───────────────────────────────────────────────────────
verdict "$T/v4" "--- tests/red-a-test.sh rc=1 1s
--- tests/red-b-test.sh rc=2 1s"
run "$T/v4" "$T/none.json" FAKE_FAIL_SEARCH_FOR=red-b-test.sh
check "N4 rc 0" [ "$RC" = 0 ]
grep -qF 'title=Nightly: tests/red-a-test.sh' "$T/sink" && ok "N4 the readable suite is filed" || bad "N4 red-a filed: $SINK"
grep -qF 'title=Nightly: tests/red-b-test.sh' "$T/sink" && bad "N4 nothing is filed for the unreadable search" || ok "N4 red-b not created"
grep -q 'issues/[0-9]*/comments' <<<"$SINK" && bad "N4 no comment blind: $SINK" || ok "N4 no comment"
grep -qxF "$(printf 'tests/red-b-test.sh\t%s..%s\tskipped-unreadable\t-' "$A" "$B")" <<<"$TSV" \
  && ok "N4 skipped-unreadable row" || bad "N4 row: $TSV"

# ── N5 the request file's shape ──────────────────────────────────────────────
awk -F'\t' 'NF != 4 { bad = 1 } END { exit bad }' "$T/n5.tsv" && ok "N5 four columns on every row" || bad "N5 columns: $(cat "$T/n5.tsv")"
check "N5 one row per decision (10 new + 2 over-cap + 1 run-level)" [ "$(wc -l < "$T/n5.tsv")" = 13 ]
awk -F'\t' '$3 !~ /^(new|comment|over-cap|skipped-unreadable|run-level)$/ { bad = 1 } END { exit bad }' "$T/n5.tsv" \
  && ok "N5 action vocabulary" || bad "N5 actions: $(cut -f3 "$T/n5.tsv" | sort | uniq -c)"

# ── N7 the negative list ─────────────────────────────────────────────────────
mkdir -p "$T/v7"; rm -f "$T/v7"/*
printf 'tests=3\nfailed=1\nhits=0\npure=fail\ntrace=clean\n' > "$T/v7/shard-0.txt"
cat > "$T/v7/shard-0.log" <<'EOF'
CHECK-NOTE test-trace-safety: /nonexistent already exists, creation probe cannot attribute
--- tests/green-test.sh rc=0 1s
--- tests/retry-test.sh rc=1 2s
FAIL: fixture flake
--- tests/retry-test.sh rc=0 2s
TRACE: 3 tests, 1 nonzero exit(s), 0 hit(s)
EOF
# shard 1 was cancelled: a partial log and no verdict file
printf -- '--- tests/cancelled-test.sh rc=143 9s\n' > "$T/v7/shard-1.log"
run "$T/v7" "$T/none.json" NT_PLAN_N=2
check "N7 rc 0" [ "$RC" = 0 ]
check "N7 no per-suite create" [ "$(suite_creates)" = 0 ]
check "N7 no new or comment row" [ "$(( $(rows new "$T/v7") + $(rows comment "$T/v7") ))" = 0 ]
has 'harness-nightly-red:tests/' "$SINK" && bad "N7 no per-suite search either: $SINK" || ok "N7 no per-suite search"
check "N7 the cancelled shard keeps the run-level ticket" [ "$(runlevel_creates)" = 1 ]
RBODY=$(cat "$T/bodies"/*.md 2>/dev/null)
has 'Shard(s) 1 left no verdict' "$RBODY" && ok "N7 run-level names shard 1" || bad "N7 run-level body: $RBODY"
# the same without the cancelled shard: nothing per-suite at all
rm -f "$T/v7/shard-1.log"
run "$T/v7" "$T/none.json" NT_PLAN_N=1
check "N7b no per-suite create" [ "$(suite_creates)" = 0 ]

# ── N6 the daily full dispatch is off unless the knob says 1 ─────────────────
HH="$T/h"; mkdir -p "$HH/logs" "$HH/flags" "$HH/env" "$HH/state" "$T/stub"
scratch_install_closure bin/ci-nightly-full.sh "$HH" >/dev/null || bad "N6 scratch_install_closure bin/ci-nightly-full.sh"
: > "$HH/env/global.env"
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$HARNESS/gh-calls.txt"
exit 1
SH
chmod +x "$T/stub/gh"
NOW6=1791343200   # 2026-10-07 03:20:00Z
drive6() { # drive6 [VAR=VAL ...]
  rm -f "$HH/gh-calls.txt" "$HH/logs/ci-nightly-full.log"; scratch_rm "$HH/state/ci-nightly-full"
  ( export HARNESS="$HH" NOW="$NOW6" GH_TOKEN=tok-fixture-6838 GH_BUDGET_DB=0 CNF_POLL_SLEEP=0 \
           HARNESS_TEST_SANDBOX=1 JOBS_URL= PATH="$T/stub:$PATH"
    unset CI_NIGHTLY_FULL_DISPATCH CI_NIGHTLY_FULL_HOUR
    while [ $# -gt 0 ]; do export "${1?}"; shift; done
    timeout 60 bash "$HH/bin/ci-nightly-full.sh" dispatch ) >"$T/out6.txt" 2>&1
  RC6=$?
}
for k in unset 0; do
  if [ "$k" = unset ]; then drive6; else drive6 CI_NIGHTLY_FULL_DISPATCH=0; fi
  check "N6 knob $k: rc 0" [ "$RC6" = 0 ]
  grep -q 'dispatch: skip dispatch-off' "$HH/logs/ci-nightly-full.log" 2>/dev/null \
    && ok "N6 knob $k: logs dispatch-off" || bad "N6 knob $k: log $(cat "$HH/logs/ci-nightly-full.log" 2>/dev/null)"
  check "N6 knob $k: no gh call" [ ! -s "$HH/gh-calls.txt" ]
  check "N6 knob $k: no claim dir" [ ! -d "$HH/state/ci-nightly-full/2026-10-07" ]
done
drive6 CI_NIGHTLY_FULL_DISPATCH=1 CI_NIGHTLY_FULL_HOUR=23
{ ! grep -q 'dispatch-off' "$HH/logs/ci-nightly-full.log" 2>/dev/null \
  && grep -q 'dispatch: skip before-hour' "$HH/logs/ci-nightly-full.log" 2>/dev/null; } \
  && ok "N6 knob 1 passes the gate to today's checks" || bad "N6 knob 1: $(cat "$HH/logs/ci-nightly-full.log" 2>/dev/null)"

echo "nightly-ticket-split: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
