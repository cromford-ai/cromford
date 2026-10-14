#!/bin/bash
# bin/lib/gh-pr-create.sh — OPENING A PR IS A LADDER, NOT ONE RUNG.
# Sourced, never executed.
#
#   gh_pr_create_ladder <owner/repo> <head> <base> <title> <body-file> \
#                       <stderr-log> <pipeline-log> [tag]
#         -> the PR URL on stdout, rc 0. Nothing on stdout and rc 1 when every
#            rung failed. Never prints anything but the URL.
#   gh_pr_rest_read <api-path> [token]
#         -> line 1 = the HTTP status (empty when there was none), the rest is the
#            body. The status is read BEFORE the body on purpose: a 403 and a
#            404 are both "gh exited 1" without it (BH-709).
#
# WHY (BH-848, 2026-09-18). `gh pr create` is GraphQL under the hood, and on a
# pool machine it runs on a GitHub App installation token whose GraphQL budget is
# chronically exhausted:
#   GraphQL: API rate limit already exceeded for installation ID 161623167.
# `PR_URL` came back empty; the adopt fallback in bin/run-build.sh was `gh pr
# list` — GraphQL again, same bucket, same failure — so the build wrote
# PR_CREATE_FAILED and bin/merge-sweep.sh, which walks only records whose line 1
# is `PR_CREATED https://`, never saw the PR that was in fact opened. Ten
# CI-green APPROVE PRs sat unswept in one day.
#
# REST AND GRAPHQL ARE SEPARATE BUDGETS. This repo already learned that for
# READS — bin/fly-pool.sh's `# >>> pr verify rest` (BH-709) and
# bin/lib/gh-pr-list.sh's REST path (BH-374) — and not for the create. So:
#
#   rung graphql          gh pr create (today's call, byte for byte)
#   rung graphql-adopt    gh pr list --head <branch> --state open (today's adopt,
#                         byte for byte — it used to live in bin/run-build.sh)
#   rung rest-adopt       GET repos/<slug>/pulls?head=<owner>:<branch>&state=open
#   rung rest             POST repos/<slug>/pulls
#   rung rest:default-pat the token bin/lib/gh-app-auth.sh saved before it
#                         swapped in the App token, when there is one
#   rung rest:admin-pat   GH_ADMIN_TOKEN from env/github-admin.env, when set
#   (an identity rung's ADOPT read always runs — the PR it finds was authored
#    by whoever opened it, not by the token reading it. Its CREATE is skipped
#    when the login READS as one outside HARNESS_PR_AUTHORS — a PR the sweep
#    would drop on author is not a success, see _gpc_author_ok. A login that
#    would not read at all is UNKNOWN and the create runs.)
#
# A pool machine holds exactly ONE identity — bin/fly-pool.sh REPLACES the PAT
# line in the env bundle with the App token — so there the useful rung is REST on
# the same token, and the log says `no second identity on this machine` rather
# than pretending it tried. Identity rungs exist on watcher boxes and the hub,
# where `gh_auth_for` (bin/lib/gh-app-auth.sh) has stashed the box's own token.
#
# THE RATE-LIMIT REGEX ONLY PICKS THE WORDS. `_gpc_is_ratelimit` decides how the
# log line READS, never whether REST runs: a GraphQL create that failed for any
# reason, with no PR to adopt, is exactly the case REST is for, and gating on a
# message shape would reintroduce this bug the day GitHub rewords the cap.
#
# A RUNG THAT ANSWERS 201 WITHOUT AN html_url IS A FAILED RUNG. An empty URL is
# what the RESULT ratchet in bin/run-build.sh exists to refuse; it must never be
# manufactured here.
#
# THE GRAPHQL ADOPT IS A RUNG, NOT A CASUALTY. `gh pr list` is the same budget
# the create just spent, so it is not the FIX for this ticket — but it is what the
# fleet does today when a create says "a pull request already exists" (continue
# mode always, retries sometimes), and REST is not always the healthy budget: a
# box whose REST quota is the exhausted one, with GraphQL fine, adopted before
# #848 and must keep adopting. It sits ABOVE the kill flag on purpose.
#
# THE KILL FLAG puts the machine back on today's behaviour byte for byte:
#   PR_CREATE_REST_FALLBACK=0 (env/global.env)  or  the settings row
#   switch.pr-create-rest-fallback-off[.<box>]=1 (no row: flags/pr-create-rest-fallback-off)
# rungs graphql and graphql-adopt run — the create and the adopt that were the
# whole of bin/run-build.sh's PR open before #848 — and nothing else.
#
# NO TOKEN VALUE EVER REACHES A LOG. Rungs are named by WORD, the way
# bin/lib/gh-repo-token.sh names default/admin.
[ -n "${_GPC_LOADED:-}" ] && return 0
_GPC_LOADED=1
_GPC_H="${HARNESS:-/root/harness}"
# The env dir is RESOLVED, never spelled (tests/env-path-test.sh): on a pool
# machine it is a tmpfs, on a box /etc/harness/env, and $HARNESS/env is a compat
# symlink for ONE release. Spelling it would make rung rest:admin-pat silently
# stop existing the day the symlink goes — the same resolution the reconciler in
# this lane already does.
# The sibling is reached through its own variable, not an inline `$(dirname …)/`
# — tests/env-path-test.sh reads a `)/env` as a spelled env dir, and it is right
# to: that is the shape the rule exists to catch.
_GPC_LIBDIR=$(dirname "${BASH_SOURCE[0]}")
# shellcheck source=bin/lib/env-path.sh
. "$_GPC_H/bin/lib/env-path.sh" 2>/dev/null \
  || . "$_GPC_LIBDIR/env-path.sh" 2>/dev/null \
  || harness_env_dir() { printf '%s\n' "${1:-${HARNESS:-/root/harness}}/env"; }

