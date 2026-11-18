#!/bin/bash
# tests/unblock-ticket-pr-resolve.bh-9446-test.sh — BH-9446 (scope 2): a
# ticket-subject record gets its open PR before the rules run
# (bin/lib/unblock/ticket-pr.sh ub_ticket_pr_enrich), and Archie's PR levers
# fit a ticket subject whose record carries that PR (bin/archie-cards.sh
# lever_record).
#
#   R1  the ledger: pr_url row BH-9335 -> pulls/9372 open: has_pr true, pr
#       9372, a 40-hex head, pr_source ledger, has_pr out of unknown; the
#       ticket_id is read case-blind; the newest row wins.
#   R2  no ledger row, the branch read answers one PR: the same, pr_source rest.
#   R3  feed rc 1 and branch read rc 1: has_pr null, unknown has has_pr once.
#   R4  the ledger PR is closed: the branch read is used; BH-93350 and another
#       repo's url are never matched; the branch read answers []: has_pr false.
#   R5  a has_pr:false record and a PR-subject record pass byte-identical; a
#       line that is not JSON passes; two records of one ticket cost 1 feed
#       read and 1 pull read (the memo); a record whose own pr is another
#       number is not changed; the fast path (pr, head, pr_state open) reads
#       nothing.
#   R6  the SHIPPED bin/archie-cards.sh: a ticket-subject card whose evidence
#       is R1's record: lever fix_round -> ub_act fix_round, pr 9372, the
#       record's head, args.ticket BH-9335; re_review -> lead_rerequest pr 9372.
#   R7  the same card with evidence.has_pr null: "lever fix_round needs a PR
#       subject", 0 writer calls; requeue on the R1 card: not pulled.
#   R8  the SHIPPED bin/unblock.sh tick: a reach record from a collector is
#       enriched before the rules (the claim body's evidence has pr 9372 and
#       has_pr true), and the tick runs as before when ticket-pr.sh is absent.
#   B   0 gh, curl or model CLI calls in the whole suite.
#
# STUBS: job_artifact_feed and gh_rest are shell functions that answer from
# fixture files and log each call; every other vendor is a PATH stub that logs
# and fails.
#
# MUTATIONS (D1), each tried once by hand: skip the ledger -> R1 red; skip the
# branch read -> R2 red; map unread to has_pr false -> R3 red; match the
# ticket by prefix -> R4 red; drop the memo -> R5 red; drop $tpr from
# lever_record -> R6 red; accept has_pr null -> R7 red; drop the enrich call
# from bin/unblock.sh -> R8 red.
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/unblock-ticket-pr-resolve.bh-9446-test.sh
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
H9372=9372aaaa9372aaaa9372aaaa9372aaaa9372aaaa
H9380=9380bbbb9380bbbb9380bbbb9380bbbb9380bbbb
NOW=$(date -u -d '2026-11-10T12:00:00Z' +%s)

mkdir -p "$T/pathbin"
for s in gh curl claude flyctl; do printf '#!/bin/bash\necho "%s $*" >> "%s/vendor.log"\nexit 7\n' "$s" "$T" > "$T/pathbin/$s"; done
chmod +x "$T/pathbin/"*
: > "$T/vendor.log"

# The fixture seams, shared by the unit cases and the tick (R8).
cat > "$T/seams.sh" <<'SH'
# job_artifact_feed <kind> <project> <since> <limit>: $FXT/feed.tsv, or rc 1
# with $FXT/feed.fail.
job_artifact_feed() {
  printf 'FEED %s %s %s %s\n' "$1" "$2" "${3:-}" "${4:-}" >> "$FXT/calls.log"
  [ -f "$FXT/feed.fail" ] && return 1
  cat "$FXT/feed.tsv" 2>/dev/null; return 0
}
# gh_rest GET <path>: $FXT/gh/<path with every non-alnum as _>, else rc 75.
gh_rest() {
  local f
  printf 'GHREST %s %s\n' "$1" "$2" >> "$FXT/calls.log"
  f="$FXT/gh/$(printf '%s' "$2" | tr -c 'A-Za-z0-9' '_')"
  [ -f "$f" ] || return 75
  cat "$f"; return 0
}
SH
ghfx() { mkdir -p "$1/gh"; printf '%s' "$3" > "$1/gh/$(printf '%s' "$2" | tr -c 'A-Za-z0-9' '_')"; }
pull() { jq -nc --argjson n "$1" --arg s "$2" --arg h "$3" '{number: $n, state: $s, head: {sha: $h}, html_url: "https://github.com/example-org/cromford/pull/\($n)", updated_at: "2026-11-10T10:00:00Z"}'; }
feedrow() { printf 'job-%s\t%s\tbox-fixture\t%s\t%s\t-\n' "$1" "$2" "$3" "$4"; }
BRANCH="repos/$R/pulls?state=open&head=example-org:ticket/bh-9335&per_page=10"

