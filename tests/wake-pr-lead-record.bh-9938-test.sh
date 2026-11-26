#!/bin/bash
# tests/wake-pr-lead-record.bh-9938-test.sh — BH-9938 (BH-9926.6) T6: the
# pr-lead wake class (bin/lib/wake-class-pr-lead.sh) reads the PR from the PR
# record through bin/lib/prr-shadow.sh, lane id wake-loop.
#
# The seam is bin/lib/prr-shadow.d/wake-loop.sh:
#   wl_pr_record <file> <slug> <n>  pr_record_peek; a hit writes
#                                   {"state","draft","head":{"sha"}}
#   wl_pr_github <file> <slug> <n>  today's gh_rest_var GET repos/<slug>/pulls/<n>
#   wl_pr_norm <file>               [{n:"pr", state, draft, head}]
#
# S* cases source the installed seam in a subshell with a stub _jobs_req that
# answers GET /api/pr-records?repo=&number= from one fixture, in the worker's
# own shape ({row, age_s}; the row's draft is the stored INTEGER 0/1).
# W* cases drive the REAL bin/wake-loop.sh on tests/lib/wake-claim-stub.sh, the
# tests/lead-review-event.bh-9582-test.sh fixture, with this suite's curl also
# answering GET /api/pr-records?repo=&number= from $T/rec/<owner_repo>_<n>.json
# (absent = {"row":null,"age_s":null}, the worker's "no record") and logging
# each such GET to $T/rec.log. `gh` is a PATH fake that logs argv to $T/gh.log
# and answers `pulls/<n>` from $T/gh/<owner_repo>_<n> (no file = exit 1).
#   W1  step record, 3 synchronize wakes, fresh records: 0 gh calls, 3 rings,
#       each on the record head.
#   W2  step record, a drain with no pr-lead event: 0 gh calls, 0 record GETs,
#       0 rings.
#   W3  step shadow, the record head differs from GitHub: 1 PRR_SHADOW
#       lane=wake-loop line, the ring is on the GitHub head.
#   W4  step record, record age = PR_RECORD_MAX_AGE_S + 1: one PRR_MISS
#       lane=wake-loop ... why=stale fallback=github line and 1 pulls/<n> read.
#   W5  step record, reads_max=1, 3 record hits: 3 rings, no cap line (a
#       record hit spends no GitHub read).
#   W6  step record, reads_max=1, 3 stale records: 1 GitHub read, 1 ring, the
#       other 2 are over the cap (no GitHub read).
#   W7  step off: today's read, 0 record GETs.
#   W8  the seam file is absent: today's inline read, 0 record GETs.
# M1-M2 at the end are the D1 self-check on a mutated seam.
#
# No wall clock: every age is a fixed age_s in a fixture. PR_RECORD_MAX_AGE_S is
# fixed at 900 in the environment.
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/wake-pr-lead-record.bh-9938-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
export HARNESS="$H" WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0 GH_ETAG=0 PR_RECORD_MAX_AGE_S=900
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE \
  LEAD_REVIEW_AUTO_REPOS LEAD_REVIEW_WORKLIST GH_SOURCE
SEAM_SED=""
LANES="merge-conductor deploy-train postmerge-qa run-triage review-prs rebase-train lead-review-land"

fresh() {
  scratch_rm "$H"
  mkdir -p "$H/bin/lib/jobs" "$H/env" "$H/logs" "$H/locks" "$H/state/wcs" "$H/flags" "$H/calls"
  rm -rf "$T/gh" "$T/rec"; mkdir -p "$T/gh" "$T/rec"
  : > "$T/gh.log"; : > "$T/lane.log"; : > "$T/rec.log"
  printf '{"settings":[]}' > "$T/settings.json"
  printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\nLEAD_REVIEW_AUTO_REPOS="example-org/cromford"\n' \
    > "$H/env/global.env"
  scratch_install_closure bin/wake-loop.sh "$H" >/dev/null \
    || { echo "FAIL: scratch_install_closure bin/wake-loop.sh"; exit 1; }
  scratch_install_closure bin/jobs-client.sh "$H" >/dev/null \
    || { echo "FAIL: scratch_install_closure bin/jobs-client.sh"; exit 1; }
  # The seam is loaded by name (prr_seam_load), so no closure scan of the loop sees it.
  scratch_install_closure bin/lib/prr-shadow.d/wake-loop.sh "$H" >/dev/null \
    || { echo "FAIL: scratch_install_closure bin/lib/prr-shadow.d/wake-loop.sh"; exit 1; }
  [ -n "$SEAM_SED" ] && sed -i -e "$SEAM_SED" "$H/bin/lib/prr-shadow.d/wake-loop.sh"
  wcs_install "$H/bin"
  wcs_identity "$H/bin" || { echo "wcs_identity failed"; exit 1; }
  cat > "$H/bin/curl" <<'SH'
#!/bin/bash
"$(dirname "$0")/wcs-routes" "$@" && exit 0
method=GET body="" url=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method="$2"; shift ;;
    --data-binary) body="$2"; case "$body" in @*) body=$(cat "${body#@}") ;; esac; shift ;;
    http*://*) url="$1" ;;
  esac
  shift