# The sweep's author set and matcher, when the lib is beside us. Sourcing it only
# defines functions and two strings — its own $_HPL_H and
# HARNESS_PR_AUTHORS_DEFAULT, which is where the default author set lives and the
# reason nothing here spells a login; nothing runs.
# shellcheck source=bin/lib/gh-pr-list.sh
command -v harness_pr_author_match >/dev/null 2>&1 \
  || . "$_GPC_H/bin/lib/gh-pr-list.sh" 2>/dev/null \
  || . "$_GPC_LIBDIR/gh-pr-list.sh" 2>/dev/null \
  || true

_gpc_log() { # _gpc_log <pipeline-log> <text...>
  local lg="${1:-}"; shift
  [ -n "$lg" ] || return 0
  printf '%s %s\n' "$(date -u '+%Y-%m-%d %H:%M:%SZ')" "$*" >> "$lg" 2>/dev/null || true
}

# _gpc_switch — rc 0 when switch.pr-create-rest-fallback-off[.<box>] (no row:
# the file flags/pr-create-rest-fallback-off) is ON, 1 when not, 2 when
# lane-switch.sh could not load. A subshell: the resolver never reaches the caller.
_gpc_switch() {
  ( HARNESS="$_GPC_H"; . "$_GPC_LIBDIR/lane-switch.sh" >/dev/null 2>&1 || exit 2; lane_switch pr-create-rest-fallback-off file ) >/dev/null 2>&1
}

_gpc_fallback_on() { # rc 1 = the ladder stops at rung 1
  local rc=0
  if _gpc_switch; then return 1; else rc=$?; fi
  [ "$rc" = 2 ] && [ -f "$_GPC_H/flags/pr-create-rest-fallback-off" ] && return 1
  [ "${PR_CREATE_REST_FALLBACK:-1}" = 0 ] && return 1
  return 0
}

_gpc_is_ratelimit() { # _gpc_is_ratelimit <text>; rc 0 = this reads like a cap
  grep -qiE 'API rate limit (already )?exceeded|secondary rate limit|HTTP 403|HTTP 429' <<<"${1:-}"
}

# The first pull URL in a blob — used ONLY on gh's own stdout, which is the URL
# it just printed, and on nothing that came from a human note (BH-848's mislink).
_gpc_first_url() {
  printf '%s' "${1:-}" | grep -oE 'https://github\.com/[^ ]+/pull/[0-9]+' | head -n 1
}

