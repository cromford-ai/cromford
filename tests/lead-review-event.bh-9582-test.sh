#!/bin/bash
# tests/lead-review-event.bh-9582-test.sh — the lead review is asked for on the
# PR event, not on the */15 cron (BH-9582 part C, slice C0 of #9582).
#
# A `pr` wake whose event is pull_request.opened, .reopened, .ready_for_review
# or .synchronize makes bin/lib/wake-class-pr-lead.sh read the PR once on
# GitHub and ring `lcw_ring lead-review <slug> <n> <head>` on the box that owns
# the repo. The next drain claims that lane row and launches
# bin/lead-review.sh tick. The class is on with no `wake-lanes-pr-lead` flag
# (the default-on arm in bin/wake-loop.sh's CLASS_ON loop).
#
# Drives the REAL bin/wake-loop.sh, the REAL class, the REAL
# bin/lib/lead-chain-wake.sh and the REAL jobs client on the
# tests/lib/wake-claim-stub.sh worker (the fixture of
# tests/wake-loop-lead-chain.bh-4057-test.sh). On top of that worker, this
# suite's curl answers:
#   POST /api/wakes/lane       logged to $T/lane.log; the row is added to the
#                              wakes table, so the next drain claims it.
#                              $T/LANE_MODE=500 answers HTTP 500.
#   GET  /api/settings[/key]   from $T/settings.json (operator rows).
# `gh` is a PATH fake: `gh api -i -X GET repos/<o>/<r>/pulls/<n>` answers from
# $T/gh/<o>_<r>_<n>, lowercased (HTTP header + body) and logs argv to $T/gh.log. No file =
# exit 1 with no output (a failed read). bin/lead-review.sh is a recorder.
#
# The stubbed fleet: cromford, board and harness-console ->
# box-small; project-3 -> box-project-3-1; project-1 -> local.
# The hub is box-hub. LEAD_REVIEW_AUTO_REPOS lists cromford,
# project-3 and project-1 only.
#
# Each case uses its own PR numbers and heads; fresh() wipes all state.
# M1-M3 at the end are the D1 self-check.
#
# Run from anywhere: HARNESS_TEST_SANDBOX=1 bash tests/lead-review-event.bh-9582-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/wake-claim-stub.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

H="$T/h"
export HARNESS="$H" WAKE_LOOP_CYCLES=1 WAKE_LOOP_INTERVAL_S=0 GH_ETAG=0
unset WAKE_CLAIM_LIMIT HUB_BOX_NAME CLAIM_ALL COOL_MODE CLAIM_MODE CURSOR_PUT_MODE CURSOR_GET_MODE \
  LEAD_REVIEW_AUTO_REPOS LEAD_REVIEW_WORKLIST
LOOP_SRC="$DIR/bin/wake-loop.sh"
CLASS_SRC="$DIR/bin/lib/wake-class-pr-lead.sh"
CLASS_SED=""
LANES="merge-conductor deploy-train postmerge-qa run-triage review-prs rebase-train lead-review-land"

