#!/bin/bash
# tests/archie-merge.bh-9212-test.sh — BH-9212: Archie's gated merge.
#
# Two halves.
#   S  the soul text Archie reads (prompts/archie-soul.d/10-authority.md and
#      40-earned-autonomy.md) and the fleet rule render (rules/CLAUDE.md).
#   G/W/R/X  the SHIPPED bin/archie-merge.sh, run as a process against a
#      scratch $HARNESS that holds its real lib closure.
#
# WHAT IS STUBBED, and only this. ARCHIE_MERGE_FIXTURE=$T/fx.sh (read by the
# script only under HARNESS_TEST_SANDBOX=1):
#   _jobs_req     a jq model of GET /api/settings/<key>, PUT /api/settings
#                 and /api/archie/actions (claim, outcome, day count); every
#                 POST and PUT body is logged;
#   gh_rest       answers from $T/gh/<path> files (a missing file is a 404);
#   vd_standing   head-bound verdicts from $T/verdict.<n> (+ .head);
#   ila_accepted  the iron-law accept from $T/ila.<n> (the head it names);
#   mc_enqueue_mergify  logs to $T/enqueue.log, rc from $T/enqueue.rc;
#   mc_queue_provider, mc_mergify_witness, _ae_required_checks, flag_active,
#   pause_active, to_lane_hold, pdg_hold, to_lane_lead_fence, bg_scan,
#   main_red_hold  answered from $T files.
# Real and unstubbed: the gate chain and its order, afq_pr_fresh, afq_approved's
# reviews read, the check-runs read, mc_pr_diff + mc_iron_law_scan,
# hold_check_thread over the PR comments, afq_claim / afq_close, afq_cap_ok, the
# conductor's PR lock, and setting_get / setting_set over the one settings row
# archie.merge.authority (merge | ask_first). The worker's own rule (a bearer
# may only write ask_first) is pinned by
# worker/jobs/test/archie-merge-authority.bh-9212.test.js.
#
# Each case uses its own PR number, its own fixture files and its own db rows,
# so no case depends on another one's state.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/archie-merge.bh-9212-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
command -v jq >/dev/null 2>&1 || { echo "archie-merge: jq is required"; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "archie-merge: flock is required"; exit 1; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); return 0; }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check() { if eval "$2"; then ok; else bad "$1"; fi; }
eq()  { if [ "$2" = "$3" ]; then ok; else bad "$1: want [$3] got [$2]"; fi; }

# The product paths this ticket ships (D41).
for f in "$DIR/bin/archie-merge.sh" "$DIR/bin/lib/archie-merge.sh" \
         "$DIR/prompts/archie-soul.d/10-authority.md" "$DIR/prompts/archie-soul.d/40-earned-autonomy.md" \
         "$DIR/catalog/prompts/replays/archie-merge/SKILL.md" "$DIR/docs/verification-map/entries/BH-9212.md" "$DIR/docs/notes/2026-11-08-BH-9212-archie-gated-merge.md" \
         "$DIR/worker/jobs/schema.d/202611080306-bh-9212-archie-merge-authority.sql" "$DIR/worker/jobs/test/archie-merge-authority.bh-9212.test.js"; do
  if [ -f "$f" ]; then ok; else bad "missing $f"; fi
done

# ═════ S: the soul and the fleet rule ═══════════════════════════════════════
AUTH="$DIR/prompts/archie-soul.d/10-authority.md"
EA_F="$DIR/prompts/archie-soul.d/40-earned-autonomy.md"
# soul_s1 <file> -> rc 0 when a paragraph starts `MAY merge, only through
#   bin/archie-merge.sh` after `MAY, without asking:` and before `NEVER:`.
soul_s1() {
  awk '/^MAY, without asking:/{m=NR} /^MAY merge, only through bin\/archie-merge\.sh/{g=NR} /^NEVER:/{v=NR}
       END{exit !(m && g && v && m < g && g < v)}' "$1"
}
check "S1 a 'MAY merge, only through bin/archie-merge.sh' paragraph sits between MAY and NEVER" 'soul_s1 "$AUTH"'
GATEB=$(sed -n '/^MAY merge, only through/,/^NEVER:/p' "$AUTH" | tr '\n' ' ')
for s in 'exact head sha' 'MERGE-WITH-NOTES' 'mergeable_state' 'clean' 'iron-law' 'automerge-disabled' 'main-red' 'HOLD' '@mergifyio queue'; do
  check "S1 the merge paragraph names [$s]" 'grep -qF -- "$s" <<<"$GATEB"'
done
NEVB=$(sed -n '/^NEVER:/,/^REPORT:/p' "$AUTH" | tr '\n' ' ')
check "S2 the NEVER block names an ungated merge" 'grep -qF "ungated" <<<"$NEVB"'
check "S2 the NEVER block still names gh pr merge" 'grep -qF "gh pr merge" <<<"$NEVB"'
check "S2 the soul says Never merge by any other command" 'grep -qF "Never merge by any other command" <<<"$(tr "\n" " " < "$AUTH")"'
for s in 'push to main' 'production DB write' 'deploy outside the deploy lanes' 'spend cap' 'client-visible' 'launching a box'; do
  check "S3 the NEVER block still names [$s]" 'grep -qF -- "$s" <<<"$NEVB"'
