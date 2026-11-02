#!/bin/bash
# tests/unblock-lifecycle.bh-8736-test.sh — BH-8736 (lifecycle 6/6): the
# Tackler reads stuck tickets from the ticket ledger and acts once per episode.
#
# Drives the SHIPPED code: the collector bin/lib/unblock/collectors/lifecycle.sh,
# the rules engine over the shipped catalog/unblock-rules.d, act.sh's ub_act,
# bin/unblock.sh tick and bin/unblock-reply.sh intercept, and bin/stuck-work.sh.
# #8731's bin/lib/jobs/lifecycle.sh calls the real worker: each scratch tree gets
# a stub of it with the #8731 contract (lifecycle_stuck <p> = GET
# /api/lifecycle/stuck; lifecycle_transition <p> <key> <to> <actor> <reason>
# [pr] = POST /api/lifecycle/transition; the _jobs_req rc: 0 2xx, 9 409 with
# {current}, 2 404, 1 else). The worker is a fake _jobs_req (or a fake curl for
# the reply script), GitHub a fake gh_rest / gh. Every case seeds its own keys.
#
#   C1-C6  the collector: kinds, fields, unknown, the row cap, its reads
#   R1-R6  the U14 rules over the collector's records (and their negatives)
#   A1-A10 act.sh: rebuild, ask, requeue with a ticket_key, no lib
#   T1-T4  bin/unblock.sh tick: claims, once per episode, the card record; C2
#          tick line (failed=1 without the lib)
#   P1-P6  bin/unblock-reply.sh: a U14-ASK answer moves the ticket to planned
#   W1-W2  bin/stuck-work.sh: the ticket facts are retired by default
#   B1     0 vendor calls: curl, gh, flyctl and claude on PATH log to net.log
#
# MUTATIONS (D1), each tried once by hand: drop the phase filter in the
# collector -> C1 red; `.abandons <= .rebuild_max + 1` -> R4 red; the rebuild
# arm launches before the transition -> A1 and A3 red; ignore lane-alert's rc
# in ask -> A7 red; drop UB_ACT_CARD from ubt_record -> T3 and P1 red; drop the
# 4b block in unblock-reply.sh -> P1 red; the stuck-work gate always on -> W1
# red; requeue without the phase write -> A8 red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-lifecycle.bh-8736-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 && command -v flock >/dev/null 2>&1 || { echo "SKIP: jq or flock missing"; exit 0; }

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "${2:0:1500}"; return 0; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want '$3' got '$2'"; fi; }
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }

R=example-org/cromford
P=cromford
NOW=1793188800          # 2026-10-28T12:00:00Z
export UB_NOW=$NOW
RULES="$SRC/catalog/unblock-rules.d"

# ── B1: the vendor guard. Every section runs with it first on PATH. ──────────
FB="$T/netguard"; mkdir -p "$FB"
for b in curl gh flyctl claude; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$b" "$T" > "$FB/$b"
  chmod +x "$FB/$b"
done
: > "$T/net.log"
budget() { check "B1 $1: 0 vendor calls (net.log)" "$(cnt . "$T/net.log")" 0; }

