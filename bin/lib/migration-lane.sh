#!/bin/bash
# shellcheck shell=bash
# bin/lib/migration-lane.sh — the logic of the hub migration lane (BH-8704).
# Sourced by bin/migration-lane.sh, never executed. No `exit`, no side effect
# at source time. Contract: docs/notes/2026-10-28-BH-8704-migration-lane.md.
#
# ONE TICK, ONE PROJECT (ml_tick). The caller holds the project lease and sets:
#   H          the harness root             P        the project
#   SLUG       owner/repo                   REPO     the lane's own bare clone
#   ML_HOLDER  the lease holder             ML_FENCE the lease fence
# and the knobs (bin/migration-lane.sh lane_env_apply, registry
# catalog/lanes.d/migration.json, rows lane.migration[.<project>].<knob>):
#   BATCH_MAX 6, CI_TIMEOUT_S 3600, CI_POLL_S 60, LEASE_TTL_S 900,
#   SETUP_TIMEOUT_S 900, APPLY_TIMEOUT_S 1800 (the code fallbacks below).
# and from env/<project>.env (never a settings row):
#   MIGRATION_LANE_APPLY_CMD, MIGRATION_LANE_SETUP_CMD (optional),
#   MIGRATION_LANE_DATABASE_URL, DATA_LANE_APP_BASE, MIGRATION_TOKEN.
#
# Steps: select (ml_select) -> batch branch + one draft PR (ml_build_batch) ->
# one CI (ml_wait_ci) -> re-check + apply through the project's own ledger CLI
# (ml_apply) -> one sha-bound merge per fully applied member (ml_merge_members).
#
# Records: logs/migration-lane.log (`#N applied <file>`, `#N merged <sha>`,
# `#N dropped: <why>`, `#N skipped: <why>`, `batch <id> <status>`, and from the
# row-count judge `#N empty: <file> statement <k> (<COMMAND>, line <L>) changed
# 0 rows`, `#N may-be-empty: <file> statement <k> (<reason>)`, `#N <file>: ...
# row counts not checked`), and the jobs ledger kind migration-lane: key
# `batch <project>` (status ci|applying|merging|done|red|timeout|failed|lost,
# detail JSON) and key `pr <project>#<n>` (status
# solo|red|concurrent|changed|empty|held, detail `<head> <why>`).
#
# ROW COUNTS (BH-8914). After migrations/status proves a member file applied,
# ml_judge_rows reads the apply CLI's `migration-rows:` report lines for it
# (bin/lib/migration-rowcount.py). A data statement that changed 0 rows with
# no `-- may-be-empty: <reason>` marker holds the member (ledger `empty
# <head>`, one PR comment); a file with no report line is proved as before.
# A report that does not match the file (unaligned) or a judge that fails
# holds the member too (ledger `held <head>`, no comment): the next tick's
# apply CLI skips the file production already holds, so without the row the
# judge would read it as unreported and merge it (lead review lr-9192).
#
# SEAMS. Every call to GitHub, the verdict readers, the app status endpoint,
# the alert path and the clock's sleep goes through one mlx_* function below.
# The block defines them only when no mlx_pr_list exists yet, so a fixture
# that defines its own set before this file loads keeps it. Git, the jobs
# ledger, the settings rows and the project lease are never seams.

ML_KIND=migration-lane
# A correctness bound, not a knob: _gh_rest_list (bin/lib/gh-rest-list.sh)
# stops at page 10 with per_page=100, so it never returns more than 1000 rows.
# A list that reaches this count may be cut, so it is read as incomplete (no
# batch from a partial board). Change both together.
ML_PR_LIST_CAP=1000

if ! declare -F mlx_pr_list >/dev/null 2>&1; then
  # mlx_pr_list <slug> <out> — every open PR on base main, as a JSON array of
  # {n, head, draft}. rc 0 only for a complete list (_gh_rest_list pages to
  # the end; ML_PR_LIST_CAP rows is its hard stop and is read as incomplete).
  mlx_pr_list() {
    local rc=0
    command -v _gh_rest_list >/dev/null 2>&1 || return 75
    _gh_rest_list "$1" pulls "$ML_PR_LIST_CAP" '{n: .number, head: .head.sha, draft: (.draft // false)}' \
      -f state=open -f base=main > "$2" || rc=$?
    [ "$rc" = 0 ] || return "$rc"
    [ "$(jq 'length' "$2" 2>/dev/null)" -lt "$ML_PR_LIST_CAP" ] 2>/dev/null || return 76
  }
  # mlx_pr_files <slug> <n> <out> — the PR's added paths (mmh_files).
  mlx_pr_files() { mmh_files "$1" "$2" "$3"; }
  # mlx_pr_head <slug> <n> — prints "<state> <head>" (open|closed, full sha).
  # gh_rest runs as a plain command into a file, never inside $( ): its
  # GH_REST_STATUS stays in this shell (tests/gh-rest-no-subshell-lint.sh).
  mlx_pr_head() {
    local t rc=0
    t=$(mktemp "${TMPDIR:-/tmp}/ml-pr-head.XXXXXX") || return 75
    gh_rest GET "repos/$1/pulls/$2" > "$t" || rc=$?
    if [ "$rc" = 0 ]; then jq -r '"\(.state // "") \(.head.sha // "")"' < "$t" 2>/dev/null || rc=$?; else rc=75; fi
    rm -f "$t"
    return "$rc"
  }
  mlx_ci_state() { mc_ci_state "$1" "$2"; }
  mlx_lead_clears() { vd_clears "$1" "$2" "$3"; }
  mlx_box_word() { vd_box_word "$1" "$2" "$3"; }
  mlx_block_scan() { bg_scan "$1" "$2" "https://github.com/$1/pull/$2" "$3" ""; }
  mlx_cr_standing() { bg_cr_standing "$1" "$2" "https://github.com/$1/pull/$2" "$3" ""; }
  # mlx_git_remote <slug> — sets ML_REMOTE, the fetch/push URL for the token
  # mc_git_auth chose. A plain call, never $( ): GIT_ASKPASS is exported here.
  # shellcheck disable=SC2034 # ML_REMOTE is read by bin/migration-lane.sh
  mlx_git_remote() { mc_git_auth "$1" >/dev/null 2>&1 || return 1; ML_REMOTE="$MC_REMOTE"; }
  # mlx_pr_create <slug> <branch> <title> <bodyfile> — prints the new PR number.
  mlx_pr_create() {
    local t rc=0
    t=$(mktemp "${TMPDIR:-/tmp}/ml-pr-create.XXXXXX") || return 75
    gh_rest POST "repos/$1/pulls" -f "title=$3" -f "head=$2" -f base=main -F draft=true -F "body=@$4" > "$t" || rc=$?   # pr-trailers: ml_build_batch applied the block to <bodyfile> before this call
    if [ "$rc" = 0 ]; then jq -r '.number // empty' < "$t" 2>/dev/null || rc=$?; else rc=75; fi
    rm -f "$t"
    return "$rc"
  }
  mlx_pr_close() { gh_rest_close "$1" "$2" pulls; }
  mlx_comment() { gh_rest_comment "$1" "$2" "$3"; }
  # mlx_merge <slug> <n> <sha> — rc 0 prints the merge sha; any other rc is a refusal.
  mlx_merge() { gh_pr_merge_rest "$1" "$2" "$3" /dev/null "$H/logs/migration-lane.log" "migration-lane $P#$2" 0; }
  # mlx_status_get <out> — GET <DATA_LANE_APP_BASE>/api/internal/migrations/status.
  # The token rides a 0600 header file, never argv. rc 0 = a JSON applied list.
  mlx_status_get() {
    local t code
    [ -n "${DATA_LANE_APP_BASE:-}" ] && [ -n "${MIGRATION_TOKEN:-}" ] || return 1
    t=$(mktemp -d "${TMPDIR:-/tmp}/ml-status.XXXXXX") || return 1
    ( umask 077; printf 'Authorization: Bearer %s\n' "$MIGRATION_TOKEN" > "$t/auth" )
    # The probe bound is the conductor's own row mc_migration_hold.probe_timeout_s (1..60, fallback 15).
    code=$(curl -sS -m "$(_mmh_int mc_migration_hold.probe_timeout_s "$MMH_TIMEOUT_DEFAULT" 1 60)" -H @"$t/auth" -o "$1" -w '%{http_code}' \
      "${DATA_LANE_APP_BASE%/}/api/internal/migrations/status" 2>/dev/null) || code=000
    rm -rf "$t"
    case "$code" in 2??) ;; *) return 1 ;; esac
    jq -e 'type == "object" and (.applied | type == "array")' "$1" >/dev/null 2>&1
  }
  # mlx_alert <warn|critical> <id> <text>
  mlx_alert() {
    local sev="$1" id="$2"; shift 2
    "$H/bin/lane-alert.sh" --severity "$sev" --id "$id" migration-lane "$*" >/dev/null 2>&1 || true
  }
  mlx_sleep() { sleep "$1"; }