done
EA=$(tr '\n' ' ' < "$EA_F")
for s in 'archie-merge' 'bin/archie-merge.sh reverted' 'archie.merge.authority' 'direct merge' 'can never be delegated' 'ask-first'; do
  check "S4 40-earned-autonomy.md names [$s]" 'grep -qF -- "$s" <<<"$EA"'
done
check "S4 the soul says Archie never sets the authority himself" 'grep -qF "you never set that value" <<<"$EA"'
check "S4 the soul gives Archie no restore verb" '! grep -qF "archie-merge.sh restore" <<<"$EA"'
check "S5 no 'waits for the operator' in 10-authority.md" '! grep -qiF "waits for the operator" "$AUTH"'
check "S5 no MUST ASK in 10-authority.md" '! grep -qiF "MUST ASK" "$AUTH"'
check "S5 no MUST ASK in 40-earned-autonomy.md" '! grep -qiF "MUST ASK" "$EA_F"'
AUTHB=$(tr '\n' ' ' < "$AUTH")
check "S6 the soul says each merge is reported in the next reply" 'grep -qF "next reply" <<<"$AUTHB"'
check "S6 the soul names the rung queued" 'grep -qF "queued for merge" <<<"$AUTHB"'
check "S7 rules/CLAUDE.md names bin/archie-merge.sh" 'grep -qF "bin/archie-merge.sh" "$DIR/rules/CLAUDE.md"'
check "S7 the rules topic names bin/archie-merge.sh" 'grep -qF "bin/archie-merge.sh" "$DIR/rules/topics/01-iron-guardrails.md"'
# Mutation: the pre-change authority block (a merge only under NEVER) is red on S1.
cat > "$T/old-auth.md" <<'MD'
Authority.
MAY, without asking: everything a factory lever does through the existing
gates.
NEVER: a direct merge (`gh pr merge`), a push to main, a production DB write.
REPORT: a daily factory digest.
MD
check "S1-mutation the pre-change authority block is red on S1" '! soul_s1 "$T/old-auth.md"'

if [ ! -f "$DIR/bin/archie-merge.sh" ]; then
  echo "archie-merge: $PASS passed, $FAIL failed"; exit 1
fi

# ═════ the scratch harness ═══════════════════════════════════════════════════
NOW=1793952000                       # 2026-11-06T08:00:00Z
DAY=2026-11-06
export HOME="$T/home"
mkdir -p "$T/home" "$T/tmp" "$T/fakebin"
sha() { printf '%040x' "$1"; }
H="$T/h"
mkdir -p "$H/bin" "$H/env" "$H/logs" "$H/flags" "$H/state"
: > "$H/flags/merge-conductor-merge"; : > "$H/flags/merge-conductor-actions"   # merges on
: > "$H/env/global.env"
cat > "$H/bin/fleet-conf.sh" <<'SH'
#!/bin/bash
case "$1" in
  --projects) echo fixt ;;
  --*) ;;
  *) [ "${2:-}" = repo ] && echo "acme/$1" ;;
esac
SH
cat > "$H/bin/alert-line.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "$FXT/alerts.log"
SH
chmod +x "$H/bin/fleet-conf.sh" "$H/bin/alert-line.sh"
# The script's closure, plus jobs-client.sh's (it loads bin/lib/jobs/ through
# a module list the static scan does not follow).
for s in bin/archie-merge.sh bin/jobs-client.sh; do
  scratch_install_closure "$s" "$H" >/dev/null || { echo "archie-merge: the closure of $s did not install"; exit 1; }
done
# Nothing reaches the network: gh and curl log and fail.
printf '#!/bin/bash\nprintf "gh %%s\\n" "$*" >> "$FXT/net.log"\nexit 1\n' > "$T/fakebin/gh"
printf '#!/bin/bash\nprintf "curl %%s\\n" "$*" >> "$FXT/net.log"\nexit 7\n' > "$T/fakebin/curl"
chmod +x "$T/fakebin/gh" "$T/fakebin/curl"

