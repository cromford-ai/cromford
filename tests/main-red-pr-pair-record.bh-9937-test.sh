#!/bin/bash
# tests/main-red-pr-pair-record.bh-9937-test.sh — BH-9937 (BH-9926 wave 5):
# lane main-red-pr-pair on the PR record through its seam
# (bin/lib/prr-shadow.d/main-red-pr-pair.sh) and the per-PR wake gate
# (bin/lib/prr-seen.sh). The production script "$DIR/bin/main-red-pr-pair.sh"
# runs whole (`bin/main-red-pr-pair.sh o/r`) in a scratch harness in file mode
# (no JOBS_URL, so the head ledger and pair marks are files), with:
#   * a stub bin/jobs-client.sh whose _jobs_req answers GET /api/pr-records
#     (the open list from $T/rec-list.json; absent = a failed read) and logs
#     every request to $T/jobs.txt;
#   * the gh shim of tests/main-red-pr-pair.bh-9890-test.sh (the -q filter is
#     applied with jq), every call logged to $T/gh.txt;
#   * the wake feed $T/state/pr-snapshot/o_r/{changed.tsv,wakes.state} in the
#     format _prsw_refresh writes, read by the REAL prs_wake_seen through wb_due.
# A "GitHub call" is every gh line except the per-repo token probe
# (`api repos/o/r -q .id`, bin/lib/gh-repo-token.sh): it picks the credential,
# reads no PR, and runs once per repo per tick before this wave as after it.
#
#   M1  record, 10 open PRs with pending heads: tick 1 reads and marks them;
#       tick 2 with no wake makes 0 GitHub calls
#   M2  a `checks` wake on #5's head: the only reads are actions/runs of that head
#   M3  shadow, the record list lacks #7: exactly 1 PRR_SHADOW line, and the
#       pair alert still names #7 (the GitHub value)
#   M4  off: 0 /api/pr-records calls
#   M5  a named failure row, quiet: 0 check-runs reads; with a `checks` wake on
#       that head: 1 check-runs read
#   M6  record, a due head whose runs read fails: no mark, read again next tick
#   M7  a quiet head counts in unknown: an open pair alert is NOT resolved on
#       that tick (control: in shadow the same fixture resolves it)
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/main-red-pr-pair-record.bh-9937-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || {
  echo "main-red-pr-pair-record.bh-9937: SKIPPED — jq/python3 is not installed"; exit 0; }

mkdir -p "$T/logs" "$T/state" "$T/flags" "$T/locks" "$T/env" "$T/fakebin"
for f in bin/main-red-pr-pair.sh bin/lib/prr-shadow.sh bin/lib/prr-seen.sh bin/lib/prr-shadow.d/main-red-pr-pair.sh \
         bin/lib/wake-backstop.sh bin/lib/pr-snapshot.sh bin/lib/pr-snapshot-wakes.sh bin/lib/pr-record.sh; do
  [ -f "$DIR/$f" ] || { bad "$f does not exist"; continue; }
  scratch_install_closure "$f" "$T" >/dev/null || bad "scratch_install_closure $f"
done
: > "$T/env/global.env"
cat > "$T/bin/jobs-client.sh" <<EOF
# a stub jobs client: the PR record's open list, nothing else
_jobs_req() {
  printf '%s %s\n' "\$1" "\$2" >> "$T/jobs.txt"
  case "\$1 \$2" in
    "GET /api/pr-records?"*"state=open"*) [ -f "$T/rec-list.json" ] && cat "$T/rec-list.json" && return 0; return 1 ;;
  esac
  return 1
}
EOF
cat > "$T/bin/lane-alert.sh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$ALERT_SINK"
exit 0
SHIM
chmod +x "$T/bin/lane-alert.sh"

cat > "$T/fakebin/gh" <<'SHIM'
#!/bin/bash
A="$*"
printf '%s\n' "$A" >> "$GH_SINK"
Q=""; CN=""; prev=""
for a in "$@"; do
  [ "$prev" = "-q" ] && Q="$a"
  case "$a" in check_name=*) CN="${a#check_name=}" ;; esac
  prev="$a"
