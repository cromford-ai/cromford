#!/bin/bash
# bin/hotfix-migrate.sh: the hotfix go-live stage (BH-370.1 / BH-375).
#
# Ordinary migrations ride the slow path on purpose: PR, merge, deploy, then the
# */15 tick in bin/apply-migrations.sh. A `hotfix` ticket needs the schema and the
# code that reads it to land together, so this stage waits for the PR's checks,
# applies the PR's OWN added migration files through the app's endpoint, and posts
# a proof comment saying exactly what it did. The proof is the point: nothing
# downstream, the merge conductor above all, may trust a hotfix that cannot show
# its work. It holds no DB credential (the app applies its own deployed SQL,
# docs/MIGRATION_ENDPOINT_SPEC.html), never applies flagged SQL, never reads an
# unreadable answer as a green one, never waits on a lock, and records `applied`
# only for the endpoint's literal `applied`/`already-applied` words. The ledger is
# $BUILD/hotfix-migrate.json keyed by FP, a content fingerprint of the added SQL:
# a rebase that leaves the SQL alone keeps the proof, any edit invalidates it.
# docs/DB-COORDINATION-SPEC.md carries the full contract, the knob table and the
# seams BH-370.3/370.4 plug into.
#
#   usage: hotfix-migrate.sh <project> <build-dir>
#   exit 0 applied or deferred-to-deploy | 2 gate FLAGGED the SQL | 3 hold (checks
#   not green, a failure word, a proof that would not post) | 4 no migration files
#   here, or a before-merge PR with no workflow to dispatch (HM_BEFORE_MERGE=1: one
#   alert, no proof) | 5 no-path, neither shape | 75 busy, we never wait.
#   HM_BEFORE_MERGE=1 (run-build's stage block, BH-9403) runs it for a NORMAL PR of
#   a project whose hotfix_migrate.conf.<project> row has "before_merge":1.
set -uo pipefail
HARNESS="${HARNESS:-/root/harness}"

# Globals the workflow lib may read (the contract in BH-370.1's "Seams"):
#   PROJECT BUILD SLUG PR_URL BRANCH WT FP FILES LEDGER HARNESS MODE KEY BASE
# run-build.sh hands most of them in through the environment and a manual re-run
# passes none, so hm_main resolves whatever is missing. Seeded here, never blanked.
PROJECT=""; BUILD=""; FP=""; FILES=(); LEDGER=""; MODE=""; KEY=""
SLUG="${SLUG:-}"; PR_URL="${PR_URL:-}"; BRANCH="${BRANCH:-}"; WT="${WT:-}"; BASE="${BASE:-}"
HM_COMMENT_ID=""; HM_GATE_NOTE=""

# shellcheck source=bin/lib/env-path.sh
. "$HARNESS/bin/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$HARNESS}/env"; }
[ -f "$HARNESS/bin/lib/gh-repo-token.sh" ] && . "$HARNESS/bin/lib/gh-repo-token.sh"
[ -f "$HARNESS/bin/lib/gh-ci-read.sh" ] && . "$HARNESS/bin/lib/gh-ci-read.sh"
[ -f "$HARNESS/bin/lib/migrations-glob.sh" ] && . "$HARNESS/bin/lib/migrations-glob.sh"
# The per-project row hotfix_migrate.conf.<project> (BH-9403): read in hm_main
# AFTER the env files, so a row key beats the env knob of the same meaning.
[ -f "$HARNESS/bin/lib/hotfix-migrate-knobs.sh" ] && . "$HARNESS/bin/lib/hotfix-migrate-knobs.sh"

# hm_checks_red / hm_checks_unreadable <file>: `gh pr checks` exits 1 for two
# opposite reasons, and conflating them lets a weaker secondary read overrule an
# explicit failure. A required check that is NOT an Actions run (Vercel, Mergify
# and CodeRabbit all sit on our PRs) can be red while every workflow run on the sha
# is green. A `fail` row is an answer: hold.
hm_checks_red() {
  awk -F'\t' 'tolower($2) ~ /^(fail|failure|cancelled|timed_out|action_required|startup_failure)$/ {f=1} END{exit !f}' "$1" && return 0
  grep -qiE '^[0-9]+ (failing|cancelled)|checks were not successful' "$1"
}
hm_checks_unreadable() {
  [ -s "$1" ] || return 0   # nonzero rc and not one word about why
  grep -qiE 'resource not accessible|not accessible by|no required checks reported|no checks reported|no commit found|HTTP (4[0-9][0-9]|5[0-9][0-9])|bad credentials|authentication|GraphQL' "$1"
}