done
path="/${url#*://*/}"
case "$method $path" in
  "POST /api/wakes/lane")
    printf '%s\n' "$body" >> "$T9938/lane.log"
    W="${WCS_WAKES:?}"
    jq -c --argjson b "$body" '.wakes += [{id: (((.wakes | map(.id) | max) // 0) + 1),
        repo: $b.repo, kind: $b.kind, key: ($b.key | tostring), event: ("lane:" + $b.kind),
        at: "2026-11-25T03:00:00Z"}]' "$W" > "$W.tmp" && mv "$W.tmp" "$W"
    printf '{"ok":true}\n200' ;;
  "GET /api/pr-records?"*number=*)
    printf '%s\n' "$path" >> "$T9938/rec.log"
    q="${path#*\?}"; r="${q#*repo=}"; r="${r%%&*}"; n="${q#*number=}"; n="${n%%&*}"
    f="$T9938/rec/${r//\//_}_$n.json"
    if [ -r "$f" ]; then cat "$f"; else printf '{"row":null,"age_s":null}'; fi
    printf '\n200' ;;
  "GET /api/settings")
    cat "$T9938/settings.json"; printf '\n200' ;;
  "GET /api/settings/"*)
    k="${path#/api/settings/}"
    v=$(jq -r --arg k "$k" '.settings[] | select(.key == $k) | .value' "$T9938/settings.json")
    if [ -n "$v" ]; then jq -nc --arg k "$k" --arg v "$v" '{setting:{key:$k,value:$v}}'; printf '\n200'
    else printf '{"error":"not found"}\n404'; fi ;;
  *) printf '{}\n200' ;;
esac
SH
  cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'cromford\n'; exit 0; }
case "$1/$2" in
  cromford/repo) echo example-org/cromford ;;
  cromford/box)  echo box-small ;;
  */board_prefix)     echo /api/board ;;
  *) exit 1 ;;
esac
SH
  for s in $LANES; do
    printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/%s"\n' "$s" > "$H/bin/$s.sh"
  done
  printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/lead-review"\n' > "$H/bin/lead-review.sh"
  cat > "$H/bin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$T9938/gh.log"
