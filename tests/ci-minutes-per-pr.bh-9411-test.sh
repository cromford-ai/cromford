#!/bin/bash
# tests/ci-minutes-per-pr.bh-9411-test.sh — BH-9411: bin/ci-minutes-watch.sh
# reports CI minutes per merged PR and the minutes spent on PRs closed unmerged.
#
#   P1  merged_prs_24h and min_per_merged_pr (repo estimate / merged PRs)
#   P2  0 merged PRs: an empty log value and JSON null, never 0, and no page;
#       a failed closed-PR read says `pr list unread` and keeps the estimate
#   P3  unmerged_min_24h / unmerged_share: same-repo heads of PRs closed
#       unmerged; merge-queue drafts, forks, re-merged heads and prefix
#       look-alikes are not unmerged
#   P4  min_per_merged_pr_7d from state/ci-minutes/ticks.jsonl: one tick per
#       24 h slot, cron jitter, merged:null and corrupt lines skipped, the
#       window bound, and a writer/reader round trip
#   P5  one critical page a day per repo; under 5 merged PRs no page; the
#       line is strict (> 400)
#   P6  no settings row: the line is 400
#   P7  the per-project row beats the lane-wide row
#   P8  the GitHub reads: pages + sample + 1 pulls per readable repo, nothing
#       else; a 100-item page cut in the window is a floor and never pages
#   P9  --dry-run stores no tick, prunes nothing, pages nothing
#   P10 the fleet: line and latest.json fleet_per_pr
#   P11 the ci_health payload carries the 9 keys, equal to latest.json
#   P12 retention of ticks.jsonl: window row, dry run by default, apply keeps
#       the newer lines byte for byte, one audit line per run
#
# A scratch harness, the k1 fake `gh` extended with */pulls, a fixture jobs
# client (ci_health_put to payload.tsv, /api/settings from $ROWS), a beat.sh
# stub. No network.
# Run: HARNESS_TEST_SANDBOX=1 bash tests/ci-minutes-per-pr.bh-9411-test.sh
set -uo pipefail
. "$(dirname "$0")/lib/scratch.sh" || exit 1
DIR=$(cd "$(dirname "$0")/.." && pwd)
. "$(dirname "$0")/lib/rendered.sh" || exit 1
REG=$(rendered_registry)
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); }
bad() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
NOW=2000000000
D=86400
iso() { date -u -d "@$(( NOW - $1 ))" '+%Y-%m-%dT%H:%M:%SZ'; }

HH="$T/h"
mkdir -p "$HH/bin/lib" "$HH/logs" "$HH/fx" "$HH/state" "$T/stub"
cat > "$HH/fleet.conf" <<'CONF'
a     Acme/a   - - 1 box-a 192.0.2.1
b     Acme/b   - - 2 box-a 192.0.2.1
CONF
# Written BEFORE the closure, which never overwrites a file the suite wrote.
cat > "$HH/bin/jobs-client.sh" <<'SH'
ci_health_put() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$HARNESS/payload.tsv"; }
_jobs_req() {
  case "$2" in
    /api/settings)
      local out="[]" kv
      for kv in ${ROWS:-}; do
        out=$(printf '%s' "$out" | jq -c --arg k "${kv%%=*}" --arg v "${kv#*=}" '. + [{key:$k,value:$v,actor:"t"}]')
      done
      printf '{"settings":%s}' "$out" ;;
    *) return 1 ;;
  esac
}
SH
cat > "$HH/bin/beat.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$1" >> "$HARNESS/beats.txt"
SH
chmod +x "$HH/bin/beat.sh"
scratch_install_closure bin/ci-minutes-watch.sh "$HH" >/dev/null || exit 1
cp "$DIR/bin/fleet-conf.sh" "$HH/bin/" || exit 1
for f in gh-budget.sh gh-repo-token.sh; do scratch_rm "$HH/bin/lib/$f"; done