# The last slice of a stderr log, flattened for one log line.
_gpc_tail_err() {
  tail -c 300 "${1:-/dev/null}" 2>/dev/null | tr '\n\t' '  ' | tr -s ' '
}

# The API's own words for a failure, never our guess at them, never a token.
_gpc_reason() {
  local msg
  msg=$(jq -r '.message // empty' 2>/dev/null <<<"${1:-}")
  [ -n "$msg" ] || msg=$(printf '%.120s' "$(tr '\n\t' '  ' <<<"${1:-}" | tr -s ' ')")
  printf '%.160s' "$msg"
}

_gpc_split() { # status line + body -> line 1 = code (empty if none), rest = body
  # The CR is stripped off the code: a header line is CRLF-terminated, and a
  # status of "200<CR>" matches no case arm anywhere — it would read as UNKNOWN
  # and every rung would fall through a perfectly good answer.
  awk 'NR==1 && $0 ~ /^HTTP\// {c=$2; sub(/\r$/, "", c); print c; next}
       NR==1 {print ""}
       f {print}
       /^\r?$/ {f=1}' <<<"${1:-}"
}

gh_pr_rest_read() { # gh_pr_rest_read <api-path> [token] -> line 1 = HTTP code, rest = body
  local _path="${1:?api path}" _tok="${2:-}" _raw=""
  if [ -n "$_tok" ]; then _raw=$(GH_TOKEN="$_tok" gh api -i "$_path" 2>>"${_GPC_STDERR:-/dev/null}")
  else _raw=$(gh api -i "$_path" 2>>"${_GPC_STDERR:-/dev/null}"); fi
  _gpc_split "$_raw"
}

_gpc_rest_post() { # _gpc_rest_post <slug> <head> <base> <title> <body-file> [token]
  local _slug="$1" _head="$2" _base="$3" _title="$4" _bf="$5" _tok="${6:-}" _raw=""
  if [ -n "$_tok" ]; then
    _raw=$(GH_TOKEN="$_tok" gh api -i -X POST "repos/$_slug/pulls" \
      -f "head=$_head" -f "base=$_base" -f "title=$_title" -F "body=@$_bf" 2>>"${_GPC_STDERR:-/dev/null}")   # pr-trailers: receives an already-trailered body
  else
    _raw=$(gh api -i -X POST "repos/$_slug/pulls" \
      -f "head=$_head" -f "base=$_base" -f "title=$_title" -F "body=@$_bf" 2>>"${_GPC_STDERR:-/dev/null}")   # pr-trailers: receives an already-trailered body
  fi
  _gpc_split "$_raw"
}

# rung 2 / rung 4a — ADOPT. The PR already existing IS success; a failed read is
# UNKNOWN and falls through, it is never read as "there is no PR" (D11/BH-709).
_gpc_rung_adopt() { # <slug> <owner> <head> <plog> <tag> <rung> <token>
  local slug="$1" owner="$2" head="$3" plog="$4" tag="$5" rung="$6" tok="$7"
  local out code body url
  out=$(gh_pr_rest_read "repos/$slug/pulls?head=$owner:$head&state=open" "$tok")
  code=$(head -n 1 <<<"$out"); body=$(tail -n +2 <<<"$out")
  case "$code" in
    200)
      url=$(jq -r 'if type == "array" and length > 0 then (.[0].html_url // empty) else empty end' 2>/dev/null <<<"$body")
      if [ -n "$url" ]; then
        _gpc_log "$plog" "[$tag] rung $rung: adopted the open PR already on $head — $url"
        printf '%s\n' "$url"; return 0
      fi
      _gpc_log "$plog" "[$tag] rung $rung: HTTP 200 with an empty list — there is genuinely no open PR on $head to adopt" ;;
    "") _gpc_log "$plog" "[$tag] rung $rung: the adopt read answered no HTTP status at all — UNKNOWN, read as neither a PR nor as absent" ;;
    *)  _gpc_log "$plog" "[$tag] rung $rung: the adopt read answered HTTP $code ($(_gpc_reason "$body")) — UNKNOWN, read as neither a PR nor as absent" ;;
  esac
  return 1
}