cat > "$T/fx.sh" <<'SH'
fx_enc() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g'; }
_jobs_req() {
  local m="$1" p="$2" b="${3:-}" out code=200 db="$FXT/db.json" key t=2026-11-06T08:00:00Z
  JOBS_HTTP=""; JOBS_BODY=""
  case "$p" in /api/flags*|/api/lanes*|/api/verdicts*|/api/job*|/api/pr-*|/api/pauses*) JOBS_HTTP=404; return 2 ;; esac
  printf '%s %s %s\n' "$m" "$p" "$b" >> "$FXT/reqlog"
  case "$m ${p%%\?*}" in
    GET\ /api/settings/*)
      [ -f "$FXT/settings.down" ] && { JOBS_HTTP=503; return 1; }
      key=${p#/api/settings/}
      [ "$key" = archie.merge.authority ] && [ -f "$FXT/authority.down" ] && { JOBS_HTTP=503; return 1; }
      [ "$key" = archie.merge.authority ] && [ -f "$FXT/authority.unproven" ] && { JOBS_HTTP=409; return 9; }
      out=$(jq -c --arg k "$key" 'select(.settings | has($k)) | {setting: {key: $k, value: .settings[$k]}}' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; return 2; } ;;
    "PUT /api/settings")
      printf '%s\n' "$b" >> "$FXT/puts.log"
      [ -f "$FXT/put.down" ] && { JOBS_HTTP=503; return 1; }
      jq --argjson b "$b" '.settings[$b.key] = $b.value | .notes[$b.key] = ($b.note // "")' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
      out=$(jq -c --argjson b "$b" '{ok: true, setting: {key: $b.key, value: $b.value}}' <<<'{}') ;;
    "POST /api/archie/actions")
      printf '%s\n' "$b" >> "$FXT/claims.log"
      [ -f "$FXT/claim.down" ] && { JOBS_HTTP=503; return 1; }
      key=$(jq -r .dedupe_key <<<"$b")
      out=$(jq -c --arg k "$key" '.actions[] | select(.dedupe_key == $k)' "$db")
      if [ -z "$out" ]; then
        jq --argjson b "$b" --arg t "$t" '.actions += [$b + {id: ((.actions | length) + 1), day: $t[0:10], created_at: $t, updated_at: $t}]' \
          "$db" > "$db.tmp" && mv "$db.tmp" "$db"
        out=$(jq -c --arg k "$key" '{ok: true, created: true, action: (.actions[] | select(.dedupe_key == $k))}' "$db"); code=201
      else
        out=$(jq -c '{ok: true, existing: true, action: .}' <<<"$out")
      fi ;;
    "POST /api/archie/actions/outcome")
      printf '%s\n' "$b" >> "$FXT/closes.log"
      out=$(jq -c --argjson b "$b" '.actions[] | select(.id == $b.id and .dedupe_key == $b.dedupe_key)' "$db")
      [ -n "$out" ] || { JOBS_HTTP=404; return 2; }
      jq --argjson b "$b" '.actions |= map(if .id == $b.id then .outcome = $b.outcome | .why = ($b.why // .why)
          | .evidence = ($b.evidence // .evidence) else . end)' "$db" > "$db.tmp" && mv "$db.tmp" "$db"
      out=$(jq -c --argjson b "$b" '{ok: true, action: (.actions[] | select(.id == $b.id))}' "$db") ;;
    "GET /api/archie/actions")
      [ -f "$FXT/count.down" ] && { JOBS_HTTP=503; return 1; }
      out=$(jq -c '[.actions[] | select(.playbook == "queue-enqueue")] as $r
        | {ok: true, actions: $r, counts: (reduce $r[] as $x ({}; .[$x.playbook][$x.mode][$x.outcome] += 1)), truncated: false}' "$db") ;;
    *) JOBS_HTTP=404; return 2 ;;
  esac
  JOBS_HTTP=$code; JOBS_BODY="$out"; printf '%s' "$out"; return 0
}
gh_rest() {
  local m="$1" p="$2" f
  printf '%s %s %s\n' "$m" "$p" "${*:3}" >> "$FXT/ghrest.log"
  case " ${*:3} " in *vnd.github.v3.diff*) p="diff/$p" ;; esac
  f="$FXT/gh/$(fx_enc "$p")"
  [ -f "$f" ] || { GH_REST_STATUS=404; return 44; }
  GH_REST_STATUS=200; cat "$f"; return 0
}
flag_active() { [ -f "$HARNESS/flags/$1" ]; }
pause_active() { [ -f "$FXT/pause.$1" ]; }
mc_queue_provider() { cat "$FXT/provider" 2>/dev/null || printf mergify; }
mc_mergify_witness() { [ -f "$FXT/witness.$(basename "$2")" ] && return 0; return 1; }
_ae_required_checks() { cat "$FXT/required"; }
to_lane_hold() { [ -f "$FXT/held.$3" ]; }
pdg_hold() { return 1; }
to_lane_lead_fence() { TO_LEAD_CLEARED=0; return 1; }
bg_scan() { return 0; }
main_red_hold() { [ -f "$FXT/mainred" ] && { MRG_FLAG=main-red-acme; return 0; }; return 1; }
vd_standing() {
  [ -f "$FXT/vd.down" ] && return 2
  [ -f "$FXT/verdict.$2" ] || return 1
  [ -f "$FXT/verdict.$2.head" ] && [ "$(cat "$FXT/verdict.$2.head")" != "$3" ] && return 1
  printf '%s\tlead\t%s\t2026-11-06T07:00:00Z\t-\tlead\n' "$(cat "$FXT/verdict.$2")" "$((7000 + $2))"
}
ila_accepted() {
  local n=${1##*/}
  [ -f "$FXT/ila.$n" ] || return 1
  [ "$(cat "$FXT/ila.$n")" = "$2" ] || return 1
  printf 'operator'
}
mc_enqueue_mergify() {
  printf '%s %s %s\n' "$1" "$2" "$3" >> "$FXT/enqueue.log"
  return "$(cat "$FXT/enqueue.rc" 2>/dev/null || echo 0)"
}
:
SH

export HARNESS="$H" FXT="$T" PATH="$T/fakebin:$PATH" JOBS_URL=https://jobs.invalid HARNESS_SECRET=fixture-secret \
       MC_REHYDRATE=0 TMPDIR="$T/tmp" ARCHIE_MERGE_NOW="$NOW" LANE_GATE_DISABLE=1   # switches read flags/ files, no settings list read
