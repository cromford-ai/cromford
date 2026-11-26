#!/bin/bash
# tests/pipeline-health-record.bh-9938-test.sh — BH-9938 (BH-9926.6 slice C0):
# bin/pipeline-health.sh reads its open-PR lists, the stale-dequeue reads
# (13c: merge-queue label list, Mergify payload, head commit time) and the
# lead-merge-unqueued combined status (13d) through prr_read pipeline-health,
# seam bin/lib/prr-shadow.d/pipeline-health.sh.
#
#   U1-U14  the seam functions, one fixture each: the record side writes the
#           GitHub side's format, the miss words (hct: another sha, null
#           head_commit; open: stale stamp, worker 400; window 100 with 100
#           truncated rows is a hit), and the norms (equal for equal data,
#           unequal for a changed number, state or verdict).
#   P0      no prr-shadow lib: the 13c block runs today's inline reads.
#   P1      step record, 13c over 4 labelled PRs with fresh records (2 queued,
#           2 dequeued with no new head): 0 gh calls, the 2 staledequeue pages.
#   P2      step record, 13d over 3 open PRs, statuses with no lead success:
#           0 gh calls, 0 pages. P2b: one lead success in the record pages.
#   P3      step record, ph_open_rows <slug> 100 serves the record rows in the
#           REST shape, 0 pulls reads.
#   P4      step shadow, the record list has 1 changed label: the GitHub read
#           runs, the GitHub-based pages, 1 PRR_SHADOW lane=pipeline-health.
#   P5      step record, a stale list stamp: PRR_MISS ... why=stale
#           fallback=github, 1 GitHub list read.
#   P6      step off: today's gh reads and 0 /api/pr-records reads.
#
# Blocks are extracted by their `# >>> ` / `# <<< ` markers (the bh-8268
# pattern). gh is a PATH stub that logs argv to <case>/gh-calls.txt. _jobs_req
# is a stub that serves <case>/rec/<n>.json for a row GET and
# <case>/rec/list.json for a list GET, and logs each call. The clock is fixed.
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
SRC=$(cd "$(dirname "$0")/.." && pwd)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "jq missing — skipping"; exit 0; }

PH="$SRC/bin/pipeline-health.sh"
SEAM="$SRC/bin/lib/prr-shadow.d/pipeline-health.sh"
blk() { awk -v s="$1" -v e="$2" 'index($0, s) == 1 {f=1; next} index($0, e) == 1 {exit} f' "$PH"; }
blk '# >>> open list (BH-7616)' '# <<< open list' > "$T/b-open.sh"
blk '# >>> stale dequeue (BH-3480)' '# <<< stale dequeue' > "$T/b-sd.sh"
blk '# >>> lead merge unqueued (BH-3778)' '# <<< lead merge unqueued' > "$T/b-lu.sh"
for b in open sd lu; do [ -s "$T/b-$b.sh" ] && ok || bad "block $b was not extracted"; done
grep -q 'lib/prr-shadow.sh' "$PH" && ok || bad "bin/pipeline-health.sh does not load bin/lib/prr-shadow.sh"
grep -q 'prr_seam_load pipeline-health' "$PH" && ok || bad "bin/pipeline-health.sh does not load its seam"

NOW0=1764000000
iso() { date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ; }
sha() { printf 'ab%038d' "$1"; }
SLUG=example-org/proj-os
DQBODY=$(jq -r '.[] | select(.id == 5882237379) | .body' "$SRC/tests/fixtures/bh-3480-pr3396-mergify-comments.json")