done
case "$A" in
  "api repos/"*" -q .id")     exit 0 ;;
  *"/pulls?state=open"*)      case "$A" in *" -i "*) printf 'HTTP/2.0 200\r\n\r\n' ;; esac
                              cat "$T/pulls.json" ;;
  "pr list"*)                 echo "[]" ;;
  *"/check-runs"*)            sha=${A##*/commits/}; sha=${sha%%/check-runs*}
                              f="$T/checks-$sha.json"
                              { [ -s "$f" ] && cat "$f" || echo '{"check_runs":[]}'; } \
                                | jq -c --arg n "$CN" '{check_runs:[.check_runs[]? | select($n == "" or .name == $n)]}' \
                                | jq -rc "${Q:-.}" ;;
  *"/actions/jobs/"*"/logs"*) jid=${A##*/actions/jobs/}; jid=${jid%%/logs*}
                              [ -f "$T/joblog-$jid.txt" ] || exit 1
                              cat "$T/joblog-$jid.txt" ;;
  *"/actions/runs/"*"/jobs"*) rid=${A##*/actions/runs/}; rid=${rid%%/jobs*}
                              cat "$T/jobs-$rid.txt" 2>/dev/null || echo "" ;;
  *"actions/runs"*)           sha=${A##*head_sha=}; sha=${sha%% *}
                              [ -s "$T/runs-$sha.json" ] || exit 1
                              jq -rc "${Q:-.}" "$T/runs-$sha.json" ;;
  *) echo "" ;;
esac
SHIM
chmod +x "$T/fakebin/gh"

CI=".github/workflows/harness-ci.yml"
ERRL="ledger-check: refuse. 1 of 1 file(s) are not in the prod ledger"
LOG="$T/logs/main-red-pr-pair.log"
SHADOW="$T/logs/prr-shadow.log"
SD="$T/state/pr-snapshot/o_r"
SEEN="$T/state/prr-seen/main-red-pr-pair/o_r.tsv"
LEDGER="$T/state/main-red/pr-errors/o-r"
MARKS="$T/state/main-red/pairs/o-r"

sha() { printf '%040x' "$1"; }
pulls() { # pulls <number>... — open PRs at head $(sha n), updated in order
  local out='[' first=1 n
  for n in "$@"; do
    [ "$first" = 1 ] || out+=','; first=0
    out+=$(jq -nc --argjson n "$n" --arg sha "$(sha "$n")" --arg u "2026-11-20T09:$(printf '%02d' "$n"):00Z" \
      '{number:$n, html_url:("https://github.com/o/r/pull/"+($n|tostring)), title:"t", body:"",
        head:{sha:$sha, ref:("b"+($n|tostring))}, base:{ref:"main"}, draft:false, user:{login:"operator", type:"User"},
        created_at:$u, updated_at:$u, merged_at:null, closed_at:null, labels:[], state:"open"}')
  done
  printf '%s]' "$out" > "$T/pulls.json"
}
recl() { # recl <number>... — the record's open list
  local rows='[]' n
  for n in "$@"; do
    rows=$(jq -c --argjson n "$n" --arg h "$(sha "$n")" --arg u "2026-11-20T09:$(printf '%02d' "$n"):00Z" \
      '. + [{number:$n, head_sha:$h, updated_at:$u, created_at:$u}]' <<<"$rows")
  done
  jq -nc --argjson r "$rows" '{rows:$r, truncated:false, sync:{age_s:5, synced_at:"2026-11-25T00:00:00Z"}, missing:null, unknown:0}' > "$T/rec-list.json"
}
pending() { jq -nc --arg p "$CI" '{workflow_runs:[{name:"Harness CI", path:$p, status:"in_progress", conclusion:null,
  created_at:"2026-11-20T09:00:00Z", html_url:"u", id:1}]}' > "$T/runs-$(sha "$1").json"; }
greenrun() { jq -nc --arg p "$CI" '{workflow_runs:[{name:"Harness CI", path:$p, status:"completed", conclusion:"success",
  created_at:"2026-11-20T09:00:00Z", html_url:"u", id:2}]}' > "$T/runs-$(sha "$1").json"; }
