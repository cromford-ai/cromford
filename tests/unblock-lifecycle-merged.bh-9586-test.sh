#!/bin/bash
# tests/unblock-lifecycle-merged.bh-9586-test.sh — BH-9586: rule U14-MERGED
# settles an ejected ticket whose PR already merged.
#
# Drives the SHIPPED code: the collector bin/lib/unblock/collectors/lifecycle.sh,
# the rules engine over the shipped catalog/unblock-rules.d, and act.sh's
# ub_act with the action settle_merged. The worker is a fake _jobs_req, the
# #8731 lib a stub with its contract, GitHub a fake gh_rest (the collector) and
# a fake `gh` on PATH (act.sh). prr_write is the real bin/lib/pr-record-write.sh
# with no jobs record path (PR_RECORD_WRITES=0). Every case seeds its own dir.
#
#   C1-C4  the collector: merge_sha and base_ref on the record, one read per row
#   R1-R8  U14-MERGED over the records, and its negatives
#   A1-A10 act.sh settle_merged: compare, transition, label, refusals
#   E1     end to end: the BH-9460 / PR 9508 shape -> collector -> rules -> act
#   B1     0 vendor calls: curl, gh, flyctl and claude on PATH log to net.log
#
# MUTATIONS (D1), each tried once by hand: drop `.merged == true` from the
# rule -> R3 red; accept compare `behind` as on base -> A4 red; skip the
# label DELETE -> A1 red; report done when the DELETE fails -> A7 red; drop
# merge_sha from the collector -> C1, R1 and E1 red; transition before the
# compare -> A4 and A6 red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-lifecycle-merged.bh-9586-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq missing"; exit 0; }

PASS=0; FAIL=0
ok() { PASS=$((PASS + 1)); echo "ok   $1"; }
no() { FAIL=$((FAIL + 1)); echo "FAIL $1"; [ -n "${2:-}" ] && printf '     %s\n' "${2:0:1500}"; return 0; }
check() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want '$3' got '$2'"; fi; }
cnt() { if [ -f "$2" ]; then grep -c -- "$1" "$2"; else echo 0; fi; }

R=example-org/cromford
RULES="$SRC/catalog/unblock-rules.d"
export UB_NOW=1794470400   # 2026-11-12T08:00:00Z
H40() { printf '%s' "$1$1$1$1$1$1$1$1$1$1" | cut -c1-40; }
HEAD9508=$(H40 428b6712)
MERGE9508=$(H40 9508beef)

# ── B1: the vendor guard, first on PATH everywhere ───────────────────────────
FB="$T/netguard"; mkdir -p "$FB"
for b in curl gh flyctl claude; do
  printf '#!/bin/bash\necho "%s $*" >> "%s/net.log"\nexit 7\n' "$b" "$T" > "$FB/$b"
  chmod +x "$FB/$b"
done
: > "$T/net.log"
budget() { check "B1 $1: 0 vendor calls (net.log)" "$(cnt . "$T/net.log")" 0; }
export PATH="$FB:$PATH"
export HARNESS="$T/hc"; mkdir -p "$HARNESS/logs"

# ── the #8731 lib stub, the fake worker, the collector's fake gh_rest ───────
cat > "$T/lifecycle-stub.sh" <<'SH'
lifecycle_stuck() { _jobs_req GET "/api/lifecycle/stuck?project=$1"; }
lifecycle_transition() {
  local b
  b=$(jq -nc --arg p "$1" --arg k "$2" --arg t "$3" --arg a "$4" --arg r "$5" --arg pr "${6:-}" \
    '{project: $p, ticket_key: $k, to_phase: $t, actor: $a, reason: $r} + (if $pr == "" then {} else {pr: ($pr | tonumber)} end)')
  _jobs_req POST /api/lifecycle/transition "$b"
}
SH
cat > "$T/fakejobs.sh" <<'SH'
_jobs_req() {
  local k rc
  printf '%s %s %s\n' "$1" "$2" "${3:-}" >> "$FXT/jobs.log"
  case "$1 $2" in
    "GET /api/lifecycle/stuck"*) cat "$FXT/stuck.json"; return 0 ;;
    "GET /api/lifecycle/history"*)
      k="${2##*ticket_key=}"
      jq -c --arg k "$k" '{events: (.[$k] // [])}' "$FXT/history.json"; return 0 ;;
    "POST /api/lifecycle/transition")
      echo "$3" >> "$FXT/transitions.log"; echo TRANSITION >> "$FXT/order.log"
      rc=$(cat "$FXT/transition.rc" 2>/dev/null || echo 0)
      case "$rc" in
        0) printf '{"ok":true,"phase":"%s"}' "$(jq -r .to_phase <<<"$3")" ;;
        9) cat "$FXT/transition.body" ;;
      esac
      return "$rc" ;;
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