# mkh <dir> — a scratch harness root with the lane's real libs.
mkh() {
  mkdir -p "$1/logs" "$1/state" "$1/rec" "$1/gh" "$1/fakebin" "$1/tmp"
  ( cd "$SRC" && scratch_install_closure bin/pipeline-health.sh "$1" ) >/dev/null || { echo "setup: closure into $1"; exit 1; }
  # The seam is loaded by name (prr_seam_load), so no closure scan of the lane sees it.
  ( cd "$SRC" && scratch_install_closure bin/lib/prr-shadow.d/pipeline-health.sh "$1" ) >/dev/null 2>&1
  ( cd "$SRC" && scratch_install_closure bin/lib/prr-shadow.sh "$1" ) >/dev/null 2>&1
  ( cd "$SRC" && scratch_install_closure bin/lib/ph-pr-record.sh "$1" ) >/dev/null 2>&1
  printf 'proj %s - - 2 box\n' "$SLUG" > "$1/fleet.conf"
  : > "$1/jobs-calls.txt"; : > "$1/gh-calls.txt"; : > "$1/alerts.txt"; : > "$1/fired.txt"
  cat > "$1/fakebin/gh" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$CT/gh-calls.txt"
A="$*"
case "$A" in
  *"repos/example-org/proj-os/issues?labels=merge-queue"*) cat "$CT/gh/labels.json" ;;
  *"repos/example-org/proj-os/issues/"*"/comments"*)
    N=$(sed -n 's|.*/issues/\([0-9]*\)/comments.*|\1|p' <<<"$A")
    if [[ " $A " =~ [\&\ =]page=([2-9]|10)[\ \&] ]]; then echo '[]'; else cat "$CT/gh/c$N.json" 2>/dev/null || echo '[]'; fi ;;
  *"api repos/example-org/proj-os/pulls/"*"/reviews"*) echo '[]' ;;
  *"api repos/example-org/proj-os/pulls/"*" --jq .head.sha"*)
    N=$(sed -n 's|.*/pulls/\([0-9]*\).*|\1|p' <<<"$A"); printf 'ab%038d\n' "$N" ;;
  *"api repos/example-org/proj-os/commits/"*"/status") S=$(sed -n 's|.*/commits/\([0-9a-f]*\)/status|\1|p' <<<"$A"); cat "$CT/gh/st-$S.json" ;;
  *"api repos/example-org/proj-os/commits/"*) S=$(sed -n 's|.*/commits/\([0-9a-f]*\).*|\1|p' <<<"$A"); cat "$CT/gh/hc-$S" ;;
  "api repos/example-org/proj-os/pulls?state=open&per_page=100") cat "$CT/gh/open.json" ;;
  *"-i "*"repos/example-org/proj-os/pulls -f state=open"*)
    pg=1; [[ " $A " =~ [\ ]page=([0-9]+) ]] && pg="${BASH_REMATCH[1]}"
    printf 'HTTP/2 200\r\n\r\n'; jq -c --argjson p "$pg" '.[($p - 1) * 100 : $p * 100]' "$CT/gh/open.json" ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$1/fakebin/gh"
}

# The jobs client, stubbed: a row GET serves rec/<n>.json, a list GET serves
# rec/list.json (JOBS_LIST=400 answers as the worker's 400 does: rc 1).
JOBS_STUB='_jobs_req() {
  printf "%s %s\n" "$1" "$2" >> "$CT/jobs-calls.txt"
  [ "$1" = GET ] || return 1
  case "$2" in
    /api/pr-records\?repo=example-org/proj-os\&number=*)
      local n="${2##*number=}"
      if [ -f "$CT/rec/$n.json" ]; then cat "$CT/rec/$n.json"; else echo "{\"row\":null,\"age_s\":null}"; fi ;;
    /api/pr-records\?repo=example-org/proj-os\&state=open*)
      [ "${JOBS_LIST:-ok}" = 400 ] && return 1
      cat "$CT/rec/list.json" ;;
    *) return 1 ;;
  esac
}'

# row <h> <n> <mergify-json|null> <head_commit-json|null> [statuses-json] [age_s]
row() {
  jq -nc --argjson n "$2" --arg sha "$(sha "$2")" --argjson mq "$3" --argjson hc "$4" \
    --argjson st "${5:-null}" --argjson age "${6:-10}" \
    '{row: {repo: "example-org/proj-os", number: $n, state: "open", draft: 0, head_sha: $sha,
            head_ref: "ticket/x-\($n)", base_ref: "main", mergeable_state: "clean", labels: ["merge-queue"],
            mergify_queue: $mq, head_commit: $hc, statuses: $st}, age_s: $age}' > "$1/rec/$2.json"
}
# lrow <n> <labels-csv> [draft 0|1] — one pr_record_list row. draft is the
# worker's INTEGER column (routes/pr-records.js), as the list GET serves it.
lrow() {
  jq -nc --argjson n "$1" --arg sha "$(sha "$1")" --arg l "$2" --arg c "$(iso $((NOW0 - 86400 + $1)))" --argjson d "${3:-0}" \
    '{number: $n, title: "X-\($n) work", head_ref: "ticket/x-\($n)", head_sha: $sha, base_ref: "main",
      author: "operator", labels: ($l | split(",") | map(select(. != ""))), body: "Refs #\($n)",
      mergeable_state: "clean", updated_at: $c, created_at: $c,
      url: "https://github.com/example-org/proj-os/pull/\($n)", draft: $d}'
}
# list <h> <age_s> <truncated> <row...>
list() {
  local h="$1" age="$2" tr="$3"; shift 3
  printf '%s\n' "$@" | jq -sc --argjson age "$age" --argjson tr "$tr" \
    '{rows: ., truncated: $tr, sync: {synced_at: "2025-11-24T15:59:00Z", age_s: $age}, missing: null, unknown: 0}' > "$h/rec/list.json"
}
# ghopen <h> <n...> — the REST pulls array GitHub serves, made from the record
# list (the same PRs, GitHub's field names).
ghopen() {
  jq -c '[.rows[] | {number, title, html_url: .url, draft: (.draft == 1), body, mergeable_state, created_at, updated_at, state: "open",
      user: {login: .author}, head: {ref: .head_ref, sha: .head_sha}, base: {ref: .base_ref, repo: {default_branch: "main"}},
      labels: [.labels[] | {name: .}]}]' "$1/rec/list.json" > "$1/gh/open.json"
}
mqobj() { # mqobj <state> <n> <epoch>
  jq -nc --arg s "$1" --argjson c "$((5000 + $2))" --arg at "$(iso "$3")" \
    '{state: $s, code: null, draft_pr: null, failing_checks: [], left_sha: null, comment_id: $c, at: $at}'
}
ghcomment() { # ghcomment <h> <n> <state> <epoch>
  jq -nc --arg b "${DQBODY/\"state\": \"dequeued\"/\"state\": \"$3\"}" --arg u "$(iso "$4")" --argjson id "$((5000 + $2))" \
    '[{id: $id, created_at: $u, updated_at: $u, user: {login: "mergify[bot]"}, body: $b}]' > "$1/gh/c$2.json"
}