failrun() { # failrun <n> <created_at> — "gate" fails with ERRL, run 900<n>, job 800<n>
  jq -nc --arg p "$CI" --arg t "$2" --argjson id "900$1" '{workflow_runs:[{name:"Harness CI", path:$p, status:"completed",
    conclusion:"failure", created_at:$t, html_url:"u", id:$id}]}' > "$T/runs-$(sha "$1").json"
  printf 'gate\t800%s\n' "$1" > "$T/jobs-900$1.txt"
  printf '2026-11-20T09:51:02.1234567Z %s\n2026-11-20T09:51:02.2234567Z ##[error]Process completed with exit code 1.\n' "$ERRL" > "$T/joblog-800$1.txt"
}
feed() { # feed [kind:key:age-s]... — the wake mirror, complete and fresh, read now
  local r k y a now i=100
  now=$(date +%s)  # determinism: ok the real prs_wake_seen bounds its window on the box clock
  mkdir -p "$SD"
  printf '%s\t1\t1\t%s\n' "$now" "$((now - 7200))" > "$SD/wakes.state"
  echo 500 > "$SD/wakes.wm"; : > "$SD/changed.tsv"
  for r in "$@"; do
    IFS=: read -r k y a <<<"$r"; i=$((i + 1))
    printf '%s\t%s\t%s\t%s\n' "$k" "$y" "$i" "$((now - a))" >> "$SD/changed.tsv"
  done
}
backdate() { # backdate <age-s> — every mark moved <age-s> into the past
  local now; now=$(date +%s)  # determinism: ok the marks hold the lane's own clock
  awk -F'\t' -v OFS='\t' -v e="$((now - $1))" '{ $2 = e; print }' "$SEEN" > "$SEEN.tmp" && mv "$SEEN.tmp" "$SEEN"
}
reset_case() {
  : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$T/jobs.txt"; : > "$LOG"; rm -f "$SHADOW"
  scratch_rm "$T/state"; mkdir -p "$T/state"; rm -f "$T"/flags/main-red-*
  rm -f "$T"/runs-*.json "$T"/jobs-*.txt "$T"/joblog-*.txt "$T"/checks-*.json "$T/rec-list.json"
  feed
}
quiet() { : > "$T/alerts.txt"; : > "$T/gh.txt"; : > "$T/jobs.txt"; : > "$LOG"; }
drive() { # drive <step> — one tick on o/r
  ( export PATH="$T/fakebin:$PATH" HARNESS="$T" T="$T" GH_SINK="$T/gh.txt" ALERT_SINK="$T/alerts.txt" \
           GH_SOURCE="$1" PR_SNAPSHOT_TTL_S=600 HARNESS_TEST_SANDBOX=1
    unset GH_TOKEN HARNESS_SECRET JOBS_URL PRR_SEEN_BACKSTOP_S WAKE_BACKSTOP WAKE_BACKSTOP_NOW PR_SNAPSHOT
    bash "$T/bin/main-red-pr-pair.sh" o/r >"$T/out.txt" 2>"$T/err.txt" )
}
ghlines() { grep -vE '^api repos/[^ ]+ -q \.id$' "$T/gh.txt" 2>/dev/null; }
ghreads() { ghlines | grep -c . ; }

# ── M1: record, 10 unchanged pending heads: tick 2 makes 0 GitHub calls ──
reset_case; pulls 1 2 3 4 5 6 7 8 9 10; recl 1 2 3 4 5 6 7 8 9 10
for n in 1 2 3 4 5 6 7 8 9 10; do pending "$n"; done
drive record
[ "$(ghlines | grep -c 'actions/runs')" = 10 ] && ok || bad "M1 tick 1 want 10 runs reads: $(ghlines)"
grep -q 'pulls?' <<<"$(ghlines)" && bad "M1 tick 1 read the GitHub list on a fresh record list" || ok
[ "$(wc -l < "$SEEN" 2>/dev/null)" = 10 ] && ok || bad "M1 tick 1 must mark the 10 pending heads: $(cat "$SEEN" 2>/dev/null) $(cat "$T/err.txt")"
backdate 600; quiet; drive record
[ "$(ghreads)" = 0 ] && ok || bad "M1 tick 2 want 0 GitHub calls, got $(ghreads): $(ghlines | head -5)"
grep -q 'o/r: record step: quiet=10 read=0' "$LOG" && ok || bad "M1 no record-step line: $(cat "$LOG")"
grep -q '10 open PR head(s) have no verdict this tick' "$LOG" && ok || bad "M1 quiet heads must count as unknown: $(cat "$LOG")"

# ── M2: one checks wake on #5's head: only that head is read ──
feed "checks:$(sha 5):300"; quiet; drive record
[ "$(ghreads)" -ge 1 ] && ok || bad "M2 the woken head was not read"
[ "$(ghlines | grep -vc "head_sha=$(sha 5)")" = 0 ] && ok || bad "M2 a read names another head: $(ghlines)"
grep -q 'o/r: record step: quiet=9 read=1' "$LOG" && ok || bad "M2 record-step line: $(cat "$LOG")"

# ── M3: shadow, the record list lacks #7: 1 PRR_SHADOW line, #7 still pairs ──
reset_case; pulls 6 7; recl 6
failrun 6 2026-11-20T09:50:00Z; failrun 7 2026-11-20T09:50:35Z
drive shadow
[ "$(grep -c 'PRR_SHADOW lane=main-red-pr-pair' "$SHADOW" 2>/dev/null)" = 1 ] && ok || bad "M3 want exactly 1 PRR_SHADOW line: $(cat "$SHADOW" 2>/dev/null)"
grep -q 'PRR_SHADOW lane=main-red-pr-pair key=o/r#open record=1 github=2 only_record=0 only_github=1 changed=0' "$SHADOW" 2>/dev/null \
  && ok || bad "M3 the line must count #7 as only_github: $(cat "$SHADOW" 2>/dev/null)"