# The fake gh (the k1 shape) plus */pulls -> fx/<repo>.pulls.json. Every call
# is recorded; a path it does not serve is recorded in unknown.txt.
cat > "$T/stub/gh" <<'SH'
#!/bin/bash
shift   # "api"
P=""; Q=""; PG=1
while [ $# -gt 0 ]; do
  case "$1" in
    -X) shift 2 ;;
    -q|--jq) Q="$2"; shift 2 ;;
    -f) case "$2" in page=*) PG="${2#page=}" ;; esac; shift 2 ;;
    *) P="$1"; shift ;;
  esac
done
echo "$P page=$PG" >> "$HARNESS/gh-calls.txt"
R=$(sed -E 's#^repos/([^/]+)/([^/]+)/.*#\1_\2#' <<<"$P")
case "$P" in
  */actions/runs/*/jobs*) ID=$(sed -E 's#.*/runs/([0-9]+)/jobs.*#\1#' <<<"$P"); F="$HARNESS/fx/$R.jobs.$ID.json" ;;
  */actions/runs) F="$HARNESS/fx/$R.runs.$PG.json" ;;
  */pulls) F="$HARNESS/fx/$R.pulls.json" ;;
  *) echo "$P" >> "$HARNESS/unknown.txt"; exit 1 ;;
esac
[ -r "$F" ] || exit 1
if [ -n "$Q" ]; then jq -c "$Q" "$F"; else cat "$F"; fi
SH
chmod +x "$T/stub/gh"

# ---- fixtures ---------------------------------------------------------------
# runs <repo_key> <wall-min> <id:branch>... — completed runs of workflow 1;
# each run gets one MonkCI job as long as the run (x2 billed with MULT 2).
runs() {
  local key="$1" wall="$2" out="" spec id b; shift 2
  for spec in "$@"; do
    id="${spec%%:*}"; b="${spec#*:}"
    out="$out${out:+,}$(jq -nc --argjson i "$id" --arg b "$b" --arg s "$(iso $(( 7200 + wall * 60 )))" --arg u "$(iso 7200)" \
      '{id:$i, workflow_id:1, event:"pull_request", name:"ci", head_branch:$b, head_sha:"s\($i)", run_started_at:$s, updated_at:$u}')"
    echo "{\"jobs\":[{\"labels\":[\"monkci-ubuntu-24.04-4\"],\"runner_name\":\"r\",\"started_at\":\"$(iso $(( 7200 + wall * 60 )))\",\"completed_at\":\"$(iso 7200)\"}]}" \
      > "$HH/fx/$key.jobs.$id.json"
  done
  printf '{"total_count":%s,"workflow_runs":[%s]}\n' "$#" "$out" > "$HH/fx/$key.runs.1.json"
}
# pr <branch> <head-repo> <merged-ago-s|-> <closed-ago-s> [updated-ago-s] — one closed PR
PRS=""
pr() {
  local m=null c u
  [ "$3" = - ] || m="\"$(iso "$3")\""
  c="\"$(iso "$4")\""; u="\"$(iso "${5:-$4}")\""
  PRS="$PRS${PRS:+,}{\"head\":{\"ref\":\"$1\",\"repo\":{\"full_name\":\"$2\"}},\"merged_at\":$m,\"closed_at\":$c,\"updated_at\":$u}"
}
pulls() { printf '[%s]\n' "$PRS" > "$HH/fx/$1.pulls.json"; PRS=""; }