# ── the 13c fixture: PRs 941..944 carry merge-queue. 941/942 queued, 943/944
# dequeued 45m ago on a head committed 150m ago (both page).
sd_fixture() {
  local h="$1" n st
  for n in 941 942 943 944; do
    st=dequeued; [ "$n" -le 942 ] && st=queued
    row "$h" "$n" "$(mqobj "$st" "$n" $((NOW0 - 2700)))" "$(jq -nc --arg s "$(sha "$n")" --arg a "$(iso $((NOW0 - 9000)))" '{sha: $s, at: $a}')"
    ghcomment "$h" "$n" "$st" $((NOW0 - 2700))
    iso $((NOW0 - 9000)) > "$h/gh/hc-$(sha "$n")"
  done
  list "$h" 30 false "$(lrow 941 merge-queue)" "$(lrow 942 merge-queue)" "$(lrow 943 merge-queue)" "$(lrow 944 merge-queue)" "$(lrow 945 '')"
  jq -c '[.rows[] | select(.labels | index("merge-queue")) | {number, pull_request: {url: "x"}, labels: [.labels[] | {name: .}]}]' \
    "$h/rec/list.json" > "$h/gh/labels.json"
}

# drive <h> <blocks> [env...] — the blocks in one subshell with the lane libs.
# NOSEAM=1 loads no prr-shadow lib (today's tree under block extraction).
drive() {
  local h="$1" blocks="$2"; shift 2
  : > "$h/alerts.txt"; : > "$h/gh-calls.txt"; : > "$h/jobs-calls.txt"; rm -f "$h/logs/prr-shadow.log"
  ( export PATH="$h/fakebin:$PATH" CT="$h" HARNESS="$h" TMPDIR="$h/tmp" PR_SNAPSHOT=0 "$@"
    unset HPL_SNAPSHOT PH_SECTIONS GH_TOKEN
    H="$h"; NOW=$NOW0; PROJECTS=proj; PH_SECTIONS=""; FIRED="$h/fired.txt"; ACTIVE="$h/active.txt"
    gh_budget_low() { return 1; }
    alert() { printf '%s|%s\n' "$2" "$3" >> "$CT/alerts.txt"; }
    eval "$JOBS_STUB"
    # shellcheck disable=SC1091
    . "$h/bin/lib/gh-rest-list.sh" || exit 98
    # shellcheck disable=SC1091
    . "$h/bin/lib/ph-pr-record.sh"
    if [ "${NOSEAM:-0}" != 1 ]; then
      # shellcheck disable=SC1091
      . "$h/bin/lib/prr-shadow.sh" || exit 97
      prr_seam_load pipeline-health || exit 96
    fi
    for b in $blocks; do
      # shellcheck disable=SC1090
      . "$T/b-$b.sh"
    done
    echo reached ) > "$h/drive.out" 2>&1
}
keys() { cut -d'|' -f1 "$1/alerts.txt" | LC_ALL=C sort | paste -sd' ' -; }
shadows() { [ -f "$1/logs/prr-shadow.log" ] || { echo 0; return; }; grep -c 'PRR_SHADOW lane=pipeline-health ' "$1/logs/prr-shadow.log"; }
lists() { grep -c '/api/pr-records?repo=example-org/proj-os&state=open' "$1/jobs-calls.txt"; }