fi

# The project's commands get none of the lane's own credentials.
ML_SCRUB=(env -u GH_TOKEN -u GITHUB_TOKEN -u MC_GIT_TOKEN -u GIT_ASKPASS -u HARNESS_SECRET -u MIGRATION_TOKEN)

# ml_h_ok — rc 0 when the harness root is set. With H empty every path below
# would become /logs/... and /state/..., so the lane refuses instead.
ml_h_ok() {
  H="${HARNESS:-${H:-}}"
  [ -n "$H" ] && return 0
  echo "migration-lane: HARNESS and H are empty; refusing to run" >&2
  return 1
}
ml_log() { [ -n "${H:-}" ] || return 0; printf '%s [%s] %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "${P:-?}" "$*" >> "$H/logs/migration-lane.log"; }
ml_flat() { printf '%s' "$*" | tr '\t\r\n' '   ' | cut -c1-300; }
ml_sha256() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# ml_pr_row <n> — prints "<status> <head>" of the ledger row `pr <p>#<n>`, or nothing.
ml_pr_row() {
  local row
  row=$(job_ledger_row "$ML_KIND" "pr $P#$1" 2>/dev/null) || return 0
  jq -r '"\(.status) \((.detail // "") | split(" ")[0])"' <<<"$row" 2>/dev/null
}
ml_pr_put() { job_ledger_put "$ML_KIND" "pr $P#$1" "$2" "$3 $(ml_flat "${4:-}")" >/dev/null 2>&1 || ml_log "#$1 ledger write ($2) failed"; }
ml_batch_put() { job_ledger_put "$ML_KIND" "batch $P" "$1" "$2" >/dev/null 2>&1 || ml_log "batch ledger write ($1) failed"; }

# ml_renew — rc 0 while this tick still holds the lease.
ml_renew() {
  local rc=0
  PJL_TTL_S="${LEASE_TTL_S:-900}" pjl_renew migration "$P" "$ML_HOLDER" "$ML_FENCE" >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ]
}

# ml_concurrent_file <file> — rc 0 when the SQL needs a concurrent index: a
# first line `-- mk:concurrent-index`, or CONCURRENTLY (any case) outside a
# `--` comment.
ml_concurrent_file() {
  head -1 "$1" 2>/dev/null | grep -q '^-- *mk:concurrent-index' && return 0
  sed 's/--.*$//' "$1" 2>/dev/null | grep -qi 'concurrently'
}

# ml_gate_status_has <basename> <sha256> — what production holds for one file,
# from ONE migrations/status read per tick (cached in $ML_TMP): prints
# applied|changed|pending, or `unread` when the endpoint did not answer.
ml_gate_status_has() {
  local st="$ML_TMP/gate-status.json"
  [ -e "$ML_TMP/gate-status.fail" ] && { echo unread; return 0; }
  if [ ! -s "$st" ]; then
    mlx_status_get "$st" || { rm -f "$st"; : > "$ML_TMP/gate-status.fail"; echo unread; return 0; }
  fi
  ml_status_has "$st" "$1" "$2"
}

# ml_main_concurrent_ok — rc 0 unless main holds a concurrent-index file that
# production has not applied. Such a file (merged by hand before the operator
# step) would run inside the next batch apply, because the apply command runs
# every pending file of main plus the batch. No batch until the operator
# applies it; one warn alert, deduped by its id.
ml_main_concurrent_ok() {
  local f g pend="" st
  local -a globs
  mapfile -t globs < <(mmh_globs "$P")
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    for g in "${globs[@]}"; do
      mmh_glob_match "$g" "$f" || continue
      git -C "$REPO" show "refs/remotes/origin/main:$f" > "$ML_TMP/main-sql" 2>/dev/null || break
      ml_concurrent_file "$ML_TMP/main-sql" || break
      st=$(ml_gate_status_has "${f##*/}" "$(ml_sha256 "$ML_TMP/main-sql")")
      case "$st" in
        pending) pend="${pend:+$pend }$f" ;;
        unread) pend="${pend:+$pend }$f (migrations/status unreadable)" ;;
      esac
      break
    done
  done < <(git -C "$REPO" grep -il concurrent refs/remotes/origin/main -- 2>/dev/null | sed 's|^refs/remotes/origin/main:||')
  [ -z "$pend" ] && return 0
  ml_log "main holds $pend: a concurrent index production has not applied; no batch until the operator applies it"
  mlx_alert warn "migration-lane-$P-main-concurrent" "$P: main holds $pend, a concurrent index that production has not applied; the migration lane forms no batch until the operator applies it (runbook npm run db:apply)"
  return 1
}