fresh() {
  scratch_rm "$H"
  mkdir -p "$H/bin/lib/jobs" "$H/env" "$H/logs" "$H/locks" "$H/state/wcs" "$H/flags" "$H/calls"
  rm -rf "$T/gh"; mkdir -p "$T/gh"
  : > "$T/gh.log"; : > "$T/lane.log"; rm -f "$T/LANE_MODE"
  printf '{"settings":[]}' > "$T/settings.json"
  printf 'HARNESS_SECRET=s\nJOBS_URL=https://jobs.test\nLEAD_REVIEW_AUTO_REPOS="example-org/cromford example-org/project-3 example-org/project-1"\n' \
    > "$H/env/global.env"
  scratch_install_closure bin/wake-loop.sh "$H" >/dev/null \
    || { echo "FAIL: scratch_install_closure bin/wake-loop.sh"; exit 1; }
  scratch_install_closure bin/jobs-client.sh "$H" >/dev/null \
    || { echo "FAIL: scratch_install_closure bin/jobs-client.sh"; exit 1; }
  # The closure above installs the real class and bin/lib/lead-chain-wake.sh.
  # An M* class mutant edits that installed copy in place.
  [ -n "$CLASS_SED" ] && sed -i -e "$CLASS_SED" "$H/bin/lib/wake-class-pr-lead.sh"
  cp "$LOOP_SRC" "$H/bin/wake-loop.sh"
  wcs_install "$H/bin"
  wcs_identity "$H/bin" || { echo "wcs_identity failed"; exit 1; }
  # This suite's curl: the wake routes first, then the lane doorbell and the
  # settings rows, then `{}` 200 for everything else.
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
    printf '%s\n' "$body" >> "$T9582/lane.log"
    [ "$(cat "$T9582/LANE_MODE" 2>/dev/null)" = 500 ] && { printf '{"error":"stub"}\n500'; exit 0; }
    W="${WCS_WAKES:?}"
    jq -c --argjson b "$body" '.wakes += [{id: (((.wakes | map(.id) | max) // 0) + 1),
        repo: $b.repo, kind: $b.kind, key: ($b.key | tostring), event: ("lane:" + $b.kind),
        at: "2026-11-14T03:00:00Z"}]' "$W" > "$W.tmp" && mv "$W.tmp" "$W"
    printf '{"ok":true}\n200' ;;
  "GET /api/settings")
    cat "$T9582/settings.json"; printf '\n200' ;;
  "GET /api/settings/"*)
    k="${path#/api/settings/}"
    v=$(jq -r --arg k "$k" '.settings[] | select(.key == $k) | .value' "$T9582/settings.json")
    if [ -n "$v" ]; then jq -nc --arg k "$k" --arg v "$v" '{setting:{key:$k,value:$v}}'; printf '\n200'
    else printf '{"error":"not found"}\n404'; fi ;;
  *) printf '{}\n200' ;;
esac
SH
  cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
[ "$1" = "--projects" ] && { printf 'project-3\ncromford\nproject-1\nboard\nharness-console\n'; exit 0; }
case "$1/$2" in
  project-3/repo)         echo example-org/project-3 ;;
  cromford/repo)   echo example-org/cromford ;;
  project-1/repo)     echo example-org/project-1 ;;
  board/repo)           echo example-org/board ;;
  harness-console/repo) echo example-org/cromford-console ;;
  project-3/box)          echo box-project-3-1 ;;
  cromford/box|board/box|harness-console/box) echo box-small ;;
  project-1/box)      echo local ;;
  */board_prefix)       echo /api/board ;;
  *) exit 1 ;;
esac
SH
  for s in $LANES; do
    printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/%s"\n' "$s" > "$H/bin/$s.sh"
  done
  printf '#!/bin/bash\necho "$*" >> "$HARNESS/calls/lead-review"\n' > "$H/bin/lead-review.sh"
  # The GitHub fake: one file per PR, argv logged.
  cat > "$H/bin/gh" <<'SH'