# ============================================================================
# U: the seam functions
# ============================================================================
U="$T/u"; mkh "$U"
# useam <cmd...> — one seam call with the stub jobs client; stdout to out.txt.
useam() {
  ( export CT="$U" HARNESS="$U" TMPDIR="$U/tmp" PATH="$U/fakebin:$PATH"
    eval "$JOBS_STUB"
    # shellcheck disable=SC1091
    . "$U/bin/lib/prr-shadow.sh" || exit 97
    prr_seam_load pipeline-health || exit 96
    "$@" ) > "$U/out.txt" 2> "$U/err.txt"
}
SEAMFN="ph_open_record ph_open_github ph_open_norm ph_sdl_record ph_sdl_github ph_sdl_norm ph_payload_record ph_payload_github ph_payload_norm ph_hct_record ph_hct_github ph_hct_norm ph_status_record ph_status_github ph_status_norm"
for fn in $SEAMFN; do
  ( . "$U/bin/lib/prr-shadow.sh"; prr_seam_load pipeline-health && declare -F "$fn" >/dev/null ) && ok || bad "U0: the seam does not define $fn"
done

H40=$(sha 961)
# U1 hct hit, head given in upper case.
row "$U" 961 null "$(jq -nc --arg s "$H40" '{sha: $s, at: "2025-11-24T13:30:00Z"}')"
useam ph_hct_record "$U/f" "$SLUG" 961 "$(tr 'a-f' 'A-F' <<<"$H40")"; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$U/f")" = "$(date -u -d 2025-11-24T13:30:00Z +%s)" ] && ok || bad "U1: hct hit must write the epoch (rc=$RC f=$(cat "$U/f" 2>/dev/null) out=$(cat "$U/out.txt"))"
# U2 hct: head_commit.sha is another sha -> miss sha.
row "$U" 962 null "$(jq -nc --arg s "$(sha 9)" '{sha: $s, at: "2025-11-24T13:30:00Z"}')"
useam ph_hct_record "$U/f" "$SLUG" 962 "$(sha 962)"; RC=$?
[ "$RC" = 1 ] && [ "$(cat "$U/out.txt")" = sha ] && ok || bad "U2: another head_commit.sha must miss with 'sha' (rc=$RC out=$(cat "$U/out.txt"))"
# U3 hct: head_commit null -> miss field:head_commit.
row "$U" 963 null null
useam ph_hct_record "$U/f" "$SLUG" 963 "$(sha 963)"; RC=$?
[ "$RC" = 1 ] && [ "$(cat "$U/out.txt")" = field:head_commit ] && ok || bad "U3: a null head_commit must miss field:head_commit (rc=$RC out=$(cat "$U/out.txt"))"
# U3b hct: no row -> unreadable, and no gh call.
: > "$U/gh-calls.txt"
useam ph_hct_record "$U/f" "$SLUG" 969 "$(sha 969)"; RC=$?
[ "$RC" = 1 ] && [ "$(cat "$U/out.txt")" = unreadable ] && [ ! -s "$U/gh-calls.txt" ] && ok || bad "U3b: no row must miss unreadable with 0 gh calls (rc=$RC out=$(cat "$U/out.txt"))"

# U4 open: a stale stamp -> miss stale.
list "$U" 5000 false "$(lrow 971 merge-queue)"
useam ph_open_record "$U/f" "$SLUG" 100; RC=$?
[ "$RC" = 1 ] && [ "$(cat "$U/out.txt")" = stale ] && ok || bad "U4: a stale stamp must miss stale (rc=$RC out=$(cat "$U/out.txt"))"
# U5 open: the worker answers 400 -> miss unreadable.
list "$U" 30 false "$(lrow 971 merge-queue)"
( export JOBS_LIST=400; useam ph_open_record "$U/f" "$SLUG" 100 ); RC=$?
[ "$RC" = 1 ] && [ "$(cat "$U/out.txt")" = unreadable ] && ok || bad "U5: a 400 must miss unreadable (rc=$RC out=$(cat "$U/out.txt"))"
# U6 open: window 100 with 100 rows, truncated -> hit, REST shape.
R100=(); for i in $(seq 1001 1100); do R100+=("$(lrow "$i" merge-queue,ai-build)"); done
list "$U" 30 true "${R100[@]}"
useam ph_open_record "$U/f" "$SLUG" 100; RC=$?
[ "$RC" = 0 ] && [ "$(jq length "$U/f")" = 100 ] && ok || bad "U6: window 100 with 100 truncated rows must hit (rc=$RC out=$(cat "$U/out.txt"))"
[ "$(jq -c '.[0] | {number, title, html_url, draft, body, mergeable_state, created_at, updated_at, user, head, base, labels}' "$U/f")" \
  = "$(jq -c --arg s "$(sha 1001)" --arg c "$(iso $((NOW0 - 86400 + 1001)))" -n '{number: 1001, title: "X-1001 work",
      html_url: "https://github.com/example-org/proj-os/pull/1001", draft: false, body: "Refs #1001", mergeable_state: "clean",
      created_at: $c, updated_at: $c, user: {login: "operator"}, head: {ref: "ticket/x-1001", sha: $s}, base: {ref: "main"},
      labels: [{name: "merge-queue"}, {name: "ai-build"}]}')" ] && ok || bad "U6: the row is not in the REST pulls shape: $(jq -c '.[0]' "$U/f")"