# hm_wait_checks: rc 0 green, rc 1 red / timed out / nobody could read it.
#
# Two reads, because the first usually answers nothing here: the PATs get
# "Resource not accessible by integration" out of the checks GraphQL (the wall
# bin/lib/gh-ci-read.sh documents) and --required reports nothing on a repo without
# branch protection, which is every repo we build today. So we ask it first and
# fall back to the Actions-runs read, under the same deadline, ONLY when it said
# nothing readable; a fail row or a timed-out read holds on the spot. Green needs
# at least one run, all completed success/skipped/neutral; no runs by the deadline
# is NOT green, because "we could not tell" may not reach a production database as
# if it were "it passed".
hm_wait_checks() {
  local wait deadline rc head runs total bad pend good remain
  wait="${HOTFIX_CI_WAIT:-1200}"
  case "$wait" in ''|*[!0-9]*) wait=1200 ;; esac
  # `timeout 0` is "no limit" in coreutils, the opposite of what a 0 caller wants.
  [ "$wait" -ge 1 ] || wait=1
  deadline=$(( $(date +%s) + wait ))
  timeout "$wait" gh pr checks "$PR_URL" --required --watch --fail-fast > "$BUILD/hotfix-checks.txt" 2>&1
  rc=$?
  if [ "$rc" = 0 ] && [ -s "$BUILD/hotfix-checks.txt" ]; then return 0; fi
  # 124 is the deadline, not a verdict, and the ticket's word for it is hold.
  if [ "$rc" = 124 ]; then
    echo "checks not green: the required-checks read did not settle within ${wait}s" >> "$BUILD/hotfix-checks.txt"
    return 1
  fi
  if hm_checks_red "$BUILD/hotfix-checks.txt"; then
    echo "checks not green: gh pr checks reported a failing required check" >> "$BUILD/hotfix-checks.txt"
    return 1
  fi
  if ! hm_checks_unreadable "$BUILD/hotfix-checks.txt"; then
    echo "checks not green: gh pr checks exited $rc with an answer we cannot read as a pass" >> "$BUILD/hotfix-checks.txt"
    return 1
  fi
  head=$(git -C "$WT" rev-parse HEAD 2>/dev/null)
  if [ -z "$head" ]; then
    echo "checks not green: could not resolve the branch head to read Actions runs for" >> "$BUILD/hotfix-checks.txt"
    return 1
  fi
  while :; do
    runs=$(gh_ci_api "$SLUG" "repos/$SLUG/actions/runs?head_sha=$head&per_page=20" 2>/dev/null)
    total=$(jq -r '(.workflow_runs // []) | length' <<<"${runs:-}" 2>/dev/null)
    if [ -n "${total:-}" ] && [ "${total:-0}" -gt 0 ] 2>/dev/null; then
      bad=$(jq -r '[(.workflow_runs // [])[] | select(.conclusion=="failure" or .conclusion=="cancelled" or .conclusion=="timed_out" or .conclusion=="action_required" or .conclusion=="startup_failure")] | length' <<<"$runs")
      if [ "${bad:-0}" -gt 0 ]; then
        echo "checks not green: $bad failing workflow run(s) on $head" >> "$BUILD/hotfix-checks.txt"
        return 1
      fi
      pend=$(jq -r '[(.workflow_runs // [])[] | select(.status != "completed")] | length' <<<"$runs")
      if [ "${pend:-0}" -eq 0 ]; then
        good=$(jq -r '[(.workflow_runs // [])[] | select(.conclusion=="success" or .conclusion=="skipped" or .conclusion=="neutral")] | length' <<<"$runs")
        if [ "${good:-0}" = "$total" ]; then
          echo "checks green: $total completed workflow run(s) on $head" >> "$BUILD/hotfix-checks.txt"
          return 0
        fi
        echo "checks not green: $total run(s) on $head, only ${good:-0} with a passing conclusion" >> "$BUILD/hotfix-checks.txt"
        return 1
      fi
    fi
    remain=$(( deadline - $(date +%s) ))
    if [ "$remain" -le 0 ]; then
      echo "checks not green: no readable check result for $head within ${wait}s" >> "$BUILD/hotfix-checks.txt"
      return 1
    fi
    [ "$remain" -gt 30 ] && remain=30
    sleep "$remain"
  done
}