# ml_gate_pr <slug> <n> <head> <files-file> — the per-PR gates on the CURRENT
# head, cheapest first. rc 0 = eligible; otherwise ML_WHY names the first
# failure. <files-file> holds the PR's migration paths.
ml_gate_pr() {
  local slug="$1" n="$2" head="$3" files="$4" ci rc w row st detail vh f tmp hit="" pend="" fst
  ML_WHY=""
  ci=$(mlx_ci_state "$slug" "$head")
  [ "$ci" = green ] || { ML_WHY="ci $ci"; return 1; }
  mlx_lead_clears "$slug" "$n" "$head" || { ML_WHY="no lead or human MERGE standing on ${head:0:8}"; return 1; }
  rc=0; w=$(mlx_box_word "$slug" "$n" "$head") || rc=$?
  [ "$rc" = 2 ] && { ML_WHY="box verdict unreadable"; return 1; }
  [ "$rc" = 0 ] && [ "$w" = BLOCK ] && { ML_WHY="box BLOCK on ${head:0:8}"; return 1; }
  rc=0; w=$(mlx_block_scan "$slug" "$n" "$head") || rc=$?
  if [ "$rc" != 0 ] || [ -n "$w" ]; then
    if [ "$rc" = 1 ]; then ML_WHY="human or lead BLOCK ($(ml_flat "$(cut -f1 <<<"$w")"))"; else ML_WHY="block gate cannot judge (rc $rc)"; fi
    return 1
  fi
  rc=0; mlx_cr_standing "$slug" "$n" "$head" >/dev/null || rc=$?
  case "$rc" in
    1) ;;
    0) ML_WHY="CHANGES_REQUESTED standing"; return 1 ;;
    *) ML_WHY="reviews unreadable (rc $rc)"; return 1 ;;
  esac
  # Fail closed: the lane lands only a head the conductor scanned clean.
  row=$(job_ledger_row mc-merge-verdict "$slug#$n" 2>/dev/null) || row=""
  st=$(jq -r '.status // ""' <<<"${row:-{\}}" 2>/dev/null)
  detail=$(jq -r '.detail // ""' <<<"${row:-{\}}" 2>/dev/null)
  vh="${detail%% *}"
  if [ "$st" != clear ] || [ "${#vh}" -lt 7 ] || [ "${head#"$vh"}" = "$head" ]; then
    ML_WHY="no conductor clear verdict on ${head:0:8}${st:+ (row: $st ${vh:0:8})}"; return 1
  fi
  # A concurrent index is never run by the lane. The operator applies it by
  # hand; the PR then passes this gate on the first tick where production
  # lists every such file applied with the checksum of this head, and rides a
  # batch like any other member (the apply command skips an applied file, and
  # ml_apply proves it before the merge). That is what the comment promises.
  tmp=$(mktemp "${TMPDIR:-/tmp}/ml-sql.XXXXXX") || { ML_WHY="no temp file"; return 1; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    git -C "$REPO" show "$head:$f" > "$tmp" 2>/dev/null || { rm -f "$tmp"; ML_WHY="cannot read $f at ${head:0:8}"; return 1; }
    ml_concurrent_file "$tmp" || continue
    hit="${hit:+$hit }$f"
    fst=$(ml_gate_status_has "${f##*/}" "$(ml_sha256 "$tmp")")
    [ "$fst" = applied ] || pend="${pend:+$pend }$f ($fst)"
  done < "$files"
  rm -f "$tmp"
  if [ -n "$pend" ]; then
    ML_WHY="concurrent index in $pend, not applied in production with this head's checksum"
    row=$(ml_pr_row "$n")
    if [ "$row" != "concurrent $head" ]; then
      ml_pr_put "$n" concurrent "$head" "$hit"
      tmp=$(mktemp "${TMPDIR:-/tmp}/ml-body.XXXXXX") && {
        printf 'The migration lane will not apply this PR: %s builds an index CONCURRENTLY, which cannot run inside the batch apply.\n\nOperator step: apply it by hand from the runbook (`npm run db:apply` against production, from this head `%s`). Then the lane merges this PR on its next tick, when the app'"'"'s `migrations/status` lists each of these files applied with the checksum at this head and the other gates (CI, a MERGE verdict, no BLOCK) still pass. The merge goes through one batch CI run and is bound to this head. A new push needs the operator step again only if a concurrent file changes.\n' "$hit" "${head:0:12}" > "$tmp"
        mlx_comment "$slug" "$n" "$tmp" || ml_log "#$n concurrent-index comment failed"
        rm -f "$tmp"; }
      mlx_alert warn "migration-lane-$P-$n-concurrent" "$P #$n needs the operator step: $hit builds an index CONCURRENTLY; the lane does not run it (apply by hand, runbook npm run db:apply); the lane merges the PR once migrations/status shows it applied"
    fi
    return 1
  fi
  [ -n "$hit" ] && ml_log "#$n concurrent index in $hit is applied in production at this head's checksum; it rides the batch"
  row=$(ml_pr_row "$n")
  case "$row" in
    "red $head") ML_WHY="its solo batch was red on ${head:0:8}; waits for a new head"; return 1 ;;
    "changed $head") ML_WHY="a file changed since staging on ${head:0:8}; waits for a new head"; return 1 ;;
    "empty $head") ML_WHY="a data statement changed 0 rows on ${head:0:8}; waits for a new head"; return 1 ;;
    "held $head") ML_WHY="row counts could not be checked on ${head:0:8}; waits for a new head"; return 1 ;;
  esac
  return 0
}

# ml_fetch_heads <n>... — fetch main and each PR head into the checkout.
ml_fetch_heads() {
  local n refs=("+refs/heads/main:refs/remotes/origin/main")
  for n in "$@"; do refs+=("+refs/pull/$n/head:refs/remotes/origin/ml-pr/$n"); done
  git -C "$REPO" -c credential.helper= fetch -q origin "${refs[@]}" >/dev/null 2>&1
}