# U6b without a window a truncated page is a miss (pr_record_list's rule, kept).
useam ph_open_record "$U/f" "$SLUG" ""; RC=$?
[ "$RC" = 1 ] && [ "$(cat "$U/out.txt")" = truncated ] && ok || bad "U6b: no window and truncated must miss (rc=$RC out=$(cat "$U/out.txt"))"

# U6c the worker's integer draft is the REST boolean: 1 -> true, 0 -> false.
list "$U" 30 false "$(lrow 981 merge-queue 1)" "$(lrow 982 merge-queue 0)"
useam ph_open_record "$U/f" "$SLUG" 100; RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '[.[] | .draft]' "$U/f")" = '[true,false]' ] && ok || bad "U6c: draft 1/0 must map to true/false (rc=$RC $(jq -c '[.[] | .draft]' "$U/f" 2>/dev/null))"
# U7 sdl: the record label list in the issue shape.
list "$U" 30 false "$(lrow 941 merge-queue)" "$(lrow 942 merge-queue,queued)" "$(lrow 943 ai-build)"
useam ph_sdl_record "$U/f" "$SLUG"; RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '[.[] | {number, pr: (.pull_request != null), labels}]' "$U/f")" \
  = '[{"number":941,"pr":true,"labels":[{"name":"merge-queue"}]},{"number":942,"pr":true,"labels":[{"name":"merge-queue"},{"name":"queued"}]}]' ] \
  && ok || bad "U7: sdl record shape (rc=$RC f=$(cat "$U/f" 2>/dev/null) out=$(cat "$U/out.txt"))"
useam ph_sdl_norm "$U/f"
[ "$(cat "$U/out.txt")" = '[{"n":941}]' ] && ok || bad "U7: sdl norm must drop the queued PR: $(cat "$U/out.txt")"
# U8 sdl: a stale list -> miss stale.
list "$U" 5000 false "$(lrow 941 merge-queue)"
useam ph_sdl_record "$U/f" "$SLUG"; RC=$?
[ "$RC" = 1 ] && [ "$(cat "$U/out.txt")" = stale ] && ok || bad "U8: sdl stale must miss stale (rc=$RC out=$(cat "$U/out.txt"))"

# U9 payload: the record writes sdq_payload_last's line.
row "$U" 964 "$(mqobj dequeued 964 $((NOW0 - 2700)))" null
useam ph_payload_record "$U/f" "$SLUG" 964; RC=$?
[ "$RC" = 0 ] && [ "$(cat "$U/f")" = "$(printf 'dequeued\t%s\t5964' $((NOW0 - 2700)))" ] && ok || bad "U9: payload line (rc=$RC f=$(cat "$U/f" 2>/dev/null))"
ghcomment "$U" 964 dequeued $((NOW0 - 2700))
u9gh() { . "$HARNESS/bin/lib/mc-stale-dequeue.sh" || return 9; ph_payload_github "$1" example-org/proj-os 964; }
useam u9gh "$U/g"; RC=$?
[ "$RC" = 0 ] && cmp -s "$U/f" "$U/g" && ok || bad "U9: the record line must equal sdq_payload_last's (rc=$RC rec=$(cat "$U/f") gh=$(cat "$U/g" 2>/dev/null))"
# U10 payload: no mergify_queue -> the reader's miss word none; no row -> unknown.
row "$U" 965 null null
useam ph_payload_record "$U/f" "$SLUG" 965; RC=$?
[ "$RC" = 1 ] && [ "$(cat "$U/out.txt")" = none ] && ok || bad "U10: a null mergify_queue must miss none (rc=$RC out=$(cat "$U/out.txt"))"
useam ph_payload_record "$U/f" "$SLUG" 968; RC=$?
[ "$RC" = 1 ] && [ "$(cat "$U/out.txt")" = unknown ] && ok || bad "U10: no row must miss unknown (rc=$RC out=$(cat "$U/out.txt"))"
# U11 payload: an unparseable at -> malformed.
row "$U" 966 '{"state":"dequeued","comment_id":7,"at":"yesterday"}' null
useam ph_payload_record "$U/f" "$SLUG" 966; RC=$?
[ "$RC" = 1 ] && [ "$(cat "$U/out.txt")" = malformed ] && ok || bad "U11: a bad at must miss malformed (rc=$RC out=$(cat "$U/out.txt"))"

