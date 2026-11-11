#!/bin/bash
# tests/group-findings-area.bh-8739-test.sh — BH-8739: a QA run files ONE issue
# per AREA or flow, never per screen.
#
# Drives the real bin/lib/group-findings.sh (installed with its closure into a
# scratch harness) against a fake GitHub (tests/lib/gh-rest-fx.sh) and the real
# lane registry, so the knobs are real settings rows.
#
#   A1  12 /finance/... findings -> 1 issue with 12 checklist items
#   A2  the gf_area case table
#   A3  the areas row maps /portal/* to `area:member portal`
#   A4  an open issue with today's `|/clients` marker gets the /clients/12 comment
#   A5  an invalid areas value groups as {} and writes one areas-invalid row
#
# Run: HARNESS_TEST_SANDBOX=1 bash tests/group-findings-area.bh-8739-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
. "$(dirname "$0")/lib/gh-rest-fx.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "group-findings-area.bh-8739: jq is required"; exit 1; }

SLUG=example-org/demo
H="$T/h"; mkdir -p "$H/state" "$H/logs" "$T/tmp"
if ! scratch_install_closure bin/lib/group-findings.sh "$H" >/dev/null; then
  echo "FAIL: cannot install the closure of bin/lib/group-findings.sh"
  echo "group-findings-area.bh-8739: 0 passed, 1 failed"; exit 1
fi
# The jobs client too: the follow-up floor (A6) reads review.* rows through it.
( cd "$DIR" && scratch_install_closure bin/jobs-client.sh "$H" ) >/dev/null \
  || { echo "FAIL: cannot install the closure of bin/jobs-client.sh"; echo "group-findings-area.bh-8739: 0 passed, 1 failed"; exit 1; }
REG=$(rendered_registry)
ghfx_init
export HARNESS="$H" TMPDIR="$T/tmp" PATH="$T/fakebin:$PATH" LANE_REGISTRY="$REG" \
       LANE_GATE_NOW=2000000000 GH_ETAG=0 JOBS_URL=
unset GROUP_FINDINGS GROUP_FINDINGS_URGENT_RANK GROUP_FINDINGS_AREAS LANE_GATE_DISABLE REVIEW_LEVEL_FOLLOWUP_MIN_LEVEL REVIEW_LEVEL_CORE_FLOWS HARNESS_SECRET
# shellcheck source=bin/lib/group-findings.sh
. "$H/bin/lib/group-findings.sh" || { echo "FAIL: cannot source the lib"; exit 1; }

ghfx_extra <<'SH'
if [ "${1:-}" = api ] && [ "${3:-}" = -X ] && [ "${4:-}" = POST ]; then
  n=$(( $(cat "$GHFX/post.n" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$GHFX/post.n"
  mkdir -p "$GHFX/posts"; printf '%s\n' "$5" > "$GHFX/posts/$n.path"
  for a in "$@"; do
    case "$a" in
      title=*) printf '%s\n' "${a#title=}" > "$GHFX/posts/$n.title" ;;
      body=@*) cp "${a#body=@}" "$GHFX/posts/$n.body" ;;
    esac
  done
  case "$5" in
    */comments) printf 'HTTP/1.1 201 Created\r\n\r\n{"id":%s,"html_url":"https://github.com/fixture/issues/1#issuecomment-%s"}' "$n" "$n" ;;
    *) printf 'HTTP/1.1 201 Created\r\n\r\n{"number":%s,"html_url":"https://github.com/fixture/issues/%s"}' $((100+n)) $((100+n)) ;;
  esac
  exit 0
fi
SH