grep -- '--severity critical' "$T/alerts.txt" | grep -q '#6, #7' && ok || bad "M3 the pair alert must name #6 and #7: $(cat "$T/alerts.txt") $(cat "$LOG")"
[ ! -e "$SEEN" ] && ok || bad "M3 shadow must write no mark: $(cat "$SEEN")"

# ── M4: off: 0 record calls ──
reset_case; pulls 6 7; recl 6
failrun 6 2026-11-20T09:50:00Z; failrun 7 2026-11-20T09:50:35Z
drive off
[ "$(grep -c '/api/pr-records' "$T/jobs.txt")" = 0 ] && ok || bad "M4 off made record calls: $(cat "$T/jobs.txt")"
grep -- '--severity critical' "$T/alerts.txt" | grep -q '#6, #7' && ok || bad "M4 off must still pair: $(cat "$T/alerts.txt")"

# ── M5: a named failure row: quiet = no check-runs read; a checks wake = 1 ──
reset_case; pulls 1 2; recl 1 2
failrun 1 2026-11-20T09:50:00Z; failrun 2 2026-11-20T09:50:35Z
drive record
grep -- '--severity critical' "$T/alerts.txt" | grep -q '#1, #2' && ok || bad "M5 setup: the pair was not raised: $(cat "$LOG")"
[ "$(wc -l < "$SEEN" 2>/dev/null)" = 2 ] && ok || bad "M5 setup: both heads must be marked: $(cat "$SEEN" 2>/dev/null)"
backdate 600; quiet; drive record
[ "$(ghlines | grep -c 'check-runs')" = 0 ] && ok || bad "M5 a quiet named head read its check runs: $(ghlines)"
[ "$(ghreads)" = 0 ] && ok || bad "M5 a quiet tick made GitHub calls: $(ghlines)"
feed "checks:$(sha 1):300"; quiet; drive record
[ "$(ghlines | grep -c 'check-runs')" = 1 ] && ok || bad "M5 a checks wake must cost 1 check-runs read: $(ghlines)"
ghlines | grep 'check-runs' | grep -q "commits/$(sha 1)/" && ok || bad "M5 the read must be of the woken head: $(ghlines)"

# ── M6: record, a due head whose runs read fails: no mark, read again ──
reset_case; pulls 3; recl 3
drive record
ghlines | grep -q "head_sha=$(sha 3)" && ok || bad "M6 tick 1 did not read #3: $(ghlines)"
grep -q '^3	' "$SEEN" 2>/dev/null && bad "M6 an unread head wrote a mark: $(cat "$SEEN")" || ok
quiet; drive record
ghlines | grep -q "head_sha=$(sha 3)" && ok || bad "M6 tick 2 must read #3 again: $(ghlines)"

# ── M7: a quiet head is unknown: the open pair is not resolved ──
m7_setup() {
  reset_case; pulls 1 2; recl 1 2
  mkdir -p "$LEDGER" "$MARKS" "$(dirname "$SEEN")"
  printf -- '-\t-\t-\n' > "$LEDGER/$(sha 1).tsv"
  greenrun 2
  { echo "job=gate"; echo "first_error=$ERRL"; echo "prs=#1, #2"; echo "detected=2026-11-20 10:00:00Z"; } > "$MARKS/abc123def456"
  printf '2\t%s\t%s\n' "$(( $(date +%s) - 600 ))" "$(sha 2)" > "$SEEN"  # determinism: ok a mark 600 s old on the lane's clock
}
m7_setup; drive record
grep -q -- '--resolve' "$T/alerts.txt" && bad "M7 a quiet head resolved the pair: $(cat "$T/alerts.txt")" || ok
[ -f "$MARKS/abc123def456" ] && ok || bad "M7 the pair marker must stay open"
grep -q 'open pairs left alone rather than called fixed' "$LOG" && ok || bad "M7 no left-alone line: $(cat "$LOG")"
m7_setup; drive shadow
grep -q -- '--resolve --id main-red-prs:o-r:abc123def456' "$T/alerts.txt" && ok || bad "M7 control: in shadow the green head must resolve the pair: $(cat "$T/alerts.txt") $(cat "$LOG")"

echo "main-red-pr-pair-record.bh-9937: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