# rung 2 — the GRAPHQL ADOPT, exactly as bin/run-build.sh made it before #848:
# no -R (rung 1 is cwd-scoped too), --state open, first url only. It runs on the
# same budget the create just spent, so on a rate-limited pool box it fails and
# costs one call; on a box whose REST quota is the exhausted one it is the rung
# that works, and with the kill flag set it is the whole of today's behaviour.
_gpc_rung_graphql_adopt() { # <head> <plog> <tag>
  local head="$1" plog="$2" tag="$3" url
  url=$(_gpc_first_url "$(gh pr list --head "$head" --state open --json url -q '.[0].url' \
        2>>"${_GPC_STDERR:-/dev/null}")")
  if [ -n "$url" ]; then
    _gpc_log "$plog" "[$tag] rung graphql-adopt: adopted the open PR already on $head — $url"
    printf '%s\n' "$url"; return 0
  fi
  _gpc_log "$plog" "[$tag] rung graphql-adopt: gh pr list named no open PR on $head — climbing"
  return 1
}

# rung 3 / rung 4b — CREATE over REST.
_gpc_rung_create() { # <slug> <owner> <head> <base> <title> <body-file> <plog> <tag> <rung> <token>
  local slug="$1" owner="$2" head="$3" base="$4" title="$5" bf="$6" plog="$7" tag="$8" rung="$9" tok="${10}"
  local out code body url
  out=$(_gpc_rest_post "$slug" "$head" "$base" "$title" "$bf" "$tok")
  code=$(head -n 1 <<<"$out"); body=$(tail -n +2 <<<"$out")
  case "$code" in
    201)
      url=$(jq -r '.html_url // empty' 2>/dev/null <<<"$body")
      if [ -n "$url" ]; then
        _gpc_log "$plog" "[$tag] rung $rung: created $url over REST"
        printf '%s\n' "$url"; return 0
      fi
      # D9: a 201 we cannot read a URL out of is a FAILED rung. An empty URL is
      # exactly the claim the RESULT ratchet refuses, and inventing one here
      # would put the lie one layer deeper.
      _gpc_log "$plog" "[$tag] rung $rung: HTTP 201 carrying no html_url — counted as a FAILED rung, never as an empty url" ;;
    422)
      # NARROW (D10): only GitHub's own "a pull request already exists" means the
      # head is taken. Every other 422 (deleted base branch, no commits between)
      # is a real refusal and reads as one.
      if grep -qi 'already exists' <<<"$body"; then
        _gpc_log "$plog" "[$tag] rung $rung: HTTP 422 says a pull request already exists for $head — re-reading it over REST"
        _gpc_rung_adopt "$slug" "$owner" "$head" "$plog" "$tag" "$rung-adopt" "$tok" && return 0
      else
        _gpc_log "$plog" "[$tag] rung $rung: HTTP 422 refused the create ($(_gpc_reason "$body"))"
      fi ;;
    403|429)
      _gpc_log "$plog" "[$tag] rung $rung: HTTP $code — this identity is rate-limited or forbidden on $slug ($(_gpc_reason "$body"))" ;;
    "") _gpc_log "$plog" "[$tag] rung $rung: the create POST answered no HTTP status at all" ;;
    *)  _gpc_log "$plog" "[$tag] rung $rung: HTTP $code ($(_gpc_reason "$body"))" ;;
  esac
  return 1
}

