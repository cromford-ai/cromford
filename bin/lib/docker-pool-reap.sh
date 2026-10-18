# shellcheck shell=bash
# bin/lib/docker-pool-reap.sh — the host-side reap of a docker-pool build
# (BH-7348, BH-7300 slice C2). A docker host keeps its disk after the container
# exits, so the host runner reaps the build dir itself and the hub READS the
# outcome from the jobs worker (POST /api/docker-pool/result). Contract:
# docs/notes/2026-10-17-BH-7348-docker-pool-results.md.
#
#   docker_pool_cost_box <project> <tag>
#       prints pool-<project>-<tag>, the tag cut to [A-Za-z0-9._-]. This is
#       fly/entrypoint.sh's POOL_MODE identity with FLY_MACHINE_ID=<tag>, so the
#       host reap and the container's own pushes write ONE box id and the
#       (box, row_hash) PK makes the overlap a dup, never a double count.
#
#   docker_pool_reap <project> <key> <build-dir> <cost-box> [auth_account]
#       run once after the container exits.
#       1. Cost rows FIRST: bin/cost-rows-push.sh --box <cost-box> --csv
#          <build-dir>/cost.csv --cursor <build-dir>/.cost-rows.cursor, then
#          --verify <cost-box> with the same csv and cursor. cost_verified is 1
#          only on a verify rc 0. cost_rows and unpriced_rows (an empty
#          cost_usd) are counted from the csv by header name.
#       2. The result: line 1 of <build-dir>/RESULT, the PR url, the TIER line
#          and job.json's job_id. No RESULT: rc 1, nothing posted.
#       3. The account: the argument, else the csv's last auth_account, else
#          unknown.
#       4. POST /api/docker-pool/result as box $JOBS_BOX.
#       rc 0 prints one TSV line: cost_rows unpriced_rows cost_verified claimed_at.
#       rc 9 = the worker refused (no_lease, superseded, already_reaped); the
#       reason goes to stderr. rc 1 = anything else. Neither prints the TSV.
#
# Needs _jobs_req (bin/jobs-client.sh) from the caller; sources
# bin/lib/docker-pool.sh for _dp_call when the caller has not. The harness root
# is ${HARNESS:-${H:-}}; with none, docker_pool_reap is rc 1. Defines functions
# only. Nothing runs on source.

# shellcheck source=bin/lib/docker-pool.sh
declare -F _dp_call >/dev/null 2>&1 || . "${BASH_SOURCE[0]%/*}/docker-pool.sh" 2>/dev/null || true

docker_pool_cost_box() {
  local p="${1:-}" tag
  tag=$(printf '%s' "${2:-}" | tr -cd 'A-Za-z0-9._-')
  [ -n "$p" ] && [ -n "$tag" ] || return 1
  printf 'pool-%s-%s\n' "$p" "$tag"
}

# _dpr_csv_counts <csv> — prints `<rows> <unpriced> <last auth_account or ->`.
_dpr_csv_counts() {
  awk -F, 'NR==1 { for (i = 1; i <= NF; i++) { if ($i == "cost_usd") c = i; if ($i == "auth_account") a = i }; next }
    $0 == "" { next }
    { n++; if (c && $c == "") u++; if (a && $a != "") acct = $a }
    END { printf "%d %d %s\n", n, u, (acct == "" ? "-" : acct) }' "$1"
}

docker_pool_reap() {
  local p="${1:-}" k="${2:-}" d="${3:-}" cb="${4:-}" acct="${5:-}" root="${HARNESS:-${H:-}}"
  local csv cur n=0 u=0 v=0 last="-" res pr="" tier="" job="" body out rc line
  [ -n "$p" ] && [ -n "$k" ] && [ -d "$d" ] && [ -n "$cb" ] && [ -n "$root" ] || return 1
  csv="$d/cost.csv"; cur="$d/.cost-rows.cursor"
  if [ -s "$csv" ]; then
    read -r n u last < <(_dpr_csv_counts "$csv")
    if [ "${n:-0}" -gt 0 ] && [ -x "$root/bin/cost-rows-push.sh" ]; then
      timeout "${COST_ROWS_REAP_TIMEOUT_S:-120}" "$root/bin/cost-rows-push.sh" --box "$cb" --csv "$csv" --cursor "$cur" >/dev/null 2>&1
      timeout "${COST_ROWS_REAP_TIMEOUT_S:-120}" "$root/bin/cost-rows-push.sh" --verify "$cb" --csv "$csv" --cursor "$cur" >/dev/null 2>&1 && v=1
    fi
  fi
  [ -s "$d/RESULT" ] || return 1
  res=$(head -n 1 "$d/RESULT" | tr -d '\r')
  [ -n "$res" ] || return 1
  # shellcheck source=bin/lib/result-pr-url.sh
  if [ -r "$root/bin/lib/result-pr-url.sh" ] && . "$root/bin/lib/result-pr-url.sh" 2>/dev/null; then
    pr=$(result_own_pr_url "$d/RESULT" 2>/dev/null) || pr=""
  else
    pr=$(grep -oE 'https://github\.com/[^ /]+/[^ /]+/pull/[0-9]+' "$d/RESULT" | head -n 1)
  fi
  tier=$(grep -oE '^TIER: [12]' "$d/RESULT" | grep -oE '[12]' | head -n 1)
  [ -s "$d/job.json" ] && job=$(jq -r '.job_id // empty' "$d/job.json" 2>/dev/null)
  if [ -z "$acct" ] && [ "$last" != - ]; then acct="$last"; fi
  [ -n "$acct" ] || acct=unknown
  body=$(_dp_body "$p" "$k") || return 1
  body=$(jq -c --arg r "$res" --arg cb "$cb" --argjson n "$n" --argjson u "$u" --argjson v "$v" \
    --arg j "$job" --arg pr "$pr" --arg t "$tier" --arg a "$acct" \
    '. + {result:$r, cost_box:$cb, cost_rows:$n, unpriced_rows:$u, cost_verified:$v, auth_account:$a}
       + (if $j == "" then {} else {job_id:$j} end) + (if $pr == "" then {} else {pr_url:$pr} end)
       + (if $t == "" then {} else {tier:($t | tonumber)} end)' <<<"$body") || return 1
  out=$(_dp_call result "$body"); rc=$?
  [ "$rc" = 0 ] || { [ "$rc" = 9 ] && return 9; return 1; }
  line=$(jq -r --argjson n "$n" --argjson u "$u" --argjson v "$v" \
    'select(.recorded == true and (.claimed_at // "") != "") | [$n, $u, $v, .claimed_at] | @tsv' <<<"$out" 2>/dev/null)
  [ -n "$line" ] || return 1
  printf '%s\n' "$line"
}