# ── the #8731 lib stub, the fake worker and the fake GitHub ──────────────────
cat > "$T/lifecycle-stub.sh" <<'SH'
# stub of bin/lib/jobs/lifecycle.sh (#8731 contract), over _jobs_req
lifecycle_stuck() { _jobs_req GET "/api/lifecycle/stuck?project=$1"; }
lifecycle_transition() {
  local b
  b=$(jq -nc --arg p "$1" --arg k "$2" --arg t "$3" --arg a "$4" --arg r "$5" --arg pr "${6:-}" \
    '{project: $p, ticket_key: $k, to_phase: $t, actor: $a, reason: $r} + (if $pr == "" then {} else {pr: ($pr | tonumber)} end)')
  _jobs_req POST /api/lifecycle/transition "$b"
}
SH
# The fake worker (a shell function the code under test calls as _jobs_req).
cat > "$T/fakejobs.sh" <<'SH'
_jobs_req() {
  local k n rc
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$FXT/jobs.log"
  case "$1 $2" in
    "GET /api/lifecycle/stuck"*)
      [ -f "$FXT/stuck.rc" ] && return "$(cat "$FXT/stuck.rc")"
      cat "$FXT/stuck.json"; return 0 ;;
    "GET /api/lifecycle/history"*)
      k="${2##*ticket_key=}"
      [ -f "$FXT/history.fail.$k" ] && return 1
      jq -c --arg k "$k" '{events: (.[$k] // [])}' "$FXT/history.json"; return 0 ;;
    "POST /api/lifecycle/transition")
      echo "$3" >> "$FXT/transitions.log"; echo TRANSITION >> "$FXT/order.log"
      rc=$(cat "$FXT/transition.rc" 2>/dev/null || echo 0)
      case "$rc" in
        0) printf '{"ok":true,"phase":"%s"}' "$(jq -r .to_phase <<<"$3")" ;;
        9) printf '{"error":"phase","current":"%s"}' "$(cat "$FXT/transition.current")" ;;
      esac
      return "$rc" ;;
    "POST /api/unblock/decisions/claim")
      k=$(jq -r .decision_key <<<"$3"); mkdir -p "$FXT/seen"
      echo "$3" >> "$FXT/claims.log"
      if [ -f "$FXT/seen/$k" ]; then printf '{"claimed":false,"id":%s,"outcome":"done"}' "$(cat "$FXT/seen/$k")"; return 9; fi
      n=$(( $(cat "$FXT/id.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$FXT/id.n"; echo "$n" > "$FXT/seen/$k"
      printf '{"claimed":true,"id":%s}' "$n"; return 0 ;;
    "POST /api/unblock/decisions/record") echo "$3" >> "$FXT/records.log"; printf '{"ok":true}'; return 0 ;;
  esac
  return 1
}
gh_rest() {
  local n
  echo "$1 $2" >> "$FXT/ghrest.log"
  n="${2##*/}"
  [ -f "$FXT/pull.fail.$n" ] && return 1
  jq -ec --arg n "$n" '.[$n]' "$FXT/pulls.json" 2>/dev/null || return 1
}
SH

# seed <dir> — a fresh fake-worker state with the shared stuck answer.
H40() { printf '%s' "$1$1$1$1$1$1$1$1$1$1" | cut -c1-40; }
seed() {
  local F="$1"
  scratch_rm "$F" || exit 1
  mkdir -p "$F"
  jq -nc '{rows: [
    {project: "cromford", ticket_key: "BH-9101", phase: "ejected",      phase_at: "2026-10-28T08:01:00Z", age_min: 239, threshold_min: 60,   phase_actor: "merge-queue"},
    {project: "cromford", ticket_key: "BH-9102", phase: "ejected",      phase_at: "2026-10-28T08:02:00Z", age_min: 238, threshold_min: 60,   phase_actor: "merge-queue"},
    {project: "cromford", ticket_key: "BH-9103", phase: "ejected",      phase_at: "2026-10-28T08:03:00Z", age_min: 237, threshold_min: 60,   phase_actor: "merge-queue"},
    {project: "cromford", ticket_key: "BH-9104", phase: "ejected",      phase_at: "2026-10-28T08:04:00Z", age_min: 236, threshold_min: 60,   phase_actor: "merge-queue"},
    {project: "cromford", ticket_key: "BH-9105", phase: "abandoned",    phase_at: "2026-10-28T08:05:00Z", age_min: 235, threshold_min: 60,   phase_actor: "blocked-resolver"},
    {project: "cromford", ticket_key: "BH-9106", phase: "abandoned",    phase_at: "2026-10-28T08:06:00Z", age_min: 234, threshold_min: 60,   phase_actor: "blocked-resolver"},
    {project: "cromford", ticket_key: "BH-9107", phase: "plan_blocked", phase_at: "2026-10-27T08:07:00Z", age_min: 1673, threshold_min: 1440, phase_actor: "plan", question: "Which fee field does the rep set?"},
    {project: "cromford", ticket_key: "BH-9108", phase: "plan_blocked", phase_at: "2026-10-27T08:08:00Z", age_min: 1672, threshold_min: 1440, phase_actor: "plan", question: null},
    {project: "cromford", ticket_key: "BH-9109", phase: "plan_blocked", phase_at: "2026-10-27T08:09:00Z", age_min: 1671, threshold_min: 1440, phase_actor: "plan", question: ""},
    {project: "cromford", ticket_key: "BH-9110", phase: "building",     phase_at: "2026-10-28T06:10:00Z", age_min: 350, threshold_min: 120,  phase_actor: "pool"}]}' > "$F/stuck.json"
  jq -nc '{
    "BH-9101": [{id: 1, to_phase: "pr_open", pr: 9101}, {id: 2, to_phase: "ejected", pr: null}],
    "BH-9102": [{id: 3, to_phase: "pr_open", pr: 9102}, {id: 4, to_phase: "ejected"}],
    "BH-9103": [{id: 5, to_phase: "pr_open", pr: 9103}, {id: 6, to_phase: "ejected"}],
    "BH-9104": [{id: 7, to_phase: "building"}, {id: 8, to_phase: "ejected"}],
    "BH-9105": [{id: 9, to_phase: "building"}, {id: 10, to_phase: "abandoned"}],
    "BH-9106": [{id: 11, to_phase: "abandoned"}, {id: 12, to_phase: "planned", actor: "lifecycle"}, {id: 13, to_phase: "abandoned"}]}' > "$F/history.json"
  jq -nc --arg a "$(H40 9101aaaa)" --arg b "$(H40 9102bbbb)" --arg c "$(H40 9103cccc)" '{
    "9101": {number: 9101, state: "open", merged: false, head: {sha: $a}, labels: [{name: "merge-queue"}, {name: "ai-build"}]},
    "9102": {number: 9102, state: "closed", merged: false, head: {sha: $b}, labels: []},
    "9103": {number: 9103, state: "closed", merged: true, head: {sha: $c}, labels: []}}' > "$F/pulls.json"
}
# collect <fx dir> [env...] — the shipped collector, in a subshell. stdout =
# the inner function's lines (records + meta); rc in <fx>/rc.
collect() {
  local F="$1"; shift
  mkdir -p "$F/tmp"
  ( env TMPDIR="$F/tmp" "$@" bash -c '
      . "$1/fakejobs.sh"; [ -f "$1/nolib" ] || . "$1/lifecycle-stub.sh"
      . "$2/bin/lib/unblock/collectors/lifecycle.sh"
      unblock_collect_lifecycle cromford example-org/cromford' _ "$T" "$SRC" ) > "$F/out.jsonl" 2> "$F/err"
  echo $? > "$F/rc"
}
rec_of() { jq -c --arg k "$2" 'select(.ticket_key == $k)' "$1/out.jsonl"; }
field() { rec_of "$1" "$2" | jq -c "$3"; }
export HARNESS="$T/hc"; mkdir -p "$HARNESS/logs"
OLDPATH=$PATH
export PATH="$FB:$OLDPATH"

# ═════ C: the collector ══════════════════════════════════════════════════════
F="$T/c1"; seed "$F"; export FXT="$F"
collect "$F"
check "C1 rc 0" "$(cat "$F/rc")" 0
check "C1 9 records (building filtered) + 1 meta" "$(jq -s 'map(select(.kind != "collector-meta")) | length' "$F/out.jsonl") $(tail -n1 "$F/out.jsonl" | jq -r .kind)" "9 collector-meta"
check "C1 kinds by phase" "$(jq -rs 'map(select(.kind != "collector-meta")) | map(.kind) | unique | join(",")' "$F/out.jsonl")" "ticket-abandoned,ticket-ejected,ticket-plan-blocked"
check "C1 building BH-9110 gives no record" "$(rec_of "$F" BH-9110)" ""
check "C1 BH-9101 fields" "$(field "$F" BH-9101 '[.family, .subject_kind, .subject, .episode, .stall_at, .pr, .head[0:8], .pr_state, .merged, .labels, .unknown]')" \
  '["lifecycle","build","cromford:BH-9101","2026-10-28T08:01:00Z","2026-10-28T08:01:00Z",9101,"9101aaaa","open",false,["merge-queue","ai-build"],[]]'
check "C1 BH-9107 carries the stored question" "$(field "$F" BH-9107 '[.question, .age_min, .threshold_min, .rebuild_max]')" '["Which fee field does the rep set?",1673,1440,1]'
check "C1 BH-9106 abandons 2, BH-9105 abandons 1" "$(field "$F" BH-9106 .abandons) $(field "$F" BH-9105 .abandons)" "2 1"
check "C1 meta rows_seen 9, truncated 0" "$(tail -n1 "$F/out.jsonl" | jq -c '[.rows_seen, .truncated, .unreadable]')" '[9,0,[]]'
# C6: its reads
check "C6 worker requests: 1 stuck + 6 history, nothing else" \
  "$(grep -c '^GET /api/lifecycle/stuck?project=cromford ' "$F/jobs.log") $(grep -c '^GET /api/lifecycle/history?project=cromford&ticket_key=BH-91' "$F/jobs.log") $(wc -l < "$F/jobs.log" | tr -d ' ')" "1 6 7"
check "C6 GitHub reads: pulls/9101 9102 9103 only" "$(sort "$F/ghrest.log" | tr '\n' ' ')" \
  "GET repos/example-org/cromford/pulls/9101 GET repos/example-org/cromford/pulls/9102 GET repos/example-org/cromford/pulls/9103 "
# the contract entry drops the meta line
E=$( env FXT="$F" bash -c '. "$1/fakejobs.sh"; . "$1/lifecycle-stub.sh"; . "$2/bin/lib/unblock/collectors/lifecycle.sh"; ub_collect_lifecycle cromford example-org/cromford' _ "$T" "$SRC" | jq -rs 'map(.kind) | [length, (map(select(. == "collector-meta")) | length)] | @tsv' )
check "C1 ub_collect_lifecycle: 9 records, 0 meta" "$E" $'9\t0'
cp "$F/out.jsonl" "$T/c1-records.jsonl"

F="$T/c2"; seed "$F"; export FXT="$F"; echo 1 > "$F/stuck.rc"
collect "$F"
check "C2 stuck read rc 1: collector rc 1, 0 records" "$(cat "$F/rc") $(grep -c . "$F/out.jsonl")" "1 0"
rm -f "$F/stuck.rc"; echo '{"error":"x"}' > "$F/stuck.json"
collect "$F"
check "C2 stuck answer with no rows array: rc 1, 0 records" "$(cat "$F/rc") $(grep -c . "$F/out.jsonl")" "1 0"
seed "$F"; touch "$F/nolib"; cp "$T/fakejobs.sh" "$F/"
( env FXT="$F" bash -c '. "$1/fakejobs.sh"; . "$2/bin/lib/unblock/collectors/lifecycle.sh"; unblock_collect_lifecycle cromford example-org/cromford' _ "$T" "$SRC" ) > "$F/out.jsonl" 2>/dev/null
check "C2 lib absent: rc 1, 0 records, 0 worker requests" "$? $(grep -c . "$F/out.jsonl") $(cnt . "$F/jobs.log")" "1 0 0"
( env -u HARNESS H= FXT="$F" bash -c '. "$1/fakejobs.sh"; . "$1/lifecycle-stub.sh"; . "$2/bin/lib/unblock/collectors/lifecycle.sh"; unblock_collect_lifecycle cromford example-org/cromford' _ "$T" "$SRC" ) >/dev/null 2>&1
check "C2 no root: rc 2" "$?" 2

F="$T/c3"; seed "$F"; export FXT="$F"; touch "$F/history.fail.BH-9105" "$F/history.fail.BH-9101"
collect "$F"
check "C3 history unread: abandons null, unknown names history" "$(field "$F" BH-9105 '[.abandons, .unknown]')" '[null,["history"]]'
check "C3 ejected with history unread: pr null, no PR read" "$(field "$F" BH-9101 '[.pr, .head, .unknown]') $(grep -c 'pulls/9101' "$F/ghrest.log")" '[null,null,["history"]] 0'
check "C3 meta names the unread reads" "$(tail -n1 "$F/out.jsonl" | jq -c .unreadable)" '["history:BH-9101","history:BH-9105"]'

F="$T/c4"; seed "$F"; export FXT="$F"; touch "$F/pull.fail.9101"
collect "$F"
check "C4 PR unread: head, pr_state, merged null, unknown names pull" "$(field "$F" BH-9101 '[.pr, .head, .pr_state, .merged, .unknown]')" '[9101,null,null,null,["pull"]]'
check "C4 the failed PR read logs its gh_rest status" "$(grep -c 'BH-9101 pull #9101 unread (rc 1, status 000' "$F/err")" 1
# Task 1a (r2): gh_rest writes to a temp dir, never inside $( ); the dir is gone after each run.
check "C4 no ucl.* temp dir left (c1, c4)" "$(find "$T/c1/tmp" "$T/c4/tmp" -maxdepth 1 -name 'ucl.*' | wc -l | tr -d ' ')" 0
check "L1 gh-rest-no-subshell lint passes with collectors/lifecycle.sh on the tree" \
  "$(bash "$SRC/tests/gh-rest-no-subshell-lint.sh" >/dev/null 2>&1; echo $?)" 0

F="$T/c5"; seed "$F"; export FXT="$F"
jq -nc '{rows: [range(0; 60) | {project: "cromford", ticket_key: "BH-95\(. + 10)", phase: "plan_blocked",
  phase_at: "2026-10-2\(if . < 30 then 6 else 7 end)T00:\(. % 30 + 10):00Z", age_min: 2000, threshold_min: 1440, question: "q\(.)"}]}' > "$F/stuck.json"
