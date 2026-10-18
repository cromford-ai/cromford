#!/bin/bash
# shellcheck shell=bash
# bin/lib/ppr-review.sh — what the hub does after it opens a PR for a "push
# rejected" deferral whose push landed (bin/lib/pool-push-rejected.sh). Loaded
# by ppr_after_reap with ppr_lib, never run: no `set`, no `exit`, nothing runs
# at source time.
#
# The machine's own PR stage sends the `pr_created` build beat, runs the
# review and checks the migrations. When the push stage fails first, none of
# that runs, and a PR the hub opens has no build row, no verdict and no check.
# ppr_review_handoff does the three steps for it, once per hub-opened PR:
#
#   review     a relayed builder APPROVE counts only when its reviewed-sha IS
#              the PR head. Otherwise one `bin/lead-verdict.sh request` for the
#              head. rc 0 = `requested`, an HTTP 409 = a request already
#              stands, any other failure = `failed` and one ALERTS line.
#   migrations the migration_renumber.dir[.<project>] knob names the dir. A
#              file the PR adds (or renames) as <dir>/NNNN_slug.sql whose
#              number main already uses under another name gets ONE PR
#              comment that names both files. A read that fails posts nothing.
#   beat       one kind:"build" beat, stage pr_created, with the PR url and the
#              machine's bkey. An empty verdict puts the card in `review`.
#
# Record files in $LOCAL, each written after its call returns:
#   review-request.txt   requested <sha> | requested <sha> (already) | bound <sha> | failed <why>
#   migration-check.txt  off | clean | collision + one line per file | could-not-run <why> | comment-failed
#
# It reads the reap loop's globals (P KEY LOCAL POOL_SLUG POOL_SLUG_TOK
# PPR_REMOTE PPR_PR_URL PPR_PR_BASE) and calls its functions (pool_rest_read,
# say, ppr_lib, verdict_is, gh_rest_comment). The harness root is
# ${HARNESS:-${H:-}} only.

PPRR_MIG_RE='^[0-9]+_[a-z0-9_]+\.sql$'

# pprr_head <slug> <num> — the PR head sha. rc 1 and $PPR_REMOTE when the read
# does not answer a 40-hex sha.
pprr_head() {
  local out s=""
  out=$(pool_rest_read "repos/$1/pulls/$2" "${POOL_SLUG_TOK:-}")
  [ "$(head -n 1 <<<"$out")" = 200 ] && s=$(tail -n +2 <<<"$out" | jq -r '.head.sha // empty' 2>/dev/null)
  if [[ "$s" =~ ^[0-9a-f]{40}$ ]]; then printf '%s' "$s"; return 0; fi
  printf '%s' "${PPR_REMOTE:-}"
  return 1
}

# pprr_bound_verdict <head> — prints APPROVE when the relayed review.md's final
# verdict is APPROVE and the relayed reviewed-sha is exactly <head>. Else
# nothing. A missing reviewed-sha is not a bound APPROVE.
pprr_bound_verdict() {
  local rs
  [ -n "${1:-}" ] && [ -f "$LOCAL/review.md" ] || return 0
  command -v verdict_is >/dev/null 2>&1 || return 0
  verdict_is APPROVE -L "$LOCAL/review.md" 2>/dev/null || return 0
  rs=$(head -n 1 "$LOCAL/reviewed-sha" 2>/dev/null | tr -d '[:space:]')
  [ "$rs" = "$1" ] && printf 'APPROVE'
  return 0
}

# pprr_beat <verdict> <tier> <detail> — the BB shape of bin/lib/rb/gates.sh,
# keyed by the machine's build dir when the RESULT names one.
pprr_beat() {
  local h="${HARNESS:-${H:-}}" mbd bkey=""
  mbd=$(grep -oE '^BUILD_DIR: .*' "$LOCAL/RESULT" 2>/dev/null | sed 's/^BUILD_DIR: //' | head -n 1)
  [ -n "$mbd" ] && bkey="build:$P:$KEY:$(basename "$mbd")"
  [ -n "$h" ] && [ -x "$h/bin/beat.sh" ] || { say "push-rejected $KEY: no bin/beat.sh — the pr_created beat was not sent"; return 0; }
  "$h/bin/beat.sh" "$(jq -nc --arg bkey "$bkey" --arg p "$P" --arg t "$KEY" --arg tier "${2:-}" --arg v "${1:-}" \
      --arg pr "$PPR_PR_URL" --arg d "$3" \
      '{kind:"build"} + (if $bkey == "" then {} else {bkey:$bkey} end)
       + {project:$p,ticket_key:$t,stage:"pr_created",tier:(if $tier == "" then null else ($tier|tonumber) end),verdict:$v,pr_url:$pr,merged:false,detail:$d}')" \
    >/dev/null 2>&1 || say "push-rejected $KEY: the pr_created beat for $PPR_PR_URL did not send"
  return 0
}