# ml_select — the eligible PRs in batch order into $ML_TMP/cand.tsv:
# "<first migration name>\t<n>\t<head>\t<path path ...>". rc 1 = no batch this
# tick (an incomplete list or a failed read), already logged.
ml_select() {
  local list="$ML_TMP/prs.json" files n head draft f g names first rc
  local -a globs
  : > "$ML_TMP/cand.tsv"
  rc=0; mlx_pr_list "$SLUG" "$list" || rc=$?
  [ "$rc" = 0 ] || { ml_log "incomplete PR list (rc $rc), no batch"; return 1; }
  mapfile -t globs < <(mmh_globs "$P")
  [ "${#globs[@]}" -gt 0 ] || { ml_log "no valid globs row, no batch"; return 1; }
  while IFS=$'\t' read -r n head draft; do
    [ -n "$n" ] || continue
    [ "$draft" = true ] && continue
    files="$ML_TMP/files-$n"; : > "$files.m"
    rc=0; mlx_pr_files "$SLUG" "$n" "$files" || rc=$?
    [ "$rc" = 0 ] || { ml_log "#$n skipped: files unreadable (rc $rc)"; continue; }
    names=""; first=""
    while IFS= read -r f; do
      for g in "${globs[@]}"; do
        if mmh_glob_match "$g" "$f"; then
          printf '%s\n' "$f" >> "$files.m"
          names="${names:+$names }$(mmh_name "$f")"
          break
        fi
      done
    done < "$files"
    [ -s "$files.m" ] || continue
    first=$(tr ' ' '\n' <<<"$names" | LC_ALL=C sort | head -1)
    printf '%s\t%s\t%s\t%s\n' "$first" "$n" "$head" "$(LC_ALL=C sort "$files.m" | tr '\n' ' ' | sed 's/ $//')" >> "$ML_TMP/all.tsv"
  done < <(jq -r '.[] | "\(.n)\t\(.head)\t\(.draft)"' "$list" 2>/dev/null)
  [ -s "$ML_TMP/all.tsv" ] || { ml_log "no migration PR open"; return 1; }
  # shellcheck disable=SC2046 # PR numbers are digits
  ml_fetch_heads $(cut -f2 "$ML_TMP/all.tsv") || { ml_log "fetch of main and the PR heads failed, no batch"; return 1; }
  ml_main_concurrent_ok || return 1
  while IFS=$'\t' read -r first n head f; do
    tr ' ' '\n' <<<"$f" > "$ML_TMP/files-$n.m"
    if ml_gate_pr "$SLUG" "$n" "$head" "$ML_TMP/files-$n.m"; then
      printf '%s\t%s\t%s\t%s\n' "$first" "$n" "$head" "$f" >> "$ML_TMP/cand.tsv"
    else
      ml_log "#$n skipped: $ML_WHY"
    fi
  done < <(LC_ALL=C sort -t$'\t' -k1,1 -k2,2n "$ML_TMP/all.tsv")
  [ -s "$ML_TMP/cand.tsv" ] || { ml_log "0 eligible migration PRs"; return 1; }
  # A PR whose row says solo at this head goes alone: the first one, in order.
  while IFS=$'\t' read -r first n head f; do
    if [ "$(ml_pr_row "$n")" = "solo $head" ]; then
      printf '%s\t%s\t%s\t%s\n' "$first" "$n" "$head" "$f" > "$ML_TMP/cand.tsv"
      ml_log "#$n goes alone (its earlier batch was red)"
      return 0
    fi
  done < "$ML_TMP/cand.tsv"
  head -n "${BATCH_MAX:-6}" "$ML_TMP/cand.tsv" > "$ML_TMP/cand.cut" && mv -f "$ML_TMP/cand.cut" "$ML_TMP/cand.tsv"
  return 0
}