knob() { # knob <areas-json-or-empty> — grouping on for project-3, plus the areas row
  local v
  v=$(jq -nc '{"lib.group-findings.project-3.group_findings": "1"}')
  [ -n "${1:-}" ] && v=$(jq -c --arg a "$1" '. + {"lib.group-findings.project-3.group_findings_areas": $a}' <<<"$v")
  scratch_rm "$H/state/lane-gate"
  jq -nc --argjson v "$v" '{fetched_at:2000000000, values:$v, seeded:{}}' > "$H/state/settings-cache.json"
}
fnd() { # fnd <key> <severity> <title>
  jq -nc --arg k "$1" --arg s "$2" --arg t "$3" \
    '{board:"project-3", screen_or_flow:$k, severity:$s, title:$t,
      repro:("Open " + $k + " as the QA user."), cause:("fixture cause: " + $t)}'
}
iss() { jq -nc --argjson n "$1" --arg b "$2" '{number:$n, state:"open", title:"fixture issue", body:$b}'; }
mk() { printf '<!-- findings-group: project-3|%s -->' "$1"; }
new_run() {
  RD="$T/runs/$1"; mkdir -p "$RD"; : > "$RD/in.jsonl"
  ghfx_routes_reset; ghfx_log_reset
  scratch_rm "$T/posts"; rm -f "$T/post.n"
}
issues() { ghfx_route GET "repos/$SLUG/issues" 200 "$1"; }
gfrun() { ( gf_run "$RD/in.jsonl" "$RD" "$SLUG" "$@" ) > "$RD/out.txt" 2>&1; RC=$?; }
nposts() {
  local f n=0
  for f in "$T"/posts/*.path; do
    [ -e "$f" ] || continue
    # shellcheck disable=SC2254
    case "$(cat "$f")" in $1) n=$((n+1)) ;; esac
  done
  echo "$n"
}
post_body() {
  local f
  for f in $(ls "$T"/posts/*.path 2>/dev/null | sort -V); do
    # shellcheck disable=SC2254
    case "$(cat "$f")" in $1) cat "${f%.path}.body"; return 0 ;; esac
  done
}
items() { grep -c '^- \[ \] ' <<<"$1"; }

# --- A1: 12 screens in one area -> 1 issue, 12 checklist items -------------------
new_run a1; knob ""; issues '[]'
for s in invoices invoices/12 invoices/12@375 payments payments/7 payroll payroll/run \
         budgets budgets/2026 reports reports/q3 ledger; do
  fnd "/finance/$s" medium "Finding on $s" >> "$RD/in.jsonl"
done
gfrun
[ "$RC" = 0 ] && ok || bad "A1: rc=$RC: $(cat "$RD/out.txt")"
[ "$(nposts "repos/$SLUG/issues")" = 1 ] && ok || bad "A1: want exactly 1 issue POST, got $(nposts "repos/$SLUG/issues")"
B=$(post_body "repos/$SLUG/issues")
grep -qF "$(mk /finance)" <<<"$B" && ok || bad "A1: the issue lacks the /finance area marker: $B"
[ "$(items "$B")" = 12 ] && ok || bad "A1: want 12 checklist items, got $(items "$B")"
grep -q 'One PR fixes this area\.' <<<"$B" && ok || bad "A1: the body must say one PR fixes this area: $B"
grep -q '^QA findings: /finance (12 items)$' "$T/posts/1.title" 2>/dev/null && ok || bad "A1: title: $(cat "$T/posts/1.title" 2>/dev/null)"
grep -q '^group-findings: 12 findings, 1 groups, filed 1' "$RD/group-findings.md" && ok \
  || bad "A1: totals line: $(tail -1 "$RD/group-findings.md" 2>/dev/null)"

# --- A2: the gf_area case table ----------------------------------------------------
area_is() { # area_is <want> <key> [areas]
  local got; got=$(gf_area "$2" "${3:-}")
  [ "$got" = "$1" ] && ok || bad "A2: gf_area '$2' ${3:+with $3 }gave '$got', want '$1'"
}
area_is /finance "/finance/invoices/12@375"
area_is /finance "/finance"
area_is / "/"
area_is /finance "/Finance?x=1"
area_is flow:rep/x "flow:rep/x"
area_is "" ""
area_is "area:member portal" "/portal/events" '{"/portal":"member portal"}'
area_is "area:member portal" "/portal" '{"/portal":"Member Portal"}'
area_is /portals "/portals" '{"/portal":"member portal"}'
area_is "area:operations" "/finance/payroll/run" '{"/finance":"finance","/finance/payroll":"operations"}'
area_is "area:finance" "/finance/invoices" '{"/finance":"finance","/finance/payroll":"operations"}'
area_is /finance "/finance/x" 'not json'
# gf_key itself is unchanged: a screen stays its own key.
[ "$(gf_key /clients/123)" = /clients/123 ] && ok || bad "A2: gf_key must keep /clients/123"

# --- A3: the areas row maps /portal/* to one named area ---------------------------
new_run a3; knob '{"/portal":"member portal"}'; issues '[]'
fnd "/portal/events" medium "Events list" >> "$RD/in.jsonl"
fnd "/portal/profile/3" low "Profile" >> "$RD/in.jsonl"
fnd "/members/9" medium "Members" >> "$RD/in.jsonl"
gfrun
[ "$RC" = 0 ] && ok || bad "A3: rc=$RC: $(cat "$RD/out.txt")"
[ "$(nposts "repos/$SLUG/issues")" = 2 ] && ok || bad "A3: want 2 issues (member portal, /members), got $(nposts "repos/$SLUG/issues")"
B=$(post_body "repos/$SLUG/issues")
grep -qF "$(mk 'area:member portal')" <<<"$B" && ok || bad "A3: the first issue lacks the member portal marker: $B"
[ "$(items "$B")" = 2 ] && ok || bad "A3: the member portal issue must carry 2 items, got $(items "$B")"

# --- A4: today's single-segment marker still matches ------------------------------
new_run a4; knob ""
issues "[$(iss 50 "$(mk /clients)")]"
ghfx_route GET "repos/$SLUG/pulls" 200 '[]'
ghfx_route GET "repos/$SLUG/issues/50/comments" 200 '[]'
fnd "/clients/12" medium "Client detail" >> "$RD/in.jsonl"
gfrun
[ "$RC" = 0 ] && ok || bad "A4: rc=$RC: $(cat "$RD/out.txt")"
[ "$(nposts "repos/$SLUG/issues/50/comments")" = 1 ] && ok || bad "A4: want 1 comment on #50"
[ "$(nposts "repos/$SLUG/issues")" = 0 ] && ok || bad "A4: no new issue expected"

# --- A5: an invalid areas value -> {} and one areas-invalid row --------------------
new_run a5; knob '{"/portal": broken'; issues '[]'
fnd "/portal/events" medium "Events" >> "$RD/in.jsonl"
fnd "/portal/news" medium "News" >> "$RD/in.jsonl"
gfrun
[ "$RC" = 0 ] && ok || bad "A5: rc=$RC: $(cat "$RD/out.txt")"
[ "$(nposts "repos/$SLUG/issues")" = 1 ] && ok || bad "A5: want 1 issue, got $(nposts "repos/$SLUG/issues")"
grep -qF "$(mk /portal)" <<<"$(post_body "repos/$SLUG/issues")" && ok || bad "A5: an invalid map must group by first segment"
[ "$(jq -s '[.[] | select(.note == "areas-invalid")] | length' "$RD/findings-ledger.jsonl")" = 1 ] \
  && ok || bad "A5: want exactly 1 areas-invalid row"
gfrun
[ "$(jq -s '[.[] | select(.note == "areas-invalid")] | length' "$RD/findings-ledger.jsonl")" = 1 ] \
  && ok || bad "A5: a rerun must not add a second areas-invalid row"

# --- A6: the follow-up floor still sees a core flow below the area ---------------
# review.core_flows names /finance/payroll; the group key is the area /finance.
new_run a6; issues '[]'
scratch_rm "$H/state/lane-gate"
jq -nc '{fetched_at:2000000000, seeded:{}, values:{"lib.group-findings.project-3.group_findings":"1",
  "review.followup_min_level":"core", "review.core_flows.project-3":"/finance/payroll"}}' > "$H/state/settings-cache.json"
fnd "/finance/payroll/run" medium "Payroll total is blank" >> "$RD/in.jsonl"
gfrun
[ "$(nposts "repos/$SLUG/issues")" = 1 ] && ok || bad "A6: a medium finding on a core-flow screen inside an area must still file, got $(nposts "repos/$SLUG/issues"): $(cat "$RD/group-findings.md" 2>/dev/null)"
# and a medium finding on a non-core screen of the same area stays under the floor
new_run a6b; issues '[]'
fnd "/finance/budgets/2026" medium "Budget chart overlaps" >> "$RD/in.jsonl"
gfrun
[ "$(nposts "repos/$SLUG/issues")" = 0 ] && ok || bad "A6b: a medium non-core group must stay under the floor, got $(nposts "repos/$SLUG/issues")"

echo "group-findings-area.bh-8739: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