# seed <dir> — the stuck answer, the history and the pulls of the C cases.
seed() {
  local F="$1"
  scratch_rm "$F" || exit 1
  mkdir -p "$F/tmp"
  jq -nc '{rows: [
    {project: "cromford", ticket_key: "BH-9460", phase: "ejected", phase_at: "2026-11-11T08:53:00Z", age_min: 1409, threshold_min: 30, phase_actor: "conductor"},
    {project: "cromford", ticket_key: "BH-9621", phase: "ejected", phase_at: "2026-11-12T06:00:00Z", age_min: 120,  threshold_min: 30, phase_actor: "conductor"},
    {project: "cromford", ticket_key: "BH-9622", phase: "ejected", phase_at: "2026-11-12T06:01:00Z", age_min: 119,  threshold_min: 30, phase_actor: "conductor"},
    {project: "cromford", ticket_key: "BH-9623", phase: "ejected", phase_at: "2026-11-12T06:02:00Z", age_min: 118,  threshold_min: 30, phase_actor: "conductor"}]}' > "$F/stuck.json"
  jq -nc '{
    "BH-9460": [{id: 1, to_phase: "pr_open", pr: 9508}, {id: 2, to_phase: "in_queue", pr: 9508}, {id: 3, to_phase: "ejected"}],
    "BH-9621": [{id: 4, to_phase: "pr_open", pr: 9621}, {id: 5, to_phase: "ejected"}],
    "BH-9622": [{id: 6, to_phase: "pr_open", pr: 9622}, {id: 7, to_phase: "ejected"}],
    "BH-9623": [{id: 8, to_phase: "pr_open", pr: 9623}, {id: 9, to_phase: "ejected"}]}' > "$F/history.json"
  jq -nc --arg h "$HEAD9508" --arg m "$MERGE9508" --arg b "$(H40 9621aaaa)" --arg c "$(H40 9622bbbb)" '{
    "9508": {number: 9508, state: "closed", merged: true, merge_commit_sha: $m, head: {sha: $h}, base: {ref: "main"}, labels: [{name: "merge-queue"}]},
    "9621": {number: 9621, state: "closed", merged: true, merge_commit_sha: null, head: {sha: $b}, base: {ref: "main"}, labels: []},
    "9622": {number: 9622, state: "open", merged: false, merge_commit_sha: "not-a-sha", head: {sha: $c}, base: {}, labels: []}}' > "$F/pulls.json"
  touch "$F/pull.fail.9623"
}
collect() {
  local F="$1"
  ( env TMPDIR="$F/tmp" FXT="$F" bash -c '
      . "$1/fakejobs.sh"; . "$1/lifecycle-stub.sh"
      . "$2/bin/lib/unblock/collectors/lifecycle.sh"
      unblock_collect_lifecycle cromford example-org/cromford' _ "$T" "$SRC" ) > "$F/out.jsonl" 2> "$F/err"
  echo $? > "$F/rc"
}
field() { jq -c --arg k "$2" "select(.ticket_key == \$k) | $3" "$1/out.jsonl"; }

# ═════ C: the collector ══════════════════════════════════════════════════════
F="$T/c1"; seed "$F"; collect "$F"
check "C1 rc 0" "$(cat "$F/rc")" 0
check "C1 merged pull: merge_sha (40 hex) and base_ref main" \
  "$(field "$F" BH-9460 '[.pr, .pr_state, .merged, .head, .merge_sha, .base_ref, .labels]')" \
  "[9508,\"closed\",true,\"$HEAD9508\",\"$MERGE9508\",\"main\",[\"merge-queue\"]]"
check "C2 merge_commit_sha null -> merge_sha null; base_ref kept" "$(field "$F" BH-9621 '[.merge_sha, .base_ref]')" '[null,"main"]'
check "C2 merge_commit_sha not 40 hex, no base.ref -> both null" "$(field "$F" BH-9622 '[.merge_sha, .base_ref]')" '[null,null]'
check "C3 unread pull -> merge_sha, base_ref, merged null, unknown pull" "$(field "$F" BH-9623 '[.merge_sha, .base_ref, .merged, .unknown]')" '[null,null,null,["pull"]]'
check "C4 one GitHub read per ejected row with a PR, nothing else" "$(sort "$F/ghrest.log" | tr '\n' ' ')" \
  "GET repos/$R/pulls/9508 GET repos/$R/pulls/9621 GET repos/$R/pulls/9622 GET repos/$R/pulls/9623 "
grep -v '"collector-meta"' "$F/out.jsonl" > "$T/records.jsonl"
budget C

# ═════ R: U14-MERGED over the records ════════════════════════════════════════
BASE=$(jq -c 'select(.ticket_key == "BH-9460")' "$T/records.jsonl")
mk() { jq -c --arg k "$1" "$2 | .ticket_key = \$k | .subject = \"cromford:\" + \$k" <<<"$BASE"; }
{
  mk BH-9701 '.'
  mk BH-9702 '.labels = []'
  mk BH-9703 '.merged = false'
  mk BH-9704 '.pr_state = "open" | .merged = false | .merge_sha = null'
  mk BH-9705 '.merge_sha = null'
  mk BH-9706 '.merged = null | .pr_state = null | .head = null | .merge_sha = null | .base_ref = null | .unknown = ["pull"]'
  mk BH-9707 '.kind = "ticket-abandoned" | .phase = "abandoned" | .abandons = 3'
  mk BH-9708 '.merged = "true"'
} > "$T/r.jsonl"
HARNESS="$SRC" bash -c '. "$1/bin/lib/unblock/rules.sh"; ub_rules_eval "$2"' _ "$SRC" "$RULES" < "$T/r.jsonl" > "$T/r.dec" 2>"$T/r.err"
rule() { jq -r --arg s "cromford:$1" 'select(.subject == $s) | .rule_id // "null"' "$T/r.dec"; }
check "R0 one decision per record" "$(grep -c . "$T/r.dec")" 8
check "R1 closed, merged, sha, base, label on -> U14-MERGED" "$(rule BH-9701)" U14-MERGED
check "R1 action settle_merged {ticket_key, merge_sha, base_ref}, class lifecycle-settle" \
  "$(jq -c 'select(.subject == "cromford:BH-9701") | [.decision, .action, .pr, .class]' "$T/r.dec")" \
  "[\"act\",{\"name\":\"settle_merged\",\"args\":{\"ticket_key\":\"BH-9701\",\"merge_sha\":\"$MERGE9508\",\"base_ref\":\"main\"}},9508,\"lifecycle-settle\"]"
check "R1 no requeue and no rebuild for a merged PR" "$(jq -r 'select(.action.name == "requeue" or .action.name == "rebuild") | .subject' "$T/r.dec" | tr '\n' ' ')" "cromford:BH-9704 "
check "R2 same with labels [] -> U14-MERGED" "$(rule BH-9702)" U14-MERGED
check "R3 closed, not merged -> U12" "$(rule BH-9703)" U12
check "R4 open, not merged -> U14-REQUEUE" "$(rule BH-9704)" U14-REQUEUE
check "R5 merged, merge_sha null -> U12" "$(rule BH-9705)" U12
check "R6 pull unread (merged null) -> not U14-MERGED" "$( [ "$(rule BH-9706)" != U14-MERGED ] && echo not)" not
check "R7 ticket-abandoned with merged true -> not U14-MERGED" "$( [ "$(rule BH-9707)" != U14-MERGED ] && echo not)" not
check "R8 merged \"true\" (a string) -> not U14-MERGED" "$( [ "$(rule BH-9708)" != U14-MERGED ] && echo not)" not
budget R

# ═════ A: act.sh settle_merged ═══════════════════════════════════════════════
# The fake gh answers act.sh's reads from <fx>: pull.json (the PR), compare.json
# (absent = rc 1), delete.rc; it logs every call to gh.log.
mkdir -p "$T/agh"
cat > "$T/agh/gh" <<'SH'
#!/bin/bash
p="${*: -1}"; echo "gh $*" >> "$FXT/gh.log"
case "$p" in
  */pulls/9508) cat "$FXT/pull.json" ;;
  */compare/*) echo COMPARE >> "$FXT/order.log"; [ -f "$FXT/compare.json" ] || exit 1; cat "$FXT/compare.json" ;;
  */labels/*) echo DELETE >> "$FXT/order.log"; rc=$(cat "$FXT/delete.rc" 2>/dev/null || echo 0)
              [ "$rc" = 0 ] && echo '[]'; exit "$rc" ;;
  *) echo '[]' ;;
esac
SH
chmod +x "$T/agh/gh"
# mkact <name> <mode> [labels-json] — a case root, a mode row, the fresh pull.
mkact() {
  local A="$T/$1"
  scratch_rm "$A" || exit 1
  mkdir -p "$A/h/bin" "$A/h/logs" "$A/fx"
  cat > "$A/h/bin/jobs-client.sh" <<SH
#!/bin/bash
[ "\$1" = setting-get ] && [ "\$2" = unblock.project.cromford.mode ] && { echo $2; exit 0; }
exit 2
SH
  printf '#!/bin/bash\nprintf "%%s\\n" "$*" >> "$FXT/alerts.log"\n' > "$A/h/bin/lane-alert.sh"
  chmod +x "$A/h/bin/"*.sh
  local labels='[{"name":"merge-queue"},{"name":"ai-build"}]'
  [ -n "${3:-}" ] && labels="$3"
  jq -nc --arg h "$HEAD9508" --arg m "$MERGE9508" --argjson l "$labels" \
    '{number: 9508, state: "closed", merged: true, merge_commit_sha: $m, head: {sha: $h}, base: {ref: "main"}, labels: $l}' > "$A/fx/pull.json"
  echo '{"status":"ahead","ahead_by":3,"behind_by":0}' > "$A/fx/compare.json"
  printf '%s' "$A"
}
# act <case> <decision-json> [nolib] — ub_act in a subshell; "<outcome>|<detail>".
act() {
  local A="$1"
  ( export HARNESS="$A/h" FXT="$A/fx" UNBLOCK_ACT=1 PR_RECORD_WRITES=0 PATH="$T/agh:$PATH"
    . "$T/fakejobs.sh"
    [ "${3:-}" = nolib ] || . "$T/lifecycle-stub.sh"
    . "$SRC/bin/lib/pr-record-write.sh"
    . "$SRC/bin/lib/unblock/act.sh"
    mc_requeue_mergify() { echo "requeue $*" >> "$FXT/mc.log"; return 0; }
    ub_act "$2" >/dev/null
    printf '%s|%s' "$UB_ACT_OUTCOME" "$UB_ACT_DETAIL" )
}
dec() { # dec <ticket> [args-override-jq]
  jq -nc --arg k "$1" --arg h "$HEAD9508" --arg m "$MERGE9508" \
    --arg dk "$(printf 'bh-9586 %s' "$1" | sha256sum | cut -d' ' -f1)" '{decision_key: $dk, project: "cromford",
    repo: "example-org/cromford", subject_kind: "build", subject: "cromford:\($k)", pr: 9508, head: $h,
    rule_id: "U14-MERGED", class: "lifecycle-settle", cites: ["G4", "G12"],
    action: {name: "settle_merged", args: {ticket_key: $k, merge_sha: $m, base_ref: "main"}}}' | jq -c "${2:-.}"
}
tbody() { jq -c "$2" "$1/fx/transitions.log" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
deletes() { cnt '-X DELETE' "$1/fx/gh.log"; }

A=$(mkact a1 act)
check "A1 compare ahead, label on: done phase merged; label removed" "$(act "$A" "$(dec BH-9711)")" "done|phase merged; label removed"
check "A1 transition {merged, lifecycle, pr 9508}" "$(tbody "$A" '[.ticket_key, .to_phase, .actor, .pr, (.reason | test("^U14-MERGED settle, merge 9508beef9508 on main, decision [0-9a-f]{12}$"))]')" \
  '["BH-9711","merged","lifecycle",9508,true]'
check "A1 one DELETE of issues/9508/labels/merge-queue" "$(grep -c -- "-X DELETE repos/$R/issues/9508/labels/merge-queue\$" "$A/fx/gh.log") $(deletes "$A")" "1 1"
check "A1 compare path merge_sha...base_ref" "$(grep -c "api repos/$R/compare/$MERGE9508...main\$" "$A/fx/gh.log")" 1
check "A1 order: compare, transition, delete" "$(tr '\n' ' ' < "$A/fx/order.log")" "COMPARE TRANSITION DELETE "
check "A1 0 requeue and 0 launch calls" "$(cnt . "$A/fx/mc.log") $(cnt launch "$A/fx/jobs.log")" "0 0"
check "A1 one unblock.log line" "$(grep -c 'act cromford cromford:BH-9711 U14-MERGED settle_merged done phase merged; label removed' "$A/h/logs/unblock.log")" 1

A=$(mkact a2 act '[{"name":"ai-build"}]')
check "A2 label absent: done phase merged; no label, 0 DELETE" "$(act "$A" "$(dec BH-9712)") $(deletes "$A")" "done|phase merged; no label 0"
A=$(mkact a2b act '[{"name":"merge-queue"}]')
check "A2 MC_MERGIFY_LABEL=queue-x: the merge-queue label is not that label" "$(MC_MERGIFY_LABEL=queue-x act "$A" "$(dec BH-9712)") $(deletes "$A")" "done|phase merged; no label 0"

A=$(mkact a3 act); echo '{"status":"identical","ahead_by":0,"behind_by":0}' > "$A/fx/compare.json"
check "A3 compare identical: done" "$(act "$A" "$(dec BH-9713)")" "done|phase merged; label removed"

A=$(mkact a4 act); echo '{"status":"behind","ahead_by":0,"behind_by":2}' > "$A/fx/compare.json"
check "A4 compare behind: refused, 0 transitions, 0 DELETE" "$(act "$A" "$(dec BH-9714)") $(cnt . "$A/fx/transitions.log") $(deletes "$A")" "refused|merge-sha-not-on-base:behind 0 0"
A=$(mkact a5 act); echo '{"status":"diverged","ahead_by":4,"behind_by":1}' > "$A/fx/compare.json"
check "A5 compare diverged: refused, 0 transitions, 0 DELETE" "$(act "$A" "$(dec BH-9715)") $(cnt . "$A/fx/transitions.log") $(deletes "$A")" "refused|merge-sha-not-on-base:diverged 0 0"

A=$(mkact a6 act); rm -f "$A/fx/compare.json"
check "A6 compare rc 1: failed compare-unreadable, 0 transitions" "$(act "$A" "$(dec BH-9716)") $(cnt . "$A/fx/transitions.log")" "failed|compare-unreadable 0"
echo '{"message":"Not Found"}' > "$A/fx/compare.json"
check "A6 compare 404 body: failed compare-unreadable, 0 transitions" "$(act "$A" "$(dec BH-9716)") $(cnt . "$A/fx/transitions.log")" "failed|compare-unreadable 0"
: > "$A/fx/compare.json"
check "A6 compare empty body: failed compare-unreadable" "$(act "$A" "$(dec BH-9716)") $(cnt . "$A/fx/transitions.log")" "failed|compare-unreadable 0"

A=$(mkact a7 act); echo 1 > "$A/fx/delete.rc"
check "A7 DELETE fails: failed label-remove-failed after phase merged" "$(act "$A" "$(dec BH-9717)")" "failed|label-remove-failed after phase merged"
check "A7 the phase move happened first" "$(tbody "$A" .to_phase)" '"merged"'

A=$(mkact a8 shadow)
check "A8 shadow: would WOULD_SETTLE_MERGED" "$(act "$A" "$(dec BH-9718)")" "would|WOULD_SETTLE_MERGED"
check "A8 shadow: 0 GitHub calls, 0 transitions" "$(cnt . "$A/fx/gh.log") $(cnt . "$A/fx/transitions.log")" "0 0"

A=$(mkact a9 act); jq -c '.merged = false' "$A/fx/pull.json" > "$A/fx/p" && mv "$A/fx/p" "$A/fx/pull.json"
check "A9 fresh pull merged false: refused not-merged, 0 writes" "$(act "$A" "$(dec BH-9719)") $(cnt . "$A/fx/transitions.log") $(deletes "$A")" "refused|not-merged 0 0"
A=$(mkact a9b act); jq -c --arg m "$(H40 0badc0de)" '.merge_commit_sha = $m' "$A/fx/pull.json" > "$A/fx/p" && mv "$A/fx/p" "$A/fx/pull.json"
check "A9 fresh merge sha differs: refused merge-sha-moved" "$(act "$A" "$(dec BH-9719)") $(cnt . "$A/fx/transitions.log")" "refused|merge-sha-moved 0"
A=$(mkact a9c act); jq -c '.base.ref = "release"' "$A/fx/pull.json" > "$A/fx/p" && mv "$A/fx/p" "$A/fx/pull.json"
check "A9 fresh base differs: refused base-moved" "$(act "$A" "$(dec BH-9719)") $(cnt . "$A/fx/transitions.log")" "refused|base-moved 0"
A=$(mkact a9d act); echo 9 > "$A/fx/transition.rc"; echo '{"error":"illegal_transition","current":"merged","to":"merged"}' > "$A/fx/transition.body"
check "A9 transition 409 current merged: done (already), label still removed" "$(act "$A" "$(dec BH-9719)") $(deletes "$A")" "done|phase merged; label removed 1"
A=$(mkact a9e act); echo 9 > "$A/fx/transition.rc"; echo '{"error":"illegal_transition","current":"ejected","to":"merged","allowed":["in_queue","pr_open","abandoned","closed"]}' > "$A/fx/transition.body"
check "A9 transition 409 illegal from ejected (worker not deployed): refused phase-illegal, 0 DELETE" "$(act "$A" "$(dec BH-9719)") $(deletes "$A")" "refused|phase-illegal 0"
echo '{"error":"illegal_transition","current":"closed","to":"merged"}' > "$A/fx/transition.body"
check "A9 transition 409 current closed: refused phase-moved:closed" "$(act "$A" "$(dec BH-9719)")" "refused|phase-moved:closed"
echo '{"error":"stale"}' > "$A/fx/transition.body"
check "A9 transition 409 with no current: failed phase-unreadable" "$(act "$A" "$(dec BH-9719)")" "failed|phase-unreadable"
echo 2 > "$A/fx/transition.rc"
check "A9 transition 404: refused no-row" "$(act "$A" "$(dec BH-9719)")" "refused|no-row"
echo 1 > "$A/fx/transition.rc"
check "A9 transition rc 1: failed transition rc 1, 0 DELETE" "$(act "$A" "$(dec BH-9719)") $(deletes "$A")" "failed|transition rc 1 0"
A=$(mkact a9f act)
jq -c --arg h "$(H40 77777777)" '.head.sha = $h' "$A/fx/pull.json" > "$A/fx/p" && mv "$A/fx/p" "$A/fx/pull.json"
check "A9 head moved: refused head-moved, 0 compare" "$(act "$A" "$(dec BH-9719)") $(grep -c compare "$A/fx/gh.log")" "refused|head-moved 0"

A=$(mkact a10 act)
check "A10 class lifecycle-settle, action settle_merged: not never-auto, 0 alerts" "$(act "$A" "$(dec BH-9720)" | cut -d'|' -f1) $(cnt . "$A/fx/alerts.log")" "done 0"
A=$(mkact a10b act)
check "A10 lib absent: failed lifecycle-libs-not-loaded, 0 GitHub calls" "$(act "$A" "$(dec BH-9721)" nolib) $(cnt . "$A/fx/gh.log")" "failed|lifecycle-libs-not-loaded 0"
check "A10 a bad merge_sha is bad input" "$(act "$A" "$(dec BH-9722 '.action.args.merge_sha = "abc"')")" "|"
check "A10 a base_ref with .. is bad input" "$(act "$A" "$(dec BH-9722 '.action.args.base_ref = "main/../x"')")" "|"
check "A10 a bad ticket_key is bad input" "$(act "$A" "$(dec BH-9722 '.action.args.ticket_key = "bh 1; rm"')")" "|"
budget A

# ═════ E1: end to end, the BH-9460 / PR 9508 shape ═══════════════════════════
F="$T/e1"; seed "$F"; collect "$F"
grep -v '"collector-meta"' "$F/out.jsonl" | HARNESS="$SRC" bash -c '. "$1/bin/lib/unblock/rules.sh"; ub_rules_eval "$2"' _ "$SRC" "$RULES" > "$F/dec" 2>/dev/null
D=$(jq -c 'select(.subject == "cromford:BH-9460")' "$F/dec")
check "E1 BH-9460 decides U14-MERGED" "$(jq -r .rule_id <<<"$D")" U14-MERGED
check "E1 BH-9621 (merged, no merge sha) does not" "$(jq -r 'select(.subject == "cromford:BH-9621") | .rule_id // "null"' "$F/dec")" U12
A=$(mkact e1a act)
check "E1 ub_act on the decision: done phase merged; label removed" "$(act "$A" "$D")" "done|phase merged; label removed"
check "E1 transition {BH-9460, merged, lifecycle, pr 9508}" "$(tbody "$A" '[.project, .ticket_key, .to_phase, .actor, .pr]')" '["cromford","BH-9460","merged","lifecycle",9508]'
check "E1 one label DELETE" "$(deletes "$A")" 1
budget E

echo
echo "unblock-lifecycle-merged.bh-9586: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