# hm_wait_checks_except: hm_wait_checks for a PR whose migration-ledger gate is
# itself a required check (BH-9403). That gate is red until the SQL is applied,
# and the apply is what this stage is about to do, so waiting on it never ends.
# The checks named in HMK_GATE_CHECKS (row mc.migration_gate_checks.<project>,
# EXACT names) are dropped from the read, and the Actions runs of the workflow
# files in HMK_GATE_WORKFLOWS are dropped from the fallback.
#   green  every remaining row is pass/skipping, and at least one row remains
#   red    a remaining row failed -> rc 1 at once
#   wait   anything else, polled every HOTFIX_QUIET_POLL seconds (default 30)
#          until HOTFIX_CI_WAIT; no answer by then is NOT green.
hm_wait_checks_except() {
  local wait deadline poll ex gw verdict head runs remain
  wait="${HOTFIX_CI_WAIT:-1200}"
  case "$wait" in ''|*[!0-9]*) wait=1200 ;; esac
  [ "$wait" -ge 1 ] || wait=1
  poll="${HOTFIX_QUIET_POLL:-30}"
  case "$poll" in ''|*[!0-9]*) poll=30 ;; esac
  [ "$poll" -ge 1 ] || poll=1
  deadline=$(( $(date +%s) + wait ))
  ex=" ${HMK_GATE_CHECKS:-} "; gw=" ${HMK_GATE_WORKFLOWS:-} "
  head=$(git -C "$WT" rev-parse HEAD 2>/dev/null)
  while :; do
    gh pr checks "$PR_URL" --required > "$BUILD/hotfix-checks.txt" 2>&1
    verdict=$(awk -F'\t' -v ex="$ex" '
      NF >= 2 { n++
        if ($1 != "" && index(ex, " " $1 " ")) next
        k++; s = tolower($2)
        if (s ~ /^(fail|failure|cancel|cancelled|timed_out|action_required|startup_failure)$/) r++
        else if (s ~ /^(pass|success|skipping|skipped|neutral)$/) g++ }
      END { if (r) print "red"; else if (k && g == k) print "green"; else if (n) print "wait"; else print "none" }' \
      "$BUILD/hotfix-checks.txt")
    if [ "$verdict" = none ] && [ -n "$head" ] && command -v gh_ci_api >/dev/null 2>&1; then
      runs=$(gh_ci_api "$SLUG" "repos/$SLUG/actions/runs?head_sha=$head&per_page=20" 2>/dev/null)
      verdict=$(jq -r --arg gw "$gw" '
        [(.workflow_runs // [])[] | select(((.path // "") | split("/") | last) as $b
          | ($b != "" and ($gw | contains(" " + $b + " "))) | not)] as $r
        | if ($r | length) == 0 then "wait"
          elif any($r[]; .conclusion == "failure" or .conclusion == "cancelled" or .conclusion == "timed_out" or .conclusion == "action_required" or .conclusion == "startup_failure") then "red"
          elif any($r[]; .status != "completed") then "wait"
          elif all($r[]; .conclusion == "success" or .conclusion == "skipped" or .conclusion == "neutral") then "green"
          else "red" end' <<<"${runs:-}" 2>/dev/null)
      [ -n "$verdict" ] || verdict=wait
    fi
    case "$verdict" in
      green) echo "checks green: every required check outside the migration gate (${HMK_GATE_CHECKS:-}${HMK_GATE_WORKFLOWS:+ $HMK_GATE_WORKFLOWS}) passed" >> "$BUILD/hotfix-checks.txt"; return 0 ;;
      red)   echo "checks not green: a required check outside the migration gate failed" >> "$BUILD/hotfix-checks.txt"; return 1 ;;
    esac
    remain=$(( deadline - $(date +%s) ))
    if [ "$remain" -le 0 ]; then
      echo "checks not green: no passing check outside the migration gate within ${wait}s" >> "$BUILD/hotfix-checks.txt"
      return 1
    fi
    [ "$remain" -gt "$poll" ] && remain="$poll"
    sleep "$remain"
  done
}

