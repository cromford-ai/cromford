#!/bin/bash
# bin/roadmap-render.sh — BH-7265 (BH-7243.2): render each listed project's
# roadmap board as docs/ROADMAP.html in its repo, through ONE pull request per
# project. A hub lane, daily at 06:41 (cron/lanes/741-roadmap-render.cron). It
# makes no model call, never writes the default branch and never merges.
#
# WHY. The roadmap board lives in the jobs DB. The repo copy is the record a
# client reads next to the code, in the example-org/project-6 docs/ROADMAP.html
# shape (bin/roadmap-import.sh reads that shape back).
#
# ONE TICK:
#   1. lane_gate_or_exit / lane_env_apply roadmap-render. flock -n
#      locks/roadmap-render.lock.
#   2. GET /api/settings/roadmap.render_projects: comma-separated projects.
#      Empty or unset: the summary says projects=0 and the tick ends, with no
#      other request and no GitHub call. An unreadable setting: FAILED
#      settings-read, no GitHub call.
#   3. GET /api/projects once: project -> repo. A project with no row (or a
#      repo that is not owner/name) is `skip=no-repo`.
#   4. Per project, in the listed order:
#        GET /api/roadmap/board?project=<p>   (a failure: FAILED board-read)
#        roadmap_html (bin/lib/roadmap-html.sh) with ROADMAP_RENDER_NOW, else
#        the wall clock, as the generated-at line
#        GET repos/<repo> -> default_branch
#        GET repos/<repo>/contents/docs/ROADMAP.html?ref=<default> (404 = absent)
#        equal to the render with line 2 (generated-at) dropped -> UNCHANGED
#        branch roadmap/render-<p>: the guard refuses the default branch, main,
#        master and any other name. Read the ref; on 404 create it from the
#        default head (a 422 counts only when a read-back shows the ref).
#        The branch file equal to the render (line 2 dropped): no PUT.
#        Else PUT contents (with the branch blob sha when there is one).
#        GET pulls?state=open&head=<owner>:roadmap/render-<p>: an open PR ->
#        PR_UPDATED (or PR_OPEN when no PUT was needed) pr=<its html_url>.
#        None -> POST pulls -> PR_CREATED pr=<html_url> only on a 201 with a
#        https html_url, else PR_FAILED and no pr=.
#      Any other failed step: FAILED <step> (http <status>), and the lane goes
#      to the next project. An rc 75 (rate limit, unverifiable) stops the loop:
#      stopped=rate-limited or stopped=unverifiable.
#   5. One line per project and one summary line, in logs/roadmap-render.log
#      and on stdout:
#      projects=<n> created=<n> updated=<n> unchanged=<n> failed=<n> skipped=<n> stopped=<none|rate-limited|unverifiable>
#      pr= is printed only with an html_url GitHub sent in this tick.
#
# A crash after the PUT leaves the branch with no PR: the next tick finds no
# open PR and opens one. The repo is the only state; no local file is kept.
#
# OFF: an empty roadmap.render_projects (the seed), flags/lane-off-roadmap-render,
# or bin/harness-ctl.sh off roadmap-render. Registry: catalog/lanes.d/roadmap-render.json.
# Note: docs/notes/2026-10-17-BH-7243.2-roadmap-board.md.
#
# gh-rest: no-graphql
set -uo pipefail
H="${HARNESS:-/root/harness}"
SELF="$(cd "$(dirname "$0")" && pwd)"
. "$H/bin/lib/env-path.sh" 2>/dev/null || . "$SELF/lib/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-$H}/env"; }
HENV=$(harness_env_dir "$H")
# shellcheck disable=SC1091
[ -r "$HENV/global.env" ] && { set -a; . "$HENV/global.env" 2>/dev/null; set +a; }
# shellcheck disable=SC1091
{
  . "$H/bin/lib/lane-gate.sh" 2>/dev/null || . "$SELF/lib/lane-gate.sh" 2>/dev/null || true
  . "$SELF/jobs-client.sh" 2>/dev/null || true
  . "$SELF/lib/gh-rest.sh" 2>/dev/null || true
  . "$SELF/lib/pr-trailers.sh" 2>/dev/null || true
  . "$SELF/lib/roadmap-html.sh" 2>/dev/null || true
}
# shellcheck source=bin/lib/deployment.sh
. "${HARNESS_DEPLOYMENT_FILE-$SELF/lib/deployment.sh}" 2>/dev/null || exit 0
command -v _jobs_req >/dev/null 2>&1 && command -v gh_rest >/dev/null 2>&1 && command -v roadmap_html >/dev/null 2>&1 \
  && command -v jq >/dev/null 2>&1 || exit 0