# Acme/a: 20 runs x 100 wall min, each billed 200 (ratio 2) -> est 4000.
#   ticket/bh-7 x2 (closed unmerged, same repo)     -> 400 unmerged min
#   mergify/merge-queue/q1, gh-readonly-queue/... (drafts closed unmerged), a
#   fork's branch, ticket/both (unmerged AND merged), ticket/bh-71 (no PR),
#   ticket/stale (closed unmerged 25 h ago)         -> not unmerged
A_RUNS=(1001:main 1002:main 1003:main 1004:main 1005:main 1006:main 1007:main 1008:main 1009:main
        1010:ticket/stale 1011:ticket/bh-7 1012:ticket/bh-7 1013:mergify/merge-queue/q1
        1014:gh-readonly-queue/main/pr-3-abc 1015:fork-branch 1016:ticket/both 1017:ticket/bh-71
        1018:ticket/m1 1019:ticket/m2 1020:ticket/m3)
runs Acme_a 100 "${A_RUNS[@]}"
a_pulls() {
  local i
  for i in 1 2 3 4 5 6 7 8 9; do pr "ticket/m$i" Acme/a $(( 3600 + i )) $(( 3600 + i )); done
  pr ticket/both Acme/a 3000 3000                  # merged: 10 in the window
  pr ticket/old Acme/a $(( 25 * 3600 )) 3500       # merged 25 h ago: not counted
  pr gh-readonly-queue/main/pr-9-x Acme/a 2000 2000 # a merged draft: not a merged PR
  pr ticket/bh-7 Acme/a - 4000
  pr ticket/both Acme/a - 4100
  pr mergify/merge-queue/q1 Acme/a - 4200
  pr gh-readonly-queue/main/pr-3-abc Acme/a - 4300
  pr fork-branch someone/a - 4400
  pr ticket/stale Acme/a - $(( 25 * 3600 ))
  pulls Acme_a
}
a_pulls
# Acme/b: 5 runs x 60 wall min, billed 120 each -> est 600; no merged PR.
runs Acme_b 60 2001:main 2002:main 2003:main 2004:main 2005:main
b_pulls() { local n="${1:-0}" i; for (( i = 1; i <= n; i++ )); do pr "ticket/b$i" Acme/b 5000 5000; done; pulls Acme_b; }
b_pulls 0