collect "$F"
check "C5 60 stuck rows, ROWS_MAX unset: 50 records, meta truncated 10" \
  "$(jq -s 'map(select(.kind != "collector-meta")) | length' "$F/out.jsonl") $(tail -n1 "$F/out.jsonl" | jq -c '[.rows_seen, .truncated]')" "50 [60,10]"
check "C5 the oldest 50 are kept (the 10 newest dropped)" "$(rec_of "$F" BH-9569 | wc -l | tr -d ' ') $(rec_of "$F" BH-9510 | wc -l | tr -d ' ')" "0 1"
collect "$F" UNBLOCK_LIFECYCLE_ROWS_MAX=7
check "C5 UNBLOCK_LIFECYCLE_ROWS_MAX=7: 7 records" "$(jq -s 'map(select(.kind != "collector-meta")) | length' "$F/out.jsonl")" 7
collect "$F" UNBLOCK_LIFECYCLE_ROWS_MAX=abc
check "C5 a bad ROWS_MAX is the fallback 50" "$(jq -s 'map(select(.kind != "collector-meta")) | length' "$F/out.jsonl")" 50
budget C

# ═════ R: the U14 rules over the collector's records ═════════════════════════
grep -v '"collector-meta"' "$T/c1-records.jsonl" > "$T/r.jsonl"
HARNESS="$SRC" bash -c '. "$1/bin/lib/unblock/rules.sh"; ub_rules_eval "$2"' _ "$SRC" "$RULES" < "$T/r.jsonl" > "$T/r.dec" 2>"$T/r.err"
rule() { jq -r --arg s "cromford:$1" 'select(.subject == $s) | .rule_id // "null"' "$T/r.dec"; }
dk() { jq -r --arg s "cromford:$1" 'select(.subject == $s) | .decision_key' "$T/r.dec"; }
check "R0 one decision per record" "$(grep -c . "$T/r.dec")" 9
# rules.sh hashes the key values (the word id is the rule id) and then the rule id.
WANT=$(printf 'cromford\x1fBH-9101\x1f2026-10-28T08:01:00Z\x1fU14-REQUEUE\x1fU14-REQUEUE' | sha256sum | cut -d' ' -f1)
check "R1 ejected, open PR labelled merge-queue -> U14-REQUEUE" "$(rule BH-9101)" U14-REQUEUE
check "R1 key = sha of project, ticket, episode, rule" "$(dk BH-9101)" "$WANT"
check "R1 action requeue {ticket_key}, pr and head on the decision" \
  "$(jq -c --arg s cromford:BH-9101 'select(.subject == $s) | [.decision, .action, .pr, .head[0:8], .subject_kind, .class]' "$T/r.dec")" \
  '["act",{"name":"requeue","args":{"ticket_key":"BH-9101"}},9101,"9101aaaa","build","queue-requeue"]'
# closed and merged PRs have a head, so U12 keys them (subject, head); no requeue.
check "R2 ejected, PR closed -> U12 card, not U14-REQUEUE" "$(rule BH-9102)" U12
check "R2 ejected, PR merged -> U12 card, not U14-REQUEUE" "$(rule BH-9103)" U12
check "R2 only BH-9101 gets a requeue" "$(jq -r 'select(.action.name == "requeue") | .subject' "$T/r.dec" | tr '\n' ' ')" "cromford:BH-9101 "
check "R2 ejected, no PR in history -> not U14-REQUEUE" "$(rule BH-9104)" null
check "R3 abandoned once -> U14-REBUILD {key}" \
  "$(jq -c --arg s cromford:BH-9105 'select(.subject == $s) | [.rule_id, .action, .class]' "$T/r.dec")" '["U14-REBUILD",{"name":"rebuild","args":{"key":"BH-9105"}},"triage-launch"]'