# Through bin/gh-rest-shim when it is installed, else gh api direct.
if [ -x "$SELF/gh-rest-shim" ]; then gh() { "$SELF/gh-rest-shim" "$@"; }; fi

LOG="$H/logs/roadmap-render.log"
FILE_PATH=docs/ROADMAP.html
mkdir -p "$H/logs" "$H/locks" 2>/dev/null
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
say() { log "$*"; echo "$*"; }
# rest <out-file> <method> <path> [args...]: one gh_rest call into a file (never
# a $( ), so GH_REST_STATUS survives); RC is its rc.
rest() { RC=0; GH_REST_STATUS=; GH_REST_REASON=; gh_rest "$2" "$3" "${@:4}" > "$1" 2>/dev/null || RC=$?; }
why() { echo "http ${GH_REST_STATUS:-000}${GH_REST_REASON:+ $GH_REST_REASON}"; }
# A failed GitHub step. rc 75 stops the loop; anything else ends this project.
gh_fail() {
  if [ "$RC" = 75 ]; then
    if [ "${GH_REST_REASON:-}" = rate-limit ]; then STOPPED=rate-limited; else STOPPED=unverifiable; fi
  fi
  OUTCOME="FAILED $1 ($(why))"
}
# The render with line 2 dropped when it is the generated-at line.
body_of() { sed '2{/^<!-- generated-at: [^>]* -->$/d}' "$1"; }
same_render() { cmp -s <(body_of "$1") <(body_of "$2"); }
# branch_ok <branch> <default>: the only branch this lane writes.
branch_ok() {
  [[ "$1" =~ ^roadmap/render-[A-Za-z0-9._-]{1,64}$ ]] || return 1
  case "$1" in "$2"|main|master) return 1 ;; esac
  return 0
}