# enrich <case dir> <records file> — the real ub_ticket_pr_enrich, sourced.
enrich() {
  ( export FXT="$1" HARNESS="$1/h" PATH="$T/pathbin:$PATH"
    . "$SRC/bin/lib/unblock/act.sh"
    . "$SRC/bin/lib/unblock/ticket-pr.sh"
    . "$T/seams.sh"
    ub_ticket_pr_enrich cromford "$R" < "$2" )
}
REACH=$(jq -nc '{family: "infra", kind: "build-reach-blocked", project: "cromford", subject: "ticket:cromford:BH-9335",
  subject_kind: "build", ticket: "BH-9335", issue: 9335, age_min: 50, reach_stuck_min: 45, has_pr: null, unknown: ["has_pr"],
  day: "2026-11-10", truncated: false}')
mkcase() { mkdir -p "$T/$1/h"; : > "$T/$1/calls.log"; printf '%s\n' "$REACH" > "$T/$1/in.jsonl"; printf '%s' "$T/$1"; }

# ═════ R1: the ledger ════════════════════════════════════════════════════════
C=$(mkcase r1)
{ feedrow 1 "https://github.com/$R/pull/9100" BH-9335 2026-11-09T08:00:00Z
  feedrow 2 "https://github.com/$R/pull/9372" bh-9335 2026-11-10T08:00:00Z; } > "$C/feed.tsv"
ghfx "$C" "repos/$R/pulls/9372" "$(pull 9372 open "$H9372")"
enrich "$C" "$C/in.jsonl" > "$C/out.jsonl"
check "R1 has_pr true, pr 9372, the head, pr_source ledger, the url" \
  "$(jq -c '[.has_pr, .pr, .head, .pr_source, .pr_url]' "$C/out.jsonl")" \
  "[true,9372,\"$H9372\",\"ledger\",\"https://github.com/$R/pull/9372\"]"
check "R1 has_pr is out of unknown" "$(jq -c .unknown "$C/out.jsonl")" '[]'
check "R1 the other fields are kept" "$(jq -c '[.kind, .subject, .ticket]' "$C/out.jsonl")" '["build-reach-blocked","ticket:cromford:BH-9335","BH-9335"]'
check "R1 one feed read (pr_url, the limit 200), one pull read, no branch read" \
  "$(tr '\n' ';' < "$C/calls.log")" "FEED pr_url cromford  200;GHREST GET repos/$R/pulls/9372;"
R1REC=$(cat "$C/out.jsonl")

# ═════ R2: no ledger row, the branch read ════════════════════════════════════
C=$(mkcase r2); feedrow 1 "https://github.com/$R/pull/8000" BH-8000 2026-11-10T08:00:00Z > "$C/feed.tsv"
ghfx "$C" "$BRANCH" "[$(pull 9371 open "$H9380" | jq -c '.updated_at = "2026-11-09T00:00:00Z"'),$(pull 9372 open "$H9372")]"
enrich "$C" "$C/in.jsonl" > "$C/out.jsonl"
check "R2 the newest open PR by updated_at: has_pr true, pr 9372, pr_source rest" \
  "$(jq -c '[.has_pr, .pr, .head, .pr_source, .unknown]' "$C/out.jsonl")" "[true,9372,\"$H9372\",\"rest\",[]]"
check "R2 one feed read, one branch read" "$(tr '\n' ';' < "$C/calls.log")" "FEED pr_url cromford  200;GHREST GET $BRANCH;"
C=$(mkcase r2b); touch "$C/feed.fail"; ghfx "$C" "$BRANCH" "[$(pull 9372 open "$H9372")]"
enrich "$C" "$C/in.jsonl" > "$C/out.jsonl"
check "R2 an unread feed falls back to the branch read" "$(jq -c '[.has_pr, .pr, .pr_source]' "$C/out.jsonl")" '[true,9372,"rest"]'