p=""
for a in "$@"; do case "$a" in repos/*/pulls/*) p="$a" ;; esac; done
[ -n "$p" ] || { echo "[]"; exit 0; }
f="$T9938/gh/$(printf '%s' "${p#repos/}" | tr 'A-Z' 'a-z' | sed 's|/pulls/|_|; s|/|_|g')"
[ -r "$f" ] || exit 1
cat "$f"
SH
  printf '#!/bin/bash\nexit 1\n' > "$H/bin/unblocked-children.sh"
  printf '#!/bin/bash\nexec "$@"\n' > "$H/bin/setsid"
  chmod +x "$H/bin/"*.sh "$H/bin/gh" "$H/bin/setsid" "$H/bin/curl"
  : > "$T/wakes.json"
}
export T9938="$T"
export WCS_WAKES="$T/wakes.json"
export PATH="$H/bin:$PATH"

wakes() { printf '{"wakes":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/wakes.json"; }
W() { # W <id> <repo> <kind> <key> <event>
  printf '{"id":%s,"repo":"%s","kind":"%s","key":"%s","event":"%s","at":"2026-11-25T03:00:00Z"}' \
    "$1" "$2" "$3" "$4" "$5"
}
head40() { printf '%s%037d' "$1" "$2"; }
# pr <n> <state> <draft> <head>: the GitHub answer for one cromford PR.
pr() {
  printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n{"number":%s,"state":"%s","draft":%s,"head":{"sha":"%s"}}\n' \
    "$1" "$2" "$3" "$4" > "$T/gh/example-org_cromford_$1"
}
# recjson <n> <state-json> <draft-json> <head-json> <age_s>: the worker's GET
# /api/pr-records?repo=&number= answer (routes/pr-records.js: {row, age_s};
# draft is stored INTEGER 0/1).
recjson() {
  jq -nc --argjson n "$1" --argjson s "$2" --argjson d "$3" --argjson h "$4" --argjson a "$5" \
    '{row: {repo: "example-org/cromford", number: $n, state: $s, draft: $d, head_ref: "ticket/x",
            base_ref: "main", head_sha: $h, base_sha: null, mergeable_state: "clean", labels: [],
            fields_at: {}, last_source: "webhook", refreshed_at: "2026-11-25T02:45:00Z"}, age_s: $a}'
}
# rec <n> <state-json> <draft-json> <head-json> <age_s>: one record fixture for the W* curl.
rec() { recjson "$@" > "$T/rec/example-org_cromford_$1.json"; }
setting() {
  jq -c --arg k "$1" --arg v "$2" '.settings += [{key:$k,value:$v,actor:"operator",note:""}]' "$T/settings.json" > "$T/s.tmp" \
    && mv "$T/s.tmp" "$T/settings.json"
}
run_as() { BOX_NAME="$1" "$H/bin/wake-loop.sh"; RC=$?; return "$RC"; }
LOG() { cat "$H/logs/wake-loop.log" 2>/dev/null; }
SHADOW() { cat "$H/logs/prr-shadow.log" 2>/dev/null; }
lanes_n() { grep -c . "$T/lane.log" 2>/dev/null || true; }
gh_all() { grep -c . "$T/gh.log" 2>/dev/null || true; }
gh_n() { grep -c 'pulls/' "$T/gh.log" 2>/dev/null || true; }
rec_n() { grep -c . "$T/rec.log" 2>/dev/null || true; }
dedupes() { jq -r 'select(.kind == "lead-review") | .dedupe' "$T/lane.log" | sort | tr '\n' ' '; }

BH=example-org/cromford
BOX=box-small

# ── S*: the seam, sourced from the installed tree ───────────────────────────
# seam <fixture-json|-> <fn> [args...]: run one seam fn in a subshell; a stub
# _jobs_req answers the record GET from the fixture (`-` = the read fails).
seam() {
  local fx="$1"; shift
  ( export HARNESS="$H"
    if [ "$fx" = - ]; then _jobs_req() { return 1; }
    else _jobs_req() { printf '%s\n' "$2" >> "$T/rec.log"; printf '%s\n' "$SEAM_FX"; }; fi
    SEAM_FX="$fx"
    . "$H/bin/lib/prr-shadow.d/wake-loop.sh" || exit 9
    "$@" )
}
HS=$(head40 abc 7001)

case_S1() { # fresh row, draft 0: a hit in the REST subset shape
  local out
  fresh
  out=$(seam "$(recjson 7001 '"open"' 0 "\"$HS\"" 12)" wl_pr_record "$T/s1.json" $BH 7001) || { echo "S1 rc $? out '$out'"; return 1; }
  [ -z "$out" ] || { echo "S1 printed '$out' on a hit"; return 1; }
  [ "$(cat "$T/s1.json")" = "{\"state\":\"open\",\"draft\":false,\"head\":{\"sha\":\"$HS\"}}" ] \
    || { echo "S1 file: $(cat "$T/s1.json")"; return 1; }
  grep -q '^/api/pr-records?repo=example-org/cromford&number=7001$' "$T/rec.log" || { echo "S1 GET: $(cat "$T/rec.log")"; return 1; }
}
case_S2() { # draft 1 and a boolean draft both map to the boolean; merged reads as closed
  fresh
  seam "$(recjson 7002 '"open"' 1 "\"$HS\"" 0)" wl_pr_record "$T/s2a.json" $BH 7002 >/dev/null || { echo "S2 draft 1 missed"; return 1; }
  [ "$(jq -c .draft "$T/s2a.json")" = true ] || { echo "S2 draft 1: $(cat "$T/s2a.json")"; return 1; }
  seam "$(recjson 7002 '"open"' false "\"$HS\"" 0)" wl_pr_record "$T/s2b.json" $BH 7002 >/dev/null || { echo "S2 draft false missed"; return 1; }
  [ "$(jq -c .draft "$T/s2b.json")" = false ] || { echo "S2 draft false: $(cat "$T/s2b.json")"; return 1; }
  seam "$(recjson 7002 '"merged"' 0 "\"$HS\"" 0)" wl_pr_record "$T/s2c.json" $BH 7002 >/dev/null || { echo "S2 merged missed"; return 1; }
  [ "$(jq -r .state "$T/s2c.json")" = closed ] || { echo "S2 merged: $(cat "$T/s2c.json")"; return 1; }
}
case_S3() { # draft null: miss field:draft
  local out rc=0
  fresh
  out=$(seam "$(recjson 7003 '"open"' null "\"$HS\"" 12)" wl_pr_record "$T/s3.json" $BH 7003) || rc=$?
  [ "$rc" = 1 ] && [ "$out" = field:draft ] || { echo "S3 rc $rc out '$out'"; return 1; }
  [ ! -s "$T/s3.json" ] || { echo "S3 wrote on a miss: $(cat "$T/s3.json")"; return 1; }
}
case_S4() { # draft 2 (not 0/1, not a boolean): miss field:draft
  local out rc=0
  fresh
  out=$(seam "$(recjson 7004 '"open"' 2 "\"$HS\"" 12)" wl_pr_record "$T/s4.json" $BH 7004) || rc=$?
  [ "$rc" = 1 ] && [ "$out" = field:draft ] || { echo "S4 rc $rc out '$out'"; return 1; }
}
case_S5() { # head_sha 39 hex: miss field:head_sha
  local out rc=0
  fresh
  out=$(seam "$(recjson 7005 '"open"' 0 "\"${HS:0:39}\"" 12)" wl_pr_record "$T/s5.json" $BH 7005) || rc=$?
  [ "$rc" = 1 ] && [ "$out" = field:head_sha ] || { echo "S5 rc $rc out '$out'"; return 1; }
}
case_S6() { # state null: miss field:state
  local out rc=0
  fresh
  out=$(seam "$(recjson 7006 null 0 "\"$HS\"" 12)" wl_pr_record "$T/s6.json" $BH 7006) || rc=$?
  [ "$rc" = 1 ] && [ "$out" = field:state ] || { echo "S6 rc $rc out '$out'"; return 1; }
}
case_S7() { # age = knob: a hit; age = knob + 1: miss stale
  local out rc=0
  fresh
  seam "$(recjson 7007 '"open"' 0 "\"$HS\"" 900)" wl_pr_record "$T/s7.json" $BH 7007 >/dev/null || { echo "S7 age 900 missed"; return 1; }
  out=$(seam "$(recjson 7007 '"open"' 0 "\"$HS\"" 901)" wl_pr_record "$T/s7b.json" $BH 7007) || rc=$?
  [ "$rc" = 1 ] && [ "$out" = stale ] || { echo "S7 age 901 rc $rc out '$out'"; return 1; }
  rc=0; out=$(seam "$(recjson 7007 '"open"' 0 "\"$HS\"" null)" wl_pr_record "$T/s7c.json" $BH 7007) || rc=$?
  [ "$rc" = 1 ] && [ "$out" = stale ] || { echo "S7 age null rc $rc out '$out'"; return 1; }
}
case_S8() { # knob 0: miss off, no jobs GET
  local out rc=0
  fresh
  out=$(PR_RECORD_MAX_AGE_S=0 seam "$(recjson 7008 '"open"' 0 "\"$HS\"" 0)" wl_pr_record "$T/s8.json" $BH 7008) || rc=$?
  [ "$rc" = 1 ] && [ "$out" = off ] || { echo "S8 rc $rc out '$out'"; return 1; }
  [ "$(rec_n)" = 0 ] || { echo "S8 GETs: $(cat "$T/rec.log")"; return 1; }
}
case_S9() { # no row, and a failed read: miss unreadable
  local out rc=0
  fresh
  out=$(seam '{"row":null,"age_s":null}' wl_pr_record "$T/s9.json" $BH 7009) || rc=$?
  [ "$rc" = 1 ] && [ "$out" = unreadable ] || { echo "S9 no row rc $rc out '$out'"; return 1; }
  rc=0; out=$(seam - wl_pr_record "$T/s9.json" $BH 7009) || rc=$?
  [ "$rc" = 1 ] && [ "$out" = unreadable ] || { echo "S9 failed read rc $rc out '$out'"; return 1; }
}
case_S10() { # norm: one object keyed on .n; the GitHub body and the record hit norm the same
  local a b
  fresh
  printf '{"number":7010,"state":"open","draft":false,"head":{"sha":"%s"},"title":"x"}' "$HS" > "$T/g.json"
  seam "$(recjson 7010 '"open"' 0 "\"$HS\"" 1)" wl_pr_record "$T/r.json" $BH 7010 >/dev/null || { echo "S10 record missed"; return 1; }
  a=$(seam - wl_pr_norm "$T/g.json"); b=$(seam - wl_pr_norm "$T/r.json")
  [ "$a" = "[{\"n\":\"pr\",\"state\":\"open\",\"draft\":false,\"head\":\"$HS\"}]" ] || { echo "S10 norm: $a"; return 1; }
  [ "$a" = "$b" ] || { echo "S10 differ: $a vs $b"; return 1; }
}
case_S11() { # wl_pr_github: the body into the file, rc 0; a failed read: a non-zero rc
  local rc=0
  fresh; pr 7011 open false "$HS"
  seam - wl_pr_github "$T/s11.json" $BH 7011 || { echo "S11 rc $?"; return 1; }
  [ "$(jq -r .head.sha "$T/s11.json")" = "$HS" ] || { echo "S11 file: $(cat "$T/s11.json")"; return 1; }
  grep -q 'repos/example-org/cromford/pulls/7011' "$T/gh.log" || { echo "S11 gh: $(cat "$T/gh.log")"; return 1; }
  seam - wl_pr_github "$T/s11b.json" $BH 7099 || rc=$?
  [ "$rc" != 0 ] || { echo "S11 failed read rc 0"; return 1; }
}

# ── W*: the real loop ───────────────────────────────────────────────────────
case_W1() { # record: 3 synchronize wakes with fresh records: 0 gh calls, 3 rings on the record heads
  local n exp=""
  fresh; export GH_SOURCE=record
  for n in 7101 7102 7103; do rec $n '"open"' 0 "\"$(head40 ec0 $n)\"" 30; exp="${exp}lead-review:$n@$(head40 ec0 $n | cut -c1-12) "; done
  wakes "$(W 1 $BH pr 7101 pull_request.synchronize)" "$(W 2 $BH pr 7102 pull_request.synchronize)" "$(W 3 $BH pr 7103 pull_request.synchronize)"
  run_as $BOX || { echo "W1 loop rc $RC: $(LOG)"; return 1; }
  [ "$(gh_all)" = 0 ] || { echo "W1 gh calls: $(cat "$T/gh.log")"; return 1; }
  [ "$(rec_n)" = 3 ] || { echo "W1 record GETs $(rec_n): $(cat "$T/rec.log")"; return 1; }
  [ "$(dedupes)" = "$exp" ] || { echo "W1 dedupes '$(dedupes)' want '$exp' log: $(LOG)"; return 1; }
}
case_W2() { # record: a drain with no pr-lead event: 0 gh calls, 0 record GETs, 0 rings
  fresh; export GH_SOURCE=record
  rec 7201 '"open"' 0 "\"$(head40 ec0 7201)\"" 30
  wakes "$(W 1 $BH pr 7201 pull_request.closed)" "$(W 2 $BH pr 7201 pull_request.labeled)"
  run_as $BOX || { echo "W2 loop rc $RC"; return 1; }
  wcs_log | grep -q '^PUT /api/wakes/cursor .*"cursor":2' || { echo "W2 drain did not run: $(wcs_log)"; return 1; }
  [ "$(gh_all)" = 0 ] && [ "$(rec_n)" = 0 ] && [ "$(lanes_n)" = 0 ] \
    || { echo "W2 gh $(gh_all) rec $(rec_n) rings $(lanes_n)"; return 1; }
}
case_W3() { # shadow: record head A, GitHub head B: 1 PRR_SHADOW line, ring on B
  local a b
  fresh; export GH_SOURCE=shadow
  a=$(head40 aaa 7301); b=$(head40 bbb 7301)
  rec 7301 '"open"' 0 "\"$a\"" 30; pr 7301 open false "$b"
  wakes "$(W 1 $BH pr 7301 pull_request.synchronize)"
  run_as $BOX || { echo "W3 loop rc $RC"; return 1; }
  [ "$(grep -c 'PRR_SHADOW lane=wake-loop' <<<"$(SHADOW)")" = 1 ] || { echo "W3 shadow log: $(SHADOW)"; return 1; }
  grep -q 'PRR_SHADOW lane=wake-loop key=example-org/cromford#7301 record=1 github=1 only_record=0 only_github=0 changed=1' <<<"$(SHADOW)" \
    || { echo "W3 line: $(SHADOW)"; return 1; }
  [ "$(gh_n)" = 1 ] && [ "$(rec_n)" = 1 ] || { echo "W3 gh $(gh_n) rec $(rec_n)"; return 1; }
  [ "$(dedupes)" = "lead-review:7301@${b:0:12} " ] || { echo "W3 dedupes '$(dedupes)'"; return 1; }
}
case_W3b() { # shadow, record equal to GitHub: 0 PRR_SHADOW lines
  local h
  fresh; export GH_SOURCE=shadow
  h=$(head40 aaa 7302); rec 7302 '"open"' 0 "\"$h\"" 30; pr 7302 open false "$h"
  wakes "$(W 1 $BH pr 7302 pull_request.synchronize)"
  run_as $BOX
  ! grep -q PRR_SHADOW <<<"$(SHADOW)" || { echo "W3b shadow log: $(SHADOW)"; return 1; }
  [ "$(dedupes)" = "lead-review:7302@${h:0:12} " ] || { echo "W3b dedupes '$(dedupes)'"; return 1; }
}
case_W4() { # record, age = knob + 1: PRR_MISS stale, 1 pulls/<n> read, the ring on the GitHub head
  local a b
  fresh; export GH_SOURCE=record
  a=$(head40 aaa 7401); b=$(head40 bbb 7401)
  rec 7401 '"open"' 0 "\"$a\"" 901; pr 7401 open false "$b"
  wakes "$(W 1 $BH pr 7401 pull_request.synchronize)"
  run_as $BOX || { echo "W4 loop rc $RC"; return 1; }
  [ "$(grep -c 'PRR_MISS lane=wake-loop key=example-org/cromford#7401 why=stale fallback=github' <<<"$(SHADOW)")" = 1 ] \
    || { echo "W4 shadow log: $(SHADOW)"; return 1; }
  [ "$(grep -c 'repos/example-org/cromford/pulls/7401' "$T/gh.log")" = 1 ] && [ "$(gh_n)" = 1 ] \
    || { echo "W4 gh: $(cat "$T/gh.log")"; return 1; }
  [ "$(dedupes)" = "lead-review:7401@${b:0:12} " ] || { echo "W4 dedupes '$(dedupes)'"; return 1; }
}
case_W5() { # record, reads_max=1, 3 record hits: 3 rings, no cap line
  local n
  fresh; export GH_SOURCE=record; setting lead_review.event_wake.reads_max 1
  for n in 7501 7502 7503; do rec $n '"open"' 0 "\"$(head40 ec0 $n)\"" 30; done
  wakes "$(W 1 $BH pr 7501 pull_request.opened)" "$(W 2 $BH pr 7502 pull_request.opened)" "$(W 3 $BH pr 7503 pull_request.opened)"
  run_as $BOX
  [ "$(gh_all)" = 0 ] || { echo "W5 gh: $(cat "$T/gh.log")"; return 1; }
  [ "$(lanes_n)" = 3 ] || { echo "W5 rings $(lanes_n) log: $(LOG)"; return 1; }
  ! grep -q 'over the read cap' <<<"$(LOG)" || { echo "W5 cap line: $(LOG)"; return 1; }
}
case_W6() { # record, reads_max=1, 3 stale records: 1 GitHub read, 1 ring, 2 over the cap
  local n
  fresh; export GH_SOURCE=record; setting lead_review.event_wake.reads_max 1
  for n in 7601 7602 7603; do rec $n '"open"' 0 "\"$(head40 ec0 $n)\"" 5000; pr $n open false "$(head40 bbb $n)"; done
  wakes "$(W 1 $BH pr 7601 pull_request.opened)" "$(W 2 $BH pr 7602 pull_request.opened)" "$(W 3 $BH pr 7603 pull_request.opened)"
  run_as $BOX
  [ "$(gh_n)" = 1 ] || { echo "W6 gh: $(cat "$T/gh.log")"; return 1; }
  [ "$(dedupes)" = "lead-review:7601@$(head40 bbb 7601 | cut -c1-12) " ] || { echo "W6 dedupes '$(dedupes)'"; return 1; }
  [ "$(grep -c 'pr-lead: 2 PR(s) over the read cap of 1; the \*/15 cron covers them' <<<"$(LOG)")" = 1 ] || { echo "W6 log: $(LOG)"; return 1; }
}
case_W7() { # off: today's read, 0 record GETs
  local b
  fresh; export GH_SOURCE=off
  b=$(head40 bbb 7701); rec 7701 '"open"' 0 "\"$(head40 aaa 7701)\"" 30; pr 7701 open false "$b"
  wakes "$(W 1 $BH pr 7701 pull_request.opened)"
  run_as $BOX
  [ "$(gh_n)" = 1 ] && [ "$(rec_n)" = 0 ] || { echo "W7 gh $(gh_n) rec $(rec_n)"; return 1; }
  [ "$(dedupes)" = "lead-review:7701@${b:0:12} " ] || { echo "W7 dedupes '$(dedupes)'"; return 1; }
}
case_W8() { # the seam file is absent: today's inline read, even in step record
  local b
  fresh; export GH_SOURCE=record
  rm -f "$H/bin/lib/prr-shadow.d/wake-loop.sh"
  b=$(head40 bbb 7801); rec 7801 '"open"' 0 "\"$(head40 aaa 7801)\"" 30; pr 7801 open false "$b"
  wakes "$(W 1 $BH pr 7801 pull_request.opened)"
  run_as $BOX
  [ "$(gh_n)" = 1 ] && [ "$(rec_n)" = 0 ] || { echo "W8 gh $(gh_n) rec $(rec_n)"; return 1; }
  [ "$(dedupes)" = "lead-review:7801@${b:0:12} " ] || { echo "W8 dedupes '$(dedupes)'"; return 1; }
}
case_W9() { # record, a record hit on a draft: no ring, no GitHub read
  fresh; export GH_SOURCE=record
  rec 7901 '"open"' 1 "\"$(head40 ec0 7901)\"" 30
  wakes "$(W 1 $BH pr 7901 pull_request.opened)"
  run_as $BOX
  [ "$(gh_all)" = 0 ] && [ "$(lanes_n)" = 0 ] || { echo "W9 gh $(gh_all) rings $(lanes_n)"; return 1; }
}