LOG="$HH/logs/ci-minutes-watch.log"; J="$HH/state/ci-minutes/latest.json"; TK="$HH/state/ci-minutes/ticks.jsonl"
fresh() { # wipe the lane's own state between cases; fixtures stay
  local x; for x in "$HH/state" "$HH/beats.txt" "$HH/payload.tsv" "$HH/unknown.txt" "$LOG"; do scratch_rm "$x" || exit 1; done
  mkdir -p "$HH/state/ci-minutes"
}
drive() { # drive [VAR=val...] [--dry-run]
  local a args=() envs=()
  for a in "$@"; do case "$a" in --*) args+=("$a") ;; *) envs+=("$a") ;; esac; done
  scratch_rm "$HH/gh-calls.txt" && scratch_rm "$HH/state/settings-cache.json" && scratch_rm "$HH/state/lane-gate" || exit 1
  ( export HARNESS="$HH" FLEET_CONF="$HH/fleet.conf" NOW PATH="$T/stub:$PATH" LANE_REGISTRY="$REG" ROWS="${ROWS:-}" \
      CI_MINUTES_DAY_MAX=0 CI_MINUTES_BILL_MULT=2
    [ ${#envs[@]} -gt 0 ] && export "${envs[@]}"
    bash "$HH/bin/ci-minutes-watch.sh" "${args[@]}" ) >"$T/out.txt" 2>&1
}
pp() { grep "ci-per-pr repo=$1 " "$LOG" | grep -v 'not paged' | tail -1; }
rj() { jq -c --arg r "$1" ".repos[] | select(.repo == \$r) | $2" "$J" 2>/dev/null; }
beats() { if [ -f "$HH/beats.txt" ]; then grep -c "\"alertid\":\"ci-minutes:per-pr:$1\"" "$HH/beats.txt"; else echo 0; fi; }
# tick <ago-s> <est> <merged|null> [floor] [repo] — one stored tick line
tick() { printf '{"at":%s,"repos":{"%s":{"est":%s,"merged":%s,"unmerged":0,"floor":%s}}}\n' \
  "$(( NOW - $1 ))" "${5:-Acme/a}" "$2" "$3" "${4:-false}" >> "$TK"; }

# ---- P1 / P3 / P6 / P10 / P11: one plain tick ---------------------------------
fresh; drive
L=$(pp Acme/a)
grep -q 'merged_prs_24h=10 min_per_merged_pr=400 ' <<<"$L" && ok || bad "P1: 10 merged PRs, 4000 / 10 = 400: $L"
[ "$(rj Acme/a .min_per_merged_pr)" = 400 ] && [ "$(rj Acme/a .merged_prs_24h)" = 10 ] \
  && ok || bad "P1: latest.json carries merged_prs_24h 10 and min_per_merged_pr 400: $(rj Acme/a .)"
grep -q 'unmerged_min_24h=400 unmerged_share=0.10 ' <<<"$L" && ok \
  || bad "P3: only ticket/bh-7's 2 runs (2 x 100 x 2 = 400) are unmerged; share 0.10: $L"
[ "$(rj Acme/a .unmerged_min_24h)" = 400 ] && [ "$(rj Acme/a .unmerged_share)" = 0.1 ] \
  && ok || bad "P3: latest.json unmerged_min_24h 400, unmerged_share 0.1: $(rj Acme/a .)"
grep -q ' line=400' <<<"$L" && [ "$(rj Acme/a .per_pr_max)" = 400 ] && ok || bad "P6: no settings row -> line 400: $L"
CL=$(grep -n 'ci-per-pr repo=Acme/a ' "$LOG" | head -1 | cut -d: -f1); EL=$(grep -n 'Acme/a:' "$LOG" | head -1 | cut -d: -f1)
[ -n "$CL" ] && [ -n "$EL" ] && [ "$CL" -lt "$EL" ] && grep 'Acme/a:' "$LOG" | tail -1 | grep -q 'est 4000 billed' \
  && ok || bad "P1: the ci-per-pr line comes before the estimate line, which stays last (est 4000)"
# P10: fleet a 4000 + b 600 = 4600 over 10 merged = 460; unmerged 400 / 4600 = 0.09
F=$(grep 'fleet:' "$LOG" | tail -1)
grep -q 'GitHub read(s)); merged_prs_24h=10 min_per_merged_pr=460 unmerged_min_24h=400 unmerged_share=0.09$' <<<"$F" \
  && ok || bad "P10: the fleet line carries the fleet per-PR figures after the reads: $F"
[ "$(jq -c '.fleet_per_pr | [.merged_prs_24h, .min_per_merged_pr, .unmerged_min_24h, .unmerged_share]' "$J")" = '[10,460,400,0.09]' ] \
  && [ "$(jq -c '.fleet_per_pr | keys' "$J")" = '["merged_prs_24h","min_per_merged_pr","unmerged_min_24h","unmerged_share"]' ] \
  && ok || bad "P10: latest.json fleet_per_pr: $(jq -c '.fleet_per_pr' "$J")"
# P11
PB=$(awk -F'\t' '$1 == "Acme/a" && $2 == "minutes" {print $3}' "$HH/payload.tsv" 2>/dev/null | tail -1)
K='[.merged_prs_24h, .min_per_merged_pr, .unmerged_min_24h, .unmerged_share, .min_per_merged_pr_7d, .merged_prs_7d, .days_7d, .per_pr_max, .pr_floor]'
[ -n "$PB" ] && [ "$(jq -c "$K" <<<"$PB")" = "$(rj Acme/a "$K")" ] && [ "$(jq -c "$K" <<<"$PB")" = '[10,400,400,0.1,400,10,1,400,false]' ] \
  && [ "${#PB}" -lt 8192 ] && ok || bad "P11: the payload carries the 9 keys equal to latest.json: $PB"

# ---- P2: no merged PR; an unread PR list -------------------------------------
L=$(pp Acme/b)
grep -q 'merged_prs_24h=0 min_per_merged_pr= unmerged_min_24h=0 ' <<<"$L" && ok || bad "P2: 0 merged -> empty value, never 0: $L"
[ "$(rj Acme/b .min_per_merged_pr)" = null ] && [ "$(rj Acme/b .min_per_merged_pr_7d)" = null ] && [ "$(beats Acme/b)" = 0 ] \
  && ok || bad "P2: 0 merged -> null in latest.json and no page: $(rj Acme/b .)"
mv "$HH/fx/Acme_b.pulls.json" "$HH/fx/Acme_b.pulls.off"
fresh; drive
L=$(pp Acme/b)
grep -q 'pr list unread' <<<"$L" && [ "$(rj Acme/b .merged_prs_24h)" = null ] && [ "$(rj Acme/b .unmerged_min_24h)" = null ] \
  && grep 'Acme/b:' "$LOG" | tail -1 | grep -q 'est 600 billed' && [ "$(beats Acme/b)" = 0 ] \
  && ok || bad "P2: a failed closed-PR read -> pr list unread, null fields, the estimate stands: $L / $(rj Acme/b .)"
[ "$(jq -c '.repos["Acme/b"].merged' "$TK" 2>/dev/null | tail -1)" = null ] && ok || bad "P2: the stored tick says merged:null for an unread list"
mv "$HH/fx/Acme_b.pulls.off" "$HH/fx/Acme_b.pulls.json"

# ---- P4: the 7-day figure ------------------------------------------------------
seed7() {
  local k h
  for (( k = 1; k <= 6; k++ )); do
    tick $(( k * D )) 4500 10
    [ "$k" -lt 6 ] && for h in 6 12 18; do tick $(( k * D + h * 3600 )) 9999 1; done
  done
  for h in 6 12 18; do tick $(( h * 3600 )) 9999 1; done      # 18 ticks between the daily ones
  tick $(( D - 600 )) 1 null                                  # merged:null in the first slot: skipped
  echo '{"at": not json' >> "$TK"                              # corrupt: skipped
}
fresh; seed7; drive
L=$(pp Acme/a)
grep -q 'min_per_merged_pr_7d=443 merged_prs_7d=70 days_7d=7 ' <<<"$L" && ok \
  || bad "P4: 7 daily picks, (6 x 4500 + 4000) / 70 = 443: $L"
# jitter: 23.6 h older is picked, 22 h older is not; an 8-day-old tick is outside
fresh; tick $(( D - 1440 )) 4000 10; drive
grep -q 'merged_prs_7d=20 days_7d=2 ' <<<"$(pp Acme/a)" && ok || bad "P4: a tick 23.6 h older is the next slot: $(pp Acme/a)"
fresh; tick $(( 22 * 3600 )) 4000 10; drive
grep -q 'merged_prs_7d=10 days_7d=1 ' <<<"$(pp Acme/a)" && ok || bad "P4: a tick 22 h older is the same slot: $(pp Acme/a)"
fresh; tick $(( 8 * D )) 4000 10; drive
grep -q 'merged_prs_7d=10 days_7d=1 ' <<<"$(pp Acme/a)" && ok || bad "P4: an 8-day-old tick is outside the window: $(pp Acme/a)"
# round trip: the line tick 1 wrote is read by tick 2 a day later
fresh; drive; NOW0=$NOW
NOW=$(( NOW0 + D )); a_pulls; drive; NOW=$NOW0; a_pulls
grep -q 'merged_prs_7d=20 days_7d=2 ' <<<"$(pp Acme/a)" && [ "$(grep -c '' "$TK")" = 2 ] \
  && ok || bad "P4: round trip, tick 2 reads tick 1's stored line: $(pp Acme/a)"

# ---- P5: the page ---------------------------------------------------------------
fresh; seed7; drive
[ "$(beats Acme/a)" = 1 ] && grep -q 'CRITICAL \[ci-minutes-watch\] ci-minutes:per-pr:Acme/a' "$HH/logs/ALERTS.log" \
  && ok || bad "P5: 443 > 400 with 70 merged -> one critical page: $(cat "$HH/beats.txt" 2>/dev/null)"
B=$(grep 'ci-minutes:per-pr:Acme/a' "$HH/beats.txt" | head -1)
[ "$(jq -r .severity <<<"$B")" = critical ] && [ "$(jq -r .triaged <<<"$B")" = true ] && [ "$(jq -r .project <<<"$B")" = a ] \
  && ok || bad "P5: a triaged critical beat on the repo's project: $B"
drive NOW=$(( NOW + 6 * 3600 ))
[ "$(beats Acme/a)" = 1 ] && ok || bad "P5: one page a day per repo, not one a tick ($(beats Acme/a))"
# Acme/b: 1 merged now + 3 stored = 4 merged at 1000 min/PR -> no page; 5 -> page
b_pulls 1
fresh; tick "$D" 3400 3 false Acme/b; drive
grep -q 'min_per_merged_pr_7d=1000 merged_prs_7d=4 ' <<<"$(pp Acme/b)" && [ "$(beats Acme/b)" = 0 ] \
  && ok || bad "P5: 4 merged PRs in 7 days never pages: $(pp Acme/b)"
fresh; tick "$D" 4400 4 false Acme/b; drive
grep -q 'min_per_merged_pr_7d=1000 merged_prs_7d=5 ' <<<"$(pp Acme/b)" && [ "$(beats Acme/b)" = 1 ] \
  && ok || bad "P5: 5 merged PRs at 1000 pages once: $(pp Acme/b)"
b_pulls 0
# strict line: exactly 400 does not page, 401 does
fresh; drive
grep -q 'min_per_merged_pr_7d=400 ' <<<"$(pp Acme/a)" && [ "$(beats Acme/a)" = 0 ] && ok || bad "P5: exactly the line (400) never pages"
fresh; tick "$D" 4020 10; drive
grep -q 'min_per_merged_pr_7d=401 ' <<<"$(pp Acme/a)" && [ "$(beats Acme/a)" = 1 ] && ok || bad "P5: 401 pages: $(pp Acme/a)"
# line 0 = off
fresh; seed7; drive CI_MINUTES_PER_PR_MAX=0
[ "$(beats Acme/a)" = 0 ] && ok || bad "P5: CI_MINUTES_PER_PR_MAX=0 turns the page off"

# ---- P7: the per-project row ---------------------------------------------------
b_pulls 1
fresh; seed7; tick "$D" 1150 4 false Acme/b
ROWS="lane.ci-minutes-watch.a.ci_minutes_per_pr_max=500 lane.ci-minutes-watch.b.ci_minutes_per_pr_max=300 lane.ci-minutes-watch.ci_minutes_per_pr_max=1000" drive
grep -q 'min_per_merged_pr_7d=443 .* line=500' <<<"$(pp Acme/a)" && [ "$(beats Acme/a)" = 0 ] \
  && ok || bad "P7: project a's row 500 lifts the line over 443 (lane row 1000 loses): $(pp Acme/a)"
grep -q 'min_per_merged_pr_7d=350 merged_prs_7d=5 .* line=300' <<<"$(pp Acme/b)" && [ "$(beats Acme/b)" = 1 ] \
  && ok || bad "P7: project b's row 300 under 350 pages: $(pp Acme/b)"
b_pulls 0

# ---- P8: the reads and the floor -------------------------------------------------
fresh; drive
# a: 1 page + 10 samples + 1 pulls; b: 1 page + 5 samples + 1 pulls
[ "$(grep -c '' "$HH/gh-calls.txt")" = 19 ] && [ "$(grep -c '/pulls ' "$HH/gh-calls.txt")" = 2 ] && [ ! -s "$HH/unknown.txt" ] \
  && ok || bad "P8: exactly pages + sample + 1 pulls per readable repo, no other path: $(cat "$HH/gh-calls.txt")"
grep -q '19 GitHub read(s)' "$LOG" && ok || bad "P8: the fleet line counts the pulls reads"
cp "$HH/fx/Acme_a.pulls.json" "$T/a.pulls"
fillpr() { # fillpr <updated-ago-s of the 100th item>
  local i
  for (( i = 1; i <= 99; i++ )); do pr "ticket/f$i" Acme/a - $(( 600 + i )); done
  pr ticket/f100 Acme/a - "$1" "$1"
  pulls Acme_a
}
fillpr 7200   # 0 merged today: (6 x 4500 + 4000) / 60 = 517, over the line
fresh; seed7; drive
L=$(pp Acme/a)
grep -q 'pr list floor' <<<"$L" && [ "$(rj Acme/a .pr_floor)" = true ] && [ "$(beats Acme/a)" = 0 ] \
  && grep -q 'ci-per-pr repo=Acme/a .*over the line but not paged: closed-PR list is a floor on 1 day(s)' "$LOG" \
  && ok || bad "P8: a 100-item page cut inside the window is a floor and never pages: $L"
fillpr $(( 2 * D ))
fresh; drive
grep -q 'pr list floor' <<<"$(pp Acme/a)" && bad "P8: a 100-item page whose last item is 2 days old is complete" || ok
cp "$T/a.pulls" "$HH/fx/Acme_a.pulls.json"

# ---- P9: dry run -----------------------------------------------------------------
fresh; seed7; cp "$TK" "$T/tk.before"; drive --dry-run
grep -q 'ci-per-pr repo=Acme/a merged_prs_24h=10' "$T/out.txt" && cmp -s "$TK" "$T/tk.before" \
  && ! grep -q 'ci-ticks-retention' "$LOG" && [ "$(beats Acme/a)" = 0 ] \
  && ok || bad "P9: --dry-run prints the line, stores no tick, prunes nothing, pages nothing"

# ---- P12: retention ---------------------------------------------------------------
seedret() { : > "$TK"; tick $(( 40 * D )) 1 1; tick $(( 36 * D )) 1 1; tick $(( 34 * D )) 1 1; tick "$D" 1 1; cp "$TK" "$T/tk.seed"; }
fresh; seedret; drive
R=$(grep 'ci-ticks-retention' "$LOG")
[ "$(grep -c 'ci-ticks-retention' "$LOG")" = 1 ] && grep -q 'mode=dry-run window_days=35 ticks=5 drop=2 oldest=' <<<"$R" \
  && cmp -s <(head -4 "$TK") "$T/tk.seed" && [ "$(grep -c '' "$TK")" = 5 ] \
  && ok || bad "P12: default is a dry run: one audit line, the file unchanged but for the new tick: $R"
fresh; seedret; drive CI_MINUTES_TICKS_RETENTION_APPLY=1
R=$(grep 'ci-ticks-retention' "$LOG")
[ "$(grep -c 'ci-ticks-retention' "$LOG")" = 1 ] && grep -q 'mode=apply window_days=35 ticks=5 drop=2' <<<"$R" \
  && cmp -s <(head -2 "$TK") <(sed -n 3,4p "$T/tk.seed") && [ "$(grep -c '' "$TK")" = 3 ] \
  && ok || bad "P12: apply keeps the 3 newer lines byte for byte: $R / $(cat "$TK")"
fresh; seedret; drive CI_MINUTES_TICKS_KEEP_DAYS=3 CI_MINUTES_PER_PR_DAYS=7
grep -q 'ci-ticks-retention mode=dry-run window_days=8 ' "$LOG" && ok || bad "P12: the window is never under the reader's (7 + 1): $(grep ci-ticks-retention "$LOG")"

echo "ci-minutes-per-pr.bh-9411: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ]