printf '%s\n' '{"settings": {"archie.merge.authority": "merge"}, "notes": {}, "actions": []}' > "$T/db.json"
printf 'ci\nlint\n' > "$T/required"

gh_put() { mkdir -p "$T/gh"; printf '%s' "$2" > "$T/gh/$(printf '%s' "$1" | sed 's/[^A-Za-z0-9]/_/g')"; }
# pr_world <n> <head> [mergeable_state] [labels-json] — a clean, approved,
# green PR with an iron-law clean diff. A case then breaks one thing.
pr_world() {
  local n="$1" head="$2" ms="${3:-clean}" lbl="${4:-[]}"
  gh_put "repos/acme/fixt/pulls/$n" "$(jq -nc --arg h "$head" --arg ms "$ms" --argjson l "$lbl" \
    '{state: "open", merged_at: null, draft: false, mergeable_state: $ms, head: {sha: $h, ref: "fix/x"},
      base: {ref: "main"}, user: {login: "dev"}, labels: $l, body: ""}')"
  gh_put "repos/acme/fixt/pulls/$n/reviews?per_page=100" '[]'
  gh_put "repos/acme/fixt/commits/$head/check-runs?per_page=100" \
    '{"total_count": 3, "check_runs": [
       {"id": 501, "name": "ci", "status": "completed", "conclusion": "failure"},
       {"id": 502, "name": "ci", "status": "completed", "conclusion": "success"},
       {"id": 503, "name": "lint", "status": "completed", "conclusion": "neutral"}]}'
  gh_put "repos/acme/fixt/issues/$n/comments?per_page=100&page=1" '[]'
  gh_put "diff/repos/acme/fixt/pulls/$n" $'diff --git a/src/a.js b/src/a.js\n+++ b/src/a.js\n+const ok = 1;\n'
  printf 'MERGE\n' > "$T/verdict.$n"; printf '%s' "$head" > "$T/verdict.$n.head"
}
# am <args...> — one run of the shipped script; OUT, RC.
am() {
  OUT=$(HARNESS_TEST_SANDBOX=1 ARCHIE_MERGE_FIXTURE="$T/fx.sh" bash "$H/bin/archie-merge.sh" "$@" 2>"$T/am.err"); RC=$?
}
# merge <n> <head> — the merge verb on acme/fixt#<n>.
merge() { am fixt "acme/fixt#$1" "$2" --reason "fixture: case $1"; }
sends() { grep -c " https://github.com/acme/fixt/pull/$1 " "$T/enqueue.log" 2>/dev/null || true; }
claims() { grep -c "\"pr\":$1," "$T/claims.log" 2>/dev/null || true; }
# hold_case <name> <n> <gate> [rc] — a refusal: the gate word, the rc, no send, no claim.
hold_case() {
  local name="$1" n="$2" gate="$3" want="${4:-3}" word=HOLD
  [ "$want" = 75 ] && word=UNREADABLE
  eq "$name rc" "$RC" "$want"
  check "$name prints ARCHIE-MERGE $word gate=$gate (got: $OUT)" 'grep -qE "^ARCHIE-MERGE $word acme/fixt#$n [0-9a-f]{12} gate=$gate( |$)" <<<"$OUT"'
  eq "$name mc_enqueue_mergify calls" "$(sends "$n")" 0
  eq "$name claims" "$(claims "$n")" 0
}

# ═════ W: the merge path ═════════════════════════════════════════════════════
HW=$(sha 1001); pr_world 1001 "$HW"
merge 1001 "$HW"
eq "W2 rc" "$RC" 0
check "W2 prints ARCHIE-MERGE QUEUED (got: $OUT)" 'grep -qF "ARCHIE-MERGE QUEUED acme/fixt#1001 ${HW:0:12}" <<<"$OUT"'
eq "W2 mc_enqueue_mergify called once" "$(sends 1001)" 1
check "W2 mc_enqueue_mergify got the head" 'grep -qF "acme/fixt https://github.com/acme/fixt/pull/1001 $HW" "$T/enqueue.log"'
CL=$(grep '"pr":1001,' "$T/claims.log" | head -1)
eq "W1 evidence.source" "$(jq -r .evidence.source <<<"$CL")" archie-merge
eq "W1 evidence.head" "$(jq -r .evidence.head <<<"$CL")" "$HW"
eq "W1 evidence.verdict_id" "$(jq -r .evidence.verdict_id <<<"$CL")" 8001
eq "W1 evidence.check_run_ids (newest run per required name)" "$(jq -c .evidence.check_run_ids <<<"$CL")" '[502,503]'
eq "W1 evidence.reason" "$(jq -r .evidence.reason <<<"$CL")" "fixture: case 1001"
eq "W1 claim repo" "$(jq -r .repo <<<"$CL")" acme/fixt
eq "W1 claim playbook" "$(jq -r .playbook <<<"$CL")" queue-enqueue
eq "W1 claim dedupe_key" "$(jq -r .dedupe_key <<<"$CL")" "archie-merge:acme/fixt#1001:$HW"
eq "W1 the row is closed done" "$(jq -r --arg k "archie-merge:acme/fixt#1001:$HW" '.actions[] | select(.dedupe_key == $k) | .outcome' "$T/db.json")" done
check "W1 one line in logs/archie-merge.log" 'grep -qF "QUEUED acme/fixt#1001" "$H/logs/archie-merge.log"'
check "X2 the PR lock was released after QUEUED" 'flock -n "$H/locks/merge-conductor-fixt-1001.lock" true'