check "R4 abandoned twice -> escalate, no rule, no rebuild" \
  "$(jq -c --arg s cromford:BH-9106 'select(.subject == $s) | [.decision, .rule_id, .action]' "$T/r.dec")" '["escalate",null,null]'
check "R4 no rebuild decision for BH-9106 anywhere" "$(jq -r 'select(.action.name == "rebuild") | .subject' "$T/r.dec" | tr '\n' ' ')" "cromford:BH-9105 "
check "R5 plan_blocked with a question -> U14-ASK, args.question = the stored text" \
  "$(jq -c --arg s cromford:BH-9107 'select(.subject == $s) | [.rule_id, .action.name, .action.args.question, .action.args.age_min]' "$T/r.dec")" '["U14-ASK","ask","Which fee field does the rep set?",1673]'
check "R6 plan_blocked question null -> not U14-ASK" "$(rule BH-9108)" null
check "R6 plan_blocked question \"\" -> not U14-ASK" "$(rule BH-9109)" null
# history unread (C3) and rebuild_max 0 never rebuild
grep -v '"collector-meta"' "$T/c3/out.jsonl" | HARNESS="$SRC" bash -c '. "$1/bin/lib/unblock/rules.sh"; ub_rules_eval "$2"' _ "$SRC" "$RULES" > "$T/r3.dec"
check "R4 abandons null (history unread) -> not U14-REBUILD" "$(jq -r 'select(.subject == "cromford:BH-9105") | .rule_id // "null"' "$T/r3.dec")" null
F="$T/r-rb0"; seed "$F"; export FXT="$F"; collect "$F" UNBLOCK_LIFECYCLE_REBUILD_MAX=0
grep -v '"collector-meta"' "$F/out.jsonl" | HARNESS="$SRC" bash -c '. "$1/bin/lib/unblock/rules.sh"; ub_rules_eval "$2"' _ "$SRC" "$RULES" > "$T/r0.dec"
check "R4 rebuild_max 0 -> the first abandon escalates" "$(jq -r 'select(.subject == "cromford:BH-9105") | .rule_id // "null"' "$T/r0.dec")" null
# a new episode is a new key
jq -c 'if .ticket_key == "BH-9101" then .episode = "2026-10-28T11:00:00Z" else . end' "$T/r.jsonl" \
  | HARNESS="$SRC" bash -c '. "$1/bin/lib/unblock/rules.sh"; ub_rules_eval "$2"' _ "$SRC" "$RULES" > "$T/r2.dec"
check "R1 a new phase_at gives a new decision key" "$( [ "$(jq -r 'select(.subject == "cromford:BH-9101") | .decision_key' "$T/r2.dec")" != "$WANT" ] && echo new)" new
budget R

# ═════ A: act.sh ═════════════════════════════════════════════════════════════
# mkact <name> <mode> — a case root with a mode row, a logging lane-alert and a
# launch-fastpath stub. The libs are sourced per call in a subshell.
mkact() {
  local A="$T/$1"
  mkdir -p "$A/h/bin" "$A/h/logs" "$A/h/stub" "$A/fx"
  cat > "$A/h/bin/jobs-client.sh" <<SH
#!/bin/bash
[ "\$1" = setting-get ] && [ "\$2" = unblock.project.cromford.mode ] && { echo $2; exit 0; }
exit 2
SH
  cat > "$A/h/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
[ -f "$FXT/alert.fail" ] && exit 1
exit 0
SH
  cat > "$A/h/bin/launch-fastpath.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$FXT/launch.log"; echo LAUNCH >> "$FXT/order.log"
if [ -f "$FXT/launch.decline" ]; then
  echo "$(date -u) FASTPATH-DECLINED $2 :: held by an owner" >> "$HARNESS/logs/$1.log"; echo "$2"; exit 1
fi
exit 0
SH
  chmod +x "$A/h/bin/"*.sh
  printf '%s' "$A"
}
# act <case> <decision-json> [nolib] — ub_act in a subshell; prints
# "<outcome>|<detail>" and writes UB_ACT_CARD to <case>/card.json.
act() {
  local A="$1"
  ( export HARNESS="$A/h" FXT="$A/fx" UNBLOCK_ACT=1
    . "$T/fakejobs.sh"
    [ "${3:-}" = nolib ] || . "$T/lifecycle-stub.sh"
    . "$SRC/bin/lib/unblock/card.sh"
    . "$SRC/bin/lib/unblock/act.sh"
    mc_requeued_mark() { :; }
    mc_requeued_record() { return 0; }
    mc_requeue_mergify() { echo "requeue $*" >> "$FXT/mc.log"; return 0; }
    ub_act "$2" >/dev/null
    printf '%s' "$UB_ACT_CARD" > "$A/card.json"
    printf '%s|%s' "$UB_ACT_OUTCOME" "$UB_ACT_DETAIL" )
}
dec() { # dec <action> <args-json> [ticket]
  jq -nc --arg a "$1" --argjson g "$2" --arg k "${3:-BH-9201}" --arg h "$(H40 9201dddd)" \
    --arg dk "$(printf 'bh-8736 %s' "${3:-BH-9201}" | sha256sum | cut -d' ' -f1)" '{decision_key: $dk, project: "cromford",
    repo: "example-org/cromford", subject_kind: "build", subject: "cromford:\($k)", pr: 9201, head: $h,
    rule_id: "U14-X", class: "triage-launch", cites: ["G1"], action: {name: $a, args: $g}}'
}
tbody() { jq -c "$2" "$1/fx/transitions.log" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }

A=$(mkact a1 act)
check "A1 rebuild: done launched" "$(act "$A" "$(dec rebuild '{"key":"BH-9201"}')")" "done|launched"
check "A1 transition body: planned, actor lifecycle, BH-9201" "$(tbody "$A" '[.project, .ticket_key, .to_phase, .actor, (.reason | test("^U14-X rebuild, decision [0-9a-f]{12}$"))]')" '["cromford","BH-9201","planned","lifecycle",true]'
check "A1 the transition runs before the launch, one each" "$(tr '\n' ' ' < "$A/fx/order.log")" "TRANSITION LAUNCH "
check "A1 launch-fastpath got the project and the key" "$(cat "$A/fx/launch.log")" "cromford BH-9201"

A=$(mkact a2 act); echo 9 > "$A/fx/transition.rc"; echo planned > "$A/fx/transition.current"
check "A2 transition 409 current planned: launch still runs, done" "$(act "$A" "$(dec rebuild '{"key":"BH-9202"}' BH-9202)") $(cnt . "$A/fx/launch.log")" "done|launched 1"

A=$(mkact a3 act); echo 9 > "$A/fx/transition.rc"; echo building > "$A/fx/transition.current"
check "A3 transition 409 current building: refused phase-moved, 0 launches" "$(act "$A" "$(dec rebuild '{"key":"BH-9203"}' BH-9203)") $(cnt . "$A/fx/launch.log")" "refused|phase-moved:building 0"
echo 2 > "$A/fx/transition.rc"
check "A3 transition 404: refused no-row, 0 launches" "$(act "$A" "$(dec rebuild '{"key":"BH-9203"}' BH-9203)") $(cnt . "$A/fx/launch.log")" "refused|no-row 0"
echo 1 > "$A/fx/transition.rc"
check "A3 transition rc 1: failed, 0 launches" "$(act "$A" "$(dec rebuild '{"key":"BH-9203"}' BH-9203)") $(cnt . "$A/fx/launch.log")" "failed|transition rc 1 0"