# ═════ R3: both unread ═══════════════════════════════════════════════════════
C=$(mkcase r3); touch "$C/feed.fail"
enrich "$C" "$C/in.jsonl" > "$C/out.jsonl"
check "R3 both unread: has_pr null, has_pr in unknown once, pr and head unset" \
  "$(jq -c '[.has_pr, .unknown, .pr, .head]' "$C/out.jsonl")" '[null,["has_pr"],null,null]'
C=$(mkcase r3b); touch "$C/feed.fail"; ghfx "$C" "$BRANCH" '{"message":"Server Error"}'
jq -c 'del(.unknown) | del(.has_pr)' <<<"$REACH" > "$C/in.jsonl"
enrich "$C" "$C/in.jsonl" > "$C/out.jsonl"
check "R3 a non-array branch answer is unread; unknown is made" "$(jq -c '[.has_pr, .unknown]' "$C/out.jsonl")" '[null,["has_pr"]]'

# ═════ R4: a closed ledger PR, look-alike rows, none open ════════════════════
C=$(mkcase r4)
{ feedrow 1 "https://github.com/$R/pull/1111" BH-93350 2026-11-10T09:00:00Z
  feedrow 2 "https://github.com/example-org/project-3/pull/2222" BH-9335 2026-11-10T09:30:00Z
  feedrow 3 "https://github.com/$R/pull/3333" BH-933 2026-11-10T09:40:00Z
  feedrow 4 "https://github.com/$R/pull/9300" BH-9335 2026-11-10T07:00:00Z; } > "$C/feed.tsv"
ghfx "$C" "repos/$R/pulls/9300" "$(pull 9300 closed "$H9380")"
ghfx "$C" "$BRANCH" "[$(pull 9372 open "$H9372")]"
enrich "$C" "$C/in.jsonl" > "$C/out.jsonl"
check "R4 the closed ledger PR: the branch read finds 9372" "$(jq -c '[.has_pr, .pr, .pr_source]' "$C/out.jsonl")" '[true,9372,"rest"]'
check "R4 reads: pulls/9300, then the branch; never 1111, 2222 or 3333" \
  "$(grep -o 'GHREST GET .*' "$C/calls.log" | tr '\n' ';')" "GHREST GET repos/$R/pulls/9300;GHREST GET $BRANCH;"
C=$(mkcase r4b); : > "$C/feed.tsv"; ghfx "$C" "$BRANCH" '[]'
enrich "$C" "$C/in.jsonl" > "$C/out.jsonl"
check "R4 no open PR: has_pr false, out of unknown" "$(jq -c '[.has_pr, .unknown, .pr]' "$C/out.jsonl")" '[false,[],null]'

# ═════ R5: what passes unchanged; the memo; the fast path ════════════════════
C=$(mkcase r5); : > "$C/feed.tsv"; ghfx "$C" "repos/$R/pulls/9372" "$(pull 9372 open "$H9372")"
feedrow 1 "https://github.com/$R/pull/9372" BH-9335 2026-11-10T08:00:00Z > "$C/feed.tsv"
{ jq -c '.has_pr = false | .unknown = []' <<<"$REACH"
  jq -nc --arg r "$R" --arg h "$H9380" '{kind: "pr-approved-idle", project: "cromford", repo: $r, subject: ($r + "#9380"), subject_kind: "pr", pr: 9380, head: $h}'
  echo 'not json {'
  jq -nc '{kind: "source-unreadable", project: "cromford", subject: "source:collect:cromford"}'
  jq -nc '{kind: "ticket-abandoned", project: "cromford", subject: "cromford:bh-9335"}'
  jq -nc '{kind: "ticket-abandoned", project: "cromford", subject: "project-3:BH-1"}'; } > "$C/same.jsonl"