# U12 status: the record statuses of the head in the combined-status shape.
row "$U" 967 null null "$(jq -nc --arg s "$(sha 967)" --arg o "$(sha 1)" '{"lead-verdict": {state: "success", description: "x", sha: $s, at: "2025-11-24T12:00:00Z"},
  "harness-verdict": {state: "pending", description: "y", sha: $s, at: "2025-11-24T11:00:00Z"}, "ci": {state: "failure", sha: $o, at: "2025-11-24T10:00:00Z"}}')"
useam ph_status_record "$U/f" "$SLUG" 967 "$(sha 967)"; RC=$?
[ "$RC" = 0 ] && [ "$(jq -c '.statuses | sort_by(.context)' "$U/f")" \
  = '[{"context":"harness-verdict","state":"pending","updated_at":"2025-11-24T11:00:00Z"},{"context":"lead-verdict","state":"success","updated_at":"2025-11-24T12:00:00Z"}]' ] \
  && ok || bad "U12: status shape (rc=$RC f=$(cat "$U/f" 2>/dev/null) out=$(cat "$U/out.txt"))"
# U13 status: entries only for an older head -> miss none.
useam ph_status_record "$U/f" "$SLUG" 967 "$(sha 2)"; RC=$?
[ "$RC" = 1 ] && [ "$(cat "$U/out.txt")" = none ] && ok || bad "U13: another head must miss none (rc=$RC out=$(cat "$U/out.txt"))"

# U14 norms: equal for equal data, unequal for a changed number, state or verdict.
normeq() { # normeq <name> <fn> <a-file> <b-file> <equal|differ>
  local a b
  a=$(useam "$2" "$3"; cat "$U/out.txt"); b=$(useam "$2" "$4"; cat "$U/out.txt")
  if [ "$5" = equal ]; then [ -n "$a" ] && [ "$a" = "$b" ] && ok || bad "U14 $1: must be equal ($a vs $b)"
  else [ -n "$a" ] && [ "$a" != "$b" ] && ok || bad "U14 $1: must differ ($a vs $b)"; fi
}
printf 'dequeued\t100\t7\n' > "$T/pa"; printf 'dequeued\t999\t7\n' > "$T/pb"; printf 'queued\t100\t7\n' > "$T/pc"; printf 'dequeued\t100\t8\n' > "$T/pd"
normeq payload-epoch ph_payload_norm "$T/pa" "$T/pb" equal
normeq payload-state ph_payload_norm "$T/pa" "$T/pc" differ
normeq payload-cid ph_payload_norm "$T/pa" "$T/pd" differ
printf '1700000000' > "$T/ha"; printf '1700000001' > "$T/hb"
normeq hct ph_hct_norm "$T/ha" "$T/hb" differ
normeq hct-same ph_hct_norm "$T/ha" "$T/ha" equal
echo '{"statuses":[{"context":"lead-verdict","state":"success","updated_at":"a"},{"context":"ci","state":"failure"}]}' > "$T/sa"
echo '{"state":"x","statuses":[{"context":"ci","state":"success"},{"context":"lead-verdict","state":"success","updated_at":"b"}]}' > "$T/sb"
echo '{"statuses":[{"context":"lead-verdict","state":"failure","updated_at":"a"}]}' > "$T/sc"
normeq status-other-context ph_status_norm "$T/sa" "$T/sb" equal
normeq status-verdict ph_status_norm "$T/sa" "$T/sc" differ
echo '[{"number":2,"head":{"sha":"b"},"labels":[{"name":"y"},{"name":"x"}]},{"number":1,"head":{"sha":"a"},"labels":[]}]' > "$T/oa"
echo '[{"number":1,"head":{"sha":"a"},"labels":[],"title":"t"},{"number":2,"head":{"sha":"b"},"labels":[{"name":"x"},{"name":"y"}]}]' > "$T/ob"
echo '[{"number":1,"head":{"sha":"a"},"labels":[]},{"number":3,"head":{"sha":"b"},"labels":[{"name":"x"},{"name":"y"}]}]' > "$T/oc"
echo '[{"number":1,"head":{"sha":"c"},"labels":[]},{"number":2,"head":{"sha":"b"},"labels":[{"name":"x"},{"name":"y"}]}]' > "$T/od"
normeq open-order ph_open_norm "$T/oa" "$T/ob" equal
normeq open-number ph_open_norm "$T/oa" "$T/oc" differ
normeq open-head ph_open_norm "$T/oa" "$T/od" differ
echo '[{"number":5,"pull_request":{},"labels":[{"name":"merge-queue"}]}]' > "$T/la"
echo '[{"number":6,"pull_request":{},"labels":[{"name":"merge-queue"}]}]' > "$T/lb"
normeq sdl-number ph_sdl_norm "$T/la" "$T/lb" differ