# AN IDENTITY THE SWEEP CANNOT SEE IS NOT A RUNG (review round 2). A PR opened on
# the default or admin PAT is AUTHORED by that account, and bin/merge-sweep.sh
# (harness_pr_author_match, bin/lib/gh-pr-list.sh) drops every PR whose author is
# outside HARNESS_PR_AUTHORS — default `operator app/cromford`. If the PAT's
# login is not in that set the ladder would "succeed" into a PR the sweep and the
# conductor never touch: the same invisibility this ticket exists to kill, one
# layer over. So each identity's login is read ONCE (`gh api user`, REST, on that
# token) and checked against the set before its CREATE runs; an outsider's create
# is skipped with the reason in pipeline.log. The ADOPT read ahead of it is never
# gated: adopting is reading, and the PR it finds was authored by whoever opened
# it, not by the token asking. A login that WOULD NOT READ is a different
# answer: `gh api user` fails on a blip, a 5xx or a secondary rate limit, and
# D11 has one rule for a failed read — it is UNKNOWN, never a fact. So it falls
# through to the rung, logged as unknown, and the sweep's own author filter stays
# the backstop. The matcher is the sweep's own where the lib is present, so the
# two can never drift.
_gpc_author_ok() { # _gpc_author_ok <login>; rc 0 = the sweep will see PRs by this login
  local l="${1:-}" aset
  [ -n "$l" ] || return 1
  if command -v harness_pr_author_match >/dev/null 2>&1; then
    harness_pr_author_match "$l"; return $?
  fi
  # THE SET IS ONE STRING (bin/lib/gh-pr-list.sh: "Nothing else may hardcode a
  # login"), so the default is that lib's own HARNESS_PR_AUTHORS_DEFAULT and not
  # a second copy of the literal here. With neither the lib nor the env var there
  # is no set to check against, and no set is UNKNOWN, not "an outsider" — the
  # rung runs. Both sides are bared the way harness_pr_author_match bares them
  # (`app/x`, `x[bot]` and `x` are one actor), so this fallback and the sweep's
  # real matcher cannot answer differently on a spelling.
  aset=$(_gpc_author_set)
  [ -n "$aset" ] || return 0
  l="${l#app/}"; l="${l%\[bot\]}"
  case " $(printf '%s' "$aset" | sed 's#app/##g; s#\[bot\]##g') " in *" $l "*) return 0 ;; esac
  return 1
}
_gpc_login_of() { # _gpc_login_of <token> -> the login, or nothing
  GH_TOKEN="$1" gh api user -q .login 2>>"${_GPC_STDERR:-/dev/null}" | tr -d '\r' | head -n 1
}
_gpc_author_set() { # the set, for the log line — names only, never a token
  if command -v harness_pr_authors >/dev/null 2>&1; then harness_pr_authors
  else printf '%s\n' "${HARNESS_PR_AUTHORS:-${HARNESS_PR_AUTHORS_DEFAULT:-}}"; fi
}

# EVERY OTHER IDENTITY THIS MACHINE HOLDS, in order, as "<word><TAB><token>".
# Read, never exported: the token goes into the environment of ONE gh call and
# the build's own GH_TOKEN is untouched.
_gpc_other_identities() {
  local cur="${GH_TOKEN:-}" admin envd
  if [ -n "${_GHAA_DEFAULT_TOK:-}" ] && [ "${_GHAA_DEFAULT_TOK}" != "$cur" ]; then
    printf 'default-pat\t%s\n' "$_GHAA_DEFAULT_TOK"
  fi
  envd=$(harness_env_dir "$_GPC_H")
  admin=$(sed -n 's/^\(export \)\{0,1\}GH_ADMIN_TOKEN=//p' "$envd/github-admin.env" 2>/dev/null \
          | tr -d "\"'" | head -n 1)
  if [ -n "$admin" ] && [ "$admin" != "$cur" ] && [ "$admin" != "${_GHAA_DEFAULT_TOK:-}" ]; then
    printf 'admin-pat\t%s\n' "$admin"
  fi
}