A=$(mkact a4 act); touch "$A/fx/launch.decline"
check "A4 launch declined: refused planned; declined: <why>" "$(act "$A" "$(dec rebuild '{"key":"BH-9204"}' BH-9204)")" "refused|planned; declined: held by an owner"

A=$(mkact a5 shadow)
check "A5 ask in shadow: would WOULD_ASK" "$(act "$A" "$(dec ask '{"key":"BH-9205","question":"Which fee field?","age_min":1500}' BH-9205)")" "would|WOULD_ASK"
check "A5 shadow: 0 alerts, 0 transitions, no card" "$(cnt . "$A/fx/alerts.log") $(cnt . "$A/fx/transitions.log") $(wc -c < "$A/card.json" | tr -d ' ')" "0 0 0"
check "A5 rebuild in shadow: would, 0 transitions, 0 launches" "$(act "$A" "$(dec rebuild '{"key":"BH-9205"}' BH-9205)") $(cnt . "$A/fx/transitions.log") $(cnt . "$A/fx/launch.log")" "would|WOULD_REBUILD 0 0"

A=$(mkact a6 act)
DJ=$(dec ask '{"key":"BH-9206","question":"Which fee field does the rep set?","age_min":1500}' BH-9206)
OUT=$(act "$A" "$DJ"); CID=$(jq -r .id "$A/card.json")
check "A6 ask in act: escalated, card <id>" "$OUT" "escalated|card $CID"
check "A6 one critical alert with id unblock-<card id>" "$(cnt . "$A/fx/alerts.log") $(grep -c -- "--critical --severity critical --id unblock-$CID unblock " "$A/fx/alerts.log")" "1 1"
check "A6 the alert text holds the question and the answer line" \
  "$(grep -cF "has been plan_blocked for 1500 min. The plan asked: Which fee field does the rep set?. Answer on the issue thread, then reply \`Tackler $CID 1\`" "$A/fx/alerts.log")" 1
check "A6 card: id u-<6 hex>, 2 options, lifecycle {project, ticket_key}, key, default hold" \
  "$(jq -c '[(.id | test("^u-[0-9a-f]{6}$")), (.options | length), .lifecycle, .default, .recommendation, (.text | length <= 900)]' "$A/card.json")" \
  '[true,2,{"project":"cromford","ticket_key":"BH-9206"},"hold",1,true]'
check "A6 card id = unblock_card_id of the decision key" "$CID" "u-$(jq -r .decision_key <<<"$DJ" | cut -c1-6)"
check "A6 ask makes no transition and no model call" "$(cnt . "$A/fx/transitions.log")" 0
LONGQ=$(printf 'why %.0s' $(seq 1 450))
OUT=$(act "$A" "$(dec ask "$(jq -nc --arg q "$LONGQ" '{key: "BH-9216", question: $q, age_min: 2000}')" BH-9216)")
check "A6 a 1800-char question is cut to fit the 900-char card" "${OUT%%|*} $(jq -r '.text | length <= 900' "$A/card.json") $(jq -r '.text | test("\\.\\.\\.\\. Answer on the issue thread")' "$A/card.json")" "escalated true true"

A=$(mkact a7 act); touch "$A/fx/alert.fail"
check "A7 alert rc 1: failed send-failed, UB_ACT_CARD empty" "$(act "$A" "$(dec ask '{"key":"BH-9207","question":"Q?"}' BH-9207)") $(wc -c < "$A/card.json" | tr -d ' ')" "failed|send-failed 0"
check "A7 an empty question is bad input" "$(act "$A" "$(dec ask '{"key":"BH-9207","question":""}' BH-9207)")" "|"
check "A7 a bad ticket key is bad input" "$(act "$A" "$(dec rebuild '{"key":"bh 9207; rm"}' BH-9207)")" "|"
Q2001=$(printf 'q%.0s' $(seq 1 2001))
check "A7 a 2001-char question is bad input (UNBLOCK_ASK_QUESTION_MAX unset: 2000)" "$(act "$A" "$(dec ask "$(jq -nc --arg q "$Q2001" '{key: "BH-9207", question: $q}')" BH-9207)")" "|"
rm -f "$A/fx/alert.fail"
check "A7 UNBLOCK_ASK_QUESTION_MAX=5: a 6-char question is bad input" "$(UNBLOCK_ASK_QUESTION_MAX=5 act "$A" "$(dec ask '{"key":"BH-9207","question":"sixchr"}' BH-9207)")" "|"
check "A7 UNBLOCK_ASK_QUESTION_MAX=5: a 5-char question is sent" "$(UNBLOCK_ASK_QUESTION_MAX=5 act "$A" "$(dec ask '{"key":"BH-9207","question":"five?"}' BH-9207)" | cut -d'|' -f1)" escalated

# A8/A9 requeue: the PR gates read gh api; a case gh answers them.
mkdir -p "$T/agh"
cat > "$T/agh/gh" <<'SH'
#!/bin/bash
p="${*: -1}"; echo "gh $*" >> "$FXT/gh.log"
case "$p" in
  */pulls/9201) printf '{"head":{"sha":"%s"}}' "$(cat "$FXT/head")" ;;
  *) echo '[]' ;;
esac
SH
chmod +x "$T/agh/gh"
A=$(mkact a8 act); H40 9201dddd > "$A/fx/head"
OUT=$(PATH="$T/agh:$PATH" act "$A" "$(dec requeue '{"ticket_key":"BH-9208"}' BH-9208)")
check "A8 requeue with ticket_key: done requeued; phase in_queue" "$OUT" "done|requeued; phase in_queue"
check "A8 one transition {in_queue, lifecycle, pr}" "$(tbody "$A" '[.ticket_key, .to_phase, .actor, .pr]')" '["BH-9208","in_queue","lifecycle",9201]'
check "A8 the requeue ran before the transition" "$(cnt . "$A/fx/mc.log")" 1
echo 9 > "$A/fx/transition.rc"; echo planned > "$A/fx/transition.current"
OUT=$(PATH="$T/agh:$PATH" act "$A" "$(dec requeue '{"ticket_key":"BH-9208"}' BH-9208)")
check "A8 a refused phase write keeps done (the requeue happened)" "$OUT" "done|requeued; phase rc 9"
A=$(mkact a9 act); H40 9201dddd > "$A/fx/head"
OUT=$(PATH="$T/agh:$PATH" act "$A" "$(dec requeue "$(jq -nc --arg h "$(H40 9201dddd)" '{pr: 9201, head: $h}')" BH-9209)")
check "A9 requeue without ticket_key (U2 shape): done requeued, 0 transitions" "$OUT $(cnt . "$A/fx/transitions.log")" "done|requeued 0"

A=$(mkact a10 act)
check "A10 lib absent: rebuild failed lifecycle-libs-not-loaded" "$(act "$A" "$(dec rebuild '{"key":"BH-9210"}' BH-9210)" nolib)" "failed|lifecycle-libs-not-loaded"
check "A10 lib absent: ask failed lifecycle-libs-not-loaded, 0 alerts" "$(act "$A" "$(dec ask '{"key":"BH-9210","question":"Q?"}' BH-9210)" nolib) $(cnt . "$A/fx/alerts.log")" "failed|lifecycle-libs-not-loaded 0"
check "A10 lib absent: 0 launches" "$(cnt . "$A/fx/launch.log")" 0
budget A

# ═════ T: bin/unblock.sh tick ════════════════════════════════════════════════
# mktick <name> — the shipped tick by its closure, the shipped rules, the real
# lifecycle collector alone in the collectors dir, the lib stub at
# bin/lib/jobs/lifecycle.sh (where the tick sources it), the fake worker and
# GitHub, and logging lane-alert / launch-fastpath stubs.
mktick() {
  local C="$T/$1" S
  mkdir -p "$C/h/env" "$C/h/state" "$C/h/logs" "$C/h/catalog/unblock-rules.d" "$C/h/catalog/prompts" "$C/fx" "$C/col" "$C/bin"
  for S in bin/unblock.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/unblock/rules.sh bin/lib/unblock/card.sh; do
    ( cd "$SRC" && scratch_install_closure "$S" "$C/h" ) >/dev/null || { echo "setup: closure $S" >&2; return 1; }
  done
  cp "$RULES"/*.json "$C/h/catalog/unblock-rules.d/"
  cp "$SRC/catalog/prompts/unblock-decide.md" "$C/h/catalog/prompts/"
  # scratch-closure-allow: the shipped collector, placed into the UNBLOCK_COLLECTORS_DIR seam the tick reads
  cp "$SRC/bin/lib/unblock/collectors/lifecycle.sh" "$C/col/lifecycle.sh"
  mkdir -p "$C/h/bin/lib/jobs"
  cp "$T/lifecycle-stub.sh" "$C/h/bin/lib/jobs/lifecycle.sh"
  : > "$C/h/env/global.env"
  printf 'cromford example-org/cromford - - 3 hub 192.0.2.10\n' > "$C/h/fleet.conf"
  rm -f "$C/h/bin/lane-alert.sh" "$C/h/bin/agent-call.sh" "$C/h/bin/launch-fastpath.sh"
  cat > "$C/h/bin/lane-alert.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
exit 0
SH
  cat > "$C/h/bin/agent-call.sh" <<'SH'
#!/bin/bash
echo "AGENTCALL $*" >> "$FXT/agentcall.log"; exit 1
SH
  cat > "$C/h/bin/launch-fastpath.sh" <<'SH'
#!/bin/bash
echo "$*" >> "$FXT/launch.log"; exit 0
SH
  chmod +x "$C/h/bin/lane-alert.sh" "$C/h/bin/agent-call.sh" "$C/h/bin/launch-fastpath.sh"
  cat > "$C/bin/gh" <<'SH'
#!/bin/bash
p="${*: -1}"; echo "gh $*" >> "$FXT/gh.log"
case "$p" in
  */pulls/9301) jq -c '."9301"' "$FXT/pulls.json" ;;
  *) echo '[]' ;;
esac
SH
  chmod +x "$C/bin/gh"
  { cat "$T/fakejobs.sh"
    cat <<'SH'
setting_get() { case "$1" in unblock.enabled) printf 1; return 0 ;; esac; return 2; }
lane_gate_or_exit() { return 0; }
lane_env_apply() { return 0; }
lane_role_model() { return 1; }
mc_requeued_mark() { :; }
mc_requeued_record() { return 0; }
mc_requeue_mergify() { echo "requeue $*" >> "$FXT/mc.log"; return 0; }
SH
  } > "$C/fx.sh"
  # the stuck answer: one row per acting rule
  jq -nc '{rows: [
    {project: "cromford", ticket_key: "BH-9301", phase: "ejected",      phase_at: "2026-10-28T09:01:00Z", age_min: 179, threshold_min: 60},
    {project: "cromford", ticket_key: "BH-9302", phase: "abandoned",    phase_at: "2026-10-28T09:02:00Z", age_min: 178, threshold_min: 60},
    {project: "cromford", ticket_key: "BH-9303", phase: "plan_blocked", phase_at: "2026-10-27T09:03:00Z", age_min: 1617, threshold_min: 1440, question: "Keep the old fee column?"}]}' > "$C/fx/stuck.json"
  jq -nc '{"BH-9301": [{id: 1, to_phase: "pr_open", pr: 9301}, {id: 2, to_phase: "ejected"}],
           "BH-9302": [{id: 3, to_phase: "abandoned"}]}' > "$C/fx/history.json"
  jq -nc --arg h "$(H40 9301eeee)" '{"9301": {number: 9301, state: "open", merged: false, head: {sha: $h}, labels: [{name: "merge-queue"}]}}' > "$C/fx/pulls.json"
  printf '%s' "$C"
}
mode() {
  jq -nc --argjson fa "$NOW" --arg m "$2" '{fetched_at: $fa, values: {"unblock.project.cromford.mode": $m, "unblock.enabled": "1"}, seeded: {}}' \
    > "$1/h/state/settings-cache.json"
}
tick() {
  local C="$1"; shift
  ( env HARNESS="$C/h" FXT="$C/fx" UNBLOCK_FIXTURE="$C/fx.sh" UNBLOCK_COLLECTORS_DIR="$C/col" HARNESS_TEST_SANDBOX=1 \
      LANE_GATE_DISABLE=1 LANE_GATE_NOW=$NOW LANE_GATE_CACHE_S=60 UNBLOCK_TIMED=1 JOBS_URL= HARNESS_SECRET= \
      PATH="$C/bin:$FB:$OLDPATH" TMPDIR="$C" UNBLOCK_NOW="$NOW" UB_NOW="$NOW" "$@" \
      bash "$C/h/bin/unblock.sh" tick --project cromford ) > "$C/tick.out" 2>&1
}
tickline() { grep ' tick cromford mode=' "$1/h/logs/unblock.log" 2>/dev/null | tail -n1; }

C=$(mktick t1) || exit 1; mode "$C" act
tick "$C" UNBLOCK_ACT=1
check "T1 3 claims, each subject_kind build" "$(jq -rs 'map(.subject_kind) | join(",")' "$C/fx/claims.log")" "build,build,build"
check "T1 the claims are U14-REQUEUE, U14-REBUILD, U14-ASK" "$(jq -rs 'map(.rule_id) | sort | join(",")' "$C/fx/claims.log")" "U14-ASK,U14-REBUILD,U14-REQUEUE"
check "T1 act: 1 requeue, 1 launch, 1 alert, 2 transitions (in_queue, planned)" \
  "$(cnt . "$C/fx/mc.log") $(cnt . "$C/fx/launch.log") $(cnt . "$C/fx/alerts.log") $(jq -rs 'map(.to_phase) | sort | join(",")' "$C/fx/transitions.log")" "1 1 1 in_queue,planned"
check "T1 0 model calls" "$(cnt . "$C/fx/agentcall.log")" 0
case "$(tickline "$C")" in *"collectors=1 unwired=0 failed=0 records=3 decisions=3 claimed=3 rows=3 deferred=0"*) ok "T1 tick line" ;;
  *) no "T1 tick line" "$(tickline "$C") $(head -c 800 "$C/tick.out")" ;; esac
ASKREC=$(jq -c 'select(.outcome == "escalated")' "$C/fx/records.log")
check "T3 the ask record: outcome escalated with the card" "$(jq -c '[.outcome, (.card.id | test("^u-")), .card.lifecycle, (.card.text | contains("Keep the old fee column?"))]' <<<"$ASKREC")" \
  '["escalated",true,{"project":"cromford","ticket_key":"BH-9303"},true]'
check "T4 the requeue record carries no card" "$(jq -c 'select(.outcome_detail | startswith("requeued")) | [.outcome, .outcome_detail, has("card")]' "$C/fx/records.log")" '["done","requeued; phase in_queue",false]'
check "T4 the rebuild record carries no card" "$(jq -c 'select(.outcome_detail == "launched") | has("card")' "$C/fx/records.log")" false
# T2: the same stuck answer again
cp "$C/fx/claims.log" "$C/claims1"; : > "$C/fx/order.log"
tick "$C" UNBLOCK_ACT=1
check "T2 second tick: 3 claims answer 409, 0 new actions" \
  "$(( $(cnt . "$C/fx/claims.log") - 3 )) $(cnt . "$C/fx/mc.log") $(cnt . "$C/fx/launch.log") $(cnt . "$C/fx/alerts.log") $(cnt . "$C/fx/transitions.log") $(cnt . "$C/fx/records.log")" "3 1 1 1 2 3"
case "$(tickline "$C")" in *"claimed=0 rows=0"*) ok "T2 tick line claimed=0" ;; *) no "T2 tick line claimed=0" "$(tickline "$C")" ;; esac
jq -c '.rows[2].phase_at = "2026-10-28T10:30:00Z"' "$C/fx/stuck.json" > "$C/fx/s.tmp" && mv "$C/fx/s.tmp" "$C/fx/stuck.json"
tick "$C" UNBLOCK_ACT=1
check "T2 a new phase_at for BH-9303: one new claim and one new card" "$(cnt . "$C/fx/alerts.log") $(cnt . "$C/fx/records.log")" "2 4"
budget T

C=$(mktick t-c2) || exit 1; mode "$C" act
rm -f "$C/h/bin/lib/jobs/lifecycle.sh"
# a second, quiet family, as on the hub: the tick prints its full line only
# when some collector is wired.
printf 'ub_collect_quiet() { return 0; }\n' > "$C/col/quiet.sh"
tick "$C" UNBLOCK_ACT=1
case "$(tickline "$C")" in *"collectors=1 unwired=0 failed=1 records=0"*) ok "C2 lib absent: the tick line says failed=1, 0 records" ;; *) no "C2 lib absent: tick line failed=1" "$(tickline "$C") $(head -c 400 "$C/tick.out")" ;; esac
check "C2 lib absent: the log names the failed family" "$(cnt 'collector lifecycle failed rc 1' "$C/h/logs/unblock.log")" 1
check "C2 lib absent: 0 claims" "$(cnt . "$C/fx/claims.log")" 0

C=$(mktick t-shadow) || exit 1; mode "$C" shadow
tick "$C"
check "A5 the shadow tick: 3 would rows, 0 alerts, 0 transitions, 0 launches" \
  "$(jq -rs 'map(.outcome) | join(",")' "$C/fx/records.log") $(cnt . "$C/fx/alerts.log") $(cnt . "$C/fx/transitions.log") $(cnt . "$C/fx/launch.log")" "would,would,would 0 0 0"
budget "T shadow"

# ═════ P: bin/unblock-reply.sh ═══════════════════════════════════════════════
HP="$T/hp"
mkdir -p "$HP/bin/lib/jobs" "$HP/logs" "$HP/env" "$T/pbin"
for s in bin/unblock-reply.sh bin/jobs-client.sh; do
  ( cd "$SRC" && scratch_install_closure "$s" "$HP" ) >/dev/null || { echo "FAIL: closure $s"; exit 1; }
done
cp "$T/lifecycle-stub.sh" "$HP/bin/lib/jobs/lifecycle.sh"
: > "$HP/env/global.env"
# A fake jobs worker behind the real jobs client: the ledger GET, the answer
# POST, and the transition POST (its code from $FXT/transition.code).
cat > "$T/pbin/curl" <<'SH'
#!/bin/bash
m=GET; body=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -X) m="$2"; shift ;;
    --data-binary) body="$2"; shift ;;
    -H|-m|--connect-timeout|-w) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
case "$url" in http://jobs.invalid*) ;; *) echo "curl $url" >> "$NETLOG"; exit 7 ;; esac
path="${url#http://jobs.invalid}"
printf '%s %s %s\n' "$m" "$path" "$body" >> "$FXT/reqlog"
case "$m $path" in
  "GET /api/unblock/decisions"*)
    card="${path##*card=}"
    jq -c --arg c "$card" '{decisions: map(select(.card.id == $c and .outcome == "escalated"))}' "$FXT/ledger.json"
    printf '\n200' ;;
  "POST /api/lifecycle/transition")
    echo "$body" >> "$FXT/ptransitions.log"; echo TRANSITION >> "$FXT/porder.log"
    code=$(cat "$FXT/transition.code" 2>/dev/null); code="${code:-200}"
    if [ "$code" = 409 ]; then printf '{"current":"%s"}\n409' "$(cat "$FXT/transition.current")"; else printf '{"ok":true}\n%s' "$code"; fi ;;
  "POST /api/unblock/decisions/"*"/answer")
    echo ANSWER >> "$FXT/porder.log"; printf '{"ok":true}\n200' ;;
  *) printf '{"error":"no route"}\n404' ;;
esac
SH
chmod +x "$T/pbin/curl"
# the ledger row: the card the T3 tick recorded, as the GET returns it
CARD=$(jq -c .card <<<"$ASKREC"); PID=$(jq -r .id <<<"$CARD")
preset() { # preset <rule_id> [card-jq]
  local F="$T/p"; scratch_rm "$F" || exit 1; mkdir -p "$F"
  jq -nc --argjson c "$CARD" --arg r "$1" '[{id: 41, rule_id: $r, outcome: "escalated", decision_key: $c.key, card: $c}]' \
    | jq -c "map(.card |= (${2:-.}))" > "$F/ledger.json"
}
reply() {
  ( env HARNESS="$HP" HARNESS_TEST_SANDBOX=1 FXT="$T/p" NETLOG="$T/net.log" PATH="$T/pbin:$FB:$OLDPATH" JOBS_URL=http://jobs.invalid \
      HARNESS_SECRET=fixture-secret JOBS_RETRIES=0 JOBS_OVERLOAD_RETRIES=0 BOX_CHAT_OWNERS="telegram:owner_a=owner@example.com" \
      UNBLOCK_TRANSPORT=telegram UNBLOCK_FROM_USER=owner_a UNBLOCK_CMD_ID="$2" "$HP/bin/unblock-reply.sh" intercept "$1" 2>/dev/null )
}
answers() { cnt '^POST /api/unblock/decisions/41/answer ' "$T/p/reqlog"; }

preset U14-ASK
OUT=$(reply "Tackler $PID 1" p1)
check "P1 one transition {BH-9303, planned, lifecycle}, reason names the owner and the card" \
  "$(jq -c '[.project, .ticket_key, .to_phase, .actor, .reason]' "$T/p/ptransitions.log")" "[\"cromford\",\"BH-9303\",\"planned\",\"lifecycle\",\"answered by owner@example.com on card $PID\"]"
check "P1 the transition runs before the answer POST" "$(tr '\n' ' ' < "$T/p/porder.log")" "TRANSITION ANSWER "
check "P1 the reply says moved" "$OUT" "Tackler: recorded answer 1 for $PID (cromford:BH-9303); moved BH-9303 to planned."

preset U14-ASK
OUT=$(reply "Tackler $PID hold" p2a); OUT2=$(reply "Tackler $PID 2" p2b)
check "P2 hold and option 2: 0 transitions, 2 answers recorded" "$(cnt . "$T/p/ptransitions.log") $(answers)" "0 2"
check "P2 hold reply unchanged" "$OUT" "Tackler: recorded hold for $PID (cromford:BH-9303). It stays parked."

preset U14-ASK; echo 500 > "$T/p/transition.code"
OUT=$(reply "Tackler $PID 1" p3)
check "P3 transition rc 1: 0 answer POSTs, reply says not recorded" "$(answers) $OUT" "0 Tackler: answer 1 for $PID was not recorded (the ticket move failed: rc 1)."
preset U14-ASK; mv "$HP/bin/lib/jobs/lifecycle.sh" "$T/lc.off"
OUT=$(reply "Tackler $PID 1" p3b)
check "P3 lib absent: 0 answer POSTs, not recorded" "$(answers) $(cnt . "$T/p/ptransitions.log") $OUT" "0 0 Tackler: answer 1 for $PID was not recorded (the ticket move failed: rc lib)."
mv "$T/lc.off" "$HP/bin/lib/jobs/lifecycle.sh"

preset U12
OUT=$(reply "Tackler $PID 1" p4)
check "P4 a U12 card answered 1: 0 transitions, answer recorded" "$(cnt . "$T/p/ptransitions.log") $(answers)" "0 1"

preset U14-ASK 'del(.lifecycle)'
OUT=$(reply "Tackler $PID 1" p5)
check "P5 a U14-ASK card with no lifecycle: 0 transitions, answer recorded as before" "$(cnt . "$T/p/ptransitions.log") $(answers) $OUT" \
  "0 1 Tackler: recorded answer 1 for $PID (cromford:BH-9303). It runs on the next Tackler tick."

preset U14-ASK; echo 409 > "$T/p/transition.code"; echo planned > "$T/p/transition.current"
OUT=$(reply "Tackler $PID 1" p6)
check "P6 transition 409 current planned: answer recorded, reply says moved" "$(answers) $OUT" "1 Tackler: recorded answer 1 for $PID (cromford:BH-9303); moved BH-9303 to planned."
preset U14-ASK; echo 409 > "$T/p/transition.code"; echo building > "$T/p/transition.current"
OUT=$(reply "Tackler $PID 1" p6b)
check "P6 transition 409 current building: answer recorded, reply names the phase" "$(answers) $OUT" "1 Tackler: recorded answer 1 for $PID (cromford:BH-9303); the ticket is already building."
budget P

# ═════ W: bin/stuck-work.sh, the ticket facts retired ════════════════════════
HW="$T/hw"; mkdir -p "$HW/env" "$T/wbin"
cp -rs "$SRC/bin" "$HW/bin"
cp -rs "$SRC/catalog" "$HW/catalog"
rm -f "$HW/catalog/lanes.json"
HARNESS_TEST_SANDBOX=1 "$SRC/bin/lanes-build.sh" > "$HW/catalog/lanes.json" 2>/dev/null || no "W setup: lanes-build failed"
: > "$HW/env/global.env"
rm -f "$HW/bin/lane-alert.sh" "$HW/bin/beat.sh" "$HW/bin/lib/stuck-work/facts-pr.sh" "$HW/bin/lib/stuck-work/facts-ticket.sh"
printf '#!/bin/bash\nexit 0\n' > "$HW/bin/lane-alert.sh"; cp "$HW/bin/lane-alert.sh" "$HW/bin/beat.sh"
chmod +x "$HW/bin/lane-alert.sh" "$HW/bin/beat.sh"
printf 'swf_pr_facts() { return 0; }\n' > "$HW/bin/lib/stuck-work/facts-pr.sh"
printf 'swf_ticket_facts() { echo called >> "$FXT/ticket-facts.marker"; return 0; }\n' > "$HW/bin/lib/stuck-work/facts-ticket.sh"
cat > "$T/wbin/curl" <<'SH'
#!/bin/bash
m=GET; wfmt=0; prev=""
for a in "$@"; do case "$prev" in -X) m="$a" ;; -w) wfmt=1 ;; esac; prev="$a"; done
url="${!#}"
case "$url" in https://jobs.invalid*) ;; *) echo "curl $url" >> "$NETLOG"; exit 7 ;; esac
path="${url#https://jobs.invalid}"
code=200; out='{"ok":true}'
case "$m $path" in
  "GET /api/settings"*) out='{"settings":[]}' ;;
  "GET "*) code=404; out='{"error":"not found"}' ;;
esac
printf '%s' "$out"; [ "$wfmt" = 1 ] && printf '\n%s' "$code"
exit 0
SH
chmod +x "$T/wbin/curl"
wrun() {
  scratch_rm "$T/w" || exit 1; mkdir -p "$T/w"
  ( env -u STUCK_WORK_TICKET_FACTS HARNESS="$HW" FXT="$T/w" NETLOG="$T/net.log" PATH="$T/wbin:$FB:$OLDPATH" \
      JOBS_URL=https://jobs.invalid JOBS_RETRIES=0 HARNESS_SECRET=fixture-secret JOBS_BOX=hub HARNESS_TEST_SANDBOX=1 \
      STUCK_WORK_NOW=1790000000 GH_TOKEN=tok-fixture-1 "$@" bash "$HW/bin/stuck-work.sh" ) > "$T/w.out" 2>&1
  echo $?
}
check "W1 STUCK_WORK_TICKET_FACTS unset: rc 0, swf_ticket_facts not called" "$(wrun) $(cnt . "$T/w/ticket-facts.marker")" "0 0"
check "W1 the run still completes (a summary line)" "$(tail -n1 "$HW/logs/stuck-work.log" | grep -c ' items=0 ')" 1
check "W2 STUCK_WORK_TICKET_FACTS=1: called once" "$(wrun STUCK_WORK_TICKET_FACTS=1) $(cnt . "$T/w/ticket-facts.marker")" "0 1"
check "W1 the knob is registered, default 0" "$(jq -c '.lanes[] | select(.id == "stuck-work") | .knobs[] | select(.env == "STUCK_WORK_TICKET_FACTS") | [.default, .min, .max, .settable]' "$HW/catalog/lanes.json")" "[0,0,1,true]"
budget W

echo "unblock-lifecycle: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