# ============================================================================
# P0: no prr-shadow lib, the 13c block runs today's inline reads.
# ============================================================================
P0="$T/p0"; mkh "$P0"; sd_fixture "$P0"
drive "$P0" sd NOSEAM=1
grep -qx reached "$P0/drive.out" && ok || bad "P0: the block did not run to its end: $(cat "$P0/drive.out")"
[ "$(keys "$P0")" = "staledequeue:proj:943 staledequeue:proj:944" ] && ok || bad "P0: must page 943 and 944: $(cat "$P0/alerts.txt")"
[ "$(grep -c 'issues?labels=merge-queue' "$P0/gh-calls.txt")" = 1 ] && [ "$(grep -c '/comments' "$P0/gh-calls.txt")" = 4 ] \
  && [ "$(grep -cE 'commits/ab[0-9]+ ' "$P0/gh-calls.txt")" = 2 ] && ok || bad "P0: today's reads expected: $(cat "$P0/gh-calls.txt")"
[ "$(lists "$P0")" = 0 ] && ok || bad "P0: no seam must make 0 list reads"

# ============================================================================
# P1: step record, 13c, fresh records: 0 gh calls, the same 2 pages.
# ============================================================================
P1="$T/p1"; mkh "$P1"; sd_fixture "$P1"
drive "$P1" sd GH_SOURCE=record
grep -qx reached "$P1/drive.out" && ok || bad "P1: the block did not run to its end: $(cat "$P1/drive.out")"
[ ! -s "$P1/gh-calls.txt" ] && ok || bad "P1: step record with fresh records must make 0 gh calls: $(cat "$P1/gh-calls.txt")"
[ "$(keys "$P1")" = "staledequeue:proj:943 staledequeue:proj:944" ] && ok || bad "P1: must page 943 and 944: $(cat "$P1/alerts.txt")"
[ "$(lists "$P1")" = 1 ] && ok || bad "P1: one record list read expected: $(cat "$P1/jobs-calls.txt")"
LOG1=$(cat "$P1/logs/prr-shadow.log" 2>/dev/null)
grep -q PRR_MISS <<<"$LOG1" && bad "P1: a hit wrote a PRR_MISS line: $LOG1" || ok

# ============================================================================
# P2: step record, 13d over 3 open PRs, no lead success: 0 gh, 0 pages.
# ============================================================================
lu_fixture() {
  local h="$1" lead951="$2"
  list "$h" 30 false "$(lrow 951 ai-build)" "$(lrow 952 '')" "$(lrow 953 ai-build)"
  ghopen "$h"
  row "$h" 951 null null "$(jq -nc --arg s "$(sha 951)" --arg st "$lead951" --arg at "$(iso $((NOW0 - 3600)))" '{"lead-verdict": {state: $st, sha: $s, at: $at}}')"
  row "$h" 952 null null "$(jq -nc --arg s "$(sha 952)" --arg at "$(iso $((NOW0 - 3600)))" '{"lead-verdict": {state: "failure", sha: $s, at: $at}, "harness-verdict": {state: "success", sha: $s, at: $at}}')"
  row "$h" 953 null null "$(jq -nc --arg s "$(sha 953)" --arg at "$(iso $((NOW0 - 3600)))" '{"harness-verdict": {state: "pending", sha: $s, at: $at}}')"
}
P2="$T/p2"; mkh "$P2"; lu_fixture "$P2" pending
drive "$P2" "open lu" GH_SOURCE=record LEAD_REVIEW_AUTO_REPOS="$SLUG"
grep -qx reached "$P2/drive.out" && ok || bad "P2: the blocks did not run to their end: $(cat "$P2/drive.out")"
[ ! -s "$P2/gh-calls.txt" ] && ok || bad "P2: step record must make 0 gh calls: $(cat "$P2/gh-calls.txt")"
[ ! -s "$P2/alerts.txt" ] && ok || bad "P2: no lead success must raise 0 pages: $(cat "$P2/alerts.txt")"
[ "$(grep -c 'number=95[123]$' "$P2/jobs-calls.txt")" = 3 ] && ok || bad "P2: one status row read per PR expected: $(cat "$P2/jobs-calls.txt")"
# P2b: a lead success 60m old in the record pages 951; the only gh call is its reviews read.
P2B="$T/p2b"; mkh "$P2B"; lu_fixture "$P2B" success
drive "$P2B" "open lu" GH_SOURCE=record LEAD_REVIEW_AUTO_REPOS="$SLUG"
[ "$(keys "$P2B")" = "leadunqueued:$SLUG#951:$(sha 951 | cut -c1-12)" ] && ok || bad "P2b: the record's lead success must page 951: $(cat "$P2B/alerts.txt")"
G2B=$(grep -v '/reviews' "$P2B/gh-calls.txt")
[ -z "$G2B" ] && ok || bad "P2b: only a reviews read may reach gh: $G2B"