# ml_build_batch — a worktree from origin/main, each candidate merged in order;
# a conflicting one is dropped. Pushes the branch and opens the draft PR. Sets
# ML_ID ML_BRANCH ML_WT ML_BPR ML_BHEAD, writes $ML_TMP/members.tsv
# ("<n>\t<head>\t<path path ...>") and the ledger row `batch <p>` = ci.
ml_build_batch() {
  local first n head f p list="" dropped="[]" members="[]" bf files
  ML_ID="$(date -u +%Y%m%dT%H%M%SZ)-$BASHPID"
  ML_BRANCH="migration-lane/$P/$ML_ID"
  ML_WT="$H/state/migration-lane/$P/wt-$ML_ID"
  ML_BPR=""; ML_BHEAD=""
  : > "$ML_TMP/members.tsv"
  mkdir -p "$(dirname "$ML_WT")"
  git -C "$REPO" worktree add -q --detach "$ML_WT" refs/remotes/origin/main >/dev/null 2>&1 \
    || { ml_log "batch worktree could not be created, no batch"; return 1; }
  git -C "$ML_WT" config user.name "harness migration lane"
  git -C "$ML_WT" config user.email "migration-lane@harness.invalid"
  while IFS=$'\t' read -r first n head f; do
    if git -C "$ML_WT" merge -q --no-ff --no-edit -m "migration batch $ML_ID: #$n" "$head" >/dev/null 2>&1; then
      printf '%s\t%s\t%s\n' "$n" "$head" "$f" >> "$ML_TMP/members.tsv"
    else
      git -C "$ML_WT" merge --abort >/dev/null 2>&1
      ml_log "#$n dropped: conflicts with main or an earlier member"
      dropped=$(jq -c --argjson n "$n" --arg h "$head" '. + [{n:$n, head:$h, why:"conflict"}]' <<<"$dropped")
    fi
  done < "$ML_TMP/cand.tsv"
  if [ ! -s "$ML_TMP/members.tsv" ]; then
    ml_log "0 members left after the conflict check, no batch"; ml_wt_remove; return 1
  fi
  while IFS=$'\t' read -r n head f; do
    list="$list #$n"
    files="[]"
    for p in $f; do
      git -C "$REPO" show "$head:$p" > "$ML_TMP/stage" 2>/dev/null || { ml_log "#$n: cannot read $p at ${head:0:8}, no batch"; ml_wt_remove; return 1; }
      files=$(jq -c --arg p "$p" --arg nm "$(mmh_name "$p")" --arg s "$(ml_sha256 "$ML_TMP/stage")" '. + [{path:$p, name:$nm, sha256:$s}]' <<<"$files")
    done
    members=$(jq -c --argjson n "$n" --arg h "$head" --argjson fs "$files" '. + [{n:$n, head:$h, files:$fs}]' <<<"$members")
  done < "$ML_TMP/members.tsv"
  ML_BHEAD=$(git -C "$ML_WT" rev-parse HEAD)
  ML_MEMBERS_JSON="$members"
  # The batch branch is new: hold_push with lease `new` refuses it when the
  # branch already exists on the remote. No ticket owns it (`none`).
  if ! HOLD_PUSH_LOG="$H/logs/migration-lane.log" hold_push -n "$P" none "$ML_WT" origin HEAD "$ML_BRANCH" new >/dev/null 2>&1; then
    ml_log "batch $ML_ID failed: the push was refused"; ml_wt_remove
    ml_batch_put failed "$(jq -nc --arg id "$ML_ID" --arg why push '{id:$id, why:$why}')"
    mlx_alert warn "migration-lane-$P-$ML_ID" "$P migration batch $ML_ID: the branch push was refused; nothing applied, nothing merged"
    return 1
  fi
  bf="$ML_TMP/batch-body.md"
  {
    printf 'Migration lane batch `%s` (BH-8704). This PR is a CI vehicle and a merge artifact. **Never merge it.** The lane closes it after the run.\n\n' "$ML_ID"
    # bin/pr-owner-sweep.sh reads this line as a park, so it never enrolls the vehicle.
    # The park ends when the lane's own bounds (CI wait, setup, apply) are spent.
    printf 'Parked: migration-lane CI vehicle, the lane closes it (expires %s)\n\n' \
      "$(date -u -d "@$(( $(date +%s) + ${CI_TIMEOUT_S:-3600} + ${SETUP_TIMEOUT_S:-900} + ${APPLY_TIMEOUT_S:-1800} ))" +%Y-%m-%d 2>/dev/null || date -u +%Y-%m-%d)"
    printf 'Members, in migration order:\n\n'
    while IFS=$'\t' read -r n head f; do printf -- '- #%s at `%s`: %s\n' "$n" "${head:0:12}" "$f"; done < "$ML_TMP/members.tsv"
  } > "$bf"
  # >>> pr trailers (BH-3987)
  # The migration lane opened this vehicle: `lane:migration` as the job, no one
  # ticket, and the branch with every member on the Harness-Train line. A
  # failed write is one log line and the batch PR opens untrailered.
  [ -r "${H:-}/bin/lib/pr-trailers.sh" ] && . "$H/bin/lib/pr-trailers.sh"
  if command -v pr_trailers_apply >/dev/null 2>&1; then
    pr_trailers_apply "$bf" lane:migration none "$ML_BRANCH$list" \
      || ml_log "batch $ML_ID: pr trailers: could not write the body file; the batch PR opens without trailers"
  fi
  # <<< pr trailers
  ML_BPR=$(mlx_pr_create "$SLUG" "$ML_BRANCH" "migration batch $ML_ID:$list" "$bf") || ML_BPR=""
  if ! [[ $ML_BPR =~ ^[0-9]+$ ]]; then
    ml_log "batch $ML_ID failed: the draft PR was not created"
    ml_branch_delete; ml_wt_remove
    ml_batch_put failed "$(jq -nc --arg id "$ML_ID" --arg why pr-create '{id:$id, why:$why}')"
    mlx_alert warn "migration-lane-$P-$ML_ID" "$P migration batch $ML_ID: the draft batch PR was not created; nothing applied, nothing merged"
    return 1
  fi
  ML_BATCH_JSON=$(jq -nc --arg id "$ML_ID" --arg b "$ML_BRANCH" --argjson pr "$ML_BPR" --arg h "$ML_BHEAD" \
    --argjson m "$members" --argjson d "$dropped" '{id:$id, branch:$b, pr:$pr, head:$h, members:$m, dropped:$d}')
  ml_batch_put ci "$ML_BATCH_JSON"
  ml_log "batch $ML_ID ci: #$ML_BPR at ${ML_BHEAD:0:12} with$list"
  return 0
}

ml_wt_remove() {
  [ -n "${ML_WT:-}" ] || return 0
  if ! git -C "$REPO" worktree remove --force "$ML_WT" >/dev/null 2>&1; then
    case "$ML_WT" in "$H"/state/migration-lane/*/wt-*) rm -rf "$ML_WT" ;; esac
  fi
  git -C "$REPO" worktree prune >/dev/null 2>&1
  return 0
}
ml_branch_delete() {
  git -C "$REPO" -c credential.helper= push -q origin --delete "$ML_BRANCH" >/dev/null 2>&1 \
    || ml_log "batch $ML_ID: branch $ML_BRANCH not deleted"
}
# ml_close_batch — close the batch PR and delete its branch.
ml_close_batch() {
  [ -n "${ML_BPR:-}" ] && { mlx_pr_close "$SLUG" "$ML_BPR" || ml_log "batch $ML_ID: PR #$ML_BPR not closed"; }
  ml_branch_delete
  ml_wt_remove
}

# ml_wait_ci — prints green|red|timeout|lost. Renews the lease before each
# poll; the waited time counts CI_POLL_S per poll.
ml_wait_ci() {
  local waited=0 st poll="${CI_POLL_S:-60}" max="${CI_TIMEOUT_S:-3600}"
  while :; do
    ml_renew || { echo lost; return 0; }
    st=$(mlx_ci_state "$SLUG" "$ML_BHEAD")
    case "$st" in
      green|red) echo "$st"; return 0 ;;
    esac
    [ "$waited" -ge "$max" ] && { echo timeout; return 0; }
    mlx_sleep "$poll"
    waited=$((waited + poll))
  done
}

# ml_run_renewing <timeout-s> <out> <cmd...> — run a command in the background
# under `timeout`, renewing the lease while it runs. rc = the command's rc. A
# refused renew writes $ML_TMP/lease-lost (a file, not a variable: the callers
# run this in a `( cd ... )` subshell). The command is let finish: killing a
# migration apply halfway is worse than a late merge.
ml_run_renewing() {
  local to="$1" out="$2" pid rc=0 step="${CI_POLL_S:-60}" ttl="${LEASE_TTL_S:-900}" i
  shift 2
  [ "$step" -gt $((ttl / 3)) ] && step=$((ttl / 3))
  [ "$step" -ge 1 ] || step=1
  ( umask 077; : > "$out" )
  timeout "$to" "$@" >> "$out" 2>&1 &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    for ((i = 0; i < step * 10; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
    kill -0 "$pid" 2>/dev/null || break
    ml_renew || : > "$ML_TMP/lease-lost"
  done
  wait "$pid" || rc=$?
  return "$rc"
}

# ml_status_has <status-file> <basename> <sha256> — prints applied|changed|pending.
ml_status_has() {
  jq -r --arg f "$2" --arg s "$3" '[.applied[]? | select(type == "object") | select((.filename // "" | split("/") | last) == $f)]
    | if length == 0 then "pending" elif any(.[]; (.checksum // "") == $s) then "applied" else "changed" end' "$1" 2>/dev/null
}

# ml_main_pending_note <status-file> — the apply command runs EVERY pending
# file of the tree, so a migration that is on main but not yet in production
# runs in this batch too. The lane does not refuse that (main is the truth, and
# a concurrent one already stopped the batch in ml_main_concurrent_ok), but it
# names each such file in the log and in the batch summary.
ml_main_pending_note() {
  local f g
  local -a globs
  mapfile -t globs < <(mmh_globs "$P")
  : > "$ML_TMP/main-names"
  while IFS= read -r f; do
    for g in "${globs[@]}"; do
      mmh_glob_match "$g" "$f" && { printf '%s\n' "${f##*/}" >> "$ML_TMP/main-names"; break; }
    done
  done < <(git -C "$REPO" ls-tree -r --name-only refs/remotes/origin/main 2>/dev/null)
  [ -s "$ML_TMP/main-names" ] || return 0
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    ml_log "batch $ML_ID: main's $f is not in production yet; this apply runs it too"
    printf 'main %s not in production yet: this apply runs it too\n' "$f" >> "$ML_TMP/summary.txt"
  done < <(jq -r --rawfile names "$ML_TMP/main-names" \
    '([.applied[]? | select(type == "object") | (.filename // "" | split("/") | last)]) as $a
     | ($names | split("\n") | map(select(length > 0))) - $a | .[]' "$1" 2>/dev/null)
  return 0
}