# W3 the send fails: the row closes failed, no QUEUED line, rc 1.
HW=$(sha 1003); pr_world 1003 "$HW"; printf '1\n' > "$T/enqueue.rc"
merge 1003 "$HW"; rm -f "$T/enqueue.rc"
eq "W3 rc" "$RC" 1
check "W3 no QUEUED line" '! grep -qF QUEUED <<<"$OUT"'
eq "W3 the row is closed failed" "$(jq -r --arg k "archie-merge:acme/fixt#1003:$HW" '.actions[] | select(.dedupe_key == $k) | .outcome' "$T/db.json")" failed
check "X2 the PR lock was released after a failed send" 'flock -n "$H/locks/merge-conductor-fixt-1003.lock" true'

# W4 the claim fails: nothing is sent, rc 75.
HW=$(sha 1004); pr_world 1004 "$HW"; : > "$T/claim.down"
merge 1004 "$HW"; rm -f "$T/claim.down"
eq "W4 rc" "$RC" 75
check "W4 UNREADABLE gate=audit" 'grep -qE "^ARCHIE-MERGE UNREADABLE acme/fixt#1004 [0-9a-f]{12} gate=audit" <<<"$OUT"'
eq "W4 nothing sent" "$(sends 1004)" 0

# W5 Mergify already witnesses the head: ALREADY, no claim, no send.
HW=$(sha 1005); pr_world 1005 "$HW"; : > "$T/witness.1005"
merge 1005 "$HW"
eq "W5 rc" "$RC" 0
check "W5 ALREADY" 'grep -qF "ARCHIE-MERGE ALREADY acme/fixt#1005" <<<"$OUT"'
eq "W5 no claim" "$(claims 1005)" 0
eq "W5 no send" "$(sends 1005)" 0
# W5b a second run after a QUEUED on the same head, once the audit row exists: no second send.
HW=$(sha 1001)
merge 1001 "$HW"
eq "W5b a rerun on a queued head sends nothing more" "$(sends 1001)" 1
check "W5b the rerun is not QUEUED" '! grep -qF QUEUED <<<"$OUT"'
eq "W5b rerun rc" "$RC" 0
check "W5b the rerun prints ALREADY gate=audit (got: $OUT)" 'grep -qE "^ARCHIE-MERGE ALREADY acme/fixt#1001 [0-9a-f]{12} gate=audit" <<<"$OUT"'
eq "W5b still one audit row for the head" "$(jq --arg k "archie-merge:acme/fixt#1001:$HW" '[.actions[] | select(.dedupe_key == $k)] | length' "$T/db.json")" 1

# W6 the stale-row knob ARCHIE_FMQ_RETRY_S out of range: one WARN line, the fallback, the merge still runs.
HW=$(sha 1006); pr_world 1006 "$HW"
ARCHIE_FMQ_RETRY_S=5 merge 1006 "$HW"
eq "W6 rc" "$RC" 0
check "W6 the WARN line names the knob (got: $OUT)" 'grep -qF "ARCHIE-MERGE WARN ARCHIE_FMQ_RETRY_S=5 is outside 60..86400; using the fallback 1800" <<<"$OUT"'
HW=$(sha 1007); pr_world 1007 "$HW"
ARCHIE_FMQ_RETRY_S=600 merge 1007 "$HW"
eq "W6 an in-range value: rc" "$RC" 0
check "W6 an in-range value prints no WARN" '! grep -qF "ARCHIE-MERGE WARN" <<<"$OUT"'

# ═════ G: every gate refuses ═════════════════════════════════════════════════
# G1 not a Mergify repo.
HW=$(sha 1101); pr_world 1101 "$HW"; printf 'github' > "$T/provider"
merge 1101 "$HW"; rm -f "$T/provider"
hold_case G1 1101 no-mergify
# G2 the head moved after the verdict: the live head is B, the argument is A.
HA=$(sha 1102); HB=$(sha 11020); pr_world 1102 "$HB"; printf '%s' "$HA" > "$T/verdict.1102.head"
merge 1102 "$HA"
hold_case G2 1102 head-moved
# G3 the verdict stands on an older head only.
HW=$(sha 1103); pr_world 1103 "$HW"; printf '%s' "$(sha 11030)" > "$T/verdict.1103.head"
merge 1103 "$HW"
hold_case G3 1103 verdict
# G4 a standing BLOCK.
HW=$(sha 1104); pr_world 1104 "$HW"; printf 'BLOCK\n' > "$T/verdict.1104"
merge 1104 "$HW"
hold_case G4 1104 verdict
# G4b MERGE-WITH-NOTES passes the verdict gate, but a reviewer's latest CHANGES_REQUESTED refuses.
HW=$(sha 1114); pr_world 1114 "$HW"; printf 'MERGE-WITH-NOTES\n' > "$T/verdict.1114"
gh_put "repos/acme/fixt/pulls/1114/reviews?per_page=100" '[{"state": "CHANGES_REQUESTED", "user": {"login": "rev"}}]'
merge 1114 "$HW"
hold_case G4b 1114 verdict
# G5 a required check is in progress (a success conclusion with no completion is a near miss).
HW=$(sha 1105); pr_world 1105 "$HW"
gh_put "repos/acme/fixt/commits/$HW/check-runs?per_page=100" \
  '{"total_count": 2, "check_runs": [{"id": 601, "name": "ci", "status": "in_progress", "conclusion": "success"},
     {"id": 602, "name": "lint", "status": "completed", "conclusion": "success"}]}'