# pprr_request_review <slug> <num> <head> — one lead review request. Writes
# review-request.txt after the call returns.
pprr_request_review() {
  local h="${HARNESS:-${H:-}}" err rc=0 why
  if [ -z "${3:-}" ]; then
    why="no PR head to bind a review to"
  elif [ -z "$h" ] || [ ! -x "$h/bin/lead-verdict.sh" ]; then
    why="no bin/lead-verdict.sh on this box"
  else
    err=$(mktemp "${TMPDIR:-/tmp}/pprr-lv.XXXXXX") || err=/dev/null
    HARNESS="$h" "$h/bin/lead-verdict.sh" request "$1" "$2" "$3" \
      --notes "hub-opened after push-rejected (BH-7383); plan: .harness/specs/$KEY/plan.md" >/dev/null 2>"$err" || rc=$?
    if [ "$rc" = 0 ]; then
      printf 'requested %s\n' "$3" > "$LOCAL/review-request.txt"
      [ "$err" = /dev/null ] || rm -f "$err"
      return 0
    fi
    if grep -q 'HTTP 409' "$err" 2>/dev/null; then
      printf 'requested %s (already)\n' "$3" > "$LOCAL/review-request.txt"
      rm -f "$err"
      return 0
    fi
    why="lead-verdict.sh rc $rc: $(tr '\n' ' ' < "$err" 2>/dev/null | head -c 200)"
    [ "$err" = /dev/null ] || rm -f "$err"
  fi
  printf 'failed %s\n' "$why" > "$LOCAL/review-request.txt"
  env HARNESS="$h" "$h/bin/alert-line.sh" "[pool/$P] $KEY: the hub opened $1#$2 after a push-rejected deferral, but the lead review request for head $3 failed ($why). The PR has no verdict, so the merge sweep holds it. Ask by hand: bin/lead-verdict.sh request $1 $2 $3"
  return 0
}