# render_one <project> <repo> <render-file>: sets OUTCOME and PR_URL.
render_one() {
  local p="$1" repo="$2" new="$3" def br head bsha put=1 url n
  OUTCOME=""; PR_URL=""
  rest "$TMPD/repo.json" GET "repos/$repo"
  if [ "$RC" != 0 ] || ! def=$(jq -er '.default_branch | select(type == "string" and length > 0)' "$TMPD/repo.json" 2>/dev/null); then
    gh_fail repo-read; return; fi
  br="roadmap/render-$p"
  if ! branch_ok "$br" "$def"; then OUTCOME="FAILED branch-guard (refused $br onto default $def)"; return; fi
  rest "$TMPD/main.json" GET "repos/$repo/contents/$FILE_PATH?ref=$def"
  if [ "$RC" = 0 ]; then
    if ! jq -er '.content' "$TMPD/main.json" 2>/dev/null | base64 -d > "$TMPD/main.html" 2>/dev/null; then
      OUTCOME="FAILED contents-decode"; return; fi
    if same_render "$TMPD/main.html" "$new"; then OUTCOME=UNCHANGED; return; fi
  elif [ "$RC" != 44 ]; then gh_fail contents-read; return
  fi
  # The branch: read it, else create it from the default head.
  rest "$TMPD/ref.json" GET "repos/$repo/git/ref/heads/$br"
  if [ "$RC" = 44 ]; then
    rest "$TMPD/head.json" GET "repos/$repo/git/ref/heads/$def"
    if [ "$RC" != 0 ] || ! head=$(jq -er '.object.sha' "$TMPD/head.json" 2>/dev/null); then gh_fail head-read; return; fi
    jq -nc --arg r "refs/heads/$br" --arg s "$head" '{ref:$r, sha:$s}' > "$TMPD/ref.in"
    rest "$TMPD/ref.out" POST "repos/$repo/git/refs" --input "$TMPD/ref.in"
    if [ "$RC" != 0 ]; then
      # gh_rest drops non-2xx bodies, so "already exists" is proven by reading the ref back.
      if [ "${GH_REST_STATUS:-}" != 422 ]; then gh_fail ref-create; return; fi
      rest "$TMPD/ref2.json" GET "repos/$repo/git/ref/heads/$br"
      if [ "$RC" != 0 ]; then gh_fail ref-create; return; fi
    fi
  elif [ "$RC" != 0 ]; then gh_fail ref-read; return
  fi
  # The file on the branch: its blob sha, and whether it already holds this render.
  bsha=""
  rest "$TMPD/blob.json" GET "repos/$repo/contents/$FILE_PATH?ref=$br"
  if [ "$RC" = 0 ]; then
    bsha=$(jq -r '.sha // ""' "$TMPD/blob.json" 2>/dev/null)
    if jq -er '.content' "$TMPD/blob.json" 2>/dev/null | base64 -d > "$TMPD/branch.html" 2>/dev/null \
      && same_render "$TMPD/branch.html" "$new"; then put=0; fi
  elif [ "$RC" != 44 ]; then gh_fail contents-branch; return
  fi
  if [ "$put" = 1 ]; then
    jq -nc --arg m "Roadmap: render $FILE_PATH ($p)" --arg c "$(base64 -w0 < "$new")" --arg s "$bsha" --arg b "$br" \
      '{message:$m, content:$c, branch:$b} + (if $s == "" then {} else {sha:$s} end)' > "$TMPD/put.in"
    rest "$TMPD/put.out" PUT "repos/$repo/contents/$FILE_PATH" --input "$TMPD/put.in"
    if [ "$RC" != 0 ]; then gh_fail contents-write; return; fi
  fi
  # ONE PR per project: reuse the open one on this branch.
  rest "$TMPD/pulls.json" GET "repos/$repo/pulls?state=open&head=${repo%%/*}:$br"
  if [ "$RC" != 0 ] || ! n=$(jq -er 'if type == "array" then length else error end' "$TMPD/pulls.json" 2>/dev/null); then
    gh_fail pulls-read; return; fi
  if [ "$n" -ge 1 ]; then
    url=$(jq -r '.[0].html_url // "" | select(startswith("https://"))' "$TMPD/pulls.json" 2>/dev/null)
    if [ "$put" = 1 ]; then OUTCOME=PR_UPDATED; else OUTCOME=PR_OPEN; fi
    PR_URL="$url"; return
  fi
  printf 'bin/roadmap-render.sh rendered `%s` from the roadmap board of `%s` (GET /api/roadmap/board).\n\nThe lane opens or updates this one PR and never merges it. Merge it by hand when the roadmap reads right.\n' \
    "$FILE_PATH" "$p" > "$TMPD/body.md"
  # >>> pr trailers (BH-3987)
  # The lane opened this PR, and no ticket owns its branch.
  command -v pr_trailers_apply >/dev/null 2>&1 && { pr_trailers_apply "$TMPD/body.md" lane:roadmap-render none \
    || log "$p: pr trailers: could not write $TMPD/body.md, PR opened without trailers"; }
  jq -nc --arg t "Roadmap: render $FILE_PATH ($p)" --arg h "$br" --arg b "$def" --rawfile body "$TMPD/body.md" \
    '{title:$t, head:$h, base:$b, body:$body}' > "$TMPD/pr.in"
  rest "$TMPD/pr.out" POST "repos/$repo/pulls" --input "$TMPD/pr.in"
  # <<< pr trailers
  if [ "$RC" = 0 ] && [ "${GH_REST_STATUS:-}" = 201 ] \
     && url=$(jq -er '.html_url | select(type == "string" and startswith("https://"))' "$TMPD/pr.out" 2>/dev/null); then
    OUTCOME=PR_CREATED; PR_URL="$url"; return
  fi
  [ "$RC" = 75 ] && { gh_fail pulls-create; return; }
  OUTCOME="PR_FAILED ($(why)$( [ "$RC" = 0 ] && echo ' no html_url'))"
}