enrich "$C" "$C/same.jsonl" > "$C/same.out"
check "R5 has_pr false, a PR subject, a non-JSON line and non-ticket subjects pass byte-identical" "$(cmp -s "$C/same.jsonl" "$C/same.out" && echo same)" same
check "R5 they cost 0 reads" "$(grep -c . "$C/calls.log")" 0
: > "$C/calls.log"
{ printf '%s\n' "$REACH"; jq -c '.kind = "ticket-starved" | .subject = "cromford:BH-9335"' <<<"$REACH"; } > "$C/two.jsonl"
enrich "$C" "$C/two.jsonl" > "$C/two.out"
check "R5 two records of one ticket: both enriched" "$(jq -c '[.pr, .has_pr]' "$C/two.out" | tr '\n' ' ')" "[9372,true] [9372,true] "
check "R5 the memo: 1 feed read, 1 pull read" "$(cnt '^FEED' "$C/calls.log") $(cnt '^GHREST' "$C/calls.log")" "1 1"
: > "$C/calls.log"
jq -c '.pr = 9999 | .head = null' <<<"$REACH" > "$C/other.jsonl"
enrich "$C" "$C/other.jsonl" > "$C/other.out"
check "R5 a record whose pr is another number is not changed" "$(cmp -s "$C/other.jsonl" "$C/other.out" && echo same)" same
: > "$C/calls.log"
jq -nc --arg h "$H9372" '{kind: "ticket-ejected", project: "cromford", subject: "cromford:BH-9335", pr: 9372, head: $h, pr_state: "open", unknown: []}' > "$C/fast.jsonl"
enrich "$C" "$C/fast.jsonl" > "$C/fast.out"
check "R5 the fast path: has_pr true, 0 reads" "$(jq -c '[.has_pr, .pr]' "$C/fast.out") $(grep -c . "$C/calls.log")" "[true,9372] 0"

# ═════ R6/R7: the SHIPPED bin/archie-cards.sh ════════════════════════════════
# mkarchie <name> — the lane by its closure; the jobs API, the open rows, the
# model route and ub_act are fixture functions (ARCHIE_CARDS_FIXTURE);
# unblock-reply.sh and agent-call.sh are logging stubs.
mkarchie() {
  local A="$T/$1"
  mkdir -p "$A/h/env" "$A/h/state" "$A/h/logs" "$A/fx"
  ( cd "$SRC" && scratch_install_closure bin/archie-cards.sh "$A/h" ) >/dev/null || { echo "setup: closure archie-cards" >&2; return 1; }
  : > "$A/h/env/global.env"
  rm -f "$A/h/bin/unblock-reply.sh" "$A/h/bin/agent-call.sh"
  printf '#!/bin/bash\necho "REPLY $*" >> "$FXT/seq.log"\necho ARCHIE_ANSWERED\nexit 0\n' > "$A/h/bin/unblock-reply.sh"
  printf '#!/bin/bash\necho "AGENTCALL $1" >> "$FXT/seq.log"\ncat "$FXT/answer" > "$5"\nexit 0\n' > "$A/h/bin/agent-call.sh"
  chmod +x "$A/h/bin/unblock-reply.sh" "$A/h/bin/agent-call.sh"
  cat > "$A/fx.sh" <<'SH'
flag_active() { return 1; }
lane_gate_or_exit() { return 0; }
lane_env_apply() { return 0; }
lane_role_model() { printf 'model-fixture\n'; }
unb_scope_projects() { printf 'cromford\tact\n'; }
unblock_card_open_rows() { cat "$FXT/rows.jsonl"; }
_jobs_req() { printf 'JOBS %s %s\n' "$1" "$2" >> "$FXT/seq.log"; return 0; }
ub_act() {
  printf 'UBACT %s\n' "$1" >> "$FXT/seq.log"
  UB_ACT_OUTCOME=done UB_ACT_DETAIL=queued; printf 'done\tqueued\n'; return 0
}
SH
  printf '%s' "$A"
}
atick() {
  local A="$1"; shift
  ( env HARNESS="$A/h" FXT="$A/fx" ARCHIE_CARDS_FIXTURE="$A/fx.sh" HARNESS_TEST_SANDBOX=1 ARCHIE_CARDS_TIMED=1 \
      ARCHIE_CARDS_NOW="$NOW" LANE_GATE_DISABLE=1 PATH="$T/pathbin:$PATH" TMPDIR="$A" HARNESS_REPO="$R" "$@" \
      bash "$A/h/bin/archie-cards.sh" tick ) > "$A/atick.out" 2>&1
}
# cardrow <evidence json> — one open archie row on a ticket subject.
cardrow() {
  jq -nc --argjson ev "$1" '{id: 41, decision_key: "k9335", project: "cromford", repo: "example-org/cromford",
    subject_kind: "build", subject: "ticket:cromford:BH-9335", head: $ev.head, stall_class: "build-reach-blocked",
    evidence: $ev, outcome: "escalated", routed_to: null, archie_claimed_at: null, created_at: "2026-11-10T11:50:00Z",
    card: {id: "u-12e877", key: "k9335", route: "archie", class: "escalate", subject: "ticket:cromford:BH-9335"}}'
}
ubrec() { grep '^UBACT ' "$1/fx/seq.log" | tail -n 1 | sed 's/^UBACT //'; }
lever() { # lever <case> <evidence> <lever>
  local A; A=$(mkarchie "$1") || return 1
  cardrow "$2" > "$A/fx/rows.jsonl"
  printf '{"pick":"act","lever":"%s","reason":"the PR has a red suite"}\n' "$3" > "$A/fx/answer"
  atick "$A"; printf '%s' "$A"
}
A=$(lever r6a "$R1REC" fix_round) || { echo "FAIL: archie setup"; exit 1; }
check "R6 fix_round on the ticket subject: the writer gets fix_round, pr 9372, the head, ticket BH-9335" \
  "$(ubrec "$A" | jq -c '[.action.name, .pr, .head, .action.args.ticket, .repo]')" "[\"fix_round\",9372,\"$H9372\",\"BH-9335\",\"$R\"]"