# ml_out_rotate <path> — keep the last run's output as <path>.prev and start a
# new <path>: two files per command per project, whatever the batch count.
ml_out_rotate() {
  [ -e "$1" ] && mv -f "$1" "${1%.out}.prev.out"
  return 0
}

# ml_judge_rows <n> <path> <staged-file> <apply-out> — judge the row report of
# one proved member file (bin/lib/migration-rowcount.py; the report line and
# the verdicts are in its header). rc 0 = the file stays proved; rc 1 = it
# holds the member, already logged. Each empty statement adds
# "<path>\t<k>\t<COMMAND>\t<line>" to $ML_TMP/empty-<n>.tsv.
ml_judge_rows() {
  local n="$1" p="$2" b="${2##*/}" py res rc=0 v k cmd cnt ln why unal=0
  # No report line for this file: the CLI does not print counts (or skipped
  # the file). Proved as before, without starting python.
  if ! awk -v pre="migration-rows: $b " 'index($0, pre) == 1 { f = 1; exit } END { exit !f }' "$4" 2>/dev/null; then
    ml_log "#$n $p: the apply output has no migration-rows lines; row counts not checked"
    return 0
  fi
  py="$(dirname "${BASH_SOURCE[0]}")/migration-rowcount.py"
  res=$(python3 -I "$py" judge "$3" "$b" "$4" 2>/dev/null) || rc=$?
  case "$rc" in
    0|1) ;;
    3) ml_log "#$n $p: the apply output has no migration-rows lines; row counts not checked"; return 0 ;;
    *) ml_log "#$n not merged: row-count judge failed on $p (rc $rc)"
       printf '%s\tjudge rc %s\n' "$p" "$rc" >> "$ML_TMP/held-$n.tsv"
       printf '#%s not merged: row-count judge failed on %s\n' "$n" "$p" >> "$ML_TMP/summary.txt"
       return 1 ;;
  esac
  while IFS=$'\t' read -r v k cmd cnt ln why; do
    case "$v" in
      marked) ml_log "#$n may-be-empty: $p statement $k ($(ml_flat "$why"))" ;;
      empty)
        ml_log "#$n empty: $p statement $k ($cmd, line $ln) changed 0 rows"
        printf '%s\t%s\t%s\t%s\n' "$p" "$k" "$cmd" "$ln" >> "$ML_TMP/empty-$n.tsv"
        printf '#%s empty: %s statement %s changed 0 rows\n' "$n" "$p" "$k" >> "$ML_TMP/summary.txt" ;;
      unaligned) unal=1 ;;
    esac
  done <<<"$res"
  if [ "$unal" = 1 ]; then
    ml_log "#$n not merged: $p row report does not match its statements"
    printf '%s\tunaligned\n' "$p" >> "$ML_TMP/held-$n.tsv"
    printf '#%s not merged: %s row report does not match its statements\n' "$n" "$p" >> "$ML_TMP/summary.txt"
  fi
  [ "$rc" = 0 ]
}

# ml_empty_comment <n> <head> — the one PR comment for a member held by an
# empty statement ($ML_TMP/empty-<n>.tsv).
ml_empty_comment() {
  local n="$1" head="$2" body="$ML_TMP/empty-body-$1.md" p k cmd ln
  read -r p k cmd ln < <(head -1 "$ML_TMP/empty-$n.tsv" | tr '\t' ' ')
  {
    printf 'The migration lane did not merge this PR: `%s` statement %s (%s, line %s) changed 0 rows.\n\n' "$p" "$k" "$cmd" "$ln"
    printf 'Batch `%s` at head `%s`. Each data statement that matched nothing:\n\n' "$ML_ID" "${head:0:12}"
    while IFS=$'\t' read -r p k cmd ln; do printf -- '- `%s` statement %s (%s, line %s) changed 0 rows\n' "$p" "$k" "$cmd" "$ln"; done < "$ML_TMP/empty-$n.tsv"
    printf '\nThe file IS applied in production: the project ledger holds it with this checksum. Two ways forward:\n\n'
    printf '1. If 0 rows is wrong, push a NEW migration file with the fixed statement. Leave this file as it is: production holds its checksum, and the lane refuses a changed file.\n'
    printf '2. If 0 rows is correct, an operator merges this PR. A marker added now changes a file that production already holds.\n\n'
    printf 'Next time, mark a statement that may match nothing on the line above it: `-- may-be-empty: <reason>`.\n'
  } > "$body"
  mlx_comment "$SLUG" "$n" "$body" || ml_log "#$n empty comment failed"
  rm -f "$body"
}