# hm_post_proof <decision> <body-file>: marker line then body, prints the comment
# id, sets HM_COMMENT_ID, rc 1 on any gh failure. The body goes over as a FILE
# (`-F body=@...`): SQL has no business in an argv a process list can read.
hm_post_proof() {
  local decision="$1" bodyfile="$2" tmp n id
  n=$(sed -nE 's#.*/pull/([0-9]+).*#\1#p' <<<"$PR_URL" | head -n1)
  case "${n:-}" in ''|*[!0-9]*) echo "hotfix-migrate: cannot read a PR number out of '$PR_URL'" >&2; return 1 ;; esac
  tmp=$(mktemp)
  { printf '<!-- hotfix-migrate-proof fp=%s decision=%s -->\n\n' "$FP" "$decision"; cat "$bodyfile"; } > "$tmp"
  id=$(gh api "repos/$SLUG/issues/$n/comments" -F "body=@$tmp" -q .id 2>>"$BUILD/hotfix-gh.err")
  rm -f "$tmp"
  [ -n "$id" ] || return 1
  HM_COMMENT_ID="$id"
  printf '%s\n' "$id"
}

# hm_write_ledger <decision> <files-json> [run_id]: atomic, tmp then mv, always
# written AFTER the side effect it records and rewritten once the comment lands.
# `applied` with posted_comment_id:null is a real and honest state: the SQL ran,
# the proof did not, and the conductor must not accept it.
hm_write_ledger() {
  local decision="$1" fjson="${2:-[]}" run="${3:-}"
  [ -n "$fjson" ] || fjson='[]'   # an empty string is not valid --argjson
  jq -n --arg fp "$FP" --arg mode "$MODE" --arg d "$decision" --arg cid "${HM_COMMENT_ID:-}" \
        --arg run "$run" --argjson files "$fjson" \
    '{fp:$fp, mode:$mode, decision:$d,
      files:(if $run == "" then $files else ($files | map(. + {run_id:$run})) end),
      posted_comment_id:(if $cid == "" then null else (($cid|tonumber?) // $cid) end),
      after_deploy:null}' > "$LEDGER.tmp" 2>/dev/null && mv "$LEDGER.tmp" "$LEDGER"
}

# hm_revert_lines <file...>: the undo story for every data-edit file. A CREATE
# TABLE that goes wrong is annoying; an UPDATE that goes wrong loses client data,
# and whoever cleans it up at 2am should not have to reconstruct the inverse from
# the diff. So a file carrying UPDATE or INSERT prints its declared `-- revert:`
# line or a line saying nobody wrote one; a file with no data edit prints nothing.
# Detection reads STATEMENTS, not text: comments are stripped first ("-- INSERT
# later" is not a data edit) and the match is anchored at a statement start.
hm_revert_lines() {
  local f p st U has rev
  for f in "$@"; do
    p="$f"; [ -f "$p" ] || p="$WT/$f"
    [ -f "$p" ] || continue
    has=0
    while IFS= read -r st; do
      [ -n "$st" ] || continue
      U=$(tr '[:lower:]' '[:upper:]' <<<"$st")
      case "$U" in "UPDATE "*|"INSERT "*) has=1 ;; esac
    done < <(perl -0777 -pe 's/--[^\n]*//g; s{/\*.*?\*/}{}gs' "$p" \
             | tr '\n' ' ' | tr ';' '\n' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
    [ "$has" = 1 ] || continue
    rev=$(grep -m1 -iE '^[[:space:]]*--[[:space:]]*revert:' "$p" 2>/dev/null)
    if [ -n "$rev" ]; then
      printf '%s: revert: %s\n' "$f" "$(sed -E 's/^[[:space:]]*--[[:space:]]*[Rr][Ee][Vv][Ee][Rr][Tt]:[[:space:]]*//' <<<"$rev")"
    else
      printf '%s: REVERT: none declared in file - write one before applying by hand\n' "$f"
    fi
  done
}

# The seam BH-370.3 plugs into, sourced AFTER the helpers so the lib can use them.
[ -f "$HARNESS/bin/lib/hotfix-migrate-workflow.sh" ] && . "$HARNESS/bin/lib/hotfix-migrate-workflow.sh"

hm_files_json() { # hm_files_json <status>  (one status for every file)
  printf '%s\n' "${FILES[@]}" \
    | jq -R -s --arg s "$1" 'split("\n") | map(select(length > 0)) | map({path:., status:$s})'
}

hm_body_head() { # hm_body_head: the lines every proof body starts with
  printf 'Files in this PR:\n'
  printf -- '- %s\n' "${FILES[@]}"
  printf '\n'
}

hm_finish() { # hm_finish <decision> <body-file> <files-json> <exit-code>
  local decision="$1" body="$2" fjson="$3" code="$4"
  hm_write_ledger "$decision" "$fjson"
  if ! hm_post_proof "$decision" "$body"; then
    echo "hotfix-migrate: the proof comment for $decision did not post. Leaving posted_comment_id null" >&2
    return 3
  fi
  hm_write_ledger "$decision" "$fjson"
  return "$code"
}

hm_no_path() { # hm_no_path <sentence>
  local body; body=$(mktemp)
  { printf 'We did not apply anything for this hotfix, because there is no way to.\n\n'
    hm_body_head
    printf '%s\n\n' "$1"
    printf 'quiet window: not needed (nothing was applied)\n'
    hm_revert_lines "${FILES[@]}"
  } > "$body"
  hm_finish no-path "$body" "$(hm_files_json not-applied)" 5
  local rc=$?; rm -f "$body"; return "$rc"
}

hm_hold() { # hm_hold <why> [extra-file]
  local body; body=$(mktemp)
  { printf 'We held this hotfix and did not touch the database.\n\n'
    hm_body_head
    printf '%s\n\n' "$1"
    if [ -n "${2:-}" ] && [ -s "${2:-}" ]; then
      printf 'What we read:\n\n```\n%s\n```\n\n' "$(tail -n 20 "$2" | head -c 1500)"
    fi
    printf 'quiet window: not needed (nothing was applied)\n'
    hm_revert_lines "${FILES[@]}"
  } > "$body"
  hm_finish hold "$body" "$(hm_files_json hold)" 3
  local rc=$?; rm -f "$body"; return "$rc"
}

hm_endpoint() {
  local bn=() f i n line st want decision arc body fjson rc
  local -a LINES=() STS=()
  hm_wait_checks || { hm_hold "checks not green, so we stopped before the apply." "$BUILD/hotfix-checks.txt"; return $?; }

  for f in "${FILES[@]}"; do bn+=("$(basename "$f")"); done
  "$HARNESS/bin/apply-migrations.sh" "$PROJECT" --files "${bn[@]}" \
    > "$BUILD/hotfix-apply.jsonl" 2>>"$BUILD/hotfix-apply.err"
  arc=$?
  if [ "$arc" = 75 ]; then
    hm_hold "the migration driver's lock is busy. The */15 cron tick owns it right now. Nothing was applied; re-run this stage and it will pick the files up."
    return $?
  fi

  mapfile -t LINES < "$BUILD/hotfix-apply.jsonl"
  n="${#FILES[@]}"
  if [ "${#LINES[@]}" != "$n" ]; then
    hm_hold "the migration driver answered ${#LINES[@]} result line(s) for $n file(s), so we cannot say what happened to each one." "$BUILD/hotfix-apply.jsonl"
    return $?
  fi
  i=0
  while [ "$i" -lt "$n" ]; do
    line="${LINES[$i]}"
    st=$(jq -r '.status // empty' <<<"$line" 2>/dev/null)
    want=$(jq -r '.filename // empty' <<<"$line" 2>/dev/null)
    if [ -z "$st" ] || [ "$want" != "${bn[$i]}" ]; then
      hm_hold "we could not read the migration driver's answer for ${bn[$i]}." "$BUILD/hotfix-apply.jsonl"
      return $?
    fi
    STS+=("$st")
    i=$((i+1))
  done

  # Only these two words are success. Refused, failed, a request that never landed,
  # no-endpoint, in-progress, a word we have never seen: all hold, and a hold beats
  # a defer when both land in the same batch.
  decision=applied
  for st in "${STS[@]}"; do
    case "$st" in
      applied|already-applied) ;;
      not-pending) [ "$decision" = hold ] || decision=deferred-to-deploy ;;
      *) decision=hold ;;
    esac
  done

  fjson=$(printf '%s\n' "${STS[@]}" | jq -R -s --argjson paths "$(printf '%s\n' "${FILES[@]}" | jq -R -s 'split("\n")|map(select(length>0))')" \
    'split("\n") | map(select(length > 0)) | to_entries | map({path:$paths[.key], status:.value})')

  body=$(mktemp)
  { case "$decision" in
      applied)            printf 'We applied this hotfix'"'"'s migration SQL through the app'"'"'s own endpoint.\n\n' ;;
      deferred-to-deploy) printf 'We could not apply this hotfix'"'"'s SQL yet: the endpoint only sees files that are in the RUNNING bundle, so these become pending once the merge deploys. The post-deploy step (BH-370.4) will pick them up as soon as the deploy is verified; until that slice ships, the */15 migration tick applies them within 15 minutes of the deploy.\n\n' ;;
      *)                  printf 'We held this hotfix: at least one file did not come back applied, so we stopped.\n\n' ;;
    esac
    hm_body_head
    printf 'Per file, the endpoint'"'"'s own answer:\n\n'
    i=0
    while [ "$i" -lt "$n" ]; do
      printf -- '- %s: %s\n' "${FILES[$i]}" "${LINES[$i]}"
      i=$((i+1))
    done
    printf '\n'
    printf -- '- %s: quiet window: not needed (endpoint shape)\n' "${FILES[@]}"
    hm_revert_lines "${FILES[@]}"
  } > "$body"

  case "$decision" in
    applied|deferred-to-deploy) hm_finish "$decision" "$body" "$fjson" 0 ;;
    *)                          hm_finish "$decision" "$body" "$fjson" 3 ;;
  esac
  rc=$?; rm -f "$body"; return "$rc"
}