check "R6 fix_round done: acted with the lever" "$(grep -c '^REPLY archie u-12e877 acted .* fix_round$' "$A/fx/seq.log")" 1
A=$(lever r6b "$R1REC" re_review)
check "R6 re_review on the ticket subject: lead_rerequest, pr 9372, request_id none" \
  "$(ubrec "$A" | jq -c '[.action.name, .pr, .action.args.request_id]')" '["lead_rerequest",9372,"none"]'
A=$(lever r7a "$(jq -c '.has_pr = null' <<<"$R1REC")" fix_round)
check "R7 evidence has_pr null: 0 writer calls" "$(cnt '^UBACT' "$A/fx/seq.log")" 0
check "R7 evidence has_pr null: needs-operator, needs a PR subject" \
  "$(grep -c '^REPLY archie u-12e877 needs-operator Archie picked lever fix_round, not pulled: lever fix_round needs a PR subject' "$A/fx/seq.log")" 1
A=$(lever r7b "$R1REC" requeue)
check "R7 requeue on the R1 card: not pulled (requeue needs a PR subject)" \
  "$(cnt '^UBACT' "$A/fx/seq.log") $(grep -c 'lever requeue needs a PR subject' "$A/fx/seq.log")" "0 1"
A=$(lever r7c "$(jq -c '.head = "abc"' <<<"$R1REC")" fix_round)
check "R7 a head that is not 40 hex: not pulled" "$(cnt '^UBACT' "$A/fx/seq.log")" 0