# pprr_migration_check <slug> <num> <head> <base> — writes migration-check.txt.
pprr_migration_check() {
  local slug="$1" n="$2" head="$3" base="$4" mf="$LOCAL/migration-check.txt"
  local dir out code body k=1 cnt files="[]" taken coll h="${HARNESS:-${H:-}}" cf
  if ! command -v mnr_conf >/dev/null 2>&1 && ! ppr_lib migration-renumber.sh; then
    printf 'could-not-run bin/lib/migration-renumber.sh is missing\n' > "$mf"; return 0
  fi
  mnr_conf "$P" 2>/dev/null
  dir="${MNR_C_DIR:-}"
  if [ -z "$dir" ] || [ "${MNR_C_MODE:-off}" = off ]; then printf 'off\n' > "$mf"; return 0; fi
  while :; do
    out=$(pool_rest_read "repos/$slug/pulls/$n/files?per_page=100&page=$k" "${POOL_SLUG_TOK:-}")
    code=$(head -n 1 <<<"$out"); body=$(tail -n +2 <<<"$out")
    cnt=$(jq 'if type == "array" then length else -1 end' 2>/dev/null <<<"$body")
    if [ "$code" != 200 ] || ! [[ "$cnt" =~ ^[0-9]+$ ]]; then
      printf 'could-not-run files page %s answered HTTP %s\n' "$k" "${code:-none}" > "$mf"; return 0
    fi
    files=$(jq -c --argjson a "$files" '$a + .' <<<"$body")
    [ "$cnt" -lt 100 ] && break
    if [ "$k" -ge 30 ]; then printf 'could-not-run more than 3000 files\n' > "$mf"; return 0; fi
    k=$((k + 1))
  done
  out=$(pool_rest_read "repos/$slug/contents/$dir?ref=$base" "${POOL_SLUG_TOK:-}")
  code=$(head -n 1 <<<"$out"); body=$(tail -n +2 <<<"$out")
  cnt=$(jq 'if type == "array" then length else -1 end' 2>/dev/null <<<"$body")
  if [ "$code" != 200 ] || ! [[ "$cnt" =~ ^[0-9]+$ ]]; then
    printf 'could-not-run contents of %s at %s answered HTTP %s\n' "$dir" "$base" "${code:-none}" > "$mf"; return 0
  fi
  if [ "$cnt" -ge 1000 ]; then printf 'could-not-run contents of %s is truncated at 1000\n' "$dir" > "$mf"; return 0; fi
  # TAKEN: main's migration names in <dir>, keyed by the decimal number.
  taken=$(jq -c --arg re "$PPRR_MIG_RE" \
    '[.[] | select(.type == "file" and (.name | test($re))) | {k: (.name | capture("^(?<n>[0-9]+)_").n | tonumber | tostring), name}]
     | reduce .[] as $x ({}; .[$x.k] = ((.[$x.k] // []) + [$x.name]))' <<<"$body")
  # BRANCH files added or renamed into <dir> (one level), against TAKEN.
  coll=$(jq -r --arg d "$dir" --arg re "$PPRR_MIG_RE" --argjson t "$taken" \
    '.[] | select(.status == "added" or .status == "renamed") | .filename
     | select((split("/") | .[:-1] | join("/")) == $d) | (split("/") | last) as $b
     | select($b | test($re)) | ($b | capture("^(?<n>[0-9]+)_").n) as $num
     | (($num | tonumber | tostring) as $key | ($t[$key] // []) | map(select(. != $b))) as $other
     | select($other | length > 0)
     | "`\($d)/\($b)` takes number \($num), which main already uses for `\($d)/\($other[0])`."' <<<"$files")
  if [ -z "$coll" ]; then printf 'clean\n' > "$mf"; return 0; fi
  cf=$(mktemp "${TMPDIR:-/tmp}/pprr-mig.XXXXXX") || { printf 'comment-failed no temp file\n' > "$mf"; return 0; }
  { printf '<!-- bh-7383 migration-number %s -->\n' "$head"
    printf 'Migration number check: this PR adds a migration whose number main already has.\n\n'
    printf '%s\n' "$coll" | sed 's/^/- /'
    printf '\nRenumber the file to the next free number above main'"'"'s highest before this PR merges.\n'
  } > "$cf"
  if command -v gh_rest_comment >/dev/null 2>&1 \
     && GH_TOKEN="${POOL_SLUG_TOK:-${GH_TOKEN:-}}" gh_rest_comment "$slug" "$n" "$cf"; then
    { printf 'collision\n'; printf '%s\n' "$coll"; } > "$mf"
  else
    { printf 'comment-failed\n'; printf '%s\n' "$coll"; } > "$mf"
    env HARNESS="$h" "$h/bin/alert-line.sh" "[pool/$P] $KEY: $slug#$n adds a migration whose number main already has, and the migration-number comment on the PR did not post (HTTP ${GH_REST_STATUS:-none}). Collisions: $(tr '\n' ' ' <<<"$coll" | head -c 300)"
  fi
  rm -f "$cf"
  return 0
}

# ppr_review_handoff — the three steps for $PPR_PR_URL, then one summary line.
ppr_review_handoff() {
  local url="${PPR_PR_URL:-}" slug n head v tier="" rv mv row=review
  [[ "$url" =~ ^https://github\.com/([^/]+/[^/]+)/pull/([0-9]+)$ ]] || return 0
  slug="${BASH_REMATCH[1]}"; n="${BASH_REMATCH[2]}"
  if ! head=$(pprr_head "$slug" "$n"); then
    say "push-rejected $KEY: the head of PR #$n did not read — the hand-off uses the branch head ${head:-none}"
  fi
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || head=""
  v=$(pprr_bound_verdict "$head")
  if [ "$v" = APPROVE ]; then
    printf 'bound %s\n' "$head" > "$LOCAL/review-request.txt"
    tier=$(grep -oE '^TIER: [12]' "$LOCAL/RESULT" 2>/dev/null | grep -oE '[12]' | head -n 1)
  else
    pprr_request_review "$slug" "$n" "$head"
  fi
  pprr_migration_check "$slug" "$n" "$head" "${PPR_PR_BASE:-main}"
  rv=$(head -n 1 "$LOCAL/review-request.txt" 2>/dev/null)
  case "$rv" in
    "requested "*"(already)") rv=already ;;
    requested*) rv=requested ;; bound*) rv=bound ;; *) rv=failed ;;
  esac
  mv=$(head -n 1 "$LOCAL/migration-check.txt" 2>/dev/null | awk '{print $1}')
  # The console's buildLane: pr_created + tier 1 + APPROVE is merge_queue.
  [ "$v" = APPROVE ] && [ "$tier" = 1 ] && row=merge_queue
  pprr_beat "$v" "$tier" "opened by the hub after push-rejected; review $rv"
  say "push-rejected $KEY: hand-off PR #$n head ${head:0:12}: row $row, review $rv, migrations ${mv:-could-not-run}"
  return 0
}