check() { local out; if out=$("$1" 2>&1); then ok; else bad "$1 — $out"; fi; unset GH_SOURCE; }
for c in S1 S2 S3 S4 S5 S6 S7 S8 S9 S10 S11 W1 W2 W3 W3b W4 W5 W6 W7 W8 W9; do check "case_$c"; done

# ── D1: mutate the installed seam, and the case that pins it must go red ────
SEAM_SRC="$DIR/bin/lib/prr-shadow.d/wake-loop.sh"
mutant() { # mutant <name> <case> <sed-expr>
  if [ ! -f "$SEAM_SRC" ] || cmp -s <(sed -e "$3" "$SEAM_SRC") "$SEAM_SRC"; then
    bad "$1: the sed did not change the seam (the mutation point moved)"; return
  fi
  SEAM_SED="$3"
  if "$2" >/dev/null 2>&1; then bad "$1: $2 stayed GREEN on the mutant"; else ok; fi
  SEAM_SED=""; unset GH_SOURCE
}
# M1: the record skips its age check.
mutant M1 case_W4 's/-gt "\$max"/-gt 999999999/'
# M2: the record takes any draft value.
mutant M2 case_S3 's/(\.draft | type) == "boolean" or \.draft == 0 or \.draft == 1/true/'

echo "wake-pr-lead-record (BH-9938): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