#!/bin/bash
echo "$*" >> "$T9582/gh.log"
p=""
for a in "$@"; do case "$a" in repos/*/pulls/*) p="$a" ;; esac; done
[ -n "$p" ] || { echo "[]"; exit 0; }
f="$T9582/gh/$(printf '%s' "${p#repos/}" | tr 'A-Z' 'a-z' | sed 's|/pulls/|_|; s|/|_|g')"
[ -r "$f" ] || exit 1
cat "$f"
SH
  printf '#!/bin/bash\nexit 1\n' > "$H/bin/unblocked-children.sh"
  printf '#!/bin/bash\nexec "$@"\n' > "$H/bin/setsid"
  chmod +x "$H/bin/"*.sh "$H/bin/gh" "$H/bin/setsid" "$H/bin/curl"
  : > "$T/wakes.json"
}
export T9582="$T"
export WCS_WAKES="$T/wakes.json"
export PATH="$H/bin:$PATH"

wakes() { printf '{"wakes":[%s]}' "$(printf '%s,' "$@" | sed 's/,$//')" > "$T/wakes.json"; }
W() { # W <id> <repo> <kind> <key> <event>
  printf '{"id":%s,"repo":"%s","kind":"%s","key":"%s","event":"%s","at":"2026-11-14T03:00:00Z"}' \
    "$1" "$2" "$3" "$4" "$5"
}
# head <prefix> <n>: a 40-hex head unique to the PR and the case.
head40() { printf '%s%037d' "$1" "$2"; }
# pr <owner_repo> <n> <state> <draft> <head>: the GitHub answer for one PR.
pr() {
  printf 'HTTP/2.0 200 OK\r\nContent-Type: application/json\r\n\r\n{"number":%s,"state":"%s","draft":%s,"head":{"sha":"%s"}}\n' \
    "$2" "$3" "$4" "$5" > "$T/gh/$(printf '%s' "$1" | tr 'A-Z' 'a-z')_$2"
}
setting() { # setting <key> <value>
  jq -c --arg k "$1" --arg v "$2" '.settings += [{key:$k,value:$v,actor:"operator",note:""}]' "$T/settings.json" > "$T/s.tmp" \
    && mv "$T/s.tmp" "$T/settings.json"
}
settle() {
  local prev="" cur i
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    sleep 0.25
    cur=$(cat "$H/calls/"* 2>/dev/null | wc -c | tr -d ' ')
    [ "$cur" = "$prev" ] && [ "$i" -ge 3 ] && return 0
    prev="$cur"
  done
}
run_as() { BOX_NAME="$1" "$H/bin/wake-loop.sh"; RC=$?; settle; return "$RC"; }
calls() { if [ -f "$H/calls/$1" ]; then wc -l < "$H/calls/$1" | tr -d " "; else echo 0; fi; }
LOG() { cat "$H/logs/wake-loop.log" 2>/dev/null; }
REQ() { wcs_log; }
lanes_n() { grep -c . "$T/lane.log" 2>/dev/null || true; }
gh_n() { grep -c 'pulls/' "$T/gh.log" 2>/dev/null || true; }
no_ring() { # no_ring <case>: no lane POST at all
  [ "$(lanes_n)" = 0 ] || { echo "$1 rang: $(cat "$T/lane.log") log: $(LOG)"; return 1; }
}
no_gh() {
  [ "$(gh_n)" = 0 ] || { echo "$1 read GitHub: $(cat "$T/gh.log")"; return 1; }
}

project-3=example-org/project-3 BH=example-org/cromford MOM=example-org/project-1
BOX=box-small

case_E1() { # opened, no class flag, no settings row: one ring this drain, the tick next drain
  local h b
  fresh; h=$(head40 abc 4242); pr example-org_cromford 4242 open false "$h"
  wakes "$(W 1 $BH pr 4242 pull_request.opened)"
  run_as $BOX || { echo "E1 loop rc $RC: $(LOG)"; return 1; }
  [ "$(lanes_n)" = 1 ] || { echo "E1 lane POSTs: $(lanes_n): $(cat "$T/lane.log") log: $(LOG)"; return 1; }
  b=$(head -1 "$T/lane.log")
  [ "$(jq -r .kind <<<"$b")" = lead-review ] && [ "$(jq -r .key <<<"$b")" = 4242 ] \
    && [ "$(jq -r .dedupe <<<"$b")" = "lead-review:4242@${h:0:12}" ] \
    && [ "$(jq -r .repo <<<"$b")" = example-org/cromford ] || { echo "E1 lane body: $b"; return 1; }
  LOG | grep -qF "pr-lead: example-org/cromford#4242 @${h:0:12}: lead-review doorbell rung" \
    || { echo "E1 no rung line: $(LOG)"; return 1; }
  LOG | grep 'wake classes armed:' | grep -qw 'pr-lead' || { echo "E1 armed line: $(LOG | grep armed)"; return 1; }
  [ "$(calls lead-review)" = 0 ] || { echo "E1 lead-review ran in drain 1: $(cat "$H/calls/lead-review")"; return 1; }
  run_as $BOX || { echo "E1 drain 2 rc $RC"; return 1; }
  [ "$(cat "$H/calls/lead-review" 2>/dev/null)" = tick ] || { echo "E1 drain 2 lead-review calls: $(calls lead-review): $(LOG)"; return 1; }
  [ "$(lanes_n)" = 1 ] || { echo "E1 drain 2 rang again: $(cat "$T/lane.log")"; return 1; }
}
case_E2() { # synchronize H1 then synchronize H2: two rows, two dedupes
  local h1 h2 d
  fresh; h1=$(head40 abc 4243); h2=$(head40 def 4243)
  pr example-org_cromford 4243 open false "$h1"
  wakes "$(W 1 $BH pr 4243 pull_request.synchronize)"
  run_as $BOX
  pr example-org_cromford 4243 open false "$h2"
  jq -c --argjson r "$(W 10 $BH pr 4243 pull_request.synchronize)" '.wakes += [$r]' "$T/wakes.json" > "$T/w.tmp" && mv "$T/w.tmp" "$T/wakes.json"
  run_as $BOX
  d=$(jq -r 'select(.kind == "lead-review") | .dedupe' "$T/lane.log" | sort | tr '\n' ' ')
  [ "$d" = "lead-review:4243@${h1:0:12} lead-review:4243@${h2:0:12} " ] || { echo "E2 dedupes: '$d' log: $(LOG)"; return 1; }
}
case_E3() { # reopened and ready_for_review each ring once; a repo whose case differs from the list rings
  fresh
  pr example-org_cromford 4244 open false "$(head40 abc 4244)"
  pr example-org_cromford 4245 open false "$(head40 abc 4245)"
  wakes "$(W 1 $BH pr 4244 pull_request.reopened)" "$(W 2 example-org/Cromford pr 4245 pull_request.ready_for_review)"
  run_as $BOX
  [ "$(lanes_n)" = 2 ] || { echo "E3 lane POSTs $(lanes_n): $(cat "$T/lane.log") log: $(LOG)"; return 1; }
  [ "$(jq -r .key "$T/lane.log" | sort | tr '\n' ' ')" = "4244 4245 " ] || { echo "E3 keys: $(cat "$T/lane.log")"; return 1; }
}
case_E4() { # closed, labeled, enqueued, a review, a comment: no read, no ring
  local n
  fresh
  for n in 4246 4247 4248 4249 4250; do pr example-org_cromford $n open false "$(head40 abc $n)"; done
  wakes "$(W 1 $BH pr 4246 pull_request.closed)" "$(W 2 $BH pr 4247 pull_request.labeled)" \
        "$(W 3 $BH pr 4248 pull_request.enqueued)" "$(W 4 $BH pr 4249 pull_request_review.submitted)" \
        "$(W 5 $BH pr 4250 issue_comment.created)"
  run_as $BOX
  REQ | grep -q '^PUT /api/wakes/cursor .*"cursor":5' || { echo "E4 drain did not run: $(REQ)"; return 1; }
  no_gh E4 && no_ring E4
}
case_E5() { # a draft opened, a synchronize GitHub answers closed: read, no ring
  fresh
  pr example-org_cromford 4251 open true "$(head40 abc 4251)"
  pr example-org_cromford 4252 closed false "$(head40 abc 4252)"
  wakes "$(W 1 $BH pr 4251 pull_request.opened)" "$(W 2 $BH pr 4252 pull_request.synchronize)"
  run_as $BOX
  [ "$(gh_n)" = 2 ] || { echo "E5 gh reads $(gh_n): $(cat "$T/gh.log")"; return 1; }
  no_ring E5
}
case_E6() { # an owned repo that is a prefix of a listed one, and one the list does not name
  fresh
  pr example-org_board 4253 open false "$(head40 abc 4253)"
  pr example-org_cromford-console 4254 open false "$(head40 abc 4254)"
  wakes "$(W 1 example-org/board pr 4253 pull_request.opened)" "$(W 2 example-org/cromford-console pr 4254 pull_request.opened)"
  run_as $BOX
  REQ | grep -q '^PUT /api/wakes/cursor .*"cursor":2' || { echo "E6 drain did not run: $(REQ) log: $(LOG)"; return 1; }
  no_gh E6 && no_ring E6
}
case_E7() { # the kill row 0: no read, no ring, one off line
  fresh; setting lead_review.event_wake.enabled 0
  pr example-org_cromford 4255 open false "$(head40 abc 4255)"
  wakes "$(W 1 $BH pr 4255 pull_request.opened)"
  run_as $BOX
  no_gh E7 && no_ring E7 || return 1
  [ "$(LOG | grep -c 'pr-lead: off (lead_review.event_wake.enabled=0)')" = 1 ] || { echo "E7 log: $(LOG)"; return 1; }
}
case_E8() { # flags/lead-chain-wake-off: no read, no ring
  fresh; touch "$H/flags/lead-chain-wake-off"
  pr example-org_cromford 4256 open false "$(head40 abc 4256)"
  wakes "$(W 1 $BH pr 4256 pull_request.opened)"
  run_as $BOX
  no_gh E8 && no_ring E8 || return 1
  LOG | grep -q 'pr-lead: off (lead-chain-wake-off)' || { echo "E8 log: $(LOG)"; return 1; }
}
case_E9() { # the worker refuses the ring: the not-rung line, the loop still exits 0 and moves its cursor
  local h
  fresh; echo 500 > "$T/LANE_MODE"; h=$(head40 abc 4257)
  pr example-org_cromford 4257 open false "$h"
  wakes "$(W 7 $BH pr 4257 pull_request.opened)"
  run_as $BOX || { echo "E9 loop rc $RC"; return 1; }
  [ "$(lanes_n)" = 1 ] || { echo "E9 lane POSTs $(lanes_n)"; return 1; }
  LOG | grep -qF "pr-lead: example-org/cromford#4257 @${h:0:12}: doorbell not rung (rc 2); the */15 cron covers it" \
    || { echo "E9 log: $(LOG)"; return 1; }
  ! grep -q 'doorbell rung' <<<"$(LOG)" || { echo "E9 claimed rung: $(LOG)"; return 1; }
  REQ | grep -q '^PUT /api/wakes/cursor {"box":"box-small","cursor":7}' || { echo "E9 cursor: $(REQ)"; return 1; }
}
case_E10() { # the GitHub read fails: one line, no ring
  fresh
  wakes "$(W 1 $BH pr 4258 pull_request.opened)"
  run_as $BOX
  [ "$(gh_n)" = 1 ] || { echo "E10 gh reads $(gh_n)"; return 1; }
  no_ring E10 || return 1
  LOG | grep -qF 'pr-lead: example-org/cromford#4258: PR read failed; the */15 cron covers it' || { echo "E10 log: $(LOG)"; return 1; }
}
case_E11() { # reads_max=2, three PRs (one twice): two reads, two rings, one cap line
  local n
  fresh; setting lead_review.event_wake.reads_max 2
  for n in 4260 4261 4262; do pr example-org_cromford $n open false "$(head40 abc $n)"; done
  wakes "$(W 1 $BH pr 4260 pull_request.opened)" "$(W 2 $BH pr 4260 pull_request.synchronize)" \
        "$(W 3 $BH pr 4261 pull_request.opened)" "$(W 4 $BH pr 4262 pull_request.opened)"
  run_as $BOX
  [ "$(gh_n)" = 2 ] || { echo "E11 gh reads $(gh_n): $(cat "$T/gh.log")"; return 1; }
  [ "$(lanes_n)" = 2 ] || { echo "E11 lane POSTs $(lanes_n)"; return 1; }
  [ "$(LOG | grep -c 'pr-lead: 1 PR(s) over the read cap of 2; the \*/15 cron covers them')" = 1 ] || { echo "E11 log: $(LOG)"; return 1; }
}
case_E12() { # the hub, handed a pr row of a repo it does not own: no read, no ring, the conductor still runs
  fresh
  pr example-org_project-3 4263 open false "$(head40 abc 4263)"
  wakes "$(W 1 $project-3 pr 4263 pull_request.opened)"
  run_as box-hub
  no_gh E12 && no_ring E12 || return 1
  [ "$(calls merge-conductor)" -ge 1 ] || { echo "E12 conductor not launched: $(LOG)"; return 1; }
}
case_E13() { # flags/wake-lanes-off beats the default-on arm
  fresh; touch "$H/flags/wake-lanes-off"
  pr example-org_cromford 4264 open false "$(head40 abc 4264)"
  wakes "$(W 1 $BH pr 4264 pull_request.opened)"
  run_as $BOX
  REQ | grep -q '^PUT /api/wakes/cursor .*"cursor":1' || { echo "E13 drain did not run: $(REQ)"; return 1; }
  ! grep -qw pr-lead <<<"$(LOG | grep 'wake classes armed:')" || { echo "E13 armed: $(LOG | grep armed)"; return 1; }
  no_gh E13 && no_ring E13
}
case_E14() { # a class with no _default_on and no flag stays off; pr-lead is on in the same run
  fresh
  cat > "$H/bin/lib/wake-class-zz-probe.sh" <<'SH'
wc_zz_probe_row() { echo "$2 $3" >> "$HARNESS/calls/zz-probe"; }
SH
  pr example-org_cromford 4265 open false "$(head40 abc 4265)"
  wakes "$(W 1 $BH pr 4265 pull_request.opened)"
  run_as $BOX
  [ "$(calls zz-probe)" = 0 ] || { echo "E14 the unarmed class ran: $(cat "$H/calls/zz-probe")"; return 1; }
  [ "$(lanes_n)" = 1 ] || { echo "E14 pr-lead did not ring: $(LOG)"; return 1; }
  ! grep -qw zz-probe <<<"$(LOG | grep 'wake classes armed:')" || { echo "E14 armed: $(LOG | grep armed)"; return 1; }
}
case_E15() { # the hub, handed a pr row of a repo it owns: the hub runs no lead review, so no read, no ring
  fresh
  pr example-org_project-1 4266 open false "$(head40 abc 4266)"
  wakes "$(W 1 $MOM pr 4266 pull_request.opened)"
  run_as box-hub
  REQ | grep -q '^PUT /api/wakes/cursor .*"cursor":1' || { echo "E15 drain did not run: $(REQ)"; return 1; }
  no_gh E15 && no_ring E15
}