tick() {
  command -v lane_gate_or_exit >/dev/null 2>&1 && lane_gate_or_exit roadmap-render
  command -v lane_env_apply >/dev/null 2>&1 && lane_env_apply roadmap-render
  exec 9>"$H/locks/roadmap-render.lock" || exit 0
  flock -n 9 || exit 0
  # Per-tick scratch only (removed on exit): no state, so it lives under TMPDIR,
  # not state/ (tests/no-state-files.bh-4159-test.sh).
  TMPD=$(mktemp -d "${TMPDIR:-/tmp}/roadmap-render.XXXXXX") || exit 0
  # shellcheck disable=SC2064
  trap "case '$TMPD' in */roadmap-render.?*) rm -rf '$TMPD' ;; esac" EXIT

  local now raw list p repo nproj=0 created=0 updated=0 unchanged=0 failed=0 skipped=0
  STOPPED=none
  now="${ROADMAP_RENDER_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"
  if ! _jobs_req GET /api/settings/roadmap.render_projects > "$TMPD/setting.json" \
     || ! raw=$(jq -er '.setting.value // "" | tostring' "$TMPD/setting.json" 2>/dev/null); then
    say "FAILED settings-read (http ${JOBS_HTTP:-none}); no GitHub call"
    say "projects=0 created=0 updated=0 unchanged=0 failed=1 skipped=0 stopped=none"
    exit 0
  fi
  # The listed names, trimmed, valid and de-duplicated, in the listed order.
  list=$(tr ',' '\n' <<<"$raw" | sed -E 's/^[[:space:]]+|[[:space:]]+$//g' | grep -E '^[A-Za-z0-9._-]{1,64}$' | awk '!seen[$0]++')
  if [ -z "$list" ]; then
    say "projects=0 created=0 updated=0 unchanged=0 failed=0 skipped=0 stopped=none"
    exit 0
  fi
  if ! _jobs_req GET /api/projects > "$TMPD/projects.json" || ! jq -e '(.projects | type) == "array"' "$TMPD/projects.json" >/dev/null 2>&1; then
    say "FAILED projects-read (http ${JOBS_HTTP:-none}); no GitHub call"
    say "projects=0 created=0 updated=0 unchanged=0 failed=1 skipped=0 stopped=none"
    exit 0
  fi
  while read -r p <&3; do
    [ "$STOPPED" = none ] || break
    nproj=$((nproj + 1))
    repo=$(jq -r --arg p "$p" '[.projects[] | select(.project == $p) | .repo][0] // ""' "$TMPD/projects.json")
    if ! [[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
      say "$p skip=no-repo"; skipped=$((skipped + 1)); continue
    fi
    if ! _jobs_req GET "/api/roadmap/board?project=$p" > "$TMPD/board.json"; then
      say "$p FAILED board-read (http ${JOBS_HTTP:-none})"; failed=$((failed + 1)); continue
    fi
    if ! roadmap_html "$TMPD/board.json" "$p" "$now" > "$TMPD/new.html"; then
      say "$p FAILED render"; failed=$((failed + 1)); continue
    fi
    render_one "$p" "$repo" "$TMPD/new.html"
    case "$OUTCOME" in
      PR_CREATED) created=$((created + 1)) ;;
      PR_UPDATED|PR_OPEN) updated=$((updated + 1)) ;;
      UNCHANGED) unchanged=$((unchanged + 1)) ;;
      *) failed=$((failed + 1)) ;;
    esac
    say "$p $OUTCOME${PR_URL:+ pr=$PR_URL}"
  done 3<<<"$list"
  say "projects=$nproj created=$created updated=$updated unchanged=$unchanged failed=$failed skipped=$skipped stopped=$STOPPED"
}

case "${1:-}" in
  '') tick ;;
  *) echo "usage: roadmap-render.sh" >&2; exit 2 ;;
esac
exit 0