# ═════ R8: the SHIPPED bin/unblock.sh tick ═══════════════════════════════════
mktick() {
  local C="$T/$1" S
  mkdir -p "$C/h/env" "$C/h/state" "$C/h/logs" "$C/h/catalog/unblock-rules.d" "$C/h/catalog/prompts" "$C/fx" "$C/col"
  for S in bin/unblock.sh bin/fleet-conf.sh bin/jobs-client.sh bin/lib/unblock/rules.sh bin/lib/unblock/judge.sh bin/lib/unblock/card.sh; do
    ( cd "$SRC" && scratch_install_closure "$S" "$C/h" ) >/dev/null || { echo "setup: closure $S" >&2; return 1; }
  done
  cp "$SRC"/catalog/unblock-rules.d/*.json "$C/h/catalog/unblock-rules.d/"
  cp "$SRC/catalog/prompts/unblock-decide.md" "$SRC/catalog/prompts/unblock-judge.md" "$C/h/catalog/prompts/"
  : > "$C/h/env/global.env"
  printf 'cromford example-org/cromford - - 3 hub 192.0.2.10\n' > "$C/h/fleet.conf"
  rm -f "$C/h/bin/lane-alert.sh" "$C/h/bin/agent-call.sh"
  printf '#!/bin/bash\necho "ALERT $*" >> "$FXT/seq.log"\nexit 0\n' > "$C/h/bin/lane-alert.sh"
  printf '#!/bin/bash\necho "AGENTCALL $1" >> "$FXT/seq.log"\n: > "$5"\nexit 0\n' > "$C/h/bin/agent-call.sh"
  chmod +x "$C/h/bin/lane-alert.sh" "$C/h/bin/agent-call.sh"
  { cat "$T/seams.sh"; cat <<'SH'
setting_get() { case "$1" in unblock.enabled) printf 1; return 0 ;; esac; return 2; }
lane_gate_or_exit() { return 0; }
lane_env_apply() { return 0; }
lane_role_model() { printf 'model-fixture\n'; }
_jobs_req() {
  printf 'JOBS %s %s %s\n' "$1" "$2" "${3:-}" >> "$FXT/seq.log"
  case "$1 $2" in
    "POST /api/unblock/decisions/claim") printf '{"claimed":true,"id":1}'; return 0 ;;
    "POST /api/unblock/decisions/record") printf '{"ok":true}'; return 0 ;;
  esac
  return 1
}
SH
  } > "$C/fx.sh"
  printf 'ub_collect_fixture() { cat "$FXT/lines.jsonl"; }\n' > "$C/col/fixture.sh"
  jq -nc --argjson fa "$NOW" '{fetched_at: $fa, values: {"unblock.project.cromford.mode": "shadow", "unblock.enabled": "1"}, seeded: {}}' \
    > "$C/h/state/settings-cache.json"
  printf '%s\n' "$REACH" > "$C/fx/lines.jsonl"
  feedrow 2 "https://github.com/$R/pull/9372" BH-9335 2026-11-10T08:00:00Z > "$C/fx/feed.tsv"
  ghfx "$C/fx" "repos/$R/pulls/9372" "$(pull 9372 open "$H9372")"
  printf '%s' "$C"
}
tick() {
  ( env HARNESS="$1/h" FXT="$1/fx" UNBLOCK_FIXTURE="$1/fx.sh" FLEET_CONF="$1/h/fleet.conf" REGISTRY_SOURCE=file \
      UNBLOCK_COLLECTORS_DIR="$1/col" HARNESS_TEST_SANDBOX=1 LANE_GATE_DISABLE=1 LANE_GATE_NOW=$NOW LANE_GATE_CACHE_S=60 \
      UNBLOCK_TIMED=1 JOBS_URL= HARNESS_SECRET= PATH="$T/pathbin:$PATH" GH_ETAG=0 TMPDIR="$1" \
      UNBLOCK_NOW="$NOW" UB_NOW="$NOW" bash "$1/h/bin/unblock.sh" tick --project cromford ) > "$1/tick.out" 2>&1
}
C=$(mktick r8) || { echo "FAIL: tick setup"; exit 1; }
tick "$C"
CL=$(grep '^JOBS POST /api/unblock/decisions/claim ' "$C/fx/seq.log" | sed 's/^JOBS POST [^ ]* //')
check "R8 the tick claims one decision on the ticket subject" "$(printf '%s\n' "$CL" | grep -c .)" 1
check "R8 the claim's evidence was enriched before the rules: pr 9372, has_pr true, the head" \
  "$(jq -c '[.subject, .evidence.pr, .evidence.has_pr, .evidence.pr_source, .head]' <<<"$CL")" \
  "[\"ticket:cromford:BH-9335\",9372,true,\"ledger\",\"$H9372\"]"
C=$(mktick r8b) || { echo "FAIL: tick setup"; exit 1; }
rm -f "$C/h/bin/lib/unblock/ticket-pr.sh"
tick "$C"
CL=$(grep '^JOBS POST /api/unblock/decisions/claim ' "$C/fx/seq.log" | sed 's/^JOBS POST [^ ]* //')
check "R8 no ticket-pr.sh on the tree: the tick runs as before (has_pr null, 0 reads)" \
  "$(jq -c '[.evidence.has_pr, .evidence.pr]' <<<"$CL") $(grep -c '^GHREST\|^FEED' "$C/fx/calls.log" 2>/dev/null || echo 0)" "[null,null] 0"

check "B 0 gh, curl or model CLI calls" "$(grep -c . "$T/vendor.log")" 0
echo "unblock-ticket-pr-resolve.bh-9446: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