merge 1105 "$HW"
hold_case G5 1105 checks
# G5b a required check is red.
HW=$(sha 1115); pr_world 1115 "$HW"
gh_put "repos/acme/fixt/commits/$HW/check-runs?per_page=100" \
  '{"total_count": 2, "check_runs": [{"id": 611, "name": "ci", "status": "completed", "conclusion": "failure"},
     {"id": 612, "name": "lint", "status": "completed", "conclusion": "success"}]}'
merge 1115 "$HW"
hold_case G5b 1115 checks
# G6 a required name is absent from the page.
HW=$(sha 1106); pr_world 1106 "$HW"
gh_put "repos/acme/fixt/commits/$HW/check-runs?per_page=100" \
  '{"total_count": 1, "check_runs": [{"id": 621, "name": "ci", "status": "completed", "conclusion": "success"}]}'
merge 1106 "$HW"
hold_case G6 1106 checks
# G6b the page is partial (total_count past the page): unreadable, never green.
HW=$(sha 1116); pr_world 1116 "$HW"
gh_put "repos/acme/fixt/commits/$HW/check-runs?per_page=100" \
  '{"total_count": 140, "check_runs": [{"id": 631, "name": "ci", "status": "completed", "conclusion": "success"},
     {"id": 632, "name": "lint", "status": "completed", "conclusion": "success"}]}'
merge 1116 "$HW"
hold_case G6b 1116 checks 75
# G7 mergeable_state unknown; G8 unstable; G8b blocked.
HW=$(sha 1107); pr_world 1107 "$HW" unknown; merge 1107 "$HW"; hold_case G7 1107 mergeable
HW=$(sha 1108); pr_world 1108 "$HW" unstable; merge 1108 "$HW"; hold_case G8 1108 mergeable
HW=$(sha 1118); pr_world 1118 "$HW" blocked; merge 1118 "$HW"; hold_case G8b 1118 mergeable
# G9 one iron-law hit with no accept.
HW=$(sha 1109); pr_world 1109 "$HW"
gh_put "diff/repos/acme/fixt/pulls/1109" $'diff --git a/src/a.js b/src/a.js\n+++ b/src/a.js\n+if (window.confirm("x")) go();\n'
merge 1109 "$HW"
hold_case G9 1109 iron-law
# G9b one hit, the accept names another head.
HW=$(sha 1119); pr_world 1119 "$HW"; printf '%s' "$(sha 11190)" > "$T/ila.1119"
gh_put "diff/repos/acme/fixt/pulls/1119" $'diff --git a/src/a.js b/src/a.js\n+++ b/src/a.js\n+if (window.confirm("x")) go();\n'
merge 1119 "$HW"
hold_case G9b 1119 iron-law
# G10 one hit, the accept is for THIS head: it passes to the send.
HW=$(sha 1110); pr_world 1110 "$HW"; printf '%s' "$HW" > "$T/ila.1110"
gh_put "diff/repos/acme/fixt/pulls/1110" $'diff --git a/src/a.js b/src/a.js\n+++ b/src/a.js\n+if (window.confirm("x")) go();\n'
merge 1110 "$HW"
eq "G10 rc" "$RC" 0
eq "G10 one send" "$(sends 1110)" 1
# G11 the diff cannot be read.
HW=$(sha 1111); pr_world 1111 "$HW"; rm -f "$T/gh/diff_repos_acme_fixt_pulls_1111"
merge 1111 "$HW"
hold_case G11 1111 iron-law 75
# G12 the kill switches.
HW=$(sha 1112); pr_world 1112 "$HW"
for fl in automerge-disabled automerge-disabled-fixt merge-conductor-observe; do
  : > "$H/flags/$fl"; merge 1112 "$HW"; rm -f "$H/flags/$fl"
  hold_case "G12 flags/$fl" 1112 kill-switch
done
: > "$T/pause.fixt"; merge 1112 "$HW"; rm -f "$T/pause.fixt"
hold_case "G12 a merges pause" 1112 kill-switch
# G13 main is red.
HW=$(sha 1113); pr_world 1113 "$HW"; : > "$T/mainred"
merge 1113 "$HW"; rm -f "$T/mainred"
hold_case G13 1113 main-red
# G14 a ticket HOLD; a HOLD comment on the PR; a hold label; an unreadable thread.
HW=$(sha 1124); pr_world 1124 "$HW"; : > "$T/held.1124"
merge 1124 "$HW"
hold_case "G14 ticket HOLD" 1124 hold
HW=$(sha 1134); pr_world 1134 "$HW"
gh_put "repos/acme/fixt/issues/1134/comments?per_page=100&page=1" \
  '[{"id": 1, "body": "HOLD: wait for the sign-in change", "user": {"login": "operator"}, "created_at": "2026-11-06T07:00:00Z"}]'