hm_main() {
  PROJECT="${1:-}"; BUILD="${2:-}"
  if [ -z "$PROJECT" ] || [ -z "$BUILD" ] || [ ! -d "$BUILD" ]; then
    echo "usage: hotfix-migrate.sh <project> <build-dir>" >&2; return 2
  fi
  # The env dir comes from the resolver, never from a hardcoded path: the boxes
  # that have finished the /etc/harness/env move have no directory of their own
  # (tests/env-path-test.sh scans for exactly this).
  local henv; henv=$(harness_env_dir "$HARNESS")
  set -a
  [ -f "$henv/global.env" ] && . "$henv/global.env"
  [ -f "$henv/$PROJECT.env" ] && . "$henv/$PROJECT.env"
  set +a
  # The settings row beats the env file (BH-9403). No row: nothing changes.
  if declare -F hmk_conf >/dev/null 2>&1; then hmk_conf "$PROJECT"; fi

  LEDGER="$BUILD/hotfix-migrate.json"
  KEY=$(basename "$BUILD"); KEY="${KEY#"$PROJECT"-}"; KEY="${KEY%-*}"
  local kl; kl=$(tr '[:upper:]' '[:lower:]' <<<"$KEY")

  BRANCH="${BRANCH:-}"
  [ -n "$BRANCH" ] || { [ -s "$BUILD/branch" ] && BRANCH=$(head -n1 "$BUILD/branch"); }
  [ -n "$BRANCH" ] || BRANCH="ticket/$kl"
  WT="${WT:-}"
  [ -n "$WT" ] || WT="/root/worktrees/$PROJECT-$kl"
  if [ ! -e "$WT/.git" ]; then
    echo "hotfix-migrate: cannot resolve worktree ($WT). Nothing to fingerprint, so nothing is posted" >&2
    return 3
  fi
  BASE="${BASE:-${BASE_BRANCH:-main}}"
  SLUG="${SLUG:-}"
  [ -n "$SLUG" ] || SLUG=$(git -C "$WT" remote get-url origin 2>/dev/null \
    | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')

  # Which token can see this repo at all. A repo no token can see is an ALERT,
  # never a quiet skip (the 2026-09-12 project-5 shape).
  if command -v gh_repo_use_token >/dev/null 2>&1; then
    gh_repo_use_token "$SLUG" || {
      gh_repo_invisible_alert hotfix-migrate "$SLUG" "the hotfix proof for $KEY was not posted"
      return 3; }
  fi

  PR_URL="${PR_URL:-}"
  if [ -z "$PR_URL" ] && [ -s "$BUILD/RESULT" ]; then
    # A manual re-run reads the build's own RESULT: second word only (the line
    # carries QA/migration notes after the URL).
    case "$(awk 'NR==1{print $1}' "$BUILD/RESULT")" in
      PR_*) PR_URL=$(awk 'NR==1{print $2}' "$BUILD/RESULT") ;;
    esac
  fi
  [ -n "$PR_URL" ] || PR_URL=$(gh pr list -R "$SLUG" --head "$BRANCH" --state all --json url -q '.[0].url' 2>/dev/null)
  if [ -z "$PR_URL" ]; then
    echo "hotfix-migrate: no PR found for $BRANCH in $SLUG. Nothing to post a proof on" >&2
    return 3
  fi

  if [ -n "${HOTFIX_MIGRATE_MODE:-}" ]; then
    MODE="$HOTFIX_MIGRATE_MODE"
    case "$MODE" in endpoint|workflow|none) ;;
      *) echo "hotfix-migrate: HOTFIX_MIGRATE_MODE must be endpoint, workflow or none (got '$MODE')" >&2; return 2 ;;
    esac
  else
    # The four projects whose app exposes /api/internal/migrations. Mirrors
    # bin/apply-migrations.sh's `case` arm, the source of truth, and why both files
    # sit in tests/fleet-projects-allowlist.txt: the fleet registry records a prod
    # URL, not which app ships the endpoint.
    case "$PROJECT" in
      project-1|project-2|project-3|project-4) MODE=endpoint ;;
      *) if [ -n "${HOTFIX_MIGRATE_WORKFLOW:-}" ]; then MODE=workflow; else MODE=none; fi ;;
    esac
  fi

  # The PR's migration files: ADDED only, the appliability gate's own definition.
  # `none` looks under both globs so a project with no shape still answers "no
  # migration files here" when the PR genuinely carries none.
  # The project's migrations_glob row (bin/lib/migrations-glob.sh) is looked
  # under IN ADDITION to scripts/migrations/*.sql, never instead of it: the merge
  # conductor's mc_hotfix_proof (bin/lib/mc/classify.sh, the BH-370 contract)
  # always counts scripts/migrations/*.sql and adds the same row, so both sides
  # fingerprint the same files. A row value gets git's :(glob) magic so its `*`
  # stays inside the one directory (mg_path_in is the conductor's copy of that).
  local ep='scripts/migrations/*.sql' epsrc=default wf globs=() eps=()
  if declare -F mg_glob >/dev/null 2>&1; then
    mg_glob "$PROJECT" >/dev/null; epsrc="$MG_SRC"
  fi
  eps=("$ep")
  case "$epsrc" in migrations_glob.*) [ "$MG_GLOB" = "$ep" ] || eps+=(":(glob)$MG_GLOB") ;; esac
  wf="${HOTFIX_MIGRATE_GLOB:-prisma/migrations/manual/*.sql}"
  case "$MODE" in
    endpoint) globs=("${eps[@]}") ;;
    workflow) globs=("$wf")
              # The row's glob (project-6: prisma/sql/*.sql), IN ADDITION to the
              # env glob, with `*` kept inside its one directory.
              if [ -n "${HMK_GLOB:-}" ] && [ "$HMK_GLOB" != "$wf" ]; then globs+=(":(glob)$HMK_GLOB"); fi ;;
    none)     globs=("${eps[@]}" "$wf") ;;
  esac
  mapfile -t FILES < <(git -C "$WT" diff --name-only --diff-filter=A "$BASE"...HEAD -- "${globs[@]}" 2>/dev/null)
  if [ "${#FILES[@]}" -eq 0 ]; then
    echo "hotfix-migrate: $BRANCH adds no migration files (looked under: ${globs[*]}; endpoint glob from $epsrc). Nothing to do" >&2
    return 4
  fi

  # A before-merge PR (not a hotfix) of a project whose row names no usable
  # workflow has no way to apply its SQL before the merge. That is a config gap,
  # not a decision about this SQL: one alert, no proof, and rc 4 so the build's
  # tier is left alone and the PR takes the ordinary path.
  if [ "${HM_BEFORE_MERGE:-0}" = 1 ] && [ "$MODE" = none ]; then
    local ar="$HARNESS/bin/alert-line.sh"
    [ -x "$ar" ] && HARNESS="$HARNESS" "$ar" --id "hotfix-migrate-no-workflow-$PROJECT" --project "$PROJECT" \
      "hotfix-migrate: $PROJECT has before_merge on but no usable workflow in hotfix_migrate.conf.$PROJECT; $PR_URL adds SQL and nothing applied it before the merge" >/dev/null 2>&1
    echo "hotfix-migrate: before-merge is on for $PROJECT but there is no workflow to dispatch. Nothing applied" >&2
    return 4
  fi

  FP=$(for f in "${FILES[@]}"; do printf '%s %s\n' "$f" "$(git -C "$WT" hash-object "$f" 2>/dev/null)"; done \
       | sort | sha256sum | awk '{print $1}')

  # Dedupe on the CONTENT, not the branch: two builds of the same SQL must not both
  # POST. flock -n, so the loser leaves immediately and is re-offered.
  mkdir -p "$HARNESS/locks" 2>/dev/null
  exec 9>"$HARNESS/locks/hotfix-migrate-$PROJECT-$FP.lock"
  flock -n 9 || { echo "hotfix-migrate: another run already owns fingerprint $FP" >&2; return 75; }

  # Idempotence: an `applied` ledger for THIS fingerprint means the SQL already ran
  # and the only question left is whether its proof ever reached the PR.
  if [ -s "$LEDGER" ] \
     && [ "$(jq -r --arg fp "$FP" 'if (.fp == $fp and .decision == "applied") then "y" else "n" end' "$LEDGER" 2>/dev/null)" = y ]; then
    local pid; pid=$(jq -r '.posted_comment_id // "null"' "$LEDGER" 2>/dev/null)
    if [ "$pid" != null ] && [ -n "$pid" ]; then
      cat "$LEDGER"
      return 0
    fi
    local body; body=$(mktemp)
    { printf 'We already applied this hotfix'"'"'s migration SQL. The proof comment did not post last time, so here it is.\n\n'
      hm_body_head
      printf 'Per file, as recorded when we applied it:\n\n'
      jq -r '.files[]? | "- \(.path): \(.status)"' "$LEDGER" 2>/dev/null
      printf '\n'
      printf -- '- %s: quiet window: not needed (endpoint shape)\n' "${FILES[@]}"
      hm_revert_lines "${FILES[@]}"
    } > "$body"
    local fj; fj=$(jq -c '.files // []' "$LEDGER" 2>/dev/null)
    hm_finish applied "$body" "${fj:-[]}" 0
    local rc=$?; rm -f "$body"; return "$rc"
  fi

  # The gate runs FIRST, in every mode: SQL it flags never reaches an apply path,
  # so this exit sits before the mode dispatch on purpose.
  "$HARNESS/bin/check-migration-appliable.sh" "$PROJECT" "$WT" "${FILES[@]}" > "$BUILD/hotfix-gate.txt" 2>&1
  local grc=$?
  HM_GATE_NOTE=""
  if [ "$grc" = 1 ] && [ "$MODE" = workflow ] && [ "${HMK_LOCAL_GATE:-strict}" = advisory ]; then
    # local_gate=advisory: the workflow's own allow-list runs from main and
    # decides. Our gate's report rides in the proof, and a refusal comes back as
    # the outcome word `refused`.
    HM_GATE_NOTE=$(printf 'The local appliability gate flagged these; the workflow'"'"'s allow-list decides:\n\n```\n%s\n```' \
      "$(head -c 1500 "$BUILD/hotfix-gate.txt")")
    grc=0
  fi
  if [ "$grc" = 1 ]; then
    local body; body=$(mktemp)
    { printf 'We did not apply this hotfix: the appliability gate flagged these statements, and the endpoint'"'"'s classifier would refuse them anyway.\n\n'
      hm_body_head
      printf '```\n%s\n```\n\n' "$(head -c 1500 "$BUILD/hotfix-gate.txt")"
      printf 'quiet window: not needed (nothing was applied)\n'
      hm_revert_lines "${FILES[@]}"
    } > "$body"
    hm_finish flagged "$body" "$(hm_files_json flagged)" 2
    local rc=$?; rm -f "$body"; return "$rc"
  elif [ "$grc" != 0 ]; then
    hm_hold "the appliability gate could not read the files (exit $grc), so we do not know what this SQL does." "$BUILD/hotfix-gate.txt"
    return $?
  fi

  case "$MODE" in
    none)
      hm_no_path "this project has neither /api/internal/migrations nor a dispatchable migration workflow; set HOTFIX_MIGRATE_WORKFLOW or ship the endpoint"
      return $? ;;
    workflow)
      if declare -F hm_workflow >/dev/null 2>&1; then hm_workflow; return $?; fi
      hm_no_path "workflow shape not installed: bin/lib/hotfix-migrate-workflow.sh missing"
      return $? ;;
    *)
      hm_endpoint; return $? ;;
  esac
}

if [ -n "${HM_SOURCE_ONLY:-}" ]; then return 0 2>/dev/null || exit 0; fi
hm_main "$@"
exit $?