# ml_apply — re-check, refuse changed files, run the project's ledger CLI from a
# main tree, prove each file. Writes $ML_TMP/applied.tsv ("<n>\t<head>\t<paths>")
# for each member whose EVERY file is proved. rc 1 = the batch failed (some
# members may still be proved), rc 2 = the lease was lost during the apply.
ml_apply() {
  local n head f p st sha want out apply="$H/state/migration-lane/$P/apply" failed=0 st_file="$ML_TMP/status.json"
  local marker="$H/state/migration-lane/$P/setup.sha" lock rc
  : > "$ML_TMP/apply.tsv"; : > "$ML_TMP/applied.tsv"
  while IFS=$'\t' read -r n head f; do
    read -r st sha <<<"$(mlx_pr_head "$SLUG" "$n")"
    if [ "$st" != open ] || [ "$sha" != "$head" ]; then ml_log "#$n dropped: the head moved or the PR closed during the CI wait (${st:-unread} ${sha:0:8})"; continue; fi
    tr ' ' '\n' <<<"$f" > "$ML_TMP/files-$n.m"
    ml_gate_pr "$SLUG" "$n" "$head" "$ML_TMP/files-$n.m" || { ml_log "#$n dropped: $ML_WHY"; continue; }
    local ok=1
    for p in $f; do
      want=$(jq -r --argjson n "$n" --arg p "$p" '.[] | select(.n == $n) | .files[] | select(.path == $p) | .sha256' <<<"$ML_MEMBERS_JSON")
      git -C "$REPO" show "$head:$p" > "$ML_TMP/stage" 2>/dev/null || { ok=0; break; }
      if [ "$(ml_sha256 "$ML_TMP/stage")" != "$want" ]; then ml_log "#$n refused $p: changed since staging"; ok=0; break; fi
    done
    [ "$ok" = 1 ] && printf '%s\t%s\t%s\n' "$n" "$head" "$f" >> "$ML_TMP/apply.tsv" || ml_log "#$n dropped: a file changed since staging"
  done < "$ML_TMP/members.tsv"
  [ -s "$ML_TMP/apply.tsv" ] || { ml_log "batch $ML_ID: no member left to apply"; return 1; }
  if ! mlx_status_get "$st_file"; then
    ml_log "batch $ML_ID failed: migrations/status unreadable, nothing applied"
    mlx_alert critical "migration-lane-$P-$ML_ID" "$P migration batch $ML_ID failed: the app's migrations/status could not be read, so nothing was applied or merged"
    return 1
  fi
  # A file prod already holds under another checksum is refused.
  : > "$ML_TMP/apply2.tsv"
  while IFS=$'\t' read -r n head f; do
    local ok=1
    for p in $f; do
      want=$(jq -r --argjson n "$n" --arg p "$p" '.[] | select(.n == $n) | .files[] | select(.path == $p) | .sha256' <<<"$ML_MEMBERS_JSON")
      if [ "$(ml_status_has "$st_file" "${p##*/}" "$want")" = changed ]; then
        ml_log "#$n refused $p: changed since staging (production holds another checksum)"
        ml_pr_put "$n" changed "$head" "$p"
        ok=0; failed=1
      fi
    done
    [ "$ok" = 1 ] && printf '%s\t%s\t%s\n' "$n" "$head" "$f" >> "$ML_TMP/apply2.tsv"
  done < "$ML_TMP/apply.tsv"
  [ -s "$ML_TMP/apply2.tsv" ] || { ml_log "batch $ML_ID: no member left to apply"; return 1; }
  ml_main_pending_note "$st_file"
  ml_batch_put applying "$ML_BATCH_JSON"
  # The tree that runs with the production credential is main's code plus the
  # members' SQL files, nothing else from a PR.
  if [ -d "$apply/.git" ] || [ -f "$apply/.git" ]; then
    git -C "$apply" checkout -q --detach -f refs/remotes/origin/main >/dev/null 2>&1 \
      && git -C "$apply" clean -q -fdx -e node_modules >/dev/null 2>&1 || { ml_log "batch $ML_ID failed: apply tree reset failed"; return 1; }
  else
    case "$apply" in "$H"/state/migration-lane/*/apply) rm -rf "$apply" ;; esac
    git -C "$REPO" worktree add -q --detach "$apply" refs/remotes/origin/main >/dev/null 2>&1 \
      || { ml_log "batch $ML_ID failed: apply tree could not be created"; return 1; }
  fi
  while IFS=$'\t' read -r n head f; do
    for p in $f; do
      mkdir -p "$apply/$(dirname "$p")"
      git -C "$REPO" show "$head:$p" > "$apply/$p" || { ml_log "batch $ML_ID failed: could not stage $p"; return 1; }
    done
  done < "$ML_TMP/apply2.tsv"
  if [ -n "${MIGRATION_LANE_SETUP_CMD:-}" ]; then
    lock=$(ml_sha256 "$apply/package-lock.json"); lock="${lock:-none}"
    if [ "$(cat "$marker" 2>/dev/null)" != "$lock" ]; then
      ml_out_rotate "$H/state/migration-lane/$P/setup.out"
      rc=0; ( cd "$apply" && ml_run_renewing "${SETUP_TIMEOUT_S:-900}" "$H/state/migration-lane/$P/setup.out" "${ML_SCRUB[@]}" bash -c "$MIGRATION_LANE_SETUP_CMD" ) || rc=$?
      [ -e "$ML_TMP/lease-lost" ] && { ml_log "batch $ML_ID lost: the lease was lost during the setup; nothing applied or merged"; return 2; }
      [ "$rc" = 0 ] || { ml_log "batch $ML_ID failed: setup command rc $rc"; mlx_alert critical "migration-lane-$P-$ML_ID" "$P migration batch $ML_ID failed: the setup command exited $rc; nothing applied or merged"; return 1; }
      printf '%s' "$lock" > "$marker"
    fi
  fi
  out="$H/state/migration-lane/$P/apply.out"
  ml_out_rotate "$out"
  rc=0
  # DATABASE_URL lives in the apply command's environment only.
  ( cd "$apply" && DATABASE_URL="$MIGRATION_LANE_DATABASE_URL" ml_run_renewing "${APPLY_TIMEOUT_S:-1800}" "$out" "${ML_SCRUB[@]}" bash -c "$MIGRATION_LANE_APPLY_CMD" ) || rc=$?
  ml_log "batch $ML_ID: apply command rc $rc (output: ${out#"$H"/})"
  if ! mlx_status_get "$st_file"; then
    ml_log "batch $ML_ID failed: migrations/status unreadable after the apply"
    mlx_alert critical "migration-lane-$P-$ML_ID" "$P migration batch $ML_ID failed: migrations/status unreadable after the apply; nothing merged"
    return 1
  fi
  while IFS=$'\t' read -r n head f; do
    local all=1 got="" held=0
    for p in $f; do
      want=$(jq -r --argjson n "$n" --arg p "$p" '.[] | select(.n == $n) | .files[] | select(.path == $p) | .sha256' <<<"$ML_MEMBERS_JSON")
      if [ "$(ml_status_has "$st_file" "${p##*/}" "$want")" = applied ]; then got="$got $p"; else all=0; fi
    done
    for p in $got; do ml_log "#$n applied $p"; done
    if [ "$all" = 1 ]; then
      # A proved file still holds the member when a data statement changed 0
      # rows. ml_gate_pr skips an `empty <head>` row before any apply, so the
      # comment posts once per head.
      : > "$ML_TMP/empty-$n.tsv"; : > "$ML_TMP/held-$n.tsv"
      for p in $f; do ml_judge_rows "$n" "$p" "$apply/$p" "$out" || held=1; done
      if [ -s "$ML_TMP/empty-$n.tsv" ]; then
        ml_pr_put "$n" empty "$head" "$(head -1 "$ML_TMP/empty-$n.tsv" | cut -f1,2 | sed 's/\t/ statement /')"
        ml_empty_comment "$n" "$head"
      elif [ "$held" = 1 ]; then
        # Every held member gets a row, whatever the cause: the hold must
        # outlast this tick (ml_gate_pr skips `held <head>`).
        ml_pr_put "$n" held "$head" "$(head -1 "$ML_TMP/held-$n.tsv" | tr '\t' ' ')"
      fi
    fi
    if [ "$all" = 1 ] && [ "$held" = 0 ]; then printf '%s\t%s\t%s\n' "$n" "$head" "$f" >> "$ML_TMP/applied.tsv"
    elif [ "$all" = 1 ]; then failed=1
    else ml_log "#$n not merged: not every file is in the production ledger"; failed=1; fi
  done < "$ML_TMP/apply2.tsv"
  if [ "$failed" = 1 ] || [ "$rc" != 0 ]; then
    mlx_alert critical "migration-lane-$P-$ML_ID" "$P migration batch $ML_ID failed: a member was not proved applied, or a data statement changed 0 rows (apply rc $rc); only the proved members merge"
    failed=1
  fi
  [ -e "$ML_TMP/lease-lost" ] && { ml_log "batch $ML_ID lost: the lease was lost during the apply; nothing merged"; return 2; }
  [ "$failed" = 0 ]
}