merge 1134 "$HW"
hold_case "G14 PR HOLD comment" 1134 hold
HW=$(sha 1144); pr_world 1144 "$HW" clean '[{"name": "do-not-merge"}]'
merge 1144 "$HW"
hold_case "G14 do-not-merge label" 1144 hold
HW=$(sha 1154); pr_world 1154 "$HW"; rm -f "$T/gh/repos_acme_fixt_issues_1154_comments_per_page_100_page_1"
merge 1154 "$HW"
hold_case "G14 PR thread unreadable" 1154 hold 75
# G15 the authority row (failure modes d-h): every value but exactly merge refuses.
HW=$(sha 1125); pr_world 1125 "$HW"
auth_set() { jq --arg v "$1" '.settings["archie.merge.authority"] = $v' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"; }
jq 'del(.settings["archie.merge.authority"])' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
merge 1125 "$HW"
hold_case "G15 no authority row (fallback ask_first)" 1125 authority
for v in ask_first Merge 'merge ' merged MERGE 1; do
  auth_set "$v"; merge 1125 "$HW"
  hold_case "G15 authority=[$v]" 1125 authority
done
auth_set merge
: > "$T/authority.unproven"; merge 1125 "$HW"; rm -f "$T/authority.unproven"
hold_case "G15 authority unproven (409)" 1125 authority
check "G15 the 409 reads as unproven (got: $OUT)" 'grep -qF "unproven" <<<"$OUT"'
: > "$T/authority.down"; merge 1125 "$HW"; rm -f "$T/authority.down"
hold_case "G15 authority unreadable" 1125 authority 75
merge 1125 "$HW"
eq "G15 authority=merge passes: rc" "$RC" 0
eq "G15 authority=merge passes: one send" "$(sends 1125)" 1
# G17 the cap is full.
HW=$(sha 1127); pr_world 1127 "$HW"
jq '.settings["archie.cap.queue-enqueue"] = "1"
    | .actions += [{id: 99127, dedupe_key: "fixture-cap-1127", playbook: "queue-enqueue", mode: "on", outcome: "done", repo: "acme/fixt", pr: 99127}]' \
  "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
merge 1127 "$HW"
jq 'del(.settings["archie.cap.queue-enqueue"]) | .actions |= map(select(.id != 99127))' "$T/db.json" > "$T/db.tmp" && mv "$T/db.tmp" "$T/db.json"
hold_case "G17 the queue-enqueue day cap is full" 1127 cap
# G18 the conductor holds the PR lock.
HW=$(sha 1128); pr_world 1128 "$HW"; mkdir -p "$H/locks"
exec 7>"$H/locks/merge-conductor-fixt-1128.lock"; flock -n 7
merge 1128 "$HW"
exec 7>&-
hold_case "G18 the conductor holds the PR lock" 1128 lock
# G19 a draft; a closed PR.
HW=$(sha 1129); pr_world 1129 "$HW"
gh_put "repos/acme/fixt/pulls/1129" "$(jq -c '.draft = true' "$T/gh/repos_acme_fixt_pulls_1129")"
merge 1129 "$HW"
hold_case "G19 a draft" 1129 state
# G20 the slug is not the project's repo; a short head; no reason: rc 2, nothing read.
am fixt "acme/other#1130" "$(sha 1130)" --reason x; eq "G20 wrong repo rc" "$RC" 2
am fixt "acme/fixt#1130" abc123 --reason x; eq "G20 short head rc" "$RC" 2
am fixt "acme/fixt#1130" "$(sha 1130)"; eq "G20 no reason rc" "$RC" 2
eq "G20 nothing sent" "$(sends 1130)" 0

# ═════ R: one reverted merge puts merges back to ask-first ═══════════════════
authority() { jq -r '.settings["archie.merge.authority"] // "none"' "$T/db.json"; }
eq "R0 the authority is merge before the revert" "$(authority)" merge
am reverted "acme/fixt#1001" --why "fixture: #1001 reverted"
eq "R1 reverted rc" "$RC" 0
eq "R1 reverted sets archie.merge.authority to ask_first" "$(authority)" ask_first
check "R1 the row's note names the PR and why" \
  'jq -e ".notes[\"archie.merge.authority\"] | test(\"^[0-9T:Z-]+ reverted acme/fixt#1001 fixture: #1001 reverted$\")" "$T/db.json" >/dev/null'
check "R1 the PUT wrote ask_first and nothing else" '[ "$(jq -r "select(.key == \"archie.merge.authority\") | .value" "$T/puts.log" | sort -u)" = ask_first ]'
check "R1 one line in logs/archie-merge.log" 'grep -qF "reverted acme/fixt#1001" "$H/logs/archie-merge.log"'
HW=$(sha 1201); pr_world 1201 "$HW"
merge 1201 "$HW"
hold_case "R2 a merge after the revert" 1201 authority
# R3 the settings PUT fails: rc 75, the row is unchanged.
auth_set merge
: > "$T/put.down"
am reverted "acme/fixt#1202" --why "fixture: #1202 reverted"
rm -f "$T/put.down"
eq "R3 reverted with a failed PUT: rc" "$RC" 75
check "R3 prints UNREADABLE (got: $OUT)" 'grep -qF "ARCHIE-MERGE UNREADABLE reverted acme/fixt#1202" <<<"$OUT"'
eq "R3 the row is unchanged" "$(authority)" merge
am reverted "acme/fixt#1203"; eq "R reverted needs --why" "$RC" 2
am reverted "nope" --why x; eq "R reverted needs <owner/repo>#<n>" "$RC" 2
# X3 no verb writes merge: restore, delegate, enable and ask-first are usage.
NPUT=$(wc -l < "$T/puts.log")
for v in restore delegate enable ask-first; do
  am "$v" --why "fixture: $v"; eq "X3 [$v] is not a verb: rc" "$RC" 2
  am "$v" --cmd c1 --why "fixture: $v"; eq "X3 [$v --cmd] is not a verb: rc" "$RC" 2
done
eq "X3 no settings PUT from a non-verb" "$(wc -l < "$T/puts.log")" "$NPUT"
SRC=$(cat "$DIR/bin/archie-merge.sh" "$DIR/bin/lib/archie-merge.sh")
check "X3 no setting_set of archie.merge.authority to merge in the script or its lib" \
  '! grep -qE "setting_set[[:space:]]+archie\.merge\.authority[[:space:]]+\"?merge" <<<"$SRC"'
check "X3 the only authority write is ask_first" \
  '[ "$(grep -oE "setting_set[[:space:]]+archie\.merge\.authority[[:space:]]+[a-z_]+" <<<"$SRC" | awk "{print \$3}" | sort -u)" = ask_first ]'

# ═════ K: the schema fragment seeds the authority row as ask_first ════════════
KF=$(ls "$DIR"/worker/jobs/schema.d/*-bh-9212-archie-merge-authority.sql 2>/dev/null | head -1)
check "K1 the schema fragment exists" '[ -n "$KF" ] && [ -f "$KF" ]'
if [ -n "$KF" ]; then
  KS=$(tr '\n' ' ' < "$KF")
  check "K1 INSERT OR IGNORE INTO settings" 'grep -qF "INSERT OR IGNORE INTO settings" <<<"$KS"'
  check "K1 no CREATE TABLE" '! grep -qi "CREATE TABLE" <<<"$KS"'
  # Apply the fragment to an empty settings table, then twice over a table that
  # already holds the operator's merge: the seed is ask_first and never overwrites.
  KOUT=$(python3 -I - "$KF" <<'PYK' 2>&1
import sqlite3, sys
sql = open(sys.argv[1]).read()
out = []
for pre in (None, "merge"):
    db = sqlite3.connect(":memory:")
    db.execute("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL, note TEXT, actor TEXT, updated_at TEXT)")
    if pre:
        db.execute("INSERT INTO settings VALUES ('archie.merge.authority',?,'operator','operator','x')", (pre,))
    db.executescript(sql); db.executescript(sql)
    out.append(" ".join(k + "=" + v for k, v in db.execute("SELECT key, value FROM settings WHERE key LIKE 'archie.merge.%' ORDER BY key")))
print(" | ".join(out))
PYK
)
  eq "K1 seeds ask_first; a re-apply keeps the operator's merge" "$KOUT" "archie.merge.authority=ask_first | archie.merge.authority=merge"
fi

# ═════ C: the box settings cache never answers the authority row ═════════════
C1OUT=$(
  JOBS_HARNESS="$T/c1"; export JOBS_HARNESS; mkdir -p "$T/c1/state"
  jq -nc --argjson t "$NOW" '{fetched_at: $t, values: {"archie.merge.authority": "merge", "archie.cap.queue-enqueue": "5"}}' \
    > "$T/c1/state/settings-cache.json"
  # shellcheck disable=SC1091
  . "$H/bin/lib/jobs/settings.sh" || exit 1
  export LANE_GATE_NOW="$NOW" JOBS_SETTINGS_CACHE_S=60
  _setting_cached archie.merge.authority >/dev/null; a=$?
  _setting_cached archie.cap.queue-enqueue >/dev/null; b=$?
  printf '%s %s' "$a" "$b"
)
eq "C1 the cache answers an ordinary key (rc 0) and never archie.merge.authority (rc 1)" "$C1OUT" "1 0"

# ═════ X: the fixture seam is sandbox-only ═══════════════════════════════════
[ -s "$T/net.log" ] && { echo "network calls:"; cat "$T/net.log"; }
check "X no network call was made by the sandboxed runs" '[ ! -s "$T/net.log" ]'
# Without the sandbox flag the fixture is ignored: the real settings read goes
# to the (fake, failing) network, so the run stops UNREADABLE and sends nothing.
HW=$(sha 1301); pr_world 1301 "$HW"
OUT=$(ARCHIE_MERGE_FIXTURE="$T/fx.sh" HARNESS_TEST_SANDBOX=0 bash "$H/bin/archie-merge.sh" fixt "acme/fixt#1301" "$HW" --reason x 2>&1); RC=$?
check "X1 without HARNESS_TEST_SANDBOX=1 the fixture is not read (rc $RC: $OUT)" '[ "$RC" != 0 ] && [ "$RC" != 3 ]'
eq "X1 nothing sent" "$(sends 1301)" 0

echo "archie-merge: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