gh_pr_create_ladder() { # <slug> <head> <base> <title> <body-file> <stderr-log> <pipeline-log> [tag]
  local slug="${1:?owner/repo}" head="${2:?head branch}" base="${3:?base branch}" \
        title="${4:-}" bf="${5:-}" errlog="${6:-/dev/null}" plog="${7:-}" tag="${8:-pr-create}"
  local _GPC_STDERR="$errlog"          # every rung's stderr lands where the caller reads it
  local owner="${slug%%/*}" url="" last="" name tok login n=0

  url=$(_gpc_first_url "$(gh pr create --head "$head" --base "$base" --title "$title" \
        --body-file "$bf" 2>>"$errlog")")   # pr-trailers: receives an already-trailered body
  if [ -n "$url" ]; then
    _gpc_log "$plog" "[$tag] rung graphql: created $url"
    printf '%s\n' "$url"; return 0
  fi

  last=$(_gpc_tail_err "$errlog")
  if _gpc_is_ratelimit "$last"; then
    _gpc_log "$plog" "[$tag] rung graphql: create rate-limited on the current identity — REST is a separate budget, climbing"
  else
    _gpc_log "$plog" "[$tag] rung graphql: create produced no url — climbing to REST"
  fi

  # ABOVE THE KILL FLAG. This is the adopt bin/run-build.sh has always done; the
  # flag switches off the REST rungs #848 ADDED, never the behaviour it replaced.
  url=$(_gpc_rung_graphql_adopt "$head" "$plog" "$tag") \
    && { printf '%s\n' "$url"; return 0; }

  if ! _gpc_fallback_on; then
    _gpc_log "$plog" "[$tag] the REST fallback is switched off (PR_CREATE_REST_FALLBACK=0 or flags/pr-create-rest-fallback-off) — the ladder stops after rung graphql-adopt, which is the pre-#848 behaviour"
    return 1
  fi

  url=$(_gpc_rung_adopt "$slug" "$owner" "$head" "$plog" "$tag" rest-adopt "") \
    && { printf '%s\n' "$url"; return 0; }
  url=$(_gpc_rung_create "$slug" "$owner" "$head" "$base" "$title" "$bf" "$plog" "$tag" rest "") \
    && { printf '%s\n' "$url"; return 0; }   # pr-trailers: receives an already-trailered body

  while IFS=$'\t' read -r name tok; do
    [ -n "${tok:-}" ] || continue
    n=$((n + 1))
    # ADOPT FIRST, UNGATED (review round 4). The adopt read only asks whether an
    # open PR already sits on the head; that PR was authored by whoever opened it
    # — on the path these rungs exist for, the ambient identity, which created
    # it and then 403'd before it could report the url — so who THIS identity is
    # has no bearing on the answer. Gating the adopt behind the login turned a
    # recoverable tick into `every rung failed`.
    url=$(_gpc_rung_adopt "$slug" "$owner" "$head" "$plog" "$tag" "rest:$name" "$tok") \
      && { printf '%s\n' "$url"; return 0; }
    login=$(_gpc_login_of "$tok")
    # A LOGIN THAT WOULD NOT READ IS UNKNOWN, NEVER "NOT ONE OF OURS" (D11 /
    # BH-709, review round 3). `gh api user` fails on a network blip, a 5xx or a
    # secondary rate limit, and reading that as an outsider deletes the last rung
    # of the ladder — on exactly the path where the ambient identity has already
    # 403'd, which is the only reason these rungs exist. So an unreadable login
    # falls THROUGH to the rung, said in its own words, and only a login we did
    # read and that is outside the set skips.
    if [ -z "$login" ]; then
      _gpc_log "$plog" "[$tag] rung rest:$name: its login would not read ($(_gpc_tail_err "$errlog")) — UNKNOWN, not an outsider, so the rung runs and bin/merge-sweep.sh's author filter is the backstop"
    elif ! _gpc_author_ok "$login"; then
      _gpc_log "$plog" "[$tag] rung rest:$name skipped — its login '$login' is not in HARNESS_PR_AUTHORS ($(_gpc_author_set | tr '\n' ' ' | sed 's/ $//')), so a PR it opened would be invisible to bin/merge-sweep.sh; set HARNESS_PR_AUTHORS in env/global.env to include it (only its create is skipped: its adopt read ran above)"
      continue
    fi
    url=$(_gpc_rung_create "$slug" "$owner" "$head" "$base" "$title" "$bf" "$plog" "$tag" "rest:$name" "$tok") \
      && { printf '%s\n' "$url"; return 0; }   # pr-trailers: receives an already-trailered body
  done < <(_gpc_other_identities)
  [ "$n" = 0 ] && _gpc_log "$plog" "[$tag] no second identity on this machine — the ladder ends at rung rest"
  _gpc_log "$plog" "[$tag] every rung failed; the last error was: $(_gpc_tail_err "$errlog")"
  return 1
}