# ml_merge_members — one sha-bound merge per proved member, in migration order.
# rc 1 when any member did not merge.
ml_merge_members() {
  local n head f out rc failed=0 body="$ML_TMP/member-body.md"
  ml_batch_put merging "$ML_BATCH_JSON"
  while IFS=$'\t' read -r n head f; do
    rc=0; out=$(mlx_merge "$SLUG" "$n" "$head") || rc=$?
    if [ "$rc" = 0 ]; then
      ml_log "#$n merged ${out:-?}"
      printf '%s\n' "#$n merged ${out:-?}" >> "$ML_TMP/summary.txt"
      printf 'Merged by the migration lane in batch `%s` (#%s, one CI run). Applied to production first, through the project'"'"'s migration ledger: %s\n' "$ML_ID" "$ML_BPR" "$f" > "$body"
      mlx_comment "$SLUG" "$n" "$body" || ml_log "#$n merged-comment failed"
    else
      ml_log "#$n merge refused: rc $rc $(ml_flat "$out")"
      printf '%s\n' "#$n merge refused: rc $rc" >> "$ML_TMP/summary.txt"
      failed=1
    fi
  done < "$ML_TMP/applied.tsv"
  [ "$failed" = 0 ] && return 0
  mlx_alert critical "migration-lane-$P-$ML_ID-merge" "$P migration batch $ML_ID: a member's migration is applied but GitHub refused its merge; see logs/migration-lane.log"
  return 1
}

# ml_finish <status> — summary comment on the batch PR, close, delete, record.
ml_finish() {
  local st="$1" sumf="$ML_TMP/summary.txt"
  [ -s "$sumf" ] && [ -n "${ML_BPR:-}" ] && {
    { printf 'Batch `%s` ended **%s**.\n\n' "$ML_ID" "$st"; sed 's/^/- /' "$sumf"; } > "$ML_TMP/sum-body.md"
    mlx_comment "$SLUG" "$ML_BPR" "$ML_TMP/sum-body.md" || ml_log "batch $ML_ID: summary comment failed"; }
  ml_close_batch
  ml_batch_put "$st" "$(jq -c --arg s "$st" --rawfile sum "$sumf" '. + {status:$s, summary:$sum}' <<<"${ML_BATCH_JSON:-{\}}" 2>/dev/null || printf '%s' "${ML_BATCH_JSON:-{\}}")"
  ml_log "batch $ML_ID $st"
}

# ml_tick — one batch for project P. rc 0 always; the outcome is in the log.
ml_tick() {
  local ci n head f cnt rc
  ml_h_ok || return 0
  ML_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ml-$P.XXXXXX") || { ml_log "no temp dir, no batch"; return 0; }
  : > "$ML_TMP/summary.txt"
  ML_BATCH_JSON='{}'; ML_MEMBERS_JSON='[]'; ML_BPR=""; ML_WT=""; ML_ID=""
  if ! ml_select; then rm -rf "$ML_TMP"; return 0; fi
  if ! ml_build_batch; then rm -rf "$ML_TMP"; return 0; fi
  ci=$(ml_wait_ci)
  case "$ci" in
    green) ;;
    red)
      cnt=$(wc -l < "$ML_TMP/members.tsv")
      while IFS=$'\t' read -r n head f; do
        if [ "$cnt" -ge 2 ]; then ml_pr_put "$n" solo "$head" "batch $ML_ID red"; else ml_pr_put "$n" red "$head" "solo batch $ML_ID red"; fi
        printf '#%s batch CI red\n' "$n" >> "$ML_TMP/summary.txt"
      done < "$ML_TMP/members.tsv"
      mlx_alert critical "migration-lane-$P-$ML_ID" "$P migration batch $ML_ID: CI red on #$ML_BPR; nothing applied or merged ($( [ "$cnt" -ge 2 ] && echo 'each member goes alone next' || echo 'the PR waits for a new head'))"
      ml_finish red; rm -rf "$ML_TMP"; return 0 ;;
    timeout)
      mlx_alert critical "migration-lane-$P-$ML_ID" "$P migration batch $ML_ID: CI did not finish within ${CI_TIMEOUT_S:-3600}s on #$ML_BPR; nothing applied or merged"
      ml_finish timeout; rm -rf "$ML_TMP"; return 0 ;;
    *)
      ml_log "batch $ML_ID lost: the lease was lost during the CI wait; nothing applied or merged"
      ml_finish lost; rm -rf "$ML_TMP"; return 0 ;;
  esac
  rc=0; ml_apply || rc=$?
  if [ "$rc" = 2 ]; then ml_finish lost; rm -rf "$ML_TMP"; return 0; fi
  if [ ! -s "$ML_TMP/applied.tsv" ]; then ml_finish failed; rm -rf "$ML_TMP"; return 0; fi
  ml_merge_members || rc=1
  if [ "$rc" = 0 ]; then ml_finish "done"; else ml_finish failed; fi
  rm -rf "$ML_TMP"
  return 0
}