# ============================================================================
# P3: step record, ph_open_rows <slug> 100 in the REST shape, 0 pulls reads.
# ============================================================================
P3="$T/p3"; mkh "$P3"
list "$P3" 30 false "$(lrow 981 ai-build)" "$(lrow 982 '')"
cat > "$T/b-p3.sh" <<'EOF'
ph_open_rows example-org/proj-os 100 > "$CT/rows.json"; echo "rc=$?" > "$CT/rows.rc"
EOF
drive "$P3" "open p3" GH_SOURCE=record
[ "$(cat "$P3/rows.rc" 2>/dev/null)" = rc=0 ] && ok || bad "P3: ph_open_rows rc: $(cat "$P3/rows.rc" 2>/dev/null) $(cat "$P3/drive.out")"
[ "$(jq -c '[.[] | {number, ref: .head.ref, body}]' "$P3/rows.json" 2>/dev/null)" \
  = '[{"number":981,"ref":"ticket/x-981","body":"Refs #981"},{"number":982,"ref":"ticket/x-982","body":"Refs #982"}]' ] \
  && ok || bad "P3: rows not in the REST shape: $(cat "$P3/rows.json" 2>/dev/null)"
G3=$(cat "$P3/gh-calls.txt")
grep -q 'pulls' <<<"$G3" && bad "P3: a pulls read reached gh: $G3" || ok
grep -q 'state=open&order=created&limit=100' "$P3/jobs-calls.txt" && ok || bad "P3: the record list must be asked for window 100: $(cat "$P3/jobs-calls.txt")"

# ============================================================================
# P4: step shadow, 1 changed label in the record: GitHub acts, 1 PRR_SHADOW.
# ============================================================================
P4="$T/p4"; mkh "$P4"; sd_fixture "$P4"
# The record says 944 is queued (Mergify holds it); GitHub's list does not.
list "$P4" 30 false "$(lrow 941 merge-queue)" "$(lrow 942 merge-queue)" "$(lrow 943 merge-queue)" "$(lrow 944 merge-queue,queued)"
drive "$P4" sd GH_SOURCE=shadow
[ "$(grep -c 'issues?labels=merge-queue' "$P4/gh-calls.txt")" = 1 ] && ok || bad "P4: shadow must read GitHub's label list: $(cat "$P4/gh-calls.txt")"
[ "$(keys "$P4")" = "staledequeue:proj:943 staledequeue:proj:944" ] && ok || bad "P4: shadow must act on GitHub (943 and 944): $(cat "$P4/alerts.txt")"
[ "$(shadows "$P4")" = 1 ] && grep -q "PRR_SHADOW lane=pipeline-health key=$SLUG#labels:merge-queue " "$P4/logs/prr-shadow.log" \
  && ok || bad "P4: exactly 1 PRR_SHADOW line on the label list: $(cat "$P4/logs/prr-shadow.log" 2>/dev/null)"

# ============================================================================
# P5: step record, a stale list stamp: PRR_MISS why=stale, 1 GitHub list read.
# ============================================================================
P5="$T/p5"; mkh "$P5"
list "$P5" 5000 false "$(lrow 981 ai-build)" "$(lrow 982 '')"; ghopen "$P5"
drive "$P5" "open p3" GH_SOURCE=record
grep -q "PRR_MISS lane=pipeline-health key=$SLUG#open:100 why=stale fallback=github" "$P5/logs/prr-shadow.log" 2>/dev/null \
  && ok || bad "P5: one PRR_MISS why=stale line expected: $(cat "$P5/logs/prr-shadow.log" 2>/dev/null)"
[ "$(grep -c 'pulls' "$P5/gh-calls.txt")" = 1 ] && ok || bad "P5: exactly one GitHub list read expected: $(cat "$P5/gh-calls.txt")"
[ "$(jq -c '[.[].number]' "$P5/rows.json" 2>/dev/null)" = '[981,982]' ] && ok || bad "P5: the GitHub rows must be served: $(cat "$P5/rows.json" 2>/dev/null)"

# ============================================================================
# P6: step off: today's gh reads, 0 /api/pr-records reads.
# ============================================================================
P6="$T/p6"; mkh "$P6"; sd_fixture "$P6"
drive "$P6" sd GH_SOURCE=off
[ "$(keys "$P6")" = "staledequeue:proj:943 staledequeue:proj:944" ] && ok || bad "P6: must page 943 and 944: $(cat "$P6/alerts.txt")"
[ "$(sort "$P6/gh-calls.txt")" = "$(sort "$P0/gh-calls.txt")" ] && ok || bad "P6: off must make today's gh calls: $(cat "$P6/gh-calls.txt")"
[ "$(lists "$P6")" = 0 ] && ok || bad "P6: off must make 0 record list reads"

echo "pipeline-health-record.bh-9938: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