check() { local out; if out=$("$1" 2>&1); then ok; else bad "$1 — $out"; fi; }
for c in E1 E2 E3 E4 E5 E6 E7 E8 E9 E10 E11 E12 E13 E14 E15; do check "case_$c"; done

# ── D1: mutate a copy, and the case that pins the behaviour must go red ─────
MUT="$T/mutant.sh"
mutant() { # mutant <name> <case> <loop|class> <sed-expr>
  local src="$LOOP_SRC"
  [ "$3" = class ] && src="$CLASS_SRC"
  [ -f "$src" ] || { bad "$1: no $src to mutate"; return; }
  sed -e "$4" "$src" > "$MUT"
  if cmp -s "$MUT" "$src"; then bad "$1: the sed did not change $src (the mutation point moved)"; return; fi
  if [ "$3" = class ]; then CLASS_SED="$4"; else LOOP_SRC="$MUT"; fi
  if "$2" >/dev/null 2>&1; then bad "$1: $2 stayed GREEN on the mutant"; else ok; fi
  CLASS_SED=""; LOOP_SRC="$DIR/bin/wake-loop.sh"
}
# M1: the class's event filter takes any pull_request.* event.
mutant M1 case_E4 class 's/pull_request\.opened|pull_request\.reopened|pull_request\.ready_for_review|pull_request\.synchronize)/pull_request.*|pull_request_review.*|issue_comment.*)/'
# M2: the loop loses its default-on arm.
mutant M2 case_E1 loop 's/_default_on"/_default_none"/'
# M3: the class forgets that the hub runs no lead review.
mutant M3 case_E15 class 's/\[ "\${IS_HUB:-0}" = 1 \] \&\& return 0/:/'

echo "lead-review-event (BH-9582): $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
